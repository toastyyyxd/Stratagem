const std = @import("std");
const wgpu = @import("wgpu");
const win32 = @import("win32");
const na1 = @import("./orca/pin_thread.zig");
const na2 = @import("./mem/VirtualPageAllocator.zig");

pub fn main(init: std.process.Init) !void {
    _ = init;
    std.log.info("Hello world!", .{});
    
}
