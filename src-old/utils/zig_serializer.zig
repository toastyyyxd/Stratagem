const std = @import("std");
const Writer = std.Io.Writer;
const Self = @This();

const WRITER_BUFFER_SIZE = 65536;

pub const Config = struct {
    must_unfold: []const u8 = "",
    unfold_all: bool = false,
    max_depth: usize = 8,
};

writer: Writer,
level: usize,
config: Config,

pub fn init(writer: Writer, config: Config) Self {
    return Self{
        .writer = writer,
        .level = 0,
        .config = config,
    };
}

pub fn generateDecl(comptime target_name: []const u8, comptime T: type, config: Config) []const u8 {
    var buffer: [WRITER_BUFFER_SIZE]u8 = undefined;
    var self = Self.init(Writer.fixed(&buffer), config);
    self.writer.print("pub const {s} = ", .{target_name}) catch @compileError("Buffer overflow");
    self.writeType(T) catch |e| {
        if (e == Writer.Error.WriteFailed) @compileError("Buffer overflow");
        @compileError("Declaration generation crashed.");
    };
    self.writer.writeAll(";") catch @compileError("Buffer overflow");
    return buffer[0..self.writer.end];
}

fn writeIndent(self: *Self) !void {
    try self.writer.splatByteAll(' ', self.level * 4);
}

fn writeBlockOpen(self: *Self, comptime prefix: []const u8) !void {
    try self.writer.writeAll(prefix);
    try self.writer.writeAll(" {\n");
    self.level += 1;
}

