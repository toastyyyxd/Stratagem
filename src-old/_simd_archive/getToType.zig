const std = @import("std");
const Address = @import("./operations.zig").Address;
const Operation = @import("./operations.zig").Operation;

pub const TypeRep = struct {
    elem_T: type,
    count: usize,
    is_scalar: bool,

    pub fn is_int(self: TypeRep) bool {
        const ti = @typeInfo(self.elem_T);
        return ti == .int or ti == .comptime_int;
    }

    pub fn is_float(self: TypeRep) bool {
        const ti = @typeInfo(self.elem_T);
        return ti == .float or ti == .comptime_float;
    }

    pub fn is_bool(self: TypeRep) bool {
        return @typeInfo(self.elem_T) == .bool;
    }
};

// --- Step 2: Logic Extraction ---

/// Defines what element types are allowed for an operation.
const Constraint = enum {
    Int, Float, Bool,
    IntFloat, IntBool, Any
};

/// Validates that two types can be combined (counts match) and elements match.
/// Returns the resulting "shape" (count + is_scalar) or null.
fn merge_shapes(a: TypeRep, b: TypeRep) ?TypeRep {
    // 1. Scalar-ness must match (no broadcasting scalar vs multi here)
    if (a.is_scalar != b.is_scalar) return null;

    // 2. If Multi, counts must match (or be comptime 0)
    const counts_ok = a.is_scalar or (a.count == b.count or a.count == 0 or b.count == 0);
    if (!counts_ok) return null;

    return TypeRep{
        .elem_T = void, // Placeholder
        .count = if (a.is_scalar) 1 else @max(a.count, b.count),
        .is_scalar = a.is_scalar and b.is_scalar,
    };
}

/// Generic validator for Binary Operations (preserve input type).
fn check_bin_op(a: TypeRep, b: TypeRep, constraint: Constraint) ?TypeRep {
    // Check Element Type identity
    if (!std.meta.eql(a.elem_T, b.elem_T)) return null;

    // Check Constraints
    const valid_type = switch (constraint) {
        .Int => a.is_int(),
        .Float => a.is_float(),
        .IntFloat => a.is_int() or a.is_float(),
        .IntBool => a.is_int() or a.is_bool(),
        .Any => true,
        else => return null,
    };
    if (!valid_type) return null;

    // Check Shape compatibility
    var res = merge_shapes(a, b) orelse return null;
    res.elem_T = a.elem_T; // Result type is input type
    return res;
}

/// Generic validator for Comparisons (result is bool).
fn check_cmp_op(a: TypeRep, b: TypeRep, constraint: Constraint) ?TypeRep {
    // Identical inputs required
    if (!std.meta.eql(a.elem_T, b.elem_T)) return null;

    // Check Constraints
    const valid_type = switch (constraint) {
        .IntFloat => a.is_int() or a.is_float(),
        .Any => true,
        else => return null,
    };
    if (!valid_type) return null;

    var res = merge_shapes(a, b) orelse return null;
    res.elem_T = bool; // Result type is always boolean
    return res;
}

/// Generic validator for Unary Operations.
fn check_un_op(a: TypeRep, constraint: Constraint) ?TypeRep {
    const valid = switch (constraint) {
        .Int => a.is_int(),
        .Float => a.is_float(),
        .IntFloat => a.is_int() or a.is_float(),
        else => return null,
    };
    return if (valid) a else null;
}

