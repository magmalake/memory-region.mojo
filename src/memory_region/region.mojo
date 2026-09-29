"""Where a region's bytes come from, and what giving them back means.

A region is a contiguous byte range. What differs between one and the next is
how it was obtained — an allocation, a mapped file, later perhaps a slab in an
object store or a pinned buffer on the way to a GPU — and what releasing it
means. Nothing that carves a region up needs to know which it has.

## Dropping one is safe; giving it away is explicit

A region frees or unmaps itself when it goes out of scope, because the failure
it would otherwise have is invisible: a leaked mapping produces no error, no
crash and nothing in the output, and the file stays open through it.

`into_raw` is the way out for the case that is not a leak — an export whose
bytes become the consumer's, freed later by its own release callback. It
consumes the region, so the destructor does not also run, and the transfer is
readable at the call site instead of being implied by an omission.

Mojo can do better than this: `@explicit_destroy` with a `not Deinitable`
conformance makes abandoning a region a *compile* error naming the method to
call. It is not used here because it needs a September-2026 nightly, and these
tins build on `mojo-compiler` 1.1.0. Worth revisiting when stable catches up —
it turns a safe default into an impossible mistake.
"""

from memory_region.ffi import (
    O_RDONLY,
    O_RDWR,
    close_fd,
    file_size,
    map_file,
    o_creat,
    o_trunc,
    open_file,
    truncate,
    unmap,
)
from std.memory.alloc import unsafe_alloc
from std.sys.info import align_of, size_of


trait Region(Movable):
    """A contiguous byte range that something else owns the lifetime of."""

    def base(self) -> Int:
        """Address of byte 0 **in this process**."""
        ...

    def size(self) -> Int:
        """How many bytes it holds."""
        ...

    def close(deinit self):
        """Give the bytes back: free, unmap, whatever this region means."""
        ...

    def into_raw(deinit self) -> Int:
        """Give up ownership; returns the base address.

        For bytes that become someone else's — an Arrow export whose release
        callback frees them later. Consuming, so the destructor does not also
        run.
        """
        ...


