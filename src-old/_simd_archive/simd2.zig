const std = @import("std");

pub const Address = usize;

/// Every operation has a destination `.to` address.
/// The payload union only contains the operands and metadata.
pub const Operation = struct {
    to: Address,

    payload: union(enum) {
        // math operations
        Add: struct { lhs: Address, rhs: Address },
        Sub: struct { lhs: Address, rhs: Address },
        Mul: struct { lhs: Address, rhs: Address },
        Div: struct { lhs: Address, rhs: Address },
        Mod: struct { lhs: Address, rhs: Address },
        Min: struct { lhs: Address, rhs: Address },
        Max: struct { lhs: Address, rhs: Address },

        // Wrapping operations
        AddWrap: struct { lhs: Address, rhs: Address },
        SubWrap: struct { lhs: Address, rhs: Address },
        MulWrap: struct { lhs: Address, rhs: Address },

        // Saturating operations
        AddSat: struct { lhs: Address, rhs: Address },
        SubSat: struct { lhs: Address, rhs: Address },
        MulSat: struct { lhs: Address, rhs: Address },

        // Bit shifts (lane-wise)
        Shl: struct { lhs: Address, rhs: Address },
        Shr: struct { lhs: Address, rhs: Address },
        ShlSat: struct { lhs: Address, rhs: Address },

        // Bitwise operations
        And: struct { lhs: Address, rhs: Address },
        Or: struct { lhs: Address, rhs: Address },
        Xor: struct { lhs: Address, rhs: Address },

        // Comparisons
        Eq: struct { lhs: Address, rhs: Address },
        Ne: struct { lhs: Address, rhs: Address },
        Gt: struct { lhs: Address, rhs: Address },
        Ge: struct { lhs: Address, rhs: Address },
        Lt: struct { lhs: Address, rhs: Address },
        Le: struct { lhs: Address, rhs: Address },

        // Unary operations
        Neg: struct { operand: Address },
        NegWrap: struct { operand: Address },
        BitNot: struct { operand: Address },
        Abs: struct { operand: Address },
        Sin: struct { operand: Address },
        Cos: struct { operand: Address },
        Tan: struct { operand: Address },
        Exp: struct { operand: Address },
        Exp2: struct { operand: Address },
        Log: struct { operand: Address },
        Log2: struct { operand: Address },
        Log10: struct { operand: Address },
        Sqrt: struct { operand: Address },
        Ceil: struct { operand: Address },
        Floor: struct { operand: Address },
        Round: struct { operand: Address },
        Trunc: struct { operand: Address },
        BitReverse: struct { operand: Address },
        ByteSwap: struct { operand: Address },
        Clz: struct { operand: Address },
        Ctz: struct { operand: Address },
        PopCount: struct { operand: Address },

        // Special operations
        As: struct { from: Address, to_type: type },
        BitCast: struct { from: Address, to_type: type },
        Shuffle: struct {
            a: Address,
            b: Address,
            E: type,
            mask_addr: Address,
            mask_len: usize,
        },
        Select: struct {
            pred: Address,
            a: Address,
            b: Address,
            T: type,
        },
        Reduce: struct {
            from: Address,
            op: std.builtin.ReduceOp,
        },
        Splat: struct { from: Address },

        // Addon operations
        Copy: struct { from: Address },
    },
};

/// Transformation classification
const OpApproxTransformation = union(enum) {
    SameAsInput,
    VectorToScalar,
    ScalarToVector,
    ResizedVector,
    Casted: type,
};

fn getOpApproxTransformation(comptime op: Operation) OpApproxTransformation {
    return comptime switch (op.payload) {
        .Abs, .Add, .AddSat, .AddWrap, .And, .BitNot, .BitReverse, .ByteSwap, .Ceil, .Clz, .Copy, .Cos, .Ctz, .Div, .Eq, .Exp, .Exp2, .Floor, .Ge, .Gt, .Le, .Log, .Log10, .Log2, .Lt, .Max, .Min, .Mod, .Mul, .MulSat, .MulWrap, .Ne, .Neg, .NegWrap, .Or, .PopCount, .Round, .Shl, .ShlSat, .Shr, .Select, .Sin, .Sqrt, .Sub, .SubSat, .SubWrap, .Tan, .Trunc, .Xor => OpApproxTransformation.SameAsInput,
        .As, .BitCast => @as(OpApproxTransformation.Casted, op.payload.Cast.to_type),
        .Reduce => OpApproxTransformation.VectorToScalar,
        .Splat => .ScalarToVector,
        .Shuffle => .ResizedVector,
        else => unreachable,
    };
}

