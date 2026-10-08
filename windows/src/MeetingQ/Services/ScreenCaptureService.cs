using MeetingQ.Services.Interfaces;
using Microsoft.Extensions.Logging;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace MeetingQ.Services;

/// <summary>
/// Periodic screenshot capture.
/// • IntPtr.Zero  → full primary screen via Graphics.CopyFromScreen
/// • non-zero     → specific window via PrintWindow (supports background / HW-accelerated windows)
/// Screenshots saved as JPEG at 85% quality under %LOCALAPPDATA%\MeetingQ\Screenshots\.
/// </summary>
public class ScreenCaptureService : IScreenCaptureService
{
    private const int CaptureIntervalMs  =  8_000;    // check every 8 s for changes
    private const int MinSaveIntervalMs  =  5_000;    // minimum cooldown between saves
    private const int JpegQuality        = 85;
    private const int MaxScreenshotCount = 2_000;
    private static readonly TimeSpan MaxScreenshotAge = TimeSpan.FromDays(7);

    private readonly ILogger<ScreenCaptureService> _logger;
    private readonly string _screenshotDir;

    private CancellationTokenSource? _loopCts;
    private Task? _loopTask;
    private readonly SemaphoreSlim _captureGate = new(1, 1);
    private IntPtr _targetWindow;
    private bool _isCapturing;
    private bool _disposed;

    // ── Deduplication ─────────────────────────────────────────────────────
    // Thumbnail size used for hashing (16:9, small enough to be fast)
    private const int ThumbW = 64;
    private const int ThumbH = 36;
    private readonly object _dedupeLock = new();
    private string? _lastCaptureHash;
    private DateTime _lastSaveTime = DateTime.MinValue;

    // ── P/Invoke ──────────────────────────────────────────────────────────

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    private static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDesktopWindow();

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindowDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    private static extern bool BitBlt(IntPtr hdcDest, int xDest, int yDest, int w, int h,
                                      IntPtr hdcSrc, int xSrc, int ySrc, uint rop);

    private const uint SRCCOPY = 0x00CC0020u;

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    private const uint PW_RENDERFULLCONTENT = 2u; // captures DWM / hardware-accelerated content

    // ── IScreenCaptureService ─────────────────────────────────────────────

    public event EventHandler<ScreenshotCapturedEventArgs>? ScreenshotCaptured;
    public bool IsCapturing => _isCapturing;
    public Func<bool>? ShouldSkipPeriodicCapture { get; set; }

