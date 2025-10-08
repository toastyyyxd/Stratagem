const std = @import("std");
const VPA = @import("../mem/virtual_page_allocator.zig").VirtualPageAllocator;
const InplaceBufferAllocator = @import("../mem/vpa_fba.zig").InplaceBufferAllocator;
const RingBuffer = @import("../mem/ring_buffer.zig").RingBuffer;

const Queue = RingBuffer(Job);

/// A unit of work that can be submitted to the thread pool.
/// Also functions as a VTable for any other FSM.
const Job = struct {
    /// The context to be passed to the tick function.
    /// Usually a pointer to the FSM that this job acts as a VTable for.
    ctx: *anyopaque,
    /// The function to be called when the job is ready to be processed.
    /// Usually a method of the FSM in .ctx.
    tick: fn (*anyopaque, *Thread) void,
    /// The intensity of the job, used for job distribution.
    /// Takes priority over the ring buffer capacity.
    intensity: u8,
}; // J*b, a derogatory slur for the unempl*yed, use with caution.

const Config = struct {
    max_thread_count: u16,
    stack_size: usize,
    main_queue_capacity: u32,
    worker_queue_capacity: u32,
    worker_saturation_threshold: u32,
};

const Thread = struct {
    const Self = @This();

    const Active = enum {
        /// Thread is either waking up, actively processing jobs and has space in queue, or spinning for jobs.
        Running,
        /// Thread is either setting up to wait for the futex, or already waiting.
        Idle,
    };
    const State = packed struct {
        active: Active,
        _padding1: [@sizeOf(u32) - @sizeOf(Active)]u8 = undefined, // pad to u32
        idle_futex_word: u32,
        saturation: u32,
        _padding2: [std.atomic.cache_line - (@sizeOf(u32) * 3)]u8 = undefined,
    };
    state: State align(std.atomic.cache_line),

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
        return @sizeOf(Self) + offsetQueue() + Queue.sizeOf(config.worker_queue_capacity);
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

    pub fn work(self: *Self) void {
        @atomicStore(Self.Active, &self.state.active, .Active, .release);
        var jobs = [16]Job{};
        var wait_count: u32 = 0;
        while (true) {
            const len = self.getQueue().pop_some(jobs);
            if (len > 0) {
                for (jobs[0..len]) |job| {
                    job.tick(job.ctx, self);
                    wait_count = 0;
                    self.state.saturation -|= job.intensity; // Can avoid atomics since it is only accessed by this thread and in one cache line.
                }
            } else {
                if (wait_count < 32) {
                    std.atomic.spinLoopHint();
                } else if (wait_count < 256) {
                    std.Thread.yield() catch std.debug.print("Thread failed to yield\n");
                } else {
                    @atomicStore(u32, &self.state.idle_futex_word, 1, .release);
                    std.Thread.Futex.wait(&self.state.idle_futex_word, 1);
                    while (@atomicLoad(u32, &self.state.idle_futex_word, .acquire) != 0) {
                        std.Thread.Futex.wait(&self.state.idle_futex_word, 1);
                    }
                }
                wait_count +|= 1;
            }
            @atomicStore(u32, &self.state.saturation, self.state.saturation, .release); // Publish saturation
        }
    }

    /// Enqueue jobs locally, or round-robin to other threads.
    fn enqueue(self: *Self, jobs: []Job, local: bool) void {
        const job_count = jobs.len;
        if (local) {
            const local_count = self.getQueue().push_some(jobs);
            if (local_count > job_count) return; // All jobs were enqueued locally
        }
        const thread_count = @as(u64, @intCast(self.parent.thread_count.value.load(.acquire)));
        if (jobs.len >= thread_count) {}
    }
};

pub const ThreadPool = struct {
    const Self = @This();

    config: Config,
    thread_count: struct {
        value: std.atomic.Value(u16),
        _padding: [std.atomic.cache_line - @sizeOf(std.atomic.Value(u16))]u8 = undefined,
    } align(std.atomic.cache_line),

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
        return @as(*u8, @ptrFromInt(@intFromPtr(self) + offsetStackRegion(&self.config)))[0 .. self.config.stack_size * self.config.thread_count];
    }
    pub inline fn getThread(self: *Self, thread_index: u16) *Thread {
        return @ptrFromInt(@intFromPtr(self) + offsetThread(&self.config, thread_index));
    }

    pub fn init(config: Config, init_thread_count: u16) !*Self {
        std.debug.assert(config.stack_size % std.heap.pageSize() == 0); // ensure stack size is a multiple of page size
        std.debug.assert(init_thread_count <= config.max_thread_count); // ensure we do not exceed max thread count

        const ptr = try VPA.reserveVirtualRegion(Self.sizeOf(&config));
        try VPA.commitVirtualPages(ptr, Self.leanSizeOf(&config) + config.stack_size * init_thread_count);
        const self = @as(*Self, @ptrCast(@alignCast(ptr)));

        // Initialize Self
        self.config = config;
        self.getFba().* = InplaceBufferAllocator.init(@ptrFromInt(@intFromPtr(self) + offsetStackRegion(&config)), config.stack_size * init_thread_count);
        self.getFbaInterface().* = self.getFba().threadSafeAllocator();

        // Initialize Threads, init queue first, then spawn
        for (0..init_thread_count) |i| {
            const thread = self.getThread(@intCast(i));
            const queue = thread.getQueue();
            _ = try Queue.initAtPtr(@ptrCast(queue), config.worker_queue_capacity);
            thread.parent = self;
            @atomicStore(Thread.State, &thread.state, .{
                .active = .Idle,
                .saturation = 0,
            }, .release);
            // Spawn the thread, passing the queue as an argument
            thread.getInternal().* = try std.Thread.spawn(.{
                .allocator = self.getFbaInterface().*,
                .stack_size = config.stack_size,
            }, thread.work, .{thread});
        }

        return self;
    }
    pub fn deinit(self: *Self) !void {
        // Join all threads
        for (0..self.thread_count.value.load(.acquire)) |i| {
            const thread = self.getThread(@intCast(i));
            thread.getInternal().join();
        }

        // Release the virtual region
        try VPA.releaseVirtualRegion(@ptrCast(self), Self.sizeOf(&self.config));
    }

    /// Submits a slice of jobs to the thread pool.
    /// Thread-affinity is not accounted for in the pool, use thread-local queues for that.
    fn submit(self: *Self, jobs: []Job) !void {
        if (self.thread_count.value.load(.monotonic)) |thread_count| {
            for (0..thread_count) |i| {
                const thread = self.getThread(@intCast(i));
                thread.getQueue().enqueue(jobs);
            }
        }
    }
};

test "ThreadPool init" {
    const pool = try ThreadPool.init(.{
        .max_thread_count = 8,
        .stack_size = std.mem.alignForward(usize, 1024 * 16, std.heap.pageSize()), // 16 KiB aligned to page size
        .main_queue_capacity = 1024,
        .worker_queue_capacity = 128,
    }, 4);
    defer pool.deinit() catch
        std.debug.panic("Failed to deinitialize ThreadPool\n", .{});
}
