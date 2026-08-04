//! Private bounded semantic evaluator for native Stylus syntax.
//!
//! The evaluator owns a fixed four-slice implementation plan. This second
//! slice adds lexical variables, ordinary and interpolated properties,
//! interpolated/nested selectors, and bounded numeric expressions. Mixins,
//! functions, control flow, the broader operator/built-in surface, and imports
//! remain explicit later slices. Project plugins and custom evaluator hooks are
//! permanently outside this module's execution boundary.
//! In particular, external custom evaluator hooks are permanently disabled.

const std = @import("std");
const native_environment = @import("environment.zig");
const native_evaluator = @import("evaluator.zig");
const native_lexer = @import("lexer.zig");
const native_numeric = @import("sass_numeric.zig");
const native_source = @import("source.zig");
const native_stylus = @import("stylus.zig");
const native_syntax = @import("syntax.zig");
const native_value = @import("value.zig");

const hard_source_bytes = 10 * 1024 * 1024;
const hard_nodes = 1_000_000;
const hard_expression_depth: u16 = 64;
const hard_selectors = 1_000_000;
const hard_temporary_bytes = 20 * 1024 * 1024;

pub const Limits = struct {
    max_source_bytes: usize = hard_source_bytes,
    max_nodes: usize = 200_000,
    environment: native_environment.Limits = .{},
    values: native_value.Limits = .{},
    max_expression_depth: u16 = 32,
    max_selectors: usize = 200_000,
    max_temporary_bytes: usize = 10 * 1024 * 1024,
};

pub const Error = native_environment.Error ||
    native_evaluator.Error ||
    native_lexer.Error ||
    native_source.Error ||
    native_stylus.Error ||
    native_syntax.Error ||
    native_value.Error || error{
    ExpressionDepthExceeded,
    InvalidDocument,
    InvalidLimits,
    InvalidOperation,
    NodeLimitExceeded,
    PluginDisabled,
    SelectorLimitExceeded,
    SourceLimitExceeded,
    TemporaryLimitExceeded,
    UndefinedVariable,
    UnsupportedFeature,
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
            "native Stylus evaluator source limit exceeded",
            &.{},
        );
        return error.SourceLimitExceeded;
    }
    if (document.nodes().len > limits.max_nodes) {
        try transaction.report(
            .err,
            .resource_limit,
            root.span,
            "native Stylus evaluator node limit exceeded",
            &.{},
        );
        return error.NodeLimitExceeded;
    }

    try transaction.consumeOperations(@intCast(document.nodes().len));
    try rejectUsePlugins(sources, root.span, input, transaction);
    const semantic = try requiresSemanticEvaluation(document, input);
    try preflightStatements(
        document,
        try document.children(document.root),
        transaction,
        semantic,
    );
    if (semantic) try rejectDeferredBuiltins(sources, document, transaction);
    if (!semantic) {
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
        limits.max_expression_depth == 0 or
        limits.max_expression_depth > hard_expression_depth or
        limits.max_selectors == 0 or limits.max_selectors > hard_selectors or
        limits.max_temporary_bytes == 0 or
        limits.max_temporary_bytes > hard_temporary_bytes)
    {
        return error.InvalidLimits;
    }
}

fn rejectUsePlugins(
    sources: *const native_source.Table,
    root_span: native_source.Span,
    input: []const u8,
    transaction: *native_evaluator.Transaction,
) Error!void {
    var lexer = try native_lexer.Lexer.init(input, .stylus, .{});
    var candidate: ?native_lexer.Token = null;
    while (true) {
        const token = try lexer.next();
        if (candidate) |name| {
            switch (token.kind) {
                .whitespace, .comment => continue,
                .open_paren => {
                    const start = std.math.add(u32, root_span.start, name.span.start) catch
                        return error.InvalidDocument;
                    const end = std.math.add(u32, root_span.start, name.span.end) catch
                        return error.InvalidDocument;
                    const span = try sources.span(root_span.source, start, end);
                    try transaction.report(
                        .err,
                        .unsupported_feature,
                        span,
                        "native Stylus use() plugins are permanently disabled",
                        &.{},
                    );
                    return error.PluginDisabled;
                },
                else => candidate = null,
            }
        }
        if (token.kind == .eof) return;
        if (token.kind == .identifier and
            native_lexer.identifierEqlIgnoreCaseAscii(token.raw(input), "use"))
        {
            candidate = token;
        }
    }
}

