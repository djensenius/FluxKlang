#include "census.h"
#include <errno.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static const char *const error_names[] = {
    "none", "arguments", "root", "unsupported_platform", "io", "changed",
    "metadata", "symlink_acl_unestablished", "special_object", "mount",
    "unknown_flags", "entry_budget", "depth_budget", "fd_budget",
    "memory_budget", "elapsed_budget", "path_budget", "group_budget",
    "output_budget"
};

void
xc_refuse(struct xc_report *r, enum xc_error e)
{
    memset(r, 0, sizeof(*r));
    r->first_error = (unsigned)e;
    r->errors = 1;
}

/* One bounded serialization buffer; never emit a partial JSON document. */
struct output {
    char bytes[XC_OUTPUT];
    size_t used, limit;
    int failed;
};

static void append(struct output *, const char *, ...)
    __attribute__((format(printf, 2, 3)));

static void
append(struct output *o, const char *fmt, ...)
{
    if (o->failed)
        return;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(o->bytes + o->used, o->limit - o->used, fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= o->limit - o->used) {
        o->failed = 1;
        return;
    }
    o->used += (size_t)n;
}

static void
quoted(struct output *o, const char *s)
{
    append(o, "\"");
    for (const unsigned char *p = (const unsigned char *)s; *p; ++p) {
        if (*p >= 32 && *p <= 126 && *p != '"' && *p != '\\')
            append(o, "%c", (int)*p);
        else
            append(o, "\\u%04x", (unsigned)*p);
    }
    append(o, "\"");
}

static int
serialize(const struct xc_report *r, struct output *o, unsigned limit)
{
    memset(o, 0, sizeof(*o));
    o->limit = limit <= XC_OUTPUT ? limit : XC_OUTPUT;
    if (o->limit == 0)
        return -1;
    append(o, "{\"schema\":1,\"role\":\"unauthenticated_read_only_layout\","
           "\"complete\":%s,\"scanned_all\":%s,\"error\":",
           r->errors ? "false" : "true", r->scanned_all ? "true" : "false");
    quoted(o, error_names[r->first_error <= XC_OUTPUT_LIMIT ?
                          r->first_error : XC_METADATA]);
    append(o, ",\"errno\":%d,\"errors\":%" PRIu64, r->first_errno, r->errors);
#define COUNT(field) append(o, ",\"" #field "\":%" PRIu64, r->field)
    COUNT(entries); COUNT(directories); COUNT(files); COUNT(symlinks);
    COUNT(special); COUNT(hardlinks); COUNT(acl_present); COUNT(acl_empty);
    COUNT(acl_unknown); COUNT(acl_entries); COUNT(symlink_absolute);
    COUNT(acl_query_errors); COUNT(acl_omitted); COUNT(acl_noacl); COUNT(acl_invalid);
    COUNT(symlink_escape); COUNT(symlink_relative); COUNT(mount_crossings);
    COUNT(unknown_flags); COUNT(samples_omitted);
#undef COUNT
    append(o, ",\"peak_fds\":%u,\"peak_depth\":%u,\"ceilings\":{"
           "\"entries\":%u,\"depth\":%u,\"fds\":%u,\"memory_bytes\":%u,"
           "\"acl_bytes\":%u,\"seconds\":%u,\"output_bytes\":%u,"
           "\"samples\":%u,\"groups\":%u,\"mounts\":%u,\"path_bytes\":%u},"
           "\"groups\":[", r->peak_fds, r->peak_depth, XC_ENTRIES, XC_DEPTH,
           XC_FDS, XC_MEMORY, XC_ACL_BYTES, XC_SECONDS, XC_OUTPUT, XC_SAMPLES,
           XC_GROUPS, XC_MOUNTS, XC_PATH);
    for (unsigned i = 0; i < r->groups_used; ++i) {
        const struct xc_group *g = &r->groups[i];
        append(o, "%s{\"uid\":%u,\"gid\":%u,\"mode\":%u,\"flags\":%u,"
               "\"device\":%" PRId64 ",\"links\":%" PRIu64
               ",\"count\":%" PRIu64 "}", i ? "," : "", g->uid, g->gid,
               g->mode, g->flags, g->device, g->links, g->count);
    }
    append(o, "],\"mounts\":[");
    for (unsigned i = 0; i < r->mounts_used; ++i) {
        const struct xc_mount *m = &r->mounts[i];
        append(o, "%s{\"device\":%" PRId64 ",\"fsid\":[%" PRId32 ",%" PRId32
               "],\"type\":%u,\"flags\":%u}", i ? "," : "", m->device,
               m->fsid[0], m->fsid[1], m->type, m->flags);
    }
    append(o, "],\"samples\":[");
    for (unsigned i = 0; i < r->samples_used; ++i) {
        const struct xc_sample *s = &r->samples[i];
        append(o, "%s{\"scope\":%u,\"reason\":", i ? "," : "", s->scope);
        quoted(o, error_names[s->reason]);
        append(o, ",\"path\":");
        quoted(o, s->path);
        append(o, ",\"truncated\":%s,\"uid\":%u,\"gid\":%u,\"mode\":%u,"
               "\"flags\":%u,\"links\":%" PRIu64 ",\"device\":%" PRId64 "}",
               s->truncated ? "true" : "false", s->uid, s->gid, s->mode,
               s->flags, s->links, s->device);
    }
    append(o, "]}\n");
    return o->failed ? -1 : 0;
}

