const std = @import("std");
const builtin = @import("builtin");
const z = @import("wgpu");

pub fn createSurfaceFromGlfw(instance: z.handles.Instance, window: ?*anyopaque) !z.handles.Surface {
    return switch (comptime builtin.os.tag) {
        .windows => {
            const win32 = struct {
                const HINSTANCE = *anyopaque;
                const HWND = *anyopaque;
                const LPCWSTR = ?[*:0]const u16;

                extern "c" fn glfwGetWin32Window(window: ?*anyopaque) ?HWND;

                extern "kernel32" fn GetModuleHandleW(lpModuleName: LPCWSTR) callconv(.c) ?HINSTANCE;
            };

            const hwnd = win32.glfwGetWin32Window(window) orelse return error.NoWin32Window;

            const hinstance = win32.GetModuleHandleW(null) orelse return error.NoModuleHandle;

            var surface_source = z.types.SurfaceSourceWindowsHWND{
                .chain = .{ .s_type = .surface_source_windows_hwnd },
                .hinstance = @ptrCast(hinstance),
                .hwnd = @ptrCast(hwnd),
            };

            return instance.createSurface(&z.types.SurfaceDescriptor{
                .next_in_chain = @ptrCast(&surface_source.chain),
            }) orelse error.SurfaceCreationFailed;
        },

        .linux => {
            const linux_glfw = struct {
                extern "c" fn glfwGetWaylandDisplay() ?*anyopaque;
                extern "c" fn glfwGetWaylandWindow(window: ?*anyopaque) ?*anyopaque;
                extern "c" fn glfwGetX11Display() ?*anyopaque;
                extern "c" fn glfwGetX11Window(window: ?*anyopaque) ?*anyopaque;
            };

            // 1. Wayland
            const wl_dpy = linux_glfw.glfwGetWaylandDisplay();
            if (wl_dpy != null) {
                const wl_sfc = linux_glfw.glfwGetWaylandWindow(window);
                if (wl_sfc) |sfc| {
                    std.log.info("[surface.zig] Attempting Wayland surface initialization.", .{});
                    var surface_source = z.types.SurfaceSourceWaylandSurface{
                        .chain = .{ .s_type = .surface_source_wayland_surface },
                        .display = wl_dpy.?,
                        .surface = sfc,
                    };
                    if (instance.createSurface(&z.types.SurfaceDescriptor{
                        .next_in_chain = @ptrCast(&surface_source.chain),
                    })) |surf| return surf else {
                        std.log.warn("[surface.zig] Wayland surface creation failed, falling back...", .{});
                    }
                }
            }

            // 2. X11/Xlib
            if (linux_glfw.glfwGetX11Display()) |x11_dpy| {
                const x11_win = linux_glfw.glfwGetX11Window(window) orelse return error.NoX11Window;
                std.log.info("[surface.zig] Attempting X11/Xlib surface initialization.", .{});

                var surface_source = z.types.SurfaceSourceXlibWindow{
                    .chain = .{ .s_type = .surface_source_xlib_window },
                    .display = x11_dpy,
                    .window = @intCast(@intFromPtr(x11_win)),
                };
                return instance.createSurface(&z.types.SurfaceDescriptor{
                    .next_in_chain = @ptrCast(&surface_source.chain),
                }) orelse error.SurfaceCreationFailed;
            }

            return error.NoValidDisplayBackendFound;
        },

        .macos => {
            const cocoa = struct {
                extern "c" fn glfwGetCocoaWindow(window: ?*anyopaque) ?*anyopaque;
                extern "c" fn objc_getClass(name: [*:0]const u8) callconv(.c) ?*anyopaque;
                extern "c" fn sel_registerName(name: [*:0]const u8) callconv(.c) ?*anyopaque;
                extern "c" fn objc_msgSend(self: ?*anyopaque, op: ?*anyopaque, ...) callconv(.c) ?*anyopaque;
            };

            const ns_window = cocoa.glfwGetCocoaWindow(window) orelse return error.NoCocoaWindow;

            // Get contentView
            const sel_contentView = cocoa.sel_registerName("contentView");
            const content_view = cocoa.objc_msgSend(ns_window, sel_contentView);

            // Create CAMetalLayer
            const metal_layer_class = cocoa.objc_getClass("CAMetalLayer") orelse return error.NoMetalLayerClass;
            const sel_alloc = cocoa.sel_registerName("alloc");
            const sel_init = cocoa.sel_registerName("init");
            const layer = cocoa.objc_msgSend(
                cocoa.objc_msgSend(metal_layer_class, sel_alloc),
                sel_init,
            );

            // Set layer on content view
            const sel_setLayer = cocoa.sel_registerName("setLayer:");
            _ = cocoa.objc_msgSend(content_view, sel_setLayer, layer);

            const sel_setWantsLayer = cocoa.sel_registerName("setWantsLayer:");
            _ = cocoa.objc_msgSend(content_view, sel_setWantsLayer, @as(c_long, 1));

            std.log.info("[surface.zig] Initializing via macOS Metal layer.", .{});
            var surface_source = z.types.SurfaceSourceMetalLayer{
                .chain = .{ .s_type = .surface_source_metal_layer },
                .layer = layer,
            };

            return instance.createSurface(&z.types.SurfaceDescriptor{
                .next_in_chain = @ptrCast(&surface_source.chain),
            }) orelse error.SurfaceCreationFailed;
        },

        else => @compileError("Unsupported target OS for WebGPU surface creation"),
    };
}
