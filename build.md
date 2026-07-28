# Building the Universal Loader

Standard: `STEADFAST-DEVKIT-STANDARD.md` §6b.3 (universal loader) + §6b.2 (code
signing). Doctrine: D31 (bus carries requests) / D32 (licensing + signing are
local) / D37 (forward-thinking — the built artifact must equal the shipped one).

The public download is **one universal loader** (`loader.ps1` →
`SteadfastLoader.exe`) that serves **every** product from an in-app dropdown; its
product catalogue is baked in-file, sourced from the central `registry.js`. There
is no per-product rendering — one binary covers the whole catalogue.

> **Superseded:** the old per-product `stub.ps1` model (rendered `<product>-setup.exe`)
> was retired to `_trash` on 2026-07-25 (GAP-32). It was never the artifact anyone
> downloaded (the Hub serves `SteadfastLoader.exe`), and `build.ps1` used to build
> that unused client while the shipped loader had no scripted build — the exact
> divergence GAP-32 flagged. `build.ps1` now builds `loader.ps1` directly.

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

- **ps2exe** — `Install-Module ps2exe -Scope CurrentUser`. Required to compile.
- **signtool.exe** (Windows SDK) + the shared **OV/HSM signing identity** — required for `-Sign`.

(node is no longer required: the loader carries its catalogue in-file, so there is
no per-product config to read at build time.)

## Build the loader

```powershell
# compile (unsigned dev build)
pwsh ./build.ps1

# release: compile + Authenticode-sign
pwsh ./build.ps1 -Sign

# CI / syntax: parse only, no compiler needed
pwsh ./build.ps1 -SkipCompile
```

Output (in `dist/`):
- `SteadfastLoader.exe` — the native, (optionally signed) public download for the
  whole catalogue. Any previous exe is preserved under `dist/_prev/` (never
  overwrite-without-backup).

The build first **syntax-parses** `loader.ps1` (fails on any parse error before it
compiles), then runs PS2EXE `-noConsole`.

## Publish + self-update (GAP-43 / GAP-44)

The loader **updates itself** so a tester never has to be re-sent a new binary.
On launch it reads its embedded `$script:LoaderVersion`, asks the public ungated
feed (`$LoaderFeed` → `steadfast-loader-feed` worker) for `latest.json`, and if a
newer version exists it downloads `SteadfastLoader.exe`, verifies the published
`sha256`, swaps its own exe in place (a detached `powershell.exe` swapper waits
for this process to exit, retries `Move-Item`, then relaunches) and continues.
Any failure is silent — it just runs the current exe and writes a one-line
breadcrumb to `%TEMP%\sf-selfupdate.log`.

```powershell
# build, hash, write latest.json, and push exe+manifest to the PRIVATE feed repo
pwsh ./build.ps1 -Publish
```

- **Version is single-sourced** from `$script:LoaderVersion` in `loader.ps1` —
  bump it, then `-Publish`. That is what tags the release (`vX.Y.Z`) and the
  `latest.json` version.
- **Feed = `steadfast-loader-feed` worker** (`steadfast-stub/worker/`) proxying the
  **private** `SteadFastSoftware/steadfast-stub-releases` repo with a server-side
  `GH_RELEASE_TOKEN` (read-only, single-repo). The loader carries **no secret**
  (D32); the feed is asset-allowlisted + fail-closed + per-IP rate-limited and
  serves ONLY `latest.json` + `SteadfastLoader.exe`.
- **PS2EXE runspace caveat (GAP-44):** the compiled exe's session does **not**
  include every cmdlet — `Get-FileHash` is missing and throws `CommandNotFound`.
  Self-update code therefore hashes via `[System.Security.Cryptography.SHA256]`,
  copies via `[System.IO.File]::Copy`, and does detached work via `powershell.exe`
  (a `cmd`/`.bat` swapper would not launch reliably). **Always prove self-update
  against the ACTUAL compiled exe, never source alone** (D08).

## Adding a product to the loader

Because the loader is universal, a new product does **not** get its own build: add
an entry to the `$script:PRODUCTS` catalogue in `loader.ps1` (values sourced from
`registry.js`: product key, `licenseDomain`, feed/hash, license dir) and rebuild.
Keep the catalogue in step with `registry.js` — that is the single source of truth
for ports, license domains, and releases repos.

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
