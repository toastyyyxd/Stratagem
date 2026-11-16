// fyi this is a culmination of many sleepless caffineated nights larping
// most likely makes performance worse with all the extra bs
// don't slime me pls i dont know what im doing

const std = @import("std");
const VPA = @import("../mem/VirtualPageAllocator.zig");
const InplaceBufferAllocator = @import("../mem/InplaceBufferAllocator.zig");
const Conduit = @import("../mem/Conduit.zig").Conduit;
const View = @import("../mem/Conduit.zig").View;
const PaddedAtomic = @import("../mem/PaddedAtomic.zig").PaddedAtomic;
const cacheInvalidationSize = @import("../mem/PaddedAtomic.zig").cacheInvalidationSize;
const Topology = @import("./pin_thread.zig").Topology;
const PhysThreadId = @import("./pin_thread.zig").PhysThreadId;
const PinKey = @import("./pin_thread.zig").PinKey;
const simd = @import("../utils/simd.zig");

const ThreadPool = @This();

// @@@ workload/job and queue @@@

pub const Workload = bitpack struct(u128) {
    ctx_ptr: usize,
    fn_ptr: usize,
};
pub const WorkFn = *const fn (*anyopaque, *Thread) void;

pub const Jobs = struct {
    workload: []Workload,
    load: []u16,
};

pub const QueueExternalImmutableJobs = struct {
    workload: []const Workload,
    load: []const u16,
};

pub const QueueInternalJobs = struct {
    workload: View(Workload),
    load: View(u16),
};

pub const Queue = Conduit(.{
    .structure = .soa,
    .concurrency = .mpmc,
    .ordering = .fifo,
    .cross_cluster = true,
    .ExternalMutable = Jobs,
    .ExternalImmutable = QueueExternalImmutableJobs,
    .Internal = QueueInternalJobs,
});

// @@@ layout const and limit @@@

const MAX_THREADS = std.math.maxInt(u16);
const VOLATILE_STRIDE = cacheInvalidationSize(true);

// @@@ id is topology but less crap @@@

pub const ThreadId = bitpack struct(u64) {
    vnuma: u16,
    complex: u16,
    thread: u16,
    /// SMT sibling's thread index within the same complex.
    twin: u16,
};

// @@@ config @@@

pub const Config = struct {
    queue_capacity: u64,
    stack_size: usize,
    batch_size: u64,
    max_thread_count: u16 = MAX_THREADS,
    steal_threshold_complex: u16 = 1,
    steal_threshold_vnuma: u16 = 1,
    spin_iterations: usize = 64,
    spin_idle_threshold: usize = 16,
    yield_idle_threshold: usize = 128,

    pub fn validate(config: *const Config) void {
        std.debug.assert(config.queue_capacity > 0);
        std.debug.assert(std.math.isPowerOfTwo(config.queue_capacity));
        std.debug.assert(std.mem.isAligned(config.stack_size, std.heap.pageSize()));
        std.debug.assert(config.max_thread_count > 0);
        std.debug.assert(config.steal_threshold_complex > 0);
        std.debug.assert(config.steal_threshold_vnuma > 0);
    }
};

