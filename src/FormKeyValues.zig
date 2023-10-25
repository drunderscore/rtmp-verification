const std = @import("std");
const Self = @This();

map: std.StringHashMap([]u8),

pub fn parse(allocator: std.mem.Allocator, body: []const u8) !Self {
    var key_values = Self{
        .map = std.StringHashMap([]u8).init(allocator),
    };

    var body_split = std.mem.split(u8, body, "&");

    while (body_split.next()) |key_value| {
        // Have to split the key and value BEFORE unescaping it, otherwise unescaping it may reveal more equal signs.
        var key_value_split = std.mem.split(u8, key_value, "=");

        var key: ?[]u8 = null;
        var value: ?[]u8 = null;

        errdefer {
            if (key) |unwrapped_key|
                allocator.free(unwrapped_key);

            if (value) |unwrapped_value|
                allocator.free(unwrapped_value);

            key_values.deinit();
        }

        while (key_value_split.next()) |key_or_value| {
            if (key != null and value != null)
                return error.InvalidKeyValuePair;

            const unescaped_key_or_value = try std.Uri.unescapeString(allocator, key_or_value);
            errdefer allocator.free(unescaped_key_or_value);

            if (key == null) {
                key = unescaped_key_or_value;
            } else if (value == null) {
                value = unescaped_key_or_value;
            } else {
                unreachable;
            }
        }

        try key_values.map.put(key.?, value.?);
    }

    return key_values;
}

pub fn deinit(self: *Self) void {
    var map_iterator = self.map.iterator();

    while (map_iterator.next()) |key_value| {
        self.map.allocator.free(key_value.key_ptr.*);
        self.map.allocator.free(key_value.value_ptr.*);
    }

    self.map.deinit();
}
