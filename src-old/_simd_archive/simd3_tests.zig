const std = @import("std");
const testing = std.testing;

// Import the module we're testing
const op = @import("simd3.zig");
const Address = op.Address;
const Operation = op.Operation;
const TypeRep = op.TypeRep;
const getToType = op.getToType;

// --- Test Type Definitions ---
const scalar_i32 = TypeRep{ .elem_T = i32, .count = 1, .is_scalar = true };
const scalar_f32 = TypeRep{ .elem_T = f32, .count = 1, .is_scalar = true };
const scalar_bool = TypeRep{ .elem_T = bool, .count = 1, .is_scalar = true };
const scalar_comptime_int = TypeRep{ .elem_T = comptime_int, .count = 1, .is_scalar = true };

const multi_i32_4 = TypeRep{ .elem_T = i32, .count = 4, .is_scalar = false };
const multi_f32_4 = TypeRep{ .elem_T = f32, .count = 4, .is_scalar = false };
const multi_bool_4 = TypeRep{ .elem_T = bool, .count = 4, .is_scalar = false };

const multi_i32_comptime = TypeRep{ .elem_T = i32, .count = 0, .is_scalar = false };
const multi_i32_5 = TypeRep{ .elem_T = i32, .count = 5, .is_scalar = false };

// A placeholder for unused 'from' slots
const unused_slot = TypeRep{ .elem_T = void, .count = 0, .is_scalar = true };

test "getToType - Add (Binary Op)" {
    const op_add = Operation{ .to = 0, .payload = .{ .Add = .{ .lhs = 0, .rhs = 1 } } };

    // (scalar, scalar) -> scalar
    const from_ss = [_]TypeRep{ scalar_i32, scalar_i32, unused_slot };
    const result_ss = getToType(from_ss, op_add);
    try testing.expect(result_ss != null);
    try testing.expectEqual(scalar_i32, result_ss.?);

    // (multi, multi) -> multi
    const from_mm = [_]TypeRep{ multi_f32_4, multi_f32_4, unused_slot };
    const result_mm = getToType(from_mm, op_add);
    try testing.expect(result_mm != null);
    try testing.expectEqual(multi_f32_4, result_mm.?);

    // (multi 4, multi comptime) -> multi 4
    const from_mc = [_]TypeRep{ multi_i32_4, multi_i32_comptime, unused_slot };
    const result_mc = getToType(from_mc, op_add);
    try testing.expect(result_mc != null);
    try testing.expectEqual(multi_i32_4, result_mc.?);

    // --- Failure Cases ---
    // (scalar, multi) - No broadcasting
    const from_sm_fail = [_]TypeRep{ scalar_i32, multi_i32_4, unused_slot };
    const result_sm_fail = getToType(from_sm_fail, op_add);
    try testing.expect(result_sm_fail == null);

    // (i32, f32) - Type mismatch
    const from_type_fail = [_]TypeRep{ scalar_i32, scalar_f32, unused_slot };
    const result_type_fail = getToType(from_type_fail, op_add);
    try testing.expect(result_type_fail == null);

    // (bool, bool) - Invalid type for op
    const from_bool_fail = [_]TypeRep{ scalar_bool, scalar_bool, unused_slot };
    const result_bool_fail = getToType(from_bool_fail, op_add);
    try testing.expect(result_bool_fail == null);
}

test "getToType - Eq (Comparison Op)" {
    const op_eq = Operation{ .to = 0, .payload = .{ .Eq = .{ .lhs = 0, .rhs = 1 } } };

    // (scalar, scalar) -> scalar bool
    const from_ss = [_]TypeRep{ scalar_i32, scalar_i32, unused_slot };
    const result_ss = getToType(from_ss, op_eq);
    try testing.expect(result_ss != null);
    try testing.expectEqual(scalar_bool, result_ss.?);

    // (multi, multi) -> multi bool
    const from_mm = [_]TypeRep{ multi_f32_4, multi_f32_4, unused_slot };
    const result_mm = getToType(from_mm, op_eq);
    try testing.expect(result_mm != null);
    try testing.expectEqual(multi_bool_4, result_mm.?);

    // (multi 4, multi comptime) -> multi 4 bool
    const from_mc = [_]TypeRep{ multi_i32_4, multi_i32_comptime, unused_slot };
    const result_mc = getToType(from_mc, op_eq);
    try testing.expect(result_mc != null);
    try testing.expectEqual(TypeRep{ .elem_T = bool, .count = 4, .is_scalar = false }, result_mc.?);
}

