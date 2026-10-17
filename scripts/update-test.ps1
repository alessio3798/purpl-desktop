<#
.SYNOPSIS
  Proves the auto-update path on a clean PC: installs an older published
  PURPL, launches it, waits for its updater to download the latest release,
  closes the window, and checks the installed app is now the new version.
  Exit code 0 only when every check passes.

.DESCRIPTION
  The app's updater (electron-updater) reads latest.yml from the public
  releases, downloads in the background and installs when the app quits
  (autoInstallOnAppQuit). Closing the last window quits the app, so a
  window close is exactly what a driver does.

  If there is no window to close (no interactive desktop), the app is
  stopped and the downloaded installer is run the way the updater runs it
  (/S --updated). The log says which path was taken.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\update-test.ps1 -Installer D:\old\PURPL-Setup.exe -From 0.1.0-beta.2 -To 0.1.0-beta.3
#>
param(
  [Parameter(Mandatory)] [string]$Installer,
  [Parameter(Mandatory)] [string]$From,
  [Parameter(Mandatory)] [string]$To,
  [string]$Log = (Join-Path $PWD 'logs\update-test.log'),
  [int]$DownloadTimeoutSec = 600
)

$ErrorActionPreference = 'Stop'
$From = $From.TrimStart('v')
$To = $To.TrimStart('v')
New-Item -ItemType Directory -Force (Split-Path $Log) | Out-Null
Set-Content $Log "update-test $From -> $To, $(Get-Date -Format o)" -Encoding utf8
$script:failed = $false

function Note([string]$msg) { Write-Host $msg; Add-Content $Log $msg -Encoding utf8 }
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  $line = "$(if ($ok) { 'PASS' } else { 'FAIL' })  $name$(if ($detail) { "  ($detail)" })"
  Note $line
  if (-not $ok) { $script:failed = $true }
  return $ok
}
function Wait-Until([scriptblock]$cond, [int]$seconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) { if (& $cond) { return $true }; Start-Sleep -Seconds 2 }
  return [bool](& $cond)
}

$installDir = Join-Path $env:LOCALAPPDATA 'Programs\purpl-desktop'
$exe = Join-Path $installDir 'PURPL.exe'
$mainLog = Join-Path $env:APPDATA 'PURPL\logs\main.log'
function Installed-Version {
  # The exe's file version is numeric (0.1.0.0); the uninstall entry the
  # installer writes carries the full version, prerelease included.
  if (-not (Test-Path $exe)) { return $null }
  $entry = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
    Get-ItemProperty | Where-Object { $_.DisplayName -like 'PURPL*' } | Select-Object -First 1
  if ($entry) { return [string]$entry.DisplayVersion }
  return $null
}
function Updater-Lines {
  if (-not (Test-Path $mainLog)) { return @() }
  return @(Get-Content $mainLog | Where-Object { $_ -match 'updater' })
}

# 1. Install the old version silently, per user.
$p = Start-Process -FilePath $Installer -ArgumentList '/S' -PassThru -Wait
Check "old installer exited 0" ($p.ExitCode -eq 0) "exit $($p.ExitCode)" | Out-Null
$v = Installed-Version
if (-not (Check "installed version is $From" ($v -eq $From) "found $v")) { exit 1 }

# 2. Launch it and wait for the updater to download the new version.
Start-Process -FilePath $exe | Out-Null
Check 'app launched' (Wait-Until { Get-Process PURPL -ErrorAction SilentlyContinue } 30) | Out-Null
$ready = Wait-Until { (Updater-Lines | Where-Object { $_ -match [regex]::Escape("$To is ready") }).Count -gt 0 } $DownloadTimeoutSec
Note '--- updater lines in main.log ---'
Updater-Lines | ForEach-Object { Note "  $_" }
Note '---'
if (-not (Check "updater downloaded $To and reported it ready" $ready)) {
  Get-Process PURPL -ErrorAction SilentlyContinue | Stop-Process -Force
  exit 1
}

$pending = Get-ChildItem $env:LOCALAPPDATA -Directory -Filter '*-updater' -ErrorAction SilentlyContinue |
  ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'pending') -Filter '*.exe' -ErrorAction SilentlyContinue } |
  Select-Object -First 1
Check 'downloaded installer is in the updater pending folder' ($null -ne $pending) "$($pending.FullName)" | Out-Null

# 3. Quit the way a driver does: close the window. The update installs on quit.
$windows = @(Get-Process PURPL -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
$closed = $false
if ($windows.Count -gt 0) {
  $windows | ForEach-Object { [void]$_.CloseMainWindow() }
  $closed = Wait-Until { -not (Get-Process PURPL -ErrorAction SilentlyContinue) } 30
}
if ($closed) {
  Note 'path: window closed, install-on-quit'
} else {
  Note 'path: no closable window (no interactive desktop); app stopped, pending installer run as the updater runs it'
  Get-Process PURPL -ErrorAction SilentlyContinue | Stop-Process -Force
  Wait-Until { -not (Get-Process PURPL -ErrorAction SilentlyContinue) } 15 | Out-Null
  if ($pending) { Start-Process -FilePath $pending.FullName -ArgumentList '/S', '--updated' -Wait | Out-Null }
}

# 4. The installed app is now the new version.
$updated = Wait-Until { (Installed-Version) -eq $To } 240
Check "installed version is now $To" $updated "found $(Installed-Version)" | Out-Null

# 5. The updated app starts, then tidy up.
if ($updated) {
  Wait-Until { -not (Get-Process 'PURPL-Setup*', '*purpl*setup*' -ErrorAction SilentlyContinue) } 60 | Out-Null
  if (-not (Get-Process PURPL -ErrorAction SilentlyContinue)) { Start-Process -FilePath $exe | Out-Null }
  Check "updated app runs" (Wait-Until { Get-Process PURPL -ErrorAction SilentlyContinue } 30) | Out-Null
  Start-Sleep -Seconds 5
  Get-Process PURPL -ErrorAction SilentlyContinue | Stop-Process -Force
}
if (Test-Path $mainLog) { Copy-Item $mainLog (Join-Path (Split-Path $Log) 'main.log') }

if ($script:failed) { Note 'RESULT: FAIL'; exit 1 }
Note 'RESULT: PASS'
exit 0
