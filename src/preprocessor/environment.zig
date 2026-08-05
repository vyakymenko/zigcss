const std = @import("std");
const value = @import("value.zig");

pub const ScopeId = struct {
    value: u32,
};

pub const Limits = struct {
    max_scopes: usize = 65_536,
    max_scope_depth: u16 = 1_024,
    max_bindings: usize = 1_000_000,
    max_name_bytes: usize = 16 * 1024 * 1024,
};

pub const Error = std.mem.Allocator.Error || error{
    BindingLimitExceeded,
    DuplicateBinding,
    InvalidName,
    NameLimitExceeded,
    RootScope,
    ScopeLimitExceeded,
    UnknownScope,
};

const Binding = struct {
    name: []const u8,
    value: *const value.Value,
};

const Data = union(enum) {
    boundary,
    binding: Binding,
};

const Node = struct {
    parent: ?ScopeId,
    lexical_depth: u16,
    data: Data,
};

pub const Environment = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    nodes: std.ArrayList(Node) = .empty,
    scope_count: usize = 0,
    binding_count: usize = 0,
    name_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Error!Environment {
        if (limits.max_scopes == 0) return error.ScopeLimitExceeded;
        var result = Environment{ .allocator = allocator, .limits = limits };
        errdefer result.deinit();
        try result.nodes.append(allocator, .{
            .parent = null,
            .lexical_depth = 0,
            .data = .boundary,
        });
        result.scope_count = 1;
        return result;
    }

    pub fn deinit(self: *Environment) void {
        for (self.nodes.items) |node| {
            switch (node.data) {
                .boundary => {},
                .binding => |binding| if (binding.name.len > 0) self.allocator.free(binding.name),
            }
        }
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn root(self: *const Environment) ScopeId {
        _ = self;
        return .{ .value = 0 };
    }

    pub fn push(self: *Environment, parent: ScopeId) Error!ScopeId {
        const parent_node = try self.get(parent);
        if (parent_node.lexical_depth >= self.limits.max_scope_depth or
            self.scope_count >= self.limits.max_scopes or
            self.nodes.items.len >= std.math.maxInt(u32))
        {
            return error.ScopeLimitExceeded;
        }
        try self.nodes.append(self.allocator, .{
            .parent = parent,
            .lexical_depth = parent_node.lexical_depth + 1,
            .data = .boundary,
        });
        self.scope_count += 1;
        return .{ .value = @intCast(self.nodes.items.len - 1) };
    }

    pub fn pop(self: *const Environment, current: ScopeId) Error!ScopeId {
        var cursor = current;
        while (true) {
            const node = try self.get(cursor);
            switch (node.data) {
                .binding => cursor = node.parent orelse return error.RootScope,
                .boundary => return node.parent orelse error.RootScope,
            }
        }
    }

    pub fn define(
        self: *Environment,
        current: ScopeId,
        name: []const u8,
        item: *const value.Value,
    ) Error!ScopeId {
        var cursor = current;
        while (true) {
            const node = try self.get(cursor);
            switch (node.data) {
                .boundary => break,
                .binding => |binding| {
                    if (std.mem.eql(u8, binding.name, name)) return error.DuplicateBinding;
                    cursor = node.parent orelse return error.UnknownScope;
                },
            }
        }
        return self.appendBinding(current, name, item);
    }

    pub fn set(
        self: *Environment,
        current: ScopeId,
        name: []const u8,
        item: *const value.Value,
    ) Error!ScopeId {
        _ = try self.get(current);
        return self.appendBinding(current, name, item);
    }

    pub fn lookup(
        self: *const Environment,
        current: ScopeId,
        name: []const u8,
    ) Error!?*const value.Value {
        if (name.len == 0) return error.InvalidName;
        var cursor: ?ScopeId = current;
        while (cursor) |scope| {
            const node = try self.get(scope);
            switch (node.data) {
                .boundary => {},
                .binding => |binding| {
                    if (std.mem.eql(u8, binding.name, name)) return binding.value;
                },
            }
            cursor = node.parent;
        }
        return null;
    }

    pub fn update(
        self: *Environment,
        current: ScopeId,
        name: []const u8,
        item: *const value.Value,
    ) Error!bool {
        if (name.len == 0) return error.InvalidName;
        var cursor: ?ScopeId = current;
        while (cursor) |scope| {
            const index: usize = @intCast(scope.value);
            if (index >= self.nodes.items.len) return error.UnknownScope;
            const node = &self.nodes.items[index];
            switch (node.data) {
                .boundary => {},
                .binding => |*binding| {
                    if (std.mem.eql(u8, binding.name, name)) {
                        binding.value = item;
                        return true;
                    }
                },
            }
            cursor = node.parent;
        }
        return false;
    }

    pub fn lookupLocal(
        self: *const Environment,
        current: ScopeId,
        name: []const u8,
    ) Error!?*const value.Value {
        if (name.len == 0) return error.InvalidName;
        var cursor = current;
        while (true) {
            const node = try self.get(cursor);
            switch (node.data) {
                .boundary => return null,
                .binding => |binding| {
                    if (std.mem.eql(u8, binding.name, name)) return binding.value;
                    cursor = node.parent orelse return error.UnknownScope;
                },
            }
        }
    }

    pub fn lookupNonGlobal(
        self: *const Environment,
        current: ScopeId,
        name: []const u8,
    ) Error!?*const value.Value {
        if (name.len == 0) return error.InvalidName;
        var cursor: ?ScopeId = current;
        while (cursor) |scope| {
            const node = try self.get(scope);
            if (node.lexical_depth == 0) return null;
            switch (node.data) {
                .boundary => {},
                .binding => |binding| {
                    if (std.mem.eql(u8, binding.name, name)) return binding.value;
                },
            }
            cursor = node.parent;
        }
        return null;
    }

    fn appendBinding(
        self: *Environment,
        parent: ScopeId,
        name: []const u8,
        item: *const value.Value,
    ) Error!ScopeId {
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidName;
        const next_name_bytes = std.math.add(usize, self.name_bytes, name.len) catch
            return error.NameLimitExceeded;
        if (next_name_bytes > self.limits.max_name_bytes) return error.NameLimitExceeded;
        if (self.binding_count >= self.limits.max_bindings or
            self.nodes.items.len >= std.math.maxInt(u32))
        {
            return error.BindingLimitExceeded;
        }
        const parent_node = try self.get(parent);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer if (owned_name.len > 0) self.allocator.free(owned_name);
        try self.nodes.append(self.allocator, .{
            .parent = parent,
            .lexical_depth = parent_node.lexical_depth,
            .data = .{ .binding = .{ .name = owned_name, .value = item } },
        });
        self.binding_count += 1;
        self.name_bytes = next_name_bytes;
        return .{ .value = @intCast(self.nodes.items.len - 1) };
    }

    fn get(self: *const Environment, id: ScopeId) Error!*const Node {
        const index: usize = @intCast(id.value);
        if (index >= self.nodes.items.len) return error.UnknownScope;
        return &self.nodes.items[index];
    }
};
