# VS Code Side Panel Layout Script
# Hotkey: Ctrl+Alt+V (dual monitor), Ctrl+Alt+N (top monitors)
# Snaps VS Code window and resizes auxiliary bar via CDP sash drag (no cursor movement)
# Trusts the live CDP endpoint/targets and keeps current windows open if CDP is not ready yet
# reprompty-mcp: {"toolName":"dual_monitor_layout_bottom","label":"Dual monitor layout (bottom)","description":"Run the Ctrl+Alt+V dual monitor bottom layout","args":["-Once"]}
# reprompty-mcp: {"toolName":"top_monitors_layout_panel_full","label":"Top monitors layout (panel full)","description":"Run the Ctrl+Alt+N top monitors panel-full layout","args":["-SingleOnce"]}

param(
    [switch]$Once,       # Run Ctrl+Alt+V layout once (dual monitors bottom)
    [switch]$SingleOnce, # Run Ctrl+Alt+N layout once (top monitors)
    [switch]$Duplicate,  # Duplicate window first, then snap
    [string]$WindowTitle = "",  # Target a specific VS Code window by title
    [Int64]$WindowHandle = 0,   # Target a specific VS Code window by exact handle
    [string]$LogPath = "",      # Optional per-run layout transcript path
    [switch]$RepairOnly,        # Internal: run fast-check-first repair and exit
    [string]$RepairTriggerSource = "manual", # Internal repair trigger source
    [switch]$StartupRepairOnly, # Re-apply CDP launch hooks and exit
    [switch]$InstallStartup,    # Install startup repair entry
    [switch]$UninstallStartup   # Remove startup repair entry
)

# ============================================================
# Ensure VS Code always launches with --remote-debugging-port
# Uses a hybrid wrapper install:
# - swaps install-path Code.exe with a forwarding wrapper for first-launch coverage
# - keeps stable external shims and shell overrides for update repair
# ============================================================

$CDPPort = 9222
$cdpFlag = "--remote-debugging-port=$CDPPort"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptPath = $MyInvocation.MyCommand.Path
$StartupRunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$StartupValueName = "VSCodeSidePanelLayoutCDPRepair"
$PowerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$UserEnvironmentKey = "HKCU:\Environment"
$UserPathBackupValueName = "VSCodeSidePanelLayoutPathBackup"
$UserTempPath = Join-Path $env:LOCALAPPDATA "Temp"
$CodeInstallDir = Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code"
$ManagedCodePath = Join-Path $CodeInstallDir "Code.exe"
$ManagedRealCodePath = Join-Path $CodeInstallDir "Code.real.exe"
$PendingRealCodePath = Join-Path $CodeInstallDir "Code.real.pending.exe"
$ManagedMarkerPath = Join-Path $CodeInstallDir "Code.cdp-wrapper.marker"
$RepairLogDir = Join-Path $env:LOCALAPPDATA "VSCodeSidePanelLayout"
$RepairLogPath = Join-Path $RepairLogDir "repair.log"
$VSCodeArgvJsonPath = Join-Path $env:USERPROFILE ".vscode\argv.json"
$ShimDir = Join-Path $env:LOCALAPPDATA "CodeCDPShim"
$ShimExePath = Join-Path $ShimDir "code.exe"
$ShimCmdPath = Join-Path $ShimDir "code.cmd"
$WrapperSrcPath = Join-Path $ScriptDir "CodeCDPWrapper.cs"
$WrapperExePath = Join-Path $ScriptDir "CodeCDPWrapper.exe"
$WrapperIconPath = Join-Path $ScriptDir "CodeCDPWrapper.ico"
$IfeoKey = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Code.exe"
$DevToolsActivePortPath = Join-Path $env:APPDATA "Code\DevToolsActivePort"
$IntegrityPollIntervalMs = 2000
$RepairDebounceMs = 5000
$RepairMutexName = "Local\VSCodeSidePanelLayoutCDPRepair"
$script:LastIntegrityPollAt = [DateTime]::MinValue
$script:LastDriftRepairAt = [DateTime]::MinValue
$script:LastDriftSignature = ""
$script:LastRepairLockNoticeAt = [DateTime]::MinValue

function Write-RepairLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    try {
        New-Item -ItemType Directory -Path $RepairLogDir -Force -ErrorAction SilentlyContinue | Out-Null
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        Add-Content -LiteralPath $RepairLogPath -Value "[$timestamp] [$Level] $Message" -Encoding UTF8
    } catch {
        # Logging should never block repair.
    }
}

$script:LayoutTranscriptActive = $false

