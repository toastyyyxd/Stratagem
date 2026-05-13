const std = @import("std");
const Io = std.Io;
const Timestamp = Io.Timestamp;
const VPA = @import("../mem/VirtualPageAllocator.zig").VirtualPageAllocator;
const InplaceBufferAllocator = @import("../mem/InplaceBufferAllocator.zig").InplaceBufferAllocator;
const RingBuffer = @import("../mem/RingBuffer.zig").RingBuffer;
const View = @import("../mem/RingBuffer.zig").View;

const Queue = RingBuffer(Job, .aos, .mpmc, .fifo, null);

pub const MAX_THREADS: comptime_int = 128;

// Work loop constants
const MAX_JOBS_BATCH = 16;
const MAX_STEAL_BATCH = 12;
const SPIN_ITERATIONS_BEFORE_YIELD = 64;
const MAX_YIELD_ITERATIONS = 512;

/// A unit of work that can be submitted to the thread pool.
/// Also functions as a VTable for any other FSM.
pub const Unit = packed struct(u128) {
    /// The context to be passed to the tick function.
    /// Usually a pointer to the FSM that this job acts as a VTable for.
    ctx: *anyopaque,
    /// The function to be called when the job is ready to be processed.
    /// Usually a method of the FSM in .ctx.
    tick: *const fn (*anyopaque, *Thread) void,
};

/// Job formatted for SoA
const Job = struct {
    unit: Unit align(16),
    load: u8,
};

pub const Config = struct {
    max_thread_count: u16 = 1,
    stack_size: usize,
    queue_capacity: u64,
    scale_up_load_threshold: u64,
    scale_up_queue_threshold: u64,
    steal_load_threshold: u64,
    steal_queue_threshold: u64,
    scale_up_extra_load: u64,
    stress_increment: u64,
    stress_decrement: u64,
    scale_up_stress_threshold: u64,
};

