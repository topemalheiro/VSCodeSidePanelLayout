# VS Code Side Panel Layout — snap VS Code windows and side panel when on a duplicated window.

This script is Windows only. Requires Python 3 (for SQLite state.vscdb manipulation).

PowerShell script to snap VS Code window across dual monitors and side panel snapped to a position *only* when duplicating a window.
 You must change the screens' coordinates to your liking, as in: "with side panel snapped on the right(...)"; This only works when you Command Palette Trigger 'Ctrl+Shift+P' Workspaces: Duplicate As Workspace in New Window — there still needs to be an update to detect when it's a new window that is not snapped.

If the coordinates for the duplicated window aren't the same on your screen/instance, you'll have to update them.

## How it works

The script sets the auxiliary bar (secondary side bar) width by writing directly to VS Code's SQLite state database (`state.vscdb`) via a Python helper script. This is pixel-precise and requires no mouse simulation or manual interaction.

## Features

- **Hotkey**: `Ctrl+Alt+V` snaps current VS Code window
- **Window positioning**: Spans two bottom monitors (3840x953 at 0,1083)
- **Panel width**: Sets auxiliary bar width via direct SQLite DB write (no mouse drag)
- **Duplicate option**: Can duplicate workspace before snapping
- **There's also 'Ctrl+Alt+N' for another setup across another 2 dual screens.

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

### Set panel width directly (Python helper)
```powershell
python set_panel_width.py 1920
```

## Installation

1. Ensure Python 3 is installed and in PATH
2. Run `CreateShortcut.ps1` to create a desktop shortcut

## Configuration

Edit these values in `VSCodeSidePanelLayout.ps1` to match your monitor setup:

```powershell
$TargetX = 0          # Window X position
$TargetY = 1083       # Window Y position
$TargetWidth = 3840   # Window width (spans 2 monitors)
$TargetHeight = 953   # Window height
$PanelWidth = 1920    # Auxiliary bar width in pixels (dual layout)
$SinglePanelWidth = 3180  # Auxiliary bar width (single/top layout)
```

## Files

- `VSCodeSidePanelLayout.ps1` - Main script (window positioning + hotkeys)
- `set_panel_width.py` - Python helper to set auxiliary bar width in state.vscdb
- `CreateShortcut.ps1` - Creates desktop shortcut