fn isIntType(T: type) bool {
    const info = @typeInfo(T);
    return info == .int or info == .comptime_int or (info == .vector and isIntType(info.vector.child));
}
fn isFloatType(T: type) bool {
    const info = @typeInfo(T);
    return info == .float or info == .comptime_float or (info == .vector and isFloatType(info.vector.child));
}
fn isBoolType(T: type) bool {
    const info = @typeInfo(T);
    return info == .bool or (info == .vector and isBoolType(info.vector.child));
}
fn isVectorType(T: type) bool {
    return @typeInfo(T) == .vector;
}
fn getVectorLen(T: type) usize {
    return @typeInfo(T).vector.len;
}
fn getVectorType(T: type) type {
    return @typeInfo(T).vector.child;
}
const TypeRepGenre = enum {
    Int, Float, Bool, Other
};
const TypeRep = struct {
    /// Type of the scalar or elements in the vector.
    T: type,
    /// Whether this is representing a vector.
    is_vector: bool,
    /// Genre of type.
    genre: TypeRepGenre,
    /// Optional size of the vector if at runtime, *not* byte-length or size of `T`.
    size: ?usize,
    pub fn typeToRep(T: type) TypeRep {
        const elem_T = if (isVectorType(T)) getVectorType(T) else T;
        return .{
            .T = elem_T,
            .is_vector = isVectorType(T),
            .genre = blk: {
                break :blk
                if (isBoolType(elem_T)) .Bool
                else if (isIntType(elem_T)) .Int
                else if (isFloatType(elem_T)) .Float
                else .Other;
            }
        };
    }
    pub fn repToType(t: TypeRep) type {
        return if (t.is_vector)
            // Dummy non-1, non-0 length of 2 for comptime.
            @Vector(t.size orelse 2, t.T)
        else t.T;
    }
};



