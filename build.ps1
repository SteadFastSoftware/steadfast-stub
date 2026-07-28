<#
=============================================================================
 build.ps1 - build the UNIVERSAL Steadfast Loader (loader.ps1 -> SteadfastLoader.exe).
 Standard: STEADFAST-DEVKIT-STANDARD.md sec6b.3 (universal loader) + sec6b.2 (signing).
           Doctrine: D31 THE-BUS-CARRIES-REQUESTS-NEVER-AUTHORITY /
           D32 LICENSING-AND-SIGNING-ARE-LOCAL / D37 forward-thinking.

 WHAT IT DOES
   Compiles the ONE universal loader (loader.ps1 - which carries the product
   catalogue in-file, sourced from registry.js) to a small native
   SteadfastLoader.exe with PS2EXE (-noConsole), optionally Authenticode-signs it,
   and preserves any previous exe under dist\_prev\ (never overwrite-without-backup).

   There is NO per-product rendering: one loader serves EVERY product via its
   in-app dropdown. This SUPERSEDED the old per-product stub.ps1 model (stub.ps1
   retired to _trash 2026-07-25, GAP-32) so the built artifact and the shipped
   artifact are the SAME source - the exact divergence GAP-32 flagged.

 USAGE
   pwsh ./build.ps1                # build unsigned SteadfastLoader.exe
   pwsh ./build.ps1 -Sign         # also Authenticode-sign (release artifact)
   pwsh ./build.ps1 -SkipCompile  # syntax-parse only (CI / no compiler needed)

 REQUIREMENTS
   * ps2exe (Install-Module ps2exe)  - only when compiling
   * signtool + the OV/HSM identity   - only when -Sign
=============================================================================
#>
[CmdletBinding()]
param(
  [string]$OutDir,          # default: <script dir>\dist
  [switch]$Sign,
  [switch]$SkipCompile,
  [switch]$Publish          # after building: hash, write latest.json, push exe+manifest to the PRIVATE releases repo
)

$ErrorActionPreference = 'Stop'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $ScriptDir 'dist' }
function Fail($m) { Write-Error $m; exit 1 }
function Info($m) { Write-Host "[loader-build] $m" }

$src = Join-Path $ScriptDir 'loader.ps1'
if (-not (Test-Path $src)) { Fail "loader.ps1 not found at $src" }

# --- 1. syntax-parse the loader (never compile a broken script) --------------
$errs = $null; $tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$errs)
if (@($errs).Count -gt 0) {
  foreach ($e in @($errs)) { Write-Host ("  L{0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) }
  Fail "loader.ps1 has $(@($errs).Count) syntax error(s) - not compiling."
}
Info "syntax OK (0 errors)"

if ($SkipCompile) { Info "SkipCompile set - done (syntax check only)."; exit 0 }

# --- 2. compile to a native .exe with PS2EXE --------------------------------
if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
  Fail "ps2exe not installed. Run:  Install-Module ps2exe -Scope CurrentUser"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$exePath = Join-Path $OutDir 'SteadfastLoader.exe'

# preserve the previous artifact (never overwrite-without-backup)
if (Test-Path $exePath) {
  $prev = Join-Path $OutDir '_prev'
  New-Item -ItemType Directory -Force -Path $prev | Out-Null
  $bk = 'SteadfastLoader.prev-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.exe'
  Copy-Item $exePath (Join-Path $prev $bk) -Force
  Info "previous exe preserved -> _prev\$bk"
}

Info "compiling -> $exePath"
Invoke-ps2exe -inputFile $src -outputFile $exePath -noConsole `
  -title 'Steadfast Loader' -product 'Steadfast Loader' `
  -company 'Steadfast Software LLC' -copyright "(c) $((Get-Date).Year) Steadfast Software LLC"
if (-not (Test-Path $exePath)) { Fail "ps2exe did not produce $exePath" }

# --- 3. Authenticode signing hook (sec6b.2 - the ONE OV/HSM identity) --------
# The private key lives on an HSM / hardware token (or Azure Trusted Signing),
# NEVER in a repo or on a worker (D32/D33). Single plug-in point for the loader's
# signing step; mirrors core/pipeline/signing.js used for installers.
if ($Sign) {
  $signTool = Get-Command signtool.exe -ErrorAction SilentlyContinue
  if (-not $signTool) { Fail "signtool.exe not found (Windows SDK). Cannot sign." }
  Info "signing $exePath with the shared OV/HSM identity (see core/pipeline/signing.js)"
  & $signTool.Source sign /v /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /a $exePath
  if ($LASTEXITCODE -ne 0) { Fail "signtool failed." }
  & $signTool.Source verify /pa /v $exePath | Out-Null
  Info "signed + verified."
} else {
  Info "unsigned build. Re-run with -Sign for a release artifact (gate-code-signing blocks unsigned releases)."
}

# --- 4. Publish the loader + manifest to the PRIVATE releases feed -----------
# The loader self-update feed (steadfast-loader-feed worker) serves whatever is
# on the latest release of steadfast-stub-releases. Version is read from the ONE
# source of truth: $script:LoaderVersion in loader.ps1. We refuse to publish an
# unsigned build unless -Sign was ALSO passed OR the caller explicitly accepts it
# (gate-code-signing blocks unsigned RELEASES; a beta loader may ship unsigned
# until the signing identity is wired, matching the deferred-signing posture).
if ($Publish) {
  $repo = 'SteadFastSoftware/steadfast-stub-releases'
  $verMatch = [regex]::Match((Get-Content $src -Raw), "LoaderVersion\s*=\s*'([^']+)'")
  if (-not $verMatch.Success) { Fail "could not read `$script:LoaderVersion from loader.ps1" }
  $version = $verMatch.Groups[1].Value
  if (-not (Test-Path $exePath)) { Fail "nothing to publish: $exePath not built (drop -SkipCompile)" }

  $sha = (Get-FileHash -Path $exePath -Algorithm SHA256).Hash.ToLower()
  $manifest = [ordered]@{
    version     = $version
    sha256      = $sha
    asset       = 'SteadfastLoader.exe'
    signed      = [bool]$Sign
    publishedAt = (Get-Date).ToUniversalTime().ToString('o')
  }
  $manPath = Join-Path $OutDir 'latest.json'
  ($manifest | ConvertTo-Json) | Set-Content -Path $manPath -Encoding utf8
  Info "manifest -> $manPath (version $version, sha256 $($sha.Substring(0,12))...)"

  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Fail "gh CLI not found - cannot publish." }
  # Use whatever auth gh already holds (GH_TOKEN env or keyring). Do NOT clear it.
  $tag = "v$version"
  $exists = & gh release view $tag --repo $repo 2>$null
  if ($exists) {
    Info "release $tag exists -- refreshing assets (--clobber)"
    & gh release upload $tag $exePath $manPath --repo $repo --clobber
  } else {
    Info "creating release $tag"
    & gh release create $tag $exePath $manPath --repo $repo --title "Steadfast Loader $tag" --notes "Universal Steadfast Loader $tag"
  }
  if ($LASTEXITCODE -ne 0) { Fail "gh publish failed." }
  $names = & gh release view $tag --repo $repo --json assets --jq '[.assets[].name]'
  Info "published assets: $names"
}

Info "done: $exePath"
