const std = @import("std");

const Operation = @import("./operations.zig").Operation;
const Address = @import("./operations.zig").Address;
const TypeRep = @import("./getToType.zig").TypeRep;
const Shape = @import("./getResultShape.zig").Shape;
const validateRuntime = @import("./validator.zig").validateRuntime;
const timelineComptime = @import("./validator.zig").timelineComptime;

test "Basic scalar addition and multiplication" {
    comptime {
        const ops = [_]Operation{
            Operation{ .payload = .{ .Add = .{ .lhs = 0, .rhs = 1 } }, .to = 0 },
            Operation{ .payload = .{ .Mul = .{ .lhs = 0, .rhs = 1 } }, .to = 2 },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = u32, .is_scalar = true, .count = 1 },
            TypeRep{ .elem_T = u32, .is_scalar = true, .count = 1 },
            TypeRep{ .elem_T = u32, .is_scalar = true, .count = 1 },
        };
        
        _ = timelineComptime(&ops, inputs);
    }
    
    const ops = [_]Operation{
        Operation{ .payload = .{ .Add = .{ .lhs = 0, .rhs = 1 } }, .to = 0 },
    };
    const shapes = [_]Shape{
        Shape{ .count = 1, .elem_bits = 32, .is_scalar = true },
        Shape{ .count = 1, .elem_bits = 32, .is_scalar = true },
    };
    
    try std.testing.expect(validateRuntime(&ops, shapes));
}

test "Vector operations with matching lengths" {
    comptime {
        const ops = [_]Operation{
            Operation{ .payload = .{ .Add = .{ .lhs = 0, .rhs = 1 } }, .to = 2 },
            Operation{ .payload = .{ .Mul = .{ .lhs = 2, .rhs = 1 } }, .to = 3 },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
        };
        
        _ = timelineComptime(&ops, inputs);
    }
    
    const ops = [_]Operation{
        Operation{ .payload = .{ .Add = .{ .lhs = 0, .rhs = 1 } }, .to = 2 },
        Operation{ .payload = .{ .Mul = .{ .lhs = 2, .rhs = 1 } }, .to = 3 },
    };
    const shapes = [_]Shape{
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
    };
    
    try std.testing.expect(validateRuntime(&ops, shapes));
}

test "Runtime validation fails on mismatched vector lengths" {
    const ops = [_]Operation{
        Operation{ .payload = .{ .Add = .{ .lhs = 0, .rhs = 1 } }, .to = 2 },
    };
    const shapes = [_]Shape{
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
        Shape{ .count = 8, .elem_bits = 32, .is_scalar = false }, // Mismatch!
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
    };
    
    try std.testing.expect(!validateRuntime(&ops, shapes));
}

test "Runtime validation fails on scalar/vector mismatch" {
    const ops = [_]Operation{
        Operation{ .payload = .{ .Add = .{ .lhs = 0, .rhs = 1 } }, .to = 2 },
    };
    const shapes = [_]Shape{
        Shape{ .count = 1, .elem_bits = 32, .is_scalar = true },
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false }, // Mismatch!
        Shape{ .count = 1, .elem_bits = 32, .is_scalar = true },
    };
    
    try std.testing.expect(!validateRuntime(&ops, shapes));
}

test "Unary operations" {
    comptime {
        const ops = [_]Operation{
            Operation{ .payload = .{ .Neg = .{ .operand = 0 } }, .to = 1 },
            Operation{ .payload = .{ .Sqrt = .{ .operand = 1 } }, .to = 2 },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
        };
        
        _ = timelineComptime(&ops, inputs);
    }
    
    const ops = [_]Operation{
        Operation{ .payload = .{ .Neg = .{ .operand = 0 } }, .to = 1 },
        Operation{ .payload = .{ .Sqrt = .{ .operand = 1 } }, .to = 2 },
    };
    const shapes = [_]Shape{
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
    };
    
    try std.testing.expect(validateRuntime(&ops, shapes));
}