int
xc_emit(const struct xc_report *r)
{
    static struct output o;
    static const char fallback[] =
        "{\"schema\":1,\"complete\":false,\"error\":\"output_budget\"}\n";
    int failed = serialize(r, &o, XC_OUTPUT);
    const char *p = failed ? fallback : o.bytes;
    size_t left = failed ? sizeof(fallback) - 1 : o.used;
    while (left) {
        ssize_t n = write(STDOUT_FILENO, p, left);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return -1;
        p += (size_t)n;
        left -= (size_t)n;
    }
    return failed;
}

#if defined(__APPLE__) && defined(__aarch64__)
#include <TargetConditionals.h>
#if !TARGET_OS_OSX
#error Only macOS is supported
#endif
#include <sys/acl.h>
#include <sys/attr.h>
#include <sys/kauth.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdbool.h>
#include <time.h>

#ifdef XC_FIXTURE
#define openat xc_fixture_openat
#define open xc_fixture_open
#endif

#ifndef XC_FIXTURE
struct xc_limits {
    uint64_t entries;
    unsigned depth, fds, memory, seconds, acl_bytes;
};
#endif

/* Reserve 64 KiB per live descriptor for libSystem DIR/ACL bookkeeping.
 * Darwin readdir uses <=8 KiB on non-union filesystems (see README).
 * No telldir/seekdir, strdup, content reads, or per-entry allocation.
 */
#define FD_MEMORY 65536U
struct scan {
    struct xc_report *r;
    struct xc_limits limits;
    struct timespec start;
    unsigned fds, scope;
    int stop;
    char path[XC_PATH];
    unsigned char acl[XC_ACL_BYTES];
    char target[XC_PATH];
#ifdef XC_FIXTURE
    xc_hook hook;
    void *hook_arg;
#endif
};

static const struct xc_limits ceilings = {
    XC_ENTRIES, XC_DEPTH, XC_FDS, XC_MEMORY, XC_SECONDS, XC_ACL_BYTES
};
_Static_assert(sizeof(struct scan) + sizeof(struct xc_report) +
               sizeof(struct output) + XC_FDS * FD_MEMORY < XC_MEMORY,
               "fixed allocations and descriptor reservations exceed memory cap");
_Static_assert(KAUTH_ACL_MAX_ENTRIES <= 128 && ACL_MAX_ENTRIES <= 128,
               "review memory reservations before accepting a larger SDK ACL");

static void
sample(struct scan *c, enum xc_error reason, const struct stat *s)
{
    struct xc_report *r = c->r;
    if ((reason == XC_OK && r->ordinary_samples >= 8) ||
        r->samples_used == XC_SAMPLES) {
        ++r->samples_omitted;
        return;
    }
    if (reason == XC_OK)
        ++r->ordinary_samples;
    struct xc_sample *p = &r->samples[r->samples_used++];
    size_t n = strlen(c->path);
    p->truncated = n >= sizeof(p->path);
    if (n >= sizeof(p->path))
        n = sizeof(p->path) - 1;
    memcpy(p->path, c->path, n);
    p->path[n] = '\0';
    p->scope = c->scope;
    p->reason = (unsigned)reason;
    if (s) {
        p->uid = s->st_uid; p->gid = s->st_gid; p->mode = s->st_mode;
        p->flags = s->st_flags; p->links = s->st_nlink; p->device = s->st_dev;
    }
}

