const std = @import("std");
const builtin = @import("builtin");
// linux and macos use posix at best effort or posix.system
const windows = @import("win32");

fn checkAlign(n: usize) error{OffsetUnaligned}!void {
    const alignment = if (@inComptime()) std.heap.page_size_min else std.heap.pageSize();
    if (std.mem.isAligned(n, alignment)) return;
    return error.OffsetUnaligned;
}

pub fn reserveVirtualRegion(size: usize) !usize {
    try checkAlign(size);
    switch (builtin.target.os.tag) {
        .linux, .macos => {
            const prot = std.posix.PROT{};
            const map_flags = std.posix.MAP{
                .TYPE = .PRIVATE,
                .ANONYMOUS = true,
            };
            const slice = std.posix.mmap(null, size, prot, map_flags, -1, 0) catch |err| switch (err) {
                error.OutOfMemory, error.LockedMemoryLimitExceeded => return error.OutOfMemory,
                else => return error.VirtualMemoryReserveFailed,
            };
            return @intFromPtr(slice.ptr);
        },
        .windows => {
            const alloc = windows.system.memory.VIRTUAL_ALLOCATION_TYPE{
                .RESERVE = 1,
            };
            const prot = windows.system.memory.PAGE_PROTECTION_FLAGS{
                .PAGE_READWRITE = 1,
            };
            const maybe_ptr = windows.system.memory.VirtualAlloc(null, size, alloc, prot);
            if (maybe_ptr) |p| {
                return @intFromPtr(p);
            }
            const err = windows.foundation.GetLastError();
            switch (err) {
                windows.foundation.ERROR_OUTOFMEMORY, windows.foundation.ERROR_COMMITMENT_LIMIT => return error.OutOfMemory,
                else => return error.VirtualMemoryReserveFailed,
            }
        },
        else => @compileError("Unsupported OS for virtual memory reservation"),
    }
}

pub fn releaseVirtualRegion(ptr: usize, size: usize) !void {
    try checkAlign(ptr);
    try checkAlign(size);
    switch (builtin.target.os.tag) {
        .linux, .macos => {
            const addr: [*]align(std.heap.page_size_min) const u8 = @alignCast(@ptrCast(@as(*const anyopaque, @ptrFromInt(ptr))));
            std.posix.munmap(addr[0..size]);
        },
        .windows => {
            const res = windows.system.memory.VirtualFree(@ptrFromInt(ptr), 0, .RELEASE);
            if (res == 0) return error.VirtualMemoryReleaseFailed;
        },
        else => @compileError("Unsupported OS for virtual memory release"),
    }
}

pub fn commitVirtualPages(ptr: usize, size: usize) !void {
    try checkAlign(ptr);
    try checkAlign(size);
    switch (builtin.target.os.tag) {
        .linux, .macos => {
            const addr: [*]align(std.heap.page_size_min) u8 = @alignCast(@ptrCast(@as(*anyopaque, @ptrFromInt(ptr))));
            const result = std.posix.system.mprotect(addr, size, .{ .READ = true, .WRITE = true });
            if (result == 0) return;
            const err: std.posix.E = @enumFromInt(-result);
            switch (err) {
                std.posix.E.NOMEM => return error.OutOfMemory,
                else => return error.VirtualMemoryReserveFailed,
            }
        },
        .windows => {
            const alloc = windows.system.memory.VIRTUAL_ALLOCATION_TYPE{
                .COMMIT = 1,
            };
            const prot = windows.system.memory.PAGE_PROTECTION_FLAGS{
                .PAGE_READWRITE = 1,
            };
            const maybe_ptr = windows.system.memory.VirtualAlloc(@ptrFromInt(ptr), size, alloc, prot);
            if (maybe_ptr) |p| {
                if (@intFromPtr(p) == ptr) return
                else return error.VirtualMemoryCommitUnaligned;
            }
            const err = windows.foundation.GetLastError();
            switch (err) {
                windows.foundation.ERROR_OUTOFMEMORY, windows.foundation.ERROR_COMMITMENT_LIMIT => return error.OutOfMemory,
                else => return error.VirtualMemoryReserveFailed,
            }
        },
        else => @compileError("Unsupported OS for virtual memory commit"),
    }
}

pub fn decommitVirtualPages(ptr: usize, size: usize) !void {
    try checkAlign(ptr);
    try checkAlign(size);
    switch (builtin.target.os.tag) {
        .linux, .macos => {
            const addr: [*]align(std.heap.page_size_min) u8 = @alignCast(@ptrCast(@as(*anyopaque, @ptrFromInt(ptr))));
            try std.posix.madvise(addr, size, std.posix.MADV.DONTNEED);
            const guard = std.posix.system.mprotect(addr, size, .{});
            if (guard != 0) return error.VirtualMemoryDecommitUnsafe;
        },
        .windows => {
            const res = windows.system.memory.VirtualFree(@ptrFromInt(ptr), size, .DECOMMIT);
            if (res == 0) return error.VirtualMemoryDecommitFailed;
        },
        else => @compileError("Unsupported OS for virtual memory decommit"),
    }
}
