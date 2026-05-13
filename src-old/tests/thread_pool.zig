const std = @import("std");
const ThreadPool = @import("../orca/ThreadPool.zig").ThreadPool;
const Config = @import("../orca/ThreadPool.zig").Config;
const Job = @import("../orca/ThreadPool.zig").Job;
const Thread = @import("../orca/ThreadPool.zig").Thread;

// Default test configuration for light workloads
pub fn defaultTestConfig() Config {
    const page_size = std.heap.pageSize();
    return .{
        .max_thread_count = 8,
        .stack_size = std.mem.alignForward(usize, 1024 * 32, page_size),
        .queue_capacity = 256,
        .scale_up_load_threshold = 128,
        .scale_up_queue_threshold = 128,
        .steal_load_threshold = 96,
        .steal_queue_threshold = 96,
        .scale_up_extra_load = 16,
        .stress_increment = 2,
        .stress_decrement = 3,
        .scale_up_stress_threshold = 16,
    };
}

// Heavy workload test configuration
pub fn heavyTestConfig() Config {
    const page_size = std.heap.pageSize();
    return .{
        .max_thread_count = 8,
        .stack_size = std.mem.alignForward(usize, 1024 * 64, page_size),
        .queue_capacity = 1024,
        .scale_up_load_threshold = 784,
        .scale_up_queue_threshold = 512,
        .steal_load_threshold = 512,
        .steal_queue_threshold = 384,
        .scale_up_extra_load = 128,
        .stress_increment = 2,
        .stress_decrement = 3,
        .scale_up_stress_threshold = 16,
    };
}

test "threadpool init" {
    std.log.info("Testing threadpool init and deinit...\n", .{});
    
    const pool = try ThreadPool.init(std.testing.io, defaultTestConfig(), 4);
    defer pool.deinit() catch std.debug.panic("Failed to deinitialize ThreadPool\n", .{});
    
    std.log.info("Done!\n", .{});
}

// Work context for counter-based tests
const CounterCtx = struct {
    counter: *std.atomic.Value(usize),
    increment: usize,
};

// Worker that increments a counter
const CounterWorker = struct {
    pub fn tick(ctx: *anyopaque, _: *Thread) void {
        const c = @as(*CounterCtx, @ptrCast(@alignCast(ctx)));
        // Simulate some work
        for (0..c.increment * 64) |_| std.Thread.yield() catch {};
        _ = c.counter.fetchAdd(c.increment, .acq_rel);
    }
};

// Configuration for a load type in tests
const LoadConfig = struct {
    increment: usize,
    load: u8,
    count: usize,
};

// Submit a batch of jobs with uniform load
fn submitJobBatch(
    pool: *ThreadPool,
    ctx: *CounterCtx,
    config: LoadConfig,
    batch_buffer: []Job,
) u64 {
    const batch_size = batch_buffer.len;
    var jobs_submitted: usize = 0;
    
    while (jobs_submitted < config.count) {
        const remaining = config.count - jobs_submitted;
        const current_batch_size = @min(batch_size, remaining);
        
        // Create a uniform batch for this submission
        for (0..current_batch_size) |i| {
            batch_buffer[i] = Job{
                .ctx = @as(*anyopaque, @ptrCast(@alignCast(ctx))),
                .tick = @constCast(&CounterWorker.tick),
                .load = config.load,
            };
        }
        
        jobs_submitted += pool.submit(batch_buffer[0..current_batch_size]);
    }
    
    return jobs_submitted;
}

// Calculate expected total from load configurations
fn calculateExpectedTotal(configs: []const LoadConfig) usize {
    var sum: usize = 0;
    for (configs) |config| {
        sum += config.increment * config.count;
    }
    return sum;
}

// Calculate total job count from load configurations
fn calculateTotalJobCount(configs: []const LoadConfig) usize {
    var sum: usize = 0;
    for (configs) |config| {
        sum += config.count;
    }
    return sum;
}

test "threadpool test" {
    // Shared atomic counter
    var counter = std.atomic.Value(usize).init(0);
    
    // Initialize pool
    const pool = try ThreadPool.init(std.testing.io, heavyTestConfig(), 4);
    defer pool.deinit() catch unreachable;
    
    // Define different load types and their counts
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
    
    // Submit jobs in uniform batches by load type
    var total_submitted: usize = 0;
    var batch_buffer: [100]Job = undefined;
    
    for (configs, 0..) |config, config_index| {
        const ctx = &ctxs[config_index];
        total_submitted += submitJobBatch(pool, ctx, config, &batch_buffer);
    }
    
    // Verify all jobs were submitted
    const expected_job_count = calculateTotalJobCount(&configs);
    try std.testing.expectEqual(expected_job_count, total_submitted);
    
    // Wait for all jobs to complete
    const expected_total = calculateExpectedTotal(&configs);
    while (counter.load(.acquire) < expected_total) {
        std.Thread.yield() catch {};
    }
    
    std.log.info("threadpool test: counter={}, expected={}, total_jobs_submitted={}\n", .{
        counter.load(.acquire),
        expected_total,
        total_submitted,
    });
    
    try std.testing.expectEqual(expected_total, counter.load(.acquire));
    
    std.log.info("Done!\n", .{});
}
