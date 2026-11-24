<#
.SYNOPSIS
  Build, test, package and (on GitHub Actions) publish the Windows app.

.DESCRIPTION
  Used by .github/workflows/build-windows.yml. It can also run on a Windows PC
  with the .NET 10 SDK and Inno Setup 6. See docs/12-pipeline-usage.md.

  Stages: preflight -> restore -> test -> (per runtime: publish -> configure
  -> sign binaries -> portable zip -> installer) -> checksums -> publish_release.
  Cleanup runs at the end of every build and again from the workflow
  (if: always()).

  Inputs (parameters or environment variables):
    -Version / VERSION            MAJOR.MINOR.PATCH[-prerelease], e.g. 0.1.0-beta.1
    -BuildNumber / BUILD_NUMBER   digits only, 0..65535 (Windows file versions
                                  have 16-bit parts)

  App configuration (written into the published appsettings.json):
    GOOGLE_CLIENT_ID_WINDOWS       repository variable (Google "Desktop app" client)
    GOOGLE_CLIENT_SECRET_WINDOWS   repository secret (Desktop-client secret; Google
                                   documents it as not confidential, it ships in the app)
    DRIVE_ROOT_SHARED_DRIVE_NAME   repository variable (default WakeupMonster)
    DRIVE_ROOT_FOLDER_ID           repository variable (non-empty overrides the name)
  Empty values only warn; the file's defaults are kept.

  Optional Authenticode signing (unset = files named -unsigned):
    WINDOWS_CERT_PFX_BASE64, WINDOWS_CERT_PASSWORD

  Other environment:
    PUBLISH_RELEASE   1 = create draft pre-release win-v<version>-b<build>, 0 = skip.
                      Default: 1 on GitHub Actions, 0 elsewhere.
    GH_TOKEN, GITHUB_REPOSITORY   needed when publishing.
    BUILD_DIR         output directory (default <repo>/build/windows).

  Outputs (BUILD_DIR/dist):
    DriveApp-<version>-<build>-win-<arch>-setup[-unsigned].exe
    DriveApp-<version>-<build>-win-<arch>-portable[-unsigned].zip
    and a .sha256 file next to each.

  Secrets are never printed. The script never uses Set-PSDebug -Trace.

.PARAMETER Command
  build (default), preflight, cleanup or help.

.PARAMETER NoInstaller
  Non-Windows hosts only: run restore, test, publish and the portable zip, and
  skip signing and the installer (local smoke test of the script). Without it
  the script stops with exit code 3 on non-Windows hosts.

.EXAMPLE
  pwsh scripts/build-windows.ps1 -Version 0.0.1 -BuildNumber 1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'GitHub Actions workflow commands (::group::, ::add-mask::) must go to the host output.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Script parameters are read inside functions.')]
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('build', 'preflight', 'cleanup', 'help')]
  [string] $Command = 'build',
  [string] $Version = $env:VERSION,
  [string] $BuildNumber = $env:BUILD_NUMBER,
  [switch] $NoInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Native tools report failure through exit codes; Invoke-Native checks them.
$PSNativeCommandUseErrorActionPreference = $false

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$WindowsDir = Join-Path $RepoRoot 'windows'
$AppProject = Join-Path $WindowsDir 'src/DriveSync.App/DriveSync.App.csproj'
$TestProject = Join-Path $WindowsDir 'tests/DriveSync.Core.Tests/DriveSync.Core.Tests.csproj'
$IssScript = Join-Path $PSScriptRoot 'windows/DriveApp.iss'
$AppName = 'DriveApp'
$Runtimes = @('win-x64', 'win-arm64')
$InnoSetupVersion = '6.7.1'   # pinned fallback when the runner image lacks Inno Setup
$TimestampUrl = 'http://timestamp.digicert.com'

