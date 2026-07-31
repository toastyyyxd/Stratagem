const std = @import("std");
const simd = std.simd;

pub fn iotaFill(comptime T: type, buffer: []T, base: T) void {
    const lanes = simd.suggestVectorLength(T) orelse 8;
    const gradient: @Vector(lanes, T) = simd.iota(T, lanes);
    const vectorized = buffer.len - (buffer.len % lanes);
    var i: usize = 0;
    while (i < vectorized) : (i += lanes) {
        const offset: @Vector(lanes, T) = @splat(base + @as(T, @intCast(i)));
        buffer[i..][0..lanes].* = offset + gradient;
    }
    while (i < buffer.len) : (i += 1) buffer[i] = base + @as(T, @intCast(i));
}

pub fn reduce(comptime T: type, comptime op: std.builtin.ReduceOp, buffer: []const T) T {
    const lanes = simd.suggestVectorLength(T) orelse 8;
    const vectorized = buffer.len - (buffer.len % lanes);
    var acc: @Vector(lanes, T) = @splat(identity(T, op));
    var i: usize = 0;
    while (i < vectorized) : (i += lanes) {
        acc = combine(op, acc, @as(@Vector(lanes, T), buffer[i..][0..lanes].*));
    }
    var result: T = @reduce(op, acc);
    while (i < buffer.len) : (i += 1) result = combine(op, result, buffer[i]);
    return result;
}

fn combine(comptime op: std.builtin.ReduceOp, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return switch (op) {
        .Add => a + b,
        .Mul => a * b,
        .Min => @min(a, b),
        .Max => @max(a, b),
        .And => a & b,
        .Or => a | b,
        .Xor => a ^ b,
    };
}

fn identity(comptime T: type, comptime op: std.builtin.ReduceOp) T {
    return switch (@typeInfo(T)) {
        .int => switch (op) {
            .Add, .Or, .Xor => 0,
            .Mul => 1,
            .And, .Min => std.math.maxInt(T),
            .Max => std.math.minInt(T),
        },
        .float => switch (op) {
            .Add => 0,
            .Mul => 1,
            .Min => std.math.inf(T),
            .Max => -std.math.inf(T),
            else => @compileError("bitwise reduce op unsupported for float type " ++ @typeName(T)),
        },
        .bool => switch (op) {
            .Or, .Xor => false,
            .And => true,
            else => @compileError("arithmetic reduce op unsupported for bool"),
        },
        else => @compileError("unsupported reduce element type " ++ @typeName(T)),
    };
}
