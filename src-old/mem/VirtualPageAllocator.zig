const std = @import("std");
const builtin = @import("builtin");

pub const VirtualPageAllocator = struct {
    pub const page_size = std.heap.pageSize();

    pub fn reserveVirtualRegion(size: usize) !*u8 {
        std.log.debug("Reserving virtual region: size={}\n", .{size});
        switch (builtin.target.os.tag) {
            .linux => {
                const prot = std.os.linux.PROT {}; // none
                const map_flags = std.os.linux.MAP{
                    .TYPE = std.os.linux.MAP_TYPE.PRIVATE,
                    .ANONYMOUS = true,
                };
                const ptr = std.os.linux.mmap(null, size, prot, map_flags, -1, 0);
                if (ptr == 0) {
                    return error.VirtualMemoryReservationFailed;
                }
                std.log.debug("Reserved virtual region at ptr={}\n", .{@as(*u8, @ptrFromInt(ptr))});
                return @ptrFromInt(ptr);
            },
            else => @compileError("Unsupported OS for virtual memory reservation"),
        }
    }

    pub fn releaseVirtualRegion(ptr: *u8, size: usize) !void {
        std.log.debug("Releasing virtual region: ptr={}, size={}\n", .{ ptr, size });
        switch (builtin.target.os.tag) {
            .linux => {
                return std.posix.munmap(@as([*]align(4096) const u8, @alignCast(@ptrCast(ptr)))[0..size]);
            },
            else => @compileError("Unsupported OS for virtual memory release"),
        }
    }

    pub fn commitVirtualPages(ptr: *u8, size: usize) !void {
        switch (builtin.target.os.tag) {
            .linux => {
                const result = std.os.linux.mprotect(@ptrCast(ptr), size, std.os.linux.PROT { .READ = true, .WRITE = true });
                if (result != 0) {
                    std.log.err("Failed to commit virtual pages: ptr={*}, size={}\n", .{ ptr, size });
                    return error.VirtualMemoryCommitFailed;
                }
                return;
            },
            else => @compileError("Unsupported OS for virtual memory commit"),
        }
    }

    pub fn decommitVirtualPages(ptr: *u8, size: usize) !void {
        switch (builtin.target.os.tag) {
            .linux => {
                const result = std.os.linux.madvise(@ptrCast(ptr), size, std.os.linux.MADV.DONTNEED);
                const guard = std.os.linux.mprotect(@ptrCast(ptr), size, std.os.linux.PROT{});
                if (result != 0) {
                    return error.VirtualMemoryDecommitFailed;
                }
                if (guard != 0) {
                    return error.VirtualMemoryDecommitUnsafe;
                }
                return;
            },
            else => @compileError("Unsupported OS for virtual memory decommit"),
        }
    }
};
