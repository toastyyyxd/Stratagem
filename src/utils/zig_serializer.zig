const std = @import("std");
const Writer = std.Io.Writer;

const WRITER_BUFFER_SIZE = 65536;

pub fn generateDecl(comptime target_name: []const u8, comptime T: type) []const u8 {
    comptime {
        var buffer: [WRITER_BUFFER_SIZE]u8 = undefined;
        var writer = Writer.fixed(&buffer);

        writer.print("pub const {s} = ", .{target_name}) catch @compileError("Buffer overflow");
        writeType(&writer, T, 0) catch |e| {
            if (e == Writer.Error.WriteFailed) @compileError("Buffer overflow");
            @compileError("Declaration generation crashed.");
        };
        writer.writeAll(";\n") catch @compileError("Buffer overflow");

        return buffer[0..writer.end];
    }
}

fn writeIndent(writer: *Writer, level: usize) !void {
    try writer.splatByteAll(' ', level * 4);
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// - `std.array.List` > `List`
/// - `*const std.mem.Slice` > `*const Slice`  
/// - `?i32` > `?i32`
/// - `*.` > `*.`
fn writeCleanName(writer: *Writer, comptime name: []const u8) !void {
    var i: usize = 0;
    while (i < name.len) {
        const c = name[i];
        // keep non-symbol characters
        if (!isIdentChar(c)) {
            try writer.writeByte(c);
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
        try writer.writeAll(final_name);
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

pub fn writeType(writer: *Writer, comptime T: type, comptime level: usize) !void {
    const info = @typeInfo(T);
    const type_name = @typeName(T);

    if (level > 0) {
        switch (info) {
            .@"struct", .@"enum", .@"union", => {
                const paren_idx = std.mem.indexOfScalar(u8, type_name, '(') orelse type_name.len;
                const base = type_name[0..paren_idx];
                const is_anon = std.mem.indexOf(u8, base, "__") != null;
                if (!is_anon and switch (info) { .@"struct" => |s| !s.is_tuple, else => true}) return writeCleanName(writer, type_name);
            },
            else => {},
        }
    }

    switch (info) {
        .int => |i| try writer.print("{c}{d}", .{ if (i.signedness == .signed) 'i' else 'u', i.bits }),
        .float => |f| try writer.print("f{d}", .{f.bits}),
        .@"opaque" => try writer.writeAll("anyopaque"),
        .optional => |opt| {
            try writer.writeAll("?");
            try writeType(writer, opt.child, level);
        },
        .vector => |v| {
            try writer.print("@Vector({d}, ", .{v.len});
            try writeType(writer, v.child, level);
            try writer.writeAll(")");
        },
        .array => |arr| try writeArray(writer, arr, level),
        .pointer => |ptr| try writePointer(writer, ptr, level),
        .@"struct" => |s| try writeStruct(writer, s, level),
        .@"fn" => |f| try writeFn(writer, f, level),
        .error_set => |err_set| try writeErrorSet(writer, err_set),
        .error_union => |err_union| {
            try writeType(writer, err_union.error_set, level);
            try writer.writeAll("!");
            try writeType(writer, err_union.payload, level);
        },
        .@"enum" => |e| try writeEnum(writer, e, level),
        .@"union" => |u| try writeUnion(writer, u, level),
        .void => try writer.writeAll("void"),
        .bool => try writer.writeAll("bool"),
        .type => try writer.writeAll("type"),
        .comptime_int => try writer.writeAll("comptime_int"),
        .comptime_float => try writer.writeAll("comptime_float"),
        .enum_literal => try writer.writeAll("@TypeOf(.enum_literal)"),
        else => try writeCleanName(writer, type_name),
    }
}

fn writeArray(writer: *Writer, comptime arr: std.builtin.Type.Array, comptime level: usize) !void {
    try writer.print("[{d}", .{arr.len});
    if (arr.sentinel_ptr) |s| try writer.print(":{any}", .{getComptimeValue(arr.child, s)});
    try writer.writeAll("]");
    try writeType(writer, arr.child, level);
}

fn writePointer(writer: *Writer, comptime ptr: std.builtin.Type.Pointer, comptime level: usize) !void {
    const prefix = switch (ptr.size) {
        .slice => "[",
        .one => "*",
        .many => "[*",
        .c => "[*c",
    };
    try writer.writeAll(prefix);
    if (ptr.sentinel_ptr) |s| try writer.print(":{any}", .{getComptimeValue(ptr.child, s)});
    if (ptr.size != .one) try writer.writeAll("]");

    if (ptr.is_allowzero) try writer.writeAll("allowzero ");
    if (ptr.is_volatile) try writer.writeAll("volatile ");

    const def_align = switch (@typeInfo(ptr.child)) {
        .@"opaque", .@"fn" => 1,
        else => @alignOf(ptr.child),
    };
    if (ptr.alignment != def_align) try writer.print("align({d}) ", .{ptr.alignment});
    if (ptr.address_space != .generic) try writer.print("addrspace(.{s}) ", .{@tagName(ptr.address_space)});
    if (ptr.is_const) try writer.writeAll("const ");
    try writeType(writer, ptr.child, level);
}

fn writeStruct(writer: *Writer, comptime s: std.builtin.Type.Struct, comptime level: usize) !void {
    if (s.is_tuple) {
        try writer.writeAll("struct { ");
        for (s.fields, 0..) |f, i| {
            try writeType(writer, f.type, level);
            if (i < s.fields.len - 1) try writer.writeAll(", ");
        }
        try writer.writeAll(" }");
        return;
    }

    const layout = switch (s.layout) {
        .auto => "struct",
        .@"extern" => "extern struct",
        .@"packed" => "packed struct",
    };
    try writer.writeAll(layout);
    if (s.layout == .@"packed") {
        if (s.backing_integer) |BI| {
            try writer.writeAll("(");
            try writeType(writer, BI, level);
            try writer.writeAll(")");
        }
    }
    try writer.writeAll(" {\n");

    for (s.fields) |f| {
        try writeIndent(writer, level + 1);
        if (f.is_comptime) try writer.writeAll("comptime ");
        try writer.print("{s}: ", .{f.name});
        try writeType(writer, f.type, level + 1);

        const def_align = if (s.layout == .@"packed") 0 else @alignOf(f.type);
        if (f.alignment != def_align) try writer.print(" align({d})", .{f.alignment});

        if (f.default_value_ptr) |ptr| {
            try writer.writeAll(" = ");
            try writeValue(writer, f.type, getComptimeValue(f.type, ptr), level + 1);
        }
        try writer.writeAll(",\n");
    }
    try writeIndent(writer, level);
    try writer.writeAll("}");
}

fn writeFn(writer: *Writer, comptime f: std.builtin.Type.Fn, comptime level: usize) !void {
    try writer.writeAll("fn (");
    for (f.params, 0..) |p, i| {
        if (p.is_noalias) try writer.writeAll("noalias ");
        if (p.is_generic or p.type == null) {
            try writer.writeAll("anytype");
        } else {
            try writeType(writer, p.type.?, level);
        }
        if (i < f.params.len - 1) try writer.writeAll(", ");
    }

    if (f.is_var_args) {
        if (f.params.len > 0) try writer.writeAll(", ");
        try writer.writeAll("...");
    }
    try writer.writeAll(") ");

    if (f.calling_convention != .auto) {
        try writer.writeAll("callconv(");
        var cc_tag: []const u8 = @tagName(f.calling_convention);

        switch (f.calling_convention) {
            inline else => |payload| {
                if (@TypeOf(payload) == void) {
                    try writer.print(".{s}", .{cc_tag});
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
                    try writer.print(".{s}", .{cc_tag});
                } else {
                    try writer.print(".{{ .{s} = ", .{cc_tag});
                    try writeValue(writer, @TypeOf(payload), payload, level + 1);
                    try writer.writeAll(" }");
                }
            },
        }
        try writer.writeAll(") ");
    }

    if (f.return_type) |rt| {
        try writeType(writer, rt, level);
    } else {
        try writer.writeAll("anytype");
    }
}

fn writeErrorSet(writer: *Writer, comptime error_set: ?[]const std.builtin.Type.Error) !void {
    if (error_set) |errors| {
        try writer.writeAll("error{");
        for (errors, 0..) |err, i| {
            try writer.writeAll(err.name);
            if (i < errors.len - 1) try writer.writeAll(",");
        }
        try writer.writeAll("}");
    } else {
        try writer.writeAll("anyerror");
    }
}

fn writeEnum(writer: *Writer, comptime e: std.builtin.Type.Enum, comptime level: usize) !void {
    const default_bits: usize =
        if (e.is_exhaustive) std.math.log2_int_ceil(usize, e.fields.len) else 0;

    if (e.is_exhaustive and default_bits == @bitSizeOf(e.tag_type)) {
        try writer.writeAll("enum {\n");
    } else {
        try writer.writeAll("enum(");
        try writeType(writer, e.tag_type, level);
        try writer.writeAll(") {\n");
    }

    for (e.fields, 0..) |field, default_value| {
        try writeIndent(writer, level + 1);
        try writer.writeAll(field.name);
        if (field.value != default_value) try writer.print(" = {any}", .{field.value});
        try writer.writeAll(",\n");
    }
    if (!e.is_exhaustive) {
        try writeIndent(writer, level + 1);
        try writer.writeAll("_,\n");
    }
    try writeIndent(writer, level);
    try writer.writeAll("}");
}

fn writeUnion(writer: *Writer, comptime u: std.builtin.Type.Union, comptime level: usize) !void {
    const layout = switch (u.layout) {
        .auto => "union",
        .@"extern" => "extern union",
        .@"packed" => "packed union",
    };
    try writer.writeAll(layout);

    if (u.tag_type) |Tag| {
        try writer.writeAll("(");
        const tag_name = @typeName(Tag);
        const is_inferred = std.mem.indexOf(u8, tag_name, "__union") != null;
        if (is_inferred) try writer.writeAll("enum") else try writeType(writer, Tag, level + 1);
        try writer.writeAll(")");
    }

    try writer.writeAll(" {\n");
    for (u.fields) |field| {
        try writeIndent(writer, level + 1);
        try writer.print("{s}: ", .{field.name});
        try writeType(writer, field.type, level + 2);
        if (field.alignment != @alignOf(field.type)) try writer.print(" align({d})", .{field.alignment});
        try writer.writeAll(",\n");
    }
    try writeIndent(writer, level);
    try writer.writeAll("}");
}

pub fn writeValue(writer: *Writer, comptime T: type, comptime val: T, comptime level: usize) !void {
    if (T == type) {
        try writeType(writer, val, 0);
        return;
    }
    switch (@typeInfo(T)) {
        .int, .comptime_int => try writer.print("{d}", .{val}),
        .float, .comptime_float => try writer.print("{d}", .{val}),
        .bool => try writer.print("{}", .{val}),
        .@"enum", .enum_literal => try writer.print(".{s}", .{@tagName(val)}),
        .error_set => try writer.print("error.{s}", .{@errorName(val)}),
        .void => try writer.writeAll("{}"),
        .optional => {
            if (val) |v| {
                try writeValue(writer, @TypeOf(v), v, level + 1);
            } else {
                try writer.writeAll("null");
            }
        },
        .@"struct" => |s| {
            if (s.fields.len == 0) {
                try writer.writeAll(".{}");
            } else if (s.is_tuple) {
                try writer.writeAll(".{ ");
                inline for (s.fields, 0..) |field, i| {
                    try writeValue(writer, field.type, @field(val, field.name), level + 1);
                    if (i < s.fields.len - 1) try writer.writeAll(", ");
                }
                try writer.writeAll(" }");
            } else {
                try writer.writeAll(".{ ");
                inline for (s.fields, 0..) |field, i| {
                    try writer.print(".{s} = ", .{field.name});
                    try writeValue(writer, field.type, @field(val, field.name), level + 1);
                    if (i < s.fields.len - 1) try writer.writeAll(", ");
                }
                try writer.writeAll(" }");
            }
        },
        .array => {
            try writer.writeAll(".{ ");
            for (val, 0..) |v, i| {
                try writeValue(writer, @TypeOf(v), v, level + 1);
                if (i < val.len - 1) try writer.writeAll(", ");
            }
            try writer.writeAll(" }");
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                try writer.print("\"{s}\"", .{val});
            } else if (p.size == .one) {
                try writer.writeAll("&");
                try writeValue(writer, p.child, val.*, level + 1);
            } else {
                // Handle slices, many, c pointers differently
                try writer.writeAll("<pointer to ");
                try writeType(writer, p.child, level + 1);
                try writer.writeAll(">");
            }
        },
        .@"fn" => |f| {
            try writer.writeAll("<naked ");
            try writeFn(writer, f, level + 1);
            try writer.writeAll(">");
        },
        .@"opaque" => {
            try writer.writeAll("opaque {}");
        },
        else => try writer.print("{any}", .{val}),
    }
}