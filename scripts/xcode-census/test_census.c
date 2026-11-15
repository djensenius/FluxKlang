#include "census.h"
#include <sys/acl.h>
#include <sys/attr.h>
#include <sys/kauth.h>
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef XC_FIXTURE
#error Fixtures must be separately compiled
#endif

#define REQUIRE(x) do { if (!(x)) { \
    fprintf(stderr, "FAIL line %d: %s (errno=%d)\n", __LINE__, #x, errno); \
    exit(1); \
} } while (0)

static struct xc_report report;
static unsigned cases;
static const struct xc_limits normal = {
    XC_ENTRIES, XC_DEPTH, XC_FDS, XC_MEMORY, XC_SECONDS, XC_ACL_BYTES
};
/* Only this process's new, fixed-prefix mkdtemp directory is modified.
 * Names below are fixed fixture objects, never scanner-controlled paths.
 * On assertion failure leave the owned directory for runner teardown rather
 * than attempting an unsafe broad recursive cleanup.
 */
static char temporary[] = "/private/tmp/xcode-census.XXXXXX";
static int rootfd;
static acl_t allow_acl;
static const char *forbidden_open;
static unsigned open_attempts;

int
xc_fixture_openat(int parent, const char *name, int flags)
{
    /* Called instead of EVERY scanner openat, BEFORE the real syscall.
     * A changed regular entry must not even be submitted to openat. */
    ++open_attempts;
    if (forbidden_open) {
        size_t n = strlen(forbidden_open);
        REQUIRE(strncmp(name, forbidden_open, n) != 0 ||
                (name[n] != '\0' && name[n] != '/'));
    }
    REQUIRE(flags == (O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC));
    size_t n = strlen(name);
    REQUIRE(n >= 2 && strcmp(name + n - 2, "/.") == 0);
    return openat(parent, name, flags);
}

int
xc_fixture_open(const char *name, int flags)
{
    (void)name; (void)flags;
    REQUIRE(0); /* no scanner path may bypass the openat tripwire */
    return -1;
}

