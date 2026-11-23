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
- `docs/LICENSE-NOTICE.md`: with the GPL-2.0 tree in-tree, `COPYING` is the primary license for
  kernel code and GPL-3.0 `LICENSE` covers SKYNET-authored files.

### Added — KernelSU (SukiSU-Nova) root variant

- [`scripts/ksu-nova-setup.sh`](scripts/ksu-nova-setup.sh): applies **SukiSU-Nova** (`builtin`,
  pinned commit `4bec532dd`) to a clean checkout — ref validation, `drivers/` wiring, the 4.14
  hook call sites it can prove are linkable, four 4.14 fixes to the clone and the `CONFIG_KSU*`
  defconfig symbols.
  Idempotent, and `--check` re-verifies an integrated tree without changing it.
- [`.github/workflows/build-kernel-sukisu.yml`](.github/workflows/build-kernel-sukisu.yml): builds
  the root flavour and asserts `CONFIG_KSU` / `CONFIG_KSU_FEATURE_ADBROOT` survived
  `olddefconfig` into `.config`, that KPM stayed off, and that no SUSFS symbol leaked in.
- [`docs/KSU-NOVA.md`](docs/KSU-NOVA.md): the feature matrix, the hook table, why SUSFS and KPM
  are excluded, and the traps this integration defends against (silent ref fallback, silently
  dropped Kconfig symbols, brace-shaped patch anchors, vendor SELinux backports).
- `Validate` gained a dry-run job that applies the whole integration to a clean tree, so upstream
  drift, a hook landing in the wrong function, or a non-idempotent re-run fails in a minute instead
  of after a 40-minute build.

#### First green build (UNTESTED)

