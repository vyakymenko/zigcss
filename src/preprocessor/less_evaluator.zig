//! Private bounded semantic evaluator for native Less syntax.
//!
//! The internal surface admits already-valid plain CSS plus the closed lazy
//! variable, lexical-scope, selector, declaration, ruleset, operation, and
//! built-in and confined import foundation derived from the pinned Less 4.6.7
//! selection. JavaScript and plugin execution are permanently rejected before
//! any CSS is staged.

const std = @import("std");
const native_diagnostics = @import("diagnostics.zig");
const native_environment = @import("environment.zig");
const native_evaluator = @import("evaluator.zig");
const native_lexer = @import("lexer.zig");
const native_less = @import("less.zig");
const native_color = @import("sass_color.zig");
const native_numeric = @import("sass_numeric.zig");
const native_resolver = @import("resolver.zig");
const native_source = @import("source.zig");
const native_syntax = @import("syntax.zig");
const native_value = @import("value.zig");

const hard_source_bytes = 10 * 1024 * 1024;
const hard_nodes = 1_000_000;
const hard_variable_depth: u16 = 256;
const hard_calls: u32 = 65_536;
const hard_expression_depth: u16 = 64;
const hard_selectors = 1_000_000;
const hard_temporary_bytes = 20 * 1024 * 1024;

pub const Limits = struct {
    max_source_bytes: usize = hard_source_bytes,
    max_nodes: usize = 200_000,
    environment: native_environment.Limits = .{},
    values: native_value.Limits = .{},
    max_variable_depth: u16 = 128,
    max_calls: u32 = 16_384,
    max_expression_depth: u16 = 32,
    max_selectors: usize = 200_000,
    max_temporary_bytes: usize = 10 * 1024 * 1024,
};

pub const Math = enum {
    parens_division,
};

pub const RewriteUrls = enum {
    all,
};

/// The closed Less 4.6.7 render options used by the pinned success corpus.
/// Strict-unit negative fixtures opt in explicitly without changing the
/// selection's ordinary permissive arithmetic contract.
pub const Options = struct {
    math: Math = .parens_division,
    quiet_deprecations: bool = false,
    rewrite_urls: RewriteUrls = .all,
    strict_units: bool = false,
};

pub const Error = native_evaluator.Error ||
    native_environment.Error ||
    native_lexer.Error ||
    native_less.Error ||
    native_resolver.Error ||
    native_source.Error ||
    native_syntax.Error ||
    native_value.Error || error{
    InvalidDocument,
    CallLimitExceeded,
    ExpressionDepthExceeded,
    IncompatibleUnits,
    InvalidImport,
    InvalidLimits,
    InvalidOperation,
    JavaScriptDisabled,
    NodeLimitExceeded,
    PluginDisabled,
    RecursiveVariable,
    SelectorLimitExceeded,
    SourceLimitExceeded,
    TemporaryLimitExceeded,
    UndefinedVariable,
    UndefinedMixin,
    UnsupportedFeature,
    VariableDepthExceeded,
};

pub fn evaluate(
    sources: *native_source.Table,
    document: *const native_syntax.Document,
    transaction: *native_evaluator.Transaction,
    limits: Limits,
) Error!void {
    return evaluateWithOptions(sources, document, transaction, .{}, limits);
}

pub fn evaluateWithOptions(
    sources: *native_source.Table,
    document: *const native_syntax.Document,
    transaction: *native_evaluator.Transaction,
    options: Options,
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
    var expanded_document: ?native_syntax.Document = null;
    defer if (expanded_document) |*expanded| expanded.deinit();
    if (containsImports(document)) {
        var expander = ImportExpander.init(
            transaction.allocator,
            sources,
            transaction,
            limits,
        );
        defer expander.deinit();
        expanded_document = try expander.expand(document);
    }
    const active_document = if (expanded_document) |*expanded| expanded else document;
    if (active_document.nodes().len > limits.max_nodes) {
        try transaction.report(
            .err,
            .resource_limit,
            root.span,
            "native Less evaluator node limit exceeded",
            &.{},
        );
        return error.NodeLimitExceeded;
    }

    try transaction.consumeOperations(@intCast(active_document.nodes().len));
    try rejectJavaScript(sources, root.span, input, transaction);
    for (active_document.nodes()) |node| try preflightNode(sources, node, transaction);

    if (expanded_document == null and !requiresSemanticEvaluation(active_document)) {
        try transaction.emitMapped(root.span, null, input);
        return;
    }

    var engine = try Engine.init(
        transaction.allocator,
        sources,
        active_document,
        transaction,
        options,
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
        limits.max_calls == 0 or limits.max_calls > hard_calls or
        limits.max_expression_depth == 0 or
        limits.max_expression_depth > hard_expression_depth or
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
        .mixin,
        .guard,
        .detached_ruleset,
        .extend,
        => {},
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
        switch (node.kind) {
            .expression,
            .variable,
            .interpolation,
            .mixin,
            .guard,
            .detached_ruleset,
            .extend,
            => return true,
            else => {},
        }
    }
    return false;
}

fn containsImports(document: *const native_syntax.Document) bool {
    for (document.nodes()) |node| {
        if (node.kind == .import) return true;
    }
    return false;
}

const ImportOptions = struct {
    once: bool = false,
    multiple: bool = false,
    optional: bool = false,
    css: bool = false,
    less: bool = false,
};

const ParsedImport = struct {
    target: []const u8,
    trailing: []const u8,
    options: ImportOptions,
};

