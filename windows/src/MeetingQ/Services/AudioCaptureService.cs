using MeetingQ.Infrastructure;
using MeetingQ.Services.Interfaces;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace MeetingQ.Services;

/// <summary>
/// Captures system speaker audio via WASAPI loopback and applies energy-based VAD.
/// Only emits <see cref="AudioDataAvailable"/> when speech is detected (PCM16, 16kHz, mono).
/// Conversion chain is built entirely on the background AudioVAD thread to avoid
/// MediaFoundationResampler COM STA/MTA threading issues.
/// </summary>
public class AudioCaptureService : IAudioCaptureService
{
    private WasapiLoopbackCapture?  _capture;
    private BufferedWaveProvider?   _buffer;
    private Thread?                 _processingThread;
    private CancellationTokenSource? _cts;

    // Microphone capture (optional)
    private WasapiCapture?        _micCapture;
    private BufferedWaveProvider? _micBuffer;
    private bool                  _micEnabled;

    private bool _isCapturing;
    private bool _disposed;
    private IAsrService? _asr;
    private int _sendCount;

    // Target format expected by ASR (16kHz, 16-bit, mono PCM)
    private static readonly WaveFormat TargetFormat = new WaveFormat(16000, 16, 1);

    // 100ms frame at 16kHz, 16-bit, mono = 1600 samples × 2 bytes
    private const int FrameSizeBytes = 3200;

    public event EventHandler<AudioDataEventArgs>? AudioDataAvailable;
    public event EventHandler<float>? AudioLevelUpdated;
    public bool IsCapturing => _isCapturing;
    public string? CurrentDeviceName { get; private set; }

    // ── ASR dump ──────────────────────────────────────────────────────────
    private WaveFileWriter? _dumpWriter;
    private string?         _dumpPath;
    private readonly object _dumpLock = new();
    private volatile bool   _isDumping;
    public bool IsDumping => _isDumping;

    // Raw WASAPI callback stats
    private int  _rawCallbackCount;
    private long _rawBytesTotal;

    public void SetAsr(IAsrService? asr)
    {
        _asr = asr;
        AppLog.Info<AudioCaptureService>(
            $"[Capture] SetAsr: asr={(_asr != null)} connected={_asr?.IsConnected}");
    }

    public void StartAsrDump()
    {
        lock (_dumpLock)
        {
            if (_isDumping) return;
            var desktop = Environment.GetFolderPath(Environment.SpecialFolder.Desktop);
            _dumpPath   = System.IO.Path.Combine(desktop,
                $"meetingq_asr_{DateTime.Now:yyyyMMdd_HHmmss}.wav");
            _dumpWriter = new WaveFileWriter(_dumpPath, TargetFormat);
            _isDumping  = true;
        }
        AppLog.Info<AudioCaptureService>($"[AsrDump] Recording to {_dumpPath}");
    }

