const std = @import("std");

// Tests are in tests/ directory, this file is used to import them all.

comptime {
    _ = @import("tests/zig_serializer.zig");
    _ = @import("utils/cpu.zig");
    //_ = @import("orca/ThreadPool.zig");
}
