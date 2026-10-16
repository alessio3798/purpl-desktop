<#
.SYNOPSIS
  Installs PURPL-Setup.exe silently with a non-admin token, launches the app,
  quits it, uninstalls it, and checks every step. Exit code 0 only when all
  checks pass; the log lists each one.

.DESCRIPTION
  Smart App Control blocks an unsigned build outright, so run this on a clean
  PC where it is off (a GitHub-hosted Windows runner, for example), or on a
  signed build. -Sandbox runs it inside Windows Sandbox if Sandbox is already
  enabled; this script never changes a system setting.

  The installer runs as `PURPL-Setup.exe /S` through
  `runas /trustlevel:0x20000` (a basic-user token), so a pass proves the
  install needs no admin even from an admin shell. -Direct runs it from this
  shell's own token instead.

  With no interactive desktop (session 0), the window checks are skipped and
  the launch is proven by the process and %APPDATA%\PURPL alone.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File desktop\scripts\install-test.ps1
  powershell -ExecutionPolicy Bypass -File desktop\scripts\install-test.ps1 -Installer D:\PURPL-Setup.exe -Log D:\install-test.log
#>
param(
  [string]$Installer = (Join-Path $PSScriptRoot '..\release\PURPL-Setup.exe'),
  [string]$Log = (Join-Path $PSScriptRoot '..\release\install-test.log'),
  [switch]$Direct,
  [switch]$Sandbox
)

$ErrorActionPreference = 'Stop'

