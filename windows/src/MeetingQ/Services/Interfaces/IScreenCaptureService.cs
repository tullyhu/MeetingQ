namespace MeetingQ.Services.Interfaces;

public class ScreenshotCapturedEventArgs : EventArgs
{
    public string FilePath  { get; }
    public DateTime Timestamp { get; }
    /// <summary>MD5 hex of downsampled pixel data; used for deduplication and DB storage.</summary>
    public string ImageHash { get; }

    public ScreenshotCapturedEventArgs(string filePath, DateTime timestamp, string imageHash)
    {
        FilePath  = filePath;
        Timestamp = timestamp;
        ImageHash = imageHash;
    }
}

public interface IScreenCaptureService : IDisposable
{
    event EventHandler<ScreenshotCapturedEventArgs>? ScreenshotCaptured;

    /// <summary>
    /// Optional gate evaluated before each periodic capture (e.g. skip while the meeting
    /// has been silent for a while — nobody is likely sharing content). Does not affect
    /// on-demand <see cref="TakeScreenshotAsync"/>.
    /// </summary>
    Func<bool>? ShouldSkipPeriodicCapture { get; set; }

    Task StartAsync(IntPtr windowHandle, CancellationToken cancellationToken = default);
    Task StopAsync(CancellationToken cancellationToken = default);
    bool IsCapturing { get; }

    /// <summary>Resets the deduplication state so the next capture is always saved.</summary>
    void ResetDuplicateState();

    /// <summary>Takes one screenshot immediately and returns the saved file path.</summary>
    Task<string> TakeScreenshotAsync();
}

