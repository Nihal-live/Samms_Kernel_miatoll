# Changelog

All notable changes to the SKYNET kernel project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); see
[`docs/BRANCHING.md`](docs/BRANCHING.md) for tags and releases.

## [Unreleased] — `17` line

### Added

- Complete `4.14.357-openela` kernel source tree committed in this repository, **at the root**
  (72,779 files from pin `4afc6f0769f0f3b2b10d50d3fa02f0ba7c89a183`).
- `.github/workflows/flatten-source.yml`: one-shot, idempotent migration from the original
  `kernel/` subfolder to the root; re-imports the pin so the 57 dotfiles filtered by nested
  `.gitignore` rules are restored.
- `.github/workflows/build-kernel.yml`: Clang/LLD build → AnyKernel3 ZIP artifact → optional
  GitHub Release, with `kernel.release`, `.config` and toolchain provenance.
- `.github/workflows/publish-release.yml`: promote an existing build artifact into a
  checksum-verified, clearly marked UNTESTED pre-release without rebuilding the kernel.
- [`anykernel3/anykernel.sh`](anykernel3/anykernel.sh): device checks for `curtana`, `joyeuse`,
  `excalibur`, `gram` and `miatoll`; clean kernel, no ramdisk edits.
- `scripts/package-anykernel.sh` and `scripts/verify-source.sh`; `scripts/sync-source.sh` removed
  (the source is now in-tree).
- [`docs/RELEASING.md`](docs/RELEASING.md): ZIP contents, provenance and flashing checklist.
- Updated README, build/branching/upstream/license docs, CI, `.gitignore` (kernel rules plus
  SKYNET exceptions for `.github/`, `.elts/` and build outputs).

### Changed

- `CONFIG_LOCALVERSION` is now `-SKYNET` instead of the upstream pin's
  `-kinesis-omega-bpf`: `uname -r` reads `4.14.357-openela-SKYNET`. The defconfig is otherwise
  unchanged, and `CONFIG_LOCALVERSION_AUTO` stays disabled.
- Removed the two hardcoded `-kinesis-omega-bpf` strings upstream had in
  `scripts/setlocalversion` (which overrode `CONFIG_LOCALVERSION` entirely) and
  `init/version.c` (`init_uts_ns.name.release`, i.e. `uname -r`). Both now use the stock
  `CONFIG_LOCALVERSION` / `UTS_RELEASE` path. `build-kernel.yml` fails the build when
  `kernel.release` lacks `SKYNET`.
- `scripts/build.sh` auto-detects the source root (root or legacy `kernel/`) and defaults to
  `Image.gz-dtb`; `Validate` CI now lints only the SKYNET helper scripts.
- CI disables `CONFIG_LLVM_POLLY` by default (`--no-polly`): the pinned defconfig's Polly flags
  are rejected by prebuilt Clang toolchains without Polly.
- New `Build SKYNET kernel + SukiSU Nova + SUSFS` workflow
  ([`.github/workflows/build-kernel-sukisu.yml`](.github/workflows/build-kernel-sukisu.yml)):
  builds with SukiSU Nova (LSM hooks, `com.sukisu.nova` manager) at kernel level plus **SUSFS
  v2.3.0** root-hiding, wired in per-run by [`scripts/sukisu-setup.sh`](scripts/sukisu-setup.sh)
  (reproducible from a clean checkout; nothing SukiSU/SUSFS is committed). CI asserts
  `CONFIG_KSU_SUSFS=y` in the generated `.config` and `kernel.release` contains `SKYNET`; the
  integration script itself fails unless `SUSFS_414_COMPAT` is stamped and the SPOOF_UNAME hook
  is present in `kernel/sys.c`. Produces an UNTESTED AnyKernel3 ZIP artifact; not boot-validated.
- `scripts/sukisu-setup.sh` pins SukiSU-Nova (`4bec532`) and the SUSFS v2.3.0 core — wxx9248
  (the GitHub `wxx9248/susfs4ksu@kernel-4.9-v2` branch, `71345de`): fetched as an exact SHA
  with `git fetch --depth 1`, not as a floating branch — so the integration is bit-for-bit
  reproducible.
  The native 4.14 SUSFS patch now comes from a **GitHub mirror** of the upstream GitLab repo
  (`Ante0/susfs4ksu`, `kernel-4.14` tip `77905b5a`) — the same commit SHA as upstream GitLab
  (`simonpunk/susfs4ksu@kernel-4.14`, v1.5.5, Feb 23 2025), so content is identical by
  construction — pinned by SHA, no gitlab.com access required (previously the build's hard
  dependency; GitLab throttles Actions runner IPs). Set `SUSFS_PATCH_REPO` to the upstream
  GitLab URL to override; other mirrors (KairoVera, Trijal08, KateWasHere001) carry the same SHA.
  The whole SukiSU+SUSFS integration now runs end-to-end locally and in CI from GitHub alone.
- **BOOTLOOP FIX (`scripts/susfs_414_reconcile.py`, stage 10):** the v2.3.0 core's
  `susfs_spoof_cmdline_or_bootconfig()` blindly `seq_puts()` a `NULL` spoof buffer when userspace
  never programmed one, and 4.14's `fs/proc/cmdline.c` called it **unconditionally** — Android init
  reads `/proc/cmdline` during early boot, so the first read page-faulted and the kernel panicked
  before the boot animation (flash reports: no boot animation, bootloop into splash). Stage 10
  restores the v1.5.5 contract on the v2.3.0 core: both spoof hooks early-return unless their
  non-static static keys (`susfs_is_fake_cmdline_or_bootconfig_buffer_set` /
  `susfs_is_uname_spoof_buffer_set`) are enabled, and `cmdline_proc_show()` now falls through to the
  stock `saved_command_line` output when the spoof is unset. `kernel/sys.c` SPOOF_UNAME path keeps
  working (the inner gate now makes the call a no-op until userspace configures it).
