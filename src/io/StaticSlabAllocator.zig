const std = @import("std");
const VPA = @import("../mem/VirtualPageAllocator.zig");
const conduit = @import("../mem/Conduit.zig");
const cacheInvalidationSize = @import("../mem/PaddedAtomic.zig").cacheInvalidationSize;
const iotaFill = @import("../utils/simd.zig").iotaFill;
const copy = @import("../mem/copy.zig");

const Self = @This();

pub const Config = struct {
    slab_size: usize,
    slab_count: u32,
    thread_stack_size: u32,
    thread_stack_count: u16,
    spill_alloc_threshold: u32,
    spill_eq_target: u32,
    spill_dealloc_threshold: u32,

    pub fn validate(config: *const Config) void {
        std.debug.assert(std.math.isPowerOfTwo(config.slab_count));
        std.debug.assert(config.thread_stack_size * @as(usize, config.thread_stack_count) <= config.slab_count);
        std.debug.assert(config.spill_eq_target <= config.thread_stack_size);
    }
};

const Freelist = conduit.Conduit(.{
    .cross_cluster = false,
    .concurrency = .mpmc,
    .ordering = .fifo,
    .structure = .aos,
    .Item = u32,
    .Internal = conduit.View(u32),
});

const Layout = struct {
    global_freelist: usize,
    first_thread_stack: usize,
    thread_stack_stride: usize,
    slabs: usize,
    size: usize,
    fn init(config: Config) Layout {
        var layout: Layout = undefined;
        var offset: usize = @sizeOf(Self);
        offset = std.mem.alignForward(usize, offset, cacheInvalidationSize(false));
        layout.global_freelist = offset;
        offset += Freelist.sizeOf(config.slab_count);
        offset = std.mem.alignForward(usize, offset, cacheInvalidationSize(false));
        layout.first_thread_stack = offset;
        layout.thread_stack_stride = std.mem.alignForward(usize, @sizeOf(usize)+@sizeOf(u32)*@as(usize, config.thread_stack_count), cacheInvalidationSize(false));
        offset += layout.thread_stack_stride * @as(usize, config.thread_stack_count);
        offset = std.mem.alignForward(usize, offset, cacheInvalidationSize(false));
        layout.slabs = offset;
        offset += config.slab_size * @as(usize, config.slab_count);
        layout.size = offset;
        return layout;
    }
};

// config
slab_size: usize,
thread_stack_count: u16,
spill_dealloc_threshold: u32,
spill_eq_target: u32,
spill_alloc_threshold: u32,

// layout
global_freelist: *Freelist,
addr_first_thread_stack: usize,
off_thread_stack_stride: usize,
thread_stack_capacity: u32,
addr_slabs: usize,
allocated_size: usize,

pub fn sizeOf(config: Config) usize {
    return Layout.init(config).size;
}
pub fn alignOf() usize {
    return @max(
        @alignOf(Self),
        Freelist.alignOf(),
    );
}

pub fn init(config: Config) !*Self {
    // validate
    config.validate();
    // alloc
    const layout = Layout.init(config);
    const addr_self = try VPA.reserveVirtualRegion(layout.size);
    std.debug.assert(std.mem.isAligned(addr_self, Self.alignOf()));
    const self = @as(*Self, @ptrFromInt(addr_self));
    // layout
    self.slab_size = config.slab_size;
    self.thread_stack_count = config.thread_stack_count;
    self.spill_eq_target = config.spill_eq_target;
    self.spill_dealloc_threshold = config.spill_dealloc_threshold;
    self.spill_alloc_threshold = config.spill_alloc_threshold;
    self.addr_first_thread_stack = addr_self + layout.first_thread_stack;
    self.off_thread_stack_stride = layout.thread_stack_stride;
    self.thread_stack_capacity = config.thread_stack_size;
    self.addr_slabs = addr_self + layout.slabs;
    self.allocated_size = layout.size;
    // init freelists
    var slab_i: u32 = 0;
    self.global_freelist = Freelist.initAtPtr(addr_self + layout.global_freelist, config.slab_count);

    for (0..@as(usize, config.thread_stack_count)) |i| {
        const ts = self.getThreadStack(@intCast(i));
        ts.count.* = config.thread_stack_size;
        iotaFill(u32, ts.buffer[0..config.thread_stack_size], slab_i);
        slab_i += config.thread_stack_size;
    }

    const res = self.global_freelist.producePriority(config.slab_count - slab_i, slab_i, void, (struct {
        fn cb(ctx_slab_i: u32, view: Freelist.Internal) void {
            iotaFill(u32, view.first, ctx_slab_i);
            iotaFill(u32, view.second, ctx_slab_i + @as(u32, @intCast(view.first.len)));
        }
    }).cb);
    std.debug.assert(res != false);
    
    return self;
}

