const std = @import("std");
const testing = std.testing;

// Import the system components
const coreheap = @import("../mem/coreheap.zig");
const CoreHeap = coreheap.CoreHeap;
const Slab = coreheap.Slab;
const AllocationTicket = CoreHeap.AllocationTicket;

const thread_pool = @import("../orca/thread_pool.zig");
const ThreadPool = thread_pool.ThreadPool;
const Thread = thread_pool.Thread;
const Config = thread_pool.Config;
const Job = thread_pool.Job;

// =============================================================================
// Test Configuration
// =============================================================================

const TestConfig = struct {
    // Wave/agent configuration
    wave_generators: u32,
    agents_per_generator: u32,
    max_slabs_per_agent: usize,
    operations_per_agent: u32,

    // Heap configuration
    initial_heap_capacity: u32,
    maximum_heap_capacity: u32,

    // Thread pool configuration
    thread_count: u32,

    // Backoff configuration
    initial_backoff_us: u64 = 10,
    max_backoff_us: u64 = 1000,
    backoff_multiplier: u64 = 2,

    // Derived values
    pub fn totalAgents(self: TestConfig) u32 {
        return self.wave_generators * self.agents_per_generator;
    }

    pub fn totalOperations(self: TestConfig) u32 {
        return self.totalAgents() * self.operations_per_agent;
    }
};

// Stress test configuration
const STRESS_CONFIG = TestConfig{
    .wave_generators = 4,
    .agents_per_generator = 16,
    .max_slabs_per_agent = 8,
    .operations_per_agent = 100,
    .initial_heap_capacity = 256,
    .maximum_heap_capacity = 1024,
    .thread_count = 4,
};

// Performance test configuration
const PERF_CONFIG = TestConfig{
    .wave_generators = 7,
    .agents_per_generator = 1,
    .max_slabs_per_agent = 1,
    .operations_per_agent = 10000,
    .initial_heap_capacity = 1024,
    .maximum_heap_capacity = 32768,
    .thread_count = 15,
};

// =============================================================================
// Pool Configuration Helper
// =============================================================================

fn makePoolConfig(max_threads: u16) Config {
    const page_size = std.heap.pageSize();
    return .{
        .max_thread_count = max_threads,
        .stack_size = std.mem.alignForward(usize, 1024 * 64, page_size),
        .queue_capacity = 2048,
        .scale_up_load_threshold = 512,
        .scale_up_queue_threshold = 256,
        .steal_load_threshold = 384,
        .steal_queue_threshold = 192,
        .scale_up_extra_load = 64,
        .stress_increment = 4,
        .stress_decrement = 2,
        .scale_up_stress_threshold = 32,
    };
}

fn stressTestPoolConfig() Config {
    return makePoolConfig(16);
}

fn perfTestPoolConfig() Config {
    return makePoolConfig(16);
}

// =============================================================================
// Memory Integrity Pattern
// =============================================================================

const MAGIC_PATTERN: u64 = 0xDEADBEEFCAFEBABE;
const HEADER_SIZE: usize = 20; // Magic(8) + agent_id(4) + sequence(8)

/// Get a typed pointer at a byte offset from the slab (align(1) for unaligned access)
fn ptrAtOffset(comptime T: type, slab: *Slab, offset: usize) *align(1) T {
    return @as(*align(1) T, @ptrCast(@as([*]u8, @ptrCast(slab)) + offset));
}

/// Write a verification pattern to a slab
fn writePattern(slab: *Slab, agent_id: u32, sequence: u64) void {
    ptrAtOffset(u64, slab, 0).* = MAGIC_PATTERN;
    ptrAtOffset(u32, slab, 8).* = agent_id;
    ptrAtOffset(u64, slab, 12).* = sequence;

    // Fill rest with derived pattern
    var i: usize = HEADER_SIZE;
    while (i + 8 <= slab.len) : (i += 8) {
        ptrAtOffset(u64, slab, i).* = MAGIC_PATTERN ^ agent_id ^ sequence ^ @as(u64, @intCast(i));
    }
}

/// Verify a slab's header integrity
fn verifyPattern(slab: *Slab, agent_id: u32, sequence: u64) bool {
    if (ptrAtOffset(u64, slab, 0).* != MAGIC_PATTERN) return false;
    if (ptrAtOffset(u32, slab, 8).* != agent_id) return false;
    if (ptrAtOffset(u64, slab, 12).* != sequence) return false;
    return true;
}

