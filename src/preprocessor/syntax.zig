const std = @import("std");
const source = @import("source.zig");

pub const NodeId = struct {
    value: u32,
};

pub const Kind = enum {
    stylesheet,
    block,
    rule,
    declaration,
    at_rule,
    variable,
    identifier,
    literal,
    interpolation,
    expression,
    unary,
    binary,
    list,
    map,
    map_entry,
    call,
    argument,
    parameter,
    conditional,
    loop,
    mixin,
    function,
    return_statement,
    content,
    import,
    module,
};

pub const Node = struct {
    kind: Kind,
    span: source.Span,
    text: ?source.Span,
    child_start: u32,
    child_len: u32,
    depth: u16,
};

pub const Limits = struct {
    max_nodes: usize = 1_000_000,
    max_edges: usize = 4_000_000,
    max_depth: u16 = 512,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidSpan,
    SyntaxDepthExceeded,
    SyntaxEdgeLimitExceeded,
    SyntaxNodeLimitExceeded,
    UnknownNode,
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    root: NodeId,
    node_items: []const Node,
    child_items: []const NodeId,

    pub fn deinit(self: *Document) void {
        if (self.node_items.len > 0) self.allocator.free(self.node_items);
        if (self.child_items.len > 0) self.allocator.free(self.child_items);
        self.* = undefined;
    }

    pub fn get(self: *const Document, id: NodeId) error{UnknownNode}!*const Node {
        const index: usize = @intCast(id.value);
        if (index >= self.node_items.len) return error.UnknownNode;
        return &self.node_items[index];
    }

    pub fn children(self: *const Document, id: NodeId) error{UnknownNode}![]const NodeId {
        const node = try self.get(id);
        const start: usize = @intCast(node.child_start);
        const end = start + node.child_len;
        if (end > self.child_items.len) return error.UnknownNode;
        return self.child_items[start..end];
    }

    pub fn nodes(self: *const Document) []const Node {
        return self.node_items;
    }
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    sources: *const source.Table,
    limits: Limits,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(NodeId) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        sources: *const source.Table,
        limits: Limits,
    ) Builder {
        return .{ .allocator = allocator, .sources = sources, .limits = limits };
    }

    pub fn deinit(self: *Builder) void {
        self.nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(
        self: *Builder,
        kind: Kind,
        span: source.Span,
        text: ?source.Span,
        children_ids: []const NodeId,
    ) Error!NodeId {
        if (self.nodes.items.len >= self.limits.max_nodes or
            self.nodes.items.len >= std.math.maxInt(u32))
        {
            return error.SyntaxNodeLimitExceeded;
        }
        self.sources.validateSpan(span) catch return error.InvalidSpan;
        if (text) |text_span| {
            self.sources.validateSpan(text_span) catch return error.InvalidSpan;
            if (!text_span.source.eql(span.source) or
                text_span.start < span.start or text_span.end > span.end)
            {
                return error.InvalidSpan;
            }
        }

        var depth: u16 = 1;
        for (children_ids) |child_id| {
            const index: usize = @intCast(child_id.value);
            if (index >= self.nodes.items.len) return error.UnknownNode;
            const child_depth = self.nodes.items[index].depth;
            if (child_depth >= self.limits.max_depth) return error.SyntaxDepthExceeded;
            depth = @max(depth, child_depth + 1);
        }
        if (depth > self.limits.max_depth) return error.SyntaxDepthExceeded;

        const next_edges = std.math.add(usize, self.edges.items.len, children_ids.len) catch
            return error.SyntaxEdgeLimitExceeded;
        if (next_edges > self.limits.max_edges or next_edges > std.math.maxInt(u32)) {
            return error.SyntaxEdgeLimitExceeded;
        }

        const child_start = self.edges.items.len;
        try self.edges.appendSlice(self.allocator, children_ids);
        errdefer self.edges.shrinkRetainingCapacity(child_start);
        try self.nodes.append(self.allocator, .{
            .kind = kind,
            .span = span,
            .text = text,
            .child_start = @intCast(child_start),
            .child_len = @intCast(children_ids.len),
            .depth = depth,
        });
        return .{ .value = @intCast(self.nodes.items.len - 1) };
    }

    pub fn finish(self: *Builder, root: NodeId) Error!Document {
        const root_index: usize = @intCast(root.value);
        if (root_index >= self.nodes.items.len) return error.UnknownNode;

        const owned_edges = try self.edges.toOwnedSlice(self.allocator);
        errdefer if (owned_edges.len > 0) self.allocator.free(owned_edges);
        const owned_nodes = try self.nodes.toOwnedSlice(self.allocator);
        return .{
            .allocator = self.allocator,
            .root = root,
            .node_items = owned_nodes,
            .child_items = owned_edges,
        };
    }
};