static void
issue(struct scan *c, enum xc_error error, int number,
      const struct stat *s, bool stop)
{
    if (c->r->errors++ == 0) {
        c->r->first_error = (unsigned)error;
        c->r->first_errno = number;
    }
    sample(c, error, s);
    if (stop)
        c->stop = 1;
}

static bool
tick(struct scan *c)
{
    struct timespec now;
    if (c->stop)
        return false;
    if (clock_gettime(CLOCK_MONOTONIC, &now) < 0) {
        issue(c, XC_IO, errno, NULL, true);
        return false;
    }
    time_t seconds = now.tv_sec - c->start.tv_sec;
    if (now.tv_nsec < c->start.tv_nsec)
        --seconds;
    if (seconds >= (time_t)c->limits.seconds) {
        issue(c, XC_TIME_LIMIT, 0, NULL, true);
        return false;
    }
    return true;
}

static bool
reserve_fd(struct scan *c)
{
    if (!tick(c))
        return false;
    if (c->fds >= c->limits.fds) {
        issue(c, XC_FD_LIMIT, 0, NULL, true);
        return false;
    }
    size_t memory = sizeof(*c) + sizeof(*c->r) + sizeof(struct output) +
                    (size_t)(c->fds + 1) * FD_MEMORY;
    if (memory > c->limits.memory) {
        issue(c, XC_MEMORY_LIMIT, 0, NULL, true);
        return false;
    }
    ++c->fds;
    if (c->fds > c->r->peak_fds)
        c->r->peak_fds = c->fds;
    return true;
}

/* No non-directory target is ever opened, even after a type-swap race.
 * The "/." suffix forces lookup to establish a directory before the final
 * component (including before compound open); NOFOLLOW_ANY rejects symlinks
 * in that prefix. O_DIRECTORY is also retained. See the XNU proof in README.
 * Shared scratch is safe: no target string remains live across this call.
 */
static int
directory_open(struct scan *c, int parent, const char *name)
{
    int n = snprintf(c->target, sizeof(c->target), "%s/.",
                     strcmp(name, "/") == 0 ? "" : name);
    if (n < 0 || (size_t)n >= sizeof(c->target)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return openat(parent, c->target,
                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC);
}

static bool
same(const struct stat *a, const struct stat *b)
{
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino &&
        a->st_gen == b->st_gen && a->st_mode == b->st_mode &&
        a->st_uid == b->st_uid && a->st_gid == b->st_gid &&
        a->st_nlink == b->st_nlink && a->st_flags == b->st_flags &&
        a->st_size == b->st_size &&
        a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec &&
        a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec == b->st_ctimespec.tv_sec &&
        a->st_ctimespec.tv_nsec == b->st_ctimespec.tv_nsec &&
        a->st_birthtimespec.tv_sec == b->st_birthtimespec.tv_sec &&
        a->st_birthtimespec.tv_nsec == b->st_birthtimespec.tv_nsec;
}

/* Directories: both the held object and name in its held parent must match.
 * Regular files and symlinks have NO object FD: only successive parent/name
 * observations are checked; their stat/ACL samples are not FD-bound.
 */
static bool
recheck(struct scan *c, int parent, const char *name, int fd,
        const struct stat *before, const struct stat *parent_before)
{
    struct stat current;
    if (fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) < 0 ||
        !same(before, &current) ||
        (fd >= 0 && (fstat(fd, &current) < 0 || !same(before, &current))) ||
        fstat(parent, &current) < 0 || !same(parent_before, &current)) {
        issue(c, XC_CHANGED, 0, before, true);
        return false;
    }
    return true;
}

static uint32_t
known_flags(void)
{
    /* Deliberately explicit: newly introduced SDK flags remain observable
     * unknowns, not silently included via UF_SETTABLE/SF_SETTABLE masks. */
    return UF_NODUMP | UF_IMMUTABLE | UF_APPEND | UF_OPAQUE | UF_COMPRESSED |
        UF_TRACKED | UF_DATAVAULT | UF_HIDDEN | SF_ARCHIVED | SF_IMMUTABLE |
        SF_APPEND | SF_RESTRICTED | SF_NOUNLINK | SF_FIRMLINK | SF_DATALESS;
}