test "getToType - Neg (Unary Op)" {
    const op_neg = Operation{ .to = 0, .payload = .{ .Neg = .{ .operand = 0 } } };

    // scalar i32
    const from_i32 = [_]TypeRep{ scalar_i32, unused_slot, unused_slot };
    const result_i32 = getToType(from_i32, op_neg);
    try testing.expect(result_i32 != null);
    try testing.expectEqual(scalar_i32, result_i32.?);

    // multi f32
    const from_f32 = [_]TypeRep{ multi_f32_4, unused_slot, unused_slot };
    const result_f32 = getToType(from_f32, op_neg);
    try testing.expect(result_f32 != null);
    try testing.expectEqual(multi_f32_4, result_f32.?);

    // --- Failure Cases ---
    // bool
    const from_bool_fail = [_]TypeRep{ scalar_bool, unused_slot, unused_slot };
    const result_bool_fail = getToType(from_bool_fail, op_neg);
    try testing.expect(result_bool_fail == null);
}

test "getToType - Copy" {
    const op_copy = Operation{ .to = 0, .payload = .{ .Copy = .{ .from = 0 } } };
    const from = [_]TypeRep{ multi_i32_4, unused_slot, unused_slot };
    const result = getToType(from, op_copy);
    try testing.expect(result != null);
    try testing.expectEqual(multi_i32_4, result.?);
}

test "getToType - Splat" {
    const op_splat = Operation{ .to = 0, .payload = .{ .Splat = .{ .from = 0 } } };

    // scalar -> multi comptime
    const from_ok = [_]TypeRep{ scalar_i32, unused_slot, unused_slot };
    const result_ok = getToType(from_ok, op_splat);
    try testing.expect(result_ok != null);
    try testing.expectEqual(multi_i32_comptime, result_ok.?);

    // --- Failure Cases ---
    // multi -> ???
    const from_fail = [_]TypeRep{ multi_i32_4, unused_slot, unused_slot };
    const result_fail = getToType(from_fail, op_splat);
    try testing.expect(result_fail == null);
}

test "getToType - Reduce" {
    // multi i32 -> scalar i32
    const op_reduce_add = Operation{ .to = 0, .payload = .{ .Reduce = .{ .from = 0, .op = .Add } } };
    const from_ok = [_]TypeRep{ multi_i32_4, unused_slot, unused_slot };
    const result_ok = getToType(from_ok, op_reduce_add);
    try testing.expect(result_ok != null);
    try testing.expectEqual(scalar_i32, result_ok.?);

    // multi comptime -> scalar
    const from_comptime = [_]TypeRep{ multi_i32_comptime, unused_slot, unused_slot };
    const result_comptime = getToType(from_comptime, op_reduce_add);
    try testing.expect(result_comptime != null);
    try testing.expectEqual(scalar_i32, result_comptime.?);

    // --- Failure Cases ---
    // scalar -> ???
    const from_scalar_fail = [_]TypeRep{ scalar_i32, unused_slot, unused_slot };
    const result_scalar_fail = getToType(from_scalar_fail, op_reduce_add);
    try testing.expect(result_scalar_fail == null);

    // Add on bool
    const op_reduce_add_bool = Operation{ .to = 0, .payload = .{ .Reduce = .{ .from = 0, .op = .Add } } };
    const from_bool_fail = [_]TypeRep{ multi_bool_4, unused_slot, unused_slot };
    const result_bool_fail = getToType(from_bool_fail, op_reduce_add_bool);
    try testing.expect(result_bool_fail == null);

    // Xor on float
    const op_reduce_xor_f32 = Operation{ .to = 0, .payload = .{ .Reduce = .{ .from = 0, .op = .Xor } } };
    const from_float_fail = [_]TypeRep{ multi_f32_4, unused_slot, unused_slot };
    const result_float_fail = getToType(from_float_fail, op_reduce_xor_f32);
    try testing.expect(result_float_fail == null);
}