$BuildDir = if ($env:BUILD_DIR) { $env:BUILD_DIR } else { Join-Path $RepoRoot 'build/windows' }
$PublishRoot = Join-Path $BuildDir 'publish'
$DistDir = Join-Path $BuildDir 'dist'
$TempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
# Fixed path so that `cleanup`, run as a separate workflow step, finds it.
$SigningDir = Join-Path $TempRoot 'driveapp-win-signing'

$script:IsCI = $env:GITHUB_ACTIONS -eq 'true'
$script:Signed = $false
$script:Thumbprint = ''
$script:SignTool = ''
$script:Iscc = ''
$script:Publish = $false
$script:NumericVersion = ''
$script:FileVersion = ''
$script:ReleaseTag = ''
$script:Assets = [System.Collections.Generic.List[string]]::new()
$script:AppExeName = ''

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step([string] $Message) { Write-Host "==> $Message" }

function Write-Warn([string] $Message) {
  if ($script:IsCI) { Write-Host "::warning::$Message" } else { Write-Warning $Message }
}

function Exit-Build([string] $Message, [int] $Code = 1) {
  if ($script:IsCI) { Write-Host '::endgroup::'; Write-Host "::error::$Message" }
  else { [Console]::Error.WriteLine("ERROR: $Message") }
  throw [System.Management.Automation.RuntimeException]::new("build-windows: $Message (exit $Code)", $null)
}

function Enter-LogGroup([string] $Title) { if ($script:IsCI) { Write-Host "::group::$Title" } else { Write-Host "`n=== $Title ===" } }
function Exit-LogGroup { if ($script:IsCI) { Write-Host '::endgroup::' } }

# Hide a value from the GitHub Actions log.
function Add-Mask([string] $Value) { if ($script:IsCI -and $Value) { Write-Host "::add-mask::$Value" } }

function Add-Summary([string] $Line) {
  if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $Line -Encoding utf8NoBOM }
}

# Run a native command; fail with Message unless the exit code is 0.
function Invoke-Native([string] $Message, [string] $FilePath, [string[]] $Arguments) {
  Write-Step "$([System.IO.Path]::GetFileName($FilePath)) $($Arguments -join ' ')"
  # Out-Host: tool output goes to the log, never into a function's return value.
  & $FilePath @Arguments | Out-Host
  if ($LASTEXITCODE -ne 0) { Exit-Build "$Message (exit $LASTEXITCODE)." }
}

# Same, but quiet: returns @{ Code; Output } (stdout and stderr merged).
function Invoke-Capture([string] $FilePath, [string[]] $Arguments) {
  $output = & $FilePath @Arguments 2>&1 | ForEach-Object { "$_" }
  return @{ Code = $LASTEXITCODE; Output = ($output -join "`n") }
}

function Write-Usage { Get-Help -Detailed $PSCommandPath | Out-String | Write-Host }

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------

function Test-BuildInput {
  if (-not $Version) { Exit-Build "VERSION is not set (workflow input 'version', e.g. 0.0.1)." 2 }
  if (-not $BuildNumber) { Exit-Build "BUILD_NUMBER is not set (workflow input 'build_number', e.g. 1)." 2 }
  if ($Version -notmatch '^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$') {
    Exit-Build "VERSION '$Version' is not valid. Use MAJOR.MINOR.PATCH with an optional -prerelease suffix, e.g. 0.0.1 or 0.1.0-beta.1." 2
  }
  if ($BuildNumber -notmatch '^(0|[1-9][0-9]{0,4})$' -or [int]$BuildNumber -gt 65535) {
    Exit-Build "BUILD_NUMBER '$BuildNumber' is not valid. Use digits only, no leading zeros, at most 65535 (Windows file versions have 16-bit parts)." 2
  }
  $script:NumericVersion = ($Version -split '-', 2)[0]
  $script:FileVersion = "$($script:NumericVersion).$BuildNumber"
  $script:ReleaseTag = "win-v$Version-b$BuildNumber"
}