fn requiresSemanticEvaluation(
    document: *const native_syntax.Document,
    input: []const u8,
) Error!bool {
    for (document.nodes()) |node| {
        if (node.kind == .variable) return true;
    }
    if (std.mem.indexOfScalar(u8, input, '{') != null) return false;
    for (document.nodes(), 0..) |node, index| {
        if (node.kind != .rule) continue;
        if ((try document.children(.{ .value = @intCast(index) })).len > 1) return true;
    }
    return false;
}

fn preflightStatements(
    document: *const native_syntax.Document,
    statements: []const native_syntax.NodeId,
    transaction: *native_evaluator.Transaction,
    semantic: bool,
) Error!void {
    for (statements) |statement_id| {
        const statement = try document.get(statement_id);
        switch (statement.kind) {
            .import => {
                try transaction.report(
                    .err,
                    .unsupported_feature,
                    statement.span,
                    "native Stylus imports are not implemented in this evaluator slice",
                    &.{},
                );
                return error.UnsupportedFeature;
            },
            .mixin,
            .function,
            .conditional,
            .loop,
            .return_statement,
            .expression,
            => {
                try transaction.report(
                    .err,
                    .unsupported_feature,
                    statement.span,
                    "native Stylus construct is not implemented in this evaluator slice",
                    &.{},
                );
                return error.UnsupportedFeature;
            },
            .at_rule => if (semantic) {
                try transaction.report(
                    .err,
                    .unsupported_feature,
                    statement.span,
                    "native Stylus at-rules are not implemented in this evaluator slice",
                    &.{},
                );
                return error.UnsupportedFeature;
            },
            else => {},
        }

        for (try document.children(statement_id)) |child_id| {
            const child = try document.get(child_id);
            if (child.kind == .block) {
                try preflightStatements(
                    document,
                    try document.children(child_id),
                    transaction,
                    semantic,
                );
            }
        }
    }
}

fn rejectDeferredBuiltins(
    sources: *const native_source.Table,
    document: *const native_syntax.Document,
    transaction: *native_evaluator.Transaction,
) Error!void {
    for (document.nodes()) |node| {
        if (node.kind != .call or node.text == null) continue;
        const raw = try sources.slice(node.text.?);
        const opening = std.mem.indexOfScalar(u8, raw, '(') orelse continue;
        const name = std.mem.trim(u8, raw[0..opening], " \t\r\n\x0c");
        if (!isDeferredBuiltin(name)) continue;
        try transaction.report(
            .err,
            .unsupported_feature,
            node.text.?,
            "native Stylus built-in functions are not implemented in this evaluator slice",
            &.{},
        );
        return error.UnsupportedFeature;
    }
}

fn isDeferredBuiltin(name: []const u8) bool {
    inline for (.{
        "add-property",
        "adjust",
        "alpha",
        "append",
        "asin",
        "acos",
        "atan",
        "base-convert",
        "basename",
        "blend",
        "blue",
        "clone",
        "component",
        "contrast",
        "convert",
        "current-media",
        "define",
        "dirname",
        "error",
        "extend",
        "extname",
        "green",
        "hue",
        "image-size",
        "json",
        "length",
        "lightness",
        "list-separator",
        "lookup",
        "luminosity",
        "match",
        "math",
        "merge",
        "operate",
        "opposite-position",
        "p",
        "pathjoin",
        "pop",
        "prepend",
        "push",
        "range",
        "red",
        "remove",
        "replace",
        "s",
        "saturation",
        "selector-exists",
        "selector",
        "selectors",
        "shift",
        "slice",
        "split",
        "substr",
        "tan",
        "trace",
        "transparentify",
        "type",
        "type-of",
        "typeof",
        "unit",
        "unquote",
        "unshift",
        "warn",
    }) |builtin| {
        if (native_lexer.identifierEqlIgnoreCaseAscii(name, builtin)) return true;
    }
    return false;
}

const RenderContext = enum {
    selector,
    property,
    value,
    interpolation,
};

const ByteRange = struct {
    start: usize,
    end: usize,
};

const Assignment = struct {
    name: []const u8,
    value: []const u8,
    conditional: bool,
};

