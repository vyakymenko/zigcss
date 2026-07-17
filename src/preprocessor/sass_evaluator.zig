//! Private bounded semantic evaluator for the native SCSS and indented-Sass
//! parser. This module is intentionally unreachable from every production API
//! until the native Sass conformance row graduates.

const std = @import("std");
const native_diagnostics = @import("diagnostics.zig");
const native_environment = @import("environment.zig");
const native_evaluator = @import("evaluator.zig");
const native_lexer = @import("lexer.zig");
const native_source = @import("source.zig");
const native_syntax = @import("syntax.zig");
const native_value = @import("value.zig");

const hard_selectors = 1_000_000;
const hard_selector_bytes = 20 * 1024 * 1024;
const hard_temporary_bytes = 20 * 1024 * 1024;
const hard_expression_tokens = 1_000_000;
const hard_evaluation_depth: u16 = 256;

pub const Limits = struct {
    values: native_value.Limits = .{},
    environment: native_environment.Limits = .{},
    max_selectors: usize = 200_000,
    max_selector_bytes: usize = 10 * 1024 * 1024,
    max_temporary_bytes: usize = 10 * 1024 * 1024,
    max_expression_tokens: usize = 200_000,
    max_evaluation_depth: u16 = 128,
};

pub const Error = native_evaluator.Error ||
    native_environment.Error ||
    native_lexer.Error ||
    native_source.Error ||
    native_value.Error || error{
    EvaluationDepthExceeded,
    IncompatibleUnits,
    InvalidExpression,
    InvalidLimits,
    InvalidSassSyntax,
    SelectorLimitExceeded,
    TemporaryLimitExceeded,
    UndefinedVariable,
    UnsupportedFeature,
};

pub fn evaluate(
    allocator: std.mem.Allocator,
    sources: *const native_source.Table,
    document: *const native_syntax.Document,
    transaction: *native_evaluator.Transaction,
    limits: Limits,
) Error!void {
    errdefer transaction.abort();
    var engine = try Engine.init(allocator, sources, document, transaction, limits);
    defer engine.deinit();
    try engine.run();
}

const SelectorList = struct {
    items: [][]u8,

    fn deinit(self: *SelectorList, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item);
        if (self.items.len > 0) allocator.free(self.items);
        self.* = undefined;
    }
};

const Numeric = struct {
    value: f64,
    unit: ?[]const u8 = null,
};

const VariableAssignment = struct {
    value: []const u8,
    default: bool = false,
    global: bool = false,
};

const ExpressionRange = struct {
    start: usize,
    end: usize,
};

const SplitSeparator = enum {
    comma,
    slash,
    whitespace,
};

const Builtin = enum {
    map_get,
    nth,
    length,
};

const LogicalOperator = enum {
    logical_or,
    logical_and,
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
};

const OperatorMatch = struct {
    operation: LogicalOperator,
    start: usize,
    end: usize,
};

