"""The memory-region.mojo test suite. `pixi run test`.

The interesting one is `test_offsets_are_independent_of_where_the_region_landed`:
it writes through one mapping and reads through a second, which is the property
the whole library exists to provide and the thing that would be impossible if
`take` returned addresses.
"""

from std.testing import TestSuite, assert_equal, assert_raises

from memory_region import Bump, HeapRegion, MappedRegion, map_shared


def test_bump_hands_out_aligned_offsets() raises:
    """Offsets, not addresses, and every one of them 8-byte aligned."""
    var bump = Bump[HeapRegion](HeapRegion(256))
    assert_equal(bump.take(1), 0)
    # 1 byte taken, but Arrow wants the next buffer aligned.
    assert_equal(bump.take(8), 8)
    assert_equal(bump.take(3), 16)
    assert_equal(bump.take(16), 24)


def test_bump_refuses_to_run_past_its_region() raises:
    var bump = Bump[HeapRegion](HeapRegion(64))
    _ = bump.take(64)
    with assert_raises():
        _ = bump.take(1)


def test_offsets_are_independent_of_where_the_region_landed() raises:
    """The property the whole file exists for.

    A region written by one mapping and read through another lands at a
    different address, so the same offsets have to resolve against whichever
    base the reader got. If `take` returned addresses this test could not be
    written.
    """
    var path = String("/tmp/arrow_mlake_region_test.bin")
    var region = MappedRegion(path, 4096)
    var writer_base = region.base()
    var bump = Bump[MappedRegion](region^)

    var head = bump.take(8)
    var payload = bump.take(4)
    # A structure inside the region referring to another part of it: by
    # offset, which is what survives the trip.
    bump.words_at(head)[unsafe_offset=0] = Int64(payload)
    var p = bump.ptr_at(payload)
    for i in range(4):
        p[unsafe_offset=i] = UInt8(0xA0 + i)
    bump^.release()

    # The peer's half: a second, independent mapping of the same bytes.
    var mapped = map_shared(path)
    var reader_base = mapped[0]
    var where = Pointer[Int64, ImmUntrackedOrigin](
        unsafe_from_address=reader_base + head
    )
    var payload_offset = Int(where[unsafe_offset=0])
    assert_equal(payload_offset, payload)
    var q = Pointer[UInt8, ImmUntrackedOrigin](
        unsafe_from_address=reader_base + payload_offset
    )
    for i in range(4):
        assert_equal(Int(q[unsafe_offset=i]), 0xA0 + i)
    _ = writer_base
    _ = reader_base


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
