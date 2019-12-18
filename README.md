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
  
  // json key mapping 
  const json_key: []const u8 = "oddly_named_key";
};

const FleshedType = Decodable(Skeleton);
//...
const json = 
  \\{"oddly_named_key": "test"}
;
const foo = try FleshedType.fromJson(.{}, allocator, (try parser.parse(json)).root.Object);
```

# Features
- [x] Map json keys to struct fields
- [x] Dump objects as JSON
- [x] Create custom decode functions specifically tailored to skeleton structs

# TODO
- [x] Alternative key names