const Engine = struct {
    allocator: std.mem.Allocator,
    sources: *const native_source.Table,
    document: *const native_syntax.Document,
    transaction: *native_evaluator.Transaction,
    limits: Limits,
    values: native_value.Store,
    environment: native_environment.Environment,
    global_scope: native_environment.ScopeId,
    expression_depth: u16 = 0,
    selector_count: usize = 0,
    selector_bytes: usize = 0,

    fn init(
        allocator: std.mem.Allocator,
        sources: *const native_source.Table,
        document: *const native_syntax.Document,
        transaction: *native_evaluator.Transaction,
        limits: Limits,
    ) Error!Engine {
        try validateLimits(limits);
        var environment = try native_environment.Environment.init(allocator, limits.environment);
        errdefer environment.deinit();
        return .{
            .allocator = allocator,
            .sources = sources,
            .document = document,
            .transaction = transaction,
            .limits = limits,
            .values = native_value.Store.init(allocator, limits.values),
            .environment = environment,
            .global_scope = environment.root(),
        };
    }

    fn deinit(self: *Engine) void {
        self.environment.deinit();
        self.values.deinit();
        self.* = undefined;
    }

    fn run(self: *Engine) Error!void {
        const root = self.document.get(self.document.root) catch return error.InvalidSassSyntax;
        if (root.kind != .stylesheet) {
            try self.report(.syntax, root.span, "native Sass document root is not a stylesheet");
            return error.InvalidSassSyntax;
        }
        const children = self.document.children(self.document.root) catch
            return error.InvalidSassSyntax;
        for (children) |child_id| {
            try self.transaction.consumeOperations(1);
            const child = self.document.get(child_id) catch return error.InvalidSassSyntax;
            switch (child.kind) {
                .declaration => {
                    if (!try self.isVariableDeclaration(child_id)) {
                        try self.report(.syntax, child.span, "top-level Sass declaration is not a variable");
                        return error.InvalidSassSyntax;
                    }
                    try self.assignVariable(child_id, &self.global_scope);
                },
                .rule => try self.evaluateRule(child_id, null, self.global_scope, 1),
                .comment => try self.emitRootComment(child),
                else => {
                    try self.report(
                        .unsupported_feature,
                        child.span,
                        "Sass directive is not implemented by the native evaluator yet",
                    );
                    return error.UnsupportedFeature;
                },
            }
        }
    }

    fn emitRootComment(self: *Engine, node: *const native_syntax.Node) Error!void {
        const text_span = node.text orelse return;
        const raw = try self.sources.slice(text_span);
        if (!std.mem.startsWith(u8, raw, "/*")) return;
        try self.transaction.emitMapped(node.span, null, raw);
        try self.transaction.emit("\n");
    }

    fn evaluateRule(
        self: *Engine,
        rule_id: native_syntax.NodeId,
        parents: ?*const SelectorList,
        inherited_scope: native_environment.ScopeId,
        depth: u16,
    ) Error!void {
        if (depth > self.limits.max_evaluation_depth) {
            const node = self.document.get(rule_id) catch return error.InvalidSassSyntax;
            try self.report(.resource_limit, node.span, "native Sass evaluation depth exceeded");
            return error.EvaluationDepthExceeded;
        }
        const rule = self.document.get(rule_id) catch return error.InvalidSassSyntax;
        const rule_children = self.document.children(rule_id) catch return error.InvalidSassSyntax;
        if (rule.kind != .rule or rule_children.len != 2) {
            try self.report(.syntax, rule.span, "malformed native Sass style rule");
            return error.InvalidSassSyntax;
        }
        const selector_node = self.document.get(rule_children[0]) catch return error.InvalidSassSyntax;
        const block_node = self.document.get(rule_children[1]) catch return error.InvalidSassSyntax;
        if (selector_node.kind != .selector or block_node.kind != .block or selector_node.text == null) {
            try self.report(.syntax, rule.span, "malformed native Sass rule children");
            return error.InvalidSassSyntax;
        }

        var selectors = try self.buildSelectors(selector_node.text.?, parents, inherited_scope);
        defer selectors.deinit(self.allocator);
        var scope = try self.environment.push(inherited_scope);
        var declarations: std.ArrayList(u8) = .empty;
        defer declarations.deinit(self.allocator);

        const block_children = self.document.children(rule_children[1]) catch
            return error.InvalidSassSyntax;
        for (block_children) |child_id| {
            try self.transaction.consumeOperations(1);
            const child = self.document.get(child_id) catch return error.InvalidSassSyntax;
            switch (child.kind) {
                .declaration => {
                    if (try self.isVariableDeclaration(child_id)) {
                        try self.assignVariable(child_id, &scope);
                    } else {
                        try self.appendDeclaration(child_id, "", &scope, &declarations, depth);
                    }
                },
                .rule => {
                    try self.emitRuleChunk(rule.span, &selectors, &declarations);
                    try self.evaluateRule(child_id, &selectors, scope, depth + 1);
                },
                .comment => try self.appendBlockComment(child, &declarations),
                else => {
                    try self.report(
                        .unsupported_feature,
                        child.span,
                        "Sass directive is not implemented by the native evaluator yet",
                    );
                    return error.UnsupportedFeature;
                },
            }
        }

        try self.emitRuleChunk(rule.span, &selectors, &declarations);
    }

    fn emitRuleChunk(
        self: *Engine,
        span: native_source.Span,
        selectors: *const SelectorList,
        declarations: *std.ArrayList(u8),
    ) Error!void {
        if (declarations.items.len == 0) return;
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        for (selectors.items, 0..) |selector, index| {
            if (index > 0) try self.appendTemporary(&output, ", ");
            try self.appendTemporary(&output, selector);
        }
        try self.appendTemporary(&output, " { ");
        try self.appendTemporary(&output, declarations.items);
        try self.appendTemporary(&output, " }\n");
        try self.transaction.emitMapped(span, null, output.items);
        declarations.clearRetainingCapacity();
    }

    fn appendBlockComment(
        self: *Engine,
        node: *const native_syntax.Node,
        output: *std.ArrayList(u8),
    ) Error!void {
        const text_span = node.text orelse return;
        const raw = try self.sources.slice(text_span);
        if (!std.mem.startsWith(u8, raw, "/*")) return;
        try self.appendTemporary(output, raw);
        try self.appendTemporary(output, " ");
    }

    fn isVariableDeclaration(self: *Engine, declaration_id: native_syntax.NodeId) Error!bool {
        const children = self.document.children(declaration_id) catch return error.InvalidSassSyntax;
        if (children.len == 0) return false;
        const first = self.document.get(children[0]) catch return error.InvalidSassSyntax;
        return first.kind == .variable;
    }

    fn assignVariable(
        self: *Engine,
        declaration_id: native_syntax.NodeId,
        scope: *native_environment.ScopeId,
    ) Error!void {
        const declaration = self.document.get(declaration_id) catch return error.InvalidSassSyntax;
        const children = self.document.children(declaration_id) catch return error.InvalidSassSyntax;
        if (children.len != 2) {
            try self.report(.syntax, declaration.span, "malformed Sass variable declaration");
            return error.InvalidSassSyntax;
        }
        const name_node = self.document.get(children[0]) catch return error.InvalidSassSyntax;
        const expression_node = self.document.get(children[1]) catch return error.InvalidSassSyntax;
        if (name_node.kind != .variable or name_node.text == null or
            expression_node.kind != .expression or expression_node.text == null)
        {
            try self.report(.syntax, declaration.span, "malformed Sass variable declaration");
            return error.InvalidSassSyntax;
        }
        const raw_name = try self.sources.slice(name_node.text.?);
        const normalized = try self.normalizeVariable(raw_name);
        defer self.allocator.free(normalized);
        const expression_bytes = try self.sources.slice(expression_node.text.?);
        const assignment = try self.parseVariableAssignment(expression_bytes, expression_node.span);
        const lookup_scope = if (assignment.global) self.global_scope else scope.*;
        const existing = try self.environment.lookup(lookup_scope, normalized);
        if (assignment.default) {
            if (existing) |item| {
                if (item.* != .null_value) return;
            }
        }
        const item = try self.evaluateExpressionBytes(assignment.value, scope.*, expression_node.span);
        if (assignment.global) {
            if (existing == null) {
                try self.transaction.report(
                    .warning,
                    .syntax,
                    expression_node.span,
                    "!global assignment declares a new variable; Sass 2.0 will reject it",
                    &.{},
                );
            }
            const is_global_cursor = scope == &self.global_scope;
            self.global_scope = try self.environment.set(self.global_scope, normalized, item);
            if (is_global_cursor) {
                scope.* = self.global_scope;
            } else {
                scope.* = try self.environment.set(scope.*, normalized, item);
            }
        } else {
            scope.* = try self.environment.set(scope.*, normalized, item);
        }
    }

    fn parseVariableAssignment(
        self: *Engine,
        raw: []const u8,
        span: native_source.Span,
    ) Error!VariableAssignment {
        var options = native_lexer.Options{};
        options.max_input_bytes = @max(raw.len, 1);
        options.max_tokens = self.limits.max_expression_tokens;
        const tokens = try native_lexer.tokenizeAlloc(self.allocator, raw, .scss, options);
        defer self.allocator.free(tokens);

        var result = VariableAssignment{ .value = trimWhitespace(raw) };
        var first_modifier: ?usize = null;
        var depth: usize = 0;
        var index: usize = 0;
        while (index < tokens.len) : (index += 1) {
            const token = tokens[index];
            switch (token.kind) {
                .open_paren, .open_square, .open_curly, .interpolation_start => {
                    depth += 1;
                    continue;
                },
                .close_paren, .close_square, .close_curly, .interpolation_end => {
                    if (depth > 0) depth -= 1;
                    continue;
                },
                else => {},
            }
            if (depth != 0 or isExpressionTrivia(token.kind) or token.kind == .eof) continue;

            if (token.kind == .operator and std.mem.eql(u8, token.raw(raw), "!")) {
                var word_index = index + 1;
                while (word_index < tokens.len and isExpressionTrivia(tokens[word_index].kind)) {
                    word_index += 1;
                }
                if (word_index < tokens.len and tokens[word_index].kind == .identifier) {
                    const word = tokens[word_index].raw(raw);
                    const is_default = std.ascii.eqlIgnoreCase(word, "default");
                    const is_global = std.ascii.eqlIgnoreCase(word, "global");
                    if (is_default or is_global) {
                        if ((is_default and result.default) or (is_global and result.global)) {
                            try self.report(.syntax, span, "duplicate Sass variable modifier");
                            return error.InvalidExpression;
                        }
                        if (first_modifier == null) first_modifier = token.span.start;
                        result.default = result.default or is_default;
                        result.global = result.global or is_global;
                        index = word_index;
                        continue;
                    }
                }
            }
            if (first_modifier != null) {
                try self.report(.syntax, span, "Sass variable modifiers must end the declaration");
                return error.InvalidExpression;
            }
        }
        if (first_modifier) |offset| result.value = trimWhitespace(raw[0..offset]);
        if (result.value.len == 0) {
            try self.report(.syntax, span, "Sass variable declaration is missing a value");
            return error.InvalidExpression;
        }
        return result;
    }

    fn appendDeclaration(
        self: *Engine,
        declaration_id: native_syntax.NodeId,
        prefix: []const u8,
        scope: *native_environment.ScopeId,
        output: *std.ArrayList(u8),
        depth: u16,
    ) Error!void {
        if (depth > self.limits.max_evaluation_depth) {
            const declaration = self.document.get(declaration_id) catch return error.InvalidSassSyntax;
            try self.report(.resource_limit, declaration.span, "nested Sass property depth exceeded");
            return error.EvaluationDepthExceeded;
        }
        const declaration = self.document.get(declaration_id) catch return error.InvalidSassSyntax;
        const children = self.document.children(declaration_id) catch return error.InvalidSassSyntax;
        if (children.len == 0) {
            try self.report(.syntax, declaration.span, "malformed Sass declaration");
            return error.InvalidSassSyntax;
        }
        const property_node = self.document.get(children[0]) catch return error.InvalidSassSyntax;
        if (property_node.kind != .identifier or property_node.text == null) {
            try self.report(.syntax, declaration.span, "malformed Sass property name");
            return error.InvalidSassSyntax;
        }
        const property = try self.renderTemplate(property_node.text.?, scope.*, false);
        defer self.allocator.free(property);
        const trimmed_property = trimWhitespace(property);
        if (trimmed_property.len == 0) {
            try self.report(.syntax, property_node.span, "empty Sass property name");
            return error.InvalidSassSyntax;
        }

        var expression: ?native_source.Span = null;
        var block: ?native_syntax.NodeId = null;
        for (children[1..]) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidSassSyntax;
            switch (child.kind) {
                .expression => expression = child.text orelse return error.InvalidSassSyntax,
                .block => block = child_id,
                else => {
                    try self.report(.syntax, child.span, "malformed Sass declaration child");
                    return error.InvalidSassSyntax;
                },
            }
        }

        if (expression) |expression_span| {
            if (std.mem.startsWith(u8, trimmed_property, "--")) {
                const rendered = try self.renderTemplate(expression_span, scope.*, false);
                defer self.allocator.free(rendered);
                try self.appendTemporary(output, prefix);
                try self.appendTemporary(output, trimmed_property);
                try self.appendTemporary(output, ": ");
                try self.appendTemporary(output, trimWhitespace(rendered));
                try self.appendTemporary(output, "; ");
            } else {
                const item = try self.evaluateExpression(expression_span, scope.*);
                if (item.* != .null_value) {
                    try self.ensureCssValue(item.*, expression_span);
                    try self.appendTemporary(output, prefix);
                    try self.appendTemporary(output, trimmed_property);
                    try self.appendTemporary(output, ": ");
                    try self.appendValue(output, item.*, false);
                    try self.appendTemporary(output, "; ");
                }
            }
        }

        if (block) |block_id| {
            var next_prefix: std.ArrayList(u8) = .empty;
            defer next_prefix.deinit(self.allocator);
            try self.appendTemporary(&next_prefix, prefix);
            try self.appendTemporary(&next_prefix, trimmed_property);
            try self.appendTemporary(&next_prefix, "-");
            const nested_children = self.document.children(block_id) catch
                return error.InvalidSassSyntax;
            for (nested_children) |nested_id| {
                const nested_node = self.document.get(nested_id) catch return error.InvalidSassSyntax;
                if (nested_node.kind != .declaration) {
                    try self.report(
                        .unsupported_feature,
                        nested_node.span,
                        "nested Sass properties may contain declarations only",
                    );
                    return error.UnsupportedFeature;
                }
                if (try self.isVariableDeclaration(nested_id)) {
                    try self.assignVariable(nested_id, scope);
                } else {
                    try self.appendDeclaration(
                        nested_id,
                        next_prefix.items,
                        scope,
                        output,
                        depth + 1,
                    );
                }
            }
        }
    }

    fn evaluateExpression(
        self: *Engine,
        span: native_source.Span,
        scope: native_environment.ScopeId,
    ) Error!*const native_value.Value {
        return self.evaluateExpressionBytes(try self.sources.slice(span), scope, span);
    }

    fn tryArithmetic(
        self: *Engine,
        raw: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!?Numeric {
        if (raw.len == 0) return null;
        if (try self.hasTopLevelListStructure(raw)) return null;
        var options = native_lexer.Options{};
        options.max_input_bytes = @max(raw.len, 1);
        options.max_tokens = self.limits.max_expression_tokens;
        const tokens = try native_lexer.tokenizeAlloc(self.allocator, raw, .scss, options);
        defer self.allocator.free(tokens);

        var first: usize = 0;
        while (first < tokens.len and isExpressionTrivia(tokens[first].kind)) first += 1;
        if (first >= tokens.len or !arithmeticStart(tokens[first], raw)) return null;
        var parser = ArithmeticParser{
            .engine = self,
            .raw = raw,
            .tokens = tokens,
            .cursor = first,
            .scope = scope,
            .span = span,
            .allows_slash_division = slashDivisionEnabled(raw),
        };
        const numeric = parser.parseExpression() catch |err| {
            if (!parser.saw_operator) return null;
            switch (err) {
                error.UndefinedVariable => return err,
                error.OutOfMemory => return err,
                else => {
                    try self.report(.invalid_operation, span, "invalid native Sass arithmetic expression");
                    return error.InvalidExpression;
                },
            }
        };
        parser.skipTrivia();
        if (parser.current().kind != .eof) {
            if (!parser.saw_operator) return null;
            try self.report(.invalid_operation, span, "invalid native Sass arithmetic expression");
            return error.InvalidExpression;
        }
        return numeric;
    }

    fn renderTemplate(
        self: *Engine,
        span: native_source.Span,
        scope: native_environment.ScopeId,
        replace_variables: bool,
    ) Error![]u8 {
        return self.renderBytes(try self.sources.slice(span), scope, span, replace_variables);
    }

    fn renderBytes(
        self: *Engine,
        raw: []const u8,
        scope: native_environment.ScopeId,
        diagnostic_span: native_source.Span,
        replace_variables: bool,
    ) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var index: usize = 0;
        while (index < raw.len) {
            if (raw[index] == '\\' and index + 1 < raw.len) {
                try self.appendTemporary(&output, raw[index .. index + 2]);
                index += 2;
                continue;
            }
            if (raw[index] == '\'' or raw[index] == '"') {
                const quote = raw[index];
                try self.appendTemporary(&output, raw[index .. index + 1]);
                index += 1;
                while (index < raw.len) {
                    if (raw[index] == '\\' and index + 1 < raw.len) {
                        try self.appendTemporary(&output, raw[index .. index + 2]);
                        index += 2;
                        continue;
                    }
                    if (raw[index] == quote) {
                        try self.appendTemporary(&output, raw[index .. index + 1]);
                        index += 1;
                        break;
                    }
                    if (index + 1 < raw.len and raw[index] == '#' and raw[index + 1] == '{') {
                        index = try self.appendInterpolation(
                            &output,
                            raw,
                            index,
                            scope,
                            diagnostic_span,
                        );
                        continue;
                    }
                    try self.appendTemporary(&output, raw[index .. index + 1]);
                    index += 1;
                }
                continue;
            }
            if (index + 1 < raw.len and raw[index] == '#' and raw[index + 1] == '{') {
                index = try self.appendInterpolation(
                    &output,
                    raw,
                    index,
                    scope,
                    diagnostic_span,
                );
                continue;
            }
            if (replace_variables and raw[index] == '$' and
                index + 1 < raw.len and isVariableNameStart(raw[index + 1]))
            {
                const end = variableEnd(raw, index + 1);
                const item = try self.lookupVariable(raw[index..end], scope, diagnostic_span);
                try self.ensureCssValue(item.*, diagnostic_span);
                try self.appendValue(&output, item.*, false);
                index = end;
                continue;
            }
            try self.appendTemporary(&output, raw[index .. index + 1]);
            index += 1;
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn appendInterpolation(
        self: *Engine,
        output: *std.ArrayList(u8),
        raw: []const u8,
        opening: usize,
        scope: native_environment.ScopeId,
        diagnostic_span: native_source.Span,
    ) Error!usize {
        const closing = findInterpolationEnd(raw, opening + 2) orelse {
            try self.report(.syntax, diagnostic_span, "unterminated Sass interpolation");
            return error.InvalidSassSyntax;
        };
        const inner = trimWhitespace(raw[opening + 2 .. closing]);
        if (inner.len == 0) {
            try self.report(.syntax, diagnostic_span, "empty Sass interpolation");
            return error.InvalidExpression;
        }
        const item = try self.evaluateExpressionBytes(inner, scope, diagnostic_span);
        try self.ensureCssValue(item.*, diagnostic_span);
        try self.appendValue(output, item.*, true);
        return closing + 1;
    }

    fn evaluateExpressionBytes(
        self: *Engine,
        raw: []const u8,
        scope: native_environment.ScopeId,
        diagnostic_span: native_source.Span,
    ) Error!*const native_value.Value {
        const trimmed = trimWhitespace(raw);
        if (self.expression_depth >= self.limits.max_evaluation_depth) {
            try self.report(.resource_limit, diagnostic_span, "native Sass expression depth exceeded");
            return error.EvaluationDepthExceeded;
        }
        self.expression_depth += 1;
        defer self.expression_depth -= 1;
        try self.transaction.consumeOperations(@intCast(trimmed.len + 1));
        if (trimmed.len > 0 and trimmed[0] == '$' and variableEnd(trimmed, 1) == trimmed.len) {
            return self.lookupVariable(trimmed, scope, diagnostic_span);
        }
        if (std.mem.eql(u8, trimmed, "true")) return self.values.own(.{ .boolean = true });
        if (std.mem.eql(u8, trimmed, "false")) return self.values.own(.{ .boolean = false });
        if (std.mem.eql(u8, trimmed, "null")) return self.values.own(.{ .null_value = {} });
        if (trimmed.len >= 2 and (trimmed[0] == '\'' or trimmed[0] == '"') and
            trimmed[trimmed.len - 1] == trimmed[0])
        {
            const rendered = try self.renderBytes(
                trimmed[1 .. trimmed.len - 1],
                scope,
                diagnostic_span,
                false,
            );
            defer self.allocator.free(rendered);
            return self.values.own(.{ .string = .{ .bytes = rendered, .quoted = true } });
        }
        if (try self.tryBuiltinCall(trimmed, scope, diagnostic_span)) |item| return item;
        if (try self.tryLogicalExpression(trimmed, scope, diagnostic_span)) |item| return item;
        if (try self.tryArithmetic(trimmed, scope, diagnostic_span)) |numeric| {
            var units: [1][]const u8 = undefined;
            const numerator_units: []const []const u8 = if (numeric.unit) |unit| blk: {
                units[0] = unit;
                break :blk units[0..1];
            } else &.{};
            return self.values.own(.{ .number = .{
                .value = numeric.value,
                .numerator_units = numerator_units,
            } });
        }
        if (try self.tryCollection(trimmed, scope, diagnostic_span)) |item| return item;
        const rendered = try self.renderBytes(trimmed, scope, diagnostic_span, true);
        defer self.allocator.free(rendered);
        return self.values.own(.{ .string = .{ .bytes = rendered, .quoted = false } });
    }

    fn hasTopLevelListStructure(self: *Engine, raw: []const u8) Error!bool {
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        if (try splitTopLevelRanges(self.allocator, raw, .comma, &ranges)) return true;
        ranges.clearRetainingCapacity();
        return try splitTopLevelRanges(self.allocator, raw, .whitespace, &ranges);
    }

    fn tryLogicalExpression(
        self: *Engine,
        raw: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        if (raw.len == 0 or try self.hasTopLevelListStructure(raw)) return null;
        var options = native_lexer.Options{};
        options.max_input_bytes = @max(raw.len, 1);
        options.max_tokens = self.limits.max_expression_tokens;
        const tokens = try native_lexer.tokenizeAlloc(self.allocator, raw, .scss, options);
        defer self.allocator.free(tokens);

        var depth: usize = 0;
        var first: ?native_lexer.Token = null;
        var logical_or: ?OperatorMatch = null;
        var logical_and: ?OperatorMatch = null;
        var equality: ?OperatorMatch = null;
        var relational: ?OperatorMatch = null;
        for (tokens) |token| {
            switch (token.kind) {
                .open_paren, .open_square, .open_curly, .interpolation_start => {
                    depth += 1;
                    continue;
                },
                .close_paren, .close_square, .close_curly, .interpolation_end => {
                    if (depth > 0) depth -= 1;
                    continue;
                },
                else => {},
            }
            if (depth != 0 or isExpressionTrivia(token.kind) or token.kind == .eof) continue;
            if (first == null) first = token;
            if (token.kind == .identifier) {
                const word = token.raw(raw);
                if (std.mem.eql(u8, word, "or")) {
                    logical_or = .{ .operation = .logical_or, .start = token.span.start, .end = token.span.end };
                } else if (std.mem.eql(u8, word, "and")) {
                    logical_and = .{ .operation = .logical_and, .start = token.span.start, .end = token.span.end };
                }
                continue;
            }
            if (token.kind != .operator) continue;
            const operation = token.raw(raw);
            const match: ?LogicalOperator = if (std.mem.eql(u8, operation, "=="))
                .equal
            else if (std.mem.eql(u8, operation, "!="))
                .not_equal
            else if (std.mem.eql(u8, operation, "<"))
                .less
            else if (std.mem.eql(u8, operation, "<="))
                .less_equal
            else if (std.mem.eql(u8, operation, ">"))
                .greater
            else if (std.mem.eql(u8, operation, ">="))
                .greater_equal
            else
                null;
            if (match) |matched| {
                const item = OperatorMatch{
                    .operation = matched,
                    .start = token.span.start,
                    .end = token.span.end,
                };
                switch (matched) {
                    .equal, .not_equal => equality = item,
                    .less, .less_equal, .greater, .greater_equal => relational = item,
                    else => unreachable,
                }
            }
        }

        if (logical_or) |match| return try self.evaluateLogicalMatch(raw, match, scope, span);
        if (logical_and) |match| return try self.evaluateLogicalMatch(raw, match, scope, span);
        if (equality) |match| return try self.evaluateLogicalMatch(raw, match, scope, span);
        if (relational) |match| return try self.evaluateLogicalMatch(raw, match, scope, span);
        if (first) |token| {
            if (token.kind == .identifier and std.mem.eql(u8, token.raw(raw), "not")) {
                const operand_raw = trimWhitespace(raw[token.span.end..]);
                if (operand_raw.len == 0) {
                    try self.report(.syntax, span, "not requires a native Sass expression");
                    return error.InvalidExpression;
                }
                const operand = try self.evaluateExpressionBytes(operand_raw, scope, span);
                return try self.values.own(.{ .boolean = !sassTruthy(operand.*) });
            }
        }
        return null;
    }

    fn evaluateLogicalMatch(
        self: *Engine,
        raw: []const u8,
        match: OperatorMatch,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const left_raw = trimWhitespace(raw[0..match.start]);
        const right_raw = trimWhitespace(raw[match.end..]);
        if (left_raw.len == 0 or right_raw.len == 0) {
            try self.report(.syntax, span, "native Sass binary operator is missing an operand");
            return error.InvalidExpression;
        }
        const left = try self.evaluateExpressionBytes(left_raw, scope, span);
        switch (match.operation) {
            .logical_or => {
                if (sassTruthy(left.*)) return left;
                return self.evaluateExpressionBytes(right_raw, scope, span);
            },
            .logical_and => {
                if (!sassTruthy(left.*)) return left;
                return self.evaluateExpressionBytes(right_raw, scope, span);
            },
            else => {},
        }

        const right = try self.evaluateExpressionBytes(right_raw, scope, span);
        const result = switch (match.operation) {
            .equal => sassValuesEqual(left.*, right.*),
            .not_equal => !sassValuesEqual(left.*, right.*),
            .less, .less_equal, .greater, .greater_equal => try self.compareValues(
                left.*,
                right.*,
                match.operation,
                span,
            ),
            else => unreachable,
        };
        return self.values.own(.{ .boolean = result });
    }

    fn compareValues(
        self: *Engine,
        left: native_value.Value,
        right: native_value.Value,
        operation: LogicalOperator,
        span: native_source.Span,
    ) Error!bool {
        const left_number = switch (left) {
            .number => |number| number,
            else => {
                try self.report(.type_mismatch, span, "native Sass ordering requires numbers");
                return error.InvalidExpression;
            },
        };
        const right_number = switch (right) {
            .number => |number| number,
            else => {
                try self.report(.type_mismatch, span, "native Sass ordering requires numbers");
                return error.InvalidExpression;
            },
        };
        if (!sassNumbersComparable(left_number, right_number)) {
            try self.report(.invalid_operation, span, "native Sass ordering uses incompatible units");
            return error.IncompatibleUnits;
        }
        return switch (operation) {
            .less => left_number.value < right_number.value,
            .less_equal => left_number.value <= right_number.value,
            .greater => left_number.value > right_number.value,
            .greater_equal => left_number.value >= right_number.value,
            else => unreachable,
        };
    }

    fn tryBuiltinCall(
        self: *Engine,
        raw: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const opening = std.mem.indexOfScalar(u8, raw, '(') orelse return null;
        if (opening == 0 or !fullyWrapped(raw[opening..], '(', ')')) return null;
        const name = raw[0..opening];
        if (!isSimpleIdentifier(name)) return null;
        const builtin: Builtin = if (sassNameEql(name, "map-get"))
            .map_get
        else if (sassNameEql(name, "nth"))
            .nth
        else if (sassNameEql(name, "length"))
            .length
        else
            return null;

        const body = raw[opening + 1 .. raw.len - 1];
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        _ = try splitTopLevelRanges(self.allocator, body, .comma, &ranges);
        if (trimWhitespace(body).len == 0) ranges.clearRetainingCapacity();
        for (ranges.items) |range| {
            if (trimWhitespace(body[range.start..range.end]).len == 0) {
                try self.report(.syntax, span, "empty native Sass function argument");
                return error.InvalidExpression;
            }
        }

        var arguments: std.ArrayList(*const native_value.Value) = .empty;
        defer arguments.deinit(self.allocator);
        for (ranges.items) |range| {
            try arguments.append(
                self.allocator,
                try self.evaluateExpressionBytes(body[range.start..range.end], scope, span),
            );
        }

        return switch (builtin) {
            .map_get => try self.callMapGet(arguments.items, span),
            .nth => try self.callNth(arguments.items, span),
            .length => try self.callLength(arguments.items, span),
        };
    }

    fn callMapGet(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len < 2) {
            try self.report(.invalid_operation, span, "map-get() requires a map and at least one key");
            return error.InvalidExpression;
        }
        var current = arguments[0];
        for (arguments[1..]) |key| {
            const map = switch (current.*) {
                .map => |item| item,
                else => {
                    try self.report(.type_mismatch, span, "map-get() requires a map value");
                    return error.InvalidExpression;
                },
            };
            var found: ?*const native_value.Value = null;
            for (map.entries, 0..) |entry, index| {
                if (sassValuesEqual(entry.key, key.*)) {
                    found = &map.entries[index].value;
                    break;
                }
            }
            current = found orelse return self.values.own(.{ .null_value = {} });
        }
        return current;
    }

    fn callNth(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 2) {
            try self.report(.invalid_operation, span, "nth() requires exactly two arguments");
            return error.InvalidExpression;
        }
        const length: usize = switch (arguments[0].*) {
            .list => |list| list.items.len,
            .map => |map| map.entries.len,
            else => 1,
        };
        const index = try self.resolveListIndex(arguments[1].*, length, span);
        return switch (arguments[0].*) {
            .list => |list| &list.items[index],
            .map => |map| blk: {
                const pair = [_]native_value.Value{
                    map.entries[index].key,
                    map.entries[index].value,
                };
                break :blk try self.values.own(.{ .list = .{
                    .items = &pair,
                    .separator = .space,
                } });
            },
            else => arguments[0],
        };
    }

    fn callLength(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 1) {
            try self.report(.invalid_operation, span, "length() requires exactly one argument");
            return error.InvalidExpression;
        }
        const length: usize = switch (arguments[0].*) {
            .list => |list| list.items.len,
            .map => |map| map.entries.len,
            else => 1,
        };
        return self.values.own(.{ .number = .{ .value = @floatFromInt(length) } });
    }

    fn resolveListIndex(
        self: *Engine,
        item: native_value.Value,
        length: usize,
        span: native_source.Span,
    ) Error!usize {
        const number = switch (item) {
            .number => |value| value,
            else => {
                try self.report(.type_mismatch, span, "Sass list index must be a unitless integer");
                return error.InvalidExpression;
            },
        };
        if (number.numerator_units.len != 0 or number.denominator_units.len != 0 or
            !std.math.isFinite(number.value) or @floor(number.value) != number.value or
            number.value == 0)
        {
            try self.report(.invalid_operation, span, "Sass list index must be a non-zero unitless integer");
            return error.InvalidExpression;
        }
        const maximum: f64 = @floatFromInt(length);
        if (number.value > maximum or number.value < -maximum) {
            try self.report(.invalid_operation, span, "Sass list index is outside the list");
            return error.InvalidExpression;
        }
        const magnitude: usize = @intFromFloat(@abs(number.value));
        return if (number.value > 0) magnitude - 1 else length - magnitude;
    }

    fn tryCollection(
        self: *Engine,
        raw: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        var body = raw;
        var parenthesized = false;
        var bracketed = false;
        if (fullyWrapped(raw, '(', ')')) {
            parenthesized = true;
            body = trimWhitespace(raw[1 .. raw.len - 1]);
        } else if (fullyWrapped(raw, '[', ']')) {
            bracketed = true;
            body = trimWhitespace(raw[1 .. raw.len - 1]);
        }

        if (parenthesized) {
            if (body.len == 0) {
                return try self.values.own(.{ .list = .{ .items = &.{} } });
            }
            if (try self.tryMap(body, scope, span)) |map| return map;
        } else if (bracketed and body.len == 0) {
            return try self.values.own(.{ .list = .{ .items = &.{}, .bracketed = true } });
        }

        const separators = [_]struct {
            split: SplitSeparator,
            value: native_value.Separator,
        }{
            .{ .split = .comma, .value = .comma },
            .{ .split = .slash, .value = .slash },
            .{ .split = .whitespace, .value = .space },
        };
        for (separators) |separator| {
            if (try self.trySeparatedList(body, scope, span, separator.split, separator.value, bracketed)) |list| {
                return list;
            }
        }

        if (bracketed) {
            const child = try self.evaluateExpressionBytes(body, scope, span);
            const items = [_]native_value.Value{child.*};
            return try self.values.own(.{ .list = .{
                .items = &items,
                .separator = .undecided,
                .bracketed = true,
            } });
        }
        if (parenthesized) return try self.evaluateExpressionBytes(body, scope, span);
        return null;
    }

    fn tryMap(
        self: *Engine,
        body: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        _ = try splitTopLevelRanges(self.allocator, body, .comma, &ranges);
        if (ranges.items.len == 0) return null;
        const final = ranges.items[ranges.items.len - 1];
        if (trimWhitespace(body[final.start..final.end]).len == 0) ranges.items.len -= 1;
        if (ranges.items.len == 0) return null;
        if (findTopLevelByte(body[ranges.items[0].start..ranges.items[0].end], ':') == null) {
            return null;
        }

        var entries: std.ArrayList(native_value.Entry) = .empty;
        defer entries.deinit(self.allocator);
        for (ranges.items) |range| {
            const entry_raw = body[range.start..range.end];
            const colon = findTopLevelByte(entry_raw, ':') orelse {
                try self.report(.syntax, span, "every native Sass map entry requires a key and value");
                return error.InvalidExpression;
            };
            const key_raw = trimWhitespace(entry_raw[0..colon]);
            const value_raw = trimWhitespace(entry_raw[colon + 1 ..]);
            if (key_raw.len == 0 or value_raw.len == 0) {
                try self.report(.syntax, span, "native Sass map entry has an empty key or value");
                return error.InvalidExpression;
            }
            const key = try self.evaluateExpressionBytes(key_raw, scope, span);
            const value = try self.evaluateExpressionBytes(value_raw, scope, span);
            for (entries.items) |existing| {
                if (sassValuesEqual(existing.key, key.*)) {
                    try self.report(.duplicate_binding, span, "duplicate native Sass map key");
                    return error.InvalidExpression;
                }
            }
            try entries.append(self.allocator, .{ .key = key.*, .value = value.* });
        }
        return try self.values.own(.{ .map = .{ .entries = entries.items } });
    }

    fn trySeparatedList(
        self: *Engine,
        body: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
        split: SplitSeparator,
        separator: native_value.Separator,
        bracketed: bool,
    ) Error!?*const native_value.Value {
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        if (!try splitTopLevelRanges(self.allocator, body, split, &ranges)) return null;
        if (split == .comma and ranges.items.len > 0) {
            const final = ranges.items[ranges.items.len - 1];
            if (trimWhitespace(body[final.start..final.end]).len == 0) ranges.items.len -= 1;
        }
        if (ranges.items.len == 0) {
            try self.report(.syntax, span, "native Sass list is missing an item");
            return error.InvalidExpression;
        }

        var items: std.ArrayList(native_value.Value) = .empty;
        defer items.deinit(self.allocator);
        for (ranges.items) |range| {
            const item_raw = trimWhitespace(body[range.start..range.end]);
            if (item_raw.len == 0) {
                try self.report(.syntax, span, "native Sass list contains an empty item");
                return error.InvalidExpression;
            }
            const item = try self.evaluateExpressionBytes(item_raw, scope, span);
            try items.append(self.allocator, item.*);
        }
        return try self.values.own(.{ .list = .{
            .items = items.items,
            .separator = separator,
            .bracketed = bracketed,
        } });
    }

    fn lookupVariable(
        self: *Engine,
        raw_name: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const normalized = try self.normalizeVariable(raw_name);
        defer self.allocator.free(normalized);
        if (try self.environment.lookup(scope, normalized)) |item| return item;
        try self.report(.undefined_variable, span, "undefined Sass variable");
        return error.UndefinedVariable;
    }

    fn normalizeVariable(self: *Engine, raw_name: []const u8) Error![]u8 {
        const name = if (raw_name.len > 0 and raw_name[0] == '$') raw_name[1..] else raw_name;
        if (name.len == 0) return error.InvalidSassSyntax;
        if (name.len > self.limits.max_temporary_bytes) return error.TemporaryLimitExceeded;
        const normalized = try self.allocator.dupe(u8, name);
        for (normalized) |*byte| {
            if (byte.* == '_') byte.* = '-';
        }
        return normalized;
    }

    fn buildSelectors(
        self: *Engine,
        span: native_source.Span,
        parents: ?*const SelectorList,
        scope: native_environment.ScopeId,
    ) Error!SelectorList {
        const rendered = try self.renderTemplate(span, scope, false);
        defer self.allocator.free(rendered);
        var children: std.ArrayList([]const u8) = .empty;
        defer children.deinit(self.allocator);
        try splitSelectors(self.allocator, rendered, &children);
        if (children.items.len == 0) {
            try self.report(.syntax, span, "empty Sass selector");
            return error.InvalidSassSyntax;
        }
        const parent_count = if (parents) |list| list.items.len else 1;
        var expansions_per_parent: usize = 0;
        for (children.items) |child| {
            const ampersands = replaceableAmpersandCount(child);
            const child_expansions = if (ampersands == 0)
                1
            else
                selectorPower(parent_count, ampersands - 1) catch {
                    try self.report(.resource_limit, span, "native Sass selector limit exceeded");
                    return error.SelectorLimitExceeded;
                };
            expansions_per_parent = std.math.add(
                usize,
                expansions_per_parent,
                child_expansions,
            ) catch {
                try self.report(.resource_limit, span, "native Sass selector limit exceeded");
                return error.SelectorLimitExceeded;
            };
        }
        const added_count = std.math.mul(usize, parent_count, expansions_per_parent) catch {
            try self.report(.resource_limit, span, "native Sass selector limit exceeded");
            return error.SelectorLimitExceeded;
        };
        const next_count = std.math.add(usize, self.selector_count, added_count) catch {
            try self.report(.resource_limit, span, "native Sass selector limit exceeded");
            return error.SelectorLimitExceeded;
        };
        if (next_count > self.limits.max_selectors) {
            try self.report(.resource_limit, span, "native Sass selector limit exceeded");
            return error.SelectorLimitExceeded;
        }

        var items: std.ArrayList([]u8) = .empty;
        errdefer {
            for (items.items) |item| self.allocator.free(item);
            items.deinit(self.allocator);
        }
        if (parents) |parent_list| {
            for (parent_list.items) |parent| {
                for (children.items) |child| {
                    const ampersands = replaceableAmpersandCount(child);
                    const expansion_count = if (ampersands == 0)
                        1
                    else
                        selectorPower(parent_list.items.len, ampersands - 1) catch unreachable;
                    for (0..expansion_count) |ordinal| {
                        const combined = try self.combineSelector(
                            parent_list,
                            parent,
                            child,
                            ampersands,
                            ordinal,
                            span,
                        );
                        errdefer self.allocator.free(combined);
                        try items.append(self.allocator, combined);
                    }
                }
            }
        } else {
            for (children.items) |child| {
                if (replaceableAmpersandCount(child) != 0) {
                    try self.report(.syntax, span, "top-level Sass selector contains '&'");
                    return error.InvalidSassSyntax;
                }
                const owned = try self.allocator.dupe(u8, child);
                try self.admitSelectorBytes(owned.len, span);
                errdefer self.allocator.free(owned);
                try items.append(self.allocator, owned);
            }
        }
        self.selector_count = next_count;
        return .{ .items = try items.toOwnedSlice(self.allocator) };
    }

    fn combineSelector(
        self: *Engine,
        parents: *const SelectorList,
        parent: []const u8,
        child: []const u8,
        ampersand_count: usize,
        ordinal: usize,
        span: native_source.Span,
    ) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        if (ampersand_count == 0) {
            try self.appendSelectorBytes(&output, parent, span);
            try self.appendSelectorBytes(&output, " ", span);
            try self.appendSelectorBytes(&output, child, span);
        } else {
            var start: usize = 0;
            var index: usize = 0;
            var occurrence: usize = 0;
            var quote: ?u8 = null;
            while (index < child.len) : (index += 1) {
                const byte = child[index];
                if (quote) |active| {
                    if (byte == '\\' and index + 1 < child.len) {
                        index += 1;
                    } else if (byte == active) {
                        quote = null;
                    }
                    continue;
                }
                if (byte == '\'' or byte == '"') {
                    quote = byte;
                    continue;
                }
                if (byte == '\\' and index + 1 < child.len) {
                    index += 1;
                    continue;
                }
                if (byte != '&') continue;
                try self.appendSelectorBytes(&output, child[start..index], span);
                const replacement = if (occurrence == 0)
                    parent
                else
                    parents.items[
                        selectorParentIndex(
                            parents.items.len,
                            ampersand_count - 1,
                            occurrence - 1,
                            ordinal,
                        )
                    ];
                try self.appendSelectorBytes(&output, replacement, span);
                start = index + 1;
                occurrence += 1;
            }
            try self.appendSelectorBytes(&output, child[start..], span);
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn admitSelectorBytes(self: *Engine, count: usize, span: native_source.Span) Error!void {
        const next = std.math.add(usize, self.selector_bytes, count) catch {
            try self.report(.resource_limit, span, "native Sass selector byte limit exceeded");
            return error.SelectorLimitExceeded;
        };
        if (next > self.limits.max_selector_bytes) {
            try self.report(.resource_limit, span, "native Sass selector byte limit exceeded");
            return error.SelectorLimitExceeded;
        }
        self.selector_bytes = next;
    }

    fn appendSelectorBytes(
        self: *Engine,
        output: *std.ArrayList(u8),
        bytes: []const u8,
        span: native_source.Span,
    ) Error!void {
        const next = std.math.add(usize, output.items.len, bytes.len) catch
            return error.SelectorLimitExceeded;
        if (next > self.limits.max_selector_bytes) {
            try self.report(.resource_limit, span, "native Sass selector byte limit exceeded");
            return error.SelectorLimitExceeded;
        }
        try output.appendSlice(self.allocator, bytes);
        try self.admitSelectorBytes(bytes.len, span);
    }

    fn appendValue(
        self: *Engine,
        output: *std.ArrayList(u8),
        item: native_value.Value,
        interpolation: bool,
    ) Error!void {
        switch (item) {
            .null_value => {},
            .boolean => |value| try self.appendTemporary(output, if (value) "true" else "false"),
            .number => |number| try self.appendNumber(output, number),
            .string, .selector => |string| {
                if (string.quoted and !interpolation) {
                    try self.appendTemporary(output, "\"");
                    var index: usize = 0;
                    while (index < string.bytes.len) {
                        if (string.bytes[index] == '\\' and index + 1 < string.bytes.len) {
                            try self.appendTemporary(output, string.bytes[index .. index + 2]);
                            index += 2;
                        } else if (string.bytes[index] == '"') {
                            try self.appendTemporary(output, "\\\"");
                            index += 1;
                        } else {
                            try self.appendTemporary(output, string.bytes[index .. index + 1]);
                            index += 1;
                        }
                    }
                    try self.appendTemporary(output, "\"");
                } else {
                    try self.appendTemporary(output, string.bytes);
                }
            },
            .list => |list| {
                if (list.bracketed) try self.appendTemporary(output, "[");
                var emitted: usize = 0;
                for (list.items) |child| {
                    if (child == .null_value) continue;
                    if (emitted > 0) try self.appendTemporary(output, switch (list.separator) {
                        .comma => ",",
                        .slash => "/",
                        .undecided, .space => " ",
                    });
                    try self.appendValue(output, child, interpolation);
                    emitted += 1;
                }
                if (list.bracketed) try self.appendTemporary(output, "]");
            },
            .map, .color, .callable => return error.InvalidExpression,
        }
    }

    fn ensureCssValue(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!void {
        if (cssValueIsValid(item, 0)) return;
        try self.report(.type_mismatch, span, "native Sass value cannot be emitted as CSS");
        return error.InvalidExpression;
    }

    fn appendNumber(
        self: *Engine,
        output: *std.ArrayList(u8),
        number: native_value.Number,
    ) Error!void {
        var buffer: [128]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buffer, "{d}", .{number.value}) catch
            return error.InvalidExpression;
        try self.appendTemporary(output, formatted);
        for (number.numerator_units, 0..) |unit, index| {
            if (index > 0) try self.appendTemporary(output, "*");
            try self.appendTemporary(output, unit);
        }
        for (number.denominator_units) |unit| {
            try self.appendTemporary(output, "/");
            try self.appendTemporary(output, unit);
        }
    }

    fn appendTemporary(
        self: *Engine,
        output: *std.ArrayList(u8),
        bytes: []const u8,
    ) Error!void {
        const next = std.math.add(usize, output.items.len, bytes.len) catch
            return error.TemporaryLimitExceeded;
        if (next > self.limits.max_temporary_bytes) return error.TemporaryLimitExceeded;
        try output.appendSlice(self.allocator, bytes);
    }

    fn report(
        self: *Engine,
        code: native_diagnostics.Code,
        span: native_source.Span,
        message: []const u8,
    ) Error!void {
        try self.transaction.report(.err, code, span, message, &.{});
    }
};

