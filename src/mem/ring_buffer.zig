const std = @import("std");
const builtin = @import("builtin");
/// This backoff is required to prevent contention.
/// In debug mode, it is set to a low value as debug builds already have a lot of overhead.
const INITIAL_BACKOFF = if (builtin.mode == .Debug) 4 else 80;
const BACKOFF_GROWTH_FACTOR = if (builtin.mode == .Debug) 2 else 8;

const PaddedAtomicU64 = struct {
    value: std.atomic.Value(u64),
    _padding: [std.atomic.cache_line - @sizeOf(std.atomic.Value(u64))]u8,
};

/// Thread-safe, MPMC, ring buffer implementation.
/// - Batch operations.
/// - Direct importing from another instance.
/// - No growing.
/// - Conservative safe capacity checks.
pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        capacity: u64,
        producer_claimed: PaddedAtomicU64 align(std.atomic.cache_line),
        producer_published: PaddedAtomicU64 align(std.atomic.cache_line),
        consumer_claimed: PaddedAtomicU64 align(std.atomic.cache_line),
        consumer_published: PaddedAtomicU64 align(std.atomic.cache_line),

        // Continuing in the allocated memory,
        // we store the entries in a buffer with no metadata.

        pub inline fn offsetEntries() usize {
            return comptime std.mem.alignForward(usize, @sizeOf(Self), @alignOf(T));
        }
        pub inline fn entries(self: *Self) [*]T {
            return @ptrFromInt(@intFromPtr(self) + Self.offsetEntries());
        }
        pub fn sizeOf(capacity: u64) usize {
            return @sizeOf(Self) + @sizeOf(T) * capacity;
        }
        pub inline fn alignOf() usize {
            return comptime @max(@alignOf(Self), @alignOf(T));
        }

        pub fn initAtPtr(ptr: [*]u8, capacity: u64) !*Self {
            if (capacity == 0 or capacity & (capacity - 1) != 0) {
                return error.InvalidCapacity; // Must be non-zero and a power of two
            }
            std.debug.assert(std.mem.isAligned(@intFromPtr(ptr), Self.alignOf())); // Ensure the pointer is aligned to the required alignment
            const self = @as(*Self, @ptrCast(@alignCast(ptr)));
            self.* = Self{
                .capacity = capacity,
                .producer_claimed = .{ .value = std.atomic.Value(u64).init(0), ._padding = undefined },
                .producer_published = .{ .value = std.atomic.Value(u64).init(0), ._padding = undefined },
                .consumer_claimed = .{ .value = std.atomic.Value(u64).init(0), ._padding = undefined },
                .consumer_published = .{ .value = std.atomic.Value(u64).init(0), ._padding = undefined },
            };
            return self;
        }
        pub fn initInSlice(buffer: []u8, capacity: u64) !*Self {
            if (capacity == 0 or capacity & (capacity - 1) != 0) {
                return error.InvalidCapacity; // Must be non-zero and a power of two
            }
            if (buffer.len < sizeOf(capacity)) {
                return error.InsufficientBufferSize;
            }
            if (buffer.len != sizeOf(capacity)) {
                std.log.warn("Buffer size exceeds required size for ring buffer, this may waste memory", .{});
            }
            return Self.initAtPtr(buffer.ptr, capacity);
        }

        /// Returns the number of items currently in the ring buffer, not guaranteed to be accurate in a multi-threaded context.
        pub fn estimate_count(self: *Self) u64 {
            // We use saturating subtraction to avoid underflow, in the edge-case where the loads don't form a coherent snapshot.
            // And we subtracted the published producer counter and the claimed consumer counter to get a safer, higher count.
            return self.producer_published.value.load(.monotonic) -| self.consumer_claimed.value.load(.monotonic);
        }

        pub fn push(self: *Self, values: []T) bool {
            const count = @as(u64, @intCast(values.len));
            if (count == 0) return true; // Nothing to do.

            var current_claimed: u64 = undefined;
            var new_claimed: u64 = undefined;
            var backoff: u32 = INITIAL_BACKOFF; // Initial backoff value, can be adjusted for performance tuning.

            const capacity = self.capacity;

            // Phase 1: Claim space
            while (true) {
                current_claimed = self.producer_claimed.value.load(.monotonic);
                const current_consumer_published = self.consumer_published.value.load(.acquire);

                // Handle potential wraparound by ensuring consumer never goes ahead of producer
                if (current_consumer_published > current_claimed) {
                    std.atomic.spinLoopHint();
                    continue;
                }

                const size = current_claimed - current_consumer_published;
                if (size + count > capacity) {
                    return false; // Not enough space.
                }

                new_claimed = current_claimed + count;
                const result = self.producer_claimed.value.cmpxchgWeak(current_claimed, new_claimed, .monotonic, .monotonic);
                if (result == null) break; // Claimed the space, exit the loop.

                // Exponential backoff
                for (0..backoff) |_| {
                    std.atomic.spinLoopHint();
                }
                backoff *|= BACKOFF_GROWTH_FACTOR;
            }

            // Phase 2: Write data to claimed space
            const start_idx = current_claimed & (capacity - 1);
            const end_idx = start_idx + count;

            const usize_start_idx = @as(usize, @intCast(start_idx));
            const usize_end_idx = @as(usize, @intCast(end_idx));
            const usize_capacity = @as(usize, @intCast(capacity));

            if (usize_end_idx <= usize_capacity) {
                @memcpy(self.entries()[usize_start_idx..usize_end_idx], values);
            } else {
                const usize_first_part_len: usize = usize_capacity - usize_start_idx;
                const usize_count = @as(usize, @intCast(count));
                @memcpy(self.entries()[usize_start_idx..usize_capacity], values[0..usize_first_part_len]);
                @memcpy(self.entries()[0..(usize_count - usize_first_part_len)], values[usize_first_part_len..]);
            }

            // Phase 3: Publish data - wait for our turn to publish in order
            while (self.producer_published.value.load(.monotonic) != current_claimed) {
                std.atomic.spinLoopHint();
            }
            self.producer_published.value.store(new_claimed, .release); // Publish the new producer count.

            return true; // Successfullyy pushed.
        }

        /// Pushes as many items as possible from `values` into the ring buffer.
        pub fn push_some(self: *Self, values: []T) u64 {
            const requested_count = @as(u64, @intCast(values.len));
            if (requested_count == 0) return 0; // Nothing to do.

            var current_claimed: u64 = undefined;
            var new_claimed: u64 = undefined;
            var available_count: u64 = undefined;
            var backoff: u32 = INITIAL_BACKOFF; // Initial backoff value, can be adjusted for performance tuning.

            const capacity = self.capacity;

            // Phase 1: Claim space
            while (true) {
                current_claimed = self.producer_claimed.value.load(.monotonic);
                const current_consumer_published = self.consumer_published.value.load(.acquire);

                // Handle potential wraparound by ensuring consumer never goes ahead of producer
                if (current_consumer_published > current_claimed) {
                    std.atomic.spinLoopHint();
                    continue;
                }

                const size = current_claimed - current_consumer_published;
                const available_capacity: u64 = capacity -| size;
                if (available_capacity > 0) {
                    available_count = @min(requested_count, available_capacity); // Adjust count to fit available space
                } else {
                    return 0; // No space available
                }

                new_claimed = current_claimed + available_count;
                const result = self.producer_claimed.value.cmpxchgWeak(current_claimed, new_claimed, .monotonic, .monotonic);
                if (result == null) break; // Claimed the space, exit the loop.

                // Exponential backoff
                for (0..backoff) |_| {
                    std.atomic.spinLoopHint();
                }
                backoff *|= BACKOFF_GROWTH_FACTOR;
            }

            // Phase 2: Write data to claimed space
            const start_idx = current_claimed & (capacity - 1);
            const end_idx = start_idx + available_count;

            // usize for slices and memcpy.
            const usize_start_idx = @as(usize, @intCast(start_idx));
            const usize_end_idx = @as(usize, @intCast(end_idx));
            const usize_capacity = @as(usize, @intCast(capacity));
            const usize_available_count = @as(usize, @intCast(available_count));

            if (end_idx <= capacity) {
                @memcpy(self.entries()[usize_start_idx..usize_end_idx], values[0..usize_available_count]);
            } else {
                const usize_first_part_len: usize = usize_capacity - usize_start_idx;
                @memcpy(self.entries()[usize_start_idx..usize_capacity], values[0..usize_first_part_len]);
                @memcpy(self.entries()[0..(usize_available_count - usize_first_part_len)], values[usize_first_part_len..usize_available_count]);
            }

            // Phase 3: Publish data - wait for our turn to publish in order
            while (self.producer_published.value.load(.monotonic) != current_claimed) {
                std.atomic.spinLoopHint();
            }
            self.producer_published.value.store(new_claimed, .release); // Publish the new producer count.

            return available_count; // Successfully pushed.
        }

        pub fn pop(self: *Self, values: []T) bool {
            const count = @as(u64, @intCast(values.len));
            if (count == 0) return true; // Nothing to do.

            var current_claimed: u64 = undefined;
            var new_claimed: u64 = undefined;
            var backoff: u32 = INITIAL_BACKOFF;

            // Phase 1: Claim items to consume
            while (true) {
                current_claimed = self.consumer_claimed.value.load(.monotonic);
                const current_producer_published = self.producer_published.value.load(.acquire);

                // Handle potential wraparound by ensuring consumer never goes ahead of producer
                if (current_claimed > current_producer_published) {
                    std.atomic.spinLoopHint();
                    continue;
                }

                const size = current_producer_published - current_claimed;
                if (size < count) {
                    return false; // Not enough items to pop.
                }

                new_claimed = current_claimed + count;
                const result = self.consumer_claimed.value.cmpxchgWeak(current_claimed, new_claimed, .monotonic, .monotonic);
                if (result == null) break; // Claimed the items, exit the loop.

                // Exponential backoff
                for (0..backoff) |_| {
                    std.atomic.spinLoopHint();
                }
                backoff *|= BACKOFF_GROWTH_FACTOR;
            }

            // Phase 2: Read data from claimed space
            const capacity = self.capacity;
            const start_idx = current_claimed & (capacity - 1);
            const end_idx = start_idx + count;

            const usize_start_idx = @as(usize, @intCast(start_idx));
            const usize_end_idx = @as(usize, @intCast(end_idx));
            const usize_capacity = @as(usize, @intCast(capacity));

            if (usize_end_idx <= usize_capacity) {
                @memcpy(values, self.entries()[usize_start_idx..usize_end_idx]);
            } else {
                const usize_first_part_len = usize_capacity - usize_start_idx;
                const usize_count = @as(usize, @intCast(count));
                @memcpy(values[0..usize_first_part_len], self.entries()[usize_start_idx..usize_capacity]);
                @memcpy(values[usize_first_part_len..], self.entries()[0..(usize_count - usize_first_part_len)]);
            }

            // Phase 3: Publish consumption - wait for our turn to publish in order
            while (self.consumer_published.value.load(.monotonic) != current_claimed) {
                std.atomic.spinLoopHint();
            }
            self.consumer_published.value.store(new_claimed, .release); // Publish the consumption.

            return true; // Successfully popped.
        }

        /// Pops up to `values.len` items from the ring buffer.
        /// Returns the number of items actually popped. This can be less than `values.len` if the buffer contains fewer items.
        pub fn pop_some(self: *Self, values: []T) u64 {
            const requested_count = @as(u64, @intCast(values.len));
            if (requested_count == 0) return 0;

            var current_claimed: u64 = undefined;
            var new_claimed: u64 = undefined;
            var available_count: u64 = undefined;
            var backoff: u32 = INITIAL_BACKOFF;

            // Phase 1: Claim available items
            while (true) {
                current_claimed = self.consumer_claimed.value.load(.monotonic);
                const current_producer_published = self.producer_published.value.load(.acquire);

                if (current_claimed > current_producer_published) {
                    std.atomic.spinLoopHint();
                    continue;
                }

                const available_items = current_producer_published - current_claimed;
                if (available_items == 0) {
                    return 0; // Buffer is empty
                }

                available_count = @min(requested_count, available_items);

                new_claimed = current_claimed + available_count;
                const result = self.consumer_claimed.value.cmpxchgWeak(current_claimed, new_claimed, .monotonic, .monotonic);
                if (result == null) break; // Claimed items, exit loop

                // Exponential backoff on contention
                for (0..backoff) |_| {
                    std.atomic.spinLoopHint();
                }
                backoff *|= BACKOFF_GROWTH_FACTOR;
            }

            // Phase 2: Read data from claimed space
            const capacity = self.capacity;
            const start_idx = current_claimed & (capacity - 1);
            const end_idx = start_idx + available_count;

            const usize_start_idx = @as(usize, @intCast(start_idx));
            const usize_end_idx = @as(usize, @intCast(end_idx));
            const usize_available_count = @as(usize, @intCast(available_count));
            const usize_capacity = @as(usize, @intCast(capacity));

            if (usize_end_idx <= usize_capacity) {
                @memcpy(values[0..usize_available_count], self.entries()[usize_start_idx..usize_end_idx]);
            } else {
                const usize_first_part_len = usize_capacity - usize_start_idx;
                @memcpy(values[0..usize_first_part_len], self.entries()[usize_start_idx..usize_capacity]);
                @memcpy(values[usize_first_part_len..usize_available_count], self.entries()[0..(usize_available_count - usize_first_part_len)]);
            }

            // Phase 3: Publish consumption
            while (self.consumer_published.value.load(.monotonic) != current_claimed) {
                std.atomic.spinLoopHint();
            }
            self.consumer_published.value.store(new_claimed, .release);

            return available_count;
        }

        /// Imports all items from another ring buffer instance.
        /// Returns `true` if the import was successful, `false` if there was not enough space.
        /// The source buffer must not be modified while this operation is in progress.
        pub fn import(self: *Self, src: *Self) bool {
            const src_consumer = src.consumer_published.value.load(.acquire);
            const src_producer = src.producer_published.value.load(.acquire);
            const src_len = src_producer - src_consumer;

            if (src_len == 0) {
                return true; // Nothing to import
            }

            var self_claimed: u64 = undefined;
            var new_claimed: u64 = undefined;
            var backoff: u32 = INITIAL_BACKOFF;

            const self_capacity = self.capacity;
            const src_capacity = @as(u64, @intCast(src.capacity));

            // Phase 1: Claim space for import
            while (true) {
                self_claimed = self.producer_claimed.value.load(.monotonic);
                const self_consumer = self.consumer_published.value.load(.monotonic);

                // Handle potential wraparound by ensuring consumer never goes ahead of producer
                if (self_consumer > self_claimed) {
                    std.atomic.spinLoopHint();
                    continue;
                }

                const self_size = self_claimed - self_consumer;
                if (self_size + src_len > self_capacity) {
                    return false; // Not enough space.
                }

                new_claimed = self_claimed + src_len;
                const result = self.producer_claimed.value.cmpxchgWeak(self_claimed, new_claimed, .monotonic, .monotonic);
                if (result == null) break; // Claimed the space, exit the loop.

                // Exponential backoff
                for (0..backoff) |_| {
                    std.atomic.spinLoopHint();
                }
                backoff *|= BACKOFF_GROWTH_FACTOR;
            }

            // Phase 2: Copy data
            var src_idx = src_consumer & (src_capacity - 1);
            var self_idx = self_claimed & (self_capacity - 1);

            var remaining = src_len;
            while (remaining > 0) {
                const src_chunk_size: u64 = @min(remaining, src_capacity - src_idx);
                const self_chunk_size: u64 = @min(remaining, self_capacity - self_idx);
                const items_to_copy: u64 = @min(src_chunk_size, self_chunk_size);

                const usize_self_idx = @as(usize, @intCast(self_idx));
                const usize_src_idx = @as(usize, @intCast(src_idx));
                const usize_items_to_copy = @as(usize, @intCast(items_to_copy));

                @memcpy(
                    self.entries()[usize_self_idx .. usize_self_idx + usize_items_to_copy],
                    src.entries()[usize_src_idx .. usize_src_idx + usize_items_to_copy],
                );

                src_idx = (src_idx + items_to_copy) & (src_capacity - 1);
                self_idx = (self_idx + items_to_copy) & (self_capacity - 1);
                remaining -= items_to_copy;
            }

            // Phase 3: Publish in order
            while (self.producer_published.value.load(.monotonic) != self_claimed) {
                std.atomic.spinLoopHint();
            }
            self.producer_published.value.store(new_claimed, .release); // Publish the import.

            return true; // Successfully imported.
        }
    };
}
