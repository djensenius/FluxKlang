# Fixed Xcode read-only census (#710)

Producer 43697825734 passed strict arm64 compilation, 15 fixtures and loader
checks for reviewed `de143300`; the real census was skipped. Its sample fixture
reported 50 unknown symlink ACLs, **not positive ACL completeness**. Producer
43699992495 compiled `f9eb960c` but failed its regular empty-FD oracle before
symlink creation: probe 0 decoded a valid empty ACL, then the getter returned
NULL/ENOENT. Loader inspection/census were skipped. This fixture correction
still requires reviewed hosted validation. No result
authorizes provisioning, hardening, root delivery, bootstrap or iOS launches.
Unauthenticated filesystem metadata is not runtime authority.

## Separate producer

The new `xcode-census-producer.yml` uses the hosted `xcode-27` label and fixed
`DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer`. Relevant PRs
build/test/inspect only. PR source and workflow are the event's merge SHA, **not
default-branch-pinned trusted source**; identity records the actual checkout,
workflow SHA/ref/blob, source hashes and run ID/attempt. SHA-pinned actions do
not make PR source trusted. No secrets, caches, sudo, product setup/tests or
changes to existing observation workflows.

After review, a manual dispatch may explicitly select `run_census` (default
false). This runs exactly one nonroot fixed-path census, not a hardener. Any
fixture, budget, inspection or census failure fails the job. The explicitly
listed artifact files exclude the fixture executable and other workspace
files; each evidence file is <=256 KiB, binary <=2 MiB, total <=4 MiB.
**Do not consume PR-produced artifacts for bootstrap.** Custody, root delivery,
whole-bundle provisioning and bootstrap order remain separate unapproved gates.

Producer-only `producer_capture.py` collects command output through a nonblocking
pipe with a monotonic deadline: 60 seconds for identity/inspection/mocked tests,
90 for hosted process fixtures, 600 for make/fixtures, 660 for census.
Output ceilings remain 128 KiB (256 KiB for make). It owns a new session and
leaves the leader unreaped until pipe EOF
or failure; inherited pipe holders cannot bypass the deadline. On timeout,
overflow or read failure it SIGKILLs only that anchored process group and allows
three seconds to reap, never an unbounded context-manager wait. This assumes a
single child owner/no external reaper and requires default SIGCHLD disposition.
Detached/escaped descendants are not containment-verified; unreaped children
or cleanup errors fail and remain runner-teardown obligations. Spawn/kernel
calls and evidence-file I/O are outside the collector's interruptible waits;
the 40-minute job ceiling leaves room for sequential budgets and uploads.
Partial output is saved before failure (`producer.log`, `census.txt`, or the
last identity/inspection/test `capture.txt`), with the last capture's outcome,
actual exit code, byte count and cleanup status in `capture.json`. A zero leader
exit does not override a pipe timeout or a successful wait returning after the
absolute deadline; an already-reaped leader is never signalled. Failed make exits
stop before JSON validation; successful fixtures still must pass the same JSON escaping gate.

The helper and both fixture sources are included in source identity hashes.
`python3 -B -m unittest discover -s scripts/xcode-census -p test_producer_capture.py`
(from the repository root) runs pure mocked clock/pipe/process tests, without
launching or signalling children or writing evidence. The separate
`hosted_capture_fixtures.py` is not unittest-discoverable and requires the explicit
`--hosted-process-fixtures` argument plus GitHub-hosted macOS/nonroot guards;
ordinary local test commands cannot enable it. These are accidental-execution
guards, not authentication. The producer explicitly runs it under a 90-second
capture ceiling. Its quiet, exited-leader/inherited-pipe and overflow cases use
eight-second deadlines, 1 KiB output caps, real owned Python sessions, and finite
30-second child fallback lifetimes. They verify failure classification, persisted
partial output/status, pre-reap group signalling and actual leader reaping;
owned-file locks check holder resource release without signalling descendant
PIDs. Success removes only named owned temporary files; failure leaves them for
runner teardown. Bounded numeric summaries go to the producer job log (and outer
`capture.txt` on failure). Real process fixtures and native checks have NOT run
locally and still require reviewed hosted execution.

A harness-owned context encloses capture and all validation. On every exit it
uses saved real primitives: only an unreaped leader anchors a group signal,
and saved waits allow three seconds to reap, with one bounded retry after holder
release. Closing a private control pipe requests holder exit even after its
leader was reaped; a separate lifetime-pipe EOF and owned-file lock release must
be observed within five seconds. No stale descendant/group IDs are signalled.
Cleanup has at most eleven seconds of waits per case, independent of capture's
status/cleanup and the child alarm. Capture evidence is never overwritten;
cleanup failures are reported separately without replacing an initial exception
(also attached as exception notes where supported). Failed cleanup cannot pass.
Default mocks cover unexpected capture exceptions, failed termination/reaping,
and cooperative release/timeout after leader reaping; all their process, signal,
pipe, clock, lock and output primitives are mocked before owner construction.

