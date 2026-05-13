const std = @import("std");
const VPA = @import("./virtual_page_allocator.zig").VirtualPageAllocator;
const RingBuffer = @import("./ring_buffer.zig").RingBuffer;
const ThreadPool = @import("../orca/ThreadPool.zig").ThreadPool;
const Thread = @import("../orca/ThreadPool.zig").Thread;
const Job = @import("../orca/ThreadPool.zig").Job;
const PaddedAtomic = @import("./PaddedAtomic.zig").PaddedAtomic;

pub const SLAB_SIZE: usize = 16 * 1024; // 16KiB
pub const Slab = [SLAB_SIZE]u8;

const SPIN_LIMITS = struct {
    pool_submit: u64 = 10_000,
};

pub const CoreHeap = struct {
    const FreeList = RingBuffer(*Slab);
    const CallbackBuffer = RingBuffer(Job);

    // Static configuration
    reserved_byte_len: usize,
    maximum_capacity: usize,
    thread_pool: *ThreadPool,
    grow_job: anyopaque, // GrowJob not implemented yet
    
    // Tuning parameters
    minimum_growth: usize,
    scalars_maximum_growth: usize,
    extra_growth_scalar: u8,
    pre_growth_scalar: u8,
    proactive_threshold: u8,

    // Static Memory Map (Calculated at init)
    slabs: [*]Slab,
    freelist: *FreeList,
    callbacks: *CallbackBuffer,

    // Mutable state (cache-line aligned to prevent false sharing)
    demanded_capacity: PaddedAtomic(usize) align(std.atomic.cache_line),
    capacity_ensured: PaddedAtomic(usize) align(std.atomic.cache_line),
    capacity_produced: PaddedAtomic(usize) align(std.atomic.cache_line),
    grow_thread: PaddedAtomic(?u16) align(std.atomic.cache_line),

    const InitError = error {
        OversizedCapacity,
        FailedReserveMemory,
        FailedCommitMemory,
        FailedRingBufferInit,
        FailedFreelistFill,
    };
    pub fn init(
        capacity: usize,
        maximum_capacity: usize,
        callback_capacity: usize,
        thread_pool: *ThreadPool,
        minimum_growth: usize,
        scalars_maximum_growth: usize,
        pre_growth_scalar: u8,
        extra_growth_scalar: u8,
        proactive_threshold: u8,
    ) InitError!*CoreHeap {
        const freelist_len = std.math.ceilPowerOfTwo(usize, maximum_capacity) catch return error.OversizedCapacity;
        const callbacks_len = std.math.ceilPowerOfTwo(usize, callback_capacity) catch return error.OversizedCapacity;
        const offset_freelist = std.mem.alignForward(usize, @sizeOf(CoreHeap), FreeList.alignOf());
        const offset_callbacks = std.mem.alignForward(usize, offset_freelist + FreeList.sizeOf(freelist_len), CallbackBuffer.alignOf());
        const offset_slabs = std.mem.alignForward(usize, offset_callbacks + CallbackBuffer.sizeOf(callbacks_len), VPA.page_size);
        const init_size = std.mem.alignForward(usize, offset_slabs +  SLAB_SIZE * capacity, VPA.page_size);
        const max_size = std.mem.alignForward(usize, offset_slabs + SLAB_SIZE * maximum_capacity, VPA.page_size);
        const ptr = VPA.reserveVirtualRegion(max_size) catch return error.FailedReserveMemory;
        VPA.commitVirtualPages(ptr, init_size) catch return error.FailedCommitMemory;

        const self: *CoreHeap = @ptrCast(@alignCast(ptr));
        const freelist = FreeList.initAtPtr(@ptrFromInt(@intFromPtr(self) + offset_freelist), freelist_len)
            catch return error.FailedRingBufferInit;
        const callbacks = CallbackBuffer.initAtPtr(@ptrFromInt(@intFromPtr(self) + offset_callbacks), callbacks_len)
            catch return error.FailedRingBufferInit;
        const slabs: [*]*Slab = @ptrFromInt(@intFromPtr(self) + offset_slabs);

        var buffer: [256]*Slab = undefined;
        var remaining: usize = capacity;
        var index: usize = 0;
        while (remaining > 0) {
            const batch: usize = @min(remaining, buffer.len);
            for (0..batch) |i| buffer[i] = &slabs[index];
            if (freelist.pushSome(buffer[0..batch]) < batch) return error.FailedFreelistFill;
            remaining -= batch;
            index += batch;
        }

        self.* = .{
            .reserved_byte_len = max_size,
            .maximum_capacity = maximum_capacity,
            .thread_pool = thread_pool,
            .grow_job = undefined,
            
            .minimum_growth = minimum_growth,
            .scalars_maximum_growth = scalars_maximum_growth,
            .pre_growth_scalar = pre_growth_scalar,
            .extra_growth_scalar = extra_growth_scalar,
            .proactive_threshold = proactive_threshold,

            .slabs = slabs,
            .freelist = freelist,
            .callbacks = callbacks,

            .demanded_capacity = .init(0),
            .capacity_ensured = .init(capacity),
            .capacity_produced = .init(capacity),
            .grow_thread = .init(null),
        };
        return self;
    }

    
};