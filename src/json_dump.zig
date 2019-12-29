// The MIT License (Expat)

// Copyright (c) 2015 Andrew Kelley

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

// FOLLOWING CODE THANKS TO @daurnimator (https://github.com/ziglang/zig/pull/3155)

const std = @import("std");
const mem = std.mem;

pub const JsonDumpOptions = struct {
    // TODO: indentation options?
    // TODO: make escaping '/' in strings optional?
};

pub fn dump(
    value: var,
    options: JsonDumpOptions,
    context: var,
    comptime Errors: type,
    output: fn (@TypeOf(context), []const u8) Errors!void,
) Errors!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .Float, .ComptimeFloat => {
            return std.fmt.formatFloatScientific(value, std.fmt.FormatOptions{}, context, Errors, output);
        },
        .Int, .ComptimeInt => {
            return std.fmt.formatIntValue(value, "", std.fmt.FormatOptions{}, context, Errors, output);
        },
        .Bool => {
            return output(context, if (value) "true" else "false");
        },
        .Optional => {
            if (value) |payload| {
                return try dump(payload, options, context, Errors, output);
            } else {
                return output(context, "null");
            }
        },
        .Enum => {
            if (comptime std.meta.trait.hasFn("jsonDump")(T)) {
                return value.jsonDump(options, context, Errors, output);
            }

            @compileError("Unable to dump enum '" ++ @typeName(T) ++ "'");
        },
        .Union => {
            if (comptime std.meta.trait.hasFn("jsonDump")(T)) {
                return value.jsonDump(options, context, Errors, output);
            }

            const info = @typeInfo(T).Union;
            if (info.tag_type) |UnionTagType| {
                inline for (info.fields) |u_field| {
                    if (@enumToInt(@as(UnionTagType, value)) == u_field.enum_field.?.value) {
                        return try dump(@field(value, u_field.name), options, context, Errors, output);
                    }
                }
            } else {
                @compileError("Unable to dump untagged union '" ++ @typeName(T) ++ "'");
            }
        },
        .Struct => |S| {
            if (comptime std.meta.trait.hasFn("jsonDump")(T)) {
                return value.jsonDump(options, context, Errors, output);
            }

            try output(context, "{");
            comptime var field_output = false;
            inline for (S.fields) |Field, field_i| {
                // don't include void fields
                if (Field.field_type == void) continue;

                if (!field_output) {
                    field_output = true;
                } else {
                    try output(context, ",");
                }

                try dump(Field.name, options, context, Errors, output);
                try output(context, ":");
                try dump(@field(value, Field.name), options, context, Errors, output);
            }
            try output(context, "}");
            return;
        },
        .Pointer => |ptr_info| switch (ptr_info.size) {
            .One => {
                // TODO: avoid loops?
                return try dump(value.*, options, context, Errors, output);
            },
            .Slice => {
                if (ptr_info.child == u8) {
                    // TODO: check for un-encodable utf8 first?
                    try output(context, "\"");
                    for (value) |x, i| {
                        switch (x) {
                            // normal ascii characters
                            0x20...0x21, 0x23...0x2E, 0x30...0x5B, 0x5D...0x7F => try output(context, ([1]u8{x})[0..]),
                            // control characters with short escapes
                            '\\' => try output(context, "\\\\"),
                            '\"' => try output(context, "\\\""),
                            '/' => try output(context, "\\/"),
                            0x8 => try output(context, "\\b"),
                            0xC => try output(context, "\\f"),
                            '\n' => try output(context, "\\n"),
                            '\r' => try output(context, "\\r"),
                            '\t' => try output(context, "\\t"),
                            // other control characters
                            0...0x7, 0xB, 0xE...0x1F => try output(context, ([6]u8{ '\\', 'u', '0', '0', '0', '0' + x })[0..]),
                            else => @panic("NYI: unicode"),
                        }
                    }
                    try output(context, "\"");
                    return;
                }

                try output(context, "[");
                for (value) |x, i| {
                    if (i != 0) {
                        try output(context, ",");
                    }
                    try dump(x, options, context, Errors, output);
                }
                try output(context, "]");
                return;
            },
            else => @compileError("Unable to dump type '" ++ @typeName(T) ++ "'"),
        },
        .Array => |info| {
            return try dump(value[0..], options, context, Errors, output);
        },
        else => @compileError("Unable to dump type '" ++ @typeName(T) ++ "'"),
    }
    unreachable;
}

fn testDump(expected: []const u8, value: var) !void {
    const TestDumpContext = struct {
        expected_remaining: []const u8,
        fn testDumpWrite(context: *@This(), bytes: []const u8) !void {
            if (context.expected_remaining.len < bytes.len) {
                std.debug.warn("\n====== expected this output: =========\n", .{});
                std.debug.warn("{}", .{context.expected_remaining});
                std.debug.warn("\n======== instead found this: =========\n", .{});
                std.debug.warn("{}", .{bytes});
                std.debug.warn("\n======================================\n", .{});
                return error.TooMuchData;
            }
            if (!mem.eql(u8, context.expected_remaining[0..bytes.len], bytes)) {
                std.debug.warn("\n====== expected this output: =========\n", .{});
                std.debug.warn("{}", .{context.expected_remaining[0..bytes.len]});
                std.debug.warn("\n======== instead found this: =========\n", .{});
                std.debug.warn("{}", .{bytes});
                std.debug.warn("\n======================================\n", .{});
                return error.DifferentData;
            }
            context.expected_remaining = context.expected_remaining[bytes.len..];
        }
    };
    var buf: [100]u8 = undefined;
    var context = TestDumpContext{ .expected_remaining = expected };
    try dump(value, JsonDumpOptions{}, &context, error{
        TooMuchData,
        DifferentData,
    }, TestDumpContext.testDumpWrite);
    if (context.expected_remaining.len > 0) return error.NotEnoughData;
}

test "dump basic types" {
    try testDump("false", false);
    try testDump("true", true);
    try testDump("null", @as(?u8, null));
    try testDump("null", @as(?*u32, null));
    try testDump("42", 42);
    try testDump("4.2e+01", 42.0);
    try testDump("42", @as(u8, 42));
    try testDump("42", @as(u128, 42));
    try testDump("4.2e+01", @as(f32, 42));
    try testDump("4.2e+01", @as(f64, 42));
}

test "dump string" {
    try testDump("\"hello\"", "hello");
}

test "dump tagged unions" {
    try testDump("42", union(enum) {
        Foo: u32,
        Bar: bool,
    }{ .Foo = 42 });
}

test "dump struct" {
    try testDump("{\"foo\":42}", struct {
        foo: u32,
    }{ .foo = 42 });
}

test "dump struct with void field" {
    try testDump("{\"foo\":42}", struct {
        foo: u32,
        bar: void = {},
    }{ .foo = 42 });
}

test "dump array of structs" {
    const MyStruct = struct {
        foo: u32,
    };
    try testDump("[{\"foo\":42},{\"foo\":100},{\"foo\":1000}]", [_]MyStruct{
        MyStruct{ .foo = 42 },
        MyStruct{ .foo = 100 },
        MyStruct{ .foo = 1000 },
    });
}

test "dump struct with custom dumper" {
    try testDump("[\"something special\",42]", struct {
        foo: u32,
        const Self = @This();
        pub fn jsonDump(
            value: Self,
            options: JsonDumpOptions,
            context: var,
            comptime Errors: type,
            output: fn (@TypeOf(context), []const u8) Errors!void,
        ) !void {
            try output(context, "[\"something special\",");
            try dump(42, options, context, Errors, output);
            try output(context, "]");
        }
    }{ .foo = 42 });
}