static void
file(const char *name)
{
    int fd = openat(rootfd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    REQUIRE(fd >= 0);
    REQUIRE(acl_set_fd_np(fd, allow_acl, ACL_TYPE_EXTENDED) == 0);
    REQUIRE(close(fd) == 0);
}

static void
make_directory(const char *name)
{
    REQUIRE(mkdirat(rootfd, name, 0700) == 0);
    int fd = openat(rootfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    REQUIRE(fd >= 0);
    REQUIRE(acl_set_fd_np(fd, allow_acl, ACL_TYPE_EXTENDED) == 0);
    REQUIRE(close(fd) == 0);
}

static void
remove_file(const char *name)
{
    REQUIRE(unlinkat(rootfd, name, 0) == 0);
}

static int
scan(const struct xc_limits *limits, xc_hook hook, void *arg)
{
    open_attempts = 0;
    return xc_fixture(rootfd, limits, hook, arg, &report);
}

static int
has_reason(enum xc_error reason)
{
    for (unsigned i = 0; i < report.samples_used; ++i)
        if (report.samples[i].reason == (unsigned)reason)
            return 1;
    return 0;
}

static void
layout(void)
{
    REQUIRE(scan(NULL, NULL, NULL) == 0);
    REQUIRE(report.entries == 1 && report.acl_present == 1 && report.scanned_all);
    file("regular");
    REQUIRE(linkat(rootfd, "regular", rootfd, "hard", 0) == 0);
    REQUIRE(symlinkat("/outside-not-opened", rootfd, "absolute") == 0);
    REQUIRE(symlinkat("../escape", rootfd, "escape") == 0);
    REQUIRE(symlinkat("cycle-b", rootfd, "cycle-a") == 0);
    REQUIRE(symlinkat("cycle-a", rootfd, "cycle-b") == 0);
    REQUIRE(symlinkat("missing", rootfd, "dangling") == 0);
    REQUIRE(symlinkat("regular", rootfd, "acl-target") == 0);
    REQUIRE(mkfifoat(rootfd, "fifo", 0600) == 0);
    REQUIRE(scan(NULL, NULL, NULL) != 0);
    REQUIRE(report.scanned_all && report.entries == 10);
    REQUIRE(report.files == 2 && report.hardlinks == 2 && report.special == 1);
    REQUIRE(report.symlinks == 6 && report.symlink_absolute == 1);
    REQUIRE(report.symlink_escape == 1 && report.symlink_relative == 4);
    REQUIRE(has_reason(XC_SPECIAL));
    /* Focused real-host obligation: a missing symlink ACL is not "empty".
     * Current Darwin source omits the returned attribute for absent va_acl.
     * Any different hosted behavior fails review, not an automatic fallback. */
    REQUIRE(report.acl_unknown == 6 && has_reason(XC_SYMLINK_ACL));
    REQUIRE(report.acl_omitted == 6 && report.acl_query_errors == 0);
    REQUIRE(report.acl_present == 3 && report.acl_empty == 0);
    REQUIRE(xc_test_output(&report, XC_OUTPUT) == 0);
    remove_file("regular"); remove_file("hard"); remove_file("absolute");
    remove_file("escape"); remove_file("cycle-a"); remove_file("cycle-b");
    remove_file("dangling"); remove_file("acl-target"); remove_file("fifo");
    ++cases;
}

static void
permissions(void)
{
    file("permissions");
    int fd = openat(rootfd, "permissions", O_RDONLY | O_NOFOLLOW);
    REQUIRE(fd >= 0);
    REQUIRE(fchmod(fd, 0640) == 0);
    REQUIRE(fchflags(fd, UF_NODUMP) == 0);
    struct stat observed;
    REQUIRE(fstat(fd, &observed) == 0);
    REQUIRE(scan(NULL, NULL, NULL) == 0);
    int found = 0;
    for (unsigned i = 0; i < report.groups_used; ++i) {
        const struct xc_group *g = &report.groups[i];
        if (S_ISREG(g->mode)) {
            REQUIRE((g->mode & 0777U) == 0640 && g->flags == UF_NODUMP);
            REQUIRE(g->uid == observed.st_uid && g->gid == observed.st_gid);
            found = 1;
        }
    }
    REQUIRE(found && report.unknown_flags == 0 && report.acl_present == 2);
    /* Regular metadata is queried without opening the file at all. */
    REQUIRE(open_attempts == 1); /* fixture root directory only */
    REQUIRE(fchmod(fd, 0000) == 0);
    REQUIRE(scan(NULL, NULL, NULL) == 0);
    REQUIRE(report.files == 1);
    REQUIRE(fchflags(fd, 0) == 0);
    REQUIRE(close(fd) == 0);
    remove_file("permissions");
    ++cases;
}

struct mutation { enum xc_stage stage; int kind, fired; };

static void
mutate(enum xc_stage stage, int parent, const char *name, int held,
       struct statfs *fs, void *arg)
{
    struct mutation *m = arg;
    (void)held;
    if (m->fired || stage != m->stage)
        return;
    if (m->kind >= 4) {
        /* SYNTHETIC ONLY: no mounting, unmounting, or privileged operations. */
        if (m->kind == 4) fs->f_flags |= MNT_UNION;
        else if (m->kind == 5) fs->f_flags &= ~(uint32_t)MNT_LOCAL;
        else if (!strcmp(name, "victim")) fs->f_fsid.val[0] ^= 1;
        else return;
        m->fired = 1;
        return;
    }
    if (strcmp(name, "victim"))
        return;
    REQUIRE(parent >= 0);
    REQUIRE(renameat(parent, "victim", parent, "old") == 0);
    if (m->kind == 0)
        REQUIRE(symlinkat("outside", parent, "victim") == 0);
    else if (m->kind == 1)
        REQUIRE(mkfifoat(parent, "victim", 0600) == 0);
    else if (m->kind == 2)
        file("victim");
    else
        REQUIRE(mkdirat(parent, "victim", 0700) == 0);
    m->fired = 1;
}

static void
races_and_mounts(void)
{
    /* Replacement symlink has a real target, but neither may be opened. */
    file("outside");
    for (int kind = 0; kind < 7; ++kind) {
        struct mutation m = {
            .stage = kind < 2 ? XC_BEFORE_METADATA :
                     kind == 2 ? XC_AFTER_METADATA :
                     kind == 3 ? XC_DIRECTORY_END : XC_FILESYSTEM,
            .kind = kind, .fired = 0
        };
        if (kind == 3 || kind == 6) {
            make_directory("victim");
        } else {
            file("victim");
        }
        forbidden_open = kind < 3 ? "victim" : NULL;
        REQUIRE(scan(NULL, mutate, &m) != 0 && m.fired);
        forbidden_open = NULL;
        REQUIRE(!report.scanned_all);
        if (kind < 3) REQUIRE(open_attempts == 1); /* root, never victim/outside */
        if (kind < 4) REQUIRE(has_reason(XC_CHANGED));
        else REQUIRE(has_reason(XC_MOUNT));
        if (kind == 6) REQUIRE(report.mount_crossings == 1);
        if (kind == 3 || kind == 6) {
            REQUIRE(unlinkat(rootfd, "victim", AT_REMOVEDIR) == 0);
            if (kind == 3) REQUIRE(unlinkat(rootfd, "old", AT_REMOVEDIR) == 0);
        } else {
            remove_file("victim");
            if (kind < 4) remove_file("old");
        }
        ++cases;
    }
    remove_file("outside");
}

static void
directory_type_swaps(void)
{
    make_directory("outside");
    for (int kind = 0; kind < 2; ++kind) {
        make_directory("victim");
        struct mutation m = { .stage = XC_BEFORE_OPEN, .kind = kind, .fired = 0 };
        /* Directory acquisition is submitted, but lookup must reject the
         * swapped FIFO/symlink BEFORE a target open, not return a held FD. */
        REQUIRE(scan(NULL, mutate, &m) != 0 && m.fired);
        REQUIRE(report.first_error == XC_IO && !report.scanned_all);
        REQUIRE(report.first_errno == (kind == 0 ? ELOOP : ENOTDIR));
        remove_file("victim");
        REQUIRE(unlinkat(rootfd, "old", AT_REMOVEDIR) == 0);
        ++cases;
    }
    REQUIRE(unlinkat(rootfd, "outside", AT_REMOVEDIR) == 0);
}

static void
budgets(void)
{
    file("entry");
    struct xc_limits limits = normal;
    limits.entries = 2;
    REQUIRE(scan(&limits, NULL, NULL) == 0 && report.entries == 2);
    limits.entries = 1;
    REQUIRE(scan(&limits, NULL, NULL) != 0 && has_reason(XC_ENTRY_LIMIT));
    limits = normal; limits.depth = 0;
    REQUIRE(scan(&limits, NULL, NULL) != 0 && has_reason(XC_DEPTH_LIMIT));
    limits = normal; limits.fds = 1;
    REQUIRE(scan(&limits, NULL, NULL) != 0 && has_reason(XC_FD_LIMIT));
    limits = normal; limits.fds = 2;
    REQUIRE(scan(&limits, NULL, NULL) == 0 && report.peak_fds == 2);
    limits = normal; limits.memory = 0;
    REQUIRE(scan(&limits, NULL, NULL) != 0 && has_reason(XC_MEMORY_LIMIT));
    limits = normal; limits.seconds = 0;
    REQUIRE(scan(&limits, NULL, NULL) != 0 && has_reason(XC_TIME_LIMIT));
    limits = normal; limits.acl_bytes = 1;
    REQUIRE(scan(&limits, NULL, NULL) != 0 && report.acl_unknown == 2);
    REQUIRE(has_reason(XC_METADATA));
    REQUIRE(xc_test_output(&report, 1) != 0);
    REQUIRE(xc_test_output(&report, XC_OUTPUT) == 0);
    remove_file("entry");
    make_directory("entry");
    limits = normal; limits.fds = 2;
    REQUIRE(scan(&limits, NULL, NULL) != 0 && has_reason(XC_FD_LIMIT));
    limits.fds = 3;
    REQUIRE(scan(&limits, NULL, NULL) == 0 && report.peak_fds == 3);
    REQUIRE(unlinkat(rootfd, "entry", AT_REMOVEDIR) == 0);
    /* Samples are intentionally lossy; their cap must not truncate the scan. */
    char name[64];
    for (unsigned i = 0; i < XC_SAMPLES + 2; ++i) {
        REQUIRE(snprintf(name, sizeof(name), "link-%u-\"-\n", i) > 0);
        REQUIRE(symlinkat("missing", rootfd, name) == 0);
    }
    REQUIRE(scan(NULL, NULL, NULL) != 0);
    REQUIRE(report.scanned_all && report.symlinks == XC_SAMPLES + 2);
    REQUIRE(report.acl_omitted == XC_SAMPLES + 2 && report.acl_query_errors == 0);
    REQUIRE(report.samples_used == XC_SAMPLES && report.samples_omitted > 0);
    REQUIRE(xc_emit(&report) == 0); /* hosted Python validates JSON escaping */
    for (unsigned i = 0; i < XC_SAMPLES + 2; ++i) {
        REQUIRE(snprintf(name, sizeof(name), "link-%u-\"-\n", i) > 0);
        remove_file(name);
    }
    ++cases;
}

static void
path_and_group_budgets(void)
{
    /* Descriptor-relative creation/removal, even beyond PATH_MAX in total.
     * All 22 directory names below belong to this single owned fixture. */
    char component[201];
    memset(component, 'd', sizeof(component) - 1);
    component[sizeof(component) - 1] = '\0';
    int parents[23];
    parents[0] = rootfd;
    for (unsigned i = 1; i < 23; ++i) {
        REQUIRE(mkdirat(parents[i - 1], component, 0700) == 0);
        parents[i] = openat(parents[i - 1], component,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        REQUIRE(parents[i] >= 0);
        REQUIRE(acl_set_fd_np(parents[i], allow_acl, ACL_TYPE_EXTENDED) == 0);
    }
    REQUIRE(scan(NULL, NULL, NULL) != 0 && has_reason(XC_PATH_LIMIT));
    REQUIRE(!report.scanned_all);
    int truncated = 0;
    for (unsigned i = 0; i < report.samples_used; ++i)
        if (report.samples[i].truncated) truncated = 1;
    REQUIRE(truncated);
    for (unsigned i = 22; i > 0; --i) {
        REQUIRE(close(parents[i]) == 0);
        REQUIRE(unlinkat(parents[i - 1], component, AT_REMOVEDIR) == 0);
    }
    char name[32];
    for (unsigned i = 0; i < XC_GROUPS; ++i) {
        REQUIRE(snprintf(name, sizeof(name), "group-%u", i) > 0);
        file(name);
        int fd = openat(rootfd, name, O_RDONLY | O_NOFOLLOW);
        REQUIRE(fd >= 0);
        REQUIRE(fchmod(fd, (mode_t)i) == 0); /* <=0377; no special mode bits */
        REQUIRE(close(fd) == 0);
    }
    REQUIRE(scan(NULL, NULL, NULL) != 0 && has_reason(XC_GROUP_LIMIT));
    REQUIRE(report.groups_used == XC_GROUPS && !report.scanned_all);
    REQUIRE(xc_test_output(&report, XC_OUTPUT) == 0);
    for (unsigned i = 0; i < XC_GROUPS; ++i) {
        REQUIRE(snprintf(name, sizeof(name), "group-%u", i) > 0);
        remove_file(name);
    }
    ++cases;
}

/* Numeric diagnostics only; never emit ACL bytes or principal UUIDs. */
static int
acl_probe(const char *name, unsigned tag, uint32_t *count)
{
    struct attrlist attrs = {0};
    attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
    attrs.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_EXTENDED_SECURITY;
    unsigned char bytes[XC_ACL_BYTES] = {0};
    int status = getattrlistat(rootfd, name, &attrs, bytes, sizeof(bytes), FSOPT_NOFOLLOW);
    int error = status == 0 ? 0 : errno;
    uint32_t length;
    attribute_set_t returned;
    attrreference_t ref;
    size_t pos = sizeof(length) + sizeof(returned);
    memcpy(&length, bytes, sizeof(length));
    memcpy(&returned, bytes + sizeof(uint32_t), sizeof(returned));
    memcpy(&ref, bytes + pos, sizeof(ref)); /* zero scratch if omitted/failed */
    *count = UINT32_MAX;
    int decoded = status == 0 ? xc_test_acl(bytes, sizeof(bytes), count) : XC_ACL_INVALID;
    printf("ACL probe=%u syscall=%d errno=%d length=%u returned=%u ref_at=%zu "
           "offset=%d ref_length=%u decoded=%d count=%u\n", tag, status, error,
           length, returned.commonattr, pos, ref.attr_dataoffset, ref.attr_length, decoded, *count);
    REQUIRE(status == 0); /* kernel EINVAL is a failure, never an unsupported waiver */
    return decoded;
}

static unsigned
oracle_entries(acl_t acl)
{
    REQUIRE(acl != NULL);
    acl_entry_t entry;
    unsigned count = 0;
    int id = ACL_FIRST_ENTRY, status;
    errno = 0;
    while ((status = acl_get_entry(acl, id, &entry)) == 0) {
        REQUIRE(++count <= KAUTH_ACL_MAX_ENTRIES);
        id = ACL_NEXT_ENTRY;
        errno = 0;
    }
    REQUIRE(status == -1 && errno == EINVAL && acl_free(acl) == 0);
    return count;
}

static void
empty_fd_oracle(int fd, unsigned phase)
{
    /* Fixture-only Libc statx/filesec empty-ACL limitation (see README).
     * ENOENT is acceptable ONLY after positive zero-entry metadata on this
     * held, known-created regular file; it is not a general ACL/error rule. */
    struct stat held, named, after;
    REQUIRE(fstat(fd, &held) == 0 && S_ISREG(held.st_mode) &&
            held.st_uid == getuid() && held.st_nlink == 1);
    REQUIRE(fstatat(rootfd, "empty", &named, AT_SYMLINK_NOFOLLOW) == 0 &&
            named.st_dev == held.st_dev && named.st_ino == held.st_ino);
    uint32_t count;
    REQUIRE(acl_probe("empty", phase, &count) == XC_ACL_OK && count == 0);
    errno = 0;
    acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
    int error = acl ? 0 : errno;
    printf("ACL empty_fd phase=%u null=%d errno=%d\n", phase, acl == NULL, error);
    if (acl) REQUIRE(oracle_entries(acl) == 0);
    else REQUIRE(error == ENOENT);
    REQUIRE(fstat(fd, &after) == 0 && after.st_dev == held.st_dev &&
            after.st_ino == held.st_ino && after.st_nlink == 1);
    REQUIRE(fstatat(rootfd, "empty", &named, AT_SYMLINK_NOFOLLOW) == 0 &&
            named.st_dev == after.st_dev && named.st_ino == after.st_ino);
}

static void
real_acl_and_read_error(void)
{
    file("empty");
    int fd = openat(rootfd, "empty", O_RDONLY | O_NOFOLLOW);
    REQUIRE(fd >= 0);
    uint32_t count;
    int decoded = acl_probe("empty", 1, &count);
    REQUIRE(oracle_entries(acl_get_fd_np(fd, ACL_TYPE_EXTENDED)) == 1);
    REQUIRE(decoded == XC_ACL_OK && count == 1);
    REQUIRE(scan(NULL, NULL, NULL) == 0 && report.acl_present == 2);
    acl_t empty = acl_init(0);
    REQUIRE(empty != NULL && acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED) == 0);
    REQUIRE(acl_free(empty) == 0);
    empty_fd_oracle(fd, 0); /* explicit decoded zero remains mandatory */
    REQUIRE(scan(NULL, NULL, NULL) == 0 && report.acl_empty == 1 && !report.acl_unknown);

    REQUIRE(symlinkat("empty", rootfd, "acl-link") == 0);
    char path[XC_PATH];
    int n = snprintf(path, sizeof(path), "%s/acl-link", temporary);
    REQUIRE(n > 0 && (size_t)n < sizeof(path));
    /* Libc acl_set_link_np refuses symlinks unconditionally. Exercise the
     * nofollow setter using libSystem's serializer, not our synthetic layout. */
    _Alignas(max_align_t) unsigned char bytes[XC_ACL_BYTES];
    attrreference_t ref = { .attr_dataoffset = (int32_t)sizeof(ref) };
    _Static_assert(sizeof(ref) % _Alignof(struct kauth_filesec) == 0, "ACL payload alignment");
    ssize_t size = acl_copy_ext_native(bytes + sizeof(ref), allow_acl,
                                       (ssize_t)(sizeof(bytes) - sizeof(ref)));
    REQUIRE(size > 0 && (size_t)size <= sizeof(bytes) - sizeof(ref));
    ref.attr_length = (uint32_t)size;
    memcpy(bytes, &ref, sizeof(ref));
    struct attrlist attrs = { .bitmapcount = ATTR_BIT_MAP_COUNT,
                              .commonattr = ATTR_CMN_EXTENDED_SECURITY };
    int status = setattrlist(path, &attrs, bytes, sizeof(ref) + (size_t)size, FSOPT_NOFOLLOW);
    int error = status == 0 ? 0 : errno;
    printf("ACL link_set syscall=%d errno=%d\n", status, error);
    REQUIRE(status == 0 || error == ENOTSUP);
    decoded = acl_probe("acl-link", 2, &count);
    empty_fd_oracle(fd, 4); /* setter must leave the regular target empty */
    if (status == 0) {
        REQUIRE(oracle_entries(acl_get_link_np(path, ACL_TYPE_EXTENDED)) == 1);
        REQUIRE(decoded == XC_ACL_OK && count == 1);
        REQUIRE(scan(NULL, NULL, NULL) == 0 && report.acl_present == 2 && report.acl_empty == 1);
        puts("PASS real regular empty/nonempty and symlink ACLs (independent getters)");
    } else {
        REQUIRE(decoded == XC_ACL_MISSING);
        REQUIRE(scan(NULL, NULL, NULL) != 0 && report.acl_omitted == 1 && report.acl_unknown == 1);
        puts("UNSUPPORTED symlink ACL setter: ENOTSUP; census remains incomplete");
    }
    remove_file("acl-link");
    REQUIRE(close(fd) == 0);
    remove_file("empty");
    REQUIRE(mkdirat(rootfd, "unreadable", 0700) == 0);
    fd = openat(rootfd, "unreadable", O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    REQUIRE(fd >= 0 && fchmod(fd, 0000) == 0);
    REQUIRE(scan(NULL, NULL, NULL) != 0 && has_reason(XC_IO));
    REQUIRE(!report.scanned_all);
    REQUIRE(fchmod(fd, 0700) == 0 && close(fd) == 0);
    REQUIRE(unlinkat(rootfd, "unreadable", AT_REMOVEDIR) == 0);
    ++cases;
}

static void
wire_metadata(void)
{
    unsigned char bytes[XC_ACL_BYTES] = {0};
    const size_t pos = sizeof(uint32_t) + sizeof(attribute_set_t);
    const size_t start = pos + sizeof(attrreference_t);
    const size_t header = offsetof(struct kauth_filesec, fsec_acl) +
                          offsetof(struct kauth_acl, acl_ace);
    uint32_t length = (uint32_t)(start + header + sizeof(struct kauth_ace));
    attribute_set_t returned = {0};
    returned.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_EXTENDED_SECURITY;
    attrreference_t ref = {
        .attr_dataoffset = (int32_t)sizeof(ref),
        .attr_length = (uint32_t)(header + sizeof(struct kauth_ace))
    };
    struct kauth_filesec sec = {0};
    sec.fsec_magic = KAUTH_FILESEC_MAGIC;
    sec.fsec_entrycount = 1;
    memcpy(bytes, &length, sizeof(length));
    memcpy(bytes + sizeof(length), &returned, sizeof(returned));
    memcpy(bytes + pos, &ref, sizeof(ref));
    memcpy(bytes + start, &sec, header);
    uint32_t count = 999;
    REQUIRE(xc_test_acl(bytes, sizeof(bytes), &count) == 0 && count == 1);
    REQUIRE(xc_test_acl(bytes, length - 1, &count) != 0);
    ref.attr_dataoffset = -1;
    memcpy(bytes + pos, &ref, sizeof(ref));
    REQUIRE(xc_test_acl(bytes, sizeof(bytes), &count) != 0);
    ref.attr_dataoffset = INT32_MAX;
    memcpy(bytes + pos, &ref, sizeof(ref));
    REQUIRE(xc_test_acl(bytes, sizeof(bytes), &count) != 0);
    ref.attr_dataoffset = (int32_t)sizeof(ref);
    ref.attr_length = UINT32_MAX;
    memcpy(bytes + pos, &ref, sizeof(ref));
    REQUIRE(xc_test_acl(bytes, sizeof(bytes), &count) != 0);
    ref.attr_length = (uint32_t)(header + sizeof(struct kauth_ace));
    memcpy(bytes + pos, &ref, sizeof(ref));
    sec.fsec_entrycount = KAUTH_ACL_MAX_ENTRIES + 1;
    memcpy(bytes + start, &sec, header);
    REQUIRE(xc_test_acl(bytes, sizeof(bytes), &count) != 0);
    sec.fsec_entrycount = KAUTH_FILESEC_NOACL;
    memcpy(bytes + start, &sec, header);
    REQUIRE(xc_test_acl(bytes, sizeof(bytes), &count) != 0);
    sec.fsec_entrycount = 1; sec.fsec_magic = 0;
    memcpy(bytes + start, &sec, header);
    REQUIRE(xc_test_acl(bytes, sizeof(bytes), &count) != 0);
    sec.fsec_magic = KAUTH_FILESEC_MAGIC; sec.fsec_entrycount = 0;
    ref.attr_length = (uint32_t)header;
    length = (uint32_t)(start + header);
    memcpy(bytes, &length, sizeof(length));
    memcpy(bytes + pos, &ref, sizeof(ref));
    memcpy(bytes + start, &sec, header);
    REQUIRE(xc_test_acl(bytes, sizeof(bytes), &count) == 0 && count == 0);
    sec.fsec_entrycount = KAUTH_FILESEC_NOACL;
    memcpy(bytes + start, &sec, header);
    REQUIRE(xc_test_acl(bytes, sizeof(bytes), &count) == XC_ACL_NOACL);
    returned.commonattr = ATTR_CMN_RETURNED_ATTRS;
    length = (uint32_t)pos; /* real omitted-attribute shape: no reference */
    memcpy(bytes, &length, sizeof(length));
    memcpy(bytes + sizeof(length), &returned, sizeof(returned));
    REQUIRE(xc_test_acl(bytes, length, &count) == XC_ACL_MISSING);
    REQUIRE(xc_test_acl(bytes, length - 1, &count) == XC_ACL_INVALID);
    puts("PASS synthetic ACL bounds; NOT proof of symlink ACL support");
    ++cases;
}

int
main(void)
{
    REQUIRE(getuid() != 0 && geteuid() != 0);
    REQUIRE(mkdtemp(temporary) != NULL);
    rootfd = open(temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    REQUIRE(rootfd >= 0);
    struct stat st;
    REQUIRE(fstat(rootfd, &st) == 0 && st.st_uid == getuid());
    /* Fixed Darwin well-known everyone UUID; metadata-read rights only. */
    const unsigned char everyone[16] = {
        0xff, 0xff, 0xee, 0xee, 0xdd, 0xdd, 0xcc, 0xcc,
        0xbb, 0xbb, 0xaa, 0xaa, 0x00, 0x00, 0x00, 0x0c
    };
    allow_acl = acl_init(1);
    REQUIRE(allow_acl != NULL);
    acl_entry_t entry;
    acl_permset_t perms;
    REQUIRE(acl_create_entry(&allow_acl, &entry) == 0);
    REQUIRE(acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0);
    REQUIRE(acl_set_qualifier(entry, everyone) == 0);
    REQUIRE(acl_get_permset(entry, &perms) == 0);
    REQUIRE(acl_clear_perms(perms) == 0);
    REQUIRE(acl_add_perm(perms, ACL_READ_ATTRIBUTES) == 0);
    REQUIRE(acl_add_perm(perms, ACL_READ_SECURITY) == 0);
    REQUIRE(acl_set_permset(entry, perms) == 0);
    REQUIRE(acl_set_fd_np(rootfd, allow_acl, ACL_TYPE_EXTENDED) == 0);
    uint32_t count;
    REQUIRE(symlinkat("missing", rootfd, "acl-probe") == 0);
    REQUIRE(acl_probe("acl-probe", 3, &count) == XC_ACL_MISSING);
    remove_file("acl-probe");
    real_acl_and_read_error();
    layout();
    permissions();
    races_and_mounts();
    directory_type_swaps();
    budgets();
    path_and_group_budgets();
    wire_metadata();
    REQUIRE(acl_free(allow_acl) == 0);
    REQUIRE(close(rootfd) == 0);
    REQUIRE(rmdir(temporary) == 0);
    printf("PASS %u fixture cases (mount cases synthetic)\n", cases);
    return 0;
}
