<#
  place-vl-libs.ps1 - put the private Qwen2.5-VL prebuilt libraries where the build expects them.

  These .so files are private artefacts and are never committed, so this script does NOT
  download anything and does NOT verify contents. It only answers "can this machine build":
    1) read the expected list from apps/compute-node/entry/src/main/cpp/libs.manifest.json
    2) report missing / zero-byte entries under the target directory
    3) copy them in when -Source is given; fail with a non-zero exit if any are still missing

  Missing libraries do NOT break the build: CMake then compiles napi_engine_stub.cpp,
  the app still builds and simply runs without vision.

  IMPORTANT: keep this file ASCII-only. Windows PowerShell 5.1 reads BOM-less scripts using
  the ANSI code page; a multi-byte comment can then swallow the following line of code.

  Usage:
    .\scripts\place-vl-libs.ps1
    .\scripts\place-vl-libs.ps1 -Source 'D:\somewhere\arm64-v8a'
    $env:VL_LIBS = 'D:\somewhere\arm64-v8a'; .\scripts\place-vl-libs.ps1
#>
param(
  [string]$Source = $env:VL_LIBS,
  [string]$Project = 'apps/compute-node',
  [switch]$Force
)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$cppDir = Join-Path $repoRoot (Join-Path $Project 'entry/src/main/cpp')
$manifestPath = Join-Path $cppDir 'libs.manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  throw "Manifest not found: $manifestPath"
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$required = @($manifest.files)
if ($required.Count -eq 0) { throw "Manifest lists no files: $manifestPath" }

$targetDir = Join-Path (Join-Path $cppDir 'libs') $manifest.arch
Write-Host "manifest : $manifestPath"
Write-Host "target   : $targetDir"
Write-Host "expected : $($required.Count) libraries (arch $($manifest.arch))"

function Get-MissingLibraries([string]$Dir, [string[]]$Names) {
  $out = @()
  foreach ($name in $Names) {
    if ([string]::IsNullOrEmpty($name)) { continue }
    $path = Join-Path $Dir $name
    if ((Test-Path -LiteralPath $path -PathType Leaf) -and (Get-Item -LiteralPath $path).Length -gt 0) { continue }
    $out += $name
  }
  # Call sites wrap this with @(); do NOT return ,$out here or it nests one level deeper.
  return $out
}

$missing = @(Get-MissingLibraries $targetDir $required)
Write-Host "present  : $($required.Count - $missing.Count)/$($required.Count)"

if ($missing.Count -gt 0 -and $Source) {
  if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    throw "Source directory not found: $Source"
  }
  New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
  $copied = 0
  foreach ($name in $missing) {
    $from = Join-Path $Source $name
    if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { continue }
    $to = Join-Path $targetDir $name
    if ((Test-Path -LiteralPath $to -PathType Leaf) -and -not $Force) { continue }
    Copy-Item -LiteralPath $from -Destination $to -Force
    $copied++
  }
  Write-Host "copied   : $copied from $Source"
  $missing = @(Get-MissingLibraries $targetDir $required)
  Write-Host "present  : $($required.Count - $missing.Count)/$($required.Count)"
}

if ($missing.Count -gt 0) {
  Write-Host "missing  :"
  $missing | ForEach-Object { Write-Host "  - $_" }
  throw ("$($missing.Count) private VL libraries are missing from '$targetDir'. " +
         "Put them there, or pass -Source (or set `$env:VL_LIBS) to a directory that has them. " +
         "Without them CMake builds the text-only stub and the app runs without vision.")
}
Write-Host 'OK: all private VL libraries are in place; CMake will build the real VL engine.'
