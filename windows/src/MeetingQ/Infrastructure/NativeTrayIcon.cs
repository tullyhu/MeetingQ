using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;

namespace MeetingQ.Infrastructure;

/// <summary>
/// System-tray icon implemented via raw Win32 Shell_NotifyIcon P/Invoke.
/// Avoids H.NotifyIcon's async ImageSource→HICON pipeline which fails at runtime.
/// </summary>
internal sealed class NativeTrayIcon : IDisposable
{
    // ── Win32 ──────────────────────────────────────────────────────────────

    private const uint NIM_ADD    = 0;
    private const uint NIM_MODIFY = 1;
    private const uint NIM_DELETE = 2;

    private const uint NIF_MESSAGE = 0x01;
    private const uint NIF_ICON    = 0x02;
    private const uint NIF_TIP     = 0x04;
    private const uint NIF_INFO    = 0x10;

    private const int WM_LBUTTONDBLCLK = 0x0203;
    private const int WM_RBUTTONUP     = 0x0205;
    private const int WM_CONTEXTMENU   = 0x007B;
    private const int NIN_BALLOONUSERACTION = 0x0405; // balloon body clicked
    private const uint CALLBACK_MSG    = 0x8001; // WM_APP + 1

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NOTIFYICONDATA
    {
        public int    cbSize;
        public IntPtr hWnd;
        public uint   uID;
        public uint   uFlags;
        public uint   uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szTip;
        public uint   dwState;
        public uint   dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string szInfo;
        public uint   uTimeout;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string szInfoTitle;
        public uint   dwInfoFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X; public int Y; }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern bool Shell_NotifyIcon(uint dwMessage, ref NOTIFYICONDATA data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessage(string msg);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT pt);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);

    // ── State ──────────────────────────────────────────────────────────────

    private readonly HwndSource _msgSink;
    private readonly uint       _wmTaskbarCreated;
    private          IntPtr     _hIcon;
    private          string     _tooltip;
    private          bool       _created;
    private          bool       _disposed;

    public event Action?   DoubleClick;
    public ContextMenu?    ContextMenu { get; set; }

    // ── Constructor ────────────────────────────────────────────────────────

    public NativeTrayIcon(string tooltip)
    {
        _tooltip          = tooltip;
        _wmTaskbarCreated = RegisterWindowMessage("TaskbarCreated");

        // Message-only window — receives Shell callbacks without a visible window
        var p = new HwndSourceParameters("MeetingQTraySink")
        {
            WindowStyle         = unchecked((int)0x80000000), // WS_POPUP
            ExtendedWindowStyle = 0,
            Width               = 0,
            Height              = 0,
            PositionX           = -32000,
            PositionY           = -32000,
            ParentWindow        = new IntPtr(-3) // HWND_MESSAGE
        };
        _msgSink = new HwndSource(p);
        _msgSink.AddHook(WndProc);
    }

    // ── Public API ─────────────────────────────────────────────────────────

    /// <summary>
    /// Creates or updates the tray icon using a System.Drawing.Icon.
    /// Takes ownership of the icon's HICON handle — destroyed on replace/Dispose.
    /// (Icon.FromHandle wrappers don't own their handle, so disposing the Icon is safe.)
    /// </summary>
    public void SetIcon(System.Drawing.Icon icon)
    {
        var old = _hIcon;
        _hIcon = icon.Handle;
        if (_created)
            Modify(NIF_ICON);
        else
            Create();
        if (old != IntPtr.Zero && old != _hIcon)
            DestroyIcon(old);
    }

    public void SetTooltip(string tooltip)
    {
        _tooltip = tooltip;
        if (_created) Modify(NIF_TIP);
    }

    /// <summary>Fired when the user clicks the body of a balloon shown via <see cref="ShowBalloon"/>.</summary>
    public event Action? BalloonClicked;

    /// <summary>
    /// Shows a tray balloon (notification). Used by the meeting watcher for
    /// start/end prompts — clicking the balloon body confirms the pending action.
    /// </summary>
    public void ShowBalloon(string title, string info)
    {
        if (!_created) return;
        var data = Build(NIF_INFO);
        data.szInfoTitle = title;
        data.szInfo      = info;
        Shell_NotifyIcon(NIM_MODIFY, ref data);
    }

    // ── Internal ───────────────────────────────────────────────────────────

    private void Create()
    {
        var data = Build(NIF_MESSAGE | NIF_ICON | NIF_TIP);
        Shell_NotifyIcon(NIM_ADD, ref data);
        _created = true;
    }

    private void Modify(uint flags)
    {
        var data = Build(flags);
        Shell_NotifyIcon(NIM_MODIFY, ref data);
    }

    private NOTIFYICONDATA Build(uint flags) => new()
    {
        cbSize          = Marshal.SizeOf<NOTIFYICONDATA>(),
        hWnd            = _msgSink.Handle,
        uID             = 1,
        uFlags          = flags,
        uCallbackMessage = CALLBACK_MSG,
        hIcon           = _hIcon,
        szTip           = _tooltip ?? string.Empty,
    };

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam,
                           ref bool handled)
    {
        if (msg == (int)CALLBACK_MSG)
        {
            var ev = (int)lParam & 0xFFFF;
            if (ev == WM_LBUTTONDBLCLK)
            {
                handled = true;
                DoubleClick?.Invoke();
            }
            else if (ev == NIN_BALLOONUSERACTION)
            {
                handled = true;
                BalloonClicked?.Invoke();
            }
            else if (ev == WM_RBUTTONUP || ev == WM_CONTEXTMENU)
            {
                handled = true;
                ShowMenu();
            }
        }
        else if (_wmTaskbarCreated != 0 && msg == (int)_wmTaskbarCreated && _created)
        {
            // Explorer restarted — re-register the icon
            _created = false;
            Create();
        }
        return IntPtr.Zero;
    }

    private void ShowMenu()
    {
        if (ContextMenu == null) return;
        GetCursorPos(out var pt);
        SetForegroundWindow(_msgSink.Handle);
        ContextMenu.Placement        = PlacementMode.AbsolutePoint;
        ContextMenu.HorizontalOffset = pt.X;
        ContextMenu.VerticalOffset   = pt.Y;
        ContextMenu.IsOpen           = true;
    }

    // ── Dispose ────────────────────────────────────────────────────────────

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_created)
        {
            var data = Build(0);
            Shell_NotifyIcon(NIM_DELETE, ref data);
        }
        _msgSink.Dispose();
        if (_hIcon != IntPtr.Zero)
        {
            DestroyIcon(_hIcon);
            _hIcon = IntPtr.Zero;
        }
    }
}