const ArithmeticParser = struct {
    engine: *Engine,
    raw: []const u8,
    tokens: []const native_lexer.Token,
    cursor: usize,
    scope: native_environment.ScopeId,
    span: native_source.Span,
    saw_operator: bool = false,
    allows_slash_division: bool,

    fn parseExpression(self: *ArithmeticParser) Error!Numeric {
        var left = try self.parseTerm();
        while (true) {
            self.skipTrivia();
            const token = self.current();
            if (token.kind != .operator) return left;
            const operation = token.raw(self.raw);
            if (!std.mem.eql(u8, operation, "+") and !std.mem.eql(u8, operation, "-")) return left;
            self.saw_operator = true;
            self.cursor += 1;
            const right = try self.parseTerm();
            left = try addNumeric(left, right, operation[0]);
        }
    }

    fn parseTerm(self: *ArithmeticParser) Error!Numeric {
        var left = try self.parseUnary();
        while (true) {
            self.skipTrivia();
            const token = self.current();
            if (token.kind != .operator) return left;
            const operation = token.raw(self.raw);
            if (!std.mem.eql(u8, operation, "*") and
                !std.mem.eql(u8, operation, "/") and
                !std.mem.eql(u8, operation, "%")) return left;
            if (std.mem.eql(u8, operation, "/") and !self.allows_slash_division) return left;
            if (std.mem.eql(u8, operation, "%") and token.span.start > 0 and
                self.cursor > 0 and self.tokens[self.cursor - 1].span.end == token.span.start)
            {
                return left;
            }
            self.saw_operator = true;
            self.cursor += 1;
            const right = try self.parseUnary();
            left = try multiplyNumeric(left, right, operation[0]);
        }
    }

    fn parseUnary(self: *ArithmeticParser) Error!Numeric {
        self.skipTrivia();
        const token = self.current();
        if (token.kind == .operator) {
            const operation = token.raw(self.raw);
            if (std.mem.eql(u8, operation, "+") or std.mem.eql(u8, operation, "-")) {
                self.saw_operator = true;
                self.cursor += 1;
                var result = try self.parseUnary();
                if (operation[0] == '-') result.value = -result.value;
                return result;
            }
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *ArithmeticParser) Error!Numeric {
        self.skipTrivia();
        const token = self.current();
        switch (token.kind) {
            .number => {
                self.cursor += 1;
                const number = std.fmt.parseFloat(f64, token.raw(self.raw)) catch
                    return error.InvalidExpression;
                if (!std.math.isFinite(number)) return error.InvalidExpression;
                var unit: ?[]const u8 = null;
                if (self.cursor < self.tokens.len) {
                    const next = self.tokens[self.cursor];
                    if (next.span.start == token.span.end and next.kind == .identifier) {
                        unit = next.raw(self.raw);
                        self.cursor += 1;
                    } else if (next.span.start == token.span.end and next.kind == .operator and
                        std.mem.eql(u8, next.raw(self.raw), "%"))
                    {
                        unit = "%";
                        self.cursor += 1;
                    }
                }
                return .{ .value = number, .unit = unit };
            },
            .variable => {
                self.cursor += 1;
                const item = try self.engine.lookupVariable(token.raw(self.raw), self.scope, self.span);
                return switch (item.*) {
                    .number => |number| blk: {
                        if (number.denominator_units.len != 0 or number.numerator_units.len > 1) {
                            return error.InvalidExpression;
                        }
                        break :blk .{
                            .value = number.value,
                            .unit = if (number.numerator_units.len == 1)
                                number.numerator_units[0]
                            else
                                null,
                        };
                    },
                    else => error.InvalidExpression,
                };
            },
            .open_paren => {
                self.cursor += 1;
                const result = try self.parseExpression();
                self.skipTrivia();
                if (self.current().kind != .close_paren) return error.InvalidExpression;
                self.cursor += 1;
                return result;
            },
            else => return error.InvalidExpression,
        }
    }

    fn skipTrivia(self: *ArithmeticParser) void {
        while (self.cursor < self.tokens.len and isExpressionTrivia(self.tokens[self.cursor].kind)) {
            self.cursor += 1;
        }
    }

    fn current(self: *const ArithmeticParser) native_lexer.Token {
        return self.tokens[@min(self.cursor, self.tokens.len - 1)];
    }
};

fn addNumeric(left: Numeric, right: Numeric, operation: u8) Error!Numeric {
    const unit = try compatibleUnit(left, right);
    return .{
        .value = if (operation == '+') left.value + right.value else left.value - right.value,
        .unit = unit,
    };
}

fn multiplyNumeric(left: Numeric, right: Numeric, operation: u8) Error!Numeric {
    return switch (operation) {
        '*' => blk: {
            if (left.unit != null and right.unit != null) return error.IncompatibleUnits;
            break :blk .{
                .value = left.value * right.value,
                .unit = left.unit orelse right.unit,
            };
        },
        '/' => blk: {
            if (right.value == 0 or right.unit != null) return error.IncompatibleUnits;
            break :blk .{ .value = left.value / right.value, .unit = left.unit };
        },
        '%' => blk: {
            if (right.value == 0) return error.InvalidExpression;
            const unit = try compatibleUnit(left, right);
            break :blk .{ .value = @mod(left.value, right.value), .unit = unit };
        },
        else => error.InvalidExpression,
    };
}

fn compatibleUnit(left: Numeric, right: Numeric) Error!?[]const u8 {
    if (left.unit == null) return right.unit;
    if (right.unit == null) return left.unit;
    if (!std.mem.eql(u8, left.unit.?, right.unit.?)) return error.IncompatibleUnits;
    return left.unit;
}

fn validateLimits(limits: Limits) Error!void {
    const value_limits = limits.values;
    const environment_limits = limits.environment;
    if (value_limits.max_values == 0 or value_limits.max_values > 1_000_000 or
        value_limits.max_depth == 0 or value_limits.max_depth > 64 or
        value_limits.max_collection_items > 1_000_000 or
        value_limits.max_owned_bytes == 0 or value_limits.max_owned_bytes > 64 * 1024 * 1024 or
        environment_limits.max_scopes == 0 or environment_limits.max_scopes > 65_536 or
        environment_limits.max_scope_depth == 0 or environment_limits.max_scope_depth > 1_024 or
        environment_limits.max_bindings > 1_000_000 or
        environment_limits.max_name_bytes == 0 or
        environment_limits.max_name_bytes > 16 * 1024 * 1024 or
        limits.max_selectors == 0 or limits.max_selectors > hard_selectors or
        limits.max_selector_bytes == 0 or limits.max_selector_bytes > hard_selector_bytes or
        limits.max_temporary_bytes == 0 or limits.max_temporary_bytes > hard_temporary_bytes or
        limits.max_expression_tokens == 0 or
        limits.max_expression_tokens > hard_expression_tokens or
        limits.max_evaluation_depth == 0 or limits.max_evaluation_depth > hard_evaluation_depth)
    {
        return error.InvalidLimits;
    }
}

fn fullyWrapped(input: []const u8, opening: u8, closing: u8) bool {
    if (input.len < 2 or input[0] != opening) return false;
    var depth: usize = 0;
    var quote: ?u8 = null;
    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\' and index + 1 < input.len) {
                index += 2;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            index += 1;
            continue;
        }
        if (byte == '\\' and index + 1 < input.len) {
            index += 2;
            continue;
        }
        if (commentEnd(input, index)) |end| {
            index = end;
            continue;
        }
        if (byte == opening) {
            depth += 1;
        } else if (byte == closing) {
            if (depth == 0) return false;
            depth -= 1;
            if (depth == 0) return index == input.len - 1;
        }
        index += 1;
    }
    return false;
}

