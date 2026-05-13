const std = @import("std");
const Io = std.Io;
const atomic = std.atomic;
const Timestamp = Io.Timestamp;
const mem = std.mem;
const assert = std.debug.assert;
const VPA = @import("../mem/VirtualPageAllocator.zig").VirtualPageAllocator;
const InplaceBufferAllocator = @import("../mem/InplaceBufferAllocator.zig").InplaceBufferAllocator;
const RingBuffer = @import("../mem/RingBuffer.zig").RingBuffer;
const View = @import("../mem/RingBuffer.zig").View;
const PaddedAtomic = @import("../mem/PaddedAtomic.zig").PaddedAtomic;

const Queue = RingBuffer(Job, .aos, .mpmc, .fifo, null);

pub const MAX_THREADS: comptime_int = 128;

const MAX_JOBS_BATCH = 64;
const MAX_STEAL_BATCH = 24;
const SPIN_ITERATIONS_BEFORE_YIELD = 128;
const MAX_YIELD_ITERATIONS = 512;

pub const Unit = packed struct(u128) {
    /// The context to be passed to the tick function.
    /// Usually a pointer to the FSM that this job acts as a VTable for.
    ctx: *anyopaque,
    /// The function to be called when the job is ready to be processed.
    /// Usually a method of the FSM in .ctx.
    tick: *const fn (*anyopaque, *Thread) void,
};

/// A unit of work that can be submitted to the thread pool.
/// Also functions as a VTable for any other FSM.
const Job = struct {
    /// Pointers to a FSM context and tick function
    unit: Unit align(16),
    /// Load integer for load-balancing
    load: u8,
};

pub const Config = struct {
    max_thread_count: u16,
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

    const Active = enum(u16) {
        // Waking up, active, or spinning.
        running,
        // Setting up futex or already waiting.
        asleep,
    };
    
    pub const WaitSlot = struct {
        trigger_stamp: Timestamp,
        io: Io,
        job: Job,
        active: bool,
    };

    active: PaddedAtomic(Active) align (atomic.cache_line),
    should_exit: PaddedAtomic(bool) align (atomic.cache_line),
    idle_futex_word: PaddedAtomic(u32) align (atomic.cache_line),

    /// Special singular job slot for any timing system to hook onto.
    wait_slot: WaitSlot,

    // Work context
    load: PaddedAtomic(u64) align (atomic.cache_line),
    wait_count: usize = 0,
    iterations: u64 = 0,
    stress: u64 = 0,

    parent: *ThreadPool,

    fn offsetStart() usize {
        return @sizeOf(Self);
    }
    fn offsetInteral 
};

