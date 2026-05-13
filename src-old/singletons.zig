const std = @import("std");
const ThreadPool = @import("./orca/thread_pool.zig").ThreadPool;

pub var thread_pool: *ThreadPool = undefined;

pub fn init() !void {
    const system_threads = try std.Thread.getCpuCount();
    thread_pool = ThreadPool.init(.{
        .max_thread_count = @min(system_threads, 64),
        .stack_size = 64 * 1024,

        .queue_capacity = 1000,
        .steal_queue_threshold = 650,
        .scale_up_queue_threshold = 800,

        .steal_load_threshold = 1200,
        .scale_up_load_threshold = 1500,
        .scale_up_extra_load = 300,

        .stress_increment = 5,
        .stress_decrement = 3,
        .scale_up_stress_threshold = 50,
    }, @min(4, system_threads)) catch {
        std.debug.panic("Failed to initialize thread pool!");
    };
}