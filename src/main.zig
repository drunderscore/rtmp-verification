const std = @import("std");
const FormKeyValues = @import("FormKeyValues.zig");

const Config = struct {
    const Application = struct {
        keys: [][]u8,
    };

    listen_address: []u8,
    listen_port: u16,
    applications: std.json.ArrayHashMap(Application),
};

var config: Config = undefined;

fn handleRequestImpl(allocator: std.mem.Allocator, response: *std.http.Server.Response) !void {
    try response.wait();

    if (response.request.method != .POST) {
        response.status = .method_not_allowed;
        try response.do();

        return error.InvalidMethod;
    }

    if (response.request.headers.getFirstEntry("Content-Type")) |field| {
        if (!std.mem.eql(u8, field.value, "application/x-www-form-urlencoded")) {
            response.status = .bad_request;
            try response.do();

            return error.InvalidContentType;
        }
    } else {
        response.status = .bad_request;
        try response.do();

        return error.MissingContentType;
    }

    var body: [512]u8 = undefined;
    _ = try response.reader().readAll(&body);

    var form_key_values = try FormKeyValues.parse(allocator, &body);
    defer form_key_values.deinit();

    const client_id = form_key_values.map.get("clientid") orelse return error.MissingClientIdInForm;
    const application_name = form_key_values.map.get("app") orelse return error.MissingAppInForm;
    const call = form_key_values.map.get("call") orelse return error.MissingCallInForm;
    const address = form_key_values.map.get("addr") orelse return error.MissingAddrInForm;
    const name = form_key_values.map.get("name") orelse return error.MissingNameInForm;

    std.log.debug("Client ID {s} ({s}) requesting '{s}' to app '{s}' (key '{s}')\n", .{ client_id, address, call, application_name, name });

    if (config.applications.map.get(application_name)) |application| {
        for (application.keys) |key| {
            if (std.mem.eql(u8, key, name)) {
                std.log.info("Allowing client ID {s} ({s}) requesting '{s}' to app '{s}' (key '{s}')\n", .{ client_id, address, call, application_name, name });

                response.status = .ok;
                try response.do();

                return;
            }
        }

        std.log.warn("Denying client ID {s} ({s}) requesting '{s}' to app '{s}': unauthorized key '{s}'\n", .{ client_id, address, call, application_name, name });
        response.status = .unauthorized;
        try response.do();
    } else {
        std.log.warn("Denying client ID {s} ({s}) requesting '{s}' to app '{s}': application not found\n", .{ client_id, address, call, application_name });

        response.status = .not_found;
        try response.do();
    }
}

fn handleRequest(allocator: std.mem.Allocator, response: std.http.Server.Response) void {
    // FIXME: This is stupid. No explicit move-semantics in Zig, how are we meant to get a non-const pointer to this thing?
    var response_pointer = @as(*std.http.Server.Response, @constCast(&response));

    defer response_pointer.deinit();

    handleRequestImpl(allocator, response_pointer) catch |err| {
        std.log.err("Error ocurred whilst attempting to handle request: {}\n", .{err});
    };
}

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_purpose_allocator.deinit();

    const allocator = general_purpose_allocator.allocator();

    var parsed_config = blk: {
        const config_file = std.fs.cwd().openFile("config.json", .{}) catch |err| {
            std.log.err("Failed to find config.json: {}\n", .{err});
            std.os.exit(1);
        };
        defer config_file.close();

        const config_reader = config_file.reader();
        var config_json_reader = std.json.reader(allocator, config_reader);

        // FIXME: This leaks?
        break :blk std.json.parseFromTokenSource(
            Config,
            allocator,
            &config_json_reader,
            .{},
        ) catch |err| {
            std.log.err("Failed to parse config.json: {}\n", .{err});
            std.os.exit(2);
        };
    };

    defer parsed_config.deinit();

    config = parsed_config.value;

    var server = std.http.Server.init(allocator, .{});
    defer server.deinit();

    const address = std.net.Address.parseIp4(config.listen_address, config.listen_port) catch |err| {
        std.log.err("Failed to create IPv4 address: {}\n", .{err});
        std.os.exit(3);
    };

    server.listen(address) catch |err| {
        std.log.err("Failed to listen: {}\n", .{err});
        std.os.exit(4);
    };

    std.log.info("Listening on {any}\n", .{address});

    while (true) {
        var response = server.accept(.{ .allocator = allocator }) catch |err| {
            std.log.err("Failed to accept request: {}\n", .{err});
            continue;
        };

        _ = try std.Thread.spawn(.{}, handleRequest, .{ allocator, response });
    }
}
