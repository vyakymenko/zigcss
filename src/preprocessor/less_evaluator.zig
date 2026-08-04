//! Private bounded semantic evaluator for native Less syntax.
//!
//! The internal surface admits already-valid plain CSS plus the closed lazy
//! variable, lexical-scope, selector, and declaration foundation derived from
//! the pinned Less 4.6.7 selection. Mixins, imports, functions, operations, and
//! other evaluation semantics remain unavailable. JavaScript and plugin
//! execution are permanently rejected before any CSS is staged.

const std = @import("std");
const native_diagnostics = @import("diagnostics.zig");
const native_environment = @import("environment.zig");
const native_evaluator = @import("evaluator.zig");
const native_lexer = @import("lexer.zig");
const native_source = @import("source.zig");
const native_syntax = @import("syntax.zig");
const native_value = @import("value.zig");

const hard_source_bytes = 10 * 1024 * 1024;
const hard_nodes = 1_000_000;
const hard_variable_depth: u16 = 256;
const hard_selectors = 1_000_000;
const hard_temporary_bytes = 20 * 1024 * 1024;

pub const Limits = struct {
    max_source_bytes: usize = hard_source_bytes,
    max_nodes: usize = 200_000,
    environment: native_environment.Limits = .{},
    values: native_value.Limits = .{},
    max_variable_depth: u16 = 128,
    max_selectors: usize = 200_000,
    max_temporary_bytes: usize = 10 * 1024 * 1024,
};

pub const Error = native_evaluator.Error ||
    native_environment.Error ||
    native_lexer.Error ||
    native_source.Error ||
    native_syntax.Error ||
    native_value.Error || error{
    InvalidDocument,
    InvalidLimits,
    JavaScriptDisabled,
    NodeLimitExceeded,
    PluginDisabled,
    RecursiveVariable,
    SelectorLimitExceeded,
    SourceLimitExceeded,
    TemporaryLimitExceeded,
    UndefinedVariable,
    UnsupportedFeature,
    VariableDepthExceeded,
};

pub fn evaluate(
    sources: *const native_source.Table,
    document: *const native_syntax.Document,
    transaction: *native_evaluator.Transaction,
    limits: Limits,
) Error!void {
    errdefer transaction.abort();
    try validateLimits(limits);

    const root = try document.get(document.root);
    if (root.kind != .stylesheet) return error.InvalidDocument;
    const input = try sources.slice(root.span);
    if (input.len > limits.max_source_bytes) {
        try transaction.report(
            .err,
            .resource_limit,
            root.span,
            "native Less evaluator source limit exceeded",
            &.{},
        );
        return error.SourceLimitExceeded;
    }
    if (document.nodes().len > limits.max_nodes) {
        try transaction.report(
            .err,
            .resource_limit,
            root.span,
            "native Less evaluator node limit exceeded",
            &.{},
        );
        return error.NodeLimitExceeded;
    }

    try transaction.consumeOperations(@intCast(document.nodes().len));
    try rejectJavaScript(sources, root.span, input, transaction);
    for (document.nodes()) |node| try preflightNode(sources, node, transaction);

    if (!requiresSemanticEvaluation(document)) {
        try transaction.emitMapped(root.span, null, input);
        return;
    }

    var engine = try Engine.init(
        transaction.allocator,
        sources,
        document,
        transaction,
        limits,
    );
    defer engine.deinit();
    try engine.run();
}

fn validateLimits(limits: Limits) Error!void {
    if (limits.max_source_bytes == 0 or limits.max_source_bytes > hard_source_bytes or
        limits.max_nodes == 0 or limits.max_nodes > hard_nodes or
        limits.environment.max_scopes == 0 or
        limits.environment.max_scopes > 65_536 or
        limits.environment.max_scope_depth == 0 or
        limits.environment.max_scope_depth > 1_024 or
        limits.environment.max_bindings == 0 or
        limits.environment.max_bindings > 1_000_000 or
        limits.environment.max_name_bytes == 0 or
        limits.environment.max_name_bytes > 16 * 1024 * 1024 or
        limits.values.max_values == 0 or limits.values.max_values > 1_000_000 or
        limits.values.max_depth == 0 or limits.values.max_depth > 64 or
        limits.values.max_collection_items == 0 or
        limits.values.max_collection_items > 1_000_000 or
        limits.values.max_owned_bytes == 0 or
        limits.values.max_owned_bytes > 64 * 1024 * 1024 or
        limits.max_variable_depth == 0 or
        limits.max_variable_depth > hard_variable_depth or
        limits.max_selectors == 0 or limits.max_selectors > hard_selectors or
        limits.max_temporary_bytes == 0 or
        limits.max_temporary_bytes > hard_temporary_bytes)
    {
        return error.InvalidLimits;
    }
}

