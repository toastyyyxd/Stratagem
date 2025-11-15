const std = @import("std");
const ThreadPool = @import("../orca/thread_pool.zig").ThreadPool;
const Job = @import("../orca/thread_pool.zig").Job;
const Thread = @import("../orca/thread_pool.zig").Thread;

test "threadpool init" {
    std.debug.print("Testing threadpool init and deinit...\n", .{});
    const pool = try ThreadPool.init(.{
        .max_thread_count = 8,
        .stack_size = std.mem.alignForward(usize, 1024 * 32, std.heap.pageSize()), // 32 KiB aligned to page size
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
    pool.deinit() catch
        std.debug.panic("Failed to deinitialize ThreadPool\n", .{});
    std.debug.print("Done!\n", .{});
}

test "threadpool test" {
    // Shared atomic counter
    var counter = std.atomic.Value(usize).init(0);

    const CounterCtx = struct {
        counter: *std.atomic.Value(usize),
        increment: usize,
    };

    const Work = struct {
        pub fn tick(ctx: *anyopaque, _: *Thread) void {
            const c = @as(*CounterCtx, @ptrCast(@alignCast(ctx)));
            for (0..c.increment * 64) |_| std.Thread.yield() catch {};
            _ = c.counter.fetchAdd(c.increment, .acq_rel);
        }
    };

    // Initialize pool
    const pool = try ThreadPool.init(.{
        .max_thread_count = 8,
        .stack_size = std.mem.alignForward(usize, 1024 * 64, std.heap.pageSize()),
        .queue_capacity = 1024,
        .scale_up_load_threshold = 784,
        .scale_up_queue_threshold = 512,
        .steal_load_threshold = 512,
        .steal_queue_threshold = 384,
        .scale_up_extra_load = 128,
        .stress_increment = 2,
        .stress_decrement = 3,
        .scale_up_stress_threshold = 16,
    }, 4);
    defer pool.deinit() catch unreachable;

    // Define different load types and their counts
    const LoadConfig = struct {
        increment: usize,
        load: u8,
        count: usize,
    };

    const configs = [_]LoadConfig{
        .{ .increment = 1, .load = 1, .count = 600000 },
        .{ .increment = 2, .load = 2, .count = 30000 },
        .{ .increment = 5, .load = 5, .count = 30000 },
        .{ .increment = 64, .load = 64, .count = 5000 },
        .{ .increment = 256, .load = 255, .count = 2000 },
    };

    // Create context for each load type
    var ctxs: [configs.len]CounterCtx = undefined;
    for (&ctxs, configs) |*ctx, config| {
        ctx.* = CounterCtx{
            .counter = &counter,
            .increment = config.increment,
        };
    }

    var total_submitted: usize = 0;
    const expected_total: usize = blk: {
        var sum: usize = 0;
        for (configs) |config| {
            sum += config.increment * config.count;
        }
        break :blk sum;
    };

    // Submit jobs in uniform batches by load type
    for (configs, 0..) |config, config_index| {
        const ctx = &ctxs[config_index];

        // Submit this load type in smaller batches to test batching
        const batch_size = 100; // Submit 100 jobs at a time
        var jobs_submitted: usize = 0;

        while (jobs_submitted < config.count) {
            const remaining = config.count - jobs_submitted;
            const current_batch_size = @min(batch_size, remaining);

            // Create a uniform batch for this submission
            var batch: [batch_size]Job = undefined;
            for (0..current_batch_size) |i| {
                batch[i] = Job{
                    .ctx = @as(*anyopaque, @ptrCast(@alignCast(ctx))),
                    .tick = @constCast(&Work.tick),
                    .load = config.load,
                };
            }

            const submitted_this_batch = pool.submit(batch[0..current_batch_size]);
            jobs_submitted += submitted_this_batch;
            total_submitted += submitted_this_batch;
        }
    }

    try std.testing.expectEqual(total_submitted, blk: {
        var sum: usize = 0;
        for (configs) |config| sum += config.count;
        break :blk sum;
    });

    // Wait for all jobs to complete
    var iterations: usize = 0;
    while (counter.load(.acquire) < expected_total) {
        std.Thread.yield() catch {};
        iterations += 1;
    }

    std.debug.print("threadpool test: counter={}, expected={}, total_jobs_submitted={}\n", .{ counter.load(.acquire), expected_total, total_submitted });

    try std.testing.expectEqual(expected_total, counter.load(.acquire));

    std.debug.print("Done!\n", .{});
}