const ImportExpander = struct {
    allocator: std.mem.Allocator,
    sources: *native_source.Table,
    transaction: *native_evaluator.Transaction,
    limits: Limits,
    builder: native_syntax.Builder,
    source_ids: std.StringHashMapUnmanaged(native_source.SourceId) = .empty,
    once_urls: std.StringHashMapUnmanaged(void) = .empty,
    ancestry: std.ArrayList([]const u8) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        sources: *native_source.Table,
        transaction: *native_evaluator.Transaction,
        limits: Limits,
    ) ImportExpander {
        return .{
            .allocator = allocator,
            .sources = sources,
            .transaction = transaction,
            .limits = limits,
            .builder = native_syntax.Builder.init(allocator, sources, .{
                .max_nodes = limits.max_nodes,
            }),
        };
    }

    fn deinit(self: *ImportExpander) void {
        self.ancestry.deinit(self.allocator);
        self.once_urls.deinit(self.allocator);
        self.source_ids.deinit(self.allocator);
        self.builder.deinit();
        self.* = undefined;
    }

    fn expand(
        self: *ImportExpander,
        document: *const native_syntax.Document,
    ) Error!native_syntax.Document {
        const root = document.get(document.root) catch return error.InvalidDocument;
        if (root.kind != .stylesheet) return error.InvalidDocument;
        const file = try self.sources.get(root.span.source);
        const root_path = native_resolver.fileUrlToPath(self.allocator, file.name) catch |failure| {
            return self.failLoad(failure, root.span);
        };
        self.allocator.free(root_path);
        try self.ancestry.append(self.allocator, file.name);
        try self.source_ids.put(self.allocator, file.name, root.span.source);

        var children: std.ArrayList(native_syntax.NodeId) = .empty;
        defer children.deinit(self.allocator);
        try self.appendStatements(document, try document.children(document.root), &children);
        const expanded_root = try self.builder.add(
            .stylesheet,
            root.span,
            root.text,
            children.items,
        );
        return self.builder.finish(expanded_root);
    }

    fn appendStatements(
        self: *ImportExpander,
        document: *const native_syntax.Document,
        children: []const native_syntax.NodeId,
        output: *std.ArrayList(native_syntax.NodeId),
    ) Error!void {
        for (children) |child_id| {
            const child = document.get(child_id) catch return error.InvalidDocument;
            if (child.kind == .import) {
                try self.expandImport(document, child_id, output);
            } else {
                try output.append(self.allocator, try self.cloneNode(document, child_id, null));
            }
        }
    }

    fn cloneNode(
        self: *ImportExpander,
        document: *const native_syntax.Document,
        node_id: native_syntax.NodeId,
        kind_override: ?native_syntax.Kind,
    ) Error!native_syntax.NodeId {
        const node = document.get(node_id) catch return error.InvalidDocument;
        var children: std.ArrayList(native_syntax.NodeId) = .empty;
        defer children.deinit(self.allocator);
        const source_children = document.children(node_id) catch return error.InvalidDocument;
        if (node.kind == .block) {
            try self.appendStatements(document, source_children, &children);
        } else {
            for (source_children) |child_id| {
                try children.append(self.allocator, try self.cloneNode(document, child_id, null));
            }
        }
        return self.builder.add(
            kind_override orelse node.kind,
            node.span,
            node.text,
            children.items,
        );
    }

    fn expandImport(
        self: *ImportExpander,
        document: *const native_syntax.Document,
        import_id: native_syntax.NodeId,
        output: *std.ArrayList(native_syntax.NodeId),
    ) Error!void {
        const import_node = document.get(import_id) catch return error.InvalidDocument;
        const import_children = document.children(import_id) catch return error.InvalidDocument;
        if (import_children.len != 1) return error.InvalidDocument;
        const expression = document.get(import_children[0]) catch return error.InvalidDocument;
        if (expression.kind != .expression or expression.text == null) {
            return error.InvalidDocument;
        }
        const raw = try self.sources.slice(expression.text.?);
        const parsed = parseImportPrelude(raw) catch {
            try self.reportImport(import_node.span, "native Less import syntax is unsupported");
            return error.InvalidImport;
        };
        if (parsed.options.once and parsed.options.multiple) {
            try self.reportImport(import_node.span, "native Less import once and multiple options conflict");
            return error.InvalidImport;
        }
        if (parsed.options.css and parsed.options.less) {
            try self.reportImport(import_node.span, "native Less import css and less options conflict");
            return error.InvalidImport;
        }

        const css_import = parsed.options.css or
            (!parsed.options.less and (hasCssExtension(parsed.target) or hasNonLocalScheme(parsed.target)));
        if (css_import) {
            try output.append(
                self.allocator,
                try self.cloneNode(document, import_id, .at_rule),
            );
            return;
        }
        if (parsed.trailing.len != 0) {
            try self.reportImport(
                import_node.span,
                "native Less evaluated import conditions are unsupported",
            );
            return error.InvalidImport;
        }

        const parent_url = self.ancestry.items[self.ancestry.items.len - 1];
        const candidate_url = candidateUrl(
            self.allocator,
            parent_url,
            parsed.target,
        ) catch |failure| return self.failLoad(failure, import_node.span);
        defer self.allocator.free(candidate_url);
        const session = try self.transaction.resolverSession();
        var loaded = session.load(candidate_url, .{
            .kind = .import,
            .ancestry = self.ancestry.items,
        }) catch |failure| switch (failure) {
            error.Missing => {
                if (parsed.options.optional) return;
                try self.reportImport(import_node.span, "native Less import was not found");
                return error.InvalidImport;
            },
            else => return self.failLoad(failure, import_node.span),
        };
        defer loaded.deinit();

        const source_id = self.source_ids.get(loaded.url) orelse source: {
            const added = self.sources.add(loaded.url, loaded.contents) catch |failure| {
                if (failure == error.OutOfMemory) return error.OutOfMemory;
                try self.transaction.report(
                    .err,
                    .resource_limit,
                    import_node.span,
                    "native Less imported source limit exceeded",
                    &.{},
                );
                return failure;
            };
            const source_file = try self.sources.get(added);
            try self.source_ids.put(self.allocator, source_file.name, added);
            break :source added;
        };
        const source_file = try self.sources.get(source_id);
        const seen = self.once_urls.contains(source_file.name);
        if (!parsed.options.multiple and seen) return;
        if (!seen) try self.once_urls.put(self.allocator, source_file.name, {});

        const full_span = try self.sources.span(source_id, 0, @intCast(source_file.bytes.len));
        try rejectJavaScript(self.sources, full_span, source_file.bytes, self.transaction);
        var parser = native_less.Parser.init(
            self.allocator,
            self.sources,
            source_id,
            .{},
            .{},
        ) catch |failure| {
            if (failure == error.OutOfMemory) return error.OutOfMemory;
            try self.transaction.report(
                .err,
                .resource_limit,
                import_node.span,
                "native Less imported parser limit exceeded",
                &.{},
            );
            return failure;
        };
        defer parser.deinit();
        var imported = parser.parse() catch |failure| {
            try self.copyParserDiagnostics(parser.diagnostics());
            return failure;
        };
        defer imported.deinit();
        const imported_root = imported.get(imported.root) catch return error.InvalidDocument;
        if (imported_root.kind != .stylesheet) return error.InvalidDocument;

        try self.ancestry.append(self.allocator, source_file.name);
        defer _ = self.ancestry.pop();
        try self.appendStatements(&imported, try imported.children(imported.root), output);
    }

    fn reportImport(
        self: *ImportExpander,
        span: native_source.Span,
        message: []const u8,
    ) Error!void {
        try self.transaction.report(.err, .invalid_import, span, message, &.{});
    }

    fn failLoad(
        self: *ImportExpander,
        failure: native_resolver.Error,
        span: native_source.Span,
    ) Error {
        switch (failure) {
            error.OutOfMemory, error.Cancelled => return failure,
            error.AttemptLimitExceeded,
            error.DepthLimitExceeded,
            error.FileCountExceeded,
            error.FileLimitExceeded,
            error.TotalLimitExceeded,
            => {
                self.transaction.report(
                    .err,
                    .resource_limit,
                    span,
                    "native Less import resource limit exceeded",
                    &.{},
                ) catch |err| return err;
                return failure;
            },
            error.Cycle => {
                self.reportImport(span, "native Less import cycle detected") catch |err| return err;
                return error.InvalidImport;
            },
            else => {
                self.reportImport(span, "native Less import load was rejected") catch |err| return err;
                return error.InvalidImport;
            },
        }
    }

    fn copyParserDiagnostics(
        self: *ImportExpander,
        diagnostics: []const native_diagnostics.Diagnostic,
    ) Error!void {
        for (diagnostics) |diagnostic| {
            var related: std.ArrayList(native_diagnostics.RelatedInput) = .empty;
            defer related.deinit(self.allocator);
            try related.ensureTotalCapacity(self.allocator, diagnostic.related.len);
            for (diagnostic.related) |item| {
                related.appendAssumeCapacity(.{ .span = item.span, .label = item.label });
            }
            try self.transaction.report(
                diagnostic.severity,
                diagnostic.code,
                diagnostic.span,
                diagnostic.message,
                related.items,
            );
        }
    }
};

