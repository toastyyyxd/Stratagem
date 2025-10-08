const std = @import("std");
const linux = std.os.linux;

pub fn pinCurrentThreadToCore(core: usize) !void {
    const bits = @bitSizeOf(usize);
    const max_cores = 16 * bits;
    if (core >= max_cores) return error.CoreOutOfRange;

    var mask: [16]usize = undefined;
    @memset(std.mem.sliceAsBytes(mask[0..]), 0);

    const word_i = core / bits;
    const bit_i = core % bits;

    mask[word_i] = @as(usize, 1) << @intCast(bit_i);
    try linux.sched_setaffinity(@intCast(std.Thread.getCurrentId()), &mask);
}
