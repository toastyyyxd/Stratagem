const std = @import("std");

pub fn conv(indices: []u32, stride: u64, offset: u64, out: []u64) []u64 {
    std.debug.assert(out.len == indices.len);

    var n = indices.len;
    while (n >= 8) : (n -= 8) {
        const i = n - 8;
        asm volatile (
            \\ vmovdqu %%ymm0, %[in]
            \\ vpmovzxdq %%ymm0, %%zmm0
            \\ movq %[stride], %%xmm1
            \\ vpbroadcastq %%xmm1, %%zmm1
            \\ movq %[offset], %%xmm2
            \\ vpbroadcastq %%xmm2, %%%zmm2
            \\ vpmullq %%zmm1, %%zmm0, %%zmm3
            \\ vpaddq %%zmm2, %%zmm3, %%zmm4
            \\ vmovdqu64 %%zmm4, %[out]
            : [out] "m&=" (),
            : [in] "m" (indices.ptr + i),
              [stride] "r" (stride),
              [offset] "r" (offset),
            : .{ .ymm0 = true, .zmm0 = true, .xmm1 = true, .zmm1 = true, .xmm2 = true, .zmm2 = true, .zmm3 = true, .zmm4 = true, .memory = true, .cc = true });
    }

    // Scalar tail
    for (out[0..n], 0..) |*dst, j| {
        dst.* = stride * @as(u64, indices[j]) + offset;
    }

    return out;
}

test "conv in-place with shared buffer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const N = 16;

    // Allocate backing memory as u64s
    var buf = try allocator.alloc(u64, N);
    defer allocator.free(buf);

    // Fill the low 32 bits with indices
    for (buf, 0..) |*slot, i| {
        slot.* = @as(u32, @intCast(i)); // store as u32 in low half
    }

    // Create two views: indices as []u32, out as []u64
    const indices = @as([*]u32, @ptrCast(buf.ptr))[0..N];
    const out = buf[0..N];

    const stride: u64 = 10;
    const offset: u64 = 5;

    const result = conv(indices, stride, offset, out);

    // Verify
    for (result, 0..) |val, i| {
        const expected = stride * @as(u64, i) + offset;
        try std.testing.expectEqual(expected, val);
    }
}