function Test-AppConfig {
  if ($env:GOOGLE_CLIENT_SECRET_WINDOWS) { Add-Mask $env:GOOGLE_CLIENT_SECRET_WINDOWS }
  if ($env:GOOGLE_CLIENT_ID_WINDOWS) {
    if ($env:GOOGLE_CLIENT_ID_WINDOWS -notmatch '^[0-9]+-[0-9A-Za-z_]+\.apps\.googleusercontent\.com$') {
      Exit-Build "GOOGLE_CLIENT_ID_WINDOWS ('$($env:GOOGLE_CLIENT_ID_WINDOWS)') is not a Google OAuth client ID (<number>-<id>.apps.googleusercontent.com)."
    }
    Write-Step "Config: Google:ClientId = $($env:GOOGLE_CLIENT_ID_WINDOWS)"
  }
  else {
    Write-Warn 'GOOGLE_CLIENT_ID_WINDOWS is empty (repository variable). The app will build but cannot sign in to Google until it is set (docs/12-pipeline-usage.md).'
  }
  if ($env:GOOGLE_CLIENT_SECRET_WINDOWS) { Write-Step 'Config: Google:ClientSecret is set (value hidden).' }
  else { Write-Warn 'GOOGLE_CLIENT_SECRET_WINDOWS is empty (repository secret). Google token exchange for the Desktop client will fail until it is set.' }
  if ($env:DRIVE_ROOT_SHARED_DRIVE_NAME) { Write-Step "Config: Drive:SharedDriveName = $($env:DRIVE_ROOT_SHARED_DRIVE_NAME)" }
  else { Write-Step 'Config: DRIVE_ROOT_SHARED_DRIVE_NAME not set; keeping the appsettings.json default (WakeupMonster).' }
  if ($env:DRIVE_ROOT_FOLDER_ID) {
    if ($env:DRIVE_ROOT_FOLDER_ID -notmatch '^[0-9A-Za-z_-]{10,}$') {
      Exit-Build "DRIVE_ROOT_FOLDER_ID ('$($env:DRIVE_ROOT_FOLDER_ID)') is not a Drive folder ID (letters, digits, - and _)."
    }
    Write-Step "Config: Drive:FolderId = $($env:DRIVE_ROOT_FOLDER_ID) (overrides the shared drive name)."
  }
}

function Test-ReleaseAbsent {
  $r = Invoke-Capture 'gh' @('release', 'view', $script:ReleaseTag, '--repo', $env:GITHUB_REPOSITORY, '--json', 'tagName')
  if ($r.Code -eq 0) { Exit-Build "Release $($script:ReleaseTag) already exists in $($env:GITHUB_REPOSITORY). Use a new build_number (or delete the old draft)." }
  if ($r.Output -notmatch 'release not found') { Exit-Build "Could not check for release $($script:ReleaseTag): $($r.Output)" }
  $r = Invoke-Capture 'gh' @('api', "repos/$($env:GITHUB_REPOSITORY)/git/ref/tags/$($script:ReleaseTag)")
  if ($r.Code -eq 0) { Exit-Build "Tag $($script:ReleaseTag) already exists in $($env:GITHUB_REPOSITORY). Use a new build_number." }
  if ($r.Output -notmatch '404') { Exit-Build "Could not check for tag $($script:ReleaseTag): $($r.Output)" }
}

function Find-SignTool {
  $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
  $candidates = @(Get-ChildItem -Path $kits -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -eq 'x64' -and $_.Directory.Parent.Name -match '^10\.' } |
    Sort-Object { [version]$_.Directory.Parent.Name } -Descending)
  if ($candidates.Count -eq 0) { Exit-Build "signtool.exe not found under $kits. Install the Windows SDK, or remove WINDOWS_CERT_PFX_BASE64 for an unsigned build." }
  return $candidates[0].FullName
}

function Find-Iscc {
  $paths = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
  )
  foreach ($p in $paths) { if (Test-Path -LiteralPath $p) { return $p } }
  $cmd = Get-Command iscc.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return ''
}

