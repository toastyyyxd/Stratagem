const std = @import("std");
const hwloc = @import("hwloc");
const cpu_features = @import("cpu_features"); // TODO
const Self = @This();

io: std.Io,
topology: *hwloc.struct_hwloc_topology,

fn do(r: c_int) !void {
    if (r >= 0) return;
    const errno = hwloc.__errno_location().*;
    if (errno == hwloc.ENOSYS) return error.UnsupportedSystem;
    if (errno == hwloc.ENOMEM) return error.OutOfMemory;
    if (errno == hwloc.EINVAL) return error.BadHwlocAbi;
    std.log.err("Other HWLOC error with return value {}: {s}", .{ r, hwloc.strerror(errno)});
    return error.AnyHwlocError;
}

pub fn init(io: std.Io) !Self {
    var self: Self = undefined;
    self.io = io;
    try do(hwloc.hwloc_topology_init(@ptrCast(&self.topology)));
    return self;
}

pub fn load(self: *Self) !void {
    try do(hwloc.hwloc_topology_load(self.topology));
    try do(hwloc.hwloc_topology_abi_check(self.topology));
}

pub fn getSharedDomain(self: *Self, pu: *hwloc.struct_hwloc_obj) *hwloc.struct_hwloc_obj {
    _ = self;
    std.debug.assert(pu.type == hwloc.HWLOC_OBJ_PU);
    var obj_maybe: ?*hwloc.struct_hwloc_obj = pu.parent.?;
    while (obj_maybe) |obj| : (obj_maybe = obj.parent) {
        if (std.mem.indexOfScalar(c_uint, &.{
            hwloc.HWLOC_OBJ_MACHINE,
            hwloc.HWLOC_OBJ_PACKAGE,
            hwloc.HWLOC_OBJ_NUMANODE,
            hwloc.HWLOC_OBJ_DIE,
            hwloc.HWLOC_OBJ_GROUP,
            hwloc.HWLOC_OBJ_L3CACHE,
        }, obj.type)) |_| break;
    }
    return obj_maybe.?;
}

pub const SchedulingDomain = struct {
    cpus: *hwloc.struct_hwloc_bitmap_s,
    avg_eff: u64,
};

pub fn buildSchedulingDomains(self: *Self, gpa: std.mem.Allocator) ![]SchedulingDomain {
    const kinds_c_int = hwloc.hwloc_cpukinds_get_nr(self.topology, 0);
    const kinds = if (kinds_c_int >= 0) @as(usize, @intCast(kinds_c_int)) else 0;
    const is_asymmetric = kinds > 1;

    const all_cpuset = hwloc.hwloc_topology_get_topology_cpuset(self.topology);
    const remaining_cpuset = hwloc.hwloc_bitmap_dup(all_cpuset) orelse return error.OutOfMemory;
    defer hwloc.hwloc_bitmap_free(remaining_cpuset);

    const kind_cpusets: []?*hwloc.struct_hwloc_bitmap_s = if (is_asymmetric) try gpa.alloc(?*hwloc.struct_hwloc_bitmap_s, kinds) else undefined;
    defer if (is_asymmetric) gpa.free(kind_cpusets);
    @memset(kind_cpusets, null);
    const kind_effs: []u64 = if (is_asymmetric) try gpa.alloc(u64, kinds) else undefined;
    defer if (is_asymmetric) gpa.free(kind_effs);

    defer if (is_asymmetric) for (kind_cpusets) |cpuset_maybe| if (cpuset_maybe) |cpuset| hwloc.hwloc_bitmap_free(cpuset);
    if (is_asymmetric) for (kind_cpusets, kind_effs, 0..) |*cpuset, *eff, i| {
        cpuset.* = hwloc.hwloc_bitmap_alloc() orelse return error.OutOfMemory;
        var eff_tmp: c_int = 0;
        try do(hwloc.hwloc_cpukinds_get_info(self.topology, @intCast(i), @ptrCast(cpuset), &eff_tmp, null, null, 0));
        eff.* = if (eff_tmp >= 0) @intCast(eff_tmp) else 1000;
    };

    var list = std.array_list.Aligned(SchedulingDomain, null).empty;
    defer list.deinit(gpa);

    var pu_maybe: ?*hwloc.struct_hwloc_obj = hwloc.hwloc_get_next_obj_by_type(self.topology, hwloc.HWLOC_OBJ_PU, null) orelse return error.MisconfiguredHwloc;
    const scratch_cpuset = hwloc.hwloc_bitmap_alloc() orelse return error.OutOfMemory;
    defer hwloc.hwloc_bitmap_free(scratch_cpuset);
    while (pu_maybe) |pu| : (
        pu_maybe = hwloc.hwloc_get_next_obj_inside_cpuset_by_type(self.topology, remaining_cpuset, hwloc.HWLOC_OBJ_PU, pu)
    ) {
        const domain = self.getSharedDomain(pu);
        try do(hwloc.hwloc_bitmap_andnot(remaining_cpuset, remaining_cpuset, domain.cpuset));
        var pu_count: u64 = 0;
        var acc: u64 = 0;
        if (is_asymmetric) for (kind_cpusets, kind_effs) |cpuset, eff| {
            try do(hwloc.hwloc_bitmap_and(scratch_cpuset, cpuset, domain.cpuset));
            const cpuset_weight: u64 = @intCast(hwloc.hwloc_bitmap_weight(scratch_cpuset));
            pu_count += cpuset_weight;
            acc += eff * cpuset_weight;
        };
        try list.append(gpa, .{
            .avg_eff = if (is_asymmetric) acc / pu_count else 1000,
            .cpus = domain.cpuset.?,
        });
    }

    return list.toOwnedSlice(gpa);
}

pub fn deinit(self: *Self) void {
    hwloc.hwloc_topology_destroy(self.topology);
}

test {
    const cpu = Self; // name alias
    var topology = try cpu.init(std.testing.io);
    defer topology.deinit();
    try topology.load();
    const domains = try topology.buildSchedulingDomains(std.testing.allocator);
    defer std.testing.allocator.free(domains);
}
