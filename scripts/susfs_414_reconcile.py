#!/usr/bin/env python3
"""
susfs_414_reconcile.py -- make the v1.5.5 4.14 hook patch work with the
v2.3.0 SUSFS core on a 4.14.357 tree.

WHY THIS EXISTS
---------------
No single SUSFS branch has both halves we need:
  * kernel-4.14 (upstream) is frozen at v1.5.5 -- its API does not match what
    SukiSU Nova calls (11 of 15 symbols missing).
  * kernel-4.9-v2 (wxx9248) is v2.3.0 -- the API SukiSU Nova expects, but its
    patch is written for 4.9 and rejects 41 times on 4.14.

So we take the v2.3.0 CORE (fs/susfs.c + headers) and the native 4.14 PATCH
(the fs/ hook hunks), then bridge the API gap here.

WHAT IT FIXES
-------------
 1. v1.5.5-named functions the 4.14 patch calls -> compat wrappers on v2.3.0
 2. fs/readdir.c: v1.5.5 ino-hash lookup -> v2.3.0 ilookup()+inode-flag
 3. i_state bit tests -> i_mapping->flags bit tests (v2.3.0 scheme)
 4. current->susfs_task_state & TASK_STRUCT_* -> susfs_is_current_proc_umounted_app()
 5. DEFAULT_SUS_MNT_* -> DEFAULT_KSU_MNT_* (+ define the one that is missing)
 6. fsnotify handle_event / fsnotify_add_mark -> 4.14 signatures
 7. missing declarations / includes
 8. stamps susfs_def.h with SUSFS_414_COMPAT so CI can prove the reconcile ran

Run from the kernel tree root, AFTER the 4.14 patch and the v2.3.0 core are in
place. Idempotent.
"""
import re
import subprocess
import sys

def read(p):
    with open(p) as f:
        return f.read()

def write(p, s):
    with open(p, "w") as f:
        f.write(s)

def sub1(path, old, new, label):
    s = read(path)
    if new in s:
        print("  [skip] %s (already applied)" % label)
        return False
    if old not in s:
        print("  [WARN] %s: anchor not found" % label)
        return False
    write(path, s.replace(old, new, 1))
    print("  [ok]   %s" % label)
    return True

