using MeetingQ.Infrastructure;
using MeetingQ.Services.Interfaces;
using SherpaOnnx;
using System.IO;
using System.Threading.Channels;

namespace MeetingQ.Services;

/// <summary>
/// Fully local real-time ASR via sherpa-onnx (in-process ONNX inference, no network):
/// - streaming Paraformer (zh-en, int8) with built-in endpoint detection — emits rolling
///   partials plus one definite final per sentence, Chinese punctuation included
/// - ERes2Net speaker embeddings + online centroid clustering → "发言人N" labels
///
/// Audio contract (same as AudioCaptureService produces): PCM16, 16 kHz, mono, ~100 ms frames.
/// </summary>
public sealed class SherpaOnnxAsrService : IAsrService, ISpeakerRefinement
{
    private const int SampleRate = 16000;
    private const int MaxEmbeddingSamples = SampleRate * 12;
    private const int MaxUtteranceBufferSamples = SampleRate * 30;

    private readonly record struct WorkItem(byte[]? Frame, bool Flush, TaskCompletionSource? Done);

    private readonly Channel<WorkItem> _queue = Channel.CreateBounded<WorkItem>(
        new BoundedChannelOptions(2000) { SingleReader = true, SingleWriter = false });

    private int _droppedFrames;

    private OnlineRecognizer? _recognizer;
    private SpeakerEmbeddingExtractor? _extractor;
    private readonly SpeakerClusterer _speakerCluster = new();

    // Voiceprint library (live hit): named entries cached at connect time.
    private readonly VoiceprintLibraryService? _voiceprints;
    private List<(long Id, string Name, float[] Centroid)> _namedLibrary = new();
    private readonly HashSet<int> _libraryResolvedClusters = new();
    private const float LibraryLiveHitThreshold = 0.75f;

    private CancellationTokenSource? _loopCts;
    private Task? _loopTask;

    private volatile bool _isConnected;
    private bool _disposed;

    private int _utteranceId;
    private string? _currentSpeakerLabel;

    public SherpaOnnxAsrService(VoiceprintLibraryService? voiceprints = null)
    {
        _voiceprints = voiceprints;
    }

    // Meeting recording (PCM16 WAV) for the post-meeting offline diarization pass.
    private FileStream? _recStream;
    private int _recDataBytes;
    private readonly object _recLock = new();

    public string? LastRecordingPath { get; private set; }
    public DateTime? RecordingStartedAt { get; private set; }

    public event EventHandler<TranscriptEventArgs>? TranscriptReceived;
    public event EventHandler<string>? ErrorReceived;
    public bool IsConnected => _isConnected;

    // ── IAsrService ──────────────────────────────────────────────────────

    private readonly SemaphoreSlim _connectGate = new(1, 1);

    public async Task ConnectAsync(CancellationToken cancellationToken = default)
    {
        await _connectGate.WaitAsync(cancellationToken);
        try
        {
            if (_isConnected)
                return;

            // First run downloads ~150MB of models; load everything off the UI thread.
            await Task.Run(async () =>
            {
                await AsrModelManager.EnsureModelsAsync(cancellationToken: cancellationToken);

                _recognizer ??= CreateRecognizer();
                _extractor  ??= CreateExtractor();
            }, cancellationToken);

            _speakerCluster.Reset();
            _libraryResolvedClusters.Clear();
            _namedLibrary = await LoadNamedLibraryAsync();
            _currentSpeakerLabel = null;
            _utteranceId = 0;

            StartRecording();

            _loopCts = new CancellationTokenSource();
            _loopTask = Task.Run(() => ProcessLoopAsync(_loopCts.Token));
            _isConnected = true;
        }
        finally
        {
            _connectGate.Release();
        }

        AppLog.Info<SherpaOnnxAsrService>("[LocalASR] Started — sherpa-onnx streaming Paraformer + speaker clustering");
    }

    public Task SendAudioAsync(byte[] audioData, CancellationToken cancellationToken = default)
    {
        if (!_isConnected || audioData.Length == 0)
            return Task.CompletedTask;

        if (!_queue.Writer.TryWrite(new WorkItem(audioData, Flush: false, Done: null)))
        {
            if (++_droppedFrames % 200 == 1)
                AppLog.Warn<SherpaOnnxAsrService>(
                    $"[LocalASR] Queue full — dropping audio frame (total dropped: {_droppedFrames})");
        }
        return Task.CompletedTask;
    }

