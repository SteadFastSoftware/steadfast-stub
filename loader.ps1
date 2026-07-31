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
# --- SINGLE-INSTANCE GUARD (fixes "two windows pop up": loader had no mutex) ---
# Only one Steadfast Loader may run. A second launch focuses the existing window
# and exits instead of stacking a duplicate.
$__sfCreatedNew = $false
$script:SfInstanceMutex = New-Object System.Threading.Mutex($true, 'Local\SteadfastLoader_SingleInstance', [ref]$__sfCreatedNew)
if (-not $__sfCreatedNew) {
    try {
        Add-Type -Namespace SfSingleInstance -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr FindWindow(string c, string n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int c);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
'@ -ErrorAction SilentlyContinue
        $__h = [SfSingleInstance.Win]::FindWindow($null, 'Steadfast Loader')
        if ($__h -ne [System.IntPtr]::Zero) {
            [void][SfSingleInstance.Win]::ShowWindow($__h, 9)
            [void][SfSingleInstance.Win]::SetForegroundWindow($__h)
        }
    } catch {}
    exit 0
}
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
    # base64url of the Worker's 32-byte Ed25519 PUBLIC key (the counterpart of
    # UDE_INSTALLER_SIGN_PRIV_KEY). NON-secret — belongs in config, not C:\Dev_Keys.
    # When set, Get-SfInstallerVerified additionally verifies the manifest's
    # installerSig over the sha256 bytes with the self-tested Ed25519 verifier and
    # HARD-STOPS on failure. Empty = signature layer dormant; the sha256 chain (feed
    # hash == downloaded exe, itself Worker-recomputed) still fully gates the install.
    InstallerSignPubKey = ''
  }
}
$script:PollSeconds    = 4
# Operator approval routinely takes far longer than the old 20-minute cap (a stuck
# customer was approved at +20 and +35 min, after the loader had already quit
# polling). Raised to 6h AND paired with relaunch-resume (see Resume-SfAllPending)
# so a still-pending request is never silently abandoned.
$script:PollTimeoutMin = 360