    public string? StopAsrDump()
    {
        lock (_dumpLock)
        {
            if (!_isDumping) return null;
            _isDumping = false;
            _dumpWriter?.Flush();
            _dumpWriter?.Dispose();
            _dumpWriter = null;
        }
        AppLog.Info<AudioCaptureService>($"[AsrDump] Saved to {_dumpPath}");
        return _dumpPath;
    }

    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (_isCapturing)
        {
            AppLog.Warn<AudioCaptureService>("StartAsync called while already capturing");
            return Task.CompletedTask;
        }

        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            CurrentDeviceName = device.FriendlyName;
        }
        catch { CurrentDeviceName = "默认播放设备"; }

        _capture = new WasapiLoopbackCapture();
        AppLog.Info<AudioCaptureService>($"WASAPI loopback format={_capture.WaveFormat}  device={CurrentDeviceName}");

        _buffer = new BufferedWaveProvider(_capture.WaveFormat)
        {
            BufferDuration          = TimeSpan.FromSeconds(10),
            DiscardOnBufferOverflow = true,
            ReadFully               = false
        };

        _capture.DataAvailable    += OnDataAvailable;
        _capture.RecordingStopped += OnRecordingStopped;

        _cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _capture.StartRecording();

        _micEnabled = SecureStorage.Load(SecureStorageKeys.MicEnabled) == "true";
        if (_micEnabled)
        {
            try
            {
                var preferredName = SecureStorage.Load(SecureStorageKeys.MicDeviceName);
                StartMicCapture(preferredName);
                AppLog.Info<AudioCaptureService>("[MicCapture] Microphone capture enabled");
            }
            catch (Exception ex)
            {
                AppLog.Warn<AudioCaptureService>($"[MicCapture] Failed to start mic — {ex.Message}. Mic capture disabled.");
                _micEnabled = false;
            }
        }

        _processingThread = new Thread(() => ProcessingLoop(_cts.Token))
        {
            IsBackground = true,
            Name = "AudioVAD"
        };
        _processingThread.Start();

        _isCapturing = true;
        AppLog.Info<AudioCaptureService>("Audio capture started");
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken = default)
    {
        if (!_isCapturing) return Task.CompletedTask;

        AppLog.Info<AudioCaptureService>("Stopping audio capture");
        StopAsrDump();
        _capture?.StopRecording();
        _micCapture?.StopRecording();
        _cts?.Cancel();
        _processingThread?.Join(TimeSpan.FromSeconds(3));
        _processingThread = null;

        _micCapture?.Dispose();
        _micCapture = null;
        _micBuffer  = null;

        _capture?.Dispose();
        _capture = null;
        _buffer  = null;

        _cts?.Dispose();
        _cts = null;

        _isCapturing = false;
        AppLog.Info<AudioCaptureService>("Audio capture stopped");
        return Task.CompletedTask;
    }

    private void ProcessingLoop(CancellationToken ct)
    {
        try
        {
            ProcessingLoopCore(ct);
        }
        catch (Exception ex)
        {
            AppLog.Error<AudioCaptureService>($"[Capture] ProcessingLoop crashed: {ex.GetType().Name} {ex.Message}", ex);
            _isCapturing = false;
        }
    }

    private void ProcessingLoopCore(CancellationToken ct)
    {
        var captureFormat = _buffer!.WaveFormat;

        IWaveProvider floatProvider =
            captureFormat.Encoding == WaveFormatEncoding.IeeeFloat
                ? (IWaveProvider)_buffer
                : new WaveProviderFormatOverride(_buffer,
                    WaveFormat.CreateIeeeFloatWaveFormat(
                        captureFormat.SampleRate, captureFormat.Channels));

        ISampleProvider chain = new WaveToSampleProvider(floatProvider);

        if (captureFormat.Channels == 2)
            chain = new StereoToMonoSampleProvider(chain);
        else if (captureFormat.Channels != 1)
            AppLog.Warn<AudioCaptureService>($"Unexpected channel count {captureFormat.Channels}");

        chain = new WdlResamplingSampleProvider(chain, 16000);

        if (_micEnabled && _micBuffer is not null)
        {
            try
            {
                var micChain = BuildMicChain(_micBuffer);
                chain = new TwoChannelMixer(chain, micChain);
                AppLog.Info<AudioCaptureService>("Microphone mixed in");
            }
            catch (Exception ex)
            {
                AppLog.Warn<AudioCaptureService>($"Failed to build mic chain — {ex.Message}");
            }
        }

        IWaveProvider waveProvider16 = new SampleToWaveProvider16(chain);
        var frameBuffer = new byte[FrameSizeBytes];

        // Per-second RMS for diagnostic panel
        float rmsAccum  = 0f;
        int   rmsFrameN = 0;
        const int RmsReportEvery = 50; // 50 × 20ms = 1s (based on real frames only)

        // 30-second pipeline stats
        int   statFrames        = 0;
        int   statSilenceFrames = 0;
        long  statBytes         = 0;
        float statRmsSum        = 0f;
        var   statWindowStart   = DateTime.UtcNow;
        const double StatWindowSec = 30.0;

        // Keepalive: only inject silence after truly silent for >2s (avoid stream speedup)
        var lastRealAudioAt = DateTime.UtcNow;
        var lastKeepaliveAt = DateTime.MinValue;

        AppLog.Info<AudioCaptureService>(
            $"Pipeline ready — format={captureFormat} → 16kHz/16bit/mono frameSize={FrameSizeBytes}B");

        while (!ct.IsCancellationRequested)
        {
            int read = waveProvider16.Read(frameBuffer, 0, FrameSizeBytes);

            if (read <= 0)
            {
                // Buffer briefly empty between WASAPI callbacks.
                // Do NOT inject silence frames here — that would make the ASR stream
                // run faster than real-time, fragmenting speech and dropping sentences.
                Thread.Sleep(5);

                // Keepalive: send a 20ms silence only when truly silent for >2s,
                // to prevent ASR server idle-timeout.
                var now = DateTime.UtcNow;
                if ((now - lastRealAudioAt).TotalSeconds > 2.0 &&
                    (now - lastKeepaliveAt).TotalMilliseconds >= 500)
                {
                    var keepalive = new byte[640]; // 20ms at 16kHz 16-bit mono
                    AudioDataAvailable?.Invoke(this, new AudioDataEventArgs(keepalive));
                    lastKeepaliveAt = now;
                }
                continue; // Don't count empty reads in stats or RMS
            }

            lastRealAudioAt = DateTime.UtcNow;
            float frameRms  = CalculateRms(frameBuffer, read);
            bool  isSilence = frameRms < 0.01f; // energy-based (for stats only)

            // Per-second RMS
            rmsAccum += frameRms;
            if (++rmsFrameN >= RmsReportEvery)
            {
                float avgRms = rmsAccum / RmsReportEvery;
                AudioLevelUpdated?.Invoke(this, avgRms);
                AppLog.Debug<AudioCaptureService>(
                    $"1s RMS={avgRms:F4}  bufferMs={_buffer!.BufferedDuration.TotalMilliseconds:F0}  silence={isSilence}");
                rmsAccum  = 0f;
                rmsFrameN = 0;
            }

            // 30-second pipeline stats
            statFrames++;
            statBytes  += read;
            statRmsSum += frameRms;
            if (isSilence) statSilenceFrames++;

            double elapsed = (DateTime.UtcNow - statWindowStart).TotalSeconds;
            if (elapsed >= StatWindowSec)
            {
                double fps        = statFrames / elapsed;
                double silencePct = statFrames > 0 ? statSilenceFrames * 100.0 / statFrames : 0;
                float  avgRms     = statFrames > 0 ? statRmsSum / statFrames : 0f;
                AppLog.Info<AudioCaptureService>(
                    $"30s stats | frames={statFrames} fps={fps:F1} bytes={statBytes} " +
                    $"silence={silencePct:F0}% avgRMS={avgRms:F4} bufferMs={_buffer!.BufferedDuration.TotalMilliseconds:F0}");
                statFrames = statSilenceFrames = 0;
                statBytes  = 0;
                statRmsSum = 0f;
                statWindowStart = DateTime.UtcNow;
            }

            var frame = new byte[read];
            Array.Copy(frameBuffer, frame, read);

            if (_isDumping)
            {
                lock (_dumpLock)
                {
                    if (_isDumping)
                        _dumpWriter?.Write(frame, 0, frame.Length);
                }
            }

            // Send directly to ASR — more reliable than event round-trip
            if (_asr != null)
            {
                _ = _asr.SendAudioAsync(frame, CancellationToken.None);
                if (_sendCount++ == 0)
                    AppLog.Info<AudioCaptureService>(
                        $"[Capture] First frame sent to ASR: {frame.Length}B");
            }

            AudioDataAvailable?.Invoke(this, new AudioDataEventArgs(frame));
        }

        AppLog.Info<AudioCaptureService>("Processing loop exited");
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        _buffer?.AddSamples(e.Buffer, 0, e.BytesRecorded);
        _rawBytesTotal += e.BytesRecorded;

        // Log every 100th callback (~1s at typical WASAPI periods)
        if (++_rawCallbackCount % 100 == 1)
        {
            bool allZero = true;
            int check = Math.Min(e.BytesRecorded, 256);
            for (int i = 0; i < check; i++)
                if (e.Buffer[i] != 0) { allZero = false; break; }
            AppLog.Debug<AudioCaptureService>(
                $"WASAPI callback #{_rawCallbackCount}: {e.BytesRecorded}B  allZero={allZero}  totalMB={_rawBytesTotal / 1_048_576.0:F1}");
        }
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        if (e.Exception is not null)
            AppLog.Error<AudioCaptureService>("WASAPI recording stopped unexpectedly", e.Exception);
        else
            AppLog.Debug<AudioCaptureService>("WASAPI recording stopped");
    }

    // ── Mic helpers ───────────────────────────────────────────────────────────

    private void StartMicCapture(string? preferredDeviceName)
    {
        MMDevice? mic = null;
        using var enumerator = new MMDeviceEnumerator();
        if (!string.IsNullOrWhiteSpace(preferredDeviceName))
        {
            foreach (var dev in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
            {
                if (dev.FriendlyName.Contains(preferredDeviceName, StringComparison.OrdinalIgnoreCase))
                {
                    mic = dev;
                    break;
                }
                dev.Dispose();
            }
        }

        _micCapture = mic is not null ? new WasapiCapture(mic) : new WasapiCapture();
        _micBuffer = new BufferedWaveProvider(_micCapture.WaveFormat)
        {
            BufferDuration          = TimeSpan.FromSeconds(10),
            DiscardOnBufferOverflow = true,
            ReadFully               = false
        };

        _micCapture.DataAvailable += (_, e) => _micBuffer.AddSamples(e.Buffer, 0, e.BytesRecorded);
        _micCapture.StartRecording();
        AppLog.Info<AudioCaptureService>($"[MicCapture] Started, format={_micCapture.WaveFormat}");
    }

    // IEEE float sub-format GUID used inside WaveFormatExtensible
    private static readonly Guid s_ieeeFloatSubFormat =
        new("00000003-0000-0010-8000-00aa00389b71");

    private static ISampleProvider BuildMicChain(BufferedWaveProvider micBuffer)
    {
        var fmt = micBuffer.WaveFormat;

        // WaveFormatExtensible wraps either PCM or IeeeFloat — must inspect SubFormat GUID.
        // Treating all Extensible as float (previous approach) causes silence when the mic
        // actually returns Extensible+PCM16 (the most common WASAPI capture format).
        bool isFloat = fmt.Encoding == WaveFormatEncoding.IeeeFloat ||
                       (fmt.Encoding == WaveFormatEncoding.Extensible &&
                        fmt is WaveFormatExtensible ext &&
                        ext.SubFormat == s_ieeeFloatSubFormat);

        AppLog.Info<AudioCaptureService>(
            $"[MicChain] encoding={fmt.Encoding} bits={fmt.BitsPerSample} " +
            $"sr={fmt.SampleRate} ch={fmt.Channels} isFloat={isFloat}");

        ISampleProvider chain;
        if (isFloat)
        {
            // Normalize to plain IeeeFloat so WaveToSampleProvider can read it
            chain = new WaveToSampleProvider(
                fmt.Encoding == WaveFormatEncoding.Extensible
                    ? new WaveProviderFormatOverride(micBuffer,
                        WaveFormat.CreateIeeeFloatWaveFormat(fmt.SampleRate, fmt.Channels))
                    : micBuffer);
        }
        else
        {
            // PCM — select converter by bit depth
            chain = fmt.BitsPerSample switch
            {
                16 => new Pcm16BitToSampleProvider(micBuffer),
                24 => new Pcm24BitToSampleProvider(micBuffer),
                32 => new Pcm32BitToSampleProvider(micBuffer),
                _  => throw new NotSupportedException(
                          $"Unsupported mic PCM bit depth: {fmt.BitsPerSample}")
            };
        }

        if (fmt.Channels >= 2)
            chain = new StereoToMonoSampleProvider(chain);
        chain = new WdlResamplingSampleProvider(chain, 16000);
        return chain;
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static float CalculateRms(byte[] pcm16, int validBytes)
    {
        if (validBytes < 2) return 0f;
        float sum = 0f;
        int sampleCount = validBytes / 2;
        for (int i = 0; i < validBytes - 1; i += 2)
        {
            short s = (short)(pcm16[i] | (pcm16[i + 1] << 8));
            float f = s / 32768f;
            sum += f * f;
        }
        return MathF.Sqrt(sum / sampleCount);
    }

    private sealed class WaveProviderFormatOverride : IWaveProvider
    {
        private readonly IWaveProvider _inner;
        public WaveFormat WaveFormat { get; }
        public WaveProviderFormatOverride(IWaveProvider inner, WaveFormat format)
        { _inner = inner; WaveFormat = format; }
        public int Read(byte[] buffer, int offset, int count) => _inner.Read(buffer, offset, count);
    }

    private sealed class TwoChannelMixer : ISampleProvider
    {
        private readonly ISampleProvider _a;
        private readonly ISampleProvider _b;
        private float[] _bufB = Array.Empty<float>();
        public WaveFormat WaveFormat => _a.WaveFormat;
        public TwoChannelMixer(ISampleProvider a, ISampleProvider b) { _a = a; _b = b; }
        public int Read(float[] buffer, int offset, int count)
        {
            int read = _a.Read(buffer, offset, count);
            if (read == 0) return 0;
            if (_bufB.Length < read) _bufB = new float[read];
            int readB = _b.Read(_bufB, 0, read);
            for (int i = 0; i < read; i++)
                buffer[offset + i] = (buffer[offset + i] + (i < readB ? _bufB[i] : 0f)) * 0.5f;
            return read;
        }
    }

    // ── Dispose ───────────────────────────────────────────────────────────────

    protected virtual void Dispose(bool disposing)
    {
        if (!_disposed)
        {
            if (disposing)
            {
                _cts?.Cancel();
                _processingThread?.Join(TimeSpan.FromSeconds(3));
                _cts?.Dispose();
                _capture?.Dispose();
                _micCapture?.Dispose();
                _dumpWriter?.Dispose();
            }
            _disposed = true;
        }
    }

    public void Dispose()
    {
        Dispose(disposing: true);
        GC.SuppressFinalize(this);
    }
}
