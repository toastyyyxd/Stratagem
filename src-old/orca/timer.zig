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
    if (@sizeOf(usize) != 8) @compileError("Timer requires 64-bit pointers.");
}

const PaddedAtomicU64 = PaddedAtomic(u64);
const PaddedAtomicBool = PaddedAtomic(bool);

/// Container of timer metadata.
/// Some fields are modified after init, do not keep a pointer to Timer after it is pushed to Timers.
pub const Timer = packed struct (u256) {
    /// Self-contained deferred allocation state hint, not to be used as .parent
    dest_hint: *Container, // 8 bytes
    /// Absolute expiry tick since epoch alternation
    expiry_tick: u32, // 4 bytes
    /// Callback job
    job: Job, // 17 bytes (ptr + ptr + u8)
    _paddingWord: u8 = undefined, // pads to a word, byte 30 after
    // -- flags below:
    /// Alternating epoch, allows for always supporting timers up to std.math.max(@TypeOf(.expiry))
    expiry_epoch: u1, // 1 bit
    /// Flag to be flipped by the consumer to note its been checked
    alt_sentinel: bool, // 1 bit
    /// Flag to be set to 1 if this Timer was not immediately scheduled and is now scheduled.
    defer_complete: std.atomic.Value(bool), // 1 bit
    _paddingFill: u13 = undefined,
    pub fn init(timers: *TimerWheel, job: Job, expiry_tick: u64) Timer {
        std.debug.assert(expiry_tick - timers.global_tick.value.load(.acquire) < @as(u64, std.math.maxInt(u32)));
        
        const end_epoch: u1 = @truncate(expiry_tick >> 32);
        const end_tick32: u32 = @truncate(expiry_tick);
        
        return Timer{
            .dest_hint = timers.first_container,
            .expiry_tick = end_tick32,
            .job = job,
            .expiry_epoch = end_epoch,
            .alt_sentinel = false,
            .defer_complete = .init(false),
        };
    }
    pub inline fn remainingTicks(self: *Timer, now_tick: u64) u32 {
        const now_high = now_tick & 0xFFFFFFFF_00000000;
        var target_tick = now_high | self.expiry_tick;
        const current_epoch_bit: u1 = @truncate(now_tick >> 32);
        if (self.expiry_epoch != current_epoch_bit) {
            if (target_tick > now_tick) {
                target_tick -%= 0x1_00000000;
            } else {
                target_tick +%= 0x1_00000000;
            }
        }
        if (target_tick <= now_tick) return 0;
        return @intCast(target_tick - now_tick);
    }
    pub inline fn targetGranularity(self: *Timer, now_tick: u64) u32 {
        const remaining = self.remainingTicks(now_tick);
        if (remaining == 0) return 0; // Index 0 for immediate
        // Use log2 to get the exponent
        return std.math.log2(remaining);
    }
};

const TimerBuffer = RingBuffer(Timer);
const GranularitiesMap = [32]u16;