fn splitTopLevelRanges(
    allocator: std.mem.Allocator,
    input: []const u8,
    separator: SplitSeparator,
    output: *std.ArrayList(ExpressionRange),
) std.mem.Allocator.Error!bool {
    var start: usize = 0;
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var curly_depth: usize = 0;
    var quote: ?u8 = null;
    var saw_separator = false;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\' and index + 1 < input.len) {
                index += 2;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            index += 1;
            continue;
        }
        if (byte == '\\' and index + 1 < input.len) {
            index += 2;
            continue;
        }
        if (commentEnd(input, index)) |end| {
            index = end;
            continue;
        }
        switch (byte) {
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => if (square_depth > 0) {
                square_depth -= 1;
            },
            '{' => curly_depth += 1,
            '}' => if (curly_depth > 0) {
                curly_depth -= 1;
            },
            else => {},
        }
        const top_level = paren_depth == 0 and square_depth == 0 and curly_depth == 0;
        const is_separator = top_level and switch (separator) {
            .comma => byte == ',',
            .slash => byte == '/',
            .whitespace => isExpressionWhitespace(byte),
        };
        if (!is_separator) {
            index += 1;
            continue;
        }

        if (separator == .whitespace) {
            var end = index + 1;
            while (end < input.len and isExpressionWhitespace(input[end])) end += 1;
            if (whitespaceIsOperatorPadding(input, index, end)) {
                index = end;
                continue;
            }
            if (trimWhitespace(input[start..index]).len == 0) {
                start = end;
                index = end;
                continue;
            }
            if (trimWhitespace(input[end..]).len == 0) {
                index = end;
                continue;
            }
            try output.append(allocator, .{ .start = start, .end = index });
            saw_separator = true;
            start = end;
            index = end;
            continue;
        }

        try output.append(allocator, .{ .start = start, .end = index });
        saw_separator = true;
        start = index + 1;
        index += 1;
    }
    if (input.len > 0 or saw_separator) {
        try output.append(allocator, .{ .start = start, .end = input.len });
    }
    return saw_separator;
}