test "getToType - BitCast" {
    // (scalar i32) -> scalar f32
    const op_cast_i32_f32 = Operation{ .to = 0, .payload = .{ .BitCast = .{ .from = 0, .to_type = f32 } } };
    const from_i32 = [_]TypeRep{ scalar_i32, unused_slot, unused_slot };
    const result_i32_f32 = getToType(from_i32, op_cast_i32_f32);
    try testing.expect(result_i32_f32 != null);
    try testing.expectEqual(scalar_f32, result_i32_f32.?);

    // (multi 4 i32) -> (multi 4 f32)
    const op_cast_v4i32_v4f32 = Operation{ .to = 0, .payload = .{ .BitCast = .{ .from = 0, .to_type = @Vector(4, f32) } } };
    const from_v4i32 = [_]TypeRep{ multi_i32_4, unused_slot, unused_slot };
    const result_v4i32_v4f32 = getToType(from_v4i32, op_cast_v4i32_v4f32);
    try testing.expect(result_v4i32_v4f32 != null);
    try testing.expectEqual(multi_f32_4, result_v4i32_v4f32.?);

    // (multi 4 i32) -> scalar u128 (128 bits -> 128 bits)
    const op_cast_v4i32_u128 = Operation{ .to = 0, .payload = .{ .BitCast = .{ .from = 0, .to_type = u128 } } };
    const from_v4i32_u128 = [_]TypeRep{ multi_i32_4, unused_slot, unused_slot };
    const result_v4i32_u128 = getToType(from_v4i32_u128, op_cast_v4i32_u128);
    try testing.expect(result_v4i32_u128 != null);
    try testing.expectEqual(TypeRep{ .elem_T = u128, .count = 1, .is_scalar = true }, result_v4i32_u128.?);

    // --- Failure Cases ---
    // (i32) -> i64 (size mismatch)
    const op_cast_size_fail = Operation{ .to = 0, .payload = .{ .BitCast = .{ .from = 0, .to_type = i64 } } };
    const from_size_fail = [_]TypeRep{ scalar_i32, unused_slot, unused_slot };
    const result_size_fail = getToType(from_size_fail, op_cast_size_fail);
    try testing.expect(result_size_fail == null);

    // (comptime_int) -> f32 (comptime from)
    const op_cast_comptime_from_fail = Operation{ .to = 0, .payload = .{ .BitCast = .{ .from = 0, .to_type = f32 } } };
    const from_comptime_from_fail = [_]TypeRep{ scalar_comptime_int, unused_slot, unused_slot };
    const result_comptime_from_fail = getToType(from_comptime_from_fail, op_cast_comptime_from_fail);
    try testing.expect(result_comptime_from_fail == null);

    // i32 -> comptime_int (comptime to)
    const op_cast_comptime_to_fail = Operation{ .to = 0, .payload = .{ .BitCast = .{ .from = 0, .to_type = comptime_int } } };
    const from_comptime_to_fail = [_]TypeRep{ scalar_i32, unused_slot, unused_slot };
    const result_comptime_to_fail = getToType(from_comptime_to_fail, op_cast_comptime_to_fail);
    try testing.expect(result_comptime_to_fail == null);

    // multi comptime -> ... (comptime count)
    const op_cast_comptime_count_fail = Operation{ .to = 0, .payload = .{ .BitCast = .{ .from = 0, .to_type = f32 } } };
    const from_comptime_count_fail = [_]TypeRep{ multi_i32_comptime, unused_slot, unused_slot };
    const result_comptime_count_fail = getToType(from_comptime_count_fail, op_cast_comptime_count_fail);
    try testing.expect(result_comptime_count_fail == null);
}