static void
observe(struct scan *c, const struct stat *s)
{
    struct xc_report *r = c->r;
    ++r->entries;
    if (S_ISDIR(s->st_mode)) ++r->directories;
    else if (S_ISREG(s->st_mode)) ++r->files;
    else if (S_ISLNK(s->st_mode)) ++r->symlinks;
    else ++r->special;
    if (!S_ISDIR(s->st_mode) && s->st_nlink > 1)
        ++r->hardlinks;
    if (s->st_flags & ~known_flags()) {
        ++r->unknown_flags;
        issue(c, XC_FLAGS, 0, s, false);
    }
    unsigned i;
    for (i = 0; i < r->groups_used; ++i) {
        struct xc_group *g = &r->groups[i];
        if (g->uid == s->st_uid && g->gid == s->st_gid &&
            g->mode == s->st_mode && g->flags == s->st_flags &&
            g->device == s->st_dev && g->links == s->st_nlink) {
            ++g->count;
            break;
        }
    }
    if (i == r->groups_used) {
        if (i == XC_GROUPS) {
            issue(c, XC_GROUP_LIMIT, 0, s, true);
            return;
        }
        r->groups[i] = (struct xc_group) {
            .count = 1, .links = s->st_nlink, .uid = s->st_uid,
            .gid = s->st_gid, .mode = s->st_mode, .flags = s->st_flags,
            .device = s->st_dev
        };
        ++r->groups_used;
    }
    sample(c, XC_OK, s);
}

static bool
filesystem(struct scan *c, int parent, const char *name, int fd,
           const struct stat *s, const struct statfs *expected,
           struct statfs *fs)
{
    if (fstatfs(fd, fs) < 0) {
        issue(c, XC_METADATA, errno, s, true);
        return false;
    }
#ifdef XC_FIXTURE
    if (c->hook)
        c->hook(XC_FILESYSTEM, parent, name, fd, fs, c->hook_arg);
#else
    (void)parent; (void)name;
#endif
    bool crossing = expected &&
        (memcmp(&fs->f_fsid, &expected->f_fsid, sizeof(fs->f_fsid)) != 0 ||
         fs->f_type != expected->f_type);
    if (crossing)
        ++c->r->mount_crossings;
    unsigned i;
    for (i = 0; i < c->r->mounts_used; ++i) {
        const struct xc_mount *m = &c->r->mounts[i];
        if (m->device == s->st_dev && m->fsid[0] == fs->f_fsid.val[0] &&
            m->fsid[1] == fs->f_fsid.val[1] && m->type == fs->f_type &&
            m->flags == fs->f_flags)
            break;
    }
    if (i == XC_MOUNTS) {
        issue(c, XC_GROUP_LIMIT, 0, s, true);
        return false;
    }
    if (i == c->r->mounts_used)
        c->r->mounts[c->r->mounts_used++] = (struct xc_mount) {
            .device = s->st_dev, .fsid = {fs->f_fsid.val[0], fs->f_fsid.val[1]},
            .type = fs->f_type, .flags = fs->f_flags
        };
    /* Preserve even refused mount metadata, but never enumerate it.
     * APFS/local is an implementation bound, not a trust assertion. */
    if (crossing || (fs->f_flags & MNT_UNION) ||
        !(fs->f_flags & MNT_LOCAL) || strcmp(fs->f_fstypename, "apfs") != 0) {
        issue(c, XC_MOUNT, 0, s, true);
        return false;
    }
    return true;
}

/* Returned-attributes + one attrreference, all copied to aligned objects.
 * A missing attribute/zero reference is UNKNOWN, never "no ACL".
 * Darwin getattrlist(2) and XNU vfs_attrlist.c require kauth_filesec,
 * NOT bare kauth_acl. Keep omission, NOACL and invalid wire data distinct.
 */