function Invoke-Preflight {
  Enter-LogGroup 'Preflight'
  Test-BuildInput
  Write-Step "Version $Version (file version $($script:FileVersion)), release tag $($script:ReleaseTag)"
  Test-AppConfig

  foreach ($p in @($AppProject, $TestProject, $IssScript)) {
    if (-not (Test-Path -LiteralPath $p)) { Exit-Build "$p not found." }
  }
  if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { Exit-Build 'dotnet not found on PATH. Install the .NET 10 SDK.' }
  Write-Step "dotnet SDK $(& dotnet --version) (global.json: windows/global.json)"

  # Executable name = AssemblyName from the project, else the project name.
  [xml] $proj = Get-Content -LiteralPath $AppProject -Raw
  $asm = @($proj.SelectNodes('//AssemblyName') | ForEach-Object { $_.InnerText.Trim() } | Where-Object { $_ })
  $baseName = if ($asm.Count -gt 0) { $asm[0] } else { [System.IO.Path]::GetFileNameWithoutExtension($AppProject) }
  $script:AppExeName = "$baseName.exe"
  Write-Step "App executable: $($script:AppExeName)"

  if (-not $IsWindows) {
    if (-not $NoInstaller) {
      Exit-Build "This build needs Windows (found $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)). Run it on GitHub Actions (Actions > Build Windows > Run workflow) or on a Windows PC; on other hosts use -NoInstaller for a publish-and-zip smoke test." 3
    }
    Write-Warn 'Not Windows: -NoInstaller given, so signing, the installer and publishing are skipped.'
  }

  # Signing inputs.
  if ($env:WINDOWS_CERT_PFX_BASE64 -and $IsWindows) {
    $script:Signed = $true
    if (-not $env:WINDOWS_CERT_PASSWORD) { Write-Warn 'WINDOWS_CERT_PASSWORD is empty; importing the .pfx without a password.' }
    $script:SignTool = Find-SignTool
    Write-Step "Signing: Authenticode (WINDOWS_CERT_PFX_BASE64 is set) with $($script:SignTool), timestamp $TimestampUrl."
  }
  else {
    if ($env:WINDOWS_CERT_PASSWORD -and -not $env:WINDOWS_CERT_PFX_BASE64) { Write-Warn 'WINDOWS_CERT_PASSWORD is set but WINDOWS_CERT_PFX_BASE64 is not; building unsigned.' }
    Write-Step 'Signing: none (WINDOWS_CERT_PFX_BASE64 not set). Files will be named -unsigned; SmartScreen will warn on first run.'
  }

  # Inno Setup (preinstalled on windows-2025; pinned Chocolatey fallback).
  if ($IsWindows) {
    $script:Iscc = Find-Iscc
    if (-not $script:Iscc) {
      Write-Step "Inno Setup not found; installing innosetup $InnoSetupVersion with Chocolatey."
      Invoke-Native 'choco install innosetup failed' 'choco' @('install', 'innosetup', '--version', $InnoSetupVersion, '-y', '--no-progress')
      $script:Iscc = Find-Iscc
      if (-not $script:Iscc) { Exit-Build 'ISCC.exe still not found after installing Inno Setup.' }
    }
    Write-Step "Inno Setup compiler: $($script:Iscc)"
  }

  # Release publishing.
  $pub = $env:PUBLISH_RELEASE
  if (-not $pub) { $pub = if ($script:IsCI) { '1' } else { '0' } }
  $script:Publish = $pub -eq '1'
  if ($script:Publish) {
    if (-not $IsWindows) { Exit-Build 'Publishing needs the installers; run on Windows or set PUBLISH_RELEASE=0.' }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Exit-Build 'GitHub CLI (gh) not found. Install it, or set PUBLISH_RELEASE=0.' }
    if (-not $env:GH_TOKEN) { Exit-Build 'GH_TOKEN is not set (needed to create the draft release). Set PUBLISH_RELEASE=0 to skip publishing.' }
    if (-not $env:GITHUB_REPOSITORY) { Exit-Build 'GITHUB_REPOSITORY is not set (owner/repo). Set it, or PUBLISH_RELEASE=0.' }
    Test-ReleaseAbsent
    Write-Step "Release: will create draft pre-release $($script:ReleaseTag) in $($env:GITHUB_REPOSITORY)."
  }
  else {
    Write-Step "Release: publishing disabled (PUBLISH_RELEASE=0); files stay in $DistDir."
  }
  Exit-LogGroup
}

