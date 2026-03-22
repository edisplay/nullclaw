const std = @import("std");

pub const ProviderModelRef = struct {
    provider: ?[]const u8,
    model: []const u8,
};

fn splitVersionedUrlProviderModel(model_ref: []const u8) ?ProviderModelRef {
    const proto_start = std.mem.indexOf(u8, model_ref, "://") orelse return null;
    var i: usize = proto_start + 3;
    while (i + 3 < model_ref.len) : (i += 1) {
        if (model_ref[i] != '/' or model_ref[i + 1] != 'v') continue;
        var j = i + 2;
        var has_digit = false;
        while (j < model_ref.len and std.ascii.isDigit(model_ref[j])) : (j += 1) {
            has_digit = true;
        }
        if (!has_digit) continue;
        if (j >= model_ref.len or model_ref[j] != '/') continue;
        if (j + 1 >= model_ref.len) return null;

        return .{
            .provider = model_ref[0..j],
            .model = model_ref[j + 1 ..],
        };
    }
    return null;
}

pub fn splitProviderModel(model_ref: []const u8) ?ProviderModelRef {
    if (model_ref.len == 0) return null;
    if (splitVersionedUrlProviderModel(model_ref)) |split| return split;
    if (std.mem.indexOf(u8, model_ref, "://") != null) return null;

    const slash = std.mem.indexOfScalar(u8, model_ref, '/') orelse return null;
    if (slash == 0 or slash + 1 >= model_ref.len) return null;
    return .{
        .provider = model_ref[0..slash],
        .model = model_ref[slash + 1 ..],
    };
}

test "splitProviderModel handles regular refs" {
    const split = splitProviderModel("openrouter/anthropic/claude-sonnet-4") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("openrouter", split.provider.?);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4", split.model);
}

test "splitProviderModel handles custom url refs" {
    const split = splitProviderModel("custom:https://api.example.com/openai/v2/qianfan/custom-model") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("custom:https://api.example.com/openai/v2", split.provider.?);
    try std.testing.expectEqualStrings("qianfan/custom-model", split.model);
}

test "splitProviderModel rejects empty model tail" {
    try std.testing.expect(splitProviderModel("custom:https://api.example.com/v1/") == null);
}