static int
parse_acl(const unsigned char *bytes, size_t capacity, uint32_t *count)
{
    uint32_t length;
    attribute_set_t returned;
    attrreference_t ref;
    const size_t pos = sizeof(length) + sizeof(returned);
    const size_t fixed = pos + sizeof(ref);
    const size_t header = offsetof(struct kauth_filesec, fsec_acl) +
                          offsetof(struct kauth_acl, acl_ace);
    struct kauth_filesec security;
    if (capacity < pos)
        return XC_ACL_INVALID;
    memcpy(&length, bytes, sizeof(length));
    memcpy(&returned, bytes + sizeof(length), sizeof(returned));
    if (length > capacity || length < pos ||
        !(returned.commonattr & ATTR_CMN_RETURNED_ATTRS) ||
        (returned.commonattr & ~(ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_EXTENDED_SECURITY)) ||
        returned.volattr || returned.dirattr || returned.fileattr || returned.forkattr)
        return XC_ACL_INVALID;
    if (!(returned.commonattr & ATTR_CMN_EXTENDED_SECURITY))
        return XC_ACL_MISSING; /* no attrreference is packed in this case */
    if (length < fixed)
        return XC_ACL_INVALID;
    memcpy(&ref, bytes + pos, sizeof(ref));
    if (ref.attr_dataoffset < (int32_t)sizeof(ref))
        return XC_ACL_INVALID;
    size_t offset = pos + (size_t)ref.attr_dataoffset;
    if (offset > length || ref.attr_length > length - offset ||
        ref.attr_length < header)
        return XC_ACL_INVALID;
    memset(&security, 0, sizeof(security));
    memcpy(&security, bytes + offset, header);
    if (security.fsec_magic != KAUTH_FILESEC_MAGIC)
        return XC_ACL_INVALID;
    if (security.fsec_entrycount == KAUTH_FILESEC_NOACL)
        return ref.attr_length == header ? XC_ACL_NOACL : XC_ACL_INVALID;
    if (security.fsec_entrycount > KAUTH_ACL_MAX_ENTRIES)
        return XC_ACL_INVALID;
    size_t needed = header + (size_t)security.fsec_entrycount * sizeof(struct kauth_ace);
    if (needed != ref.attr_length)
        return XC_ACL_INVALID;
    *count = security.fsec_entrycount;
    return XC_ACL_OK;
}

static void
acl_observe(struct scan *c, int parent, const char *name, int fd,
            const struct stat *s)
{
    uint32_t count = 0;
    int error = 0;
    if (!S_ISDIR(s->st_mode)) {
        struct attrlist attrs = {0};
        attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
        attrs.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_EXTENDED_SECURITY;
        memset(c->acl, 0, sizeof(c->acl));
        int decoded = XC_ACL_OK;
        int status = getattrlistat(parent, name, &attrs, c->acl, c->limits.acl_bytes,
                                   FSOPT_NOFOLLOW);
        if (status != 0) {
            error = errno;
            ++c->r->acl_query_errors;
        } else {
            decoded = parse_acl(c->acl, c->limits.acl_bytes, &count);
            if (decoded == XC_ACL_MISSING) ++c->r->acl_omitted;
            else if (decoded == XC_ACL_NOACL) ++c->r->acl_noacl;
            else if (decoded == XC_ACL_INVALID) ++c->r->acl_invalid;
        }
        if (status != 0 || decoded != XC_ACL_OK) {
            ++c->r->acl_unknown;
            issue(c, S_ISLNK(s->st_mode) ? XC_SYMLINK_ACL : XC_METADATA,
                  error, s, false);
            return;
        }
    } else {
        /* libSystem's ACL object has ACL_MAX_ENTRIES fixed slots. Do not
         * interpret NULL, including errno==0/ENOENT/ENOTSUP, as an empty ACL. */
        if (c->limits.acl_bytes < XC_ACL_BYTES) {
            ++c->r->acl_unknown;
            issue(c, XC_METADATA, ERANGE, s, false);
            return;
        }
        errno = 0;
        acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
        if (!acl) {
            ++c->r->acl_unknown;
            issue(c, XC_METADATA, errno, s, false);
            return;
        }
        acl_entry_t entry;
        /* Darwin returns 0 for an entry, -1/EINVAL at end, NOT POSIX's 1/0.
         * acl_valid checks the object header, not ACE policy semantics. */
        if (acl_valid(acl) != 0)
            error = EINVAL;
        errno = 0;
        int result = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry);
        while (!error && result == 0) {
            if (++count > KAUTH_ACL_MAX_ENTRIES) {
                error = EOVERFLOW;
                break;
            }
            errno = 0;
            result = acl_get_entry(acl, ACL_NEXT_ENTRY, &entry);
        }
        if (!error && (result != -1 || errno != EINVAL))
            error = EINVAL;
        (void)acl_free(acl);
        if (error) {
            ++c->r->acl_unknown;
            issue(c, XC_METADATA, error, s, false);
            return;
        }
    }
    c->r->acl_entries += count;
    if (count) ++c->r->acl_present;
    else ++c->r->acl_empty;
}

