# VS Code Side Panel Layout — snap VS Code windows and side panel when on a duplicated window.

This script is Windows only.

PowerShell script to snap VS Code window across dual monitors and side panel snapped to a position *only* when duplicating a window.
 You must change the screens' coordinates to your liking, as in: "with side panel snapped on the right(...)"; This only works when you Command Palette Trigger 'Ctrl+Shift+P' Workspaces: Duplicate As Workspace in New Window — there still needs to be an update to detect when it's a new window that is not snapped.

If the coordinates for the duplicated window aren't the same on your screen/instance, you'll have to update them.

## Features

- **Hotkey**: `Ctrl+Alt+V` snaps current VS Code window
- **Window positioning**: Spans two bottom monitors (3840x953 at 0,1083)
- **Panel divider**: Drags side panel divider to center (X=1920)
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

## Installation

1. Run `CreateShortcut.ps1` to create a desktop shortcut
2. Optionally add the shortcut to `shell:startup` for auto-run on login

## Configuration

Edit these values in `VSCodeSidePanelLayout.ps1` to match your monitor setup:

```powershell
$TargetX = 0          # Window X position
$TargetY = 1083       # Window Y position
$TargetWidth = 3840   # Window width (spans 2 monitors)
$TargetHeight = 953   # Window height
$DividerTargetX = 1920  # Panel divider position (center)
```

## Files

- `VSCodeSidePanelLayout.ps1` - Main script
- `CreateShortcut.ps1` - Creates desktop shortcut