/// Perform operations on allocated memory (preserves header)
fn performMemoryOperations(slab: *Slab) void {
    var sum: u64 = 0;
    var i: usize = HEADER_SIZE;
    while (i + 8 <= slab.len) : (i += 8) {
        const ptr = ptrAtOffset(u64, slab, i);
        sum = std.math.rotl(u64, sum, 7) ^ ptr.*;
        ptr.* = std.math.rotr(u64, ptr.* ^ sum, 3);
    }
}

// =============================================================================
// Performance Metrics
// =============================================================================

const Metrics = struct {
    alloc_latency_ns: std.atomic.Value(u64),
    alloc_count: std.atomic.Value(u64),
    alloc_failures: std.atomic.Value(u64),
    dealloc_latency_ns: std.atomic.Value(u64),
    dealloc_count: std.atomic.Value(u64),
    operation_latency_ns: std.atomic.Value(u64),
    operation_count: std.atomic.Value(u64),
    verification_failures: std.atomic.Value(u64),
    backoff_events: std.atomic.Value(u64),
    total_backoff_us: std.atomic.Value(u64),

    pub fn init() Metrics {
        return .{
            .alloc_latency_ns = .init(0),
            .alloc_count = .init(0),
            .alloc_failures = .init(0),
            .dealloc_latency_ns = .init(0),
            .dealloc_count = .init(0),
            .operation_latency_ns = .init(0),
            .operation_count = .init(0),
            .verification_failures = .init(0),
            .backoff_events = .init(0),
            .total_backoff_us = .init(0),
        };
    }

    pub fn recordAllocation(self: *Metrics, latency_ns: u64, success: bool) void {
        if (success) {
            _ = self.alloc_latency_ns.fetchAdd(latency_ns, .monotonic);
            _ = self.alloc_count.fetchAdd(1, .monotonic);
        } else {
            _ = self.alloc_failures.fetchAdd(1, .monotonic);
        }
    }

    pub fn recordDeallocation(self: *Metrics, latency_ns: u64) void {
        _ = self.dealloc_latency_ns.fetchAdd(latency_ns, .monotonic);
        _ = self.dealloc_count.fetchAdd(1, .monotonic);
    }

    pub fn recordOperation(self: *Metrics, latency_ns: u64) void {
        _ = self.operation_latency_ns.fetchAdd(latency_ns, .monotonic);
        _ = self.operation_count.fetchAdd(1, .monotonic);
    }

    pub fn recordVerificationFailure(self: *Metrics) void {
        _ = self.verification_failures.fetchAdd(1, .monotonic);
    }

    pub fn recordBackoff(self: *Metrics, backoff_us: u64) void {
        _ = self.backoff_events.fetchAdd(1, .monotonic);
        _ = self.total_backoff_us.fetchAdd(backoff_us, .monotonic);
    }

    pub fn printReport(self: *const Metrics) void {
        const alloc_count = self.alloc_count.load(.acquire);
        const alloc_failures = self.alloc_failures.load(.acquire);
        const dealloc_count = self.dealloc_count.load(.acquire);
        const op_count = self.operation_count.load(.acquire);

        std.debug.print("\n=== Performance Report ===\n", .{});
        std.debug.print("Allocations: {} successful, {} failed\n", .{ alloc_count, alloc_failures });
        if (alloc_count > 0) {
            const avg_alloc_ns = self.alloc_latency_ns.load(.acquire) / alloc_count;
            std.debug.print("Average allocation latency: {} ns\n", .{avg_alloc_ns});
        }
        if (dealloc_count > 0) {
            const avg_dealloc_ns = self.dealloc_latency_ns.load(.acquire) / dealloc_count;
            std.debug.print("Deallocations: {}, avg latency: {} ns\n", .{ dealloc_count, avg_dealloc_ns });
        }
        if (op_count > 0) {
            const avg_op_ns = self.operation_latency_ns.load(.acquire) / op_count;
            std.debug.print("Operations: {}, avg latency: {} ns\n", .{ op_count, avg_op_ns });
        }
        std.debug.print("Verification failures: {}\n", .{self.verification_failures.load(.acquire)});

        const backoff_events = self.backoff_events.load(.acquire);
        if (backoff_events > 0) {
            const total_backoff = self.total_backoff_us.load(.acquire);
            std.debug.print("Backoff events: {}, total: {} us, avg: {} us\n", .{
                backoff_events,
                total_backoff,
                total_backoff / backoff_events,
            });
        }
        std.debug.print("==========================\n\n", .{});
    }
};