if ($Sandbox) {
  $sandboxExe = Join-Path $env:windir 'System32\WindowsSandbox.exe'
  if (-not (Test-Path $sandboxExe)) { Write-Host 'Windows Sandbox is not enabled on this PC.'; exit 2 }
  $desktop = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
  $wsb = Join-Path $desktop 'release\install-test.wsb'
  $sandboxLog = Join-Path $desktop 'release\install-test-sandbox.log'
  if (Test-Path $sandboxLog) { Remove-Item $sandboxLog }
  $xml = @"
<Configuration>
  <Networking>Disable</Networking>
  <MappedFolders>
    <MappedFolder><HostFolder>$desktop\scripts</HostFolder><SandboxFolder>C:\purpl\scripts</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$desktop\release</HostFolder><SandboxFolder>C:\purpl\release</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell -ExecutionPolicy Bypass -File C:\purpl\scripts\install-test.ps1 -Installer C:\purpl\release\PURPL-Setup.exe -Log C:\purpl\release\install-test-sandbox.log</Command>
  </LogonCommand>
</Configuration>
"@
  Set-Content -Path $wsb -Value $xml -Encoding UTF8
  Start-Process -FilePath $sandboxExe -ArgumentList "`"$wsb`""
  Write-Host "Windows Sandbox started. Waiting for $sandboxLog ..."
  $deadline = (Get-Date).AddMinutes(10)
  while ((Get-Date) -lt $deadline) {
    if ((Test-Path $sandboxLog) -and (Select-String -Path $sandboxLog -Pattern '^RESULT ' -Quiet)) { break }
    Start-Sleep -Seconds 5
  }
  if (-not (Test-Path $sandboxLog)) { Write-Host 'No log from the sandbox after 10 minutes.'; exit 2 }
  Get-Content $sandboxLog
  if (Select-String -Path $sandboxLog -Pattern '^RESULT PASS' -Quiet) { exit 0 } else { exit 1 }
}

$script:failures = 0
function Write-Log([string]$line) {
  Write-Host $line
  Add-Content -Path $Log -Value $line -Encoding UTF8
}
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Log "PASS  $name $detail" } else { $script:failures++; Write-Log "FAIL  $name $detail" }
}
function Skip([string]$name, [string]$why) { Write-Log "SKIP  $name ($why)" }
function Get-Default([string]$key) {
  $item = Get-Item -Path $key -ErrorAction SilentlyContinue
  if ($null -eq $item) { return '<no key>' }
  return [string]$item.GetValue('')
}
# The double-click owner: the extension key's default value. A missing key and
# an empty default both mean no owner (adding OpenWithProgids creates the key).
function Get-Owner([string]$key) {
  $value = Get-Default $key
  if ($value -eq '<no key>') { return '' }
  return $value
}
function Get-PurplUninstallEntry {
  Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
    Where-Object { $_.GetValue('DisplayName') -eq 'PURPL' -and [string]$_.GetValue('UninstallString') -like '*Uninstall PURPL.exe*' } |
    Select-Object -First 1
}
function Wait-Until([scriptblock]$condition, [int]$seconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    if (& $condition) { return $true }
    Start-Sleep -Milliseconds 500
  }
  return [bool](& $condition)
}
# Electron's browser process is the PURPL.exe without a --type= switch; the
# GPU, network, renderer and crashpad children all carry one. PowerShell 5.1
# unrolls a function's array output (and a lone CimInstance has no .Count),
# so callers wrap these in @().
function Get-MainProcesses {
  @(Get-CimInstance Win32_Process -Filter "Name='PURPL.exe'" | Where-Object { $_.CommandLine -notmatch '--type=' })
}
function Get-AppWindows {
  @(Get-Process PURPL -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq 'PURPL' })
}
function Get-ShortcutTarget([string]$lnk) {
  if (-not (Test-Path $lnk)) { return '<missing>' }
  return (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath
}

if (Test-Path $Log) { Remove-Item $Log }
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\purpl-desktop'
$exe = Join-Path $installDir 'PURPL.exe'
$userData = Join-Path $env:APPDATA 'PURPL'
$startMenuLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\PURPL.lnk'
$desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'PURPL.lnk'
$extensions = @('.xrk', '.xrz', '.csv')
$hklmKeyPaths = @('HKLM:\Software\Classes\purpl-desktop', 'HKLM:\Software\Classes\PURPL.Session', 'HKLM:\Software\purpl-desktop')
$interactive = (Get-Process -Id $PID).SessionId -ne 0

try {
  $Installer = (Resolve-Path $Installer).Path
  Write-Log "PURPL install test $(Get-Date -Format o) on $env:COMPUTERNAME"
  Write-Log "installer $Installer ($((Get-Item $Installer).Length) bytes, sha256 $((Get-FileHash $Installer -Algorithm SHA256).Hash))"
  $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  Write-Log "shell has an admin token: $($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)); interactive session: $interactive"

  Check 'not installed yet' (-not (Test-Path $installDir)) $installDir
  $before = @{}
  foreach ($e in $extensions) {
    $before[$e] = @{ hkcu = Get-Owner "HKCU:\Software\Classes\$e"; hkcr = Get-Owner "Registry::HKEY_CLASSES_ROOT\$e" }
    Write-Log "before $e owner HKCU=[$($before[$e].hkcu)] HKCR=[$($before[$e].hkcr)]"
  }

  Write-Log '-- install'
  if ($Direct) {
    $p = Start-Process -FilePath $Installer -ArgumentList '/S' -PassThru -Wait
    Write-Log "installer exit code $($p.ExitCode) (this shell's token)"
  } else {
    # runas takes the program and its arguments as one string and returns at
    # once, so wait on the result.
    Start-Process -FilePath runas.exe -ArgumentList "/trustlevel:0x20000 `"\`"$Installer\`" /S`"" -WindowStyle Hidden
  }
  $installed = Wait-Until { (Test-Path $exe) -and ($null -ne (Get-PurplUninstallEntry)) -and -not (Get-Process 'PURPL-Setup' -ErrorAction SilentlyContinue) } 180
  Check "silent install finished ($(if ($Direct) { 'direct' } else { 'basic-user token' }))" $installed
  Check 'installed per-user under %LOCALAPPDATA%\Programs' (Test-Path $exe) $exe
  $entry = Get-PurplUninstallEntry
  Check 'uninstall entry in HKCU' ($null -ne $entry) "$($entry.PSChildName)"
  if ($entry) { Write-Log "  DisplayVersion=$($entry.GetValue('DisplayVersion')) Publisher=$($entry.GetValue('Publisher'))" }
  $hklmUninstall = @(Get-ChildItem 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
      Where-Object { [string]$_.GetValue('UninstallString') -like '*Uninstall PURPL.exe*' })
  Check 'no machine-wide uninstall entry' ($hklmUninstall.Count -eq 0)
  $hklmKeys = @($hklmKeyPaths | Where-Object { Test-Path $_ })
  Check 'no PURPL keys under HKLM' ($hklmKeys.Count -eq 0) ($hklmKeys -join ', ')
  Check 'Start menu shortcut opens PURPL' ((Get-ShortcutTarget $startMenuLnk) -eq $exe) $startMenuLnk
  Check 'desktop shortcut opens PURPL' ((Get-ShortcutTarget $desktopLnk) -eq $exe) $desktopLnk

  $protocol = Get-Default 'HKCU:\Software\Classes\purpl-desktop\shell\open\command'
  Check 'purpl-desktop:// opens PURPL (HKCU)' ($protocol -like "*$exe*") $protocol
  Check 'purpl-desktop is a URL protocol' ($null -ne (Get-ItemProperty 'HKCU:\Software\Classes\purpl-desktop' -Name 'URL Protocol' -ErrorAction SilentlyContinue))
  foreach ($e in $extensions) {
    $owp = Get-Item "HKCU:\Software\Classes\$e\OpenWithProgids" -ErrorAction SilentlyContinue
    Check "$e lists PURPL in Open with" ($null -ne $owp -and $owp.GetValueNames() -contains 'PURPL.Session')
    $verb = Get-Default "HKCU:\Software\Classes\SystemFileAssociations\$e\shell\PURPL.Open\command"
    Check "$e has the Open with PURPL verb" ($verb -like "*$exe*")
    Check "$e double-click owner unchanged" ((Get-Owner "HKCU:\Software\Classes\$e") -eq $before[$e].hkcu -and (Get-Owner "Registry::HKEY_CLASSES_ROOT\$e") -eq $before[$e].hkcr) "HKCR=[$(Get-Owner "Registry::HKEY_CLASSES_ROOT\$e")]"
  }

  # A silent install does not run the app (runAfterFinish needs the UI), so
  # this launch is the first.
  Write-Log '-- launch'
  Check 'the silent install did not start the app' (@(Get-MainProcesses).Count -eq 0)
  $launchedAt = Get-Date
  Start-Process -FilePath $exe
  Check 'app process running' (Wait-Until { @(Get-MainProcesses).Count -eq 1 } 30) "main processes=$(@(Get-MainProcesses).Count)"
  if ($interactive) {
    Check 'app window "PURPL" is open' (Wait-Until { @(Get-AppWindows).Count -ge 1 } 30)
  } else {
    Skip 'app window "PURPL" is open' 'no interactive desktop'
  }
  $fresh = Wait-Until { (Test-Path $userData) -and @(Get-ChildItem $userData | Where-Object { $_.LastWriteTime -ge $launchedAt.AddSeconds(-2) }).Count -gt 0 } 20
  Check 'the app writes %APPDATA%\PURPL' $fresh $userData

  Start-Process -FilePath $exe
  Start-Sleep -Seconds 6
  Check 'a second launch leaves one app (single instance)' (@(Get-MainProcesses).Count -eq 1) "main processes=$(@(Get-MainProcesses).Count)"
  if ($interactive) { Check 'still one window' (@(Get-AppWindows).Count -eq 1) "windows=$(@(Get-AppWindows).Count)" }

  $closed = $false
  if ($interactive) {
    Get-AppWindows | ForEach-Object { [void]$_.CloseMainWindow() }
    $closed = Wait-Until { @(Get-MainProcesses).Count -eq 0 } 15
  }
  if (-not $closed) { Get-Process PURPL -ErrorAction SilentlyContinue | Stop-Process -Force }
  Check "app quit ($(if ($closed) { 'window closed' } else { 'process stopped' }))" (Wait-Until { -not (Get-Process PURPL -ErrorAction SilentlyContinue) } 15)

  Write-Log '-- uninstall'
  $marker = Join-Path $userData 'install-test-marker.txt'
  Set-Content -Path $marker -Value 'kept across uninstall' -Encoding UTF8
  $uninstaller = Join-Path $installDir 'Uninstall PURPL.exe'
  $p = Start-Process -FilePath $uninstaller -ArgumentList '/currentuser', '/S' -PassThru -Wait
  Write-Log "uninstaller exit code $($p.ExitCode)"
  $gone = Wait-Until { -not (Test-Path $exe) -and $null -eq (Get-PurplUninstallEntry) } 60
  Check 'app files and uninstall entry removed' $gone
  Check 'shortcuts removed' (-not (Test-Path $startMenuLnk) -and -not (Test-Path $desktopLnk))
  Check '%APPDATA%\PURPL kept' ((Test-Path $userData) -and (Test-Path $marker)) $userData
  Check 'purpl-desktop:// removed' (-not (Test-Path 'HKCU:\Software\Classes\purpl-desktop'))
  Check 'PURPL.Session removed' (-not (Test-Path 'HKCU:\Software\Classes\PURPL.Session'))
  foreach ($e in $extensions) {
    $owp = Get-Item "HKCU:\Software\Classes\$e\OpenWithProgids" -ErrorAction SilentlyContinue
    Check "$e Open with entry removed" ($null -eq $owp -or -not ($owp.GetValueNames() -contains 'PURPL.Session'))
    Check "$e verb removed" (-not (Test-Path "HKCU:\Software\Classes\SystemFileAssociations\$e\shell\PURPL.Open"))
    Check "$e double-click owner still unchanged" ((Get-Owner "HKCU:\Software\Classes\$e") -eq $before[$e].hkcu -and (Get-Owner "Registry::HKEY_CLASSES_ROOT\$e") -eq $before[$e].hkcr)
  }
  Remove-Item $marker -ErrorAction SilentlyContinue
} catch {
  $script:failures++
  Write-Log "FAIL  the test itself stopped: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
}

if ($script:failures -eq 0) { Write-Log 'RESULT PASS'; exit 0 } else { Write-Log "RESULT FAIL ($script:failures)"; exit 1 }