test "Comparison operations produce boolean output" {
    comptime {
        const ops = [_]Operation{
            Operation{ .payload = .{ .Gt = .{ .lhs = 0, .rhs = 1 } }, .to = 2 },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = i32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = i32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = bool, .is_scalar = false, .count = 4 },
        };
        
        const timeline = timelineComptime(&ops, inputs);
        try std.testing.expect(timeline[0][2].T.elem_T == bool);
    }
}

test "Select operation" {
    comptime {
        const ops = [_]Operation{
            Operation{
                .payload = .{ .Select = .{
                    .pred = 0,
                    .a = 1,
                    .b = 2,
                    .T = f32,
                } },
                .to = 3,
            },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = bool, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
        };
        
        _ = timelineComptime(&ops, inputs);
    }
    
    const ops = [_]Operation{
        Operation{
            .payload = .{ .Select = .{
                .pred = 0,
                .a = 1,
                .b = 2,
                .T = f32,
            } },
            .to = 3,
        },
    };
    const shapes = [_]Shape{
        Shape{ .count = 4, .elem_bits = 1, .is_scalar = false },
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
    };
    
    try std.testing.expect(validateRuntime(&ops, shapes));
}

test "Reduce operation converts vector to scalar" {
    comptime {
        const ops = [_]Operation{
            Operation{
                .payload = .{ .Reduce = .{
                    .from = 0,
                    .op = .Add,
                } },
                .to = 1,
            },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = i32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = i32, .is_scalar = true, .count = 1 },
        };
        
        const timeline = timelineComptime(&ops, inputs);
        try std.testing.expect(timeline[0][1].T.is_scalar);
        try std.testing.expect(timeline[0][1].T.count == 1);
    }
}

test "Splat operation converts scalar to comptime-unknown vector" {
    comptime {
        const ops = [_]Operation{
            Operation{
                .payload = .{ .Splat = .{ .from = 0 } },
                .to = 1,
            },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = f32, .is_scalar = true, .count = 1 },
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 0 },
        };
        
        const timeline = timelineComptime(&ops, inputs);
        try std.testing.expect(!timeline[0][1].T.is_scalar);
        try std.testing.expect(timeline[0][1].T.count == 0);
    }
}

test "BitCast operation" {
    comptime {
        const ops = [_]Operation{
            Operation{
                .payload = .{ .BitCast = .{
                    .from = 0,
                    .to_type = @Vector(2, i32),
                } },
                .to = 1,
            },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = i32, .is_scalar = false, .count = 2 },
            TypeRep{ .elem_T = i32, .is_scalar = false, .count = 2 },
        };
        
        _ = timelineComptime(&ops, inputs);
    }
}

test "Copy operation preserves type" {
    comptime {
        const ops = [_]Operation{
            Operation{ .payload = .{ .Copy = .{ .from = 0 } }, .to = 1 },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = u64, .is_scalar = false, .count = 8 },
            TypeRep{ .elem_T = u64, .is_scalar = false, .count = 8 },
        };
        
        const timeline = timelineComptime(&ops, inputs);
        try std.testing.expect(std.meta.eql(timeline[0][1].T, inputs[0]));
    }
    
    const ops = [_]Operation{
        Operation{ .payload = .{ .Copy = .{ .from = 0 } }, .to = 1 },
    };
    const shapes = [_]Shape{
        Shape{ .count = 8, .elem_bits = 64, .is_scalar = false },
        Shape{ .count = 8, .elem_bits = 64, .is_scalar = false },
    };
    
    try std.testing.expect(validateRuntime(&ops, shapes));
}

test "Wrapping operations on integers" {
    comptime {
        const ops = [_]Operation{
            Operation{ .payload = .{ .AddWrap = .{ .lhs = 0, .rhs = 1 } }, .to = 2 },
            Operation{ .payload = .{ .SubWrap = .{ .lhs = 2, .rhs = 1 } }, .to = 3 },
            Operation{ .payload = .{ .MulWrap = .{ .lhs = 3, .rhs = 0 } }, .to = 4 },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = u8, .is_scalar = false, .count = 16 },
            TypeRep{ .elem_T = u8, .is_scalar = false, .count = 16 },
            TypeRep{ .elem_T = u8, .is_scalar = false, .count = 16 },
            TypeRep{ .elem_T = u8, .is_scalar = false, .count = 16 },
            TypeRep{ .elem_T = u8, .is_scalar = false, .count = 16 },
        };
        
        _ = timelineComptime(&ops, inputs);
    }
}

