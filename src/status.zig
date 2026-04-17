const std = @import("std");
const std_compat = @import("compat");
const Config = @import("config.zig").Config;
const version = @import("version.zig");
const channel_catalog = @import("channel_catalog.zig");
const cron = @import("cron.zig");
const health = @import("health.zig");
const json_util = @import("json_util.zig");

fn printUsage() void {
    std.debug.print("Usage: nullclaw status [--json]\n", .{});
}

fn printStdoutBytes(text: []const u8) void {
    std_compat.fs.File.stdout().writeAll(text) catch return;
}

fn appendNullableString(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: ?[]const u8) !void {
    if (value) |text| {
        try json_util.appendJsonString(buf, allocator, text);
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn overallStatus(snapshot: health.HealthSnapshot) []const u8 {
    var saw_starting = false;
    var iter = snapshot.components.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.status, "error")) return "error";
        if (!std.mem.eql(u8, entry.value_ptr.status, "ok")) saw_starting = true;
    }
    return if (saw_starting) "starting" else "ok";
}

fn appendComponentJson(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    component: health.ComponentHealth,
) !void {
    try json_util.appendJsonKey(buf, allocator, name);
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonKeyValue(buf, allocator, "status", component.status);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(buf, allocator, "updated_at", component.updated_at[0..component.updated_at_len]);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "last_ok");
    if (component.last_ok) |last_ok| {
        try json_util.appendJsonString(buf, allocator, last_ok[0..component.last_ok_len]);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "last_error");
    try appendNullableString(buf, allocator, component.last_error);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "restart_count", @intCast(component.restart_count));
    try buf.appendSlice(allocator, "}");
}

pub fn buildRuntimeStatusJson(allocator: std.mem.Allocator) ![]u8 {
    const snapshot = health.snapshot();

    var names = std.ArrayListUnmanaged([]const u8).empty;
    defer names.deinit(allocator);

    var iter = snapshot.components.iterator();
    while (iter.next()) |entry| {
        try names.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonKeyValue(&buf, allocator, "version", version.string);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "pid", snapshot.pid);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "uptime_seconds", @intCast(snapshot.uptime_seconds));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "overall_status", overallStatus(snapshot));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "components");
    try buf.appendSlice(allocator, "{");
    for (names.items, 0..) |name, idx| {
        if (idx > 0) try buf.appendSlice(allocator, ",");
        try appendComponentJson(&buf, allocator, name, snapshot.components.get(name).?);
    }
    try buf.appendSlice(allocator, "}}");

    return try buf.toOwnedSlice(allocator);
}

fn printGatewayRuntimeStatusJson(allocator: std.mem.Allocator) bool {
    switch (cron.requestGatewayGet(allocator, "/status")) {
        .unavailable => return false,
        .response => |resp| {
            defer allocator.free(resp.body);
            if (resp.status_code < 200 or resp.status_code >= 300) return false;
            printStdoutBytes(resp.body);
            if (resp.body.len == 0 or resp.body[resp.body.len - 1] != '\n') {
                printStdoutBytes("\n");
            }
            return true;
        },
    }
}