// =============================================================================
// Agent FSM States
// =============================================================================

const AgentState = enum(u8) {
    preparing,
    allocating,
    working,
    verifying,
    deallocating,
    backing_off,
    completed,
};

// =============================================================================
// Agent Context
// =============================================================================

const AgentContext = struct {
    agent_id: u32,
    wave_id: u32,
    state: std.atomic.Value(AgentState),
    operations_completed: std.atomic.Value(u32),
    target_operations: u32,
    current_backoff_us: u64,
    backoff_until: u64,
    held_slabs: [STRESS_CONFIG.max_slabs_per_agent]?*Slab,
    held_count: usize,
    held_sequences: [STRESS_CONFIG.max_slabs_per_agent]u64,
    ticket: AllocationTicket,
    slabs_to_allocate: u32,
    allocation_start_time: u64,
    alloc_buffer: [STRESS_CONFIG.max_slabs_per_agent]*Slab,
    heap: *CoreHeap,
    pool: *ThreadPool,
    metrics: *Metrics,
    completed_count: *std.atomic.Value(u32),
};

// =============================================================================
// Agent FSM Job
// =============================================================================

const AgentFSM = struct {
    /// Process one state transition. Returns true if agent is still active.
    pub fn process(agent: *AgentContext, thread: *Thread) bool {
        const current_state = agent.state.load(.acquire);

        switch (current_state) {
            .preparing => {
                handlePreparing(agent, thread);
                return true;
            },
            .allocating => return handleAllocating(agent, thread),
            .working => {
                handleWorking(agent, thread);
                return true;
            },
            .verifying => {
                handleVerifying(agent, thread);
                return true;
            },
            .deallocating => {
                handleDeallocating(agent, thread);
                return true;
            },
            .backing_off => {
                handleBackingOff(agent, thread);
                return true;
            },
            .completed => return false,
        }
    }

    /// Main tick function - delegates to process for single code path
    pub fn tick(ctx: *anyopaque, thread: *Thread) void {
        const agent = @as(*AgentContext, @ptrCast(@alignCast(ctx)));
        _ = process(agent, thread);
    }

    fn handlePreparing(agent: *AgentContext, thread: *Thread) void {
        _ = thread;

        if (agent.operations_completed.load(.acquire) >= agent.target_operations) {
            agent.state.store(.completed, .release);
            _ = agent.completed_count.fetchAdd(1, .acq_rel);
            return;
        }

        // Determine how many slabs to allocate (bursty pattern)
        const ops_done = agent.operations_completed.load(.acquire);
        const variance = (agent.agent_id + ops_done) % STRESS_CONFIG.max_slabs_per_agent;
        agent.slabs_to_allocate = @intCast(@max(1, variance) + 1);
        agent.held_count = 0;

        @memset(&agent.alloc_buffer, undefined);

        agent.ticket = agent.heap.prepareAllocation(agent.slabs_to_allocate);
        agent.allocation_start_time = @intCast(std.time.nanoTimestamp());

        agent.state.store(.allocating, .release);
    }

    fn finishAllocation(agent: *AgentContext, latency: u64) void {
        agent.metrics.recordAllocation(latency, true);

        for (0..agent.slabs_to_allocate) |i| {
            const slab = agent.alloc_buffer[i];
            agent.held_slabs[i] = slab;
            agent.held_sequences[i] = agent.operations_completed.load(.acquire);
            writePattern(slab, agent.agent_id, agent.held_sequences[i]);
        }
        agent.held_count = agent.slabs_to_allocate;
        agent.current_backoff_us = STRESS_CONFIG.initial_backoff_us;
        agent.state.store(.working, .release);
    }

    fn handleAllocating(agent: *AgentContext, thread: *Thread) bool {
        const ticket_state = agent.ticket.state.load(.acquire);

        // Check if a previous deferred allocation has completed
        if (ticket_state == .complete) {
            const latency = @as(u64, @intCast(std.time.nanoTimestamp() - @as(i128, @intCast(agent.allocation_start_time))));
            finishAllocation(agent, latency);
            return true;
        }

        // If ticket is consumed, a slow allocation is in progress - just wait
        if (ticket_state == .consumed) {
            return true;
        }

        // Try to allocate
        const out_slabs = agent.alloc_buffer[0..agent.slabs_to_allocate];
        const result = agent.heap.allocate(thread, &agent.ticket, out_slabs, null);

        switch (result) {
            .immediate => {
                const latency = @as(u64, @intCast(std.time.nanoTimestamp() - @as(i128, @intCast(agent.allocation_start_time))));
                finishAllocation(agent, latency);
                return true;
            },
            .deferred, .consuming => {
                // Allocation deferred or being handled by another thread - wait
                return true;
            },
        }
    }

    fn handleWorking(agent: *AgentContext, thread: *Thread) void {
        _ = thread;
        const work_start: u64 = @intCast(std.time.nanoTimestamp());

        for (0..agent.held_count) |i| {
            if (agent.held_slabs[i]) |slab| {
                performMemoryOperations(slab);
            }
        }

        const work_latency = @as(u64, @intCast(std.time.nanoTimestamp() - @as(i128, @intCast(work_start))));
        agent.metrics.recordOperation(work_latency);
        agent.state.store(.verifying, .release);
    }

    fn handleVerifying(agent: *AgentContext, thread: *Thread) void {
        _ = thread;
        var all_valid = true;
        for (0..agent.held_count) |i| {
            if (agent.held_slabs[i]) |slab| {
                if (!verifyPattern(slab, agent.agent_id, agent.held_sequences[i])) {
                    agent.metrics.recordVerificationFailure();
                    all_valid = false;
                }
            }
        }

        if (!all_valid) {
            std.debug.print("Agent {}.{}: Memory corruption detected!\n", .{ agent.wave_id, agent.agent_id });
        }

        agent.state.store(.deallocating, .release);
    }

    fn handleDeallocating(agent: *AgentContext, thread: *Thread) void {
        const dealloc_start: u64 = @intCast(std.time.nanoTimestamp());

        var slabs_to_free: [STRESS_CONFIG.max_slabs_per_agent]*Slab = undefined;
        for (0..agent.held_count) |i| {
            slabs_to_free[i] = agent.held_slabs[i].?;
            agent.held_slabs[i] = null;
        }

        if (agent.held_count > 0) {
            const slab_slice = slabs_to_free[0..agent.held_count];
            agent.heap.deallocate(thread, slab_slice, true);

            const dealloc_latency = @as(u64, @intCast(std.time.nanoTimestamp() - @as(i128, @intCast(dealloc_start))));
            agent.metrics.recordDeallocation(dealloc_latency);
        }

        _ = agent.operations_completed.fetchAdd(1, .monotonic);
        agent.held_count = 0;
        agent.state.store(.preparing, .release);
    }

    fn handleBackingOff(agent: *AgentContext, thread: *Thread) void {
        _ = thread;
        const now: u64 = @intCast(std.time.nanoTimestamp());

        if (now >= agent.backoff_until) {
            agent.state.store(.allocating, .release);
            agent.allocation_start_time = now;
        }
    }
};

