# Vendored SUSFS v2.4.0 kernel patch (Linux 4.14)

`susfs-4.14-v2.4.0.patch` is the SUSFS kernel side for this tree, rebased so that every hunk
applies with **zero fuzz** to a clean checkout of `miatoll` at `4.14.357-openela`
(`4afc6f0769f0f3b2b10d50d3fa02f0ba7c89a183`).

It is a *source file*, not a build artefact. Do not regenerate or "refresh" it by hand — run
`./scripts/ksu-nova-setup.sh` on a clean tree, make the change there, and re-diff, so the patch
keeps applying to the pinned tree.

## What it contains

| Path | Purpose |
| --- | --- |
| `fs/susfs.c`, `include/linux/susfs.h`, `include/linux/susfs_def.h` | the SUSFS implementation (~2.6k lines) |
| `fs/Makefile` | builds `susfs.o` |
| `fs/namei.c`, `fs/namespace.c`, `fs/readdir.c`, `fs/stat.c`, `fs/statfs.c`, `fs/super.c`, `fs/open.c`-equivalents | path/mount hiding |
| `fs/proc/{base,cmdline,fd,task_mmu}.c`, `fs/proc_namespace.c`, `fs/notify/fdinfo.c` | `/proc` views |
| `kernel/kallsyms.c`, `kernel/sys.c`, `block/ioprio.c` | symbol hiding, uname spoof, priority filter |
| `mm/memory.c`, `security/selinux/avc.c` | `SUS_MAP`, AVC log spoofing |

It carries the `CONFIG_KSU_SUSFS*` hooks only; the KernelSU side (the `Kconfig` menu, supercalls and
`/proc/susfs` plumbing) comes from SukiSU-Nova itself.

## Local changes on top of the upstream v2.4.0 port

| Change | Why |
| --- | --- |
| `kernel/sys.c`: `susfs_spoof_uname()` inserted after `memcpy()` inside `newuname()`, with the vendor `CONFIG_FAKE_UNAME_*` block kept | the stock hunk does not apply to this tree, which has Xiaomi's uname spoofing in the same function |
| `fs/notify/fdinfo.c`: `fanotify_fdinfo()` gets the extra `struct file *` parameter, matching `show_fdinfo()` | upstream converts only the inotify callback; with `CONFIG_FANOTIFY=y` that is a type mismatch |

## Provenance and licensing

SUSFS is by **simonpunk** and is published at <https://gitlab.com/simonpunk/susfs4ksu> under
**GPL-2.0**; the v2.4.0 port for older kernels is distributed through
[JackA1ltman/NonGKI_Kernel_Build_2nd](https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd)
(`Patches/Patch/susfs_patch_to_4.14.patch`, GPL-3.0 project) and
[SukiSU-Nova/SukiSU_patch](https://github.com/SukiSU-Nova/SukiSU_patch).

This file is a derivative of that work, redistributed under **GPL-2.0** as part of the GPL-2.0
kernel tree; the original copyright notices are preserved inside the patched files. The
SKYNET-specific edits above are released under the same terms. Keep this notice with the patch.
