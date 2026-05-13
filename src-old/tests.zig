const std = @import("std");
const build_options = @import("build_options");

// Tests are in tests/ directory, this file is used to import them all.

comptime {
    _ = @import("tests/ring_buffer.zig");
    //_ = @import("tests/thread_pool.zig");
    //_ = @import("tests/hazards_map.zig");
    //_ = @import("tests/coreheap.zig");
    //_ = @import("tests/timing.zig");
    //_ = @import("./orca/timer2.zig");
    _ = @import("tests/zig_serializer.zig");
}