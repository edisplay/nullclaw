const std = @import("std");
const root = @import("root.zig");
const config_types = @import("../config_types.zig");
const bus_mod = @import("../bus.zig");

const log = std.log.scoped(.teams);

/// Microsoft Teams channel — Bot Framework REST API for outbound, webhook for inbound.
/// Uses Azure AD OAuth2 client credentials flow for authentication.
pub const TeamsChannel = struct {
    allocator: std.mem.Allocator,
    account_id: []const u8 = "default",
    client_id: []const u8,
    client_secret: []const u8,
    tenant_id: []const u8,
    webhook_secret: ?[]const u8 = null,
    notification_channel_id: ?[]const u8 = null,
    bot_id: ?[]const u8 = null,
    bus: ?*bus_mod.Bus = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // OAuth2 token cache
    cached_token: ?[]u8 = null,
    token_expiry: i64 = 0, // epoch seconds

    // Conversation reference for proactive messaging (serviceUrl + conversationId)
    conv_ref_service_url: ?[]u8 = null,
    conv_ref_conversation_id: ?[]u8 = null,

    pub const TOKEN_BUFFER_SECS: i64 = 5 * 60; // 5-minute buffer before token expiry
    pub const WEBHOOK_PATH = "/api/messages";

    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: config_types.TeamsConfig) TeamsChannel {
        return .{
            .allocator = allocator,
            .account_id = cfg.account_id,
            .client_id = cfg.client_id,
            .client_secret = cfg.client_secret,
            .tenant_id = cfg.tenant_id,
            .webhook_secret = cfg.webhook_secret,
            .notification_channel_id = cfg.notification_channel_id,
            .bot_id = cfg.bot_id,
        };
    }

    // ── OAuth2 Token Management ─────────────────────────────────────

    /// Acquire a new OAuth2 token from Azure AD using client credentials flow.
    pub fn acquireToken(self: *TeamsChannel) !void {
        // Build token URL: https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token
        var url_buf: [256]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("https://login.microsoftonline.com/{s}/oauth2/v2.0/token", .{self.tenant_id});
        const token_url = url_fbs.getWritten();

        // Build form body with URL-encoded values
        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);
        const bw = body_list.writer(self.allocator);
        try bw.writeAll("grant_type=client_credentials&client_id=");
        try writeUrlEncoded(bw, self.client_id);
        try bw.writeAll("&client_secret=");
        try writeUrlEncoded(bw, self.client_secret);
        try bw.writeAll("&scope=https%3A%2F%2Fapi.botframework.com%2F.default");

        const resp = root.http_util.curlPostForm(self.allocator, token_url, body_list.items) catch |err| {
            log.err("Teams OAuth2 token request failed: {}", .{err});
            return error.TeamsTokenError;
        };
        defer self.allocator.free(resp);

        // Parse JSON response for access_token and expires_in
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch {
            log.err("Teams OAuth2: failed to parse token response: {s}", .{resp[0..@min(resp.len, 500)]});
            return error.TeamsTokenError;
        };
        defer parsed.deinit();

        if (parsed.value != .object) return error.TeamsTokenError;
        const obj = parsed.value.object;

        const token_val = obj.get("access_token") orelse {
            // Log the error details from Azure AD
            if (obj.get("error_description")) |desc| {
                if (desc == .string) log.err("Teams OAuth2 error: {s}", .{desc.string});
            } else if (obj.get("error")) |err_val| {
                if (err_val == .string) log.err("Teams OAuth2 error: {s}", .{err_val.string});
            } else {
                log.err("Teams OAuth2: no access_token in response: {s}", .{resp[0..@min(resp.len, 500)]});
            }
            return error.TeamsTokenError;
        };
        if (token_val != .string) return error.TeamsTokenError;

        const expires_in_val = obj.get("expires_in") orelse {
            log.err("Teams OAuth2: no expires_in in response", .{});
            return error.TeamsTokenError;
        };
        const expires_in: i64 = switch (expires_in_val) {
            .integer => expires_in_val.integer,
            else => return error.TeamsTokenError,
        };

        // Free old cached token
        if (self.cached_token) |old| self.allocator.free(old);

        // Cache new token
        self.cached_token = try self.allocator.dupe(u8, token_val.string);
        self.token_expiry = std.time.timestamp() + expires_in;

        log.info("Teams OAuth2 token acquired, expires in {d}s", .{expires_in});
    }

    /// Get a valid token, refreshing if necessary.
    fn getToken(self: *TeamsChannel) ![]const u8 {
        const now = std.time.timestamp();
        if (self.cached_token) |token| {
            if (now < self.token_expiry - TOKEN_BUFFER_SECS) {
                return token;
            }
        }
        try self.acquireToken();
        return self.cached_token orelse error.TeamsTokenError;
    }

    // ── Outbound Messaging ──────────────────────────────────────────

    /// Send a message to a Teams conversation via Bot Framework REST API.
    pub fn sendMessage(self: *TeamsChannel, service_url: []const u8, conversation_id: []const u8, text: []const u8) !void {
        const token = try self.getToken();

        // Build URL: {serviceUrl}/v3/conversations/{conversationId}/activities
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        // Strip trailing slash from service_url if present
        const svc = if (service_url.len > 0 and service_url[service_url.len - 1] == '/')
            service_url[0 .. service_url.len - 1]
        else
            service_url;
        try url_fbs.writer().print("{s}/v3/conversations/{s}/activities", .{ svc, conversation_id });
        const url = url_fbs.getWritten();

        // Build JSON body: {"type":"message","text":"..."}
        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);
        const bw = body_list.writer(self.allocator);
        try bw.writeAll("{\"type\":\"message\",\"text\":");
        try root.appendJsonStringW(bw, text);
        try bw.writeByte('}');

        // Build auth header
        var auth_buf: [2048]u8 = undefined;
        var auth_fbs = std.io.fixedBufferStream(&auth_buf);
        try auth_fbs.writer().print("Authorization: Bearer {s}", .{token});
        const auth_header = auth_fbs.getWritten();

        const resp = root.http_util.curlPost(self.allocator, url, body_list.items, &.{auth_header}) catch |err| {
            log.err("Teams Bot Framework POST failed: {}", .{err});
            return error.TeamsSendError;
        };
        defer self.allocator.free(resp);

        // Check for error in response (best-effort)
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("error")) |_| {
                log.err("Teams Bot Framework API returned error", .{});
                return error.TeamsSendError;
            }
        }
    }

    // ── Conversation Reference Persistence ──────────────────────────

    /// Save conversation reference to JSON file.
    pub fn saveConversationRef(self: *TeamsChannel, config_dir: []const u8) !void {
        const service_url = self.conv_ref_service_url orelse return;
        const conversation_id = self.conv_ref_conversation_id orelse return;

        var path_buf: [512]u8 = undefined;
        var path_fbs = std.io.fixedBufferStream(&path_buf);
        try path_fbs.writer().print("{s}/teams_conversation_ref.json", .{config_dir});
        const path = path_fbs.getWritten();

        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);
        const bw = body_list.writer(self.allocator);
        try bw.writeAll("{\"serviceUrl\":");
        try root.appendJsonStringW(bw, service_url);
        try bw.writeAll(",\"conversationId\":");
        try root.appendJsonStringW(bw, conversation_id);
        try bw.writeByte('}');

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(body_list.items);

        log.info("Teams conversation reference saved to {s}", .{path});
    }

    /// Load conversation reference from JSON file.
    pub fn loadConversationRef(self: *TeamsChannel, config_dir: []const u8) !void {
        var path_buf: [512]u8 = undefined;
        var path_fbs = std.io.fixedBufferStream(&path_buf);
        try path_fbs.writer().print("{s}/teams_conversation_ref.json", .{config_dir});
        const path = path_fbs.getWritten();

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                log.debug("No Teams conversation reference file found", .{});
                return;
            }
            return err;
        };
        defer file.close();

        var buf: [4096]u8 = undefined;
        const len = try file.readAll(&buf);
        if (len == 0) return;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, buf[0..len], .{}) catch {
            log.warn("Failed to parse Teams conversation reference file", .{});
            return;
        };
        defer parsed.deinit();

        if (parsed.value != .object) return;
        const obj = parsed.value.object;

        if (obj.get("serviceUrl")) |v| {
            if (v == .string) {
                if (self.conv_ref_service_url) |old| self.allocator.free(old);
                self.conv_ref_service_url = try self.allocator.dupe(u8, v.string);
            }
        }
        if (obj.get("conversationId")) |v| {
            if (v == .string) {
                if (self.conv_ref_conversation_id) |old| self.allocator.free(old);
                self.conv_ref_conversation_id = try self.allocator.dupe(u8, v.string);
            }
        }

        if (self.conv_ref_service_url != null and self.conv_ref_conversation_id != null) {
            log.info("Teams conversation reference loaded", .{});
        }
    }

    /// Capture conversation reference from an inbound message if it matches the notification channel.
    pub fn captureConversationRef(self: *TeamsChannel, conversation_id: []const u8, service_url: []const u8, config_dir: []const u8) !void {
        // Only capture if notification_channel_id matches
        const notif_id = self.notification_channel_id orelse return;
        if (!std.mem.eql(u8, conversation_id, notif_id)) return;

        // Already captured
        if (self.conv_ref_conversation_id != null) return;

        self.conv_ref_service_url = try self.allocator.dupe(u8, service_url);
        self.conv_ref_conversation_id = try self.allocator.dupe(u8, conversation_id);

        self.saveConversationRef(config_dir) catch |err| {
            log.warn("Failed to save conversation reference: {}", .{err});
        };
    }

    // ── Typing Indicator ──────────────────────────────────────────

    /// Send a typing indicator to a Teams conversation.
    pub fn startTyping(self: *TeamsChannel, target: []const u8) !void {
        if (!self.running.load(.acquire)) return;

        // Parse target as "serviceUrl|conversationId".
        // Proactive messages (stored conv ref) won't have this format — silently skip,
        // since typing indicators don't make sense for bot-initiated messages.
        const sep = std.mem.indexOfScalar(u8, target, '|') orelse return;
        const service_url = target[0..sep];
        const conversation_id = target[sep + 1 ..];

        const token = self.getToken() catch |err| {
            log.warn("Teams startTyping: failed to get token: {}", .{err});
            return;
        };

        // Build URL: {serviceUrl}/v3/conversations/{conversationId}/activities
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        const svc = if (service_url.len > 0 and service_url[service_url.len - 1] == '/')
            service_url[0 .. service_url.len - 1]
        else
            service_url;
        url_fbs.writer().print("{s}/v3/conversations/{s}/activities", .{ svc, conversation_id }) catch return;
        const url = url_fbs.getWritten();

        // Build auth header
        var auth_buf: [2048]u8 = undefined;
        var auth_fbs = std.io.fixedBufferStream(&auth_buf);
        auth_fbs.writer().print("Authorization: Bearer {s}", .{token}) catch return;
        const auth_header = auth_fbs.getWritten();

        const resp = root.http_util.curlPost(self.allocator, url, "{\"type\":\"typing\"}", &.{auth_header}) catch |err| {
            log.warn("Teams typing indicator failed: {}", .{err});
            return;
        };
        self.allocator.free(resp);
    }

    /// No-op — Bot Framework typing indicator auto-clears after ~3 seconds.
    pub fn stopTyping(_: *TeamsChannel, _: []const u8) !void {}

    // ── VTable Implementation ───────────────────────────────────────

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        const self: *TeamsChannel = @ptrCast(@alignCast(ptr));
        if (self.running.load(.acquire)) return;

        self.running.store(true, .release);
        errdefer self.running.store(false, .release);

        if (self.webhook_secret == null) {
            log.warn("Teams webhook_secret not configured — inbound auth is disabled", .{});
        }

        // Try to acquire initial token (best-effort — will retry on first send)
        self.acquireToken() catch |err| {
            log.warn("Teams initial token acquisition failed (will retry on send): {}", .{err});
        };

        log.info("Teams channel started", .{});
    }

    fn vtableStop(ptr: *anyopaque) void {
        const self: *TeamsChannel = @ptrCast(@alignCast(ptr));
        self.running.store(false, .release);

        if (self.cached_token) |token| {
            self.allocator.free(token);
            self.cached_token = null;
        }
        if (self.conv_ref_service_url) |url| {
            self.allocator.free(url);
            self.conv_ref_service_url = null;
        }
        if (self.conv_ref_conversation_id) |id| {
            self.allocator.free(id);
            self.conv_ref_conversation_id = null;
        }

        log.info("Teams channel stopped", .{});
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8, _: []const []const u8) anyerror!void {
        const self: *TeamsChannel = @ptrCast(@alignCast(ptr));

        // Strip <nc_choices>...</nc_choices> tags — Teams doesn't render interactive choices.
        const clean = if (std.mem.indexOf(u8, message, "<nc_choices>")) |tag_start|
            std.mem.trimRight(u8, message[0..tag_start], &std.ascii.whitespace)
        else
            message;

        // Target format: "serviceUrl|conversationId" or use stored conversation ref for proactive
        if (std.mem.indexOfScalar(u8, target, '|')) |sep| {
            const service_url = target[0..sep];
            const conversation_id = target[sep + 1 ..];
            try self.sendMessage(service_url, conversation_id, clean);
        } else if (self.conv_ref_service_url != null and self.conv_ref_conversation_id != null) {
            // Proactive: use stored conversation reference
            try self.sendMessage(self.conv_ref_service_url.?, self.conv_ref_conversation_id.?, clean);
        } else {
            log.warn("Teams send: no conversation reference available for target '{s}'", .{target});
        }
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        const self: *TeamsChannel = @ptrCast(@alignCast(ptr));
        _ = self;
        return "teams";
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *TeamsChannel = @ptrCast(@alignCast(ptr));
        if (!self.running.load(.acquire)) return false;
        // Healthy if we have a valid token or can obtain one
        const now = std.time.timestamp();
        if (self.cached_token != null and now < self.token_expiry - TOKEN_BUFFER_SECS) {
            return true;
        }
        // Try to acquire a token
        self.acquireToken() catch return false;
        return self.cached_token != null;
    }

    /// URL-encode a string for use in application/x-www-form-urlencoded bodies.
    fn writeUrlEncoded(writer: anytype, input: []const u8) !void {
        for (input) |c| {
            switch (c) {
                'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '*' => try writer.writeByte(c),
                ' ' => try writer.writeByte('+'),
                else => {
                    try writer.writeByte('%');
                    const hex = "0123456789ABCDEF";
                    try writer.writeByte(hex[c >> 4]);
                    try writer.writeByte(hex[c & 0x0F]);
                },
            }
        }
    }

    fn vtableStartTyping(ptr: *anyopaque, recipient: []const u8) anyerror!void {
        const self: *TeamsChannel = @ptrCast(@alignCast(ptr));
        return self.startTyping(recipient);
    }

    fn vtableStopTyping(ptr: *anyopaque, recipient: []const u8) anyerror!void {
        const self: *TeamsChannel = @ptrCast(@alignCast(ptr));
        return self.stopTyping(recipient);
    }

    pub const vtable = root.Channel.VTable{
        .start = &vtableStart,
        .stop = &vtableStop,
        .send = &vtableSend,
        .name = &vtableName,
        .healthCheck = &vtableHealthCheck,
        .startTyping = &vtableStartTyping,
        .stopTyping = &vtableStopTyping,
    };

    pub fn channel(self: *TeamsChannel) root.Channel {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

test "Teams startTyping and stopTyping are safe in tests" {
    var ch = TeamsChannel{
        .allocator = std.testing.allocator,
        .client_id = "test-client-id",
        .client_secret = "test-secret",
        .tenant_id = "test-tenant",
    };
    // startTyping returns immediately when not running (running = false by default)
    try ch.startTyping("https://smba.trafficmanager.net/teams|19:abc@thread.v2");
    try ch.stopTyping("https://smba.trafficmanager.net/teams|19:abc@thread.v2");
}

test "Teams stopTyping is idempotent" {
    var ch = TeamsChannel{
        .allocator = std.testing.allocator,
        .client_id = "test-client-id",
        .client_secret = "test-secret",
        .tenant_id = "test-tenant",
    };
    try ch.stopTyping("https://smba.trafficmanager.net/teams|19:abc@thread.v2");
    try ch.stopTyping("https://smba.trafficmanager.net/teams|19:abc@thread.v2");
}

test "vtableSend strips nc_choices tags from message" {
    const msg = "Pick one:\n- Option A\n- Option B\n<nc_choices>{\"v\":1,\"options\":[{\"id\":\"a\",\"label\":\"A\"},{\"id\":\"b\",\"label\":\"B\"}]}</nc_choices>";
    const clean = if (std.mem.indexOf(u8, msg, "<nc_choices>")) |tag_start|
        std.mem.trimRight(u8, msg[0..tag_start], &std.ascii.whitespace)
    else
        msg;
    try std.testing.expectEqualStrings("Pick one:\n- Option A\n- Option B", clean);
}

test "vtableSend preserves message without nc_choices" {
    const msg = "Hello, how can I help?";
    const clean = if (std.mem.indexOf(u8, msg, "<nc_choices>")) |tag_start|
        std.mem.trimRight(u8, msg[0..tag_start], &std.ascii.whitespace)
    else
        msg;
    try std.testing.expectEqualStrings("Hello, how can I help?", clean);
}
