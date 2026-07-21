<#
=============================================================================
 build.ps1 - build the UNIVERSAL STUB for one product.
 Standard: STEADFAST-DEVKIT-STANDARD.md sec6b.3 (stub) + sec6b.2 (code signing).

 WHAT IT DOES
   1. Reads the product's canonical values from the devkit central registry
      (registry.js: licenseDomain) and the product's product.config.js
      (product key, licenseWorker cross-check, optional stub overrides).
   2. Renders those values into a per-product copy of stub.ps1 by replacing the
      SF-CONFIG-BEGIN..SF-CONFIG-END region (no hand editing, no drift).
   3. Compiles the rendered .ps1 to a small NATIVE .exe with PS2EXE
      (-noConsole), so a normal Windows user just double-clicks it. NOT Electron.
   4. Authenticode-signs the .exe with the ONE shared OV/HSM identity (sec6b.2).
      This is the single place the signing step plugs in for the stub.

 USAGE
   pwsh ./build.ps1 -Product nexus
   pwsh ./build.ps1 -Product nexus -ProductConfig 'C:\SteadfastSoftware\Nexus_Optimizer\product.config.js'
   pwsh ./build.ps1 -Product nexus -Sign            # also Authenticode-sign
   pwsh ./build.ps1 -Product nexus -SkipCompile     # render only (CI/syntax)

 REQUIREMENTS
   * node   (to read registry.js / product.config.js - both are CommonJS)
   * ps2exe (Install-Module ps2exe)  - only when compiling
   * signtool + the OV/HSM identity   - only when -Sign
=============================================================================
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Product,
  [string]$ProductConfig,                         # path to <product>/product.config.js (optional)
  [string]$DevkitRoot,                            # ...\steadfast-devkit (default: parent of this script's dir)
  [string]$OutDir,                                # default: <script dir>\dist
  [switch]$Sign,
  [switch]$SkipCompile
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot can be empty depending on how the script is dispatched (e.g. some
# nested `powershell -File` hosts). Derive the script's own directory robustly so
# the path defaults never bind to an empty string.
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $DevkitRoot) { $DevkitRoot = Split-Path -Parent $ScriptDir }
if (-not $OutDir)     { $OutDir = Join-Path $ScriptDir 'dist' }
function Fail($m) { Write-Error $m; exit 1 }
function Info($m) { Write-Host "[stub-build] $m" }

$registryPath = Join-Path $DevkitRoot 'registry.js'
if (-not (Test-Path $registryPath)) { Fail "registry.js not found at $registryPath" }
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Fail "node is required to read registry.js / product.config.js" }

