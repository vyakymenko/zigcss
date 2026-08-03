const std = @import("std");

pub const Separator = enum {
    undecided,
    space,
    comma,
    slash,
    legacy_slash,
};

pub const ColorSpace = enum {
    rgb,
    hsl,
    hwb,
    lab,
    lch,
    oklab,
    oklch,
    srgb,
    srgb_linear,
    display_p3,
    a98_rgb,
    prophoto_rgb,
    rec2020,
    xyz_d50,
    xyz,
};

pub const CallableKind = enum {
    builtin_function,
    builtin_mixin,
    user_function,
    mixin,
    parent_function,
    parent_mixin,
    local_module_function,
    local_module_mixin,
};

pub const String = struct {
    bytes: []const u8,
    quoted: bool = false,
};

pub const Number = struct {
    value: f64,
    numerator_units: []const []const u8 = &.{},
    denominator_units: []const []const u8 = &.{},
    preserve_precision: bool = false,
};

pub const Color = struct {
    space: ColorSpace,
    channels: [4]f64,
    missing_mask: u4 = 0,
    computed: bool = false,
};

pub const List = struct {
    items: []const Value,
    separator: Separator = .undecided,
    bracketed: bool = false,
};

pub const Entry = struct {
    key: Value,
    value: Value,
};

pub const Map = struct {
    entries: []const Entry,
};

pub const ArgumentListState = struct {
    keywords_accessed: bool = false,
};

pub const ArgumentKeyword = struct {
    name: []const u8,
    value: Value,
    normalize_name: bool,
};

pub const ArgumentList = struct {
    positional: []const Value,
    keywords: []const ArgumentKeyword,
    state: *ArgumentListState,
};

pub const Callable = struct {
    kind: CallableKind,
    id: u32,
    identity: u64 = 0,
    reexport_depth: u16 = 0,
    peer_argument_transport: bool = false,
    forwarded_member: bool = false,
};

pub const CallableRemapper = struct {
    context: usize,
    map: *const fn (context: usize, callable: Callable) ?Callable,
};

pub const Value = union(enum) {
    null_value: void,
    boolean: bool,
    number: Number,
    color: Color,
    string: String,
    list: List,
    map: Map,
    argument_list: ArgumentList,
    selector: String,
    callable: Callable,
};

pub const Limits = struct {
    max_values: usize = 1_000_000,
    max_depth: u16 = 64,
    max_collection_items: usize = 1_000_000,
    max_owned_bytes: usize = 64 * 1024 * 1024,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidValue,
    ValueDepthExceeded,
    ValueLimitExceeded,
};

pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    limits: Limits,
    value_count: usize = 0,
    collection_items: usize = 0,
    owned_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Store {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator), .limits = limits };
    }

    pub fn deinit(self: *Store) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn own(self: *Store, input: Value) Error!*const Value {
        const cloned = try self.cloneValue(input, 1, false, null);
        const result = try self.arena.allocator().create(Value);
        result.* = cloned;
        return result;
    }

    pub fn ownRemappingCallables(
        self: *Store,
        input: Value,
        remapper: CallableRemapper,
    ) Error!*const Value {
        const cloned = try self.cloneValue(input, 1, false, remapper);
        const result = try self.arena.allocator().create(Value);
        result.* = cloned;
        return result;
    }

    pub fn ownCollectionWithSharedArgumentLists(
        self: *Store,
        input: Value,
    ) Error!*const Value {
        switch (input) {
            .list, .map => {},
            else => return error.InvalidValue,
        }
        const cloned = try self.cloneValue(input, 1, true, null);
        const result = try self.arena.allocator().create(Value);
        result.* = cloned;
        return result;
    }

    fn cloneValue(
        self: *Store,
        input: Value,
        depth: u16,
        share_argument_list_state: bool,
        remapper: ?CallableRemapper,
    ) Error!Value {
        if (depth > self.limits.max_depth) return error.ValueDepthExceeded;
        if (self.value_count >= self.limits.max_values) return error.ValueLimitExceeded;
        self.value_count += 1;

        return switch (input) {
            .null_value => .{ .null_value = {} },
            .boolean => |item| .{ .boolean = item },
            .number => |item| .{ .number = try self.cloneNumber(item) },
            .color => |item| .{ .color = try cloneColor(item) },
            .string => |item| .{ .string = try self.cloneString(item) },
            .selector => |item| .{ .selector = try self.cloneString(item) },
            .callable => |item| .{ .callable = if (remapper) |mapper|
                mapper.map(mapper.context, item) orelse return error.InvalidValue
            else
                item },
            .list => |item| .{
                .list = try self.cloneList(
                    item,
                    depth,
                    share_argument_list_state,
                    remapper,
                ),
            },
            .map => |item| .{
                .map = try self.cloneMap(
                    item,
                    depth,
                    share_argument_list_state,
                    remapper,
                ),
            },
            .argument_list => |item| .{
                .argument_list = try self.cloneArgumentList(
                    item,
                    depth,
                    share_argument_list_state,
                    remapper,
                ),
            },
        };
    }

    fn cloneString(self: *Store, input: String) Error!String {
        return .{ .bytes = try self.cloneBytes(input.bytes, false), .quoted = input.quoted };
    }

    fn cloneNumber(self: *Store, input: Number) Error!Number {
        if (!std.math.isFinite(input.value)) return error.InvalidValue;
        return .{
            .value = input.value,
            .numerator_units = try self.cloneUnits(input.numerator_units),
            .denominator_units = try self.cloneUnits(input.denominator_units),
            .preserve_precision = input.preserve_precision,
        };
    }

    fn cloneUnits(self: *Store, units: []const []const u8) Error![]const []const u8 {
        try self.reserveCollection(units.len);
        if (units.len == 0) return &.{};
        const owned = try self.arena.allocator().alloc([]const u8, units.len);
        for (units, 0..) |unit, index| {
            owned[index] = try self.cloneBytes(unit, true);
        }
        return owned;
    }

    fn cloneList(
        self: *Store,
        input: List,
        depth: u16,
        share_argument_list_state: bool,
        remapper: ?CallableRemapper,
    ) Error!List {
        try self.reserveCollection(input.items.len);
        if (input.items.len == 0) return .{
            .items = &.{},
            .separator = input.separator,
            .bracketed = input.bracketed,
        };
        const items = try self.arena.allocator().alloc(Value, input.items.len);
        for (input.items, 0..) |item, index| {
            items[index] = try self.cloneValue(
                item,
                depth + 1,
                share_argument_list_state,
                remapper,
            );
        }
        return .{
            .items = items,
            .separator = input.separator,
            .bracketed = input.bracketed,
        };
    }

    fn cloneMap(
        self: *Store,
        input: Map,
        depth: u16,
        share_argument_list_state: bool,
        remapper: ?CallableRemapper,
    ) Error!Map {
        try self.reserveCollection(input.entries.len);
        if (input.entries.len == 0) return .{ .entries = &.{} };
        const entries = try self.arena.allocator().alloc(Entry, input.entries.len);
        for (input.entries, 0..) |entry, index| {
            entries[index] = .{
                .key = try self.cloneValue(
                    entry.key,
                    depth + 1,
                    share_argument_list_state,
                    remapper,
                ),
                .value = try self.cloneValue(
                    entry.value,
                    depth + 1,
                    share_argument_list_state,
                    remapper,
                ),
            };
        }
        return .{ .entries = entries };
    }

    fn cloneArgumentList(
        self: *Store,
        input: ArgumentList,
        depth: u16,
        share_argument_list_state: bool,
        remapper: ?CallableRemapper,
    ) Error!ArgumentList {
        const collection_count = std.math.add(
            usize,
            input.positional.len,
            input.keywords.len,
        ) catch return error.ValueLimitExceeded;
        try self.reserveCollection(collection_count);

        const positional = try self.arena.allocator().alloc(Value, input.positional.len);
        for (input.positional, 0..) |item, index| {
            positional[index] = try self.cloneValue(
                item,
                depth + 1,
                share_argument_list_state,
                remapper,
            );
        }

        const keywords = try self.arena.allocator().alloc(
            ArgumentKeyword,
            input.keywords.len,
        );
        for (input.keywords, 0..) |keyword, index| {
            keywords[index] = .{
                .name = try self.cloneBytes(keyword.name, false),
                .value = try self.cloneValue(
                    keyword.value,
                    depth + 1,
                    share_argument_list_state,
                    remapper,
                ),
                .normalize_name = keyword.normalize_name,
            };
        }

        const state = if (share_argument_list_state) input.state else blk: {
            const owned = try self.arena.allocator().create(ArgumentListState);
            owned.* = input.state.*;
            break :blk owned;
        };
        return .{
            .positional = positional,
            .keywords = keywords,
            .state = state,
        };
    }

    fn cloneBytes(self: *Store, bytes: []const u8, require_nonempty: bool) Error![]const u8 {
        if ((require_nonempty and bytes.len == 0) or std.mem.indexOfScalar(u8, bytes, 0) != null) {
            return error.InvalidValue;
        }
        const next = std.math.add(usize, self.owned_bytes, bytes.len) catch
            return error.ValueLimitExceeded;
        if (next > self.limits.max_owned_bytes) return error.ValueLimitExceeded;
        const result = if (bytes.len == 0) &.{} else try self.arena.allocator().dupe(u8, bytes);
        self.owned_bytes = next;
        return result;
    }

    fn reserveCollection(self: *Store, count: usize) Error!void {
        const next = std.math.add(usize, self.collection_items, count) catch
            return error.ValueLimitExceeded;
        if (next > self.limits.max_collection_items) return error.ValueLimitExceeded;
        self.collection_items = next;
    }
};

