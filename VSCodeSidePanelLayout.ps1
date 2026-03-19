# VS Code Side Panel Layout Script
# Hotkey: Ctrl+Alt+V
# Snaps VS Code window to span both bottom monitors with side panel on right

param(
    [switch]$Once,       # Run Ctrl+Alt+V layout once (dual monitors bottom)
    [switch]$SingleOnce, # Run Ctrl+Alt+N layout once (top monitors)
    [switch]$Duplicate   # Duplicate window first, then snap
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class WinAPI {
    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    // For message loop
    [DllImport("user32.dll")]
    public static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    public static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    public static extern IntPtr DispatchMessage(ref MSG lpMsg);

    // Mouse control
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);

    // SendInput with proper struct layout for unions
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    public const int SM_CXSCREEN = 0;
    public const int SM_CYSCREEN = 1;
    public const int SM_XVIRTUALSCREEN = 76;
    public const int SM_YVIRTUALSCREEN = 77;
    public const int SM_CXVIRTUALSCREEN = 78;
    public const int SM_CYVIRTUALSCREEN = 79;

    private const uint INPUT_MOUSE = 0;
    private const uint MOUSEEVENTF_MOVE = 0x0001;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;
    private const uint MOUSEEVENTF_ABSOLUTE = 0x8000;

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT {
        public uint type;
        public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public POINT pt;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int x;
        public int y;
    }

    public const int WM_HOTKEY = 0x0312;

    // Convert screen coordinates to virtual desktop normalized coordinates (0-65535)
    private static void ToAbsolute(int x, int y, out int absX, out int absY) {
        int vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
        int vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        int vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);

        absX = ((x - vx) * 65536) / vw;
        absY = ((y - vy) * 65536) / vh;
    }

    public static void MouseClick(int x, int y) {
        SetCursorPos(x, y);
        Thread.Sleep(10);

        int absX, absY;
        ToAbsolute(x, y, out absX, out absY);

        INPUT[] inputs = new INPUT[2];

        inputs[0].type = INPUT_MOUSE;
        inputs[0].mi.dx = absX;
        inputs[0].mi.dy = absY;
        inputs[0].mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_MOVE | MOUSEEVENTF_LEFTDOWN;

        inputs[1].type = INPUT_MOUSE;
        inputs[1].mi.dx = absX;
        inputs[1].mi.dy = absY;
        inputs[1].mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_LEFTUP;

        SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void MouseDrag(int fromX, int fromY, int toX, int toY) {
        // Move to start position
        SetCursorPos(fromX, fromY);
        Thread.Sleep(50);

        int absFromX, absFromY, absToX, absToY;
        ToAbsolute(fromX, fromY, out absFromX, out absFromY);
        ToAbsolute(toX, toY, out absToX, out absToY);

        // Mouse down at start
        INPUT downInput = new INPUT();
        downInput.type = INPUT_MOUSE;
        downInput.mi.dx = absFromX;
        downInput.mi.dy = absFromY;
        downInput.mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_MOVE | MOUSEEVENTF_LEFTDOWN;
        SendInput(1, new INPUT[] { downInput }, Marshal.SizeOf(typeof(INPUT)));
        Thread.Sleep(50);

        // Move to end position (in steps for smoother drag)
        int steps = 10;
        for (int i = 1; i <= steps; i++) {
            int curX = fromX + ((toX - fromX) * i / steps);
            int curY = fromY + ((toY - fromY) * i / steps);
            SetCursorPos(curX, curY);
            Thread.Sleep(10);
        }

        // Final position
        SetCursorPos(toX, toY);
        Thread.Sleep(50);

        // Mouse up at end
        INPUT upInput = new INPUT();
        upInput.type = INPUT_MOUSE;
        upInput.mi.dx = absToX;
        upInput.mi.dy = absToY;
        upInput.mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_LEFTUP;
        SendInput(1, new INPUT[] { upInput }, Marshal.SizeOf(typeof(INPUT)));
    }
}
"@

# Load Windows Forms for SendKeys
Add-Type -AssemblyName System.Windows.Forms

# Window position settings for your monitors
# DISPLAY6 (left):  X=0,    Y=1083, WorkingArea height=1032
# DISPLAY5 (right): X=1920, Y=1002, WorkingArea height=1032
$TargetX = 0
$TargetY = 1083
$TargetWidth = 3840
$TargetHeight = 953

# Panel divider target position (X coordinate where monitors split)
$DividerTargetX = 1920

