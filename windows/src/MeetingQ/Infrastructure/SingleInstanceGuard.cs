using System.IO.Pipes;
using System.Runtime.InteropServices;

namespace MeetingQ.Infrastructure;

/// <summary>
/// Enforces single-instance execution via a named mutex.
/// The first instance starts a named-pipe server; subsequent instances
/// connect to the pipe (which triggers the first instance to show its window)
/// and then exit immediately.
/// </summary>
public sealed class SingleInstanceGuard : IDisposable
{
    private const string MutexName = "MeetingQ_SingleInstance_v2";
    private const string PipeName  = "MeetingQ_Activation_v2";

    private Mutex?                  _mutex;
    private bool                    _ownsMutex;
    private bool                    _disposed;
    private CancellationTokenSource? _pipeCts;
    private Task?                   _pipeTask;

    /// <summary>
    /// Returns true if another instance is already running.
    /// Call before showing any UI; if true, call BringExistingToFront() then exit.
    /// </summary>
    public bool IsAlreadyRunning()
    {
        _mutex = new Mutex(initiallyOwned: true, MutexName, out _ownsMutex);
        return !_ownsMutex;
    }

    /// <summary>
    /// Starts a background pipe server. When a second instance connects,
    /// <paramref name="onActivationRequested"/> is invoked (on a thread-pool thread).
    /// </summary>
    public void StartActivationListener(Action onActivationRequested)
    {
        _pipeCts  = new CancellationTokenSource();
        _pipeTask = Task.Run(() => PipeServerLoop(onActivationRequested, _pipeCts.Token));
    }

    /// <summary>Signals the first instance to show itself, then returns.</summary>
    public void BringExistingToFront()
    {
        try
        {
            using var client = new NamedPipeClientStream(".", PipeName, PipeDirection.Out);
            client.Connect(1000);
            // Just connecting is enough — the server detects the connection.
        }
        catch
        {
            // First instance may not be listening yet; ignore.
        }
    }

    // ── Private ───────────────────────────────────────────────────────────

    private static async Task PipeServerLoop(Action onActivated, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                using var server = new NamedPipeServerStream(
                    PipeName,
                    PipeDirection.In,
                    maxNumberOfServerInstances: 1,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous);

                await server.WaitForConnectionAsync(ct);
                // A second instance connected — activate the first instance.
                onActivated();
            }
            catch (OperationCanceledException) { break; }
            catch
            {
                // Restart loop on transient errors — no ct here so Dispose() can't
                // turn this backoff into a tight spin or an unhandled exception.
                try { await Task.Delay(500).ConfigureAwait(false); } catch { }
                if (ct.IsCancellationRequested) break;
            }
        }
    }

    public void Dispose()
    {
        if (!_disposed)
        {
            _pipeCts?.Cancel();
            try { _pipeTask?.Wait(TimeSpan.FromMilliseconds(500)); } catch { }
            _pipeCts?.Dispose();
            if (_ownsMutex)
                try { _mutex?.ReleaseMutex(); } catch { }
            _mutex?.Dispose();
            _disposed = true;
        }
    }
}
