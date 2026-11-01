//! Provider-neutral messages read and written by the model API adapters.

const std = @import("std");

pub const ExtraMember = struct {
    name: []const u8,
    value: std.json.Value,
};

pub const Extra = struct {
    members: []const ExtraMember = &.{},
};

fn ForwardCompatible(comptime T: type) type {
    const info = @typeInfo(T).@"struct";

    return struct {
        pub fn jsonStringify(self: T, jw: *std.json.Stringify) std.json.Stringify.Error!void {
            try jw.beginObject();
            inline for (info.field_names) |field| {
                if (comptime !std.mem.eql(u8, field, "extra")) {
                    try jw.objectField(field);
                    try jw.write(@field(self, field));
                }
            }
            for (self.extra.members) |member| {
                try jw.objectField(member.name);
                try jw.write(member.value);
            }
            try jw.endObject();
        }

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!T {
            if (.object_begin != try source.next()) return error.UnexpectedToken;

            const max_len = options.max_value_len orelse std.json.default_max_value_len;
            var result: T = undefined;
            var seen = @as([info.field_names.len]bool, @splat(false));
            var extras: std.ArrayList(ExtraMember) = .empty;

            while (true) {
                const name_token = try source.nextAllocMax(allocator, .alloc_if_needed, max_len);
                const name = switch (name_token) {
                    .object_end => break,
                    .string, .allocated_string => |slice| slice,
                    else => return error.UnexpectedToken,
                };

                var matched = false;
                inline for (info.field_names, info.field_types, 0..) |field, field_type, i| {
                    if (comptime !std.mem.eql(u8, field, "extra")) {
                        if (!matched and std.mem.eql(u8, field, name)) {
                            @field(result, field) = try std.json.innerParse(field_type, allocator, source, options);
                            seen[i] = true;
                            matched = true;
                        }
                    }
                }
                if (matched) continue;

                try extras.append(allocator, .{
                    .name = try allocator.dupe(u8, name),
                    .value = try std.json.innerParse(std.json.Value, allocator, source, options),
                });
            }

            inline for (info.field_names, info.field_types, info.field_attrs, 0..) |field, field_type, attrs, i| {
                if (comptime std.mem.eql(u8, field, "extra")) {
                    result.extra = .{ .members = try extras.toOwnedSlice(allocator) };
                } else if (!seen[i]) {
                    @field(result, field) = attrs.defaultValue(field_type) orelse return error.MissingField;
                }
            }
            return result;
        }
    };
}

fn WireString(comptime T: type) type {
    return struct {
        pub fn wireName(self: T) []const u8 {
            return switch (self) {
                .unknown => |name| name,
                inline else => |_, tag| @tagName(tag),
            };
        }

        pub fn jsonStringify(self: T, jw: *std.json.Stringify) std.json.Stringify.Error!void {
            try jw.write(wireName(self));
        }

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!T {
            const max_len = options.max_value_len orelse std.json.default_max_value_len;
            const token = try source.nextAllocMax(allocator, .alloc_if_needed, max_len);
            const text = switch (token) {
                .string, .allocated_string => |slice| slice,
                else => return error.UnexpectedToken,
            };
            inline for (@typeInfo(T).@"union".field_names) |field_name| {
                if (comptime std.mem.eql(u8, field_name, "unknown")) continue;
                if (std.mem.eql(u8, field_name, text)) return @unionInit(T, field_name, {});
            }
            return .{ .unknown = try allocator.dupe(u8, text) };
        }
    };
}

pub const Role = union(enum) {
    user,
    assistant,
    system,
    tool,
    unknown: []const u8,

    pub const wireName = WireString(Role).wireName;
    pub const jsonStringify = WireString(Role).jsonStringify;
    pub const jsonParse = WireString(Role).jsonParse;
};

pub const Reasoning = struct {
    text: []const u8,
    signature: []const u8,
    extra: Extra = .{},

    const forward = ForwardCompatible(@This());
    pub const jsonStringify = forward.jsonStringify;
    pub const jsonParse = forward.jsonParse;
};

pub const ToolCall = struct {
    call_id: []const u8,
    tool: []const u8,
    arguments: []const u8,
    extra: Extra = .{},

    const forward = ForwardCompatible(@This());
    pub const jsonStringify = forward.jsonStringify;
    pub const jsonParse = forward.jsonParse;
};

pub const ToolResultPart = struct {
    call_id: []const u8,
    output: []const u8,
    is_error: bool,
    extra: Extra = .{},

    const forward = ForwardCompatible(@This());
    pub const jsonStringify = forward.jsonStringify;
    pub const jsonParse = forward.jsonParse;
};

pub const ImagePart = struct {
    call_id: []const u8,
    media_type: []const u8,
    data: []const u8,
    extra: Extra = .{},

    const forward = ForwardCompatible(@This());
    pub const jsonStringify = forward.jsonStringify;
    pub const jsonParse = forward.jsonParse;
};

pub const UnknownPart = struct {
    name: []const u8,
    raw: std.json.Value,
};

