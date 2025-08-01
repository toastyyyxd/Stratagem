const std = @import("std");
const rl = @import("raylib");
const xev = @import("xev");
pub var thread_pool: ?xev.ThreadPool = null;
pub var event_loop: ?xev.Sys.Loop = null;

pub fn get_loop() xev.Sys.Loop {
    if (event_loop) |loop| {
        return loop;
    } else {
        std.debug.panic("Event loop is not initialized", .{});
    }
}
pub fn get_thread_pool() xev.ThreadPool {
    if (thread_pool) |pool| {
        return pool.?;
    } else {
        std.debug.panic("Thread pool is not initialized", .{});
    }
}

pub fn main() !void {
    // Initialize the event loop
    thread_pool = xev.ThreadPool.init(.{
        .max_threads = @as(u32, @truncate(try std.Thread.getCpuCount())),
    });
    defer thread_pool.?.deinit();
    event_loop = xev.Loop.init(.{
        .thread_pool = &thread_pool.?,
    }) catch |err| std.debug.panic("Failed to initialize event loop, error:\n{}", .{err});
    defer event_loop.?.deinit();

    // Game configuration
    const config = struct {
        pub const screen_width = 800;
        pub const screen_height = 450;
        pub const title = "Stratagem";
        pub const target_fps = 60;
    };

    // Access build options
    const build_options = @import("build_options");

    // Initialize window
    rl.initWindow(config.screen_width, config.screen_height, config.title);
    defer rl.closeWindow();
    rl.setTargetFPS(config.target_fps);

    // Game state
    var game = struct {
        frame_count: u64 = 0,
        // Add more state here later
    }{};

    // Main game loop
    while (!rl.windowShouldClose()) {
        // Update phase
        game.frame_count += 1;

        // Render phase
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.black);
        if (build_options.is_dev) {
            rl.drawFPS(10, 10);
        }
        rl.drawText("Stratagem Prototype", config.screen_width / 2 - 100, config.screen_height / 2, 20, .white);
    }
}

test "basic test" {
    try std.testing.expect(true);
}
