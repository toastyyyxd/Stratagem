const std = @import("std");
const serializer = @import("../utils/zig_serializer.zig");

const TestItems = struct {
    pub fn GenericType(comptime T: type, comptime value: T) type {
        return struct {
            data: T = value,
            id: u32,
        };
    }
    pub fn uselessFunction() void {}
    pub const Status = enum { ok, err };
    pub const Hammer = struct {
        // primitives
        a: u32,
        b: f64,
        c: bool,
        d: void,
        e: type,
        f: comptime_int = 42,
        // pointers and arrays
        g: *const [5:0]u8,
        h: []align(16) const i32,
        i: [4]GenericType(bool, false),
        // errors unions
        j: error{ AccessDenied, OutOfMemory }!f32,
        k: anyerror!void,
        // enums
        l: enum { red, blue, green },
        m: enum(u16) { start = 0, stop = 100, _ },
        // unions
        n: union(enum) {
            val: i32,
            name: []const u8,
        },
        o: union(Status) {
            ok: u32,
            err: []const u8,
        },
        // special
        p: @Vector(4, f32),
        q: @TypeOf(.this_should_be_an_enum_literal),
        // nested packed and tuples
        r: packed struct(u32) {
            tag: u8,
            data: u24,
        },
        s: struct { u32, f32, bool }, // Tuple detection
        // nested again
        t: struct {
            inner: struct {
                val: i8,
            },
        },
        // functions
        u: *const fn () void,
        v: *const fn (u32, f32) bool,
        w: *const fn (noalias *u32) void,
        x: *const fn (anytype) void,
        y: *const fn (u32, ...) callconv(.{ .x86_64_win = .{} }) void,
        z: *const fn () callconv(.c) void,
        // horrifying pointer
        aa: [*:0]allowzero align(64) const volatile u8,
        // function pointer, should emit <naked ...> as best effort
        bb: *const fn () void = &uselessFunction,
        // more defaults
        cc: struct { foo: u32, bar: []const u8 } = .{ .foo = 123, .bar = "stratageming it" },
        dd: [3]enum { one, two, three } = .{ .one, .two, .three },
        ee: ?f64 = 3.14159,
        ff: ?f64 = null,
        gg: union(enum) { a: i32, b: bool } = .{ .b = true },
    };
};

test "try to generate declaration from some vomit of a type - should match expected" {
    const expected = 
        \\pub const Hammer = struct {
        \\    a: u32,
        \\    b: f64,
        \\    c: bool,
        \\    d: void,
        \\    e: type,
        \\    f: comptime_int = 42,
        \\    g: *const [5:0]u8,
        \\    h: []align(16) const i32,
        \\    i: [4]GenericType(bool,false),
        \\    j: error{AccessDenied,OutOfMemory}!f32,
        \\    k: anyerror!void,
        \\    l: enum {
        \\        red,
        \\        blue,
        \\        green,
        \\    },
        \\    m: enum(u16) {
        \\        start,
        \\        stop = 100,
        \\        _,
        \\    },
        \\    n: union(enum) {
        \\        val: i32,
        \\        name: []const u8,
        \\    },
        \\    o: union(Status) {
        \\        ok: u32,
        \\        err: []const u8,
        \\    },
        \\    p: @Vector(4, f32),
        \\    q: @TypeOf(.enum_literal),
        \\    r: packed struct(u32) {
        \\        tag: u8,
        \\        data: u24,
        \\    },
        \\    s: struct { u32, f32, bool },
        \\    t: struct {
        \\        inner: struct {
        \\            val: i8,
        \\        },
        \\    },
        \\    u: *const fn () void,
        \\    v: *const fn (u32, f32) bool,
        \\    w: *const fn (noalias *u32) void,
        \\    x: *const fn (anytype) void,
        \\    y: *const fn (u32, ...) callconv(.winapi) void,
        \\    z: *const fn () callconv(.c) void,
        \\    aa: [*:0]allowzero volatile align(64) const u8,
        \\    bb: *const fn () void = &<naked fn () void>,
        \\    cc: struct {
        \\        foo: u32,
        \\        bar: []const u8,
        \\    } = .{ .foo = 123, .bar = "stratageming it" },
        \\    dd: [3]enum {
        \\        one,
        \\        two,
        \\        three,
        \\    } = .{ .one, .two, .three },
        \\    ee: ?f64 = 3.14159,
        \\    ff: ?f64 = null,
        \\    gg: union(enum) {
        \\        a: i32,
        \\        b: bool,
        \\    } = .{ .b = true },
        \\};
        \\
    ;

    comptime {
        try std.testing.expectEqualStrings(expected, serializer.generateDecl("Hammer", TestItems.Hammer));
    }
}