pub const ThreadPool = struct {
    const Self = @This();
    config: Config,
    io: Io,
    thread_count: PaddedAtomic(u16) align(atomic.cache_line),
    thread_count_claimed: PaddedAtomic(u16) align(atomic.cache_line),

    fn offsetStart() usize {
        return @sizeOf(Self);
    }
    fn offsetStackAllocator() usize {
        var offset = offsetStart();
        offset = mem.alignForward(usize, offset, @alignOf(InplaceBufferAllocator));
        return offset;
    }
    fn offsetAfterStackAllocator() usize {
        var offset = offsetStackAllocator();
        offset += @sizeOf(InplaceBufferAllocator);
    }
    fn offsetAllocatorInterface() usize {
        var offset = offsetAfterStackAllocator();
        offset = mem.alignForward(usize, offset, @alignOf(mem.Allocator));
        return offset;
    }
    fn offsetAfterAllocatorInterface() usize {
        var offset = offsetAllocatorInterface();
        offset += @sizeOf(mem.Allocator);
        return offset;
    }
    fn offsetThread(config: *const Config, thread_i: u16) usize {
        assert(thread_i < config.max_thread_count);
        var offset = offsetAfterAllocatorInterface();
        offset = mem.alignForward(usize, offset, Thread.alignOf());
        offset += mem.alignForward(usize, Thread.sizeOf(config), Thread.alignOf()) * thread_i;
        return offset;
    }
    fn offsetAfterThreads(config: *const Config) usize {
        var offset = offsetThread(config, config.max_thread_count - 1);
        offset += Thread.sizeOf();
        return offset;
    }
    // Stack region is last for the VPA to be able to reserve but not fully commit the memory.
    fn offsetStackRegion(config: *const Config) usize {
        var offset = offsetAfterThreads(config);
        offset = mem.alignForward(usize, offset, VPA.page_size);
        return offset;
    }
    fn offsetAfterStackRegion(config: *const Config) usize {
        var offset = offsetStackRegion(config);
        offset += config.stack_size * config.max_thread_count;
    }

    pub fn sizeOf(config: *const Config) usize {
        return offsetAfterStackRegion(config);
    }
    /// `.sizeOf(...)` without the stack region.
    pub fn leanSizeOf(config: *const Config) usize {
        return offsetAfterThreads(config);
    }
    pub fn alignOf() usize {
        return @max(
            @alignOf(Self),
            @alignOf(InplaceBufferAllocator),
            @alignOf(mem.Allocator),
            Queue.alignOf(),
            Thread.alignOf(),
        );
    }

    fn getStackAllocator(self: *Self) *InplaceBufferAllocator {
        const base = @intFromPtr(self);
        return @ptrFromInt(base + offsetStackAllocator());
    }
    fn getStackAllocatorInterface(self: *Self) *mem.Allocator {
        const base = @intFromPtr(self);
        return @ptrFromInt(base + offsetAllocatorInterface());
    }
    fn getThread(self: *Self, thread_i: u16) *Thread {
        const base = @intFromPtr(self);
        return @ptrFromInt(base + offsetThread(&self.config, thread_i));
    }
    fn getStackRegion(self: *Self) []u8 {
        const base = @intFromPtr(self);
        const ptr: [*]u8 = @ptrFromInt(base);
        return ptr[offsetStackRegion(self.config) .. offsetAfterStackRegion(self.config)];
    }

    pub fn getMaxThreadCount(self: *const Self) u16 {
        return self.config.max_thread_count;
    }

    pub fn init(io: Io, config: Config, init_thread_count: u16) !*Self {
        assert(config.max_thread_count <= MAX_THREADS);
        assert(mem.isAligned(config.stack_size, VPA.page_size));
        assert(init_thread_count <= config.max_thread_count);

        const ptr = try VPA.reserveVirtualRegion(Self.sizeOf(&config));
        try VPA.commitVirtualPages(ptr, Self.leanSizeOf(&config));
        const self = @as(*Self, @ptrCast(@alignCast(ptr)));
        self.* = .{
            .io = io,
            .config = config,
            .thread_count = .init(0),
            .thread_count_claimed = .init(0),
        };
        const stack_region = self.getStackRegion();
        self.getStackAllocator().* = InplaceBufferAllocator.init(stack_region[0..], stack_region.len);
        self.getStackAllocatorInterface().* = self.getStackAllocator().threadSafeAllocator();

        self.ensureThreads(init_thread_count);

        return self;
    }

    pub fn deinit(self: *Self) void {
        const n = self.thread_count.value.load(.acquire);
        for (0..n) |i| self.getThread(@intCast(i)).should_exit.store(true, .release); // Signal exit
        for (0..n) |i| self.getThread(@intCast(i)).wake(); // Wake any sleeping threads
        for (0..n) |i| self.getThread(@intCast(i)).getInternal().join(); // Join thread
    }
    pub fn free(self: *Self) !void {
        try VPA.releaseVirtualRegion(@ptrCast(self), Self.sizeOf(self.config));
    }

    pub fn getRunningCount(self: *Self) u16 {
        var n: u16 = 0;
        for (0..self.thread_count.load(.acquire)) |i| {
            const thread = self.getThread(@truncate(i));
            if (thread.active.value.load(.acquire) == .running) n += 1;
        }
        return n;
    }
};
