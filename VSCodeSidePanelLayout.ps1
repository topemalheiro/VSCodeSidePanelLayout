# VS Code Side Panel Layout Script
# Hotkey: Ctrl+Alt+V (dual monitor), Ctrl+Alt+N (top monitors)
# Snaps VS Code window and resizes auxiliary bar via CDP sash drag (no cursor movement)
# Falls back to WinAPI mouse drag if CDP unavailable

param(
    [switch]$Once,       # Run Ctrl+Alt+V layout once (dual monitors bottom)
    [switch]$SingleOnce, # Run Ctrl+Alt+N layout once (top monitors)
    [switch]$Duplicate   # Duplicate window first, then snap
)

# ============================================================
# Ensure VS Code always launches with --remote-debugging-port
# Re-applies on every script start (survives VS Code updates)
# ============================================================

$cdpFlag = "--remote-debugging-port=9222"
$codePath = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"

if (Test-Path $codePath) {
    # Fix Start Menu shortcut
    try {
        $WshShell = New-Object -ComObject WScript.Shell
        $lnkPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Visual Studio Code\Visual Studio Code.lnk"
        if (Test-Path $lnkPath) {
            $shortcut = $WshShell.CreateShortcut($lnkPath)
            if ($shortcut.Arguments -notmatch "remote-debugging-port") {
                $shortcut.Arguments = $cdpFlag
                $shortcut.Save()
            }
        }
    } catch {}

    # Fix taskbar pinned shortcut
    try {
        $taskbarPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Visual Studio Code.lnk"
        if (Test-Path $taskbarPath) {
            $shortcut = $WshShell.CreateShortcut($taskbarPath)
            if ($shortcut.Arguments -notmatch "remote-debugging-port") {
                $shortcut.Arguments = $cdpFlag
                $shortcut.Save()
            }
        }
    } catch {}

    # Fix desktop shortcut
    try {
        $desktopPath = "$env:USERPROFILE\Desktop\Visual Studio Code.lnk"
        if (Test-Path $desktopPath) {
            $shortcut = $WshShell.CreateShortcut($desktopPath)
            if ($shortcut.Arguments -notmatch "remote-debugging-port") {
                $shortcut.Arguments = $cdpFlag
                $shortcut.Save()
            }
        }
    } catch {}

    # Fix registry entries for file associations
    $regKeys = @(
        "HKCU:\Software\Classes\Applications\Code.exe\shell\open\command",
        "HKCU:\Software\Classes\VSCodeSourceFile\shell\open\command",
        "HKCU:\Software\Classes\vscode\shell\open\command"
    )
    foreach ($key in $regKeys) {
        try {
            if (Test-Path $key) {
                $val = (Get-ItemProperty -Path $key).'(Default)'
                if ($val -and $val -notmatch "remote-debugging-port") {
                    $updated = $val -replace '(Code\.exe")', ('$1 "' + $cdpFlag + '"')
                    Set-ItemProperty -Path $key -Name '(Default)' -Value $updated
                }
            }
        } catch {}
    }
}

# ============================================================

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

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

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
    public const int WM_CLOSE = 0x0010;

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

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
        SetCursorPos(fromX, fromY);
        Thread.Sleep(50);

        int absFromX, absFromY, absToX, absToY;
        ToAbsolute(fromX, fromY, out absFromX, out absFromY);
        ToAbsolute(toX, toY, out absToX, out absToY);

        INPUT downInput = new INPUT();
        downInput.type = INPUT_MOUSE;
        downInput.mi.dx = absFromX;
        downInput.mi.dy = absFromY;
        downInput.mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_MOVE | MOUSEEVENTF_LEFTDOWN;
        SendInput(1, new INPUT[] { downInput }, Marshal.SizeOf(typeof(INPUT)));
        Thread.Sleep(50);

        int steps = 10;
        for (int i = 1; i <= steps; i++) {
            int curX = fromX + ((toX - fromX) * i / steps);
            int curY = fromY + ((toY - fromY) * i / steps);
            SetCursorPos(curX, curY);
            Thread.Sleep(10);
        }

        SetCursorPos(toX, toY);
        Thread.Sleep(50);

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

# CDP port for Chrome DevTools Protocol
$CDPPort = 9222

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

# Panel width for single monitor layout (divider at monitor boundary: X=0 screen = 1360 viewport)
$SinglePanelWidth = 1920

