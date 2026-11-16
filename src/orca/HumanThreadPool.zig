const std = @import("std");
const VPA = @import("../mem/VirtualPageAllocator.zig");
const InplaceBufferAllocator = @import("../mem/InplaceBufferAllocator.zig");

const Conduit = @import("../mem/Conduit.zig").Conduit;
const View = @import("../mem/Conduit.zig").View;

const PaddedAtomic = @import("../mem/PaddedAtomic.zig").PaddedAtomic;
const cacheInvalidationSize = @import("../mem/PaddedAtomic.zig").cacheInvalidationSize;

const pin_thread = @import("./pin_thread.zig");
const simd = @import("../utils/simd.zig");

// how this works because ill forget:
// first we get the topology of the cpu at runtime.
// then we sort the threads by performance and organize them by locality.
// we only really need PinKey to refer to a thread for the library that pins it.
// ourselves we use the index as the id.
//
// our automatic scaling relies on the order to prioritize performant threads.
// 
// we have two types of localization for submissions
// a submission is a batch of jobs.
// a submission COULD end up partially complete, as the function returns a value of successfully submitted jobs in the submission.
// it's up to the submitter to treat a partial complete as possibly:
//     - a signal for backpressure
//     - to raise Y manually
//     - do a global disperse
//     - or continue repeating (not unboundedly!) and let the threadpool continue stepping X Y Z until equilibrium is reached naturall
// "not being able to take the load" is defined by either:
//     a threshold of the load counter,
//     e.g. 255 (1ms) * 2, usually jobs should never near the magnitude 1ms, but if they do, the threads still need to prioritize latency.
//     OR
//     hitting the bounded queue size limit.
// 1. localized
//      the submitter provides [mutable pointers to] X, Y, Z integers.
//      X should be seeded randomly by submitter are persistent for these workloads, e.g. a physics island.
//      Y should be seeded to 1 or however many threads are wanted on first submit,
//          note that Y is a hard constraint and can make things inefficient if seed is bad, until the threadpool eventually normalizes it.
//      Z should always be seeded to 0, similar situation to Y.
//
//      X is hashed to provide psuedo random scattering, then modulo-ed to active_limit.
//      define A as that.
//      this scatters submissions psuedorandomly, does roundrobin for individual threads, and respects pool scaling for new work.
//      
//      for small submissions where Y is small, A acts as round robin.
//      for large submissions where Y exceeds threads_in_ccd, it doesn't matter.
//
//      Y is the number of threads we spread to, N=0..Y, A+N as the threads we spread the work to.
//      if A+max(...N) is past the indexes in current CCD, then:
//          define A_0 = A
//          once we finish spreading work to A_0,
//          we spread work to A_1, A_..., A_m as if restarting this function but with X differently set.
//          A_m is derived from X_m as described previously.
//          each time, we calculate X_m by hashing X_m-1.
//          continue until we've spread onto Y threads.
//
//      note A is modulo-ed, but not A+Y or Y.
//          we leniently allow spill within the same CCD outside of active_limit, because:
//          modulo Y means within the CCD, we treat that as spill.
//          Y should decay if possible, active_limit should keep up if needed. both values migrate towards what's needed.
//          and if we did modulo A+Y, then we'd get cross-ccd wraparound (another ccd) on a submission that's supposed to be on one less ccd, for no reason!
//      
//      if threads A+...Y cannot take the load, and, Y < current_ccd_thread_count, then:
//          we modify Y.*+=1
//          note this case can never set Y > current_ccd_thread_count
//          if target EMA is very high, but ccd EMA is drastically lower, then we could be unluckily on a hotspot spread, then:
//              do a coinflip, if yes:
//                  we modify X.*+=1 to reroll.
//              else:
//                  we stay. 
//          note this avoids having to step all the way up to [all threads in ccd saturated] before doing an "index reroll".
//      else if threads A+...Y cannot take the load, [and, we're already filling the current ccd,] then:
//          we flip a coin, if yes, we migrate or spread:
//              if Z<6, then migrate:
//                  we modify X.*+=1 to reroll and move the submitter somewhere less loaded.
//                  modify Z.*+=3
//                      note Z functionally is incremented by 2 on average since on the "stay" branch we do -=1
//                      hence +=3 to maintain faster response
//              else then spread:
//                  we modify Y.*+=2
//                  we reset Z.*=0
//                  note this modifies past current_ccd_thread_count, spreads, plus grows more aggressively since
//                  our workload is already large enough to need to be spread thin - and thats still not enough
//          else, we stay:
//              we modify Z.*-|=1, note the saturating subtraction decays Z.
//
//      note we do require decaying Y in order to constrict this submitter's locality better.
//      the submitter is free to safely decay Y by itself too, if it wants to:
//          the submitter can e.g. infer Y by [previous Y : however it quantifies it's total work] "ratio".
//      the threadpool will also decay Y automatically if targetted threads' [low_estimate_load]s are low.
//
//      X does not need to decay.
//
//      return consumed jobs.
//
//      note that even with Y, active_limit bounds everything.
//      the monitor running between batches would instantly bump up active_limit proportionally and wake threads, if it finds average per-thread EMA is very high;
//      otherwise it's variable Y's purpose to continue spreading into the available active_limit.
//
//      note that CCD boundaries are checked with a condensed map of topology, we already have thread n-1 fetched, and thread n-1 has the reference CCD index.
//      in our map, we query that CCD index, it will return the last CCD index that's owned by topology and the total thread count of that CCD,
//      use it in however way you need to use those two data points.
//
//      note Z is incremented whenever we do a migration, because whenever we migrate a few times and STILL not have enough compute on the entire CCD,
//      compounding the reduced probability (hopefully) of the coin flip, it's likely that this means we literally won't ever have enough compute if we stay CCD-local.
//      hence, when we migrate around 3 times, we spread.
//
//      note Y can be modified by both threadpool and submitter, it is possible and usually fine even if submitter and threadpool do double action.
//      it's encouraged that sensitive systems check before and after if Y has been modified by thread pool,
//      or it should strictly take hold of Y by setting instead of incrementing, after letting the thread pool establish a baseline ^"ratio".
//
// 2. unlocalized
//      unlocalized work does not carry persistent X Y Z metadata, they attempt to stay on their local thread, that's it.
//      if the local thread can't take it, it'll look at the local ccd, then global disperse.
//      dead simple.
//      note this does double count the local ccd if we then hit global disperse, we'll turn a blind eye to this and pretend its locality bias.
//      return consumed jobs.
//
// 3. global disperse
//      global disperse works on the entire threadpool, and incurs quite a bit of upfront cost to get EMAs.
//      we get the total load of our submission.
//      we get the EMA summary value for all ccds within active_limit.
//      we sort the ccds.
//      we get @min(max_ccds, needed_ccds_to_absorb_load*2), that will be N.
//      we random 50% of the N indices in the sorted ccd array.
//      we disperse the work to those evenly because these are unlocalized jobs,
//          i.e. dumping them at best effort would hamper the workloads that actually NEED localization
//      if that's not enough, we sort remaining [initially pruned] N ccds by performance, and disperse live_remaining_work/live_remaining_ccds jobs to each ccd.
//      if that's STILL not enough, yield to submitter to decide what to do.
//      return the consumed jobs.
//
//  if in terms of dispersing within a ccd and the method doesn't define how, we do roundrobin at a random starting point,
//  and dump per_ccd_load/needed_threads_to_absorb_per_ccd_load*2 load until it is all consumed.
//  needed_X_to_absorb_load would be defined by @max(EMA * thread max load [e.g. 255*2 = est ~2ms], EMA * queue capacity), where EMA is EMA of X treated as a zero to one multiplier.

