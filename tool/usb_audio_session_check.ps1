param(
    [string]$KotlinHome = $env:KOTLIN_HOME,
    [string]$JavaHome = $env:JAVA_HOME
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$compiler = if ($KotlinHome) {
    Join-Path $KotlinHome 'bin/kotlinc.bat'
} else {
    (Get-Command kotlinc -ErrorAction Stop).Source
}
$java = if ($JavaHome) { Join-Path $JavaHome 'bin/java.exe' } else {
    (Get-Command java -ErrorAction Stop).Source
}
$output = Join-Path $repoRoot 'build/usb-audio-session-contract'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$jar = Join-Path $output 'usb-audio-session-contract.jar'
$helper = Join-Path $repoRoot 'android/app/src/main/kotlin/dev/naominet/lazer/UsbAudioSessionState.kt'
$probe = Join-Path $repoRoot 'tool/validation/usb_audio_session_contract.kt'
& $compiler $helper $probe -jvm-target 17 -include-runtime -d $jar
if ($LASTEXITCODE -ne 0) { throw "Kotlin compilation failed ($LASTEXITCODE)" }
& $java -jar $jar
if ($LASTEXITCODE -ne 0) { throw "USB audio contracts failed ($LASTEXITCODE)" }
