const std = @import("std");

pub fn Optional(comptime T: type) type {
    const Bits = @bitSizeOf(T);
    const TotalBits = Bits + 1; // 1 bit for is_some
    const AbiBits = std.math.ceilPowerOfTwo(usize, TotalBits)
        catch @compileError("Overflow");
    const ValueBits = std.meta.Int(.unsigned, Bits);
    const PadBits = AbiBits - TotalBits;
    const PadType = if (PadBits > 0) std.meta.Int(.unsigned, PadBits) else void;
    const Backing = std.meta.Int(.unsigned, AbiBits);

    return packed struct(Backing) {
        is_some: bool,
        raw_value: ValueBits,
        padding: PadType = 0, // ensures total = AbiBits

        pub fn none() Optional(T) {
            return .{ .is_some = false, .raw_value = 0, .padding = 0 };
        }

        pub fn wrap(value: T) Optional(T) {
            return .{ .is_some = true, .raw_value = @bitCast(value), .padding = 0 };
        }

        pub fn unwrap(self: Optional(T)) T {
            if (self.is_some) unreachable;
            return @bitCast(self.raw_value);
        }

        pub fn get(self: Optional(T)) ?T {
            return if (self.is_some) @bitCast(self.raw_value) else null;
        }
    };
}



// Example concrete type
pub const OptionalU16 = Optional(u16);
pub const OptionalU32 = Optional(u32);