fn findTopLevelByte(input: []const u8, target: u8) ?usize {
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var curly_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\' and index + 1 < input.len) {
                index += 2;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            index += 1;
            continue;
        }
        if (byte == '\\' and index + 1 < input.len) {
            index += 2;
            continue;
        }
        if (commentEnd(input, index)) |end| {
            index = end;
            continue;
        }
        if (paren_depth == 0 and square_depth == 0 and curly_depth == 0 and byte == target) {
            return index;
        }
        switch (byte) {
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => if (square_depth > 0) {
                square_depth -= 1;
            },
            '{' => curly_depth += 1,
            '}' => if (curly_depth > 0) {
                curly_depth -= 1;
            },
            else => {},
        }
        index += 1;
    }
    return null;
}

fn commentEnd(input: []const u8, start: usize) ?usize {
    if (start + 1 >= input.len or input[start] != '/') return null;
    if (input[start + 1] == '*') {
        const closing = std.mem.indexOf(u8, input[start + 2 ..], "*/") orelse return input.len;
        return start + 2 + closing + 2;
    }
    if (input[start + 1] == '/') {
        const newline = std.mem.indexOfScalar(u8, input[start + 2 ..], '\n') orelse return input.len;
        return start + 2 + newline;
    }
    return null;
}

fn isSimpleIdentifier(input: []const u8) bool {
    if (input.len == 0 or !isVariableNameStart(input[0])) return false;
    for (input[1..]) |byte| {
        if (!isVariableNameContinue(byte)) return false;
    }
    return true;
}