pub fn getToType(from: [3]TypeRep, op: Operation) ?TypeRep {
    const t0 = from[0];
    const t1 = from[1];
    // t2 is only used in Select/Shuffle

    return switch (op.payload) {
        // 1. Arithmetic & Math (Result == Input Type)
        .Add, .Sub, .Mul, .Div, .Mod, .Min, .Max =>
            check_bin_op(t0, t1, .IntFloat),

        .AddWrap, .SubWrap, .MulWrap, .AddSat, .SubSat, .MulSat =>
            check_bin_op(t0, t1, .Int),

        .And, .Or, .Xor =>
            check_bin_op(t0, t1, .IntBool),

        // 2. Bit Shifts (Special Case: Inputs are ints, shapes compatible, result is LHS type)
        .Shl, .Shr, .ShlSat => blk: {
            if (!t0.is_int() or !t1.is_int()) break :blk null;
            var res = merge_shapes(t0, t1) orelse break :blk null;
            res.elem_T = t0.elem_T;
            break :blk res;
        },

        // 3. Comparisons (Result == Bool)
        .Eq, .Ne =>
            check_cmp_op(t0, t1, .Any),

        .Gt, .Ge, .Lt, .Le =>
            check_cmp_op(t0, t1, .IntFloat),

        // 4. Unary Ops
        .Neg, .Abs =>
            check_un_op(t0, .IntFloat),

        .NegWrap, .BitNot, .BitReverse, .ByteSwap, .Clz, .Ctz, .PopCount =>
            check_un_op(t0, .Int),

        .Sin, .Cos, .Tan, .Exp, .Exp2, .Log, .Log2, .Log10,
        .Sqrt, .Ceil, .Floor, .Round, .Trunc =>
            check_un_op(t0, .Float),

        // 5. Special Operations (Logic kept specific)
        .Copy => t0,

        .Splat => if (t0.is_scalar) TypeRep{
            .elem_T = t0.elem_T, .count = 0, .is_scalar = false
        } else null,

        .Reduce => |o| blk: {
            if (t0.is_scalar) break :blk null;
            const valid = switch (o.op) {
                .And, .Or, .Xor => t0.is_int() or t0.is_bool(),
                else => t0.is_int() or t0.is_float(),
            };
            break :blk if (valid) TypeRep{ .elem_T = t0.elem_T, .count = 1, .is_scalar = true } else null;
        },

        .As => |o| TypeRep{
            .elem_T = o.to_type,
            .count = t0.count,
            .is_scalar = t0.is_scalar,
        },

        .BitCast => |o| blk: {
            // 1. Cannot cast from runtime-unknown length
            if (t0.count == 0) break :blk null; 

            // 2. Validate Input Element Type (must have concrete size)
            const ti_in = @typeInfo(t0.elem_T);
            if (ti_in == .comptime_int or ti_in == .comptime_float) break :blk null;

            // 3. Determine Output Shape
            // BitCast target `to_type` is a raw Zig type (e.g. i32 or @Vector(4, i32))
            const to_rep = TypeRep{ .elem_T = o.to_type, .count = 1, .is_scalar = true };

            // 4. Validate Output Element Type
            const ti_out = @typeInfo(to_rep.elem_T);
            if (ti_out == .comptime_int or ti_out == .comptime_float) break :blk null;

            // 5. Strict Bit-Size Equality Check
            const in_bits = @bitSizeOf(t0.elem_T) * t0.count;
            const out_bits = @bitSizeOf(to_rep.elem_T) * to_rep.count;

            if (in_bits != out_bits) break :blk null;

            break :blk to_rep;
        },

        .Select => |o| blk: {
            const t2 = from[2]; // pred, a, b
            // Check A and B compatibility
            if (!std.meta.eql(t1.elem_T, t2.elem_T)) break :blk null;
            if (t1.elem_T != o.T) break :blk null;
            const data_res = merge_shapes(t1, t2) orelse break :blk null;

            // Check Predicate
            if (!t0.is_bool()) break :blk null;
            
            // Predicate shape must match data shape logic
            if (t0.is_scalar != data_res.is_scalar) break :blk null;
            if (!t0.is_scalar) {
                 const pred_res = merge_shapes(t0, data_res) orelse break :blk null;
                 // Return result with data element type and max count
                 break :blk TypeRep{ .elem_T = t1.elem_T, .count = pred_res.count, .is_scalar = false };
            }
            break :blk t1; // Scalar case
        },

        .Shuffle => |o| blk: {
             const t2 = from[2];
             // Check scalar-ness
             if (t0.is_scalar or t1.is_scalar or t2.is_scalar) break :blk null;
             // Check types
             if (t0.elem_T != t1.elem_T or t2.elem_T != o.E) break :blk null;
             // Check shapes
             const ab_shape = merge_shapes(t0, t1) orelse break :blk null;
             _ = ab_shape;
             
             // Mask checks
             const mask_int = @typeInfo(o.E) == .int or @typeInfo(o.E) == .comptime_int;
             const mask_len_ok = (t2.count == o.mask_len) or (t2.count == 0);
             
             if (mask_int and mask_len_ok) {
                 break :blk TypeRep{ .elem_T = t0.elem_T, .count = o.mask_len, .is_scalar = false };
             }
             break :blk null;
        },
    };
}