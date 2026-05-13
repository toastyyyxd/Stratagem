const std = @import("std");

const Operation = @import("./operations.zig").Operation;
const Address = @import("./operations.zig").Address;
const TypeRep = @import("./getToType.zig").TypeRep;
const Shape = @import("./getResultShape.zig").Shape;
const validateRuntime = @import("./validator.zig").validateRuntime;
const timelineComptime = @import("./validator.zig").timelineComptime;
const tallyInputCount = @import("./validator.zig").tallyInputCount;

fn ParamsType(comptime ops: []const Operation, comptime in_types: [tallyInputCount(ops)]TypeRep,) type {
    var types: [in_types.len]type = undefined;
    for (in_types, 0..) |t, i| {
        types[i] = if (t.is_scalar) *t.elem_T
        else []t.elem_T;
    }
    return std.meta.Tuple(&types);
}

const ISA = enum {
    AVX2,
    AVX512,
    NEON
};
const ISAS = @typeInfo(ISA).@"enum".fields;
const ISA_COUNT = @typeInfo(ISA).@"enum".fields.len;
fn PipelineRunners(
    comptime ops: []const Operation,
    comptime in_types: [tallyInputCount(ops)]TypeRep,
) type {
    return [ISA_COUNT]fn(ParamsType(ops, in_types))void;
}
pub fn create(
    comptime ops: []const Operation,
    comptime in_types: [tallyInputCount(ops)]TypeRep,
) PipelineRunners(ops, in_types) {
    _ = timelineComptime(ops, in_types);
    var runners: PipelineRunners(ops, in_types) = undefined;
    for (ISAS, 0..) |_, i| {
        const Impl = struct {
            fn run(inputs: ParamsType(ops, in_types)) void {
                var shapes: [inputs.len]Shape = undefined;
                inline for (inputs, 0..) |input, j| {
                    const ti = @typeInfo(@TypeOf(input));
                    if (ti != .pointer) @compileError("Inputs must be pointers or slices.");
                    const p_ti = ti.pointer;
                    const bit_size = @bitSizeOf(p_ti.child);
                    const alignment = @alignOf(p_ti.child);
                    shapes[j] = switch (p_ti.size) {
                        .one => comptime Shape{ .count = 1, .elem_bits = bit_size, .elem_alignment = alignment, .is_scalar = true },
                        .slice => Shape{ .count = input.len, .elem_bits = bit_size, .elem_alignment = alignment, .is_scalar = false },
                        else => @compileError("Inputs must be pointers or slices, NOT pointers to arrays or c arrays."),
                    };
                }
                if (!validateRuntime(ops, shapes)) std.debug.panic("Invalid SIMD operations at runtime!", .{});
                
            }
        };
        runners[i] = Impl.run;
    }
    return runners;
}


test {
    const ops = [_]Operation{
        Operation{ .payload = .{ .Add = .{ .lhs = 0, .rhs = 1 } }, .to = 0 },
        Operation{ .payload = .{ .Mul = .{ .lhs = 0, .rhs = 1 } }, .to = 2 },
        Operation{ .payload = .{ .Reduce = .{ .from = 2, .op = .Add } }, .to = 3},
    };
    const inputs = [_]TypeRep{
        TypeRep{ .elem_T = u32, .is_scalar = false, .count = 0 },
        TypeRep{ .elem_T = u32, .is_scalar = false, .count = 0 },
        TypeRep{ .elem_T = u32, .is_scalar = false, .count = 0 },
        TypeRep{ .elem_T = u32, .is_scalar = true, .count = 1 },
    };
    const runners = create(&ops, inputs);
    var x: [8]u32 = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var y: [8]u32 = [_]u32{ 2, 3, 4, 5, 6, 7 ,8, 9 };
    var z: [8]u32 = [_]u32{ 4, 5, 6, 7, 8, 9, 10, 11 };
    var w: u32 = undefined;
    runners[2](.{&x, &y, &z, &w});
}