fn rejectJavaScript(
    sources: *const native_source.Table,
    root_span: native_source.Span,
    input: []const u8,
    transaction: *native_evaluator.Transaction,
) Error!void {
    var lexer = try native_lexer.Lexer.init(input, .less, .{});
    while (true) {
        const token = try lexer.next();
        if (token.kind == .eof) return;
        const raw = token.raw(input);
        if (token.kind != .delimiter or raw.len != 1 or raw[0] != 0x60) continue;
        const start = std.math.add(u32, root_span.start, token.span.start) catch
            return error.InvalidDocument;
        const end = std.math.add(u32, root_span.start, token.span.end) catch
            return error.InvalidDocument;
        const span = try sources.span(root_span.source, start, end);
        try transaction.report(
            .err,
            .unsupported_feature,
            span,
            "native Less JavaScript evaluation is permanently disabled",
            &.{},
        );
        return error.JavaScriptDisabled;
    }
}

fn preflightNode(
    sources: *const native_source.Table,
    node: native_syntax.Node,
    transaction: *native_evaluator.Transaction,
) Error!void {
    if (node.kind == .at_rule and node.text != null) {
        const keyword = try sources.slice(node.text.?);
        if (native_lexer.identifierEqlIgnoreCaseAscii(keyword, "@plugin")) {
            try transaction.report(
                .err,
                .unsupported_feature,
                node.text.?,
                "native Less plugins are permanently disabled",
                &.{},
            );
            return error.PluginDisabled;
        }
    }

    switch (node.kind) {
        .stylesheet,
        .block,
        .rule,
        .declaration,
        .at_rule,
        .identifier,
        .literal,
        .string,
        .comment,
        .selector,
        .expression,
        .variable,
        .interpolation,
        => {},
        .import => {
            try transaction.report(
                .err,
                .unsupported_feature,
                node.span,
                "native Less imports are not implemented in this evaluator slice",
                &.{},
            );
            return error.UnsupportedFeature;
        },
        .unary,
        .binary,
        .list,
        .map,
        .map_entry,
        .call,
        .argument,
        .parameter,
        .conditional,
        .loop,
        .mixin,
        .guard,
        .detached_ruleset,
        .extend,
        .function,
        .return_statement,
        .content,
        .module,
        => {
            try transaction.report(
                .err,
                .unsupported_feature,
                node.span,
                "native Less construct is not implemented in this evaluator slice",
                &.{},
            );
            return error.UnsupportedFeature;
        },
    }
}

fn requiresSemanticEvaluation(document: *const native_syntax.Document) bool {
    for (document.nodes()) |node| {
        if (node.kind == .variable or node.kind == .interpolation) return true;
    }
    return false;
}

const BindingState = enum {
    unresolved,
    evaluating,
    resolved,
};

const Binding = struct {
    holder: *const native_value.Value,
    name: []const u8,
    expression: native_source.Span,
    definition_scope: native_environment.ScopeId,
    state: BindingState = .unresolved,
    resolved: ?*const native_value.Value = null,
};

const Scope = struct {
    cursor: native_environment.ScopeId,
};

const RenderContext = enum {
    selector,
    property,
    value,
    at_rule,
};