// @@@ thread and main work @@@
pub const Thread = struct {
    const Self = @This();
    const SleepFutex = enum (u32) {
        sleep,
        wake,
    };

    active: PaddedAtomic(bool, false),
    sleep_futex: PaddedAtomic(SleepFutex, false),

    id: ThreadId,
    pin_id: PinKey,
    capacity: u16,

    parent: *ThreadPool,
    fba: InplaceBufferAllocator,

    load: PaddedAtomic(i32, true),

    internal: std.Thread,

    fn offsetQueue() usize {
        var offset: usize = @sizeOf(Self);
        offset = std.mem.alignForward(usize, offset, Queue.alignOf());
        return offset;
    }

    fn sizeOf(queue_capacity: u64) usize {
        return offsetQueue() + Queue.sizeOf(queue_capacity);
    }

    fn alignOf() usize {
        return comptime @max(@alignOf(Self), Queue.alignOf());
    }

    fn pageAlignedStride(queue_capacity: u64) usize {
        return std.mem.alignForward(usize, sizeOf(queue_capacity), std.heap.pageSize());
    }

    pub fn getQueue(self: *Self) *Queue {
        return @ptrFromInt(@intFromPtr(self) + offsetQueue());
    }

    pub fn main(self: *Self) void {
        var idle_for: usize = 0;
        while (!self.parent.stopping.value.load(.acquire)) {
            const consumed = self.getQueue().computePrioritySome(self.parent.batch_size, self, void, work);
            if (consumed != 0) {
                idle_for = 0;
                continue;
            }
            idle_for +|= 1;
            if (idle_for < self.parent.spin_idle_threshold) {
                inline for (0..self.parent.spin_iterations) |_| {
                    std.atomic.spinLoopHint();
                }
            } else if (idle_for < self.parent.yield_idle_threshold) {
                std.Thread.yield() catch {};
            } else _ = self.sleepWake();
        }
    }

    fn sleepWake(self: *Self) enum { never_slept, slept } {
        self.sleep_futex.value.store(.sleep, .acq_rel);
        self.parent.bitset.writeBitAt(.sleep, self.id, true, 1, 1);
        if (self.getQueue().estimateCountHigher() != 0 or self.load.value.load(.acquire) != 0) { // both, because the estimate is monotonic, while getting load ensures some sync
            self.parent.bitset.writeBitAt(.sleep, self.id, false, 1, 1);
            return .never_slept;
        }
        // nobody should steal from us. it will be set accordingly during fn main, so no reset at end.
        self.parent.bitset.writeBitAt(.steal, self.id, false, self.parent.steal_threshold_complex, self.parent.steal_threshold_vnuma);
        while (self.sleep_futex.value.load(.acquire) == .sleep) {
            self.parent.io.futexWaitUncancelable(SleepFutex, &self.sleep_futex.value.raw, .sleep);
        }
        self.parent.bitset.writeBitAt(.sleep, self.id, false, 1, 1);
        // sleep futex value should now be .wake anyway
        return .slept;
    }

    pub fn submitSome(self: *Self, jobs: Jobs) Jobs {
        std.debug.assert(jobs.workload.len == jobs.load.len);
        var remaining = self.submitLocal(jobs);
        remaining = self.parent.submitFrom(self, jobs);
        return remaining;
    }

    pub fn submitSomeLocal(self: *Self, jobs: Jobs) Jobs {
        std.debug.assert(jobs.workload.len == jobs.load.len);
        const consumed = self.getQueue().pushPrioritySome(jobs);
        self.submitLoadCounter(jobs.load[0..consumed]);
        return .{
            .load = jobs.load[consumed..],
            .workload = jobs.workload[consumed..],
        };
    }
    pub fn submitAllLocal(self: *Self, jobs: Jobs) bool {
        std.debug.assert(jobs.workload.len == jobs.load.len);
        const res = self.getQueue().pushPriority(jobs);
        if (res) {
            @branchHint(.likely);
            self.submitLoadCounter(jobs.load);
        }
        return res;
    }
    fn submitLoadCounter(self: *Self, loads: []u16) void {
        const load = simd.reduce(u16, .Add, loads);
        self.load.value.fetchAdd(@intCast(load), .acq_rel);
    }

    fn work(self: *Self, internal: QueueInternalJobs) void {
        // subtract load
        var d_load = simd.reduce(u16, .Add, internal.load.first);
        d_load += simd.reduce(u16, .Add, internal.load.second);
        self.load.value.fetchSub(@intCast(d_load), .acq_rel);
        // work
        inline for ([2]@TypeOf(internal.workload.first){internal.workload.first, internal.workload.second}) |l| {
            for (l) |w| {
                const func: WorkFn = @ptrFromInt(w.fn_ptr);
                const ctx: *anyopaque = @ptrFromInt(w.ctx_ptr);
                func(ctx, self);
            }
        }
    }
};

// @@@ bitset hierarchy @@@