    public ScreenCaptureService(ILogger<ScreenCaptureService> logger)
    {
        _logger = logger;
        _screenshotDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "MeetingQ", "Screenshots");
        Directory.CreateDirectory(_screenshotDir);
    }

    public void ResetDuplicateState()
    {
        lock (_dedupeLock) _lastCaptureHash = null;
    }

    public Task StartAsync(IntPtr windowHandle, CancellationToken cancellationToken = default)
    {
        if (_isCapturing) return Task.CompletedTask;

        _targetWindow = windowHandle;
        _isCapturing  = true;
        lock (_dedupeLock) _lastCaptureHash = null;   // always save the first shot of each session

        CleanupOldScreenshots();

        _loopCts  = new CancellationTokenSource();
        _loopTask = Task.Run(() => CaptureLoopAsync(_loopCts.Token));

        _logger.LogInformation("[ScreenCapture] Started — target={Hwnd}, interval={Interval}s",
            windowHandle, CaptureIntervalMs / 1000);
        return Task.CompletedTask;
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        _isCapturing = false;
        if (_loopCts is not null)
        {
            await _loopCts.CancelAsync();
            if (_loopTask is not null)
            {
                try { await Task.WhenAny(_loopTask, Task.Delay(2000, cancellationToken)); }
                catch (Exception ex) { _logger.LogDebug(ex, "[ScreenCapture] Stop wait failed"); }
            }
            _loopCts.Dispose();
            _loopCts  = null;
            _loopTask = null;
        }
        _logger.LogInformation("[ScreenCapture] Stopped");
    }

    // Serial capture loop — each iteration fully completes before the next interval starts.
    private async Task CaptureLoopAsync(CancellationToken ct)
    {
        CaptureOnce(ct);
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(CaptureIntervalMs));
        try
        {
            while (await timer.WaitForNextTickAsync(ct))
                CaptureOnce(ct);
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>
    /// Takes one screenshot immediately (bypasses deduplication) and returns the saved path.
    /// Used for on-demand shots (name alert, manual trigger) that should always be kept.
    /// </summary>
    public Task<string> TakeScreenshotAsync() => Task.Run(async () =>
    {
        await _captureGate.WaitAsync();
        try
        {
            var timestamp = DateTime.Now;
            var filePath  = Path.Combine(_screenshotDir,
                $"screenshot_{timestamp:yyyyMMdd_HHmmss_fff}.jpg");
            using var bmp  = _targetWindow != IntPtr.Zero
                ? CaptureToBitmap(_targetWindow)
                : CaptureToBitmap();
            var hash = ComputeHash(bmp);
            SaveJpeg(bmp, filePath);
            ScreenshotCaptured?.Invoke(this, new ScreenshotCapturedEventArgs(filePath, timestamp, hash));
            return filePath;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[ScreenCapture] TakeScreenshotAsync failed");
            throw;
        }
        finally
        {
            _captureGate.Release();
        }
    });

    // ── Capture helpers ───────────────────────────────────────────────────

    private void CaptureOnce(CancellationToken ct)
    {
        if (!_isCapturing || ct.IsCancellationRequested) return;
        if (ShouldSkipPeriodicCapture?.Invoke() == true) return;
        try { _captureGate.Wait(ct); }
        catch (OperationCanceledException) { return; }
        try
        {
            var timestamp = DateTime.Now;

            using var bmp = _targetWindow != IntPtr.Zero
                ? CaptureToBitmap(_targetWindow)
                : CaptureToBitmap();

            var hash = ComputeHash(bmp);

            lock (_dedupeLock)
            {
                if (hash == _lastCaptureHash)
                {
                    _logger.LogDebug("[ScreenCapture] Duplicate frame — skipped");
                    return;
                }

                // Cooldown: prevent burst captures on rapid content changes (animations, video).
                // Update the hash baseline even when skipped, so the next check after cooldown
                // compares against the latest frame, not an old one.
                _lastCaptureHash = hash;

                var sinceLastSave = (DateTime.Now - _lastSaveTime).TotalMilliseconds;
                if (sinceLastSave < MinSaveIntervalMs)
                {
                    _logger.LogDebug("[ScreenCapture] Cooldown ({SinceLastSave}ms < {Min}ms) — skipped",
                        (int)sinceLastSave, MinSaveIntervalMs);
                    return;
                }

                _lastSaveTime = DateTime.Now;
            }

            var fileName = $"screenshot_{timestamp:yyyyMMdd_HHmmss_fff}.jpg";
            var filePath = Path.Combine(_screenshotDir, fileName);
            SaveJpeg(bmp, filePath);

            ScreenshotCaptured?.Invoke(this,
                new ScreenshotCapturedEventArgs(filePath, timestamp, hash));

            _logger.LogDebug("[ScreenCapture] Saved {File}", fileName);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[ScreenCapture] Capture failed");
        }
        finally
        {
            _captureGate.Release();
        }
    }

    /// <summary>Captures the primary screen and returns an owned Bitmap (caller must dispose).</summary>
    private Bitmap CaptureToBitmap()
    {
        int w = GetSystemMetrics(0); // SM_CXSCREEN
        int h = GetSystemMetrics(1); // SM_CYSCREEN

        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);

        bool captured = false;
        try
        {
            g.CopyFromScreen(0, 0, 0, 0, new Size(w, h), CopyPixelOperation.SourceCopy);
            captured = true;
        }
        catch { /* fall through to BitBlt */ }

        if (!captured)
        {
            IntPtr hwndDesktop = GetDesktopWindow();
            IntPtr hdcSrc      = GetWindowDC(hwndDesktop);
            if (hdcSrc != IntPtr.Zero)
            {
                IntPtr hdcDest = g.GetHdc();
                try   { BitBlt(hdcDest, 0, 0, w, h, hdcSrc, 0, 0, SRCCOPY); }
                finally
                {
                    g.ReleaseHdc(hdcDest);
                    ReleaseDC(hwndDesktop, hdcSrc);
                }
            }
        }

        return bmp;
    }

    /// <summary>Captures a specific window and returns an owned Bitmap (caller must dispose).
    /// Falls back to full-screen capture if the window handle is invalid.</summary>
    private Bitmap CaptureToBitmap(IntPtr hwnd)
    {
        if (!GetWindowRect(hwnd, out RECT r))
        {
            _logger.LogWarning("[ScreenCapture] GetWindowRect failed, falling back to screen");
            return CaptureToBitmap();
        }

        int w = r.Right  - r.Left;
        int h = r.Bottom - r.Top;
        if (w <= 0 || h <= 0)
        {
            _logger.LogWarning("[ScreenCapture] Window rect is empty, falling back to screen");
            return CaptureToBitmap();
        }

        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        var hdc = g.GetHdc();
        bool ok = PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT);
        g.ReleaseHdc(hdc);

        if (!ok)
        {
            _logger.LogWarning("[ScreenCapture] PrintWindow failed, falling back to screen");
            bmp.Dispose();
            return CaptureToBitmap();
        }

        return bmp;
    }

    /// <summary>
    /// Computes an MD5 hash of a 64×36 thumbnail of <paramref name="bmp"/>.
    /// Downsampling before hashing makes the hash insensitive to screen resolution
    /// while still detecting any meaningful content change.
    /// </summary>
    private static string ComputeHash(Bitmap bmp)
    {
        using var thumb = new Bitmap(bmp, ThumbW, ThumbH);

        // Lock pixels and hash the raw bytes
        var data = thumb.LockBits(
            new Rectangle(0, 0, ThumbW, ThumbH),
            ImageLockMode.ReadOnly,
            PixelFormat.Format32bppArgb);
        try
        {
            int stride = Math.Abs(data.Stride);
            var pixels = new byte[stride * ThumbH];
            Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
            var hashBytes = MD5.HashData(pixels);
            return Convert.ToHexString(hashBytes).ToLowerInvariant();
        }
        finally
        {
            thumb.UnlockBits(data);
        }
    }

    private static void SaveJpeg(Bitmap bmp, string path)
    {
        var encoder = ImageCodecInfo.GetImageEncoders()
            .First(c => c.FormatID == ImageFormat.Jpeg.Guid);
        using var encoderParams = new EncoderParameters(1);
        using var qualityParam = new EncoderParameter(
            System.Drawing.Imaging.Encoder.Quality, (long)JpegQuality);
        encoderParams.Param[0] = qualityParam;
        bmp.Save(path, encoder, encoderParams);
    }

    // Deletes screenshots older than MaxScreenshotAge or beyond MaxScreenshotCount (oldest first).
    private void CleanupOldScreenshots()
    {
        try
        {
            var cutoff = DateTime.Now - MaxScreenshotAge;
            var files = Directory.GetFiles(_screenshotDir, "screenshot_*.jpg")
                .Select(f => new FileInfo(f))
                .OrderBy(f => f.CreationTime)
                .ToList();

            var toDelete = files.Where(f => f.CreationTime < cutoff).ToList();
            if (files.Count - toDelete.Count > MaxScreenshotCount)
                toDelete.AddRange(files.Except(toDelete)
                    .Take(files.Count - toDelete.Count - MaxScreenshotCount));

            var deleted = 0;
            foreach (var f in toDelete)
            {
                try { f.Delete(); deleted++; }
                catch (Exception ex) { _logger.LogDebug(ex, "[ScreenCapture] Failed to delete {File}", f.Name); }
            }
            if (deleted > 0)
                _logger.LogInformation("[ScreenCapture] Cleaned up {Count} old screenshots", deleted);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[ScreenCapture] Screenshot cleanup failed");
        }
    }

    // ── IDisposable ───────────────────────────────────────────────────────

    protected virtual void Dispose(bool disposing)
    {
        if (!_disposed)
        {
            if (disposing)
            {
                _isCapturing = false;
                _loopCts?.Cancel();
                try { _loopTask?.Wait(1000); } catch { }
                _loopCts?.Dispose();
                _captureGate.Dispose();
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
