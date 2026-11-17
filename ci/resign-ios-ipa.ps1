<#
.SYNOPSIS
Re-signs the unsigned Lazer IPA on Windows, without Xcode.

.DESCRIPTION
The CI build produces an unsigned IPA on macOS (`--no-codesign`), and signing it
needs no Mac: `rcodesign` from the `apple-codesign` crate is a pure-Rust signer
that runs on Windows. What it does need is a signing identity and a provisioning
profile, and the profile decides which entitlements are legal.

That last point is the whole trick. iOS refuses to install a bundle whose
entitlements are not a subset of its profile's, so taking this repository's own
`Runner.entitlements` - which declares an App Group - fails with a free Apple ID
profile, because free profiles cannot carry App Groups. This script therefore
derives the entitlements *from the profile* instead: whatever the profile grants
is exactly what gets signed. The app then has no shared container, and the widget
honestly reports "not enabled" rather than showing an empty card.

Requirements:
  cargo install apple-codesign        # provides rcodesign
  A .p12 with its password, and a .mobileprovision whose App ID covers
  dev.naominet.lazer and dev.naominet.lazer.PlayCountWidget (a wildcard
  TEAMID.* profile covers both).

.EXAMPLE
  pwsh ci/resign-ios-ipa.ps1 `
      -Ipa dist/Lazer-v2.0.210-iOS-aarch64.ipa `
      -P12 dev-cert.p12 -P12Password (Read-Host -AsSecureString) `
      -Profile dev.mobileprovision `
      -Out dist/Lazer-signed.ipa
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Ipa,
    [Parameter(Mandatory = $true)][string]$P12,
    [Parameter(Mandatory = $true)][System.Security.SecureString]$P12Password,
    [Parameter(Mandatory = $true)][string]$Profile,
    [string]$Out,
    [string]$AppGroup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Require-Tool([string]$Name, [string]$Hint) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) { throw "$Name was not found. $Hint" }
    return $command.Source
}

function Read-Plist([string]$Path) {
    # plist is XML, so the XML API is the only plist reader needed on Windows.
    # The external DTD in the DOCTYPE is not fetched: DtdProcessing.Ignore keeps
    # this offline and deterministic.
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($Path, $settings)
    try {
        $document = [System.Xml.XmlDocument]::new()
        $document.Load($reader)
        return $document
    }
    finally { $reader.Dispose() }
}

