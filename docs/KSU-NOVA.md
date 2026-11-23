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
   lower the CPU-spoof guard from 5.10 to 4.14, compile the parts of
   `cpu_spoof.c` that assume a 4.18+ vDSO out of the build, and swap the
   >= 5.10-only `selinux_hide.c` for the 4.14 edition described in
   [SELinux hiding and AVC log spoofing](#selinux-hiding-and-avc-log-spoofing).
   See also [CPU identity spoofing](#cpu-identity-spoofing).
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
| Hide SELinux modification | yes, 4.14 edition | upstream's `selinux_hide.c` needs `struct selinux_policy` (5.6+); this build snapshots the pristine policy instead and serves it back. See [SELinux hiding and AVC log spoofing](#selinux-hiding-and-avc-log-spoofing). |
| Shell su (adb only) | yes | runtime toggle |
| Mount hide | yes | needs `mount_list` / `mount_list_lock`, present in this tree |
| App profile / allowlist / manager tracking | yes | |
| CPU identity spoofing | yes | MIDR + BogoMIPS + ELF `hwcap`; see [CPU identity spoofing](#cpu-identity-spoofing) |
| Extensions (version spoof, dynamic manager, unmount paths) | yes | |
| **KPM** (load external kernel modules) | **yes, needs the image patch** | `CONFIG_KPM=y` compiles SukiSU's bridge; `scripts/kpm-patch.sh` injects KernelPatch into the image. See [KPM](#kpm). |
| **AVC log spoofing** | **yes, native** | the same `avc_dump_query()` rewrite SUSFS performs, driven over the SUSFS `reboot()` supercall — no SUSFS code in the build |
| **SUSFS** | **opt-in, separate build** | `KSU_SUSFS=1` adds the device-verified 4.14 port of SUSFS v2.3.0. Not in the default image: it hooks the filesystem core. See [SUSFS](#susfs-opt-in-separate-build). |

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

### The two symbols KernelPatch looks for

The bridge above is only half of KPM; the KernelPatch payload in the image
installs the other half, and it refuses to do so on this kernel:

```c
int sukisu_kpm_supercall_install(void)
{
    if (!has_syscall_wrapper) return -EOPNOTSUPP;          /* 4.14 stops here */
    addr = kallsyms_lookup_name("__arm64_sys_truncate");   /* 4.17+ name */
    ...
    hook_wrap1((void *)addr, before_supercall, 0, 0);
}
```

`has_syscall_wrapper` is set by looking for `__arm64_sys_openat`. Both that and
`__arm64_sys_truncate` arrived with the `SYSCALL_DEFINE` wrapper generation in
4.17, so the payload logs

```
KP syscall has_wrapper: 0
KP sukisu_kpm_supercall_install done: -95
```

and the manager greys KPM out — which is exactly what the first build did on the
device, with everything else working.

`arch/arm64/kernel/kp_syswrap.c` (built only with `CONFIG_KPM`) now defines those
two names. Nothing in the kernel calls them: `sys_call_table` still points at
`sys_truncate`/`sys_openat`, and the only caller of `__arm64_sys_truncate` is the
KPM bridge, which the payload intercepts before the first instruction runs. If
the hook is not installed, the stub answers `-ENOSYS` and the bridge reports
"unavailable" — the same state as without the shim, so the failure mode is a
greyed-out panel, not a wrong answer and not a crash. The stubs start with
relocatable nops (an inline hook rewrites the first instructions of its target)
and their addresses are kept in a `__used` array so LTO cannot drop them; the
build asserts both names are in `out/System.map`.

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

## SELinux hiding and AVC log spoofing

Both toggles read *"Kernel does not support this feature"* in the manager on a
stock 4.14 + SukiSU-Nova build, for two unrelated reasons:

- **Hide SELinux modification** is a >= 5.10 feature upstream.
  `kernel/ksu_main.c` wraps both `#include "feature/selinux_hide.c"` and
  `ksu_selinux_hide_init()` in
  `#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)`, so on 4.14 the
  `KSU_FEATURE_SELINUX_HIDE` handler is never registered and the manager is
  told the feature does not exist. The file itself is built around
  `struct selinux_policy` (5.6+) and duplicates the policydb.
- **AVC log spoofing** exists only behind `CONFIG_KSU_SUSFS`: the
  `CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING` case sits in the
  `#ifdef CONFIG_KSU_SUSFS` block of `kernel/supercall/dispatch.c`, and nothing
  answers it with SUSFS off. `grep -r avc_log` in the clone finds that single
  place and nothing else.

### What this build does instead

Both are re-implemented in the kernel tree — no SUSFS, no 5.10 requirement:

| Piece | Where | Role |
| --- | --- | --- |
| `ksu_hide_compat.c` | `security/selinux/` | both features, built with `CONFIG_KSU` |
| `ksu_hide_compat.h` | `include/linux/` | prototypes for the four call sites |
| `selinux_hide_414.c` | SukiSU-Nova `kernel/feature/` | registers `KSU_FEATURE_SELINUX_HIDE` |

**Hide SELinux modification.** At the init second stage — the one moment where
the stock policy is loaded and `apply_kernelsu_rules()` has not run yet — the
policy is read once (`security_read_policy()`) and kept. While the feature is
on:

- `security_read_policy()` hands out the snapshot instead of the live policy,
  so `/sys/fs/selinux/policy` — and its inode size, through
  `security_policydb_len()` — is the stock one;
- the `policyload` counter in `/sys/fs/selinux/status`, in the netlink
  notification and in `security_load_policy()` is masked to the pristine value,
  so KernelSU's reload is invisible.

Enabling is instant: the snapshot exists from every boot, so nothing waits for
a reboot. If the second-stage hook did not run (feature forced before it), the
manager gets `-EAGAIN` and the message says to save and reboot, exactly as
upstream words it.

This is a deliberate subset of upstream: it hides the two things a detector
reads back — the policy dump and the load counter — not the per-object
`sidtab` queries upstream also redirects (`getfilecon()` on a path KernelSU
touched still answers from the live policy). A full port would mean duplicating
the policydb *and* the sidtab on 4.14, which upstream's code does not do either.

**AVC log spoofing.** `avc_dump_query()` formats every denial. When the
*target* of a denial is KernelSU's own domain (`u:r:ksu:s0` in this tree), the
context is replaced with `u:r:priv_app:s0:c512,c768` — the same rewrite
susfs4ksu's hook performs — so an `avc: denied` line in `dmesg`/`logcat` does
not point at root. The SID is resolved on the first `ENABLE_AVC_LOG_SPOOFING`
command, never at boot.

The manager drives that toggle over the SUSFS `reboot()` supercall, so
`kernel/reboot.c` answers the four commands it needs — `SHOW_VERSION`
(`v2.4.0`), `SHOW_VARIANT` (`NON-GKI`), `SHOW_ENABLED_FEATURES`
(`CONFIG_KSU_SUSFS_AVC_LOG_SPOOFING`) and `ENABLE_AVC_LOG_SPOOFING` — on
`reboot(0xDEADBEEF, 0xFAFAFAFA, cmd, &info)` from uid 0. Without them the
manager cannot know the kernel has anything to offer and greys the row out. The
version and variant strings are the values the manager parses; they are not a
claim that SUSFS is present, and every other SUSFS command is unanswered.

### What the device should log

- init second stage: `selinux_hide: pristine policy captured` plus
  `ksu: selinux_hide: pristine policy captured, NNNNN bytes, policyload 1`
- toggling hide: `ksu: selinux_hide: enabled`
- first AVC toggle: `ksu: avc spoof: masking denials targeting sid NNN`

## SUSFS (opt-in, separate build)

Root hiding is a **second product**, built from the same tree behind a switch:

```sh
KSU_SUSFS=1 ./scripts/ksu-nova-setup.sh      # root + SUSFS
./scripts/build.sh --clang-dir <clang>/bin
```

In CI that is the `susfs` input (`susfs: true`), and the ZIP, the artifact and
the release notes get a `-susfs` suffix. The default build is unchanged.

### Why it is a separate image

SUSFS hooks the filesystem core — `fs/namei.c`, `fs/namespace.c`, `fs/stat.c`,
`fs/super.c`, `fs/readdir.c`, `mm/memory.c` — so a port can compile, link, and
still bootloop. Behind a switch, a broken hiding layer costs one build instead
of the kernel you already trust.

### Which SUSFS, and why

The pinned SukiSU-Nova speaks the **v2.x** supercall ABI, which rules out most
of what is published for 4.14:

| Candidate | Version | 4.14 | Fits Nova's API | Verdict |
| --- | --- | --- | --- | --- |
| `simonpunk/susfs4ksu`, branch `kernel-4.14` (GitLab) | v1.5.5 — frozen ("master stays at 1.3.8 forever") | yes | **no**: no `susfs_add_sus_map()`, `susfs_show_variant()`, `susfs_get_enabled_features()` | rejected: undefined symbols at link |
| `xiaofan6ya/agate-bakasu-susfs`, `feature/susfs-2.3.4.14-port` | **v2.3.0** | **yes — 4.14.336, device-verified** (boots, root works, manager reports v2.3.0) | yes | **used** |
| `wxx9248/susfs4ksu` | v2.3.0 | 4.9 only | yes | rejected: wrong line, no 4.14 verification |
| `ShirkNeko/SukiSU_patch`, `3.10/…v2.4.0` | v2.4.0 | 3.10 only | yes | rejected: wrong line; the one 4.14 file in that bundle is the KernelSU hook glue, not SUSFS |
| a device kernel pairing SukiSU-Nova v3.0.0 with a **v2.4.0** non-GKI 4.14 port (XDA, SM-A226B, 4.14.186, Nov 2026) | v2.4.0 | yes — one device | yes | rejected: it ships as one device's kernel, not as a portable patch stack; nothing to apply, and nothing to verify against 4.14.357 |
| `Bias8145/KsuNext-susfs-msm4.14` | v1.5.3 | yes | no | rejected: v1.x ABI |
| `zzh20188/GKI_KernelSU_SUSFS` releases | v2.2–v2.3 | GKI only | yes | rejected: GKI tree |

The chosen port is the only candidate that is **both** v2.x **and** published
as a patch stack that is verified booting on non-GKI 4.14 hardware, and its
integration patch was generated against 4.14.357 — the exact base of this
tree. Its sources apply here without a single rejected hunk, which is as
close to a compatibility proof as you get before flashing.

### The known bootloop, and why this build does not carry it

Upstream's own documentation has one open, device-class warning:

> **Known Issues** — `mnt_id_reorder` feature causes bootloop for non-gki
> devices, more test is needed.
> — `gitlab.com/simonpunk/susfs4ksu`, README

That is the failure this build is arranged to avoid. `mnt_id_reorder` was a
v1.x feature: it rewrote `mnt_id`s across the mount tree at boot, which is
exactly the sort of global surgery that hangs a device whose init depends on
those ids. v2.x dropped it; the v2.3.0 sources here carry no `reorder` code at
all and spoof the mount id *per entry* instead (`spoofed_mnt_id`, filled by
`susfs_get_non_sus_mnt_id_from_mnt()`), which is a read-time substitution, not
a rewrite. The kernel-side integration adds no boot-time renumbering either:
the only change next to boot-critical code is the `fs/super.c` minor-number
branch, and it keeps 4.14's own allocator.

Feature creep is the other bootloop source, and that is why `SUS_MAP` and
`OPEN_REDIRECT` stay off rather than being wired to half a port.

### What is enabled

`SUS_PATH`, `SUS_MOUNT`, `SUS_KSTAT`, `SPOOF_UNAME`, `ENABLE_LOG`,
`HIDE_KSU_SUSFS_SYMBOLS`, `SPOOF_CMDLINE_OR_BOOTCONFIG`.

Deliberately **off**, because there is no implementation behind them in this
port:

- `SUS_MAP` and `OPEN_REDIRECT` ride on the `/proc/pid/maps` rewrite, which
  needs `seq_put_hex_ll()` and `num_to_str(…, width)` (4.20+). Bringing those
  in breaks `fs/proc/meminfo.c` and `drivers/of/unittest.c` on 4.14.
- `PRIORITY_UID_FILTER` is a v2.4-only command. Enabling the symbol would make
  the manager send a command that has no handler — exactly the "shows as
  supported, does nothing" failure this tree avoids elsewhere.

### What had to change to fit

| Piece | Why |
| --- | --- |
| `fs/super.c` hunk rewritten | upstream's version replaces 4.14's `ida_pre_get()`/`ida_get_new_above()` with the 4.19 `ida_alloc_range()` API. This tree keeps the allocator it boots with and only adds the KernelSU minor-number branch, under `unnamed_dev_lock`, gated on `CONFIG_KSU_SUSFS_SUS_MOUNT` and the KSU domain. |
| `lib/idr.c` hunk dropped | same API problem; nothing else needs it. |
| `fs/proc/task_mmu.c`, `task_nommu.c`, `seq_file.c`, `lib/vsprintf.c`, `include/linux/{pkeys,seq_file,kernel}.h` dropped | the `/proc/pid/maps` rewrite above; it also carried non-SUSFS changes. |
| `security/selinux/hooks.c`, `kernel/sys.c` dropped | KernelSU-Next glue, not SUSFS. The one sys.c hunk worth having — spoofed `uname` — is re-applied here, anchor-checked, inside `newuname()`. |
| `arch/arm64/configs/vayu_defconfig` dropped | another device's config. |
| `fs/susfs_compat.c` added | SukiSU-Nova calls four v2.4 entry points v2.3.0 lacks (`susfs_add_sus_type`, `susfs_add_sus_avd_allowed_by_type`, `susfs_set_current_proc_no_su`, `susfs_set_current_proc_umounted_for_zygote_next`). They are no-ops here and each says what is lost; it also implements `susfs_ends_with()` (v2.3.0 ships only the mirror) and owns `susfs_is_avc_log_spoofing_enabled`. |

With SUSFS in the build the AVC toggle belongs to SUSFS:
`avc_dump_query()` still performs the rewrite through `ksu_avc_log_spoof_matches()`,
but the flag is `susfs_set_avc_log_spoofing()`'s, the SID is resolved once at
the init second stage, and `reboot()` no longer answers the supercall — the
SUSFS dispatch does.

### What CI proves, and what it does not

`validate.yml` applies the two-patch stack on a clean checkout and asserts that
no hunk was rejected, every shim exists, the 4.14 IDA API is intact, `SUS_MAP`
and `PRIORITY_UID_FILTER` stayed off, `susfs_spoof_uname()` is inside
`newuname()`, and the setresuid hook is in `setresuid()`. The build workflow
then proves it **compiles and links**.

That is all it proves. **SUSFS has not been boot-tested on miatoll** by this
tree: the port's evidence comes from a different 4.14.336 device, and the
community reports that do exist are for that class of device (an SM-A226B on
4.14.186 with a v2.4.0 port, an agate on 4.14.336 with v2.3.0), not for
miatoll. Flash it with a known-good boot image at hand, and expect the default
(root-only) image to stay the safe choice until someone reports a boot.

### What the manager should show

SUSFS reports itself over the same `reboot()` supercall the manager already
uses: `SHOW_VERSION` → `v2.3.0`, `SHOW_VARIANT` → `NON-GKI`,
`SHOW_ENABLED_FEATURES` → the seven symbols above. The hiding panels then
enable, and `grep susfs /proc/kallsyms` stays empty because
`HIDE_KSU_SUSFS_SYMBOLS` is on.

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

The dry run additionally asserts that the SELinux work is in place:
`ksu_hide_compat.c` is in the SELinux Makefile, `avc_dump_query()` calls
`ksu_avc_log_spoof_matches()`, `security_read_policy()` and
`security_policydb_len()` consult the snapshot, `reboot()` calls
`ksu_avc_spoof_reboot()`, and the clone includes
`feature/selinux_hide_414.c` instead of skipping the feature.

It proves the kernel **compiles and links with root integrated**. It does not
prove the kernel boots, that `su` works on your firmware, or that the manager
detects the kernel version correctly. That needs a device — and it is true
twice over for the `susfs` flavour, whose patch stack CI can only verify as
text (see [SUSFS](#susfs-opt-in-separate-build)).

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
./scripts/ksu-nova-setup.sh                 # apply + verify (root only)
KSU_SUSFS=1 ./scripts/ksu-nova-setup.sh     # same, plus SUSFS v2.3.0
./scripts/ksu-nova-setup.sh --check         # verify only, change nothing
./scripts/build.sh --clang-dir <clang>/bin  # defconfig + build
grep -x 'CONFIG_KSU=y' out/.config          # must be =y, not dropped
```

Requirements are the same as the clean build
([`BUILDING.md`](BUILDING.md)); the only extra dependency is network access for
the SukiSU-Nova fetch (or a pre-populated `KernelSU/` clone, honoured by
`--check`).
