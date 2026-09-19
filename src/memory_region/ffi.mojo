"""POSIX, for the two backings that need it.

Kept apart from the regions themselves so that a reader of `region.mojo` sees
what a region *is* rather than which integer `O_CREAT` happens to be on this
platform.
"""

from std.ffi import external_call
from std.sys.info import CompilationTarget

comptime PROT_READ: Int = 1
comptime PROT_WRITE: Int = 2
comptime MAP_SHARED: Int = 1
comptime MAP_FAILED: Int = -1

comptime O_RDONLY: Int = 0
comptime O_RDWR: Int = 2


def o_creat() -> Int:
    """`O_CREAT`, which is not the same number on both platforms.

    macOS has 0x0200 and Linux 0x40. Getting it wrong does not fail loudly —
    it opens with some other flag set — so it is spelled out here rather than
    inherited from a header nobody reads.
    """
    comptime if CompilationTarget.is_macos():
        return 0x0200
    return 0x40


def o_trunc() -> Int:
    """`O_TRUNC`: 0x0400 on macOS, 0x200 on Linux."""
    comptime if CompilationTarget.is_macos():
        return 0x0400
    return 0x200


def cstr(s: String) -> List[UInt8]:
    """A NUL-terminated copy, owned by the caller across the FFI call."""
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    out.append(0)
    return out^


def open_file(path: String, flags: Int, mode: Int = 0o600) raises -> Int:
    """`open(2)`, as an fd.

    `open` is variadic in C — `int open(const char *, int, ...)` — and a
    variadic call has a different ABI from a fixed one on arm64, so the
    fixed-argument count has to be declared or the mode lands in the wrong
    place. It fails at LLVM lowering rather than at the call, so the error
    does not point here.
    """
    var c_path = cstr(path)
    var fd = external_call["open", Int32, num_fixed_args=2](
        c_path.unsafe_ptr(), Int32(flags), Int32(mode)
    )
    if Int(fd) < 0:
        raise Error("memory_region: cannot open " + path)
    return Int(fd)


def close_fd(fd: Int):
    _ = external_call["close", Int32](Int32(fd))


def file_size(fd: Int) -> Int:
    """`lseek(fd, 0, SEEK_END)`."""
    return Int(external_call["lseek", Int64](Int32(fd), Int64(0), Int32(2)))


def truncate(fd: Int, size: Int) -> Bool:
    return Int(external_call["ftruncate", Int32](Int32(fd), Int64(size))) == 0


def map_file(fd: Int, size: Int, writable: Bool) -> Int:
    """`mmap(..., MAP_SHARED)`; 0 when the kernel refused."""
    var prot = PROT_READ | PROT_WRITE if writable else PROT_READ
    var addr = Int(
        external_call["mmap", Int](0, size, prot, MAP_SHARED, fd, Int64(0))
    )
    return 0 if addr == MAP_FAILED else addr


def unmap(addr: Int, size: Int):
    _ = external_call["munmap", Int32](addr, size)