# =========================================================== 1. compat layer
COMPAT = r'''

/* =====================================================================
 * 4.14 compat layer.
 *
 * The 4.14 hook patch is v1.5.5-era and calls function names that v2.3.0
 * renamed or removed. These wrappers implement the old names on top of
 * v2.3.0's data structures so the patch's call sites link.
 * ===================================================================== */

#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
/* v1.5.5: void susfs_sus_ino_for_generic_fillattr(unsigned long ino, struct kstat *stat) */
void susfs_sus_ino_for_generic_fillattr(unsigned long ino, struct kstat *stat)
{
	struct st_susfs_sus_kstat_hlist *entry = NULL;

	rcu_read_lock();
	hash_for_each_possible_rcu(SUS_KSTAT_HLIST, entry, node, ino) {
		if (entry->target_ino != ino)
			continue;
		if (entry->info.flags & KSTAT_SPOOF_INO)
			stat->ino = entry->info.spoofed_ino;
		if (entry->info.flags & KSTAT_SPOOF_DEV)
			stat->dev = entry->info.spoofed_dev;
		if (entry->info.flags & KSTAT_SPOOF_NLINK)
			stat->nlink = entry->info.spoofed_nlink;
		if (entry->info.flags & KSTAT_SPOOF_SIZE)
			stat->size = entry->info.spoofed_size;
		if (entry->info.flags & KSTAT_SPOOF_ATIME_TV_SEC)
			stat->atime.tv_sec = entry->info.spoofed_atime_tv_sec;
		if (entry->info.flags & KSTAT_SPOOF_ATIME_TV_NSEC)
			stat->atime.tv_nsec = entry->info.spoofed_atime_tv_nsec;
		if (entry->info.flags & KSTAT_SPOOF_MTIME_TV_SEC)
			stat->mtime.tv_sec = entry->info.spoofed_mtime_tv_sec;
		if (entry->info.flags & KSTAT_SPOOF_MTIME_TV_NSEC)
			stat->mtime.tv_nsec = entry->info.spoofed_mtime_tv_nsec;
		if (entry->info.flags & KSTAT_SPOOF_CTIME_TV_SEC)
			stat->ctime.tv_sec = entry->info.spoofed_ctime_tv_sec;
		if (entry->info.flags & KSTAT_SPOOF_CTIME_TV_NSEC)
			stat->ctime.tv_nsec = entry->info.spoofed_ctime_tv_nsec;
		if (entry->info.flags & KSTAT_SPOOF_BLKSIZE)
			stat->blksize = entry->info.spoofed_blksize;
		if (entry->info.flags & KSTAT_SPOOF_BLOCKS)
			stat->blocks = entry->info.spoofed_blocks;
		break;
	}
	rcu_read_unlock();
}
#endif /* CONFIG_KSU_SUSFS_SUS_KSTAT */

#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
/* v1.5.5: struct filename *susfs_get_redirected_path(unsigned long ino) */
struct filename *susfs_get_redirected_path(unsigned long ino)
{
	struct st_susfs_open_redirect_hlist *entry = NULL;

	rcu_read_lock();
	hash_for_each_possible_rcu(OPEN_REDIRECT_HLIST, entry, node, ino) {
		if (entry->target_ino == ino) {
			struct filename *ret;
			SUSFS_LOGI("Redirect for ino: %lu\n", ino);
			ret = getname_kernel(entry->info.redirected_pathname);
			rcu_read_unlock();
			return ret;
		}
	}
	rcu_read_unlock();
	return ERR_PTR(-ENOENT);
}
#endif /* CONFIG_KSU_SUSFS_OPEN_REDIRECT */

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
/* v2.3.0's susfs.c calls these; upstream defines them in the fs/namespace.c
 * hunk of the 4.9 patch, which we do not apply. */
int susfs_get_non_sus_mnt_id_from_mnt(struct mount *orig_mnt)
{
	struct mount *mnt = orig_mnt;
	int mnt_id;

	lock_mount_hash();
	for (; mnt && mnt->mnt_parent && mnt != mnt->mnt_parent &&
	       mnt->mnt_id >= DEFAULT_KSU_MNT_ID; mnt = mnt->mnt_parent) { }
	mnt_id = mnt->mnt_id;
	unlock_mount_hash();
	return mnt_id;
}

struct vfsmount *susfs_get_non_sus_vfsmnt_from_vfsmnt(struct vfsmount *vfsmnt)
{
	struct mount *mnt = real_mount(vfsmnt);

	lock_mount_hash();
	for (; mnt && mnt->mnt_parent && mnt != mnt->mnt_parent &&
	       mnt->mnt_id >= DEFAULT_KSU_MNT_ID; mnt = mnt->mnt_parent) { }
	mntget(&mnt->mnt);
	if (!mnt->mnt.mnt_root || IS_ERR(mnt->mnt.mnt_root)) {
		mntput(&mnt->mnt);
		unlock_mount_hash();
		return vfsmnt;
	}
	dget(mnt->mnt.mnt_root);
	unlock_mount_hash();
	return &mnt->mnt;
}
#endif /* CONFIG_KSU_SUSFS_SUS_MOUNT */

/* SukiSU Nova's sepolicy.c calls this unconditionally under CONFIG_KSU_SUSFS,
 * but no SUSFS release defines it. It is a bookkeeping hook for the avtab
 * "allowed" cache; a no-op is correct and safe. */
int susfs_add_sus_avd_allowed_by_type(u32 s_type, u32 t_type, u16 type,
				      u32 orig_avd_allowed)
{
	return 0;
}
'''

