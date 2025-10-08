const std = @import("std");
const xev = @import("xev");

var thread_pool: xev.ThreadPool = undefined;
var event_loop: xev.Sys.Loop = undefined;

pub fn init() !void {
    thread_pool = xev.ThreadPool.init(.{
        .max_threads = @as(u32, @truncate(try std.Thread.getCpuCount())),
    });

    event_loop = xev.Loop.init(.{
        .thread_pool = &thread_pool,
    }) catch |err| std.debug.panic("Failed to initialize event loop, error:\n{}", .{err});
}

pub fn get_loop() xev.Sys.Loop {
    return event_loop;
}
pub fn get_thread_pool() xev.ThreadPool {
    return thread_pool;
}

pub fn deinit() void {
    thread_pool.deinit();
    event_loop.deinit();
}