fn parseImportPrelude(raw_input: []const u8) error{InvalidImport}!ParsedImport {
    var raw = std.mem.trim(u8, raw_input, " \t\r\n\x0c");
    var options = ImportOptions{};
    if (raw.len > 0 and raw[0] == '(') {
        const closing = std.mem.indexOfScalar(u8, raw, ')') orelse return error.InvalidImport;
        var iterator = std.mem.splitScalar(u8, raw[1..closing], ',');
        while (iterator.next()) |option_input| {
            const option = std.mem.trim(u8, option_input, " \t\r\n\x0c");
            if (std.ascii.eqlIgnoreCase(option, "once")) {
                options.once = true;
            } else if (std.ascii.eqlIgnoreCase(option, "multiple")) {
                options.multiple = true;
            } else if (std.ascii.eqlIgnoreCase(option, "optional")) {
                options.optional = true;
            } else if (std.ascii.eqlIgnoreCase(option, "css")) {
                options.css = true;
            } else if (std.ascii.eqlIgnoreCase(option, "less")) {
                options.less = true;
            } else {
                return error.InvalidImport;
            }
        }
        raw = std.mem.trim(u8, raw[closing + 1 ..], " \t\r\n\x0c");
    }
    if (raw.len == 0) return error.InvalidImport;

    var target: []const u8 = undefined;
    var consumed: usize = 0;
    if (raw[0] == '\'' or raw[0] == '"') {
        const quote = raw[0];
        var escaped = false;
        var index: usize = 1;
        while (index < raw.len) : (index += 1) {
            if (escaped) {
                escaped = false;
            } else if (raw[index] == '\\') {
                escaped = true;
            } else if (raw[index] == quote) {
                target = raw[1..index];
                consumed = index + 1;
                break;
            }
        }
        if (consumed == 0) return error.InvalidImport;
    } else if (startsWithIgnoreCase(raw, "url(")) {
        const closing = std.mem.indexOfScalarPos(u8, raw, 4, ')') orelse
            return error.InvalidImport;
        target = stripQuotes(std.mem.trim(u8, raw[4..closing], " \t\r\n\x0c"));
        consumed = closing + 1;
    } else {
        consumed = std.mem.indexOfAny(u8, raw, " \t\r\n\x0c") orelse raw.len;
        target = raw[0..consumed];
    }
    if (target.len == 0 or std.mem.indexOfAny(u8, target, "\x00\r\n") != null) {
        return error.InvalidImport;
    }
    return .{
        .target = target,
        .trailing = std.mem.trim(u8, raw[consumed..], " \t\r\n\x0c"),
        .options = options,
    };
}

fn startsWithIgnoreCase(input: []const u8, prefix: []const u8) bool {
    return input.len >= prefix.len and std.ascii.eqlIgnoreCase(input[0..prefix.len], prefix);
}

fn hasCssExtension(target: []const u8) bool {
    const end = std.mem.indexOfAny(u8, target, "?#") orelse target.len;
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(target[0..end]), ".css");
}

fn hasNonLocalScheme(target: []const u8) bool {
    return std.mem.indexOf(u8, target, "://") != null or
        std.mem.startsWith(u8, target, "//");
}

fn candidateUrl(
    allocator: std.mem.Allocator,
    parent_url: []const u8,
    target: []const u8,
) native_resolver.Error![]u8 {
    if (hasNonLocalScheme(target) or std.mem.indexOfAny(u8, target, "?#") != null) {
        return error.SchemeNotAllowed;
    }
    const parent_path = try native_resolver.fileUrlToPath(allocator, parent_url);
    defer allocator.free(parent_path);
    const parent_directory = std.fs.path.dirname(parent_path) orelse return error.InvalidUrl;
    const target_with_extension = if (std.fs.path.extension(target).len == 0)
        try std.fmt.allocPrint(allocator, "{s}.less", .{target})
    else
        try allocator.dupe(u8, target);
    defer allocator.free(target_with_extension);
    const absolute = if (std.fs.path.isAbsolute(target_with_extension))
        try std.fs.path.resolve(allocator, &.{target_with_extension})
    else
        try std.fs.path.resolve(allocator, &.{ parent_directory, target_with_extension });
    defer allocator.free(absolute);
    return native_resolver.pathToFileUrl(allocator, absolute);
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
    id: usize,
};

const ScopeRecord = struct {
    parent: ?usize,
};

const MixinDefinition = struct {
    name: []const u8,
    signature: native_source.Span,
    guard: ?native_source.Span,
    block: native_syntax.NodeId,
    scope: Scope,
};

const DetachedDefinition = struct {
    name: []const u8,
    block: native_syntax.NodeId,
    scope: Scope,
};

const Extension = struct {
    target: []const u8,
    extender: []const u8,
};