pub const ContentPart = union(enum) {
    text: []const u8,
    reasoning: Reasoning,
    tool_use: ToolCall,
    tool_result: ToolResultPart,
    image: ImagePart,
    unknown: UnknownPart,

    pub fn jsonStringify(self: ContentPart, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        try jw.beginObject();
        switch (self) {
            .unknown => |part| {
                try jw.objectField(part.name);
                try jw.write(part.raw);
            },
            inline else => |payload, tag| {
                try jw.objectField(@tagName(tag));
                try jw.write(payload);
            },
        }
        try jw.endObject();
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!ContentPart {
        if (.object_begin != try source.next()) return error.UnexpectedToken;
        const max_len = options.max_value_len orelse std.json.default_max_value_len;
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, max_len);
        const name = switch (token) {
            .string, .allocated_string => |slice| slice,
            else => return error.UnexpectedToken,
        };

        const result: ContentPart = if (std.mem.eql(u8, name, "text"))
            .{ .text = try std.json.innerParse([]const u8, allocator, source, options) }
        else if (std.mem.eql(u8, name, "reasoning"))
            .{ .reasoning = try std.json.innerParse(Reasoning, allocator, source, options) }
        else if (std.mem.eql(u8, name, "tool_use"))
            .{ .tool_use = try std.json.innerParse(ToolCall, allocator, source, options) }
        else if (std.mem.eql(u8, name, "tool_result"))
            .{ .tool_result = try std.json.innerParse(ToolResultPart, allocator, source, options) }
        else if (std.mem.eql(u8, name, "image"))
            .{ .image = try std.json.innerParse(ImagePart, allocator, source, options) }
        else
            .{ .unknown = .{
                .name = try allocator.dupe(u8, name),
                .raw = try std.json.innerParse(std.json.Value, allocator, source, options),
            } };

        if (.object_end != try source.next()) return error.UnexpectedToken;
        return result;
    }
};

pub const Message = struct {
    role: Role,
    content: []const ContentPart,
    model_alias: []const u8 = "",
    extra: Extra = .{},

    const forward = ForwardCompatible(@This());
    pub const jsonStringify = forward.jsonStringify;
    pub const jsonParse = forward.jsonParse;
};

pub const Amount = struct {
    value: f64,
    currency: []const u8,
    extra: Extra = .{},

    const forward = ForwardCompatible(@This());
    pub const jsonStringify = forward.jsonStringify;
    pub const jsonParse = forward.jsonParse;
};

pub const Cost = union(enum) {
    known: Amount,
    free,
    unknown,
    unrecognized: UnknownPart,

    pub fn jsonStringify(self: Cost, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        try jw.beginObject();
        switch (self) {
            .known => |amount| {
                try jw.objectField("known");
                try jw.write(amount);
            },
            .unrecognized => |part| {
                try jw.objectField(part.name);
                try jw.write(part.raw);
            },
            inline .free, .unknown => |_, tag| {
                try jw.objectField(@tagName(tag));
                try jw.write(true);
            },
        }
        try jw.endObject();
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Cost {
        if (.object_begin != try source.next()) return error.UnexpectedToken;

        const max_len = options.max_value_len orelse std.json.default_max_value_len;
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, max_len);
        const name = switch (token) {
            .string, .allocated_string => |slice| slice,
            else => return error.UnexpectedToken,
        };

        const result: Cost = if (std.mem.eql(u8, name, "known"))
            .{ .known = try std.json.innerParse(Amount, allocator, source, options) }
        else if (std.mem.eql(u8, name, "free") or std.mem.eql(u8, name, "unknown")) result: {
            _ = try std.json.innerParse(std.json.Value, allocator, source, options);
            break :result if (std.mem.eql(u8, name, "free")) .free else .unknown;
        } else .{ .unrecognized = .{
            .name = try allocator.dupe(u8, name),
            .raw = try std.json.innerParse(std.json.Value, allocator, source, options),
        } };

        if (.object_end != try source.next()) return error.UnexpectedToken;
        return result;
    }
};

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cost: Cost = .unknown,
    price_table_version: []const u8 = "",
    model: []const u8 = "",
    model_alias: []const u8 = "",
    request_id: []const u8 = "",
    inference_ms: u64 = 0,
    reasoning_effort_applied: []const u8 = "",
    extra: Extra = .{},

    const forward = ForwardCompatible(@This());
    pub const jsonStringify = forward.jsonStringify;
    pub const jsonParse = forward.jsonParse;

    pub fn totalTokens(self: Usage) u64 {
        return self.input_tokens + self.output_tokens +
            self.cache_creation_input_tokens + self.cache_read_input_tokens;
    }
};

pub const Capability = enum {
    tool_calls,
    image_results,
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
};

pub const ProviderSearch = struct {
    allowed_domains: []const []const u8,
};

pub const Request = struct {
    model: []const u8,
    system: []const u8,
    messages: []const Message,
    tools: []const ToolDefinition = &.{},
    provider_search: ?ProviderSearch = null,
};

pub const ToolCallFragment = struct {
    index: usize,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};

test "neutral messages preserve fields from future writers" {
    const allocator = std.testing.allocator;
    const source =
        \\{"role":"assistant","content":[{"future_part":{"value":7}}],"model_alias":"work","future_field":true}
    ;
    const parsed = try std.json.parseFromSlice(Message, allocator, source, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("work", parsed.value.model_alias);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.extra.members.len);
    try std.testing.expectEqualStrings("future_field", parsed.value.extra.members[0].name);
    try std.testing.expectEqualStrings("future_part", parsed.value.content[0].unknown.name);

    const encoded = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "future_field") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "future_part") != null);
}

test "usage cost states remain distinct through JSON" {
    const allocator = std.testing.allocator;
    const states = [_]Cost{
        .{ .known = .{ .value = 0.0042, .currency = "USD" } },
        .free,
        .unknown,
    };

    for (states) |state| {
        const encoded = try std.json.Stringify.valueAlloc(allocator, Usage{
            .input_tokens = 10,
            .output_tokens = 2,
            .cost = state,
        }, .{});
        defer allocator.free(encoded);
        const parsed = try std.json.parseFromSlice(Usage, allocator, encoded, .{});
        defer parsed.deinit();

        try std.testing.expectEqual(std.meta.activeTag(state), std.meta.activeTag(parsed.value.cost));
        try std.testing.expectEqual(@as(u64, 12), parsed.value.totalTokens());
    }
}
