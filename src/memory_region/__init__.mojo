"""Bytes that survive being moved.

A **region** is a contiguous byte range, however it was obtained: an ordinary
allocation, or a file mapped `MAP_SHARED` that another process can map by
name. A `Bump` carves one up.

## Offsets, not addresses

`Bump.take` returns an **offset from the start of the region**, and anything
stored inside a region refers to the rest of it by offset. That is the whole
point of the library, and it costs nothing: a shared mapping lands at a
different address in every process that maps it, so an address written into it
means something only to the process that wrote it. A reader adds its own
`base()` and everything resolves.

What that buys is a blob you can hand to someone else — through a file, a
shared mapping, an object store — without serialising it. The bytes are
already in their final layout; the only thing the reader needs is where the
mapping landed.

## Using one

    var bump = Bump[MappedRegion](MappedRegion("/dev/shm/batch", size))
    var header = bump.take(8)          # offsets
    var payload = bump.take(n)
    bump.words_at(header)[unsafe_offset=0] = Int64(payload)   # store the offset
    ...
    bump^.release()                    # unmap; the file stays

and on the other side, `map_shared(path)` and add the base it returns.

**A region cannot grow.** It is a bump allocator over a fixed range, so the
size is decided up front and `take` raises rather than reallocating — nothing
that has already handed out an offset can afford to move. Producers that know
their total (an Arrow batch whose buffers already exist, say) size it exactly;
producers that do not can over-allocate a mapping, since untouched pages never
materialise, and truncate afterwards.

## What it is not

Not a general allocator: there is no free of an individual piece, which is the
usual arena trade and fits data that dies together. Not a description of what
is in the bytes either — a reader needs a manifest of some kind, and what that
looks like belongs to whoever owns the payload. `arrow-mlake` builds an Arrow
C Data Interface layout in one of these; a different caller would build
something else.
"""

from std.ffi import external_call
from std.memory.alloc import unsafe_alloc
from std.sys.info import CompilationTarget


comptime PROT_READ: Int = 1
comptime PROT_WRITE: Int = 2
comptime MAP_SHARED: Int = 1
comptime MAP_FAILED: Int = -1

comptime O_RDONLY: Int = 0
comptime O_RDWR: Int = 2


def _o_creat() -> Int:
    """`O_CREAT`, which is not the same number on both platforms.

    macOS has 0x0200 and Linux 0x40. Getting it wrong does not fail loudly —
    it opens with some other flag set — so it is spelled out here rather than
    inherited from a header nobody reads.
    """
    comptime if CompilationTarget.is_macos():
        return 0x0200
    return 0x40


def _o_trunc() -> Int:
    """`O_TRUNC`: 0x0400 on macOS, 0x200 on Linux."""
    comptime if CompilationTarget.is_macos():
        return 0x0400
    return 0x200


def _cstr(s: String) -> List[UInt8]:
    """A NUL-terminated copy, owned by the caller across the FFI call."""
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    out.append(0)
    return out^


trait Region(Movable):
    """A contiguous byte range that something else owns the lifetime of.

    Implementations differ in where the bytes come from and what releasing
    them means; nothing that carves a region up needs to know which it has.
    """

    def base(self) -> Int:
        """Address of byte 0 **in this process**."""
        ...

    def size(self) -> Int:
        """How many bytes it holds."""
        ...

    def release(deinit self):
        """Give the bytes back — free, unmap, whatever this region means."""
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

    def release(deinit self):
        """Hand the allocation back."""
        if self._base != 0:
            Pointer[UInt64, MutUntrackedOrigin](
                unsafe_from_address=self._base
            ).unsafe_free()


