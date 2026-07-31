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
    var final: [self.writer.end]u8 = undefined;
    @memcpy(&final, buffer[0..self.writer.end]);
    const finalfinal = final;
    return &finalfinal;
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

/// Writes a cleaned-up version of a type name, preserving pointer symbols.
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

/// Returns the final component of a fully qualified name.
/// - `std.array.List` > `List`
/// - `symbol` > `symbol` (trims surrounding spaces)
fn finalName(segment: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, segment, '.')) |dot_idx| {
        var start = dot_idx + 1;
        while (start < segment.len and segment[start] == ' ') start += 1;
        return segment[start..];
    }
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

                // Fix: Use exact matching for must_unfold to prevent substring false positives
                const should_unfold = self.config.unfold_all or blk: {
                    var it = std.mem.splitScalar(u8, self.config.must_unfold, ',');
                    while (it.next()) |name| {
                        if (std.mem.eql(u8, std.mem.trim(u8, name, " "), type_name)) break :blk true;
                    }
                    break :blk false;
                };

                const is_anon = std.mem.indexOf(u8, base, "__") != null;
                const is_tuple = switch (info) { .@"struct" => |s| s.is_tuple, else => false };

                if (!is_anon and !is_tuple and !should_unfold) {
                    return self.writeCleanName(type_name);
                }

                // Fix: Prevent infinite recursion by respecting max_depth
                if (self.level > self.config.max_depth) {
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
        .@"fn" => |f| {
            // Fix: Generic functions cannot be represented as type literals in Zig
            if (f.is_generic or f.return_type == null) {
                try self.writeCleanName(type_name);
            } else {
                try self.writeFn(f);
            }
        },
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

    if (ptr.attrs.@"allowzero") try self.writer.writeAll("allowzero ");
    if (ptr.attrs.@"volatile") try self.writer.writeAll("volatile ");

    const def_align = switch (@typeInfo(ptr.child)) {
        .@"opaque", .@"fn" => 1,
        else => @alignOf(ptr.child),
    };
    if (ptr.attrs.@"align") |ali| if (ali != def_align) try self.writer.print("align({d}) ", .{ali});
    if (ptr.attrs.@"addrspace" != null and ptr.attrs.@"addrspace".? != .generic) try self.writer.print("addrspace(.{s}) ", .{@tagName(ptr.address_space)});
    if (ptr.attrs.@"const") try self.writer.writeAll("const ");
    try self.writeType(ptr.child);
}

