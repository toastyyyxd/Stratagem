const std = @import("std");
const VPA = @import("../mem/virtual_page_allocator.zig").VirtualPageAllocator;
const InplaceBufferAllocator = @import("../mem/vpa_fba.zig").InplaceBufferAllocator;
const RingBuffer = @import("../mem/ring_buffer.zig").RingBuffer;

const Queue = RingBuffer(Job);

/// A unit of work that can be submitted to the thread pool.
/// Also functions as a VTable for any other FSM.
pub const Job = struct {
    /// The context to be passed to the tick function.
    /// Usually a pointer to the FSM that this job acts as a VTable for.
    ctx: *anyopaque,
    /// The function to be called when the job is ready to be processed.
    /// Usually a method of the FSM in .ctx.
    tick: *fn (*anyopaque, *Thread) void,
    /// The load of the job, used for job distribution.
    /// Takes priority over the ring buffer capacity.
    load: u8,
};

pub const Config = struct {
    max_thread_count: u16,
    stack_size: usize,
    worker_queue_capacity: u64,
    worker_load_threshold: u64,
    avg_load_threshold: u64,
};

pub const Thread = struct {
    const ThreadError = error{ThreadAsleep};

    const Self = @This();

    const Active = enum(u8) {
        /// Thread is either waking up, actively processing jobs and has space in queue, or spinning for jobs.
        Running,
        /// Thread is either setting up to wait for the futex, or already waiting.
        Asleep,
    };
    active: std.atomic.Value(Active) align(std.atomic.cache_line),
    should_exit: std.atomic.Value(bool) align(std.atomic.cache_line),
    idle_futex_word: std.atomic.Value(u32) align(std.atomic.cache_line),
    load: std.atomic.Value(u64) align(std.atomic.cache_line),

    parent: *ThreadPool,

    inline fn offsetInternal() usize {
        var offset: usize = @sizeOf(Self);
        offset = std.mem.alignForward(usize, offset, @alignOf(std.Thread));
        return offset;
    }
    inline fn offsetQueue() usize {
        var offset = offsetInternal() + @sizeOf(std.Thread);
        offset = std.mem.alignForward(usize, offset, Queue.alignOf());
        return offset;
    }
    inline fn sizeOf(config: *const Config) usize {
        return offsetQueue() + Queue.sizeOf(config.worker_queue_capacity);
    }
    inline fn alignOf() usize {
        return comptime @max(@alignOf(Self), @alignOf(std.Thread), Queue.alignOf());
    }
    inline fn getInternal(self: *Self) *std.Thread {
        return @ptrFromInt(@intFromPtr(self) + offsetInternal());
    }
    inline fn getQueue(self: *Self) *Queue {
        return @ptrFromInt(@intFromPtr(self) + offsetQueue());
    }

    pub fn work(self: *Self) !void {
        self.active.store(.Running, .release);
        var jobs: [16]Job = undefined;
        var stolen: [12]Job = undefined;
        var wait_count: u32 = 0;
        var iterations: u64 = 0; // used for probe rotation
        while (self.should_exit.load(.acquire) == false) {
            iterations +|= 1;
            const len = self.getQueue().pop_some(&jobs);
            if (len > 0) {
                var load_reduced: u64 = 0;
                for (jobs[0..len]) |job| {
                    job.tick(job.ctx, self);
                    wait_count = 0;
                    load_reduced += @as(u64, job.load);
                }
                _ = self.load.fetchSub(load_reduced, .acq_rel);
                if (self.load.load(.monotonic) >= self.parent.config.avg_load_threshold) {
                    self.parent.ensureThreads(self.parent.thread_count.load(.acquire));
                }
                continue;
            }

            const pool = self.parent;
            const n = pool.thread_count.load(.acquire);
            if (n > 1) {
                const probe_budget: u16 = n / 2;
                var probed: u16 = 0;

                var idx: u16 = @intCast((@intFromPtr(self) + @as(usize, @truncate(iterations)) >> 6) % @as(usize, n));

                var stole_any = false;
                while (probed < probe_budget) : (probed += 1) {
                    idx = (idx + 1) % n;
                    const victim = pool.getThread(idx);
                    if (victim == self) continue;

                    const victim_load: u64 = victim.load.load(.acquire);
                    const victim_used_capacity: u64 = victim.getQueue().estimate_count();
                    if (victim_load < pool.config.worker_load_threshold / 2) continue;
                    if (victim_used_capacity < pool.config.worker_queue_capacity / 2) continue;

                    var stolen_load: u64 = 0;
                    const stolen_len = victim.getQueue().pop_some(&stolen);
                    if (stolen_len == 0) continue;
                    for (stolen[0..stolen_len]) |job| stolen_load += @as(u64, job.load);
                    _ = self.load.fetchAdd(stolen_load, .acq_rel);
                    _ = victim.load.fetchSub(stolen_load, .acq_rel);
                    for (stolen[0..stolen_len]) |job| {
                        job.tick(job.ctx, self);
                    }
                    _ = self.load.fetchSub(stolen_load, .acq_rel);
                    stole_any = true;
                    break;
                }
                if (stole_any) continue;
            }

            if (wait_count < 64) {
                wait_count +|= 1;
                std.atomic.spinLoopHint();
            } else if (wait_count < 256) {
                wait_count +|= 1;
                std.Thread.yield() catch {};
            } else {
                self.active.store(.Asleep, .release);
                if (self.should_exit.load(.acquire)) break; // Check exit condition again before sleeping
                // Publish "waiting" and consume any pending signal in one op.
                const prev = self.idle_futex_word.swap(0, .acq_rel);
                if (prev == 0) // handle spurious wakeups
                    while (self.idle_futex_word.load(.acquire) == 0)
                        std.Thread.Futex.wait(&self.idle_futex_word, 0);
                if (self.should_exit.load(.acquire)) break;
                wait_count = 0;
                self.active.store(.Running, .release);
            }
        }
    }

    pub fn wake(self: *Self) void {
        self.idle_futex_word.store(1, .release);
        std.Thread.Futex.wake(&self.idle_futex_word, 1);
    }

    /// Submit jobs to this thread while in the same thread.
    ///
    /// All jobs in the slice must have the same `load` value.
    /// Supplying inconsistent `load` values results in undefined behavior, as this function assumes uniformity.
    fn submit_local(self: *Self, jobs: []Job) u64 {
        const enqueued = self.getQueue().push_some(jobs);
        _ = self.load.fetchAdd(enqueued * @as(u64, @intCast(jobs[0].load)), .monotonic);
        return enqueued;
    }

    /// Submit jobs to this thread from another thread.
    ///
    /// All jobs in the slice must have the same `load` value.
    /// Supplying inconsistent `load` values results in undefined behavior, as this function assumes uniformity.
    fn submit_remote(self: *Self, jobs: []Job) u64 {
        const enqueued = self.getQueue().push_some(jobs);
        _ = self.load.fetchAdd(enqueued * @as(u64, @intCast(jobs[0].load)), .acq_rel);
        return enqueued;
    }
};

