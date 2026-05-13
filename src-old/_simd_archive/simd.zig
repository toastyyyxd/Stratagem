const std = @import("std");

pub fn inplaceIndicesToPointers(src: []const u32, dest: []usize, factor: usize, base: usize) void {
    std.debug.assert(src.len == dest.len);

    const simd_size = std.simd.suggestVectorLength(usize) orelse 1;
    const VecUsize = @Vector(simd_size, usize);

    const factor_vec: VecUsize = @splat(factor);
    const base_vec: VecUsize = @splat(base);

    std.debug.assert(std.mem.isAligned(@intFromPtr(dest.ptr), @alignOf(VecUsize)));

    std.debug.print("Vector width: {}, Type size: {}\n", .{simd_size, @sizeOf(usize)});

    var i: usize = dest.len;
    while (i >= simd_size) {
        i -= simd_size;
        const src_chunk: *const [simd_size]u32 = @ptrCast(src.ptr + i);
        const dest_chunk: *VecUsize = @alignCast(@ptrCast(dest.ptr + i));
        dest_chunk.* = @as(VecUsize, src_chunk.*);
        dest_chunk.* *= factor_vec;
        dest_chunk.* += base_vec;
    }
    while (i > 0) { // Scalar tail
        i -= 1;
        dest[i] = base + @as(usize, src[i]) * factor;
    }
}



test "inplace SIMD reinterpretation" {
    const N = 512;
    var buffer: [N]usize align(32) = undefined;

    // view the buffer as u32s for filling
    const src_u32 = @as([*]u32, @ptrCast(&buffer))[0..N];
    for (src_u32, 0..) |*d, idx| {
        d.* = @as(u32, @truncate(idx));
    }

    // view the same buffer as usize for output
    const dest_usize = buffer[0..];

    inplaceIndicesToPointers(src_u32, dest_usize, 10, 100);

    for (dest_usize, 0..) |d, idx| {
        try std.testing.expectEqual(@as(usize, idx) * 10 + 100, d);
    }
}