struct MappedRegion(Movable, Region):
    """A file mapped `MAP_SHARED`, which a peer process can map by name.

    The file is the handle. A consumer needs the path and the length, and
    nothing else: everything inside is laid out by offset, so it can map the
    same bytes wherever its own address space happens to put them.

    Releasing unmaps. It deliberately does *not* unlink — the consumer may not
    have mapped it yet, and deciding when the bytes are no longer needed is
    the caller's business, not the region's.
    """

    var _base: Int
    var _size: Int
    var path: String

    def __init__(out self, var path: String, size: Int) raises:
        """Create (or truncate) `path` at `size` bytes and map it writable."""
        var n = (size + 7) & ~7
        var c_path = _cstr(path)
        # `open` is variadic in C — `int open(const char *, int, ...)` — and a
        # variadic call has a different ABI from a fixed one on arm64, so the
        # fixed-argument count has to be declared or the mode lands in the
        # wrong place.
        var fd = external_call["open", Int32, num_fixed_args=2](
            c_path.unsafe_ptr(),
            Int32(O_RDWR | _o_creat() | _o_trunc()),
            Int32(0o600),
        )
        if Int(fd) < 0:
            raise Error("region: cannot open " + path)
        if Int(external_call["ftruncate", Int32](fd, Int64(n))) != 0:
            _ = external_call["close", Int32](fd)
            raise Error("region: cannot size " + path)
        var addr = Int(
            external_call["mmap", Int](
                0, n, PROT_READ | PROT_WRITE, MAP_SHARED, Int(fd), Int64(0)
            )
        )
        # The fd is not needed once the mapping exists; the mapping keeps the
        # file alive on its own.
        _ = external_call["close", Int32](fd)
        if addr == MAP_FAILED or addr == 0:
            raise Error("region: cannot map " + path)
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

    def release(deinit self):
        """Drop this process's view of the bytes. The file stays.

        Unlinking is deliberately not done here: the consumer may not have
        mapped it yet, and when the bytes stop being needed is the caller's
        business rather than the region's.
        """
        if self._base != 0:
            _ = external_call["munmap", Int32](self._base, self._size)


struct Bump[R: Region & Deinitable](Movable):
    """Hands out 8-byte-aligned offsets into a region, front to back.

    Arrow wants every buffer 8-byte aligned — consumers cast them in place —
    so alignment is the allocator's job rather than each caller's.
    """

    var region: Self.R
    var used: Int

    def __init__(out self, var region: Self.R):
        self.region = region^
        self.used = 0

    def __init__(out self, *, deinit move: Self):
        self.region = move.region^
        self.used = move.used

    def take(mut self, n: Int) raises -> Int:
        """Reserve `n` bytes and return their **offset** from the region base.

        Not an address: see the module docstring. A caller that wants to write
        through it asks `ptr_at`.
        """
        var at = self.used
        self.used = (self.used + n + 7) & ~7
        if self.used > self.region.size():
            raise Error(
                String(
                    "region: block overflow (",
                    self.used,
                    " > ",
                    self.region.size(),
                    ")",
                )
            )
        return at

    def ptr_at(self, offset: Int) -> Pointer[UInt8, MutUntrackedOrigin]:
        """A writable pointer to `offset`, valid in this process only."""
        return Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=self.region.base() + offset
        )

    def words_at(self, offset: Int) -> Pointer[Int64, MutUntrackedOrigin]:
        """The same, as 64-bit cells, for a struct being laid out by hand."""
        return Pointer[Int64, MutUntrackedOrigin](
            unsafe_from_address=self.region.base() + offset
        )

    def address_of(self, offset: Int) -> Int:
        """`offset` as an address in this process."""
        return self.region.base() + offset

    def release(deinit self):
        """Give the region up.

        Consuming the whole `Bump` rather than reaching into it: a region is
        moved out of a field one piece at a time otherwise, which Mojo
        rightly refuses.
        """
        self.region^.release()


def map_shared(path: String) raises -> Tuple[Int, Int]:
    """Map an existing file read-only; returns `(address, length)`.

    The consumer's half, and the reason a region is worth naming: a peer opens
    the same path, maps it wherever its address space allows, and reads every
    structure inside by offset from what it got back.
    """
    var c_path = _cstr(path)
    var fd = external_call["open", Int32, num_fixed_args=2](
        c_path.unsafe_ptr(), Int32(O_RDONLY)
    )
    if Int(fd) < 0:
        raise Error("region: cannot open " + path)
    var size = Int(external_call["lseek", Int64](fd, Int64(0), Int32(2)))
    if size <= 0:
        _ = external_call["close", Int32](fd)
        raise Error("region: " + path + " is empty")
    var addr = Int(
        external_call["mmap", Int](0, size, PROT_READ, MAP_SHARED, Int(fd), Int64(0))
    )
    _ = external_call["close", Int32](fd)
    if addr == MAP_FAILED or addr == 0:
        raise Error("region: cannot map " + path)
    return (addr, size)
