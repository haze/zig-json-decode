# zig-json-decode

To use, simply clone and link in your zig project

# Example
```zig
// ./build.zig =====
exe.addPackagePath("zig-json-decode", "zig-json-decode/src/main.zig");

// ./src/main.zig =====
const Decodable = @import("zig-json-decode").Decodable;
const Skeleton = struct {
  key: []const u8,
};

const FleshedType = Decodable(Skeleton);
//...
const foo = try FleshedType.fromJson(.{}, allocator, (try parser.parse(json)).root.Object);
```

# TODO
- [ ] Alternative key names
