const std = @import("std");
const VPA = @import("./virtual_page_allocator.zig").VirtualPageAllocator;
const RingBuffer = @import("./ring_buffer.zig").RingBuffer;
const ThreadPool = @import("../orca/thread_pool.zig").ThreadPool;
const Thread = @import("../orca/thread_pool.zig").Thread;
const Job = @import("../orca/thread_pool.zig").Job;
const Epoch = @import("../orca/epoch.zig").Epoch;
const QSBR = @import("../orca/qsbr.zig").QSBR;
const OptionalU16 = @import("./unmanaged_optional.zig").Optional(u16);

pub const SLAB_SIZE: usize = 16 * 1024; // 16KiB
pub const Slab = [SLAB_SIZE]u8;

/// Spin loop iteration limits for various operations.
const SPIN_LIMITS = struct {
    version_sync: u32 = 100_000,
    dealloc_outer: u64 = 10_000,
    dealloc_inner: u32 = 10_000,
    grow_quiescent: u64 = 1_000_000,
    submit_retry: u32 = 10_000,
    pool_submit: u64 = 10_000,
};

/// Grow phase enumeration.
const Phase = enum(u3) {
    idle = 0,
    claimed = 1,
    active = 2,
    importing = 3,
    exiting = 4,
};

/// Compact grow state that fits in u64 for atomic operations.
/// Callback buffer pointer is computed from new_capacity when needed.
const GrowState = packed struct(u64) {
    phase: Phase,
    new_capacity: u32,
    reserved: u29 = 0,
};

