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

`span` is how to read and write what has been claimed: a typed view that
borrows the allocator, so the compiler knows when it stops being valid.
`unsafe_address` is the way back to a raw address, for the moment one has to
be written into a C structure whose consumer is this process.
"""

from memory_region.region import Region
from std.sys.info import align_of, size_of


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

    def append[
        dtype: DType, //
    ](mut self, data: Span[Scalar[dtype], _]) raises -> Int:
        """Claim room for `data`, copy it in, and return where it went.

        Any scalar element type, so a buffer of `Int32` offsets goes in as
        itself rather than as an address and a byte count.
        """
        var at = self.claim(
            len(data) * size_of[Scalar[dtype]]() if len(data) else 1
        )
        if len(data):
            self.span[dtype](at, len(data)).copy_from(data)
        return at

    def span[
        dtype: DType
    ](ref self, offset: Int, count: Int) -> Span[
        Scalar[dtype], origin_of(self)
    ]:
        """`count` values of `dtype` at `offset`, as a view of this allocator.

        The view borrows the allocator: writable when the allocator is
        reached through `mut`, read-only otherwise, and unusable once it is
        closed, moved or dropped — all checked by the compiler. Claiming more
        while a view is alive is fine, because `claim` never moves anything.

        The offset is one this allocator handed out, so a bad one is a bug
        rather than bad input: it is a `debug_assert` against what has been
        claimed, not a raise.
        """
        comptime assert dtype != DType.bool, "read Bool bytes as uint8"
        comptime assert (
            align_of[Scalar[dtype]]() <= 8
        ), "claims are 8-byte aligned"
        debug_assert(
            offset >= 0
            and count >= 0
            and offset + count * size_of[Scalar[dtype]]() <= self.used,
            "memory_region: span outside what has been claimed",
        )
        return Span[Scalar[dtype], origin_of(self)](
            unsafe_ptr=Pointer[Scalar[dtype], origin_of(self)](
                unsafe_from_address=self.region.base() + offset
            ),
            length=count,
        )

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