pub const BitsetHierarchy = struct {
    const Self = @This();

    pub const Tier = enum { system, vnuma, complex };
    pub const TargetSet = enum { sleep, steal };

    volatile_addr: [TargetSet][Tier]usize,
    volatile_stride: [Tier]u16,

    exists_addr: [Tier]usize,
    exists_stride: [Tier]u16,

    pe_addr: usize,

    vnuma_count: u16,
    max_complexes_per_vnuma: u16,
    max_threads_per_complex: u16,

    pub fn words(items: u16) u16 {
        return @intCast(@max(1, (@as(usize, items) + 63) / 64));
    }

    fn tierOffset(comptime tier: Tier, vnuma: u16, complex: u16, stride: usize, complexes_per_vnuma: u16) usize {
        const vu = @as(usize, vnuma);
        const cu = @as(usize, complex);
        const cpu = @as(usize, complexes_per_vnuma);
        return switch (tier) {
            .system => 0,
            .vnuma => vu * stride,
            .complex => (vu * cpu + cu) * stride,
        };
    }

    fn targetSlotPtr(self: *const Self, comptime tier: Tier, comptime target: TargetSet, vnuma: u16, complex: u16) *align(VOLATILE_STRIDE) u64 {
        const base = self.volatile_addr[target][tier];
        const off = tierOffset(tier, vnuma, complex, self.volatile_stride[tier], self.max_complexes_per_vnuma);
        return @ptrFromInt(base + off);
    }

    fn volatileWord(self: *const Self, comptime tier: Tier, comptime target: TargetSet, vnuma: u16, complex: u16, word_idx: usize) *u64 {
        return &@as([*]u64, @ptrCast(self.targetSlotPtr(tier, target, vnuma, complex)))[word_idx];
    }

    fn existsNodePtr(self: *const Self, comptime tier: Tier, vnuma: u16, complex: u16) [*]u8 {
        const off = tierOffset(tier, vnuma, complex, self.exists_stride[tier], self.max_complexes_per_vnuma);
        return @ptrFromInt(self.exists_addr[tier] + off);
    }

    fn existsSetBit(self: *Self, comptime tier: Tier, vnuma: u16, complex: u16, bit: u16) void {
        const word = self.existsMutWord(tier, vnuma, complex, bit / 64);
        word.* |= bitMask(bit);
    }

    fn pe(self: *const Self, vnuma: u16) *u8 {
        return @ptrFromInt(self.pe_addr + @as(usize, vnuma));
    }

    fn volatileMaxWords(self: *const Self, comptime tier: Tier) usize {
        const counts = [_]u16{ self.vnuma_count, self.max_complexes_per_vnuma, self.max_threads_per_complex };
        return words(counts[@intFromEnum(tier)]);
    }

    pub fn readBitsetSlice(
        self: *const Self,
        comptime tier: Tier,
        comptime target: TargetSet,
        vnuma: u16,
        complex: u16,
    ) []u64 {
        const max_words = self.volatileMaxWords(tier);

        const exists_ptr = self.existsNodePtr(tier, vnuma, complex);
        const exists_words = @as([*]const u64, @ptrCast(@alignCast(exists_ptr)));

        var active_words: usize = 0;
        for (0..max_words) |w| {
            if (exists_words[w] != 0) active_words = w + 1;
        }

        const target_ptr = self.targetSlotPtr(tier, target, vnuma, complex);
        return @as([*]u64, @ptrCast(target_ptr))[0..active_words];
    }

    pub fn readBit(
        self: *const Self,
        comptime tier: Tier,
        comptime target: TargetSet,
        vnuma: u16,
        complex: u16,
        bit_index: u16,
    ) bool {
        const word_ptr = self.volatileWord(tier, target, vnuma, complex, bit_index / 64);
        const val = @atomicLoad(u64, word_ptr, .acquire);
        return (val & bitMask(bit_index)) != 0;
    }

    fn bitMask(x: u16) u64 {
        return @as(u64, 1) << @as(u6, @intCast(x % 64));
    }

    fn shouldPropagateUp(prev: u64, mask: u64, threshold: u16) bool {
        const prev_pop = @popCount(prev);
        const new_pop = prev_pop + @intFromBool((prev & mask) == 0);
        return prev_pop < threshold and new_pop >= threshold;
    }

    fn shouldPropagateDown(current: u64, exists: u64, threshold: u16) bool {
        return @popCount(current & exists) < threshold;
    }

    fn existsWord(self: *const Self, comptime tier: Tier, vnuma: u16, complex: u16, word_idx: usize) u64 {
        return @as(*const u64, @ptrCast(@alignCast(self.existsNodePtr(tier, vnuma, complex))))[word_idx];
    }

    fn existsMutWord(self: *Self, comptime tier: Tier, vnuma: u16, complex: u16, word_idx: usize) *u64 {
        return &@as([*]u64, @ptrCast(@alignCast(self.existsNodePtr(tier, vnuma, complex))))[word_idx];
    }

    fn clearBitAndPropagate(
        self: *Self,
        comptime target: TargetSet,
        comptime child_tier: Tier, child_vnuma: u16, child_complex: u16, child_word: usize, child_thresh: u16,
        comptime parent_tier: Tier, parent_vnuma: u16, parent_complex: u16, parent_word: usize, parent_mask: u64,
    ) bool {
        const cw = self.volatileWord(child_tier, target, child_vnuma, child_complex, child_word);
        const cur = @atomicLoad(u64, cw, .acquire);
        const ex = self.existsWord(child_tier, child_vnuma, child_complex, child_word);
        if (!shouldPropagateDown(cur, ex, child_thresh)) return false;

        const pw = self.volatileWord(parent_tier, target, parent_vnuma, parent_complex, parent_word);
        _ = @atomicRmw(u64, pw, .And, ~parent_mask, .acq_rel);

        const cur2 = @atomicLoad(u64, cw, .acquire);
        const ex2 = self.existsWord(child_tier, child_vnuma, child_complex, child_word);
        if (!shouldPropagateDown(cur2, ex2, child_thresh)) {
            _ = @atomicRmw(u64, pw, .Or, parent_mask, .acq_rel);
            return false;
        }
        return true;
    }

    pub fn writeBitAt(self: *Self, comptime target: TargetSet, id: ThreadId, value: bool, thresh_complex: u16, thresh_vnuma: u16) void {
        const t_mask = bitMask(id.thread);
        const t_word = id.thread / 64;
        const c_mask = bitMask(id.complex);
        const c_word = id.complex / 64;
        const v_mask = bitMask(id.vnuma);
        const v_word = id.vnuma / 64;

        if (value) {
            const c_word_ptr = self.volatileWord(.complex, target, id.vnuma, id.complex, t_word);
            const c_prev = @atomicRmw(u64, c_word_ptr, .Or, t_mask, .acq_rel);
            if (!shouldPropagateUp(c_prev, t_mask, thresh_complex)) return;

            const v_word_ptr = self.volatileWord(.vnuma, target, id.vnuma, 0, c_word);
            const v_prev = @atomicRmw(u64, v_word_ptr, .Or, c_mask, .acq_rel);
            if (!shouldPropagateUp(v_prev, c_mask, thresh_vnuma)) return;

            const s_word_ptr = self.volatileWord(.system, target, 0, 0, v_word);
            _ = @atomicRmw(u64, s_word_ptr, .Or, v_mask, .acq_rel);
        } else {
            const c_word_ptr = self.volatileWord(.complex, target, id.vnuma, id.complex, t_word);
            _ = @atomicRmw(u64, c_word_ptr, .And, ~t_mask, .acq_rel);

            if (!self.clearBitAndPropagate(target,
                .complex, id.vnuma, id.complex, t_word, thresh_complex,
                .vnuma, id.vnuma, 0, c_word, c_mask)) return;

            _ = self.clearBitAndPropagate(target,
                .vnuma, id.vnuma, 0, c_word, thresh_vnuma,
                .system, 0, 0, v_word, v_mask);
        }
    }
};

