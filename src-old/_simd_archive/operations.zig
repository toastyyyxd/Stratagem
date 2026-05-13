const std = @import("std");

pub const Address = usize;

pub const BinOp = struct { lhs: Address, rhs: Address };
pub const UnOp = struct { operand: Address };

pub const Operation = struct {
    to: Address,

    payload: union(enum) {
        // Math (Binary)
        Add: BinOp, Sub: BinOp, Mul: BinOp, Div: BinOp, Mod: BinOp,
        Min: BinOp, Max: BinOp,

        // Wrapping/Saturating
        AddWrap: BinOp, SubWrap: BinOp, MulWrap: BinOp,
        AddSat: BinOp, SubSat: BinOp, MulSat: BinOp,

        // Bit Shifts & Bitwise
        Shl: BinOp, Shr: BinOp, ShlSat: BinOp,
        And: BinOp, Or: BinOp, Xor: BinOp,

        // Comparisons
        Eq: BinOp, Ne: BinOp,
        Gt: BinOp, Ge: BinOp, Lt: BinOp, Le: BinOp,

        // Unary
        Neg: UnOp, NegWrap: UnOp, BitNot: UnOp, Abs: UnOp,
        Sin: UnOp, Cos: UnOp, Tan: UnOp,
        Exp: UnOp, Exp2: UnOp, Log: UnOp, Log2: UnOp, Log10: UnOp,
        Sqrt: UnOp, Ceil: UnOp, Floor: UnOp, Round: UnOp, Trunc: UnOp,
        BitReverse: UnOp, ByteSwap: UnOp, Clz: UnOp, Ctz: UnOp, PopCount: UnOp,

        // Special (Keep specific structs for complex payloads)
        As: struct { from: Address, to_type: type },
        BitCast: struct { from: Address, to_type: type },
        Shuffle: struct {
            a: Address, b: Address,
            E: type, mask_addr: Address, mask_len: usize,
        },
        Select: struct {
            pred: Address, a: Address, b: Address, T: type,
        },
        Reduce: struct { from: Address, op: std.builtin.ReduceOp },
        Splat: struct { from: Address },
        Copy: struct { from: Address },
    },
};