// =============================================================================
// Wave Generator
// =============================================================================

const WaveGenerator = struct {
    wave_id: u32,
    agents: [STRESS_CONFIG.agents_per_generator]AgentContext,
    active: std.atomic.Value(bool),

    pub fn init(
        self: *WaveGenerator,
        wave_id: u32,
        heap: *CoreHeap,
        pool: *ThreadPool,
        metrics: *Metrics,
        completed_count: *std.atomic.Value(u32),
    ) void {
        self.wave_id = wave_id;
        self.active = .init(true);

        for (0..STRESS_CONFIG.agents_per_generator) |i| {
            const agent_id = @as(u32, @intCast(wave_id * STRESS_CONFIG.agents_per_generator + i));
            self.agents[i] = AgentContext{
                .agent_id = agent_id,
                .wave_id = wave_id,
                .state = .init(.preparing),
                .operations_completed = .init(0),
                .target_operations = STRESS_CONFIG.operations_per_agent,
                .current_backoff_us = STRESS_CONFIG.initial_backoff_us,
                .backoff_until = 0,
                .held_slabs = @splat(null),
                .held_count = 0,
                .held_sequences = @splat(0),
                .ticket = undefined,
                .slabs_to_allocate = 0,
                .allocation_start_time = 0,
                .alloc_buffer = @splat(undefined),
                .heap = heap,
                .pool = pool,
                .metrics = metrics,
                .completed_count = completed_count,
            };
        }
    }
};