// @@@ big scary fucky layout @@@

const Layout = struct {
    off_steal_system: usize,
    off_steal_vnuma_base: usize,
    off_steal_complex_base: usize,

    off_pe_vnuma: usize,

    off_sleep_system: usize,
    off_sleep_vnuma_base: usize,
    off_sleep_complex_base: usize,

    off_exists_system: usize,
    stride_exists_system: usize,
    off_exists_vnuma_base: usize,
    stride_exists_vnuma: usize,
    off_exists_complex_base: usize,
    stride_exists_complex: usize,

    off_first_thread: usize,
    thread_stride: usize,
    off_first_stack: usize,

    total_size: usize,

    fn init(
        queue_capacity: u64,
        stack_size: usize,
        vnuma_count: u16,
        max_complexes_per_vnuma: u16,
        max_threads_per_complex: u16,
    ) Layout {
        var lay: Layout = undefined;
        var offset: usize = @sizeOf(ThreadPool);
        const N = @as(usize, vnuma_count);
        const M = @as(usize, max_complexes_per_vnuma);
        const T = @as(usize, max_threads_per_complex);
        const stride_sys = std.mem.alignForward(usize, BitsetHierarchy.words(vnuma_count) * @sizeOf(u64), VOLATILE_STRIDE);
        const stride_vnu = std.mem.alignForward(usize, BitsetHierarchy.words(max_complexes_per_vnuma) * @sizeOf(u64), VOLATILE_STRIDE);
        const stride_com = std.mem.alignForward(usize, BitsetHierarchy.words(max_threads_per_complex) * @sizeOf(u64), VOLATILE_STRIDE);

        offset = std.mem.alignForward(usize, offset, VOLATILE_STRIDE);

        // volatile steal
        lay.off_steal_system = offset;
        offset += stride_sys;

        lay.off_steal_vnuma_base = offset;
        offset += stride_vnu * N;

        lay.off_steal_complex_base = offset;
        offset += stride_com * N * M;

        // volatile sleep
        lay.off_sleep_system = offset;
        offset += stride_sys;

        lay.off_sleep_vnuma_base = offset;
        offset += stride_vnu * N;

        lay.off_sleep_complex_base = offset;
        offset += stride_com * N * M;

        // exists read-only metadata
        lay.off_exists_system = offset;
        lay.stride_exists_system = existsStride(vnuma_count);
        offset += lay.stride_exists_system;

        lay.off_exists_vnuma_base = offset;
        lay.stride_exists_vnuma = existsStride(max_complexes_per_vnuma);
        offset += lay.stride_exists_vnuma * N;

        lay.off_exists_complex_base = offset;
        lay.stride_exists_complex = existsStride(max_threads_per_complex);
        offset += lay.stride_exists_complex * N * M;

        // PE array (one u8 per vnuma)
        lay.off_pe_vnuma = offset;
        offset += N;

        // threads (page-aligned)
        lay.off_first_thread = std.mem.alignForward(usize, offset, std.heap.pageSize());
        lay.thread_stride = Thread.pageAlignedStride(queue_capacity);
        offset = lay.off_first_thread + lay.thread_stride * N * M * T;

        // stacks (already page-aligned due to thread_stride)
        lay.off_first_stack = offset;
        offset += stack_size * N * M * T;

        lay.total_size = offset;
        return lay;
    }

    fn existsStride(items: u16) usize {
        const words = (@as(usize, items) + 63) / 64;
        return std.math.ceilPowerOfTwoAssert(usize, @max(8, words * 8));
    }
};

