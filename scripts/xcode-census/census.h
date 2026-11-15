#ifndef XCODE_CENSUS_H
#define XCODE_CENSUS_H

#include <stddef.h>
#include <stdint.h>

/* Review ceilings, NOT measured Xcode capacity. No runtime overrides. */
#define XC_ENTRIES 2000000U
#define XC_DEPTH 64U
#define XC_FDS 72U
#define XC_MEMORY (8U * 1024U * 1024U)
#define XC_ACL_BYTES 16384U
#define XC_SECONDS 600U
#define XC_OUTPUT (128U * 1024U)
#define XC_SAMPLES 48U
#define XC_SAMPLE_PATH 160U
#define XC_PATH 4096U
#define XC_GROUPS 256U
#define XC_MOUNTS 16U

enum xc_error {
    XC_OK, XC_ARGUMENTS, XC_ROOT, XC_PLATFORM, XC_IO, XC_CHANGED,
    XC_METADATA, XC_SYMLINK_ACL, XC_SPECIAL, XC_MOUNT, XC_FLAGS,
    XC_ENTRY_LIMIT, XC_DEPTH_LIMIT, XC_FD_LIMIT, XC_MEMORY_LIMIT,
    XC_TIME_LIMIT, XC_PATH_LIMIT, XC_GROUP_LIMIT, XC_OUTPUT_LIMIT
};

enum xc_acl_result { XC_ACL_OK, XC_ACL_MISSING, XC_ACL_NOACL, XC_ACL_INVALID };

struct xc_group {
    uint64_t count, links;
    uint32_t uid, gid, mode, flags;
    int64_t device;
};

struct xc_mount {
    int64_t device;
    int32_t fsid[2];
    uint32_t type, flags;
};

struct xc_sample {
    char path[XC_SAMPLE_PATH];
    unsigned scope, reason, truncated;
    uint32_t uid, gid, mode, flags;
    uint64_t links;
    int64_t device;
};

struct xc_report {
    uint64_t entries, directories, files, symlinks, special, hardlinks;
    uint64_t acl_present, acl_empty, acl_unknown, acl_entries;
    uint64_t acl_query_errors, acl_omitted, acl_noacl, acl_invalid;
    uint64_t symlink_absolute, symlink_escape, symlink_relative;
    uint64_t mount_crossings, unknown_flags, errors, samples_omitted;
    unsigned first_error, scanned_all, peak_fds, peak_depth;
    unsigned groups_used, mounts_used, samples_used, ordinary_samples;
    int first_errno;
    struct xc_group groups[XC_GROUPS];
    struct xc_mount mounts[XC_MOUNTS];
    struct xc_sample samples[XC_SAMPLES];
};

int xc_fixed(struct xc_report *report);
int xc_emit(const struct xc_report *report); /* stdout only */
void xc_refuse(struct xc_report *report, enum xc_error error);

#ifdef XC_FIXTURE
#include <sys/mount.h>
enum xc_stage {
    XC_BEFORE_OPEN, XC_AFTER_OPEN, XC_DIRECTORY_END, XC_FILESYSTEM,
    XC_BEFORE_METADATA, XC_AFTER_METADATA
};
struct xc_limits {
    uint64_t entries;
    unsigned depth, fds, memory, seconds, acl_bytes;
};
typedef void (*xc_hook)(enum xc_stage, int, const char *, int,
                        struct statfs *, void *);
int xc_fixture(int rootfd, const struct xc_limits *, xc_hook, void *,
               struct xc_report *);
int xc_test_acl(const unsigned char *, size_t, uint32_t *);
int xc_test_output(const struct xc_report *, unsigned);
/* Interpose scanner calls only; fixture setup still uses the real syscalls. */
int xc_fixture_openat(int, const char *, int);
int xc_fixture_open(const char *, int);
#endif
#endif
