"""Bytes that survive being moved.

A **region** is a contiguous byte range, however it was obtained: an ordinary
allocation, or a file mapped `MAP_SHARED` that another process can map by
name. A `BumpAllocator` carves one up.

The rule that makes it a library rather than a helper is that `claim` returns
an **offset**, not an address. A shared mapping lands somewhere different in
every process that maps it, so anything built inside a region has to refer to
itself by offset; a reader adds its own `base()` and it all resolves. What
that buys is a structure you can hand to someone else — through a file, a
shared mapping, an object store — without serialising it.

    var bump = BumpAllocator[MappedRegion](MappedRegion("/tmp/batch", size))
    var header = bump.claim(8)
    var payload = bump.append(some_bytes)
    bump.unsafe_ptr(header).unsafe_bitcast[Int64]()[unsafe_offset=0] = Int64(payload)
    bump^.close()          # unmaps; the file stays

and on the other side, `map_shared(path)` and add the base it returns.

## Dropping is safe, giving away is explicit

A region frees or unmaps itself at end of scope, because a leaked mapping has
no other symptom. `into_raw()` is how an export says the bytes are the
consumer's now: it consumes the region so the destructor does not run.

## What it does not do

**Grow.** A fixed range, so `claim` raises rather than reallocating. Size it
up front: a producer that knows its total sizes it exactly, one that does not
can over-allocate a mapping, since untouched pages never materialise.

**Free a piece.** The whole region goes at once.

**Describe itself.** A reader needs a manifest, and what that looks like
belongs to whoever owns the payload.
"""

from memory_region.bump import BumpAllocator
from memory_region.ffi import cstr
from memory_region.region import (
    HeapRegion,
    MappedRegion,
    Region,
    map_shared,
)
