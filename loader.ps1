# =============================================================================
# Steadfast Loader - the ONE universal, uniform installer for every Steadfast
# product (public thin bootstrapper).
#
# Standard: STEADFAST-DEVKIT-STANDARD.md sec6b.3 (universal loader) + sec4a
#           (licensing). Doctrine: D31 THE-BUS-CARRIES-REQUESTS-NEVER-AUTHORITY
#           / D32 LICENSING-AND-SIGNING-ARE-LOCAL.
#
# WHAT THIS IS
#   The single public download for the whole Steadfast catalogue. A normal user
#   double-clicks SteadfastLoader.exe, PICKS the product from a dropdown, fills
#   in name/email, and requests a license. On operator approval the loader pulls
#   the real (private) installer from that product's gated feed, verifies its
#   published hash, runs it, and writes license.json so the app opens activated.
#   It carries NO product code and NO key material.
#
# UNIFORM DEVICE-ID STANDARD (2026-07-21)
#   Every listed product computes the SAME device id, so ONE loader binds them
#   all identically:  sha256(hostname|platform|arch|cpuModel|totalmem)[:16].upper
#   No MAC address (moves with VPNs/docks/virtual adapters, not reproducible).
#   Nexus + CastForge apps both compute exactly this. Each product's app
#   re-computes the same id at runtime and verifies the bundled Ed25519 license.
# =============================================================================

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# -----------------------------------------------------------------------------
# PRODUCT CATALOGUE  (values sourced from steadfast-devkit/registry.js)
# Every entry uses the uniform 'node-os' device id + 'json-file' activation.
# To add a product: append an entry here once its app conforms to the standard.
# -----------------------------------------------------------------------------
$script:PRODUCTS = [ordered]@{
  'nexus' = @{
    Product       = 'nexus'
    DisplayName   = 'Nexus Optimus'
    LicenseDomain = 'nexus-license.steadfastsoftwarellc.com'
    ApiPrefix     = ''
    ManifestKind  = 'electron-yml'
    FeedManifest  = 'latest.yml'
    HashField     = 'sha512'
    HashEncoding  = 'base64'
    LicenseDir    = "$env:APPDATA\Nexus Optimus"
    LicenseFile   = 'license.json'
    InstallerArgs = ''
  }
  'castforge' = @{
    Product       = 'castforge'
    DisplayName   = 'CastForge'
    LicenseDomain = 'castforge-license.steadfastsoftwarellc.com'
    ApiPrefix     = ''
    ManifestKind  = 'electron-yml'
    FeedManifest  = 'latest.yml'
    HashField     = 'sha512'
    HashEncoding  = 'base64'
    LicenseDir    = "$env:APPDATA\CastForge"
    LicenseFile   = 'license.json'
    InstallerArgs = ''
  }
  'ude-home' = @{
    Product       = 'ude-home'
    DisplayName   = 'Undestructable Update Engine'
    LicenseDomain = 'ude-license.steadfastsoftwarellc.com'
    ApiPrefix     = '/v1'
    ManifestKind  = 'ude-json'
    Edition       = 'Home'
    HashField     = 'sha256'
    HashEncoding  = 'hex'
    LicenseDir    = "$env:APPDATA\UDE"
    LicenseFile   = 'license.json'
    InstallerArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
  }
}
$script:PollSeconds    = 4
$script:PollTimeoutMin = 20

