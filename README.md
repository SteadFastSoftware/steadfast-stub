# Steadfast Software - Installer

The public installer ("stub") for Steadfast Software products: Nexus Optimus,
CastForge, and the Undestructable Update Engine (UDE).

## How it works
1. Download the **one** universal loader (`SteadfastLoader.exe`) — it serves every
   product from an in-app dropdown; there is no per-product download.
2. Run it - it reads this machine's device ID (byte-identical across all products)
   and lets you request a license for one or more products at once.
3. Steadfast approves your request.
4. Once approved, the loader securely downloads and installs each product through the
   licensed update channel. Your license is the key; without approval, nothing downloads.

**Already approved?** The loader is device-keyed (GAP-43): re-running it recognizes a
device that's already approved and activates it straight away — no re-requesting.

**Self-updating (GAP-44).** On launch the loader checks a public feed for a newer
build of itself, verifies its published SHA-256, and swaps itself in place — so you
only ever download it once; future loader improvements arrive automatically.

The full products and their releases are private. Only this thin, self-updating
loader is public. It carries no product code and no secrets.

(c) Steadfast Software LLC