print("[1] compat layer")
p = "fs/susfs.c"
s = read(p)
if "4.14 compat layer" in s:
    print("  [skip] already present")
else:
    if "#include <linux/namei.h>" not in s:
        s = s.replace("#include <linux/susfs.h>",
                      "#include <linux/susfs.h>\n#include <linux/namei.h>\n#include \"../fs/mount.h\"", 1)
    write(p, s.rstrip("\n") + "\n" + COMPAT)
    print("  [ok]   appended")

# ====================================================== 2. missing macros
print("[2] missing macros in susfs_def.h")
p = "include/linux/susfs_def.h"
s = read(p)
if "SUSFS_414_COMPAT" in s:
    print("  [skip] already defined")
else:
    anchor = "#define DEFAULT_KSU_MNT_GROUP_ID 200000"
    if anchor not in s:
        sys.exit("  [ERROR] macro anchor missing")
    add = (anchor + "\n"
           "/* v1.5.5 name kept for the 4.14 patch's fs/namespace.c hunks */\n"
           "#define DEFAULT_SUS_MNT_GROUP_ID DEFAULT_KSU_MNT_GROUP_ID\n"
           "#define DEFAULT_SUS_MNT_ID DEFAULT_KSU_MNT_ID\n"
           "#define DEFAULT_KSU_MNT_ID_FOR_KSU_PROC_UNSHARE 2000000001\n"
           "/* marker for CI: the 4.14 reconcile ran (build-kernel-sukisu.yml checks this) */\n"
           "#define SUSFS_414_COMPAT 1")
    write(p, s.replace(anchor, add, 1))
    print("  [ok]   added DEFAULT_SUS_MNT_* aliases + KSU_PROC_UNSHARE + SUSFS_414_COMPAT")

# ============================================ 3. declare susfs_is_inode_sus_path
print("[3] declare susfs_is_inode_sus_path in susfs_def.h")
p = "include/linux/susfs_def.h"
s = read(p)
if "extern bool susfs_is_inode_sus_path" in s:
    print("  [skip] already declared")
else:
    anchor = "static inline bool susfs_is_current_proc_umounted_app(void) {"
    if anchor not in s:
        sys.exit("  [ERROR] decl anchor missing")
    decl = ("/* fs/namei.c, fs/dcache.c and fs/readdir.c include this header and\n"
            " * call it from their sus_path guards. */\n"
            "#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
            "extern bool susfs_is_inode_sus_path(struct inode *inode);\n"
            "#endif\n\n" + anchor)
    write(p, s.replace(anchor, decl, 1))
    print("  [ok]   declared")

# 3b. susfs_def.h uses current_uid()/current_fsuid() in its inline helpers but
#     only includes bits.h + string.h. 4.14 needs cred.h and sched.h.
print("[3b] susfs_def.h includes")
p = "include/linux/susfs_def.h"
s = read(p)
if "#include <linux/cred.h>" in s:
    print("  [skip] already included")
else:
    anchor = "#include <linux/string.h>"
    if anchor not in s:
        sys.exit("  [ERROR] include anchor missing")
    write(p, s.replace(anchor, anchor + "\n#include <linux/cred.h>\n#include <linux/sched.h>", 1))
    print("  [ok]   added cred.h + sched.h")

# ================================================== 4. fs/readdir.c rewrite
print("[4] fs/readdir.c -> v2.3.0 ilookup style")
p = "fs/readdir.c"
s = read(p)
if "susfs_is_inode_sus_path" in s:
    print("  [skip] already v2.3.0 style")
