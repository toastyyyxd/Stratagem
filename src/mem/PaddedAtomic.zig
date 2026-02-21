const std = @import("std");

pub fn PaddedAtomic(T: type) type {
    const AtomicT = std.atomic.Value(T);
    const t_size = @sizeOf(AtomicT);
    const line_size = std.atomic.cache_line;
    const align_t = @alignOf(AtomicT);
    const effective_align = @max(align_t, line_size);

    // Round up to nearest multiple of effective_align
    const padded_size = ((t_size + effective_align - 1) / effective_align) * effective_align;

    return struct {
        value: AtomicT align(effective_align),
        _padding: [padded_size - t_size]u8,
        pub inline fn init(value: T) @This() {
            return .{
                .value = .init(value),
                ._padding = undefined,
            };
        }
    };
}