function Invoke-RestoreAndTest {
  Enter-LogGroup 'Restore and test'
  Invoke-Native 'dotnet restore failed' 'dotnet' @('restore', $TestProject)
  Invoke-Native 'Unit tests failed' 'dotnet' @('test', $TestProject, '-c', 'Release', '--no-restore',
    '--logger', 'console;verbosity=normal', '--results-directory', (Join-Path $BuildDir 'TestResults'))
  Exit-LogGroup
}

function Import-SigningCertificate {
  if (-not $script:Signed) { return }
  Enter-LogGroup 'Import code-signing certificate'
  Remove-Item -LiteralPath $SigningDir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $SigningDir -Force | Out-Null
  try {
    $bytes = [Convert]::FromBase64String(($env:WINDOWS_CERT_PFX_BASE64 -replace '\s', ''))
  }
  catch { Exit-Build 'WINDOWS_CERT_PFX_BASE64 is not valid base64.' }
  $password = if ($env:WINDOWS_CERT_PASSWORD) { $env:WINDOWS_CERT_PASSWORD } else { '' }
  $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]'UserKeySet, PersistKeySet'
  try {
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes, $password, $flags)
  }
  catch { Exit-Build 'Could not open the .pfx (wrong WINDOWS_CERT_PASSWORD, or not a PKCS#12 file).' }
  if (-not $cert.HasPrivateKey) { Exit-Build 'The .pfx has no private key. Export the code-signing certificate WITH its private key.' }
  $eku = @($cert.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
    ForEach-Object { $_.EnhancedKeyUsages } | ForEach-Object { $_.Value })
  if ($eku.Count -gt 0 -and $eku -notcontains '1.3.6.1.5.5.7.3.3') { Exit-Build 'The certificate is not valid for code signing (no Code Signing EKU 1.3.6.1.5.5.7.3.3).' }
  if ($cert.NotAfter -lt (Get-Date)) { Exit-Build "The code-signing certificate expired on $($cert.NotAfter.ToString('u'))." }
  if ($cert.NotAfter -lt (Get-Date).AddDays(30)) { Write-Warn "The code-signing certificate expires on $($cert.NotAfter.ToString('u'))." }

  $store = [System.Security.Cryptography.X509Certificates.X509Store]::new('My', 'CurrentUser')
  $store.Open('ReadWrite')
  $store.Add($cert)
  $store.Close()
  $script:Thumbprint = $cert.Thumbprint
  Set-Content -LiteralPath (Join-Path $SigningDir 'thumbprint') -Value $cert.Thumbprint -Encoding ascii
  Write-Step "Imported '$($cert.Subject)' (thumbprint $($cert.Thumbprint), valid until $($cert.NotAfter.ToString('u')))."
  Exit-LogGroup
}

# signtool with retries (the timestamp server occasionally fails).
function Invoke-SignTool([string[]] $Files) {
  $arguments = @('sign', '/sha1', $script:Thumbprint, '/s', 'My', '/fd', 'SHA256', '/tr', $TimestampUrl, '/td', 'SHA256', '/d', $AppName) + $Files
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    & $script:SignTool @arguments | Out-Host
    if ($LASTEXITCODE -eq 0) { return }
    if ($attempt -lt 3) { Write-Warn "signtool failed (attempt $attempt); retrying in 10 s."; Start-Sleep -Seconds 10 }
  }
  Exit-Build 'signtool sign failed 3 times.'
}

function Test-Signature([string] $File) {
  Invoke-Native "Signature of $([System.IO.Path]::GetFileName($File)) does not verify" $script:SignTool @('verify', '/pa', '/q', $File)
}