fn getResultType(from: [3]type, To: type, op: Operation) ?type {
    return switch (op.payload) {
        .Add, .Sub, .Mul, .Div, .Mod, .Min, .Max => |o| {
            const c1 = isIntType(from[0]) or isFloatType(from[0]);
            const c2 = from[0] == from[1];
            return if (c1 and c2) from[0] else null;
        },
        .AddWrap, .SubWrap, .MulWrap, .AddSat, .SubSat, .MulSat => |o| {
            const c1 = isIntType(from[0]);
            const c2 = from[0] == from[1];
            return if (c1 and c2) from[0] else null;
        },
        .Shl, .Shr, .ShlSat => |o| {
            const c1 = isIntType(from[0]) and isIntType(from[1]);
            const c2 = isVectorType(from[0]) == isVectorType(from[1]);
            //const c3 = getVectorLen(from[0]) == getVectorLen(from[1]);
            return if (c1 and c2) from[0] else null;
        },
        .And, .Or, .Xor => |o| {
            const c1 = isIntType(from[0]) or isFloatType(from[0]) or isBoolType(from[0]);
            const c2 = from[0] == from[1];
            return if (c1 and c2) from[0] else null;
        },
        .Eq, .Ne => |o| {
            const c1 = from[0] == from[1];
            if (!c1) return null;
            return if(isVectorType(from[0]))
                @Vector(getVectorLen(from[0]), bool)
            else bool;
        },
        .Gt, .Ge, .Lt, .Le => |o| {
            const c1 = isIntType(from[0]) or isFloatType(from[0]);
            const c2 = from[0] == from[1];
            if (!(c1 and c2)) return null;
            return if (isVectorType(from[0]))
                @Vector(getVectorLen(from[0]), bool)
            else bool;
        },
        .Neg, .Abs => |o| {
            const c1 = isIntType(from[0]) or isFloatType(from[0]);
            return if (c1) from[0] else null;
        },
        .NegWrap, .BitNot, .BitReverse, .ByteSwap => |o| {
            const c1 = isIntType(from[0]);
            return if (c1) from[0] else null;
        },
        .Sin, .Cos, .Tan, .Exp, .Exp2, .Log, .Log2, .Log10, .Sqrt,
        .Ceil, .Floor, .Round, .Trunc => |o| {
            const c1 = isFloatType(from[0]);
            return if (c1) from[0] else null;
        }, // TODO: Clz, Ctz, PopCount
        .As => |o| {
            return if (isVectorType(from[0]))
                @Vector(getVectorLen(from[0]), from[1])
            else from[1];
        },
        .BitCast => |o| {
            const c1 = @bitSizeOf(from[0]) == @bitSizeOf(from[1]);
            if (!c1) return null;
            return if (isVectorType(from[0]))
                @Vector(getVectorLen(from[0]), from[1])
            else from[1];
        },
        .Shuffle => |o| {
            const c1 = isVectorType(from[0]) and isVectorType(from[1]) and isVectorType(from[2]);
            const c2 = from[0] == from[1];
            const c3 = getVectorType(from[2]) == i32;
            return if (c1 and c2 and c3)
                @Vector(getVectorLen(from[2]), getVectorType(from[0]))
            else null;
        },
        .Select => |o| {
            const c1 = isVectorType(from[0]) and isVectorType(from[1]) and isVectorType(from[2]);
            const c2 = from[1] == from[2];
            const c3 = getVectorLen(from[0]) == getVectorType(from[1]);
            const c4 = getVectorType(from[0]) == bool;
            return if (c1 and c2 and c3 and c3) type[0]
            else null;
        },
        .Reduce => |o| {
            const c1 = isVectorType(from[0]);
            const c2 = from[1] == std.builtin.ReduceOp;
            return if (c1 and c2) getVectorType(from[0])
            else null;
        },
        .Splat => |o| {
            const c1 = !isVectorType(from[0]);
            // we NEED the arbitrary length here to make the type at all
        }
    };
}

/// Used addresses helper
const OpUsedAddresses = struct {
    from: []Address,
    _from: [3]Address,
    to: Address,
};

/// Input state tracking
const InputState = struct {
    T: type,
    modifiable: bool,
};
fn getInputsFields(comptime inputs: anytype) @TypeOf(@typeInfo(@TypeOf(inputs)).@"struct".fields) {
    const InputsType = @TypeOf(inputs);
    const inputs_type_info = @typeInfo(InputsType);
    if (inputs_type_info != .@"struct") {
        @compileError("expected tuple or struct argument, found " ++ @typeName(InputsType));
    }
    return inputs_type_info.@"struct".fields;
}
fn generateTypeTimeline(comptime ops: []Operation, comptime inputs: anytype) [ops.len][getInputsFields(inputs).len]InputState {
    const fields_info = getInputsFields(inputs);

    var timeline: [ops.len][fields_info.len]InputState = undefined;

    for (fields_info, 0..) |field, indice| {
        timeline[0][indice] = .{
            .T = field.type,
            .modifiable = true,
        };
    } 
    for (ops, 1..) |op, frame| {
        const current = timeline[frame - 1];
        const future = timeline[frame];
        const tr = getOpApproxTransformation(op);
        @memcpy(current, future);
        switch (tr) {
            .Casted => future[op.to].T = switch (op.payload) {
                .BitCast => |c| c.to_type,
                .As => |c| c.to_type,
            },
            .ScalarToVector => future[op.to].T = @typeInfo(@TypeOf(current[op.payload.Splat.from])).pointer.child,
            .VectorToScalar => future[op.to].T = []@TypeOf(current[op.payload.Reduce.from]),
        }
        switch (op.payload) {
            .Shuffle => |shuffle| {
                for (timeline) |f| f[shuffle.mask_addr].modifiable = false;
            },
        }
    }
    for (ops) |op| {
        if (!timeline[0][op.to].modifiable) @compileError("Cannot modify comptime value, i.e. @shuffle mask.");
    }
    return timeline;
}

test {
    const timeline = comptime generateTypeTimeline(&[_]Operation{}, .{});
    std.debug.print("Timeline result:\n{any}\n", .{timeline});
}