fn sassNameEql(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        const normalized = if (left_byte == '_') '-' else left_byte;
        if (normalized != right_byte) return false;
    }
    return true;
}

fn whitespaceIsOperatorPadding(input: []const u8, start: usize, end: usize) bool {
    if (end < input.len) {
        const next = input[end];
        if (isSymbolicExpressionOperator(next) or startsSassWord(input, end, "and") or
            startsSassWord(input, end, "or"))
        {
            return true;
        }
    }
    if (start > 0) {
        const previous = input[start - 1];
        if (isSymbolicExpressionOperator(previous) or endsSassWord(input, start, "and") or
            endsSassWord(input, start, "or") or endsSassWord(input, start, "not"))
        {
            return true;
        }
    }
    return false;
}

fn isSymbolicExpressionOperator(byte: u8) bool {
    return switch (byte) {
        '+', '-', '*', '/', '%', '=', '!', '<', '>', '&', '|', '^', '~', '?' => true,
        else => false,
    };
}

fn startsSassWord(input: []const u8, start: usize, word: []const u8) bool {
    if (start + word.len > input.len or !std.mem.eql(u8, input[start .. start + word.len], word)) {
        return false;
    }
    const end = start + word.len;
    return end == input.len or !isVariableNameContinue(input[end]);
}