- `scripts/sukisu-setup.sh` gained `KSU_NO_PREINIT=1` support: rewrites the
  SukiSU-Nova `kernel/Makefile` "preinit runner" block into its own upstream
  "disabled" branch (`-DKSU_NO_PREINIT`, runner objects dropped). This keeps
  `CONFIG_KSU_SUSFS=y` while eliminating the one early-boot code path that
  exist only in SUSFS builds at all -- PID 1's `/system/bin/init selinux_setup`
  execve is no longer swapped to an `.init.rodata` static-ELF runner, matching
  the known-booting Nova-only build's PID-1 flow. Exposed as the `ksu_no_preinit`
  workflow input (default `false`).
- `scripts/sukisu-setup.sh` gained `SUSFS_DISABLE` (space-separated symbols, e.g.
  `SUSFS_DISABLE="CONFIG_KSU_SUSFS_SUS_MOUNT"` or `"CONFIG_KSU_SUSFS"` for a Nova-only control
  build): matching defconfig symbols are written as `# CONFIG_X is not set` (Kconfig default is
  `y`), the verifier skips them, and the workflow gained a `susfs_disable` dispatch input so the
  bootloop can be bisected without script edits. Default is unchanged: a full SUSFS build.
- `.gitignore` now excludes the SukiSU/SUSFS CI-generated files (`KernelSU/`,
  `drivers/kernelsu`, `fs/susfs.c`, `include/linux/susfs*.h`, `*.rej`/`*.orig`).
- `docs/LICENSE-NOTICE.md`: with the GPL-2.0 tree in-tree, `COPYING` is the primary license for
  kernel code and GPL-3.0 `LICENSE` covers SKYNET-authored files.

### Fixed

- SUSFS `SPOOF_UNAME` was silently inert: the v1.5.5 patch hunk for `kernel/sys.c` rejects on
  this tree (its `newuname()` carries the openela/Xiaomi `FAKE_UNAME` bpfloader block between
  `memcpy` and `up_read`), but no stage re-applied it. `scripts/sukisu-setup.sh` now installs the
  same hook (`susfs_spoof_uname(&tmp)` before `up_read`) in new stage 6.5, verified by stage 8.
- CI `grep -c SUSFS_414_COMPAT` diagnostic killed an otherwise good integration step (run #4):
  `scripts/susfs_414_reconcile.py` now stamps `#define SUSFS_414_COMPAT 1` in `susfs_def.h`.
- `scripts/sukisu-setup.sh` no longer depends on `raw.githubusercontent.com` (SukiSU-Nova is
  fetched by git directly, with SHA pin + pre-existing-clone pin enforcement) and is executable.
- Stage 8 no longer deletes an unverified state: it fails if `susfs_spoof_uname` is missing from
  `kernel/sys.c` or if the patch hunks were not reconciled.

### Notes

- The `17` line stays **clean / stock-like**: no KernelSU, SUSFS or other root/hiding patches.
- No flashable ZIP is committed to the repository; none has been validated on hardware yet.

### First CI build — `skynet-17-r1` (UNTESTED, **SUPERSEDED**)

- Actions run `41580476064`, source commit `4fbcf9e82`, proton-clang `master`, `--no-polly`.
- `skynet-17-20261103-2.zip` — SHA-256
  `31ae7b45cf993dfe4c7557c6368f02341d62fd6a0310926394fc414aabc9b778`.
- Contains `Image.gz-dtb` and `Image.gz` in an AnyKernel3 framework. **No boot test yet**.
- **Superseded by `skynet-17-r2`**: this ZIP still reports
  `4.14.357-openela-kinesis-omega-bpf` in `uname -r`. Do not flash it expecting SKYNET branding.

### Current build — `skynet-17-r2` (UNTESTED)

- Actions run `41601405560`, source commit `c5024cafb`, proton-clang `master`, `--no-polly`.
- CI verified `kernel.release = 4.14.357-openela-SKYNET` and
  `CONFIG_LOCALVERSION="-SKYNET"`; the build fails if that branding is missing.
- `skynet-17-20261103-4.zip` — SHA-256
  `ecfe2c0193ff426c866df1aae0f2d0e0f9e483ec3918eba71621b36ccd5db592`.
- Contains `Image.gz-dtb` and `Image.gz` in an AnyKernel3 framework. **No boot test yet**;
  back up stock `boot`/`dtbo` and verify device, block and slot settings before flashing.
- An intermediate build (`41598972597`, `skynet-17-20261103-3.zip`) was discarded without
  release: it still carried the Kinesis name and exposed the upstream hardcodes.

## [0.1.0] — scaffold

- Initial README, device matrix, build/sync tooling, docs, CI and issue/PR templates.

[Unreleased]: https://github.com/Saamitk/kernel_xiaomi_SM6250_SKYNET/commits/main
[0.1.0]: https://github.com/Saamitk/kernel_xiaomi_SM6250_SKYNET/pull/1
