const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const json_key_prefix = "json_";

pub const DecodeOptions = struct {
    ignoreMissing: bool = false,
};

fn fieldCount(comptime T: type) usize {
    const typeInfo = @typeInfo(T);
    if (typeInfo != .Struct) @compileError("Attempted to call fieldCount() on a non struct");
    comptime var count = 0;
    inline for (typeInfo.Struct.fields) |field| {
        if (!mem.startsWith(u8, field.name, json_key_prefix)) {
            count += 1;
        }
    }
    return count;
}

pub fn Decodable(comptime T: type) type {
    const info = @typeInfo(T);
    return struct {
        const Self = @This();

        const Error = mem.Allocator.Error || error{MissingField};

        pub fn fromJson(options: DecodeOptions, allocator: *mem.Allocator, node: var) Error!T {
            var item: *T = try allocator.create(T);
            if (info != .Struct) unreachable;
            // hot path for missing
            if (!options.ignoreMissing and fieldCount(T) != node.count()) return error.MissingField;
            inline for (info.Struct.fields) |field| {
                const maybeJsonMapping = json_key_prefix ++ field.name;
                const fieldName = field.name;
                const accessorKey = if (@hasDecl(T, maybeJsonMapping)) @field(T, maybeJsonMapping) else field.name;
                const fieldTypeInfo = @typeInfo(field.field_type);
                if (node.get(accessorKey)) |obj| {
                    if (fieldTypeInfo == .Struct) { // complex json type
                        const generatedType = Decodable(field.field_type);
                        @field(item, fieldName) = try generatedType.fromJson(options, allocator, obj.value.Object);
                    } else if (fieldTypeInfo == .Pointer and field.field_type != []const u8) { // strings are handled
                        const arrayType = fieldTypeInfo.Pointer.child;
                        const values = obj.value.Array;
                        var dest = try allocator.alloc(arrayType, values.toSliceConst().len);
                        if (isNaiveJSONType(arrayType)) {
                            for (values.toSliceConst()) |value, index| {
                                dest[index] = switch (arrayType) {
                                    i64 => value.Integer,
                                    f64 => value.Float,
                                    bool => value.Bool,
                                    []const u8 => value.String,
                                    else => unreachable,
                                };
                            }
                        } else {
                            const generatedArrayType = Decodable(arrayType);
                            for (values.toSliceConst()) |value, index| {
                                dest[index] = try generatedArrayType.fromJson(options, allocator, value.Object);
                            }
                        }
                        @field(item, fieldName) = dest;
                    } else if (fieldTypeInfo == .Optional) {
                        if (obj.value == .Null) {
                            @field(item, fieldName) = null;
                        } else {
                            const childType = fieldTypeInfo.Optional.child;
                            assignRawType(item, fieldName, childType, obj);
                        }
                    } else {
                        assignRawType(item, fieldName, field.field_type, obj);
                    }
                } else if (!options.ignoreMissing) return error.MissingField;
            }
            return item.*;
        }
    };
}

fn isNaiveJSONType(comptime T: type) bool {
    return switch (T) {
        i64, f64, []const u8, bool => true,
        else => false,
    };
}

fn assignRawType(destination: var, comptime fieldName: []const u8, comptime fieldType: type, object: var) void {
    switch (fieldType) {
        i64 => @field(destination, fieldName) = object.value.Integer,
        f64 => @field(destination, fieldName) = object.value.Float,
        bool => @field(destination, fieldName) = object.value.Bool,
        []const u8 => @field(destination, fieldName) = object.value.String,
        else => @compileError(@typeName(fieldType) ++ " is not supported"),
    }
}

const TestSkeleton = struct {
    int: i64,
    isCool: bool,
    float: f64,
    language: []const u8,
    optional: ?bool,
    array: []f64,

    const Bar = struct {
        nested: []const u8,
    };
    complex: Bar,

    const Baz = struct {
        foo: []const u8,
    };
    veryComplex: []Baz,
};
const TestStruct = Decodable(TestSkeleton);

test "JSON Mapping works" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    var p = std.json.Parser.init(allocator, false);
    defer p.deinit();
    const tree = try p.parse("{\"TEST_EXPECTED\": 1}");
    const S = Decodable(struct {
        expected: i64,
        pub const json_expected: []const u8 = "TEST_EXPECTED";
    });
    const s = try S.fromJson(.{}, allocator, tree.root.Object);
}

test "NoIgnore works" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    var p = std.json.Parser.init(allocator, false);
    defer p.deinit();
    const tree = try p.parse("{}");
    const S = Decodable(struct {
        expected: i64,
    });
    const attempt = S.fromJson(.{}, allocator, tree.root.Object);
    std.testing.expectError(error.MissingField, attempt);
}

test "Decode works" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    const json =
        \\{
        \\  "int": 420,
        \\  "float": 3.14,
        \\  "isCool": true,
        \\  "language": "zig",
        \\  "optional": null,
        \\  "array": [66.6, 420.420, 69.69],
        \\  "complex": {
        \\    "nested": "zig"
        \\  },
        \\  "veryComplex": [
        \\    {
        \\      "foo": "zig"
        \\    }, {
        \\      "foo": "rocks"
        \\    }
        \\  ]
        \\}
    ;
    var p = std.json.Parser.init(allocator, false);
    defer p.deinit();
    const tree = try p.parse(json);
    const testStruct = try TestStruct.fromJson(.{}, allocator, tree.root.Object);
    testing.expectEqual(testStruct.int, 420);
    testing.expectEqual(testStruct.float, 3.14);
    testing.expectEqual(testStruct.isCool, true);
    testing.expect(mem.eql(u8, testStruct.language, "zig"));
    testing.expectEqual(testStruct.optional, null);
    testing.expect(mem.eql(u8, testStruct.complex.nested, "zig"));
    testing.expectEqual(testStruct.array[0], 66.6);
    testing.expectEqual(testStruct.array[1], 420.420);
    testing.expectEqual(testStruct.array[2], 69.69);
    testing.expect(mem.eql(u8, testStruct.veryComplex[0].foo, "zig"));
    testing.expect(mem.eql(u8, testStruct.veryComplex[1].foo, "rocks"));
}

// FOLLOWING CODE THANKS TO @DAURNIMATOR

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