# =============================================================================
# NATIVE: GlobalMemoryStatusEx().ullTotalPhys == Node os.totalmem() (exact match)
# =============================================================================
if (-not ('SfNative' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SfNative {
  [StructLayout(LayoutKind.Sequential)]
  public struct MEMORYSTATUSEX {
    public uint dwLength; public uint dwMemoryLoad;
    public ulong ullTotalPhys; public ulong ullAvailPhys;
    public ulong ullTotalPageFile; public ulong ullAvailPageFile;
    public ulong ullTotalVirtual; public ulong ullAvailVirtual;
    public ulong ullAvailExtendedVirtual;
  }
  [DllImport("kernel32.dll", SetLastError=true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);
  public static ulong TotalPhys() {
    MEMORYSTATUSEX m = new MEMORYSTATUSEX();
    m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
    GlobalMemoryStatusEx(ref m);
    return m.ullTotalPhys;
  }
}
'@
}

# =============================================================================
# UNIFORM DEVICE ID  (byte-identical to the products' Node scheme):
#   raw  = [ os.hostname(), 'win32', 'x64', os.cpus()[0].model, String(os.totalmem()) ].join('|')
#   hwid = sha256(raw).hex.slice(0,16).toUpperCase()
# =============================================================================
function Get-SfSha256Hex([string]$Raw) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Raw)) }
  finally { $sha.Dispose() }
  return (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
}
function Get-SfHwid {
  $hostname = [System.Net.Dns]::GetHostName()
  $cpu = ''
  try {
    $cpu = (Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -Name ProcessorNameString -ErrorAction Stop).ProcessorNameString
  } catch { $cpu = '' }
  $totalmem = [SfNative]::TotalPhys().ToString()
  $raw = @($hostname, 'win32', 'x64', $cpu, $totalmem) -join '|'
  return (Get-SfSha256Hex $raw).Substring(0, 16).ToUpper()
}

# =============================================================================
# HTTP helpers
# =============================================================================
function Invoke-SfPostJson([string]$Url, [hashtable]$Body) {
  $json = $Body | ConvertTo-Json -Compress
  return Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json' -Body $json -TimeoutSec 20
}
function Invoke-SfGetJson([string]$Url) { return Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec 20 }
function Invoke-SfDownload([string]$Url, [string]$OutFile, [hashtable]$Headers) {
  Invoke-WebRequest -Uri $Url -Headers $Headers -OutFile $OutFile -UseBasicParsing -TimeoutSec 120
}
function ConvertFrom-SfBase64Url([string]$s) {
  $s = $s.Replace('-', '+').Replace('_', '/')
  switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
  return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))
}
function Test-SfTokenBinding([string]$Token, [string]$Hwid, [string]$ProductKey) {
  try {
    $parts = $Token.Trim().Split('.')
    if ($parts.Count -ge 3)     { $seg = $parts[1] }
    elseif ($parts.Count -eq 2) { $seg = $parts[0] }
    else { return $false }
    $payload = ConvertFrom-SfBase64Url $seg | ConvertFrom-Json
    if ($payload.product -and ($payload.product -ne $ProductKey)) { return $false }
    $machine = if ($payload.machine) { $payload.machine } elseif ($payload.hwid) { $payload.hwid } else { $null }
    if ($machine -and (($machine.ToString().ToUpper()) -ne $Hwid)) { return $false }
    return $true
  } catch { return $true }
}