function Invoke-PublishRuntime([string] $Rid) {
  Enter-LogGroup "Publish $Rid (self-contained)"
  $out = Join-Path $PublishRoot $Rid
  Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
  Invoke-Native "dotnet publish ($Rid) failed" 'dotnet' @('publish', $AppProject,
    '-c', 'Release', '-r', $Rid, '--self-contained', 'true', '-o', $out,
    "-p:Version=$Version", "-p:FileVersion=$($script:FileVersion)",
    "-p:AssemblyVersion=$($script:NumericVersion).0",
    "-p:InformationalVersion=$Version+build.$BuildNumber",
    '-p:ContinuousIntegrationBuild=true')
  $exe = Join-Path $out $script:AppExeName
  if (-not (Test-Path -LiteralPath $exe)) { Exit-Build "dotnet publish did not produce $($script:AppExeName) in $out." }
  Exit-LogGroup
  return $out
}

# Write the CI configuration into the published appsettings.json.
function Write-AppConfiguration([string] $Dir) {
  $file = Join-Path $Dir 'appsettings.json'
  if (-not (Test-Path -LiteralPath $file)) {
    Exit-Build "appsettings.json is missing from the publish output ($Dir). DriveSync.App.csproj must copy it (CopyToPublishDirectory)."
  }
  $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
  $changes = @(
    @('Google', 'ClientId', $env:GOOGLE_CLIENT_ID_WINDOWS),
    @('Google', 'ClientSecret', $env:GOOGLE_CLIENT_SECRET_WINDOWS),
    @('Drive', 'SharedDriveName', $env:DRIVE_ROOT_SHARED_DRIVE_NAME),
    @('Drive', 'FolderId', $env:DRIVE_ROOT_FOLDER_ID)
  )
  foreach ($c in $changes) {
    $section, $key, $value = $c
    if (-not $value) { continue }
    if (-not $json.ContainsKey($section) -or $json[$section] -isnot [System.Collections.IDictionary]) {
      $json[$section] = [ordered]@{}
    }
    $json[$section][$key] = $value
  }
  ($json | ConvertTo-Json -Depth 32) | Set-Content -LiteralPath $file -Encoding utf8NoBOM
  # Read back (never print the secret).
  $check = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
  $hasSecret = $check.ContainsKey('Google') -and $check['Google'] -is [System.Collections.IDictionary] -and
    $check['Google'].ContainsKey('ClientSecret') -and [bool]$check['Google']['ClientSecret']
  $clientId = if ($check.ContainsKey('Google') -and $check['Google'] -is [System.Collections.IDictionary] -and $check['Google'].ContainsKey('ClientId')) { $check['Google']['ClientId'] } else { '' }
  Write-Step "appsettings.json: Google:ClientId = '$clientId', Google:ClientSecret set = $hasSecret"
}

function Invoke-CodeSigning([string] $Dir) {
  if (-not $script:Signed) { return }
  Enter-LogGroup "Sign binaries in $([System.IO.Path]::GetFileName($Dir))"
  # Only our own binaries: the app host exe and DriveSync.* assemblies that are
  # not signed yet. Microsoft and NuGet binaries keep their own signatures.
  $ours = @(Get-ChildItem -LiteralPath $Dir -File | Where-Object {
      ($_.Name -eq $script:AppExeName -or $_.Name -like 'DriveSync*.dll' -or $_.Name -like 'DriveSync*.exe') -and
      (Get-AuthenticodeSignature -LiteralPath $_.FullName).Status -eq 'NotSigned'
    } | ForEach-Object { $_.FullName })
  if ($ours.Count -eq 0) { Exit-Build "No unsigned DriveSync binaries found in $Dir." }
  Write-Step "Signing $($ours.Count) files: $(($ours | ForEach-Object { [System.IO.Path]::GetFileName($_) }) -join ', ')"
  Invoke-SignTool $ours
  foreach ($f in $ours) { Test-Signature $f }
  Exit-LogGroup
}