pub const Thread = struct {
    const Self = @This();

    const Active = enum(u8) {
        /// Thread is either waking up, actively processing jobs and has space in queue, or spinning for jobs.
        Running,
        /// Thread is either setting up to wait for the futex, or already waiting.
        Asleep,
    };
    pub const WaitSlot = struct {
        trigger_stamp: Timestamp,
        io: Io,
        job: Job,
        active: bool,
    };
    active: std.atomic.Value(Active) align(std.atomic.cache_line),
    should_exit: std.atomic.Value(bool) align(std.atomic.cache_line),
    idle_futex_word: std.atomic.Value(u32) align(std.atomic.cache_line),
    load: std.atomic.Value(u64) align(std.atomic.cache_line),
    /// Special singular job slot for any timing system to hook onto, i.e. a timing wheel.
    wait_slot: WaitSlot,
    /// Work context
    wait_count: u32 = 0,
    iterations: u64 = 0,
    stress: u64 = 0,

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
        return offsetQueue() + Queue.sizeOf(config.queue_capacity);
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

    /// Main work loop for the thread.
    pub fn work(self: *Self) !void {
        self.active.store(.Running, .release);

        while (!self.shouldExit()) {
            self.iterations +|= 1;

            if (self.tryProcessWaitSlot()) continue;
            if (self.tryProcessLocalJobs()) continue;
            if (self.tryStealJobs()) continue;

            self.tryWaitForWork();
        }
    }

    /// Check if the thread should exit.
    inline fn shouldExit(self: *Self) bool {
        return self.should_exit.load(.acquire);
    }

    inline fn tryProcessWaitSlot(self: *Self) bool {
        if (!self.wait_slot.active) return false;
        return self.checkWaitSlotTimeout();
    }

    /// Process jobs from the local queue.
    /// Returns true if any jobs were processed.
    fn tryProcessLocalJobs(self: *Self) bool {
        var jobs: [MAX_JOBS_BATCH]Job = undefined;
        const len = self.getQueue().popSome(.aos, &jobs);

        if (len == 0) return false;

        var load_reduced: u64 = 0;
        for (jobs[0..len]) |job| {
            job.tick(job.ctx, self);
            self.wait_count = 0;
            load_reduced += @as(u64, job.load);
        }

        _ = self.load.fetchSub(load_reduced, .acq_rel);
        self.updateStressAndScale();

        return true;
    }

    /// Update stress level and scale up threads if needed.
    fn updateStressAndScale(self: *Self) void {
        const current_load = self.load.load(.monotonic);
        const queue_count = self.getQueue().estimateCount();
        const config = &self.parent.config;

        const should_scale_up = (current_load >= config.scale_up_load_threshold) or
            (queue_count >= config.scale_up_queue_threshold);

        if (should_scale_up) {
            self.stress +|= config.stress_increment;
            const extra_threads: u16 = if (self.stress > config.scale_up_stress_threshold) 1 else 0;
            self.parent.ensureThreads(self.parent.thread_count.load(.acquire) + extra_threads);
        } else {
            self.stress -|= config.stress_decrement;
        }
    }

    /// Try to steal jobs from other threads.
    /// Returns true if any jobs were stolen and processed.
    fn tryStealJobs(self: *Self) bool {
        const pool = self.parent;
        const thread_count = pool.thread_count.load(.acquire);

        if (thread_count <= 1) return false;

        const probe_budget: u16 = thread_count / 2;
        const start_index = computeStealStartIndex(self, self.iterations, thread_count);

        return stealFromVictims(self, pool, start_index, probe_budget);
    }

    /// Compute the starting index for victim selection using hash-based randomization.
    fn computeStealStartIndex(self: *Self, iterations: u64, thread_count: u16) u16 {
        const hash = @intFromPtr(self) + @as(usize, @truncate(iterations));
        return @intCast((hash >> 6) % @as(usize, thread_count));
    }

    /// Attempt to steal jobs from victim threads.
    fn stealFromVictims(self: *Self, pool: *ThreadPool, start_index: u16, probe_budget: u16) bool {
        var stolen: [MAX_STEAL_BATCH]Job = undefined;
        var victim_index: u16 = start_index;

        for (0..probe_budget) |_| {
            victim_index = (victim_index + 1) % pool.thread_count.load(.acquire);
            const victim = pool.getThread(victim_index);

            if (victim == self) continue;
            if (!isVictimStealable(victim, &pool.config)) continue;

            if (stealAndProcessJobs(self, victim, &stolen)) return true;
        }

        return false;
    }

    /// Check if a victim thread has enough work to steal.
    fn isVictimStealable(victim: *Thread, config: *const Config) bool {
        const victim_load = victim.load.load(.acquire);
        const victim_queue_count = victim.getQueue().estimateCount();

        return (victim_load >= config.steal_load_threshold) and
            (victim_queue_count >= config.steal_queue_threshold);
    }

    /// Steal jobs from a victim and process them.
    /// Returns true if jobs were stolen and processed.
    fn stealAndProcessJobs(thief: *Thread, victim: *Thread, stolen_buffer: []Job) bool {
        const stolen_len = victim.getQueue().popSome(.aos, stolen_buffer);
        if (stolen_len == 0) return false;

        var stolen_load: u64 = 0;
        for (stolen_buffer[0..stolen_len]) |job| {
            stolen_load += @as(u64, job.load);
        }
        _ = victim.load.fetchSub(stolen_load, .acq_rel);

        for (stolen_buffer[0..stolen_len]) |job| {
            job.tick(job.ctx, thief);
        }
        return true;
    }

    /// Wait for work with progressive backoff (spin -> yield -> sleep).
    fn tryWaitForWork(self: *Self) void {
        if (self.wait_count < SPIN_ITERATIONS_BEFORE_YIELD) {
            self.wait_count +|= 1;
            std.atomic.spinLoopHint();
        } else if (self.wait_count < MAX_YIELD_ITERATIONS) {
            self.wait_count +|= 1;
            std.Thread.yield() catch {};
        } else {
            self.sleepOnFutex();
        }
    }

    /// Put the thread to sleep on the futex waiting for work.
    fn sleepOnFutex(self: *Self) void {
        self.active.store(.Asleep, .release);
        if (self.shouldExit()) return;

        // Check queue ONE MORE TIME before sleeping
        // This prevents the race where a job was just submitted
        if (self.getQueue().estimateCount() > 0) {
            self.active.store(.Running, .release);
            return;
        }

        // Publish "waiting" and consume any pending signal in one op.
        const prev = self.idle_futex_word.swap(0, .acq_rel);
        if (prev != 0) {
            if (!self.shouldExit())
                self.active.store(.Running, .release);
            return;
        }

        // Handle spurious wakeups
        while (self.idle_futex_word.load(.acquire) == 0) {
            // CRITICAL: Check queue periodically while waiting
            if (self.getQueue().estimateCount() > 0) {
                self.idle_futex_word.store(1, .release);
                break;
            }
            if (self.wait_slot.active) {
                if (self.checkWaitSlotTimeout()) break;
            } else {
                self.parent.io.futexWaitUncancelable(u32, &self.idle_futex_word.raw, 0);
            }
        }

        if (self.shouldExit()) return;
        self.active.store(.Running, .release);
    }

    inline fn checkWaitSlotTimeout(self: *Self) bool {
        const past_duration = self.wait_slot.trigger_stamp.untilNow(self.wait_slot.io, .awake);
        if (past_duration.nanoseconds < 0) return false else {
            const job = self.wait_slot.job;
            self.wait_slot.active = false;
            job.tick(job.ctx, self);
            return true; // We processed a job, wake up the work loop
        }
    }

    pub fn wake(self: *Self) void {
        const prev = self.idle_futex_word.swap(1, .acq_rel);
        if (prev == 0) {
            self.parent.io.futexWake(@TypeOf(self.idle_futex_word.raw), &self.idle_futex_word.raw, 1);
        }
    }

    /// Get this thread's index in the thread pool
    pub inline fn getIndex(self: *Self) u16 {
        const pool = self.parent;
        const base = @intFromPtr(pool.getThread(0));
        const self_addr = @intFromPtr(self);
        const thread_size = Thread.sizeOf(&pool.config);
        return @as(u16, @intCast((self_addr - base) / thread_size));
    }

    /// Submit jobs to this thread while in the same thread.
    ///
    /// All jobs in the slice must have the same `load` value.
    /// Supplying inconsistent `load` values results in undefined behavior, as this function assumes uniformity.
    pub fn submitLocal(self: *Self, jobs: []const Job) u64 {
        const per_job_load: u64 = @as(u64, @intCast(jobs[0].load));
        _ = self.load.fetchAdd(per_job_load * jobs.len, .monotonic);
        const enqueued = self.getQueue().pushSome(jobs);
        if (enqueued < jobs.len) _ = self.load.fetchSub(per_job_load * (jobs.len - enqueued), .monotonic);
        if (enqueued > 0) {
            self.wake();
        }
        return enqueued;
    }

    /// Submit jobs to this thread from another thread.
    ///
    /// All jobs in the slice must have the same `load` value.
    /// Supplying inconsistent `load` values results in undefined behavior, as this function assumes uniformity.
    pub fn submitRemote(self: *Self, jobs: []const Job) u64 {
        const per_job_load: u64 = @as(u64, @intCast(jobs[0].load));
        _ = self.load.fetchAdd(per_job_load * jobs.len, .acq_rel);
        const enqueued = self.getQueue().pushSome(.aos, jobs);
        if (enqueued < jobs.len) _ = self.load.fetchSub(per_job_load * (jobs.len - enqueued), .acq_rel);
        if (enqueued > 0) {
            self.wake();
        }
        return enqueued;
    }
};

