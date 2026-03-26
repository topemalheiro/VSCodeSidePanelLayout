# VS Code Side Panel Layout — snap VS Code windows and side panel when on a duplicated window.

This script is Windows only.

PowerShell script to snap VS Code window across dual monitors and side panel snapped to a position *only* when duplicating a window.
 You must change the screens' coordinates to your liking, as in: "with side panel snapped on the right(...)"; This only works when you Command Palette Trigger 'Ctrl+Shift+P' Workspaces: Duplicate As Workspace in New Window — there still needs to be an update to detect when it's a new window that is not snapped.

If the coordinates for the duplicated window aren't the same on your screen/instance, you'll have to update them.

## How it works

The script resizes VS Code's auxiliary bar (secondary side bar) using **Chrome DevTools Protocol (CDP)**. It connects to VS Code's Chromium renderer via WebSocket, finds the sash divider element in the DOM, and dispatches synthetic mouse drag events to resize it — **without moving the real OS cursor**.

If CDP is unavailable (VS Code wasn't launched with `--remote-debugging-port`), it falls back to WinAPI mouse drag.

## Features

- **Hotkey**: `Ctrl+Alt+V` snaps current VS Code window (dual bottom monitors)
- **Hotkey**: `Ctrl+Alt+N` snaps to top monitors with maximized panel
- **Window positioning**: Spans two bottom monitors (3840x953 at 0,1083)
- **Panel width**: CDP sash drag (pixel-precise, no cursor movement)
- **Fallback**: WinAPI mouse drag when CDP unavailable
- **Duplicate option**: Can duplicate workspace before snapping

## Prerequisites

Launch VS Code with the Chrome DevTools Protocol flag:

```
code --remote-debugging-port=9222
```

Or use the "VS Code (CDP)" desktop shortcut created by `CreateShortcut.ps1`.

## Usage

### One-time snap (testing)
```powershell
powershell -ExecutionPolicy Bypass -File VSCodeSidePanelLayout.ps1 -Once
```

### Duplicate window then snap
```powershell
powershell -ExecutionPolicy Bypass -File VSCodeSidePanelLayout.ps1 -Once -Duplicate
```

### Run as hotkey listener (background)
```powershell
powershell -ExecutionPolicy Bypass -File VSCodeSidePanelLayout.ps1
```

## Installation

1. Run `CreateShortcut.ps1` to create desktop shortcuts (layout script + VS Code CDP)
2. Launch VS Code via the "VS Code (CDP)" shortcut

## Configuration

Edit these values in `VSCodeSidePanelLayout.ps1` to match your monitor setup:

```powershell
$CDPPort = 9222       # Chrome DevTools Protocol port
$TargetX = 0          # Window X position
$TargetY = 1083       # Window Y position
$TargetWidth = 3840   # Window width (spans 2 monitors)
$TargetHeight = 953   # Window height
$PanelWidth = 1920    # Auxiliary bar width in pixels (dual layout)
$SinglePanelWidth = 3180  # Auxiliary bar width (single/top layout)
```

## Files

- `VSCodeSidePanelLayout.ps1` - Main script (CDP sash drag + WinAPI fallback + hotkeys)
- `CreateShortcut.ps1` - Creates desktop shortcuts (layout script + VS Code CDP)
- `set_panel_width.py` - Python helper to set auxiliary bar width in state.vscdb (pre-launch only)
