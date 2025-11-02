const std = @import("std");
const build_options = @import("build_options");

// Tests are in tests/ directory, this file is used to import them all.

comptime {
    _ = @import("tests/ring_buffer.zig");
    _ = @import("tests/thread_pool.zig");
    //_ = @import("mem/coreheap.zig");
}