# Hotkey settings
$MOD_CONTROL = 0x0002
$MOD_ALT = 0x0001
$VK_V = 0x56
$VK_N = 0x4E
$HOTKEY_ID = 9999
$HOTKEY_ID_N = 10000

# ============================================================
# CDP (Chrome DevTools Protocol) functions
# ============================================================

function Connect-CDPWebSocket {
    param(
        [string]$WindowTitle = ""
    )

    try {
        $targets = Invoke-RestMethod -Uri "http://localhost:$CDPPort/json" -TimeoutSec 3 -ErrorAction Stop

        # Debug: log all targets
        Write-Host "    [DEBUG] CDP targets found: $($targets.Count)" -ForegroundColor DarkGray
        foreach ($t in $targets) {
            $marker = ""
            if ($t.url -match "workbench") { $marker = " [WORKBENCH]" }
            Write-Host "    [DEBUG]   type=$($t.type) title='$($t.title)'$marker" -ForegroundColor DarkGray
        }

        if ($WindowTitle) {
            Write-Host "    [DEBUG] Looking for window: '$WindowTitle'" -ForegroundColor DarkGray
        }

        # Find the correct CDP target
        $target = $null

        # 1. If we have a window title, match it exactly (the CDP target title = VS Code window title)
        if ($WindowTitle) {
            foreach ($t in $targets) {
                if ($t.type -eq "page" -and $t.title -eq $WindowTitle) {
                    $target = $t
                    Write-Host "    [DEBUG] Exact title match!" -ForegroundColor DarkGray
                    break
                }
            }
        }

        # 2. If no exact match, try partial match on window title
        if ($null -eq $target -and $WindowTitle) {
            foreach ($t in $targets) {
                if ($t.type -eq "page" -and $t.title -match [regex]::Escape($WindowTitle)) {
                    $target = $t
                    Write-Host "    [DEBUG] Partial title match" -ForegroundColor DarkGray
                    break
                }
            }
        }

        # 3. Fall back to any workbench page
        if ($null -eq $target) {
            foreach ($t in $targets) {
                if ($t.type -eq "page" -and $t.url -match "workbench") {
                    $target = $t
                    break
                }
            }
        }

        if ($null -eq $target -or [string]::IsNullOrEmpty($target.webSocketDebuggerUrl)) {
            Write-Host "    CDP: No suitable target found" -ForegroundColor Gray
            return $null
        }

        Write-Host "    [DEBUG] Connecting to: $($target.title) ($($target.url))" -ForegroundColor DarkGray

        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter(5000)
        $ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, $cts.Token).Wait()

        return @{
            WebSocket = $ws
            MessageId = 1
        }
    } catch {
        Write-Host "    CDP: Connection failed ($($_.Exception.Message))" -ForegroundColor Gray
        return $null
    }
}

function Send-CDPMessage {
    param(
        [hashtable]$Connection,
        [string]$Method,
        [hashtable]$Params = @{}
    )

    $id = $Connection.MessageId
    $Connection.MessageId = $id + 1

    $message = @{
        id = $id
        method = $Method
        params = $Params
    } | ConvertTo-Json -Depth 10 -Compress

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($message)
    $segment = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)

    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter(5000)

    $Connection.WebSocket.SendAsync(
        $segment,
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        $cts.Token
    ).Wait()

    # Receive response
    $buffer = New-Object byte[] 65536
    $responseBuilder = New-Object System.Text.StringBuilder

    do {
        $recvCts = New-Object System.Threading.CancellationTokenSource
        $recvCts.CancelAfter(5000)
        $recvSegment = New-Object System.ArraySegment[byte] -ArgumentList @(,$buffer)
        $result = $Connection.WebSocket.ReceiveAsync($recvSegment, $recvCts.Token).Result
        $chunk = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
        $responseBuilder.Append($chunk) | Out-Null
    } while (-not $result.EndOfMessage)

    $responseText = $responseBuilder.ToString()
    $response = $responseText | ConvertFrom-Json

    # CDP may send events before our response; keep reading until we get our id
    while ($response.id -ne $id) {
        $responseBuilder = New-Object System.Text.StringBuilder
        do {
            $recvCts = New-Object System.Threading.CancellationTokenSource
            $recvCts.CancelAfter(5000)
            $recvSegment = New-Object System.ArraySegment[byte] -ArgumentList @(,$buffer)
            $result = $Connection.WebSocket.ReceiveAsync($recvSegment, $recvCts.Token).Result
            $chunk = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
            $responseBuilder.Append($chunk) | Out-Null
        } while (-not $result.EndOfMessage)
        $responseText = $responseBuilder.ToString()
        $response = $responseText | ConvertFrom-Json
    }

    return $response
}

