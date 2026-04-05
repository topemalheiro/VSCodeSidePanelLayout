# VS Code Side Panel Layout

Windows-only PowerShell script that snaps VS Code across dual monitors and resizes the auxiliary bar (secondary side bar) to a target width using **Chrome DevTools Protocol** -- no cursor movement.

Falls back to WinAPI mouse drag if CDP is unavailable.

## VS Code Setup (Required for CDP)

VS Code needs this in `argv.json` for the cursor-free CDP resize to work:

```json
"remote-debugging-port": "9222"
```

Open `Preferences: Configure Runtime Arguments` in VS Code, then make sure your `argv.json` contains that exact entry as a string.

On Windows, the file is usually:

```text
C:\Users\<you>\.vscode\argv.json
```

Example:

```jsonc
// NOTE: Changing this file requires a restart of VS Code.
{
  "remote-debugging-port": "9222"
}
```

After changing `argv.json`, fully restart VS Code before using the layout script.

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
| `CreateShortcut.ps1` | Creates a desktop shortcut for the layout listener |
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
