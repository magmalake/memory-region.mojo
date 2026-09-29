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
from memory_region import BumpAllocator, MappedRegion, SharedMapping

# Producer: lay a structure out in a shared mapping.
var bump = BumpAllocator[MappedRegion](MappedRegion("/tmp/batch", 1 << 20))
var header = bump.claim(8)
var payload = bump.append(some_bytes)          # copies, returns where it went
bump.unsafe_ptr(header).unsafe_bitcast[Int64]()[unsafe_offset=0] = Int64(
    payload                                     # an offset, not a pointer
)
...
# unmapped at end of scope, or `bump^.close()` now, or `bump^.into_raw()` to
# hand the bytes to a consumer that will free them itself
```

```mojo
# Consumer, in another process: map the same bytes, read them by offset.
var mapped = SharedMapping("/tmp/batch")           # read-only, unmapped at end of scope
var payload_offset = mapped.span[DType.int64](header, 1)[0]
var payload = mapped.span[DType.uint8](Int(payload_offset), n)
```

The second mapping lands at a different address than the first. Everything
still resolves, because nothing inside the region was written as an address.

## What you get

| | |
|---|---|
| `Region` | a trait: `base()`, `size()`, `close()`, `into_raw()` |
| `HeapRegion` | an ordinary allocation |
| `MappedRegion` | a file mapped `MAP_SHARED`, addressable by path |
| `BumpAllocator[R]` | `claim(n)` and `append(span)`, both returning offsets |
| `unsafe_ptr` / `unsafe_address` | an offset made usable, in this process only |
| `SharedMapping` | the consumer's half: a file mapped read-only, with checked, origin-tracked views |

A region frees or unmaps itself at end of scope, because a leaked mapping has
no other symptom — no error, no crash, nothing in the output. `into_raw()` is
the other ending: it consumes the region so the destructor does not run, for
bytes that become a consumer's.

`SharedMapping.span[dtype](offset, count)` returns a `Span` tied to the
mapping. Writing through one is a compile error, because the pages are
read-only, and so is keeping one after the mapping has gone. What a type
cannot check, it checks at run time: the offset came from another process, so
a span that would run past the end of the mapping, or start misaligned for
its type, raises instead of reading garbage.

Arrow wants every buffer 8-byte aligned so a consumer can cast it in place, so
alignment is the allocator's job here rather than each caller's.

## Limitations

**Fixed size.** A region is a fixed range and `claim` raises rather than
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
