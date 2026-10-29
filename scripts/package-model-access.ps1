param(
  [string]$SdkRoot = 'D:\command-line-tools\sdk\default\openharmony',
  [string]$OutputDirectory = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($OutputDirectory.Length -eq 0) { $OutputDirectory = Join-Path $root 'MiniPC-Model-Access' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
$archive = "$output.zip"
if (Test-Path -LiteralPath $output) { throw "Output already exists; choose a new OutputDirectory: $output" }
if (Test-Path -LiteralPath $archive) { throw "Archive already exists: $archive" }
$source = Join-Path $root 'tools\model-access'
$toolchains = Join-Path $SdkRoot 'toolchains'
$launchers = @('Enable-Access.bat', 'Check-Access.bat', 'Restore-Access.bat', 'launch.ps1', 'README.txt')
$scripts = @('vl-app-access.ps1', 'vl-app-access.sh')
$binaries = @('hdc.exe', 'libusb_shared.dll', 'NOTICE.txt', 'oh-uni-package.json')
foreach ($file in @($launchers | ForEach-Object { Join-Path $source $_ }) +
    @($scripts | ForEach-Object { Join-Path $PSScriptRoot $_ }) +
    @($binaries | ForEach-Object { Join-Path $toolchains $_ })) {
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Source file missing: $file" }
}
New-Item -ItemType Directory -Path $output | Out-Null
New-Item -ItemType Directory -Path (Join-Path $output 'scripts'), (Join-Path $output 'hdc') | Out-Null
foreach ($file in $launchers) { Copy-Item -LiteralPath (Join-Path $source $file) -Destination (Join-Path $output $file) }
foreach ($file in $scripts) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $output 'scripts') }
foreach ($file in $binaries) { Copy-Item -LiteralPath (Join-Path $toolchains $file) -Destination (Join-Path $output 'hdc') }
# Normalize checkout line endings for the receiving Windows/remote shell pair.
foreach ($file in Get-ChildItem -LiteralPath $output -Filter '*.bat') {
  $text = [IO.File]::ReadAllText($file.FullName) -replace '\r?\n', "`r`n"
  [IO.File]::WriteAllText($file.FullName, $text, [Text.Encoding]::ASCII)
}
$shell = Join-Path $output 'scripts\vl-app-access.sh'
[IO.File]::WriteAllText($shell, ([IO.File]::ReadAllText($shell) -replace '\r\n', "`n"), [Text.UTF8Encoding]::new($false))
$readme = Join-Path $output 'README.txt'
[IO.File]::WriteAllText($readme, [IO.File]::ReadAllText($readme), [Text.UTF8Encoding]::new($true))
$hashes = @(Get-ChildItem -LiteralPath $output -Recurse -File | Sort-Object FullName | ForEach-Object {
  '{0}  {1}' -f (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant(),
    $_.FullName.Substring($output.Length + 1).Replace('\', '/')
})
[IO.File]::WriteAllLines((Join-Path $output 'SHA256SUMS.txt'), $hashes, [Text.Encoding]::ASCII)
Compress-Archive -LiteralPath $output -DestinationPath $archive -CompressionLevel Optimal
Write-Output "Portable folder: $output"
Write-Output "Portable archive: $archive"