const ByteRange = struct {
    start: usize,
    end: usize,
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
    options: Options,
    limits: Limits,
    root_source: native_source.SourceId,
    values: native_value.Store,
    environment: native_environment.Environment,
    bindings: std.ArrayList(Binding) = .empty,
    binding_indices: std.AutoHashMapUnmanaged(*const native_value.Value, usize) = .empty,
    scopes: std.ArrayList(ScopeRecord) = .empty,
    mixins: std.ArrayList(MixinDefinition) = .empty,
    detached: std.ArrayList(DetachedDefinition) = .empty,
    extensions: std.ArrayList(Extension) = .empty,
    selector_count: usize = 0,
    call_count: u32 = 0,
    variable_depth: u16 = 0,

    fn init(
        allocator: std.mem.Allocator,
        sources: *const native_source.Table,
        document: *const native_syntax.Document,
        transaction: *native_evaluator.Transaction,
        options: Options,
        limits: Limits,
    ) Error!Engine {
        var values = native_value.Store.init(allocator, limits.values);
        errdefer values.deinit();
        const environment = try native_environment.Environment.init(
            allocator,
            limits.environment,
        );
        const root = document.get(document.root) catch return error.InvalidDocument;
        return .{
            .allocator = allocator,
            .sources = sources,
            .document = document,
            .transaction = transaction,
            .options = options,
            .limits = limits,
            .root_source = root.span.source,
            .values = values,
            .environment = environment,
        };
    }

    fn deinit(self: *Engine) void {
        self.extensions.deinit(self.allocator);
        self.detached.deinit(self.allocator);
        self.mixins.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
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
        try self.collectRootExtensions(children, scope);
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
        const scope_id = self.scopes.items.len;
        try self.scopes.append(self.allocator, .{
            .parent = if (parent) |scope| scope.id else null,
        });
        var result = Scope{ .cursor = boundary, .id = scope_id };
        try self.populateScope(children, &result);
        return result;
    }

    fn populateScope(
        self: *Engine,
        children: []const native_syntax.NodeId,
        result: *Scope,
    ) Error!void {
        const binding_start = self.bindings.items.len;
        for (children) |child_id| {
            if (try self.isVariableDeclaration(child_id)) {
                try self.addBinding(child_id, result);
            }
        }
        for (self.bindings.items[binding_start..]) |*binding| {
            binding.definition_scope = result.cursor;
        }
        try self.rejectDirectCycles(binding_start);
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            switch (child.kind) {
                .mixin => if (try self.isMixinDefinition(child_id)) {
                    try self.registerMixin(child_id, result.*);
                },
                .detached_ruleset => try self.registerDetached(child_id, result.*),
                else => {},
            }
        }
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

    fn isMixinDefinition(
        self: *const Engine,
        mixin_id: native_syntax.NodeId,
    ) Error!bool {
        const mixin = self.document.get(mixin_id) catch return error.InvalidDocument;
        if (mixin.kind != .mixin) return false;
        const children = self.document.children(mixin_id) catch return error.InvalidDocument;
        return children.len >= 2;
    }

    fn registerMixin(
        self: *Engine,
        mixin_id: native_syntax.NodeId,
        scope: Scope,
    ) Error!void {
        const children = self.document.children(mixin_id) catch return error.InvalidDocument;
        if (children.len < 2 or children.len > 3) return error.InvalidDocument;
        const signature = self.document.get(children[0]) catch return error.InvalidDocument;
        const block = self.document.get(children[children.len - 1]) catch
            return error.InvalidDocument;
        if (signature.kind != .selector or signature.text == null or block.kind != .block) {
            return error.InvalidDocument;
        }
        var guard: ?native_source.Span = null;
        if (children.len == 3) {
            const guard_node = self.document.get(children[1]) catch return error.InvalidDocument;
            if (guard_node.kind != .guard or guard_node.text == null) {
                return error.InvalidDocument;
            }
            guard = guard_node.text.?;
        }
        const raw = try self.sources.slice(signature.text.?);
        const name = callableName(raw) orelse return error.InvalidDocument;
        try self.mixins.append(self.allocator, .{
            .name = name,
            .signature = signature.text.?,
            .guard = guard,
            .block = children[children.len - 1],
            .scope = scope,
        });
    }

    fn registerDetached(
        self: *Engine,
        detached_id: native_syntax.NodeId,
        scope: Scope,
    ) Error!void {
        const children = self.document.children(detached_id) catch return error.InvalidDocument;
        if (children.len != 2) return error.InvalidDocument;
        const name_node = self.document.get(children[0]) catch return error.InvalidDocument;
        const block = self.document.get(children[1]) catch return error.InvalidDocument;
        if (name_node.kind != .variable or name_node.text == null or block.kind != .block) {
            return error.InvalidDocument;
        }
        const name = try normalizeVariableName(try self.sources.slice(name_node.text.?));
        try self.detached.append(self.allocator, .{
            .name = name,
            .block = children[1],
            .scope = scope,
        });
    }

    fn collectRootExtensions(
        self: *Engine,
        children: []const native_syntax.NodeId,
        scope: Scope,
    ) Error!void {
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            if (child.kind != .rule) continue;
            const rule_children = self.document.children(child_id) catch return error.InvalidDocument;
            if (rule_children.len != 2) return error.InvalidDocument;
            const selector_node = self.document.get(rule_children[0]) catch
                return error.InvalidDocument;
            if (selector_node.kind != .selector or selector_node.text == null) {
                return error.InvalidDocument;
            }
            const extender_owned = try self.renderOwned(
                selector_node.text.?,
                scope.cursor,
                .selector,
            );
            defer self.allocator.free(extender_owned);
            const extender = std.mem.trim(u8, extender_owned, " \t\r\n\x0c");
            const block_children = self.document.children(rule_children[1]) catch
                return error.InvalidDocument;
            for (block_children) |statement_id| {
                const statement = self.document.get(statement_id) catch
                    return error.InvalidDocument;
                if (statement.kind != .extend) continue;
                const extend_children = self.document.children(statement_id) catch
                    return error.InvalidDocument;
                if (extend_children.len != 1) return error.InvalidDocument;
                const expression = self.document.get(extend_children[0]) catch
                    return error.InvalidDocument;
                const raw = try self.sources.slice(expression.text orelse
                    return error.InvalidDocument);
                const target = extendTarget(raw) orelse {
                    try self.transaction.report(
                        .err,
                        .invalid_operation,
                        expression.span,
                        "native Less extend requires one simple selector target",
                        &.{},
                    );
                    return error.InvalidOperation;
                };
                const owned_target = try self.values.own(.{ .string = .{ .bytes = target } });
                const owned_extender = try self.values.own(.{ .string = .{ .bytes = extender } });
                try self.extensions.append(self.allocator, .{
                    .target = owned_target.string.bytes,
                    .extender = owned_extender.string.bytes,
                });
            }
        }
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
                .mixin => if (!try self.isMixinDefinition(child_id)) {
                    if (parent_selector == null) return error.InvalidDocument;
                },
                .detached_ruleset, .extend => {},
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
        const emitted_selector = try self.selectorWithExtenders(selector);
        defer self.allocator.free(emitted_selector);

        var declarations: std.ArrayList(u8) = .empty;
        defer declarations.deinit(self.allocator);
        for (block_children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            switch (child.kind) {
                .declaration => if (!try self.isVariableDeclaration(child_id)) {
                    try self.appendDeclaration(&declarations, child_id, scope);
                },
                .mixin => if (!try self.isMixinDefinition(child_id)) {
                    try self.appendCallable(&declarations, child_id, scope, selector);
                },
                else => {},
            }
        }
        if (declarations.items.len > 0) {
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(self.allocator);
            try self.appendTemporary(&output, emitted_selector);
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

    fn selectorWithExtenders(self: *Engine, selector: []const u8) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        try self.appendTemporary(&output, selector);
        for (self.extensions.items) |extension| {
            if (!std.mem.eql(u8, extension.target, selector)) continue;
            try self.appendTemporary(&output, ",");
            try self.appendTemporary(&output, extension.extender);
        }
        return try output.toOwnedSlice(self.allocator);
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

    fn appendCallable(
        self: *Engine,
        output: *std.ArrayList(u8),
        call_id: native_syntax.NodeId,
        caller_scope: Scope,
        parent_selector: []const u8,
    ) Error!void {
        const call = self.document.get(call_id) catch return error.InvalidDocument;
        const children = self.document.children(call_id) catch return error.InvalidDocument;
        if (call.kind != .mixin or children.len != 1) return error.InvalidDocument;
        const expression = self.document.get(children[0]) catch return error.InvalidDocument;
        if (expression.kind != .expression or expression.text == null) {
            return error.InvalidDocument;
        }
        const raw = try self.sources.slice(expression.text.?);
        const name = callableName(raw) orelse return error.InvalidDocument;
        if (name[0] == '@') {
            try self.appendDetached(output, name, expression.text.?, caller_scope, parent_selector);
        } else {
            try self.appendMixin(output, name, expression.text.?, caller_scope, parent_selector);
        }
    }

    fn appendMixin(
        self: *Engine,
        output: *std.ArrayList(u8),
        name: []const u8,
        call_span: native_source.Span,
        caller_scope: Scope,
        parent_selector: []const u8,
    ) Error!void {
        const definition = self.lookupMixin(caller_scope, name) orelse {
            const message = try std.fmt.allocPrint(
                self.allocator,
                "native Less mixin {s} is undefined",
                .{name},
            );
            defer self.allocator.free(message);
            try self.transaction.report(.err, .undefined_variable, call_span, message, &.{});
            return error.UndefinedMixin;
        };
        try self.enterCallable(call_span);
        var call_open = true;
        defer if (call_open) self.transaction.leaveCall() catch {};

        var invocation = try self.createChildScope(definition.scope);
        try self.bindMixinParameters(definition, call_span, caller_scope, &invocation);
        const block_children = self.document.children(definition.block) catch
            return error.InvalidDocument;
        try self.populateScope(block_children, &invocation);
        if (definition.guard) |guard| {
            if (!try self.guardMatches(guard, invocation)) {
                try self.transaction.report(
                    .err,
                    .invalid_operation,
                    call_span,
                    "native Less mixin guard did not match",
                    &.{},
                );
                return error.UndefinedMixin;
            }
        }
        try self.appendCallableBody(output, block_children, invocation, parent_selector);
        try self.transaction.leaveCall();
        call_open = false;
    }

    fn appendDetached(
        self: *Engine,
        output: *std.ArrayList(u8),
        name: []const u8,
        call_span: native_source.Span,
        caller_scope: Scope,
        parent_selector: []const u8,
    ) Error!void {
        const definition = self.lookupDetached(caller_scope, name) orelse {
            const message = try std.fmt.allocPrint(
                self.allocator,
                "native Less detached ruleset {s} is undefined",
                .{name},
            );
            defer self.allocator.free(message);
            try self.transaction.report(.err, .undefined_variable, call_span, message, &.{});
            return error.UndefinedMixin;
        };
        try self.enterCallable(call_span);
        var call_open = true;
        defer if (call_open) self.transaction.leaveCall() catch {};
        var invocation = try self.createChildScope(definition.scope);
        const block_children = self.document.children(definition.block) catch
            return error.InvalidDocument;
        try self.populateScope(block_children, &invocation);
        try self.appendCallableBody(output, block_children, invocation, parent_selector);
        try self.transaction.leaveCall();
        call_open = false;
    }

    fn enterCallable(self: *Engine, span: native_source.Span) Error!void {
        if (self.call_count >= self.limits.max_calls) {
            try self.transaction.report(
                .err,
                .call_limit,
                span,
                "native Less callable limit exceeded",
                &.{},
            );
            return error.CallLimitExceeded;
        }
        self.call_count += 1;
        try self.transaction.enterCall();
    }

    fn createChildScope(self: *Engine, parent: Scope) Error!Scope {
        const cursor = try self.environment.push(parent.cursor);
        const id = self.scopes.items.len;
        try self.scopes.append(self.allocator, .{ .parent = parent.id });
        return .{ .cursor = cursor, .id = id };
    }

    fn bindMixinParameters(
        self: *Engine,
        definition: MixinDefinition,
        call_span: native_source.Span,
        caller_scope: Scope,
        invocation: *Scope,
    ) Error!void {
        const signature_raw = try self.sources.slice(definition.signature);
        const call_raw = try self.sources.slice(call_span);
        const signature_arguments = callableArguments(signature_raw) orelse
            return error.InvalidDocument;
        const call_arguments = callableArguments(call_raw) orelse return error.InvalidDocument;
        const delimiter: u8 = if (containsTopLevel(
            signature_raw[signature_arguments.start..signature_arguments.end],
            ';',
        )) ';' else ',';
        var parameters = try splitTopLevelAlloc(
            self.allocator,
            signature_raw,
            signature_arguments,
            delimiter,
        );
        defer parameters.deinit(self.allocator);
        var arguments = try splitTopLevelAlloc(
            self.allocator,
            call_raw,
            call_arguments,
            delimiter,
        );
        defer arguments.deinit(self.allocator);
        if (arguments.items.len > parameters.items.len) {
            try self.reportInvalidOperation(call_span, "native Less mixin received too many arguments");
            return error.InvalidOperation;
        }

        for (parameters.items, 0..) |parameter_range, index| {
            const parameter = trimByteRange(signature_raw, parameter_range);
            const colon = findTopLevelByte(signature_raw, parameter, ':');
            const name_range = trimByteRange(
                signature_raw,
                .{ .start = parameter.start, .end = colon orelse parameter.end },
            );
            const name = try normalizeVariableName(signature_raw[name_range.start..name_range.end]);
            const rendered = if (index < arguments.items.len) blk: {
                const argument = trimByteRange(call_raw, arguments.items[index]);
                if (argument.start == argument.end) {
                    try self.reportInvalidOperation(call_span, "native Less mixin argument is empty");
                    return error.InvalidOperation;
                }
                const argument_span = try self.relativeSpan(
                    call_span,
                    @intCast(argument.start),
                    @intCast(argument.end),
                );
                break :blk try self.renderOwned(argument_span, caller_scope.cursor, .value);
            } else blk: {
                const colon_index = colon orelse {
                    try self.reportInvalidOperation(call_span, "native Less mixin argument is required");
                    return error.InvalidOperation;
                };
                const default_range = trimByteRange(signature_raw, .{
                    .start = colon_index + 1,
                    .end = parameter.end,
                });
                const default_span = try self.relativeSpan(
                    definition.signature,
                    @intCast(default_range.start),
                    @intCast(default_range.end),
                );
                break :blk try self.renderOwned(default_span, invocation.cursor, .value);
            };
            defer self.allocator.free(rendered);
            try self.addResolvedBinding(name, rendered, invocation);
        }
    }

    fn addResolvedBinding(
        self: *Engine,
        name: []const u8,
        rendered: []const u8,
        scope: *Scope,
    ) Error!void {
        const holder = try self.values.own(.{ .string = .{ .bytes = rendered } });
        const binding_index = self.bindings.items.len;
        try self.bindings.append(self.allocator, .{
            .holder = holder,
            .name = name,
            .expression = (self.document.get(self.document.root) catch
                return error.InvalidDocument).span,
            .definition_scope = scope.cursor,
            .state = .resolved,
            .resolved = holder,
        });
        try self.binding_indices.put(self.allocator, holder, binding_index);
        scope.cursor = try self.environment.set(scope.cursor, name, holder);
        try self.transaction.consumeOperations(1);
    }

    fn appendCallableBody(
        self: *Engine,
        output: *std.ArrayList(u8),
        children: []const native_syntax.NodeId,
        scope: Scope,
        parent_selector: []const u8,
    ) Error!void {
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            switch (child.kind) {
                .declaration => if (!try self.isVariableDeclaration(child_id)) {
                    try self.appendDeclaration(output, child_id, scope);
                },
                .mixin => if (!try self.isMixinDefinition(child_id)) {
                    try self.appendCallable(output, child_id, scope, parent_selector);
                },
                .comment, .detached_ruleset, .extend => {},
                else => {
                    try self.transaction.report(
                        .err,
                        .unsupported_feature,
                        child.span,
                        "native Less callable nested rules are not implemented in this evaluator slice",
                        &.{},
                    );
                    return error.UnsupportedFeature;
                },
            }
        }
    }

    fn lookupMixin(
        self: *const Engine,
        scope: Scope,
        name: []const u8,
    ) ?MixinDefinition {
        var scope_id: ?usize = scope.id;
        while (scope_id) |current| {
            var index = self.mixins.items.len;
            while (index > 0) {
                index -= 1;
                const definition = self.mixins.items[index];
                if (definition.scope.id == current and std.mem.eql(u8, definition.name, name)) {
                    return definition;
                }
            }
            scope_id = self.scopes.items[current].parent;
        }
        return null;
    }

    fn lookupDetached(
        self: *const Engine,
        scope: Scope,
        name: []const u8,
    ) ?DetachedDefinition {
        var scope_id: ?usize = scope.id;
        while (scope_id) |current| {
            var index = self.detached.items.len;
            while (index > 0) {
                index -= 1;
                const definition = self.detached.items[index];
                if (definition.scope.id == current and std.mem.eql(u8, definition.name, name)) {
                    return definition;
                }
            }
            scope_id = self.scopes.items[current].parent;
        }
        return null;
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

        if (prelude.len > 0) try self.appendTemporary(&header, " ");
        try self.appendTemporary(&header, "{");
        try self.transaction.emitMapped(at_rule.span, null, header.items);
        const block_children = self.document.children(block_id.?) catch
            return error.InvalidDocument;
        const block_scope = try self.prepareScope(block_children, scope);
        try self.emitAtRuleStatements(block_children, block_scope, parent_selector);
        try self.transaction.emit("}");
    }

    fn emitAtRuleStatements(
        self: *Engine,
        children: []const native_syntax.NodeId,
        scope: Scope,
        parent_selector: ?[]const u8,
    ) Error!void {
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            switch (child.kind) {
                .declaration => if (!try self.isVariableDeclaration(child_id)) {
                    var rendered: std.ArrayList(u8) = .empty;
                    defer rendered.deinit(self.allocator);
                    try self.appendDeclaration(&rendered, child_id, scope);
                    try self.transaction.emitMapped(child.span, null, rendered.items);
                },
                .rule => try self.emitRule(child_id, scope, parent_selector),
                .at_rule => try self.emitAtRule(child_id, scope, parent_selector),
                .mixin => if (!try self.isMixinDefinition(child_id)) {
                    if (parent_selector == null) return error.InvalidDocument;
                },
                .detached_ruleset, .extend, .comment => {},
                else => return error.InvalidDocument,
            }
        }
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
        if (context == .value) {
            const evaluated = try self.evaluateValueOwned(span, output.items);
            output.deinit(self.allocator);
            return evaluated;
        }
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
            try self.appendTemporary(output, token.raw(raw));
            cursor = token_end;
        }
        try self.appendTemporary(output, raw[cursor..]);
    }

    fn evaluateValueOwned(
        self: *Engine,
        span: native_source.Span,
        rendered: []const u8,
    ) Error![]u8 {
        const value = std.mem.trim(u8, rendered, " \t\r\n\x0c");
        if (value.len == 0) return try self.allocator.dupe(u8, value);
        if (functionArguments(value, "url") != null) {
            return self.rewriteUrlOwned(span, value);
        }
        if (functionArguments(value, "calc") != null) {
            return try self.allocator.dupe(u8, value);
        }
        if (functionArguments(value, "percentage")) |arguments| {
            const numeric = try self.parseNumericOrReport(span, value[arguments.start..arguments.end]);
            if (!numeric.isDimensionless()) {
                try self.reportInvalidOperation(span, "native Less percentage() requires a unitless number");
                return error.InvalidOperation;
            }
            var buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
            const percentage = native_numeric.serialize(numeric.value * 100, &buffer, true) catch {
                try self.reportInvalidOperation(span, "native Less percentage() result is invalid");
                return error.InvalidOperation;
            };
            return try std.fmt.allocPrint(self.allocator, "{s}%", .{percentage});
        }
        if (functionArguments(value, "darken")) |arguments| {
            var parts = try splitTopLevelAlloc(self.allocator, value, arguments, ',');
            defer parts.deinit(self.allocator);
            if (parts.items.len != 2) {
                try self.reportInvalidOperation(span, "native Less darken() requires two arguments");
                return error.InvalidOperation;
            }
            const color_range = trimByteRange(value, parts.items[0]);
            const amount_range = trimByteRange(value, parts.items[1]);
            const color = native_color.parseLiteral(value[color_range.start..color_range.end]) orelse {
                try self.reportInvalidOperation(span, "native Less darken() requires a color");
                return error.InvalidOperation;
            };
            const amount = try self.parseNumericOrReport(
                span,
                value[amount_range.start..amount_range.end],
            );
            var numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
            var denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
            const amount_number = amount.toNumber(&numerator, &denominator) catch {
                try self.reportInvalidOperation(span, "native Less darken() amount is invalid");
                return error.InvalidOperation;
            };
            if (amount_number.numerator_units.len != 1 or
                !std.mem.eql(u8, amount_number.numerator_units[0], "%") or
                amount_number.denominator_units.len != 0)
            {
                try self.reportInvalidOperation(span, "native Less darken() amount requires percent units");
                return error.InvalidOperation;
            }
            const adjusted = native_color.adjustLightness(color, -amount.value) catch {
                try self.reportInvalidOperation(span, "native Less darken() arguments are invalid");
                return error.InvalidOperation;
            };
            const channels = native_color.toRgb(adjusted) catch {
                try self.reportInvalidOperation(span, "native Less darken() result is invalid");
                return error.InvalidOperation;
            };
            if (channels[3] != 1) {
                try self.reportInvalidOperation(span, "native Less darken() alpha is unsupported");
                return error.InvalidOperation;
            }
            const result = try self.allocator.alloc(u8, 7);
            result[0] = '#';
            for (channels[0..3], 0..) |channel, index| {
                const rounded: u8 = @intFromFloat(@floor(
                    std.math.clamp(channel, 0, 255) + 0.5 - 1e-9,
                ));
                result[1 + index * 2] = hexDigit(rounded >> 4);
                result[2 + index * 2] = hexDigit(rounded & 0x0f);
            }
            return result;
        }

        if (!looksNumeric(value)) return try self.allocator.dupe(u8, value);
        var parser = NumericParser{
            .input = value,
            .max_depth = self.limits.max_expression_depth,
            .strict_units = self.options.strict_units,
        };
        const numeric = parser.parse() catch |err| switch (err) {
            error.ExpressionDepthExceeded => {
                try self.transaction.report(
                    .err,
                    .resource_limit,
                    span,
                    "native Less expression depth exceeded",
                    &.{},
                );
                return error.ExpressionDepthExceeded;
            },
            error.IncompatibleUnits => {
                try self.reportInvalidOperation(span, "native Less operation uses incompatible units");
                return error.IncompatibleUnits;
            },
            else => return try self.allocator.dupe(u8, value),
        };
        return try self.serializeNumeric(numeric);
    }

    fn parseNumericOrReport(
        self: *Engine,
        span: native_source.Span,
        input: []const u8,
    ) Error!native_numeric.Numeric {
        var parser = NumericParser{
            .input = std.mem.trim(u8, input, " \t\r\n\x0c"),
            .max_depth = self.limits.max_expression_depth,
            .strict_units = self.options.strict_units,
        };
        return parser.parse() catch |err| switch (err) {
            error.ExpressionDepthExceeded => {
                try self.transaction.report(
                    .err,
                    .resource_limit,
                    span,
                    "native Less expression depth exceeded",
                    &.{},
                );
                return error.ExpressionDepthExceeded;
            },
            error.IncompatibleUnits => {
                try self.reportInvalidOperation(span, "native Less operation uses incompatible units");
                return error.IncompatibleUnits;
            },
            else => {
                try self.reportInvalidOperation(span, "native Less numeric expression is invalid");
                return error.InvalidOperation;
            },
        };
    }

    fn serializeNumeric(
        self: *Engine,
        numeric: native_numeric.Numeric,
    ) Error![]u8 {
        var numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
        var denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
        const number = numeric.toNumber(&numerator, &denominator) catch
            return error.InvalidOperation;
        var number_buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
        const value = native_numeric.serialize(number.value, &number_buffer, true) catch
            return error.InvalidOperation;
        var unit_buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
        const units = native_numeric.serializeUnits(number, &unit_buffer) catch
            return error.InvalidOperation;
        return try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ value, units });
    }

    fn rewriteUrlOwned(
        self: *Engine,
        span: native_source.Span,
        value: []const u8,
    ) Error![]u8 {
        _ = self.options.math;
        _ = self.options.quiet_deprecations;
        _ = self.options.rewrite_urls;
        if (span.source.eql(self.root_source)) return try self.allocator.dupe(u8, value);
        const arguments = functionArguments(value, "url") orelse
            return try self.allocator.dupe(u8, value);
        const raw_argument = std.mem.trim(
            u8,
            value[arguments.start..arguments.end],
            " \t\r\n\x0c",
        );
        const target = stripQuotes(raw_argument);
        if (target.len == 0 or target[0] == '/' or target[0] == '#' or
            hasNonLocalScheme(target) or std.mem.indexOfAny(u8, target, "?#") != null)
        {
            return try self.allocator.dupe(u8, value);
        }

        const imported_file = try self.sources.get(span.source);
        const root_file = try self.sources.get(self.root_source);
        const imported_path = native_resolver.fileUrlToPath(
            self.allocator,
            imported_file.name,
        ) catch return try self.allocator.dupe(u8, value);
        defer self.allocator.free(imported_path);
        const root_path = native_resolver.fileUrlToPath(
            self.allocator,
            root_file.name,
        ) catch return try self.allocator.dupe(u8, value);
        defer self.allocator.free(root_path);
        const imported_directory = std.fs.path.dirname(imported_path) orelse
            return try self.allocator.dupe(u8, value);
        const root_directory = std.fs.path.dirname(root_path) orelse
            return try self.allocator.dupe(u8, value);
        const absolute_target = try std.fs.path.resolve(
            self.allocator,
            &.{ imported_directory, target },
        );
        defer self.allocator.free(absolute_target);
        const relative = std.fs.path.relative(
            self.allocator,
            root_directory,
            absolute_target,
        ) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return try self.allocator.dupe(u8, value),
        };
        defer self.allocator.free(relative);

        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(self.allocator);
        if (!std.mem.startsWith(u8, relative, ".")) {
            try self.appendTemporary(&normalized, "./");
        }
        for (relative) |byte| {
            try normalized.append(self.allocator, if (byte == '\\') '/' else byte);
        }
        const quote: ?u8 = if (raw_argument.len >= 2 and
            (raw_argument[0] == '\'' or raw_argument[0] == '"'))
            raw_argument[0]
        else
            null;
        if (quote) |value_quote| {
            return try std.fmt.allocPrint(
                self.allocator,
                "url({c}{s}{c})",
                .{ value_quote, normalized.items, value_quote },
            );
        }
        return try std.fmt.allocPrint(self.allocator, "url({s})", .{normalized.items});
    }

    fn guardMatches(
        self: *Engine,
        span: native_source.Span,
        scope: Scope,
    ) Error!bool {
        const rendered = try self.renderOwned(span, scope.cursor, .at_rule);
        defer self.allocator.free(rendered);
        var raw = std.mem.trim(u8, rendered, " \t\r\n\x0c");
        if (!std.mem.startsWith(u8, raw, "when")) return error.InvalidOperation;
        raw = std.mem.trim(u8, raw[4..], " \t\r\n\x0c");
        if (raw.len >= 2 and raw[0] == '(' and raw[raw.len - 1] == ')') {
            raw = std.mem.trim(u8, raw[1 .. raw.len - 1], " \t\r\n\x0c");
        }
        const comparison = findComparison(raw) orelse return error.InvalidOperation;
        const left = try self.parseNumericOrReport(span, raw[0..comparison.index]);
        const right = try self.parseNumericOrReport(
            span,
            raw[comparison.index + comparison.length ..],
        );
        const ordering = native_numeric.compare(left, right) catch {
            try self.reportInvalidOperation(span, "native Less guard uses incompatible units");
            return error.IncompatibleUnits;
        };
        return switch (comparison.kind) {
            .less => ordering == .less,
            .less_equal => ordering != .greater,
            .greater => ordering == .greater,
            .greater_equal => ordering != .less,
            .equal => ordering == .equal,
        };
    }

    fn reportInvalidOperation(
        self: *Engine,
        span: native_source.Span,
        message: []const u8,
    ) Error!void {
        try self.transaction.report(.err, .invalid_operation, span, message, &.{});
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

const ComparisonKind = enum {
    less,
    less_equal,
    greater,
    greater_equal,
    equal,
};

const Comparison = struct {
    index: usize,
    length: usize,
    kind: ComparisonKind,
};

const NumericParser = struct {
    input: []const u8,
    max_depth: u16,
    strict_units: bool,
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
            result = native_numeric.add(result, right, operation) catch |failure| switch (failure) {
                error.IncompatibleUnits => if (self.strict_units)
                    return failure
                else
                    try native_numeric.addPermissive(result, right, operation),
                else => return failure,
            };
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
        return try native_numeric.Numeric.init(value, unit);
    }

    fn skipWhitespace(self: *NumericParser) void {
        while (self.cursor < self.input.len and
            std.ascii.isWhitespace(self.input[self.cursor]))
        {
            self.cursor += 1;
        }
    }

    fn peek(self: *const NumericParser) u8 {
        return if (self.cursor < self.input.len) self.input[self.cursor] else 0;
    }
};