struct HeapRegion(Movable, Region):
    """An ordinary allocation: what an in-process export has always used."""

    var _base: Int
    var _size: Int

    def __init__(out self, size: Int):
        var n = (size + 7) & ~7
        self._base = Int(unsafe_alloc[UInt64](n // 8))
        self._size = n

    def __init__(out self, *, deinit move: Self):
        self._base = move._base
        self._size = move._size

    def base(self) -> Int:
        return self._base

    def size(self) -> Int:
        return self._size

    def __deinit__(deinit self):
        """Freed when it goes out of scope, unless `into_raw` took it."""
        self^.close()

    def close(deinit self):
        """Hand the allocation back, now rather than at the end of scope."""
        if self._base != 0:
            Pointer[UInt64, MutUntrackedOrigin](
                unsafe_from_address=self._base
            ).unsafe_free()

    def into_raw(deinit self) -> Int:
        """Give up ownership; returns the base address.

        For a consumer that will free the bytes itself — the Arrow C Data
        Interface being the case this exists for, where the release callback
        on the exported array is what eventually frees the block.
        """
        return self._base


struct MappedRegion(Movable, Region):
    """A file mapped `MAP_SHARED`, which a peer process can map by name.

    The file is the handle. A consumer needs the path and nothing else:
    everything inside is laid out by offset, so it can map the same bytes
    wherever its own address space happens to put them.
    """

    var _base: Int
    var _size: Int
    var path: String
    """Where a peer will find these bytes."""

    def __init__(out self, var path: String, size: Int) raises:
        """Create (or truncate) `path` at `size` bytes and map it writable."""
        var n = (size + 7) & ~7
        var fd = open_file(path, O_RDWR | o_creat() | o_trunc())
        if not truncate(fd, n):
            close_fd(fd)
            raise Error("memory_region: cannot size " + path)
        var addr = map_file(fd, n, writable=True)
        # The fd is not needed once the mapping exists; the mapping keeps the
        # file alive on its own.
        close_fd(fd)
        if addr == 0:
            raise Error("memory_region: cannot map " + path)
        self._base = addr
        self._size = n
        self.path = path^

    def __init__(out self, *, deinit move: Self):
        self._base = move._base
        self._size = move._size
        self.path = move.path^

    def base(self) -> Int:
        return self._base

    def size(self) -> Int:
        return self._size

    def __deinit__(deinit self):
        """Unmapped when it goes out of scope, unless `into_raw` took it."""
        self^.close()

    def close(deinit self):
        """Drop this process's view of the bytes. The file stays.

        Unlinking is deliberately not done here: the consumer may not have
        mapped it yet, and when the bytes stop being needed is the caller's
        business rather than the region's.
        """
        if self._base != 0:
            unmap(self._base, self._size)

    def into_raw(deinit self) -> Int:
        """Leave the mapping in place and give up ownership of it."""
        return self._base


struct SharedMapping(Movable):
    """The consumer's half: a peer's region, mapped read-only by path.

    It lands wherever this address space puts it, and everything inside is
    reached by offset from there. Unmapped at end of scope, like a region.

    Views come out of `span` and `bytes`, and carry this mapping's origin.
    That makes two mistakes compile errors rather than crashes: writing
    through a view (the pages are `PROT_READ`, so a write would fault), and
    holding a view after the mapping has gone (it would point at nothing).

    What the types cannot promise is anything about the bytes: offsets come
    from another process's manifest, so `span` checks them against the
    mapping at run time, and the producer can still rewrite or truncate the
    file underneath a view.

    It is deliberately not a `Region`: a region is something a
    `BumpAllocator` carves up and writes into, and this one cannot be written.
    """

    var _base: Int
    var _size: Int
    var path: String
    """The file these bytes were mapped from."""

    def __init__(out self, var path: String) raises:
        """Map `path` read-only, all of it."""
        var fd = open_file(path, O_RDONLY)
        var size = file_size(fd)
        if size <= 0:
            close_fd(fd)
            raise Error("memory_region: " + path + " is empty")
        var addr = map_file(fd, size, writable=False)
        # As with MappedRegion: the mapping keeps the file alive on its own.
        close_fd(fd)
        if addr == 0:
            raise Error("memory_region: cannot map " + path)
        self._base = addr
        self._size = size
        self.path = path^

    def __init__(out self, *, deinit move: Self):
        self._base = move._base
        self._size = move._size
        self.path = move.path^

    def __deinit__(deinit self):
        """Unmapped when it goes out of scope."""
        unmap(self._base, self._size)

    def size(self) -> Int:
        """How many bytes are mapped: the file's length when it was opened."""
        return self._size

    def span[
        dtype: DType
    ](self, offset: Int, count: Int) raises -> Span[
        Scalar[dtype], origin_of(self)
    ]:
        """`count` values of `dtype` starting `offset` bytes in, read-only.

        Raises if they do not fit inside the mapping, or if `offset` is not
        aligned for `dtype` — both things a manifest from another process can
        get wrong, and neither of which a type can rule out.
        """
        comptime assert dtype != DType.bool, (
            "Bool is not valid for every bit pattern; read the bytes as uint8"
        )
        comptime width = size_of[Scalar[dtype]]()
        comptime align = align_of[Scalar[dtype]]()
        if offset < 0 or count < 0 or offset > self._size:
            raise Error(
                String(
                    "memory_region: ", count, " values at ", offset,
                    " are outside ", self.path, " (", self._size, " bytes)",
                )
            )
        # Compared by division, so a huge count from a bad manifest cannot
        # overflow its way back inside the mapping.
        if count > (self._size - offset) // width:
            raise Error(
                String(
                    "memory_region: ", count, " values at ", offset,
                    " run past the end of ", self.path, " (", self._size,
                    " bytes)",
                )
            )
        if offset % align != 0:
            raise Error(
                String(
                    "memory_region: offset ", offset, " is not aligned to ",
                    align, " for ", dtype,
                )
            )
        return Span[Scalar[dtype], origin_of(self)](
            unsafe_ptr=Pointer[Scalar[dtype], origin_of(self)](
                unsafe_from_address=self._base + offset
            ),
            length=count,
        )

    def bytes(self) -> Span[UInt8, origin_of(self)]:
        """The whole mapping, as bytes."""
        return Span[UInt8, origin_of(self)](
            unsafe_ptr=Pointer[UInt8, origin_of(self)](
                unsafe_from_address=self._base
            ),
            length=self._size,
        )

    def unsafe_base(self) -> Int:
        """Address of byte 0 in this process, untracked.

        For handing a buffer to something outside Mojo's view — an Arrow
        C Data import, a foreign function. The address is only good while
        this mapping is alive, and nothing checks that.
        """
        return self._base


@deprecated("use SharedMapping(path): it unmaps itself and checks offsets")
def map_shared(path: String) raises -> Tuple[Int, Int]:
    """Map an existing file read-only; returns `(address, length)`.

    Nothing ever unmaps what this returns. Kept for one release while callers
    move to `SharedMapping`.
    """
    var fd = open_file(path, O_RDONLY)
    var size = file_size(fd)
    if size <= 0:
        close_fd(fd)
        raise Error("memory_region: " + path + " is empty")
    var addr = map_file(fd, size, writable=False)
    close_fd(fd)
    if addr == 0:
        raise Error("memory_region: cannot map " + path)
    return (addr, size)
