const std = @import("std");
const allocator = @import("./allocator.zig");
const OptionalU32 = @import("./unmanaged_optional.zig").OptionalU32;
const Optional = @import("./unmanaged_optional.zig").Optional;
const xev = @import("../main.zig").xev;
const loop = @import("../main.zig").get_loop();
const thread_pool = @import("../main.zig").get_thread_pool();

pub const SlabSize = 16 * 1024; // 16kb per slab

pub const Slab = [SlabSize]u8;

/// The core heap for fast, multithreaded allocation of memory.
/// It is a fixed-size slab allocator that uses a virtual memory region to prevent ext fragmentation.
/// Allocations are always batched and return a xev.Completion to start the allocation.
pub const CoreHeap = struct {
    ptr: *u8,
    reserved_byte_len: usize,
    capacity_state: std.atomic.Value(CapacityState),
    /// State of the grow state machine. Also used to track if a grow is in progress.
    grow_state: std.atomic.Value(?Grow),
    /// Tracks how many slabs are queued for growth while the first grow is in progress.
    grow_deficit: std.atomic.Value(u32),
    /// The threshold for when to grow the heap, in n/100 percentage of free slabs remaining.
    free_grow_threshold: u8,

    const CapacityState = packed struct {
        last_capacity: u32,
        capacity: u32,
        pub fn getCurrent(self: *const CapacityState) u32 {
            return self.capacity;
        }
        pub fn getLast(self: *const CapacityState) u32 {
            return self.last_capacity;
        }
        pub fn iterateNew(self: *const CapacityState, new_capacity: u32) CapacityState {
            return CapacityState{
                .last_capacity = self.getCurrent(),
                .capacity = new_capacity,
            };
        }
    };
    const Field = enum {
        Slabs, // Slab
        FreeSlabIndicesLen, // u32 (atomic)
        FreeSlabIndices, // []u32
        EndByte, // This is not a field, just a marker for the end of the buffer
    };

    fn fieldOffset(cap_state: *const CapacityState, field: Field) usize {
        var offset: usize = 0;
        offset = std.mem.alignForward(usize, offset, @alignOf(Slab));
        if (field == .Slabs) return offset;
        offset += @sizeOf(Slab) * @as(usize, @intCast(cap_state.getCurrent()));
        offset = std.mem.alignForward(usize, offset, @alignOf(u32));
        if (field == .FreeSlabIndicesLen) return offset;
        offset += @sizeOf(u32);
        offset = std.mem.alignForward(usize, offset, @alignOf(u32));
        if (field == .FreeSlabIndices) return offset;
        offset += @sizeOf([*]u32) * @as(usize, @intCast(cap_state.getCurrent()));
        // Align to bytes for the end, could be used for getting the entire buffer.
        offset = std.mem.alignForward(usize, offset, @alignOf(u8));
        if (field == .EndByte) return offset;
        std.debug.panic("Invalid field requested: index {}", .{@intFromEnum(field)});
    }
    fn fieldRange(ptr: *const u8, cap_state: *const CapacityState, field: Field) []u8 {
        const start = CoreHeap.fieldOffset(cap_state, field);
        const next_field = @as(Field, @enumFromInt(@intFromEnum(field) + 1));
        const end = CoreHeap.fieldOffset(cap_state, next_field);
        return @as([*]u8, @constCast(@alignCast(@ptrCast(ptr))))[start..end];
    }

    pub fn init(target_capacity: u32, target_reserved_capacity: u32, free_grow_threshold: u8) !CoreHeap {
        const capacity = try std.math.ceilPowerOfTwo(u32, target_capacity);
        const reserved_capacity = try std.math.ceilPowerOfTwo(u32, target_reserved_capacity);
        const max_cap_state = CapacityState{
            .capacity = reserved_capacity,
            .last_capacity = capacity,
        };
        const reserved_byte_len = std.mem.alignForward(usize, CoreHeap.fieldOffset(&max_cap_state, .EndByte), allocator.page_size);
        const ptr = try allocator.reserveVirtualRegion(reserved_byte_len);
        var heap = CoreHeap{
            .ptr = ptr,
            .reserved_byte_len = reserved_byte_len,
            .capacity_state = std.atomic.Value(CapacityState).init(CapacityState{
                .capacity = capacity,
                .last_capacity = capacity,
                .free_grow_threshold = free_grow_threshold,
            }),
            .grow_state = std.atomic.Value(bool).init(false),
        };
        heap.initHeader();
        return heap;
    }
    fn initHeader(self: *CoreHeap) void {
        const cap_state = self.capacity_state.load(.acquire);
        const headerStart = fieldOffset(&cap_state, .FreeSlabIndicesLen);
        const headerEnd = fieldOffset(&cap_state, .EndByte);
        @memset(@as([*]u8, @alignCast(@ptrCast(self.ptr)))[headerStart..headerEnd], 0); // Zero out the header region.
        // Initialize free arrays
        const freeSlabIndices = @as([*]u32, @alignCast(@ptrCast(fieldRange(self.ptr, &cap_state, .FreeSlabIndices))));
        for (freeSlabIndices, 0..cap_state.getCurrent()) |*indice, i| {
            indice.* = @as(u32, @intCast(i));
        }
        // Set the lengths of the free array, no need to use atomics here since this is the initialization phase
        @as(*u32, @alignCast(@ptrCast(fieldRange(self.ptr, &cap_state, .FreeSlabIndicesLen)))).* = cap_state.getCurrent();
    }
    pub fn deinit(self: *CoreHeap) !void {
        try allocator.releaseVirtualRegion(self.ptr, self.reserved_byte_len);
    }

    /// This not a full state machine.
    const Grow = struct {
        state: GrowState,
        heap: *CoreHeap,
        new_capacity: u32,
    };
    fn growCompletion(state: *Grow, _: *xev.Sys.Loop, _: *xev.Sys.Completion, _: xev.Sys.Result) xev.CallbackAction {
        const self = state.heap;
        self.grow(state.new_capacity) catch |err| {
            std.debug.panic("Failed to grow heap: {}", .{err});
            unreachable;
        };
        return .disarm;
    }
    fn resumeAllocate(state: *AllocationState, _: *xev.Sys.Loop, _: *xev.Sys.Completion, _: xev.Sys.Result) xev.CallbackAction {
        const self = state.heap;
        const cap_state = self.capacity_state.load(.acquire);
        const free_indices_len = @as(*std.atomic.Value(u32), @alignCast(@ptrCast(fieldRange(self.ptr, &cap_state, .FreeSlabIndicesLen)))).fetchSub(state.n_slabs, .acq_rel);
        const target_indices = @as([]u32, @alignCast(@ptrCast(fieldRange(self.ptr, &cap_state, .FreeSlabIndices))))[free_indices_len - state.n_slabs .. free_indices_len];
        const slabs = @as([]Slab, @alignCast(@ptrCast(fieldRange(self.ptr, &cap_state, .Slabs))))[target_indices..];
        //std.debug.print("Allocating Slab ptr: {*}, Index: {}\n", .{ slab, free_indice });
        state.slabs = slabs;
        return .disarm;
    }

    pub fn allocateSlabBatch(self: *CoreHeap, n_slabs: u32) ![]Slab {
        const cap_state = self.capacity_state.load(.acquire);
        const free_indices_len = @as(*std.atomic.Value(u32), @alignCast(@ptrCast(fieldRange(self.ptr, &cap_state, .FreeSlabIndicesLen)))).fetchSub(n_slabs, .acq_rel);
        if (free_indices_len * 100 <= cap_state.getCurrent() * self.free_grow_threshold) {
            @branchHint(.unlikely);
            const c = xev.Sys.Completion{
                .callback = *self.growCompletion,
                .userdata = &Grow{
                    .heap = self,
                    .new_capacity = cap_state.getCurrent() + n_slabs,
                },
            };
            return c;
        } else {
            @branchHint(.likely);
            unreachable; // TODO: ahh
        }
    }

    pub fn allocateSlab(self: *CoreHeap) !*Slab {
        const cap_state = self.capacity_state.load(.acquire);
        const free_indices_len = @as(*std.atomic.Value(u32), @alignCast(@ptrCast(fieldRange(self.ptr, &cap_state, .FreeSlabIndicesLen)))).fetchSub(1, .acq_rel);
        const free_indice = @as([]u32, @alignCast(@ptrCast(fieldRange(self.ptr, &cap_state, .FreeSlabIndices))))[free_indices_len - 1];
        const slab = &@as([]Slab, @alignCast(@ptrCast(fieldRange(self.ptr, &cap_state, .Slabs))))[free_indice];
        //std.debug.print("Allocating Slab ptr: {*}, Index: {}\n", .{ slab, free_indice });
        return slab;
    }
    pub fn deallocateSlab(self: *CoreHeap, slab: *Slab) !void {
        const cap_state = self.capacity_state.load(.acquire);
        const slab_index = @as(u32, @truncate((@as(usize, @intFromPtr(slab)) - @as(usize, @intFromPtr(self.ptr))) / SlabSize));
        const free_indices_len = @as(*std.atomic.Value(u32), @alignCast(@ptrCast(fieldRange(self.ptr, &cap_state, .FreeSlabIndicesLen)))).fetchAdd(1, .acq_rel);
        @as([]u32, @alignCast(@ptrCast(fieldRange(self.ptr, &cap_state, .FreeSlabIndices))))[free_indices_len] = slab_index;
        //std.debug.print("Deallocating Slab ptr: {*}, Index: {}\n", .{ slab, slab_index });
    }

    pub fn grow(self: *CoreHeap, new_target_capacity: u32) !void {
        if (self.grow_state.cmpxchgStrong(false, true, .acq_rel, .acquire) == true) return error.MigrationInProgress;
        defer self.grow_state.store(false, .release); // Ensure we reset the migrating state on exit.

        const old_cap_state = self.capacity_state.load(.acquire);
        const new_capacity = try std.math.ceilPowerOfTwo(u32, new_target_capacity);
        const new_cap_state = old_cap_state.iterateNew(new_capacity);
        if (new_capacity <= old_cap_state.getCurrent()) return error.CapacityNotIncreased;
        if (fieldOffset(&new_cap_state, .EndByte) > self.reserved_byte_len) return error.CapacityExceedsReserved;

        // ### Commit the reserved region to the new capacity.
        const commit_start = @as(*u8, @ptrFromInt(std.mem.alignBackward(usize, @intFromPtr(self.ptr) + fieldOffset(&old_cap_state, .EndByte), allocator.page_size)));
        const commit_size = std.mem.alignForward(usize, fieldOffset(&new_cap_state, .EndByte) - fieldOffset(&old_cap_state, .EndByte), allocator.page_size);
        try allocator.commitVirtualPages(commit_start, commit_size);

        // ### Initialize only the new header region for the increased capacity,
        // ### ensuring no overlap or conflict with the old header.
        // We *MUST* ensure the slabs are not overlapping with the old header.
        // The new header shouldn't overlap with the old header, unless we're doing
        // something stupid like growing the capacity to the same size or by a very small amount.
        std.debug.assert(fieldOffset(&new_cap_state, .FreeSlabIndicesLen) >= fieldOffset(&old_cap_state, .EndByte));
        const new_header_start_offset = fieldOffset(&new_cap_state, .FreeSlabIndicesLen);
        const new_header_end_offset = fieldOffset(&new_cap_state, .EndByte);
        @memset(@as([*]u8, @alignCast(@ptrCast(self.ptr)))[new_header_start_offset..new_header_end_offset], 0);

        // ### Initialize free arrays for the new capacity.
        // Realistically, the old end is always going to be more than the new start which is 0,
        // but we do this for clearness.
        const safe_slabs_start_offset = @max(fieldOffset(&old_cap_state, .EndByte), fieldOffset(&new_cap_state, .Slabs));
        // Align to the next slab, for the slabs, so no need to align to a slab again.
        const safe_slabs_start_aligned_offset = std.mem.alignForward(usize, safe_slabs_start_offset, @alignOf(Slab));
        const unsafe_slabs_start_offset = fieldOffset(&new_cap_state, .Slabs);
        //const unsafe_slabs_end_offset = fieldOffset(&new_cap_state, .FreeSlabIndicesLen);

        // Calculate the free indices start from the slabs start pointer.
        const unsafe_free_indices_start_index = @as(u32, @truncate(unsafe_slabs_start_offset / @sizeOf(Slab))); // The start in indices, not bytes.
        const safe_free_indices_start_index = @as(u32, @truncate(safe_slabs_start_aligned_offset / @sizeOf(Slab))); // The safe start in indices, not bytes.
        // Calculate the free indices end, because we have to take account for a worst/edge case where
        // all old capacity is suddenly deallocated, and we must store the freed indices in the new header.
        const safe_free_indices_end_index = safe_free_indices_start_index + (new_cap_state.getCurrent() - new_cap_state.getLast()); // not bytes.
        // Calculate the start pointer for the free slab indices, only in the safe region,
        // we do *not* touch anything outside the safe region, not even reading it.
        const safe_free_indices_start_offset = fieldOffset(&new_cap_state, .FreeSlabIndices) + safe_free_indices_start_index * @sizeOf(u32);

        const safe_free_slab_indices_array = @as([*]u32, @ptrFromInt(@intFromPtr(self.ptr) + safe_free_indices_start_offset));
        for (safe_free_slab_indices_array, 0..safe_free_indices_end_index) |*indice, i| {
            indice.* = @as(u32, @intCast(i));
        }
        // Set the lengths of the free array, no need to use atomics here since this is the initialization phase
        @as(*u32, @alignCast(@ptrCast(fieldRange(self.ptr, &new_cap_state, .FreeSlabIndicesLen)))).* = safe_free_indices_end_index;

        // TODO: keep going with the double buffered switch
        // ### First, we update the capacity state atomically.
        self.capacity_state.store(new_cap_state, .release);

        // Now that everyone is using the new capacity state, and by extension, the new header,
        // we can begin filtering and copying over the old free indices *if they are still free*.
        // This will be slower than a direct copy, but it ensures we don't have to worry about
        // adding duplicate free indices. This is fine since this is not blocking.
        const old_free_indices_array = @as([*]u32, @alignCast(@ptrCast(fieldRange(self.ptr, &old_cap_state, .FreeSlabIndices))));
        // No atomicity here, since nobody else is using the old header anymore.
        const old_free_indices_len = @as(*u32, @alignCast(@ptrCast(fieldRange(self.ptr, &old_cap_state, .FreeSlabIndicesLen)))).*;
        const new_free_indices_len_atomic = @as(*std.atomic.Value(u32), @alignCast(@ptrCast(fieldRange(self.ptr, &new_cap_state, .FreeSlabIndicesLen))));

        // NOTE: It is IMPOSSIBLE for a free slab indice to appear in both old and new arrays:
        // - Here, we only migrate indices from the old array that are present at the time of the switch.
        // - We never initialize the new array with indices that were already present in the old array.
        // - After the switch, all new deallocations add indices only to the new array.
        // - Even if a slab with an old indice is dealloced into the new array, it will not be
        //   present in the old array, because it was allocated and not in the old array!
        const dest_index = new_free_indices_len_atomic.fetchAdd(old_free_indices_len, .acq_rel);
        @memcpy(safe_free_slab_indices_array[dest_index .. dest_index + old_free_indices_len], old_free_indices_array[0..old_free_indices_len]);

        // ### Finally, we can free the old header region.
        for (unsafe_free_indices_start_index..safe_free_indices_start_index) |indice| {
            safe_free_slab_indices_array[new_free_indices_len_atomic.fetchAdd(1, .acq_rel)] = @as(u32, @truncate((indice)));
        }
    }
};