test "getToType - Select" {
    const op_select = Operation{ .to = 0, .payload = .{ .Select = .{ .pred = 0, .a = 1, .b = 2, .T = i32 } } };

    // (scalar bool, scalar i32, scalar i32) -> scalar i32
    const from_ss = [_]TypeRep{ scalar_bool, scalar_i32, scalar_i32 };
    const result_ss = getToType(from_ss, op_select);
    try testing.expect(result_ss != null);
    try testing.expectEqual(scalar_i32, result_ss.?);

    // (multi 4 bool, multi 4 i32, multi 4 i32) -> multi 4 i32
    const from_mm = [_]TypeRep{ multi_bool_4, multi_i32_4, multi_i32_4 };
    const result_mm = getToType(from_mm, op_select);
    try testing.expect(result_mm != null);
    try testing.expectEqual(multi_i32_4, result_mm.?);

    // (multi 4 bool, multi 4 i32, multi comptime i32) -> multi 4 i32
    const from_mc = [_]TypeRep{ multi_bool_4, multi_i32_4, multi_i32_comptime };
    const result_mc = getToType(from_mc, op_select);
    try testing.expect(result_mc != null);
    try testing.expectEqual(multi_i32_4, result_mc.?);

    // --- Failure Cases ---
    // (scalar bool, multi i32, multi i32) - scalar-ness mismatch
    const from_sm_fail = [_]TypeRep{ scalar_bool, multi_i32_4, multi_i32_4 };
    const result_sm_fail = getToType(from_sm_fail, op_select);
    try testing.expect(result_sm_fail == null);

    // (multi bool, scalar i32, scalar i32) - scalar-ness mismatch
    const from_ms_fail = [_]TypeRep{ multi_bool_4, scalar_i32, scalar_i32 };
    const result_ms_fail = getToType(from_ms_fail, op_select);
    try testing.expect(result_ms_fail == null);

    // (multi 4 bool, multi 5 i32, multi 5 i32) - count mismatch
    const from_count_fail = [_]TypeRep{ multi_bool_4, multi_i32_5, multi_i32_5 };
    const result_count_fail = getToType(from_count_fail, op_select);
    try testing.expect(result_count_fail == null);

    // (multi 4 bool, multi 4 i32, multi 4 f32) - data type mismatch
    const from_type_fail = [_]TypeRep{ multi_bool_4, multi_i32_4, multi_f32_4 };
    const result_type_fail = getToType(from_type_fail, op_select);
    try testing.expect(result_type_fail == null);

    // (multi 4 i32, multi 4 i32, multi 4 i32) - pred not bool
    const from_pred_fail = [_]TypeRep{ multi_i32_4, multi_i32_4, multi_i32_4 };
    const result_pred_fail = getToType(from_pred_fail, op_select);
    try testing.expect(result_pred_fail == null);
}

test "getToType - Shuffle" {
    const op_shuffle = Operation{ .to = 0, .payload = .{
        .Shuffle = .{
            .a = 0,
            .b = 1,
            .E = i32, // mask element type
            .mask_addr = 2,
            .mask_len = 5, // output length
        },
    } };

    // (multi 4 i32, multi 4 i32, multi 5 i32) -> multi 5 i32
    const from_ok = [_]TypeRep{ multi_i32_4, multi_i32_4, multi_i32_5 };
    const result_ok = getToType(from_ok, op_shuffle);
    try testing.expect(result_ok != null);
    try testing.expectEqual(multi_i32_5, result_ok.?);

    // (multi 4 i32, multi comptime i32, multi 5 i32) -> multi 5 i32
    const from_comptime = [_]TypeRep{ multi_i32_4, multi_i32_comptime, multi_i32_5 };
    const result_comptime = getToType(from_comptime, op_shuffle);
    try testing.expect(result_comptime != null);
    try testing.expectEqual(multi_i32_5, result_comptime.?);

    // --- Failure Cases ---
    // mask_len mismatch
    const op_shuffle_bad_len = Operation{ .to = 0, .payload = .{
        .Shuffle = .{
            .a = 0,
            .b = 1,
            .E = i32,
            .mask_addr = 2,
            .mask_len = 99, // mismatch with from[2].count
        },
    } };
    const from_len_fail = [_]TypeRep{ multi_i32_4, multi_i32_4, multi_i32_5 };
    const result_len_fail = getToType(from_len_fail, op_shuffle_bad_len);
    try testing.expect(result_len_fail == null);

    // mask elem_T mismatch
    const op_shuffle_bad_E = Operation{ .to = 0, .payload = .{
        .Shuffle = .{
            .a = 0,
            .b = 1,
            .E = f32, // Mismatch with from[2].elem_T
            .mask_addr = 2,
            .mask_len = 5,
        },
    } };
    const from_E_fail = [_]TypeRep{ multi_i32_4, multi_i32_4, multi_i32_5 };
    const result_E_fail = getToType(from_E_fail, op_shuffle_bad_E);
    try testing.expect(result_E_fail == null);

    // mask elem_T not int
    const op_shuffle_bad_E_float = Operation{ .to = 0, .payload = .{
        .Shuffle = .{
            .a = 0,
            .b = 1,
            .E = f32, // Not an integer type
            .mask_addr = 2,
            .mask_len = 5,
        },
    } };
    const from_E_float = [_]TypeRep{ multi_i32_4, multi_i32_4, TypeRep{ .elem_T = f32, .count = 5, .is_scalar = false } };
    const result_E_float = getToType(from_E_float, op_shuffle_bad_E_float);
    try testing.expect(result_E_float == null);

    // 'a' is scalar
    const from_scalar_fail = [_]TypeRep{ scalar_i32, multi_i32_4, multi_i32_5 };
    const result_scalar_fail = getToType(from_scalar_fail, op_shuffle);
    try testing.expect(result_scalar_fail == null);
}