function Get-AssetName([string] $Rid, [string] $Kind, [string] $Extension) {
  $suffix = if ($script:Signed) { '' } else { '-unsigned' }
  return "$AppName-$Version-$BuildNumber-$Rid-$Kind$suffix$Extension"
}

function Build-PortableZip([string] $Rid, [string] $Dir) {
  $zip = Join-Path $DistDir (Get-AssetName $Rid 'portable' '.zip')
  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
  Compress-Archive -Path (Join-Path $Dir '*') -DestinationPath $zip -CompressionLevel Optimal
  Write-Step "Portable zip: $zip"
  $script:Assets.Add($zip)
}

function Build-Installer([string] $Rid, [string] $Dir) {
  Enter-LogGroup "Installer $Rid (Inno Setup)"
  $arch = $Rid -replace '^win-', ''
  $name = Get-AssetName $Rid 'setup' '.exe'
  $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
  $arguments = @('/Qp', "/O$DistDir", "/F$base",
    "/DAppVersion=$Version", "/DAppVersionNumeric=$($script:FileVersion)", "/DAppArch=$arch",
    "/DSourceDir=$Dir", "/DAppExeName=$($script:AppExeName)", "/DAppName=$AppName")
  if ($script:Signed) {
    # $q and $f are Inno Setup placeholders (quote, file name), not PowerShell variables.
    $sign = '$q' + $script:SignTool + '$q sign /sha1 ' + $script:Thumbprint + ' /s My /fd SHA256 /tr ' + $TimestampUrl + ' /td SHA256 /d $q' + $AppName + '$q $f'
    $arguments += @('/DSignInstaller', "/Sdriveappsign=$sign")
  }
  $arguments += $IssScript
  Invoke-Native "Inno Setup failed for $Rid" $script:Iscc $arguments
  $setup = Join-Path $DistDir $name
  if (-not (Test-Path -LiteralPath $setup)) { Exit-Build "Inno Setup did not create $setup." }
  if ($script:Signed) { Test-Signature $setup }
  Write-Step "Installer: $setup"
  $script:Assets.Add($setup)
  Exit-LogGroup
}

