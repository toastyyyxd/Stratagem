pub fn twoToOne(comptime T: type, dst: []T, src0: []const T, src1: []const T) void {
    const std = @import("std");
    std.debug.assert(dst.len == src0.len + src1.len);
    var counted: usize = 0;
    var src_off: usize = 0;
    while (counted < dst.len) {
        const src = if (src_off < src0.len)
            src0[src_off..]
        else
            src1[src_off - src0.len ..];
        const chunk = @min(src.len, dst.len - counted);
        @memcpy(dst[counted .. counted + chunk], src[0..chunk]);
        counted += chunk;
        src_off += chunk;
    }
}

pub fn twoToTwo(comptime T: type, dst0: []T, dst1: []T, src0: []const T, src1: []const T) void {
    const std = @import("std");
    std.debug.assert(dst0.len + dst1.len == src0.len + src1.len);
    var counted: usize = 0;
    const total = dst0.len + dst1.len;
    while (counted < total) {
        const src = if (counted < src0.len)
            src0[counted..]
        else
            src1[counted - src0.len ..];
        const dst = if (counted < dst0.len)
            dst0[counted..]
        else
            dst1[counted - dst0.len ..];
        const chunk = @min(src.len, dst.len);
        @memcpy(dst[0..chunk], src[0..chunk]);
        counted += chunk;
    }
}
