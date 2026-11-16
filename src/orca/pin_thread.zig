const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32");
const posix = std.posix;

const PinKey = switch (builtin.os.tag) {
    .linux => u32,
    .windows => extern struct {
        group: u16,
        mask: usize,
    },
    .macos, .ios, .tvos, .watchos, .visionos => i32,
    else => u32,
};

/// Conservative lower-baseline capacity for a given efficiency class rank.
/// Used as a fallback when the platform does not expose real capacity ratios
/// (e.g. Windows, Darwin). Linux uses raw cpu_capacity from sysfs instead.
/// Mapping: class 0→128, 1→256, 2→512, 3→1024, etc.
fn defaultCapacity(efficiency_class: u8) u16 {
    return @as(u16, 128) << @intCast(efficiency_class);
}

pub const PhysThreadId = extern struct {
    _key: PinKey,
    numa: u16,
    die: u16,
    cluster: u16,
    core: u16,
    thread: u16,
    /// 0 = efficiency core (most power-efficient, least performant).
    /// Non-zero = performance core (higher value = more performant).
    /// Matches Windows PROCESSOR_RELATIONSHIP.EfficiencyClass (perflevel0 = highest perf):
    ///   https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-processor_relationship
    /// Matches Darwin hw.perflevel ordering:
    ///   https://developer.apple.com/forums/thread/692671
    efficiency_class: u8,
    /// Relative compute capacity of this logical processor.
    /// Linux: raw cpu_capacity from sysfs.
    /// Windows/Darwin: estimated from efficiency_class via defaultCapacity().
    capacity: u16 = 0,

    pub fn format(self: PhysThreadId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try switch (builtin.os.tag) {
            .windows => writer.print(
                "PhysThreadId{{ .group={d}, .mask=0x{x}, .numa={d}, .die={d}, .cl={d}, .core={d}, .thr={d}, .eff={d}, .cap={d} }}",
                .{ self._key.group, self._key.mask, self.numa, self.die, self.cluster, self.core, self.thread, self.efficiency_class, self.capacity },
            ),
            .linux => writer.print(
                "PhysThreadId{{ .cpu={d}, .numa={d}, .die={d}, .cl={d}, .core={d}, .thr={d}, .eff={d}, .cap={d} }}",
                .{ self._key, self.numa, self.die, self.cluster, self.core, self.thread, self.efficiency_class, self.capacity },
            ),
            .macos, .ios, .tvos, .watchos, .visionos => writer.print(
                "PhysThreadId{{ .tag={d}, .numa={d}, .die={d}, .cl={d}, .core={d}, .thr={d}, .eff={d}, .cap={d} }}",
                .{ self._key, self.numa, self.die, self.cluster, self.core, self.thread, self.efficiency_class, self.capacity },
            ),
            else => writer.writeAll("PhysThreadId{{ ... }}"),
        };
    }
};