fn writeStruct(self: *Self, comptime s: std.builtin.Type.Struct) !void {
    if (s.is_tuple) {
        try self.writer.writeAll("struct { ");
        for (s.field_types, 0..) |ft, i| {
            try self.writeType(ft);
            if (i < s.field_types.len - 1) try self.writer.writeAll(", ");
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

    for (s.field_names, s.field_types, s.field_attrs) |name, ft, attrs| {
        try self.writeIndent();
        if (attrs.@"comptime") try self.writer.writeAll("comptime ");
        try self.writer.print("{s}: ", .{name});
        try self.writeType(ft);

        const def_align = if (s.layout == .@"packed") 0 else @alignOf(ft);
        if (attrs.@"align") |ali| if (ali != def_align) try self.writer.print(" align({d})", .{ali});

        if (attrs.default_value_ptr) |ptr| {
            try self.writer.writeAll(" = ");
            try self.writeValue(ft, getComptimeValue(ft, ptr));
        }
        try self.writer.writeAll(",\n");
    }
    try self.writeBlockClose();
}

fn writeFn(self: *Self, comptime f: std.builtin.Type.Fn) !void {
    try self.writer.writeAll("fn (");
    for (f.param_attrs, f.param_types, 0..) |param_attrs, param_type, i| {
        if (param_attrs.@"noalias") try self.writer.writeAll("noalias ");
        if (f.is_generic or param_type == null) {
            try self.writer.writeAll("anytype");
        } else {
            try self.writeType(param_type.?);
        }
        if (i < f.param_attrs.len - 1) try self.writer.writeAll(", ");
    }

    if (f.attrs.varargs) {
        if (f.param_attrs.len > 0) try self.writer.writeAll(", ");
        try self.writer.writeAll("...");
    }
    try self.writer.writeAll(") ");

    if (f.attrs.@"callconv" != .auto) {
        try self.writer.writeAll("callconv(");
        var cc_tag: []const u8 = @tagName(f.attrs.@"callconv");

        switch (f.attrs.@"callconv") {
            inline else => |payload| {
                if (@TypeOf(payload) == void) {
                    try self.writer.print(".{s}", .{cc_tag});
                } else if (blk: {
                    for (@typeInfo(std.builtin.CallingConvention).@"union".decl_names) |decl_name| {
                        const value = @field(std.builtin.CallingConvention, decl_name);
                        if (@TypeOf(value) == type) continue;
                        if (std.meta.eql(f.attrs.@"callconv", value)) {
                            cc_tag = decl_name;
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

    // Generic return types are caught in `writeType`, so `rt` should be valid here.
    if (f.return_type) |rt| {
        try self.writeType(rt);
    } else {
        try self.writer.writeAll("void");
    }
}

fn writeErrorSet(self: *Self, comptime error_set: std.builtin.Type.ErrorSet) !void {
    if (error_set.error_names) |errors| {
        try self.writer.writeAll("error{");
        for (errors, 0..) |err, i| {
            try self.writer.writeAll(err);
            if (i < errors.len - 1) try self.writer.writeAll(",");
        }
        try self.writer.writeAll("}");
    } else {
        try self.writer.writeAll("anyerror");
    }
}

fn writeEnum(self: *Self, comptime e: std.builtin.Type.Enum) !void {
    // Fix: Prevent panic on `log2_int_ceil` when enum has 0 fields
    const default_bits: usize = if (e.mode == .exhaustive and e.field_names.len > 0)
        std.math.log2_int_ceil(usize, e.field_names.len)
    else 0;

    if (e.mode == .exhaustive and default_bits == @bitSizeOf(e.tag_type)) {
        try self.writeBlockOpen("enum");
    } else {
        try self.writer.writeAll("enum(");
        try self.writeType(e.tag_type);
        try self.writeBlockOpen(")");
    }

    for (e.field_names, e.field_values, 0..) |field_name, field_value, default_value| {
        try self.writeIndent();
        try self.writer.writeAll(field_name);
        if (field_value != default_value) try self.writer.print(" = {any}", .{field_value});
        try self.writer.writeAll(",\n");
    }
    if (e.mode == .nonexhaustive) {
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

    for (u.field_names, u.field_attrs, u.field_types) |name, attrs, @"type"| {
        try self.writeIndent();
        try self.writer.print("{s}: ", .{name});
        try self.writeType(@"type");
        if (attrs.@"align") |ali| if (ali != @alignOf(@"type")) try self.writer.print(" align({d})", .{ali});
        try self.writer.writeAll(",\n");
    }
    try self.writeBlockClose();
}

pub fn writeValue(self: *Self, comptime T: type, comptime val: T) !void {
    // Note: Zig provides no native way to detect if a comptime value is `undefined`.
    // If a default value is literally `undefined`, evaluating it may trigger a compile error.
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
        .error_union => {
            // Fix: Missing error_union formatting
            if (val) |payload| {
                try self.writeValue(@TypeOf(payload), payload);
            } else |err| {
                try self.writeValue(@TypeOf(err), err);
            }
        },
        .void => try self.writer.writeAll("{}"),
        .optional => {
            if (val) |v| {
                try self.writeValue(@TypeOf(v), v);
            } else {
                try self.writer.writeAll("null");
            }
        },
        .@"struct" => |s| {
            if (s.field_names.len == 0) {
                try self.writer.writeAll(".{}");
            } else if (s.is_tuple) {
                self.level += 1;
                try self.writer.writeAll(".{ ");
                inline for (s.field_names, s.field_types, 0..) |name, ft, i| {
                    try self.writeValue(ft, @field(val, name));
                    if (i < s.field_names.len - 1) try self.writer.writeAll(", ");
                }
                try self.writer.writeAll(" }");
                self.level -= 1;
            } else if (s.field_names.len > 1) {
                self.level += 1;
                try self.writer.writeAll(".{\n");
                inline for (s.field_names, s.field_types) |name, ft| {
                    try self.writeIndent();
                    try self.writer.print(".{s} = ", .{name});
                    try self.writeValue(ft, @field(val, name));
                    try self.writer.writeAll(",\n");
                }
                self.level -= 1;
                try self.writeIndent();
                try self.writer.writeAll("}");
            } else {
                self.level += 1;
                const name = s.field_names[0];
                const ft = s.field_types[0];
                try self.writer.print(".{{ .{s} = ", .{name});
                try self.writeValue(ft, @field(val, name));
                self.level -= 1;
                try self.writer.writeAll(" }");
            }
        },
        .array => |a| {
            self.level += 1;
            defer self.level -= 1;
            if (val.len != 0 and std.mem.allEqual(a.child, &val, val[0])) {
                try self.writer.writeAll("[_]");
                try self.writeType(a.child);
                try self.writer.writeAll("{");
                try self.writeValue(a.child, val[0]);
                try self.writer.print("}} ** {d}", .{a.len});
                return;
            }
            try self.writer.writeAll(".{ ");
            for (val, 0..) |v, i| {
                try self.writeValue(@TypeOf(v), v);
                if (i < val.len - 1) try self.writer.writeAll(", ");
            }
            try self.writer.writeAll(" }");
        },
        .vector => |v| {
            // Fix: Missing vector formatting
            self.level += 1;
            defer self.level -= 1;
            try self.writer.writeAll(".{ ");
            inline for (0..v.len) |i| {
                try self.writeValue(v.child, val[i]);
                if (i < v.len - 1) try self.writer.writeAll(", ");
            }
            try self.writer.writeAll(" }");
        },
        .pointer => |p| {
            if (p.size == .slice) {
                if (p.child == u8 and p.attrs.@"const") {
                    // Fix: Properly escape string literals
                    try self.writer.writeByte('"');
                    for (val) |c| {
                        switch (c) {
                            '"' => try self.writer.writeAll("\\\""),
                            '\\' => try self.writer.writeAll("\\\\"),
                            '\n' => try self.writer.writeAll("\\n"),
                            '\r' => try self.writer.writeAll("\\r"),
                            '\t' => try self.writer.writeAll("\\t"),
                            else => {
                                if (std.ascii.isPrint(c)) {
                                    try self.writer.writeByte(c);
                                } else {
                                    try self.writer.print("\\x{x:0>2}", .{c});
                                }
                            },
                        }
                    }
                    try self.writer.writeByte('"');
                } else {
                    // Fix: Correctly emit array literals for non-u8 slices
                    self.level += 1;
                    defer self.level -= 1;
                    try self.writer.writeAll("&.{ ");
                    for (val, 0..) |v, i| {
                        try self.writeValue(p.child, v);
                        if (i < val.len - 1) try self.writer.writeAll(", ");
                    }
                    try self.writer.writeAll(" }");
                }
            } else if (p.size == .one) {
                if (@typeInfo(p.child) == .@"fn") {
                    try self.writer.writeAll("<function>");
                    return;
                }
                self.level += 1;
                defer self.level -= 1;
                try self.writer.writeAll("&");
                if (self.level > self.config.max_depth) {
                    try self.writer.writeAll("<too deep>");
                } else {
                    try self.writeValue(p.child, val.*);
                }
            } else {
                try self.writer.writeAll("<pointer>");
            }
        },
        .@"fn" => {
            // Fix: Function values cannot be resolved to names
            try self.writer.writeAll("<function>");
        },
        .@"union" => |u| {
            // Fix: Missing union formatting
            self.level += 1;
            defer self.level -= 1;
            try self.writer.writeAll(".{ ");
            if (u.tag_type) |_| {
                const tag = std.meta.activeTag(val);
                inline for (u.field_names, u.field_types) |field_name, field_type| {
                    if (std.mem.eql(u8, field_name, @tagName(tag))) {
                        try self.writer.print(".{s} = ", .{field_name});
                        try self.writeValue(field_type, @field(val, field_name));
                        break;
                    }
                }
            } else {
                // Untagged unions cannot be safely inspected at comptime to find the active field
                try self.writer.writeAll("<untagged union value>");
            }
            try self.writer.writeAll(" }");
        },
        .@"opaque" => {
            try self.writer.writeAll("opaque {}");
        },
        else => try self.writer.print("{any}", .{val}),
    }
}