static void
link_observe(struct scan *c, int parent, const char *name,
             const struct stat *s, unsigned depth)
{
    ssize_t n = readlinkat(parent, name, c->target, sizeof(c->target));
    if (n <= 0 || (size_t)n >= sizeof(c->target)) {
        issue(c, XC_METADATA, n < 0 ? errno : ERANGE, s, false);
        return;
    }
    c->target[n] = '\0';
    if (c->target[0] == '/') {
        ++c->r->symlink_absolute;
        return;
    }
    /* Lexical classification only. A cycle is simply a relative string;
     * in-bundle lexical strings may still traverse other escaping symlinks. */
    unsigned level = depth > 0 ? depth - 1 : 0;
    const char *p = c->target;
    bool escape = false;
    while (*p) {
        while (*p == '/') ++p;
        const char *end = p;
        while (*end && *end != '/') ++end;
        size_t len = (size_t)(end - p);
        if (len == 2 && p[0] == '.' && p[1] == '.') {
            if (level == 0) escape = true;
            else --level;
        } else if (len && !(len == 1 && p[0] == '.')) {
            ++level;
        }
        p = end;
    }
    if (escape) ++c->r->symlink_escape;
    else ++c->r->symlink_relative;
}

static bool visit(struct scan *, int, const char *, unsigned, const struct statfs *);

static bool
directory(struct scan *c, int parent, const char *name, int fd, unsigned depth,
          const struct stat *s, const struct stat *ps, const struct statfs *fs)
{
    /* fdopendir owns fd on success; caller always accounts for exactly one FD. */
    DIR *dir = fdopendir(fd);
    if (!dir) {
        issue(c, XC_IO, errno, s, true);
        (void)close(fd);
        return false;
    }
    bool all = true;
    size_t prefix = strlen(c->path);
    while (tick(c)) {
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) {
            if (errno) {
                issue(c, XC_IO, errno, s, true);
                all = false;
            }
            break;
        }
        size_t n = strnlen(entry->d_name, sizeof(entry->d_name));
        if (n == 0 || n == sizeof(entry->d_name) || n != entry->d_namlen ||
            strchr(entry->d_name, '/')) {
            issue(c, XC_METADATA, EINVAL, s, true);
            all = false;
            break;
        }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
            continue;
        if (prefix + 1 + n >= sizeof(c->path)) {
            issue(c, XC_PATH_LIMIT, 0, s, true);
            all = false;
            break;
        }
        c->path[prefix] = '/';
        memcpy(c->path + prefix + 1, entry->d_name, n + 1);
        /* Copy the name: recursive readdir must not invalidate a parent entry. */
        char child[sizeof(entry->d_name)];
        memcpy(child, entry->d_name, n + 1);
        if (!visit(c, fd, child, depth + 1, fs))
            all = false;
        c->path[prefix] = '\0';
    }
#ifdef XC_FIXTURE
    if (c->hook)
        c->hook(XC_DIRECTORY_END, parent, name, fd, NULL, c->hook_arg);
#endif
    if (!recheck(c, parent, name, fd, s, ps))
        all = false;
    struct statfs endfs;
    if (fstatfs(fd, &endfs) < 0 ||
        memcmp(&endfs.f_fsid, &fs->f_fsid, sizeof(fs->f_fsid)) ||
        endfs.f_flags != fs->f_flags || endfs.f_type != fs->f_type) {
        issue(c, XC_CHANGED, 0, s, true);
        all = false;
    }
    if (closedir(dir) < 0) {
        issue(c, XC_IO, errno, s, true);
        all = false;
    }
    return all && !c->stop;
}