pub const Topology = struct {
    threads: []PhysThreadId,
    _alloc: std.mem.Allocator,

    pub fn deinit(self: *Topology) void {
        self._alloc.free(self.threads);
        self.* = undefined;
    }

    pub fn count(self: *const Topology) usize {
        return self.threads.len;
    }

    pub fn get(self: *const Topology, index: usize) ?*const PhysThreadId {
        if (index >= self.threads.len) return null;
        return &self.threads[index];
    }

    pub const Filter = struct {
        numa: ?u16 = null,
        die: ?u16 = null,
        cluster: ?u16 = null,
        core: ?u16 = null,
        thread: ?u16 = null,
        performance_only: bool = false,
        efficiency_only: bool = false,
    };

    fn matches(t: *const PhysThreadId, f: Filter) bool {
        if (f.numa) |v| if (t.numa != v) return false;
        if (f.die) |v| if (t.die != v) return false;
        if (f.cluster) |v| if (t.cluster != v) return false;
        if (f.core) |v| if (t.core != v) return false;
        if (f.thread) |v| if (t.thread != v) return false;
        if (f.performance_only and t.efficiency_class == 0) return false;
        if (f.efficiency_only and t.efficiency_class != 0) return false;
        return true;
    }

    pub fn filter(self: *const Topology, alloc: std.mem.Allocator, f: Filter) ![]*const PhysThreadId {
        var list: std.ArrayList(*const PhysThreadId) = .empty;
        errdefer list.deinit(alloc);
        for (self.threads) |*t| {
            if (Topology.matches(t, f)) {
                try list.append(alloc, t);
            }
        }
        return list.toOwnedSlice(alloc);
    }

    pub fn allPerformance(self: *const Topology, alloc: std.mem.Allocator) ![]*const PhysThreadId {
        return self.filter(alloc, .{ .performance_only = true });
    }

    pub fn allEfficiency(self: *const Topology, alloc: std.mem.Allocator) ![]*const PhysThreadId {
        return self.filter(alloc, .{ .efficiency_only = true });
    }

    pub fn inNuma(self: *const Topology, alloc: std.mem.Allocator, numa: u16) ![]*const PhysThreadId {
        return self.filter(alloc, .{ .numa = numa });
    }

    pub fn inDie(self: *const Topology, alloc: std.mem.Allocator, numa: u16, die: u16) ![]*const PhysThreadId {
        return self.filter(alloc, .{ .numa = numa, .die = die });
    }

    pub fn inCore(self: *const Topology, alloc: std.mem.Allocator, numa: u16, core: u16) ![]*const PhysThreadId {
        return self.filter(alloc, .{ .numa = numa, .core = core });
    }

    pub fn inCluster(self: *const Topology, alloc: std.mem.Allocator, numa: u16, cl: u16) ![]*const PhysThreadId {
        return self.filter(alloc, .{ .numa = numa, .cluster = cl });
    }
};

pub fn pinThreadToCore(allocator: std.mem.Allocator, core: usize) !void {
    const key: PinKey = switch (builtin.os.tag) {
        .linux, .macos, .ios, .tvos, .watchos, .visionos => @intCast(core),
        .windows => .{ .group = 0, .mask = @as(usize, 1) << @intCast(core) },
        else => @intCast(core),
    };
    const id: PhysThreadId = .{
        ._key = key,
        .numa = 0,
        .die = 0,
        .cluster = 0,
        .core = 0,
        .thread = 0,
        .efficiency_class = 0,
        .capacity = 0,
    };
    return pinThreadToPhys(allocator, id);
}

pub fn pinThreadToPhys(allocator: std.mem.Allocator, id: PhysThreadId) !void {
    switch (comptime builtin.os.tag) {
        .linux => return LinuxImpl.pin(allocator, id._key),
        .windows => return WindowsImpl.pin(id._key),
        .macos, .ios, .tvos, .watchos, .visionos => return DarwinImpl.pin(id._key),
        else => return error.UnsupportedPlatform,
    }
}

pub fn discover(allocator: std.mem.Allocator) !Topology {
    var topo = switch (comptime builtin.os.tag) {
        .linux => try LinuxImpl.discover(allocator),
        .windows => try WindowsImpl.discover(allocator),
        .macos, .ios, .tvos, .watchos, .visionos => try DarwinImpl.discover(allocator),
        else => return error.UnsupportedPlatform,
    };
    if (topo.threads.len > std.math.maxInt(u16)) {
        topo.deinit();
        return error.TooManyCpus;
    }
    return topo;
}

