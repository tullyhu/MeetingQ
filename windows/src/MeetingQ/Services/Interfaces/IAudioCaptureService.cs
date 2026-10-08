namespace MeetingQ.Services.Interfaces;

public class AudioDataEventArgs : EventArgs
{
    public byte[] Data { get; }
    public AudioDataEventArgs(byte[] data) => Data = data;
}

public interface IAudioCaptureService : IDisposable
{
    event EventHandler<AudioDataEventArgs>? AudioDataAvailable;
    /// <summary>Fired once per second with the peak RMS of the last second (0–1 scale).
    /// Used by the diagnostics panel to show whether audio is being captured.</summary>
    event EventHandler<float>? AudioLevelUpdated;

    Task StartAsync(CancellationToken cancellationToken = default);
    Task StopAsync(CancellationToken cancellationToken = default);
    bool IsCapturing { get; }

    /// <summary>Friendly name of the audio endpoint being captured (set after StartAsync).</summary>
    string? CurrentDeviceName { get; }

    /// <summary>Set the ASR service to receive audio directly. Disables event-based forwarding.</summary>
    void SetAsr(IAsrService? asr);

    // ── Debug ASR dump ────────────────────────────────────────────────────
    void StartAsrDump();
    string? StopAsrDump();
    bool IsDumping { get; }
}
