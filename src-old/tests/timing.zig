const std = @import("std");
const Timing = @import("../orca/Timing.zig").Timing;
const ThreadPool = @import("../orca/ThreadPool.zig").ThreadPool;

const TestHook = struct {
    counter: std.atomic.Value(u64),
    ticks: std.atomic.Value(u64),
    pub fn fire(ctx: *TestHook, delta_ns: u64) void {
        _ = ctx.counter.fetchAdd(delta_ns, .monotonic);
        _ = ctx.ticks.fetchAdd(1, .monotonic);
    }
};

test {
    const thread_pool = try ThreadPool.init(std.testing.io, .{
        .max_thread_count = 8,
        .stack_size = std.mem.alignForward(usize, 1024 * 32, std.heap.pageSize()),
        .queue_capacity = 256,
        .scale_up_load_threshold = 128,
        .scale_up_queue_threshold = 128,
        .steal_load_threshold = 96,
        .steal_queue_threshold = 96,
        .scale_up_extra_load = 16,
        .stress_increment = 2,
        .stress_decrement = 3,
        .scale_up_stress_threshold = 16,
    }, 4);
    var timing = Timing.init(.fromNanoseconds(1_000_000_000 / 1920), .fromNanoseconds(10_000));
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    const al = &debug_allocator.allocator();
    var hook = TestHook{
        .counter = .init(0),
        .ticks = .init(0)
    };
    var hooks_buf = try al.alloc(Timing.Hook, 32);
    hooks_buf[0] = .{
        .ctx = @ptrCast(&hook),
        .fire = @ptrCast(&TestHook.fire),
    };
    const hooks = hooks_buf[0..1];
    try timing.start(std.testing.io, thread_pool, hooks);
    std.testing.io.sleep(.fromSeconds(5), .awake) catch unreachable;
    try timing.stop();
    var spin_limit: usize = 1_000_000;
    while (timing.state.load(.acquire) == .dying) : (spin_limit -= 1) {
        try std.Thread.yield();
    }
    try std.testing.expect(timing.state.load(.acquire) == .dead);
    std.log.info("delta per tick = {}\n", .{hook.counter.load(.acquire) / hook.ticks.load(.acquire)});
}