else:
    s = s.replace("extern int susfs_sus_ino_for_filldir64(unsigned long ino);",
                  "extern bool susfs_is_inode_sus_path(struct inode *inode);", 1)
    for cb in ("readdir_callback", "getdents_callback", "getdents_callback64",
               "compat_readdir_callback", "compat_getdents_callback"):
        pat = re.compile(r"(struct %s \{[^}]*?)(\n\};)" % cb, re.S)
        def add_sb(m):
            if "struct super_block *sb;" in m.group(1):
                return m.group(0)
            return (m.group(1) + "\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
                    "\tstruct super_block *sb;\n#endif" + m.group(2))
        s, n = pat.subn(add_sb, s, count=1)
        if n == 0:
            print("  [WARN] callback %s not found" % cb)

    old_call = re.compile(
        r"#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
        r"\s*if \(likely\(current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC\) && susfs_sus_ino_for_filldir64\(ino\)\) \{\n"
        r"\s*return 0;\n\s*\}\n#endif\n")
    new_call = ("#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\t{\n"
                "\t\tstruct inode *inode = ilookup(buf->sb, ino);\n"
                "\t\tif (!inode)\n\t\t\tgoto orig_flow;\n"
                "\t\tif (susfs_is_inode_sus_path(inode)) {\n"
                "\t\t\tiput(inode);\n\t\t\treturn 0;\n\t\t}\n"
                "\t\tiput(inode);\n\t}\norig_flow:\n#endif\n")
    s, n = old_call.subn(new_call, s)
    print("  [ok]   %d call sites" % n)
    if n != 4:
        sys.exit("  [ERROR] expected 4 call sites, got %d" % n)

    s, n = re.subn(r"(\n\s*)(error = iterate_dir\(f\.file, &buf\.ctx\);)",
                   r"\1#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\1buf.sb = f.file->f_inode->i_sb;\n\1#endif\n\1\2", s)
    print("  [ok]   %d iterate_dir sites seeded" % n)
    write(p, s)

# ============================================ 5. task_mmu / stat / namei API
print("[5] task_mmu.c / stat.c / namei.c -> v2.3.0 API")
sub1("fs/proc/task_mmu.c",
     "extern void susfs_sus_ino_for_show_map_vma(unsigned long ino, dev_t *out_dev, unsigned long *out_ino);",
     "extern void susfs_sus_kstat_spoof_show_map_vma(struct inode *inode, dev_t *out_dev, unsigned long *out_ino);",
     "task_mmu decl")
sub1("fs/proc/task_mmu.c",
     "if (unlikely(inode->i_state & INODE_STATE_SUS_KSTAT)) {\n\t\t\tsusfs_sus_ino_for_show_map_vma(inode->i_ino, &dev, &ino);",
     "if (unlikely(test_bit(AS_FLAGS_SUS_KSTAT, &inode->i_mapping->flags))) {\n\t\t\tsusfs_sus_kstat_spoof_show_map_vma(inode, &dev, &ino);",
     "task_mmu call")
sub1("fs/proc/task_mmu.c",
     "#include <linux/mm_inline.h>\n#include <linux/ctype.h>",
     "#include <linux/mm_inline.h>\n#include <linux/ctype.h>\n#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif",
     "task_mmu include")
sub1("fs/stat.c",
     "unlikely(inode->i_state & INODE_STATE_SUS_KSTAT)",
     "unlikely(test_bit(AS_FLAGS_SUS_KSTAT, &inode->i_mapping->flags))",
     "stat.c guard")
sub1("fs/namei.c",
     "unlikely(filp->f_inode->i_state & INODE_STATE_OPEN_REDIRECT)",
     "unlikely(test_bit(AS_FLAGS_OPEN_REDIRECT, &filp->f_inode->i_mapping->flags))",
     "namei.c open_redirect guard")

# ================================================ 6. sus_path guards (16)
print("[6] sus_path guards -> susfs_is_inode_sus_path()")
PAT = re.compile(
    r"unlikely\(\s*([A-Za-z_][A-Za-z0-9_]*(?:->[A-Za-z_][A-Za-z0-9_]*)*)\s*->i_state\s*&\s*INODE_STATE_SUS_PATH\s*\)"
    r"\s*&&\s*likely\(\s*current->susfs_task_state\s*&\s*TASK_STRUCT_NON_ROOT_USER_APP_PROC\s*\)")
