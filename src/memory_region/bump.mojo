"""A cursor that only moves forward.

`BumpAllocator` holds one number — how far into the region it has got — and
allocating is "give me where the cursor is, then move it on by `n`". No free
list, no search, no per-allocation header: two instructions. The price is that
an individual piece can never be freed, which is the usual arena trade and
suits data that is born together and dies together.

## Offsets, not addresses

`claim` returns an **offset from the start of the region**, and anything
stored inside a region refers to the rest of it by offset. A shared mapping
lands at a different address in every process that maps it, so an address
written into it means something only to the process that wrote it; a reader
adds its own `base()` and everything resolves.

`unsafe_address` is the one way back to a real pointer, for the moment a value
has to be written into a C structure whose consumer is this process.
"""

from memory_region.region import Region
from std.memory import unsafe_memcpy


struct BumpAllocator[R: Region & Deinitable](Movable):
    """Hands out 8-byte-aligned offsets into a region, front to back.

    Arrow wants every buffer 8-byte aligned — consumers cast them in place —
    so alignment is the allocator's job rather than each caller's.
    """

    var region: Self.R
    var used: Int
    """How far the cursor has moved: the region's occupied prefix."""

    def __init__(out self, var region: Self.R):
        self.region = region^
        self.used = 0

    def __init__(out self, *, deinit move: Self):
        self.region = move.region^
        self.used = move.used

    def claim(mut self, n: Int) raises -> Int:
        """Reserve `n` bytes and return their **offset** from the base.

        Raises rather than growing: a region is a fixed range, and nothing
        that has already handed out an offset could survive being moved.
        """
        var at = self.used
        self.used = (self.used + n + 7) & ~7
        if self.used > self.region.size():
            raise Error(
                String(
                    "memory_region: region is full (",
                    self.used,
                    " > ",
                    self.region.size(),
                    ")",
                )
            )
        return at

    def append(mut self, data: Span[UInt8, _]) raises -> Int:
        """Claim room for `data`, copy it in, and return where it went.

        The pairing `claim` was always used in — both of this library's first
        two callers wrote it for themselves before it lived here.
        """
        var at = self.claim(len(data) if len(data) else 1)
        if len(data):
            unsafe_memcpy(
                dest=self.unsafe_ptr(at), src=data.unsafe_ptr(), count=len(data)
            )
        return at

    def unsafe_ptr(self, offset: Int) -> Pointer[UInt8, MutUntrackedOrigin]:
        """A writable pointer to `offset`, valid in this process only."""
        return Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=self.region.base() + offset
        )

    def unsafe_address(self, offset: Int) -> Int:
        """`offset` as an address in this process.

        The only place an address belongs: writing one into a C structure
        whose consumer is this process. Anything a peer will read stores the
        offset instead.
        """
        return self.region.base() + offset

    def close(deinit self):
        """Give the region back now; it would go at end of scope anyway."""
        self.region^.close()

    def into_raw(deinit self) -> Int:
        """Give up ownership of the region; returns its base address.

        What an export does when the bytes become the consumer's — the Arrow
        C Data Interface release callback frees them later.
        """
        return self.region^.into_raw()