const ThreadPool = @This();

// @@@ workload/job and queue @@@

pub const Workload = bitpack struct(u128) {
    ctx_ptr: usize,
    fn_ptr: usize,
};
pub const WorkFn = *const fn (*anyopaque, *Thread) void;
pub const Jobs = struct {
    workload: []Workload,
    load: []u16,
};
const QueueExternalImmutableJobs = struct {
    workload: []const Workload,
    load: []const u16,
};
const QueueInternalJobs = struct {
    workload: View(Workload),
    load: View(u16),
};
const Queue = Conduit(.{
    .structure = .soa,
    .concurrency = .mpsc,
    .ordering = .fifo,
    .cross_cluster = true,
    .ExternalMutable = Jobs,
    .ExternalImmutable = QueueExternalImmutableJobs,
    .Internal = QueueInternalJobs,
});

// @@@ options and config flags @@@
pub const Options = struct {
    stack_size: usize,
    queue_capacity: u64,
    max_threads: u16,
    init_threads: u16,
    mode: enum { performance_first, efficiency_first },
    pub fn validate(self: *const Options) void {
        std.debug.assert(std.mem.isAligned(self.stack_size, std.heap.pageSize()));
        std.debug.assert(std.math.isPowerOfTwo(self.queue_capacity));
        std.debug.assert(self.max_threads <= 0xFFFE); // 0xFFFF is the null sentinel
        std.debug.assert(self.init_threads <= self.max_threads);
    }
};

