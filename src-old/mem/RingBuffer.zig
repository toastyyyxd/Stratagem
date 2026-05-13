const std = @import("std");
const assert = std.debug.assert;
const builtin = std.builtin;
const Type = builtin.Type;
const Writer = std.Io.Writer;
const atomic = std.atomic;
const mem = std.mem;
const simd = std.simd;
const math = std.math;
const zig_serializer = @import("../utils/zig_serializer.zig");

const Top = @This();

// probably should tune this some time but these do suffice
const INITIAL_BACKOFF = if (builtin.mode == .Debug) 4 else 80;
const BACKOFF_GROWTH_FACTOR = if (builtin.mode == .Debug) 2 else 8;
fn execBackoff(backoff: *usize) void {
    var i: usize = 0;
    while (i < backoff.*) : (i += 1) std.atomic.spinLoopHint();
    if (backoff.* < 1024) backoff.* *= BACKOFF_GROWTH_FACTOR;
}

// exposed enums
const Concurrency = enum { mpmc, mpsc, spmc, spsc };
const Ordering = enum {
    /// First in first out, benefits from batching, suffers from high contention at small batches.
    fifo,
    /// Per-item sequence atomic, magnitudes faster with tiny batches, slower otherwise. Uses more memory for the sequence array.
    unordered,
};
const Structure = enum { aos, soa };

// internal enums
const Role = enum {
    producer,
    consumer,
    pub fn isMulti(comptime self: Role, comptime config: Config) bool {
        return if (config.ordering == .unordered) false else switch (config.concurrency) {
            .mpmc => true,
            .mpsc => self == .producer,
            .spmc => self == .consumer,
            .spsc => false,
        };
    }
    pub fn flip(comptime self: Role) Role {
        return if (self == .producer) .consumer else .producer;
    }
};
const State = enum { claimed, published };
const ClaimMode = enum { exact, partial };

// @typeinfo abstraction
const Field = struct {
    name: [:0]const u8,
    FieldType: type,
    size: usize,
    alignment: usize,
};

// types
pub fn View(comptime ItemT: type) type {
    return struct { first: []ItemT, second: []ItemT };
}
fn SliceMutable(comptime ItemT: type) type {
    return []ItemT;
}
fn SliceImmutable(comptime ItemT: type) type {
    return []const ItemT;
}
fn InSoA(fields: []const Field, comptime Generic: *const fn (T: type) type) type {
    var n: [fields.len][:0]const u8 = undefined;
    var t: [fields.len]type = undefined;
    var a: [fields.len]Type.StructField.Attributes = undefined;
    for (fields, 0..) |f, i| {
        const M = Generic(f.FieldType);
        n[i] = f.name;
        t[i] = M;
        a[i] = Type.StructField.Attributes{
            .@"align" = @alignOf(M),
            .@"comptime" = false,
            .default_value_ptr = null,
        };
    }
    return @Struct(.auto, null, &n, &t, &a);
}

// config
pub const Config = struct {
    Item: type,
    structure: Structure,
    concurrency: Concurrency,
    ordering: Ordering,
    ExternalMutable: type = void, // []T or struct { field: []FieldT }
    ExternalImmutable: type = void, // []const T or struct { field: []const FieldT }
    Internal: type = void, // View(config.Item) or struct { field: View(config.Item) }
};