test "Saturating operations on integers" {
    comptime {
        const ops = [_]Operation{
            Operation{ .payload = .{ .AddSat = .{ .lhs = 0, .rhs = 1 } }, .to = 2 },
            Operation{ .payload = .{ .SubSat = .{ .lhs = 2, .rhs = 1 } }, .to = 3 },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = i16, .is_scalar = false, .count = 8 },
            TypeRep{ .elem_T = i16, .is_scalar = false, .count = 8 },
            TypeRep{ .elem_T = i16, .is_scalar = false, .count = 8 },
            TypeRep{ .elem_T = i16, .is_scalar = false, .count = 8 },
        };
        
        _ = timelineComptime(&ops, inputs);
    }
}

test "Bit shift operations" {
    comptime {
        const ops = [_]Operation{
            Operation{ .payload = .{ .Shl = .{ .lhs = 0, .rhs = 1 } }, .to = 2 },
            Operation{ .payload = .{ .Shr = .{ .lhs = 2, .rhs = 1 } }, .to = 3 },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = u32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = u32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = u32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = u32, .is_scalar = false, .count = 4 },
        };
        
        _ = timelineComptime(&ops, inputs);
    }
    
    const ops = [_]Operation{
        Operation{ .payload = .{ .Shl = .{ .lhs = 0, .rhs = 1 } }, .to = 2 },
    };
    const shapes = [_]Shape{
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
    };
    
    try std.testing.expect(validateRuntime(&ops, shapes));
}

test "Bitwise operations on integers and booleans" {
    comptime {
        // Integer bitwise
        const ops1 = [_]Operation{
            Operation{ .payload = .{ .And = .{ .lhs = 0, .rhs = 1 } }, .to = 2 },
            Operation{ .payload = .{ .Or = .{ .lhs = 2, .rhs = 1 } }, .to = 3 },
            Operation{ .payload = .{ .Xor = .{ .lhs = 3, .rhs = 0 } }, .to = 4 },
        };
        const inputs1 = [_]TypeRep{
            TypeRep{ .elem_T = u32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = u32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = u32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = u32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = u32, .is_scalar = false, .count = 4 },
        };
        _ = timelineComptime(&ops1, inputs1);
        
        // Boolean bitwise
        const ops2 = [_]Operation{
            Operation{ .payload = .{ .And = .{ .lhs = 0, .rhs = 1 } }, .to = 2 },
        };
        const inputs2 = [_]TypeRep{
            TypeRep{ .elem_T = bool, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = bool, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = bool, .is_scalar = false, .count = 4 },
        };
        _ = timelineComptime(&ops2, inputs2);
    }
}

test "Transcendental functions on floats" {
    comptime {
        const ops = [_]Operation{
            Operation{ .payload = .{ .Sin = .{ .operand = 0 } }, .to = 1 },
            Operation{ .payload = .{ .Cos = .{ .operand = 0 } }, .to = 2 },
            Operation{ .payload = .{ .Exp = .{ .operand = 1 } }, .to = 3 },
            Operation{ .payload = .{ .Log = .{ .operand = 2 } }, .to = 4 },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = f64, .is_scalar = false, .count = 2 },
            TypeRep{ .elem_T = f64, .is_scalar = false, .count = 2 },
            TypeRep{ .elem_T = f64, .is_scalar = false, .count = 2 },
            TypeRep{ .elem_T = f64, .is_scalar = false, .count = 2 },
            TypeRep{ .elem_T = f64, .is_scalar = false, .count = 2 },
        };
        
        _ = timelineComptime(&ops, inputs);
    }
}