// @@@ thread @@@
const Thread = struct {
    const SleepFutex = enum {
        sleep,
        wake,
    };

    iba: InplaceBufferAllocator,
    internal: std.Thread,

    sleep_futex: PaddedAtomic(SleepFutex, true),
    load: PaddedAtomic(bitpack struct (u64) {
        immediate: u32,
        unorm_ema: u32,
    }, true),

    pool: *ThreadPool,

    pub fn alignOf() usize {
        return @max(Queue.alignOf(), @alignOf(Thread));
    }
    pub fn sizeOf(queue_capacity: u64) usize {
        var off = @sizeOf(Thread);
        off = std.mem.alignForward(usize, off, Queue.alignOf());
        off += Queue.sizeOf(queue_capacity);
        off = std.mem.alignForward(usize, off, Thread.alignOf());
        return off;
    }
    fn getQueue(self: *Thread) *Queue {
        return @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(self) + @sizeOf(Thread), Queue.alignOf()));
    }
};

// @@@ pool @@@

const AISF = bitpack struct (u64) {
    submitter_active_limit: u16,
    identity: u16,
    spread: u16,
    frustration: u16,
};

const PhysIdentity = bitpack struct (u48) {
    const NO_TWIN = 0xFFFF;
    thread: u16,
    cluster: u16,
    _twin: u16 = NO_TWIN,
    pub fn getTwin(self: *@This()) ?u16 {
        return if (self._twin != NO_TWIN) self._twin else null;
    }
};

const Indirector = bitpack struct (u64) {
    phys: PhysIdentity,
    redirection: u16,
}; // no padding because while we do want to avoid false sharing, it's nearly never written to.

const SortTopology = struct {

};

allocator: std.mem.Allocator,

options: Options,
topology: pin_thread.Topology, // pointer struct, [WARN] needs deinit & bundles its own allocator !!!

active_limit: PaddedAtomic(u16, true),

pub fn alignOfStackless() usize {
    return @max(Thread.alignOf(), @alignOf(ThreadPool));
}
pub fn sizeOf(options: *const Options, real_max_threads: u16) usize {
    var off = @sizeOf(ThreadPool);
    off = std.mem.alignForward(usize, off, @alignOf(Indirector));
    off += @sizeOf(Indirector) * @as(usize, real_max_threads);
    off = std.mem.alignForward(usize, off, Thread.alignOf());
    off += Thread.sizeOf(@intCast(options.queue_capacity)) * @as(usize, real_max_threads);
    off = std.mem.alignForward(usize, off, std.heap.pageSize());
    off += options.stack_size * @as(usize, real_max_threads);
    off = std.mem.alignForward(usize, off, alignOfStackless()); // this line is probably useless tho
    return off;
}
pub fn sizeOfStackless(options: *const Options, real_max_threads: u16) usize {
    var off = @sizeOf(ThreadPool);
    off = std.mem.alignForward(usize, off, @alignOf(Indirector));
    off += @sizeOf(Indirector) * @as(usize, real_max_threads);
    off = std.mem.alignForward(usize, off, Thread.alignOf());
    off += Thread.sizeOf(@intCast(options.queue_capacity)) * @as(usize, real_max_threads);
    off = std.mem.alignForward(usize, off, alignOfStackless());
    return off;
}

