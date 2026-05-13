const std = @import("std");

const Operation = @import("./operations.zig").Operation;
const Address = @import("./operations.zig").Address;
const TypeRep = @import("./getToType.zig").TypeRep;
const getToType = @import("./getToType.zig").getToType;
const Shape = @import("./getResultShape.zig").Shape;
const getResultShape = @import("./getResultShape.zig").getResultShape;

/// Represents the state of an input slot at a particular frame in the timeline.
fn InputState(T: type) type {
    return struct {
        T: T,
        modifiable: bool,
    };
}

/// Extracts Address operands from an operation's payload.
/// Returns the number of Address operands found and an array containing them.
/// Non-Address fields (like `to_type`, `E`, `mask_len`, etc.) are skipped.
fn generateFromArray(comptime op: Operation) struct { len: usize, from: [3]Address } {
    var from: [3]Address = .{ 0, 0, 0 };
    var len: usize = 0;
    
    const deunioned_op = @field(op.payload, @tagName(op.payload));
    const fields = @typeInfo(@TypeOf(deunioned_op)).@"struct".fields;
    
    inline for (fields) |field| {
        const val = @field(deunioned_op, field.name);
        if (@TypeOf(val) == Address) {
            from[len] = val;
            len += 1;
        }
    }
    return .{ .len = len, .from = from };
}

/// Calculates the minimum number of input slots needed for a pipeline.
/// This is determined by the highest address referenced (either as input or output).
pub fn tallyInputCount(comptime ops: []const Operation) usize {
    var watermark: usize = 0;
    inline for (ops) |op| {
        const count_b = op.to + 1;
        if (count_b > watermark) watermark = count_b;
        const from_res = generateFromArray(op);
        const from = from_res.from[0..from_res.len];
        for (from) |a| {
            const count_a = a + 1;
            if (count_a > watermark) watermark = count_a;
        }
    }
    return watermark;
}

/// Validates a pipeline at compile-time by checking type compatibility.
/// Returns a timeline showing the type state at each operation frame.
/// Emits a compile error if any operation has invalid operand types.
pub fn timelineComptime(
    comptime ops: []const Operation,
    comptime inputs: [tallyInputCount(ops)]TypeRep,
) [ops.len][inputs.len]InputState(TypeRep) {
    var timeline: [ops.len + 1][inputs.len]InputState(TypeRep) = undefined;
    
    // Initialize frame 0 with input types
    inline for (inputs, 0..) |field, indice| {
        timeline[0][indice] = .{
            .T = field,
            .modifiable = true,
        };
    }
    
    // Process each operation
    inline for (ops, 1..) |op, frame| {
        const current = timeline[frame - 1];
        var future: [inputs.len]InputState(TypeRep) = undefined;
        @memcpy(&future, &current);
        
        const from_info = generateFromArray(op);
        
        // Gather input types for this operation
        var types: [3]TypeRep = undefined;
        for (0..types.len) |i| {
            types[i] = TypeRep{ .elem_T = void, .count = 0, .is_scalar = true };
        }
        
        for (0..from_info.len) |i| {
            const address = from_info.from[i];
            types[i] = current[address].T;
        }
        
        // Validate and compute output type
        const to_type = getToType(types, op) orelse {
            @compileError(std.fmt.comptimePrint(
                "Operation {s} at frame {} has invalid operand types",
                .{ @tagName(op.payload), frame - 1 },
            ));
        };
        
        future[op.to].T = to_type;
        timeline[frame] = future;
    }
    
    // Verify that no comptime-immutable slots are being modified
    inline for (ops) |op| {
        if (!timeline[0][op.to].modifiable) {
            @compileError("Cannot modify comptime-immutable value (e.g., @shuffle mask)");
        }
    }
    
    return timeline[1..][0..ops.len].*;
}

/// Validates a pipeline at runtime by checking shape compatibility.
/// Returns true if all operations have valid operand shapes, false otherwise.
/// Prints diagnostic information for any invalid operations.
pub fn validateRuntime(
    comptime ops: []const Operation,
    inputs: [tallyInputCount(ops)]Shape,
) bool {
    var timeline: [ops.len + 1][inputs.len]Shape = undefined;
    
    // Initialize frame 0 with input shapes
    inline for (inputs, 0..) |field, indice| {
        timeline[0][indice] = field;
    }
    
    var fails: u32 = 0;
    
    // Process each operation
    inline for (ops, 1..) |op, frame| {
        const current = timeline[frame - 1];
        var future: [inputs.len]Shape = undefined;
        @memcpy(&future, &current);
        
        const from_info = generateFromArray(op);
        
        // Gather input shapes for this operation
        var shapes: [3]Shape = undefined;
        for (0..shapes.len) |i| {
            shapes[i] = Shape{ .count = 0, .elem_bits = 0, .elem_alignment = 0, .is_scalar = false };
        }
        
        for (0..from_info.len) |i| {
            const address = from_info.from[i];
            shapes[i] = current[address];
        }
        
        // Validate and compute output shape
        const result_shape = getResultShape(shapes, op);
        if (result_shape) |shape| {
            future[op.to] = shape;
        } else {
            fails += 1;
            std.debug.print(
                "Frame {}: Operation (.{s}) at address {} with inputs {any} failed shape validation\n",
                .{ frame - 1, @tagName(op.payload), op.to, from_info.from[0..from_info.len] },
            );
        }
        
        timeline[frame] = future;
    }
    
    if (fails > 0) {
        std.debug.print("Pipeline validation failed with {} error(s)\n", .{fails});
        return false;
    }
    
    return true;
}