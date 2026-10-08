using Microsoft.Extensions.Logging;

namespace MeetingQ.Services;

/// <summary>
/// Energy-based Voice Activity Detector.
/// Input: 20ms PCM16 frames (640 bytes at 16kHz mono).
/// Output: <see cref="SpeechSegmentReady"/> event with concatenated PCM16 bytes.
/// </summary>
internal sealed class VadProcessor
{
    private const float SpeechThreshold  = 0.005f;  // RMS to start speech
    private const float SilenceThreshold = 0.003f;  // RMS to end speech
    private const int MaxSegmentFrames = 3000;      // 60s at 20ms/frame — force-emit beyond this

    private readonly int _preRollFrames;
    private readonly int _postRollFrames;
    private readonly int _minSpeechFrames;
    private readonly ILogger _logger;

    private enum State { Silence, Speech, Trailing }

    private State _state = State.Silence;
    private int _trailingCount;
    private int _speechFrameCount;

    private readonly Queue<byte[]> _preRoll = new();
    private readonly List<byte[]>  _accumulated = new();

    // Diagnostics: log peak RMS once per second (every 50 frames × 20ms)
    private int   _diagFrameCount;
    private float _diagPeakRms;

    /// <summary>True while in Speech or Trailing state — i.e., audio should be streamed to ASR.</summary>
    public bool IsSpeechActive => _state == State.Speech || _state == State.Trailing;

    public event EventHandler<byte[]>? SpeechSegmentReady;

    /// <summary>Fires once per second with the peak RMS of the last second of audio (0–1 scale).</summary>
    public event EventHandler<float>? RmsUpdated;

    public VadProcessor(ILogger logger, int preRollMs = 200, int postRollMs = 300, int minSpeechMs = 150)
    {
        _logger          = logger;
        _preRollFrames   = preRollMs  / 20;
        _postRollFrames  = postRollMs / 20;
        _minSpeechFrames = minSpeechMs / 20;
    }

    public void ProcessFrame(byte[] frame, int validBytes)
    {
        var data = validBytes == frame.Length ? frame : frame[..validBytes];
        float rms = CalculateRms(data);

        // Diagnostics: log peak RMS every second (debug only)
        _diagPeakRms = MathF.Max(_diagPeakRms, rms);
        if (++_diagFrameCount >= 50)
        {
            _logger.LogDebug("[VAD] peak RMS last 1s = {Rms:F4}  state={State}  threshold={Thr:F4}",
                _diagPeakRms, _state, SpeechThreshold);
            RmsUpdated?.Invoke(this, _diagPeakRms);
            _diagFrameCount = 0;
            _diagPeakRms    = 0f;
        }

        switch (_state)
        {
            case State.Silence:
                _preRoll.Enqueue((byte[])data.Clone());
                if (_preRoll.Count > _preRollFrames)
                    _preRoll.Dequeue();

                if (rms >= SpeechThreshold)
                {
                    _logger.LogInformation("[VAD] Speech START (rms={Rms:F4})", rms);
                    _state = State.Speech;
                    _speechFrameCount = 0;
                    foreach (var f in _preRoll) _accumulated.Add(f);
                    _preRoll.Clear();
                    _accumulated.Add((byte[])data.Clone());
                    _speechFrameCount++;
                }
                break;

            case State.Speech:
                _accumulated.Add((byte[])data.Clone());
                _speechFrameCount++;
                if (_speechFrameCount >= MaxSegmentFrames)
                {
                    _logger.LogInformation("[VAD] Max segment length reached ({Frames} frames) — force emit",
                        _speechFrameCount);
                    _state = State.Silence;
                    Emit();
                    _preRoll.Clear();
                }
                else if (rms < SilenceThreshold)
                {
                    _state = State.Trailing;
                    _trailingCount = 0;
                }
                break;

            case State.Trailing:
                _accumulated.Add((byte[])data.Clone());
                _trailingCount++;

                if (rms >= SpeechThreshold)
                {
                    _state = State.Speech;
                    _speechFrameCount += _trailingCount;
                    _trailingCount = 0;
                }
                else if (_trailingCount >= _postRollFrames)
                {
                    _state = State.Silence;
                    if (_speechFrameCount >= _minSpeechFrames)
                        Emit();
                    else
                        _accumulated.Clear();
                    _preRoll.Clear();
                }
                break;
        }
    }

    public void Flush()
    {
        if (_state != State.Silence && _speechFrameCount >= _minSpeechFrames)
            Emit();
        _accumulated.Clear();
        _preRoll.Clear();
        _state = State.Silence;
    }

    private void Emit()
    {
        int totalBytes = _accumulated.Sum(b => b.Length);
        var output = new byte[totalBytes];
        int offset = 0;
        foreach (var chunk in _accumulated)
        {
            chunk.CopyTo(output, offset);
            offset += chunk.Length;
        }
        _accumulated.Clear();
        _logger.LogInformation("[VAD] Speech segment emitted: {Bytes} bytes ({Ms}ms)",
            totalBytes, totalBytes / 32);  // 32 bytes/ms at 16kHz PCM16 mono
        SpeechSegmentReady?.Invoke(this, output);
    }

    private static float CalculateRms(byte[] pcm16)
    {
        if (pcm16.Length < 2) return 0f;
        float sum = 0f;
        int sampleCount = pcm16.Length / 2;
        for (int i = 0; i < pcm16.Length - 1; i += 2)
        {
            short s = (short)(pcm16[i] | (pcm16[i + 1] << 8));
            float f = s / 32768f;
            sum += f * f;
        }
        return MathF.Sqrt(sum / sampleCount);
    }
}