pub const ThreadPool = struct {
    const Self = @This();

    config: Config,
    thread_count: std.atomic.Value(u16) align(std.atomic.cache_line),

    inline fn offsetBumpAllocator() usize {
        var offset: usize = @sizeOf(Self);
        offset = std.mem.alignForward(usize, offset, @alignOf(InplaceBufferAllocator));
        return offset;
    }
    inline fn offsetAllocInterface() usize {
        var offset = offsetBumpAllocator() + @sizeOf(InplaceBufferAllocator);
        offset = std.mem.alignForward(usize, offset, @alignOf(std.mem.Allocator));
        return offset;
    }
    inline fn offsetThread(config: *const Config, thread_index: u16) usize {
        // Each stack size is already asserted to be a multiple of (and aligned to) page size.
        var offset = offsetAllocInterface() + @sizeOf(std.mem.Allocator);
        offset = std.mem.alignForward(usize, offset, Thread.alignOf());
        // Due to lower expected counts of threads, we should align to the Thread's alignment
        // for performance over memory efficiency.
        offset += std.mem.alignForward(usize, Thread.sizeOf(config), Thread.alignOf()) * thread_index;
        return offset;
    }
    // Stack region is last for the VPA to be able to reserve but not fully commit the memory.
    inline fn offsetStackRegion(config: *const Config) usize {
        var offset = offsetThread(config, config.max_thread_count - 1) + Thread.sizeOf(config);
        offset = std.mem.alignForward(usize, offset, std.heap.pageSize());
        return offset;
    }

    pub inline fn sizeOf(config: *const Config) usize {
        return offsetStackRegion(config) + config.stack_size * config.max_thread_count;
    }
    /// .sizeOf() without the stack region.
    pub inline fn leanSizeOf(config: *const Config) usize {
        return offsetStackRegion(config);
    }
    pub inline fn alignOf() usize {
        return comptime @max(@alignOf(Self), @alignOf(InplaceBufferAllocator), @alignOf(std.mem.Allocator), Queue.alignOf(), Thread.alignOf());
    }

    pub inline fn getFba(self: *Self) *InplaceBufferAllocator {
        return @ptrFromInt(@intFromPtr(self) + offsetBumpAllocator());
    }
    pub inline fn getFbaInterface(self: *Self) *std.mem.Allocator {
        return @ptrFromInt(@intFromPtr(self) + offsetAllocInterface());
    }
    pub inline fn getStackRegion(self: *Self) []u8 {
        return @as(*u8, @ptrFromInt(@intFromPtr(self) + offsetStackRegion(&self.config)))[0 .. self.config.stack_size * self.config.max_thread_count];
    }
    pub inline fn getThread(self: *Self, thread_index: u16) *Thread {
        return @ptrFromInt(@intFromPtr(self) + offsetThread(&self.config, thread_index));
    }

    pub fn init(config: Config, init_thread_count: u16) !*Self {
        std.debug.assert(config.max_thread_count <= 64); // arbitrary limit to avoid allocations
        std.debug.assert(config.stack_size % std.heap.pageSize() == 0); // ensure stack size is a multiple of page size
        std.debug.assert(init_thread_count <= config.max_thread_count); // ensure we do not exceed max thread count

        const ptr = try VPA.reserveVirtualRegion(Self.sizeOf(&config));
        try VPA.commitVirtualPages(ptr, Self.leanSizeOf(&config) + config.stack_size * init_thread_count);
        const self = @as(*Self, @ptrCast(@alignCast(ptr)));

        // Initialize Self
        self.config = config;
        self.thread_count = .init(0);
        self.getFba().* = InplaceBufferAllocator.init(@ptrFromInt(@intFromPtr(self) + offsetStackRegion(&config)), config.stack_size * init_thread_count);
        self.getFbaInterface().* = self.getFba().threadSafeAllocator();

        self.ensureThreads(init_thread_count);

        return self;
    }
    pub fn deinit(self: *Self) !void {
        // Join all threads
        const n = self.thread_count.load(.acquire);
        for (0..n) |i| self.getThread(@intCast(i)).should_exit.store(true, .release); // Signal exit
        for (0..n) |i| self.getThread(@intCast(i)).wake(); // Wake any sleeping threads
        for (0..n) |i| self.getThread(@intCast(i)).getInternal().join(); // Join threads

        // Release the virtual region
        try VPA.releaseVirtualRegion(@ptrCast(self), Self.sizeOf(&self.config));
    }

    pub fn getRunningCount(self: *Self) u16 {
        var n: u16 = 0;
        for (0..self.thread_count.load(.acquire)) |i| {
            if (self.getThread(i).active.load(.acquire) == .Running) n += 1;
        }
        return n;
    }

    fn initThread(self: *Self, i: u16) !void {
        const thread = self.getThread(@intCast(i));
        const queue = thread.getQueue();
        _ = try Queue.initAtPtr(@ptrCast(queue), self.config.worker_queue_capacity);
        thread.parent = self;
        thread.should_exit = .init(false);
        thread.idle_futex_word = .init(1);
        thread.active = .init(.Asleep);
        thread.load = .init(0);
        thread.getInternal().* = try std.Thread.spawn(.{
            .allocator = self.getFbaInterface().*,
            .stack_size = self.config.stack_size,
        }, Thread.work, .{thread});
    }

    /// Starts or wakes up threads if the target isn't reached.
    /// Does nothing if target is already reached or is higher than max.
    pub fn ensureThreads(self: *Self, target: u16) void {
        var initialized = self.thread_count.load(.acquire);
        const capped_target = @min(target, self.config.max_thread_count);

        if (initialized < capped_target) {
            // Need to spawn new threads
            for (initialized..capped_target) |i| {
                _ = self.thread_count.fetchAdd(1, .seq_cst);
                self.initThread(@as(u16, @truncate(i))) catch {
                    std.debug.panic("Failed to spawn new thread!", .{});
                };
            }
            initialized = capped_target;
        }
        // Enough threads exist, maybe some are asleep
        var running: u16 = 0;
        var asleep_threads: [64]*Thread = undefined;
        var asleep_count: u16 = 0;
        for (0..initialized) |i| {
            const t = self.getThread(@intCast(i));
            switch (t.active.load(.acquire)) {
                .Running => running += 1,
                .Asleep => {
                    asleep_threads[asleep_count] = t;
                    asleep_count += 1;
                },
            }
        }
        if (running < capped_target) {
            const need_wake = capped_target - running;
            const to_wake = @min(need_wake, asleep_count);
            for (0..to_wake) |i| asleep_threads[i].wake();
        }
    }

    pub fn averageLoad(self: *Self) u64 {
        const n = self.thread_count.load(.acquire);
        if (n == 0) return 0;
        var total: u64 = 0;
        for (0..n) |i| {
            total += self.getThread(@intCast(i)).load.load(.acquire);
        }
        return total / n;
    }

    /// Submits a slice of jobs for execution and returns the number of jobs successfully submitted.
    ///
    /// All jobs in the slice must have the same `load` value.
    /// Supplying inconsistent `load` values results in undefined behavior, as this function assumes uniformity.
    pub fn submit(self: *Self, jobs: []Job) u64 {
        const thread_count: u16 = self.thread_count.load(.acquire);
        var thread_loads: [64]u64 = [_]u64{0} ** 64; // Max 64 threads supported
        var total_current_load: u64 = 0;
        for (0..thread_count) |i| {
            thread_loads[i] = self.getThread(@as(u16, @truncate(i))).load.load(.acquire);
            total_current_load += thread_loads[i];
        }

        std.debug.assert(blk: {
            const expected_load = jobs[0].load;
            for (jobs) |job| {
                if (job.load != expected_load) break :blk false;
            }
            break :blk true;
        });

        const per_job_load = @as(u64, jobs[0].load);
        std.debug.assert(per_job_load > 0);

        const total_incoming_load: u64 = jobs.len * per_job_load;
        const total_summed_load: u64 = total_current_load + total_incoming_load;

        var per_thread_target_load: u64 = total_summed_load / thread_count;
        var available_threads: u64 = thread_count;
        var threads_available = [_]u16{0} ** 64;
        // Remove threads that already exceed or are at the target load.
        // Actively recalculating the target load ensures threads aren't excluded based on an outdated lower target.
        var _threads_available_count: usize = 0; // only needed during loop while available threads is being adjusted
        for (0..thread_count) |i| {
            const thread_load = thread_loads[i];
            if (thread_load >= per_thread_target_load) {
                available_threads -= 1;
                per_thread_target_load = total_summed_load / available_threads; // adjust immediately
            } else {
                threads_available[_threads_available_count] = @as(u16, @truncate(i));
                _threads_available_count += 1;
            }
        }

        // Wake threads if load will be high
        if (per_thread_target_load >= self.config.avg_load_threshold) {
            self.ensureThreads(@as(u16, @truncate(total_summed_load / (self.config.avg_load_threshold / 10 * 7))));
        }

        per_thread_target_load = total_summed_load / available_threads;
        var load_remainder: u64 = total_summed_load % available_threads;
        var jobs_submitted: u64 = 0;
        for (0..available_threads) |i| {
            const thread_i = threads_available[i];
            const thread = self.getThread(@intCast(thread_i));
            const thread_load = thread_loads[thread_i];
            const load_diff: u64 = per_thread_target_load - thread_load;
            const jobs_diff: u64 = (load_diff + load_remainder) / per_job_load;
            load_remainder = (load_diff + load_remainder) % per_job_load;
            const jobs_to_submit = @min(jobs_diff, jobs.len - jobs_submitted);
            if (jobs_to_submit == 0) continue; // Or break if you know no more jobs can be submitted
            jobs_submitted += thread.submit_remote(jobs[jobs_submitted .. jobs_submitted + jobs_to_submit]);
            if (jobs_submitted == jobs.len) break; // All jobs have been submitted
            std.debug.assert(jobs_submitted <= jobs.len);
        }
        return jobs_submitted;
    }
};