# Top monitors layout (Ctrl+Alt+N) - spans DISPLAY2 + DISPLAY1 (top-left to top-middle)
# DISPLAY2: X=-1360, Y=449, 1360x768
# DISPLAY1: X=0, Y=0, 1920x1080 (primary, taskbar at top 40px)
$SingleMonitorX = -1360       # Left edge of DISPLAY2
$SingleMonitorY = 449         # Top of DISPLAY2
$SingleMonitorWidth = 3280    # 1360 + 1920 (both monitors)
$SingleMonitorHeight = 583    # From Y=449 to Y=1032 (DISPLAY1 working area bottom)

# Hotkey settings
$MOD_CONTROL = 0x0002
$MOD_ALT = 0x0001
$VK_V = 0x56
$VK_N = 0x4E
$HOTKEY_ID = 9999
$HOTKEY_ID_N = 10000

function Find-VSCodeWindow {
    # First check if foreground window is VS Code
    $foreground = [WinAPI]::GetForegroundWindow()
    $titleLength = [WinAPI]::GetWindowTextLength($foreground)
    if ($titleLength -gt 0) {
        $sb = New-Object System.Text.StringBuilder($titleLength + 1)
        [WinAPI]::GetWindowText($foreground, $sb, $sb.Capacity) | Out-Null
        $title = $sb.ToString()
        if ($title -match "Visual Studio Code") {
            return $foreground
        }
    }

    # Otherwise find any VS Code window
    $vsCodeProcesses = Get-Process -Name "Code" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero }

    foreach ($proc in $vsCodeProcesses) {
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
            $titleLength = [WinAPI]::GetWindowTextLength($proc.MainWindowHandle)
            if ($titleLength -gt 0) {
                $sb = New-Object System.Text.StringBuilder($titleLength + 1)
                [WinAPI]::GetWindowText($proc.MainWindowHandle, $sb, $sb.Capacity) | Out-Null
                $title = $sb.ToString()
                if ($title -match "Visual Studio Code" -or $title -match " - .+ - Visual Studio Code") {
                    return $proc.MainWindowHandle
                }
            }
        }
    }

    return $null
}


function Open-SecondaryPanel {
    param(
        [IntPtr]$hwnd,
        [switch]$SkipToggle  # Skip Ctrl+Alt+B if panel is already open
    )

    # First ensure VS Code has focus
    [WinAPI]::SetForegroundWindow($hwnd) | Out-Null
    Start-Sleep -Milliseconds 50

    # Click in the center of the VS Code window to ensure it has keyboard focus
    $clickX = [int]($script:TargetX + ($script:TargetWidth / 2))
    $clickY = [int]($script:TargetY + ($script:TargetHeight / 2))
    [WinAPI]::MouseClick($clickX, $clickY)
    Start-Sleep -Milliseconds 50

    if (-not $SkipToggle) {
        Write-Host "  Opening Claude Code panel (Ctrl+Alt+B)..." -ForegroundColor Cyan
        # Use SendKeys to send Ctrl+Alt+B
        # ^ = Ctrl, % = Alt, b = B key
        [System.Windows.Forms.SendKeys]::SendWait("^%b")

        # Wait for panel to open and render
        Start-Sleep -Milliseconds 300
        Write-Host "  Panel toggle sent" -ForegroundColor Green
    } else {
        Write-Host "  Skipping panel toggle (assuming already open)" -ForegroundColor Cyan
    }
}

function Move-PanelDivider {
    param(
        [int]$TargetX = 1920,
        [int]$WindowX = 0,
        [int]$WindowY = 1083,
        [int]$WindowWidth = 3840,
        [int]$WindowHeight = 953
    )

    Write-Host "  Dragging panel divider to X=$TargetX..." -ForegroundColor Cyan

    # Save original cursor position
    $originalPos = New-Object WinAPI+POINT
    [WinAPI]::GetCursorPos([ref]$originalPos) | Out-Null

    # Y position: middle of window, but skip title bar (~35px) and status bar (~25px)
    $clickY = [int]($WindowY + 35 + (($WindowHeight - 60) / 2))

    # The divider is 300px from right edge of window
    $dividerX = $WindowX + $WindowWidth - 300

    Write-Host "    Dragging from X=$dividerX to X=$TargetX, Y=$clickY" -ForegroundColor Gray

    # Single drag from divider position to target using C# method
    [WinAPI]::MouseDrag($dividerX, $clickY, $TargetX, $clickY)

    # Restore cursor
    [WinAPI]::SetCursorPos($originalPos.x, $originalPos.y) | Out-Null

    Write-Host "  Panel divider drag complete" -ForegroundColor Green
}

