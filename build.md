# Building the Universal Stub

Standard: `STEADFAST-DEVKIT-STANDARD.md` §6b.3 (universal stub) + §6b.2 (code
signing). Doctrine: D31 (bus carries requests) / D32 (licensing + signing are
local).

The stub is **one codebase** (`stub.ps1`) built **per product** by rendering a
small config region from the central `registry.js` + the product's
`product.config.js`. No product ever forks the stub; only its config differs.

## Language choice — PowerShell + PS2EXE (native, tiny, not Electron)

| Candidate | Verdict |
|---|---|
| Electron | ✗ 100 MB+ per download; the whole point of the stub is to be thin |
| Go / Rust | Preferred if a toolchain is present, but **no `go`/`rustc`/`dotnet` is installed** on this build host |
| **PowerShell + PS2EXE** | ✓ ships on every Win10/11 (zero runtime to install), compiles to a **small native `.exe`**, WinForms gives a native window, and the Steadfast stack **already uses PS2EXE + Authenticode** (UDE), so signing (§6b.2) is already wired |

If a Go/Rust toolchain is later added to the build host, the same flow
(HWID → request → poll → gated fetch+verify → run → write license) ports 1:1;
the contract in `README.md` is language-agnostic.

## Prerequisites

- **node** — reads `registry.js` and `product.config.js` (both CommonJS). Always required.
- **ps2exe** — `Install-Module ps2exe -Scope CurrentUser`. Required to compile.
- **signtool.exe** (Windows SDK) + the shared **OV/HSM signing identity** — required for `-Sign`.

## Build a product's stub

```powershell
# render + compile (unsigned dev build)
pwsh ./build.ps1 -Product nexus

# point at the product's product.config.js for stub overrides + cross-check
pwsh ./build.ps1 -Product nexus -ProductConfig C:\SteadfastSoftware\Nexus_Optimizer\product.config.js

# release: render + compile + Authenticode-sign
pwsh ./build.ps1 -Product nexus -Sign

# CI / syntax: render only, no compiler needed
pwsh ./build.ps1 -Product nexus -SkipCompile
```

Outputs (in `stub/dist/`):
- `<product>-stub.ps1` — the rendered, product-configured source.
- `<product>-setup.exe` — the native, (optionally signed) public download.

## What the build injects (and from where)

`build.ps1` replaces the `# --- SF-CONFIG-BEGIN --- … # --- SF-CONFIG-END ---`
region of `stub.ps1` with values resolved by a small node reader:

| Config field | Source | Notes |
|---|---|---|
| `Product` | `registry.PRODUCTS[<key>].product` | registry is the source of truth |
| `DisplayName` | `registry.PRODUCTS[<key>].name` | window title / labels |
| `LicenseDomain` | `registry.PRODUCTS[<key>].licenseDomain` | `<product>-license.steadfastsoftwarellc.com` |
| `Platform` / `Arch` | `product.config.stub` (default `win32` / `x64`) | baked HWID inputs |
| `FeedManifest` / `HashField` | `product.config.stub` (default `latest.yml` / `sha512`) | electron-updater feed; PS2EXE products override |
| `LicenseDir` / `LicenseFile` | `product.config.stub` (default `%APPDATA%\<DisplayName>` / `license.json`) | where the app reads its license |
| `InstallerArgs` | `product.config.stub` (default `''`) | e.g. `/S` for silent NSIS |

**Cross-check:** if `product.config.licenseWorker` is set it MUST equal the
registry `licenseDomain`, or the build fails (no drift — mirrors
`gate-port-isolation` / `gate-devkit-parity`).

## Signing hook (§6b.2 — the ONE OV/HSM identity)

Signing plugs into `build.ps1` step 4 (`-Sign`). The private key lives on an
**HSM / hardware token (or Azure Trusted Signing)** — never in a repo, never on
a worker (D32/D33). The stub is signed the **same way, from the same identity**
as every product installer (`core/pipeline/signing.js`). `gate-code-signing`
blocks a release whose stub isn't validly signed once the signing lockfile is
`signed` (ratchet). The build prints the exact `signtool` invocation used.

## Integrity of what the stub downloads (§6b.2 — published hashes)

The stub never trusts the OS trust chain alone. It fetches the product's
published feed manifest (electron-updater `latest.yml`, or a product's own hash
manifest), reads the installer's **published SHA-512**, downloads the installer
through the gated feed, recomputes the hash, and **refuses to run on mismatch**.
`core/pipeline/release.js` is what emits those hashes at release time.