fn callableName(raw: []const u8) ?[]const u8 {
    const input = std.mem.trim(u8, raw, " \t\r\n\x0c;");
    if (input.len == 0) return null;
    var end: usize = 0;
    while (end < input.len and input[end] != '(' and
        !std.ascii.isWhitespace(input[end])) : (end += 1)
    {}
    if (end == 0 or (input[0] != '.' and input[0] != '#' and input[0] != '@')) {
        return null;
    }
    return input[0..end];
}

fn callableArguments(raw: []const u8) ?ByteRange {
    const opening = std.mem.indexOfScalar(u8, raw, '(') orelse return null;
    var depth: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
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
        if (byte == '(') depth += 1;
        if (byte == ')') {
            depth -= 1;
            if (depth == 0) {
                if (std.mem.trim(u8, raw[index + 1 ..], " \t\r\n\x0c;").len != 0) {
                    return null;
                }
                return .{ .start = opening + 1, .end = index };
            }
        }
    }
    return null;
}

fn functionArguments(raw: []const u8, name: []const u8) ?ByteRange {
    const arguments = callableArguments(raw) orelse return null;
    const function_name = std.mem.trim(u8, raw[0 .. arguments.start - 1], " \t\r\n\x0c");
    if (!std.ascii.eqlIgnoreCase(function_name, name)) return null;
    return arguments;
}