static bool
visit(struct scan *c, int parent, const char *name, unsigned depth,
      const struct statfs *expected)
{
    struct stat s, ps;
    if (!tick(c))
        return false;
    if (c->r->entries >= c->limits.entries) {
        issue(c, XC_ENTRY_LIMIT, 0, NULL, true);
        return false;
    }
    if (depth > c->limits.depth) {
        issue(c, XC_DEPTH_LIMIT, 0, NULL, true);
        return false;
    }
    if (depth > c->r->peak_depth)
        c->r->peak_depth = depth;
    if (fstat(parent, &ps) < 0 ||
        fstatat(parent, name, &s, AT_SYMLINK_NOFOLLOW) < 0) {
        issue(c, XC_IO, errno, NULL, true);
        return false;
    }
    observe(c, &s);
    if (c->stop)
        return false;
    if (depth == 0 && !S_ISDIR(s.st_mode)) {
        issue(c, XC_METADATA, ENOTDIR, &s, true);
        return false;
    }
    if (!S_ISDIR(s.st_mode) && !S_ISREG(s.st_mode) && !S_ISLNK(s.st_mode)) {
        issue(c, XC_SPECIAL, 0, &s, false);
        (void)recheck(c, parent, name, -1, &s, &ps);
        return true; /* visited, but incomplete metadata and nonzero result */
    }
    if (s.st_dev != ps.st_dev && expected) {
        ++c->r->mount_crossings;
        issue(c, XC_MOUNT, 0, &s, true);
        return false;
    }
    if (!S_ISDIR(s.st_mode)) {
        if (!recheck(c, parent, name, -1, &s, &ps))
            return false;
#ifdef XC_FIXTURE
        if (c->hook)
            c->hook(XC_BEFORE_METADATA, parent, name, -1, NULL, c->hook_arg);
#endif
        if (S_ISLNK(s.st_mode))
            link_observe(c, parent, name, &s, depth);
        acl_observe(c, parent, name, -1, &s);
#ifdef XC_FIXTURE
        if (c->hook)
            c->hook(XC_AFTER_METADATA, parent, name, -1, NULL, c->hook_arg);
#endif
        return recheck(c, parent, name, -1, &s, &ps);
    }
    if (!reserve_fd(c))
        return false;
#ifdef XC_FIXTURE
    if (c->hook)
        c->hook(XC_BEFORE_OPEN, parent, name, -1, NULL, c->hook_arg);
#endif
    int fd = directory_open(c, parent, name);
    bool all = false;
    if (fd < 0) {
        issue(c, XC_IO, errno, &s, true);
        --c->fds;
        return false;
    }
#ifdef XC_FIXTURE
    if (c->hook)
        c->hook(XC_AFTER_OPEN, parent, name, fd, NULL, c->hook_arg);
#endif
    struct statfs fs;
    if (recheck(c, parent, name, fd, &s, &ps) &&
        filesystem(c, parent, name, fd, &s, expected, &fs)) {
        acl_observe(c, parent, name, fd, &s);
        all = directory(c, parent, name, fd, depth, &s, &ps, &fs);
        fd = -1;
    }
    if (fd >= 0 && close(fd) < 0) {
        issue(c, XC_IO, errno, &s, true);
        all = false;
    }
    --c->fds;
    return all && tick(c);
}

static bool
initialize(struct scan *c, struct xc_report *r)
{
    memset(c, 0, sizeof(*c));
    memset(r, 0, sizeof(*r));
    c->r = r;
    c->limits = ceilings;
    strcpy(c->path, ".");
    if (getuid() == 0 || geteuid() == 0) {
        issue(c, XC_ROOT, 0, NULL, true);
        return false;
    }
    if (clock_gettime(CLOCK_MONOTONIC, &c->start) < 0) {
        issue(c, XC_IO, errno, NULL, true);
        return false;
    }
    return true;
}