const LinuxImpl = if (builtin.os.tag == .linux) struct {
    fn toU16(val: anytype) !u16 {
        return std.math.cast(u16, val) orelse return error.TopologyTooLarge;
    }

    fn pin(allocator: std.mem.Allocator, cpu: u32) !void {
        const bits = @bitSizeOf(usize);
        const max_cores = std.os.linux.CPU_SETSIZE * @bitSizeOf(usize);

        if (cpu < max_cores) {
            var mask: std.os.linux.cpu_set_t = @splat(0);
            const word_i = cpu / bits;
            const bit_i = cpu % bits;
            mask[word_i] = @as(usize, 1) << @intCast(bit_i);

            return std.os.linux.sched_setaffinity(0, &mask) catch |err| {
                std.log.err("sched_setaffinity failed: {s}", .{@errorName(err)});
                return error.PinFailed;
            };
        }

        const words_needed = cpu / bits + 1;
        const mask = try allocator.alloc(usize, words_needed);
        defer allocator.free(mask);
        @memset(mask, 0);

        const word_i = cpu / bits;
        const bit_i = cpu % bits;
        mask[word_i] = @as(usize, 1) << @intCast(bit_i);

        const mask_bytes: u32 = @intCast(words_needed * @sizeOf(usize));
        const rc = std.os.linux.syscall3(
            .sched_setaffinity,
            @as(u32, @bitCast(@as(i32, 0))),
            mask_bytes,
            @intFromPtr(mask.ptr),
        );
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return,
            .INVAL => return error.CpuOutOfRange,
            else => |err| {
                std.log.err("sched_setaffinity failed: {s}", .{@errorName(err)});
                return error.PinFailed;
            },
        }
    }

    fn discover(allocator: std.mem.Allocator) !Topology {
        var list: std.ArrayList(PhysThreadId) = .empty;
        errdefer list.deinit(allocator);

        const online_str = readSysfsFileAlloc(allocator, "/sys/devices/system/cpu/online") catch |err| {
            std.log.err("Failed to read /sys/devices/system/cpu/online: {s}", .{@errorName(err)});
            return error.TopologyUnavailable;
        };
        defer allocator.free(online_str);

        const cpu_ids = parseCpuList(allocator, online_str) catch |err| {
            std.log.err("Failed to parse CPU online list: {s}", .{@errorName(err)});
            return error.TopologyUnavailable;
        };
        defer allocator.free(cpu_ids);

        var capacities = try allocator.alloc(u32, cpu_ids.len);
        defer allocator.free(capacities);
        for (cpu_ids, 0..) |cpu_id, i| {
            capacities[i] = readCpuCapacity(allocator, cpu_id);
        }

        const eff_classes = try computeEfficiencyClasses(allocator, capacities);
        defer allocator.free(eff_classes);

        for (cpu_ids, 0..) |cpu_id, i| {
            var buf: [128]u8 = undefined;

            const cpu_path = std.fmt.bufPrint(&buf, "/sys/devices/system/cpu/cpu{d}/topology", .{cpu_id}) catch continue;

            const numa_id = readTopoInt(allocator, cpu_path, "physical_package_id", -1);
            const die_id = readTopoInt(allocator, cpu_path, "die_id", 0);
            const cluster_id = readTopoInt(allocator, cpu_path, "cluster_id", 0);
            const core_id = readTopoInt(allocator, cpu_path, "core_id", 0);
            const thread_index = readThreadIndex(allocator, cpu_path, cpu_id);

            list.append(allocator, PhysThreadId{
                ._key = @intCast(cpu_id),
                .numa = try toU16(numa_id),
                .die = try toU16(die_id),
                .cluster = try toU16(cluster_id),
                .core = try toU16(core_id),
                .thread = try toU16(thread_index),
                .efficiency_class = eff_classes[i],
                .capacity = try toU16(capacities[i]),
            }) catch |err| {
                list.deinit(allocator);
                return err;
            };
        }

        return Topology{
            .threads = try list.toOwnedSlice(allocator),
            ._alloc = allocator,
        };
    }

    fn readSysfsFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const fd = try posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
        defer _ = std.os.linux.close(fd);

        const buf = try allocator.alloc(u8, 4096);
        errdefer allocator.free(buf);

        const n = try posix.read(fd, buf);
        if (n < buf.len) {
            return try allocator.realloc(buf, n);
        }
        return buf;
    }

    fn readTopoInt(allocator: std.mem.Allocator, base_path: []const u8, name: []const u8, default: i32) i32 {
        var buf: [256]u8 = undefined;
        const full_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ base_path, name }) catch return default;
        const content = readSysfsFileAlloc(allocator, full_path) catch return default;
        defer allocator.free(content);
        return std.fmt.parseInt(i32, std.mem.trimEnd(u8, content, "\n"), 10) catch default;
    }

    fn readCpuCapacity(allocator: std.mem.Allocator, cpu_id: u32) u32 {
        var buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/sys/devices/system/cpu/cpu{d}/cpu_capacity", .{cpu_id}) catch return 0;
        const content = readSysfsFileAlloc(allocator, path) catch return 0;
        defer allocator.free(content);
        return std.fmt.parseUnsigned(u32, std.mem.trimEnd(u8, content, "\n"), 10) catch 0;
    }

    fn computeEfficiencyClasses(allocator: std.mem.Allocator, capacities: []const u32) ![]u8 {
        var unique: std.ArrayList(u32) = .empty;
        defer unique.deinit(allocator);

        for (capacities) |cap| {
            var found = false;
            for (unique.items) |u| {
                if (u == cap) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                var pos: usize = 0;
                while (pos < unique.items.len and unique.items[pos] < cap) : (pos += 1) {}
                try unique.insert(allocator, pos, cap);
            }
        }

        var classes = try allocator.alloc(u8, capacities.len);
        errdefer allocator.free(classes);
        for (capacities, 0..) |cap, i| {
            for (unique.items, 0..) |un_val, rank| {
                if (cap == un_val) {
                    classes[i] = @intCast(rank);
                    break;
                }
            }
        }

        return classes;
    }

    fn readThreadIndex(allocator: std.mem.Allocator, base_path: []const u8, cpu_id: u32) u32 {
        var siblings: [32]u32 = @splat(0);
        const nwords = readSiblingsMaskTo(allocator, base_path, &siblings) catch return 0;

        var count: u32 = 0;
        for (0..@intCast(cpu_id)) |b| {
            const word = b / 32;
            if (word >= nwords) break;
            const bit = b % 32;
            if ((siblings[word] & (@as(u32, 1) << @intCast(bit))) != 0) {
                count += 1;
            }
        }
        return count;
    }

    fn readSiblingsMaskTo(allocator: std.mem.Allocator, base_path: []const u8, words: []u32) !usize {
        var buf: [256]u8 = undefined;

        const path_new = std.fmt.bufPrint(&buf, "{s}/core_cpus", .{base_path}) catch return error.NameTooLong;
        const content = readSysfsFileAlloc(allocator, path_new) catch {
            const path_old = std.fmt.bufPrint(&buf, "{s}/thread_siblings", .{base_path}) catch return error.NameTooLong;
            const c = readSysfsFileAlloc(allocator, path_old) catch return error.TopologyUnavailable;
            defer allocator.free(c);
            return parseCpumaskHex(c, words);
        };
        defer allocator.free(content);
        return parseCpumaskHex(content, words);
    }

    fn parseCpumaskHex(text: []const u8, words: []u32) !usize {
        const trimmed = std.mem.trimEnd(u8, text, "\n \t");
        var it = std.mem.splitBackwardsScalar(u8, trimmed, ',');
        var i: usize = 0;
        while (it.next()) |token| {
            if (i >= words.len) break;
            words[i] = std.fmt.parseUnsigned(u32, token, 16) catch 0;
            i += 1;
        }
        return i;
    }

    fn parseCpuList(allocator: std.mem.Allocator, text: []const u8) ![]u32 {
        const trimmed = std.mem.trimEnd(u8, text, "\n \t");
        var list: std.ArrayList(u32) = .empty;
        errdefer list.deinit(allocator);

        var it = std.mem.splitScalar(u8, trimmed, ',');
        while (it.next()) |range| {
            if (std.mem.indexOfScalar(u8, range, '-')) |dash_pos| {
                const start = try std.fmt.parseUnsigned(u32, range[0..dash_pos], 10);
                const end = try std.fmt.parseUnsigned(u32, range[dash_pos + 1 ..], 10);
                var i = start;
                while (i <= end) : (i += 1) {
                    try list.append(allocator, i);
                }
            } else {
                try list.append(allocator, try std.fmt.parseUnsigned(u32, range, 10));
            }
        }
        return list.toOwnedSlice(allocator);
    }
} else struct {};