# --- 1. pull canonical values (registry is the source of truth) --------------
# One tiny node one-liner emits JSON we can consume. registry.js + product.config
# are CommonJS, so node is the correct reader (no hand-parsing, no drift).
$nodeExpr = @'
const path = require('path');
const reg = require(${0});
const p = reg.PRODUCTS[$env:SF_PRODUCT_JSON];
if (!p) { console.error('unknown product'); process.exit(2); }
let cfg = {};
const cfgPath = process.env.SF_PRODUCT_CONFIG;
if (cfgPath) { try { cfg = require(path.resolve(cfgPath)); } catch (e) { console.error('config load failed: ' + e.message); process.exit(3); } }
const stub = (cfg.stub) || {};
const out = {
  product:       p.product,
  displayName:   p.name,
  licenseDomain: p.licenseDomain,
  // product.config cross-check (must agree with the registry) + optional stub overrides
  licenseWorker: cfg.licenseWorker || null,
  apiPrefix:     stub.apiPrefix || '',
  hwidScheme:    stub.hwidScheme || 'node-os',
  platform:      stub.platform || 'win32',
  arch:          stub.arch || 'x64',
  manifestKind:  stub.manifestKind || 'electron-yml',
  feedManifest:  stub.feedManifest || 'latest.yml',
  hashField:     stub.hashField || 'sha512',
  hashEncoding:  stub.hashEncoding || 'base64',
  activationTarget: stub.activationTarget || 'json-file',
  licenseDir:    stub.licenseDir || null,
  licenseFile:   stub.licenseFile || 'license.json',
  installerArgs: stub.installerArgs || '',
  pollSeconds:   stub.pollSeconds || 4,
  pollTimeout:   stub.pollTimeoutMin || 20,
};
process.stdout.write(JSON.stringify(out));
'@
# inject the registry path as a JS string literal safely
$nodeExpr = $nodeExpr.Replace('${0}', ("'" + $registryPath.Replace('\', '\\') + "'"))
$nodeExpr = $nodeExpr.Replace('$env:SF_PRODUCT_JSON', ("'" + $Product + "'"))

$env:SF_PRODUCT_CONFIG = if ($ProductConfig) { (Resolve-Path $ProductConfig).Path } else { '' }
$raw = $nodeExpr | node -
if ($LASTEXITCODE -ne 0 -or -not $raw) { Fail "could not resolve product '$Product' from registry/product.config" }
$cfg = $raw | ConvertFrom-Json

# licenseDir default: Electron userData == %APPDATA%\<DisplayName>. Products with
# a different userData name MUST set stub.licenseDir in product.config.
$licenseDir = if ($cfg.licenseDir) { $cfg.licenseDir } else { "`$env:APPDATA\$($cfg.displayName)" }

# cross-check: product.config.licenseWorker (if present) must equal the registry domain
if ($cfg.licenseWorker -and ($cfg.licenseWorker -ne $cfg.licenseDomain)) {
  Fail "licenseWorker ($($cfg.licenseWorker)) disagrees with registry licenseDomain ($($cfg.licenseDomain)). Fix product.config or registry - no drift."
}

Info "product      : $($cfg.product) ($($cfg.displayName))"
Info "licenseDomain: $($cfg.licenseDomain)"
Info "feed/hash    : $($cfg.feedManifest) / $($cfg.hashField)"
Info "licenseDir   : $licenseDir"

# --- 2. render the SF-CONFIG region into a per-product stub.ps1 --------------
$template = Get-Content -Path (Join-Path $ScriptDir 'stub.ps1') -Raw

$configBlock = @"
`$SF = @{
  Product        = '$($cfg.product)'
  DisplayName    = '$($cfg.displayName)'
  LicenseDomain  = '$($cfg.licenseDomain)'
  ApiPrefix      = '$($cfg.apiPrefix)'
  HwidScheme     = '$($cfg.hwidScheme)'
  Platform       = '$($cfg.platform)'
  Arch           = '$($cfg.arch)'
  ManifestKind   = '$($cfg.manifestKind)'
  FeedManifest   = '$($cfg.feedManifest)'
  HashField      = '$($cfg.hashField)'
  HashEncoding   = '$($cfg.hashEncoding)'
  LicenseDir     = "$licenseDir"
  LicenseFile    = '$($cfg.licenseFile)'
  InstallerArgs  = '$($cfg.installerArgs)'
  PollSeconds    = $($cfg.pollSeconds)
  PollTimeoutMin = $($cfg.pollTimeout)
}
"@

$pattern  = '(?s)# --- SF-CONFIG-BEGIN ---.*?# --- SF-CONFIG-END ---'
$replace  = "# --- SF-CONFIG-BEGIN ---  (generated by build.ps1 for $($cfg.product) on $(Get-Date -Format o))`r`n$configBlock`r`n# --- SF-CONFIG-END ---"
if ($template -notmatch $pattern) { Fail "SF-CONFIG markers not found in stub.ps1 - cannot render safely." }
$rendered = [regex]::Replace($template, $pattern, ([System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replace }))

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$renderedPath = Join-Path $OutDir "$($cfg.product)-stub.ps1"
[System.IO.File]::WriteAllText($renderedPath, $rendered, (New-Object System.Text.UTF8Encoding($false)))
Info "rendered -> $renderedPath"

if ($SkipCompile) { Info "SkipCompile set - done (render only)."; exit 0 }

# --- 3. compile to a native .exe with PS2EXE --------------------------------
if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
  Fail "ps2exe not installed. Run:  Install-Module ps2exe -Scope CurrentUser"
}
$exePath = Join-Path $OutDir "$($cfg.product)-setup.exe"
Info "compiling -> $exePath"
Invoke-ps2exe -inputFile $renderedPath -outputFile $exePath -noConsole `
  -title "$($cfg.displayName) Installer" -product "$($cfg.displayName)" `
  -company 'Steadfast Software LLC' -copyright "(c) $((Get-Date).Year) Steadfast Software LLC"
if (-not (Test-Path $exePath)) { Fail "ps2exe did not produce $exePath" }

# --- 4. Authenticode signing hook (sec6b.2 - the ONE OV/HSM identity) ----------
# The private key lives on an HSM / hardware token (or Azure Trusted Signing),
# NEVER in a repo or on a worker (D32/D33). This is the single place the stub's
# signing step plugs in; it mirrors core/pipeline/signing.js used for installers.
if ($Sign) {
  $signTool = Get-Command signtool.exe -ErrorAction SilentlyContinue
  if (-not $signTool) { Fail "signtool.exe not found (Windows SDK). Cannot sign." }
  # Reference invocation - the actual identity/params come from the shared
  # signing config (core/pipeline/signing.js). Example (Azure Trusted Signing):
  #   signtool sign /v /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 `
  #     /dlib <AzureCodeSigning.dll> /dmdf <metadata.json> $exePath
  # Example (HSM/OV cert by thumbprint):
  #   signtool sign /v /fd SHA256 /sha1 <THUMBPRINT> `
  #     /tr http://timestamp.digicert.com /td SHA256 $exePath
  Info "signing $exePath with the shared OV/HSM identity (see core/pipeline/signing.js)"
  & $signTool.Source sign /v /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /a $exePath
  if ($LASTEXITCODE -ne 0) { Fail "signtool failed." }
  & $signTool.Source verify /pa /v $exePath | Out-Null
  Info "signed + verified."
} else {
  Info "unsigned build. Re-run with -Sign for a release artifact (gate-code-signing blocks unsigned releases)."
}

Info "done: $exePath"
