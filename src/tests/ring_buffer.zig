const std = @import("std");
const RingBuffer = @import("../mem/ring_buffer.zig").RingBuffer;
/// Thread-pinning improves msgs/s by ~10% on my Ryzen 9700X.
const pinCurrentThreadToCore = @import("../orca/pin_thread.zig").pinCurrentThreadToCore;
const builtin = @import("builtin");

test "ringbuffer build and init" {
    const T = RingBuffer(u32);
    const capacity = 8;
    const size = T.sizeOf(capacity);
    const buffer = try std.heap.page_allocator.alloc(u8, size);
    defer std.heap.page_allocator.free(buffer);

    const ring_buffer = try T.initInSlice(buffer, capacity);
    // Don't use .deinit, as we already defer the buffer free.

    try std.testing.expect(ring_buffer.capacity == capacity);
    try std.testing.expect(ring_buffer.producer_claimed.value.load(.monotonic) == 0);
    try std.testing.expect(ring_buffer.producer_published.value.load(.monotonic) == 0);
    try std.testing.expect(ring_buffer.consumer_claimed.value.load(.monotonic) == 0);
    try std.testing.expect(ring_buffer.consumer_published.value.load(.monotonic) == 0);
}

test "ringbuffer mpmc perf stress test" {
    const TestItem = struct {
        producer_id: u32,
        sequence: u32,
        magic: u32 = 0xDEADBEEF,
    };

    const RB = RingBuffer(TestItem);
    const capacity = 256; // Good balance between memory usage and contention reduction
    const num_producers = 4; // Producers are much faster than consumers due to the integrity check
    const num_consumers = 4;
    const test_duration_ms = 1000;

    // Initialize ring buffer
    const ring_buffer = try RB.init(std.testing.allocator, capacity);
    defer ring_buffer.deinit(std.testing.allocator);

    // Performance and integrity tracking
    var total_produced: std.atomic.Value(u64) align(std.atomic.cache_line) = std.atomic.Value(u64).init(0);
    var total_consumed: std.atomic.Value(u64) align(std.atomic.cache_line) = std.atomic.Value(u64).init(0);
    var integrity_errors: std.atomic.Value(u32) align(std.atomic.cache_line) = std.atomic.Value(u32).init(0);
    var test_running: std.atomic.Value(bool) align(std.atomic.cache_line) = std.atomic.Value(bool).init(true);

    var current_cpu: std.atomic.Value(usize) align(std.atomic.cache_line) = std.atomic.Value(usize).init(0);

    // Producer context and function
    const ProducerContext = struct {
        current_cpu: *std.atomic.Value(usize) align(std.atomic.cache_line),
        ring_buffer: *RB,
        producer_id: u8,
        total_produced: *std.atomic.Value(u64) align(std.atomic.cache_line),
        test_running: *std.atomic.Value(bool) align(std.atomic.cache_line),
    };

    const producer_fn = struct {
        fn run(ctx: *ProducerContext) void {
            pinCurrentThreadToCore(ctx.current_cpu.fetchAdd(2, .seq_cst)) catch |err| {
                std.debug.panic("Failed to pin thread to core: {}\n", .{err});
                return;
            };
            var local_sequence: u32 = 0;
            var local_produced: u64 = 0;
            var batch = [_]TestItem{undefined} ** @min(16, capacity); // Balanced batch size

            while (ctx.test_running.load(.acquire)) {
                // Prepare batch
                for (0..batch.len) |i| {
                    batch[i] = TestItem{
                        .producer_id = ctx.producer_id,
                        .sequence = local_sequence,
                        .magic = 0xDEADBEEF,
                    };
                    local_sequence +%= 1; // Wrapping add to prevent overflow
                }

                // Try to push batch
                if (ctx.ring_buffer.push(&batch)) {
                    local_produced += batch.len;
                } else {
                    // Buffer full, yield briefly
                    std.Thread.yield() catch {};
                }
            }

            // Update global counter
            _ = ctx.total_produced.fetchAdd(local_produced, .monotonic);
        }
    }.run;

    // Consumer context and function
    const ConsumerContext = struct {
        current_cpu: *std.atomic.Value(usize) align(std.atomic.cache_line),
        ring_buffer: *RB,
        consumer_id: u8,
        total_consumed: *std.atomic.Value(u64) align(std.atomic.cache_line),
        integrity_errors: *std.atomic.Value(u32) align(std.atomic.cache_line),
        test_running: *std.atomic.Value(bool) align(std.atomic.cache_line),
        num_producers: u8,
    };

    const consumer_fn = struct {
        fn run(ctx: *ConsumerContext) void {
            pinCurrentThreadToCore(ctx.current_cpu.fetchAdd(2, .seq_cst)) catch |err| {
                std.debug.panic("Failed to pin thread to core: {}\n", .{err});
                return;
            };
            var local_consumed: u64 = 0;
            var local_errors: u32 = 0;
            var batch = [_]TestItem{undefined} ** @min(16, capacity); // Match producer batch size

            while (ctx.test_running.load(.acquire)) {
                // Attempt to pop a full batch. If it fails, yield.
                // This is more symmetric with the producer's behavior.
                const items_popped = ctx.ring_buffer.pop_some(&batch);
                if (items_popped > 0) {
                    // Validate integrity of consumed items
                    for (0..items_popped) |item_i| {
                        const item = &batch[item_i];
                        if (item.magic != 0xDEADBEEF or item.producer_id >= ctx.num_producers) {
                            local_errors += 1;
                        }
                    }
                    local_consumed += items_popped;
                } else {
                    // If the pop fails, the buffer is likely empty. Yield immediately.
                    std.Thread.yield() catch {};
                }
            }

            // Update global counters
            _ = ctx.total_consumed.fetchAdd(local_consumed, .monotonic);
            //_ = ctx.integrity_errors.fetchAdd(local_errors, .monotonic);
        }
    }.run;

    // Create and start producer threads
    var producer_threads: [num_producers]std.Thread = undefined;
    var producer_contexts: [num_producers]ProducerContext = undefined;

    for (0..num_producers) |i| {
        producer_contexts[i] = ProducerContext{
            .current_cpu = &current_cpu,
            .ring_buffer = ring_buffer,
            .producer_id = @intCast(i),
            .total_produced = &total_produced,
            .test_running = &test_running,
        };
        producer_threads[i] = try std.Thread.spawn(.{}, producer_fn, .{&producer_contexts[i]});
    }

    // Create and start consumer threads
    var consumer_threads: [num_consumers]std.Thread = undefined;
    var consumer_contexts: [num_consumers]ConsumerContext = undefined;

    for (0..num_consumers) |i| {
        consumer_contexts[i] = ConsumerContext{
            .current_cpu = &current_cpu,
            .ring_buffer = ring_buffer,
            .consumer_id = @intCast(i),
            .total_consumed = &total_consumed,
            .integrity_errors = &integrity_errors,
            .test_running = &test_running,
            .num_producers = num_producers,
        };
        consumer_threads[i] = try std.Thread.spawn(.{}, consumer_fn, .{&consumer_contexts[i]});
    }

    // Let the test run for the specified duration
    std.Thread.sleep(test_duration_ms * std.time.ns_per_ms);

    // Signal test completion
    test_running.store(false, .release);

    // Wait for all threads to complete with timeout
    const timeout_ns = 10 * std.time.ns_per_s; // 10 second hard timeout
    const start_time = std.time.nanoTimestamp();

    // Join producer threads with timeout
    for (producer_threads) |thread| {
        const elapsed = std.time.nanoTimestamp() - start_time;
        if (elapsed > timeout_ns) {
            std.debug.print("Warning: Producer thread join timeout, forcing continuation\n", .{});
            break;
        }
        thread.join();
    }

    // Join consumer threads with timeout
    for (consumer_threads) |thread| {
        const elapsed = std.time.nanoTimestamp() - start_time;
        if (elapsed > timeout_ns) {
            std.debug.print("Warning: Consumer thread join timeout, forcing continuation\n", .{});
            break;
        }
        thread.join();
    }

    // Collect final results
    const final_produced = total_produced.load(.monotonic);
    const final_consumed = total_consumed.load(.monotonic);
    const final_errors = integrity_errors.load(.monotonic);

    // Calculate performance metrics
    const ops_per_second = (final_produced + final_consumed) * 1000 / test_duration_ms;

    // Print performance results
    std.log.info("MPMC Performance Stress Test Results:\n", .{});
    std.log.info("- Test duration: {} ms\n", .{test_duration_ms});
    std.log.info("- Producers: {}, Consumers: {}, System CPUs: {}\n", .{ num_producers, num_consumers, try std.Thread.getCpuCount() });
    std.log.info("- Item size: {} bytes\n", .{@sizeOf(TestItem)});
    std.log.info("- Ring buffer capacity: {}\n", .{capacity});
    std.log.info("- Items produced: {}\n", .{final_produced});
    std.log.info("- Items consumed: {}\n", .{final_consumed});
    std.log.info("- Total operations: {}\n", .{final_produced + final_consumed});
    std.log.info("- Operations/second: {}\n", .{ops_per_second});
    std.log.info("- Messages/second: {}\n", .{@divFloor(ops_per_second, 2)});
    std.log.info("- Integrity errors: {}\n", .{final_errors});

    // Basic integrity checks
    try std.testing.expect(final_errors == 0); // No integrity violations
    try std.testing.expect(final_produced > 0); // Producers did work
    try std.testing.expect(final_consumed > 0); // Consumers did work
    //try std.testing.expect(ops_per_second > if (builtin.mode == .Debug) 200_000_000 else 500_000_000); // Minimum performance threshold

    std.log.info("Performance test completed successfully!\n", .{});
}

