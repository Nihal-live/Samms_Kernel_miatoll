# KernelSU: SukiSU-Nova (kernel-level root)

This kernel can be built with **SukiSU-Nova** integrated at source level. It is
an **opt-in build flavour**: the committed defconfig stays stock-like, and the
integration is applied from a clean checkout by
[`scripts/ksu-nova-setup.sh`](../scripts/ksu-nova-setup.sh) at build time.

- **No SUSFS.** Root hiding is not part of this build. See
  [Why no SUSFS](#why-no-susfs).
- **KPM: on, with a post-build step.** SukiSU's KPM is only a bridge;
  [KernelPatch](https://github.com/bmax121/KernelPatch) provides the loader and
  is injected into the built image by `scripts/kpm-patch.sh`. See
  [KPM](#kpm).

## What gets installed

`scripts/ksu-nova-setup.sh` does five things, all idempotent, all from a clean
tree:

1. **Fetch SukiSU-Nova `builtin` at a pinned commit** and verify the checkout.
   `builtin` is the source-integrated branch: the kernel calls `ksu_handle_*()`
   directly instead of relying on kprobes (kprobes are unreliable on 4.x).
2. **Wire the module** — `drivers/kernelsu` symlink, `drivers/Makefile` rule and
   `drivers/Kconfig` source line. A stale `CONFIG_WITH_KERNEL_SU` guard left by
   an earlier setup script is normalised to `CONFIG_KSU`.
3. **Apply the 4.14 fixes** to the clone: guard `linux/static_call.h` (does not
   exist before 5.10), port KPM's three 5.10 assumptions (see [KPM](#kpm)),
   lower the CPU-spoof guard from 5.10 to 4.14 and compile the parts of
   `cpu_spoof.c` that assume a 4.18+ vDSO out of the build. See
   [CPU identity spoofing](#cpu-identity-spoofing).
4. **Insert the manual hook call sites** a 4.14 kernel needs — see
   [Hooks](#hooks).
5. **Inject the defconfig symbols** — `CONFIG_KSU`, `CONFIG_KSU_FEATURE_ADBROOT`,
   `CONFIG_KALLSYMS_ALL`, `CONFIG_KPM=y`, plus explicit
   `# CONFIG_KSU_SUSFS is not set` (SUSFS defaults to *on* upstream, so "not
   mentioned" is not the same as "off").

Nothing is committed pre-applied: `git status` on a fresh checkout is clean.

## Feature matrix

SukiSU-Nova's runtime features live in its unity build
(`drivers/kernelsu/ksu_main.c`) and are toggled from the manager. They are
compiled in unconditionally; only ADB root and KPM have Kconfig switches.

| Feature | In this build | Notes |
| --- | --- | --- |
| su compat (`su`, `ksud`) | yes | execve hook |
| Kernel umount | yes | via Nova's `path_umount()` shim for < 5.9 |
| sulog (root logging) | yes | runtime toggle |
| ADB root | yes | `CONFIG_KSU_FEATURE_ADBROOT=y` |
| SELinux hide | **no** | `selinux_hide` reimplements selinuxfs against `struct selinux_policy` and other 5.6+ SELinux internals; its init call is `#if`d at 5.10 and this tree has no `selinux_policy`. Porting it means rewriting 400 lines of policy internals — not attempted. |
| Shell su (adb only) | yes | runtime toggle |
| Mount hide | yes | needs `mount_list` / `mount_list_lock`, present in this tree |
| App profile / allowlist / manager tracking | yes | |
| CPU identity spoofing | yes | MIDR + BogoMIPS + ELF `hwcap`; see [CPU identity spoofing](#cpu-identity-spoofing) |
| Extensions (version spoof, dynamic manager, unmount paths) | yes | |
| **KPM** (load external kernel modules) | **yes, needs the image patch** | `CONFIG_KPM=y` compiles SukiSU's bridge; `scripts/kpm-patch.sh` injects KernelPatch into the image. See [KPM](#kpm). |
| **AVC log spoofing** | **no** | SUSFS-only (`susfs_set_avc_log_spoofing()`) |
| **SUSFS** | **no** | see below |

## KPM

KPM lets the manager load `.kpm` modules — compiled kernel code — at runtime.
It needs two halves, and only one of them is a Kconfig switch:

1. **The bridge** (SukiSU-Nova, `CONFIG_KPM=y`). `sukisu_kpm_bridge()` builds a
   fake `pt_regs` with three magic words and calls the kernel's truncate
   syscall handler. If the handler answers with `SUKISU_KPM_ABI_VERSION`, the
   bridge forwards the real op. Without KernelPatch it simply returns
   `-EOPNOTSUPP`, which is why `CONFIG_KPM=y` on its own changes nothing.
2. **The loader** (KernelPatch). `scripts/kpm-patch.sh` runs `kptools -p` from
   ShirkNeko's [SukiSU_patch](https://github.com/ShirkNeko/SukiSU_patch) on the
   built `Image` and rebuilds `Image.gz-dtb` around the patched result.

`kptools` is called directly rather than through the bundle's `patch_linux`
wrapper. The wrapper decrypts an embedded `kpimg` into a memfd and passes
`-k /proc/self/fd/N` to `kptools`; in the pinned bundle that file comes out
16 bytes long, and the image is written with an empty payload while the wrapper
still reports success:

```
[+] layout kimg: 0x0,0x2930810, kpimg: 0x2931000,0x10, ...    <- 16-byte payload
[+] kpimg version: 0
[+] kpimg compile time:
```

Calling `kptools` with the `kpimg` that ships next to it does the same patch
(same arguments, including the wrapper's superkey) with a payload that can be
inspected first: `kptools -k kpimg -l` reports `version=0xe00`,
`config=android,release`, `arch=arm64`. The script then verifies the result
instead of trusting the exit status: the payload's own preset magic (`KP1158`)
must be present in the output, the file must grow by at least the payload size,
and `Image.gz` must decompress to the patched `Image`.

### The 4.14 ports

With upstream's `KSU_CAN_USE_KPM` guard (>= 4.4) the KPM sources compile on
4.14, but three of them assume newer kernels:

| Assumption | 4.14 reality | What the script does |
| --- | --- | --- |
| `access_ok(addr, size)` | takes the access type first until 5.0 | `VERIFY_WRITE` form below 5.0 |
| `task_struct::pids[PIDTYPE_PID].pid` | this vendor tree already carries the 4.19 `thread_pid` layout | the Makefile probes `include/linux/sched.h` and defines `KSU_TASK_HAS_THREAD_PID`, like its other vendor-backport probes |
| `__arm64_sys_truncate` | `__arm64_sys_*` wrappers only exist from 4.17 | falls back to `sys_call_table[__NR_truncate]`, then `sys_truncate` / `SyS_truncate` |

The syscall-table lookup is deliberate: it reaches KernelPatch whether it hooks
the table entry or the function body.

### What can still go wrong

- **KernelPatch has to accept the image.** It is a binary patcher, so it parses
  the kernel's `_stext`/kallsyms rather than source. kpimg reports
  `3.18 - 6.6 (theoretically)`; this 4.14 image is at the old end of that claim
  and is the one part of this integration that cannot be verified without
  booting. `scripts/kpm-patch.sh` refuses to continue if `kptools` fails, if the
  result no longer looks like an arm64 Image, if the payload magic is missing,
  or if the file did not grow by the payload size, so a bad patch fails the
  build instead of producing a zip.
- **`.kpm` modules must be built for 4.14 arm64.** A module built against a 5.x
  kernel will not load, and a broken module is the one thing that can panic the
  device. Flash with a boot backup.
- **KPM widens the attack surface by design**: it executes third-party code in
  kernel context. That is the feature, not a bug, but it is why it is the only
  thing in this build that its own Kconfig calls "may affect system stability".

## CPU identity spoofing

The manager's *CPU identity spoofing* panel rewrites what `/proc/cpuinfo` and
the ELF loader report for a CPU: MIDR, BogoMIPS, `AT_HWCAP`, and the vDSO clock
mode. Upstream compiles it out below 5.10, so the manager shows it as
unsupported and the panel cannot be opened at all.

The gate is a version check, not missing code. Every write it performs is
resolved through kallsyms, so the only version-dependent part is *which fields
exist*. `scripts/ksu-nova-setup.sh` therefore:

- lowers `KSU_CAN_USE_CPU_SPOOF` from 5.10 to 4.14, which registers the
  extension handler and makes the panel available;
- includes `asm/vdso_datapage.h` instead of the 4.18+ `<vdso/datapage.h>`;
- skips the `elf_hwcap_bitmap[1]` write below 4.20 — 4.14's `elf_hwcap` is a
  single `unsigned long` with no `elf_hwcap2` beside it, so writing the second
  word would corrupt whatever follows;
- skips the whole vDSO/clocksource block below 4.18: 4.14's datapage has no
  `clock_mode`, `struct clocksource` has no `vdso_clock_mode`, there is no
  `vdso_default`, and the Cortex-A76 erratum 1418040 the upstream code clears
  does not exist yet. Clearing bit 37 of a shorter `cpu_hwcaps` bitmap would be
  an out-of-bounds write, so doing nothing is both correct and safer.

What still happens on 4.14 is the part with visible effect: `cpu_data[]->reg_midr`
(what `/proc/cpuinfo` prints), `loops_per_jiffy` (BogoMIPS, calibrated for this
kernel's `HZ=100`), and `elf_hwcap` (`AT_HWCAP` for new processes). "vDSO clock
mode" is a 4.18+ concept — on 4.14 there is no mode to spoof, and the arch-timer
fast path is already what this device reports.

If a symbol is missing the call returns `-ENXIO` instead of pretending to
succeed, so a partial spoof is visible rather than silent.

## Why no SUSFS

SUSFS is a kernel-side root-hiding layer, and there is no upstream branch that
ships it for 4.14 *with the API SukiSU-Nova calls*:

- `simonpunk/susfs4ksu` `kernel-4.14` is frozen at **v1.5.5**.
- SukiSU-Nova calls the **v2.x** API (`susfs_add_sus_map()`,
  `susfs_set_priority_uid_filter()`, `susfs_get_enabled_features()`,
  `susfs_show_variant()`), so linking against v1.5.5 fails with undefined
  symbols.
- No branch is both 4.14 and v2.x.

Making it work means maintaining a private rebase of a ~5,400-line patch
against every upstream move, plus a second userspace component that must speak
the same protocol version. A half-ported hiding layer is exactly the class of
change that turns a working root into an unstable device, which is why this
build leaves it out. If you want hiding later, the honest options are: follow a
tree that ports SUSFS to 4.14 upstream, or accept the maintenance of the
vendored patch.

## Hooks

| File | Function | Call |
| --- | --- | --- |
| `fs/exec.c` | `do_execveat_common()` | `ksu_handle_execveat()` |
| `kernel/reboot.c` | `SYSCALL_DEFINE4(reboot)` | `ksu_handle_sys_reboot()` |
| `drivers/input/input.c` | `input_handle_event()` | `ksu_handle_input_handle_event()` |
| `fs/open.c` | `SYSCALL_DEFINE3(faccessat)` | `ksu_handle_faccessat()` |
| `fs/stat.c` | `vfs_statx()` | `ksu_handle_stat()` |

Five sites, not six: `ksu_handle_setresuid()` exists **only in the SUSFS
build** (it drives SUSFS's zygote handling), so the setup script detects that
and skips the hook instead of calling a symbol that will not link. The script
checks every symbol a hooked file calls against the clone before writing the
call, which is what turns that class of mistake into a one-second failure
instead of a 15-minute build that ends in `undefined symbol`.

The last two are what make an app's `access()`/`stat()` of `/system/bin/su`
resolve to the su wrapper, so `which su` and Termux-style probing work. Their
signatures only line up because `CONFIG_KSU_SUSFS` is **off**: with SUSFS
enabled the same handlers take a `struct filename **`, which 4.14's
`const char __user *` is not — passing it compiles (separate translation units)
and corrupts a pointer at runtime. That is one more reason the defconfig pins
`# CONFIG_KSU_SUSFS is not set`.

Deliberately **not** hooked: `vfs_read` (`ksu_handle_vfs_read`), which only
serves the legacy syscall-su path this ref does not use.

## Traps this integration defends against

1. **Silent ref fallback.** Every KernelSU `setup.sh` ends its checkout with
   `git checkout "$1" || echo "checkout default branch"`. A typo or stale
   branch name therefore *succeeds* and leaves you on the default branch. The
   script resolves the ref first and compares `HEAD` afterwards.
2. **Silently dropped Kconfig symbols.** An option whose dependency is unmet is
   removed by `olddefconfig` without a word. CI asserts every requested
   `CONFIG_KSU*` is `=y` in the generated `out/.config`.
3. **Brace-shaped patch anchors.** `setresuid()` and `setregid()` open with the
   same three lines; an anchor of just `{\n\tstruct user_namespace *ns = ...`
   drops the hook into `setregid()`, where `ruid`/`euid`/`suid` do not exist.
   The script anchors on the full signature, requires exactly one match, and
   re-checks the call's offset afterwards.
4. **Wrong `kernel_read()` signature.** It changed in 4.14. Not an issue here
   because no SUSFS code is compiled.
5. **KPM on a 4.14 tree.** Its `KSU_CAN_USE_KPM` guard says 4.4, which drags in
   5.10 interfaces (`task_struct::pids`, `set_memory.h`). The script raises the
   guard; that section now ports those interfaces instead of hiding them.
6. **`path_umount()` before 5.9.** Nova ships a `__weak` shim
   (`kernel/kernel_compat.c`) built on `d_path()` + `sys_umount()`; it links and
   works for the kernel-umount feature. It is a shim, not the 5.9 implementation.
7. **Vendor SELinux backports.** This tree has `struct selinux_state` on a 4.14
   version number. Nova's Makefile detects it by grepping the header
   (`KSU_COMPAT_HAS_SELINUX_STATE`) rather than trusting
   `LINUX_VERSION_CODE`; without that, `selinux_enforcing`/`avc_ss_reset()`
   fail to compile.

## What CI proves, and what it does not

The workflow
[`build-kernel-sukisu.yml`](../.github/workflows/build-kernel-sukisu.yml):

- applies the integration to a clean checkout,
- builds the kernel with the pinned Clang/LLD,
- asserts `CONFIG_KSU` (and `CONFIG_KSU_FEATURE_ADBROOT`) are `=y` in
  `out/.config` after `olddefconfig`,
- asserts `kernel.release` still contains `SKYNET`,
- packages an AnyKernel3 ZIP.

It proves the kernel **compiles and links with root integrated**. It does not
prove the kernel boots, that `su` works on your firmware, or that the manager
detects the kernel version correctly. That needs a device.

A dry-run job in [`validate.yml`](../.github/workflows/validate.yml) applies the
integration without building, so upstream drift fails in about a minute instead
of after a 40-minute build.

## Flashing and the manager

1. Use the **SukiSU-Nova** manager (`com.sukisu.nova`). An older SukiSU Ultra
   manager will report "kernel update required".
2. Back up `boot`, `dtbo`, `vendor_boot`, `recovery` and `persist` first, and
   check the device codename and slot layout
   ([`DEVICES.md`](DEVICES.md)).
3. The ZIP is AnyKernel3 — it patches the installed boot image, it does not
   replace partitions.

## Building it locally

```sh
./scripts/ksu-nova-setup.sh                 # apply + verify
./scripts/ksu-nova-setup.sh --check         # verify only, change nothing
./scripts/build.sh --clang-dir <clang>/bin  # defconfig + build
grep -x 'CONFIG_KSU=y' out/.config          # must be =y, not dropped
```

Requirements are the same as the clean build
([`BUILDING.md`](BUILDING.md)); the only extra dependency is network access for
the SukiSU-Nova fetch (or a pre-populated `KernelSU/` clone, honoured by
`--check`).
