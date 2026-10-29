param(
    [string]$ReleaseDirectory = 'build/windows/x64/runner/Release',
    [string]$OutputDirectory = 'dist'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$release = (Resolve-Path -LiteralPath $ReleaseDirectory).Path
foreach ($required in @('lazer_nextgen.exe', 'flutter_windows.dll', 'data')) {
    if (-not (Test-Path -LiteralPath (Join-Path $release $required))) {
        throw "Missing Windows bundle component: $required"
    }
}

# Cloud desktop builds must carry the native engine and its complete runtime. Fail
# here instead of publishing an artifact that silently falls back to just_audio.
$nativeEngine = @('lazer-audio.dll', 'liblazer-audio.dll') |
    Where-Object { Test-Path -LiteralPath (Join-Path $release $_) } |
    Select-Object -First 1
$nativeBridge = @('lazer-audio-bridge.dll', 'liblazer-audio-bridge.dll') |
    Where-Object { Test-Path -LiteralPath (Join-Path $release $_) } |
    Select-Object -First 1
if (-not $nativeEngine) { throw 'Missing native audio engine DLL' }
if (-not $nativeBridge) { throw 'Missing native audio bridge DLL' }
foreach ($component in @('avcodec', 'avformat', 'avutil', 'swresample')) {
    if (-not (Get-ChildItem -LiteralPath $release -Filter "$component-*.dll" -File)) {
        throw "Missing FFmpeg runtime DLL: $component"
    }
}
foreach ($required in @(
    'licenses/lazer-ffmpeg/COPYING.LGPLv2.1',
    'licenses/lazer-ffmpeg/BUILDINFO.txt'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $release $required))) {
        throw "Missing bundled FFmpeg license/build information: $required"
    }
}

# Flutter's EXE requires the entire Release bundle and the MSVC runtime.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'Visual C++ installation not found' }
$redist = Get-ChildItem -LiteralPath (Join-Path $installation 'VC/Redist/MSVC') -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $redist) { throw 'Versioned Visual C++ redistributable directory not found' }
$crt = Get-ChildItem -Path (Join-Path $redist.FullName 'x64/Microsoft.VC*.CRT') -Directory | Select-Object -First 1
if (-not $crt) { throw 'Visual C++ x64 redistributable not found' }
Get-ChildItem -LiteralPath $crt.FullName -Filter '*.dll' | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $release -Force
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$archive = Join-Path $OutputDirectory 'Lazer-Windows-x86_64.zip'
Compress-Archive -Path (Join-Path $release '*') -DestinationPath $archive -CompressionLevel Optimal -Force
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  Lazer-Windows-x86_64.zip" | Set-Content -LiteralPath "$archive.sha256" -Encoding ascii