    /// <summary>
    /// Commit whatever is currently in progress as a final sentence, then continue the
    /// session. Unlike the old WebSocket service there is no reconnect — the local
    /// recognizer keeps running continuously.
    /// </summary>
    public Task FinalizeSegmentAsync(CancellationToken cancellationToken = default)
    {
        if (!_isConnected)
            return Task.CompletedTask;

        var tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _queue.Writer.TryWrite(new WorkItem(null, Flush: true, Done: tcs));
        return AwaitFlushAsync(tcs, cancellationToken);
    }

    private static async Task AwaitFlushAsync(TaskCompletionSource tcs, CancellationToken cancellationToken)
    {
        try
        {
            await tcs.Task.WaitAsync(TimeSpan.FromSeconds(10), cancellationToken);
        }
        catch (TimeoutException)
        {
            AppLog.Warn<SherpaOnnxAsrService>("[LocalASR] FinalizeSegmentAsync timed out after 10s");
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            AppLog.Warn<SherpaOnnxAsrService>("[LocalASR] FinalizeSegmentAsync canceled (processing loop ended)");
        }
    }

    public async Task DisconnectAsync(CancellationToken cancellationToken = default)
    {
        if (!_isConnected)
            return;

        // Flush any in-progress utterance so the tail of the speech isn't lost.
        try { await FinalizeSegmentAsync(cancellationToken); }
        catch (Exception ex)
        {
            AppLog.Warn<SherpaOnnxAsrService>($"[LocalASR] Final flush failed: {ex.Message}");
        }

        _isConnected = false;
        _loopCts?.Cancel();

        if (_loopTask is not null)
        {
            try { await Task.WhenAny(_loopTask, Task.Delay(2000, cancellationToken)); }
            catch { }
        }

        _loopCts?.Dispose();
        _loopCts = null;
        _loopTask = null;

        FinishRecording();

        AppLog.Info<SherpaOnnxAsrService>("[LocalASR] Stopped");
    }

    // ── Processing loop ──────────────────────────────────────────────────

    private async Task ProcessLoopAsync(CancellationToken ct)
    {
        var stream = _recognizer!.CreateStream();
        var utteranceSamples = new List<float>(SampleRate * 8);
        var lastPartial = string.Empty;

        try
        {
            while (!ct.IsCancellationRequested)
            {
                WorkItem item;
                try
                {
                    item = await _queue.Reader.ReadAsync(ct);
                }
                catch (OperationCanceledException)
                {
                    break;
                }

                if (item.Flush)
                {
                    FlushUtterance(stream, utteranceSamples);
                    lastPartial = string.Empty;
                    item.Done?.TrySetResult();
                    continue;
                }

                var frame = item.Frame!;
                var n = frame.Length / 2;
                if (n == 0)
                    continue;

                AppendRecording(frame);

                var samples = new float[n];
                for (var i = 0; i < n; i++)
                    samples[i] = BitConverter.ToInt16(frame, i * 2) / 32768f;

                stream.AcceptWaveform(SampleRate, samples);
                utteranceSamples.AddRange(samples);
                if (utteranceSamples.Count > MaxUtteranceBufferSamples)
                    utteranceSamples.RemoveRange(0, utteranceSamples.Count - MaxUtteranceBufferSamples);

                while (_recognizer.IsReady(stream))
                    _recognizer.Decode(stream);

                var text = _recognizer.GetResult(stream).Text?.Trim() ?? string.Empty;

                if (_recognizer.IsEndpoint(stream))
                {
                    CommitUtterance(stream, text, utteranceSamples);
                    utteranceSamples.Clear();
                    lastPartial = string.Empty;
                }
                else if (text.Length > 0 && text != lastPartial)
                {
                    lastPartial = text;
                    TranscriptReceived?.Invoke(this,
                        new TranscriptEventArgs(text, isFinal: false, confidence: 0.9f,
                            utteranceId: _utteranceId, speakerLabel: null));
                }
            }
        }
        catch (Exception ex)
        {
            AppLog.Error<SherpaOnnxAsrService>($"[LocalASR] ProcessLoop crashed: {ex.GetType().Name} {ex.Message}", ex);
            ErrorReceived?.Invoke(this, LocalizationManager.Format("AsrLocalError", ex.Message));
        }
        finally
        {
            stream.Dispose();
            _isConnected = false;
            FailPendingFlushes();
        }
    }

    // Unblock any FinalizeSegmentAsync waiters still queued when the loop exits.
    private void FailPendingFlushes()
    {
        while (_queue.Reader.TryRead(out var item))
            item.Done?.TrySetCanceled();
    }