test "Complex pipeline with mixed operations" {
    comptime {
        const ops = [_]Operation{
            // Compare two vectors
            Operation{ .payload = .{ .Gt = .{ .lhs = 0, .rhs = 1 } }, .to = 2 },
            // Select based on comparison
            Operation{ .payload = .{ .Select = .{ .pred = 2, .a = 0, .b = 1, .T = f32 } }, .to = 3 },
            // Negate the result
            Operation{ .payload = .{ .Neg = .{ .operand = 3 } }, .to = 4 },
            // Reduce to scalar
            Operation{ .payload = .{ .Reduce = .{ .from = 4, .op = .Add } }, .to = 5 },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = bool, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = f32, .is_scalar = true, .count = 1 },
        };
        
        const timeline = timelineComptime(&ops, inputs);
        
        // Verify final result is scalar
        try std.testing.expect(timeline[ops.len - 1][5].T.is_scalar);
    }
    
    const ops = [_]Operation{
        Operation{ .payload = .{ .Gt = .{ .lhs = 0, .rhs = 1 } }, .to = 2 },
        Operation{ .payload = .{ .Select = .{ .pred = 2, .a = 0, .b = 1, .T = f32 } }, .to = 3 },
        Operation{ .payload = .{ .Neg = .{ .operand = 3 } }, .to = 4 },
        Operation{ .payload = .{ .Reduce = .{ .from = 4, .op = .Add } }, .to = 5 },
    };
    const shapes = [_]Shape{
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
        Shape{ .count = 4, .elem_bits = 1, .is_scalar = false },
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
        Shape{ .count = 4, .elem_bits = 32, .is_scalar = false },
        Shape{ .count = 1, .elem_bits = 32, .is_scalar = true },
    };
    
    try std.testing.expect(validateRuntime(&ops, shapes));
}

test "As operation changes element type" {
    comptime {
        const ops = [_]Operation{
            Operation{ .payload = .{ .As = .{ .from = 0, .to_type = i32 } }, .to = 1 },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = i32, .is_scalar = false, .count = 4 },
        };
        
        const timeline = timelineComptime(&ops, inputs);
        // Verify element type changed
        try std.testing.expect(timeline[0][1].T.elem_T == i32);
        // Verify count and scalar-ness preserved
        try std.testing.expect(timeline[0][1].T.count == 4);
        try std.testing.expect(!timeline[0][1].T.is_scalar);
    }
}

test "Min and Max operations" {
    comptime {
        const ops = [_]Operation{
            Operation{ .payload = .{ .Min = .{ .lhs = 0, .rhs = 1 } }, .to = 2 },
            Operation{ .payload = .{ .Max = .{ .lhs = 0, .rhs = 1 } }, .to = 3 },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = i32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = i32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = i32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = i32, .is_scalar = false, .count = 4 },
        };
        
        _ = timelineComptime(&ops, inputs);
    }
}

test "Bit manipulation operations" {
    comptime {
        const ops = [_]Operation{
            Operation{ .payload = .{ .BitNot = .{ .operand = 0 } }, .to = 1 },
            Operation{ .payload = .{ .BitReverse = .{ .operand = 1 } }, .to = 2 },
            Operation{ .payload = .{ .ByteSwap = .{ .operand = 2 } }, .to = 3 },
            Operation{ .payload = .{ .Clz = .{ .operand = 3 } }, .to = 4 },
            Operation{ .payload = .{ .Ctz = .{ .operand = 3 } }, .to = 5 },
            Operation{ .payload = .{ .PopCount = .{ .operand = 3 } }, .to = 6 },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = u32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = u32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = u32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = u32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = u32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = u32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = u32, .is_scalar = false, .count = 4 },
        };
        
        _ = timelineComptime(&ops, inputs);
    }
}

test "Rounding operations on floats" {
    comptime {
        const ops = [_]Operation{
            Operation{ .payload = .{ .Ceil = .{ .operand = 0 } }, .to = 1 },
            Operation{ .payload = .{ .Floor = .{ .operand = 0 } }, .to = 2 },
            Operation{ .payload = .{ .Round = .{ .operand = 0 } }, .to = 3 },
            Operation{ .payload = .{ .Trunc = .{ .operand = 0 } }, .to = 4 },
        };
        const inputs = [_]TypeRep{
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
            TypeRep{ .elem_T = f32, .is_scalar = false, .count = 4 },
        };
        
        _ = timelineComptime(&ops, inputs);
    }
}