const RenderedDeclaration = struct {
    span: native_source.Span,
    property: []u8,
    value: []u8,

    fn deinit(self: *RenderedDeclaration, allocator: std.mem.Allocator) void {
        allocator.free(self.property);
        allocator.free(self.value);
        self.* = undefined;
    }
};

const NestedRule = struct {
    id: native_syntax.NodeId,
    scope: native_environment.ScopeId,
};

const Engine = struct {
    allocator: std.mem.Allocator,
    sources: *const native_source.Table,
    document: *const native_syntax.Document,
    transaction: *native_evaluator.Transaction,
    limits: Limits,
    values: native_value.Store,
    environment: native_environment.Environment,
    selector_count: usize = 0,
    temporary_bytes: usize = 0,

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
        self.environment.deinit();
        self.values.deinit();
        self.* = undefined;
    }

    fn run(self: *Engine) Error!void {
        const root = self.document.get(self.document.root) catch
            return error.InvalidDocument;
        if (root.kind != .stylesheet) return error.InvalidDocument;
        var scope = self.environment.root();
        for (try self.document.children(self.document.root)) |child_id| {
            const child = try self.document.get(child_id);
            switch (child.kind) {
                .variable => try self.assign(child_id, &scope),
                .rule => try self.emitRule(child_id, scope, null),
                .comment => {},
                else => return error.InvalidDocument,
            }
        }
    }

    fn assign(
        self: *Engine,
        node_id: native_syntax.NodeId,
        scope: *native_environment.ScopeId,
    ) Error!void {
        const node = try self.document.get(node_id);
        const text = node.text orelse return error.InvalidDocument;
        const raw = try self.sources.slice(text);
        const assignment = parseAssignment(raw) orelse {
            try self.transaction.report(
                .err,
                .syntax,
                text,
                "native Stylus variable assignment is invalid",
                &.{},
            );
            return error.InvalidDocument;
        };
        if (assignment.conditional and
            try self.environment.lookup(scope.*, assignment.name) != null)
        {
            return;
        }
        const evaluated = try self.evaluateValue(text, assignment.value, scope.*, 0);
        scope.* = try self.environment.set(scope.*, assignment.name, evaluated);
    }

    fn emitRule(
        self: *Engine,
        rule_id: native_syntax.NodeId,
        parent_scope: native_environment.ScopeId,
        parent_selector: ?[]const u8,
    ) Error!void {
        const rule = try self.document.get(rule_id);
        const children = try self.document.children(rule_id);
        if (children.len != 2) return error.InvalidDocument;
        const selector_node = try self.document.get(children[0]);
        const block_node = try self.document.get(children[1]);
        if (selector_node.kind != .selector or selector_node.text == null or
            block_node.kind != .block)
        {
            return error.InvalidDocument;
        }

        const rendered = try self.renderTextOwned(
            selector_node.text.?,
            parent_scope,
            .selector,
            0,
        );
        defer self.allocator.free(rendered);
        const selector = try self.combineSelectors(
            parent_selector,
            rendered,
            selector_node.text.?,
        );
        defer self.allocator.free(selector);

        var scope = self.environment.push(parent_scope) catch |failure| {
            try self.reportResource(rule.span, "native Stylus lexical scope limit exceeded");
            return failure;
        };
        var declarations: std.ArrayList(RenderedDeclaration) = .empty;
        defer {
            for (declarations.items) |*declaration| declaration.deinit(self.allocator);
            declarations.deinit(self.allocator);
        }
        var nested: std.ArrayList(NestedRule) = .empty;
        defer nested.deinit(self.allocator);

        for (try self.document.children(children[1])) |child_id| {
            const child = try self.document.get(child_id);
            switch (child.kind) {
                .variable => try self.assign(child_id, &scope),
                .declaration => {
                    var rendered_declaration = try self.renderDeclaration(child_id, scope);
                    errdefer rendered_declaration.deinit(self.allocator);
                    try declarations.append(self.allocator, rendered_declaration);
                },
                .rule => try nested.append(self.allocator, .{ .id = child_id, .scope = scope }),
                .comment => {},
                else => return error.InvalidDocument,
            }
        }

        if (declarations.items.len > 0) {
            try self.transaction.emitMapped(selector_node.text.?, null, selector);
            try self.transaction.emit("{");
            for (declarations.items) |declaration| {
                try self.transaction.emitMapped(declaration.span, null, declaration.property);
                try self.transaction.emit(":");
                try self.transaction.emitMapped(declaration.span, null, declaration.value);
                try self.transaction.emit(";");
            }
            try self.transaction.emit("}");
        }
        for (nested.items) |child| {
            try self.emitRule(child.id, child.scope, selector);
        }
    }

    fn renderDeclaration(
        self: *Engine,
        declaration_id: native_syntax.NodeId,
        scope: native_environment.ScopeId,
    ) Error!RenderedDeclaration {
        const declaration = try self.document.get(declaration_id);
        const text = declaration.text orelse return error.InvalidDocument;
        const raw = try self.sources.slice(text);
        const parts = splitDeclaration(raw) orelse {
            try self.transaction.report(
                .err,
                .syntax,
                text,
                "native Stylus property declaration is invalid",
                &.{},
            );
            return error.InvalidDocument;
        };
        const property_span = try self.relativeSpan(text, parts[0]);
        const value_span = try self.relativeSpan(text, parts[1]);
        const property = try self.renderTextOwned(property_span, scope, .property, 0);
        errdefer self.allocator.free(property);
        const value = try self.evaluateValue(value_span, raw[parts[1].start..parts[1].end], scope, 0);
        const serialized = try self.serializeValueOwned(value, .value, value_span);
        return .{ .span = declaration.span, .property = property, .value = serialized };
    }

    fn evaluateValue(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        scope: native_environment.ScopeId,
        depth: u16,
    ) Error!*const native_value.Value {
        if (depth >= self.limits.max_expression_depth) {
            try self.reportExpressionDepth(span);
            return error.ExpressionDepthExceeded;
        }
        const rendered = try self.renderRawOwned(span, raw, scope, .value, depth + 1);
        defer self.allocator.free(rendered);
        const input = std.mem.trim(u8, rendered, " \t\r\n\x0c;");
        if (input.len >= 2 and
            ((input[0] == '\'' and input[input.len - 1] == '\'') or
                (input[0] == '"' and input[input.len - 1] == '"')))
        {
            return self.ownValue(span, .{ .string = .{
                .bytes = input[1 .. input.len - 1],
                .quoted = true,
            } });
        }
        if (std.mem.eql(u8, input, "true")) {
            return self.ownValue(span, .{ .boolean = true });
        }
        if (std.mem.eql(u8, input, "false")) {
            return self.ownValue(span, .{ .boolean = false });
        }

        if (looksNumeric(input)) {
            var parser = NumericParser{
                .input = input,
                .max_depth = self.limits.max_expression_depth,
            };
            if (parser.parse()) |numeric| {
                var numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
                var denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
                const number = numeric.toNumber(&numerator, &denominator) catch {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                };
                return self.ownValue(span, .{ .number = number });
            } else |failure| switch (failure) {
                error.ExpressionDepthExceeded => {
                    try self.reportExpressionDepth(span);
                    return error.ExpressionDepthExceeded;
                },
                error.InvalidExpression => {},
                else => {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                },
            }
        }
        return self.ownValue(span, .{ .string = .{ .bytes = input } });
    }

    fn ownValue(
        self: *Engine,
        span: native_source.Span,
        input: native_value.Value,
    ) Error!*const native_value.Value {
        return self.values.own(input) catch |failure| {
            switch (failure) {
                error.ValueDepthExceeded, error.ValueLimitExceeded => try self.reportResource(span, "native Stylus value limit exceeded"),
                else => {},
            }
            return failure;
        };
    }

    fn renderTextOwned(
        self: *Engine,
        span: native_source.Span,
        scope: native_environment.ScopeId,
        context: RenderContext,
        depth: u16,
    ) Error![]u8 {
        return self.renderRawOwned(span, try self.sources.slice(span), scope, context, depth);
    }

    fn renderRawOwned(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        scope: native_environment.ScopeId,
        context: RenderContext,
        depth: u16,
    ) Error![]u8 {
        if (depth >= self.limits.max_expression_depth) {
            try self.reportExpressionDepth(span);
            return error.ExpressionDepthExceeded;
        }
        try self.transaction.consumeOperations(@intCast(raw.len));
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var index: usize = 0;
        var quote: u8 = 0;
        var escaped = false;
        while (index < raw.len) {
            const byte = raw[index];
            if (escaped) {
                try self.appendTemporary(&output, span, raw[index - 1 .. index + 1]);
                escaped = false;
                index += 1;
                continue;
            }
            if (byte == '\\') {
                escaped = true;
                index += 1;
                continue;
            }
            if (quote != 0) {
                if (byte == quote) {
                    try self.appendTemporary(&output, span, raw[index .. index + 1]);
                    quote = 0;
                    index += 1;
                    continue;
                }
                if (byte == '{') {
                    const closing = matchingCurly(raw, index) orelse return error.InvalidDocument;
                    const inner_span = try self.relativeSpan(span, .{
                        .start = index + 1,
                        .end = closing,
                    });
                    const inner = try self.evaluateValue(
                        inner_span,
                        raw[index + 1 .. closing],
                        scope,
                        depth + 1,
                    );
                    const replacement = try self.serializeValueOwned(
                        inner,
                        .interpolation,
                        inner_span,
                    );
                    defer self.allocator.free(replacement);
                    try self.appendTemporary(&output, span, replacement);
                    index = closing + 1;
                    continue;
                }
                try self.appendTemporary(&output, span, raw[index .. index + 1]);
                index += 1;
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte;
                try self.appendTemporary(&output, span, raw[index .. index + 1]);
                index += 1;
                continue;
            }
            if (byte == '/' and index + 1 < raw.len and raw[index + 1] == '/') break;
            if (byte == '/' and index + 1 < raw.len and raw[index + 1] == '*') {
                const relative = std.mem.indexOfPos(u8, raw, index + 2, "*/") orelse
                    return error.InvalidDocument;
                index = relative + 2;
                continue;
            }
            if (byte == '{') {
                const closing = matchingCurly(raw, index) orelse return error.InvalidDocument;
                const inner_span = try self.relativeSpan(span, .{
                    .start = index + 1,
                    .end = closing,
                });
                const inner = try self.evaluateValue(
                    inner_span,
                    raw[index + 1 .. closing],
                    scope,
                    depth + 1,
                );
                const replacement = try self.serializeValueOwned(
                    inner,
                    .interpolation,
                    inner_span,
                );
                defer self.allocator.free(replacement);
                try self.appendTemporary(&output, span, replacement);
                index = closing + 1;
                continue;
            }
            if (isNameStart(raw, index)) {
                const start = index;
                index = nameEnd(raw, index);
                const name = raw[start..index];
                const unit_suffix = start > 0 and
                    (std.ascii.isDigit(raw[start - 1]) or raw[start - 1] == '.');
                const substitute = context == .value and !unit_suffix;
                if (substitute) {
                    if (try self.environment.lookup(scope, name)) |resolved| {
                        const replacement = try self.serializeValueOwned(
                            resolved,
                            context,
                            span,
                        );
                        defer self.allocator.free(replacement);
                        try self.appendTemporary(&output, span, replacement);
                        continue;
                    }
                    if (name[0] == '$') {
                        try self.transaction.report(
                            .err,
                            .undefined_variable,
                            span,
                            "native Stylus variable is undefined",
                            &.{},
                        );
                        return error.UndefinedVariable;
                    }
                }
                try self.appendTemporary(&output, span, name);
                continue;
            }
            try self.appendTemporary(&output, span, raw[index .. index + 1]);
            index += 1;
        }
        if (escaped) try self.appendTemporary(&output, span, "\\");
        return output.toOwnedSlice(self.allocator);
    }

    fn serializeValueOwned(
        self: *Engine,
        input: *const native_value.Value,
        context: RenderContext,
        span: native_source.Span,
    ) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        switch (input.*) {
            .null_value => try self.appendTemporary(&output, span, "null"),
            .boolean => |item| try self.appendTemporary(
                &output,
                span,
                if (item) "true" else "false",
            ),
            .number => |number| {
                var number_buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
                const scalar = native_numeric.serialize(number.value, &number_buffer, false) catch {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                };
                var unit_buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
                const units = native_numeric.serializeUnits(number, &unit_buffer) catch {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                };
                try self.appendTemporary(&output, span, scalar);
                try self.appendTemporary(&output, span, units);
            },
            .string, .selector => |item| {
                if (item.quoted and context == .value) {
                    try self.appendTemporary(&output, span, "'");
                    try self.appendTemporary(&output, span, item.bytes);
                    try self.appendTemporary(&output, span, "'");
                } else {
                    try self.appendTemporary(&output, span, item.bytes);
                }
            },
            else => return error.InvalidDocument,
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn combineSelectors(
        self: *Engine,
        parent_selector: ?[]const u8,
        child_selector: []const u8,
        span: native_source.Span,
    ) Error![]u8 {
        var children = try splitTopLevel(self.allocator, child_selector, ',');
        defer children.deinit(self.allocator);
        var parents: std.ArrayList(ByteRange) = .empty;
        defer parents.deinit(self.allocator);
        if (parent_selector) |parent| {
            parents = try splitTopLevel(self.allocator, parent, ',');
        } else {
            try parents.append(self.allocator, .{ .start = 0, .end = 0 });
        }

        const count = std.math.mul(usize, children.items.len, parents.items.len) catch {
            try self.reportSelectorLimit(span);
            return error.SelectorLimitExceeded;
        };
        if (count == 0 or count > self.limits.max_selectors -| self.selector_count) {
            try self.reportSelectorLimit(span);
            return error.SelectorLimitExceeded;
        }
        self.selector_count += count;

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        for (children.items) |child_range| {
            const child = std.mem.trim(
                u8,
                child_selector[child_range.start..child_range.end],
                " \t\r\n\x0c",
            );
            if (child.len == 0) return error.InvalidDocument;
            for (parents.items) |parent_range| {
                if (output.items.len > 0) try self.appendTemporary(&output, span, ",");
                if (parent_selector) |parent_raw| {
                    const parent = std.mem.trim(
                        u8,
                        parent_raw[parent_range.start..parent_range.end],
                        " \t\r\n\x0c",
                    );
                    if (std.mem.indexOfScalar(u8, child, '&') != null) {
                        try self.appendReplacingAmpersands(&output, span, child, parent);
                    } else {
                        try self.appendTemporary(&output, span, parent);
                        try self.appendTemporary(&output, span, " ");
                        try self.appendTemporary(&output, span, child);
                    }
                } else {
                    try self.appendTemporary(&output, span, child);
                }
            }
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn appendReplacingAmpersands(
        self: *Engine,
        output: *std.ArrayList(u8),
        span: native_source.Span,
        child: []const u8,
        parent: []const u8,
    ) Error!void {
        var cursor: usize = 0;
        while (std.mem.indexOfScalarPos(u8, child, cursor, '&')) |marker| {
            try self.appendTemporary(output, span, child[cursor..marker]);
            try self.appendTemporary(output, span, parent);
            cursor = marker + 1;
        }
        try self.appendTemporary(output, span, child[cursor..]);
    }

    fn appendTemporary(
        self: *Engine,
        output: *std.ArrayList(u8),
        span: native_source.Span,
        bytes: []const u8,
    ) Error!void {
        const next = std.math.add(usize, self.temporary_bytes, bytes.len) catch {
            try self.reportResource(span, "native Stylus temporary byte limit exceeded");
            return error.TemporaryLimitExceeded;
        };
        if (next > self.limits.max_temporary_bytes) {
            try self.reportResource(span, "native Stylus temporary byte limit exceeded");
            return error.TemporaryLimitExceeded;
        }
        try output.appendSlice(self.allocator, bytes);
        self.temporary_bytes = next;
    }

    fn relativeSpan(
        self: *const Engine,
        parent: native_source.Span,
        relative: ByteRange,
    ) Error!native_source.Span {
        const start = std.math.add(u32, parent.start, @intCast(relative.start)) catch
            return error.InvalidDocument;
        const end = std.math.add(u32, parent.start, @intCast(relative.end)) catch
            return error.InvalidDocument;
        return self.sources.span(parent.source, start, end);
    }

    fn reportResource(self: *Engine, span: native_source.Span, message: []const u8) Error!void {
        try self.transaction.report(.err, .resource_limit, span, message, &.{});
    }

    fn reportSelectorLimit(self: *Engine, span: native_source.Span) Error!void {
        try self.reportResource(span, "native Stylus selector limit exceeded");
    }

    fn reportExpressionDepth(self: *Engine, span: native_source.Span) Error!void {
        try self.reportResource(span, "native Stylus expression depth exceeded");
    }

    fn reportInvalidOperation(self: *Engine, span: native_source.Span) Error!void {
        try self.transaction.report(
            .err,
            .invalid_operation,
            span,
            "native Stylus numeric expression is invalid",
            &.{},
        );
    }
};

fn parseAssignment(raw_input: []const u8) ?Assignment {
    const raw = std.mem.trim(u8, raw_input, " \t\r\n\x0c;");
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        if (quote != 0) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == quote) {
                quote = 0;
            }
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        switch (byte) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            else => {},
        }
        if (depth != 0 or byte != '=') continue;
        const operator_start = if (index > 0 and raw[index - 1] == '?') index - 1 else index;
        const name = std.mem.trim(u8, raw[0..operator_start], " \t\r\n\x0c");
        const value = std.mem.trim(u8, raw[index + 1 ..], " \t\r\n\x0c");
        if (!validVariableName(name) or value.len == 0) return null;
        return .{
            .name = name,
            .value = value,
            .conditional = operator_start != index,
        };
    }
    return null;
}