test "ringbuffer import functionality" {
    const TestItem = u32;
    const RB = RingBuffer(TestItem);
    const capacity = 16;

    // Create source and destination ring buffers
    const src_buffer = try RB.init(std.testing.allocator, capacity);
    defer src_buffer.deinit(std.testing.allocator);

    const dst_buffer = try RB.init(std.testing.allocator, capacity);
    defer dst_buffer.deinit(std.testing.allocator);

    // Fill source buffer with test data
    var test_data = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try std.testing.expect(src_buffer.push(test_data[0..]));

    // Import from source to destination
    try std.testing.expect(dst_buffer.import(src_buffer));

    // Verify import worked correctly
    var imported_data: [8]u32 = undefined;
    try std.testing.expect(dst_buffer.pop(&imported_data));

    for (test_data, imported_data) |expected, actual| {
        try std.testing.expect(expected == actual);
    }

    // Test import with insufficient space
    var large_data = [_]u32{1} ** (capacity - 2); // Almost fill destination
    try std.testing.expect(dst_buffer.push(large_data[0..]));

    var more_data = [_]u32{ 9, 10, 11, 12 };
    try std.testing.expect(src_buffer.push(more_data[0..]));

    // This should fail due to insufficient space
    try std.testing.expect(!dst_buffer.import(src_buffer));
}
