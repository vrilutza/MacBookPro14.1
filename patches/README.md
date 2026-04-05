# patches/ — Cirrus CS8409 driver diff archive

This directory contains reference diffs showing **what this project changes** in the
Cirrus Logic CS8409 HDA audio driver relative to the upstream kernel source.

These are **not applied by any script** — they are archived for reference and debugging.
The actual modified files live in `patch_cirrus/`.

---

## Files

| File | Source base | What it shows |
|------|------------|---------------|
| `patch_patch_cs8409.h.main.diff` | mainline kernel ≥5.19 | Changes to `patch_cs8409.h` vs upstream mainline |
| `patch_patch_cs8409.h.ubuntu.diff` | Ubuntu kernel ≥5.15.47 | Changes to `patch_cs8409.h` vs Ubuntu HWE base |
| `patch_patch_cs8409.h.main.pre519.diff` | mainline kernel <5.19 | Changes to `patch_cs8409.h` vs older mainline |
| `patch_patch_cs8409.h.ubuntu.pre51547.diff` | Ubuntu kernel <5.15.47 | Changes to `patch_cs8409.h` vs older Ubuntu base |
| `patch_patch_cirrus_apple.h.main.diff` | mainline kernel ≥5.19 | Changes to `patch_cirrus_apple.h` vs upstream mainline |
| `patch_patch_cirrus_apple.h.ubuntu.diff` | Ubuntu kernel ≥5.15.47 | Changes to `patch_cirrus_apple.h` vs Ubuntu base |

---

## What the patches do

### `patch_cs8409.h` (559-line diffs)

The core HDA codec patch for the Cirrus Logic CS8409 chip on MacBook Pro 14,1.
Changes vs upstream:
- MacBook Pro 2017 (MacBookPro14,1) quirk tables for CS42L83 codec topology
- Pin configuration overrides for speakers, headphone jack, internal mic
- CS8409 codec init sequence fixes for Ubuntu kernel
- SSM3515 / MAX98706 amplifier control paths

### `patch_cirrus_apple.h` (12-line diffs)

Apple-specific additions to the CS8409 patch header.
Changes vs upstream:
- MacBookPro14,1 board identifier
- Apple-specific codec address constants

---

## Two source variants: `main` vs `ubuntu`

Ubuntu kernels (from `linux-source-*`) diverge significantly from Linus mainline:
extensive backporting means the HDA subsystem source tree differs in file layout,
struct definitions, and function signatures.

The installer (`install.cirrus.driver.sh`) picks the correct variant automatically
based on the running kernel version and distribution.

| Variant | Kernel range | Used by |
|---------|-------------|---------|
| `ubuntu` | Ubuntu 22.04/24.04/26.04 kernel | install.cirrus.driver.sh (default) |
| `main` | Upstream Linus mainline | manual builds on non-Ubuntu distros |
| `pre519` / `pre51547` | Older kernels | install.cirrus.driver.pre617.sh |

---

## How to use these diffs for debugging

If the driver fails to compile on a new kernel, compare the current upstream
`patch_cs8409.h` with our modified version:

```bash
# Extract upstream source for current kernel
sudo apt-get install linux-source-$(uname -r | cut -d- -f1)
tar -xf /usr/src/linux-source-*.tar.bz2 linux-source-*/sound/hda/patch_cs8409.h

# Compare with our version
diff linux-source-*/sound/hda/patch_cs8409.h patch_cirrus/patch_cs8409.h
```

The diffs in this directory serve as a baseline — new conflicts show exactly
what changed in the upstream kernel that needs re-porting.