fn endsSassWord(input: []const u8, end: usize, word: []const u8) bool {
    if (end < word.len or !std.mem.eql(u8, input[end - word.len .. end], word)) return false;
    return end == word.len or !isVariableNameContinue(input[end - word.len - 1]);
}

fn sassTruthy(item: native_value.Value) bool {
    return switch (item) {
        .null_value => false,
        .boolean => |value| value,
        else => true,
    };
}

fn sassValuesEqual(left: native_value.Value, right: native_value.Value) bool {
    return sassValuesEqualDepth(left, right, 0);
}

fn sassValuesEqualDepth(left: native_value.Value, right: native_value.Value, depth: u16) bool {
    if (depth > 64 or std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .null_value => true,
        .boolean => |value| value == right.boolean,
        .number => |number| number.value == right.number.value and
            unitSlicesEqual(number.numerator_units, right.number.numerator_units) and
            unitSlicesEqual(number.denominator_units, right.number.denominator_units),
        .color => |color| std.meta.eql(color, right.color),
        .string => |string| std.mem.eql(u8, string.bytes, right.string.bytes),
        .selector => |selector| std.mem.eql(u8, selector.bytes, right.selector.bytes),
        .callable => |callable| std.meta.eql(callable, right.callable),
        .list => |list| blk: {
            const other = right.list;
            if (list.separator != other.separator or list.bracketed != other.bracketed or
                list.items.len != other.items.len)
            {
                break :blk false;
            }
            for (list.items, other.items) |item, other_item| {
                if (!sassValuesEqualDepth(item, other_item, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .map => |map| blk: {
            const other = right.map;
            if (map.entries.len != other.entries.len) break :blk false;
            for (map.entries) |entry| {
                var matched = false;
                for (other.entries) |other_entry| {
                    if (sassValuesEqualDepth(entry.key, other_entry.key, depth + 1) and
                        sassValuesEqualDepth(entry.value, other_entry.value, depth + 1))
                    {
                        matched = true;
                        break;
                    }
                }
                if (!matched) break :blk false;
            }
            break :blk true;
        },
    };
}

fn sassNumbersComparable(left: native_value.Number, right: native_value.Number) bool {
    if (left.denominator_units.len != 0 or right.denominator_units.len != 0 or
        left.numerator_units.len > 1 or right.numerator_units.len > 1)
    {
        return false;
    }
    if (left.numerator_units.len == 0 or right.numerator_units.len == 0) return true;
    return std.mem.eql(u8, left.numerator_units[0], right.numerator_units[0]);
}

fn unitSlicesEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |unit, other| {
        if (!std.mem.eql(u8, unit, other)) return false;
    }
    return true;
}

fn cssValueIsValid(item: native_value.Value, depth: u16) bool {
    if (depth > 64) return false;
    return switch (item) {
        .null_value, .boolean, .number, .string, .selector => true,
        .list => |list| blk: {
            var emitted: usize = 0;
            for (list.items) |child| {
                if (child == .null_value) continue;
                if (!cssValueIsValid(child, depth + 1)) break :blk false;
                emitted += 1;
            }
            break :blk list.bracketed or emitted > 0;
        },
        .map, .color, .callable => false,
    };
}

fn isExpressionWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '\x0c';
}

fn splitSelectors(
    allocator: std.mem.Allocator,
    input: []const u8,
    output: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    var start: usize = 0;
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\' and index + 1 < input.len) {
                index += 1;
            } else if (byte == active) {
                quote = null;
            }
            continue;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => if (square_depth > 0) {
                square_depth -= 1;
            },
            ',' => if (paren_depth == 0 and square_depth == 0) {
                const item = trimWhitespace(input[start..index]);
                if (item.len > 0) try output.append(allocator, item);
                start = index + 1;
            },
            else => {},
        }
    }
    const final = trimWhitespace(input[start..]);
    if (final.len > 0) try output.append(allocator, final);
}