fn validVariableName(name: []const u8) bool {
    if (name.len == 0) return false;
    var index: usize = if (name[0] == '$') 1 else 0;
    if (index >= name.len or
        (!std.ascii.isAlphabetic(name[index]) and name[index] != '_' and name[index] != '-'))
    {
        return false;
    }
    index += 1;
    while (index < name.len) : (index += 1) {
        if (!std.ascii.isAlphanumeric(name[index]) and name[index] != '_' and name[index] != '-') {
            return false;
        }
    }
    return true;
}

fn splitDeclaration(raw: []const u8) ?[2]ByteRange {
    const bounds = trimRange(raw, .{ .start = 0, .end = raw.len });
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    var index = bounds.start;
    while (index < bounds.end) : (index += 1) {
        const byte = raw[index];
        if (quote != 0) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == quote) {
                quote = 0;
            }
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        switch (byte) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            else => {},
        }
        if (depth != 0) continue;
        if (byte == ':') {
            const property = trimRange(raw, .{ .start = bounds.start, .end = index });
            const value = trimRange(raw, .{ .start = index + 1, .end = bounds.end });
            if (property.start == property.end or value.start == value.end) return null;
            return .{ property, value };
        }
        if (std.ascii.isWhitespace(byte)) {
            var value_start = index;
            while (value_start < bounds.end and std.ascii.isWhitespace(raw[value_start])) {
                value_start += 1;
            }
            const property = trimRange(raw, .{ .start = bounds.start, .end = index });
            const value = trimRange(raw, .{ .start = value_start, .end = bounds.end });
            if (property.start == property.end or value.start == value.end) return null;
            return .{ property, value };
        }
    }
    return null;
}