function Duplicate-VSCodeWindow {
    param([IntPtr]$hwnd)

    Write-Host "  Duplicating workspace in new window..." -ForegroundColor Cyan

    # Ensure VS Code has focus
    [WinAPI]::SetForegroundWindow($hwnd) | Out-Null
    Start-Sleep -Milliseconds 100

    # Open command palette with Ctrl+Shift+P
    [System.Windows.Forms.SendKeys]::SendWait("^+p")
    Start-Sleep -Milliseconds 300

    # Type the command
    [System.Windows.Forms.SendKeys]::SendWait("Duplicate as Workspace in New Window")
    Start-Sleep -Milliseconds 300

    # Press Enter to execute
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")

    Write-Host "  Waiting for new window to open..." -ForegroundColor Cyan
    Start-Sleep -Milliseconds 1500  # Wait for new window to spawn

    Write-Host "  Duplicate command sent" -ForegroundColor Green
}

function Invoke-LayoutSnap {
    param(
        [switch]$DuplicateFirst  # If set, duplicate the window before snapping
    )

    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Snapping VS Code window..."

    $hwnd = Find-VSCodeWindow

    if ($null -eq $hwnd -or $hwnd -eq [IntPtr]::Zero) {
        Write-Host "  No VS Code window found!" -ForegroundColor Yellow
        return $false
    }

    # Get window title for feedback
    $titleLength = [WinAPI]::GetWindowTextLength($hwnd)
    $sb = New-Object System.Text.StringBuilder($titleLength + 1)
    [WinAPI]::GetWindowText($hwnd, $sb, $sb.Capacity) | Out-Null
    Write-Host "  Found: $($sb.ToString())" -ForegroundColor Cyan

    # If DuplicateFirst flag is set, duplicate the window first
    if ($DuplicateFirst) {
        Duplicate-VSCodeWindow -hwnd $hwnd

        # Now find the NEW window (it should be the foreground window)
        Start-Sleep -Milliseconds 500
        $hwnd = [WinAPI]::GetForegroundWindow()

        $titleLength = [WinAPI]::GetWindowTextLength($hwnd)
        $sb = New-Object System.Text.StringBuilder($titleLength + 1)
        [WinAPI]::GetWindowText($hwnd, $sb, $sb.Capacity) | Out-Null
        Write-Host "  New window: $($sb.ToString())" -ForegroundColor Cyan
    }

    # Restore if minimized (SW_RESTORE = 9)
    [WinAPI]::ShowWindow($hwnd, 9) | Out-Null

    # Move and resize
    $result = [WinAPI]::MoveWindow($hwnd, $TargetX, $TargetY, $TargetWidth, $TargetHeight, $true)

    if ($result) {
        Write-Host "  Repositioned to: X=$TargetX, Y=$TargetY, ${TargetWidth}x${TargetHeight}" -ForegroundColor Green
        # Bring to front
        [WinAPI]::SetForegroundWindow($hwnd) | Out-Null

        # Small delay for window to render
        Start-Sleep -Milliseconds 100

        # Ensure VS Code has focus (skip Ctrl+Alt+B since panel is usually already open)
        Open-SecondaryPanel -hwnd $hwnd -SkipToggle

        # Now drag the panel divider to the target position
        Move-PanelDivider -TargetX $DividerTargetX -WindowX $TargetX -WindowY $TargetY -WindowWidth $TargetWidth -WindowHeight $TargetHeight

        return $true
    } else {
        Write-Host "  Failed to reposition window!" -ForegroundColor Red
        return $false
    }
}

function Invoke-SingleMonitorLayout {
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Snapping VS Code to top monitors (auxiliary panel full)..."

    # First run dual layout to set up panel correctly
    Write-Host "  Running dual layout first to set up panel..." -ForegroundColor Cyan
    Invoke-LayoutSnap | Out-Null
    Start-Sleep -Milliseconds 200

    # Now find the window again and apply single monitor layout
    $hwnd = Find-VSCodeWindow

    if ($null -eq $hwnd -or $hwnd -eq [IntPtr]::Zero) {
        Write-Host "  No VS Code window found!" -ForegroundColor Yellow
        return $false
    }

    # Get window title for feedback
    $titleLength = [WinAPI]::GetWindowTextLength($hwnd)
    $sb = New-Object System.Text.StringBuilder($titleLength + 1)
    [WinAPI]::GetWindowText($hwnd, $sb, $sb.Capacity) | Out-Null
    Write-Host "  Found: $($sb.ToString())" -ForegroundColor Cyan

    # Restore if minimized (SW_RESTORE = 9)
    [WinAPI]::ShowWindow($hwnd, 9) | Out-Null

    # Move and resize to single monitor
    $result = [WinAPI]::MoveWindow($hwnd, $SingleMonitorX, $SingleMonitorY, $SingleMonitorWidth, $SingleMonitorHeight, $true)

    if ($result) {
        Write-Host "  Repositioned to: X=$SingleMonitorX, Y=$SingleMonitorY, ${SingleMonitorWidth}x${SingleMonitorHeight}" -ForegroundColor Green
        # Bring to front
        [WinAPI]::SetForegroundWindow($hwnd) | Out-Null

        # Small delay for window to render
        Start-Sleep -Milliseconds 100

        # Click to ensure focus
        $clickX = [int]($SingleMonitorX + ($SingleMonitorWidth / 2))
        $clickY = [int]($SingleMonitorY + ($SingleMonitorHeight / 2))
        [WinAPI]::MouseClick($clickX, $clickY)
        Start-Sleep -Milliseconds 50

        # Drag panel divider to maximize auxiliary panel (panel is on right side)
        # Start from right side of window, drag left to minimize editor
        $dragY = [int]($SingleMonitorY + 35 + (($SingleMonitorHeight - 60) / 2))
        $startX = $SingleMonitorX + $SingleMonitorWidth - 100  # Right side, inside panel
        $endX = $SingleMonitorX + 100  # Left edge, minimal editor width

        Write-Host "  Maximizing auxiliary panel (drag from X=$startX to X=$endX)..." -ForegroundColor Cyan
        [WinAPI]::MouseDrag($startX, $dragY, $endX, $dragY)

        return $true
    } else {
        Write-Host "  Failed to reposition window!" -ForegroundColor Red
        return $false
    }
}