tot = 0
for path in ("fs/dcache.c", "fs/namei.c"):
    s = read(path)
    s2, n = PAT.subn(lambda m: "susfs_is_inode_sus_path(%s)" % m.group(1), s)
    if n:
        write(path, s2)
    print("  [ok]   %s: %d" % (path, n))
    tot += n
print("  total %d" % tot)

# ==================================== 7. remaining task-state / bit / mnt ids
print("[7] remaining v1.5.5 constructs")
TASK_PAT = re.compile(r"likely\(\s*current->susfs_task_state\s*&\s*TASK_STRUCT_NON_ROOT_USER_APP_PROC\s*\)")
BIT_PAT = re.compile(
    r"unlikely\(\s*([A-Za-z_][A-Za-z0-9_]*(?:->[A-Za-z_][A-Za-z0-9_]*)*)\s*->i_state\s*&\s*INODE_STATE_(SUS_KSTAT|SUS_MOUNT|SUS_PATH)\s*\)")
FILES = ["fs/notify/fdinfo.c", "fs/proc/fd.c", "fs/stat.c", "fs/statfs.c",
         "fs/dcache.c", "fs/namei.c", "fs/readdir.c", "fs/proc/task_mmu.c",
         "fs/proc_namespace.c", "fs/namespace.c", "fs/overlayfs/util.c",
         "fs/overlayfs/readdir.c", "fs/overlayfs/inode.c", "fs/overlayfs/super.c"]
for path in FILES:
    try:
        s = read(path)
    except FileNotFoundError:
        continue
    orig = s
    s, n1 = TASK_PAT.subn("susfs_is_current_proc_umounted_app()", s)
    s, n2 = BIT_PAT.subn(lambda m: "unlikely(test_bit(AS_FLAGS_%s, &%s->i_mapping->flags))" % (m.group(2), m.group(1)), s)
    n3 = s.count("DEFAULT_SUS_MNT_ID")
    s = s.replace("DEFAULT_SUS_MNT_ID", "DEFAULT_KSU_MNT_ID")
    if s != orig:
        write(path, s)
    if n1 or n2 or n3:
        print("  [ok]   %-26s task=%d bit=%d mnt=%d" % (path, n1, n2, n3))

# ==================================================== 8. fsnotify signatures
print("[8] fsnotify 4.14 signatures")
sub1("fs/susfs.c",
     "\tu32 mask, void *data, int data_type,\n\tconst unsigned char *file_name, u32 cookie)",
     "\tu32 mask, const void *data, int data_type,\n\tconst unsigned char *file_name, u32 cookie,\n\tstruct fsnotify_iter_info *iter_info)",
     "handle_event signature")
sub1("fs/susfs.c",
     "\tfsnotify_init_mark(m, NULL);\n\tm->mask = mask;\n\tif (fsnotify_add_mark(m, g, inode, NULL, 0)) {",
     "\tfsnotify_init_mark(m, g);\n\tm->mask = mask;\n\tif (fsnotify_add_mark(m, inode, NULL, 0)) {",
     "fsnotify_add_mark")

# ============================================================== 9. verify
print("[9] verify")
left = subprocess.run(
    ["grep", "-rn", "-E",
     "INODE_STATE_|TASK_STRUCT_NON_ROOT_USER_APP_PROC|DEFAULT_SUS_MNT_ID|susfs_sus_ino_for_filldir64|susfs_sus_ino_for_show_map_vma",
     "fs/", "include/"],
    capture_output=True, text=True).stdout.strip()
left = "\n".join(l for l in left.splitlines() if "fs/susfs.c" not in l)
if left:
    print("  [WARN] leftovers:\n" + left)
else:
    print("  [ok]   no v1.5.5 constructs remain")
print("[done]")