// =============================================================================
// Worker Context for Thread Pool
// =============================================================================

const WorkerContext = struct {
    generators: []WaveGenerator,

    pub fn workerTick(ctx: *anyopaque, thread: *Thread) void {
        const worker = @as(*@This(), @ptrCast(@alignCast(ctx)));

        var any_active = false;
        for (worker.generators) |*gen| {
            for (&gen.agents) |*agent| {
                if (AgentFSM.process(agent, thread)) {
                    any_active = true;
                }
            }
        }

        if (any_active) {
            const job = Job{
                .ctx = ctx,
                .tick = workerTick,
                .load = 1,
            };
            var jobs = [1]Job{job};
            _ = thread.submitLocal(&jobs);
        }
    }
};

// =============================================================================
// Test Setup Helpers
// =============================================================================

fn initHeap(pool: *ThreadPool, config: TestConfig) !*CoreHeap {
    return try CoreHeap.init(
        config.initial_heap_capacity,
        config.maximum_heap_capacity,
        pool,
        16, // minimum_growth
        64, // maximum_growth_from_scalar
        10, // pre_growth_scalar
        20, // extra_growth_scalar
        200, // proactive_grow_threshold
    );
}

fn submitWorkerJobs(pool: *ThreadPool, worker_ctxs: []WorkerContext) void {
    var submitted: usize = 0;
    while (submitted < worker_ctxs.len) {
        const job = Job{
            .ctx = &worker_ctxs[submitted],
            .tick = WorkerContext.workerTick,
            .load = 1,
        };
        var jobs = [1]Job{job};
        const result = pool.submit(&jobs);
        if (result > 0) {
            submitted += 1;
        } else {
            std.Thread.yield() catch {};
        }
    }
    std.debug.print("Submitted {} worker jobs\n", .{submitted});
}

fn waitForCompletion(
    completed_count: *std.atomic.Value(u32),
    total_agents: u32,
    timeout_ms: i64,
) !void {
    const start_time: i64 = std.time.milliTimestamp();
    var last_printed: i64 = 0;

    while (true) {
        const now = std.time.milliTimestamp();
        if (now - start_time > timeout_ms) {
            std.debug.print("Test timeout! Completed: {}/{} agents\n", .{
                completed_count.load(.acquire),
                total_agents,
            });
            return error.TestTimeout;
        }

        const completed = completed_count.load(.acquire);
        if (completed >= total_agents) {
            std.debug.print("All {} agents completed successfully!\n", .{total_agents});
            break;
        }

        if (now - last_printed > 2000) {
            std.debug.print("Progress: {}/{} agents completed ({} ms elapsed)\n", .{
                completed,
                total_agents,
                now - start_time,
            });
            last_printed = now;
        }

        std.Thread.yield() catch {};
    }
}

// =============================================================================
// Main Stress Test
// =============================================================================

