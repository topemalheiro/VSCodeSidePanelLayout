# VS Code Side Panel Layout Script
# Hotkey: Ctrl+Alt+V
# Snaps VS Code window to span both bottom monitors with side panel on right
# Uses direct SQLite state.vscdb manipulation for panel width (no mouse simulation)

param(
    [switch]$Once,       # Run Ctrl+Alt+V layout once (dual monitors bottom)
    [switch]$SingleOnce, # Run Ctrl+Alt+N layout once (top monitors)
    [switch]$Duplicate   # Duplicate window first, then snap
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

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
}
"@

# Load Windows Forms for SendKeys
Add-Type -AssemblyName System.Windows.Forms

# Path to the Python helper script for setting panel width via SQLite
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SetPanelWidthScript = Join-Path $ScriptDir "set_panel_width.py"

# Window position settings for your monitors
# DISPLAY6 (left):  X=0,    Y=1083, WorkingArea height=1032
# DISPLAY5 (right): X=1920, Y=1002, WorkingArea height=1032
$TargetX = 0
$TargetY = 1083
$TargetWidth = 3840
$TargetHeight = 953

# Panel width target (pixels) for dual monitor layout
$PanelWidth = 1920

# Top monitors layout (Ctrl+Alt+N) - spans DISPLAY2 + DISPLAY1 (top-left to top-middle)
# DISPLAY2: X=-1360, Y=449, 1360x768
# DISPLAY1: X=0, Y=0, 1920x1080 (primary, taskbar at top 40px)
$SingleMonitorX = -1360       # Left edge of DISPLAY2
$SingleMonitorY = 449         # Top of DISPLAY2
$SingleMonitorWidth = 3280    # 1360 + 1920 (both monitors)
$SingleMonitorHeight = 583    # From Y=449 to Y=1032 (DISPLAY1 working area bottom)

# Panel width for single monitor layout (maximize auxiliary panel)
$SinglePanelWidth = 3180      # Nearly full window width

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

function Set-PanelWidthDB {
    param(
        [int]$Width
    )

    Write-Host "  Setting auxiliary bar width to ${Width}px via state.vscdb..." -ForegroundColor Cyan

    if (-not (Test-Path $SetPanelWidthScript)) {
        Write-Host "  ERROR: set_panel_width.py not found at $SetPanelWidthScript" -ForegroundColor Red
        return $false
    }

    try {
        $output = python $SetPanelWidthScript $Width 2>&1
        $exitCode = $LASTEXITCODE

        foreach ($line in $output) {
            Write-Host "    $line" -ForegroundColor Gray
        }

        if ($exitCode -eq 0) {
            Write-Host "  Panel width set successfully" -ForegroundColor Green
            return $true
        } else {
            Write-Host "  WARNING: Failed to set panel width (exit code $exitCode)" -ForegroundColor Yellow
            return $false
        }
    } catch {
        Write-Host "  ERROR: Failed to run set_panel_width.py: $_" -ForegroundColor Red
        return $false
    }
}

function Open-SecondaryPanel {
    param(
        [IntPtr]$hwnd,
        [switch]$SkipToggle  # Skip Ctrl+Alt+B if panel is already open
    )

    # Ensure VS Code has focus
    [WinAPI]::SetForegroundWindow($hwnd) | Out-Null
    Start-Sleep -Milliseconds 100

    if (-not $SkipToggle) {
        Write-Host "  Opening secondary panel (Ctrl+Alt+B)..." -ForegroundColor Cyan
        [System.Windows.Forms.SendKeys]::SendWait("^%b")
        Start-Sleep -Milliseconds 300
        Write-Host "  Panel toggle sent" -ForegroundColor Green
    } else {
        Write-Host "  Skipping panel toggle (assuming already open)" -ForegroundColor Cyan
    }
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

    # Set panel width in state.vscdb before positioning
    Set-PanelWidthDB -Width $PanelWidth | Out-Null

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
        [WinAPI]::SetForegroundWindow($hwnd) | Out-Null
        Start-Sleep -Milliseconds 100

        # Ensure secondary panel is visible
        Open-SecondaryPanel -hwnd $hwnd -SkipToggle

        return $true
    } else {
        Write-Host "  Failed to reposition window!" -ForegroundColor Red
        return $false
    }
}

function Invoke-SingleMonitorLayout {
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Snapping VS Code to top monitors (auxiliary panel full)..."

    # Set panel width in state.vscdb for maximized auxiliary panel
    Set-PanelWidthDB -Width $SinglePanelWidth | Out-Null

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
        [WinAPI]::SetForegroundWindow($hwnd) | Out-Null
        Start-Sleep -Milliseconds 100

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
Write-Host "  Dual:   ${TargetWidth}x${TargetHeight} at $TargetX,$TargetY (panel=${PanelWidth}px)"
Write-Host "  Single: ${SingleMonitorWidth}x${SingleMonitorHeight} at $SingleMonitorX,$SingleMonitorY (panel=${SinglePanelWidth}px)"
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
