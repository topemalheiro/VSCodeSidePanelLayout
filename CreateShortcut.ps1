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

# Create VS Code shortcut with CDP debug port enabled
$vscodeExe = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
if (Test-Path $vscodeExe) {
    $vscodeLnkPath = "$env:USERPROFILE\Desktop\VS Code (CDP).lnk"
    $vscodeShortcut = $WshShell.CreateShortcut($vscodeLnkPath)
    $vscodeShortcut.TargetPath = $vscodeExe
    $vscodeShortcut.Arguments = "--remote-debugging-port=9222"
    $vscodeShortcut.Description = "VS Code with Chrome DevTools Protocol on port 9222"
    $vscodeShortcut.Save()
    Write-Host "VS Code CDP shortcut created: $vscodeLnkPath" -ForegroundColor Green
} else {
    Write-Host "VS Code not found at $vscodeExe - skipping CDP shortcut" -ForegroundColor Yellow
}