function Start-LayoutRunLogging {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    try {
        $parentDir = Split-Path -Parent $Path
        if (-not [string]::IsNullOrWhiteSpace($parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction SilentlyContinue | Out-Null
        }

        Start-Transcript -Path $Path -Force | Out-Null
        $script:LayoutTranscriptActive = $true
        Write-Host "  Layout transcript: $Path" -ForegroundColor DarkGray
    } catch {
        Write-RepairLog "Failed to start layout transcript at '$Path': $($_.Exception.Message)" "WARN"
    }
}

function Stop-LayoutRunLogging {
    if (-not $script:LayoutTranscriptActive) {
        return
    }

    try {
        Stop-Transcript | Out-Null
    } catch {
        Write-RepairLog "Failed to stop layout transcript: $($_.Exception.Message)" "WARN"
    } finally {
        $script:LayoutTranscriptActive = $false
    }
}

function Get-VSCodeArgvJsonStatus {
    $fileExists = Test-Path -LiteralPath $VSCodeArgvJsonPath
    $rawValue = ""
    $matchesPort = $false
    $errorMessage = ""

    if ($fileExists) {
        try {
            $content = Get-Content -LiteralPath $VSCodeArgvJsonPath -Raw -ErrorAction Stop
            $match = [regex]::Match($content, '"remote-debugging-port"\s*:\s*"(?<port>[^"]+)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($match.Success) {
                $rawValue = $match.Groups['port'].Value
            }

            $matchesPort = $rawValue -eq "$CDPPort"
        } catch {
            $errorMessage = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        Path = $VSCodeArgvJsonPath
        FileExists = $fileExists
        RawValue = $rawValue
        MatchesPort = $matchesPort
        ErrorMessage = $errorMessage
    }
}

function Ensure-VSCodeArgvJsonPort {
    $parentDir = Split-Path -Parent $VSCodeArgvJsonPath
    New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction SilentlyContinue | Out-Null
    $fileAlreadyExists = Test-Path -LiteralPath $VSCodeArgvJsonPath

    $rawContent =
        if ($fileAlreadyExists) {
            Get-Content -LiteralPath $VSCodeArgvJsonPath -Raw -ErrorAction Stop
        } else {
@"
// This configuration file allows you to pass permanent command line arguments to VS Code.
// Only a subset of arguments is currently supported to reduce the likelihood of breaking
// the installation.
//
// PLEASE DO NOT CHANGE WITHOUT UNDERSTANDING THE IMPACT
//
// NOTE: Changing this file requires a restart of VS Code.
{
	"remote-debugging-port": "$CDPPort"
}
"@
        }

    $updatedContent = $rawContent
    $desiredProperty = ('"remote-debugging-port": "{0}"' -f $CDPPort)
    $existingPropertyPattern = '"remote-debugging-port"\s*:\s*(?:"[^"]*"|\d+)'

    if ([regex]::IsMatch($updatedContent, $existingPropertyPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $updatedContent = [regex]::Replace(
            $updatedContent,
            $existingPropertyPattern,
            $desiredProperty,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    } else {
        $newline = if ($updatedContent -match "`r`n") { "`r`n" } else { "`n" }
        $contentWithoutLineComments = [regex]::Replace($updatedContent, '(?m)^\s*//.*$', '')
        $hasAnyProperty = $contentWithoutLineComments -match '"[^"]+"\s*:'
        $commaPrefix = if ($hasAnyProperty) { "," } else { "" }
        $insertion = "$commaPrefix$newline`t$desiredProperty$newline"
        $updatedContent = [regex]::Replace($updatedContent.TrimEnd(), '\}\s*$', "$insertion}", 1)
    }

    if (($updatedContent -ne $rawContent) -or -not $fileAlreadyExists) {
        Set-Content -LiteralPath $VSCodeArgvJsonPath -Value $updatedContent -Encoding Ascii
        return $true
    }

    return $false
}

function Invoke-VSCodeArgvJsonEnsure {
    param(
        [string]$TriggerSource = "manual",
        [switch]$WriteConsoleNotice
    )

    try {
        $updated = Ensure-VSCodeArgvJsonPort
        $status = Get-VSCodeArgvJsonStatus

        if ($updated) {
            Write-RepairLog "Ensured argv.json remote-debugging-port for source '$TriggerSource'."
            if ($WriteConsoleNotice) {
                Write-Host "  Ensured argv.json remote-debugging-port=$CDPPort before evaluating CDP health..." -ForegroundColor DarkGray
            }
        }

        return [pscustomobject]@{
            Updated = $updated
            Status = $status
            ErrorMessage = ""
        }
    } catch {
        $errorMessage = $_.Exception.Message
        Write-RepairLog "Failed to ensure argv.json for source '$TriggerSource': $errorMessage" "WARN"

        return [pscustomobject]@{
            Updated = $false
            Status = Get-VSCodeArgvJsonStatus
            ErrorMessage = $errorMessage
        }
    }
}

function Format-RepairElapsed {
    param([System.Diagnostics.Stopwatch]$Stopwatch)

    if ($null -eq $Stopwatch) {
        return "0 ms"
    }

    return "$($Stopwatch.ElapsedMilliseconds) ms"
}

function Test-CDPRepairInProgress {
    $mutex = $null
    $lockAcquired = $false

    try {
        $mutex = New-Object System.Threading.Mutex($false, $RepairMutexName)
        try {
            $lockAcquired = $mutex.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
        }

        if ($lockAcquired) {
            $mutex.ReleaseMutex()
            return $false
        }

        return $true
    } finally {
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

function Invoke-CDPLaunchRepairCore {
    param(
        [string]$TriggerSource,
        [string[]]$DetectionReasons = @()
    )

    $mutex = $null
    $lockAcquired = $false

    try {
        $mutex = New-Object System.Threading.Mutex($false, $RepairMutexName)
        try {
            $lockAcquired = $mutex.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
        }

        if (-not $lockAcquired) {
            Write-RepairLog "Repair already in progress; source=$TriggerSource reused the in-flight repair."
            return "locked"
        }

        Install-CDPLaunchHooks -Quiet -TriggerSource $TriggerSource -DetectionReasons $DetectionReasons
        return "completed"
    } catch {
        Write-RepairLog "Repair execution failed for source '$TriggerSource': $($_.Exception.Message)" "ERROR"
        return "failed"
    } finally {
        if ($lockAcquired -and $null -ne $mutex) {
            try {
                $mutex.ReleaseMutex()
            } catch {
                # Ignore release issues during shutdown.
            }
        }

        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

function Start-CDPBackgroundRepair {
    param([string]$TriggerSource)

    try {
        $process = Start-Process -FilePath $PowerShellExe -ArgumentList @(
            "-NoProfile",
            "-WindowStyle", "Hidden",
            "-ExecutionPolicy", "Bypass",
            "-File", $ScriptPath,
            "-RepairOnly",
            "-RepairTriggerSource", $TriggerSource
        ) -WindowStyle Hidden -PassThru

        Write-RepairLog "Queued background repair process $($process.Id) for trigger '$TriggerSource'."
        return $true
    } catch {
        Write-RepairLog "Failed to queue background repair for '$TriggerSource': $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Write-ManagedInstallMarker {
    Set-Content -LiteralPath $ManagedMarkerPath -Value "Managed by VSCodeSidePanelLayout" -Encoding Ascii
}

function Get-ManagedShortcutPaths {
    return @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Visual Studio Code\Visual Studio Code.lnk",
        "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Visual Studio Code.lnk",
        "$env:USERPROFILE\Desktop\Visual Studio Code.lnk"
    )
}

function Get-ExpectedShellCommandDefinitions {
    param([string]$WrapperExe)

    return @(
        [pscustomobject]@{ KeyPath = "HKCU:\Software\Classes\Applications\Code.exe\shell\open\command"; CommandValue = ('"{0}" "%1"' -f $WrapperExe) },
        [pscustomobject]@{ KeyPath = "HKCU:\Software\Classes\VSCodeSourceFile\shell\open\command"; CommandValue = ('"{0}" "%1"' -f $WrapperExe) },
        [pscustomobject]@{ KeyPath = "HKCU:\Software\Classes\Directory\shell\VSCode\command"; CommandValue = ('"{0}" "%V"' -f $WrapperExe) },
        [pscustomobject]@{ KeyPath = "HKCU:\Software\Classes\Directory\Background\shell\VSCode\command"; CommandValue = ('"{0}" "%V"' -f $WrapperExe) }
    )
}

function Promote-PendingRealCode {
    if (-not (Test-Path -LiteralPath $PendingRealCodePath)) {
        return $false
    }

    if ((Test-Path -LiteralPath $ManagedRealCodePath) -and (Test-FilesMatch -PathA $PendingRealCodePath -PathB $ManagedRealCodePath)) {
        Remove-Item -LiteralPath $PendingRealCodePath -Force -ErrorAction SilentlyContinue
        Write-RepairLog "Removed redundant staged Code.real pending update because it already matches Code.real.exe."
        return $true
    }

    try {
        Copy-Item -LiteralPath $PendingRealCodePath -Destination $ManagedRealCodePath -Force -ErrorAction Stop
        Remove-Item -LiteralPath $PendingRealCodePath -Force -ErrorAction SilentlyContinue
        Write-RepairLog "Promoted staged Code.real pending update into Code.real.exe."
        return $true
    } catch {
        Write-RepairLog "Deferred staged Code.real pending update: $($_.Exception.Message)"
        return $false
    }
}

function Test-FilesMatch {
    param(
        [string]$PathA,
        [string]$PathB
    )

    if (-not (Test-Path -LiteralPath $PathA) -or -not (Test-Path -LiteralPath $PathB)) {
        return $false
    }

    try {
        $hashA = (Get-FileHash -LiteralPath $PathA -Algorithm SHA256).Hash
        $hashB = (Get-FileHash -LiteralPath $PathB -Algorithm SHA256).Hash
        return $hashA -eq $hashB
    } catch {
        return $false
    }
}

function Test-IsVSCodeBinary {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        return (
            $info.FileDescription -eq "Visual Studio Code" -or
            $info.ProductName -eq "Visual Studio Code" -or
            $info.OriginalFilename -eq "electron.exe"
        )
    } catch {
        return $false
    }
}

function Ensure-UsableTempEnvironment {
    param([switch]$PersistUserVariables)

    New-Item -ItemType Directory -Path $UserTempPath -Force -ErrorAction SilentlyContinue | Out-Null

    $env:TEMP = $UserTempPath
    $env:TMP = $UserTempPath

    if ($PersistUserVariables) {
        New-Item -Path $UserEnvironmentKey -Force -ErrorAction SilentlyContinue | Out-Null
        $existingTemp = [Environment]::GetEnvironmentVariable("TEMP", "User")
        $existingTmp = [Environment]::GetEnvironmentVariable("TMP", "User")

        if ([string]::IsNullOrWhiteSpace($existingTemp) -or $existingTemp -ieq "C:\Windows\TEMP") {
            New-ItemProperty -Path $UserEnvironmentKey -Name TEMP -Value $UserTempPath -PropertyType String -Force | Out-Null
        }

        if ([string]::IsNullOrWhiteSpace($existingTmp) -or $existingTmp -ieq "C:\Windows\TEMP") {
            New-ItemProperty -Path $UserEnvironmentKey -Name TMP -Value $UserTempPath -PropertyType String -Force | Out-Null
        }
    }
}

function Ensure-CodeWrapperIcon {
    $iconSourcePath = $null
    if (Test-Path -LiteralPath $ManagedRealCodePath) {
        $iconSourcePath = $ManagedRealCodePath
    } elseif (Test-IsVSCodeBinary -Path $ManagedCodePath) {
        $iconSourcePath = $ManagedCodePath
    }

    if ([string]::IsNullOrWhiteSpace($iconSourcePath)) {
        return $null
    }

    $needsRefresh =
        -not (Test-Path -LiteralPath $WrapperIconPath) -or
        (Get-Item -LiteralPath $iconSourcePath).LastWriteTime -gt (Get-Item -LiteralPath $WrapperIconPath).LastWriteTime

    if ($needsRefresh) {
        Add-Type -AssemblyName System.Drawing
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconSourcePath)
        if ($null -ne $icon) {
            $stream = [System.IO.File]::Create($WrapperIconPath)
            try {
                $icon.Save($stream)
            } finally {
                $stream.Dispose()
                $icon.Dispose()
            }
        }
    }

    if (Test-Path -LiteralPath $WrapperIconPath) {
        return $WrapperIconPath
    }

    return $null
}

function Ensure-CodeWrapperCompiled {
    param([switch]$Quiet)

    $cscPath = Join-Path $env:SystemRoot "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    $iconPath = Ensure-CodeWrapperIcon

    if (-not (Test-Path -LiteralPath $WrapperSrcPath)) {
        throw "Wrapper source not found: $WrapperSrcPath"
    }

    if (-not (Test-Path -LiteralPath $cscPath)) {
        throw "C# compiler not found: $cscPath"
    }

    $needsCompile =
        -not (Test-Path -LiteralPath $WrapperExePath) -or
        (Get-Item -LiteralPath $WrapperSrcPath).LastWriteTime -gt (Get-Item -LiteralPath $WrapperExePath).LastWriteTime -or
        ($iconPath -and (Test-Path -LiteralPath $iconPath) -and ((Get-Item -LiteralPath $iconPath).LastWriteTime -gt (Get-Item -LiteralPath $WrapperExePath).LastWriteTime))

    if ($needsCompile) {
        $compileArgs = @(
            "-nologo",
            "-target:winexe",
            "-out:$WrapperExePath"
        )

        if ($iconPath) {
            $compileArgs += "-win32icon:$iconPath"
        }

        $compileArgs += $WrapperSrcPath
        & $cscPath @compileArgs 2>$null
    }

    if (-not (Test-Path -LiteralPath $WrapperExePath)) {
        throw "Wrapper executable was not produced: $WrapperExePath"
    }

    return $WrapperExePath
}

function Get-CodeInstallState {
    param([string]$SourceWrapperExe)

    $managedCodeExists = Test-Path -LiteralPath $ManagedCodePath
    $managedRealExists = Test-Path -LiteralPath $ManagedRealCodePath
    $markerExists = Test-Path -LiteralPath $ManagedMarkerPath

    $managedCodeIsWrapper = $false
    $managedCodeIsVSCode = $false
    $managedRealIsVSCode = $false

    if ($managedCodeExists) {
        $managedCodeIsWrapper = Test-FilesMatch -PathA $ManagedCodePath -PathB $SourceWrapperExe
        $managedCodeIsVSCode = Test-IsVSCodeBinary -Path $ManagedCodePath
    }

    if ($managedRealExists) {
        $managedRealIsVSCode = Test-IsVSCodeBinary -Path $ManagedRealCodePath
    }

    $state = switch ($true) {
        { $managedCodeExists -and $managedCodeIsWrapper -and $managedRealExists -and $managedRealIsVSCode -and $markerExists } { "managed"; break }
        { $managedCodeExists -and $managedCodeIsWrapper -and $managedRealExists -and $managedRealIsVSCode -and -not $markerExists } { "managed-marker-missing"; break }
        { -not $managedCodeExists -and $managedRealExists -and $managedRealIsVSCode } { "managed-code-missing"; break }
        { $managedCodeExists -and $managedCodeIsVSCode -and $managedRealExists -and $managedRealIsVSCode } { "managed-overwritten"; break }
        { $managedCodeExists -and $managedCodeIsVSCode -and -not $managedRealExists -and -not $markerExists } { "unmanaged"; break }
        { $managedCodeExists -and $managedCodeIsWrapper -and -not $managedRealExists } { "wrapper-without-real"; break }
        { -not $managedCodeExists -and -not $managedRealExists } { "missing-install"; break }
        default { "unknown" }
    }

    return [pscustomobject]@{
        State = $state
        ManagedCodeExists = $managedCodeExists
        ManagedRealExists = $managedRealExists
        MarkerExists = $markerExists
        ManagedCodeIsWrapper = $managedCodeIsWrapper
        ManagedCodeIsVSCode = $managedCodeIsVSCode
        ManagedRealIsVSCode = $managedRealIsVSCode
    }
}

function Install-CodeExeSwap {
    param(
        [string]$SourceWrapperExe,
        [switch]$Quiet
    )

    Promote-PendingRealCode | Out-Null

    $stateBefore = Get-CodeInstallState -SourceWrapperExe $SourceWrapperExe
    Write-RepairLog "Install state before repair: $($stateBefore.State)"

    switch ($stateBefore.State) {
        "managed" {
            Write-RepairLog "Managed state already healthy."
        }
        "managed-marker-missing" {
            Write-ManagedInstallMarker
            Write-RepairLog "Marker file restored for managed state."
        }
        "managed-code-missing" {
            Copy-Item -LiteralPath $SourceWrapperExe -Destination $ManagedCodePath -Force -ErrorAction Stop
            Write-ManagedInstallMarker
            Write-RepairLog "Restored missing managed Code.exe wrapper."
        }
        "managed-overwritten" {
            if (Test-FilesMatch -PathA $ManagedCodePath -PathB $ManagedRealCodePath) {
                Remove-Item -LiteralPath $PendingRealCodePath -Force -ErrorAction SilentlyContinue
                Write-RepairLog "Managed-overwritten payload already matches Code.real.exe; staging skipped."
            } else {
                Copy-Item -LiteralPath $ManagedCodePath -Destination $PendingRealCodePath -Force -ErrorAction Stop
                try {
                    Copy-Item -LiteralPath $ManagedCodePath -Destination $ManagedRealCodePath -Force -ErrorAction Stop
                    Remove-Item -LiteralPath $PendingRealCodePath -Force -ErrorAction SilentlyContinue
                    Write-RepairLog "Promoted overwritten Code.exe payload into Code.real.exe."
                } catch {
                    Write-RepairLog "Code.real.exe is in use; staged updated real binary at $PendingRealCodePath for later promotion."
                }
            }
            Copy-Item -LiteralPath $SourceWrapperExe -Destination $ManagedCodePath -Force -ErrorAction Stop
            Write-ManagedInstallMarker
            Write-RepairLog "Recovered from update overwrite and restored managed wrapper."
        }
        "unmanaged" {
            Move-Item -LiteralPath $ManagedCodePath -Destination $ManagedRealCodePath -Force -ErrorAction Stop
            Copy-Item -LiteralPath $SourceWrapperExe -Destination $ManagedCodePath -Force -ErrorAction Stop
            Write-ManagedInstallMarker
            Write-RepairLog "Promoted unmanaged install into managed wrapper state."
        }
        "wrapper-without-real" {
            Write-RepairLog "Wrapper exists without Code.real.exe; repair cannot continue safely." "ERROR"
            throw "Managed wrapper exists without Code.real.exe. Manual recovery is required."
        }
        "missing-install" {
            Write-RepairLog "VS Code install missing from expected root." "ERROR"
            throw "VS Code install not found at $CodeInstallDir"
        }
        default {
            Write-RepairLog "Unknown install state; refusing blind repair." "ERROR"
            throw "Unrecognized VS Code install state. Manual recovery is required."
        }
    }

    $stateAfter = Get-CodeInstallState -SourceWrapperExe $SourceWrapperExe
    Write-RepairLog "Install state after repair: $($stateAfter.State)"

    if ($stateAfter.State -ne "managed") {
        throw "Managed install state was not restored. Current state: $($stateAfter.State)"
    }

    return $stateAfter
}

function Install-CodeShims {
    param(
        [string]$SourceWrapperExe,
        [switch]$Quiet
    )

    $realCliCmd = Join-Path $CodeInstallDir "bin\code.cmd"
    if (-not (Test-Path -LiteralPath $realCliCmd)) {
        throw "VS Code CLI not found at $realCliCmd"
    }

    New-Item -ItemType Directory -Path $ShimDir -Force -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath $SourceWrapperExe -Destination $ShimExePath -Force -ErrorAction Stop

    $shimContent = @(
        "@echo off",
        "setlocal",
        "call `"$realCliCmd`" --remote-debugging-port=9222 %*",
        "set EXITCODE=%ERRORLEVEL%",
        "endlocal & exit /b %EXITCODE%"
    ) -join "`r`n"

    Set-Content -LiteralPath $ShimCmdPath -Value $shimContent -Encoding Ascii
}

function Broadcast-EnvironmentChange {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class EnvironmentBroadcast {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint Msg,
        UIntPtr wParam,
        string lParam,
        uint fuFlags,
        uint uTimeout,
        out UIntPtr lpdwResult
    );
}
"@ -ErrorAction SilentlyContinue

    $result = [UIntPtr]::Zero
    [void][EnvironmentBroadcast]::SendMessageTimeout(
        [IntPtr]0xffff,
        0x001A,
        [UIntPtr]::Zero,
        "Environment",
        0x0002,
        5000,
        [ref]$result
    )
}

function Get-DerivedUserPathSegments {
    param([string]$PrefixPath)

    $machineSegments = @(
        [Environment]::GetEnvironmentVariable("Path", "Machine") -split ';' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $machineSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($segment in $machineSegments) {
        [void]$machineSet.Add($segment.TrimEnd('\'))
    }

    $derivedSegments = @()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($segment in ($env:Path -split ';')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }

        $normalizedSegment = $segment.TrimEnd('\')
        if (
            $normalizedSegment -ieq $PrefixPath.TrimEnd('\') -or
            $normalizedSegment -ieq $CodeInstallDir.TrimEnd('\') -or
            $normalizedSegment -like "$($env:USERPROFILE)\.codex\tmp\*"
        ) {
            continue
        }

        if ($machineSet.Contains($normalizedSegment) -or $seen.Contains($normalizedSegment)) {
            continue
        }

        [void]$seen.Add($normalizedSegment)
        $derivedSegments += $segment
    }

    return $derivedSegments
}

function Ensure-UserPathPrefix {
    param(
        [string]$PrefixPath,
        [switch]$Quiet
    )

    New-Item -Path $UserEnvironmentKey -Force -ErrorAction SilentlyContinue | Out-Null
    $environmentValues = Get-ItemProperty -Path $UserEnvironmentKey -ErrorAction SilentlyContinue
    $existingUserPath = $environmentValues.Path
    $backupUserPath = $environmentValues.$UserPathBackupValueName

    if (
        -not [string]::IsNullOrWhiteSpace($existingUserPath) -and
        $existingUserPath.TrimEnd('\') -ine $PrefixPath.TrimEnd('\') -and
        $existingUserPath -ne $backupUserPath
    ) {
        Set-ItemProperty -Path $UserEnvironmentKey -Name $UserPathBackupValueName -Value $existingUserPath
        $backupUserPath = $existingUserPath
    }

    $baseUserPath = $existingUserPath
    if ([string]::IsNullOrWhiteSpace($baseUserPath) -or $baseUserPath.TrimEnd('\') -ieq $PrefixPath.TrimEnd('\')) {
        if (-not [string]::IsNullOrWhiteSpace($backupUserPath)) {
            $baseUserPath = $backupUserPath
        } else {
            $baseUserPath = (Get-DerivedUserPathSegments -PrefixPath $PrefixPath) -join ';'
            if (-not [string]::IsNullOrWhiteSpace($baseUserPath)) {
                Set-ItemProperty -Path $UserEnvironmentKey -Name $UserPathBackupValueName -Value $baseUserPath
            }
        }
    }

    $segments = @()

    foreach ($segment in ($baseUserPath -split ';')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }

        if ($segment.TrimEnd('\') -ieq $PrefixPath.TrimEnd('\')) {
            continue
        }

        $segments += $segment
    }

    $updatedUserPath = ((@($PrefixPath) + $segments) -join ';')
    Set-ItemProperty -Path $UserEnvironmentKey -Name Path -Value $updatedUserPath

    $processSegments = @()
    foreach ($segment in ($env:Path -split ';')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }

        if ($segment.TrimEnd('\') -ieq $PrefixPath.TrimEnd('\')) {
            continue
        }

        $processSegments += $segment
    }

    $env:Path = ((@($PrefixPath) + $processSegments) -join ';')
    Broadcast-EnvironmentChange
}

function Set-ShortcutTarget {
    param(
        [Parameter(Mandatory = $true)]
        $WshShell,
        [string]$ShortcutPath,
        [string]$TargetPath,
        [string]$Arguments,
        [string]$IconTargetPath
    )

    if (-not (Test-Path -LiteralPath $ShortcutPath)) {
        return
    }

    $shortcut = $WshShell.CreateShortcut($ShortcutPath)
    $existingWorkingDirectory = $shortcut.WorkingDirectory

    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory =
        if ([string]::IsNullOrWhiteSpace($existingWorkingDirectory)) {
            Split-Path -Parent $IconTargetPath
        } else {
            $existingWorkingDirectory
        }
    $shortcut.IconLocation = "$IconTargetPath,0"
    $shortcut.Save()
}

function Set-RegistryCommand {
    param(
        [string]$KeyPath,
        [string]$CommandValue
    )

    $item = New-Item -Path $KeyPath -Force -ErrorAction Stop
    $item.SetValue("", $CommandValue)
}

function Get-CDPLaunchSurfaceStatus {
    param([string]$SourceWrapperExe = $WrapperExePath)

    $reasons = New-Object 'System.Collections.Generic.List[string]'
    $shortcutIssues = New-Object 'System.Collections.Generic.List[string]'
    $shellIssues = New-Object 'System.Collections.Generic.List[string]'
    $shimIssues = New-Object 'System.Collections.Generic.List[string]'
    $argvIssues = New-Object 'System.Collections.Generic.List[string]'

    $wrapperExists = Test-Path -LiteralPath $SourceWrapperExe
    if (-not $wrapperExists) {
        $reasons.Add("wrapper-missing")
    }

    $installState =
        if ($wrapperExists) {
            Get-CodeInstallState -SourceWrapperExe $SourceWrapperExe
        } else {
            [pscustomobject]@{
                State = "wrapper-missing"
                ManagedCodeExists = Test-Path -LiteralPath $ManagedCodePath
                ManagedRealExists = Test-Path -LiteralPath $ManagedRealCodePath
                MarkerExists = Test-Path -LiteralPath $ManagedMarkerPath
                ManagedCodeIsWrapper = $false
                ManagedCodeIsVSCode = $false
                ManagedRealIsVSCode = $false
            }
        }

    if ($installState.State -ne "managed") {
        $reasons.Add($installState.State)
    }

    if (-not (Test-Path -LiteralPath $ShimExePath)) {
        $shimIssues.Add("shim-exe-missing")
        $reasons.Add("shim-exe-missing")
    } elseif ($wrapperExists -and -not (Test-FilesMatch -PathA $ShimExePath -PathB $SourceWrapperExe)) {
        $shimIssues.Add("shim-exe-mismatch")
        $reasons.Add("shim-exe-mismatch")
    }

    $realCliCmd = Join-Path $CodeInstallDir "bin\code.cmd"
    if (-not (Test-Path -LiteralPath $ShimCmdPath)) {
        $shimIssues.Add("shim-cmd-missing")
        $reasons.Add("shim-cmd-missing")
    } else {
        $shimCmdContent = Get-Content -LiteralPath $ShimCmdPath -Raw -ErrorAction SilentlyContinue
        $expectedShimCall = ('call "{0}" --remote-debugging-port=9222 %*' -f $realCliCmd)
        if ([string]::IsNullOrWhiteSpace($shimCmdContent) -or $shimCmdContent -notlike "*$expectedShimCall*") {
            $shimIssues.Add("shim-cmd-mismatch")
            $reasons.Add("shim-cmd-mismatch")
        }
    }

    $codeSource = ""
    try {
        $codeCmdInfo = Get-Command code -ErrorAction SilentlyContinue
        if ($codeCmdInfo) {
            $codeSource = $codeCmdInfo.Source
            if ($codeSource -notlike "$ShimDir*") {
                $reasons.Add("code-path-drift")
            }
        } else {
            $reasons.Add("code-command-missing")
        }
    } catch {
        $reasons.Add("code-command-unresolved")
    }

    $argvStatus = Get-VSCodeArgvJsonStatus
    if (-not $argvStatus.FileExists) {
        $argvIssues.Add("argv-json-missing")
        $reasons.Add("argv-json-missing")
    } elseif ($argvStatus.MatchesPort) {
        # Healthy argv.json state.
    } elseif (-not [string]::IsNullOrWhiteSpace($argvStatus.RawValue)) {
        $argvIssues.Add("argv-cdp-mismatch:$($argvStatus.RawValue)")
        $reasons.Add("argv-cdp-mismatch")
    } elseif (-not [string]::IsNullOrWhiteSpace($argvStatus.ErrorMessage)) {
        $argvIssues.Add("argv-read-failed:$($argvStatus.ErrorMessage)")
        $reasons.Add("argv-read-failed")
    } else {
        $argvIssues.Add("argv-cdp-missing")
        $reasons.Add("argv-cdp-missing")
    }

    $expectedShortcutTarget =
        if ($installState.State -eq "managed") {
            $ManagedCodePath
        } else {
            $SourceWrapperExe
        }

    try {
        $wshShell = New-Object -ComObject WScript.Shell
        foreach ($shortcutPath in (Get-ManagedShortcutPaths)) {
            if (-not (Test-Path -LiteralPath $shortcutPath)) {
                continue
            }

            $shortcut = $wshShell.CreateShortcut($shortcutPath)
            $targetPath = $shortcut.TargetPath
            $arguments = $shortcut.Arguments
            if (
                $targetPath -ne $expectedShortcutTarget -or
                (-not [string]::IsNullOrWhiteSpace($arguments))
            ) {
                $shortcutIssues.Add("$shortcutPath => target='$targetPath' args='$arguments'")
            }
        }
    } catch {
        $shortcutIssues.Add("shortcut-check-failed: $($_.Exception.Message)")
    }

    if ($shortcutIssues.Count -gt 0) {
        $reasons.Add("shortcut-drift")
    }

    foreach ($definition in (Get-ExpectedShellCommandDefinitions -WrapperExe $SourceWrapperExe)) {
        try {
            $currentValue = (Get-ItemProperty -Path $definition.KeyPath -ErrorAction Stop).'(default)'
            if ($currentValue -ne $definition.CommandValue) {
                $shellIssues.Add("{0} => '{1}'" -f $definition.KeyPath, $currentValue)
            }
        } catch {
            $shellIssues.Add("{0} => missing" -f $definition.KeyPath)
        }
    }

    if ($shellIssues.Count -gt 0) {
        $reasons.Add("shell-command-drift")
    }

    $reasonArray = @($reasons.ToArray() | Select-Object -Unique)

    return [pscustomobject]@{
        IsHealthy = $reasonArray.Count -eq 0
        InstallState = $installState.State
        Reasons = $reasonArray
        CodeSource = $codeSource
        ShortcutIssues = $shortcutIssues.ToArray()
        ShellIssues = $shellIssues.ToArray()
        ShimIssues = $shimIssues.ToArray()
        ArgvIssues = $argvIssues.ToArray()
        ArgvStatus = $argvStatus
    }
}

function Install-CDPLaunchHooks {
    param(
        [switch]$Quiet,
        [string]$TriggerSource = "startup",
        [string[]]$DetectionReasons = @()
    )

    Ensure-UsableTempEnvironment -PersistUserVariables
    $wrapperExe = Ensure-CodeWrapperCompiled -Quiet:$Quiet
    $repairTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Write-RepairLog "Starting CDP launch hook repair."
    Write-RepairLog "Repair trigger source: $TriggerSource"
    if ($DetectionReasons.Count -gt 0) {
        Write-RepairLog "Repair detection reasons: $($DetectionReasons -join '; ')"
    }

    try {
        Remove-Item -LiteralPath $IfeoKey -Recurse -Force -ErrorAction SilentlyContinue
        Write-RepairLog "Removed stale IFEO key."
    } catch {}

    $installState = $null
    try {
        $stageTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $installState = Install-CodeExeSwap -SourceWrapperExe $wrapperExe -Quiet:$Quiet
        Write-RepairLog "Repair stage install swap completed in $(Format-RepairElapsed -Stopwatch $stageTimer)."
    } catch {
        Write-RepairLog "Code.exe swap repair failed: $($_.Exception.Message)" "ERROR"
        if (-not $Quiet) {
            Write-Host "Code.exe swap skipped: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    try {
        $stageTimer = [System.Diagnostics.Stopwatch]::StartNew()
        Install-CodeShims -SourceWrapperExe $wrapperExe -Quiet:$Quiet
        Ensure-UserPathPrefix -PrefixPath $ShimDir -Quiet:$Quiet
        Write-RepairLog "Shim directory and PATH prefix refreshed in $(Format-RepairElapsed -Stopwatch $stageTimer)."
    } catch {
        Write-RepairLog "Shim repair failed: $($_.Exception.Message)" "ERROR"
        if (-not $Quiet) {
            Write-Host "Shim repair failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    try {
        $stageTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $argvUpdated = Ensure-VSCodeArgvJsonPort
        $argvStatus = Get-VSCodeArgvJsonStatus
        $argvSummary =
            if ($argvStatus.MatchesPort) {
                "configured for port $($argvStatus.RawValue)"
            } elseif (-not [string]::IsNullOrWhiteSpace($argvStatus.RawValue)) {
                "configured for unexpected value '$($argvStatus.RawValue)'"
            } else {
                "missing remote-debugging-port"
            }
        Write-RepairLog "argv.json checked in $(Format-RepairElapsed -Stopwatch $stageTimer): $argvSummary$(if ($argvUpdated) { ' (updated)' } else { '' })."
    } catch {
        Write-RepairLog "argv.json repair failed: $($_.Exception.Message)" "ERROR"
        if (-not $Quiet) {
            Write-Host "argv.json repair failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    try {
        $codeCmdInfo = Get-Command code -ErrorAction SilentlyContinue
        if ($codeCmdInfo) {
            $codeSource = $codeCmdInfo.Source
            $level = if ($codeSource -like "$ShimDir*") { "INFO" } else { "WARN" }
            Write-RepairLog "Shell `code` resolves to $codeSource" $level
        } else {
            Write-RepairLog "Shell `code` command missing from PATH" "WARN"
        }
    } catch {
        Write-RepairLog "Failed to resolve shell `code`: $($_.Exception.Message)" "WARN"
    }

    try {
        $stageTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $wshShell = New-Object -ComObject WScript.Shell
        $effectiveState = if ($installState) { $installState } else { Get-CodeInstallState -SourceWrapperExe $wrapperExe }
        $shortcutTargetPath = if ($effectiveState.State -eq "managed") { $ManagedCodePath } else { $wrapperExe }
        $iconTargetPath = if (Test-Path -LiteralPath $ManagedRealCodePath) { $ManagedRealCodePath } else { $ManagedCodePath }
        $shortcutTargets = Get-ManagedShortcutPaths

        foreach ($shortcutPath in $shortcutTargets) {
            Set-ShortcutTarget -WshShell $wshShell -ShortcutPath $shortcutPath -TargetPath $shortcutTargetPath -Arguments "" -IconTargetPath $iconTargetPath
        }
        Write-RepairLog "Shortcut targets refreshed to $shortcutTargetPath in $(Format-RepairElapsed -Stopwatch $stageTimer)."
    } catch {
        Write-RepairLog "Shortcut repair failed: $($_.Exception.Message)" "ERROR"
        if (-not $Quiet) {
            Write-Host "Shortcut repair failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    try {
        $stageTimer = [System.Diagnostics.Stopwatch]::StartNew()
        foreach ($definition in (Get-ExpectedShellCommandDefinitions -WrapperExe $wrapperExe)) {
            Set-RegistryCommand -KeyPath $definition.KeyPath -CommandValue $definition.CommandValue
        }
        Write-RepairLog "Shell command overrides refreshed in $(Format-RepairElapsed -Stopwatch $stageTimer)."
    } catch {
        Write-RepairLog "Shell command repair failed: $($_.Exception.Message)" "ERROR"
        if (-not $Quiet) {
            Write-Host "Shell command repair failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    try {
        $stageTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $postRepairStatus = Get-CDPLaunchSurfaceStatus -SourceWrapperExe $wrapperExe
        Write-RepairLog "Post-repair launch surface healthy: $($postRepairStatus.IsHealthy)"
        Write-RepairLog "Post-repair code command source: $($postRepairStatus.CodeSource)"
        Write-RepairLog "Post-repair shortcut integrity healthy: $($postRepairStatus.ShortcutIssues.Count -eq 0)"
        Write-RepairLog "Post-repair shell-command integrity healthy: $($postRepairStatus.ShellIssues.Count -eq 0)"
        Write-RepairLog "Post-repair argv.json configured for current port: $($postRepairStatus.ArgvStatus.MatchesPort)"
        if ($postRepairStatus.Reasons.Count -gt 0) {
            Write-RepairLog "Post-repair remaining reasons: $($postRepairStatus.Reasons -join '; ')" "WARN"
        }
        Write-RepairLog "Repair stage post-check completed in $(Format-RepairElapsed -Stopwatch $stageTimer)."
    } catch {
        Write-RepairLog "Post-repair integrity check failed: $($_.Exception.Message)" "WARN"
    }

    Write-RepairLog "Completed CDP launch hook repair in $(Format-RepairElapsed -Stopwatch $repairTimer)."

    if (-not $Quiet) {
        Write-Host "CDP launch hooks refreshed." -ForegroundColor Green
    }
}

function Install-StartupRepair {
    param([switch]$Quiet)

    $startupCommand = ('"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -StartupRepairOnly' -f $PowerShellExe, $ScriptPath)
    New-Item -Path $StartupRunKey -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $StartupRunKey -Name $StartupValueName -Value $startupCommand

    if (-not $Quiet) {
        Write-Host "Startup repair installed." -ForegroundColor Green
    }
}

function Uninstall-StartupRepair {
    try {
        Remove-ItemProperty -Path $StartupRunKey -Name $StartupValueName -ErrorAction Stop
        Write-Host "Startup repair removed." -ForegroundColor Green
    } catch {
        Write-Host "Startup repair was not installed." -ForegroundColor Yellow
    }
}

function Get-CDPRuntimeStatus {
    $endpointStatus = Get-CDPStatus
    $launchStatus = Get-CDPLaunchSurfaceStatus
    $repairInProgress = Test-CDPRepairInProgress
    $argvStatus = $launchStatus.ArgvStatus

    $launchHookLabel =
        if ($repairInProgress -and -not $launchStatus.IsHealthy) {
            "launch hooks drift detected, repairing"
        } elseif ($repairInProgress) {
            "startup self-heal running"
        } elseif ($launchStatus.IsHealthy) {
            "launch hooks healthy"
        } else {
            "launch hooks drift detected, repair pending"
        }

    $endpointLabel = if ($endpointStatus.EndpointReady) { "active" } else { "endpoint inactive" }
    $argvLabel =
        if ($argvStatus.MatchesPort) {
            "argv.json configured"
        } elseif (-not [string]::IsNullOrWhiteSpace($argvStatus.RawValue)) {
            "argv.json port mismatch"
        } else {
            "argv.json missing CDP port"
        }

    return [pscustomobject]@{
        EndpointStatus = $endpointStatus
        LaunchStatus = $launchStatus
        ArgvStatus = $argvStatus
        RepairInProgress = $repairInProgress
        EndpointLabel = $endpointLabel
        LaunchHookLabel = $launchHookLabel
        ArgvLabel = $argvLabel
        BannerText = "$endpointLabel; $launchHookLabel; $argvLabel"
    }
}

function Invoke-CDPLaunchRepairIfNeeded {
    param(
        [string]$TriggerSource,
        [switch]$WriteConsoleNotice,
        [switch]$RunInBackground,
        [switch]$LogHealthySkip
    )

    $argvEnsureResult = Invoke-VSCodeArgvJsonEnsure -TriggerSource $TriggerSource -WriteConsoleNotice:$WriteConsoleNotice
    $status = Get-CDPLaunchSurfaceStatus
    $result = [ordered]@{
        ArgvEnsure = $argvEnsureResult
        Status = $status
        Action = "none"
        RepairQueued = $false
        RepairCompleted = $false
        RepairInProgress = Test-CDPRepairInProgress
    }

    if ($status.IsHealthy) {
        if ($LogHealthySkip) {
            Write-RepairLog "Repair skipped because launch hooks are already healthy for source '$TriggerSource'."
        }

        $result.Action = "healthy"
        return [pscustomobject]$result
    }

    if ($result.RepairInProgress) {
        $now = Get-Date
        if ((($now - $script:LastRepairLockNoticeAt).TotalMilliseconds -ge $RepairDebounceMs) -or $script:LastRepairLockNoticeAt -eq [DateTime]::MinValue) {
            Write-RepairLog "Repair already in progress; source=$TriggerSource reused the in-flight repair."
            $script:LastRepairLockNoticeAt = $now
        }

        if ($WriteConsoleNotice) {
            Write-Host "  CDP launch repair already in progress - leaving current windows alone while hooks finish healing..." -ForegroundColor Yellow
        }

        $result.Action = "repair-in-progress"
        return [pscustomobject]$result
    }

    $reasonSignature = ($status.Reasons -join '|')
    $now = Get-Date
    if (
        $reasonSignature -eq $script:LastDriftSignature -and
        (($now - $script:LastDriftRepairAt).TotalMilliseconds -lt $RepairDebounceMs)
    ) {
        $result.Action = "debounced"
        return [pscustomobject]$result
    }

    $script:LastDriftSignature = $reasonSignature
    $script:LastDriftRepairAt = $now

    Write-RepairLog "vs code updated restarting and implementing CDP"
    Write-RepairLog "Drift trigger source: $TriggerSource"
    Write-RepairLog "Drift reasons: $($status.Reasons -join '; ')"
    if ($status.ShortcutIssues.Count -gt 0) {
        Write-RepairLog "Shortcut drift details: $($status.ShortcutIssues -join ' || ')" "WARN"
    }
    if ($status.ShellIssues.Count -gt 0) {
        Write-RepairLog "Shell-command drift details: $($status.ShellIssues -join ' || ')" "WARN"
    }
    if ($status.ShimIssues.Count -gt 0) {
        Write-RepairLog "Shim drift details: $($status.ShimIssues -join '; ')" "WARN"
    }
    if ($status.ArgvIssues.Count -gt 0) {
        Write-RepairLog "argv.json drift details: $($status.ArgvIssues -join '; ')" "WARN"
    }

    if ($WriteConsoleNotice) {
        Write-Host "  VS Code drift detected - repairing CDP launch hooks..." -ForegroundColor Yellow
    }

    if ($RunInBackground) {
        if (Start-CDPBackgroundRepair -TriggerSource $TriggerSource) {
            $result.Action = "repair-queued"
            $result.RepairQueued = $true
        } else {
            $result.Action = "repair-queue-failed"
        }

        return [pscustomobject]$result
    }

    $repairOutcome = Invoke-CDPLaunchRepairCore -TriggerSource $TriggerSource -DetectionReasons $status.Reasons
    $result.Action = $repairOutcome
    $result.RepairCompleted = $repairOutcome -eq "completed"
    $result.RepairInProgress = $repairOutcome -eq "locked"
    return [pscustomobject]$result
}

function Invoke-CDPIntegrityWatcherTick {
    $now = Get-Date
    if (($now - $script:LastIntegrityPollAt).TotalMilliseconds -lt $IntegrityPollIntervalMs) {
        return
    }

    $script:LastIntegrityPollAt = $now
    [void](Invoke-CDPLaunchRepairIfNeeded -TriggerSource "watcher" -RunInBackground)
}

if ($UninstallStartup) {
    Uninstall-StartupRepair
    exit 0
}

Ensure-UsableTempEnvironment
Install-StartupRepair -Quiet

if ($InstallStartup) {
    Install-StartupRepair
    exit 0
}

if ($RepairOnly) {
    [void](Invoke-CDPLaunchRepairIfNeeded -TriggerSource $RepairTriggerSource -LogHealthySkip)
    exit 0
}

if ($StartupRepairOnly) {
    [void](Invoke-CDPLaunchRepairIfNeeded -TriggerSource "startup" -LogHealthySkip)
    exit 0
}

$initialRepairResult = Invoke-CDPLaunchRepairIfNeeded -TriggerSource "startup" -RunInBackground

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
    public static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);

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
    public const uint PM_REMOVE = 0x0001;

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

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class CommandLineHelper {
    [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CommandLineToArgvW(string lpCmdLine, out int pNumArgs);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr LocalFree(IntPtr hMem);
}
"@ -ErrorAction SilentlyContinue

# Load Windows Forms for SendKeys
Add-Type -AssemblyName System.Windows.Forms

# CDP port for Chrome DevTools Protocol

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

function Get-CDPEndpointInfo {
    $port = $CDPPort
    $source = "default"
    $browserPath = ""
    $fileExists = Test-Path -LiteralPath $DevToolsActivePortPath

    if ($fileExists) {
        try {
            $lines = Get-Content -LiteralPath $DevToolsActivePortPath -ErrorAction Stop
            if ($lines.Count -gt 0 -and $lines[0] -match '^\d+$') {
                $port = [int]$lines[0]
                $source = "DevToolsActivePort"
            }

            if ($lines.Count -gt 1) {
                $browserPath = $lines[1]
            }
        } catch {
            $source = "default"
        }
    }

    return [pscustomobject]@{
        Port = $port
        Source = $source
        FileExists = $fileExists
        BrowserPath = $browserPath
    }
}

function Get-CDPStatus {
    $endpoint = Get-CDPEndpointInfo
    $versionUri = "http://127.0.0.1:$($endpoint.Port)/json/version"

    try {
        $version = Invoke-RestMethod -Uri $versionUri -TimeoutSec 1 -ErrorAction Stop
        return [pscustomobject]@{
            Port = $endpoint.Port
            Source = $endpoint.Source
            FileExists = $endpoint.FileExists
            BrowserPath = $endpoint.BrowserPath
            EndpointReady = $true
            ErrorMessage = ""
            Browser = $version.Browser
        }
    } catch {
        return [pscustomobject]@{
            Port = $endpoint.Port
            Source = $endpoint.Source
            FileExists = $endpoint.FileExists
            BrowserPath = $endpoint.BrowserPath
            EndpointReady = $false
            ErrorMessage = $_.Exception.Message
            Browser = ""
        }
    }
}

function Find-CDPPageTarget {
    param(
        [object[]]$Targets,
        [string]$WindowTitle = "",
        [switch]$AllowWorkbenchFallback
    )

    $pageTargets = @($Targets | Where-Object { $null -ne $_ -and $_.type -eq "page" })
    $workbenchTargets = @($pageTargets | Where-Object { $_.url -match "workbench" })
    $target = $null
    $matchKind = ""

    if (-not [string]::IsNullOrWhiteSpace($WindowTitle)) {
        $target = $pageTargets | Where-Object { $_.title -eq $WindowTitle } | Select-Object -First 1
        if ($null -ne $target) {
            $matchKind = "exact"
        }

        if ($null -eq $target) {
            $escapedTitle = [regex]::Escape($WindowTitle)
            $target = $pageTargets | Where-Object { $_.title -match $escapedTitle } | Select-Object -First 1
            if ($null -ne $target) {
                $matchKind = "partial"
            }
        }
    }

    if ($null -eq $target -and $AllowWorkbenchFallback) {
        $target = $workbenchTargets | Select-Object -First 1
        if ($null -ne $target) {
            $matchKind = "workbench-fallback"
        }
    }

    return [pscustomobject]@{
        Target = $target
        MatchKind = $matchKind
        PageCount = $pageTargets.Count
        WorkbenchPageCount = $workbenchTargets.Count
    }
}

function Get-CDPWindowTargetStatus {
    param(
        [string]$WindowTitle = "",
        [switch]$AllowWorkbenchFallback
    )

    $status = Get-CDPStatus
    $targets = @()
    $targetsReady = $false
    $targetsErrorMessage = ""
    $targetMatch = [pscustomobject]@{
        Target = $null
        MatchKind = ""
        PageCount = 0
        WorkbenchPageCount = 0
    }

    if ($status.EndpointReady) {
        try {
            $rawTargets = Invoke-RestMethod -Uri "http://127.0.0.1:$($status.Port)/json" -TimeoutSec 2 -ErrorAction Stop
            $targets = @($rawTargets | Where-Object { $null -ne $_ })
            $targetsReady = $true
            $targetMatch = Find-CDPPageTarget -Targets $targets -WindowTitle $WindowTitle -AllowWorkbenchFallback:$AllowWorkbenchFallback
        } catch {
            $targetsErrorMessage = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        Port = $status.Port
        Source = $status.Source
        FileExists = $status.FileExists
        BrowserPath = $status.BrowserPath
        Browser = $status.Browser
        EndpointReady = $status.EndpointReady
        EndpointErrorMessage = $status.ErrorMessage
        TargetsReady = $targetsReady
        TargetsErrorMessage = $targetsErrorMessage
        TargetCount = $targets.Count
        PageCount = $targetMatch.PageCount
        WorkbenchPageCount = $targetMatch.WorkbenchPageCount
        WindowTargetMatched = $null -ne $targetMatch.Target
        TargetTitle = if ($null -ne $targetMatch.Target) { $targetMatch.Target.title } else { "" }
        TargetUrl = if ($null -ne $targetMatch.Target) { $targetMatch.Target.url } else { "" }
        TargetMatchKind = $targetMatch.MatchKind
    }
}

function Connect-CDPWebSocket {
    param(
        [string]$WindowTitle = ""
    )

    try {
        $targetStatus = Get-CDPWindowTargetStatus -WindowTitle $WindowTitle -AllowWorkbenchFallback
        $endpoint = [pscustomobject]@{
            Port = $targetStatus.Port
            Source = $targetStatus.Source
            FileExists = $targetStatus.FileExists
        }
        $targets = @()
        if ($targetStatus.TargetsReady) {
            $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$($endpoint.Port)/json" -TimeoutSec 3 -ErrorAction Stop
        } else {
            throw $targetStatus.TargetsErrorMessage
        }

        # Debug: log all targets
        Write-Host "    [DEBUG] CDP targets found: $($targets.Count) on port $($endpoint.Port) ($($endpoint.Source))" -ForegroundColor DarkGray
        foreach ($t in $targets) {
            $marker = ""
            if ($t.url -match "workbench") { $marker = " [WORKBENCH]" }
            Write-Host "    [DEBUG]   type=$($t.type) title='$($t.title)'$marker" -ForegroundColor DarkGray
        }

        if ($WindowTitle) {
            Write-Host "    [DEBUG] Looking for window: '$WindowTitle'" -ForegroundColor DarkGray
        }

        $targetMatch = Find-CDPPageTarget -Targets $targets -WindowTitle $WindowTitle -AllowWorkbenchFallback
        $target = $targetMatch.Target

        if ($targetMatch.MatchKind -eq "exact") {
            Write-Host "    [DEBUG] Exact title match!" -ForegroundColor DarkGray
        } elseif ($targetMatch.MatchKind -eq "partial") {
            Write-Host "    [DEBUG] Partial title match" -ForegroundColor DarkGray
        } elseif ($targetMatch.MatchKind -eq "workbench-fallback") {
            Write-Host "    [DEBUG] Falling back to first workbench page" -ForegroundColor DarkGray
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
        $endpoint = Get-CDPEndpointInfo
        Write-Host "    CDP: Connection failed on port $($endpoint.Port) ($($endpoint.Source)): $($_.Exception.Message)" -ForegroundColor Gray
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
    return (Get-CDPStatus).EndpointReady
}

function Get-VSCodeWindowProcessId {
    param([IntPtr]$hwnd)

    if ($null -eq $hwnd -or $hwnd -eq [IntPtr]::Zero) {
        return $null
    }

    $procId = [uint32]0
    [WinAPI]::GetWindowThreadProcessId($hwnd, [ref]$procId) | Out-Null

    if ($procId -eq 0) {
        return $null
    }

    return [int]$procId
}

function Get-VSCodeWindowTitle {
    param([IntPtr]$hwnd)

    if ($null -eq $hwnd -or $hwnd -eq [IntPtr]::Zero) {
        return ""
    }

    $titleLength = [WinAPI]::GetWindowTextLength($hwnd)
    if ($titleLength -le 0) {
        return ""
    }

    $sb = New-Object System.Text.StringBuilder($titleLength + 1)
    [WinAPI]::GetWindowText($hwnd, $sb, $sb.Capacity) | Out-Null
    return $sb.ToString()
}

function Get-VSCodeProcessWindows {
    $vsCodeProcesses = Get-Process -Name "Code","Code.real" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero }

    $results = @()
    foreach ($proc in $vsCodeProcesses) {
        $title = Get-VSCodeWindowTitle -hwnd $proc.MainWindowHandle
        if ([string]::IsNullOrWhiteSpace($title)) {
            continue
        }

        if ($title -notmatch "Visual Studio Code") {
            continue
        }

        $results += [pscustomobject]@{
            Handle = [int64]$proc.MainWindowHandle
            Title = $title
            ProcessId = $proc.Id
        }
    }

    return $results
}

function Get-ProcessCommandLine {
    param([int]$ProcessId)

    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
        return $proc.CommandLine
    } catch {
        return $null
    }
}

function Convert-CommandLineToArguments {
    param([string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return @()
    }

    $argc = 0
    $argvPtr = [CommandLineHelper]::CommandLineToArgvW($CommandLine, [ref]$argc)
    if ($argvPtr -eq [IntPtr]::Zero -or $argc -le 0) {
        return @()
    }

    $args = New-Object 'System.Collections.Generic.List[string]'
    $intPtrSize = [IntPtr]::Size
    try {
        for ($i = 0; $i -lt $argc; $i++) {
            $ptr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($argvPtr, $i * $intPtrSize)
            $args.Add([System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr))
        }
    } finally {
        [CommandLineHelper]::LocalFree($argvPtr) | Out-Null
    }

    return $args.ToArray()
}

function Get-VSCodeWindowArguments {
    param([IntPtr]$hwnd)

    $procId = Get-VSCodeWindowProcessId -hwnd $hwnd
    if ($null -eq $procId) {
        return @()
    }

    $commandLine = Get-ProcessCommandLine -ProcessId $procId
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        return @()
    }

    $args = Convert-CommandLineToArguments -CommandLine $commandLine
    if ($args.Count -le 1) {
        return @()
    }

    return $args[1..($args.Count - 1)]
}

function Get-VSCodeWindowExecutablePath {
    param([IntPtr]$hwnd)

    $procId = Get-VSCodeWindowProcessId -hwnd $hwnd
    if ($null -eq $procId) {
        return ""
    }

    $commandLine = Get-ProcessCommandLine -ProcessId $procId
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        return ""
    }

    $args = Convert-CommandLineToArguments -CommandLine $commandLine
    if ($args.Count -eq 0) {
        return ""
    }

    return $args[0]
}

function Ensure-CDPFlagInArgs {
    param([string[]]$Arguments)

    if (-not $Arguments) {
        $Arguments = @()
    }

    $args = @()
    $flagFound = $false
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $arg = $Arguments[$i]
        if ($arg -like '--remote-debugging-port=*') {
            $flagFound = $true
            $args += "--remote-debugging-port=$CDPPort"
            continue
        }

        if ($arg -ieq '--remote-debugging-port') {
            $flagFound = $true
            if ($i + 1 -lt $Arguments.Count) {
                $i++
            }
            $args += "--remote-debugging-port=$CDPPort"
            continue
        }

        $args += $arg
    }

    if (-not $flagFound) {
        $args += "--remote-debugging-port=$CDPPort"
    }

    return $args
}

function Test-VSCodeWindowHasCDPFlag {
    param([IntPtr]$hwnd)

    $procId = Get-VSCodeWindowProcessId -hwnd $hwnd
    if ($null -eq $procId) {
        return $false
    }

    $commandLine = Get-ProcessCommandLine -ProcessId $procId
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        return $false
    }

    return $commandLine -match '(^|\s)--remote-debugging-port(?:=|\s|$)'
}

function Get-VSCodeWindowCDPState {
    param(
        [IntPtr]$hwnd,
        [string]$WindowTitle = ""
    )

    $effectiveWindowTitle =
        if ([string]::IsNullOrWhiteSpace($WindowTitle)) {
            Get-VSCodeWindowTitle -hwnd $hwnd
        } else {
            $WindowTitle
        }

    $targetStatus = Get-CDPWindowTargetStatus -WindowTitle $effectiveWindowTitle
    $argvStatus = Get-VSCodeArgvJsonStatus

    return [pscustomobject]@{
        WindowTitle = $effectiveWindowTitle
        FlagVisible = Test-VSCodeWindowHasCDPFlag -hwnd $hwnd
        ArgvConfigured = $argvStatus.MatchesPort
        ArgvPort = $argvStatus.RawValue
        EndpointReady = $targetStatus.EndpointReady
        TargetsReady = $targetStatus.TargetsReady
        WindowTargetMatched = $targetStatus.WindowTargetMatched
        TargetTitle = $targetStatus.TargetTitle
        TargetUrl = $targetStatus.TargetUrl
        TargetMatchKind = $targetStatus.TargetMatchKind
        TargetCount = $targetStatus.TargetCount
        WorkbenchPageCount = $targetStatus.WorkbenchPageCount
        Port = $targetStatus.Port
        Source = $targetStatus.Source
        FileExists = $targetStatus.FileExists
        BrowserPath = $targetStatus.BrowserPath
        Browser = $targetStatus.Browser
        ErrorMessage =
            if (-not $targetStatus.EndpointReady) {
                $targetStatus.EndpointErrorMessage
            } elseif (-not $targetStatus.TargetsReady) {
                $targetStatus.TargetsErrorMessage
            } else {
                ""
            }
    }
}

function Restart-VSCodeWithCDP {
    param(
        [IntPtr]$hwnd,
        [string]$ExpectedTitle = ""
    )

    Write-Host "  Restarting this VS Code window with CDP flag..." -ForegroundColor Cyan

    $procId = Get-VSCodeWindowProcessId -hwnd $hwnd
    $originalCommandLine = if ($procId) { Get-ProcessCommandLine -ProcessId $procId } else { "" }
    $titleFilter = if ([string]::IsNullOrWhiteSpace($ExpectedTitle)) { Get-VSCodeWindowTitle -hwnd $hwnd } else { $ExpectedTitle }
    $originalArgs = Get-VSCodeWindowArguments -hwnd $hwnd
    $finalArgs = Ensure-CDPFlagInArgs -Arguments $originalArgs

    if (-not [string]::IsNullOrWhiteSpace($originalCommandLine)) {
        Write-RepairLog "Restart triggered for '$titleFilter' with command line: $originalCommandLine"
    }

    # Gracefully close ONLY this window (WM_CLOSE, not kill all processes)
    [WinAPI]::PostMessage($hwnd, [WinAPI]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    Start-Sleep -Milliseconds 2000

    # Relaunch with CDP flag
    $codePath = if (Test-Path -LiteralPath $ManagedCodePath) { $ManagedCodePath } else { $ManagedRealCodePath }
    if (-not (Test-Path $codePath)) {
        Write-Host "    Code.exe not found" -ForegroundColor Red
        return $null
    }

    Start-Process -FilePath $codePath -ArgumentList $finalArgs

    # Wait for new VS Code window
    $waited = 0
    $newHwnd = $null
    while ($waited -lt 15000) {
        if ($titleFilter) {
            $newHwnd = Find-VSCodeWindow -TargetTitle $titleFilter
        } else {
            $newHwnd = Find-VSCodeWindow
        }
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
    while ($waited -lt 45000) {
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
# Core layout functions
# ============================================================

function Find-VSCodeWindow {
    param(
        [string]$TargetTitle = ""
    )

    # If a specific title filter is provided, skip foreground heuristic and search all windows
    if ($TargetTitle -ne "") {
        $vsCodeProcesses = Get-Process -Name "Code","Code.real" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero }
        foreach ($proc in $vsCodeProcesses) {
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
                $titleLength = [WinAPI]::GetWindowTextLength($proc.MainWindowHandle)
                if ($titleLength -gt 0) {
                    $sb = New-Object System.Text.StringBuilder($titleLength + 1)
                    [WinAPI]::GetWindowText($proc.MainWindowHandle, $sb, $sb.Capacity) | Out-Null
                    $title = $sb.ToString()
                    if ($title -like "*$TargetTitle*" -and $title -match "Visual Studio Code") {
                        return $proc.MainWindowHandle
                    }
                }
            }
        }
        return $null
    }

    # No filter — use original behavior: foreground first, then first match
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

    $vsCodeProcesses = Get-Process -Name "Code","Code.real" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero }
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

function Find-VSCodeWindow {
    param(
        [string]$TargetTitle = "",
        [Int64]$TargetHandle = 0
    )

    if ($TargetHandle -gt 0) {
        $handle = [IntPtr]$TargetHandle
        $title = Get-VSCodeWindowTitle -hwnd $handle
        if ([string]::IsNullOrWhiteSpace($title) -or $title -notmatch "Visual Studio Code") {
            Write-Host "  Requested window handle $TargetHandle is not a visible VS Code window." -ForegroundColor Yellow
            Write-RepairLog "Requested window handle $TargetHandle is not a visible VS Code window." "WARN"
            return $null
        }

        Write-Host "  Exact window handle match: $TargetHandle" -ForegroundColor DarkGray
        return $handle
    }

    if ($TargetTitle -ne "") {
        $windows = @(Get-VSCodeProcessWindows)
        $exactMatches = @($windows | Where-Object { $_.Title -ieq $TargetTitle })

        if ($exactMatches.Count -eq 1) {
            Write-Host "  Exact title match found." -ForegroundColor DarkGray
            return [IntPtr]$exactMatches[0].Handle
        }

        if ($exactMatches.Count -gt 1) {
            $matchTitles = ($exactMatches | ForEach-Object { $_.Title }) -join " | "
            Write-Host "  Ambiguous exact title match for '$TargetTitle': $matchTitles" -ForegroundColor Yellow
            Write-RepairLog "Ambiguous exact title match for '$TargetTitle': $matchTitles" "WARN"
            return $null
        }

        $substringMatches = @(
            $windows | Where-Object {
                $_.Title.IndexOf($TargetTitle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            }
        )

        if ($substringMatches.Count -eq 1) {
            Write-Host "  Single substring title match found." -ForegroundColor DarkGray
            return [IntPtr]$substringMatches[0].Handle
        }

        if ($substringMatches.Count -gt 1) {
            $matchTitles = ($substringMatches | ForEach-Object { $_.Title }) -join " | "
            Write-Host "  Ambiguous substring title match for '$TargetTitle': $matchTitles" -ForegroundColor Yellow
            Write-RepairLog "Ambiguous substring title match for '$TargetTitle': $matchTitles" "WARN"
            return $null
        }

        Write-Host "  No VS Code window matched '$TargetTitle'." -ForegroundColor Yellow
        Write-RepairLog "No VS Code window matched '$TargetTitle'." "WARN"
        return $null
    }

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

    foreach ($window in Get-VSCodeProcessWindows) {
        if ($window.Title -match "Visual Studio Code" -or $window.Title -match " - .+ - Visual Studio Code") {
            return [IntPtr]$window.Handle
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

    $repairResult = Invoke-CDPLaunchRepairIfNeeded -TriggerSource "hotkey integrity check" -WriteConsoleNotice -RunInBackground
    if ($repairResult.RepairQueued) {
        Start-Sleep -Milliseconds 150
    }

    # Try CDP first (no cursor movement)
    $cdpResult = Set-AuxiliaryBarWidthCDP -TargetWidth $Width -WindowTitle $WindowTitle -ExpectedWindowWidth $WindowWidth
    if ($cdpResult) {
        return $true
    }

    if ($WindowHandle -ne [IntPtr]::Zero) {
        $windowCDPState = Get-VSCodeWindowCDPState -hwnd $WindowHandle -WindowTitle $WindowTitle
        if ($windowCDPState.EndpointReady -and $windowCDPState.WindowTargetMatched) {
            $cdpSource =
                if ($windowCDPState.ArgvConfigured) {
                    "argv.json"
                } elseif ($windowCDPState.FlagVisible) {
                    "process args"
                } else {
                    "live endpoint"
                }

            Write-Host "  CDP is live for this window on port $($windowCDPState.Port) ($($windowCDPState.Source)); target match '$($windowCDPState.TargetMatchKind)' via $cdpSource - retrying once without restart..." -ForegroundColor Yellow
            Start-Sleep -Milliseconds 500

            $retryResult = Set-AuxiliaryBarWidthCDP -TargetWidth $Width -WindowTitle $WindowTitle -ExpectedWindowWidth $WindowWidth
            if ($retryResult) {
                return $true
            }

            Write-Host "  CDP is live for this window, but resize still failed for another reason; window left open." -ForegroundColor Yellow
            Write-RepairLog "Current window '$WindowTitle' has a live CDP target, but panel resize still failed."
            return $false
        }

        if ($windowCDPState.EndpointReady -and $windowCDPState.TargetsReady -and -not $windowCDPState.WindowTargetMatched) {
            Write-Host "  CDP browser is live on port $($windowCDPState.Port), but this window target is not visible yet (targets=$($windowCDPState.TargetCount)); retrying once..." -ForegroundColor Yellow
            Start-Sleep -Milliseconds 500

            $windowCDPState = Get-VSCodeWindowCDPState -hwnd $WindowHandle -WindowTitle $WindowTitle
            if ($windowCDPState.WindowTargetMatched) {
                $retryResult = Set-AuxiliaryBarWidthCDP -TargetWidth $Width -WindowTitle $WindowTitle -ExpectedWindowWidth $WindowWidth
                if ($retryResult) {
                    return $true
                }

                Write-Host "  CDP target appeared for this window, but resize still failed for another reason; window left open." -ForegroundColor Yellow
                Write-RepairLog "Current window '$WindowTitle' matched a live CDP target after retry, but panel resize still failed."
                return $false
            }

            Write-Host "  CDP browser is live but this window target is not visible yet; leaving window open." -ForegroundColor Yellow
            Write-RepairLog "Current window '$WindowTitle' did not appear in the live CDP target list yet; leaving window open."
            return $false
        }

        if ($windowCDPState.EndpointReady -and -not $windowCDPState.TargetsReady) {
            Write-Host "  CDP browser is live on port $($windowCDPState.Port), but the target list is unavailable: $($windowCDPState.ErrorMessage)" -ForegroundColor Yellow
            Write-RepairLog "Current window '$WindowTitle' has a live CDP endpoint, but the target list is unavailable; leaving window open."
        }

        if (-not $windowCDPState.EndpointReady) {
            $sourceText = if ($windowCDPState.FileExists) { "$($windowCDPState.Source)" } else { "default port" }
            $argvText =
                if ($windowCDPState.ArgvConfigured) {
                    " argv.json is configured for port $($windowCDPState.ArgvPort)."
                } elseif ($windowCDPState.FlagVisible) {
                    " The process args do show the CDP flag."
                } else {
                    ""
                }

            if ($repairResult.RepairQueued -or $repairResult.RepairInProgress) {
                Write-Host "  CDP endpoint unavailable on port $($windowCDPState.Port) ($sourceText) while launch-hook self-heal is still running: $($windowCDPState.ErrorMessage)$argvText" -ForegroundColor Yellow
                Write-RepairLog "Current window '$WindowTitle' is waiting on launch-hook self-heal before CDP becomes reachable."
            } else {
                Write-Host "  CDP endpoint unavailable on port $($windowCDPState.Port) ($sourceText): $($windowCDPState.ErrorMessage)$argvText" -ForegroundColor Yellow
                Write-RepairLog "Current window '$WindowTitle' does not have a reachable CDP endpoint; leaving window open."
            }
        }
    }

    # CDP not available — gracefully restart this VS Code window with the flag
    Write-Host "  CDP unavailable on this window - window left open, panel not resized. The next hotkey run will retry once the live endpoint/target is ready." -ForegroundColor Yellow
    return $false
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

    $hwnd = Find-VSCodeWindow -TargetTitle $WindowTitle -TargetHandle $WindowHandle

    if ($null -eq $hwnd -or $hwnd -eq [IntPtr]::Zero) {
        Write-Host "  No VS Code window found$(if ($WindowTitle) {" matching '$WindowTitle'"})!" -ForegroundColor Yellow
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

    $hwnd = Find-VSCodeWindow -TargetTitle $WindowTitle -TargetHandle $WindowHandle

    if ($null -eq $hwnd -or $hwnd -eq [IntPtr]::Zero) {
        Write-Host "  No VS Code window found$(if ($WindowTitle) {" matching '$WindowTitle'"})!" -ForegroundColor Yellow
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

$oneShotExitCode = $null
Start-LayoutRunLogging -Path $LogPath

try {
    if ($Once) {
        $layoutSucceeded =
            if ($Duplicate) {
                Invoke-LayoutSnap -DuplicateFirst
            } else {
                Invoke-LayoutSnap
            }

        $oneShotExitCode = if ($layoutSucceeded) { 0 } else { 1 }
    } elseif ($SingleOnce) {
        $layoutSucceeded = Invoke-SingleMonitorLayout
        $oneShotExitCode = if ($layoutSucceeded) { 0 } else { 1 }
    } else {
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host "  VS Code Side Panel Layout Script" -ForegroundColor White
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host "  Ctrl+Alt+V - Dual monitor layout (bottom)" -ForegroundColor Yellow
        Write-Host "  Ctrl+Alt+N - Top monitors layout (panel full)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Dual:   ${TargetWidth}x${TargetHeight} at $TargetX,$TargetY (panel=${PanelWidth}px)"
        Write-Host "  Single: ${SingleMonitorWidth}x${SingleMonitorHeight} at $SingleMonitorX,$SingleMonitorY (panel=${SinglePanelWidth}px)"
        $runtimeStatus = Get-CDPRuntimeStatus
        Write-Host "  CDP:    localhost:$CDPPort - $($runtimeStatus.BannerText)"
        Write-Host ""
        Write-Host "  Press Ctrl+C to exit"
        Write-Host "============================================" -ForegroundColor Cyan

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

        $msg = New-Object WinAPI+MSG

        try {
            while ($true) {
                $processedMessage = $false

                while ([WinAPI]::PeekMessage([ref]$msg, [IntPtr]::Zero, 0, 0, [WinAPI]::PM_REMOVE)) {
                    $processedMessage = $true

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

                Invoke-CDPIntegrityWatcherTick
                Start-Sleep -Milliseconds $(if ($processedMessage) { 25 } else { 150 })
            }
        } finally {
            [WinAPI]::UnregisterHotKey([IntPtr]::Zero, $HOTKEY_ID) | Out-Null
            [WinAPI]::UnregisterHotKey([IntPtr]::Zero, $HOTKEY_ID_N) | Out-Null
            Write-Host "Hotkeys unregistered. Goodbye!" -ForegroundColor Cyan
        }
    }
} finally {
    Stop-LayoutRunLogging
}

if ($null -ne $oneShotExitCode) {
    exit $oneShotExitCode
}