const WindowsImpl = if (builtin.os.tag == .windows) struct {
    const si = win32.system.system_information;

    fn pin(key: PinKey) !void {
        const hthread = win32.system.threading.GetCurrentThread();

        var ga: si.GROUP_AFFINITY = .{
            .Mask = key.mask,
            .Group = key.group,
            .Reserved = .{ 0, 0, 0 },
        };

        if (win32.system.threading.SetThreadGroupAffinity(hthread, &ga, null) == 0) {
            const err = win32.foundation.GetLastError();
            std.log.err("SetThreadGroupAffinity failed: error code {d}", .{@intFromEnum(err)});
            return error.PinFailed;
        }
    }

    fn discover(allocator: std.mem.Allocator) !Topology {
        var needed: u32 = 0;
        _ = si.GetLogicalProcessorInformationEx(si.RelationAll, null, &needed);
        if (needed == 0) return error.TopologyUnavailable;

        const buf = try allocator.alloc(u8, needed);
        defer allocator.free(buf);

        if (si.GetLogicalProcessorInformationEx(si.RelationAll, @ptrCast(buf.ptr), &needed) == 0) {
            return error.TopologyUnavailable;
        }

        // Pre-scan: find maximum context key for allocation sizing
        var max_ck: usize = 0;
        {
            var scan_ptr: [*]const u8 = @ptrCast(buf.ptr);
            const scan_end = scan_ptr + needed;
            while (@intFromPtr(scan_ptr) < @intFromPtr(scan_end)) {
                const info: *const si.SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX = @ptrCast(@alignCast(scan_ptr));
                if (info.Relationship == si.RelationProcessorCore) {
                    const pr = info.Anonymous.Processor;
                    for (pr.GroupMask[0..pr.GroupCount]) |gm| {
                        const base = @as(usize, gm.Group) * 64;
                        var m = gm.Mask;
                        var bit: u32 = 0;
                        while (m != 0) : (bit += 1) {
                            if (m & 1 != 0) {
                                const ck = base + bit;
                                if (ck > max_ck) max_ck = ck;
                            }
                            m >>= 1;
                        }
                    }
                }
                scan_ptr += info.Size;
            }
        }

        const ctx_indices = try allocator.alloc(usize, max_ck + 1);
        defer allocator.free(ctx_indices);
        @memset(ctx_indices, std.math.maxInt(usize));

        var list: std.ArrayList(PhysThreadId) = .empty;
        errdefer list.deinit(allocator);

        // Pass 1: processor cores
        var ptr: [*]const u8 = @ptrCast(buf.ptr);
        const end_ptr = ptr + needed;
        var core_counter: u16 = 0;

        while (@intFromPtr(ptr) < @intFromPtr(end_ptr)) {
            const info: *const si.SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX = @ptrCast(@alignCast(ptr));
            if (info.Relationship == si.RelationProcessorCore) {
                const pr = info.Anonymous.Processor;
                const eff_class: u8 = pr.EfficiencyClass;
                const flags: u8 = pr.Flags;
                const is_smt = (flags & 1) != 0;

                var ti: u16 = 0;
                for (0..pr.GroupCount) |gi| {
                    const gmask = pr.GroupMask[gi];
                    var m = gmask.Mask;
                    var bit: u32 = 0;
                    while (m != 0) : (bit += 1) {
                        if (m & 1 != 0) {
                            const ck = ctxKey(gmask.Group, bit);
                            ctx_indices[ck] = list.items.len;

                            list.append(allocator, PhysThreadId{
                                ._key = .{ .group = gmask.Group, .mask = @as(usize, 1) << @intCast(bit) },
                                .numa = 0xFFFF,
                                .die = 0,
                                .cluster = 0,
                                .core = core_counter,
                                .thread = if (is_smt) ti else 0,
                                .efficiency_class = eff_class,
                                .capacity = defaultCapacity(eff_class),
                            }) catch |err| {
                                list.deinit(allocator);
                                return err;
                            };
                            ti += 1;
                            if (ti == 0) return error.TopologyTooLarge;
                        }
                        m >>= 1;
                    }
                }
                core_counter += 1;
                if (core_counter == 0) return error.TopologyTooLarge;
            }
            ptr += info.Size;
        }

        // Pass 2: numa nodes, dies, cache clusters
        ptr = @ptrCast(buf.ptr);
        var numa_counter: u16 = 0;
        var die_counter: u16 = 0;
        var cl_counter: u16 = 0;

        while (@intFromPtr(ptr) < @intFromPtr(end_ptr)) {
            const info: *const si.SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX = @ptrCast(@alignCast(ptr));

            switch (info.Relationship) {
                si.RelationProcessorPackage => {
                    const pr = info.Anonymous.Processor;
                    applyField(pr.GroupMask[0..pr.GroupCount], &list, ctx_indices, .numa, numa_counter);
                    numa_counter += 1;
                    if (numa_counter == 0) return error.TopologyTooLarge;
                },
                si.RelationProcessorDie => {
                    const pr = info.Anonymous.Processor;
                    applyField(pr.GroupMask[0..pr.GroupCount], &list, ctx_indices, .die, die_counter);
                    die_counter += 1;
                    if (die_counter == 0) return error.TopologyTooLarge;
                },
                si.RelationCache => {
                    const cr = info.Anonymous.Cache;
                    if (cr.Level == 2) {
                        const masks = if (cr.GroupCount == 1)
                            (@as([*]const si.GROUP_AFFINITY, @ptrCast(&cr.Anonymous.GroupMask)))[0..1]
                        else
                            cr.Anonymous.GroupMasks[0..cr.GroupCount];
                        applyField(masks, &list, ctx_indices, .cluster, cl_counter);
                        cl_counter += 1;
                        if (cl_counter == 0) return error.TopologyTooLarge;
                    }
                },
                si.RelationNumaNode, si.RelationNumaNodeEx => {
                    const nr = info.Anonymous.NumaNode;
                    const masks = if (nr.GroupCount == 1)
                        (@as([*]const si.GROUP_AFFINITY, @ptrCast(&nr.Anonymous.GroupMask)))[0..1]
                    else
                        nr.Anonymous.GroupMasks[0..nr.GroupCount];
                    applyNuma(masks, &list, ctx_indices, @intCast(nr.NodeNumber));
                },
                else => {},
            }
            ptr += info.Size;
        }

        // Pass 3: fill unknown numa nodes
        for (list.items) |*item| {
            if (item.numa == 0xFFFF) {
                item.numa = 0;
            }
        }

        return Topology{
            .threads = try list.toOwnedSlice(allocator),
            ._alloc = allocator,
        };
    }

    fn ctxKey(group: u16, bit: u32) usize {
        return @as(usize, group) * 64 + bit;
    }

    const FieldTag = enum { numa, die, cluster };

    fn applyField(
        masks: []const si.GROUP_AFFINITY,
        list: *std.ArrayList(PhysThreadId),
        indices: []const usize,
        comptime field: FieldTag,
        value: u16,
    ) void {
        for (masks) |gm| {
            var m = gm.Mask;
            var bit: u32 = 0;
            while (m != 0) : (bit += 1) {
                if (m & 1 != 0) {
                    const ck = ctxKey(gm.Group, bit);
                    if (ck < indices.len) {
                        const idx = indices[ck];
                        if (idx < list.items.len) {
                            switch (field) {
                                .numa => list.items[idx].numa = value,
                                .die => list.items[idx].die = value,
                                .cluster => list.items[idx].cluster = value,
                            }
                        }
                    }
                }
                m >>= 1;
            }
        }
    }

    fn applyNuma(
        masks: []const si.GROUP_AFFINITY,
        list: *std.ArrayList(PhysThreadId),
        indices: []const usize,
        node: u16,
    ) void {
        for (masks) |gm| {
            var m = gm.Mask;
            var bit: u32 = 0;
            while (m != 0) : (bit += 1) {
                if (m & 1 != 0) {
                    const ck = ctxKey(gm.Group, bit);
                    if (ck < indices.len) {
                        const idx = indices[ck];
                        if (idx < list.items.len and list.items[idx].numa == 0xFFFF) {
                            list.items[idx].numa = node;
                        }
                    }
                }
                m >>= 1;
            }
        }
    }
} else struct {};