fn splitTopLevelAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    bounds: ByteRange,
    delimiter: u8,
) std.mem.Allocator.Error!std.ArrayList(ByteRange) {
    var result: std.ArrayList(ByteRange) = .empty;
    errdefer result.deinit(allocator);
    const trimmed = trimByteRange(raw, bounds);
    if (trimmed.start == trimmed.end) return result;
    var depth: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    var start = bounds.start;
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
            ')', ']', '}' => if (depth > 0) {
                depth -= 1;
            },
            else => {},
        }
        if (byte == delimiter and depth == 0) {
            try result.append(allocator, .{ .start = start, .end = index });
            start = index + 1;
        }
    }
    try result.append(allocator, .{ .start = start, .end = bounds.end });
    return result;
}

fn containsTopLevel(raw: []const u8, needle: u8) bool {
    return findTopLevelByte(raw, .{ .start = 0, .end = raw.len }, needle) != null;
}

fn findTopLevelByte(raw: []const u8, bounds: ByteRange, needle: u8) ?usize {
    var depth: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    for (raw[bounds.start..bounds.end], bounds.start..) |byte, index| {
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
            ')', ']', '}' => if (depth > 0) {
                depth -= 1;
            },
            else => {},
        }
        if (byte == needle and depth == 0) return index;
    }
    return null;
}