// @@@ ThreadPool @@@

io: std.Io,

queue_capacity: u64,
stack_size: usize,
steal_threshold_complex: u16,
steal_threshold_vnuma: u16,
spin_iterations: usize,
spin_idle_threshold: usize,
yield_idle_threshold: usize,
batch_size: u64,

thread_count: PaddedAtomic(u16, true),
thread_count_claimed: PaddedAtomic(u16, true),
stopping: PaddedAtomic(bool, true),

bitset: BitsetHierarchy,

addr_first_thread: usize,
thread_stride: usize,
addr_first_stack: usize,

sorted_threads: []PhysThreadId,
sorted_threads_capacity: usize,
thread_ids: []ThreadId,
gpa: std.mem.Allocator,
layout_total_size: usize,

fn threadSlotIndex(self: *const ThreadPool, id: ThreadId) usize {
    const T = @as(usize, self.bitset.max_threads_per_complex);
    const C = @as(usize, self.bitset.max_complexes_per_vnuma);
    return @as(usize, id.vnuma) * C * T + @as(usize, id.complex) * T + @as(usize, id.thread);
}

pub fn writeBitSteal(self: *ThreadPool, id: ThreadId, value: bool) void {
    self.bitset.writeBitAt(.steal, id, value, self.steal_threshold_complex, self.steal_threshold_vnuma);
}

pub fn writeBitSleep(self: *ThreadPool, id: ThreadId, value: bool) void {
    self.bitset.writeBitAt(.sleep, id, value, 1, 1);
}

pub fn getThread(self: *const ThreadPool, id: ThreadId) *Thread {
    return @ptrFromInt(self.addr_first_thread + self.threadSlotIndex(id) * self.thread_stride);
}

pub fn stackPagePtr(self: *const ThreadPool, id: ThreadId) *u8 {
    return @ptrFromInt(self.addr_first_stack + self.threadSlotIndex(id) * self.stack_size);
}

const VnumaInfo = struct { pe: u8, eff_class: u8 };

