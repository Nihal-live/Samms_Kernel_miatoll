# KernelSU: SukiSU-Nova (kernel-level root)

This kernel can be built with **SukiSU-Nova** integrated at source level. It is
an **opt-in build flavour**: the committed defconfig stays stock-like, and the
integration is applied from a clean checkout by
[`scripts/ksu-nova-setup.sh`](../scripts/ksu-nova-setup.sh) at build time.

- **No SUSFS.** Root hiding is not part of this build. See
  [Why no SUSFS](#why-no-susfs).
- **No KPM.** Kernel module (LKM) loading is off. See [Feature matrix](#feature-matrix).

## What gets installed

`scripts/ksu-nova-setup.sh` does five things, all idempotent, all from a clean
tree:

1. **Fetch SukiSU-Nova `builtin` at a pinned commit** and verify the checkout.
   `builtin` is the source-integrated branch: the kernel calls `ksu_handle_*()`
   directly instead of relying on kprobes (kprobes are unreliable on 4.x).
2. **Wire the module** — `drivers/kernelsu` symlink, `drivers/Makefile` rule and
   `drivers/Kconfig` source line. A stale `CONFIG_WITH_KERNEL_SU` guard left by
   an earlier setup script is normalised to `CONFIG_KSU`.
3. **Apply two 4.14 fixes** to the clone: guard `linux/static_call.h` (does not
   exist before 5.10) and raise the KPM guard from 4.4 to 5.10 so KPM's dead
   code is actually dead.
4. **Insert the six manual hook call sites** a 4.14 kernel needs — see
   [Hooks](#hooks).
5. **Inject the defconfig symbols** — `CONFIG_KSU`, `CONFIG_KSU_FEATURE_ADBROOT`,
   `CONFIG_KALLSYMS_ALL`, plus explicit `# CONFIG_KPM is not set` and
   `# CONFIG_KSU_SUSFS is not set`. Both of the latter default to *on* upstream,
   so "not mentioned" is not the same as "off".

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
| SELinux hide | yes | `CONFIG_KSU_SUSFS`-free path |
| Shell su (adb only) | yes | runtime toggle |
| Mount hide | yes | needs `mount_list` / `mount_list_lock`, present in this tree |
| App profile / allowlist / manager tracking | yes | |
| Extensions (CPU spoof, version spoof, dynamic manager) | yes | |
| **KPM** (load external kernel modules) | **no** | its own Kconfig help says it "may affect system stability"; needs 5.10+ interfaces |
| **SUSFS** | **no** | see below |

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
| `kernel/sys.c` | `SYSCALL_DEFINE3(setresuid)` | `ksu_handle_setresuid()` |
| `drivers/input/input.c` | `input_handle_event()` | `ksu_handle_input_handle_event()` |
| `fs/open.c` | `SYSCALL_DEFINE3(faccessat)` | `ksu_handle_faccessat()` |
| `fs/stat.c` | `vfs_statx()` | `ksu_handle_stat()` |

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
   guard and the defconfig keeps KPM off.
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
