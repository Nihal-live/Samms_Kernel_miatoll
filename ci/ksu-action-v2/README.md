# Building with KernelSU_Action_V2

[`Nihal-live/KernelSU_Action_V2`](https://github.com/Nihal-live/KernelSU_Action_V2)
is the build pipeline used here for its logging and its debug switches. It is
compatible with this tree, but it needs three small additions for it:

| File | Why |
| --- | --- |
| `scripts/kernelsu.sh` | a `samms-nova` variant: SukiSU-Nova has no `kernel/setup.sh`, because the integration lives in *this* repo (`scripts/ksu-nova-setup.sh`) |
| `scripts/config.sh` | lets `ENABLE_KPM=true` with that variant |
| `scripts/patches.sh` | the KPM step delegates to this tree's `scripts/kpm-patch.sh`, which owns the gz+dtb repacking |
| `config/miatoll.env` | the device profile: source repo, branch, defconfig, Clang, KPM on, no SUSFS |

Two things in that profile are there because of how this tree builds, not
because of the device:

* `CUSTOM_CMDS:CLANG_TRIPLE=aarch64-linux-gnu-` -- the Makefile refuses to build
  when `CROSS_COMPILE` ends in `android-` and the Clang target is not overridden.
* `EXTRA_CMDS:... HOSTLDFLAGS=-B/usr/bin` -- proton-clang's `bin/` ships an old
  GNU `ld` that is ahead of `/usr/bin` in `PATH`, and the host link of
  `scripts/basic/fixdep` fails on it (`unknown type [0x13] section .relr.dyn`),
  which surfaces as a defconfig failure before anything is compiled.

All four are in [`miatoll.patch`](miatoll.patch), which applies on top of
KernelSU_Action_V2 `26c1b95532` (2026-10-25):

```sh
git clone https://github.com/Nihal-live/KernelSU_Action_V2 && cd KernelSU_Action_V2
git checkout 26c1b95532549d4cb57ab152f5650003d89c6efb
git apply /path/to/miatoll.patch
# Actions -> Build Kernel -> Run workflow -> Config file: config/miatoll.env
```

Push access to that repository is required to commit the patch; the workflow in
this repo ([`build-with-ksu-action.yml`](../../.github/workflows/build-with-ksu-action.yml))
does the same thing without needing any: it clones the action at the pinned
commit, applies the patch and runs its scripts, so the build still goes through
KernelSU_Action_V2's own code.