fn trimRange(raw: []const u8, input: ByteRange) ByteRange {
    var start = input.start;
    var end = input.end;
    while (start < end and std.ascii.isWhitespace(raw[start])) start += 1;
    while (end > start and (std.ascii.isWhitespace(raw[end - 1]) or raw[end - 1] == ';')) end -= 1;
    return .{ .start = start, .end = end };
}

fn splitTopLevel(
    allocator: std.mem.Allocator,
    raw: []const u8,
    delimiter: u8,
) std.mem.Allocator.Error!std.ArrayList(ByteRange) {
    var output: std.ArrayList(ByteRange) = .empty;
    errdefer output.deinit(allocator);
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    var start: usize = 0;
    for (raw, 0..) |byte, index| {
        if (quote != 0) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == quote) {
                quote = 0;
            }
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        switch (byte) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            else => {},
        }
        if (byte == delimiter and depth == 0) {
            try output.append(allocator, .{ .start = start, .end = index });
            start = index + 1;
        }
    }
    try output.append(allocator, .{ .start = start, .end = raw.len });
    return output;
}

fn matchingCurly(raw: []const u8, opening: usize) ?usize {
    if (opening >= raw.len or raw[opening] != '{') return null;
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    var index = opening;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        if (quote != 0) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == quote) {
                quote = 0;
            }
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        if (byte == '{') depth += 1;
        if (byte == '}') {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

fn isNameStart(raw: []const u8, index: usize) bool {
    if (index >= raw.len) return false;
    const byte = raw[index];
    if (byte == '$' or std.ascii.isAlphabetic(byte) or byte == '_') return true;
    return byte == '-' and index + 1 < raw.len and
        (std.ascii.isAlphabetic(raw[index + 1]) or raw[index + 1] == '_' or
            raw[index + 1] == '-');
}

fn nameEnd(raw: []const u8, start: usize) usize {
    var index = start + 1;
    while (index < raw.len and
        (std.ascii.isAlphanumeric(raw[index]) or raw[index] == '_' or raw[index] == '-'))
    {
        index += 1;
    }
    return index;
}

fn looksNumeric(input: []const u8) bool {
    if (input.len == 0 or
        (!std.ascii.isDigit(input[0]) and input[0] != '.' and input[0] != '+' and
            input[0] != '-' and input[0] != '('))
    {
        return false;
    }
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.ascii.isWhitespace(byte) or
            std.mem.indexOfScalar(u8, ".%+-*/()", byte) != null)
        {
            continue;
        }
        return false;
    }
    return true;
}

