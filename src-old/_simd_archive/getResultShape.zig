const std = @import("std");
const Address = @import("./operations.zig").Address;
const Operation = @import("./operations.zig").Operation;

/// Runtime equivalent of TypeRep.
pub const Shape = struct {
    count: usize,
    elem_bits: usize,
    elem_alignment: usize,
    is_scalar: bool,
};

pub fn getResultShape(from: [3]Shape, op: Operation) ?Shape {
    const s0 = from[0];
    const s1 = from[1];
    const s2 = from[2];
    
    if (s0.count == 0) return null;

    return switch (op.payload) {
        // 1. Strict Binary Ops
        .Add, .Sub, .Mul, .Div, .Mod, .Min, .Max,
        .AddWrap, .SubWrap, .MulWrap, .AddSat, .SubSat, .MulSat,
        .And, .Or, .Xor, .Shl, .Shr, .ShlSat => blk: {
            if (s1.count == 0) return null;
            if (s0.is_scalar != s1.is_scalar) return null;
            if (!s0.is_scalar and s0.count != s1.count) return null;
            break :blk s0; // Inherit LHS shape
        },

        // 2. Comparisons
        .Eq, .Ne, .Gt, .Ge, .Lt, .Le => blk: {
            if (s1.count == 0) return null;
            if (s0.is_scalar != s1.is_scalar) return null;
            if (!s0.is_scalar and s0.count != s1.count) return null;
            break :blk Shape{
                .count = s0.count,
                .is_scalar = s0.is_scalar,
                .elem_alignment = @alignOf(bool),
                .elem_bits = @bitSizeOf(bool),
            };
        },

        // 3. Unary Ops
        .Neg, .NegWrap, .BitNot, .Abs,
        .Sin, .Cos, .Tan, .Exp, .Exp2, .Log, .Log2, .Log10,
        .Sqrt, .Ceil, .Floor, .Round, .Trunc,
        .BitReverse, .ByteSwap, .Clz, .Ctz, .PopCount, .Copy => s0,

        // 4. Splat - Broadcast scalar to target shape
        .Splat => blk: {
            if (s1.count == 0) return null; // Template must exist
            if (!s0.is_scalar) return null; // Can only splat scalars
            
            break :blk Shape{
                .count = s1.count,
                .is_scalar = s1.is_scalar,
                .elem_alignment = s0.elem_alignment,
                .elem_bits = s0.elem_bits, // Keep value's bit depth
            };
        },

        // 5. Type Conversion
        .As => |o| blk: {
            const target_alignment = @alignOf(o.to_type);
            const target_bits = @bitSizeOf(o.to_type);
            
            break :blk Shape{
                .count = s0.count,
                .is_scalar = s0.is_scalar,
                .elem_alignment = target_alignment,
                .elem_bits = target_bits,
            };
        },

        // 6. BitCast - reinterpret bits with new type
        .BitCast => |o| blk: {
            const target_alignment = @alignOf(o.to_type);
            const target_bits = @bitSizeOf(o.to_type);
            const total_bits_in = s0.count * s0.elem_bits;
            
            if (target_bits == 0) return null;
            if (total_bits_in % target_bits != 0) return null;

            break :blk Shape{
                .count = total_bits_in / target_bits,
                .elem_bits = target_bits,
                .elem_alignment = target_alignment,
                .is_scalar = true, // BitCast always produces scalar or vector based on count
            };
        },

        // 7. Shuffle - rearrange elements from two vectors
        .Shuffle => |o| blk: {
            if (s1.count == 0 or s2.count == 0) return null;
            if (s0.is_scalar or s1.is_scalar or s2.is_scalar) return null;
            if (s0.count != s1.count) return null;
            if (s2.count != o.mask_len) return null;

            break :blk Shape{
                .count = o.mask_len,
                .is_scalar = false,
                .elem_bits = s0.elem_bits,
                .elem_alignment = s0.elem_alignment,
            };
        },

        // 8. Select - choose between two values based on predicate
        .Select => |_| blk: {
            if (s1.count == 0 or s2.count == 0) return null;
            if (s1.is_scalar != s2.is_scalar) return null;
            if (!s1.is_scalar and s1.count != s2.count) return null;
            if (s0.is_scalar != s1.is_scalar) return null;
            if (!s0.is_scalar and s0.count != s1.count) return null;
            break :blk s1;
        },

        // 9. Reduce - reduce vector to scalar
        .Reduce => |_| blk: {
            if (s0.is_scalar) return null;
            break :blk Shape{
                .count = 1,
                .is_scalar = true,
                .elem_bits = s0.elem_bits,
                .elem_alignment = s0.elem_alignment,
            };
        },
    };
}