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
    "output_budget", "hardlink_accounting_budget"
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
static struct output output_scratch; /* emit and fixture serialization are sequential */

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

static void
capacity_output(struct output *o, const struct xc_capacity *p, uint64_t samples)
{
    if (!samples) {
        append(o, "null");
        return;
    }
    append(o, "{\"f_bsize\":%" PRIu64 ",\"f_blocks\":%" PRIu64
           ",\"f_bfree\":%" PRIu64 ",\"f_bavail\":%" PRIu64 ",\"bytes\":",
           p->bsize, p->blocks, p->bfree, p->bavail);
    if (p->bytes_valid)
        append(o, "{\"total\":%" PRIu64 ",\"free\":%" PRIu64
               ",\"available\":%" PRIu64 "}", p->total_bytes,
               p->free_bytes, p->available_bytes);
    else
        append(o, "null");
    append(o, "}");
}

static int
serialize(const struct xc_report *r, struct output *o, unsigned limit)
{
    memset(o, 0, sizeof(*o));
    o->limit = limit <= XC_OUTPUT ? limit : XC_OUTPUT;
    if (o->limit == 0)
        return -1;
    append(o, "{\"schema\":2,\"role\":\"unauthenticated_read_only_layout\","
           "\"complete\":%s,\"scanned_all\":%s,\"error\":",
           r->errors ? "false" : "true", r->scanned_all ? "true" : "false");
    quoted(o, error_names[r->first_error <= XC_LINK_LIMIT ?
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
    const struct xc_links *l = &r->regular_links;
    append(o, ",\"regular_links\":{\"groups\":%u,\"encountered\":%" PRIu64
           ",\"recorded\":%" PRIu64 ",\"reported_first_nlink_sum\":%" PRIu64
           ",\"below\":%" PRIu64 ",\"equal\":%" PRIu64 ",\"above\":%" PRIu64
           ",\"inconsistent_groups\":%" PRIu64 ",\"inconsistent_observations\":%" PRIu64
           ",\"reported_link_deficit\":%" PRIu64 ",\"unrecorded_observed_entries\":%" PRIu64
           ",\"exhausted\":%s,\"accounting_complete\":%s,\"containment_proven\":false}",
           l->groups, l->encountered, l->recorded, l->reported, l->below,
           l->equal, l->above, l->inconsistent_groups, l->inconsistent_observations,
           l->reported_deficit, l->unrecorded, l->exhausted ? "true" : "false",
           l->accounting_complete ? "true" : "false");
    append(o, ",\"peak_fds\":%u,\"peak_depth\":%u,\"ceilings\":{"
           "\"entries\":%u,\"depth\":%u,\"fds\":%u,\"memory_bytes\":%u,"
           "\"acl_bytes\":%u,\"seconds\":%u,\"output_bytes\":%u,"
           "\"samples\":%u,\"groups\":%u,\"mounts\":%u,\"path_bytes\":%u,"
           "\"link_records\":%u,\"link_slots\":%u,\"link_probes\":%u,"
           "\"transitions\":%u},"
           "\"groups\":[", r->peak_fds, r->peak_depth, XC_ENTRIES, XC_DEPTH,
           XC_FDS, XC_MEMORY, XC_ACL_BYTES, XC_SECONDS, XC_OUTPUT, XC_SAMPLES,
           XC_GROUPS, XC_MOUNTS, XC_PATH, XC_LINK_RECORDS, XC_LINK_SLOTS,
           XC_LINK_PROBES, XC_MOUNTS);
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
               "],\"type\":%u,\"flags\":%u,\"boundary\":%u,"
               "\"initial_samples\":%" PRIu64 ",\"final_samples\":%" PRIu64
               ",\"initial\":", i ? "," : "", m->device,
               m->fsid[0], m->fsid[1], m->type, m->flags, m->boundary,
               m->initial_samples, m->final_samples);
        capacity_output(o, &m->initial, m->initial_samples);
        append(o, ",\"final\":");
        capacity_output(o, &m->final, m->final_samples);
        append(o, "}");
    }
    append(o, "],\"mount_transitions\":[");
    for (unsigned i = 0; i < r->transitions_used; ++i) {
        const struct xc_transition *t = &r->transitions[i];
        append(o, "%s{\"from_device\":%" PRId64 ",\"from_fsid\":[%" PRId32
               ",%" PRId32 "],\"from_type\":%u,\"to_mount\":%u,\"count\":%" PRIu64 "}",
               i ? "," : "", t->from_device, t->from_fsid[0], t->from_fsid[1],
               t->from_type, t->to_mount, t->count);
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
    struct output *o = &output_scratch;
    static const char fallback[] =
        "{\"schema\":2,\"complete\":false,\"error\":\"output_budget\"}\n";
    int failed = serialize(r, o, XC_OUTPUT);
    const char *p = failed ? fallback : o->bytes;
    size_t left = failed ? sizeof(fallback) - 1 : o->used;
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
struct link_record {
    struct stat first; /* compared explicitly by same(), never by padding */
    int32_t fsid[2];
    uint32_t type, flags;
    uint64_t seen;
    unsigned inconsistent;
};

struct scan {
    struct xc_report *r;
    struct xc_limits limits;
    struct timespec start;
    unsigned fds, scope;
    int stop;
    bool active;
    char path[XC_PATH];
    unsigned char acl[XC_ACL_BYTES];
    char target[XC_PATH];
    struct link_record links[XC_LINK_RECORDS];
    uint32_t slots[XC_LINK_SLOTS]; /* zero empty, otherwise record index + 1 */
#ifdef XC_FIXTURE
    unsigned link_records, link_slots, link_probes;
    int collide;
    xc_hook hook;
    void *hook_arg;
#endif
};
/* Single-threaded entrypoints share ONE retained scanner, including fixtures.
 * initialize rejects nested calls before touching either scratch or report. */
static struct scan scan_scratch;

static const struct xc_limits ceilings = {
    XC_ENTRIES, XC_DEPTH, XC_FDS, XC_MEMORY, XC_SECONDS, XC_ACL_BYTES
};
_Static_assert(sizeof(scan_scratch) + sizeof(struct xc_report) +
               sizeof(output_scratch) + XC_FDS * FD_MEMORY < XC_MEMORY,
               "fixed allocations and descriptor reservations exceed memory cap");
_Static_assert(XC_LINK_RECORDS < UINT32_MAX && XC_LINK_RECORDS <= XC_LINK_SLOTS &&
               (XC_LINK_SLOTS & (XC_LINK_SLOTS - 1U)) == 0 &&
               XC_LINK_PROBES <= XC_LINK_SLOTS &&
               XC_LINK_RECORDS <= SIZE_MAX / sizeof(struct link_record) &&
               XC_LINK_SLOTS <= SIZE_MAX / sizeof(uint32_t),
               "invalid hardlink table sizing");
_Static_assert(sizeof(((struct stat *)0)->st_nlink) <= sizeof(uint32_t) &&
               XC_LINK_RECORDS <= UINT64_MAX / UINT32_MAX,
               "reported link sums must fit uint64_t");
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
    size_t memory = sizeof(scan_scratch) + sizeof(*c->r) + sizeof(output_scratch) +
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

/* Unsigned mixing has intentional modulo-2^64 wrap, unlike capacity math. */
static uint64_t
mix(uint64_t x)
{
    x ^= x >> 30;
    x *= UINT64_C(0xbf58476d1ce4e5b9);
    x ^= x >> 27;
    x *= UINT64_C(0x94d049bb133111eb);
    return x ^ (x >> 31);
}

static void
account_link(struct scan *c, const struct stat *s, const struct statfs *fs)
{
    if (!S_ISREG(s->st_mode))
        return;
    struct xc_links *l = &c->r->regular_links;
    unsigned records = XC_LINK_RECORDS, slots = XC_LINK_SLOTS, probes = XC_LINK_PROBES;
#ifdef XC_FIXTURE
    records = c->link_records; slots = c->link_slots; probes = c->link_probes;
#endif
    uint64_t hash = mix((uint64_t)s->st_ino) ^ mix((uint64_t)s->st_dev) ^
        mix((uint32_t)fs->f_fsid.val[0]) ^
        mix((uint64_t)(uint32_t)fs->f_fsid.val[1] << 32) ^ mix(fs->f_type);
#ifdef XC_FIXTURE
    if (c->collide) hash = 0;
#endif
    for (unsigned n = 0; n < probes && n < slots; ++n) {
        if (!tick(c))
            return;
        unsigned slot = (unsigned)((hash + n) % slots);
        uint32_t index = c->slots[slot];
        if (!index) {
            if (s->st_nlink <= 1)
                return; /* singles are not retained; still look up prior groups */
            if (l->groups >= records)
                break;
            struct link_record *p = &c->links[l->groups];
            p->first = *s;
            p->fsid[0] = fs->f_fsid.val[0]; p->fsid[1] = fs->f_fsid.val[1];
            p->type = fs->f_type; p->flags = fs->f_flags;
            p->seen = 1;
            c->slots[slot] = ++l->groups;
            ++l->recorded;
            --l->unrecorded; /* observe counted this multiply-linked entry */
            return;
        }
        struct link_record *p = &c->links[index - 1];
        if (p->first.st_dev != s->st_dev || p->first.st_ino != s->st_ino ||
            p->fsid[0] != fs->f_fsid.val[0] || p->fsid[1] != fs->f_fsid.val[1] ||
            p->type != fs->f_type)
            continue;
        ++p->seen;
        ++l->recorded;
        if (s->st_nlink > 1)
            --l->unrecorded; /* single-link repeats never incremented it */
        if (!same(&p->first, s) || p->flags != fs->f_flags ||
            p->seen > p->first.st_nlink) {
            ++l->inconsistent_observations;
            if (!p->inconsistent)
                ++l->inconsistent_groups;
            p->inconsistent = 1;
            issue(c, XC_CHANGED, 0, s, false);
        }
        return;
    }
    l->exhausted = 1;
    issue(c, XC_LINK_LIMIT, 0, s, true);
}

static void
finish_links(struct scan *c)
{
    struct xc_links *l = &c->r->regular_links;
    /* At most 16384 records, no syscalls/search here. Even stopped scans get
     * provisional aggregates; the absolute deadline is checked afterwards. */
    for (unsigned i = 0; i < l->groups; ++i) {
        const struct link_record *p = &c->links[i];
        uint64_t reported = p->first.st_nlink;
        l->reported += reported;
        if (p->seen < reported) {
            ++l->below;
            l->reported_deficit += reported - p->seen;
        } else if (p->seen == reported) ++l->equal;
        else ++l->above;
    }
    l->accounting_complete = tick(c) && c->r->scanned_all &&
        !l->exhausted && !l->inconsistent_observations && !l->unrecorded ? 1U : 0U;
}

static bool
capacity_bytes(uint64_t size, uint64_t blocks, uint64_t *bytes)
{
    if (!size || blocks > UINT64_MAX / size)
        return false;
    *bytes = size * blocks;
    return true;
}

static bool
same_fs(const struct statfs *a, const struct statfs *b)
{
    return !memcmp(&a->f_fsid, &b->f_fsid, sizeof(a->f_fsid)) &&
        a->f_type == b->f_type;
}

static bool
mount_observe(struct scan *c, const struct stat *s, const struct statfs *fs,
              const struct statfs *expected, int64_t parent_device,
              unsigned boundary, bool final)
{
    bool crossing = expected && (parent_device != s->st_dev || !same_fs(fs, expected));
    if (crossing && !final)
        ++c->r->mount_crossings;
    unsigned i;
    for (i = 0; i < c->r->mounts_used; ++i) {
        const struct xc_mount *m = &c->r->mounts[i];
        if (m->device == s->st_dev && m->fsid[0] == fs->f_fsid.val[0] &&
            m->fsid[1] == fs->f_fsid.val[1] && m->type == fs->f_type &&
            m->flags == fs->f_flags && m->boundary == boundary)
            break;
    }
    if (i == XC_MOUNTS) {
        issue(c, XC_GROUP_LIMIT, 0, s, true);
        return false;
    }
    if (i == c->r->mounts_used)
        c->r->mounts[c->r->mounts_used++] = (struct xc_mount) {
            .device = s->st_dev, .fsid = {fs->f_fsid.val[0], fs->f_fsid.val[1]},
            .type = fs->f_type, .flags = fs->f_flags, .boundary = boundary
        };
    struct xc_mount *m = &c->r->mounts[i];
    struct xc_capacity capacity = {
        .bsize = fs->f_bsize, .blocks = fs->f_blocks,
        .bfree = fs->f_bfree, .bavail = fs->f_bavail
    };
    capacity.bytes_valid =
        capacity_bytes(capacity.bsize, capacity.blocks, &capacity.total_bytes) &&
        capacity_bytes(capacity.bsize, capacity.bfree, &capacity.free_bytes) &&
        capacity_bytes(capacity.bsize, capacity.bavail, &capacity.available_bytes) ? 1U : 0U;
    if (final) {
        ++m->final_samples;
        m->final = capacity;
    } else if (m->initial_samples++ == 0) {
        m->initial = capacity;
    }
    if (!capacity.bytes_valid)
        issue(c, XC_METADATA, EOVERFLOW, s, true);
    if (crossing && !final) {
        unsigned j;
        for (j = 0; j < c->r->transitions_used; ++j) {
            const struct xc_transition *t = &c->r->transitions[j];
            if (t->from_device == parent_device && t->to_mount == i &&
                t->from_fsid[0] == expected->f_fsid.val[0] &&
                t->from_fsid[1] == expected->f_fsid.val[1] &&
                t->from_type == expected->f_type)
                break;
        }
        if (j == XC_MOUNTS) {
            issue(c, XC_GROUP_LIMIT, 0, s, true);
            return false;
        }
        if (j == c->r->transitions_used)
            c->r->transitions[c->r->transitions_used++] = (struct xc_transition) {
                .from_device = parent_device, .to_mount = i,
                .from_fsid = {expected->f_fsid.val[0], expected->f_fsid.val[1]},
                .from_type = expected->f_type
            };
        ++c->r->transitions[j].count;
    }
    /* / -> Applications is observable, not an internal bundle crossing. */
    if (!final && ((crossing && boundary >= XC_FS_BUNDLE) ||
        (fs->f_flags & MNT_UNION) || !(fs->f_flags & MNT_LOCAL) ||
        strcmp(fs->f_fstypename, "apfs") != 0))
        issue(c, XC_MOUNT, 0, s, true);
    return !c->stop;
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
    if (S_ISREG(s->st_mode) && s->st_nlink > 1) {
        ++r->regular_links.encountered;
        ++r->regular_links.unrecorded; /* remains pending across any refusal */
    }
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
           int64_t parent_device, unsigned boundary, struct statfs *fs)
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
    return mount_observe(c, s, fs, expected, parent_device, boundary, false);
}

static bool
filesystem_end(struct scan *c, int parent, const char *name, int fd,
               const struct stat *s, const struct statfs *initial, unsigned boundary)
{
    struct statfs final;
    if (fstatfs(fd, &final) < 0) {
        issue(c, XC_METADATA, errno, s, true);
        return false;
    }
#ifdef XC_FIXTURE
    if (c->hook)
        c->hook(XC_FILESYSTEM_END, parent, name, fd, &final, c->hook_arg);
#else
    (void)parent; (void)name;
#endif
    (void)mount_observe(c, s, &final, NULL, 0, boundary, true);
    if (!same_fs(&final, initial) || final.f_flags != initial->f_flags)
        issue(c, XC_CHANGED, 0, s, true);
    return !c->stop;
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
    if (!filesystem_end(c, parent, name, fd, s, fs,
                        depth == 0 ? XC_FS_BUNDLE : XC_FS_DESCENDANT))
        all = false;
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
    if (!S_ISDIR(s.st_mode) && s.st_dev != ps.st_dev && expected) {
        ++c->r->mount_crossings;
        issue(c, XC_MOUNT, 0, &s, true);
        return false;
    }
    if (!S_ISDIR(s.st_mode)) {
        if (expected)
            account_link(c, &s, expected);
        if (c->stop)
            return false;
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
        filesystem(c, parent, name, fd, &s, expected, ps.st_dev,
                   depth == 0 ? XC_FS_BUNDLE : XC_FS_DESCENDANT, &fs)) {
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
    if (c->active) {
        errno = EBUSY;
        return false; /* even an aliased active report must remain untouched */
    }
    memset(c, 0, sizeof(*c));
    memset(r, 0, sizeof(*r));
    c->active = true;
    c->r = r;
    c->limits = ceilings;
#ifdef XC_FIXTURE
    c->link_records = XC_LINK_RECORDS;
    c->link_slots = XC_LINK_SLOTS;
    c->link_probes = XC_LINK_PROBES;
#endif
    strcpy(c->path, ".");
    if (getuid() == 0 || geteuid() == 0) {
        issue(c, XC_ROOT, 0, NULL, true);
        c->active = false;
        return false;
    }
    if (clock_gettime(CLOCK_MONOTONIC, &c->start) < 0) {
        issue(c, XC_IO, errno, NULL, true);
        c->active = false;
        return false;
    }
    return true;
}

int
xc_fixed(struct xc_report *r)
{
    struct scan *c = &scan_scratch;
    struct stat root_stat, apps_stat, root_parent, root_name;
    struct statfs root_fs, apps_fs;
    int root = -1, apps = -1;
    if (!initialize(c, r))
        return -1;
    if (!reserve_fd(c))
        goto done;
    /* "/" has no mutable lexical ancestor. Subsequent names are single
     * components; directory acquisition appends the fixed lookup suffix "/.". */
    if (fstatat(AT_FDCWD, "/", &root_name, AT_SYMLINK_NOFOLLOW) < 0 ||
        !S_ISDIR(root_name.st_mode)) {
        issue(c, XC_METADATA, 0, NULL, true);
        goto done;
    }
    root = directory_open(c, AT_FDCWD, "/");
    if (root < 0 || fstat(root, &root_stat) < 0 ||
        fstatat(root, ".", &root_parent, AT_SYMLINK_NOFOLLOW) < 0 ||
        !same(&root_stat, &root_parent) || !same(&root_name, &root_stat)) {
        issue(c, XC_IO, errno, NULL, true);
        goto done;
    }
    observe(c, &root_stat);
    if (!filesystem(c, root, ".", root, &root_stat, NULL, 0, XC_FS_ROOT, &root_fs))
        goto done;
    acl_observe(c, root, ".", root, &root_stat);
    c->scope = 1;
    if (fstatat(root, "Applications", &apps_stat, AT_SYMLINK_NOFOLLOW) < 0 ||
        !S_ISDIR(apps_stat.st_mode)) {
        issue(c, XC_METADATA, 0, NULL, true);
        goto done;
    }
    if (!reserve_fd(c))
        goto done;
    apps = directory_open(c, root, "Applications");
    if (apps < 0) {
        issue(c, XC_IO, errno, &apps_stat, true);
        goto done;
    }
    observe(c, &apps_stat);
    if (!recheck(c, root, "Applications", apps, &apps_stat, &root_stat) ||
        !filesystem(c, root, "Applications", apps, &apps_stat, &root_fs,
                    root_stat.st_dev, XC_FS_APPLICATIONS, &apps_fs))
        goto done;
    acl_observe(c, root, "Applications", apps, &apps_stat);
    c->scope = 2;
    r->scanned_all = visit(c, apps, "Xcode_27.1.app", 0, &apps_fs) ? 1U : 0U;
    c->scope = 1;
    (void)recheck(c, root, "Applications", apps, &apps_stat, &root_stat);
    (void)filesystem_end(c, root, "Applications", apps, &apps_stat, &apps_fs,
                         XC_FS_APPLICATIONS);
    c->scope = 0;
    (void)recheck(c, root, ".", root, &root_stat, &root_parent);
    (void)filesystem_end(c, root, ".", root, &root_stat, &root_fs, XC_FS_ROOT);
    if (fstatat(AT_FDCWD, "/", &root_name, AT_SYMLINK_NOFOLLOW) < 0 ||
        !same(&root_stat, &root_name))
        issue(c, XC_CHANGED, 0, &root_stat, true);
done:
    if (apps >= 0 && close(apps) < 0)
        issue(c, XC_IO, errno, NULL, true);
    if (root >= 0 && close(root) < 0)
        issue(c, XC_IO, errno, NULL, true);
    finish_links(c);
    c->active = false;
    return r->errors ? -1 : 0;
}

#ifdef XC_FIXTURE
int
xc_fixture(int rootfd, const struct xc_limits *limits, xc_hook hook, void *arg,
           struct xc_report *r)
{
    struct scan *c = &scan_scratch;
    if (!initialize(c, r))
        return -1;
    if (limits) {
        /* Tests can lower ceilings only; this seam is absent in production. */
#define LOWER(field) if (limits->field < c->limits.field) c->limits.field = limits->field
        LOWER(entries); LOWER(depth); LOWER(fds); LOWER(memory);
        LOWER(seconds); LOWER(acl_bytes);
#undef LOWER
    }
    c->hook = hook;
    c->hook_arg = arg;
    c->scope = 2;
    if (reserve_fd(c)) /* account for caller's held fixture root */
        r->scanned_all = visit(c, rootfd, ".", 0, NULL) ? 1U : 0U;
    finish_links(c);
    c->active = false;
    return r->errors ? -1 : 0;
}

void
xc_test_links(const struct stat *stats, const struct statfs *fs, size_t count,
              unsigned records, unsigned slots, unsigned probes, int all,
              struct xc_report *r)
{
    struct scan *c = &scan_scratch;
    if (!initialize(c, r))
        return;
    if (!reserve_fd(c))
        goto done;
    c->link_records = records < XC_LINK_RECORDS ? records : XC_LINK_RECORDS;
    c->link_slots = slots < XC_LINK_SLOTS ? slots : XC_LINK_SLOTS;
    c->link_probes = probes < XC_LINK_PROBES ? probes : XC_LINK_PROBES;
    c->collide = 1; /* synthetic collisions only; no production controls */
    size_t i;
    for (i = 0; i < count && i < XC_ENTRIES && !c->stop; ++i) {
        observe(c, &stats[i]);
        account_link(c, &stats[i], &fs[i]);
    }
    r->scanned_all = all && i == count && !c->stop ? 1U : 0U;
done:
    finish_links(c);
    c->active = false;
}

int
xc_test_capacity(uint64_t size, uint64_t blocks, uint64_t *bytes)
{
    return capacity_bytes(size, blocks, bytes) ? 0 : -1;
}

void
xc_test_mounts(const struct statfs *fs, const int64_t *devices,
               const unsigned *boundaries, size_t count, struct xc_report *r)
{
    struct scan *c = &scan_scratch;
    if (!initialize(c, r))
        return;
    if (!reserve_fd(c))
        goto done;
    for (size_t i = 0; i < count && i < XC_MOUNTS && tick(c); ++i) {
        struct stat s = {0};
        s.st_dev = (dev_t)devices[i];
        (void)mount_observe(c, &s, &fs[i], i ? &fs[i - 1] : NULL,
                            i ? devices[i - 1] : 0, boundaries[i], false);
    }
done:
    c->active = false;
}

int
xc_test_acl(const unsigned char *bytes, size_t capacity, uint32_t *count)
{
    return parse_acl(bytes, capacity, count);
}

int
xc_test_output(const struct xc_report *r, unsigned limit)
{
    return serialize(r, &output_scratch, limit);
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