// @@@ layout + init and deinit @@@

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    topology: *const Topology,
) !*ThreadPool {
    config.validate();

    // clone topology threads
    const thread_count_input = topology.count();
    if (thread_count_input == 0) return error.EmptyTopology;
    var clone_full = try allocator.alloc(PhysThreadId, thread_count_input);
    errdefer allocator.free(clone_full);
    @memcpy(clone_full, topology.threads);

    // sort most performant first: efficiency_class descending, then by hardware proximity
    std.mem.sort(PhysThreadId, clone_full, {}, lessThanSortKey);

    // keep only the most performant threads up to the config cap
    const trimmed_len = @min(clone_full.len, config.max_thread_count);
    if (trimmed_len == 0) return error.NoThreadsWithinCap;
    const clone = clone_full[0..trimmed_len];

    const thread_ids = try allocator.alloc(ThreadId, trimmed_len);
    errdefer allocator.free(thread_ids);

    // virtual NUMA split + dimension computation
    var vnuma_infos: std.ArrayListUnmanaged(VnumaInfo) = .{};
    defer vnuma_infos.deinit(allocator);

    var num_vnumas: u16 = 0;
    var M: u16 = 0;
    var T: u16 = 0;

    // global max capacity for absolute P/E scaling across all threads
    var global_max_cap: u16 = 1;
    for (clone) |t| {
        if (t.capacity > global_max_cap) global_max_cap = t.capacity;
    }

    var i: usize = 0;
    while (i < clone.len) {
        const vnuma_end = initVnumaEnd(clone, i);

        const pe = initComputePe(clone, i, vnuma_end - i, global_max_cap);
        try vnuma_infos.append(allocator, .{ .pe = pe, .eff_class = clone[i].efficiency_class });

        var complexes_in_vnuma: u16 = 0;
        var c: usize = i;
        while (c < vnuma_end) {
            const complex_end = initClusterEnd(clone, c, vnuma_end);
            const threads_in_complex: u16 = @intCast(complex_end - c);
            if (threads_in_complex > T) T = threads_in_complex;
            complexes_in_vnuma += 1;
            c = complex_end;
        }
        if (complexes_in_vnuma > M) M = complexes_in_vnuma;

        i = vnuma_end;
        num_vnumas += 1;
    }

    // clamp
    const total_slots = @as(usize, num_vnumas) * @as(usize, M) * @as(usize, T);
    if (total_slots > MAX_THREADS) return error.TopologyTooLarge;

    // compute layout
    const layout = Layout.init(config.queue_capacity, config.stack_size, num_vnumas, M, T);

    // allocate virtual memory
    const addr = try VPA.reserveVirtualRegion(layout.total_size);
    errdefer _ = VPA.releaseVirtualRegion(addr, layout.total_size);

    // commit metadata region: header + volatile bitsets + exists masks
    try VPA.commitVirtualPages(addr, layout.off_first_thread);
    const self: *ThreadPool = @ptrFromInt(addr);

    // zero volatile + exists region before first thread
    const z_start = layout.off_steal_system;
    const z_end = layout.off_first_thread;
    @memset(@as([*]u8, @ptrFromInt(addr + z_start))[0 .. z_end - z_start], 0);

    // populate header
    self.* = .{
        .io = io,

        .queue_capacity = config.queue_capacity,
        .stack_size = config.stack_size,
        .steal_threshold_complex = config.steal_threshold_complex,
        .steal_threshold_vnuma = config.steal_threshold_vnuma,
        .spin_iterations = config.spin_iterations,
        .spin_idle_threshold = config.spin_idle_threshold,
        .yield_idle_threshold = config.yield_idle_threshold,
        .batch_size = config.batch_size,

        .thread_count = .init(0),
        .thread_count_claimed = .init(0),
        .stopping = .init(false),

        .bitset = .{
            .volatile_stride = .{
                .system = @intCast(std.mem.alignForward(usize, BitsetHierarchy.words(num_vnumas) * @sizeOf(u64), VOLATILE_STRIDE)),
                .vnuma = @intCast(std.mem.alignForward(usize, BitsetHierarchy.words(M) * @sizeOf(u64), VOLATILE_STRIDE)),
                .complex = @intCast(std.mem.alignForward(usize, BitsetHierarchy.words(T) * @sizeOf(u64), VOLATILE_STRIDE)),
            },
            .volatile_addr = .{
                .steal = .{
                    .system = addr + layout.off_steal_system,
                    .vnuma = addr + layout.off_steal_vnuma_base,
                    .complex = addr + layout.off_steal_complex_base,
                },
                .sleep = .{
                    .system = addr + layout.off_sleep_system,
                    .vnuma = addr + layout.off_sleep_vnuma_base,
                    .complex = addr + layout.off_sleep_complex_base,
                },
            },
            .exists_addr = .{
                .system = addr + layout.off_exists_system,
                .vnuma = addr + layout.off_exists_vnuma_base,
                .complex = addr + layout.off_exists_complex_base,
            },
            .exists_stride = .{
                .system = @intCast(layout.stride_exists_system),
                .vnuma = @intCast(layout.stride_exists_vnuma),
                .complex = @intCast(layout.stride_exists_complex),
            },
            .pe_addr = addr + layout.off_pe_vnuma,
            .vnuma_count = num_vnumas,
            .max_complexes_per_vnuma = M,
            .max_threads_per_complex = T,
        },

        .addr_first_thread = addr + layout.off_first_thread,
        .thread_stride = layout.thread_stride,
        .addr_first_stack = addr + layout.off_first_stack,

        .sorted_threads = clone,
        .sorted_threads_capacity = clone_full.len,
        .thread_ids = thread_ids,
        .gpa = allocator,
        .layout_total_size = layout.total_size,
    };

    // populate exists masks + PE + thread structs
    try populateLayout(self, clone, vnuma_infos.items, thread_ids);

    return self;
}

fn lessThanSortKey(_: void, a: PhysThreadId, b: PhysThreadId) bool {
    if (a.efficiency_class != b.efficiency_class) return a.efficiency_class > b.efficiency_class;
    if (a.numa != b.numa) return a.numa < b.numa;
    if (a.cluster != b.cluster) return a.cluster < b.cluster;
    if (a.core != b.core) return a.core < b.core;
    return a.thread < b.thread;
}

fn initVnumaEnd(clone: []const PhysThreadId, start: usize) usize {
    const base_numa = clone[start].numa;
    const base_eff = clone[start].efficiency_class;
    var j = start + 1;
    while (j < clone.len and clone[j].numa == base_numa and clone[j].efficiency_class == base_eff) : (j += 1) {}
    return j;
}

fn initClusterEnd(clone: []const PhysThreadId, start: usize, end: usize) usize {
    const base_cluster = clone[start].cluster;
    var j = start + 1;
    while (j < end and clone[j].cluster == base_cluster) : (j += 1) {}
    return j;
}

fn initCoreEnd(clone: []const PhysThreadId, start: usize, complex_end: usize) usize {
    const base_core = clone[start].core;
    var j = start + 1;
    while (j < complex_end and clone[j].core == base_core) : (j += 1) {}
    return j;
}

fn initTwinIndex(thread_idx: u16, sibling_rel: u16, siblings_on_core: u16) u16 {
    const twin_rel: u16 = if (sibling_rel % 2 == 0) blk: {
        if (sibling_rel + 1 < siblings_on_core)
            break :blk sibling_rel + 1
        else
            break :blk sibling_rel;
    } else sibling_rel - 1;
    return thread_idx - sibling_rel + twin_rel;
}

