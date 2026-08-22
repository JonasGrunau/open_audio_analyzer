# make_installer.ps1 — build Open Audio Analyzer for Windows and wrap it and
# the VST3 in an installer whose plug-in row is a checkbox.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:  pwsh packaging/windows/make_installer.ps1 [-SkipBuild] [-Plugins <dir>]
# Output: build\packaging\Open Audio Analyzer-<version>-windows-x64.exe
#
# <dir> holds the VST3\ directory, which is the layout both of
# plugin\build\OaaPlugin_artefacts\Release and of the oaa-plugin-Windows.zip
# that ci.yml's plugin job uploads. Defaults to the first.
#
# ---------------------------------------------------------------------------
# Inno Setup, and why not WiX
#
# WiX produces an MSI, which is what an IT department wants for a silent
# machine-wide deployment, and it costs an XML dialect and a build step to
# say what twelve lines of oaa.iss say. Nobody deploys a metering plug-in
# through Group Policy. Inno is what the audio industry ships and what a
# musician has already clicked through a hundred times.
#
# ---------------------------------------------------------------------------
# Signing, and the part signing does not fix
#
#   OAA_WINDOWS_CERT         path to a .pfx. Your own machine.
#   OAA_WINDOWS_CERT_BASE64  base64 of that .pfx. A runner, which has no file
#                            to point at — the same distinction that made
#                            OAA_NOTARY_PROFILE read as configured and do
#                            nothing for three macOS releases. Whichever is
#                            set is used; base64 wins if both are.
#   OAA_WINDOWS_CERT_PASS    the export password, for either form.
#
# Both the application executable and the finished installer are signed, in
# that order — the first has to happen before the second packs it, or the
# signature is not in what ships.
#
# **An Authenticode signature does not remove SmartScreen.** A standard OV
# certificate produces "Windows protected your PC" until the installer has
# accumulated download reputation, which takes weeks and resets when the
# certificate does. Only an EV certificate carries reputation from the first
# download. So an unsigned build and a freshly-signed one look identical to
# the first person who runs either, and the difference is that one of them
# stops warning eventually. Worth knowing before buying the cheaper one.
#
# With no certificate the installer is still produced, unsigned, and this says
# so rather than implying otherwise.

param(
  [switch]$SkipBuild,
  [string]$Plugins = 'plugin\build\OaaPlugin_artefacts\Release'
)

$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Set-Location $root

$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value.Split('+')[0].Trim()
$bundle = 'build\windows\x64\runner\Release'
$out = 'build\packaging'
$staging = "$out\inno-staging"
$vst3 = Join-Path $Plugins 'VST3\Open Audio Analyzer.vst3'
$setup = "$out\Open Audio Analyzer-$version-windows-x64.exe"

if (-not $SkipBuild) {
  Write-Host '==> flutter build windows --release'
  flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw 'flutter build failed' }
}

if (-not (Test-Path $bundle)) {
  throw "make_installer: $bundle does not exist. Build first, or drop -SkipBuild."
}

# Required, not optional. An installer that quietly ships without its plug-in
# is indistinguishable from one that has it until somebody opens a DAW, and
# the download page cannot tell them apart at all.
if (-not (Test-Path $vst3)) {
  Write-Host "make_installer: $vst3 does not exist." -ForegroundColor Red
  Write-Host '  The plug-in is the point of this installer. Build it with:'
  Write-Host '    cmake -B plugin\build -S plugin -DCMAKE_BUILD_TYPE=Release'
  Write-Host '    cmake --build plugin\build --config Release'
  Write-Host '  or point -Plugins at an unpacked oaa-plugin-Windows.zip.'
  throw 'no VST3 to package'
}

New-Item -ItemType Directory -Force -Path $staging | Out-Null

# --- Licences --------------------------------------------------------------
#
# Generated rather than held, so it cannot go stale against LICENSE. The
# installer carries binaries under three licences and the plug-in's is the
# strictest of them; a notice naming only the application's would be wrong
# about the bundle this format exists to install.

$notice = @"
Open Audio Analyzer

This installer places binaries under more than one licence:

  The application                    GPL-3.0-or-later
  The VST3 plug-in                   AGPL-3.0-or-later, because it links JUCE
  The DSP engine and domain packages MIT
  The bundled fonts                  SIL OFL 1.1

Corresponding Source for every binary here is the tagged commit at
https://github.com/JonasGrunau/open_audio_analyzer, which also carries the
full text of each licence above.