    private void FlushUtterance(OnlineStream stream, List<float> utteranceSamples)
    {
        var text = _recognizer!.GetResult(stream).Text?.Trim() ?? string.Empty;
        CommitUtterance(stream, text, utteranceSamples);
        utteranceSamples.Clear();
    }

    private void CommitUtterance(OnlineStream stream, string text, List<float> utteranceSamples)
    {
        _recognizer!.Reset(stream);

        if (string.IsNullOrWhiteSpace(text))
            return;

        var label = IdentifySpeaker(utteranceSamples);
        var uid = _utteranceId++;

        AppLog.Info<SherpaOnnxAsrService>($"[LocalASR] final uid={uid} speaker={label} '{text}'");

        TranscriptReceived?.Invoke(this,
            new TranscriptEventArgs(text, isFinal: true, confidence: 0.9f,
                utteranceId: uid, speakerLabel: label));
    }

    // ── Speaker identification ───────────────────────────────────────────

    private string? IdentifySpeaker(List<float> samples)
    {
        if (_extractor is null)
            return _currentSpeakerLabel;

        // Duration gates (aligned with macOS, docs/speaker_diarization_spec.md):
        // <1s skip entirely, 1-2s match-only (no learning), ≥2s learn.
        var durationSec = (double)samples.Count / SampleRate;
        if (SpeakerClusterer.Decide(durationSec) == SpeakerClusterer.IdentifyDecision.Skip)
            return _currentSpeakerLabel;

        try
        {
            var take = Math.Min(samples.Count, MaxEmbeddingSamples);
            var buf = samples.GetRange(0, take).ToArray();

            using var stream = _extractor.CreateStream();
            stream.AcceptWaveform(SampleRate, buf);
            stream.InputFinished();

            var embedding = _extractor.Compute(stream);
            OnlineSpeakerCluster.NormalizeInPlace(embedding);

            var clusterId = _speakerCluster.Process(embedding, durationSec);
            if (clusterId is not int cid)
                return _currentSpeakerLabel;

            // Voiceprint-library live hit: once a cluster is stable, a known
            // voice shows their real name during the meeting.
            if (!_libraryResolvedClusters.Contains(cid) && _speakerCluster.IsLiveLabelable(cid))
            {
                var centroid = _speakerCluster.CentroidOf(cid);
                if (centroid is not null && _namedLibrary.Count > 0)
                {
                    var hitId = SpeakerClusterer.BestLibraryMatch(
                        centroid,
                        _namedLibrary.Select(e => (e.Id, e.Centroid)).ToList(),
                        LibraryLiveHitThreshold);
                    if (hitId is long id)
                    {
                        _libraryResolvedClusters.Add(cid);
                        var name = _namedLibrary.FirstOrDefault(e => e.Id == id).Name;
                        if (!string.IsNullOrEmpty(name))
                        {
                            _currentSpeakerLabel = name;
                            return name;
                        }
                    }
                }
            }

            _currentSpeakerLabel = LocalizationManager.Instance.IsEnglish
                ? $"Speaker {cid}"
                : $"发言人{cid}";
            return _currentSpeakerLabel;
        }
        catch (Exception ex)
        {
            AppLog.Warn<SherpaOnnxAsrService>($"[LocalASR] Speaker embedding failed: {ex.Message}");
            return _currentSpeakerLabel;
        }
    }

    private async Task<List<(long Id, string Name, float[] Centroid)>> LoadNamedLibraryAsync()
    {
        if (_voiceprints is null) return new();
        try
        {
            var named = await _voiceprints.FetchNamedCentroidsAsync();
            var all = await _voiceprints.FetchAllAsync();
            return named.Select(t => (t.Id, all.First(s => s.Id == t.Id).Name, t.Centroid)).ToList();
        }
        catch (Exception ex)
        {
            AppLog.Warn<SherpaOnnxAsrService>($"[Voiceprint] Library load failed: {ex.Message}");
            return new();
        }
    }

    /// <summary>Stable clusters (≥2 learnable samples) for end-of-meeting persistence.</summary>
    public IReadOnlyList<(int ClusterId, float[] Centroid, int LearnCount, DateTime LastHeardAt)> GetStableClusters() =>
        _speakerCluster.StableClusters
            .Select(c => (c.Id, c.Centroid.ToArray(), c.LearnCount, c.LastHeardAt))
            .ToList();