fn cloneColor(input: Color) Error!Color {
    for (input.channels) |channel| {
        if (!std.math.isFinite(channel)) return error.InvalidValue;
    }
    var result = input;
    for (&result.channels) |*channel| {
        if (channel.* == 0) channel.* = 0;
    }
    return result;
}

pub fn eql(left: Value, right: Value) bool {
    return eqlDepth(left, right, 0);
}

fn eqlDepth(left: Value, right: Value, depth: u16) bool {
    if (depth > 64 or std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .null_value => true,
        .boolean => |item| item == right.boolean,
        .number => |item| eqlNumber(item, right.number),
        .color => |item| eqlColor(item, right.color),
        .string => |item| eqlString(item, right.string),
        .selector => |item| eqlString(item, right.selector),
        .callable => |item| callableEql(item, right.callable),
        .list => |item| blk: {
            const other = right.list;
            if (item.separator != other.separator or item.bracketed != other.bracketed or
                item.items.len != other.items.len)
            {
                break :blk false;
            }
            for (item.items, other.items) |child, other_child| {
                if (!eqlDepth(child, other_child, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .map => |item| blk: {
            const other = right.map;
            if (item.entries.len != other.entries.len) break :blk false;
            for (item.entries, other.entries) |entry, other_entry| {
                if (!eqlDepth(entry.key, other_entry.key, depth + 1) or
                    !eqlDepth(entry.value, other_entry.value, depth + 1))
                {
                    break :blk false;
                }
            }
            break :blk true;
        },
        .argument_list => |item| blk: {
            const other = right.argument_list;
            if (item.positional.len != other.positional.len or
                item.keywords.len != other.keywords.len)
            {
                break :blk false;
            }
            for (item.positional, other.positional) |child, other_child| {
                if (!eqlDepth(child, other_child, depth + 1)) break :blk false;
            }
            for (item.keywords, other.keywords) |keyword, other_keyword| {
                if (keyword.normalize_name != other_keyword.normalize_name or
                    !std.mem.eql(u8, keyword.name, other_keyword.name) or
                    !eqlDepth(keyword.value, other_keyword.value, depth + 1))
                {
                    break :blk false;
                }
            }
            break :blk true;
        },
    };
}

pub fn callableEql(left: Callable, right: Callable) bool {
    if (left.kind != right.kind) return false;
    if (left.identity != 0 and right.identity != 0) {
        return left.identity == right.identity;
    }
    return left.id == right.id;
}

fn eqlString(left: String, right: String) bool {
    return left.quoted == right.quoted and std.mem.eql(u8, left.bytes, right.bytes);
}

fn eqlColor(left: Color, right: Color) bool {
    if (left.space != right.space or left.missing_mask != right.missing_mask) return false;
    for (left.channels, right.channels) |left_channel, right_channel| {
        if (left_channel != right_channel) return false;
    }
    return true;
}

fn eqlNumber(left: Number, right: Number) bool {
    return left.value == right.value and
        eqlUnits(left.numerator_units, right.numerator_units) and
        eqlUnits(left.denominator_units, right.denominator_units);
}

fn eqlUnits(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |unit, other| {
        if (!std.mem.eql(u8, unit, other)) return false;
    }
    return true;
}