test "coreheap heavy contention stress test" {
    std.debug.print("\nStarting coreheap heavy contention stress test...\n", .{});
    std.debug.print("Configuration: {} wave generators x {} agents = {} total agents\n", .{
        STRESS_CONFIG.wave_generators,
        STRESS_CONFIG.agents_per_generator,
        STRESS_CONFIG.totalAgents(),
    });

    const pool = try ThreadPool.init(stressTestPoolConfig(), STRESS_CONFIG.thread_count);
    defer pool.deinit() catch unreachable;

    const heap = try initHeap(pool, STRESS_CONFIG);

    std.debug.print("Heap initialized: initial_capacity={}, max_capacity={}\n", .{
        STRESS_CONFIG.initial_heap_capacity,
        STRESS_CONFIG.maximum_heap_capacity,
    });

    var metrics = Metrics.init();
    var completed_count = std.atomic.Value(u32).init(0);

    var generators: [STRESS_CONFIG.wave_generators]WaveGenerator = undefined;
    for (0..STRESS_CONFIG.wave_generators) |i| {
        generators[i].init(@intCast(i), heap, pool, &metrics, &completed_count);
    }

    var worker_ctxs: [STRESS_CONFIG.wave_generators]WorkerContext = undefined;
    for (0..STRESS_CONFIG.wave_generators) |i| {
        worker_ctxs[i].generators = generators[i .. i + 1];
    }

    submitWorkerJobs(pool, &worker_ctxs);
    try waitForCompletion(&completed_count, STRESS_CONFIG.totalAgents(), 60000);

    metrics.printReport();

    const verification_failures = metrics.verification_failures.load(.acquire);
    try testing.expectEqual(@as(u64, 0), verification_failures);

    std.debug.print("Coreheap stress test completed successfully!\n", .{});
}

// =============================================================================
// Simpler Integration Test
// =============================================================================

test "coreheap basic threadpool integration" {
    std.debug.print("\nTesting basic coreheap + threadpool integration...\n", .{});

    const pool = try ThreadPool.init(stressTestPoolConfig(), 2);
    defer pool.deinit() catch unreachable;

    const heap = try CoreHeap.init(
        32, // small initial capacity
        128,
        pool,
        8,
        32,
        10,
        20,
        200,
    );

    // Simple allocation test from main thread
    var ticket: AllocationTicket = heap.prepareAllocation(4);

    var slabs: [4]*Slab = undefined;
    const result = heap.allocate(@ptrCast(pool.getThread(0)), &ticket, &slabs, null);

    try testing.expect(result == .immediate or result == .deferred);

    if (result == .immediate) {
        for (&slabs) |slab| {
            writePattern(slab, 0, 0);
            try testing.expect(verifyPattern(slab, 0, 0));
        }

        heap.deallocate(@ptrCast(pool.getThread(0)), &slabs, true);
    }

    std.debug.print("Basic integration test passed!\n", .{});
}

// =============================================================================
// Performance Test
// =============================================================================

const PerfAgentContext = struct {
    agent_id: u32,
    wave_id: u32,
    operations_completed: std.atomic.Value(u32),
    target_operations: u32,
    held_slab: ?*Slab,
    held_sequence: u64,
    ticket: AllocationTicket,
    alloc_buffer: [PERF_CONFIG.max_slabs_per_agent]*Slab,
    heap: *CoreHeap,
    pool: *ThreadPool,
    metrics: *Metrics,
    completed_count: *std.atomic.Value(u32),
    latency_histogram: [10]std.atomic.Value(u64),

    fn recordLatency(self: *PerfAgentContext, latency_ns: u64) void {
        const bucket = @min(latency_ns / 100, 9);
        _ = self.latency_histogram[bucket].fetchAdd(1, .monotonic);
    }
};

const PerfWaveGenerator = struct {
    wave_id: u32,
    agent: PerfAgentContext,

    pub fn init(
        self: *PerfWaveGenerator,
        wave_id: u32,
        heap: *CoreHeap,
        pool: *ThreadPool,
        metrics: *Metrics,
        completed_count: *std.atomic.Value(u32),
    ) void {
        self.wave_id = wave_id;

        var histogram: [10]std.atomic.Value(u64) = undefined;
        for (0..10) |i| {
            histogram[i] = .init(0);
        }

        self.agent = PerfAgentContext{
            .agent_id = wave_id,
            .wave_id = wave_id,
            .operations_completed = .init(0),
            .target_operations = PERF_CONFIG.operations_per_agent,
            .held_slab = null,
            .held_sequence = 0,
            .ticket = undefined,
            .alloc_buffer = @splat(undefined),
            .heap = heap,
            .pool = pool,
            .metrics = metrics,
            .completed_count = completed_count,
            .latency_histogram = histogram,
        };
    }
};