pub fn RingBuffer(comptime config: Config) type {
    const comptime_item_fields_len = switch (config.structure) {
        .aos => 1,
        .soa => @typeInfo(config.Item).@"struct".fields.len,
    };
    assert(comptime_item_fields_len > 0);

    comptime var comptime_item_fields: [comptime_item_fields_len]Field = undefined;
    if (config.structure == .aos) {
        comptime_item_fields[0] = .{ .name = "array", .FieldType = config.Item, .size = @sizeOf(config.Item), .alignment = @alignOf(config.Item) };
    } else {
        const struct_fields = @typeInfo(config.Item).@"struct".fields;
        for (struct_fields, 0..) |f, i| {
            comptime_item_fields[i] = .{ .name = f.name, .FieldType = f.type, .size = @sizeOf(f.type), .alignment = @alignOf(f.type) };
        }
    }

    if (config.Internal == void or
        config.ExternalMutable == void or
        config.ExternalImmutable == void) @compileError(std.fmt.comptimePrint(
        \\Use these generated types in your ring buffer Config after double-checking.
        \\Ensure your code imports RingBuffer.View and other type names found below.
        \\/// Auto-generated with zig_serializer.
        \\{s}
        \\/// Auto-generated with zig_serializer.
        \\{s}
        \\/// Auto-generated with zig_serializer.
        \\{s}
    , .{
        zig_serializer.generateDecl(
            "ExternalMutable",
            switch (config.structure) {
                .aos => SliceMutable(config.Item),
                .soa => InSoA(&comptime_item_fields, &SliceMutable),
            },
            .{},
        ),
        zig_serializer.generateDecl(
            "ExternalImmutable",
            switch (config.structure) {
                .aos => SliceImmutable(config.Item),
                .soa => InSoA(&comptime_item_fields, &SliceImmutable),
            },
            .{},
        ),
        zig_serializer.generateDecl(
            "Internal",
            switch (config.structure) {
                .aos => View(config.Item),
                .soa => InSoA(&comptime_item_fields, &View),
            },
            .{},
        ),
    }));

    const comptime_aligned_counter_size = mem.alignForward(usize, @sizeOf(atomic.Value(u64)), atomic.cache_line);
    comptime var comptime_counters_len: usize = 0;
    const possible_states = std.meta.tags(State);
    for (std.meta.tags(Role)) |role| {
        if (role.isMulti(config)) {
            comptime_counters_len += possible_states.len;
        } else {
            comptime_counters_len += 1;
        }
    }

    return struct {
        // hoist comptime into scope
        const item_fields_len = comptime_item_fields_len;
        const item_fields = comptime_item_fields;
        const aligned_counter_size = comptime_aligned_counter_size;
        const counters_len = comptime_counters_len;
        
        // typing
        const Self = @This();
        const Item = config.Item;
        pub const Internal = config.Internal;
        pub const ExternalImmutable = config.ExternalImmutable;
        pub const ExternalMutable = config.ExternalMutable;

        fn createInternal(self: *Self, start_idx: u64, count: u64) Internal {
            if (config.structure == .aos) {
                return self.getView(0, start_idx, count);
            }
            var internal: Internal = undefined;
            inline for (item_fields, 0..) |item_field, i| {
                @field(internal, item_field.name) = self.getView(i, start_idx, count);
            }
            return internal;
        }
        fn getExternalCount(comptime role: Role, items: RoleExternal(role)) usize {
            return switch (config.structure) {
                .aos => items.len,
                .soa => @field(items, item_fields[0].name).len,
            };
        }
        fn RoleExternal(comptime role: Role) type {
            return switch (role) {
                .producer => ExternalImmutable,
                .consumer => ExternalMutable,
            };
        }

        // only struct field
        capacity: u64,

        // offsets, pointers, and getters
        fn offsetStart() usize {
            return mem.alignForward(usize, @sizeOf(Self), atomic.cache_line);
        }
        fn offsetCounter(comptime role: Role, comptime state: State) usize {
            var offset = offsetStart();
            for (0..@intFromEnum(role) + 1) |i| {
                const r: Role = @enumFromInt(i);
                if (r.isMulti(config)) {
                    const to_advance = if (r == role) @intFromEnum(state) else possible_states.len;
                    offset += aligned_counter_size * to_advance;
                } else {
                    if (r != role) offset += aligned_counter_size;
                }
            }
            assert(offset <= offsetAfterCounters());
            return offset;
        }
        fn offsetAfterCounters() usize {
            return offsetStart() + counters_len * aligned_counter_size;
        }
        fn offsetSequences() usize {
            assert(config.ordering == .unordered);
            var offset = offsetAfterCounters();
            offset = mem.alignForward(usize, offset, atomic.cache_line);
            return offset;
        }
        fn offsetAfterSequences(capacity: u64) usize {
            var offset = offsetSequences();
            offset += @sizeOf(atomic.Value(u64)) * @as(usize, @intCast(capacity));
            return offset;
        }
        fn offsetBufferRange(capacity: u64, comptime end_exclusive: usize) usize {
            var offset = offsetAfterSequences(capacity);
            offset = mem.alignForward(usize, offset, atomic.cache_line);
            for (0..end_exclusive) |i| {
                const item_field = item_fields[i];
                const alignment: usize = @max(atomic.cache_line, item_field.alignment);
                offset += item_field.size * @as(usize, @intCast(capacity));
                offset = mem.alignForward(usize, offset, alignment);
            }
            return offset;
        }
        fn offsetBuffer(capacity: u64, comptime item_field_i: usize) usize {
            assert(item_field_i < item_fields_len);
            return offsetBufferRange(capacity, item_field_i);
        }
        fn offsetAfterBuffers(capacity: u64) usize {
            return offsetBufferRange(capacity, item_fields_len);
        }
        fn offsetEnd(capacity: u64) usize {
            return offsetAfterBuffers(capacity);
        }
        pub fn sizeOf(capacity: u64) usize {
            return offsetEnd(capacity);
        }
        pub fn alignOf() usize {
            var max: usize = @alignOf(Self);
            if (config.ordering == .unordered) max = @max(max, @alignOf(u64));
            for (item_fields) |item_field| {
                max = @max(max, item_field.alignment);
            }
            return max;
        }
        fn getCounter(self: *Self, comptime role: Role, comptime state: State) *atomic.Value(u64) {
            const base_ptr = @intFromPtr(self);
            return @ptrFromInt(base_ptr + offsetCounter(role, state));
        }
        fn getSequencesBuffer(self: *Self) [*]atomic.Value(u64) { // usually don't need bounds
            const base_ptr = @intFromPtr(self);
            return @ptrFromInt(base_ptr + offsetSequences());
        }
        fn getBuffer(self: *Self, comptime item_field_i: usize) [*]item_fields[item_field_i].FieldType { // same here
            const base_ptr = @intFromPtr(self);
            return @ptrFromInt(base_ptr + offsetBuffer(self.capacity, item_field_i));
        }
        fn getSequence(self: *Self, absolute_i: u64) *atomic.Value(u64) {
            assert(config.ordering == .unordered);
            const idx = absolute_i & (self.capacity - 1);
            var sequences = self.getSequencesBuffer();
            return &sequences[idx];
        }
        fn getView(
            self: *Self,
            comptime item_field_i: usize,
            absolute_i: u64,
            len: usize,
        ) View(item_fields[item_field_i].FieldType) {
            const T = item_fields[item_field_i].FieldType;
            const start_idx = absolute_i & (self.capacity - 1);
            var buffer = self.getBuffer(item_field_i);
            const space_left = self.capacity - start_idx;
            if (len <= space_left) {
                return .{
                    .first = buffer[start_idx .. start_idx + len],
                    .second = &[0]T{},
                };
            } else {
                return .{
                    .first = buffer[start_idx..self.capacity],
                    .second = buffer[0 .. len - space_left],
                };
            }
        }
        fn getPointer(
            self: *Self,
            comptime item_field_i: usize,
            absolute_idx: u64,
        ) *item_fields[item_field_i].FieldType {
            const idx = absolute_idx & (self.capacity - 1);
            var buffer = self.getBuffer(item_field_i);
            return &buffer[idx];
        }

        // init
        pub fn initInSlice(buffer: []u8, capacity: u64) *Self {
            const required_size = sizeOf(capacity);
            assert(buffer.len >= required_size);
            assert(buffer.len == required_size); // separate for easier debugging
            return Self.initAtPtr(buffer.ptr, capacity);
        }
        pub fn initAtPtr(ptr: [*]u8, capacity: u64) *Self {
            assert(capacity != 0);
            assert(math.isPowerOfTwo(capacity));
            assert(mem.isAligned(@intFromPtr(ptr), Self.alignOf()));
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.* = .{ .capacity = capacity };
            self.initCounters();
            if (config.ordering == .unordered) self.initSequences();
            return self;
        }
        fn initCounters(self: *Self) void {
            const base_ptr = @intFromPtr(self);
            for (0..counters_len) |i| {
                const counter_ptr = base_ptr + offsetStart() + aligned_counter_size * i;
                const counter: *atomic.Value(u64) = @ptrFromInt(counter_ptr);
                counter.* = .init(0);
            }
        }
        fn initSequences(self: *Self) void {
            assert(config.ordering == .unordered);
            assert(@bitSizeOf(atomic.Value(u64)) == @bitSizeOf(u64)); // should be, but just incase
            const VECTOR_SIZE = simd.suggestVectorLength(u64) orelse 8; // fallback avx512 will be lowered by compiler if still too large
            const gradient: @Vector(VECTOR_SIZE, u64) = simd.iota(u64, VECTOR_SIZE);
            var sequences = @as([*]u64, @bitCast(self.getSequencesBuffer()));
            var i: u64 = 0;
            while (i < self.capacity) {
                if (self.capacity - i < VECTOR_SIZE) {
                    sequences[i] = i;
                    i += 1;
                    continue;
                }
                const base: @Vector(VECTOR_SIZE, u64) = @splat(i);
                var offset_sequences = sequences[i..];
                offset_sequences[0..VECTOR_SIZE].* = @bitCast(base + gradient);
                i += VECTOR_SIZE;
            }
        }

        // public api with docs
        /// Copies all `items` into the buffer and handles AoS/SoA transposition.
        /// Fails by returning `false` when the buffer is full.
        pub fn push(self: *Self, items: ExternalImmutable) bool {
            return self.doTransfer(.producer, .exact, items);
        }
        /// Copies `items` at best-effort into the buffer and handles AoS/SoA transposition.
        /// Fails by returning `0` when the buffer is full.
        pub fn pushSome(self: *Self, items: ExternalImmutable) u64 {
            return self.doTransfer(.producer, .partial, items);
        }
        /// Copies from the buffer to exactly fill `items`. Handles AoS/SoA transposition.
        /// Fails by returning `false` when there aren't enough items in the buffer.
        pub fn pop(self: *Self, items: ExternalMutable) bool {
            return self.doTransfer(.consumer, .exact, items);
        }
        /// Copies from the buffer to fill `items` at best-effort. Handles AoS/SoA transposition.
        /// Fails by returning `0` when there are no items in the buffer.
        pub fn popSome(self: *Self, items: ExternalMutable) u64 {
            return self.doTransfer(.consumer, .partial, items);
        }

        /// Claims exactly `count` items and passes an `Internal` internal to the callback, which is executed inline.
        /// Fails by returning `false` when there aren't enough items in the buffer.\
        /// `E` is the error set the callback may return if it fails, or `void` if there is no error union.
        /// If the callback returns an error, it is passed through, but the claimed items are still consumed from the buffer.
        pub fn compute(self: *Self, count: u64, ctx: anytype, E: type, comptime callback: ComputeCallback(@TypeOf(ctx), E, void)) OptionalErrorUnion(E, bool) {
            return self.doCallback(.consumer, .exact, count, ctx, E, callback);
        }
        /// Claims up to `count` items at best-effort and passes an `Internal` internal to the callback, which is executed inline.
        /// Fails by returning `0` when there are no items in the buffer. If the callback passes an error, it is safe to assume `> 0` and `<= count` items were consumed.\
        /// `E` is the error set the callback may return if it fails, or `void` if there is no error union.
        /// If the callback returns an error, it is passed through. The exact number of claimed items will be unknown to the caller, but they are still consumed from the buffer.
        pub fn computeSome(self: *Self, count: u64, ctx: anytype, E: type, comptime callback: ComputeCallback(@TypeOf(ctx), E, void)) OptionalErrorUnion(E, usize) {
            return self.doCallback(.consumer, .partial, count, ctx, E, callback);
        }
        /// Claims exactly `count` free slots and passes an `Internal` internal to the callback, which is executed inline.
        /// Fails by returning `false` when there isn't enough space in the buffer.\
        /// `E` is the error set the callback may return if it fails, or `void` if there is no error union.
        /// If the callback returns an error, it is passed through, but the claimed slots are still published to consumers.
        pub fn produce(self: *Self, count: u64, ctx: anytype, E: type, comptime callback: ComputeCallback(@TypeOf(ctx), E, void)) OptionalErrorUnion(E, bool) {
            return self.doCallback(.producer, .exact, count, ctx, E, callback);
        }
        /// Claims up to `count` free slots at best-effort and passes an `Internal` internal to the callback, which is executed inline.
        /// Fails by returning `0` when the buffer is full. If the callback passes an error, it is safe to assume `> 0` and `<= count` slots were published.\
        /// `E` is the error set the callback may return if it fails, or `void` if there is no error union.
        /// If the callback returns an error, it is passed through. The exact number of claimed slots will be unknown to the caller, but they are still published to consumers.
        pub fn produceSome(self: *Self, count: u64, ctx: anytype, E: type, comptime callback: ComputeCallback(@TypeOf(ctx), E, void)) OptionalErrorUnion(E, usize) {
            return self.doCallback(.producer, .partial, count, ctx, E, callback);
        }

        // public heuristics
        pub fn debugLoadCounter(self: *Self, comptime role: Role, comptime state: State) u64 {
            return self.getCounter(role, state).load(.acquire);
        }
        /// Lower monotonic estimate of items in this buffer.
        pub fn estimateCountLower(self: *Self) u64 {
            return self.getCounter(.producer, .published).load(.monotonic) -| self.getCounter(.consumer, .claimed).load(.monotonic);
        }
        /// Higher monotonic estimate of items in this buffer.
        pub fn estimateCountHigher(self: *Self) u64 {
            return self.getCounter(.producer, .claimed).load(.monotonic) -| self.getCounter(.consumer, .published).load(.monotonic);
        }

        /// Checks if the buffer is completely idle and stable.
        /// For unordered mode, this performs an O(N) scan of the sequences.
        pub fn isStable(self: *Self) bool {
            const producer = self.getCounter(.producer, .claimed).load(.acquire);
            const consumer = self.getCounter(.consumer, .claimed).load(.acquire);
            var stable = true;
            if (stable and Role.producer.isMulti(config))
                stable = self.getCounter(.producer, .published).load(.acquire) == producer;
            if (stable and Role.consumer.isMulti(config))
                stable = self.getCounter(.consumer, .published).load(.acquire) == consumer;
            if (config.ordering == .fifo) return stable;
            assert(config.ordering == .unordered); // check guard incase of enum changes
            for (0..self.capacity) |offset| {
                const ticket = consumer + offset;
                const expected = if (ticket < producer) ticket + 1 else ticket;
                const actual = self.getSequence(ticket).load(.acquire);
                if (actual != expected) return false;
            }
            return true;
        }

        /// Imports all items from a stable, idle source ring buffer into this buffer.
        /// Returns `true` if successful, or `false` if the source is not stable or this buffer lacks space.
        pub fn import(self: *Self, src: *Self) bool {
            if (!src.isStable()) return false;

            const p_claimed = src.getCounter(.producer, .claimed).load(.acquire);
            const c_claimed = src.getCounter(.consumer, .claimed).load(.acquire);
            const available = p_claimed - c_claimed;
            if (available == 0) return true; // nothing to import

            const self_claim = self.claim(.producer, .exact, available);
            if (self_claim.count == 0) return false; // not enough space

            const src_claim = src.claim(.consumer, .exact, available);
            assert(src_claim.count == available);

            inline for (item_fields, 0..) |item_field, field_idx| {
                const src_view = src.getView(field_idx, c_claimed, available);
                const dst_view = self.getView(field_idx, self_claim.start_idx, available);
                self.copyViews(item_field.FieldType, dst_view, src_view);
            }

            self.publish(.producer, self_claim.start_idx, self_claim.start_idx + available);
            src.publish(.consumer, c_claimed, c_claimed + available);
            return true;
        }

        // import, handle wrapping with views
        fn copyViews(self: *Self, comptime T: type, dest: View(T), src: View(T)) void {
            _ = self;
            var src_offset: usize = 0;
            var dest_offset: usize = 0;
            var remaining = dest.first.len + dest.second.len;
            while (remaining > 0) {
                const src_slice = if (src_offset < src.first.len)
                    src.first[src_offset..]
                else
                    src.second[src_offset - src.first.len ..];
                const dst_slice = if (dest_offset < dest.first.len)
                    dest.first[dest_offset..]
                else
                    dest.second[dest_offset - dest.first.len ..];
                const chunk = @min(src_slice.len, dst_slice.len);
                @memcpy(dst_slice[0..chunk], src_slice[0..chunk]);
                src_offset += chunk;
                dest_offset += chunk;
                remaining -= chunk;
            }
        }

        // transfer
        fn doTransfer(
            self: *Self,
            comptime role: Role,
            comptime claim_mode: ClaimMode,
            items: RoleExternal(role),
        ) if (claim_mode == .exact) bool else u64 {
            const count = getExternalCount(role, items);
            assert(count > 0);
            const res = self.claim(role, claim_mode, count);
            if (res.count == 0) return if (claim_mode == .exact) false else 0;
            switch (config.structure) {
                .aos => {
                    const slice = items[0..res.count];
                    self.transfer(0, role, res.start_idx, slice);
                },
                .soa => inline for (item_fields, 0..) |item_field, i| {
                    const slice = @field(items, item_field.name)[0..res.count];
                    self.transfer(i, role, res.start_idx, slice);
                },
            }
            self.publish(role, res.start_idx, res.start_idx + res.count);
            return if (claim_mode == .exact) true else res.count;
        }
        fn transfer(
            self: *Self,
            comptime field_idx: usize,
            comptime role: Role,
            absolute_idx: u64,
            data: RoleExternal(role),
        ) void {
            const view = self.getView(field_idx, absolute_idx, data.len);
            if (role == .producer) {
                @memcpy(view.first, data[0..view.first.len]);
                if (view.second.len > 0) @memcpy(view.second, data[view.first.len..]);
            } else {
                @memcpy(data[0..view.first.len], view.first);
                if (view.second.len > 0) @memcpy(data[view.first.len..], view.second);
            }
        }

        // callback
        fn CheckedErrorSet(E: type) ?type {
            if (E == void) return null;
            return switch (@typeInfo(E)) {
                .error_set => |info| if (info) |_| E else @compileError("Passed error set is null."),
                else => @compileError("Expected an error set or void."),
            };
        }
        fn OptionalErrorUnion(E: type, Value: type) type {
            return if (CheckedErrorSet(E)) |ErrorSet| ErrorSet!Value else Value;
        }
        fn ComputeCallback(CtxT: type, E: type, ReturnType: type) type {
            return if (CheckedErrorSet(E)) |ErrorSet|
                fn (ctx: CtxT, internal: Internal) ErrorSet!ReturnType
            else
                fn (ctx: CtxT, internal: Internal) ReturnType;
        }

        inline fn doCallback(
            self: *Self,
            comptime role: Role,
            comptime claim_mode: ClaimMode,
            count: u64,
            ctx: anytype,
            E: type,
            comptime callback: ComputeCallback(@TypeOf(ctx), E, void),
        ) OptionalErrorUnion(E, if (claim_mode == .exact) bool else u64) {
            const res = self.claim(role, claim_mode, count);
            if (res.count == 0) return if (claim_mode == .exact) false else 0;

            // defer since we may handle errors and return
            defer self.publish(role, res.start_idx, res.start_idx + res.count);

            const internal = self.createInternal(res.start_idx, res.count);
            if (CheckedErrorSet(E) == null) {
                @call(.always_inline, callback, .{ ctx, internal });
            } else {
                @call(.always_inline, callback, .{ ctx, internal }) catch |e| return e;
            }
            return if (claim_mode == .exact) true else res.count;
        }

        // claiming
        const GrantResult = struct { granted: u64, retry: bool, current_claimed: u64 };
        const ClaimResult = struct { count: u64, start_idx: u64 };

        fn claim(
            self: *Self,
            comptime role: Role,
            comptime mode: ClaimMode,
            requested: u64,
        ) ClaimResult {
            assert(requested > 0);
            return switch (config.ordering) {
                .fifo => if (role.isMulti(config))
                    self.claimFifoMulti(role, mode, requested)
                else
                    self.claimFifoSingle(role, mode, requested),
                .unordered => self.claimUnordered(role, mode, requested),
            };
        }

        fn calculateAvailable(self: *Self, comptime role: Role, own: u64, limit: u64) u64 {
            return switch (role) {
                // limited by capacity
                .producer => self.capacity - (own - limit),
                // limited by producers
                .consumer => limit - own,
            };
        }
        fn isStale(comptime role: Role, own: u64, limit: u64) bool {
            return switch (role) {
                // Consumers are the limiter, they can't publish before we claim
                .producer => limit > own,
                // Producers are the limiter, we can't publish before they claim
                .consumer => own > limit,
            };
        }

        fn claimUnordered(self: *Self, comptime role: Role, comptime mode: ClaimMode, requested: u64) ClaimResult {
            const own_counter = self.getCounter(role, .claimed);
            var backoff: usize = INITIAL_BACKOFF;
            var current_own = own_counter.load(.monotonic);
            while (true) {
                var available: u64 = 0;
                for (0..requested) |i| {
                    const expected = if (role == .producer) current_own + i else current_own + i + 1;
                    const actual = self.getSequence(current_own + i).load(.acquire);
                    if (actual == expected) {
                        available += 1;
                    } else {
                        break;
                    }
                }
                const count = if (mode == .exact)
                    (if (available == requested) requested else 0)
                else
                    available;
                if (count == 0) {
                    return .{ .count = 0, .start_idx = current_own };
                }
                if (own_counter.cmpxchgWeak(current_own, current_own + count, .monotonic, .monotonic)) |updated_own| {
                    current_own = updated_own;
                    execBackoff(&backoff);
                } else {
                    return .{ .count = count, .start_idx = current_own };
                }
            }
        }

        fn claimFifoSingle(self: *Self, comptime role: Role, comptime mode: ClaimMode, requested: u64) ClaimResult {
            const own_counter = self.getCounter(role, .claimed);
            const limit_counter = self.getCounter(role.flip(), .published);
            // own is the index, limit is the fence
            const current_own = own_counter.load(.monotonic); // < single user
            const current_limit = limit_counter.load(.acquire);
            const available = self.calculateAvailable(role, current_own, current_limit);
            const count: u64 = if (mode == .exact and available < requested) 0 else @min(requested, available);
            if (count == 0) return .{ .count = 0, .start_idx = current_own };
            own_counter.store(current_own + count, .monotonic);
            return .{ .count = count, .start_idx = current_own };
        }

        fn claimFifoMulti(self: *Self, comptime role: Role, comptime mode: ClaimMode, requested: u64) ClaimResult {
            const own_counter = self.getCounter(role, .claimed);
            var backoff: usize = INITIAL_BACKOFF;
            while (true) {
                const result = self.grantFifoMulti(role, mode, requested);
                if (result.retry) {
                    execBackoff(&backoff);
                    continue;
                }
                if (result.granted == 0) {
                    return .{ .count = 0, .start_idx = result.current_claimed };
                }
                if (own_counter.cmpxchgWeak(result.current_claimed, result.current_claimed + result.granted, .monotonic, .monotonic) == null) {
                    return .{ .count = result.granted, .start_idx = result.current_claimed };
                }
                execBackoff(&backoff);
            }
        }
        fn grantFifoMulti(
            self: *Self,
            comptime role: Role,
            comptime mode: ClaimMode,
            requested: u64,
        ) GrantResult {
            const own_counter = self.getCounter(role, .claimed);
            const limit_counter = self.getCounter(role.flip(), .published);
            // own is the index, limit is the fence
            const current_own = own_counter.load(.monotonic); // < not a fence, can be unordered
            const current_limit = limit_counter.load(.acquire);

            if (isStale(role, current_own, current_limit)) {
                return .{ .granted = 0, .retry = true, .current_claimed = current_own };
            }
            const available = self.calculateAvailable(role, current_own, current_limit);
            const count: u64 = if (mode == .exact and available < requested) 0 else @min(requested, available);
            if (count == 0) {
                return .{
                    .granted = 0,
                    .retry = false,
                    .current_claimed = current_own,
                };
            }
            return .{
                .granted = count,
                .retry = false,
                .current_claimed = current_own,
            };
        }

        // publishing
        fn publish(
            self: *Self,
            comptime role: Role,
            expected_current: u64,
            new_val: u64,
        ) void {
            switch (config.ordering) {
                .fifo => self.publishFifo(role, expected_current, new_val),
                .unordered => self.publishUnordered(role, expected_current, new_val),
            }
        }
        fn publishFifo(self: *Self, comptime role: Role, expected_current: u64, new_val: u64) void {
            const publish_counter = self.getCounter(role, .published);
            var backoff: usize = INITIAL_BACKOFF;
            if (role.isMulti(config)) {
                while (publish_counter.load(.acquire) != expected_current)
                    execBackoff(&backoff);
            }
            publish_counter.store(new_val, .release);
        }
        fn publishUnordered(self: *Self, comptime role: Role, expected_current: u64, new_val: u64) void {
            const count = new_val - expected_current;
            for (0..count) |i| {
                const ticket = expected_current + i;
                const new_seq = if (role == .producer) ticket + 1 else ticket + self.capacity;
                self.getSequence(ticket).store(new_seq, .release);
            }
        }
    };
}
