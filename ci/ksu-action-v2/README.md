# Building with KernelSU_Action_V2

[`Nihal-live/KernelSU_Action_V2`](https://github.com/Nihal-live/KernelSU_Action_V2)
is the other build pipeline here, used for its step-by-step logging and its
`RUNNER_DEBUG` switch. It builds this tree as it stands — same kernel, same
SukiSU-Nova tree, same KPM step — with four small additions carried in
[`miatoll.patch`](miatoll.patch) and the device profile `config/miatoll.env`.

**Status: it works.** Run
[`45101073164`](https://github.com/Nihal-live/Samms_Kernel_miatoll/actions/runs/45101073164)
(20m51s, action commit `26c1b95532` + this patch) produced `Image`, `Image.gz`
and a patched `Image.gz-dtb`, with the KernelPatch payload in the image.

## What the patch adds, and why

| File | Change | Why it is needed for this tree |
| --- | --- | --- |
| `scripts/kernelsu.sh` | a `samms-nova` variant, and an install path for it | SukiSU-Nova ships no `kernel/setup.sh`: the integration lives in this repo (`scripts/ksu-nova-setup.sh`), because it owns the 4.14 hook call sites, the KPM and cpu_spoof ports and the defconfig block. The variant runs that script and then verifies the symlink, the `drivers/Makefile` wiring, `drivers/Kconfig` and the pinned commit. Re-deriving hooks in the action would patch the call sites twice, and the second patch would not apply. |
| `scripts/config.sh` | `ENABLE_KPM` allowed for that variant, variant added to the accepted list | KPM is not exclusive to `sukisu-ultra`; the check is about which forks speak the KernelPatch supercall. |
| `scripts/patches.sh` | the KPM step delegates to `scripts/kpm-patch.sh` when the tree has one | That script owns the gzip + dtb repacking and verifies the result. A second copy of the payload arithmetic in the action would drift from it. |
| `scripts/build.sh` | after the KPM step, `KERNEL_IMAGE_NAME` switches to `Image.gz-dtb` when it exists | A bare `make` on this tree produces `Image`, `Image.gz` and `dtb.img`; `Image.gz-dtb` is a separate target. `KERNEL_IMAGE_NAME` has to name a file that exists right after `make`, but the combined artefact is what gets flashed. |
| `config/miatoll.env` | the profile | Source repo and branch, `vendor/xiaomi/miatoll_defconfig`, proton-clang, KPM on, SUSFS off. |

### Two settings in the profile that are about the toolchain, not the device

* `CUSTOM_CMDS:CLANG_TRIPLE=aarch64-linux-gnu-` — the Makefile refuses to build
  when `CROSS_COMPILE` ends in `android-` and the Clang target is not overridden:

  ```
  *** Clang with Android --target detected. Did you specify CLANG_TRIPLE?
  ```

* `EXTRA_CMDS:... HOSTLDFLAGS=-B/usr/bin` — proton-clang's `bin/` ships an old
  GNU `ld` and the toolchain directory is first in `PATH`, so the host link of
  `scripts/basic/fixdep` picked it up and could not read a current glibc. It
  surfaced as `defconfig generation failed`, before anything was compiled:

  ```
    HOSTCC  scripts/basic/fixdep
    .../clang/bin/ld: /usr/lib/x86_64-linux-gnu/libc.so.6: unknown type [0x13] section '.relr.dyn'
    .../clang/bin/ld: cannot find /usr/lib/x86_64-linux-gnu/libc.so.6
    collect2: error: ld returned 1 exit status
    make[2]: *** [scripts/Makefile.host:102: scripts/basic/fixdep] Error 1
    [x] defconfig generation failed
  ```

  `-B/usr/bin` points that link at the system binutils. Verified locally: with a
  failing `ld` first in `PATH`, `make ... scripts_basic` fails the same way, and
  adding `HOSTLDFLAGS=-B/usr/bin` builds `fixdep`.

## Using it

The patch applies on top of action commit `26c1b95532` (2026-10-25):

```sh
git clone https://github.com/Nihal-live/KernelSU_Action_V2 && cd KernelSU_Action_V2
git checkout 26c1b95532549d4cb57ab152f5650003d89c6efb
git apply /path/to/miatoll.patch
# Actions -> Build Kernel -> Run workflow -> Config file: config/miatoll.env
```

Committing the patch to that repository needs write access to it, which this
repository's automation does not have. Instead,
[`build-with-ksu-action.yml`](../../.github/workflows/build-with-ksu-action.yml)
clones the action at that commit, applies the patch (with `--check` first), runs
its scripts stage by stage, and keeps each stage's output:

* `.github/workflows/build-with-ksu-action.yml` — the pipeline;
* `ci/ksu-action-v2/run-stage.sh` — runs one of the action's stages and tees its
  full output, because the job log and the artefact zip are served from storage
  that not every client can reach;
* the `ci-action-log` branch — the stage logs of the last failed run, pushed
  there for the same reason.

Start it from the Actions tab, or over the API when the workflow is not on the
default branch:

```sh
gh api -X POST repos/Nihal-live/Samms_Kernel_miatoll/actions/workflows/427301527/dispatches \
  -f ref=<branch>
```

## What it does not do

* It does not patch hooks, SUSFS, or `path_umount`: this tree's own script owns
  those, and the profile sets `KSU_HOOK_MODE=none` so the action does not touch
  them.
* It does not boot-test. Neither pipeline can: KernelPatch accepting the image
  is the last thing a build can prove.
