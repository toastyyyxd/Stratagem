const std = @import("std");

pub fn cacheInvalidationSize(comptime cross_cluster: bool) usize {
    const line_size = std.atomic.cache_line;
    return if (cross_cluster and line_size == 64) line_size * 2 else line_size;
}

pub fn PaddedAtomic(T: type, comptime cross_cluster: bool) type {
    const AtomicT = std.atomic.Value(T);
    const t_size = @sizeOf(AtomicT);
    const cache_invalidation_size = cacheInvalidationSize(cross_cluster);
    const align_t = @alignOf(AtomicT);
    const effective_align = @max(align_t, cache_invalidation_size);
    const padding_stride = @max(effective_align, cache_invalidation_size);

    const padded_size = ((t_size + padding_stride - 1) / padding_stride) * padding_stride;
    const padding_size = padded_size - t_size;

    return struct {
        value: AtomicT align(effective_align),
        _padding: [padding_size]u8,
        pub inline fn init(value: T) @This() {
            return .{
                .value = .init(value),
                ._padding = @splat(0),
            };
        }
        pub fn alignOf() usize {
            return padded_size;
        }
    };
}