- Run [`45057289070`](https://github.com/Nihal-live/Samms_Kernel_miatoll/actions/runs/45057289070),
  commit `238b5757a`, proton-clang `master`, `--no-polly`, 15m29s.
- Artifact `skynet-kernel-sukisu-nova-zip` (38.1 MB) — an AnyKernel3 ZIP plus `.sha256`.
- Passing assertions from that run: `CONFIG_KSU=y` and `CONFIG_KSU_FEATURE_ADBROOT=y` survived
  `olddefconfig` in `out/.config`, `CONFIG_KPM` stayed off, no `CONFIG_KSU_SUSFS*` symbol leaked
  in, `kernel.release` contains `SKYNET`, and every `ksu_handle_*` a hooked file calls is defined
  in the SukiSU-Nova clone.
- **Not boot-tested.** This proves the kernel compiles and links with root integrated, nothing
  more. The previous attempt died at `ld.lld: undefined symbol: ksu_handle_setresuid`, which is
  the failure the symbol gate in the setup script now rules out.

#### CPU identity spoofing on 4.14 (UNTESTED)

- The manager showed *CPU identity spoofing* as unsupported: `KSU_CAN_USE_CPU_SPOOF` is `#if`d
  at `LINUX_VERSION_CODE >= 5.10`, so neither the extension handler nor the panel existed.
- That gate is a version check, not missing code — every write goes through kallsyms. The setup
  script now lowers it to 4.14 and compiles the 4.18-only parts out of `cpu_spoof.c`:
  `asm/vdso_datapage.h` instead of `<vdso/datapage.h>`, no `elf_hwcap2` write (4.14 has a single
  `unsigned long elf_hwcap`; `[1]` would corrupt the next symbol), and no vDSO/clocksource block
  (`clock_mode`, `vdso_clock_mode`, `vdso_default` and erratum 1418040 all postdate 4.14, and
  clearing bit 37 of a shorter `cpu_hwcaps` bitmap would be an out-of-bounds write).
- MIDR (`cpu_data[]->reg_midr`), BogoMIPS (`loops_per_jiffy`, kernel `HZ=100`) and `AT_HWCAP`
  (`elf_hwcap`) do work and are what the panel changes.
- Verified locally by compiling the whole unity TU with clang for `aarch64-linux-gnu` against
  this tree's headers: 0 errors, `cpu_spoof` handler and name string present, and the
  preprocessed output contains no `vdso_time_data`, no `vdso_data_ptr` and no
  `clear_bit(ARM64_WORKAROUND_1418040`.
- Built in CI: run [`45093146525`](https://github.com/Nihal-live/Samms_Kernel_miatoll/actions/runs/45093146525)
  (commit `bb4434ac6`), 13m43s, artifact `skynet-kernel-sukisu-nova-zip` (38.1 MB). That run also
  asserts `strings vmlinux` contains the `cpu_spoof` handler name, so the extension is in the
  image and not just in the sources.
- **Not boot-tested.**

#### KPM enabled (UNTESTED)

- KPM is SukiSU-Nova's bridge plus KernelPatch's loader: `sukisu_kpm_bridge()` calls the truncate
  syscall handler with three magic words, and KernelPatch answers. `CONFIG_KPM=y` alone therefore
  did nothing before — the probe returned `-EOPNOTSUPP` and the manager kept the panel disabled.
- Three 4.14 ports were needed for the bridge and the KPM sources to compile on this tree:
  `access_ok()`'s pre-5.0 signature; `task_struct::pids[PIDTYPE_PID].pid`, which this vendor tree
  does not have because it already carries the 4.19 `thread_pid`/`pid_links` layout (the clone
  Makefile now probes `include/linux/sched.h` for it, like its other vendor-backport probes); and
  the truncate handler lookup, since `__arm64_sys_*` wrappers only exist from 4.17 — the bridge
  now falls back to `sys_call_table[__NR_truncate]`, then `sys_truncate`/`SyS_truncate`.
- New [`scripts/kpm-patch.sh`](scripts/kpm-patch.sh) does the half that is not in the kernel: it
  runs ShirkNeko's `kptools -p` (pinned SukiSU_patch commit) on the built `Image` and rebuilds
  `Image.gz-dtb` as `gzip(patched Image) + the dtb blob` — taken from the original `Image.gz-dtb`
  when make built it, from `dtb.img` otherwise — then verifies the arm64 header magic, the
  payload's own `KP1158` preset magic, that the file grew by at least the payload size, and that
  `Image.gz` decompresses to the patched `Image`.
- `kptools` is called directly rather than through the bundle's `patch_linux`, which in the pinned
  bundle hands `kptools` an *empty* embedded payload (16 bytes, `kpimg version: 0`) through a
  memfd and still reports success. That was a real failure here: the first run produced an image
  whose KPM panel could never have worked.
- The workflow runs it after the build and before packaging, and asserts `CONFIG_KPM=y` and
  `CONFIG_KALLSYMS_ALL=y` survived `olddefconfig`.
- Built in CI, twice, from the same commit: run
  [`45101070470`](https://github.com/Nihal-live/Samms_Kernel_miatoll/actions/runs/45101070470)
  (this repo's workflow, 16m38s, `skynet-kernel-sukisu-nova-zip`, 39.2 MB) and run
  [`45101073164`](https://github.com/Nihal-live/Samms_Kernel_miatoll/actions/runs/45101073164)
  (KernelSU_Action_V2's scripts, 20m51s). Both assert the payload magic in the packaged
  `Image`, `CONFIG_KPM=y` in `out/.config` and that `Image.gz` decompresses to it; the KPM log
  shows `kpimg version: e00`, `config: android,release` and `Image 43190288 -> 43486832 bytes`.
- **Not boot-tested.** KernelPatch accepts and patches this 4.14 image, which is the last thing
  a build can prove; whether the loader starts on the device is not something CI can answer.

#### SELinux hide stays unsupported (by construction, not by omission)

- **SELinux hide** (`selinux_hide`, what the settings screen calls "Hide SELinux modification")
  reimplements selinuxfs against `struct selinux_policy` and other 5.6+ SELinux internals, and
  its init call is `#if`d at 5.10. This tree has `struct selinux_state` backported but no
  `selinux_policy`, so a port is a rewrite of ~400 lines of policy internals, not a one-line gate.
- **AVC log spoofing** is `susfs_set_avc_log_spoofing()` — SUSFS only.


### Removed

- **SUSFS** from this build: `patches/susfs/` (the vendored v2.4.0 4.14 patch) and
  `docs/KSU-SUSFS.md` are gone. SUSFS needs a kernel-side port of the API SukiSU-Nova calls, and
  no upstream branch ships one for 4.14 — maintaining a private 5,400-line rebase plus a matching
  userspace module is not worth the boot risk it puts on the device.
- `scripts/sukisu-setup.sh` and `scripts/susfs_414_reconcile.py`: the older approach paired the
  v1.5.5 4.14 SUSFS patch with the v2.3.0 core and bridged the API gap with a Python rewriter.

### Notes

- The committed defconfig stays **clean / stock-like** — no `CONFIG_KSU`, no root integration.
  The SukiSU-Nova flavour is opt-in and applies its config at build time.
- KPM is kept off on purpose: its Kconfig help warns it may affect system stability and it needs
  5.10+ interfaces. KPM's guard in `kernel_compat.h` is still raised to 5.10 so the dead code
  actually compiles out.
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