pub fn run(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    const json_mode = blk: {
        if (sub_args.len == 0) break :blk false;
        if (sub_args.len == 1 and std.mem.eql(u8, sub_args[0], "--json")) break :blk true;
        printUsage();
        std_compat.process.exit(1);
    };

    if (json_mode) {
        if (printGatewayRuntimeStatusJson(allocator)) return;

        const status_json = buildRuntimeStatusJson(allocator) catch |err| {
            std.debug.print("Failed to build status JSON: {s}\n", .{@errorName(err)});
            std_compat.process.exit(1);
        };
        defer allocator.free(status_json);

        printStdoutBytes(status_json);
        printStdoutBytes("\n");
        return;
    }

    var buf: [4096]u8 = undefined;
    var bw = std_compat.fs.File.stdout().writer(&buf);
    const w = &bw.interface;

    var cfg = Config.load(allocator) catch {
        try w.print("nullclaw Status (no config found -- run `nullclaw onboard` first)\n", .{});
        try w.print("\nVersion: {s}\n", .{version.string});
        try w.flush();
        return;
    };
    defer cfg.deinit();

    try w.print("nullclaw Status\n\n", .{});
    try w.print("Version:     {s}\n", .{version.string});
    try w.print("Workspace:   {s}\n", .{cfg.workspace_dir});
    try w.print("Config:      {s}\n", .{cfg.config_path});
    try w.print("\n", .{});
    try w.print("Provider:    {s}\n", .{cfg.default_provider});
    try w.print("Model:       {s}\n", .{cfg.default_model orelse "(default)"});
    try w.print("Temperature: {d:.1}\n", .{cfg.temperature});
    try w.print("\n", .{});
    try w.print("Memory:      {s} (auto-save: {s})\n", .{
        cfg.memory_backend,
        if (cfg.memory_auto_save) "on" else "off",
    });
    try w.print("Heartbeat:   {s}\n", .{
        if (cfg.heartbeat_enabled) "enabled" else "disabled",
    });
    try w.print("Security:    autonomy={s}, workspace_only={s}, max_actions/hr={d}\n", .{
        cfg.autonomy.level.toString(),
        if (cfg.workspace_only) "yes" else "no",
        cfg.max_actions_per_hour,
    });
    try w.print("\n", .{});

    // Diagnostics
    try w.print("Diagnostics:   {s}\n", .{cfg.diagnostics.backend});

    // Runtime
    try w.print("Runtime:     {s}\n", .{cfg.runtime.kind});

    // Gateway
    try w.print("Gateway:     {s}:{d}\n", .{ cfg.gateway_host, cfg.gateway_port });

    // Scheduler
    try w.print("Scheduler:   {s} (max_tasks={d}, max_concurrent={d})\n", .{
        if (cfg.scheduler.enabled) "enabled" else "disabled",
        cfg.scheduler.max_tasks,
        cfg.scheduler.max_concurrent,
    });

    // Cost tracking
    try w.print("Cost:        {s}\n", .{
        if (cfg.cost.enabled) "tracking enabled" else "disabled",
    });

    // Hardware
    try w.print("Hardware:    {s}\n", .{
        if (cfg.hardware.enabled) "enabled" else "disabled",
    });

    // Peripherals
    try w.print("Peripherals: {s} ({d} boards)\n", .{
        if (cfg.peripherals.enabled) "enabled" else "disabled",
        cfg.peripherals.boards.len,
    });

    // Sandbox
    try w.print("Sandbox:     {s}\n", .{
        if (cfg.sandboxEnabled()) "enabled" else "disabled",
    });

    // Audit
    try w.print("Audit:       {s}\n", .{
        if (cfg.security.audit.enabled) "enabled" else "disabled",
    });

    try w.print("\n", .{});

    // Channels
    try w.print("Channels:\n", .{});
    for (channel_catalog.known_channels) |meta| {
        var status_buf: [64]u8 = undefined;
        const status_text = if (meta.id == .cli)
            "always"
        else
            channel_catalog.statusText(&cfg, meta, &status_buf);
        try w.print("  {s}: {s}\n", .{ meta.label, status_text });
    }

    try w.flush();
}

test "buildRuntimeStatusJson reports healthy components" {
    health.reset();
    defer health.reset();

    health.markComponentOk("gateway");
    health.markComponentOk("scheduler");

    const json = try buildRuntimeStatusJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"overall_status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"components\":{\"gateway\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scheduler\":{\"status\":\"ok\"") != null);
}

test "buildRuntimeStatusJson reports unhealthy components" {
    health.reset();
    defer health.reset();

    health.markComponentOk("gateway");
    health.markComponentError("scheduler", "connection refused");

    const json = try buildRuntimeStatusJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"overall_status\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"last_error\":\"connection refused\"") != null);
}