fn perfAgentTick(ctx: *anyopaque, thread: *Thread) void {
    const agent = @as(*PerfAgentContext, @ptrCast(@alignCast(ctx)));

    if (agent.operations_completed.load(.acquire) >= agent.target_operations) {
        _ = agent.completed_count.fetchAdd(1, .acq_rel);
        return;
    }

    if (agent.held_slab == null) {
        // Allocate
        agent.ticket = agent.heap.prepareAllocation(1);
        const alloc_start: i128 = std.time.nanoTimestamp();

        var out_slabs: [1]*Slab = undefined;
        const result = agent.heap.allocate(thread, &agent.ticket, &out_slabs, null);

        const alloc_end: i128 = std.time.nanoTimestamp();
        const latency = @as(u64, @intCast(alloc_end - alloc_start));

        switch (result) {
            .immediate => {
                agent.metrics.recordAllocation(latency, true);
                agent.recordLatency(latency);
                agent.held_slab = out_slabs[0];
                agent.held_sequence = agent.operations_completed.load(.acquire);
                writePattern(agent.held_slab.?, agent.agent_id, agent.held_sequence);
            },
            .deferred, .consuming => {
                agent.metrics.recordAllocation(latency, false);
                _ = agent.metrics.alloc_failures.fetchAdd(1, .monotonic);
            },
        }
    } else {
        // Verify and perform work (outside of deallocation timing)
        if (!verifyPattern(agent.held_slab.?, agent.agent_id, agent.held_sequence)) {
            agent.metrics.recordVerificationFailure();
        }
        performMemoryOperations(agent.held_slab.?);

        // Measure ONLY deallocation latency
        const dealloc_start: i128 = std.time.nanoTimestamp();
        var slabs_to_free: [1]*Slab = .{agent.held_slab.?};
        agent.heap.deallocate(thread, &slabs_to_free, false); // disable erase for perf test
        const dealloc_end: i128 = std.time.nanoTimestamp();

        const dealloc_latency = @as(u64, @intCast(dealloc_end - dealloc_start));
        agent.metrics.recordDeallocation(dealloc_latency);

        agent.held_slab = null;
        _ = agent.operations_completed.fetchAdd(1, .monotonic);
    }

    const job = Job{
        .ctx = ctx,
        .tick = perfAgentTick,
        .load = 1,
    };
    var jobs = [1]Job{job};
    _ = thread.submitLocal(&jobs);
}

fn printPerfResults(
    metrics: *const Metrics,
    generators: []PerfWaveGenerator,
    total_duration_ns: u64,
    total_ops: u32,
) void {
    const alloc_count = metrics.alloc_count.load(.acquire);
    const total_alloc_ns = metrics.alloc_latency_ns.load(.acquire);
    const avg_alloc_ns = if (alloc_count > 0) total_alloc_ns / alloc_count else 0;

    const dealloc_count = metrics.dealloc_count.load(.acquire);
    const total_dealloc_ns = metrics.dealloc_latency_ns.load(.acquire);
    const avg_dealloc_ns = if (dealloc_count > 0) total_dealloc_ns / dealloc_count else 0;

    const throughput = @as(f64, @floatFromInt(total_ops)) / (@as(f64, @floatFromInt(total_duration_ns)) / 1_000_000_000.0);

    std.debug.print("\n╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                  Performance Results                       ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n\n", .{});

    std.debug.print("Timing Summary:\n", .{});
    std.debug.print("  Total test duration: {d:.3} ms\n", .{@as(f64, @floatFromInt(total_duration_ns)) / 1_000_000.0});
    std.debug.print("  Total operations: {}\n", .{total_ops});
    std.debug.print("  Throughput: {d:.2} ops/sec\n\n", .{throughput});

    std.debug.print("Allocation Latency:\n", .{});
    std.debug.print("  Total allocations: {}\n", .{alloc_count});
    std.debug.print("  Average latency: {} ns ({} µs)\n", .{
        avg_alloc_ns,
        @as(f64, @floatFromInt(avg_alloc_ns)) / 1000.0,
    });

    if (avg_alloc_ns < 1000) {
        std.debug.print("  ✓ Sub-microsecond average achieved!\n", .{});
    } else {
        std.debug.print("  ⚠ Average exceeded 1µs\n", .{});
    }

    std.debug.print("\nAllocation Latency Histogram:\n", .{});
    const labels = [_][]const u8{
        "<100 ns ", "<200 ns ", "<300 ns ", "<400 ns ", "<500 ns ",
        "<600 ns ", "<700 ns ", "<800 ns ", "<900 ns ", "<1000ns+",
    };

    for (0..10) |i| {
        var count: u64 = 0;
        for (generators) |*gen| {
            count += gen.agent.latency_histogram[i].load(.acquire);
        }
        const pct = if (alloc_count > 0)
            @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(alloc_count)) * 100.0
        else
            0.0;
        const bar_len = @as(usize, @intFromFloat(@min(pct / 2.0, 50.0)));
        std.debug.print("  {s} |", .{labels[i]});
        for (0..bar_len) |_| std.debug.print("█", .{});
        std.debug.print(" {d:>6.2}% ({})\n", .{ pct, count });
    }

    std.debug.print("\nDeallocation Latency:\n", .{});
    std.debug.print("  Total deallocations: {}\n", .{dealloc_count});
    std.debug.print("  Average latency: {} ns ({} µs)\n\n", .{
        avg_dealloc_ns,
        @as(f64, @floatFromInt(avg_dealloc_ns)) / 1000.0,
    });

    const verification_failures = metrics.verification_failures.load(.acquire);
    std.debug.print("Data Integrity:\n", .{});
    std.debug.print("  Verification failures: {}\n\n", .{verification_failures});

    std.debug.print("╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║              Fast-Path Performance Test Complete           ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n\n", .{});
}