fn writeBlockClose(self: *Self) !void {
    self.level -= 1;
    try self.writeIndent();
    try self.writer.writeAll("}");
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// - `std.array.List` > `List`
/// - `*const std.mem.Slice` > `*const Slice`  
/// - `?i32` > `?i32`
/// - `*.` > `*.`
fn writeCleanName(self: *Self, comptime name: []const u8) !void {
    var i: usize = 0;
    while (i < name.len) {
        const c = name[i];
        // keep non-symbol characters
        if (!isIdentChar(c)) {
            try self.writer.writeByte(c);
            i += 1;
            continue;
        }
        // start of a symbol
        const segment_start = i;
        while (i < name.len) {
            const ch = name[i];
            if (!isIdentChar(ch) and ch != '.' and ch != ' ') break;
            i += 1;
        }
        // get the last symbol
        const segment = name[segment_start..i];
        const final_name = finalName(segment);
        try self.writer.writeAll(final_name);
    }
}

/// - `std.array.List` > `List`
/// - `some_file_or_struct_symbol__1234 List` > `List`
fn finalName(segment: []const u8) []const u8 {
    // find the last dot to split off the final component
    if (std.mem.lastIndexOfScalar(u8, segment, '.')) |dot_idx| {
        var start = dot_idx + 1;
        // skip any spaces immediately after the dot
        while (start < segment.len and segment[start] == ' ') start += 1;
        return segment[start..];
    }
    // no dot, return the segment with surrounding spaces trimmed
    return std.mem.trim(u8, segment, " ");
}

fn getComptimeValue(comptime T: type, comptime ptr: *const anyopaque) T {
    return @as(*const T, @ptrCast(@alignCast(ptr))).*;
}

pub fn writeType(self: *Self, comptime T: type) !void {
    const info = @typeInfo(T);
    const type_name = @typeName(T);

    if (self.level > 0) {
        switch (info) {
            .@"struct", .@"enum", .@"union" => {
                const paren_idx = std.mem.indexOfScalar(u8, type_name, '(') orelse type_name.len;
                const base = type_name[0..paren_idx];
                const should_unfold = self.config.unfold_all or std.mem.indexOf(u8, self.config.must_unfold, type_name) != null;
                const is_anon = std.mem.indexOf(u8, base, "__") != null;
                const is_tuple = switch (info) { .@"struct" => |s| s.is_tuple, else => false };
                if (!is_anon and !is_tuple and !should_unfold) {
                    return self.writeCleanName(type_name);
                }
            },
            else => {},
        }
    }

    switch (info) {
        .int => |i| try self.writer.print("{c}{d}", .{ if (i.signedness == .signed) 'i' else 'u', i.bits }),
        .float => |f| try self.writer.print("f{d}", .{f.bits}),
        .@"opaque" => try self.writer.writeAll("anyopaque"),
        .optional => |opt| {
            try self.writer.writeAll("?");
            try self.writeType(opt.child);
        },
        .vector => |v| {
            try self.writer.print("@Vector({d}, ", .{v.len});
            try self.writeType(v.child);
            try self.writer.writeAll(")");
        },
        .array => |arr| try self.writeArray(arr),
        .pointer => |ptr| try self.writePointer(ptr),
        .@"struct" => |s| try self.writeStruct(s),
        .@"fn" => |f| try self.writeFn(f),
        .error_set => |err_set| try self.writeErrorSet(err_set),
        .error_union => |err_union| {
            try self.writeType(err_union.error_set);
            try self.writer.writeAll("!");
            try self.writeType(err_union.payload);
        },
        .@"enum" => |e| try self.writeEnum(e),
        .@"union" => |u| try self.writeUnion(u),
        .void => try self.writer.writeAll("void"),
        .bool => try self.writer.writeAll("bool"),
        .type => try self.writer.writeAll("type"),
        .comptime_int => try self.writer.writeAll("comptime_int"),
        .comptime_float => try self.writer.writeAll("comptime_float"),
        .enum_literal => try self.writer.writeAll("@TypeOf(.enum_literal)"),
        else => try self.writeCleanName(type_name),
    }
}

fn writeArray(self: *Self, comptime arr: std.builtin.Type.Array) !void {
    try self.writer.print("[{d}", .{arr.len});
    if (arr.sentinel_ptr) |s| {
        try self.writer.writeAll(":");
        try self.writeValue(arr.child, getComptimeValue(arr.child, s));
    }
    try self.writer.writeAll("]");
    try self.writeType(arr.child);
}

fn writePointer(self: *Self, comptime ptr: std.builtin.Type.Pointer) !void {
    const prefix = switch (ptr.size) {
        .slice => "[",
        .one => "*",
        .many => "[*",
        .c => "[*c",
    };
    try self.writer.writeAll(prefix);
    if (ptr.sentinel_ptr) |s| try self.writer.print(":{any}", .{getComptimeValue(ptr.child, s)});
    if (ptr.size != .one) try self.writer.writeAll("]");

    if (ptr.is_allowzero) try self.writer.writeAll("allowzero ");
    if (ptr.is_volatile) try self.writer.writeAll("volatile ");

    const def_align = switch (@typeInfo(ptr.child)) {
        .@"opaque", .@"fn" => 1,
        else => @alignOf(ptr.child),
    };
    if (ptr.alignment != def_align) try self.writer.print("align({d}) ", .{ptr.alignment});
    if (ptr.address_space != .generic) try self.writer.print("addrspace(.{s}) ", .{@tagName(ptr.address_space)});
    if (ptr.is_const) try self.writer.writeAll("const ");
    try self.writeType(ptr.child);
}

fn writeStruct(self: *Self, comptime s: std.builtin.Type.Struct) !void {
    if (s.is_tuple) {
        try self.writer.writeAll("struct { ");
        for (s.fields, 0..) |f, i| {
            try self.writeType(f.type);
            if (i < s.fields.len - 1) try self.writer.writeAll(", ");
        }
        try self.writer.writeAll(" }");
        return;
    }

    const layout = switch (s.layout) {
        .auto => "struct",
        .@"extern" => "extern struct",
        .@"packed" => "packed struct",
    };
    if (s.layout == .@"packed") {
        if (s.backing_integer) |BI| {
            try self.writer.print("{s}(", .{layout});
            try self.writeType(BI);
            try self.writeBlockOpen(")");
        } else {
            try self.writeBlockOpen(layout);
        }
    } else {
        try self.writeBlockOpen(layout);
    }

    for (s.fields) |f| {
        try self.writeIndent();
        if (f.is_comptime) try self.writer.writeAll("comptime ");
        try self.writer.print("{s}: ", .{f.name});
        try self.writeType(f.type);

        const def_align = if (s.layout == .@"packed") 0 else @alignOf(f.type);
        if (f.alignment != def_align) try self.writer.print(" align({d})", .{f.alignment});

        if (f.default_value_ptr) |ptr| {
            try self.writer.writeAll(" = ");
            try self.writeValue(f.type, getComptimeValue(f.type, ptr));
        }
        try self.writer.writeAll(",\n");
    }
    try self.writeBlockClose();
}

fn writeFn(self: *Self, comptime f: std.builtin.Type.Fn) !void {
    try self.writer.writeAll("fn (");
    for (f.params, 0..) |p, i| {
        if (p.is_noalias) try self.writer.writeAll("noalias ");
        if (p.is_generic or p.type == null) {
            try self.writer.writeAll("anytype");
        } else {
            try self.writeType(p.type.?);
        }
        if (i < f.params.len - 1) try self.writer.writeAll(", ");
    }

    if (f.is_var_args) {
        if (f.params.len > 0) try self.writer.writeAll(", ");
        try self.writer.writeAll("...");
    }
    try self.writer.writeAll(") ");

    if (f.calling_convention != .auto) {
        try self.writer.writeAll("callconv(");
        var cc_tag: []const u8 = @tagName(f.calling_convention);

        switch (f.calling_convention) {
            inline else => |payload| {
                if (@TypeOf(payload) == void) {
                    try self.writer.print(".{s}", .{cc_tag});
                } else if (blk: {
                    for (@typeInfo(std.builtin.CallingConvention).@"union".decls) |d| {
                        const value = @field(std.builtin.CallingConvention, d.name);
                        if (@TypeOf(value) == type) continue;
                        if (std.meta.eql(f.calling_convention, value)) {
                            cc_tag = d.name;
                            break :blk true;
                        }
                    }
                    break :blk false;
                }) {
                    try self.writer.print(".{s}", .{cc_tag});
                } else {
                    try self.writer.print(".{{ .{s} = ", .{cc_tag});
                    try self.writeValue(@TypeOf(payload), payload);
                    try self.writer.writeAll(" }");
                }
            },
        }
        try self.writer.writeAll(") ");
    }

    if (f.return_type) |rt| {
        try self.writeType(rt);
    } else {
        try self.writer.writeAll("anytype");
    }
}

fn writeErrorSet(self: *Self, comptime error_set: ?[]const std.builtin.Type.Error) !void {
    if (error_set) |errors| {
        try self.writer.writeAll("error{");
        for (errors, 0..) |err, i| {
            try self.writer.writeAll(err.name);
            if (i < errors.len - 1) try self.writer.writeAll(",");
        }
        try self.writer.writeAll("}");
    } else {
        try self.writer.writeAll("anyerror");
    }
}

fn writeEnum(self: *Self, comptime e: std.builtin.Type.Enum) !void {
    const default_bits: usize =
        if (e.is_exhaustive) std.math.log2_int_ceil(usize, e.fields.len) else 0;

    if (e.is_exhaustive and default_bits == @bitSizeOf(e.tag_type)) {
        try self.writeBlockOpen("enum");
    } else {
        try self.writer.writeAll("enum(");
        try self.writeType(e.tag_type);
        try self.writeBlockOpen(")");
    }

    for (e.fields, 0..) |field, default_value| {
        try self.writeIndent();
        try self.writer.writeAll(field.name);
        if (field.value != default_value) try self.writer.print(" = {any}", .{field.value});
        try self.writer.writeAll(",\n");
    }
    if (!e.is_exhaustive) {
        try self.writeIndent();
        try self.writer.writeAll("_,\n");
    }
    try self.writeBlockClose();
}

fn writeUnion(self: *Self, comptime u: std.builtin.Type.Union) !void {
    const layout = switch (u.layout) {
        .auto => "union",
        .@"extern" => "extern union",
        .@"packed" => "packed union",
    };

    if (u.tag_type) |Tag| {
        try self.writer.print("{s}(", .{layout});
        const tag_name = @typeName(Tag);
        const is_inferred = std.mem.indexOf(u8, tag_name, "__union") != null;
        if (is_inferred) try self.writer.writeAll("enum") else try self.writeType(Tag);
        try self.writeBlockOpen(")");
    } else {
        try self.writeBlockOpen(layout);
    }

    for (u.fields) |field| {
        try self.writeIndent();
        try self.writer.print("{s}: ", .{field.name});
        try self.writeType(field.type);
        if (field.alignment != @alignOf(field.type)) try self.writer.print(" align({d})", .{field.alignment});
        try self.writer.writeAll(",\n");
    }
    try self.writeBlockClose();
}

pub fn writeValue(self: *Self, comptime T: type, comptime val: T) !void {
    if (T == type) {
        try self.writeType(val);
        return;
    }
    switch (@typeInfo(T)) {
        .int, .comptime_int => try self.writer.print("{d}", .{val}),
        .float, .comptime_float => try self.writer.print("{d}", .{val}),
        .bool => try self.writer.print("{}", .{val}),
        .@"enum", .enum_literal => try self.writer.print(".{s}", .{@tagName(val)}),
        .error_set => try self.writer.print("error.{s}", .{@errorName(val)}),
        .void => try self.writer.writeAll("{}"),
        .optional => {
            if (val) |v| {
                try self.writeValue(@TypeOf(v), v);
            } else {
                try self.writer.writeAll("null");
            }
        },
        .@"struct" => |s| {
            if (s.fields.len == 0) {
                try self.writer.writeAll(".{}");
            } else if (s.is_tuple) {
                try self.writer.writeAll(".{ ");
                inline for (s.fields, 0..) |field, i| {
                    try self.writeValue(field.type, @field(val, field.name));
                    if (i < s.fields.len - 1) try self.writer.writeAll(", ");
                }
                try self.writer.writeAll(" }");
            } else if (s.fields.len > 1) {
                try self.writer.writeAll(".{\n");
                self.level += 1;
                inline for (s.fields) |field| {
                    try self.writeIndent();
                    try self.writer.print(".{s} = ", .{field.name});
                    try self.writeValue(field.type, @field(val, field.name));
                    try self.writer.writeAll(",\n");
                }
                self.level -= 1;
                try self.writeIndent();
                try self.writer.writeAll("}");
            } else {
                const field = s.fields[0];
                try self.writer.print(".{{ .{s} = ", .{field.name});
                try self.writeValue(field.type, @field(val, field.name));
                try self.writer.writeAll(" }");
            }
        },
        .array => |a| {
            if (val.len != 0 and std.mem.allEqual(a.child, &val, val[0])) {
                try self.writer.writeAll("[_]");
                try self.writeType(a.child);
                try self.writer.writeAll("{");
                try self.writeValue(a.child, val[0]);
                try self.writer.print("}} ** {d}", .{ a.len });
                return;
            }
            try self.writer.writeAll(".{ ");
            for (val, 0..) |v, i| {
                try self.writeValue(@TypeOf(v), v);
                if (i < val.len - 1) try self.writer.writeAll(", ");
            }
            try self.writer.writeAll(" }");
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                try self.writer.print("\"{s}\"", .{val});
            } else if (p.size == .one) {
                try self.writer.writeAll("&");
                if (self.level > self.config.max_depth) try self.writer.writeAll("<too deep>")
                else try self.writeValue(p.child, val.*);
            } else {
                try self.writer.writeAll("<pointer to ");
                try self.writeType(p.child);
                try self.writer.writeAll(">");
            }
        },
        .@"fn" => |f| {
            try self.writer.writeAll("<naked ");
            try self.writeFn(f);
            try self.writer.writeAll(">");
        },
        .@"opaque" => {
            try self.writer.writeAll("opaque {}");
        },
        else => try self.writer.print("{any}", .{val}),
    }
}