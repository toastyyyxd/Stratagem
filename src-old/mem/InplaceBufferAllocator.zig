const std = @import("std");

/// Very minimal bump or reset allocator that allows committing and decommitting memory,
/// for use with the VirtualPageAllocator.
pub const InplaceBufferAllocator = struct {
    const Self = @This();

    ptr: [*]u8,
    end_index: usize,
    capacity: usize,

    pub fn init(ptr: [*]u8, capacity: usize) Self {
        std.debug.assert(capacity > 0);
        return Self{
            .ptr = ptr,
            .end_index = 0,
            .capacity = capacity,
        };
    }
    pub fn commit(self: *Self, new_capacity: usize) void {
        std.debug.assert(new_capacity > self.capacity);
        if (new_capacity <= self.capacity) return;
        self.capacity = new_capacity;
    }
    pub fn decommit(self: *Self, new_capacity: usize) void {
        if (new_capacity >= self.capacity) return;
        std.debug.assert(self.end_index <= new_capacity);
        self.end_index = @min(self.end_index, new_capacity);
        self.capacity = new_capacity;
    }
    pub fn decommitUnsafe(self: *Self, new_capacity: usize) void {
        if (new_capacity >= self.capacity) return;
        self.end_index = @min(self.end_index, new_capacity);
        self.capacity = new_capacity;
    }
    pub fn reset(self: *Self) void {
        self.end_index = 0;
    }

    // std.mem.Allocator interface
    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{ .ptr = @ptrCast(@alignCast(self)), .vtable = &.{
            .alloc = alloc,
            .free = std.mem.Allocator.noFree,
            .remap = std.mem.Allocator.noRemap,
            .resize = std.mem.Allocator.noResize,
        } };
    }
    pub fn threadSafeAllocator(self: *Self) std.mem.Allocator {
        return .{ .ptr = @ptrCast(@alignCast(self)), .vtable = &.{
            .alloc = threadSafeAlloc,
            .free = std.mem.Allocator.noFree,
            .remap = std.mem.Allocator.noRemap,
            .resize = std.mem.Allocator.noResize,
        } };
    }

    pub fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = ra; // return address, unused.
        const alignment_bytes = alignment.toByteUnits();
        const aligned_end_index = std.mem.alignForward(usize, self.end_index, alignment_bytes);
        const new_end_index = aligned_end_index + n;
        if (new_end_index > self.capacity) return null; // OOM
        self.end_index = new_end_index;
        return self.ptr[aligned_end_index..];
    }
    pub fn threadSafeAlloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = ra;
        const alignment_bytes = alignment.toByteUnits();
        var end_index = @atomicLoad(usize, &self.end_index, .seq_cst);
        while (true) {
            const aligned_end_index = std.mem.alignForward(usize, end_index, alignment_bytes);
            const new_end_index = aligned_end_index + n;
            if (new_end_index > self.capacity) return null; // OOM
            end_index = @cmpxchgWeak(usize, &self.end_index, end_index, new_end_index, .seq_cst, .seq_cst) orelse
                return self.ptr[aligned_end_index..];
        }
    }
};