// We could use alternating buffers to reduce moving memory around, but that would double memory usage for large amounts of timers.
const Container = struct {
    const ExpandCtx = struct {
        waiting_timers: ?[]Timer,
        connect_next: ?*Container,
        /// Requested slab count
        len: usize,
        /// Array of slabs for .allocate to utilize
        slabs: [64]*Slab,
        /// The count of containers for each granularity, fine to coarse
        granularities: GranularitiesMap,
        /// Max granularity cached
        max_granularity: u32,
        pub fn init(out: *ExpandCtx, granularities: []u16, connect_next: ?*Container, waiting_timers: ?[]Timer) void {
            std.debug.assert(granularities.len <= GranularitiesMap.len);
            const aggregated = aggregateGranularities(granularities);
            @memset(&out.granularities, 0);
            @memcpy(out.granularities[0..granularities.len], granularities);
            out.waiting_timers = waiting_timers;
            out.connect_next = connect_next;
            out.len = aggregated.slabs_needed;
            out.max_granularity = aggregated.max_granularity;
        }
        pub fn aggregateGranularities(granularities: []u16) struct { slabs_needed: usize, max_granularity: u32 } {
            var slabs_needed = 0;
            var max_granularity = 1;
            for (granularities, 0..) |count, g| {
                slabs_needed += count;
                if (count != 0) max_granularity = g;
            }
            return .{ slabs_needed, max_granularity };
        }
    };
    /// The granularity of ticks this container represents in powers of 2
    granularity: u32,
    parent: *TimerWheel,
    next: std.atomic.Value(?*Container),
    modifying_next: std.atomic.Value(bool),
    expand_ctx: ExpandCtx,

    pub inline fn get(self: *Container, idx: usize) *TimerBuffer {
        const addr: usize = @intFromPtr(self);
        var ptr: usize = std.mem.alignForward(usize, addr + @sizeOf(Container), TimerBuffer.alignOf());
        return blk: switch (idx) {
            0 => @ptrFromInt(ptr),
            1 => {
                ptr += TimerBuffer.sizeOf(256);
                ptr = std.mem.alignForward(usize, ptr, TimerBuffer.alignOf());
                break :blk @ptrFromInt(ptr);
            },
            else => unreachable,
        };
    }

    pub fn init(parent: *TimerWheel, slab: *Slab, granularity: u16, next: ?*Container) *Container {
        var self: *Container = @ptrCast(slab);
        self.* = .{
            .parent = parent,
            .granularity = granularity,
            .next = .init(next),
            .modifying_next = .init(false),
            .expand_ctx = undefined,
        };
        TimerBuffer.initAtPtr(self.get(0), 256);
        TimerBuffer.initAtPtr(self.get(1), 128);
        return self;
    }

    pub fn pushSome(self: *Container, timers: []const Timer) u64 {
        var prog: u64 = self.get(0).pushSome(timers);
        if (prog == timers.len) return prog;
        prog += self.get(1).pushSome(timers[prog..timers.len]);
        return prog;
    }

    fn startExpand(self: *Container, thread: *Thread, expansion_map: []u16, connect_next: ?*Container, waiting_timers: ?[]Timer) struct { blocked: bool, immediate: bool } {
        if (self.modifying_next.cmpxchgStrong(false, true, .acq_rel, .acquire)) |_| {
            return .{ .blocked = true, .immediate = false };
        }

        std.debug.assert(blk: { // Verify validity of ladder
            var last = self.granularity;
            for (expansion_map) |g| {
                if (g == last) continue;
                if (g == last + 1) last = g
                else break :blk false;
            }
            break :blk true;
        });

        ExpandCtx.init(&self.expand_ctx, expansion_map, connect_next, waiting_timers);

        const ticket = self.parent.heap.prepareAllocation(self.expand_ctx.len);
        const allocation = self.parent.heap.allocate(thread, ticket, self.expand_ctx.slabs, .{
            .ctx = ticket,
            .load = 2,
            .tick = continueExtend,
        });

        if (allocation == .immediate) continueExtend(ticket, thread);
        return .{ .blocked = false, .immediate = allocation == .immediate };
    }

    fn continueExtend(ticket: *CoreHeap.AllocationTicket, thread: *Thread) void {
        const slabs_array_ptr: *[256]*Slab = @ptrCast(ticket.context.slabs.ptr);
        const expand_ctx: *ExpandCtx = @fieldParentPtr("slabs", slabs_array_ptr);
        const self: *Container = @fieldParentPtr("expand_ctx", expand_ctx);
        
        var to_be_next: ?*Container = expand_ctx.connect_next;
        var slab_i = 0;
        var g: usize = expand_ctx.max_granularity + 1;
        while (g > 0) {
            g -= 1;
            for (@intCast(expand_ctx.granularities[g])..0) |_| {
                const slab = expand_ctx.slabs[slab_i];
                to_be_next = Container.init(self.parent, slab, g, to_be_next);
                slab_i += 1;
            }
        }
        
        self.next.store(@ptrCast(ticket.context.slabs[0]), .release);
        self.modifying_next.store(false, .release);
        if (expand_ctx.waiting_timers) |timers|
            self.parent.traversePush(thread, self, timers);
    }
};

