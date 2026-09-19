# memory-region.mojo

[![mojoshelf](https://mojoshelf.org/badge/memory-region-mojo.svg)](https://mojoshelf.org/tins/memory-region-mojo) [![mojo nightly](https://mojoshelf.org/badge/memory-region-mojo/nightly.svg)](https://mojoshelf.org/tins/memory-region-mojo)

[![CI](https://github.com/magmalake/memory-region.mojo/actions/workflows/ci.yml/badge.svg)](https://github.com/magmalake/memory-region.mojo/actions/workflows/ci.yml)

Part of [**magmalake**](https://magmalake.org) — data lake building blocks in Mojo.

Bytes that survive being moved.

A **region** is a contiguous byte range, however it was obtained: an ordinary
allocation, or a file mapped `MAP_SHARED` that another process can map by
name. A `Bump` carves one up. The rule that makes it worth a library is that
`take` returns an **offset**, not an address — so whatever you build inside a
region can be read by anyone who can see the bytes, wherever their address
space happens to put them.

## Install

```sh
pixi shelf add memory-region-mojo
```

magmalake tins are **git source dependencies, not conda-channel packages** —
`pixi add memory-region-mojo` finds nothing. The
[mojoshelf-consume](https://mojoshelf.org/getting-started) skill explains the
shape if your tooling needs it.

## The idea

```mojo
from memory_region import Bump, MappedRegion, map_shared

# Producer: lay a structure out in a shared mapping.
var bump = Bump[MappedRegion](MappedRegion("/tmp/batch", 1 << 20))
var header = bump.take(8)
var payload = bump.take(4096)
bump.words_at(header)[unsafe_offset=0] = Int64(payload)   # an offset, not a pointer
var p = bump.ptr_at(payload)
...
bump^.release()          # unmaps; the file stays
```

```mojo
# Consumer, in another process: map the same bytes and add its own base.
var mapped = map_shared("/tmp/batch")
var base = mapped[0]
var payload_offset = Pointer[Int64, ImmUntrackedOrigin](
    unsafe_from_address=base + 0
)[unsafe_offset=0]
```

The second mapping lands at a different address than the first. Everything
still resolves, because nothing inside the region was written as an address.
That is the whole library, and it is what the test suite checks.

## What you get

| | |
|---|---|
| `Region` | a trait: `base()`, `size()`, `release()` |
| `HeapRegion` | an ordinary allocation |
| `MappedRegion` | a file mapped `MAP_SHARED`, addressable by path |
| `Bump[R]` | 8-byte-aligned offsets, front to back |
| `map_shared` | the consumer's half: map an existing file read-only |

Arrow wants every buffer 8-byte aligned so a consumer can cast it in place, so
alignment is the allocator's job here rather than each caller's.

## What it does not do

**Grow.** A region is a fixed range and `take` raises rather than
reallocating — nothing that has already handed out an offset can afford to
move. Size it up front. A producer that knows its total (a batch whose buffers
already exist) sizes it exactly; one that does not can over-allocate a
mapping, since untouched pages never materialise, and truncate afterwards.

**Free a piece.** The whole region goes at once. That is the usual arena trade
and it suits data that dies together.

**Describe itself.** A reader needs a manifest of some kind, and what that
looks like belongs to whoever owns the payload. `arrow-mlake` builds an Arrow
C Data Interface layout in one of these; a different caller would build
something else.

## Why it exists

Arrow's C Data Interface hands over **pointers**, which mean nothing in
another address space — so the one thing it cannot do is cross a process. A
mapping can. Building the same buffers in a region, by offset, is what lets a
reader in one process hand a batch to a consumer in another without
serialising it.

Nothing about that is Arrow-specific, which is why this is its own tin. The
same contract — size up front, fill, publish, map elsewhere — is what a
shared-memory object store like Ray's Plasma offers, and a `Region` over
pinned or device memory would serve a GPU handoff.

## Development

```sh
pixi run test     # the suite, including a write-here-read-there round trip
pixi run lint     # mojolint --lsp
```

## License

Apache-2.0.