The GNU General Public License, version 3, follows.

---------------------------------------------------------------------------

"@
$licence = "$staging\LICENSE.txt"
Set-Content -Path $licence -Value ($notice + (Get-Content LICENSE -Raw)) -Encoding UTF8

# --- Signing, first half ---------------------------------------------------

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

$signed = $false
$pfx = $null
if ($env:OAA_WINDOWS_CERT_BASE64) {
  $pfx = Join-Path $staging 'signing.pfx'
  [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:OAA_WINDOWS_CERT_BASE64))
  if ((Get-Item $pfx).Length -eq 0) {
    throw 'make_installer: OAA_WINDOWS_CERT_BASE64 did not decode to anything.'
  }
} elseif ($env:OAA_WINDOWS_CERT -and (Test-Path $env:OAA_WINDOWS_CERT)) {
  $pfx = $env:OAA_WINDOWS_CERT
}

if ($pfx) {
  if (-not $env:OAA_WINDOWS_CERT_PASS) {
    throw 'make_installer: a certificate is set and OAA_WINDOWS_CERT_PASS is not.'
  }
  $signtool = Find-SdkTool 'signtool.exe'
  Write-Host '==> signtool the application'
  # RFC 3161 timestamping, not the legacy /t. Without a timestamp of either
  # kind every signature expires with the certificate, and installers that
  # were fine last year start warning.
  & $signtool sign /fd sha256 /td sha256 /tr http://timestamp.digicert.com `
    /f $pfx /p $env:OAA_WINDOWS_CERT_PASS `
    "$bundle\OpenAudioAnalyzer.exe"
  if ($LASTEXITCODE -ne 0) { throw 'signtool failed on the application' }
  $signed = $true
} else {
  Write-Host '==> no certificate set: the application is not signed.'
}

# --- Compile ---------------------------------------------------------------

$iscc = Get-Command iscc.exe -ErrorAction SilentlyContinue
if (-not $iscc) {
  $candidates = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
  ) | Where-Object { Test-Path $_ }
  if (-not $candidates) {
    Write-Host 'make_installer: ISCC.exe not found.' -ForegroundColor Red
    Write-Host '  Inno Setup ships on the GitHub windows runner images. On a'
    Write-Host '  machine that has not got it:  winget install JRSoftware.InnoSetup'
    throw 'Inno Setup is not installed'
  }
  $iscc = $candidates[0]
} else {
  $iscc = $iscc.Source
}

New-Item -ItemType Directory -Force -Path $out | Out-Null
Remove-Item $setup -ErrorAction SilentlyContinue

Write-Host "==> $iscc"
& $iscc `
  "/DAppVersion=$version" `
  "/DBundleDir=$(Resolve-Path $bundle)" `
  "/DVst3Dir=$(Resolve-Path $vst3)" `
  "/DLicenseFile=$(Resolve-Path $licence)" `
  "/DOutDir=$(Resolve-Path $out)" `
  packaging\windows\oaa.iss
if ($LASTEXITCODE -ne 0) { throw 'iscc failed' }

if (-not (Test-Path $setup)) { throw "make_installer: iscc produced no $setup" }

# --- Signing, second half --------------------------------------------------

if ($signed) {
  $signtool = Find-SdkTool 'signtool.exe'
  Write-Host '==> signtool the installer'
  & $signtool sign /fd sha256 /td sha256 /tr http://timestamp.digicert.com `
    /f $pfx /p $env:OAA_WINDOWS_CERT_PASS $setup
  if ($LASTEXITCODE -ne 0) { throw 'signtool failed on the installer' }

  # The gate, on the spot. A build that produced an installer carrying a
  # signature Windows will not accept is worse than one that produced none,
  # because nothing downstream looks again.
  Write-Host '==> signtool verify'
  & $signtool verify /pa /v $setup
  if ($LASTEXITCODE -ne 0) { throw 'the installer does not verify against its own signature' }
} else {
  Write-Host ''
  Write-Host '==> unsigned. Windows will show "Windows protected your PC" and'
  Write-Host '    the user has to click More info -> Run anyway. Set'
  Write-Host '    OAA_WINDOWS_CERT_BASE64 and OAA_WINDOWS_CERT_PASS to sign, and'
  Write-Host '    read the note above about what signing does not fix.'
}

Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
Write-Host $setup