Hosted-only commands, from this directory:

```
make all check
./build/xcode-census
```

Do not execute these locally during this source-only review. Build outputs are
covered by the existing repository `build/` ignore rule. No clean recipe,
recursive deletion or overridable build directory is provided.

## Observation contract

The production entrypoint has no path, environment or behavior overrides and
refuses real/effective UID 0 and non-arm64/non-macOS. It holds `/`, opens the
single `Applications` component, then walks **all** of `Xcode_27.1.app`, never
following symlinks. No file bytes, target strings, host paths, environment dumps,
authority token or permission-changing operations are emitted/executed.

JSON contains aggregate uid/gid/mode/flags/device/link-count groups, mount
fsid/type/flags, ACL counts, lexical symlink classes, hardlink observations and
bounded samples. Scope 0 is `/`, 1 is `/Applications`, 2 is bundle-relative
(`.` is that scope's root). Modes are decimal including file type; path bytes
outside printable ASCII are escaped as `\u00XX`, not normalized as Unicode.
Samples truncate at 159 bytes and explicitly mark truncation. Counts are per
directory entry, **not deduplicated inodes or allocation estimates**.
`scanned_all` means enumeration finished, not that metadata is complete.
`complete` requires no errors; incomplete/changed/budget/error results exit 1.
Hardlinks and symlink cycles/escapes are observations, not loader-closure verdicts.

Only local, non-union APFS is supported. Ancestor mount transitions are recorded;
bundle mount crossings are refused, not traversed. **Regular files and symlinks
are never opened**, even to obtain ACLs/flags: descriptor-relative `fstatat`
and `getattrlistat(FSOPT_NOFOLLOW)` observe names in held directories. Their
device ID must match the parent's; mount identity is associated with that held
parent, not a separately opened non-directory object. Special objects are
reported/rejected without opening them.

Directory acquisition uses `openat(parent, "name/.", O_RDONLY | O_DIRECTORY |
O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)` (`/.` for `/`). The fixed suffix forces
directory lookup before final-component open; NOFOLLOW_ANY rejects even a
replacement symlink to a directory. Held directories and parent/name identities
are rechecked at entry/exit and directory completion, including metadata times
(not atime). Regular/link stat and ACL samples have **no held object FD** and
are only bracketed by name/identity rechecks. These may detect replacement but
cannot bind separate metadata calls to one object under swap-and-restore:
**no atomic snapshot, freeze, revocation, content identity or authority**.

Ceilings in `census.h` are reviewed conservative limits, not measured capacity:
2M entries, depth 64, 72 scanner FDs, 8 MiB accounting budget, 16 KiB ACL scratch,
600 monotonic seconds, 128 KiB JSON, 48 samples, 256 groups, 16 mounts, 4096-byte
paths. One shared scratch area avoids large recursive ACL buffers. Each FD
reserves 64 KiB for stack/libSystem bookkeeping. This is an allocation model,
not an OS RSS limit: dyld/runtime mappings are outside it. Time checks occur
between calls, not inside a stalled kernel call or output write; the hosted
40-minute job timeout is the outer bound. Read-only syscalls can still update
OS-maintained access metadata. No claim of zero kernel/cache side effects.

## Focused Darwin obligations

Primary sources consulted (declarations are taken from the build's Darwin SDK):
[XNU f6217f8](https://github.com/apple-oss-distributions/xnu/tree/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea)
`bsd/sys/{attr,kauth}.h`, `bsd/vfs/vfs_{attrlist,cache,lookup,vnops,subr}.c`;
[Libc 71bbe35](https://github.com/apple-oss-distributions/Libc/tree/71bbe350ab79eef58113991d817ccc6165061a64)
`posix1e/{acl,acl_entry,acl_file,acl_translate,aclvar}.*`,
`gen/FreeBSD/{opendir,readdir,telldir}.*`, `sys/statx_np.c`, `gen/filesec.c`.

* Directory `acl_get_fd_np` NULL/error is unknown, never empty. Darwin ACL iteration uses
  0 for an entry and -1/EINVAL for end; the fixed ACE ceiling bounds iteration.
* Regular/link ACLs use descriptor-relative `getattrlistat`, `FSOPT_NOFOLLOW`
  and bounded attrreference parsing. The pinned Darwin `getattrlist.2:684–689`
  specifies **kauth_filesec**, not bare kauth_acl. XNU `vfs_attrlist.c:2051–2064`
  constructs the filesec prefix plus native ACL; `2792–2809` sizes that wrapper.
  With RETURNED_ATTRS, a null/unsupported `va_acl` omits both the bit and reference.
  Omission cannot distinguish absence from unsupported metadata: it stays
  **incomplete**, as do NOACL sentinels and malformed buffers. No layout fallback.
  Name-based ACL JSON distinguishes `acl_query_errors` (actual syscall errno), `acl_omitted`,
  `acl_noacl` and `acl_invalid`; decoder refusals set errno 0, not invented EINVAL.
  The old run's errno 22 alone cannot identify which path failed.
  `vfs_attrlist.c:3532–3573` resolves via LOOKUP/OP_GETATTR with no FOLLOW,
  queries attributes and releases the vnode reference; it does not open it.
* Real positive fixtures require explicit regular empty/nonempty ACLs, successful
  decoding and complete census results; unknown is not a pass. Nonempty FD/link
  getter oracles still require an allocated ACL and matching entry count.
  The generic `acl_get_fd(3)` manual documents NULL/errors, not guaranteed empty
  ACL allocation. Pinned Libc `statx_np.c:197–214` drops records shorter than
  `sizeof(kauth_filesec)` (68 bytes, including one ACE); the empty record is 44.
  `filesec.c:148–151` returns ENOENT for that absent ACL property, propagated by
  `acl_file.c:85–89`. On a valid held FD this need not mean a missing pathname.
  Only the known empty regular fixture accepts this NULL/ENOENT getter outcome,
  after positive zero-entry decoding, with held-FD and parent/name identity
  checks before/after. Arbitrary errors, missing paths, omitted attributes and
  the link oracle get no such exception. Empty-FD phases 0 (initial) and 4
  (after link setter) log only NULL status/errno; target emptiness stays mandatory.
  Libc `acl_set_link_np` unconditionally refuses links (`acl_file.c:166–176`),
  but this does not prove kernel ACL queries unsupported. The fixture instead
  uses nofollow `setattrlist` with SDK `acl_copy_ext_native` serialization, then
  `acl_get_link_np` as oracle, and checks the target's empty ACL is unchanged.
  Success must yield a positive decoded link ACL and complete fixture census.
  Only setter ENOTSUP is an explicit unsupported branch retaining incomplete
  census; EINVAL/other errors fail. Numeric probes log syscall status/errno,
  length, returned bits, reference position/offset/length, decoder status
  (0 OK, 1 omitted, 2 NOACL, 3 invalid) and count; never ACL bytes/UUIDs.
  Probe count 4294967295 means no count was decoded, not an observed ACL size.
  Empty-FD reconciliation and subsequent link/fixture checks await a hosted rerun.
* Libc `fdopendir` can allocate an entire union directory: refuse union mounts
  before calling it. Non-union `readdir` buffers in the cited implementation
  grow from 2 to 8 KiB; ACL objects have fixed slots. Hosted SDK/runtime behavior,
  regular name-based ACL access and nofollow/type-swap guards still need execution checks.
* Directory pre-open ordering: in the pinned XNU, `vfs_lookup.c:1493–1524`
  checks the search vnode is VDIR **before** final-component compound-open
  deferral. `name/.` makes the mutable name an intermediate component, so a
  FIFO replacement yields ENOTDIR before any target open. The cached path
  also stops at non-directory intermediates (`vfs_cache.c:2121–2125`) and
  checks the final dot's directory type (`2000–2005`). NOFOLLOW_ANY sets
  the exhausted symlink budget (`466–469`); resolution returns ELOOP before
  reading/following a link (`1926–1933`). The final `.` denotes that held
  directory, not another mutable child. `vfs_subr.c:8352–8359` also rejects
  non-directories with O_DIRECTORY before traditional VNOP_OPEN
  (`vfs_vnops.c:668–699`). We do **not** rely on the latter check alone: compound
  open is delegated earlier. This is a published-source ordering argument,
  not a claim that hosted kernel/SDK checks have run.
* Fixtures mutate only their new owned temp directory and remove named fixture
  objects, never a broad tree. They cover real ACLs/flags/permissions, symlink
  escapes/cycles, FIFO rejection, hardlinks, identity replacements, malformed
  ACL references, budgets and escaped output. Mount cases are labelled synthetic;
  no privileged mounts or root tests run. Failure leaves owned fixtures for
  runner teardown rather than attempting risky cleanup.
  Scanner-only open/openat interposition rejects **any attempted open** of a
  protected regular-to-FIFO/symlink/replacement name before the real syscall,
  not just an eventual XC_CHANGED result. Directory swaps separately require
  lookup refusal (ENOTDIR/ELOOP), never success followed by XC_CHANGED.