$rcodesign = Require-Tool 'rcodesign' 'Install it with: cargo install apple-codesign'
if (-not (Test-Path -LiteralPath $Ipa)) { throw "missing IPA: $Ipa" }
if (-not (Test-Path -LiteralPath $P12)) { throw "missing certificate: $P12" }
if (-not (Test-Path -LiteralPath $Profile)) { throw "missing profile: $Profile" }
if (-not $Out) {
    $Out = Join-Path (Split-Path -Parent $Ipa) `
        ([System.IO.Path]::GetFileNameWithoutExtension($Ipa) + '-signed.ipa')
}
if ($AppGroup -and -not $AppGroup.StartsWith('group.')) {
    throw "-AppGroup must start with 'group.', got: $AppGroup"
}

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("lazer-resign-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null

try {
    # The profile is a CMS envelope; the plist inside it is what matters and it
    # is plain XML after the signature block, so it can be sliced out without a
    # macOS `security cms -D`.
    $profileBytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Profile))
    $profileText = [System.Text.Encoding]::UTF8.GetString($profileBytes)
    $plistStart = $profileText.IndexOf('<?xml')
    $plistEnd = $profileText.LastIndexOf('</plist>')
    if ($plistStart -lt 0 -or $plistEnd -lt 0) {
        throw "$Profile does not contain an XML plist; is it a .mobileprovision?"
    }
    $profileXmlPath = Join-Path $stage 'profile.plist'
    $profileXml = $profileText.Substring($plistStart, $plistEnd - $plistStart + '</plist>'.Length)
    [System.IO.File]::WriteAllText($profileXmlPath, $profileXml, [System.Text.UTF8Encoding]::new($false))
    $profilePlist = Read-Plist $profileXmlPath

    # The Entitlements dict is what iOS will require of the signature. Reading it
    # from the profile - rather than from this repository's Runner.entitlements -
    # is what keeps a free-Apple-ID profile installable: that profile grants no
    # App Group, so asking for one would make the install fail outright.
    $entitlementsNode = $null
    $dictNode = $profilePlist.plist.dict
    for ($index = 0; $index -lt $dictNode.ChildNodes.Count; $index++) {
        $node = $dictNode.ChildNodes[$index]
        if ($node.Name -eq 'key' -and $node.InnerText -eq 'Entitlements') {
            $entitlementsNode = $dictNode.ChildNodes[$index + 1]
            break
        }
    }
    if ($null -eq $entitlementsNode -or $entitlementsNode.Name -ne 'dict') {
        throw "$Profile has no Entitlements dictionary; it cannot sign an app."
    }

    $granted = [ordered]@{}
    $children = $entitlementsNode.ChildNodes
    # `$index + 1 -lt Count` keeps the last pair: `Count - 2` silently dropped the
    # final entitlement, which would have removed keychain-access-groups from
    # every re-signed build.
    for ($index = 0; $index + 1 -lt $children.Count; $index += 2) {
        if ($children[$index].Name -ne 'key') {
            throw "$Profile's Entitlements dictionary is malformed at entry $([int]($index / 2))."
        }
        $granted[$children[$index].InnerText] = $children[$index + 1]
    }
    Write-Host "profile grants: $($granted.Keys -join ', ')"
    if (-not $granted.Contains('application-identifier')) {
        throw "$Profile grants no application-identifier; it cannot sign an app."
    }
    if ($granted.Contains('com.apple.security.application-groups')) {
        Write-Host "  note: this profile carries an App Group, so the widget can share data."
    }
    else {
        Write-Host "  note: no App Group, so the widget will show 'not enabled'."
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory((Resolve-Path -LiteralPath $Ipa), $stage)

    $app = Join-Path $stage 'Payload/Runner.app'
    if (-not (Test-Path -LiteralPath $app)) { throw "$Ipa has no Payload/Runner.app" }

    # The profile's own entitlements are what gets signed, so nothing can be
    # requested that iOS would reject at install time.
    $signEntitlements = Join-Path $stage 'entitlements.plist'
    $writerSettings = [System.Xml.XmlWriterSettings]::new()
    $writerSettings.Indent = $true
    $writerSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $writer = [System.Xml.XmlWriter]::Create($signEntitlements, $writerSettings)
    try {
        $writer.WriteStartDocument()
        # No DOCTYPE: XmlWriter appends an empty internal subset (`[]`) to it, and
        # a plist needs none. codesign and rcodesign both accept it either way,
        # but the shorter form is what Xcode itself writes.
        $writer.WriteStartElement('plist')
        $writer.WriteAttributeString('version', '1.0')
        $writer.WriteStartElement('dict')
        foreach ($entry in $granted.GetEnumerator()) {
            $writer.WriteElementString('key', [string]$entry.Key)
            # WriteTo copies the value subtree - <string>, <true/>, <array> -
            # exactly as the profile declared it.
            $entry.Value.WriteTo($writer)
        }
        $writer.WriteEndElement()
        $writer.WriteEndElement()
        $writer.WriteEndDocument()
    }
    finally { $writer.Dispose() }

    if ($AppGroup) {
        # Only reachable with a profile that carries the group; the script says
        # so above. The widget reads this value from Info.plist, so it is set
        # here rather than recompiled.
        foreach ($bundle in @($app) + (Get-ChildItem -LiteralPath $app -Recurse -Filter '*.appex' -Directory | ForEach-Object { $_.FullName })) {
            $infoPath = Join-Path $bundle 'Info.plist'
            $info = Read-Plist $infoPath
            $node = $info.plist.dict.ChildNodes | Where-Object { $_.Name -eq 'key' -and $_.InnerText -eq 'LazerAppGroupIdentifier' }
            if ($node) { $node.NextSibling.InnerText = $AppGroup }
            else {
                $key = $info.CreateElement('key'); $key.InnerText = 'LazerAppGroupIdentifier'
                $val = $info.CreateElement('string'); $val.InnerText = $AppGroup
                [void]$info.plist.dict.AppendChild($key); [void]$info.plist.dict.AppendChild($val)
            }
            $infoSettings = [System.Xml.XmlWriterSettings]::new()
            $infoSettings.Indent = $true
            $infoSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
            $writer = [System.Xml.XmlWriter]::Create($infoPath, $infoSettings)
            try { $info.Save($writer) } finally { $writer.Dispose() }
        }
        Write-Host "app group set to $AppGroup"
    }

    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($P12Password))
    $passwordFile = Join-Path $stage 'p12-password.txt'
    [System.IO.File]::WriteAllText($passwordFile, $password, [System.Text.UTF8Encoding]::new($false))
    $password = $null

    # Nested code first; the enclosing bundle's signature seals it. rcodesign
    # signs one bundle per call, the same rule codesign follows.
    $nested = @()
    $nested += Get-ChildItem -LiteralPath $app -Recurse -Filter '*.appex' -Directory | ForEach-Object { $_.FullName }
    $nested += Get-ChildItem -LiteralPath $app -Recurse -Filter '*.framework' -Directory | ForEach-Object { $_.FullName }
    $nested += Get-ChildItem -LiteralPath $app -Recurse -Filter '*.dylib' -File | ForEach-Object { $_.FullName }

    $targets = @($nested) + @($app)
    foreach ($target in $targets) {
        Write-Host "signing $(Split-Path -Leaf $target)"
        & $rcodesign sign `
            --p12-file $P12 `
            --p12-password-file $passwordFile `
            --entitlements-xml-file $signEntitlements `
            $target
        if ($LASTEXITCODE -ne 0) { throw "rcodesign failed for $target" }
    }

    # Read the signature back: an entitlement the profile does not allow is
    # dropped silently, which is exactly how a re-signed widget ends up empty.
    $printed = & $rcodesign print-signature-info (Join-Path $app 'Runner') 2>&1 | Out-String
    if ($printed -notmatch 'com\.apple\.developer\.team-identifier') {
        throw "the signed binary carries no team identifier; check the certificate and profile."
    }

    if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $stage, $Out, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    Write-Host "wrote $Out"

    # The packaging check this repository already ships understands the result.
    python ci/verify-ios-bundle.py --ipa $Out
}
finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