int
xc_fixed(struct xc_report *r)
{
    static struct scan c;
    struct stat root_stat, apps_stat, root_parent, root_name;
    struct statfs root_fs, apps_fs;
    int root = -1, apps = -1;
    if (!initialize(&c, r) || !reserve_fd(&c))
        return -1;
    /* "/" has no mutable lexical ancestor. Subsequent names are single
     * components; directory acquisition appends the fixed lookup suffix "/.". */
    if (fstatat(AT_FDCWD, "/", &root_name, AT_SYMLINK_NOFOLLOW) < 0 ||
        !S_ISDIR(root_name.st_mode)) {
        issue(&c, XC_METADATA, 0, NULL, true);
        goto done;
    }
    root = directory_open(&c, AT_FDCWD, "/");
    if (root < 0 || fstat(root, &root_stat) < 0 ||
        fstatat(root, ".", &root_parent, AT_SYMLINK_NOFOLLOW) < 0 ||
        !same(&root_stat, &root_parent) || !same(&root_name, &root_stat)) {
        issue(&c, XC_IO, errno, NULL, true);
        goto done;
    }
    observe(&c, &root_stat);
    if (!filesystem(&c, root, ".", root, &root_stat, NULL, &root_fs))
        goto done;
    acl_observe(&c, root, ".", root, &root_stat);
    c.scope = 1;
    if (fstatat(root, "Applications", &apps_stat, AT_SYMLINK_NOFOLLOW) < 0 ||
        !S_ISDIR(apps_stat.st_mode)) {
        issue(&c, XC_METADATA, 0, NULL, true);
        goto done;
    }
    if (!reserve_fd(&c))
        goto done;
    apps = directory_open(&c, root, "Applications");
    if (apps < 0) {
        issue(&c, XC_IO, errno, &apps_stat, true);
        goto done;
    }
    observe(&c, &apps_stat);
    if (!recheck(&c, root, "Applications", apps, &apps_stat, &root_stat) ||
        !filesystem(&c, root, "Applications", apps, &apps_stat, NULL, &apps_fs))
        goto done;
    if (root_stat.st_dev != apps_stat.st_dev ||
        memcmp(&root_fs.f_fsid, &apps_fs.f_fsid, sizeof(root_fs.f_fsid)))
        ++r->mount_crossings; /* expected ancestor transitions are reported */
    acl_observe(&c, root, "Applications", apps, &apps_stat);
    c.scope = 2;
    r->scanned_all = visit(&c, apps, "Xcode_27.1.app", 0, &apps_fs) ? 1U : 0U;
    c.scope = 1;
    (void)recheck(&c, root, "Applications", apps, &apps_stat, &root_stat);
    c.scope = 0;
    (void)recheck(&c, root, ".", root, &root_stat, &root_parent);
    if (fstatat(AT_FDCWD, "/", &root_name, AT_SYMLINK_NOFOLLOW) < 0 ||
        !same(&root_stat, &root_name))
        issue(&c, XC_CHANGED, 0, &root_stat, true);
    struct statfs endfs;
    if (fstatfs(root, &endfs) < 0 ||
        memcmp(&endfs.f_fsid, &root_fs.f_fsid, sizeof(root_fs.f_fsid)) ||
        endfs.f_flags != root_fs.f_flags || endfs.f_type != root_fs.f_type ||
        fstatfs(apps, &endfs) < 0 ||
        memcmp(&endfs.f_fsid, &apps_fs.f_fsid, sizeof(apps_fs.f_fsid)) ||
        endfs.f_flags != apps_fs.f_flags || endfs.f_type != apps_fs.f_type)
        issue(&c, XC_CHANGED, 0, NULL, true);
done:
    if (apps >= 0 && close(apps) < 0)
        issue(&c, XC_IO, errno, NULL, true);
    if (root >= 0 && close(root) < 0)
        issue(&c, XC_IO, errno, NULL, true);
    (void)tick(&c);
    return r->errors ? -1 : 0;
}

#ifdef XC_FIXTURE
int
xc_fixture(int rootfd, const struct xc_limits *limits, xc_hook hook, void *arg,
           struct xc_report *r)
{
    static struct scan c;
    if (!initialize(&c, r))
        return -1;
    if (limits) {
        /* Tests can lower ceilings only; this seam is absent in production. */
#define LOWER(field) if (limits->field < c.limits.field) c.limits.field = limits->field
        LOWER(entries); LOWER(depth); LOWER(fds); LOWER(memory);
        LOWER(seconds); LOWER(acl_bytes);
#undef LOWER
    }
    c.hook = hook;
    c.hook_arg = arg;
    c.scope = 2;
    if (!reserve_fd(&c)) /* account for caller's held fixture root */
        return -1;
    r->scanned_all = visit(&c, rootfd, ".", 0, NULL) ? 1U : 0U;
    return r->errors ? -1 : 0;
}

int
xc_test_acl(const unsigned char *bytes, size_t capacity, uint32_t *count)
{
    return parse_acl(bytes, capacity, count);
}

int
xc_test_output(const struct xc_report *r, unsigned limit)
{
    static struct output o;
    return serialize(r, &o, limit);
}
#endif
#else
int
xc_fixed(struct xc_report *r)
{
    xc_refuse(r, XC_PLATFORM);
    return -1;
}
#endif