fn getIndirector(self: *ThreadPool, i: u16) *Indirector {
    var off = @intFromPtr(self) + @sizeOf(ThreadPool);
    off = std.mem.alignForward(usize, off, @alignOf(Indirector));
    off += @sizeOf(Indirector) * i;
    return @ptrFromInt(off);
}
fn getRealMaxThreads(self: *ThreadPool) u16 {
    return @intCast(self.topology.threads.len);
}
fn getThread(self: *ThreadPool, i: u16) *Thread {
    std.debug.assert(i < self.getRealMaxThreads());
    var off = @intFromPtr(self) + @sizeOf(ThreadPool);
    off = std.mem.alignForward(usize, off, @alignOf(Indirector));
    off += @sizeOf(Indirector) * @as(usize, self.getRealMaxThreads());
    off = std.mem.alignForward(usize, off, Thread.alignOf());
    off += Thread.sizeOf(@intCast(self.options.queue_capacity)) * @as(usize, i);
    return @ptrFromInt(off);
}
fn getStackPtr(self: *ThreadPool, i: u16) usize {
    std.debug.assert(i < self.getRealMaxThreads());
    var off = @intFromPtr(self) + @sizeOf(ThreadPool);
    off = std.mem.alignForward(usize, off, @alignOf(Indirector));
    off += @sizeOf(Indirector) * @as(usize, self.getRealMaxThreads());
    off = std.mem.alignForward(usize, off, Thread.alignOf());
    off += Thread.sizeOf(@intCast(self.options.queue_capacity)) * @as(usize, self.getRealMaxThreads());
    off = std.mem.alignForward(usize, off, std.heap.pageSize());
    off += self.options.stack_size * @as(usize, i);
    return off;
}
pub fn init(al: std.mem.Allocator, options: *const Options) !*ThreadPool {
    options.validate();

    const topology = try pin_thread.discover(al);
    std.mem.sort(pin_thread.PhysThreadId, topology.threads, options.mode, struct {
        fn lessThanFn(mode: @TypeOf(options.mode), lhs: SortMeta, rhs: SortMeta) bool {
            if (lhs.cluster != rhs.cluster) return lhs.cluster < rhs.cluster;
            if (lhs.perf != rhs.perf) return if (mode == .efficiency_first) lhs.perf < rhs.perf else lhs.perf > rhs.perf;
            if (lhs.core_id != rhs.core_id) return lhs.core_id < rhs.core_id;
            return lhs.smt_tid < rhs.smt_tid;
        }
    }.lessThanFn); // sorts inline

    for (0..topology.count()) |i| {
        
    }

    const init_threads = @min(topology.count(), options.init_threads);

    const ptr = try VPA.reserveVirtualRegion(ThreadPool.sizeOf(options, topology.count()));
    try VPA.commitVirtualPages(ptr, ThreadPool.sizeOfStackless(options, topology.count()));
    const self = @as(*ThreadPool, @ptrFromInt(ptr));
    self.* = .{
        .allocator = al,
        .options = options,
        .topology = topology,
        .active_limit = .init(init_threads),
    };

    for (0..@as(usize, self.getRealMaxThreads())) |usize_i| {
        const u16_i: u16 = @intCast(usize_i);
    }

    return self;
}

pub fn initThread(self: *ThreadPool, u16_i: u16) !void {
    const usize_i = @as(usize, u16_i);
    const indir = self.getIndirector(i);
    const thread = self.getThread(i);
    const thread_topology = self.topology.threads[usize_i];
    const twin_topology =  self.topology.inCore(self.allocator, thread_topology.numa, thread_topology.core).get

    indir.* = .{
        .phys = .{
            .cluster = thread_topology.cluster,
            .thread = thread_topology.thread,
            ._twin =
        }
    }
}