# If -Once flag, run dual layout and exit
if ($Once) {
    if ($Duplicate) {
        Invoke-LayoutSnap -DuplicateFirst
    } else {
        Invoke-LayoutSnap
    }
    exit 0
}

# If -SingleOnce flag, run single/top layout and exit
if ($SingleOnce) {
    Invoke-SingleMonitorLayout
    exit 0
}

# Main execution with hotkey listener
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  VS Code Side Panel Layout Script" -ForegroundColor White
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Ctrl+Alt+V - Dual monitor layout (bottom)" -ForegroundColor Yellow
Write-Host "  Ctrl+Alt+N - Top monitors layout (panel full)" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Dual:   ${TargetWidth}x${TargetHeight} at $TargetX,$TargetY"
Write-Host "  Single: ${SingleMonitorWidth}x${SingleMonitorHeight} at $SingleMonitorX,$SingleMonitorY"
Write-Host ""
Write-Host "  Press Ctrl+C to exit"
Write-Host "============================================" -ForegroundColor Cyan

# Register hotkeys
$registered = [WinAPI]::RegisterHotKey([IntPtr]::Zero, $HOTKEY_ID, ($MOD_CONTROL -bor $MOD_ALT), $VK_V)
$registeredN = [WinAPI]::RegisterHotKey([IntPtr]::Zero, $HOTKEY_ID_N, ($MOD_CONTROL -bor $MOD_ALT), $VK_N)

if (-not $registered) {
    Write-Host ""
    Write-Host "ERROR: Failed to register Ctrl+Alt+V hotkey!" -ForegroundColor Red
    Write-Host "The hotkey may be in use by another application." -ForegroundColor Red
    exit 1
}

if (-not $registeredN) {
    Write-Host ""
    Write-Host "ERROR: Failed to register Ctrl+Alt+N hotkey!" -ForegroundColor Red
    Write-Host "The hotkey may be in use by another application." -ForegroundColor Red
    [WinAPI]::UnregisterHotKey([IntPtr]::Zero, $HOTKEY_ID) | Out-Null
    exit 1
}

Write-Host ""
Write-Host "Hotkeys registered. Listening..." -ForegroundColor Green

# Message loop
$msg = New-Object WinAPI+MSG

try {
    while ($true) {
        $result = [WinAPI]::GetMessage([ref]$msg, [IntPtr]::Zero, 0, 0)

        if ($result -eq 0 -or $result -eq -1) {
            break
        }

        if ($msg.message -eq [WinAPI]::WM_HOTKEY) {
            if ($msg.wParam -eq $HOTKEY_ID) {
                Invoke-LayoutSnap
            } elseif ($msg.wParam -eq $HOTKEY_ID_N) {
                Invoke-SingleMonitorLayout
            }
        }

        [WinAPI]::TranslateMessage([ref]$msg) | Out-Null
        [WinAPI]::DispatchMessage([ref]$msg) | Out-Null
    }
} finally {
    [WinAPI]::UnregisterHotKey([IntPtr]::Zero, $HOTKEY_ID) | Out-Null
    [WinAPI]::UnregisterHotKey([IntPtr]::Zero, $HOTKEY_ID_N) | Out-Null
    Write-Host "`nHotkeys unregistered. Goodbye!" -ForegroundColor Cyan
}
