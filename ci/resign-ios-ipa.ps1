<#
.SYNOPSIS
Re-sign the unsigned Lazer IPA on Windows using rcodesign (apple-codesign 0.29+).

.DESCRIPTION
Requires Python 3 and rcodesign (`cargo install apple-codesign`). Each app and
extension needs a provisioning profile that covers its own identifier. A single
wildcard profile remains supported when it covers every target. App Groups work
only when every target's profile grants the same group; otherwise the widget
reports that sharing is not enabled. Binary Info.plist files are supported.

.EXAMPLE
pwsh ci/resign-ios-ipa.ps1 -Ipa dist/Lazer-iOS-aarch64.ipa `
  -P12 dev-cert.p12 -P12Password (Read-Host -AsSecureString) `
  -Profile app.mobileprovision `
  -ExtensionProfiles @{ 'dev.naominet.lazer.PlayCountWidget' = 'widget.mobileprovision' } `
  -AppGroup group.com.example.lazer -Out dist/Lazer-signed.ipa
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Ipa,
    [Parameter(Mandatory = $true)][string]$P12,
    [Parameter(Mandatory = $true)][System.Security.SecureString]$P12Password,
    [Parameter(Mandatory = $true)][string]$Profile,
    [hashtable]$ExtensionProfiles = @{},
    [string]$Out,
    [string]$AppGroup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
foreach ($tool in @('python', 'rcodesign')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool was not found on PATH" }
}
foreach ($inputFile in @($Ipa, $P12, $Profile)) {
    if (-not (Test-Path -LiteralPath $inputFile -PathType Leaf)) { throw "missing input file: $inputFile" }
}
if (-not $Out) {
    $Out = Join-Path ([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Ipa))) `
        ([System.IO.Path]::GetFileNameWithoutExtension($Ipa) + '-signed.ipa')
}

# The password lives outside the IPA extraction/package directory and never
# reaches argv. Free the temporary BSTR as soon as the file has been written.
$secretDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('lazer-signing-secret-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $secretDirectory | Out-Null
try {
    $passwordFile = Join-Path $secretDirectory 'p12-password.txt'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($P12Password)
    try {
        [System.IO.File]::WriteAllText($passwordFile,
            [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr), [System.Text.UTF8Encoding]::new($false))
    }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $arguments = @((Join-Path $PSScriptRoot 'resign-ios-ipa.py'), '--backend', 'rcodesign',
        '--ipa', $Ipa, '--p12', $P12, '--password-file', $passwordFile, '--profile', $Profile)
    foreach ($entry in $ExtensionProfiles.GetEnumerator()) {
        $arguments += @('--extension-profile', "$($entry.Key)=$($entry.Value)")
    }
    if ($Out) { $arguments += @('--out', $Out) }
    if ($AppGroup) { $arguments += @('--app-group', $AppGroup) }
    & python @arguments
    if ($LASTEXITCODE -ne 0) { throw "iOS re-signing failed (exit $LASTEXITCODE)" }
}
finally {
    if (Test-Path -LiteralPath $secretDirectory) {
        $resolvedSecretDirectory = (Resolve-Path -LiteralPath $secretDirectory).Path
        if ($resolvedSecretDirectory -ne [System.IO.Path]::GetFullPath($secretDirectory)) {
            throw 'The signing secret cleanup path did not resolve to its original temporary directory'
        }
        Remove-Item -LiteralPath $secretDirectory -Recurse -Force
    }
}