fn findInterpolationEnd(input: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var index = start;
    var quote: ?u8 = null;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\' and index + 1 < input.len) {
                index += 1;
            } else if (byte == active) {
                quote = null;
            }
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '{') {
            depth += 1;
        } else if (byte == '}') {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

fn arithmeticStart(token: native_lexer.Token, raw: []const u8) bool {
    return switch (token.kind) {
        .number, .variable, .open_paren => true,
        .operator => blk: {
            const operation = token.raw(raw);
            break :blk std.mem.eql(u8, operation, "+") or std.mem.eql(u8, operation, "-");
        },
        else => false,
    };
}

fn isExpressionTrivia(kind: native_lexer.Kind) bool {
    return switch (kind) {
        .whitespace, .newline, .comment => true,
        else => false,
    };
}

fn trimWhitespace(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n\x0c");
}

fn variableEnd(input: []const u8, start: usize) usize {
    var index = start;
    while (index < input.len and isVariableNameContinue(input[index])) index += 1;
    return index;
}

fn isVariableNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '-' or byte >= 0x80;
}

fn isVariableNameContinue(byte: u8) bool {
    return isVariableNameStart(byte) or std.ascii.isDigit(byte);
}

fn replaceableAmpersandCount(input: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\' and index + 1 < input.len) {
                index += 1;
            } else if (byte == active) {
                quote = null;
            }
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '\\' and index + 1 < input.len) {
            index += 1;
        } else if (byte == '&') {
            count += 1;
        }
    }
    return count;
}

fn selectorPower(base: usize, exponent: usize) error{SelectorLimitExceeded}!usize {
    var result: usize = 1;
    for (0..exponent) |_| {
        result = std.math.mul(usize, result, base) catch return error.SelectorLimitExceeded;
        if (result > hard_selectors) return error.SelectorLimitExceeded;
    }
    return result;
}

fn selectorParentIndex(
    parent_count: usize,
    varying_ampersands: usize,
    occurrence: usize,
    ordinal: usize,
) usize {
    var divisor: usize = 1;
    const following = varying_ampersands - occurrence - 1;
    for (0..following) |_| divisor *= parent_count;
    return (ordinal / divisor) % parent_count;
}

fn slashDivisionEnabled(input: []const u8) bool {
    const trimmed = trimWhitespace(input);
    return std.mem.indexOfScalar(u8, trimmed, '$') != null or
        (trimmed.len >= 2 and trimmed[0] == '(' and trimmed[trimmed.len - 1] == ')');
}