# -----------------------------------------------------------------------------
# SELF-UPDATE (so a tester never has to be re-sent a fresh loader by hand).
# On launch the loader asks its PUBLIC, ungated feed whether a newer build of
# ITSELF exists; if so it downloads it, verifies the published sha256, swaps the
# running exe in place and relaunches. Any failure is silent -- it just runs the
# current loader (never bricks a tester). The feed exposes ONLY the loader
# manifest + binary; it carries no secret (the GitHub read token lives on the
# worker). $LoaderVersion is the single source of version truth: build.ps1
# -Publish reads it to tag the release + write latest.json.
# -----------------------------------------------------------------------------
$script:LoaderVersion = '1.0.5'
$script:LoaderFeed    = 'https://steadfast-loader-feed.castforge.workers.dev'

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
  # GAP-10 (2026-07-30): bounded retry with backoff so a transient network blip does
  # not fail the install outright. The downstream sha256/sha512 check still catches a
  # truncated/partial file, so a retry can never install corrupt bytes.
  $attempts = 3
  for ($i = 1; $i -le $attempts; $i++) {
    try {
      Invoke-WebRequest -Uri $Url -Headers $Headers -OutFile $OutFile -UseBasicParsing -TimeoutSec 120
      return
    } catch {
      if ($i -eq $attempts) { throw }
      Start-Sleep -Seconds ([int][Math]::Min(8, [Math]::Pow(2, $i)))
    }
  }
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
  } catch {
    # GAP-8 (2026-07-30): FAIL-CLOSED. A legit (or legacy) token has a valid base64url
    # JSON payload that never throws here; only a malformed/garbage token reaches this
    # catch, so returning $false rejects exactly the bad ones. The worker 401 remains
    # the authority, but the loader no longer waves a broken token through.
    return $false
  }
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
# =============================================================================
# Ed25519 signature verification (GAP-3, 2026-07-30). .NET Framework has no Ed25519
# API, so we compile a compact BigInteger reference verifier (RFC 8032 -- slow but
# correct; one verify per install). It is SELF-TESTED against the RFC 8032 test vector
# at first use: only if the known-good vector verifies TRUE and a 1-bit-tampered vector
# verifies FALSE do we trust it. If the self-test fails (or the assembly won't compile),
# we DO NOT verify -- we fall back to the sha256 chain, so a buggy verifier can never
# accept a forged signature.
# =============================================================================
$script:SfEd25519Ready = $null
$SfEd25519Cs = @'
using System; using System.Numerics; using System.Security.Cryptography;
public static class SfEd {
  static readonly BigInteger P = BigInteger.Pow(2,255) - 19;
  static readonly BigInteger L = BigInteger.Pow(2,252) + BigInteger.Parse("27742317777372353535851937790883648493");
  static BigInteger M(BigInteger x){ x%=P; if(x.Sign<0)x+=P; return x; }
  static BigInteger Inv(BigInteger x){ return BigInteger.ModPow(M(x),P-2,P); }
  static readonly BigInteger D = default(BigInteger);
  static readonly BigInteger I = default(BigInteger);
  static readonly BigInteger[] Ba = null;
  static SfEd(){
    D = M(BigInteger.Parse("-121665")*Inv(121666));
    I = BigInteger.ModPow(2,(P-1)/4,P);
    BigInteger By = M(4*Inv(5));
    BigInteger Bx = Xrec(By);
    Ba = new BigInteger[]{Bx,By};
  }
  static BigInteger Xrec(BigInteger y){ BigInteger xx=M((y*y-1)*Inv(D*y*y+1)); BigInteger x=BigInteger.ModPow(xx,(P+3)/8,P); if(M(x*x-xx).Sign!=0)x=M(x*I); if((x&1)!=0)x=P-x; return x; }
  static BigInteger[] AddP(BigInteger[] p,BigInteger[] q){ BigInteger a=p[0],b=p[1],c=q[0],e=q[1]; BigInteger dd=M(D*a*c*b*e); BigInteger x=M((a*e+c*b)*Inv(1+dd)); BigInteger y=M((b*e+a*c)*Inv(1-dd)); return new BigInteger[]{x,y}; }
  static BigInteger[] Mul(BigInteger[] p,BigInteger n){ if(n.Sign==0) return new BigInteger[]{BigInteger.Zero,BigInteger.One}; BigInteger[] q=Mul(p,n/2); q=AddP(q,q); if((n&1)!=0)q=AddP(q,p); return q; }
  static BigInteger LE(byte[] b){ BigInteger r=BigInteger.Zero; for(int i=b.Length-1;i>=0;i--) r=r*256+b[i]; return r; }
  static BigInteger[] Dec(byte[] s){ byte[] t=(byte[])s.Clone(); int sign=(t[31]>>7)&1; t[31]=(byte)(t[31]&0x7f); BigInteger y=LE(t); BigInteger x=Xrec(y); if(((int)(x&1))!=sign)x=P-x; return new BigInteger[]{x,y}; }
  public static bool Verify(byte[] sig,byte[] msg,byte[] pk){
    if(sig==null||pk==null||sig.Length!=64||pk.Length!=32) return false;
    try{
      byte[] R=new byte[32]; Array.Copy(sig,0,R,0,32);
      byte[] Sb=new byte[32]; Array.Copy(sig,32,Sb,0,32); BigInteger S=LE(Sb);
      byte[] hin=new byte[64+msg.Length]; Array.Copy(R,0,hin,0,32); Array.Copy(pk,0,hin,32,32); Array.Copy(msg,0,hin,64,msg.Length);
      byte[] hh; using(var sha=SHA512.Create()) hh=sha.ComputeHash(hin);
      BigInteger h=LE(hh)%L; if(h.Sign<0)h+=L;
      var A=Dec(pk); var sB=Mul(Ba,S); var Rp=Dec(R); var hA=Mul(A,h); var RhA=AddP(Rp,hA);
      return sB[0]==RhA[0] && sB[1]==RhA[1];
    } catch { return false; }
  }
}
'@
function Test-SfEd25519Ready {
  if ($null -ne $script:SfEd25519Ready) { return $script:SfEd25519Ready }
  $ok = $false
  try {
    if (-not ('SfEd' -as [type])) {
      # BigInteger lives in System.Numerics.dll on .NET Framework (Windows PowerShell
      # 5.1 / PS2EXE — the loader's shipping runtime) but is forwarded to
      # System.Runtime.Numerics on .NET Core / PowerShell 7. Reference the assembly that
      # ACTUALLY backs BigInteger on whatever runtime we are on, resolved at runtime, so
      # the compile is correct on both without name-guessing. Also reference the SHA512
      # assembly the same way. If Add-Type fails for any reason the catch below sets
      # Ready=$false and the loader falls back to the sha256 chain (never a false accept).
      $refs = @(
        [System.Numerics.BigInteger].Assembly.Location,
        [System.Security.Cryptography.SHA512].Assembly.Location
      ) | Where-Object { $_ } | Sort-Object -Unique
      Add-Type -TypeDefinition $SfEd25519Cs -ReferencedAssemblies $refs -Language CSharp -ErrorAction Stop
    }
    # Fixed Ed25519 known-answer vector. Generated with Node's crypto (OpenSSL-backed
    # Ed25519) and verified good==true / 1-bit-tampered==false under this very verifier
    # on Windows PowerShell 5.1 (the loader's shipping runtime) on 2026-07-31. The
    # message is a 32-byte value, deliberately modelling the production path: the Worker
    # signs bytesFromHex(sha256) — a 32-byte hash — so the self-test exercises the exact
    # message length the real installerSig verification uses. If this KAT ever fails to
    # verify (buggy impl, broken BigInteger, wrong assembly), Ready stays false and the
    # loader falls back to the sha256 chain — it can NEVER accept a forged signature.
    $pk  = [byte[]]@(0xd5,0xc7,0xec,0xc1,0x20,0x6d,0xed,0x2b,0x5e,0xf8,0x86,0xf4,0x81,0x5a,0x4e,0xdd,0x17,0xbf,0x97,0x84,0x53,0xf4,0x31,0xa6,0x18,0x7f,0x56,0xd0,0xf0,0xa3,0xf1,0xc1)
    $msg = [byte[]]@(0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff,0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0x01)
    $sig = [byte[]]@(0x2f,0x3d,0x18,0x6e,0x23,0x86,0x32,0x99,0x7d,0x60,0x84,0x4e,0x93,0xbf,0x60,0x65,0x58,0x9c,0xfa,0x05,0xfa,0xf8,0x9d,0xe5,0x93,0xda,0x97,0xc9,0x0d,0x07,0x16,0x8f,0x51,0xcf,0x05,0x3a,0xad,0xae,0xd3,0xf6,0xd1,0xad,0xeb,0x0f,0x21,0x40,0x9a,0x9d,0x6b,0x94,0x24,0xce,0x42,0xdc,0x53,0x22,0x77,0x5e,0x11,0x72,0x16,0x2b,0x2b,0x08)
    $good = [SfEd]::Verify($sig,$msg,$pk)
    $bad = [byte[]]$sig.Clone(); $bad[0] = [byte]($bad[0] -bxor 1)
    $tamper = [SfEd]::Verify($bad,$msg,$pk)
    $ok = ($good -and -not $tamper)
  } catch { $ok = $false }
  $script:SfEd25519Ready = $ok
  return $ok
}
function ConvertFrom-SfB64UrlBytes([string]$s) {
  $s = $s.Replace('-', '+').Replace('_', '/'); switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
  return [Convert]::FromBase64String($s)
}
function ConvertFrom-SfHexBytes([string]$h) {
  $h = $h.Trim(); $out = New-Object byte[] ($h.Length/2)
  for ($i=0; $i -lt $out.Length; $i++) { $out[$i] = [Convert]::ToByte($h.Substring($i*2,2),16) }
  return $out
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
    # GAP-3 (2026-07-30, upgraded 2026-07-31): the manifest carries an Ed25519 installerSig
    # over the sha256. Two layers now guard it. (1) The sha256 chain is authoritative -- the
    # Worker computes it from the REAL ude-releases asset and we recompute+compare the
    # downloaded bytes below. (2) FULL cryptographic Ed25519 verify is now performed in-proc
    # by [SfEd] (a self-tested BigInteger RFC-8032 verifier that runs in the PS2EXE
    # .NET-Framework runspace -- no native Ed25519 API needed) whenever the Worker's public
    # key is configured. First, enforce the signature is PRESENT + well-formed as a tamper
    # tripwire: a 64-byte Ed25519 sig is ~86 base64url chars. A stripped or mangled sig is
    # refused BEFORE any download.
    $sig = if ($m.installerSig) { [string]$m.installerSig } else { '' }
    if ($sig -and ($sig -notmatch '^[A-Za-z0-9_-]{80,90}$')) {
      throw "UDE update feed installerSig is malformed (not a base64url Ed25519 signature). Nothing was run."
    }
    # Full Ed25519 verify when the Worker's public key is configured AND the self-tested
    # verifier is available. The Worker signs the RAW sha256 bytes (bytesFromHex(sha256)),
    # so the signed message is the 32-byte hash. A verify failure is a hard stop; when no
    # pubkey is set (or the runtime lacks a proven verifier) the sha256 chain stands in.
    $pub = if ($P.InstallerSignPubKey) { [string]$P.InstallerSignPubKey } else { '' }
    if ($sig -and $pub -and (Test-SfEd25519Ready)) {
      $ok2 = $false
      try { $ok2 = [SfEd]::Verify((ConvertFrom-SfB64UrlBytes $sig), (ConvertFrom-SfHexBytes $hash), (ConvertFrom-SfB64UrlBytes $pub)) } catch { $ok2 = $false }
      if (-not $ok2) { throw "UDE update feed installerSig FAILED Ed25519 verification (manifest tampered or wrong key). Nothing was run." }
    }
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

# =============================================================================
# SELF-UPDATE: check the feed for a newer loader, verify its hash, swap + relaunch.
# =============================================================================
function ConvertTo-SfVersion([string]$v) {
  try { return [version]($v -replace '^[vV]', '') } catch { return $null }
}
function Invoke-SfSelfUpdate {
  try {
    # Only the COMPILED loader may self-swap. In dev (running loader.ps1 under
    # pwsh) the host exe is pwsh.exe -- never touch it.
    $selfExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if (-not $selfExe -or ([System.IO.Path]::GetFileName($selfExe) -ne 'SteadfastLoader.exe')) { return }

    $man = Invoke-SfGetJson "$($script:LoaderFeed)/loader/latest"
    if (-not $man -or -not $man.version) { return }
    $latest = ConvertTo-SfVersion ([string]$man.version)
    $cur    = ConvertTo-SfVersion $script:LoaderVersion
    if (-not $latest -or -not $cur -or $latest -le $cur) { return }   # already current

    $sha = if ($man.sha256) { [string]$man.sha256 } else { '' }
    if (-not $sha) { return }   # refuse to swap without an integrity value

    $tmp = Join-Path $env:TEMP ("SteadfastLoader-" + ([string]$man.version) + ".exe")
    Invoke-SfDownload "$($script:LoaderFeed)/loader/download/SteadfastLoader.exe" $tmp @{}
    # Hash via .NET, NOT Get-FileHash: the PS2EXE runspace does not include the
    # Get-FileHash cmdlet, so it throws CommandNotFound and self-update silently
    # aborts. The .NET SHA256 path is the same one used for the device id.
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { $calcBytes = $sha256.ComputeHash([System.IO.File]::ReadAllBytes($tmp)) } finally { $sha256.Dispose() }
    $calc = -join ($calcBytes | ForEach-Object { $_.ToString('x2') })
    if ($calc -ine $sha) { try { [System.IO.File]::Delete($tmp) } catch { }; return }  # integrity fail -> keep current

    # Stage the verified new exe beside the running one, then hand off to a
    # detached PowerShell swapper: a running .exe is locked, so it waits for THIS
    # process to exit, retries Move-Item over the original until it succeeds, and
    # relaunches it. (A cmd/.bat swapper proved unreliable to launch detached;
    # powershell.exe is on every Windows box and launches cleanly.) If the move
    # can never happen (e.g. no write permission), nothing is lost -- the old exe
    # stays and keeps working.
    $newPath = "$selfExe.new"
    [System.IO.File]::Copy($tmp, $newPath, $true)   # .NET copy (avoid cmdlet gaps in the PS2EXE runspace)
    $se = $selfExe.Replace("'", "''")
    $np = $newPath.Replace("'", "''")
    $swap = "Start-Sleep -Seconds 2; for(`$i=0;`$i -lt 40;`$i++){ try{ Move-Item -LiteralPath '$np' -Destination '$se' -Force; break }catch{ Start-Sleep -Milliseconds 500 } }; Start-Process -FilePath '$se'"
    # Release the single-instance mutex so the relaunched loader can acquire it.
    try { $script:SfInstanceMutex.ReleaseMutex() } catch {}
    Start-Process powershell -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-Command', $swap -WindowStyle Hidden
    exit 0
  } catch {
    # Any failure -> silently continue with the current loader. A one-line breadcrumb
    # is written so a self-update problem is diagnosable without bricking anyone.
    try { ("{0} self-update: {1}: {2}" -f [DateTime]::Now.ToString('o'), $_.Exception.GetType().Name, $_.Exception.Message) | Out-File "$env:TEMP\sf-selfupdate.log" -Append -Encoding utf8 } catch { }
  }
}
# Run the check up front, before any UI is built (avoids flashing a window we are
# about to relaunch). Guarded + fail-safe: a bad network or feed never blocks use.
Invoke-SfSelfUpdate

# request-id persistence (per product) so a relaunch resumes a pending request
function Get-SfRequestStatePath([string]$ProductKey) { Join-Path $env:TEMP "$ProductKey-loader-request.json" }
function Save-SfRequestState([string]$ProductKey, [string]$RequestId) {
  $rec = @{ requestId = $RequestId; at = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json
  [System.IO.File]::WriteAllText((Get-SfRequestStatePath $ProductKey), $rec, (New-Object System.Text.UTF8Encoding($false)))
}
function Clear-SfRequestState([string]$ProductKey) { try { Remove-Item (Get-SfRequestStatePath $ProductKey) -Force -ErrorAction SilentlyContinue } catch {} }
# Read back a saved pending request (the persistence above was previously write-only:
# the id was saved but nothing ever re-read it, so a relaunch could never resume).
function Get-SfRequestState([string]$ProductKey) {
  $p = Get-SfRequestStatePath $ProductKey
  if (-not (Test-Path $p)) { return $null }
  try { return (Get-Content -Path $p -Raw | ConvertFrom-Json) } catch { return $null }
}

# DEVICE-KEYED lookup: ask the worker "is THIS device already approved for this product?"
# Returns the token/license if approved, else $null. This is what lets the loader
# recognize an already-approved device and skip requesting/waiting entirely, and makes
# an operator's approval reach the device no matter which request it approved.
function Get-SfApprovedKeyForDevice([hashtable]$P) {
  try {
    $r = Invoke-SfGetJson "https://$($P.LicenseDomain)$($P.ApiPrefix)/device/$([uri]::EscapeDataString($script:Hwid))"
    if ($r -and $r.status -eq 'approved') {
      $tok = if ($r.token) { $r.token } elseif ($r.license) { $r.license } else { $null }
      if ($tok) { return [string]$tok }
    }
  } catch { }
  return $null
}


# =============================================================================
# UI  (minimal WinForms - native window, product dropdown + request form)
# =============================================================================
# Multi-product state. Instead of a single $script:RequestId we now track a
# per-product job record so 1-3 products can be requested / polled / activated in
# ONE run. Keyed by product key (same keys as $script:PRODUCTS). Each job is:
#   @{ Product; DisplayName; Name; RequestId; Status; Message; P }
# Status is one of: pending | approved | denied | activated | error
$script:Hwid        = Get-SfHwid
$script:Jobs        = @{}
$script:ProductKeys = @($script:PRODUCTS.Keys)
$script:PollTimer   = $null
$script:PollStarted = $null

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'Steadfast Loader'
$form.Size            = New-Object System.Drawing.Size(470, 545)
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

$form.Controls.Add((New-SfLabel 'Products (check 1-3)' 20 46 300))
# Multi-select: one checkbox per product in $script:PRODUCTS. The user may check
# 1, 2, or all 3. Index order matches $script:ProductKeys so a checked index maps
# straight back to a product key.
$clbProducts = New-Object System.Windows.Forms.CheckedListBox
$clbProducts.Location = New-Object System.Drawing.Point(20, 66)
$clbProducts.Size = New-Object System.Drawing.Size(410, 70)
$clbProducts.CheckOnClick = $true
$clbProducts.IntegralHeight = $false
foreach ($k in $script:ProductKeys) { [void]$clbProducts.Items.Add($script:PRODUCTS[$k].DisplayName) }
$form.Controls.Add($clbProducts)

$form.Controls.Add((New-SfLabel 'Name'  20 142 120)); $txtName    = New-SfText 20 162 410; $form.Controls.Add($txtName)
$form.Controls.Add((New-SfLabel 'Email' 20 190 120)); $txtEmail   = New-SfText 20 210 410; $form.Controls.Add($txtEmail)
$form.Controls.Add((New-SfLabel 'Company (optional)' 20 238 200)); $txtCompany = New-SfText 20 258 410; $form.Controls.Add($txtCompany)

$lblHwid = New-SfLabel "Device ID: $($script:Hwid)" 20 286 430
$form.Controls.Add($lblHwid)

$btnRequest = New-Object System.Windows.Forms.Button
$btnRequest.Text = 'Request license'
$btnRequest.Location = New-Object System.Drawing.Point(20, 312)
$btnRequest.Size = New-Object System.Drawing.Size(410, 32)
$form.Controls.Add($btnRequest)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(20, 352)
$lblStatus.Size = New-Object System.Drawing.Size(410, 40)
$lblStatus.Text = 'Check the products you want, enter your details, and request licenses. Approval releases each download.'
$form.Controls.Add($lblStatus)

# Per-product status list so the user sees, e.g.,
#   Nexus Optimus: waiting for approval
#   CastForge: installed / activated
#   Undestructable Update Engine: declined: ...
$txtProductStatus = New-Object System.Windows.Forms.TextBox
$txtProductStatus.Location = New-Object System.Drawing.Point(20, 396)
$txtProductStatus.Size = New-Object System.Drawing.Size(410, 92)
$txtProductStatus.Multiline = $true
$txtProductStatus.ReadOnly = $true
$txtProductStatus.ScrollBars = 'Vertical'
$txtProductStatus.BackColor = [System.Drawing.SystemColors]::Window
$form.Controls.Add($txtProductStatus)

function Set-SfStatus([string]$msg) { $lblStatus.Text = $msg; $lblStatus.Refresh() }

# Products the user has currently checked, as an array of product config hashtables.
function Get-SfCheckedProducts {
  $sel = @()
  foreach ($i in $clbProducts.CheckedIndices) { $sel += $script:PRODUCTS[$script:ProductKeys[$i]] }
  return $sel
}

# Count of jobs still needing the poll loop (pending, or approved-but-not-yet-installed).
function Get-SfActiveJobCount {
  $n = 0
  foreach ($k in $script:ProductKeys) {
    if ($script:Jobs.Contains($k)) {
      $s = $script:Jobs[$k].Status
      if ($s -eq 'pending' -or $s -eq 'approved') { $n++ }
    }
  }
  return $n
}

# Rebuild the per-product status panel from $script:Jobs (in catalogue order).
function Set-SfProductStatusUi {
  $lines = @()
  foreach ($k in $script:ProductKeys) {
    if ($script:Jobs.Contains($k)) {
      $j = $script:Jobs[$k]
      $human = switch ($j.Status) {
        'pending'   { 'waiting for approval' }
        'approved'  { 'approved - installing' }
        'activated' { 'installed / activated' }
        'denied'    { "declined: $($j.Message)" }
        'error'     { "error: $($j.Message)" }
        default     { [string]$j.Status }
      }
      $lines += "$($j.DisplayName): $human"
    }
  }
  $txtProductStatus.Text = ($lines -join [Environment]::NewLine)
  $txtProductStatus.Refresh()
}

function Stop-SfPoll { if ($script:PollTimer) { $script:PollTimer.Stop(); $script:PollTimer.Dispose(); $script:PollTimer = $null } }

# Download / verify / activate a SINGLE approved product independently of the others.
# Unlike the old single-product flow this NEVER closes the form (other products may
# still be pending); it just marks that product's job 'activated' (or 'error') and
# lets the poll loop keep going for the rest.
function Complete-SfApprovedJob([hashtable]$Job, [string]$Token) {
  $P = $Job.P
  $Job.Status = 'approved'; $Job.Message = 'installing'
  Set-SfProductStatusUi
  try {
    if (-not (Test-SfTokenBinding $Token $script:Hwid $P.Product)) {
      $Job.Status = 'error'; $Job.Message = 'license does not match this device/product'
      Set-SfProductStatusUi
      return
    }
    Set-SfStatus "Approved: $($P.DisplayName). Downloading and verifying the installer..."
    $installer = Get-SfInstallerVerified $Token $P
    # Write the licence BEFORE running the installer: installers commonly auto-launch
    # the app when they finish, and the app checks its licence at startup. Writing
    # license.json first guarantees the app opens PRE-ACTIVATED instead of flashing a
    # "locked / paste your key" wall because the file landed a beat too late.
    Set-SfStatus "Activating $($P.DisplayName) on this device..."
    Write-SfLicense $Token $script:Hwid $P
    Set-SfStatus "Installing $($P.DisplayName)..."
    Invoke-SfInstaller $installer $P
    Clear-SfRequestState $P.Product
    $Job.Status = 'activated'; $Job.Message = ''
  } catch {
    $Job.Status = 'error'; $Job.Message = $_.Exception.Message
  }
  Set-SfProductStatusUi
}

# One poll cycle: poll EVERY still-active product (pending or approved-awaiting-token)
# and update its job independently. One product's failure never aborts the batch.
function Invoke-SfPollTick {
  # Snapshot the products that still need work this cycle.
  $active = @()
  foreach ($k in $script:ProductKeys) {
    if ($script:Jobs.Contains($k)) {
      $s = $script:Jobs[$k].Status
      if ($s -eq 'pending' -or $s -eq 'approved') { $active += $k }
    }
  }
  if ($active.Count -eq 0) { Stop-SfPoll; return }

  if (((Get-Date) - $script:PollStarted).TotalMinutes -ge $script:PollTimeoutMin) {
    Stop-SfPoll
    # Pending state is intentionally NOT cleared: reopening the loader auto-resumes
    # every still-pending request via Resume-SfAllPending.
    Set-SfStatus 'Still pending. You can close this - it resumes automatically when you reopen the loader.'
    $btnRequest.Enabled = $true; $clbProducts.Enabled = $true
    return
  }

  foreach ($k in $active) {
    $j = $script:Jobs[$k]
    $P = $j.P
    try {
      # DEVICE-KEYED poll: is THIS device approved for the product now? Authoritative --
      # one request's rejection or a stale id must NEVER declare the product declined.
      $tok = Get-SfApprovedKeyForDevice $P
      if ($tok) { Complete-SfApprovedJob $j $tok }
      else { $j.Status = 'pending'; $j.Message = '' }
    } catch {
      # transient network blip -- leave pending, retry next tick
    }
  }

  Set-SfProductStatusUi
  $stillActive = Get-SfActiveJobCount
  if ($stillActive -eq 0) {
    Stop-SfPoll
    $btnRequest.Enabled = $true; $clbProducts.Enabled = $true
    Set-SfStatus 'All requests resolved. See per-product status below.'
  } else {
    Set-SfStatus "Waiting for operator approval... ($stillActive still pending, device $($script:Hwid))"
  }
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

# Resume EVERY still-pending request found in %TEMP% on launch (the persistence
# layer is already per-product). This closes the loop the persistence left open
# (state was saved but never read back), so approvals that land after the loader was
# closed are collected the next time it opens -- for all products at once. Rebuilds
# the multi-product job table from the per-product saved records and checks each
# resumed product in the list so the UI reflects it. Returns $true if any resumed.
function Resume-SfAllPending {
  $resumed = $false
  for ($i = 0; $i -lt $script:ProductKeys.Count; $i++) {
    $key = $script:ProductKeys[$i]
    $P = $script:PRODUCTS[$key]
    $st = Get-SfRequestState $P.Product
    if (-not $st) { continue }
    # Drop a request older than the worker's retention window so we never resume onto
    # an id the server has already forgotten (a 404 during polling also self-heals it).
    try {
      $age = ((Get-Date).ToUniversalTime() - ([datetime]$st.at).ToUniversalTime()).TotalDays
      if ($age -gt 7) { Clear-SfRequestState $P.Product; continue }
    } catch { Clear-SfRequestState $P.Product; continue }
    $script:Jobs[$key] = @{ Product = $P.Product; DisplayName = $P.DisplayName; Name = ''; RequestId = $null; Status = 'pending'; Message = ''; P = $P }
    $clbProducts.SetItemChecked($i, $true)
    $resumed = $true
  }
  if ($resumed) {
    $btnRequest.Enabled = $false; $clbProducts.Enabled = $false
    Set-SfProductStatusUi
    Set-SfStatus 'Resuming your pending request(s) - waiting for operator approval...'
    Start-SfPoll
  }
  return $resumed
}

$btnRequest.Add_Click({
  $sel   = Get-SfCheckedProducts
  $name  = $txtName.Text.Trim()
  $email = $txtEmail.Text.Trim()
  if ($sel.Count -lt 1) { Set-SfStatus 'Please check at least one product.'; return }
  if (-not $name -or -not $email) { Set-SfStatus 'Please enter your name and email.'; return }
  if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { Set-SfStatus 'Please enter a valid email.'; return }
  $btnRequest.Enabled = $false
  $clbProducts.Enabled = $false
  $company = $txtCompany.Text.Trim()
  # POST one /request per checked product. Record each result as a job; a failure on
  # one product is recorded and we continue with the rest (never abort the batch).
  $anySent = $false
  foreach ($P in $sel) {
    # DEVICE-FIRST: already approved for this device? activate now, never request.
    $existing = Get-SfApprovedKeyForDevice $P
    if ($existing) {
      $job = @{ Product = $P.Product; DisplayName = $P.DisplayName; Name = $name; RequestId = $null; Status = 'approved'; Message = ''; P = $P }
      $script:Jobs[$P.Product] = $job
      Complete-SfApprovedJob $job $existing
      $anySent = $true
      continue
    }
    # DE-DUPE: already have a pending request saved for this device+product? don't mint a duplicate.
    if (Get-SfRequestState $P.Product) {
      $script:Jobs[$P.Product] = @{ Product = $P.Product; DisplayName = $P.DisplayName; Name = $name; RequestId = $null; Status = 'pending'; Message = ''; P = $P }
      $anySent = $true
      continue
    }
    Set-SfStatus "Sending $($P.DisplayName) request..."
    try {
      $body = @{ name = $name; email = $email; hwid = $script:Hwid; product = $P.Product; appVersion = 'loader' }
      if ($company) { $body.company = $company }
      $resp = Invoke-SfPostJson "https://$($P.LicenseDomain)$($P.ApiPrefix)/request" $body
      if ($resp -and $resp.requestId) {
        Save-SfRequestState $P.Product ([string]$resp.requestId)
        $script:Jobs[$P.Product] = @{ Product = $P.Product; DisplayName = $P.DisplayName; Name = $name; RequestId = [string]$resp.requestId; Status = 'pending'; Message = ''; P = $P }
        $anySent = $true
      } else {
        $err = if ($resp -and $resp.error) { $resp.error } else { 'unknown error' }
        # rate_limited just means mid-cooldown / already pending -- treat as pending, poll by device.
        if ($err -match 'rate') {
          Save-SfRequestState $P.Product ''
          $script:Jobs[$P.Product] = @{ Product = $P.Product; DisplayName = $P.DisplayName; Name = $name; RequestId = $null; Status = 'pending'; Message = ''; P = $P }
          $anySent = $true
        } else {
          $script:Jobs[$P.Product] = @{ Product = $P.Product; DisplayName = $P.DisplayName; Name = $name; RequestId = $null; Status = 'error'; Message = $err; P = $P }
        }
      }
    } catch {
      $msg = $_.Exception.Message
      if ($msg -match '429|rate') {
        Save-SfRequestState $P.Product ''
        $script:Jobs[$P.Product] = @{ Product = $P.Product; DisplayName = $P.DisplayName; Name = $name; RequestId = $null; Status = 'pending'; Message = ''; P = $P }
        $anySent = $true
      } else {
        $script:Jobs[$P.Product] = @{ Product = $P.Product; DisplayName = $P.DisplayName; Name = $name; RequestId = $null; Status = 'error'; Message = $msg; P = $P }
      }
    }
  }

  Set-SfProductStatusUi
  if ($anySent) {
    Set-SfStatus 'Request(s) sent. Waiting for operator approval...'
    Start-SfPoll
  } else {
    Set-SfStatus 'No requests could be sent. See per-product status below.'
    $btnRequest.Enabled = $true; $clbProducts.Enabled = $true
  }
})

$form.Add_FormClosed({ Stop-SfPoll })
# On launch, auto-resume ALL still-pending requests found in %TEMP% (per-product).
[void](Resume-SfAllPending)
[void]$form.ShowDialog()