const Engine = struct {
    allocator: std.mem.Allocator,
    sources: *const native_source.Table,
    document: *const native_syntax.Document,
    transaction: *native_evaluator.Transaction,
    limits: Limits,
    values: native_value.Store,
    environment: native_environment.Environment,
    bindings: std.ArrayList(Binding) = .empty,
    binding_indices: std.AutoHashMapUnmanaged(*const native_value.Value, usize) = .empty,
    selector_count: usize = 0,
    variable_depth: u16 = 0,

    fn init(
        allocator: std.mem.Allocator,
        sources: *const native_source.Table,
        document: *const native_syntax.Document,
        transaction: *native_evaluator.Transaction,
        limits: Limits,
    ) Error!Engine {
        var values = native_value.Store.init(allocator, limits.values);
        errdefer values.deinit();
        const environment = try native_environment.Environment.init(
            allocator,
            limits.environment,
        );
        return .{
            .allocator = allocator,
            .sources = sources,
            .document = document,
            .transaction = transaction,
            .limits = limits,
            .values = values,
            .environment = environment,
        };
    }

    fn deinit(self: *Engine) void {
        self.binding_indices.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        self.environment.deinit();
        self.values.deinit();
        self.* = undefined;
    }

    fn run(self: *Engine) Error!void {
        const root = self.document.get(self.document.root) catch return error.InvalidDocument;
        if (root.kind != .stylesheet) return error.InvalidDocument;
        const children = self.document.children(self.document.root) catch
            return error.InvalidDocument;
        const scope = try self.prepareScope(children, null);
        try self.emitStatements(children, scope, null);
    }

    fn prepareScope(
        self: *Engine,
        children: []const native_syntax.NodeId,
        parent: ?Scope,
    ) Error!Scope {
        const boundary = if (parent) |scope|
            try self.environment.push(scope.cursor)
        else
            self.environment.root();
        var result = Scope{ .cursor = boundary };
        const binding_start = self.bindings.items.len;
        for (children) |child_id| {
            if (try self.isVariableDeclaration(child_id)) {
                try self.addBinding(child_id, &result);
            }
        }
        for (self.bindings.items[binding_start..]) |*binding| {
            binding.definition_scope = result.cursor;
        }
        try self.rejectDirectCycles(binding_start);
        return result;
    }

    fn addBinding(
        self: *Engine,
        declaration_id: native_syntax.NodeId,
        scope: *Scope,
    ) Error!void {
        const declaration = self.document.get(declaration_id) catch
            return error.InvalidDocument;
        const children = self.document.children(declaration_id) catch
            return error.InvalidDocument;
        if (children.len != 2) return error.InvalidDocument;
        const name_node = self.document.get(children[0]) catch return error.InvalidDocument;
        const expression = self.document.get(children[1]) catch return error.InvalidDocument;
        if (name_node.kind != .variable or name_node.text == null or
            expression.kind != .expression or expression.text == null)
        {
            return error.InvalidDocument;
        }
        const raw_name = try self.sources.slice(name_node.text.?);
        const name = try normalizeVariableName(raw_name);
        const expression_bytes = try self.sources.slice(expression.text.?);
        const holder = try self.values.own(.{ .string = .{
            .bytes = expression_bytes,
        } });
        const binding_index = self.bindings.items.len;
        try self.bindings.append(self.allocator, .{
            .holder = holder,
            .name = name,
            .expression = expression.text.?,
            .definition_scope = scope.cursor,
        });
        try self.binding_indices.put(self.allocator, holder, binding_index);
        scope.cursor = try self.environment.set(scope.cursor, name, holder);
        try self.transaction.consumeOperations(1);
        _ = declaration;
    }

    fn rejectDirectCycles(self: *Engine, binding_start: usize) Error!void {
        for (self.bindings.items[binding_start..]) |binding| {
            const raw = try self.sources.slice(binding.expression);
            const tokens = try native_lexer.tokenizeAlloc(self.allocator, raw, .less, .{});
            defer if (tokens.len > 0) self.allocator.free(tokens);
            try self.transaction.consumeOperations(@intCast(tokens.len));
            for (tokens) |token| {
                if (token.kind != .at_identifier or
                    !std.mem.eql(u8, token.raw(raw), binding.name))
                {
                    continue;
                }
                const span = try self.relativeSpan(
                    binding.expression,
                    token.span.start,
                    token.span.end,
                );
                const message = try std.fmt.allocPrint(
                    self.allocator,
                    "recursive native Less variable definition for {s}",
                    .{binding.name},
                );
                defer self.allocator.free(message);
                try self.transaction.report(
                    .err,
                    .undefined_variable,
                    span,
                    message,
                    &.{},
                );
                return error.RecursiveVariable;
            }
        }
    }

    fn isVariableDeclaration(
        self: *const Engine,
        declaration_id: native_syntax.NodeId,
    ) Error!bool {
        const declaration = self.document.get(declaration_id) catch
            return error.InvalidDocument;
        if (declaration.kind != .declaration) return false;
        const children = self.document.children(declaration_id) catch
            return error.InvalidDocument;
        if (children.len == 0) return false;
        const first = self.document.get(children[0]) catch return error.InvalidDocument;
        return first.kind == .variable;
    }

    fn emitStatements(
        self: *Engine,
        children: []const native_syntax.NodeId,
        scope: Scope,
        parent_selector: ?[]const u8,
    ) Error!void {
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            switch (child.kind) {
                .declaration => if (!try self.isVariableDeclaration(child_id)) {
                    return error.InvalidDocument;
                },
                .rule => try self.emitRule(child_id, scope, parent_selector),
                .at_rule => try self.emitAtRule(child_id, scope, parent_selector),
                .comment => {},
                else => return error.InvalidDocument,
            }
        }
    }

    fn emitRule(
        self: *Engine,
        rule_id: native_syntax.NodeId,
        parent_scope: Scope,
        parent_selector: ?[]const u8,
    ) Error!void {
        const rule = self.document.get(rule_id) catch return error.InvalidDocument;
        const children = self.document.children(rule_id) catch return error.InvalidDocument;
        if (children.len != 2) return error.InvalidDocument;
        const selector_node = self.document.get(children[0]) catch return error.InvalidDocument;
        const block_node = self.document.get(children[1]) catch return error.InvalidDocument;
        if (selector_node.kind != .selector or selector_node.text == null or
            block_node.kind != .block)
        {
            return error.InvalidDocument;
        }
        const block_children = self.document.children(children[1]) catch
            return error.InvalidDocument;
        const scope = try self.prepareScope(block_children, parent_scope);
        const rendered_selector = try self.renderOwned(
            selector_node.text.?,
            parent_scope.cursor,
            .selector,
        );
        defer self.allocator.free(rendered_selector);
        const selector = try self.combineSelector(parent_selector, rendered_selector);
        defer self.allocator.free(selector);

        var declarations: std.ArrayList(u8) = .empty;
        defer declarations.deinit(self.allocator);
        for (block_children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            if (child.kind == .declaration and !try self.isVariableDeclaration(child_id)) {
                try self.appendDeclaration(&declarations, child_id, scope);
            }
        }
        if (declarations.items.len > 0) {
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(self.allocator);
            try self.appendTemporary(&output, selector);
            try self.appendTemporary(&output, "{");
            try self.appendTemporary(&output, declarations.items);
            try self.appendTemporary(&output, "}");
            try self.transaction.emitMapped(rule.span, null, output.items);
        }

        for (block_children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            switch (child.kind) {
                .rule => try self.emitRule(child_id, scope, selector),
                .at_rule => try self.emitAtRule(child_id, scope, selector),
                else => {},
            }
        }
    }

    fn appendDeclaration(
        self: *Engine,
        output: *std.ArrayList(u8),
        declaration_id: native_syntax.NodeId,
        scope: Scope,
    ) Error!void {
        const declaration = self.document.get(declaration_id) catch
            return error.InvalidDocument;
        const children = self.document.children(declaration_id) catch
            return error.InvalidDocument;
        if (children.len == 0 or children.len > 2) return error.InvalidDocument;
        const property_node = self.document.get(children[0]) catch return error.InvalidDocument;
        if (property_node.kind != .identifier or property_node.text == null) {
            return error.InvalidDocument;
        }
        const property = try self.renderOwned(property_node.text.?, scope.cursor, .property);
        defer self.allocator.free(property);
        try self.appendTemporary(output, property);
        try self.appendTemporary(output, ":");
        if (children.len == 2) {
            const value_node = self.document.get(children[1]) catch return error.InvalidDocument;
            if (value_node.kind != .expression or value_node.text == null) {
                return error.InvalidDocument;
            }
            const rendered = try self.renderOwned(value_node.text.?, scope.cursor, .value);
            defer self.allocator.free(rendered);
            try self.appendTemporary(output, rendered);
        }
        try self.appendTemporary(output, ";");
        _ = declaration;
    }

    fn emitAtRule(
        self: *Engine,
        at_rule_id: native_syntax.NodeId,
        scope: Scope,
        parent_selector: ?[]const u8,
    ) Error!void {
        const at_rule = self.document.get(at_rule_id) catch return error.InvalidDocument;
        if (at_rule.text == null) return error.InvalidDocument;
        const keyword = try self.sources.slice(at_rule.text.?);
        const children = self.document.children(at_rule_id) catch return error.InvalidDocument;
        var expression: ?*const native_syntax.Node = null;
        var block_id: ?native_syntax.NodeId = null;
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            switch (child.kind) {
                .expression => expression = child,
                .block => block_id = child_id,
                else => return error.InvalidDocument,
            }
        }
        const prelude = if (expression) |node|
            try self.renderOwned(node.text orelse return error.InvalidDocument, scope.cursor, .at_rule)
        else
            try self.allocator.dupe(u8, "");
        defer self.allocator.free(prelude);

        var header: std.ArrayList(u8) = .empty;
        defer header.deinit(self.allocator);
        try self.appendTemporary(&header, keyword);
        if (prelude.len > 0) {
            try self.appendTemporary(&header, " ");
            try self.appendTemporary(&header, prelude);
        }
        if (block_id == null) {
            try self.appendTemporary(&header, ";");
            try self.transaction.emitMapped(at_rule.span, null, header.items);
            return;
        }

        try self.appendTemporary(&header, "{");
        try self.transaction.emitMapped(at_rule.span, null, header.items);
        const block_children = self.document.children(block_id.?) catch
            return error.InvalidDocument;
        const block_scope = try self.prepareScope(block_children, scope);
        try self.emitStatements(block_children, block_scope, parent_selector);
        try self.transaction.emit("}");
    }

    fn combineSelector(
        self: *Engine,
        parent: ?[]const u8,
        raw_child: []const u8,
    ) Error![]u8 {
        const child = std.mem.trim(u8, raw_child, " \t\r\n\x0c");
        if (child.len == 0 or std.mem.indexOfScalar(u8, child, ',') != null) {
            return self.rejectUnsupportedSelector(child);
        }
        if (self.selector_count >= self.limits.max_selectors) {
            return error.SelectorLimitExceeded;
        }
        self.selector_count += 1;
        if (parent == null) return try self.allocator.dupe(u8, child);

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        if (std.mem.indexOfScalar(u8, child, '&') == null) {
            try self.appendTemporary(&output, parent.?);
            try self.appendTemporary(&output, " ");
            try self.appendTemporary(&output, child);
        } else {
            var cursor: usize = 0;
            for (child, 0..) |byte, index| {
                if (byte != '&') continue;
                try self.appendTemporary(&output, child[cursor..index]);
                try self.appendTemporary(&output, parent.?);
                cursor = index + 1;
            }
            try self.appendTemporary(&output, child[cursor..]);
        }
        return try output.toOwnedSlice(self.allocator);
    }

    fn rejectUnsupportedSelector(self: *Engine, selector: []const u8) Error {
        _ = selector;
        self.transaction.report(
            .err,
            .unsupported_feature,
            (self.document.get(self.document.root) catch return error.InvalidDocument).span,
            "native Less selector lists are not implemented in this evaluator slice",
            &.{},
        ) catch |err| return err;
        return error.UnsupportedFeature;
    }

    fn renderOwned(
        self: *Engine,
        span: native_source.Span,
        scope: native_environment.ScopeId,
        context: RenderContext,
    ) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        try self.renderInto(span, scope, context, &output);
        return try output.toOwnedSlice(self.allocator);
    }

    fn renderInto(
        self: *Engine,
        span: native_source.Span,
        scope: native_environment.ScopeId,
        context: RenderContext,
        output: *std.ArrayList(u8),
    ) Error!void {
        const raw = try self.sources.slice(span);
        const tokens = try native_lexer.tokenizeAlloc(self.allocator, raw, .less, .{});
        defer if (tokens.len > 0) self.allocator.free(tokens);
        try self.transaction.consumeOperations(@intCast(tokens.len));

        var unsupported = false;
        var cursor: usize = 0;
        var index: usize = 0;
        while (index < tokens.len) : (index += 1) {
            const token = tokens[index];
            if (token.kind == .eof) break;
            const token_start: usize = token.span.start;
            const token_end: usize = token.span.end;
            try self.appendTemporary(output, raw[cursor..token_start]);

            if (token.kind == .delimiter and std.mem.eql(u8, token.raw(raw), "@") and
                index + 1 < tokens.len and tokens[index + 1].kind == .at_identifier and
                token.span.end == tokens[index + 1].span.start)
            {
                const name_token = tokens[index + 1];
                const use_span = try self.relativeSpan(span, token.span.start, name_token.span.end);
                const name_value = try self.resolveVariable(
                    name_token.raw(raw),
                    use_span,
                    scope,
                );
                const unquoted = stripQuotes(std.mem.trim(u8, name_value, " \t\r\n\x0c"));
                const indirect = try self.indirectName(unquoted);
                defer self.allocator.free(indirect);
                const resolved = try self.resolveVariable(indirect, use_span, scope);
                try self.appendTemporary(output, resolved);
                cursor = name_token.span.end;
                index += 1;
                continue;
            }
            if (token.kind == .at_identifier) {
                const use_span = try self.relativeSpan(span, token.span.start, token.span.end);
                const resolved = try self.resolveVariable(token.raw(raw), use_span, scope);
                try self.appendTemporary(output, resolved);
                cursor = token_end;
                continue;
            }
            if (token.kind == .interpolation_start) {
                const closing = findInterpolationEnd(tokens, index) orelse
                    return error.InvalidDocument;
                const close_token = tokens[closing];
                const inner = std.mem.trim(
                    u8,
                    raw[token.span.end..close_token.span.start],
                    " \t\r\n\x0c",
                );
                const name = if (std.mem.startsWith(u8, inner, "@"))
                    try self.allocator.dupe(u8, inner)
                else
                    try self.indirectName(inner);
                defer self.allocator.free(name);
                const use_span = try self.relativeSpan(
                    span,
                    token.span.start,
                    close_token.span.end,
                );
                const resolved = try self.resolveVariable(name, use_span, scope);
                try self.appendTemporary(
                    output,
                    stripQuotes(std.mem.trim(u8, resolved, " \t\r\n\x0c")),
                );
                cursor = close_token.span.end;
                index = closing;
                continue;
            }
            if (token.kind == .comment and
                std.mem.startsWith(u8, token.raw(raw), "//"))
            {
                cursor = token_end;
                continue;
            }
            if (context == .value and
                (token.kind == .whitespace or token.kind == .newline) and
                previousSignificantKind(tokens, index) == .comma)
            {
                cursor = token_end;
                continue;
            }
            if (context == .value and token.kind == .operator) {
                const operator = token.raw(raw);
                if (std.mem.eql(u8, operator, "+") or
                    std.mem.eql(u8, operator, "*") or
                    std.mem.eql(u8, operator, "/") or
                    std.mem.eql(u8, operator, "~"))
                {
                    unsupported = true;
                }
            }
            if (context == .value and token.kind == .identifier and
                nextSignificantKind(tokens, index + 1) == .open_paren)
            {
                unsupported = true;
            }
            try self.appendTemporary(output, token.raw(raw));
            cursor = token_end;
        }
        try self.appendTemporary(output, raw[cursor..]);
        if (unsupported) {
            try self.transaction.report(
                .err,
                .unsupported_feature,
                span,
                "native Less operations and functions are not implemented in this evaluator slice",
                &.{},
            );
            return error.UnsupportedFeature;
        }
    }

    fn resolveVariable(
        self: *Engine,
        raw_name: []const u8,
        use_span: native_source.Span,
        scope: native_environment.ScopeId,
    ) Error![]const u8 {
        const name = normalizeVariableName(raw_name) catch {
            try self.reportUndefined(raw_name, use_span);
            return error.UndefinedVariable;
        };
        const holder = try self.environment.lookup(scope, name) orelse {
            try self.reportUndefined(name, use_span);
            return error.UndefinedVariable;
        };
        const binding_index = self.binding_indices.get(holder) orelse
            return error.InvalidDocument;
        const binding = &self.bindings.items[binding_index];
        if (binding.state == .evaluating) {
            const message = try std.fmt.allocPrint(
                self.allocator,
                "recursive native Less variable definition for {s}",
                .{name},
            );
            defer self.allocator.free(message);
            try self.transaction.report(
                .err,
                .undefined_variable,
                use_span,
                message,
                &.{},
            );
            return error.RecursiveVariable;
        }
        if (binding.resolved) |resolved| return resolved.string.bytes;
        if (self.variable_depth >= self.limits.max_variable_depth) {
            try self.transaction.report(
                .err,
                .resource_limit,
                use_span,
                "native Less variable resolution depth exceeded",
                &.{},
            );
            return error.VariableDepthExceeded;
        }

        self.variable_depth += 1;
        defer self.variable_depth -= 1;
        binding.state = .evaluating;
        errdefer binding.state = .unresolved;
        try self.transaction.enterCall();
        const rendered = try self.renderOwned(binding.expression, binding.definition_scope, .value);
        defer self.allocator.free(rendered);
        try self.transaction.leaveCall();
        const owned = try self.values.own(.{ .string = .{ .bytes = rendered } });
        binding.resolved = owned;
        binding.state = .resolved;
        return owned.string.bytes;
    }

    fn reportUndefined(
        self: *Engine,
        name: []const u8,
        span: native_source.Span,
    ) Error!void {
        const message = try std.fmt.allocPrint(
            self.allocator,
            "native Less variable {s} is undefined",
            .{name},
        );
        defer self.allocator.free(message);
        try self.transaction.report(.err, .undefined_variable, span, message, &.{});
    }

    fn indirectName(self: *Engine, raw: []const u8) Error![]u8 {
        if (!validBareVariableName(raw)) return error.UndefinedVariable;
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);
        try self.appendTemporary(&result, "@");
        try self.appendTemporary(&result, raw);
        return try result.toOwnedSlice(self.allocator);
    }

    fn relativeSpan(
        self: *const Engine,
        owner: native_source.Span,
        relative_start: u32,
        relative_end: u32,
    ) Error!native_source.Span {
        const start = std.math.add(u32, owner.start, relative_start) catch
            return error.InvalidDocument;
        const end = std.math.add(u32, owner.start, relative_end) catch
            return error.InvalidDocument;
        return self.sources.span(owner.source, start, end);
    }

    fn appendTemporary(
        self: *const Engine,
        output: *std.ArrayList(u8),
        bytes: []const u8,
    ) Error!void {
        const next = std.math.add(usize, output.items.len, bytes.len) catch
            return error.TemporaryLimitExceeded;
        if (next > self.limits.max_temporary_bytes) return error.TemporaryLimitExceeded;
        try output.appendSlice(self.allocator, bytes);
    }
};

