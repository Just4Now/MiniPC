param(
  [ValidateSet('Start', 'Status', 'Stop')][string]$Action = 'Start',
  [ValidatePattern('^[A-Za-z0-9._:-]*$')][string]$Device = ''
)
$ErrorActionPreference = 'Stop'
$hdc = Join-Path $PSScriptRoot 'hdc\hdc.exe'
$access = Join-Path $PSScriptRoot 'scripts\vl-app-access.ps1'

try {
  foreach ($file in @($hdc, (Join-Path $PSScriptRoot 'hdc\libusb_shared.dll'), $access,
      (Join-Path $PSScriptRoot 'scripts\vl-app-access.sh'))) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Package file missing: $file. Extract the complete ZIP first." }
  }
  $lines = @(& $hdc list targets 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "HDC could not list devices: $($lines -join ' ')" }
  $targets = @($lines | ForEach-Object { ([string]$_).Trim() } |
    Where-Object { $_ -match '^[A-Za-z0-9._:-]+$' } | Select-Object -Unique)
  if ($targets.Count -eq 0) { throw 'No connected devices. Connect by USB, enable device debugging, and approve this computer on the device.' }

  Write-Host ''
  Write-Host "MiniPC Model Access - $Action"
  Write-Host 'Use only on compute devices prepared for direct NPU access.'
  if ($Action -ne 'Status') { Write-Host 'The selected compute application will be restarted.' }
  if ($Device.Length -gt 0) {
    if ($targets -notcontains $Device) { throw "Device is not connected: $Device" }
    $selected = @($Device)
  } else {
    for ($index = 0; $index -lt $targets.Count; $index++) {
      $model = @(& $hdc -t $targets[$index] shell 'param get const.product.model' 2>&1) -join ' '
      Write-Host ('  {0}. {1}  {2}' -f ($index + 1), $targets[$index], $model.Trim())
    }
    Write-Host '  0. Exit'
    $selection = Read-Host 'Device number(s), for example 1 or 1,2'
    if ($null -eq $selection -or $selection.Trim() -eq '0') { exit 0 }
    $selection = $selection.Trim()
    if ($selection -notmatch '^\d+(\s*,\s*\d+)*$') { throw 'Enter device numbers separated by commas.' }
    $numbers = @($selection -split '\s*,\s*' | ForEach-Object {
      $number = 0
      if (-not [int]::TryParse($_, [ref]$number) -or $number -lt 1 -or $number -gt $targets.Count) {
        throw 'A selected device number is outside the displayed list.'
      }
      $number
    } | Select-Object -Unique)
    $selected = @($numbers | ForEach-Object { $targets[$_ - 1] })
  }

  $failed = $false
  foreach ($target in $selected) {
    Write-Host "`nDevice: $target"
    try {
      & $access -Device $target -Action $Action -HdcPath $hdc -RestartApp:($Action -ne 'Status')
      Write-Host "Completed: $target" -ForegroundColor Green
    } catch {
      $failed = $true
      Write-Host "Failed: $target - $_" -ForegroundColor Red
    }
  }
  if ($failed) { exit 1 }
  if ($Action -eq 'Start') {
    Write-Host "`nAccess enabled. Select the installed model in the application settings."
    Write-Host 'Run Enable-Access.bat again after rebooting the device.'
  }
  exit 0
} catch {
  Write-Host "ERROR: $_" -ForegroundColor Red
  exit 1
}