pub const TimerWheel = struct {
    const InitContext = struct {
        callback: ?Job,
        allocation_ticket: CoreHeap.AllocationTicket,
        granularities: GranularitiesMap,
    };
    const TickContext = struct {
        const State = enum {
            /// Running algorithm and indexing bin heads as we go
            Indexing,
            /// Already indexed bin heads, past first try and retrying
            Retrying
        };
        batch: [32]Timer,
        return_batch: [32][16]Timer,
        /// Alternating buffer A for retries to be iterated from and queued to, not using ringbuffer since
        /// its padding would outweigh savings, and we prefer a complete array iterable instead of per-item with a sentry.
        bin_heads_a: [32]*Container,
        bin_heads_a_len: usize,
        /// Alternating buffer A for retries to be iterated from and queued to, not using ringbuffer since
        /// its padding would outweigh savings, and we prefer a complete array iterable instead of per-item with a sentry.
        bin_heads_b: [32]*Container,
        bin_heads_b_len: usize,
        /// Alternating per pass of the FSM for selecting the alternating .bin_heads_a/b buffer
        iteration_alt: bool,
    };

    heap: *CoreHeap,
    thread_pool: *ThreadPool,
    first_container: *Container,
    ready: PaddedAtomicBool align(std.atomic.cache_line),
    global_tick: PaddedAtomicU64 align(std.atomic.cache_line),
    ns_accumulator: PaddedAtomicU64  align(std.atomic.cache_line),
    ticking: PaddedAtomicBool align(std.atomic.cache_line),
    /// Alternating per tick for marking timers as checked.
    tick_alt: bool,

    // config
    tick_ns: u64,

    // FSMs
    init_ctx: InitContext,
    tick_ctx: TickContext,

    fn allTimersHaveSameGranularity(timers: []Timer, now_tick: u64) bool {
        if (timers.len == 0) return true;
        const expected_g = timers[0].targetGranularity(now_tick);
        for (timers[1..timers.len]) |t|
            if (t.targetGranularity(now_tick) != expected_g) return false;
        return true;
    }

    pub fn startInit(self: *TimerWheel, heap: *CoreHeap, thread: *Thread, tick_ns: u64, granularities: []u16, callback: ?Job) struct { immediate: bool } {
        std.debug.assert(granularities.len != 0 and granularities[0] == 1);
        self.* = .{
            .heap = heap,
            .thread_pool = thread.parent,
            .first_container = undefined,
            .ready = .value.init(false),
            .global_tick = .value.init(0),
            .tick_ns = tick_ns,
            .init_ctx = .{
                .callback = callback,
                .allocation_ticket = heap.prepareAllocation(1),
                .granularities = undefined
            },
            .tick_ctx = undefined,
        };
        @memset(&self.init_ctx.granularities, 0);
        @memcpy(self.init_ctx.granularities[0..granularities.len], granularities);
        // We use the field as the array pointer for the slice, stupid hacky way to avoid having to allocate one.
        const slabs: []*Container = @as([*]*Container, @ptrCast(&self.first_container))[0..1];
        const allocation = self.heap.allocate(thread, &self.init_ctx.allocation_ticket, slabs, .{
            .ctx = self,
            .load = 1,
            .tick = continueInit
        });
        if (allocation == .immediate) continueInit(self, thread);
        return .{ .immediate = allocation == .immediate }; 
    }
    fn continueInit(self: *TimerWheel, thread: *Thread) void {
        _ = Container.init(self, @ptrCast(self.first_container), 1, null);
        self.init_ctx.granularities[0] -= 1;
        // Passing the entire init_ctx.granularities is fine since it would ignore coarser indexes with zeros anyway
        self.first_container.startExpand(thread, &self.init_ctx.granularities);
        self.ready.value.store(true, .release);
        if (self.init_ctx.callback) |job| {
            job.tick(job.ctx, thread);
            self.init_ctx.callback = null;
        }
    }

    /// Pushes a timers into this structure by taking a **pointer to a slice** of timers.
    /// If .immediate == false, backing memory for timers AND the slice itself should be maintained by the caller until .deferred_complete.load() == true on all
    /// Specifically, each individual timer is free once .deferred_complete.load() on it == true, and the pointer to the slice once all .deferered.completel.load() == true
    /// After push is complete, the memory should be treated as consumed and outdated state.
    pub fn schedule(self: *TimerWheel, thread: *Thread, timers: *[]Timer) struct { immediate: bool } {
        return self.traversePush(thread, self.first_container, timers);
    }
    fn traversePush(self: *TimerWheel, thread:* Thread, first: *Container, timers: *[]Timer) struct { immediate: bool } {
        const now_tick: u64 = self.global_tick.value.load(.acquire);
        std.debug.assert(allTimersHaveSameGranularity(timers, now_tick));
        const target_g: u32 = timers[0].targetGranularity(now_tick);

        var last_container = first;
        var container = first;
        var progress = 0;
        while (progress < timers.len) {
            const next = container.next.load(.acquire);
            if (next) |n| { // Standard path, has next
                if (n.granularity < target_g) { // Standard path, next or following could be us
                    last_container = container;
                    container = n;
                    continue; // continue
                } else if (n.granularity == target_g) {
                    last_container = container;
                    container = n;
                    const last_progress = progress;
                    progress += container.pushSome(timers[progress..timers.len]);
                    for (timers[last_progress..progress]) |*t| t.defer_complete.store(true, .release);
                    continue; // continue or exit on success
                }
            }
            // There is no next or next and following are too coarse, not us
            // Extend the list, we want to cover all granualities not available from current to target
            const expansion_map = [_]u16{0} ** 32; // This can be stack as it is copied by .startExtend into ExpandCtx
            for (container.granularity + 1 .. target_g) |g| expansion_map[g] = 1;
            // `next` may be a coarser bucket or null, .startExtend can take either without logic on our part
            const expansion = container.startExpand(thread, expansion_map[0..target_g], next, timers[progress..timers.len]);
            if (expansion.immediate) continue; // expanded, continue to see if next or subsequent is us
            if (expansion.blocked == false) return; // we will be called back after the expansion
            // expansion.blocked == true:
            // try again later, we are conflicting with another, so it may be expanded later
            timers[0].dest = container; // set dest as hint for continuation
            const jobs = [1]Job{ .{
                .ctx = @ptrCast(timers),
                .load = 1,
                .tick = @ptrCast(traversePushJob),
            } };
            thread.submitLocal(&jobs);
            return .{ .immediate = false };
        }
        
        return .{ .immediate = true };
    }
    fn traversePushJob(timers: *[]Timer, thread: *Thread) void {
        const self = timers[0].dest.parent;
        self.traversePush(thread, timers[0].dest, timers);
    }

    pub fn hook(self: *TimerWheel, timing: *Timing) void {
        timing.hooks[timing.hooks.len] = .{
            .ctx = @ptrCast(self),
            .fire = @ptrCast(accumulate)
        };
    }
    fn accumulate(self: *TimerWheel, delta_ns: u64) void {
        self.ns_accumulator.value.fetchAdd(delta_ns, .acq_rel);
        const jobs = [1]Job{ .{
            .ctx = @ptrCast(self),
            .load = 4,
            .tick = @ptrCast(tick),
        } };
        self.thread_pool.submit(&jobs);
    }
    fn tickInit(self: *TimerWheel, thread: *Thread) void {
        const ticks = self.ns_accumulator.value.load(.acquire) / self.tick_ns;
        if (self.ticking.value.cmpxchgStrong(false, true, .acq_rel, .acquire)) |_| {
            std.log.warn("Can't keep up ticking Timers, another {} tick(s) are up while the last is still being processed!", .{ticks});
            return; // Give up if we are already being ticked, means we can't keep up anyway.
        }
        const now_tick = self.global_tick.value.fetchAdd(ticks, .acq_rel) + ticks;
        self.ns_accumulator %= self.tick_ns;

        self.tick_ctx.tick_alt = !self.tick_ctx.tick_alt;
        // Init context
        self.tick_ctx.bin_heads_length
    }
    fn tick(self: *TimerWheel, thread: *Thread) void {
        const ticks = self.ns_accumulator.value.load(.acquire) / self.tick_ns;
        if (self.ticking.value.cmpxchgStrong(false, true, .acq_rel, .acquire)) |_| {
            std.log.warn("Can't keep up ticking Timers, another {} tick(s) are up while the last is still being processed!", .{ticks});
            return; // Give up if we are already being ticked, means we can't keep up anyway.
        }
        const now_tick = self.global_tick.value.fetchAdd(ticks, .acq_rel) + ticks;
        self.tick_alt = !self.tick_alt;
        self.ns_accumulator %= self.tick_ns;
        var container = self.first_container;
        var return_batch_len = [_]usize{ 0 } ** self.return_batch.len;
        while (true) {
            var first: ?*Timer = null;
            const rb = container.get(0);
            outer: while (true) {
                const total_len = rb.popSome(&self.batch);
                if (first == null and total_len != 0) first = self.batch[0];
                inner: for (self.batch[0..total_len]) |*t| {
                    if (t == first) break :outer;
                    if (t.alt_sentinel == self.tick_alt) continue :inner;
                    t.alt_sentinel = self.tick_alt;
                    if (t.remainingTicks(now_tick) == 0) {
                        self.thread_pool.submit(@as([*]Job, @ptrCast(&t.job))[0..1]);
                        continue :inner;
                    }
                    const target_g = t.targetGranularity(now_tick);
                    var g_ret_batch = self.return_batch[target_g];
                    var g_ret_batch_slice = g_ret_batch[0..return_batch_len[target_g]];
                    return_batch_len[target_g] += 1;
                    if (return_batch_len >= g_ret_batch.len) z
                }
            }
            if (container.next.load(.acquire)) |c| container = c
            else break;
        }
    }
};