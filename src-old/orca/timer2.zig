const std = @import("std");
const Instant = std.time.Instant;
const Thread = @import("./thread_pool.zig").Thread;
const ThreadPool = @import("./thread_pool.zig").ThreadPool;
const Job = @import("./thread_pool.zig").Job;
const CoreHeap = @import("../mem/coreheap.zig").CoreHeap;
const Slab = @import("../mem/coreheap.zig").Slab;
const RingBuffer = @import("../mem/ring_buffer.zig").RingBuffer;
const PaddedAtomic = @import("../mem/padded_atomic.zig").PaddedAtomic;
const Timing = @import("./timing.zig").Timing;

comptime {
    std.debug.assert(@sizeOf(usize) == 8);
}

/// Container of timer metadata
pub const Timer = packed struct(u256) {
    /// reference back to wheel and next container, not to be used as .parent
    dest_hint: *Container, // 8 bytes
    /// absolute truncated expiry tick
    expiry_tick: u32, // 4 bytes
    /// callback job
    job: Job, // 17 bytes
    /// padding to a word
    _paddingWord: u8 = undefined, // 1 byte, at 30 bytes
    // -- flags --
    /// absolute global epoch truncated into an alternating bit
    expiry_epoch: u1,
    /// padding to fit u256
    _paddingFill: u15 = undefined,
    pub fn init(job: Job, now_tick: u64, expiry_tick: u64) Timer {
        std.debug.assert(expiry_tick - now_tick < @as(u64, std.math.maxInt(u32)));
        const end_epoch: u1 = @truncate(expiry_tick >> 32);
        const end_tick32: u32 = @truncate(expiry_tick);
        return Timer{
            .dest_hint = undefined,
            .expiry_epoch = end_epoch,
            .expiry_tick = end_tick32,
            .job = job,
        };
    }
    pub inline fn remainingTicks(self: *Timer, now_tick: u64) u32 {
        // Merge high of now_tick and low as u32 expiry_tick
        var target_tick: u64 = (now_tick & ~0xFFFFFFFF) | self.expiry_tick;
        // Current epoch is just the lowest top bit (u1 at 33 rtl) of the 64-bit tick
        const current_epoch: u1 = @truncate(now_tick >> 32);
        // if expiry_epoch != current, otherwise 0
        const mismatch: u64 = @intFromBool(self.expiry_epoch != current_epoch);
        // +1 if target_tick <= now_tick, otherwise -1
        // idrk what im doing here but its ok if it works
        const dir: u64 = @intFromBool(target_tick <= now_tick);
        const adjust: i64 = @as(i64, mismatch) * (@as(i64, (dir << 1)) - 1);
        // apply adjustment
        // we don't really care about the upper 31 bits so this is fine afaik
        target_tick +%= @as(u64, adjust) << 32;
        // yuh
        const diff: i64 = @as(i64, target_tick) - @as(i64, now_tick);
        // mask = -1 when diff > 0, else 0
        const mask: i64 = -@as(i64, @intFromBool(diff > 0));
        return @truncate(diff & mask); // trunc i64 to u32
    }
    /// Expects remaining ticks to be >0 for the log2 operation.
    pub inline fn targetBin(self: *Timer, now_tick: u64) u5 {
        const remaining: u32 = self.remainingTicks(now_tick);
        std.debug.assert(remaining > 0);
        return std.math.log2(remaining);
    }
};

const BinMapBuffer = [32]u16;
const BinMap = []u16;

