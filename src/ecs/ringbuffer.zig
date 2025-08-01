const std = @import("std");

/// Thread-safe, MPMC, ring buffer implementation
/// - Power-of-two capacities only.
/// - Batch operations.
/// - Direct importing from another instance.
/// - No growing, no capacity checks, no empty or full checks.
pub fn RingBuffer(T: type) type {
    return struct {
        const Self = @This();
        entries: []T,
        producer_counter: std.atomic.Value(u64),
        consumer_counter: std.atomic.Value(u64),
        capacity: u32,
        pub fn init_at_ptr(ptr: *u8, capacity: u32) *Self {
            const self_ptr = @as(Self, @ptrCast(ptr));
            self_ptr.* = Self{
                .entries = @as([]T, @ptrCast(ptr + @sizeOf(Self))),
                .producer_counter = std.atomic.Value(u64).init(0),
                .consumer_counter = std.atomic.Value(u64).init(0),
                .capacity = capacity,
            };
            return self_ptr;
        }
        pub fn init(al: std.heap.Allocator, capacity: u32) !*Self {
            if (capacity == 0 or capacity & (capacity - 1) != 0) {
                return error.InvalidCapacity; // Must be a power of two
            }
            const size = @sizeOf(Self) + @sizeOf(T) * capacity;
            const ptr = try al.alloc(u8, size);
            return Self.init_at_ptr(ptr, capacity);
        }
        pub fn deinit(self: *Self, al: std.heap.Allocator) void {
            al.free(@ptrCast(self));
        }

        pub fn push(self: *Self, values: []T) void {
            const capacity = self.capacity;
            const start_idx = self.producer_counter.fetchAdd(values.len, .acq_rel) & (capacity - 1);
            const end_idx = start_idx + @as(u64, @intCast(values.len));

            if (end_idx <= capacity) {
                @memcpy(self.entries[start_idx..end_idx], values);
            } else {
                const first_part_len = capacity - start_idx;
                @memcpy(self.entries[start_idx..capacity], values[0..first_part_len]);
                @memcpy(self.entries[0..(@as(u64, @intCast(values.len)) - first_part_len)], values[first_part_len..]);
            }
        }
        pub fn pop(self: *Self, values: []T) void {
            const count = @as(u64, @intCast(values.len));
            const capacity = @as(u64, @intCast(self.capacity));
            const start_idx = self.consumer_counter.fetchAdd(count, .acq_rel) & (capacity - 1);
            const end_idx = start_idx + @as(u64, @intCast(count));

            if (end_idx <= capacity) {
                @memcpy(values, self.entries[start_idx..end_idx]);
            } else {
                const first_part_len = capacity - start_idx;
                @memcpy(values, self.entries[start_idx..capacity]);
                @memcpy(values[first_part_len..], self.entries[0..(@as(u64, @intCast(count)) - first_part_len)]);
            }
        }

        /// Ensure that the other is in a consistent state before importing.
        /// This omits atomic operations on the source buffer.
        pub fn import(self: *Self, src: *Self) void {
            const src_start_idx = @as(u64, src.consumer_counter) & (src.capacity - 1);
            const src_end_idx = @as(u64, src.producer_counter) & (src.capacity - 1);
            const src_len = @as(u64, src.producer_counter) - @as(u64, src.consumer_counter);
            if (src_len == 0) {
                return; // Nothing to import
            }

            const self_free_start_idx = self.producer_counter.fetchAdd(src_len, .acq_rel) & (self.capacity - 1);
            const self_res_end_idx = (self_free_start_idx + src_len) & (self.capacity - 1);

            const src_wraps = src_end_idx < src_start_idx;
            const self_hasto_wrap = self_res_end_idx < self_free_start_idx;

            if (!src_wraps) {
                if (!self_hasto_wrap) {
                    @memcpy(self.entries[self_free_start_idx..self_res_end_idx], src.entries[src_start_idx..src_end_idx]);
                } else {
                    const self_first_part_len = self.capacity - self_free_start_idx;
                    @memcpy(self.entries[self_free_start_idx .. self_free_start_idx + self_first_part_len], src.entries[src_start_idx .. src_start_idx + self_first_part_len]);
                    @memcpy(self.entries[0..self_res_end_idx], src.entries[src_start_idx + self_first_part_len .. src_end_idx]);
                }
            } else {
                if (!self_hasto_wrap) {
                    const src_first_part_len = src.capacity - src_start_idx;
                    @memcpy(self.entries[self_free_start_idx .. self_free_start_idx + src_first_part_len], src.entries[src_start_idx .. src_start_idx + src_first_part_len]);
                    @memcpy(self.entries[self_free_start_idx + src_first_part_len .. self_res_end_idx], src.entries[src_start_idx + src_first_part_len .. src_end_idx]);
                } else {
                    // Both wrap.
                    const self_first_part_len = self.capacity - self_free_start_idx;
                    const src_first_part_len = src.capacity - src_start_idx;
                    // Let's see if we have enough space in self's first part to fit src's first part.
                    // If yes:
                    // - we copy the entire first part of src into self's first part
                    // - we copy the first part of src's second part into self's second part
                    // - we copy the second part of src into self's second part
                    // If not:
                    // - we copy the first part of src that fits into self's first part
                    // - we copy the rest of src's first part into self's second part
                    // - we copy the second part of src into self's second part
                    if (self_first_part_len >= src_first_part_len) {
                        // Enough space in self's first part.
                        @memcpy(self.entries[self_free_start_idx .. self_free_start_idx + src_first_part_len], src.entries[src_start_idx .. src_start_idx + src_first_part_len]);
                        const src_second_part_that_fits = src_end_idx - (src_start_idx + src_first_part_len);
                        if (src_second_part_that_fits > 0) { // We could skip since it could be 0 if `=` in `>=` applied in the previous condition
                            @memcpy(self.entries[self_free_start_idx + src_first_part_len .. self_res_end_idx], src.entries[0..src_second_part_that_fits]);
                        }
                        @memcpy(self.entries[0 .. self_res_end_idx - src_first_part_len - src_second_part_that_fits], src.entries[src_second_part_that_fits..src_end_idx]);
                    } else {
                        // Not enough space in self's first part.
                        @memcpy(self.entries[self_free_start_idx .. self_free_start_idx + self_first_part_len], src.entries[src_start_idx .. src_start_idx + self_first_part_len]);
                        const src_remaining_first_part = src_first_part_len - self_first_part_len;
                        // No need for `if` here, since `src_remaining_first_part` is always > 0 as the previous condition was false.
                        @memcpy(self.entries[0..src_remaining_first_part], src.entries[src_start_idx + self_first_part_len .. src_start_idx + src_first_part_len + src_remaining_first_part]);
                        @memcpy(self.entries[src_remaining_first_part..self_res_end_idx], src.entries[0..src_end_idx]);
                    }
                }
            }
        }
    };
}
