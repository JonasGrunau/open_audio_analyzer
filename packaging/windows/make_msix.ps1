# make_msix.ps1 — build Open Audio Analyzer for Windows and pack it as an msix.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:  pwsh packaging/windows/make_msix.ps1 [-SkipBuild]
# Output: build/packaging/Open Audio Analyzer-<version>-windows-x64.msix
#
# ---------------------------------------------------------------------------
# No pub package does this, on purpose
#
# `msix` on pub would replace this file with a block of YAML in pubspec.yaml. It
# would also be a dependency that exists only to run at release time, in a
# repository whose dependency rule says anything wanting to be one is weighed
# against writing it. What it does is substitute two strings into a manifest and
# call two SDK tools, both of which are already installed on any machine that
# can build Flutter for Windows. That is this file.
#
# ---------------------------------------------------------------------------
# Signing, and the thing that will actually bite
#
#   OAA_WINDOWS_CERT      path to a .pfx
#   OAA_WINDOWS_CERT_PASS its password
#   OAA_WINDOWS_PUBLISHER the certificate's subject, e.g. "CN=Jonas Grunau"
#
# **`Publisher` in the manifest must equal the certificate's subject exactly.**
# Not the display name, not a tidied version of it — the DN as the certificate
# carries it, spaces and all. A mismatch fails at install time with 0x800B0100,
# which reads as "the signature is invalid" and sends people to look at the
# certificate rather than at a string. `certutil -dump` prints the subject.
#
# Without a certificate the package is still produced, unsigned. Windows will
# not install it. That is a useful artefact for checking the layout and a
# useless one for a user, and the script says so rather than implying success.

param([switch]$SkipBuild)

$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Set-Location $root

$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value.Split('+')[0].Trim()
$bundle = 'build\windows\x64\runner\Release'
$out = 'build\packaging'
$staging = "$out\msix-staging"
$msix = "$out\Open Audio Analyzer-$version-windows-x64.msix"

if (-not $SkipBuild) {
  Write-Host '==> flutter build windows --release'
  flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw 'flutter build failed' }
}

if (-not (Test-Path $bundle)) {
  throw "make_msix: $bundle does not exist. Build first, or drop -SkipBuild."
}

# --- SDK tools -------------------------------------------------------------
#
# Found by version rather than assumed: a runner may carry several SDKs, and the
# newest is the one whose makeappx understands the newest manifest schema.

function Find-SdkTool([string]$name) {
  $roots = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
    "$env:ProgramFiles\Windows Kits\10\bin"
  ) | Where-Object { Test-Path $_ }

  $found = $roots |
    ForEach-Object { Get-ChildItem $_ -Filter $name -Recurse -ErrorAction SilentlyContinue } |
    Where-Object { $_.FullName -match '\\x64\\' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1

  if (-not $found) { throw "$name not found. Install the Windows 10/11 SDK." }
  return $found.FullName
}

$makeappx = Find-SdkTool 'makeappx.exe'
$signtool = Find-SdkTool 'signtool.exe'

# --- Stage -----------------------------------------------------------------

Write-Host '==> staging'
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging -Force | Out-Null

Copy-Item "$bundle\*" $staging -Recurse
Copy-Item 'packaging\windows\images' "$staging\images" -Recurse

# The licences travel with the binary. Both bundled font families are SIL OFL
# 1.1 and their licence files must ship with anything they are embedded in.
New-Item -ItemType Directory -Path "$staging\licences" -Force | Out-Null
Copy-Item 'LICENSE' "$staging\licences\LICENSE.txt"
Get-ChildItem 'assets\fonts\*-LICENSE.txt' -ErrorAction SilentlyContinue |
  Copy-Item -Destination "$staging\licences"

# Windows wants four parts and rejects a three-part version with a message that
# does not mention the version.
$publisher = if ($env:OAA_WINDOWS_PUBLISHER) { $env:OAA_WINDOWS_PUBLISHER } else { 'CN=Open Audio Analyzer Development' }
(Get-Content 'packaging\windows\AppxManifest.xml' -Raw).
  Replace('{{VERSION}}', "$version.0").
  Replace('{{PUBLISHER}}', $publisher) |
  Set-Content "$staging\AppxManifest.xml" -Encoding UTF8

# --- Pack ------------------------------------------------------------------

Write-Host '==> makeappx'
New-Item -ItemType Directory -Path $out -Force | Out-Null
if (Test-Path $msix) { Remove-Item $msix -Force }

& $makeappx pack /d $staging /p $msix /o
if ($LASTEXITCODE -ne 0) { throw 'makeappx failed' }

Remove-Item $staging -Recurse -Force

# --- Sign ------------------------------------------------------------------

if ($env:OAA_WINDOWS_CERT) {
  Write-Host '==> signtool'
  # SHA256 because SHA1 packages are refused outright by current Windows, and
  # a timestamp so the signature outlives the certificate.
  & $signtool sign /fd SHA256 `
    /f $env:OAA_WINDOWS_CERT `
    /p $env:OAA_WINDOWS_CERT_PASS `
    /tr http://timestamp.digicert.com /td SHA256 `
    $msix
  if ($LASTEXITCODE -ne 0) { throw 'signtool failed' }
  Write-Host '==> signed'
} else {
  Write-Host '==> NOT signed. Windows will refuse to install this package.'
  Write-Host '    Set OAA_WINDOWS_CERT, OAA_WINDOWS_CERT_PASS and'
  Write-Host '    OAA_WINDOWS_PUBLISHER (the certificate subject, exactly).'
}

Write-Host $msix
