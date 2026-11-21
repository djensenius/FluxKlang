"""Opt-in, invocation-bounded loose/explicit-pack snapshot readers."""

import checkout_head
import git_loose
import git_loose_acquire
import git_pack
import git_pack_acquire


SNAPSHOT_LIMIT = 2
OBJECT_CALL_LIMIT = 64
LOOSE_IO_LIMIT = OBJECT_CALL_LIMIT * (git_loose.COMPRESSED_LIMIT + 1)
PAIR_IO_LIMIT = SNAPSHOT_LIMIT * (git_pack.PACK_LIMIT + 1 + git_pack.INDEX_LIMIT + 1)


class Invocation:
    """Create one sequential invocation; request each snapshot exactly once."""

    __slots__ = ("__next_snapshot",)

    def __init__(self, checkout_root, pack_id):
        if hasattr(self, "_Invocation__next_snapshot"):
            raise TypeError("invocation cannot be reset")
        checkout_head._checkout_path(checkout_root)
        checkout_head._expected_oid(pack_id)
        # Reservations include each helper's detection byte, even on failure.
        loose_attempt = git_loose.COMPRESSED_LIMIT + 1
        pair_attempt = git_pack.PACK_LIMIT + 1 + git_pack.INDEX_LIMIT + 1
        snapshot_limit = SNAPSHOT_LIMIT
        call_limit = OBJECT_CALL_LIMIT
        loose_limit = LOOSE_IO_LIMIT
        pair_limit = PAIR_IO_LIMIT
        snapshots = calls = loose_bytes = pair_bytes = 0
        failed = busy = False
        pair = None

        def next_snapshot():
            nonlocal snapshots, failed, busy, pair
            if failed or busy or snapshots >= snapshot_limit:
                failed = True
                raise KeyError("Git snapshot observation unavailable")
            snapshots += 1
            generation = snapshots
            pair = None

            def read(oid):
                nonlocal calls, loose_bytes, pair_bytes, failed, busy, pair
                entered = False
                try:
                    if failed or busy or generation != snapshots:
                        raise ValueError("snapshot unavailable")
                    busy = True
                    entered = True
                    calls += 1
                    loose_bytes += loose_attempt
                    if calls > call_limit or loose_bytes > loose_limit:
                        raise ValueError("object call or loose I/O limit")
                    checkout_head._expected_oid(oid)
                    try:
                        result = git_loose_acquire.read_object(checkout_root, oid)
                    except git_loose_acquire.LooseAbsent:
                        if failed:
                            raise ValueError("invocation already refused")
                        if pair is None:
                            pair_bytes += pair_attempt
                            if pair_bytes > pair_limit:
                                raise ValueError("pack/index I/O limit")
                            pair = git_pack_acquire.acquire_validated_pair(
                                checkout_root, pack_id,
                            )
                        result = pair.read(oid)
                    if failed:
                        raise ValueError("invocation already refused")
                    return result
                except (ValueError, OSError, KeyError) as error:
                    failed = True
                    raise KeyError("Git snapshot observation unavailable") from error
                except BaseException:
                    failed = True
                    raise
                finally:
                    if entered:
                        busy = False

            return read

        object.__setattr__(self, "_Invocation__next_snapshot", next_snapshot)

    def __setattr__(self, name, value):
        raise AttributeError("invocation is immutable")

    def __delattr__(self, name):
        raise AttributeError("invocation is immutable")

    def __copy__(self):
        raise TypeError("invocation cannot be copied")

    def __deepcopy__(self, memo):
        raise TypeError("invocation cannot be copied")

    def __reduce_ex__(self, protocol):
        raise TypeError("invocation cannot be serialized")

    def snapshot(self):
        """Return a callable for the next snapshot, invalidating the previous one."""
        return self.__next_snapshot()