const Container = struct {
    const ExpandCtx = struct {
        callback: ?Job,
        connect_next: ?*Container,
        /// requested slab count
        len: usize,
        /// allocation for CoreHeap.allocate
        slabs: [64]*Slab,
        /// Count of containers for each bin, fine to coarse, contiguous after this one
        bins: BinMapBuffer,
        /// Cached max bin in .bins
        max_bin: u16,
        pub fn init(self: *ExpandCtx, bins: BinMap, connect_next: ?*Container, callback: ?Job) void {
            std.debug.assert(bins.len <= @typeInfo(BinMapBuffer).array.len);
            const aggr = aggregateBinMap(bins);
            self.* = .{
                .callback = callback,
                .connect_next = connect_next,
                .len = aggr.total,
                .max_bin = aggr.max_bin,
                .slabs = undefined,
                .bins = undefined,
            };
            @memset(&self.bins, 0);
            @memcpy(self.bins[0..bins.len], bins);
        }
        pub fn aggregateBinMap(bins: BinMap) struct { total: usize, max_bin: u16 } {
            var total: usize = 0;
            var max_bin: u16 = 0;
            for (bins, 0..) |count, bin| {
                total += count;
                if (count != 0) max_bin = bin;
            }
            return .{ total, max_bin };
        }
    };
    const Buffer = enum(u16) { a, b };

    bin: u16,
    parent: *TimerWheel,
    next: PaddedAtomic(?*Container),
    modifying_next: PaddedAtomic(bool),
    expand_ctx: ExpandCtx,

    buffer_a: [240]Timer,
    buffer_b: [240]Timer,
    current_buffer: PaddedAtomic(Buffer),
    write_cursor: PaddedAtomic(packed struct(u128) {
        a: usize,
        b: usize,
    }),
    reserved_cursor: PaddedAtomic(packed struct(u128) {
        a: usize,
        b: usize,
    }),

    pub fn init(self: *Container, parent: *TimerWheel, bin: u16, next: ?*Container) void {
        self.* = .{
            .bin = bin,
            .parent = parent,
            .next = .init(next),
            .modifying_next = .init(false),
            .expand_ctx = undefined,
            .buffer_a = undefined,
            .buffer_b = undefined,
            .current_buffer = .init(.a),
            .write_cursor = .init(.{ .a = 0, .b = 0 }),
            .reserved_cursor = .init(.{ .a = 0, .b = 0 }),
        };
    }
    pub fn startExtend(self: *Container, thread: *Thread, expansion_bins: BinMap, connect_next: ?*Container, callback: ?Job) struct { blocked: bool, immediate: bool } {
        if (self.modifying_next.value.cmpxchgStrong(false, true, .acq_rel, .acquire)) |_| {
            return .{ .blocked = true, .immediate = false };
        }
        std.debug.assert(blk: {
            var last = self.bin;
            for (expansion_bins) |b| {
                if (b == last) continue;
                if (b == last + 1) last = b else break :blk false;
            }
            break :blk true;
        });

        ExpandCtx.init(&self.expand_ctx, expansion_bins, connect_next, callback);
        const ticket = self.parent.heap.prepareAllocation(self.expand_ctx.len);
        const allocation = self.parent.heap.allocate(thread, ticket, self.expand_ctx.slabs, .{
            .ctx = @ptrCast(self),
            .load = 2,
            .tick = @ptrCast(continueExtend),
        });
        if (allocation == .immediate) continueExtend(self, thread);
        return .{ .blocked = false, .immediate = allocation == .immediate };
    }
    fn continueExtend(self: *Container, thread: *Thread) void {
        var to_be_next: ?*Container = self.expand_ctx.connect_next;
        var slab_i: usize = 0;
        var current_bin: usize = self.expand_ctx.max_bin;
        var bin_container_i: usize = self.expand_ctx.bins[current_bin];

        outer: while (true) {
            while (bin_container_i > 0) {
                bin_container_i -= 1;
                const new_container: *Container = @ptrCast(self.expand_ctx.slabs[slab_i]);
                Container.init(new_container, self.parent, current_bin, to_be_next);
                to_be_next = new_container;
                slab_i += 1;
            }
            // move to next lower bin
            if (current_bin == 0) break :outer;
            current_bin -= 1;
            bin_container_i = self.expand_ctx.bins[current_bin];
            if (current_bin == 0 and bin_container_i == 0) break :outer;
        }

        self.next.store(@ptrCast(self.expand_ctx.slabs[0]), .release);
        self.modifying_next.store(false, .release);

        if (self.expand_ctx.callback) |job| {
            thread.submitLocal(&[1]Job{job});
        }
    }
};
comptime {
    std.debug.assert(@sizeOf(Container) <= @sizeOf(Slab));
}