    IReadOnlyList<StableVoiceprintCluster> ISpeakerRefinement.GetStableVoiceprintClusters() =>
        _speakerCluster.StableClusters
            .Select(c => new StableVoiceprintCluster(c.Id, c.Centroid.ToArray(), c.LearnCount, c.LastHeardAt))
            .ToList();

    public async Task PersistVoiceprintsAsync(Func<int, string?> nameResolver, CancellationToken cancellationToken = default)
    {
        if (_voiceprints is null) return;
        foreach (var c in _speakerCluster.StableClusters)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                await _voiceprints.PersistClusterAsync(
                    c.Centroid.ToArray(), c.LearnCount, c.LastHeardAt, nameResolver(c.Id));
            }
            catch (Exception ex)
            {
                AppLog.Warn<SherpaOnnxAsrService>($"[Voiceprint] Persist cluster {c.Id} failed: {ex.Message}");
            }
        }
    }

    // ── Meeting recording (for offline diarization) ──────────────────────

    private void StartRecording()
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "MeetingQ", "recordings");
            Directory.CreateDirectory(dir);

            var path = Path.Combine(dir, $"meeting-{DateTime.Now:yyyyMMdd-HHmmss}.wav");
            var stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
            WriteWavHeader(stream, dataBytes: 0); // placeholder, patched in FinishRecording

            lock (_recLock)
            {
                _recStream = stream;
                _recDataBytes = 0;
            }
            LastRecordingPath = path;
            RecordingStartedAt = null; // set on first audio frame
        }
        catch (Exception ex)
        {
            AppLog.Warn<SherpaOnnxAsrService>($"[LocalASR] Recording disabled: {ex.Message}");
        }
    }

    private void AppendRecording(byte[] pcmFrame)
    {
        lock (_recLock)
        {
            if (_recStream is null) return;
            try
            {
                if (_recDataBytes == 0)
                    RecordingStartedAt = DateTime.Now;
                _recStream.Write(pcmFrame, 0, pcmFrame.Length);
                _recDataBytes += pcmFrame.Length;
            }
            catch (Exception ex)
            {
                AppLog.Warn<SherpaOnnxAsrService>($"[LocalASR] Recording write failed: {ex.Message}");
            }
        }
    }

    private void FinishRecording()
    {
        lock (_recLock)
        {
            if (_recStream is null) return;
            try
            {
                _recStream.Seek(0, SeekOrigin.Begin);
                WriteWavHeader(_recStream, _recDataBytes);
            }
            catch (Exception ex)
            {
                AppLog.Warn<SherpaOnnxAsrService>($"[LocalASR] Recording header patch failed: {ex.Message}");
            }
            _recStream.Dispose();
            _recStream = null;
            AppLog.Info<SherpaOnnxAsrService>(
                $"[LocalASR] Recording saved: {LastRecordingPath} ({_recDataBytes / 32000.0:F1}s)");
        }
    }

    private static void WriteWavHeader(Stream s, int dataBytes)
    {
        using var w = new BinaryWriter(s, System.Text.Encoding.ASCII, leaveOpen: true);
        w.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));
        w.Write(36 + dataBytes);
        w.Write(System.Text.Encoding.ASCII.GetBytes("WAVE"));
        w.Write(System.Text.Encoding.ASCII.GetBytes("fmt "));
        w.Write(16);                       // PCM chunk size
        w.Write((short)1);                 // PCM format
        w.Write((short)1);                 // mono
        w.Write(SampleRate);
        w.Write(SampleRate * 2);           // byte rate
        w.Write((short)2);                 // block align
        w.Write((short)16);                // bits per sample
        w.Write(System.Text.Encoding.ASCII.GetBytes("data"));
        w.Write(dataBytes);
    }

    // ── Offline speaker diarization (post-meeting refinement) ────────────

    public Task<List<DiarizedSegment>> DiarizeLastRecordingAsync(
        int? numClustersHint = null, CancellationToken cancellationToken = default)
    {
        lock (_recLock)
        {
            if (_recStream is not null)
            {
                AppLog.Warn<SherpaOnnxAsrService>(
                    "[LocalASR] DiarizeLastRecordingAsync refused — meeting recording still in progress");
                return Task.FromResult(new List<DiarizedSegment>());
            }
        }

        var path = LastRecordingPath;
        if (path is null || !File.Exists(path))
            return Task.FromResult(new List<DiarizedSegment>());

        return Task.Run(async () =>
        {
            // Ensure the segmentation model is available (bundled; downloads only if missing)
            await AsrModelManager.EnsureModelsAsync(cancellationToken: cancellationToken);

            var samples = ReadWavSamples(path);
            if (samples.Length < SampleRate * 5)
            {
                AppLog.Info<SherpaOnnxAsrService>("[LocalASR] Recording too short for diarization — skipped");
                return new List<DiarizedSegment>();
            }

            var config = new OfflineSpeakerDiarizationConfig();
            config.Segmentation.Pyannote.Model = AsrModelManager.SegmentationModelPath;
            config.Segmentation.NumThreads = 2;
            config.Segmentation.Provider = "cpu";
            config.Segmentation.Debug = 0;
            config.Embedding.Model = AsrModelManager.SpeakerModelPath;
            config.Embedding.NumThreads = 1;
            config.Embedding.Provider = "cpu";
            config.Embedding.Debug = 0;
            config.Clustering.NumClusters = numClustersHint ?? -1;   // -1 = unknown → threshold
            config.Clustering.Threshold = 0.5f;
            config.MinDurationOn = 0.3f;
            config.MinDurationOff = 0.5f;

            AppLog.Info<SherpaOnnxAsrService>(
                $"[LocalASR] Offline diarization started ({samples.Length / (float)SampleRate:F0}s audio)");
            var sw = System.Diagnostics.Stopwatch.StartNew();

            using var diarizer = new OfflineSpeakerDiarization(config);
            var segments = diarizer.Process(samples);

            sw.Stop();
            AppLog.Info<SherpaOnnxAsrService>(
                $"[LocalASR] Offline diarization done: {segments.Length} segments, " +
                $"{segments.Select(s => s.Speaker).Distinct().Count()} speakers, took {sw.Elapsed.TotalSeconds:F1}s");

            // Audio is not kept on disk after a successful pass.
            try
            {
                File.Delete(path);
                LastRecordingPath = null;
            }
            catch (Exception ex)
            {
                AppLog.Warn<SherpaOnnxAsrService>($"[LocalASR] Failed to delete recording: {ex.Message}");
            }

            return segments
                .Select(s => new DiarizedSegment(s.Start, s.End, s.Speaker))
                .ToList();
        }, cancellationToken);
    }

    private static float[] ReadWavSamples(string path)
    {
        var bytes = File.ReadAllBytes(path);
        // Files we write ourselves always have a canonical 44-byte PCM16 header.
        const int headerBytes = 44;
        var n = (bytes.Length - headerBytes) / 2;
        if (n <= 0) return [];
        var samples = new float[n];
        for (var i = 0; i < n; i++)
            samples[i] = BitConverter.ToInt16(bytes, headerBytes + i * 2) / 32768f;
        return samples;
    }

    // ── Model construction ───────────────────────────────────────────────

    private static OnlineRecognizer CreateRecognizer()
    {
        var config = new OnlineRecognizerConfig();
        config.FeatConfig.SampleRate = SampleRate;
        config.FeatConfig.FeatureDim = 80;
        config.ModelConfig.Paraformer.Encoder = AsrModelManager.EncoderPath;
        config.ModelConfig.Paraformer.Decoder = AsrModelManager.DecoderPath;
        config.ModelConfig.Tokens = AsrModelManager.TokensPath;
        config.ModelConfig.NumThreads = 2;
        config.ModelConfig.Provider = "cpu";
        config.ModelConfig.Debug = 0;
        config.EnableEndpoint = 1;
        config.Rule1MinTrailingSilence = 2.4f;
        config.Rule2MinTrailingSilence = 1.2f;   // sentence commit after ~1.2s pause
        config.Rule3MinUtteranceLength = 20f;    // force-commit long monologues
        return new OnlineRecognizer(config);
    }

    private static SpeakerEmbeddingExtractor CreateExtractor()
    {
        var config = new SpeakerEmbeddingExtractorConfig();
        config.Model = AsrModelManager.SpeakerModelPath;
        config.NumThreads = 1;
        config.Provider = "cpu";
        config.Debug = 0;
        return new SpeakerEmbeddingExtractor(config);
    }

    // ── IDisposable ──────────────────────────────────────────────────────

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        _isConnected = false;
        _loopCts?.Cancel();
        try { _loopTask?.Wait(1000); } catch { }
        _loopCts?.Dispose();

        FinishRecording();

        _recognizer?.Dispose();
        _recognizer = null;
        _extractor?.Dispose();
        _extractor = null;
        _connectGate.Dispose();
    }
}