function Disconnect-CDP {
    param([hashtable]$Connection)

    if ($null -ne $Connection -and $null -ne $Connection.WebSocket) {
        try {
            $cts = New-Object System.Threading.CancellationTokenSource
            $cts.CancelAfter(2000)
            $Connection.WebSocket.CloseAsync(
                [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                "Done",
                $cts.Token
            ).Wait()
        } catch {
            # Ignore close errors
        }
    }
}

function Get-AuxiliaryBarSashPosition {
    param([hashtable]$Connection)

    $js = @"
(() => {
    const debug = [];
    const auxBar = document.getElementById('workbench.parts.auxiliarybar');
    if (!auxBar) return JSON.stringify({ error: 'no-auxiliary-bar', debug: ['auxBar element not found'] });

    const auxRect = auxBar.getBoundingClientRect();
    const auxStyle = window.getComputedStyle(auxBar);
    const isLeft = auxRect.left < window.innerWidth / 2;
    debug.push('auxBar: left=' + Math.round(auxRect.left) + ' top=' + Math.round(auxRect.top) + ' w=' + Math.round(auxRect.width) + ' h=' + Math.round(auxRect.height));
    debug.push('auxBar side=' + (isLeft ? 'LEFT' : 'RIGHT'));

    if (auxRect.width === 0) return JSON.stringify({ error: 'auxiliary-bar-hidden', auxBarWidth: 0, debug: debug });

    const allSashes = document.querySelectorAll('.monaco-sash');
    const vertSashes = document.querySelectorAll('.monaco-sash.vertical');
    debug.push('sashes: total=' + allSashes.length + ' vertical=' + vertSashes.length);

    let bestSash = null;
    let bestDist = Infinity;
    for (const s of vertSashes) {
        const r = s.getBoundingClientRect();
        const sashCenter = r.left + r.width / 2;
        const dist = isLeft
            ? Math.abs(sashCenter - (auxRect.left + auxRect.width))
            : Math.abs(sashCenter - auxRect.left);
        debug.push('  sash: x=' + Math.round(r.left) + ' w=' + Math.round(r.width) + ' h=' + Math.round(r.height) + ' dist=' + Math.round(dist));
        if (dist < bestDist) {
            bestDist = dist;
            bestSash = s;
        }
    }
    if (!bestSash || bestDist > 20) return JSON.stringify({ error: 'no-sash-found', bestDist: bestDist, debug: debug });

    const sr = bestSash.getBoundingClientRect();
    debug.push('bestSash: left=' + Math.round(sr.left) + ' w=' + Math.round(sr.width) + ' dist=' + Math.round(bestDist));

    return JSON.stringify({
        sashX: Math.round(sr.left + sr.width / 2),
        sashY: Math.round(sr.top + sr.height / 2),
        sashTop: Math.round(sr.top),
        sashBottom: Math.round(sr.bottom),
        auxBarLeft: Math.round(auxRect.left),
        auxBarWidth: Math.round(auxRect.width),
        windowWidth: window.innerWidth,
        isLeft: isLeft,
        debug: debug
    });
})()
"@

    $response = Send-CDPMessage -Connection $Connection -Method "Runtime.evaluate" -Params @{
        expression    = $js
        returnByValue = $true
    }

    if ($null -eq $response -or $null -eq $response.result -or $null -eq $response.result.result) {
        return $null
    }

    $value = $response.result.result.value
    if ([string]::IsNullOrEmpty($value)) {
        return $null
    }

    return $value | ConvertFrom-Json
}

function Invoke-CDPSashDrag {
    param(
        [hashtable]$Connection,
        [int]$FromX,
        [int]$FromY,
        [int]$ToX,
        [int]$ToY
    )

    # Mouse pressed at sash
    Send-CDPMessage -Connection $Connection -Method "Input.dispatchMouseEvent" -Params @{
        type       = "mousePressed"
        x          = $FromX
        y          = $FromY
        button     = "left"
        clickCount = 1
    } | Out-Null

    # Single instant move to target (no interpolation)
    Send-CDPMessage -Connection $Connection -Method "Input.dispatchMouseEvent" -Params @{
        type   = "mouseMoved"
        x      = $ToX
        y      = $FromY
        button = "left"
    } | Out-Null

    # Release
    Send-CDPMessage -Connection $Connection -Method "Input.dispatchMouseEvent" -Params @{
        type       = "mouseReleased"
        x          = $ToX
        y          = $FromY
        button     = "left"
        clickCount = 1
    } | Out-Null
}

function Set-AuxiliaryBarWidthCDP {
    param(
        [int]$TargetWidth,
        [string]$WindowTitle = "",
        [int]$ExpectedWindowWidth = 0
    )

    Write-Host "  Resizing auxiliary bar to ${TargetWidth}px via CDP..." -ForegroundColor Cyan

    $conn = Connect-CDPWebSocket -WindowTitle $WindowTitle
    if ($null -eq $conn) {
        Write-Host "    CDP not available" -ForegroundColor Yellow
        return $false
    }

    try {
        # Single query to get current sash position
        $sashInfo = Get-AuxiliaryBarSashPosition -Connection $conn

        if ($null -eq $sashInfo -or $sashInfo.error) {
            $errMsg = if ($sashInfo) { $sashInfo.error } else { "no response" }
            Write-Host "    Sash error: $errMsg" -ForegroundColor Yellow
            return $false
        }

        $currentSashX = $sashInfo.sashX
        $sashY = $sashInfo.sashY

        # Use expected window width for target calculation (don't rely on potentially stale innerWidth)
        $effectiveWidth = if ($ExpectedWindowWidth -gt 0) { $ExpectedWindowWidth } else { $sashInfo.windowWidth }
        $isLeft = $sashInfo.isLeft -eq $true

        # Same formula for both sides: sash goes to the monitor boundary
        $targetSashX = $effectiveWidth - $TargetWidth

        $side = if ($isLeft) { "LEFT" } else { "RIGHT" }
        Write-Host "    Sash at X=$currentSashX, target X=$targetSashX (panel=${TargetWidth}px on ${effectiveWidth}px, aux bar $side)" -ForegroundColor Gray

        # Already close enough?
        if ([Math]::Abs($currentSashX - $targetSashX) -le 5) {
            Write-Host "    Already at target position" -ForegroundColor Green
            return $true
        }

        Write-Host "    Dragging sash from X=$currentSashX to X=$targetSashX (Y=$sashY)" -ForegroundColor Gray

        Invoke-CDPSashDrag -Connection $conn -FromX $currentSashX -FromY $sashY -ToX $targetSashX -ToY $sashY

        Start-Sleep -Milliseconds 200

        # Verify
        $verify = Get-AuxiliaryBarSashPosition -Connection $conn
        if ($null -ne $verify -and -not $verify.error) {
            $newWidth = $verify.auxBarWidth
            Write-Host "    Auxiliary bar resized: ${currentWidth}px -> ${newWidth}px" -ForegroundColor Green
            return $true
        }

        Write-Host "    Drag sent (verification skipped)" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "    CDP error: $_" -ForegroundColor Yellow
        return $false
    } finally {
        Disconnect-CDP -Connection $conn
    }
}

# ============================================================
# VS Code CDP lifecycle management
# ============================================================

function Test-CDPAvailable {
    try {
        Invoke-RestMethod "http://localhost:$CDPPort/json" -TimeoutSec 1 -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Restart-VSCodeWithCDP {
    param([IntPtr]$hwnd)

    Write-Host "  Restarting this VS Code window with CDP flag..." -ForegroundColor Cyan

    # Gracefully close ONLY this window (WM_CLOSE, not kill all processes)
    [WinAPI]::PostMessage($hwnd, [WinAPI]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    Start-Sleep -Milliseconds 2000

    # Relaunch with CDP flag
    $codePath = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
    if (-not (Test-Path $codePath)) {
        Write-Host "    Code.exe not found" -ForegroundColor Red
        return $null
    }

    Start-Process -FilePath $codePath -ArgumentList "--remote-debugging-port=$CDPPort"

    # Wait for new VS Code window
    $waited = 0
    $newHwnd = $null
    while ($waited -lt 15000) {
        $newHwnd = Find-VSCodeWindow
        if ($null -ne $newHwnd -and $newHwnd -ne [IntPtr]::Zero -and $newHwnd -ne $hwnd) {
            break
        }
        Start-Sleep -Milliseconds 500
        $waited += 500
    }

    if ($null -eq $newHwnd -or $newHwnd -eq [IntPtr]::Zero) {
        Write-Host "    Timeout waiting for VS Code window" -ForegroundColor Yellow
        return $null
    }

    # Wait for CDP to become available
    $waited = 0
    while ($waited -lt 10000) {
        if (Test-CDPAvailable) {
            Write-Host "    CDP ready" -ForegroundColor Green
            return $newHwnd
        }
        Start-Sleep -Milliseconds 500
        $waited += 500
    }

    Write-Host "    Timeout waiting for CDP" -ForegroundColor Yellow
    return $null
}

# ============================================================
# WinAPI fallback functions (when CDP unavailable)
# ============================================================

function Move-PanelDivider {
    param(
        [int]$TargetX = 1920,
        [int]$WindowX = 0,
        [int]$WindowY = 1083,
        [int]$WindowWidth = 3840,
        [int]$WindowHeight = 953,
        [bool]$AuxBarIsLeft = $false
    )

    Write-Host "  Dragging panel divider to X=$TargetX (mouse fallback)..." -ForegroundColor Cyan

    $originalPos = New-Object WinAPI+POINT
    [WinAPI]::GetCursorPos([ref]$originalPos) | Out-Null

    $clickY = [int]($WindowY + 35 + (($WindowHeight - 60) / 2))
    if ($AuxBarIsLeft) {
        $dividerX = $WindowX + 300
    } else {
        $dividerX = $WindowX + $WindowWidth - 300
    }

    Write-Host "    Dragging from X=$dividerX to X=$TargetX, Y=$clickY" -ForegroundColor Gray

    [WinAPI]::MouseDrag($dividerX, $clickY, $TargetX, $clickY)

    [WinAPI]::SetCursorPos($originalPos.x, $originalPos.y) | Out-Null

    Write-Host "  Panel divider drag complete" -ForegroundColor Green
}

# ============================================================
# Core layout functions
# ============================================================

function Find-VSCodeWindow {
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

function Set-PanelWidth {
    param(
        [int]$Width,
        [int]$WindowX,
        [int]$WindowY,
        [int]$WindowWidth,
        [int]$WindowHeight,
        [string]$WindowTitle = "",
        [IntPtr]$WindowHandle = [IntPtr]::Zero
    )

    # Try CDP first (no cursor movement)
    $cdpResult = Set-AuxiliaryBarWidthCDP -TargetWidth $Width -WindowTitle $WindowTitle -ExpectedWindowWidth $WindowWidth
    if ($cdpResult) {
        return $true
    }

    # CDP not available — gracefully restart this VS Code window with the flag
    if ($WindowHandle -ne [IntPtr]::Zero) {
        $newHwnd = Restart-VSCodeWithCDP -hwnd $WindowHandle
        if ($null -ne $newHwnd) {
            # Reposition the new window
            [WinAPI]::ShowWindow($newHwnd, 9) | Out-Null
            [WinAPI]::MoveWindow($newHwnd, $WindowX, $WindowY, $WindowWidth, $WindowHeight, $true) | Out-Null
            [WinAPI]::SetForegroundWindow($newHwnd) | Out-Null
            Start-Sleep -Milliseconds 50

            # Get new window title
            $titleLen = [WinAPI]::GetWindowTextLength($newHwnd)
            $sb = New-Object System.Text.StringBuilder($titleLen + 1)
            [WinAPI]::GetWindowText($newHwnd, $sb, $sb.Capacity) | Out-Null
            $newTitle = $sb.ToString()

            $cdpResult = Set-AuxiliaryBarWidthCDP -TargetWidth $Width -WindowTitle $newTitle -ExpectedWindowWidth $WindowWidth
            if ($cdpResult) {
                return $true
            }
        }
    }

    # Last resort: mouse drag (try to detect side via quick CDP query)
    Write-Host "  Using mouse drag..." -ForegroundColor Yellow
    $auxIsLeft = $false
    try {
        $quickConn = Connect-CDPWebSocket -WindowTitle $WindowTitle
        if ($null -ne $quickConn) {
            $quickInfo = Get-AuxiliaryBarSashPosition -Connection $quickConn
            if ($null -ne $quickInfo -and $quickInfo.isLeft -eq $true) {
                $auxIsLeft = $true
            }
            Disconnect-CDP -Connection $quickConn
        }
    } catch {}

    # Same formula for both sides: sash at monitor boundary
    $dividerTargetX = $WindowX + $WindowWidth - $Width
    Move-PanelDivider -TargetX $dividerTargetX -WindowX $WindowX -WindowY $WindowY `
        -WindowWidth $WindowWidth -WindowHeight $WindowHeight -AuxBarIsLeft $auxIsLeft
    return $true
}

function Duplicate-VSCodeWindow {
    param([IntPtr]$hwnd)

    Write-Host "  Duplicating workspace in new window..." -ForegroundColor Cyan

    [WinAPI]::SetForegroundWindow($hwnd) | Out-Null
    Start-Sleep -Milliseconds 100

    [System.Windows.Forms.SendKeys]::SendWait("^+p")
    Start-Sleep -Milliseconds 300

    [System.Windows.Forms.SendKeys]::SendWait("Duplicate as Workspace in New Window")
    Start-Sleep -Milliseconds 300

    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")

    Write-Host "  Waiting for new window to open..." -ForegroundColor Cyan
    Start-Sleep -Milliseconds 1500

    Write-Host "  Duplicate command sent" -ForegroundColor Green
}

function Invoke-LayoutSnap {
    param(
        [switch]$DuplicateFirst
    )

    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Snapping VS Code window..."

    $hwnd = Find-VSCodeWindow

    if ($null -eq $hwnd -or $hwnd -eq [IntPtr]::Zero) {
        Write-Host "  No VS Code window found!" -ForegroundColor Yellow
        return $false
    }

    $titleLength = [WinAPI]::GetWindowTextLength($hwnd)
    $sb = New-Object System.Text.StringBuilder($titleLength + 1)
    [WinAPI]::GetWindowText($hwnd, $sb, $sb.Capacity) | Out-Null
    Write-Host "  Found: $($sb.ToString())" -ForegroundColor Cyan

    if ($DuplicateFirst) {
        Duplicate-VSCodeWindow -hwnd $hwnd

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

        Start-Sleep -Milliseconds 50

        $winTitle = $sb.ToString()
        Set-PanelWidth -Width $PanelWidth -WindowX $TargetX -WindowY $TargetY -WindowWidth $TargetWidth -WindowHeight $TargetHeight -WindowTitle $winTitle -WindowHandle $hwnd

        return $true
    } else {
        Write-Host "  Failed to reposition window!" -ForegroundColor Red
        return $false
    }
}

function Invoke-SingleMonitorLayout {
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Snapping VS Code to top monitors (auxiliary panel full)..."

    $hwnd = Find-VSCodeWindow

    if ($null -eq $hwnd -or $hwnd -eq [IntPtr]::Zero) {
        Write-Host "  No VS Code window found!" -ForegroundColor Yellow
        return $false
    }

    $titleLength = [WinAPI]::GetWindowTextLength($hwnd)
    $sb = New-Object System.Text.StringBuilder($titleLength + 1)
    [WinAPI]::GetWindowText($hwnd, $sb, $sb.Capacity) | Out-Null
    Write-Host "  Found: $($sb.ToString())" -ForegroundColor Cyan

    [WinAPI]::ShowWindow($hwnd, 9) | Out-Null

    # Move and resize to top monitors
    $result = [WinAPI]::MoveWindow($hwnd, $SingleMonitorX, $SingleMonitorY, $SingleMonitorWidth, $SingleMonitorHeight, $true)

    if ($result) {
        Write-Host "  Repositioned to: X=$SingleMonitorX, Y=$SingleMonitorY, ${SingleMonitorWidth}x${SingleMonitorHeight}" -ForegroundColor Green
        [WinAPI]::SetForegroundWindow($hwnd) | Out-Null

        Start-Sleep -Milliseconds 500

        $winTitle = $sb.ToString()
        Set-PanelWidth -Width $SinglePanelWidth -WindowX $SingleMonitorX -WindowY $SingleMonitorY -WindowWidth $SingleMonitorWidth -WindowHeight $SingleMonitorHeight -WindowTitle $winTitle -WindowHandle $hwnd

        return $true
    } else {
        Write-Host "  Failed to reposition window!" -ForegroundColor Red
        return $false
    }
}

# ============================================================
# Entry point
# ============================================================

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
$cdpStatus = if (Test-CDPAvailable) { "ACTIVE" } else { "not available (mouse drag)" }
Write-Host "  CDP:    localhost:$CDPPort - $cdpStatus"
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
    Write-Host "Hotkeys unregistered. Goodbye!" -ForegroundColor Cyan
}
