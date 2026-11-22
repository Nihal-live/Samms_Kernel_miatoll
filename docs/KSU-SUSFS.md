# KernelSU (SukiSU-Nova) and SUSFS on this 4.14 tree

This documents the root/hiding build: **SukiSU-Nova** (the KernelSU fork formerly published as
SukiSU-Ultra, now at [`SukiSU-Nova/SukiSU-Nova`](https://github.com/SukiSU-Nova/SukiSU-Nova))
integrated at kernel level, plus **SUSFS v2.4.0** path/mount/stat hiding.

It is applied from a clean checkout by [`scripts/ksu-nova-setup.sh`](../scripts/ksu-nova-setup.sh)
on every build, so nothing here depends on a dirty working tree. The clean kernel build is
unaffected: the committed defconfig has no `CONFIG_KSU`.

- Workflow: [`.github/workflows/build-kernel-sukisu.yml`](../.github/workflows/build-kernel-sukisu.yml)
- SUSFS patch: [`patches/susfs/susfs-4.14-v2.4.0.patch`](../patches/susfs/susfs-4.14-v2.4.0.patch)

## What gets installed

| Piece | Source | Pinned to |
| --- | --- | --- |
| KernelSU | SukiSU-Nova `builtin` (source-integrated: the kernel calls `ksu_handle_*()` directly) | commit `4bec532dd447e2852aa8932afa768255350c103a` |
| SUSFS kernel side | vendored v2.4.0 port for 4.14 (`fs/susfs.c`, `include/linux/susfs*.h`, fs/mm/security hunks) | in-tree patch |
| KernelSU → kernel hooks | `fs/exec.c`, `kernel/reboot.c`, `kernel/sys.c`, `drivers/input/input.c` | this script |

The build is **source-integrated (built-in)**, not the GKI loadable-module flow.

## Why these exact versions

The original approach was: take the official 4.14 SUSFS patch and the newest SukiSU, then reconcile
the API differences with a Python rewriter. It worked but was unmaintainable — the rewriter had to
move inode flags, rewrite `fs/readdir.c`, and fix `fsnotify` signatures by hand.

The current pairing avoids that entirely:

* **SukiSU-Nova's SUSFS support expects the v2.x API.** Its supercall handlers call
  `susfs_add_sus_map()`, `susfs_set_priority_uid_filter()`, `susfs_get_enabled_features()`,
  `susfs_show_variant()` and friends. Upstream `susfs4ksu`'s `kernel-4.14` branch is frozen at
  **v1.5.5** and does not have them: the link fails with a pile of `undefined symbol: susfs_*`.
* **No upstream branch is both "4.14" and "v2.x".** The v2.x port exists for 3.10 and 4.9; the 4.14
  tree only has the old v1.5.5 patch. So the v2.4.0 sources were rebased onto *this* tree once and
  the result is committed here — every hunk applies with zero fuzz, and the diff is reviewable.
  [SukiSU-Nova/SukiSU_patch](https://github.com/SukiSU-Nova/SukiSU_patch) follows the same idea
  (`0001-SUSFS-port-v2.4.0-to-Linux-3.10.patch`).
* **The two config menus already match.** SukiSU-Nova's `kernel/Kconfig` declares exactly the
  `CONFIG_KSU_SUSFS_*` options the patch's code uses, so nothing is enabled that has no
  implementation, and nothing the code needs is left disabled.

Everything is committed rather than fetched at build time on purpose: the sources that would
otherwise be fetched are either the wrong version or have already been moved once (the SukiSU repo
went `ShirkNeko/…` → `SukiSU-Ultra/…` → `SukiSU-Nova/…`, with GitHub redirects hiding the churn).

## The traps this setup is built around

These come from the [KernelSU_Action_V2](https://github.com/Nihal-live/KernelSU_Action_V2) README
(which documents them after they bit real builds) and were all re-verified on this tree.

### 1. A wrong ref does not fail — it silently builds the default branch

Every KernelSU `setup.sh` ends its checkout with

```sh
git checkout "$1" || echo "[-] Checkout default branch"
```

so a typo, a stale branch name, or a ref that never existed (SukiSU's docs long recommended
`susfs-main`, which does not exist) leaves you on the default branch. You get a green build with
none of the feature you asked for.

`scripts/ksu-nova-setup.sh` resolves the ref with `ls-remote` first, fails with the list of real
branches if it does not exist, and re-checks `HEAD` after the fetch. `KSU_REF` is a commit SHA by
default.

### 2. An unknown Kconfig symbol is dropped from a defconfig without a warning

`CONFIG_KSU_SUSFS_SUS_MAP` exists on v2.x and not on v1.5.5; `CONFIG_KSU_SUSFS_AUTO_ADD_*` is the
other way round. A hardcoded list therefore silently compiles half the feature out — the kernel
looks patched and hides nothing.

The setup script reads the `KSU_SUSFS*` menu out of the `Kconfig` that is actually installed and
writes exactly those symbols; it refuses to continue if the menu is empty. The workflow then
asserts that **every** `CONFIG_KSU_SUSFS*=y` from the defconfig survived `olddefconfig` into
`out/.config`, because an unmet `depends on` drops the option just as quietly.

`CONFIG_KSU_SUSFS` depends on `THREAD_INFO_IN_TASK`; arm64 selects it on 4.14, and the script
writes it into the defconfig anyway so the dependency cannot silently disappear.

### 3. `faccessat`/`stat` hooks cannot be used on 4.14 with SUSFS

With `CONFIG_KSU_SUSFS=y`, SukiSU-Nova's `sucompat.c` declares

```c
int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *unused);
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
```

because the SUSFS build rewrites `filename->name` in place. On 4.14, `SYSCALL_DEFINE3(faccessat, …)`
and `vfs_statx()` only have a `const char __user *` at that point — there is no `struct filename`
to hand over. Passing the argument anyway compiles (declaration and definition are in different
translation units) and corrupts a pointer at runtime.

So **these two hooks are deliberately not patched.** `su` itself is handled by the `execve` hook,
which is present; the faccessat/stat hooks only implement the legacy in-kernel `su` path, which the
SUSFS build does not use. If you see a tree that patches them with
`const char __user **` *and* `CONFIG_KSU_SUSFS=y`, that tree is wrong.

### 4. KPM and `static_call.h` need guards above 4.14

Two conditionals in SukiSU-Nova are wrong for this kernel and are fixed by the script, with the
anchor text asserted so an upstream rewrite fails the build instead of silently skipping:

* `#include <linux/static_call.h>` — the header only exists from 5.10. Wrapped in a version guard.
* `KSU_CAN_USE_KPM` was guarded at `4.4.0`, pulling 5.10-only interfaces (`task_struct::pids`,
  `set_memory.h`) into 4.14. Raised 4.4 → 5.10. KPM is therefore off on this kernel, which is
  correct: it needs 5.10+.

### 5. `path_umount()` predates 4.14? No — 4.14 predates it

`path_umount()` arrived in 5.9. This tree does not need a backport because SukiSU-Nova ships a
`__weak int path_umount()` fallback in `kernel/kernel_compat.c` for kernels below 5.9, which
`ksu_handle_umount()` links against. If you switch to a fork without that fallback, add the
backport (the well-known `can_umount()` + `path_umount()` snippet from Linux 5.9) — otherwise
module unmounting silently does nothing and root detection starts finding mounts.

### 6. Toolchain: new Clang does not build 4.x reliably

The workflow verifies that `clang`, `ld.lld`, `llvm-ar`, `llvm-nm`, `llvm-objcopy` and
`llvm-strip` really exist after cloning the toolchain repo. AOSP-style prebuilt repositories serve
*empty* version directories with HTTP 200, so a wrong version does not 404 — it fails much later
with `clang: not found`.

`CONFIG_LLVM_POLLY` is disabled by default (`--no-polly`): Proton Clang has no Polly, and the
`-mllvm -polly*` flags would abort the build.

### 7. This tree has vendor uname spoofing that collides with the SUSFS hunk

`kernel/sys.c` here carries a Xiaomi `CONFIG_FAKE_UNAME_*` block inside `newuname()`, so the stock
SUSFS hunk does not apply. The vendored patch inserts `susfs_spoof_uname()` in the same place the
upstream patch does — right after `memcpy()` — so the vendor behaviour is unchanged and the SUSFS
spoof (set from the manager) still wins for other processes.

### 8. `FANOTIFY` callback arity

The upstream 4.14 SUSFS hunk gives `show_fdinfo()` an extra `struct file *` parameter but only
converts the inotify callback. With `CONFIG_FANOTIFY=y` that is a type mismatch. The vendored patch
converts `fanotify_fdinfo()` too, so enabling fanotify later cannot break the build.

## What CI proves — and what it does not

The workflow proves that the integration applies to a clean checkout, that the tree compiles, that
`CONFIG_KSU`, `CONFIG_KSU_SUSFS` and every `CONFIG_KSU_SUSFS_*` option requested by the defconfig
are `=y` in the generated `.config`, and that `kernel.release` still contains `SKYNET`.

It does **not** prove that the kernel boots, that the manager attaches, or that hiding works on
your ROM. Those need a device. Back up `boot`, `dtbo`, `vendor_boot`, `recovery` and `persist`,
flash one device first, and check `dmesg | grep -i susfs` after booting:

```
susfs: susfs is initialized! version: v2.4.0
```

## Flashing notes

* Anyone can flash the ZIP, but **the matching userspace matters**:
  * Use the **SukiSU-Nova** manager (package `com.sukisu.nova` in current builds). An older SukiSU
    Ultra manager reports "kernel update required".
  * SUSFS needs a `ksu_susfs` userspace module that speaks the **v2.4.0** protocol. A v1.5.x
    module reports the kernel as unsupported.
* The ROM must match the kernel's vendor blobs, as with any 4.14 vendor kernel.
* Because the kernel is flashed through AnyKernel3, the ZIP only replaces the kernel image; DTBO and
  vendor_boot are untouched (see [`anykernel3/anykernel.sh`](../anykernel3/anykernel.sh)).

## Changing any of this

| Want to… | Do |
| --- | --- |
| Track a newer SukiSU-Nova | set the `ksu_ref` input on the workflow, or edit `KSU_REF` in the script; then fix any broken anchor it reports |
| Use a different fork (KernelSU-Next, ReSukiSU, …) | they have different hook signatures and SUSFS-side patches — this script is deliberately specific to SukiSU-Nova's 4.14 API |
| Enable KPM | not possible here: it needs 5.10+ interfaces |
| Enable a SUSFS option | it is already enabled if the installed Kconfig declares it; to turn one *off*, add it to a deny-list in the script and explain why |

Shell syntax, ShellCheck and the source pin are covered by the *Validate* workflow; the
integration itself is exercised by the SukiSU build workflow.