fn initComputePe(clone: []const PhysThreadId, start: usize, count: usize, global_max_cap: u16) u8 {
    if (global_max_cap == 0) return 0;
    var sum: u32 = 0;
    for (clone[start .. start + count]) |t| sum += t.capacity;
    const avg = sum / @as(u32, @intCast(count));
    const scaled = (avg * 255) / global_max_cap;
    return @intCast(@min(scaled, 255));
}

fn initPopulateThreadSlot(
    self: *ThreadPool,
    id: ThreadId,
    phys: PhysThreadId,
    thread_ids: []ThreadId,
    sort_i: *usize,
) !void {
    thread_ids[sort_i.*] = id;
    sort_i.* += 1;

    const thread_addr = self.addr_first_thread + self.threadSlotIndex(id) * self.thread_stride;
    try VPA.commitVirtualPages(thread_addr, self.thread_stride);

    const thread = self.getThread(id);
    thread.active.value = .init(false);
    thread.sleep_futex.value = .init(.wake);
    thread.id = id;
    thread.pin_id = phys._key;
    thread.capacity = phys.capacity;
    thread.parent = self;
    thread.fba = InplaceBufferAllocator.init(
        self.stackPagePtr(id),
        self.stack_size,
    );

    const queue_ptr = @intFromPtr(thread) + Thread.offsetQueue();
    const q = @as(*Queue, @ptrFromInt(queue_ptr));
    q.* = undefined;
    _ = Queue.initAtPtr(queue_ptr, self.queue_capacity);
}

fn populateLayout(
    self: *ThreadPool,
    clone: []const PhysThreadId,
    vnuma_infos: []const VnumaInfo,
    thread_ids: []ThreadId,
) !void {
    var sort_i: usize = 0;
    var vnuma_idx: u16 = 0;
    var vi: usize = 0;

    while (vi < clone.len) {
        const vnuma_end = initVnumaEnd(clone, vi);
        try populateVnuma(self, clone, vi, vnuma_end, vnuma_idx, vnuma_infos[vnuma_idx].pe, thread_ids, &sort_i);
        vi = vnuma_end;
        vnuma_idx += 1;
    }
}

fn populateVnuma(
    self: *ThreadPool,
    clone: []const PhysThreadId,
    vnuma_start: usize,
    vnuma_end: usize,
    vnuma_idx: u16,
    pe: u8,
    thread_ids: []ThreadId,
    sort_i: *usize,
) !void {
    self.bitset.existsSetBit(.system, 0, 0, vnuma_idx);
    self.bitset.pe(vnuma_idx).* = pe;

    var complex_idx: u16 = 0;
    var c = vnuma_start;
    while (c < vnuma_end) {
        const complex_end = initClusterEnd(clone, c, vnuma_end);
        try populateComplex(self, clone, c, complex_end, vnuma_idx, complex_idx, thread_ids, sort_i);
        c = complex_end;
        complex_idx += 1;
    }
}

fn populateComplex(
    self: *ThreadPool,
    clone: []const PhysThreadId,
    complex_start: usize,
    complex_end: usize,
    vnuma_idx: u16,
    complex_idx: u16,
    thread_ids: []ThreadId,
    sort_i: *usize,
) !void {
    self.bitset.existsSetBit(.vnuma, vnuma_idx, 0, complex_idx);

    var thread_idx: u16 = 0;
    var t = complex_start;
    while (t < complex_end) {
        const core_end = initCoreEnd(clone, t, complex_end);
        const siblings_on_core: u16 = @intCast(core_end - t);

        for (t..core_end) |s| {
            const sibling_rel: u16 = @intCast(s - t);
            self.bitset.existsSetBit(.complex, vnuma_idx, complex_idx, thread_idx);

            const id = ThreadId{
                .vnuma = vnuma_idx,
                .complex = complex_idx,
                .thread = thread_idx,
                .twin = initTwinIndex(thread_idx, sibling_rel, siblings_on_core),
            };
            try initPopulateThreadSlot(self, id, clone[s], thread_ids, sort_i);
            thread_idx += 1;
        }
        t = core_end;
    }
}


// @@@ init and deinit @@@

pub fn initThreadTill(self: *ThreadPool, count: u16, batch_size: u16) !enum { wait_for_other, done, stopping } {
    std.debug.assert(count <= self.thread_ids.len);
    var current = self.thread_count_claimed.value.load(.acquire);
    var target = @min(count, current + batch_size);
    while (true) {
        if (current == std.math.maxInt(u16)) return .stopping;
        if (current >= target) return if (self.thread_count.value.load(.acquire) >= count) .done else .wait_for_other;
        if (self.thread_count_claimed.value.cmpxchgStrong(current, target, .acq_rel, .acquire)) |actual| {
            current = actual;
            target = @min(count, current + batch_size);
            continue;
        }
        for (current..target) |i| {
            try self.initThread(self.thread_ids[@as(u16, @intCast(i))]);
        }

        // have to wait for others before us to publish if we're ahead
        while (self.thread_count.value.load(.acquire) != current) {
            std.atomic.spinLoopHint();
        }
        self.thread_count.value.store(target, .release);

        current = target;
        target = @min(count, current + batch_size);
    }
}