# =============================================================================
# GATED INSTALL: pull manifest + installer from the token-gated feed, verify the
# published hash, then run it. electron-updater publishes sha512/base64.
# =============================================================================
function Get-SfFileHashEncoded([string]$Path, [hashtable]$P) {
  $algo = if ($P.HashField -eq 'sha256') { [System.Security.Cryptography.SHA256]::Create() }
          else                           { [System.Security.Cryptography.SHA512]::Create() }
  try { $fb = [System.IO.File]::ReadAllBytes($Path); $raw = $algo.ComputeHash($fb) }
  finally { $algo.Dispose() }
  if ($P.HashEncoding -eq 'hex') { return (-join ($raw | ForEach-Object { $_.ToString('x2') })) }
  return [Convert]::ToBase64String($raw)
}
function Get-SfInstallerVerified([string]$Token, [hashtable]$P) {
  if ($P.ManifestKind -eq 'ude-json') {
    # UDE: /v1/latest (public) names the installer + its sha256; the file itself is
    # pulled through the TOKEN-GATED worker proxy /updates/ude/<file> (ude-releases
    # is private) -- uniform with Nexus/CastForge: the licence is the key, the
    # Worker is the door.
    $edition = if ($P.Edition) { $P.Edition } else { 'Home' }
    $manUrl  = "https://$($P.LicenseDomain)$($P.ApiPrefix)/latest?edition=$edition&channel=stable&current=0.0.0"
    $m = Invoke-SfGetJson $manUrl
    $hash = if ($m.installerSha256) { [string]$m.installerSha256 } else { '' }
    $fileName = if ($m.installerUrl) { [System.IO.Path]::GetFileName(([uri][string]$m.installerUrl).AbsolutePath) } else { '' }
    if (-not $fileName) { throw "UDE update feed did not name an installer." }
    if (-not $hash) { throw "UDE update feed published no sha256 to verify against." }
    $dlUrl    = "https://$($P.LicenseDomain)/updates/ude/$([uri]::EscapeDataString($fileName))"
    $instPath = Join-Path $env:TEMP $fileName
    Invoke-SfDownload $dlUrl $instPath @{ Authorization = "Bearer $Token" }
    $calc = Get-SfFileHashEncoded $instPath $P
    if ($calc -ine $hash) {
      try { Remove-Item $instPath -Force -ErrorAction SilentlyContinue } catch {}
      throw "Installer integrity check FAILED (sha256 mismatch). Nothing was run."
    }
    return $instPath
  }
  # electron-yml (Nexus / CastForge): token-gated /updates feed.
  $base    = "https://$($P.LicenseDomain)/updates/$($P.Product)"
  $headers = @{ Authorization = "Bearer $Token" }
  $manPath = Join-Path $env:TEMP "$($P.Product)-$($P.FeedManifest)"
  Invoke-SfDownload "$base/$([uri]::EscapeDataString($P.FeedManifest))" $manPath $headers
  $manRaw = Get-Content -Path $manPath -Raw
  $file = [regex]::Match($manRaw, '(?m)^path:\s*(\S.*?)\s*$').Groups[1].Value
  $hash = [regex]::Match($manRaw, '(?m)^sha512:\s*(\S+)\s*$').Groups[1].Value
  if (-not $file) { throw "Feed manifest did not name an installer." }
  if (-not $hash) { throw "Feed manifest published no hash to verify against." }
  $instPath = Join-Path $env:TEMP $file
  Invoke-SfDownload "$base/$([uri]::EscapeDataString($file))" $instPath $headers
  $calc = Get-SfFileHashEncoded $instPath $P
  $ok = if ($P.HashEncoding -eq 'hex') { $calc -ieq $hash } else { $calc -ceq $hash }
  if (-not $ok) {
    try { Remove-Item $instPath -Force -ErrorAction SilentlyContinue } catch {}
    throw "Installer integrity check FAILED (published hash mismatch). Nothing was run."
  }
  return $instPath
}
function Invoke-SfInstaller([string]$InstallerPath, [hashtable]$P) {
  if ($P.InstallerArgs) { Start-Process -FilePath $InstallerPath -ArgumentList $P.InstallerArgs -Wait }
  else                  { Start-Process -FilePath $InstallerPath -Wait }
}
function Write-SfLicense([string]$Token, [string]$Hwid, [hashtable]$P) {
  $dir = [System.Environment]::ExpandEnvironmentVariables($P.LicenseDir)
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $rec = [ordered]@{ key = $Token.Trim(); hwid = $Hwid; activatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }
  $json = ($rec | ConvertTo-Json)
  $path = Join-Path $dir $P.LicenseFile
  [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# request-id persistence (per product) so a relaunch resumes a pending request
function Get-SfRequestStatePath([string]$ProductKey) { Join-Path $env:TEMP "$ProductKey-loader-request.json" }
function Save-SfRequestState([string]$ProductKey, [string]$RequestId) {
  $rec = @{ requestId = $RequestId; at = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json
  [System.IO.File]::WriteAllText((Get-SfRequestStatePath $ProductKey), $rec, (New-Object System.Text.UTF8Encoding($false)))
}
function Clear-SfRequestState([string]$ProductKey) { try { Remove-Item (Get-SfRequestStatePath $ProductKey) -Force -ErrorAction SilentlyContinue } catch {} }

# =============================================================================
# UI  (minimal WinForms - native window, product dropdown + request form)
# =============================================================================
$script:Hwid        = Get-SfHwid
$script:RequestId   = $null
$script:PollTimer   = $null
$script:PollStarted = $null

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'Steadfast Loader'
$form.Size            = New-Object System.Drawing.Size(470, 400)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false

function New-SfLabel($text, $x, $y, $w) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
  $l.Size = New-Object System.Drawing.Size($w, 20); return $l
}
function New-SfText($x, $y, $w) {
  $t = New-Object System.Windows.Forms.TextBox
  $t.Location = New-Object System.Drawing.Point($x, $y)
  $t.Size = New-Object System.Drawing.Size($w, 22); return $t
}

$form.Controls.Add((New-SfLabel 'Steadfast Software - request a product license' 20 14 430))

$form.Controls.Add((New-SfLabel 'Product' 20 46 120))
$cboProduct = New-Object System.Windows.Forms.ComboBox
$cboProduct.Location = New-Object System.Drawing.Point(20, 66)
$cboProduct.Size = New-Object System.Drawing.Size(410, 24)
$cboProduct.DropDownStyle = 'DropDownList'
foreach ($k in $script:PRODUCTS.Keys) { [void]$cboProduct.Items.Add($script:PRODUCTS[$k].DisplayName) }
$cboProduct.SelectedIndex = 0
$form.Controls.Add($cboProduct)

$form.Controls.Add((New-SfLabel 'Name'  20 98  120));  $txtName    = New-SfText 20 118 410; $form.Controls.Add($txtName)
$form.Controls.Add((New-SfLabel 'Email' 20 148 120));  $txtEmail   = New-SfText 20 168 410; $form.Controls.Add($txtEmail)
$form.Controls.Add((New-SfLabel 'Company (optional)' 20 198 200)); $txtCompany = New-SfText 20 218 410; $form.Controls.Add($txtCompany)

$lblHwid = New-SfLabel "Device ID: $($script:Hwid)" 20 248 430
$form.Controls.Add($lblHwid)

$btnRequest = New-Object System.Windows.Forms.Button
$btnRequest.Text = 'Request license'
$btnRequest.Location = New-Object System.Drawing.Point(20, 274)
$btnRequest.Size = New-Object System.Drawing.Size(410, 32)
$form.Controls.Add($btnRequest)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(20, 316)
$lblStatus.Size = New-Object System.Drawing.Size(410, 44)
$lblStatus.Text = 'Pick your product, enter your details, and request a license. Approval releases the download.'
$form.Controls.Add($lblStatus)

function Set-SfStatus([string]$msg) { $lblStatus.Text = $msg; $lblStatus.Refresh() }
function Get-SfSelectedProduct {
  $keys = @($script:PRODUCTS.Keys)
  return $script:PRODUCTS[$keys[$cboProduct.SelectedIndex]]
}
function Stop-SfPoll { if ($script:PollTimer) { $script:PollTimer.Stop(); $script:PollTimer.Dispose(); $script:PollTimer = $null } }

# switching product cancels any in-flight poll and re-enables the form
$cboProduct.Add_SelectedIndexChanged({
  Stop-SfPoll
  $script:RequestId = $null
  $btnRequest.Enabled = $true
  Set-SfStatus "Selected $((Get-SfSelectedProduct).DisplayName). Enter your details and request a license."
})

function Complete-SfApproved([string]$Token, [hashtable]$P) {
  Stop-SfPoll
  $btnRequest.Enabled = $false
  try {
    if (-not (Test-SfTokenBinding $Token $script:Hwid $P.Product)) {
      Set-SfStatus 'The approved license does not match this device/product. Contact support.'
      return
    }
    Set-SfStatus 'Approved. Downloading and verifying the installer...'
    $installer = Get-SfInstallerVerified $Token $P
    # Write the licence BEFORE running the installer: installers commonly auto-launch
    # the app when they finish, and the app checks its licence at startup. Writing
    # license.json first guarantees the app opens PRE-ACTIVATED instead of flashing a
    # "locked / paste your key" wall because the file landed a beat too late.
    Set-SfStatus 'Activating this device...'
    Write-SfLicense $Token $script:Hwid $P
    Set-SfStatus 'Verified. Running the installer...'
    Invoke-SfInstaller $installer $P
    Clear-SfRequestState $P.Product
    Set-SfStatus "Done. $($P.DisplayName) is installed and pre-activated."
    [System.Windows.Forms.MessageBox]::Show("$($P.DisplayName) is installed and activated. You can launch it now.", 'Steadfast Loader', 'OK', 'Information') | Out-Null
    $form.Close()
  } catch {
    Set-SfStatus "Install failed: $($_.Exception.Message)"
    $btnRequest.Enabled = $true
  }
}

function Invoke-SfPollTick {
  if (-not $script:RequestId) { Stop-SfPoll; return }
  $P = Get-SfSelectedProduct
  if (((Get-Date) - $script:PollStarted).TotalMinutes -ge $script:PollTimeoutMin) {
    Stop-SfPoll
    Set-SfStatus 'No response yet. Reopen the loader later to resume - your request is saved.'
    $btnRequest.Enabled = $true
    return
  }
  try {
    $r = Invoke-SfGetJson "https://$($P.LicenseDomain)$($P.ApiPrefix)/poll/$([uri]::EscapeDataString($script:RequestId))"
    if ($r -and $r.status) {
      switch ($r.status) {
        'approved' { if ($r.token) { Complete-SfApproved ([string]$r.token) $P } else { Set-SfStatus 'Approved - waiting for the signed token...' } }
        'rejected' {
          Stop-SfPoll
          $reason = if ($r.rejectedReason) { $r.rejectedReason } else { 'no reason given' }
          Set-SfStatus "Request declined: $reason. Nothing was downloaded."
          Clear-SfRequestState $P.Product
          $btnRequest.Enabled = $true
        }
        default { Set-SfStatus "Waiting for operator approval... (device $($script:Hwid))" }
      }
    }
  } catch { Set-SfStatus "Still waiting (server unreachable, will retry): $($_.Exception.Message)" }
}

function Start-SfPoll {
  Stop-SfPoll
  $script:PollStarted = Get-Date
  $script:PollTimer = New-Object System.Windows.Forms.Timer
  $script:PollTimer.Interval = [int]($script:PollSeconds * 1000)
  $script:PollTimer.Add_Tick({ Invoke-SfPollTick })
  $script:PollTimer.Start()
  Invoke-SfPollTick
}

$btnRequest.Add_Click({
  $P = Get-SfSelectedProduct
  $name  = $txtName.Text.Trim()
  $email = $txtEmail.Text.Trim()
  if (-not $name -or -not $email) { Set-SfStatus 'Please enter your name and email.'; return }
  if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { Set-SfStatus 'Please enter a valid email.'; return }
  $btnRequest.Enabled = $false
  $cboProduct.Enabled = $false
  Set-SfStatus "Sending $($P.DisplayName) request..."
  try {
    $body = @{ name = $name; email = $email; hwid = $script:Hwid; product = $P.Product; appVersion = 'loader' }
    if ($txtCompany.Text.Trim()) { $body.company = $txtCompany.Text.Trim() }
    $resp = Invoke-SfPostJson "https://$($P.LicenseDomain)$($P.ApiPrefix)/request" $body
    if ($resp -and $resp.requestId) {
      $script:RequestId = [string]$resp.requestId
      Save-SfRequestState $P.Product $script:RequestId
      Set-SfStatus 'Request sent. Waiting for operator approval...'
      Start-SfPoll
    } else {
      $err = if ($resp -and $resp.error) { $resp.error } else { 'unknown error' }
      Set-SfStatus "Request failed: $err"
      $btnRequest.Enabled = $true; $cboProduct.Enabled = $true
    }
  } catch {
    Set-SfStatus "Could not reach the license server: $($_.Exception.Message)"
    $btnRequest.Enabled = $true; $cboProduct.Enabled = $true
  }
})

$form.Add_FormClosed({ Stop-SfPoll })
[void]$form.ShowDialog()