fn trimByteRange(raw: []const u8, input: ByteRange) ByteRange {
    var start = input.start;
    var end = input.end;
    while (start < end and std.ascii.isWhitespace(raw[start])) start += 1;
    while (end > start and std.ascii.isWhitespace(raw[end - 1])) end -= 1;
    return .{ .start = start, .end = end };
}

fn extendTarget(raw: []const u8) ?[]const u8 {
    const marker = ":extend(";
    const opening = std.mem.indexOf(u8, raw, marker) orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, raw[0..opening], " \t\r\n\x0c"), "&")) {
        return null;
    }
    const target_start = opening + marker.len;
    const closing = std.mem.lastIndexOfScalar(u8, raw, ')') orelse return null;
    if (closing <= target_start) return null;
    const target = std.mem.trim(u8, raw[target_start..closing], " \t\r\n\x0c");
    if (target.len == 0 or std.mem.indexOfAny(u8, target, " ,()") != null) return null;
    return target;
}

fn looksNumeric(raw: []const u8) bool {
    return raw.len > 0 and (std.ascii.isDigit(raw[0]) or raw[0] == '.' or
        raw[0] == '(' or raw[0] == '+' or raw[0] == '-');
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

fn findComparison(raw: []const u8) ?Comparison {
    for (raw, 0..) |byte, index| {
        if (byte != '<' and byte != '>' and byte != '=') continue;
        const has_equal = index + 1 < raw.len and raw[index + 1] == '=';
        return .{
            .index = index,
            .length = if (has_equal) 2 else 1,
            .kind = switch (byte) {
                '<' => if (has_equal) .less_equal else .less,
                '>' => if (has_equal) .greater_equal else .greater,
                '=' => .equal,
                else => unreachable,
            },
        };
    }
    return null;
}

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
