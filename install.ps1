<#
  Installs Drift for the current user, from wherever this folder was unzipped:

    1. copies the app into %LOCALAPPDATA%\Programs\Drift, so the downloaded
       folder can be deleted afterwards;
    2. adds it to Startup (runs at every sign-in) and to the Start menu;
    3. starts it - replacing an older copy if one is running - and checks it
       stayed up.

  Running it again updates an existing install. No admin rights; nothing
  outside the user's own profile.
#>
param([switch]$Uninstall, [switch]$Quiet)  # -Quiet: print instead of message boxes (for testing)

Add-Type -AssemblyName System.Windows.Forms
$source = $PSScriptRoot
$appDir = Join-Path $env:LOCALAPPDATA 'Programs\Drift'
$launcher = Join-Path $appDir 'Start-Drift.vbs'
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Drift.lnk'
$menuLink = Join-Path ([Environment]::GetFolderPath('Programs')) 'Drift.lnk'
$files = @('drift.ps1', 'Start-Drift.vbs', 'install.ps1', 'install.cmd', 'uninstall.cmd', 'README.md')

function Get-Running {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*drift.ps1*' }
}

# A plain true/false. (Counting what Get-Running returns is unreliable: a
# single result is unwrapped from its array, and .Count on one CIM process
# object comes back empty.)
function Test-Running { [bool](Get-Running | Select-Object -First 1) }

function Stop-Drift {
  Get-Running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  for ($i = 0; $i -lt 10 -and (Test-Running); $i++) { Start-Sleep -Milliseconds 300 }
}

function Say([string]$text, [string]$icon = 'Information') {
  if ($Quiet) { Write-Output "[$icon] $text"; return }
  [void][System.Windows.Forms.MessageBox]::Show($text, 'Drift', 'OK', $icon)
}

function New-Link([string]$path) {
  $ws = New-Object -ComObject WScript.Shell
  $s = $ws.CreateShortcut($path)
  $s.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
  $s.Arguments = '"' + $launcher + '"'
  $s.WorkingDirectory = $appDir
  $s.Description = 'Drift - screen break and water reminders'
  $s.IconLocation = (Join-Path $env:WINDIR 'System32\imageres.dll') + ',109'
  $s.Save()
}

# ── Uninstall ────────────────────────────────────────────────────────────────

if ($Uninstall) {
  Set-Location $env:TEMP   # never sit inside the folder being removed
  Stop-Drift
  Remove-Item $startupLink, $menuLink -Force -ErrorAction SilentlyContinue
  Remove-Item $appDir -Recurse -Force -ErrorAction SilentlyContinue
  if ((Test-Path $startupLink) -or (Test-Running)) {
    Say 'Could not fully remove Drift. Close it from the tray icon (Exit) and try again.' 'Warning'
    exit 1
  }
  Say "Drift has been removed.`n`nYour history and settings are kept in $env:APPDATA\Drift - delete that folder too if you want them gone."
  exit
}

# ── Install / update ─────────────────────────────────────────────────────────

$problems = @()

$missing = $files | Where-Object { -not (Test-Path (Join-Path $source $_)) }
if ($missing) {
  Say ("Some Drift files are missing next to install.cmd:`n`n" + ($missing -join "`n") + "`n`nUnzip the whole Drift folder first, then run install.cmd from inside it.") 'Error'
  exit 1
}

# An older copy may be running from the folder about to be replaced.
$wasRunning = Test-Running
if ($wasRunning) { Stop-Drift }

# 1. Copy the app into the user's profile (skipped when already running from there).
try {
  if ((Resolve-Path $source).Path.TrimEnd('\') -ne $appDir.TrimEnd('\')) {
    New-Item -ItemType Directory -Force -Path $appDir | Out-Null
    foreach ($f in $files) { Copy-Item (Join-Path $source $f) (Join-Path $appDir $f) -Force }
  }
  # Files that came by email, Teams or a browser carry a "downloaded from the
  # internet" mark that can make Windows block or warn about them.
  Get-ChildItem $appDir -File | Unblock-File -ErrorAction SilentlyContinue
} catch {
  $problems += "Could not copy Drift into $appDir`: $($_.Exception.Message)"
}

# 2. Startup and Start menu shortcuts.
try { New-Link $startupLink; New-Link $menuLink } catch { $problems += "Could not create shortcuts: $($_.Exception.Message)" }
if (-not (Test-Path $startupLink)) { $problems += "The Startup shortcut is missing ($startupLink)." }

# 3. Start it and make sure it stays up.
if (-not $problems.Count) {
  Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + $launcher + '"')
  # The first start compiles the card graphics; give it a few seconds.
  for ($i = 0; $i -lt 20 -and -not (Test-Running); $i++) { Start-Sleep -Milliseconds 500 }
  Start-Sleep -Seconds 3
  if (-not (Test-Running)) {
    $log = Join-Path $env:APPDATA 'Drift\error.log'
    $detail = if (Test-Path $log) { "`n`nLast error:`n" + ((Get-Content $log -Tail 3) -join "`n") } else { '' }
    $problems += "Drift did not stay running after starting.$detail"
  }
}

if ($problems.Count) {
  Say ("Drift could not be installed:`n`n- " + ($problems -join "`n- ") + "`n`nSend this message to whoever shared Drift with you.") 'Error'
  exit 1
}

$verb = if ($wasRunning) { 'updated' } else { 'installed' }
Say ("Drift is $verb and running.`n`n" +
  "Look for the blue water drop near the clock. If you do not see it, click the small ^ arrow " +
  "on the taskbar - Windows 11 tucks new icons in there. Drag the drop onto the taskbar so it always shows.`n`n" +
  "It starts by itself every time you sign in, and you can also open it from the Start menu (search 'Drift').`n`n" +
  "You can delete the folder you installed from.")