const NumericParser = struct {
    input: []const u8,
    max_depth: u16,
    cursor: usize = 0,

    const ParseError = native_numeric.Error || error{
        ExpressionDepthExceeded,
        InvalidExpression,
    };

    fn parse(self: *NumericParser) ParseError!native_numeric.Numeric {
        const result = try self.parseAdd(0);
        self.skipWhitespace();
        if (self.cursor != self.input.len) return error.InvalidExpression;
        return result;
    }

    fn parseAdd(self: *NumericParser, depth: u16) ParseError!native_numeric.Numeric {
        var result = try self.parseMultiply(depth);
        while (true) {
            self.skipWhitespace();
            const operation = self.peek();
            if (operation != '+' and operation != '-') return result;
            self.cursor += 1;
            const right = try self.parseMultiply(depth);
            result = try native_numeric.addPermissive(result, right, operation);
        }
    }

    fn parseMultiply(self: *NumericParser, depth: u16) ParseError!native_numeric.Numeric {
        var result = try self.parsePrimary(depth);
        while (true) {
            self.skipWhitespace();
            const operation = self.peek();
            if (operation != '*' and operation != '/') return result;
            if (operation == '/' and depth == 0) return result;
            self.cursor += 1;
            const right = try self.parsePrimary(depth);
            result = try native_numeric.multiply(result, right, operation);
        }
    }

    fn parsePrimary(self: *NumericParser, depth: u16) ParseError!native_numeric.Numeric {
        self.skipWhitespace();
        if (self.peek() == '(') {
            if (depth + 1 >= self.max_depth) return error.ExpressionDepthExceeded;
            self.cursor += 1;
            const result = try self.parseAdd(depth + 1);
            self.skipWhitespace();
            if (self.peek() != ')') return error.InvalidExpression;
            self.cursor += 1;
            return result;
        }

        const start = self.cursor;
        if (self.peek() == '+' or self.peek() == '-') self.cursor += 1;
        var saw_digit = false;
        while (std.ascii.isDigit(self.peek())) {
            saw_digit = true;
            self.cursor += 1;
        }
        if (self.peek() == '.') {
            self.cursor += 1;
            while (std.ascii.isDigit(self.peek())) {
                saw_digit = true;
                self.cursor += 1;
            }
        }
        if (!saw_digit) return error.InvalidExpression;
        const number_end = self.cursor;
        while (std.ascii.isAlphabetic(self.peek()) or self.peek() == '%') self.cursor += 1;
        const unit = if (self.cursor > number_end) self.input[number_end..self.cursor] else null;
        const value = std.fmt.parseFloat(f64, self.input[start..number_end]) catch
            return error.InvalidExpression;
        return native_numeric.Numeric.init(value, unit);
    }

    fn skipWhitespace(self: *NumericParser) void {
        while (self.cursor < self.input.len and std.ascii.isWhitespace(self.input[self.cursor])) {
            self.cursor += 1;
        }
    }

    fn peek(self: *const NumericParser) u8 {
        return if (self.cursor < self.input.len) self.input[self.cursor] else 0;
    }
};