pub const ThreadPool = struct {
    const Self = @This();

    io: Io,

    config: Config,
    thread_count: std.atomic.Value(u16) align(std.atomic.cache_line),
    thread_count_claimed: std.atomic.Value(u16) align(std.atomic.cache_line),

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

    /// Public accessor for thread count
    pub inline fn getMaxThreadCount(self: *const Self) u16 {
        return self.config.max_thread_count;
    }

    pub fn init(io: Io, config: Config, init_thread_count: u16) !*Self {
        std.debug.assert(config.max_thread_count <= MAX_THREADS); // arbitrary limit to avoid allocations
        std.debug.assert(config.stack_size % std.heap.pageSize() == 0); // ensure stack size is a multiple of page size
        std.debug.assert(init_thread_count <= config.max_thread_count); // ensure we do not exceed max thread count

        const ptr = try VPA.reserveVirtualRegion(Self.sizeOf(&config));
        try VPA.commitVirtualPages(ptr, Self.leanSizeOf(&config) + config.stack_size * init_thread_count);
        const self = @as(*Self, @ptrCast(@alignCast(ptr)));

        // Initialize Self
        self.io = io;
        self.config = config;
        self.thread_count = .init(0);
        self.getFba().* = InplaceBufferAllocator.init(@ptrFromInt(@intFromPtr(self) + offsetStackRegion(&config)), config.stack_size * config.max_thread_count);
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
            if (self.getThread(@truncate(i)).active.load(.acquire) == .Running) n += 1;
        }
        return n;
    }

    fn initThread(self: *Self, i: u16) !void {
        const thread = self.getThread(@intCast(i));
        try VPA.commitVirtualPages(@as(*u8, @ptrFromInt(@intFromPtr(self) + ThreadPool.offsetStackRegion(&self.config) + self.config.stack_size * i)), self.config.stack_size);
        const queue = thread.getQueue();
        _ = try Queue.initAtPtr(@ptrCast(queue), self.config.queue_capacity);
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
        const capped_target = @min(target, self.config.max_thread_count);

        self.spawnThreadsIfNeeded(capped_target);
        self.wakeSleepingThreads(capped_target);
    }

    /// Spawn new threads if the claimed count is below target.
    fn spawnThreadsIfNeeded(self: *Self, target: u16) void {
        var claimed = self.thread_count_claimed.load(.acquire);
        var published = self.thread_count.load(.acquire);

        if (claimed >= target) return;

        // Claim thread counter
        while (true) {
            const new_claimed = self.thread_count_claimed.cmpxchgWeak(claimed, target, .acq_rel, .acquire);
            if (new_claimed == null) break;
            claimed = new_claimed.?;
        }

        // Spawn new threads
        for (claimed..target) |i| {
            self.initThread(@as(u16, @truncate(i))) catch {
                std.debug.panic("Failed to spawn new thread!", .{});
            };
        }

        // Publish the new thread count
        while (true) {
            const new_published = self.thread_count.cmpxchgWeak(published, target, .acq_rel, .acquire);
            if (new_published == null) break;
            std.atomic.spinLoopHint(); // wait to publish in order as indexes matter
            published = new_published.?;
        }
    }

    /// Wake up sleeping threads to reach the target running count.
    fn wakeSleepingThreads(self: *Self, target: u16) void {
        const published = self.thread_count.load(.acquire);

        var running: u16 = 0;
        var asleep_threads: [MAX_THREADS]*Thread = undefined;
        var asleep_count: u16 = 0;

        for (0..published) |i| {
            const t = self.getThread(@intCast(i));
            switch (t.active.load(.acquire)) {
                .Running => running += 1,
                .Asleep => {
                    asleep_threads[asleep_count] = t;
                    asleep_count += 1;
                },
            }
        }

        if (running < target) {
            const need_wake = target - running;
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
        var thread_loads: [MAX_THREADS]u64 = [_]u64{0} ** MAX_THREADS;
        var total_current_load: u64 = 0;

        for (0..thread_count) |i| {
            thread_loads[i] = self.getThread(@as(u16, @truncate(i))).load.load(.acquire);
            total_current_load += thread_loads[i];
        }

        std.debug.assert(allJobsHaveSameLoad(jobs));

        const per_job_load = @as(u64, jobs[0].load);
        std.debug.assert(per_job_load > 0);

        const total_incoming_load: u64 = @as(u64, jobs.len) * per_job_load;
        const total_summed_load: u64 = total_current_load + total_incoming_load;

        var available_threads = collectAvailableThreads(thread_loads[0..thread_count], total_summed_load);

        self.scaleUpIfNeeded(total_summed_load, per_job_load);

        return distributeJobs(self, jobs, &available_threads, thread_loads[0..thread_count], total_summed_load, per_job_load);
    }

    /// Verify all jobs in the slice have the same load value.
    fn allJobsHaveSameLoad(jobs: []Job) bool {
        if (jobs.len == 0) return true;
        const expected_load = jobs[0].load;
        for (jobs) |job| {
            if (job.load != expected_load) return false;
        }
        return true;
    }

    /// Collect threads that are available for receiving jobs.
    fn collectAvailableThreads(thread_loads: []u64, total_summed_load: u64) AvailableThreads {
        const thread_count: u16 = @intCast(thread_loads.len);
        var available: AvailableThreads = .{
            .count = thread_count,
            .indices = undefined,
        };

        var per_thread_target = total_summed_load / thread_count;
        var available_count: usize = 0;

        for (thread_loads, 0..) |load, i| {
            if (load >= per_thread_target) {
                available.count -= 1;
                per_thread_target = total_summed_load / available.count; // adjust immediately
            } else {
                available.indices[available_count] = @intCast(i);
                available_count += 1;
            }
        }

        return available;
    }

    /// Scale up threads if the load justifies it.
    fn scaleUpIfNeeded(self: *Self, total_summed_load: u64, per_job_load: u64) void {
        const per_thread_target = total_summed_load / self.thread_count.load(.acquire);

        const should_scale = (per_thread_target >= self.config.scale_up_load_threshold) or
            (per_thread_target / per_job_load >= self.config.scale_up_queue_threshold);

        if (should_scale) {
            const target_load = self.config.scale_up_load_threshold + self.config.scale_up_extra_load;
            const target_threads = total_summed_load / target_load;
            self.ensureThreads(@as(u16, @truncate(target_threads)));
        }
    }

    /// Distribute jobs to available threads.
    fn distributeJobs(
        self: *Self,
        jobs: []Job,
        available: *AvailableThreads,
        thread_loads: []u64,
        total_summed_load: u64,
        per_job_load: u64,
    ) u64 {
        const per_thread_target = total_summed_load / available.count;
        var load_remainder: u64 = total_summed_load % available.count;
        var jobs_submitted: u64 = 0;

        for (0..available.count) |i| {
            const thread_i = available.indices[i];
            const thread = self.getThread(thread_i);
            // Use snapshot value to ensure consistency with per_thread_target
            const thread_load = thread_loads[thread_i];

            // Both per_thread_target and thread_load are from the same snapshot,
            // so this subtraction is safe and race-free.
            const load_diff = if (thread_load >= per_thread_target) 0 else per_thread_target - thread_load;
            const jobs_diff = (load_diff + load_remainder) / per_job_load;
            load_remainder = (load_diff + load_remainder) % per_job_load;

            const jobs_to_submit = @min(jobs_diff, jobs.len - jobs_submitted);
            if (jobs_to_submit == 0) continue;

            const start = jobs_submitted;
            const end = jobs_submitted + jobs_to_submit;
            jobs_submitted += thread.submitRemote(jobs[start..end]);

            if (jobs_submitted == jobs.len) break;
        }

        return jobs_submitted;
    }
};

/// Tracks available threads for job distribution.
const AvailableThreads = struct {
    count: u16,
    indices: [MAX_THREADS]u16,
};
