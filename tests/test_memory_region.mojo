"""The memory-region.mojo test suite. `pixi run test`.

The interesting one is `test_offsets_are_independent_of_where_the_region_landed`:
it writes through one mapping and reads through a second, which is the property
the whole library exists to provide and the thing that would be impossible if
`take` returned addresses.
"""

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from memory_region import (
    BumpAllocator,
    HeapRegion,
    MappedRegion,
    SharedMapping,
)


def test_a_dropped_region_frees_itself() raises:
    """The default has to be safe, because a leak here is invisible.

    Nothing asserts, because there is nothing to observe from inside the
    process — the point is that this function allocates and maps nothing that
    survives it. `into_raw` is the other ending, and the export path uses it.
    """
    var bump = BumpAllocator[HeapRegion](HeapRegion(64))
    _ = bump.claim(8)
    # and it goes out of scope here


def test_into_raw_hands_the_bytes_over() raises:
    """The other ending: the caller frees, so the region must not.

    Nothing here can observe a double free directly — the point is that this
    compiles and runs, and that the export path in arrow-mlake spells the
    transfer rather than implying it by dropping the block.
    """
    var bump = BumpAllocator[HeapRegion](HeapRegion(64))
    var at = bump.claim(8)
    assert_equal(at, 0)
    var base = bump^.into_raw()
    assert_true(base != 0)
    Pointer[UInt64, MutUntrackedOrigin](unsafe_from_address=base).unsafe_free()


def test_append_copies_and_says_where() raises:
    var bump = BumpAllocator[HeapRegion](HeapRegion(128))
    var bytes = List[UInt8]()
    for i in range(5):
        bytes.append(UInt8(0x10 + i))
    var at = bump.append(Span(bytes))
    assert_equal(at, 0)
    var p = bump.unsafe_ptr(at)
    for i in range(5):
        assert_equal(Int(p[unsafe_offset=i]), 0x10 + i)
    # The next claim starts past it, rounded up to 8.
    assert_equal(bump.claim(1), 8)


def test_bump_hands_out_aligned_offsets() raises:
    """Offsets, not addresses, and every one of them 8-byte aligned."""
    var bump = BumpAllocator[HeapRegion](HeapRegion(256))
    assert_equal(bump.claim(1), 0)
    # 1 byte claimed, but Arrow wants the next buffer aligned.
    assert_equal(bump.claim(8), 8)
    assert_equal(bump.claim(3), 16)
    assert_equal(bump.claim(16), 24)


def test_bump_refuses_to_run_past_its_region() raises:
    var bump = BumpAllocator[HeapRegion](HeapRegion(64))
    _ = bump.claim(64)
    with assert_raises():
        _ = bump.claim(1)


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
    var bump = BumpAllocator[MappedRegion](region^)

    var head = bump.claim(8)
    var payload = bump.claim(4)
    # A structure inside the region referring to another part of it: by
    # offset, which is what survives the trip.
    bump.unsafe_ptr(head).unsafe_bitcast[Int64]()[unsafe_offset=0] = Int64(
        payload
    )
    var p = bump.unsafe_ptr(payload)
    for i in range(4):
        p[unsafe_offset=i] = UInt8(0xA0 + i)
    bump^.close()

    # The peer's half: a second, independent mapping of the same bytes.
    var mapped = SharedMapping(path)
    var payload_offset = Int(mapped.span[DType.int64](head, 1)[0])
    assert_equal(payload_offset, payload)
    var q = mapped.span[DType.uint8](payload_offset, 4)
    for i in range(4):
        assert_equal(Int(q[i]), 0xA0 + i)
    _ = writer_base


def _publish(path: String, values: List[Float64]) raises -> Int:
    """Write `values` into a fresh mapping at `path`; returns their offset."""
    var bump = BumpAllocator[MappedRegion](MappedRegion(path, 4096))
    _ = bump.claim(8)  # something in front, so the offset is not 0
    var at = bump.claim(len(values) * 8)
    var p = bump.unsafe_ptr(at).unsafe_bitcast[Float64]()
    for i in range(len(values)):
        p[unsafe_offset=i] = values[i]
    bump^.close()
    return at


def test_a_shared_mapping_reads_by_offset() raises:
    var path = String("/tmp/memory_region_shared_test.bin")
    var at = _publish(path, [1.5, 2.5, 4.0])
    var mapped = SharedMapping(path)
    assert_equal(mapped.size(), 4096)
    var total = Float64(0)
    for x in mapped.span[DType.float64](at, 3):
        total += x
    assert_equal(total, 8.0)
    assert_equal(len(mapped.bytes()), 4096)


def test_a_shared_mapping_refuses_what_does_not_fit() raises:
    """Offsets come from another process, so they are checked, not trusted."""
    var path = String("/tmp/memory_region_shared_bounds.bin")
    _ = _publish(path, [1.0])
    var mapped = SharedMapping(path)
    # the last 8 bytes fit; one more value does not
    _ = mapped.span[DType.float64](4088, 1)
    with assert_raises(contains="run past the end"):
        _ = mapped.span[DType.float64](4088, 2)
    with assert_raises(contains="outside"):
        _ = mapped.span[DType.uint8](-8, 1)
    with assert_raises(contains="outside"):
        _ = mapped.span[DType.uint8](4097, 0)
    # a count big enough to overflow offset + count * 8 back into range
    with assert_raises(contains="run past the end"):
        _ = mapped.span[DType.float64](8, Int.MAX // 4)
    with assert_raises(contains="not aligned"):
        _ = mapped.span[DType.float64](12, 1)
    # zero values at the very end is a legitimate empty buffer
    assert_equal(len(mapped.span[DType.uint8](4096, 0)), 0)


def test_a_shared_mapping_refuses_an_empty_file() raises:
    var path = String("/tmp/memory_region_shared_empty.bin")
    with open(path, "w") as f:
        f.write("")
    with assert_raises(contains="is empty"):
        _ = SharedMapping(path)

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