const DarwinImpl = if (builtin.os.tag.isDarwin()) struct {
    extern "c" fn thread_policy_set(
        thread: std.c.mach_port_t,
        flavor: i32,
        policy_info: ?*const anyopaque,
        count: std.c.mach_msg_type_number_t,
    ) std.c.kern_return_t;

    const THREAD_AFFINITY_POLICY: i32 = 4;
    const KERN_NOT_SUPPORTED: i32 = 46;

    const ThreadAffinityPolicyData = extern struct {
        affinity_tag: i32,
    };

    fn pin(tag: i32) !void {
        const thread_self = std.c.pthread_self();
        const thread_port = std.c.pthread_mach_thread_np(thread_self) orelse return error.PinFailed;

        const policy: ThreadAffinityPolicyData = .{ .affinity_tag = tag };
        const ret = thread_policy_set(
            thread_port,
            THREAD_AFFINITY_POLICY,
            &policy,
            @sizeOf(ThreadAffinityPolicyData) / @sizeOf(i32),
        );

        if (ret != 0) {
            if (ret == KERN_NOT_SUPPORTED) return error.NotSupported;
            std.log.err("thread_policy_set(THREAD_AFFINITY_POLICY) failed: kern_return_t={d}", .{ret});
            return error.PinFailed;
        }
    }

    fn discover(allocator: std.mem.Allocator) !Topology {
        var list: std.ArrayList(PhysThreadId) = .empty;
        errdefer list.deinit(allocator);

        const nlevels = sysctlInt("hw.nperflevels") catch 1;

        var os_index: u32 = 0;
        for (0..nlevels) |level_i| {
            var name_buf: [64]u8 = undefined;
            const name_path = std.fmt.bufPrint(&name_buf, "hw.perflevel{d}.name", .{level_i}) catch continue;

            const name = sysctlString(allocator, name_path) catch blk: {
                var fallback: [32]u8 = undefined;
                break :blk std.fmt.bufPrint(&fallback, "level{d}", .{level_i}) catch continue;
            };
            defer allocator.free(name);

            const is_perf = std.mem.indexOf(u8, name, "Performance") != null or
                std.mem.indexOf(u8, name, "performance") != null;

            const eff_class: u8 = if (is_perf) 1 else 0;

            const logical_max = sysctlIntFormat(allocator, "hw.perflevel{d}.logicalcpu_max", .{level_i}) catch
                sysctlIntFormat(allocator, "hw.perflevel{d}.logicalcpu", .{level_i}) catch
                @as(i64, 1);

            const physical_max = sysctlIntFormat(allocator, "hw.perflevel{d}.physicalcpu_max", .{level_i}) catch
                sysctlIntFormat(allocator, "hw.perflevel{d}.physicalcpu", .{level_i}) catch
                logical_max;

            const cpus_per_l2 = sysctlIntFormat(allocator, "hw.perflevel{d}.cpusperl2", .{level_i}) catch
                physical_max;

            const threads_per_core = if (physical_max > 0)
                @divTrunc(@as(u32, @intCast(logical_max)), @as(u32, @intCast(physical_max)))
            else
                @as(u32, 1);

            for (0..@as(u32, @intCast(logical_max))) |_| {
                const phys_core: u16 = @intCast(os_index / threads_per_core);
                const cl: u16 = if (cpus_per_l2 > 0)
                    @intCast(phys_core / @as(u16, @intCast(cpus_per_l2)))
                else
                    0;

                list.append(allocator, PhysThreadId{
                    ._key = @intCast(os_index),
                    .numa = 0,
                    .die = 0,
                    .cluster = cl,
                    .core = phys_core,
                    .thread = @intCast(os_index % threads_per_core),
                    .efficiency_class = eff_class,
                    .capacity = defaultCapacity(eff_class),
                }) catch |err| {
                    list.deinit(allocator);
                    return err;
                };
                os_index += 1;
            }
        }

        return Topology{
            .threads = try list.toOwnedSlice(allocator),
            ._alloc = allocator,
        };
    }

    fn sysctlInt(name: []const u8) !i64 {
        var val: i64 = 0;
        var len: usize = @sizeOf(i64);

        if (posix.sysctlbyname(name.ptr, &val, &len, null, 0) != 0) {
            return error.SysctlFailed;
        }
        return val;
    }

    fn sysctlIntFormat(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !i64 {
        _ = allocator;
        var buf: [128]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, fmt, args);
        return sysctlInt(name);
    }

    fn sysctlString(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        var len: usize = 0;
        if (posix.sysctlbyname(name.ptr, null, &len, null, 0) != 0) {
            return error.SysctlFailed;
        }
        if (len == 0) len = 64;
        const buf = try allocator.alloc(u8, len);
        errdefer allocator.free(buf);
        if (posix.sysctlbyname(name.ptr, buf.ptr, &len, null, 0) != 0) {
            return error.SysctlFailed;
        }
        return buf[0 .. len - 1];
    }
} else struct {};
