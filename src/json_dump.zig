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
    // TODO: allow picking if []u8 is string or array?
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
            // TODO: .Many when there is a sentinel (waiting for https://github.com/ziglang/zig/pull/3972)
            .Slice => {
                if (ptr_info.child == u8 and std.unicode.utf8ValidateSlice(value)) {
                    try output(context, "\"");
                    var i: usize = 0;
                    while (i < value.len) : (i += 1) {
                        switch (value[i]) {
                            // normal ascii characters
                            0x20...0x21, 0x23...0x2E, 0x30...0x5B, 0x5D...0x7F => try output(context, value[i .. i + 1]),
                            // control characters with short escapes
                            '\\' => try output(context, "\\\\"),
                            '\"' => try output(context, "\\\""),
                            '/' => try output(context, "\\/"),
                            0x8 => try output(context, "\\b"),
                            0xC => try output(context, "\\f"),
                            '\n' => try output(context, "\\n"),
                            '\r' => try output(context, "\\r"),
                            '\t' => try output(context, "\\t"),
                            else => {
                                const ulen = std.unicode.utf8ByteSequenceLength(value[i]) catch unreachable;
                                const codepoint = std.unicode.utf8Decode(value[i .. i + ulen]) catch unreachable;
                                if (codepoint <= 0xFFFF) {
                                    // If the character is in the Basic Multilingual Plane (U+0000 through U+FFFF),
                                    // then it may be represented as a six-character sequence: a reverse solidus, followed
                                    // by the lowercase letter u, followed by four hexadecimal digits that encode the character's code point.
                                    try output(context, "\\u");
                                    try std.fmt.formatIntValue(codepoint, "x", std.fmt.FormatOptions{ .width = 4, .fill = '0' }, context, Errors, output);
                                } else {
                                    // To escape an extended character that is not in the Basic Multilingual Plane,
                                    // the character is represented as a 12-character sequence, encoding the UTF-16 surrogate pair.
                                    const high = @intCast(u16, (codepoint - 0x10000) >> 10) + 0xD800;
                                    const low = @intCast(u16, codepoint & 0x3FF) + 0xDC00;
                                    try output(context, "\\u");
                                    try std.fmt.formatIntValue(high, "x", std.fmt.FormatOptions{ .width = 4, .fill = '0' }, context, Errors, output);
                                    try output(context, "\\u");
                                    try std.fmt.formatIntValue(low, "x", std.fmt.FormatOptions{ .width = 4, .fill = '0' }, context, Errors, output);
                                }
                                i += ulen - 1;
                            },
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
                std.debug.warn(
                    \\====== expected this output: =========
                    \\{}
                    \\======== instead found this: =========
                    \\{}
                    \\======================================
                , .{
                    context.expected_remaining,
                    bytes,
                });
                return error.TooMuchData;
            }
            if (!mem.eql(u8, context.expected_remaining[0..bytes.len], bytes)) {
                std.debug.warn(
                    \\====== expected this output: =========
                    \\{}
                    \\======== instead found this: =========
                    \\{}
                    \\======================================
                , .{
                    context.expected_remaining[0..bytes.len],
                    bytes,
                });
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
    try testDump("\"with\\nescapes\\r\"", "with\nescapes\r");
    try testDump("\"with unicode\\u0001\"", "with unicode\u{1}");
    try testDump("\"with unicode\\u0080\"", "with unicode\u{80}");
    try testDump("\"with unicode\\u00ff\"", "with unicode\u{FF}");
    try testDump("\"with unicode\\u0100\"", "with unicode\u{100}");
    try testDump("\"with unicode\\u0800\"", "with unicode\u{800}");
    try testDump("\"with unicode\\u8000\"", "with unicode\u{8000}");
    try testDump("\"with unicode\\ud799\"", "with unicode\u{D799}");
    try testDump("\"with unicode\\ud800\\udc00\"", "with unicode\u{10000}");
    try testDump("\"with unicode\\udbff\\udfff\"", "with unicode\u{10FFFF}");
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
