# memory-region.mojo

[![mojoshelf](https://mojoshelf.org/badge/memory-region-mojo.svg)](https://mojoshelf.org/tins/memory-region-mojo) [![mojo nightly](https://mojoshelf.org/badge/memory-region-mojo/nightly.svg)](https://mojoshelf.org/tins/memory-region-mojo)

[![CI](https://github.com/magmalake/memory-region.mojo/actions/workflows/ci.yml/badge.svg)](https://github.com/magmalake/memory-region.mojo/actions/workflows/ci.yml)

Part of [**magmalake**](https://magmalake.org) — data lake building blocks in Mojo.


A **region** is a contiguous byte range that is internally addressable by offset 
not by pointers to memory.  Whatever you build inside a
region can be read by anyone who can see the bytes, wherever their address
space happens to put them. The first use case is transmitting Arrow data through
shared memory.

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

## Limitations

**Fixed size.** A region is a fixed range and `take` raises rather than
reallocating — nothing that has already handed out an offset can afford to
move. Size it up front. A producer that knows its total (a batch whose buffers
already exist) sizes it exactly; one that does not can over-allocate a
mapping, since untouched pages never materialise, and truncate afterwards.

**Monolithic deallocation.** The whole region goes at once. That is the usual arena trade
and it suits data that dies together.

**Not self describing.** A reader needs a manifest of some kind, and what that
looks like belongs to whoever owns the payload. `arrow-mlake` builds an Arrow
C Data Interface layout in one of these; a different caller would build
something else.


## Development

```sh
pixi run test     # the suite, including a write-here-read-there round trip
pixi run lint     # mojolint --lsp
```

## License

Apache-2.0.
