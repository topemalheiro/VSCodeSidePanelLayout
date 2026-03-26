# VS Code Side Panel Layout

Windows-only PowerShell script that snaps VS Code across dual monitors and resizes the auxiliary bar (secondary side bar) to a target width using **Chrome DevTools Protocol** -- no cursor movement.

Falls back to WinAPI mouse drag if CDP is unavailable.

## VS Code Setup (Required for CDP)

VS Code must be launched with the `--remote-debugging-port` flag for the cursor-free CDP resize to work.

### Option 1: Always launch with the flag (recommended)

Run this PowerShell script **once as administrator** to modify your VS Code shortcuts and registry entries:

```powershell
# Modify Start Menu shortcut
$WshShell = New-Object -ComObject WScript.Shell
$lnkPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Visual Studio Code\Visual Studio Code.lnk"
$shortcut = $WshShell.CreateShortcut($lnkPath)
$shortcut.Arguments = "--remote-debugging-port=9222"
$shortcut.Save()

# Modify registry for file associations ("Open with Code", double-click, etc.)
$codePath = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
$entries = @(
    "HKCU:\Software\Classes\vscode\shell\open\command",
    "HKCU:\Software\Classes\Applications\Code.exe\shell\open\command",
    "HKCU:\Software\Classes\VSCodeSourceFile\shell\open\command"
)
foreach ($key in $entries) {
    if (Test-Path $key) {
        $current = (Get-ItemProperty -Path $key).'(Default)'
        if ($current -notmatch "remote-debugging-port") {
            $updated = $current -replace '(Code\.exe")', '$1 "--remote-debugging-port=9222"'
            Set-ItemProperty -Path $key -Name '(Default)' -Value $updated
        }
    }
}
Write-Host "Done. All VS Code launches will now include --remote-debugging-port=9222"
```

> **Note:** VS Code updates may reset the Start Menu shortcut. Re-run the script above if CDP stops working after an update.

### Option 2: Launch manually from the command line

```
code --remote-debugging-port=9222
```

### Option 3: Use the CDP shortcut

Run `CreateShortcut.ps1` to create a "VS Code (CDP)" desktop shortcut.

### Verify CDP is working

Open a browser and go to `http://localhost:9222/json`. If you see JSON output listing your VS Code windows, CDP is active.

## Features

- **Ctrl+Alt+V** -- Snap VS Code to dual bottom monitors, panel at monitor boundary
- **Ctrl+Alt+N** -- Snap VS Code to top monitors, panel at monitor boundary
- **CDP sash drag** -- Resizes the auxiliary bar via Chrome DevTools Protocol (no cursor movement)
- **WinAPI fallback** -- Mouse drag when CDP is unavailable
- **Multi-window safe** -- Targets the correct VS Code window by title

## Usage

### Run as hotkey listener (background)
```powershell
powershell -ExecutionPolicy Bypass -File VSCodeSidePanelLayout.ps1
```

### One-time snap
```powershell
powershell -ExecutionPolicy Bypass -File VSCodeSidePanelLayout.ps1 -Once
```

### Duplicate window then snap
```powershell
powershell -ExecutionPolicy Bypass -File VSCodeSidePanelLayout.ps1 -Once -Duplicate
```

## Configuration

Edit these values in `VSCodeSidePanelLayout.ps1` to match your monitor setup:

```powershell
$CDPPort = 9222           # Chrome DevTools Protocol port

# Dual bottom monitors layout (Ctrl+Alt+V)
$TargetX = 0              # Window X position
$TargetY = 1083           # Window Y position
$TargetWidth = 3840       # Window width (spans 2 monitors)
$TargetHeight = 953       # Window height
$PanelWidth = 1920        # Auxiliary bar width (divider at monitor boundary)

# Top monitors layout (Ctrl+Alt+N)
$SingleMonitorX = -1360   # Window X position
$SingleMonitorY = 449     # Window Y position
$SingleMonitorWidth = 3280    # Window width
$SingleMonitorHeight = 583    # Window height
$SinglePanelWidth = 1920      # Auxiliary bar width (divider at monitor boundary)
```

## Files

| File | Purpose |
|------|---------|
| `VSCodeSidePanelLayout.ps1` | Main script (CDP sash drag + WinAPI fallback + hotkeys) |
| `CreateShortcut.ps1` | Creates desktop shortcuts (layout script + VS Code CDP) |
| `set_panel_width.py` | Python helper to set auxiliary bar width in state.vscdb (pre-launch only) |

## How it works

1. Registers global hotkeys (`Ctrl+Alt+V`, `Ctrl+Alt+N`) via WinAPI
2. On hotkey press, finds the active VS Code window by title
3. Repositions and resizes the window with `MoveWindow`
4. Connects to VS Code's Chromium renderer via CDP WebSocket on port 9222
5. Queries the DOM to find the `.monaco-sash.vertical` element adjacent to `#workbench.parts.auxiliarybar`
6. Dispatches `Input.dispatchMouseEvent` (press, move, release) to drag the sash to the target position
7. If CDP is unavailable, falls back to WinAPI `SendInput` mouse drag (moves the real cursor briefly)

## License

GNU AGPL v3