fn normalizeVariableName(raw: []const u8) error{InvalidDocument}![]const u8 {
    if (raw.len < 2 or raw[0] != '@' or !validBareVariableName(raw[1..])) {
        return error.InvalidDocument;
    }
    return raw;
}

fn validBareVariableName(raw: []const u8) bool {
    if (raw.len == 0 or !(std.ascii.isAlphabetic(raw[0]) or raw[0] == '_')) return false;
    for (raw[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

fn stripQuotes(raw: []const u8) []const u8 {
    if (raw.len >= 2 and
        ((raw[0] == '\'' and raw[raw.len - 1] == '\'') or
            (raw[0] == '"' and raw[raw.len - 1] == '"')))
    {
        return raw[1 .. raw.len - 1];
    }
    return raw;
}

fn findInterpolationEnd(tokens: []const native_lexer.Token, start: usize) ?usize {
    var depth: usize = 0;
    var index = start;
    while (index < tokens.len) : (index += 1) {
        if (tokens[index].kind == .interpolation_start) depth += 1;
        if (tokens[index].kind == .interpolation_end) {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

fn nextSignificantKind(
    tokens: []const native_lexer.Token,
    start: usize,
) native_lexer.Kind {
    var index = start;
    while (index < tokens.len) : (index += 1) {
        switch (tokens[index].kind) {
            .whitespace, .newline, .comment => continue,
            else => return tokens[index].kind,
        }
    }
    return .eof;
}

fn previousSignificantKind(
    tokens: []const native_lexer.Token,
    end: usize,
) native_lexer.Kind {
    var index = end;
    while (index > 0) {
        index -= 1;
        switch (tokens[index].kind) {
            .whitespace, .newline, .comment => continue,
            else => return tokens[index].kind,
        }
    }
    return .eof;
}
