const std = @import("std");
const RingBuffer = @import("../mem/RingBuffer.zig").RingBuffer;
const View = @import("../mem/RingBuffer.zig").View;

const Payload = packed struct(u128) {
    /// The context to be passed to the tick function.
    /// Usually a pointer to the FSM that this job acts as a VTable for.
    ctx: *anyopaque,
    /// The function to be called when the job is ready to be processed.
    /// Usually a method of the FSM in .ctx.
    tick: *const fn (*anyopaque) void,
};
const Job = struct {
    payload: Payload align(16),
    /// Used for load balancing.
    load: u8,
};
/// Auto-generated with zig_serializer.
pub const ExternalMutable = struct {
    payload: []Payload,
    load: []u8,
};
/// Auto-generated with zig_serializer.
pub const ExternalImmutable = struct {
    payload: []const Payload,
    load: []const u8,
};
/// Auto-generated with zig_serializer.
pub const Internal = struct {
    payload: View(Payload),
    load: View(u8),
};

test {
    
    const RB = RingBuffer(.{
        .Item = Job,
        .concurrency = .mpmc,
        .ordering = .fifo,
        .structure = .soa,
        .ExternalImmutable = ExternalImmutable,
        .ExternalMutable = ExternalMutable,
        .Internal = Internal,
    });
    _ = RB;
}