function Write-Checksum {
  Enter-LogGroup 'SHA-256'
  Add-Summary "## $AppName for Windows"
  Add-Summary ''
  Add-Summary "Version $Version (build $BuildNumber), Authenticode signed: $($script:Signed), Google client ID set: $([bool]$env:GOOGLE_CLIENT_ID_WINDOWS)"
  Add-Summary ''
  Add-Summary '| File | SHA-256 |'
  Add-Summary '| --- | --- |'
  $shaFiles = [System.Collections.Generic.List[string]]::new()
  foreach ($asset in $script:Assets) {
    $hash = (Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant()
    $leaf = [System.IO.Path]::GetFileName($asset)
    $line = "$hash  $leaf"
    # "<hash>  <name>" + LF: the format `sha256sum -c` / `shasum -a 256 -c` read.
    [System.IO.File]::WriteAllText("$asset.sha256", "$line`n", [System.Text.UTF8Encoding]::new($false))
    Write-Host $line
    Add-Summary "| ``$leaf`` | ``$hash`` |"
    $shaFiles.Add("$asset.sha256")
  }
  foreach ($s in $shaFiles) { $script:Assets.Add($s) }
  Exit-LogGroup
}

function Publish-Release {
  if (-not $script:Publish) { Write-Step "Release skipped (PUBLISH_RELEASE=0). Files: $DistDir"; return }
  Enter-LogGroup "Create draft pre-release $($script:ReleaseTag)"
  Test-ReleaseAbsent
  $target = if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { (& git -C $RepoRoot rev-parse HEAD) }
  $title = "$AppName $Version (build $BuildNumber) for Windows"
  if (-not $script:Signed) { $title += ', unsigned' }
  $notes = Join-Path $BuildDir 'release-notes.md'
  $lines = @(
    "Test build of $AppName $Version (build $BuildNumber) for Windows 10 2004+ / Windows 11 from commit $target.",
    '',
    "- Authenticode signed: $(if ($script:Signed) { 'yes' } else { 'no' })",
    '- `*-setup*.exe`: per-user installer (no admin rights), installs to %LOCALAPPDATA%\Programs\DriveApp.',
    '- `*-portable*.zip`: the same files without an installer.',
    '- `win-x64` for Intel/AMD PCs, `win-arm64` for Arm PCs.',
    '',
    'Verify a download in PowerShell: `(Get-FileHash <file> -Algorithm SHA256).Hash` and compare with `<file>.sha256`.'
  )
  if (-not $script:Signed) {
    $lines += @('', 'These files are NOT signed. Windows SmartScreen will warn on first run: see docs/12-pipeline-usage.md ("Opening an unsigned build").')
  }
  Set-Content -LiteralPath $notes -Value $lines -Encoding utf8NoBOM
  $arguments = @('release', 'create', $script:ReleaseTag) + $script:Assets + @(
    '--repo', $env:GITHUB_REPOSITORY, '--draft', '--prerelease', '--target', $target,
    '--title', $title, '--notes-file', $notes)
  $r = Invoke-Capture 'gh' $arguments
  if ($r.Code -ne 0) { Exit-Build "gh release create failed: $($r.Output)" }
  Write-Step "Draft pre-release: $($r.Output)"
  Add-Summary ''
  Add-Summary "Draft pre-release: $($r.Output)"
  Exit-LogGroup
}

# Idempotent; never fails. Removes the imported certificate and decoded files.
function Invoke-Cleanup {
  try {
    if (Test-Path -LiteralPath $SigningDir) {
      $thumbFile = Join-Path $SigningDir 'thumbprint'
      if ($IsWindows -and (Test-Path -LiteralPath $thumbFile)) {
        $thumb = (Get-Content -LiteralPath $thumbFile -Raw).Trim()
        $store = [System.Security.Cryptography.X509Certificates.X509Store]::new('My', 'CurrentUser')
        $store.Open('ReadWrite')
        foreach ($c in @($store.Certificates.Find('FindByThumbprint', $thumb, $false))) { $store.Remove($c) }
        $store.Close()
        # Also delete the persisted private key (certutil removes cert + key).
        & certutil -user -delstore My $thumb *> $null
      }
      Remove-Item -LiteralPath $SigningDir -Recurse -Force -ErrorAction SilentlyContinue
      Write-Step "Cleanup: removed the imported code-signing certificate and $SigningDir."
    }
    else {
      Write-Step 'Cleanup: nothing to remove.'
    }
  }
  catch {
    Write-Warn "Cleanup: $($_.Exception.Message)"
  }
}

function Invoke-Build {
  try {
    Invoke-Preflight
    Invoke-RestoreAndTest
    Import-SigningCertificate
    New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
    Get-ChildItem -LiteralPath $DistDir -File | Remove-Item -Force
    foreach ($rid in $Runtimes) {
      $dir = Invoke-PublishRuntime $rid
      Write-AppConfiguration $dir
      Invoke-CodeSigning $dir
      Build-PortableZip $rid $dir
      if ($IsWindows) { Build-Installer $rid $dir }
    }
    Write-Checksum
    Publish-Release
    Write-Step "Done: $DistDir"
  }
  finally {
    Invoke-Cleanup
  }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

try {
  switch ($Command) {
    'help' { Write-Usage }
    'preflight' { Invoke-Preflight }
    'cleanup' { Invoke-Cleanup }
    'build' { Invoke-Build }
  }
}
catch {
  $message = $_.Exception.Message
  $code = 1
  if ($message -match '\(exit (\d+)\)$') { $code = [int]$Matches[1] }
  else { [Console]::Error.WriteLine("build-windows: $message") }
  [Console]::Error.WriteLine("build-windows.ps1: failed (exit $code).")
  exit $code
}
exit 0