test "coreheap performance test" {
    std.debug.print("\n╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║         CoreHeap Fast-Path Performance Test               ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n", .{});

    std.debug.print("\nConfiguration:\n", .{});
    std.debug.print("  - Agents: {} ({} generators x {} agents)\n", .{
        PERF_CONFIG.totalAgents(),
        PERF_CONFIG.wave_generators,
        PERF_CONFIG.agents_per_generator,
    });
    std.debug.print("  - Heap capacity: {} initial / {} max (no growth)\n", .{
        PERF_CONFIG.initial_heap_capacity,
        PERF_CONFIG.maximum_heap_capacity,
    });
    std.debug.print("  - Operations per agent: {}\n", .{PERF_CONFIG.operations_per_agent});
    std.debug.print("  - Total operations: {}\n", .{PERF_CONFIG.totalOperations()});
    std.debug.print("  - Thread pool size: {}\n", .{PERF_CONFIG.thread_count});
    std.debug.print("  - Target: sub-microsecond fast-path allocations\n\n", .{});

    const pool = try ThreadPool.init(perfTestPoolConfig(), PERF_CONFIG.thread_count);
    defer pool.deinit() catch unreachable;

    const heap = try initHeap(pool, PERF_CONFIG);

    var metrics = Metrics.init();
    var completed_count = std.atomic.Value(u32).init(0);

    var generators: [PERF_CONFIG.wave_generators]PerfWaveGenerator = undefined;
    for (0..PERF_CONFIG.wave_generators) |i| {
        generators[i].init(@intCast(i), heap, pool, &metrics, &completed_count);
    }

    const test_start: i128 = std.time.nanoTimestamp();

    for (0..PERF_CONFIG.wave_generators) |i| {
        const job = Job{
            .ctx = &generators[i].agent,
            .tick = perfAgentTick,
            .load = 1,
        };
        var jobs = [1]Job{job};
        _ = pool.submit(&jobs);
    }

    const timeout_ns: i128 = 30_000_000_000;

    while (true) {
        const now = std.time.nanoTimestamp();
        if (now - test_start > timeout_ns) {
            std.debug.print("Test timeout! Completed: {}/{} agents\n", .{
                completed_count.load(.acquire),
                PERF_CONFIG.totalAgents(),
            });
            return error.TestTimeout;
        }

        const completed = completed_count.load(.acquire);
        if (completed >= PERF_CONFIG.totalAgents()) {
            break;
        }

        std.Thread.yield() catch {};
    }

    const test_end: i128 = std.time.nanoTimestamp();
    const total_duration_ns = @as(u64, @intCast(test_end - test_start));

    printPerfResults(&metrics, &generators, total_duration_ns, PERF_CONFIG.totalOperations());

    try testing.expectEqual(@as(u64, 0), metrics.verification_failures.load(.acquire));
    try testing.expect(metrics.alloc_count.load(.acquire) >= PERF_CONFIG.totalOperations() - 10);
}
