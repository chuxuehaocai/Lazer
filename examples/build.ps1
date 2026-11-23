# Builds importable Lazer plugin ZIPs from the example folders.
#
#   build.bat                        (Windows entry point, calls this script)
#   powershell -ExecutionPolicy Bypass -File .\build.ps1 [output-dir]
#
# Each archive has manifest.json at its root, as the plugin manager requires.
# Output: dist/<plugin-id>-<version>.zip

[CmdletBinding()]
param(
  [string]$OutputDirectory = "dist"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$output = Join-Path $root $OutputDirectory
New-Item -ItemType Directory -Force -Path $output | Out-Null

$projects = @("gateway-mock", "theme-plugin")
foreach ($project in $projects) {
  $source = Join-Path $root $project
  $manifestPath = Join-Path $source "manifest.json"
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Missing manifest: $manifestPath"
  }

  $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $zipPath = Join-Path $output ("{0}-{1}.zip" -f $manifest.id, $manifest.version)
  if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
  }

  $archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    $files = Get-ChildItem -LiteralPath $source -Recurse -File
    foreach ($file in $files) {
      $relative = $file.FullName.Substring($source.Length + 1).Replace("\", "/")
      [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $archive, $file.FullName, $relative,
        [System.IO.Compression.CompressionLevel]::Optimal
      ) | Out-Null
    }
  }
  finally {
    $archive.Dispose()
  }

  $size = (Get-Item -LiteralPath $zipPath).Length
  Write-Host ("{0} -> {1} ({2} bytes)" -f $project, $zipPath, $size)
}