pub fn initThread(self: *ThreadPool, id: ThreadId) !void {
    const thread = self.getThread(id);
    try VPA.commitVirtualPages(@intFromPtr(self.stackPagePtr(id)), self.stack_size);
    const internal = try std.Thread.spawn(.{
        .allocator = thread.fba.allocator(),
        .stack_size = self.stack_size,
    }, Thread.main, thread);
    thread.internal = internal;
}

pub fn wake(self: *ThreadPool, id: ThreadId) void {
    const thread = self.getThread(id);
    thread.sleep_futex.value.store(.wake, .release);
    self.io.futexWake(Thread.SleepFutex, &thread.sleep_futex.value.raw, 1);
}

pub fn submitFrom(self: *ThreadPool, local_id: ThreadId, jobs: Jobs, bearers: enum { least, spread }) Jobs {
    const jobs_count = jobs.workload.len;
    var jobs_consumed: u64 = 0;
    const threads_budget = jobs_count / @as(usize, @intCast(self.batch_size));
    var threads_used: usize = 0;
    const twin_id: ThreadId = .{
        .vnuma = local_id.vnuma,
        .complex = local_id.complex,
        .thread = local_id.twin,
        .twin = local_id.thread,
    };
    const real_twin = twin_id != local_id;
    if (real_twin) {
        if (!self.bitset.readBit(.complex, .sleep, twin_id.vnuma, twin_id.complex, twin_id.thread)
            and !self.bitset.readBit(.complex, .steal, twin_id.vnuma, twin_id.complex, twin_id.thread)) {
            const twin = self.getThread(twin_id);
            const current = twin.getQueue().estimateCountHigher();
            const target = @min(jobs_count, self.steal_load_threshold -| current);
            if (target > self.batch_size or threads_budget == 1) {
                jobs_consumed += twin.getQueue().pushSome(.{
                    .workload = jobs.workload[@intCast(jobs_consumed)..@intCast(target)],
                    .load = jobs.load[@intCast(jobs_consumed)..@intCast(target)],
                });
                if (jobs_consumed != 0) {
                    twin.submitLoadCounter(jobs.load[@intCast(consumed)..@intCast(target)]);
                    threads_used += 1;
                }
            }
        }
        if (jobs_count == jobs_consumed) return .{
            .load = jobs.load[jobs_consumed..], // should naturally be len 0
            .workload = jobs.workload[jobs_consumed..],
        };
    }
    
    ascent: for ([3]BitsetHierarchy.Tier{ .vnuma, .system }) |tier| {
        const sleep_bits = self.bitset.readBitsetSlice(tier, .sleep, local_id.vnuma, local_id.complex);
        const steal_bits = self.bitset.readBitsetSlice(tier, .steal, local_id.vnuma, local_id.complex);
        
    }
}
inline fn submitComplex(
    self: *ThreadPool,
    local_id: ThreadId,
    twin_id: ThreadId,
    threads_used: *usize,
    threads_budget: usize,
    jobs: Jobs,
    jobs_count: usize,
    jobs_consumed: *u64,
) void {
    const sleep_bits = self.bitset.readBitsetSlice(tier, .sleep, local_id.vnuma, local_id.complex);
    const steal_bits = self.bitset.readBitsetSlice(tier, .steal, local_id.vnuma, local_id.complex);
    for (0..@popCount(self.bitset.))
}

fn trashInit(self: *ThreadPool) !void {
    // lock and sync init barriers
    var current = self.thread_count_claimed.value.load(.acquire);
    while (true) {
        const res = self.thread_count_claimed.value.cmpxchgWeak(current, std.math.maxInt(u16), .acq_rel, .acquire);
        if (res) |actual| {
            current = actual;
            std.atomic.spinLoopHint();
        }
        else break;
    }
    // current is now the last valid value
    while (self.thread_count.value.load(.acquire) != current) {
        try std.Thread.yield();
    }
}

pub fn deinit(self: *ThreadPool) !void {
    const stopping = self.stopping.value.cmpxchgStrong(false, true, .acq_rel, .acquire);
    if (stopping) |y| if (y) return error.AlreadyDeinitializing;
    try self.trashInit();
    for (self.thread_ids) |id| {
        const thread = self.getThread(id);
        thread.internal.join();
    }
    self.gpa.free(self.sorted_threads.ptr[0..self.sorted_threads_capacity]);
    self.gpa.free(self.thread_ids);
    try VPA.releaseVirtualRegion(@intFromPtr(self), self.layout_total_size);
}
