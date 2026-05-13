const std = @import("std");
const Io = std.Io;
const Timestamp = Io.Timestamp;
const Duration = Io.Duration;
const ThreadPool = @import("./ThreadPool.zig").ThreadPool;
const Job = @import("./ThreadPool.zig").Job;
const Thread = @import("./ThreadPool.zig").Thread;

pub const TimingError = error {
    NotDead,
    NotLive,
    NotSupported,
};
pub const Timing = struct {
    pub const State = enum(u8) {
        live, dying, dead
    };
    pub const Hook = struct {
        ctx: *anyopaque,
        fire: *const fn (ctx: *anyopaque, delta: Duration) void,
    };
    interval: Duration,
    jitter_buffer: Duration,
    total_elapsed: Timestamp,
    io: Io,
    start_stamp: Timestamp,
    last_stamp: Timestamp,
    state: std.atomic.Value(Timing.State) align(std.atomic.cache_line),
    hooks: []Hook,
    
    pub fn init(interval_ns: Duration, jitter_buffer: Duration) Timing {
        const self: Timing = .{
            .io = undefined,
            .interval = interval_ns,
            .jitter_buffer = jitter_buffer,
            .total_elapsed = undefined,
            .start_stamp = undefined,
            .last_stamp = undefined,
            .state = .init(.dead),
            .hooks = undefined,
        };
        return self;
    }
    pub fn start(self: *Timing, io: Io, thread_pool: *ThreadPool, hooks: []Hook) TimingError!void {
        if (self.state.cmpxchgStrong(.dead, .live, .acq_rel, .acquire)) |_| {
            return error.NotDead;
        }
        self.io = io;
        self.total_elapsed = Timestamp.zero;
        self.start_stamp = Timestamp.now(io, .awake);
        self.last_stamp = self.start_stamp;
        self.hooks = hooks;
        var cb = self.createJob();
        var submitted: u64 = 0;
        while (submitted == 0) {
            submitted += thread_pool.submit(cb[0..1]);
        }
    }
    pub fn stop(self: *Timing) TimingError!void {
        if (self.state.cmpxchgStrong(.live, .dying, .acq_rel, .acquire)) |_| {
            return error.NotLive;
        }
    }

    fn loop(ctx: *anyopaque, thread: *Thread) void {
        const self: *Timing = @ptrCast(@alignCast(ctx));
        if (self.state.load(.acquire) == .dying) {
            self.state.store(.dead, .release);
            return;
        }
        const now = Timestamp.now(self.io, .awake);
        const delta = self.last_stamp.durationTo(now);
        self.last_stamp = now;
        self.total_elapsed = self.total_elapsed.addDuration(delta);
        for (self.hooks) |h| h.fire(h.ctx, delta);
        const after_hooks = Timestamp.now(self.io, .awake);
        const wait_stamp = self.last_stamp.addDuration(self.interval).subDuration(self.jitter_buffer).subDuration(self.last_stamp.durationTo(after_hooks));
        var cb = self.createJob();
        thread.wait_slot = .{
            .active = true,
            .trigger_stamp = wait_stamp,
            .io = self.io,
            .job = cb[0],
        };
    }
    inline fn createJob(self: *Timing) [1]Job {
        return [_]Job{
            Job{
                .ctx = self,
                .load = 1,
                .tick = Timing.loop
            }
        };
    }
};