pub const TimerWheel = struct {
    const InitContext = struct {
        callback: ?Job,
        allocation_ticket: CoreHeap.AllocationTicket,
        slab: [1]*Slab,
        bins_buffer: BinMapBuffer,
    };
    const TickContext = struct {
        const State = enum { Indexing, Retrying };
        return_batch: [32][16]Timer,
        bin_heads: [32]?*Container,
    };

    heap: *CoreHeap,
    thread_pool: *ThreadPool,
    ready: std.atomic.Value(bool),

    legend: [32]PaddedAtomic(?*Container),

    now_tick: PaddedAtomic(u64),
    ns_accumulator: PaddedAtomic(u64),
    ticking: std.atomic.Value(bool),

    init_ctx: InitContext,
    tick_alt: bool,
    tick_ctx: TickContext,

    tick_ns: u64,

    pub fn startInit(self: *TimerWheel, heap: *CoreHeap, thread: *Thread, tick_ns: u64, bins: BinMap, callback: ?Job) struct { immediate: bool } {
        std.debug.assert(bins.len != 0 and bins[0] >= 1 and bins.len <= @typeInfo(BinMapBuffer).array.len);
        self.* = .{
            .heap = heap,
            .thread_pool = thread.parent,
            .ready = .init(false),
            .legend = [_]PaddedAtomic(?*Container){.init(null)} ** self.legend.len,
            .now_tick = .init(0),
            .ns_accumulator = .init(0),
            .ticking = .init(0),
            .init_ctx = .{
                .callback = callback,
                .allocation_ticket = heap.prepareAllocation(1),
                .bins_buffer = undefined,
                .slab = undefined,
            },
            .tick_ctx = undefined,
            .tick_ns = tick_ns,
        };
        @memset(&self.init_ctx.bins_buffer, 0);
        @memcpy(self.init_ctx.bins_buffer[0..bins.len], bins);
        const slabs: []*Slab = self.init_ctx.slab[0..1];
        const allocation = self.heap.allocate(thread, &self.init_ctx.allocation_ticket, slabs, .{
            .ctx = self,
            .load = 2,
            .tick = continueInit,
        });
        if (allocation == .immediate) continueInit(self, thread);
        return .{ .immediate = allocation == .immediate };
    }
    fn continueInit(self: *TimerWheel, thread: *Thread) void {
        const container: *Container = @ptrCast(self.init_ctx.slab[0]);
        Container.init(container, self, 0, null);
        if (self.legend[0].value.cmpxchgStrong(null, container, .acq_rel, .acquire)) |_| {
            std.debug.panic("Was the timer wheel already initialized? This should never happen and I don't know what's the correct state anymore!", .{});
        }
        self.init_ctx.bins_buffer[0] -= 1;
        const extension = container.startExtend(thread, &self.init_ctx.bins_buffer, null, .{
            .ctx = @ptrCast(self),
            .load = 1,
            .tick = @ptrCast(finalizeInit),
        });
        if (extension.blocked) {
            thread.submitLocal(&[1]Job{.{ .ctx = self, .load = 2, .tick = @ptrCast(continueInit) }});
            std.log.warn("Blocked when extending timer wheel containers to init configuration. Retrying.\nThis should never happen as there should be no other users!\n", .{});
        }
        if (extension.immediate) finalizeInit(self, thread);
    }
    fn finalizeInit(self: *TimerWheel, thread: *Thread) void {
        self.ready.store(true, .release);
        if (self.init_ctx.callback) |job| thread.submitLocal(&[1]Job{job});
    }
};