const ThreadStack = struct {
    count: *usize,
    buffer: [*]u32,

    fn slice(self: ThreadStack) []u32 {
        return self.buffer[0..self.count.*];
    }
    fn pop(self: ThreadStack, buf: []u32) void {
        std.debug.assert(self.count.* >= buf.len);
        @memcpy(buf, self.buffer[self.count.* - buf.len .. self.count.*]);
        self.count.* -= buf.len;
    }
};

fn getThreadStack(self: *Self, thread_idx: u16) ThreadStack {
    std.debug.assert(thread_idx < self.thread_stack_count);
    const addr_thread_stack = self.addr_first_thread_stack + self.off_thread_stack_stride * thread_idx;
    return .{
        .count = @ptrFromInt(addr_thread_stack),
        .buffer = @ptrFromInt(addr_thread_stack + @sizeOf(usize)),
    };
}

pub fn alloc(self: *Self, thread_idx: u16, buf: []u32) bool {
    const stack = self.getThreadStack(thread_idx);
    const spill = buf.len > stack.count.* or buf.len >= self.spill_alloc_threshold;
    if (spill) {
        const count_demand = buf.len;
        const stack_deficit = @as(usize, self.spill_eq_target) -| stack.count.*;
        const count_filled = buf.len + stack_deficit;
        const Ctx = struct {
            buf: []u32,
            stack: ThreadStack,
        };
        const ctx_arg = Ctx{
            .buf = buf,
            .stack = stack,
        };
        const res = self.global_freelist.computeTiered(2, [_]u64{ @intCast(count_filled), @intCast(count_demand) }, ctx_arg, void, struct {
            fn cb(ctx: Ctx, view: Freelist.Internal) void {
                const total_claimed = view.first.len + view.second.len;
                std.debug.assert(total_claimed >= ctx.buf.len);
                if (total_claimed == ctx.buf.len) {
                    copy.twoToOne(u32, ctx.buf, view.first, view.second);
                } else {
                    const count_to_stack = total_claimed - ctx.buf.len;
                    const dest_stack = ctx.stack.buffer[ctx.stack.count.* .. ctx.stack.count.* + count_to_stack];
                    copy.twoToTwo(u32, ctx.buf, dest_stack, view.first, view.second);
                    ctx.stack.count.* += count_to_stack;
                }
            }
        }.cb);
        return res >= @as(u64, count_demand);
    }
    stack.pop(buf);
    return true;
}

pub fn dealloc(self: *Self, thread_idx: u16, buf: []u32) void {
    const stack = self.getThreadStack(thread_idx);
    if (buf.len > self.spill_dealloc_threshold) {
        const res = self.global_freelist.push(buf[0..]);
        std.debug.assert(res);
        return;
    }
    const space_left = self.thread_stack_capacity - stack.count.*;
    if (buf.len > space_left) {
        const stack_deficit = @as(usize, self.spill_eq_target) -| stack.count.*;
        if (stack_deficit > 0) {
            const to_stack = buf[0..@min(stack_deficit, buf.len)];
            const dest = stack.buffer[stack.count.* .. stack.count.* + to_stack.len];
            @memcpy(dest, to_stack);
            stack.count.* += to_stack.len;
            const remaining = buf[to_stack.len..];
            if (remaining.len > 0) {
                const res = self.global_freelist.push(remaining[0..]);
                std.debug.assert(res);
            }
        } else {
            const res = self.global_freelist.push(buf[0..]);
            std.debug.assert(res);
        }
        return;
    }
    const dest = stack.buffer[stack.count.* .. stack.count.* + buf.len];
    @memcpy(dest, buf);
    stack.count.* += buf.len;
}

pub inline fn slabPtr(self: *Self, index: u32) [*]u8 {
    return @ptrFromInt(self.addr_slabs + @as(usize, index) * self.slab_size);
}

pub fn deinit(self: *Self) !void {
    std.debug.assert(self.global_freelist.isStable());
    const slab_count: usize = @intCast(self.global_freelist.capacity);
    const global_count: usize = @intCast(self.global_freelist.estimateCountLower());
    var total: usize = global_count;
    for (0..self.thread_stack_count) |i| {
        const ts = self.getThreadStack(i);
        total += ts.count.*;
    }
    std.debug.assert(total == slab_count);
    try VPA.releaseVirtualRegion(@intFromPtr(self), self.allocated_size);
}
