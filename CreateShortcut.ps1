$WshShell = New-Object -ComObject WScript.Shell

$scriptPath = "C:\Users\topem\Scripts\VSCodeSidePanelLayout\VSCodeSidePanelLayout.ps1"
$workingDir = "C:\Users\topem\Scripts\VSCodeSidePanelLayout"
$shortcutName = "VS Code Side Panel Layout.lnk"
$description = "VS Code Side Panel Layout (Ctrl+Alt+V dual, Ctrl+Alt+N single)"
$arguments = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""

# Create Desktop shortcut
$desktopPath = "$env:USERPROFILE\Desktop\$shortcutName"
$desktopShortcut = $WshShell.CreateShortcut($desktopPath)
$desktopShortcut.TargetPath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
$desktopShortcut.Arguments = $arguments
$desktopShortcut.WorkingDirectory = $workingDir
$desktopShortcut.Description = $description
$desktopShortcut.Save()
Write-Host "Desktop shortcut created: $desktopPath" -ForegroundColor Green

# Create Startup shortcut (runs on login)
$startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\$shortcutName"
$startupShortcut = $WshShell.CreateShortcut($startupPath)
$startupShortcut.TargetPath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
$startupShortcut.Arguments = $arguments
$startupShortcut.WorkingDirectory = $workingDir
$startupShortcut.Description = $description
$startupShortcut.Save()
Write-Host "Startup shortcut created: $startupPath" -ForegroundColor Green

Write-Host "`nThe script will now run automatically on login." -ForegroundColor Cyan