/// A thread-safe, growable memory heap for allocating fixed-size slabs.
pub const CoreHeap = struct {
    const FreeList = RingBuffer(*Slab);
    const CallbackBuffer = RingBuffer(Job);
    const Self = @This();

    // Static configuration
    reserved_byte_len: usize,
    maximum_capacity: u32,
    thread_pool: *ThreadPool,
    grow_job: GrowJob,
    minimum_growth: u32,
    maximum_growth_from_scalar: u32,
    extra_growth_scalar: u8,
    pre_growth_scalar: u8,
    proactive_threshold: u8,

    // Mutable state (cache-line aligned)
    demanded_capacity: std.atomic.Value(u32) align(std.atomic.cache_line),
    actual_capacity: std.atomic.Value(u32) align(std.atomic.cache_line),

    // Synchronization (cache-line aligned)
    epoch: Epoch align(std.atomic.cache_line),
    grow_state: std.atomic.Value(GrowState) align(std.atomic.cache_line),
    qsbr: QSBR align(std.atomic.cache_line),
    grow_thread: std.atomic.Value(OptionalU16),

    // Freelist management
    freelist_ptr: std.atomic.Value(u64), // Packed pointer

    const GrowJob = struct {
        ctx: *CoreHeap,
        load: u8,

        pub fn tick(ctx: *anyopaque, thread: *Thread) void {
            const heap = @as(*CoreHeap, @ptrCast(@alignCast(ctx)));

            // Try to become the grow thread
            if (heap.grow_thread.cmpxchgStrong(.none(), .wrap(thread.getIndex()), .acq_rel, .acquire)) |_| {
                return; // Another thread is already growing
            }
            defer heap.grow_thread.store(.none(), .release);

            // Perform grow operations while needed
            while (heap.checkGrowWanted()) {
                const new_capacity = heap.calculateGrowCapacity();
                const current_cap = heap.actual_capacity.load(.monotonic);

                if (new_capacity <= current_cap) {
                    return; // At max capacity
                }

                heap.grow(new_capacity) catch |e| {
                    std.log.err("Failed to grow heap to {} slabs: {}", .{ new_capacity, e });
                    return;
                };
            }
        }
    };

    // Offset calculations (same as coreheap2)
    inline fn offsetSlabs(thread_pool: *ThreadPool) usize {
        _ = thread_pool;
        const hdr = @sizeOf(Self);
        const qsbr_off = hdr + @sizeOf(Epoch);
        const aligned_qsbr = std.mem.alignForward(usize, qsbr_off, @alignOf(QSBR));
        const after_qsbr = aligned_qsbr + @sizeOf(QSBR);
        return std.mem.alignForward(usize, after_qsbr, std.atomic.cache_line);
    }

    inline fn offsetFreelist(capacity: u32, thread_pool: *ThreadPool) usize {
        const slabs_off = offsetSlabs(thread_pool);
        const slabs_size = @as(usize, capacity) * SLAB_SIZE;
        return std.mem.alignForward(usize, slabs_off + slabs_size, FreeList.alignOf());
    }

    inline fn freelistSize(capacity: u32) u32 {
        const ceiled = std.math.ceilPowerOfTwo(u64, @intCast(capacity)) catch |e|
            std.debug.panic("Failed to calculate freelist size: {}", .{e});
        return @intCast(ceiled);
    }

    inline fn offsetGrowCBBuf(new_capacity: u32, thread_pool: *ThreadPool) usize {
        const pre = usualSizeOf(new_capacity, thread_pool);
        return std.mem.alignForward(usize, pre, CallbackBuffer.alignOf());
    }

    pub inline fn usualSizeOf(capacity: u32, thread_pool: *ThreadPool) usize {
        const pre = offsetFreelist(capacity, thread_pool);
        return pre + FreeList.sizeOf(freelistSize(capacity));
    }

    pub inline fn sizeOf(capacity: u32, maximum_capacity: u32, thread_pool: *ThreadPool) usize {
        const pre = offsetGrowCBBuf(capacity, thread_pool);
        return pre + CallbackBuffer.sizeOf(maximum_capacity);
    }

    inline fn slabPtr(self: *Self, thread_pool: *ThreadPool, index: u32) *Slab {
        const base = @intFromPtr(self) + offsetSlabs(thread_pool);
        return @ptrFromInt(base + SLAB_SIZE * index);
    }

    fn callbacksPtr(self: *Self, new_capacity: u32) *CallbackBuffer {
        const offset = offsetGrowCBBuf(new_capacity, self.thread_pool);
        return @ptrFromInt(@intFromPtr(self) + offset);
    }

    /// Returns a coherent snapshot of capacity state.
    fn getCapacitySnapshot(self: *Self) struct { actual: u32, demanded: u32 } {
        var actual = self.actual_capacity.load(.acquire);
        var demanded: u32 = undefined;
        var iterations: u32 = 0;
        const limits = SPIN_LIMITS{};

        while (true) {
            if (iterations > limits.version_sync) {
                std.debug.panic("getCapacitySnapshot: spin timeout after {} iterations", .{iterations});
            }
            iterations += 1;

            demanded = self.demanded_capacity.load(.monotonic);
            const current_actual = self.actual_capacity.load(.acquire);
            if (current_actual == actual) break;
            actual = current_actual;
            std.atomic.spinLoopHint();
        }

        return .{ .actual = actual, .demanded = demanded };
    }

    fn calculateGrowCapacity(self: *Self) u32 {
        const capacity = self.getCapacitySnapshot();
        const target: u32 = if (capacity.actual >= capacity.demanded)
            capacity.actual + @max(capacity.actual - capacity.demanded, @min(self.maximum_growth_from_scalar, @as(u32, capacity.actual >> 8) * @as(u32, self.pre_growth_scalar)))
        else
            capacity.demanded + @min(self.maximum_growth_from_scalar, @as(u32, (capacity.demanded - capacity.actual) >> 8) * @as(u32, self.extra_growth_scalar));
        return @min(self.maximum_capacity, target);
    }

    fn checkGrowWanted(self: *Self) bool {
        const capacity = self.getCapacitySnapshot();
        return capacity.demanded > capacity.actual or
            capacity.demanded > @as(u32, capacity.actual >> 8) * @as(u32, self.proactive_threshold);
    }

    /// Transition grow phase with epoch barrier.
    /// Waits for all threads to reach current epoch before bumping and returning.
    fn transitionGrowPhase(self: *Self, new_phase: Phase, new_capacity: u32) void {
        const current_epoch = self.epoch.current();
        const new_epoch = self.epoch.bump();
        const limits = SPIN_LIMITS{};

        // Wait for all threads to acknowledge current state before changing
        if (!self.qsbr.spinForQuiescent(current_epoch, limits.grow_quiescent)) {
            std.debug.panic("transitionGrowPhase: timeout waiting for epoch {}", .{current_epoch});
        }

        // Safe to publish new state
        const new_state = GrowState{
            .phase = new_phase,
            .new_capacity = new_capacity,
        };
        self.grow_state.store(new_state, .release);

        // Wait for all threads to acknowledge new epoch
        if (!self.qsbr.spinForQuiescent(new_epoch, limits.grow_quiescent)) {
            std.debug.panic("transitionGrowPhase: timeout waiting for epoch {} after phase change", .{new_epoch});
        }
    }

    fn grow(self: *Self, new_capacity: u32) !void {
        const limits = SPIN_LIMITS{};
        const old_capacity = self.actual_capacity.load(.monotonic);

        if (new_capacity <= old_capacity) {
            return error.InvalidCapacity;
        }

        // Phase 1: Claim exclusive grow right
        self.transitionGrowPhase(.claimed, new_capacity);

        // Phase 2: Commit VPA memory
        const old_size = sizeOf(old_capacity, self.maximum_capacity, self.thread_pool);
        const new_size = sizeOf(new_capacity, self.maximum_capacity, self.thread_pool);
        const commit_start = std.mem.alignForward(usize, @intFromPtr(self) + old_size, VPA.page_size);
        const commit_end = std.mem.alignForward(usize, @intFromPtr(self) + new_size, VPA.page_size);

        if (commit_end > commit_start) {
            const size_to_commit = commit_end - commit_start;
            VPA.commitVirtualPages(@ptrFromInt(commit_start), size_to_commit) catch {
                self.transitionGrowPhase(.idle, 0);
                return error.InsufficientMemory;
            };
        }

        // Phase 3: Initialize callback buffer and new freelist
        const callbacks = self.callbacksPtr(new_capacity);
        _ = CallbackBuffer.initAtPtr(@ptrCast(callbacks), self.maximum_capacity) catch |e| {
            self.transitionGrowPhase(.idle, 0);
            std.debug.panic("Failed to initialize callback buffer: {}", .{e});
        };

        const new_freelist_ptr = @as([*]u8, @ptrFromInt(@intFromPtr(self) + offsetFreelist(new_capacity, self.thread_pool)));
        const new_freelist_capacity = freelistSize(new_capacity);
        const new_freelist = FreeList.initAtPtr(new_freelist_ptr, new_freelist_capacity) catch |e| {
            self.transitionGrowPhase(.idle, 0);
            std.debug.panic("Failed to initialize new freelist: {}", .{e});
        };

        // Calculate safe/unsafe slab ranges
        const old_freelist_size = FreeList.sizeOf(freelistSize(old_capacity));
        const aligned_old_freelist_end = std.mem.alignForward(usize, offsetFreelist(old_capacity, self.thread_pool) + old_freelist_size, std.atomic.cache_line);
        const unsafe_slabs_start = offsetSlabs(self.thread_pool) + @as(usize, old_capacity) * SLAB_SIZE;
        const safe_slabs_start = @max(aligned_old_freelist_end, unsafe_slabs_start);
        const idx_unsafe_start: u32 = @truncate((unsafe_slabs_start - offsetSlabs(self.thread_pool)) / SLAB_SIZE);
        const idx_safe_start: u32 = @truncate((safe_slabs_start - offsetSlabs(self.thread_pool)) / SLAB_SIZE);
        const safe_count = new_capacity - idx_safe_start;

        // Phase 4: Push safe slabs to new freelist
        var buffer: [256]*Slab = undefined;
        var remaining = safe_count;
        var index = idx_safe_start;
        while (remaining > 0) {
            const batch = @min(remaining, @as(u32, @intCast(buffer.len)));
            for (0..batch) |i| {
                buffer[i] = self.slabPtr(self.thread_pool, index + @as(u32, @intCast(i)));
            }
            if (new_freelist.pushSome(buffer[0..batch]) < batch) {
                std.debug.panic("Failed to push safe slabs to new freelist", .{});
            }
            remaining -= batch;
            index += batch;
        }

        // Phase 5: Transition to active and switch freelist
        self.transitionGrowPhase(.active, new_capacity);

        // Atomic switch to new freelist
        const old_freelist: *FreeList = @ptrFromInt(self.freelist_ptr.load(.acquire));
        self.freelist_ptr.store(@intFromPtr(new_freelist), .release);

        // Temporarily update actual capacity
        const temp_capacity = @max(old_capacity, @min(old_capacity, self.demanded_capacity.load(.monotonic)) + safe_count);
        self.actual_capacity.store(temp_capacity, .release);

        // Phase 6: Transition to importing and import old freelist
        self.transitionGrowPhase(.importing, new_capacity);

        if (!new_freelist.import(old_freelist)) {
            std.debug.panic("Failed to import old freelist", .{});
        }

        // Phase 7: Push unsafe slabs
        remaining = idx_safe_start - idx_unsafe_start;
        index = idx_unsafe_start;
        while (remaining > 0) {
            const batch = @min(remaining, @as(u32, @intCast(buffer.len)));
            for (0..batch) |i| {
                buffer[i] = self.slabPtr(self.thread_pool, index + @as(u32, @intCast(i)));
            }
            if (new_freelist.pushSome(buffer[0..batch]) < batch) {
                std.debug.panic("Failed to push unsafe slabs to new freelist", .{});
            }
            remaining -= batch;
            index += batch;
        }

        // Update actual capacity to full new capacity
        self.actual_capacity.store(new_capacity, .release);

        // Phase 8: Transition to exiting and run callbacks
        self.transitionGrowPhase(.exiting, new_capacity);

        var finalized = false;
        var iterations: u64 = 0;
        while (true) {
            if (iterations > limits.grow_quiescent) {
                std.debug.panic("grow: callback loop timeout after {} iterations", .{iterations});
            }
            iterations += 1;

            var job = [1]Job{undefined};
            const popped = callbacks.pop(job[0..1]);

            if (finalized and !popped) break;

            if (!popped) {
                finalized = self.qsbr.quiescent(self.epoch.current());
                if (!finalized) std.atomic.spinLoopHint();
            } else {
                var done: u64 = 0;
                var submit_iters: u32 = 0;
                while (done == 0) {
                    if (submit_iters > limits.submit_retry) {
                        std.debug.panic("grow: callback submission timeout", .{});
                    }
                    submit_iters += 1;
                    done = self.thread_pool.submit(job[0..1]);
                    if (done == 0) std.Thread.yield() catch {};
                }
            }
        }

        // Phase 9: Return to idle
        self.transitionGrowPhase(.idle, 0);
    }

    fn suggestGrow(self: *Self) void {
        const limits = SPIN_LIMITS{};
        const grow_active = self.grow_thread.load(.monotonic);

        var job_arr = [_]Job{Job{
            .ctx = self.grow_job.ctx,
            .load = self.grow_job.load,
            .tick = GrowJob.tick,
        }};

        if (!grow_active.is_some) {
            var done: u64 = 0;
            var i: u64 = 0;
            while (done == 0) {
                if (i > limits.pool_submit) {
                    std.debug.panic("suggestGrow: submission timeout after {} iterations", .{i});
                }
                done = self.thread_pool.submit(job_arr[0..1]);
                if (done == 0) std.Thread.yield() catch {};
                i += 1;
            }
        }
    }

    /// Context for asynchronous allocations.
    const AllocationContext = struct {
        self: *Self,
        thread: *Thread,
        slabs: []*Slab,
        callback: ?Job,
    };

    pub const AllocationTicket = struct {
        context: AllocationContext,
        state: std.atomic.Value(enum(usize) { pending, consumed, complete }),
    };

    /// Slow allocation job for retrying allocations during/after grow.
    const SlowAllocationJob = struct {
        fn tryAllocateNow(context: *AllocationContext, thread: *Thread) bool {
            const self = context.self;
            const thread_idx = thread.getIndex();
            const limits = SPIN_LIMITS{};

            // Coherent state read - enter QSBR first, then verify epoch
            var freelist: *FreeList = undefined;
            var iterations: u32 = 0;
            while (true) {
                if (iterations > limits.version_sync) {
                    std.debug.panic("tryAllocateNow: spin timeout after {} iterations", .{iterations});
                }
                iterations += 1;

                // Enter QSBR with current epoch
                const epoch = self.epoch.current();
                self.qsbr.enter(thread_idx, epoch);

                // Read state AFTER entering QSBR
                const state = self.grow_state.load(.acquire);
                const fl_ptr = self.freelist_ptr.load(.acquire);

                // Verify epoch hasn't changed
                if (self.epoch.current() == epoch) {
                    // Check if we can allocate in current phase
                    switch (state.phase) {
                        .idle, .claimed => {
                            freelist = @ptrFromInt(fl_ptr);
                            break;
                        },
                        .active, .importing => {
                            self.qsbr.exit(thread_idx);
                            return false; // Need to register callback
                        },
                        .exiting => {
                            self.qsbr.exit(thread_idx);
                            return false; // Retry
                        },
                    }
                }

                // Epoch changed - exit and retry
                self.qsbr.exit(thread_idx);
                std.atomic.spinLoopHint();
            }
            defer self.qsbr.exit(thread_idx);

            if (!freelist.pop(context.slabs)) return false;

            const ticket: *AllocationTicket = @fieldParentPtr("context", context);
            ticket.state.store(.complete, .release);

            // Submit callback if requested
            if (context.callback) |cb| {
                var jobs_buf = [1]Job{cb};
                var done: u64 = 0;
                var submit_iters: u32 = 0;
                const limits2 = SPIN_LIMITS{};
                while (done == 0) {
                    if (submit_iters > limits2.submit_retry) {
                        std.debug.panic("tryAllocateNow: callback submission timeout", .{});
                    }
                    submit_iters += 1;
                    done = self.thread_pool.submit(&jobs_buf);
                    if (done == 0) std.Thread.yield() catch {};
                }
            }
            return true;
        }

        pub fn tick(ctx: *anyopaque, thread: *Thread) void {
            const limits = SPIN_LIMITS{};
            const context = @as(*AllocationContext, @ptrCast(@alignCast(ctx)));
            const self = context.self;
            const thread_idx = thread.getIndex();

            // Try to allocate immediately
            if (tryAllocateNow(context, thread)) return;

            // Check grow state and potentially register callback or trigger grow
            while (true) {
                // Enter QSBR first, then read state
                const epoch = self.epoch.current();
                self.qsbr.enter(thread_idx, epoch);

                const state = self.grow_state.load(.acquire);

                if (self.epoch.current() != epoch) {
                    self.qsbr.exit(thread_idx);
                    continue;
                }

                switch (state.phase) {
                    .idle => {
                        self.qsbr.exit(thread_idx);
                        // Try allocate again or trigger grow
                        if (tryAllocateNow(context, thread)) return;

                        // Try to become grow thread
                        const lost_race = self.grow_thread.cmpxchgWeak(.none(), .wrap(thread_idx), .acq_rel, .monotonic);
                        if (lost_race) |_| {
                            // Resubmit to pool
                            var jobs_buf = [1]Job{Job{
                                .ctx = context,
                                .load = 1,
                                .tick = tick,
                            }};
                            var done: u64 = 0;
                            var submit_iters: u32 = 0;
                            while (done == 0) {
                                if (submit_iters > limits.submit_retry) {
                                    std.debug.panic("SlowAllocationJob: resubmit timeout", .{});
                                }
                                done = self.thread_pool.submit(&jobs_buf);
                                if (done == 0) std.Thread.yield() catch {};
                                submit_iters += 1;
                            }
                            return;
                        }

                        // We are the grow thread
                        defer self.grow_thread.store(.none(), .release);

                        const current_cap = self.actual_capacity.load(.monotonic);
                        const new_cap = self.calculateGrowCapacity();

                        if (new_cap <= current_cap) {
                            std.Thread.yield() catch {};
                            continue;
                        }

                        self.grow(new_cap) catch |e| {
                            std.log.err("Forced grow failed: {}", .{e});
                        };

                        if (tryAllocateNow(context, thread)) return;

                        // Still failed, resubmit
                        var jobs_buf = [1]Job{Job{
                            .ctx = context,
                            .load = 1,
                            .tick = tick,
                        }};
                        var done: u64 = 0;
                        while (done == 0) {
                            done = self.thread_pool.submit(&jobs_buf);
                            if (done == 0) std.Thread.yield() catch {};
                        }
                        return;
                    },
                    .claimed => {
                        self.qsbr.exit(thread_idx);
                        std.Thread.yield() catch {};
                        continue;
                    },
                    .active, .importing => {
                        // Register for callback
                        const callbacks = self.callbacksPtr(state.new_capacity);
                        const job = Job{
                            .ctx = context,
                            .tick = tick,
                            .load = 1,
                        };
                        var jobs_buf = [1]Job{job};
                        if (callbacks.push(&jobs_buf)) {
                            self.qsbr.exit(thread_idx);
                            return;
                        }
                        self.qsbr.exit(thread_idx);
                        continue; // Buffer full, retry
                    },
                    .exiting => {
                        self.qsbr.exit(thread_idx);
                        continue; // Grow nearly done, retry
                    },
                }
            }
        }
    };

    pub fn init(
        capacity: u32,
        maximum_capacity: u32,
        thread_pool: *ThreadPool,
        minimum_growth: u32,
        maximum_growth_from_scalar: u32,
        pre_growth_scalar: u8,
        extra_growth_scalar: u8,
        proactive_threshold: u8,
    ) !*Self {
        const reserved_bytes = Self.sizeOf(maximum_capacity, maximum_capacity, thread_pool);
        const ptr = try VPA.reserveVirtualRegion(reserved_bytes);
        try VPA.commitVirtualPages(ptr, Self.sizeOf(capacity, maximum_capacity, thread_pool));

        const self = @as(*Self, @ptrCast(@alignCast(ptr)));
        const freelist = FreeList.initAtPtr(@ptrFromInt(@intFromPtr(self) + offsetFreelist(capacity, thread_pool)), freelistSize(capacity)) catch |e| {
            std.debug.panic("Failed to initialize freelist: {}", .{e});
        };

        // Populate freelist with all slabs
        var buffer: [256]*Slab = undefined;
        var remaining = capacity;
        var index: u32 = 0;
        while (remaining > 0) {
            const batch: u32 = @min(remaining, @as(u32, @intCast(buffer.len)));
            for (0..batch) |i| {
                buffer[i] = self.slabPtr(thread_pool, index + @as(u32, @intCast(i)));
            }
            if (freelist.pushSome(buffer[0..batch]) < batch) {
                std.debug.panic("Failed to fill freelist", .{});
            }
            remaining -= batch;
            index += batch;
        }

        self.* = Self{
            .reserved_byte_len = reserved_bytes,
            .maximum_capacity = maximum_capacity,
            .thread_pool = thread_pool,
            .grow_job = .{ .ctx = self, .load = 2 },
            .minimum_growth = minimum_growth,
            .maximum_growth_from_scalar = maximum_growth_from_scalar,
            .pre_growth_scalar = pre_growth_scalar,
            .extra_growth_scalar = extra_growth_scalar,
            .proactive_threshold = proactive_threshold,
            .demanded_capacity = .init(0),
            .actual_capacity = .init(capacity),
            .epoch = Epoch.init(),
            .grow_state = .init(.{ .phase = .idle, .new_capacity = 0 }),
            .qsbr = QSBR.init(thread_pool.getMaxThreadCount()),
            .grow_thread = .init(.none()),
            .freelist_ptr = .init(@intFromPtr(freelist)),
        };

        return self;
    }

    pub fn prepareAllocation(self: *Self, count: u32) AllocationTicket {
        const new_demand = self.demanded_capacity.fetchAdd(count, .monotonic) + count;
        const actual = self.actual_capacity.load(.monotonic);

        // Proactive grow check
        const threshold_actual = (actual >> 8) * @as(u32, self.proactive_threshold);
        if (new_demand > threshold_actual) {
            self.suggestGrow();
        }

        return .{
            .context = .{
                .self = self,
                .thread = undefined,
                .slabs = undefined,
                .callback = undefined,
            },
            .state = .init(.pending),
        };
    }

    const AllocationState = enum { consuming, deferred, immediate };
    pub fn allocate(
        self: *Self,
        thread: *Thread,
        ticket: *AllocationTicket,
        out_slabs: []*Slab,
        callback: ?Job,
    ) AllocationState {
        const limits = SPIN_LIMITS{};
        const thread_idx = thread.getIndex();

        if (ticket.state.cmpxchgStrong(.pending, .consumed, .acq_rel, .acquire)) |_| return .consuming;

        var context = &ticket.context;
        context.thread = thread;
        context.slabs = out_slabs;
        context.callback = callback;

        // Coherent state read - enter QSBR first, then verify epoch
        var freelist: *FreeList = undefined;
        var iterations: u32 = 0;
        while (true) {
            if (iterations > limits.version_sync) {
                std.debug.panic("allocate: spin timeout after {} iterations", .{iterations});
            }
            iterations += 1;

            // Enter QSBR with current epoch
            const epoch = self.epoch.current();
            self.qsbr.enter(thread_idx, epoch);

            // Read state AFTER entering QSBR
            const state = self.grow_state.load(.acquire);
            const fl_ptr = self.freelist_ptr.load(.acquire);

            // Verify epoch hasn't changed
            if (self.epoch.current() == epoch) {
                switch (state.phase) {
                    .idle, .claimed => {
                        freelist = @ptrFromInt(fl_ptr);
                        break;
                    },
                    .active, .importing, .exiting => {
                        self.qsbr.exit(thread_idx);
                        // Fall through to slow path
                        self.suggestGrow();
                        return self.enqueueSlowAllocation(context);
                    },
                }
            }

            // Epoch changed - exit and retry
            self.qsbr.exit(thread_idx);
            std.atomic.spinLoopHint();
        }
        defer self.qsbr.exit(thread_idx);

        if (freelist.pop(out_slabs)) {
            ticket.state.store(.complete, .release);
            return .immediate;
        }

        // Empty freelist, go to slow path
        self.suggestGrow();
        return self.enqueueSlowAllocation(context);
    }

    fn enqueueSlowAllocation(self: *Self, context: *AllocationContext) AllocationState {
        const limits = SPIN_LIMITS{};
        const slow_job = Job{
            .ctx = context,
            .load = 1,
            .tick = SlowAllocationJob.tick,
        };
        var jobs_buf = [1]Job{slow_job};
        var done: u64 = 0;
        var i: u64 = 0;
        while (done == 0) {
            if (i > limits.pool_submit) {
                std.debug.panic("allocate: submission timeout after {} iterations", .{i});
            }
            done = self.thread_pool.submit(&jobs_buf);
            if (done == 0) std.Thread.yield() catch {};
            i += 1;
        }
        return .deferred;
    }

    pub fn deallocate(self: *Self, thread: *Thread, slabs: []*Slab, comptime erase: bool) void {
        const limits = SPIN_LIMITS{};
        const thread_idx = thread.getIndex();

        // 1. Initial cleanup (if requested)
        if (comptime erase) {
            for (slabs) |slab| @memset(slab, 0);
        }

        // 2. Debug range validation
        if (@import("builtin").mode == .Debug) {
            const base = @intFromPtr(self) + offsetSlabs(self.thread_pool);
            const limit = base + @as(usize, self.maximum_capacity) * SLAB_SIZE;
            for (slabs) |slab| {
                const ptr = @intFromPtr(slab);
                if (ptr < base or ptr >= limit) {
                    std.debug.panic("CORRUPTION: slab pointer 0x{x} outside heap range", .{ptr});
                }
            }
        }

        var total_pushed: u32 = 0;
        var outer_iterations: u64 = 0;

        // 3. ENTER QSBR ONCE
        // This protects the thread until all slabs are successfully returned.
        var current_epoch = self.epoch.current();
        self.qsbr.enter(thread_idx, current_epoch);
        
        // Use defer to ensure we always mark the thread as idle when the function returns
        defer self.qsbr.exit(thread_idx);

        while (total_pushed < slabs.len) {
            if (outer_iterations > limits.dealloc_outer) {
                std.debug.panic("deallocate: outer timeout, pushed={}/{}", .{ total_pushed, slabs.len });
            }
            outer_iterations += 1;

            // 4. Coherent state read
            // Check if the global epoch changed while we were pushing
            const new_epoch = self.epoch.current();
            if (new_epoch != current_epoch) {
                current_epoch = new_epoch;
                self.qsbr.enter(thread_idx, current_epoch);
            }

            // Acquire the latest freelist pointer
            const fl_ptr = self.freelist_ptr.load(.acquire);
            const freelist: *FreeList = @ptrFromInt(fl_ptr);

            // 5. Attempt the push
            const pushed: u32 = @truncate(freelist.pushSome(slabs[total_pushed..slabs.len]));

            if (pushed > 0) {
                _ = self.demanded_capacity.fetchSub(pushed, .monotonic);
                total_pushed += pushed;
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }
};