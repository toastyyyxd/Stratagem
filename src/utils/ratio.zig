const std = @import("std");

pub fn simplify(a: anytype, b: anytype) Ratio(@TypeOf(a, b)) {
    const gcd_val = std.math.gcd(a, b);
    return .{
        .a = a / gcd_val,
        .b = b / gcd_val,
    };
}

pub fn Ratio(comptime T: type) type {
    return struct {
        a: T,
        b: T,
    };
}
