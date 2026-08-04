//! Private bounded semantic evaluator for native Less syntax.
//!
//! The internal surface implements the finite semantics exercised by all 68
//! successes and 20 strict failures in the pinned Less 4.6.7 selection.
//! JavaScript and plugin execution are permanently rejected before any CSS is
//! staged, and the frontend remains private until the later product gates.

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
    var inline_sources: std.AutoHashMapUnmanaged(native_source.SourceId, void) = .empty;
    defer inline_sources.deinit(transaction.allocator);
    var reference_nodes: std.AutoHashMapUnmanaged(native_syntax.NodeId, void) = .empty;
    defer reference_nodes.deinit(transaction.allocator);
    if (containsImports(document)) {
        var expander = ImportExpander.init(
            transaction.allocator,
            sources,
            transaction,
            limits,
            &inline_sources,
            &reference_nodes,
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
        &inline_sources,
        &reference_nodes,
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
    inline_content: bool = false,
    reference: bool = false,
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
    optional_missing_urls: std.StringHashMapUnmanaged(void) = .empty,
    variables: std.StringHashMapUnmanaged([]const u8) = .empty,
    ancestry: std.ArrayList([]const u8) = .empty,
    multiple_depth: usize = 0,
    preloading: bool = false,
    did_preload: bool = false,
    inline_sources: *std.AutoHashMapUnmanaged(native_source.SourceId, void),
    reference_nodes: *std.AutoHashMapUnmanaged(native_syntax.NodeId, void),
    reference_depth: usize = 0,

    fn init(
        allocator: std.mem.Allocator,
        sources: *native_source.Table,
        transaction: *native_evaluator.Transaction,
        limits: Limits,
        inline_sources: *std.AutoHashMapUnmanaged(native_source.SourceId, void),
        reference_nodes: *std.AutoHashMapUnmanaged(native_syntax.NodeId, void),
    ) ImportExpander {
        return .{
            .allocator = allocator,
            .sources = sources,
            .transaction = transaction,
            .limits = limits,
            .inline_sources = inline_sources,
            .reference_nodes = reference_nodes,
            .builder = native_syntax.Builder.init(allocator, sources, .{
                .max_nodes = limits.max_nodes,
            }),
        };
    }

    fn deinit(self: *ImportExpander) void {
        self.ancestry.deinit(self.allocator);
        self.once_urls.deinit(self.allocator);
        var optional_missing_iterator = self.optional_missing_urls.iterator();
        while (optional_missing_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.optional_missing_urls.deinit(self.allocator);
        self.variables.deinit(self.allocator);
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
        try self.collectVariables(document, try document.children(document.root));

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
        if (!self.preloading and !self.did_preload) {
            self.did_preload = true;
            self.preloading = true;
            var discarded: std.ArrayList(native_syntax.NodeId) = .empty;
            defer discarded.deinit(self.allocator);
            for (children) |child_id| {
                const child = document.get(child_id) catch return error.InvalidDocument;
                if (child.kind != .import) continue;
                const import_children = document.children(child_id) catch return error.InvalidDocument;
                if (import_children.len != 1) continue;
                const expression = document.get(import_children[0]) catch return error.InvalidDocument;
                const raw = try self.sources.slice(expression.text orelse continue);
                if (std.mem.indexOf(u8, raw, "@{") != null) continue;
                try self.expandImport(document, child_id, &discarded);
            }
            self.once_urls.clearRetainingCapacity();
            self.preloading = false;
        }
        for (children) |child_id| {
            const child = document.get(child_id) catch return error.InvalidDocument;
            if (child.kind == .import) {
                try self.expandImport(document, child_id, output);
            } else {
                try output.append(self.allocator, try self.cloneNode(document, child_id, null));
            }
        }
    }

    fn collectVariables(
        self: *ImportExpander,
        document: *const native_syntax.Document,
        children: []const native_syntax.NodeId,
    ) Error!void {
        for (children) |child_id| {
            const child = document.get(child_id) catch return error.InvalidDocument;
            if (child.kind != .declaration) continue;
            const declaration_children = document.children(child_id) catch
                return error.InvalidDocument;
            if (declaration_children.len != 2) continue;
            const name_node = document.get(declaration_children[0]) catch
                return error.InvalidDocument;
            const value_node = document.get(declaration_children[1]) catch
                return error.InvalidDocument;
            if (name_node.kind != .variable or name_node.text == null or value_node.text == null) {
                continue;
            }
            const name = try self.sources.slice(name_node.text.?);
            const value = stripQuotes(std.mem.trim(
                u8,
                try self.sources.slice(value_node.text.?),
                " \t\r\n\x0c",
            ));
            if (!self.variables.contains(name)) {
                try self.variables.put(self.allocator, name, value);
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
        const cloned = try self.builder.add(
            kind_override orelse node.kind,
            node.span,
            node.text,
            children.items,
        );
        if (self.reference_depth > 0) {
            try self.reference_nodes.put(self.allocator, cloned, {});
        }
        return cloned;
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
        const interpolated_raw = try self.interpolateImportOwned(raw);
        defer self.allocator.free(interpolated_raw);
        const parsed = parseImportPrelude(interpolated_raw) catch {
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
        if (!self.preloading and self.optional_missing_urls.contains(candidate_url)) return;
        const cached_source_id = if (self.preloading)
            null
        else
            self.source_ids.get(candidate_url);
        if (cached_source_id != null) {
            for (self.ancestry.items) |ancestor| {
                if (!std.mem.eql(u8, ancestor, candidate_url)) continue;
                try self.reportImport(import_node.span, "native Less import cycle detected");
                return error.InvalidImport;
            }
        }
        const source_id = cached_source_id orelse source: {
            const session = try self.transaction.resolverSession();
            var loaded = session.load(candidate_url, .{
                .kind = .import,
                .ancestry = self.ancestry.items,
            }) catch |failure| switch (failure) {
                error.Missing => {
                    if (parsed.options.optional) {
                        if (self.preloading and
                            !self.optional_missing_urls.contains(candidate_url))
                        {
                            const owned_url = try self.allocator.dupe(u8, candidate_url);
                            errdefer self.allocator.free(owned_url);
                            try self.optional_missing_urls.put(self.allocator, owned_url, {});
                        }
                        return;
                    }
                    try self.reportImport(import_node.span, "native Less import was not found");
                    return error.InvalidImport;
                },
                else => return self.failLoad(failure, import_node.span),
            };
            defer loaded.deinit();

            const added = self.source_ids.get(loaded.url) orelse added: {
                const new_source = self.sources.add(loaded.url, loaded.contents) catch |failure| {
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
                const source_file = try self.sources.get(new_source);
                try self.source_ids.put(self.allocator, source_file.name, new_source);
                break :added new_source;
            };
            break :source added;
        };
        const source_file = try self.sources.get(source_id);
        if (parsed.options.inline_content) {
            try self.inline_sources.put(self.allocator, source_id, {});
        }
        const seen = self.once_urls.contains(source_file.name);
        const effective_multiple = parsed.options.multiple or self.multiple_depth > 0;
        if (!effective_multiple and seen) return;
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
        try self.collectVariables(&imported, try imported.children(imported.root));

        try self.ancestry.append(self.allocator, source_file.name);
        defer _ = self.ancestry.pop();
        if (parsed.options.multiple) self.multiple_depth += 1;
        if (parsed.options.reference) self.reference_depth += 1;
        defer {
            if (parsed.options.multiple) self.multiple_depth -= 1;
            if (parsed.options.reference) self.reference_depth -= 1;
        }
        try self.appendStatements(&imported, try imported.children(imported.root), output);
    }

    fn interpolateImportOwned(
        self: *ImportExpander,
        input: []const u8,
    ) Error![]u8 {
        var current = try self.allocator.dupe(u8, input);
        errdefer self.allocator.free(current);
        var count: usize = 0;
        while (std.mem.indexOf(u8, current, "@{")) |opening| {
            if (count >= 64) return error.InvalidImport;
            const closing = std.mem.indexOfScalarPos(u8, current, opening + 2, '}') orelse
                return error.InvalidImport;
            const bare = std.mem.trim(u8, current[opening + 2 .. closing], " \t\r\n\x0c");
            const name = try std.fmt.allocPrint(self.allocator, "@{s}", .{bare});
            defer self.allocator.free(name);
            const value = self.variables.get(name) orelse return error.InvalidImport;
            const next = try std.fmt.allocPrint(
                self.allocator,
                "{s}{s}{s}",
                .{ current[0..opening], value, current[closing + 1 ..] },
            );
            self.allocator.free(current);
            current = next;
            count += 1;
        }
        return current;
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
            } else if (std.ascii.eqlIgnoreCase(option, "inline")) {
                options.inline_content = true;
            } else if (std.ascii.eqlIgnoreCase(option, "reference")) {
                options.reference = true;
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
    visible_scope: usize,
};

const DetachedDefinition = struct {
    name: []const u8,
    block: native_syntax.NodeId,
    scope: Scope,
    visible_scope: usize,
};

const Extension = struct {
    target: []const u8,
    extender: []const u8,
    all: bool,
    context: u64,
};

const ByteRange = struct {
    start: usize,
    end: usize,
};

const AtRulePrelude = struct {
    rendered: []u8,
    cleaned: ?[]u8 = null,
    comments: std.ArrayList(ByteRange) = .empty,

    fn text(self: *const AtRulePrelude) []const u8 {
        return self.cleaned orelse self.rendered;
    }

    fn deinit(self: *AtRulePrelude, allocator: std.mem.Allocator) void {
        self.comments.deinit(allocator);
        if (self.cleaned) |cleaned| allocator.free(cleaned);
        allocator.free(self.rendered);
        self.* = undefined;
    }
};

const DeferredMedia = struct {
    id: native_syntax.NodeId,
    scope: Scope,
    parent_selector: ?[]u8,
};

const RenderContext = enum {
    selector,
    property,
    value,
    binding_value,
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
    inline_sources: *const std.AutoHashMapUnmanaged(native_source.SourceId, void),
    reference_nodes: *const std.AutoHashMapUnmanaged(native_syntax.NodeId, void),
    values: native_value.Store,
    environment: native_environment.Environment,
    bindings: std.ArrayList(Binding) = .empty,
    binding_indices: std.AutoHashMapUnmanaged(*const native_value.Value, usize) = .empty,
    unlocked_bindings: std.StringHashMapUnmanaged(*const native_value.Value) = .empty,
    guard_unorderable_bindings: std.AutoHashMapUnmanaged(
        *const native_value.Value,
        void,
    ) = .empty,
    scope_fallbacks: std.AutoHashMapUnmanaged(
        native_environment.ScopeId,
        native_environment.ScopeId,
    ) = .empty,
    empty_detached_parameters: std.StringHashMapUnmanaged(void) = .empty,
    scopes: std.ArrayList(ScopeRecord) = .empty,
    mixins: std.ArrayList(MixinDefinition) = .empty,
    detached: std.ArrayList(DetachedDefinition) = .empty,
    extensions: std.ArrayList(Extension) = .empty,
    active_rule_blocks: std.ArrayList(native_syntax.NodeId) = .empty,
    owned_names: std.ArrayList([]u8) = .empty,
    selector_count: usize = 0,
    call_count: u32 = 0,
    active_call_depth: u16 = 0,
    extension_context: u64 = 0,
    deferred_media: ?*std.ArrayList(DeferredMedia) = null,
    force_important_depth: usize = 0,
    default_guard_value: bool = false,
    guard_has_unorderable_operand: bool = false,
    variable_depth: u16 = 0,

    fn init(
        allocator: std.mem.Allocator,
        sources: *const native_source.Table,
        document: *const native_syntax.Document,
        transaction: *native_evaluator.Transaction,
        options: Options,
        limits: Limits,
        inline_sources: *const std.AutoHashMapUnmanaged(native_source.SourceId, void),
        reference_nodes: *const std.AutoHashMapUnmanaged(native_syntax.NodeId, void),
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
            .inline_sources = inline_sources,
            .reference_nodes = reference_nodes,
            .values = values,
            .environment = environment,
        };
    }

    fn deinit(self: *Engine) void {
        for (self.owned_names.items) |name| self.allocator.free(name);
        self.owned_names.deinit(self.allocator);
        self.active_rule_blocks.deinit(self.allocator);
        self.extensions.deinit(self.allocator);
        self.detached.deinit(self.allocator);
        self.mixins.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.scope_fallbacks.deinit(self.allocator);
        self.empty_detached_parameters.deinit(self.allocator);
        self.guard_unorderable_bindings.deinit(self.allocator);
        self.unlocked_bindings.deinit(self.allocator);
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
        try self.emitRootStatements(children, scope);
    }

    fn emitRootStatements(
        self: *Engine,
        children: []const native_syntax.NodeId,
        scope: Scope,
    ) Error!void {
        var emitted_charset = false;
        for (children) |child_id| {
            if (!emitted_charset and try self.isAtRuleKeyword(child_id, "@charset")) {
                try self.emitAtRule(child_id, scope, null);
                emitted_charset = true;
            }
        }
        for (children) |child_id| {
            if (try self.isCssImportAtRule(child_id)) {
                try self.emitAtRuleInternal(child_id, scope, null, false);
            }
        }
        for (children) |child_id| {
            if (try self.isAtRuleKeyword(child_id, "@charset")) continue;
            if (try self.isCssImportAtRule(child_id)) {
                try self.emitAtRuleKeywordComments(child_id, scope);
                continue;
            }
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            switch (child.kind) {
                .declaration => if (!try self.isVariableDeclaration(child_id)) {
                    return error.InvalidDocument;
                },
                .rule => try self.emitRule(child_id, scope, null),
                .at_rule => try self.emitAtRule(child_id, scope, null),
                .mixin => if (!try self.isMixinDefinition(child_id)) {
                    const node_children = self.document.children(child_id) catch
                        return error.InvalidDocument;
                    if (node_children.len > 1) {
                        try self.emitRule(child_id, scope, null);
                        continue;
                    }
                    var discarded: std.ArrayList(u8) = .empty;
                    defer discarded.deinit(self.allocator);
                    const expression_children = node_children;
                    if (expression_children.len != 1) return error.InvalidDocument;
                    const expression = self.document.get(expression_children[0]) catch
                        return error.InvalidDocument;
                    const raw = try self.sources.slice(expression.text orelse
                        return error.InvalidDocument);
                    if (functionArguments(raw, "each") != null) {
                        try self.appendCallable(&discarded, child_id, scope, "");
                        continue;
                    }
                    if (callableName(raw)) |name| {
                        if (name[0] == '.' or name[0] == '#' or name[0] == '@') {
                            try self.appendCallable(&discarded, child_id, scope, "");
                            try self.emitCallableNested(child_id, scope, "");
                        }
                    }
                } else if (try self.mixinDefinitionEmitsRule(child_id)) {
                    try self.emitRule(child_id, scope, null);
                },
                .detached_ruleset, .extend, .comment => {},
                else => return error.InvalidDocument,
            }
        }
    }

    fn isCssImportAtRule(
        self: *const Engine,
        node_id: native_syntax.NodeId,
    ) Error!bool {
        return self.isAtRuleKeyword(node_id, "@import");
    }

    fn isAtRuleKeyword(
        self: *const Engine,
        node_id: native_syntax.NodeId,
        expected: []const u8,
    ) Error!bool {
        const node = self.document.get(node_id) catch return error.InvalidDocument;
        if (node.kind != .at_rule or node.text == null) return false;
        const keyword = try self.sources.slice(node.text.?);
        return native_lexer.identifierEqlIgnoreCaseAscii(keyword, expected);
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
        if (parent) |parent_scope| {
            if (self.scope_fallbacks.get(parent_scope.cursor)) |fallback| {
                try self.scope_fallbacks.put(self.allocator, result.cursor, fallback);
            }
        }
        try self.populateScope(children, &result);
        if (parent) |parent_scope| {
            if (self.scope_fallbacks.get(parent_scope.cursor)) |fallback| {
                try self.scope_fallbacks.put(self.allocator, result.cursor, fallback);
            }
        }
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
            if (binding.name.len > 0 and binding.name[0] == '@') {
                binding.definition_scope = result.cursor;
            }
        }
        try self.rejectDirectCycles(binding_start);
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            switch (child.kind) {
                .mixin => if (try self.isMixinDefinition(child_id)) {
                    try self.registerMixin(child_id, result.*);
                },
                .rule => try self.registerRuleMixin(child_id, result.*),
                .detached_ruleset => try self.registerDetached(child_id, result.*),
                else => {},
            }
        }
        for (children) |child_id| {
            if (try self.isPropertyDeclaration(child_id)) {
                try self.addPropertyBinding(child_id, result);
                continue;
            }
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            if (child.kind == .mixin and !try self.isMixinDefinition(child_id)) {
                try self.addCallablePropertyBindings(child_id, result);
            }
        }
    }

    fn addCallablePropertyBindings(
        self: *Engine,
        call_id: native_syntax.NodeId,
        scope: *Scope,
    ) Error!void {
        const children = self.document.children(call_id) catch return error.InvalidDocument;
        if (children.len != 1) return;
        const expression = self.document.get(children[0]) catch return error.InvalidDocument;
        const raw = try self.sources.slice(expression.text orelse return error.InvalidDocument);
        const name = callableName(raw) orelse return;
        if (name[0] == '@' or std.mem.indexOfScalar(u8, raw, '>') != null) return;
        const definition = self.lookupMixin(scope.*, name) orelse return;
        const definition_children = self.document.children(definition.block) catch
            return error.InvalidDocument;
        const signature_raw = try self.sources.slice(definition.signature);
        const signature_arguments = callableArguments(signature_raw);
        const has_parameters = if (signature_arguments) |bounds|
            std.mem.trim(
                u8,
                signature_raw[bounds.start..bounds.end],
                " \t\r\n\x0c",
            ).len > 0
        else
            false;
        for (definition_children) |definition_child| {
            if (!has_parameters and try self.isVariableDeclaration(definition_child)) {
                try self.addBinding(definition_child, scope);
            }
            if (try self.isPropertyDeclaration(definition_child)) {
                try self.addPropertyBinding(definition_child, scope);
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
        const previous_cursor = scope.cursor;
        scope.cursor = try self.environment.set(scope.cursor, name, holder);
        if (self.scope_fallbacks.get(previous_cursor)) |fallback| {
            try self.scope_fallbacks.put(self.allocator, scope.cursor, fallback);
        }
        try self.transaction.consumeOperations(1);
        _ = declaration;
    }

    fn addPropertyBinding(
        self: *Engine,
        declaration_id: native_syntax.NodeId,
        scope: *Scope,
    ) Error!void {
        const children = self.document.children(declaration_id) catch
            return error.InvalidDocument;
        if (children.len != 2) return;
        const name_node = self.document.get(children[0]) catch return error.InvalidDocument;
        const expression = self.document.get(children[1]) catch return error.InvalidDocument;
        if (name_node.kind != .identifier or name_node.text == null or
            expression.kind != .expression or expression.text == null)
        {
            return;
        }
        const raw_name = std.mem.trim(
            u8,
            try self.sources.slice(name_node.text.?),
            " \t\r\n\x0c",
        );
        if (raw_name.len == 0 or std.mem.indexOfAny(u8, raw_name, "@${}") != null) return;
        const space_merge = std.mem.endsWith(u8, raw_name, "+_");
        const comma_merge = !space_merge and std.mem.endsWith(u8, raw_name, "+");
        const merge_suffix_len: usize = if (space_merge) 2 else if (comma_merge) 1 else 0;
        const property_end = raw_name.len - merge_suffix_len;
        if (property_end == 0) return;
        const name = try std.fmt.allocPrint(self.allocator, "${s}", .{raw_name[0..property_end]});
        var name_stored = false;
        errdefer if (!name_stored) self.allocator.free(name);
        if (space_merge or comma_merge) {
            const previous = if (try self.environment.lookup(scope.cursor, name) != null)
                try self.resolveVariable(name, expression.span, scope.cursor)
            else
                null;
            const rendered = try self.renderOwned(expression.text.?, scope.cursor, .value);
            defer self.allocator.free(rendered);
            if (previous) |prior| {
                const combined = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}{s}{s}",
                    .{ prior, if (space_merge) " " else ", ", rendered },
                );
                defer self.allocator.free(combined);
                try self.addResolvedBinding(name, combined, scope);
            } else {
                try self.addResolvedBinding(name, rendered, scope);
            }
            self.allocator.free(name);
            name_stored = true;
            return;
        }
        try self.owned_names.append(self.allocator, name);
        name_stored = true;
        const expression_bytes = try self.sources.slice(expression.text.?);
        const holder = try self.values.own(.{ .string = .{ .bytes = expression_bytes } });
        const binding_index = self.bindings.items.len;
        try self.bindings.append(self.allocator, .{
            .holder = holder,
            .name = name,
            .expression = expression.text.?,
            .definition_scope = scope.cursor,
        });
        try self.binding_indices.put(self.allocator, holder, binding_index);
        const previous_cursor = scope.cursor;
        scope.cursor = try self.environment.set(scope.cursor, name, holder);
        if (self.scope_fallbacks.get(previous_cursor)) |fallback| {
            try self.scope_fallbacks.put(self.allocator, scope.cursor, fallback);
        }
        try self.transaction.consumeOperations(1);
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

    fn isPropertyDeclaration(
        self: *const Engine,
        declaration_id: native_syntax.NodeId,
    ) Error!bool {
        const declaration = self.document.get(declaration_id) catch
            return error.InvalidDocument;
        if (declaration.kind != .declaration) return false;
        const children = self.document.children(declaration_id) catch
            return error.InvalidDocument;
        if (children.len < 2) return false;
        const first = self.document.get(children[0]) catch return error.InvalidDocument;
        return first.kind == .identifier;
    }

    fn isMixinDefinition(
        self: *const Engine,
        mixin_id: native_syntax.NodeId,
    ) Error!bool {
        const mixin = self.document.get(mixin_id) catch return error.InvalidDocument;
        if (mixin.kind != .mixin) return false;
        const children = self.document.children(mixin_id) catch return error.InvalidDocument;
        if (children.len < 2) return false;
        const signature = self.document.get(children[0]) catch return error.InvalidDocument;
        if (signature.kind != .selector or signature.text == null) return false;
        return callableName(try self.sources.slice(signature.text.?)) != null;
    }

    fn mixinDefinitionEmitsRule(
        self: *const Engine,
        mixin_id: native_syntax.NodeId,
    ) Error!bool {
        if (!try self.isMixinDefinition(mixin_id)) return false;
        const children = self.document.children(mixin_id) catch return error.InvalidDocument;
        const signature = self.document.get(children[0]) catch return error.InvalidDocument;
        const raw = try self.sources.slice(signature.text orelse return error.InvalidDocument);
        return std.mem.indexOfScalar(u8, raw, '(') == null;
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
        const raw_signature = try self.sources.slice(signature.text.?);
        const rendered_signature = try self.resolveInterpolatedTextOwned(
            raw_signature,
            signature.text.?,
            scope.cursor,
        );
        defer self.allocator.free(rendered_signature);
        const name = callableName(rendered_signature) orelse return error.InvalidDocument;
        const owned_name = try self.values.own(.{ .string = .{ .bytes = name } });
        try self.mixins.append(self.allocator, .{
            .name = owned_name.string.bytes,
            .signature = signature.text.?,
            .guard = guard,
            .block = children[children.len - 1],
            .scope = scope,
            .visible_scope = scope.id,
        });
    }

    fn registerRuleMixin(
        self: *Engine,
        rule_id: native_syntax.NodeId,
        scope: Scope,
    ) Error!void {
        const children = self.document.children(rule_id) catch return error.InvalidDocument;
        if (children.len < 2) return error.InvalidDocument;
        const selector = self.document.get(children[0]) catch return error.InvalidDocument;
        if (selector.kind != .selector or selector.text == null) return error.InvalidDocument;
        const raw = try self.sources.slice(selector.text.?);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n\x0c");
        if (std.mem.startsWith(u8, trimmed, ">")) {
            const rendered = try self.resolveInterpolatedTextOwned(
                trimmed,
                selector.text.?,
                scope.cursor,
            );
            defer self.allocator.free(rendered);
            const normalized = std.mem.trimLeft(u8, rendered[1..], " \t\r\n\x0c");
            const name = callableName(normalized) orelse return;
            const owned_name = try self.values.own(.{ .string = .{ .bytes = name } });
            var guard: ?native_source.Span = null;
            if (children.len == 3) {
                const guard_node = self.document.get(children[1]) catch
                    return error.InvalidDocument;
                guard = guard_node.text;
            }
            try self.mixins.append(self.allocator, .{
                .name = owned_name.string.bytes,
                .signature = selector.text.?,
                .guard = guard,
                .block = children[children.len - 1],
                .scope = scope,
                .visible_scope = scope.id,
            });
            return;
        }
        var selector_parts = try splitTopLevelAlloc(
            self.allocator,
            trimmed,
            .{ .start = 0, .end = trimmed.len },
            ',',
        );
        defer selector_parts.deinit(self.allocator);
        if (selector_parts.items.len == 1) {
            if (callableName(raw) == null) {
                if (std.mem.indexOf(u8, raw, "@{") == null and
                    std.mem.indexOf(u8, raw, "${") == null) return;
                const rendered = try self.resolveInterpolatedTextOwned(
                    raw,
                    selector.text.?,
                    scope.cursor,
                );
                defer self.allocator.free(rendered);
                if (callableName(rendered) == null) return;
            }
            try self.registerMixin(rule_id, scope);
            return;
        }
        for (selector_parts.items) |part| {
            const selector_piece = std.mem.trim(
                u8,
                trimmed[part.start..part.end],
                " \t\r\n\x0c",
            );
            if (std.mem.indexOfAny(u8, selector_piece, " \t\r\n\x0c>+~") != null) continue;
            const part_name = callableName(selector_piece) orelse continue;
            const owned_name = try self.values.own(.{ .string = .{ .bytes = part_name } });
            var guard: ?native_source.Span = null;
            if (children.len == 3) {
                const guard_node = self.document.get(children[1]) catch
                    return error.InvalidDocument;
                guard = guard_node.text;
            }
            try self.mixins.append(self.allocator, .{
                .name = owned_name.string.bytes,
                .signature = selector.text.?,
                .guard = guard,
                .block = children[children.len - 1],
                .scope = scope,
                .visible_scope = scope.id,
            });
        }
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
        const owned_name = try self.values.own(.{ .string = .{ .bytes = name } });
        try self.detached.append(self.allocator, .{
            .name = owned_name.string.bytes,
            .block = children[1],
            .scope = scope,
            .visible_scope = scope.id,
        });
    }

    fn collectRootExtensions(
        self: *Engine,
        children: []const native_syntax.NodeId,
        scope: Scope,
    ) Error!void {
        try self.collectExtensions(children, scope, null);
    }

    fn collectExtensions(
        self: *Engine,
        children: []const native_syntax.NodeId,
        scope: Scope,
        parent_selector: ?[]const u8,
    ) Error!void {
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            if (self.reference_nodes.contains(child_id) and
                (child.kind == .rule or child.kind == .at_rule)) continue;
            const child_nodes = self.document.children(child_id) catch
                return error.InvalidDocument;
            const mixin_with_selector_extend = if (child.kind == .mixin and child_nodes.len > 1) blk: {
                const selector = self.document.get(child_nodes[0]) catch
                    return error.InvalidDocument;
                const raw = if (selector.text) |text| try self.sources.slice(text) else "";
                break :blk std.mem.indexOf(u8, raw, ":extend(") != null;
            } else false;
            if (child.kind == .rule or mixin_with_selector_extend) {
                const rule_children = self.document.children(child_id) catch
                    return error.InvalidDocument;
                if (rule_children.len < 2 or rule_children.len > 3) return error.InvalidDocument;
                const selector_node = self.document.get(rule_children[0]) catch
                    return error.InvalidDocument;
                if (selector_node.kind != .selector or selector_node.text == null) {
                    return error.InvalidDocument;
                }
                const rendered = try self.renderOwned(selector_node.text.?, scope.cursor, .selector);
                defer self.allocator.free(rendered);
                const stripped = try self.stripSelectorExtendsOwned(rendered, parent_selector, true);
                defer self.allocator.free(stripped);
                const combined = try self.combineSelector(parent_selector, stripped);
                defer self.allocator.free(combined);
                const block_children = self.document.children(rule_children[rule_children.len - 1]) catch
                    return error.InvalidDocument;
                const child_scope = try self.prepareScope(block_children, scope);
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
                    const ignored = try self.stripSelectorExtendsOwned(raw, combined, true);
                    self.allocator.free(ignored);
                }
                try self.collectExtensions(block_children, child_scope, combined);
            } else if (child.kind == .at_rule) {
                const at_children = self.document.children(child_id) catch
                    return error.InvalidDocument;
                for (at_children) |at_child_id| {
                    const at_child = self.document.get(at_child_id) catch
                        return error.InvalidDocument;
                    if (at_child.kind != .block) continue;
                    const block_children = self.document.children(at_child_id) catch
                        return error.InvalidDocument;
                    const previous_context = self.extension_context;
                    self.extension_context = extendContext(previous_context, child_id);
                    self.collectExtensions(block_children, scope, parent_selector) catch |err| {
                        self.extension_context = previous_context;
                        return err;
                    };
                    self.extension_context = previous_context;
                }
            }
        }
    }

    fn addExtension(
        self: *Engine,
        target_raw: []const u8,
        extender_raw: []const u8,
    ) Error!void {
        var target = std.mem.trim(u8, target_raw, " \t\r\n\x0c");
        var all = false;
        if (std.mem.endsWith(u8, target, " all")) {
            target = std.mem.trimRight(u8, target[0 .. target.len - 4], " \t\r\n\x0c");
            all = true;
        }
        const extender = std.mem.trim(u8, extender_raw, " \t\r\n\x0c");
        if (target.len == 0 or extender.len == 0) return;
        const owned_target = try self.values.own(.{ .string = .{ .bytes = target } });
        var extender_parts = try splitTopLevelAlloc(
            self.allocator,
            extender,
            .{ .start = 0, .end = extender.len },
            ',',
        );
        defer extender_parts.deinit(self.allocator);
        for (extender_parts.items) |part| {
            const piece = std.mem.trim(
                u8,
                extender[part.start..part.end],
                " \t\r\n\x0c",
            );
            if (piece.len == 0) continue;
            const owned_extender = try self.values.own(.{ .string = .{ .bytes = piece } });
            try self.extensions.append(self.allocator, .{
                .target = owned_target.string.bytes,
                .extender = owned_extender.string.bytes,
                .all = all,
                .context = self.extension_context,
            });
        }
    }

    fn stripSelectorExtendsOwned(
        self: *Engine,
        input: []const u8,
        parent_selector: ?[]const u8,
        collect: bool,
    ) Error![]u8 {
        var selector_parts = try splitTopLevelAlloc(
            self.allocator,
            input,
            .{ .start = 0, .end = input.len },
            ',',
        );
        defer selector_parts.deinit(self.allocator);
        if (selector_parts.items.len > 1) {
            var combined: std.ArrayList(u8) = .empty;
            errdefer combined.deinit(self.allocator);
            for (selector_parts.items) |part| {
                const stripped_part = try self.stripSelectorExtendsOwned(
                    std.mem.trim(u8, input[part.start..part.end], " \t\r\n\x0c"),
                    parent_selector,
                    collect,
                );
                defer self.allocator.free(stripped_part);
                if (stripped_part.len == 0) continue;
                if (combined.items.len > 0) try self.appendTemporary(&combined, ",");
                try self.appendTemporary(&combined, stripped_part);
            }
            return try combined.toOwnedSlice(self.allocator);
        }
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        var targets: std.ArrayList([]u8) = .empty;
        defer {
            for (targets.items) |target| self.allocator.free(target);
            targets.deinit(self.allocator);
        }
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, input, cursor, ":extend(")) |marker| {
            const opening = marker + ":extend".len;
            const closing = matchingCloseParen(input, opening) orelse
                return error.InvalidDocument;
            try self.appendTemporary(&output, input[cursor..marker]);
            if (collect) {
                var parsed_targets = try splitTopLevelAlloc(
                    self.allocator,
                    input,
                    .{ .start = opening + 1, .end = closing },
                    ',',
                );
                defer parsed_targets.deinit(self.allocator);
                for (parsed_targets.items) |target_range| {
                    try targets.append(
                        self.allocator,
                        try self.allocator.dupe(
                            u8,
                            input[target_range.start..target_range.end],
                        ),
                    );
                }
            }
            cursor = closing + 1;
        }
        try self.appendTemporary(&output, input[cursor..]);
        const trimmed = std.mem.trim(u8, output.items, " \t\r\n\x0c;");
        if (collect and targets.items.len > 0) {
            const extender_owned = try self.combineSelector(
                parent_selector,
                if (trimmed.len > 0) trimmed else "&",
            );
            defer self.allocator.free(extender_owned);
            for (targets.items) |target| {
                try self.addExtension(target, extender_owned);
            }
        }
        return try self.allocator.dupe(u8, trimmed);
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
                    const mixin_children = self.document.children(child_id) catch
                        return error.InvalidDocument;
                    if (mixin_children.len > 1) {
                        try self.emitRule(child_id, scope, parent_selector);
                    } else if (parent_selector == null) {
                        return error.InvalidDocument;
                    }
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
        if (children.len < 2 or children.len > 3) return error.InvalidDocument;
        const selector_node = self.document.get(children[0]) catch return error.InvalidDocument;
        const block_node = self.document.get(children[children.len - 1]) catch
            return error.InvalidDocument;
        if (selector_node.kind != .selector or selector_node.text == null or
            block_node.kind != .block)
        {
            return error.InvalidDocument;
        }
        const block_children = self.document.children(children[children.len - 1]) catch
            return error.InvalidDocument;
        try self.active_rule_blocks.append(self.allocator, children[children.len - 1]);
        defer _ = self.active_rule_blocks.pop();
        const scope = try self.prepareScope(block_children, parent_scope);
        if (children.len == 3) {
            const guard = self.document.get(children[1]) catch return error.InvalidDocument;
            if (guard.kind != .guard or guard.text == null) return error.InvalidDocument;
            if (!try self.guardMatches(guard.text.?, scope)) return;
        }
        const rendered_selector = try self.renderOwned(
            selector_node.text.?,
            parent_scope.cursor,
            .selector,
        );
        defer self.allocator.free(rendered_selector);
        const stripped_selector = try self.stripSelectorExtendsOwned(
            rendered_selector,
            parent_selector,
            false,
        );
        defer self.allocator.free(stripped_selector);
        const selector = try self.combineSelector(parent_selector, stripped_selector);
        defer self.allocator.free(selector);
        try self.registerNestedRuleAliases(
            block_children,
            scope,
            selector,
            parent_scope.id,
        );
        const reference_only = self.reference_nodes.contains(rule_id);
        const emitted_selector = try self.selectorWithExtenders(selector, !reference_only);
        defer self.allocator.free(emitted_selector);
        if (reference_only and emitted_selector.len == 0) return;

        var declarations: std.ArrayList(u8) = .empty;
        defer declarations.deinit(self.allocator);
        for (block_children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            switch (child.kind) {
                .declaration => if (!try self.isVariableDeclaration(child_id)) {
                    try self.appendDeclaration(&declarations, child_id, scope);
                },
                .mixin => if (!try self.isMixinDefinition(child_id)) {
                    const mixin_children = self.document.children(child_id) catch
                        return error.InvalidDocument;
                    if (mixin_children.len == 1) {
                        try self.appendCallable(&declarations, child_id, scope, selector);
                    } else {
                        try self.appendParentGuardedDeclarations(
                            &declarations,
                            child_id,
                            scope,
                            selector,
                        );
                    }
                },
                .at_rule => if (!try self.atRuleHasBlock(child_id)) {
                    try self.appendInlineAtRule(&declarations, child_id, scope);
                } else if (try self.isDeclarationAtRule(child_id)) {
                    try self.appendDeclarationAtRule(&declarations, child_id, scope);
                },
                else => {},
            }
        }
        if (declarations.items.len > 0) {
            const merged_declarations = try self.mergeDeclarationsOwned(declarations.items);
            defer self.allocator.free(merged_declarations);
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(self.allocator);
            try self.appendTemporary(&output, emitted_selector);
            try self.appendTemporary(&output, "{");
            try self.appendTemporary(&output, merged_declarations);
            try self.appendTemporary(&output, "}");
            try self.transaction.emitMapped(rule.span, null, output.items);
        } else if (!reference_only) {
            var has_imported_child = false;
            for (block_children) |child_id| {
                const child = self.document.get(child_id) catch return error.InvalidDocument;
                if (!child.span.source.eql(rule.span.source) and
                    !self.reference_nodes.contains(child_id))
                {
                    has_imported_child = true;
                    break;
                }
            }
            if (has_imported_child) {
                const empty_rule = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}{{}}",
                    .{emitted_selector},
                );
                defer self.allocator.free(empty_rule);
                try self.transaction.emitMapped(rule.span, null, empty_rule);
            }
        }

        if (reference_only) return;

        for (block_children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            switch (child.kind) {
                .rule => try self.emitRule(child_id, scope, selector),
                .at_rule => if (try self.atRuleHasBlock(child_id) and
                    !try self.isDeclarationAtRule(child_id))
                {
                    try self.emitAtRule(child_id, scope, selector);
                },
                .mixin => if (!try self.isMixinDefinition(child_id)) {
                    const mixin_children = self.document.children(child_id) catch
                        return error.InvalidDocument;
                    if (mixin_children.len == 1) {
                        try self.emitCallableNested(child_id, scope, selector);
                    } else if (!try self.isParentSelectorMixin(child_id)) {
                        try self.emitRule(child_id, scope, selector);
                    }
                } else if (try self.mixinDefinitionEmitsRule(child_id)) {
                    try self.emitRule(child_id, scope, selector);
                },
                else => {},
            }
        }
    }

    fn registerNestedRuleAliases(
        self: *Engine,
        children: []const native_syntax.NodeId,
        scope: Scope,
        prefix: []const u8,
        visible_scope: usize,
    ) Error!void {
        const compact_prefix = try compactMixinSelectorOwned(self.allocator, prefix);
        defer self.allocator.free(compact_prefix);
        if (compact_prefix.len == 0 or std.mem.indexOfScalar(u8, compact_prefix, ',') != null) {
            return;
        }
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            if (child.kind != .rule and child.kind != .mixin) continue;
            const child_nodes = self.document.children(child_id) catch
                return error.InvalidDocument;
            if (child_nodes.len < 2 or child_nodes.len > 3) continue;
            const selector_node = self.document.get(child_nodes[0]) catch
                return error.InvalidDocument;
            const block_node = self.document.get(child_nodes[child_nodes.len - 1]) catch
                return error.InvalidDocument;
            if (selector_node.kind != .selector or selector_node.text == null or
                block_node.kind != .block) continue;
            const raw_selector = try self.sources.slice(selector_node.text.?);
            if (std.mem.indexOfScalar(u8, raw_selector, '(') != null) continue;
            const rendered = try self.renderOwned(selector_node.text.?, scope.cursor, .selector);
            defer self.allocator.free(rendered);
            const compact_child = try compactMixinSelectorOwned(self.allocator, rendered);
            defer self.allocator.free(compact_child);
            if (compact_child.len == 0 or std.mem.indexOfScalar(u8, compact_child, ',') != null) {
                continue;
            }
            const alias = try std.fmt.allocPrint(
                self.allocator,
                "{s}{s}",
                .{ compact_prefix, compact_child },
            );
            defer self.allocator.free(alias);
            var already_registered = false;
            for (self.mixins.items) |definition| {
                if (definition.block.value == child_nodes[child_nodes.len - 1].value and
                    definition.visible_scope == visible_scope and
                    std.mem.eql(u8, definition.name, alias))
                {
                    already_registered = true;
                    break;
                }
            }
            if (!already_registered) {
                const owned_name = try self.values.own(.{ .string = .{ .bytes = alias } });
                var guard: ?native_source.Span = null;
                if (child_nodes.len == 3) {
                    const guard_node = self.document.get(child_nodes[1]) catch
                        return error.InvalidDocument;
                    guard = guard_node.text;
                }
                try self.mixins.append(self.allocator, .{
                    .name = owned_name.string.bytes,
                    .signature = selector_node.text.?,
                    .guard = guard,
                    .block = child_nodes[child_nodes.len - 1],
                    .scope = scope,
                    .visible_scope = visible_scope,
                });
            }
            const nested_children = self.document.children(
                child_nodes[child_nodes.len - 1],
            ) catch return error.InvalidDocument;
            const nested_scope = try self.prepareScope(nested_children, scope);
            try self.registerNestedRuleAliases(
                nested_children,
                nested_scope,
                alias,
                visible_scope,
            );
        }
    }

    fn isParentSelectorMixin(
        self: *const Engine,
        node_id: native_syntax.NodeId,
    ) Error!bool {
        const children = self.document.children(node_id) catch return error.InvalidDocument;
        if (children.len < 2) return false;
        const selector = self.document.get(children[0]) catch return error.InvalidDocument;
        if (selector.kind != .selector or selector.text == null) return false;
        return std.mem.eql(
            u8,
            std.mem.trim(u8, try self.sources.slice(selector.text.?), " \t\r\n\x0c"),
            "&",
        );
    }

    fn appendParentGuardedDeclarations(
        self: *Engine,
        output: *std.ArrayList(u8),
        node_id: native_syntax.NodeId,
        parent_scope: Scope,
        parent_selector: []const u8,
    ) Error!void {
        if (!try self.isParentSelectorMixin(node_id)) return;
        const children = self.document.children(node_id) catch return error.InvalidDocument;
        const block_children = self.document.children(children[children.len - 1]) catch
            return error.InvalidDocument;
        const scope = try self.prepareScope(block_children, parent_scope);
        if (children.len == 3) {
            const guard = self.document.get(children[1]) catch return error.InvalidDocument;
            if (guard.kind != .guard or guard.text == null) return error.InvalidDocument;
            if (!try self.guardMatches(guard.text.?, scope)) return;
        }
        for (block_children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            switch (child.kind) {
                .declaration => if (!try self.isVariableDeclaration(child_id)) {
                    try self.appendDeclaration(output, child_id, scope);
                },
                .mixin => if (!try self.isMixinDefinition(child_id)) {
                    const nested = self.document.children(child_id) catch return error.InvalidDocument;
                    if (nested.len == 1) {
                        try self.appendCallable(output, child_id, scope, parent_selector);
                    } else {
                        try self.appendParentGuardedDeclarations(
                            output,
                            child_id,
                            scope,
                            parent_selector,
                        );
                    }
                },
                .at_rule => if (!try self.atRuleHasBlock(child_id)) {
                    try self.appendInlineAtRule(output, child_id, scope);
                },
                else => {},
            }
        }
    }

    fn atRuleHasBlock(self: *const Engine, at_rule_id: native_syntax.NodeId) Error!bool {
        const children = self.document.children(at_rule_id) catch return error.InvalidDocument;
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            if (child.kind == .block) return true;
        }
        return false;
    }

    fn isDeclarationAtRule(
        self: *const Engine,
        at_rule_id: native_syntax.NodeId,
    ) Error!bool {
        return self.isAtRuleKeyword(at_rule_id, "@starting-style");
    }

    fn appendDeclarationAtRule(
        self: *Engine,
        output: *std.ArrayList(u8),
        at_rule_id: native_syntax.NodeId,
        parent_scope: Scope,
    ) Error!void {
        const at_rule = self.document.get(at_rule_id) catch return error.InvalidDocument;
        const keyword = try self.sources.slice(at_rule.text orelse return error.InvalidDocument);
        const children = self.document.children(at_rule_id) catch return error.InvalidDocument;
        var block_id: ?native_syntax.NodeId = null;
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            if (child.kind == .block) block_id = child_id;
        }
        const block_children = self.document.children(block_id orelse return error.InvalidDocument) catch
            return error.InvalidDocument;
        const scope = try self.prepareScope(block_children, parent_scope);
        var declarations: std.ArrayList(u8) = .empty;
        defer declarations.deinit(self.allocator);
        for (block_children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            if (child.kind == .declaration and !try self.isVariableDeclaration(child_id)) {
                try self.appendDeclaration(&declarations, child_id, scope);
            } else if (child.kind == .mixin and !try self.isMixinDefinition(child_id)) {
                try self.appendCallable(&declarations, child_id, scope, "");
            }
        }
        const merged = try self.mergeDeclarationsOwned(declarations.items);
        defer self.allocator.free(merged);
        try self.appendTemporary(output, keyword);
        try self.appendTemporary(output, " {");
        try self.appendTemporary(output, merged);
        try self.appendTemporary(output, "}");
    }

    fn appendInlineAtRule(
        self: *Engine,
        output: *std.ArrayList(u8),
        at_rule_id: native_syntax.NodeId,
        scope: Scope,
    ) Error!void {
        const at_rule = self.document.get(at_rule_id) catch return error.InvalidDocument;
        const keyword_span = at_rule.text orelse return error.InvalidDocument;
        const keyword = try self.sources.slice(keyword_span);
        const children = self.document.children(at_rule_id) catch return error.InvalidDocument;
        var expression: ?*const native_syntax.Node = null;
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            if (child.kind != .expression) return error.InvalidDocument;
            expression = child;
        }
        try self.appendTemporary(output, keyword);
        if (expression) |node| {
            const rendered = try self.renderOwned(
                node.text orelse return error.InvalidDocument,
                scope.cursor,
                .at_rule,
            );
            defer self.allocator.free(rendered);
            if (rendered.len > 0) {
                try self.appendTemporary(output, " ");
                try self.appendTemporary(output, rendered);
            }
        }
        try self.appendTemporary(output, ";");
    }

    fn selectorWithExtenders(
        self: *Engine,
        selector: []const u8,
        include_original: bool,
    ) Error![]u8 {
        var selectors: std.ArrayList([]u8) = .empty;
        defer {
            for (selectors.items) |item| self.allocator.free(item);
            selectors.deinit(self.allocator);
        }
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.allocator);
        var initial = try splitTopLevelAlloc(
            self.allocator,
            selector,
            .{ .start = 0, .end = selector.len },
            ',',
        );
        defer initial.deinit(self.allocator);
        for (initial.items) |range| {
            const item = try self.allocator.dupe(
                u8,
                std.mem.trim(u8, selector[range.start..range.end], " \t\r\n\x0c"),
            );
            var item_owned = true;
            errdefer if (item_owned) self.allocator.free(item);
            if (seen.contains(item)) {
                self.allocator.free(item);
                item_owned = false;
                continue;
            }
            try seen.put(self.allocator, item, {});
            try selectors.append(self.allocator, item);
            item_owned = false;
        }
        const initial_count = selectors.items.len;
        var extension_order: std.ArrayList(usize) = .empty;
        defer extension_order.deinit(self.allocator);
        for (self.extensions.items, 0..) |extension, extension_index| {
            var seen_extender = false;
            for (self.extensions.items[0..extension_index]) |earlier| {
                if (std.mem.eql(u8, earlier.extender, extension.extender)) {
                    seen_extender = true;
                    break;
                }
            }
            if (seen_extender) continue;
            for (self.extensions.items, 0..) |candidate, candidate_index| {
                if (std.mem.eql(u8, candidate.extender, extension.extender)) {
                    try extension_order.append(self.allocator, candidate_index);
                }
            }
        }
        var frontier_start: usize = 0;
        var frontier_end: usize = selectors.items.len;
        while (frontier_start < frontier_end) {
            if (selectors.items.len >= @min(self.limits.max_selectors, 10_000)) break;
            for (extension_order.items) |extension_index| {
                const extension = self.extensions.items[extension_index];
                if (extension.context != 0 and extension.context != self.extension_context) continue;
                var index = frontier_start;
                while (index < frontier_end) : (index += 1) {
                    const current = selectors.items[index];
                    if (index >= initial_count and extension.all and
                        !self.extensionTargetWasIntroduced(current, extension.target))
                    {
                        continue;
                    }
                    const generated = if (extension.all and
                        std.mem.indexOf(u8, current, extension.extender) == null)
                        try replaceAllSelectorTargetsOwned(
                            self.allocator,
                            current,
                            extension.target,
                            extension.extender,
                        )
                    else if (!extension.all and std.mem.eql(u8, current, extension.target))
                        try self.allocator.dupe(u8, extension.extender)
                    else
                        null;
                    if (generated) |item| {
                        var item_owned = true;
                        errdefer if (item_owned) self.allocator.free(item);
                        if (seen.contains(item)) {
                            self.allocator.free(item);
                            item_owned = false;
                            continue;
                        }
                        try seen.put(self.allocator, item, {});
                        try selectors.append(self.allocator, item);
                        item_owned = false;
                    }
                }
            }
            frontier_start = frontier_end;
            frontier_end = selectors.items.len;
        }
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        const output_start = if (include_original) 0 else initial_count;
        for (selectors.items[output_start..], 0..) |item, item_index| {
            if (item_index > 0) try self.appendTemporary(&output, ",");
            try self.appendTemporary(&output, item);
        }
        return try output.toOwnedSlice(self.allocator);
    }

    fn extensionTargetWasIntroduced(
        self: *const Engine,
        selector: []const u8,
        target: []const u8,
    ) bool {
        for (self.extensions.items) |source| {
            if (!selectorContainsTarget(source.extender, target)) continue;
            if (std.mem.indexOf(u8, selector, source.extender) != null) return true;
        }
        return false;
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
            const normalized = try self.normalizeImportantOwned(rendered);
            defer self.allocator.free(normalized);
            const spaced = try self.normalizeValueSpacingOwned(normalized);
            defer self.allocator.free(spaced);
            try self.appendTemporary(output, spaced);
            if (self.force_important_depth > 0 and
                !std.mem.endsWith(
                    u8,
                    std.mem.trimRight(u8, spaced, " \t\r\n\x0c"),
                    "!important",
                ))
            {
                try self.appendTemporary(output, " !important");
            }
        }
        try self.appendTemporary(output, ";");
        _ = declaration;
    }

    fn mergeDeclarationsOwned(self: *Engine, input: []const u8) Error![]u8 {
        const Entry = struct {
            name: []const u8,
            value: []u8,
        };
        var entries: std.ArrayList(Entry) = .empty;
        defer {
            for (entries.items) |entry| self.allocator.free(entry.value);
            entries.deinit(self.allocator);
        }
        var start: usize = 0;
        while (start < input.len) {
            const semicolon = findTopLevelByte(
                input,
                .{ .start = start, .end = input.len },
                ';',
            ) orelse input.len;
            const statement = trimByteRange(input, .{ .start = start, .end = semicolon });
            start = @min(semicolon + 1, input.len);
            if (statement.start == statement.end) continue;
            const colon = findTopLevelByte(input, statement, ':') orelse {
                const raw_statement = std.mem.trim(
                    u8,
                    input[statement.start..statement.end],
                    " \t\r\n\x0c",
                );
                if (!std.mem.startsWith(u8, raw_statement, "@")) return error.InvalidDocument;
                const owned_value = try self.allocator.dupe(u8, "");
                var value_stored = false;
                errdefer if (!value_stored) self.allocator.free(owned_value);
                try entries.append(self.allocator, .{
                    .name = raw_statement,
                    .value = owned_value,
                });
                value_stored = true;
                continue;
            };
            var name = std.mem.trim(u8, input[statement.start..colon], " \t\r\n\x0c");
            const value = std.mem.trim(u8, input[colon + 1 .. statement.end], " \t\r\n\x0c");
            const space_merge = std.mem.endsWith(u8, name, "+_");
            const comma_merge = !space_merge and std.mem.endsWith(u8, name, "+");
            if (space_merge) name = name[0 .. name.len - 2];
            if (comma_merge) name = name[0 .. name.len - 1];
            if (space_merge or comma_merge) {
                var index = entries.items.len;
                while (index > 0) {
                    index -= 1;
                    if (!std.mem.eql(u8, entries.items[index].name, name)) continue;
                    const combined = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}{s}{s}",
                        .{ entries.items[index].value, if (space_merge) " " else ", ", value },
                    );
                    defer self.allocator.free(combined);
                    const normalized = try self.normalizeImportantOwned(combined);
                    defer self.allocator.free(normalized);
                    const spaced = try self.normalizeValueSpacingOwned(normalized);
                    self.allocator.free(entries.items[index].value);
                    entries.items[index].value = spaced;
                    break;
                } else {
                    const owned_value = try self.allocator.dupe(u8, value);
                    var value_stored = false;
                    errdefer if (!value_stored) self.allocator.free(owned_value);
                    try entries.append(self.allocator, .{
                        .name = name,
                        .value = owned_value,
                    });
                    value_stored = true;
                }
            } else {
                const owned_value = try self.allocator.dupe(u8, value);
                var value_stored = false;
                errdefer if (!value_stored) self.allocator.free(owned_value);
                try entries.append(self.allocator, .{
                    .name = name,
                    .value = owned_value,
                });
                value_stored = true;
            }
        }
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        for (entries.items, 0..) |entry, entry_index| {
            var duplicate_later = false;
            for (entries.items[entry_index + 1 ..]) |later| {
                if (std.mem.eql(u8, entry.name, later.name) and
                    std.mem.eql(u8, entry.value, later.value))
                {
                    duplicate_later = true;
                    break;
                }
            }
            if (duplicate_later) continue;
            try self.appendTemporary(&output, entry.name);
            if (!std.mem.startsWith(u8, entry.name, "@")) {
                try self.appendTemporary(&output, ":");
                try self.appendTemporary(&output, entry.value);
            }
            try self.appendTemporary(&output, ";");
        }
        return try output.toOwnedSlice(self.allocator);
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
        const output_start = output.items.len;
        if (mixinCallNeedsQualifiedLookup(raw)) {
            const qualified = try self.resolveQualifiedMixin(raw, caller_scope);
            try self.appendMixin(
                output,
                qualified.name,
                expression.text.?,
                qualified.scope,
                parent_selector,
                qualified.exact_scope,
            );
        } else {
            const name = callableName(raw) orelse {
                if (functionArguments(raw, "each") != null) {
                    return self.appendEach(output, expression.text.?, caller_scope, parent_selector);
                }
                return error.InvalidDocument;
            };
            if (name[0] == '@') {
                try self.appendDetached(output, name, expression.text.?, caller_scope, parent_selector);
            } else {
                try self.appendMixin(
                    output,
                    name,
                    expression.text.?,
                    caller_scope,
                    parent_selector,
                    null,
                );
            }
        }
        if (std.mem.endsWith(
            u8,
            std.mem.trim(u8, raw, " \t\r\n\x0c;"),
            "!important",
        ) and output.items.len > output_start) {
            const important = try self.addImportantToDeclarationsOwned(output.items[output_start..]);
            defer self.allocator.free(important);
            output.shrinkRetainingCapacity(output_start);
            try self.appendTemporary(output, important);
        }
    }

    fn addImportantToDeclarationsOwned(
        self: *Engine,
        declarations: []const u8,
    ) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var cursor: usize = 0;
        while (cursor < declarations.len) {
            const semicolon = findTopLevelByte(
                declarations,
                .{ .start = cursor, .end = declarations.len },
                ';',
            ) orelse declarations.len;
            const statement = std.mem.trimRight(
                u8,
                declarations[cursor..semicolon],
                " \t\r\n\x0c",
            );
            try self.appendTemporary(&output, statement);
            if (statement.len > 0 and
                !std.mem.endsWith(u8, statement, "!important"))
            {
                try self.appendTemporary(&output, " !important");
            }
            if (semicolon < declarations.len) try self.appendTemporary(&output, ";");
            cursor = @min(semicolon + 1, declarations.len);
        }
        return try output.toOwnedSlice(self.allocator);
    }

    const QualifiedMixin = struct {
        name: []const u8,
        scope: Scope,
        exact_scope: ?usize,
    };

    fn resolveQualifiedMixin(
        self: *Engine,
        raw: []const u8,
        caller_scope: Scope,
    ) Error!QualifiedMixin {
        const prefix_end = std.mem.lastIndexOfScalar(u8, raw, '(') orelse
            (std.mem.indexOfScalar(u8, raw, ';') orelse raw.len);
        const prefix = std.mem.trim(u8, raw[0..prefix_end], " \t\r\n\x0c");
        var iterator = std.mem.splitScalar(u8, prefix, '>');
        var scope = caller_scope;
        var exact_scope: ?usize = null;
        var segment = iterator.next() orelse return error.InvalidDocument;
        while (iterator.next()) |next_segment| {
            const namespace_name = std.mem.trim(u8, segment, " \t\r\n\x0c");
            const merged_scope = try self.resolveNamespace(namespace_name, scope) orelse
                return error.UndefinedMixin;
            scope = merged_scope;
            exact_scope = merged_scope.id;
            segment = next_segment;
        }
        var name = std.mem.trim(u8, segment, " \t\r\n\x0c");
        if (name.len == 0) return error.InvalidDocument;
        while (self.lookupMixin(scope, name) == null) {
            var split: ?usize = null;
            var index: usize = 1;
            while (index < name.len) : (index += 1) {
                if (name[index] != '.' and name[index] != '#') continue;
                const candidate = std.mem.trim(u8, name[0..index], " \t\r\n\x0c");
                if (self.lookupMixin(scope, candidate) != null) {
                    split = index;
                    break;
                }
            }
            const boundary = split orelse break;
            const namespace_name = std.mem.trim(u8, name[0..boundary], " \t\r\n\x0c");
            const nested_scope = try self.resolveNamespace(namespace_name, scope) orelse break;
            scope = nested_scope;
            exact_scope = nested_scope.id;
            name = name[boundary..];
        }
        return .{ .name = name, .scope = scope, .exact_scope = exact_scope };
    }

    fn resolveNamespace(
        self: *Engine,
        name: []const u8,
        caller_scope: Scope,
    ) Error!?Scope {
        var merged_scope = try self.createChildScope(caller_scope);
        var found = false;
        var seen_blocks: std.AutoHashMapUnmanaged(native_syntax.NodeId, void) = .empty;
        defer seen_blocks.deinit(self.allocator);
        const definition_count = self.mixins.items.len;
        var definition_index: usize = 0;
        while (definition_index < definition_count) : (definition_index += 1) {
            const definition = self.mixins.items[definition_index];
            if (!std.mem.eql(u8, definition.name, name) or
                !self.scopeVisible(definition.visible_scope, caller_scope.id) or
                seen_blocks.contains(definition.block)) continue;
            if (!try self.namespaceDefinitionMatches(definition, caller_scope)) continue;
            try seen_blocks.put(self.allocator, definition.block, {});
            try self.scope_fallbacks.put(
                self.allocator,
                merged_scope.cursor,
                definition.scope.cursor,
            );
            if (!try self.bindNamespaceDefaults(definition, &merged_scope)) continue;
            const children = self.document.children(definition.block) catch
                return error.InvalidDocument;
            try self.populateScope(children, &merged_scope);
            found = true;
        }
        return if (found) merged_scope else null;
    }

    fn namespaceDefinitionMatches(
        self: *Engine,
        definition: MixinDefinition,
        caller_scope: Scope,
    ) Error!bool {
        var candidate = try self.createChildScope(definition.scope);
        try self.scope_fallbacks.put(
            self.allocator,
            candidate.cursor,
            caller_scope.cursor,
        );
        if (!try self.bindNamespaceDefaults(definition, &candidate)) return false;
        const children = self.document.children(definition.block) catch
            return error.InvalidDocument;
        try self.populateScope(children, &candidate);
        try self.scope_fallbacks.put(
            self.allocator,
            candidate.cursor,
            caller_scope.cursor,
        );
        if (definition.guard) |guard| return self.guardMatches(guard, candidate);
        return true;
    }

    fn bindNamespaceDefaults(
        self: *Engine,
        definition: MixinDefinition,
        scope: *Scope,
    ) Error!bool {
        const signature_raw = try self.sources.slice(definition.signature);
        const signature_clean = try blankCommentsOwned(self.allocator, signature_raw);
        defer self.allocator.free(signature_clean);
        const arguments = callableArguments(signature_clean) orelse {
            try self.addResolvedBinding("@arguments", "", scope);
            return true;
        };
        const delimiter: u8 = if (containsTopLevel(
            signature_clean[arguments.start..arguments.end],
            ';',
        )) ';' else ',';
        var parameters = try splitTopLevelAlloc(
            self.allocator,
            signature_clean,
            arguments,
            delimiter,
        );
        defer parameters.deinit(self.allocator);
        for (parameters.items) |parameter_range| {
            const parameter = trimByteRange(signature_clean, parameter_range);
            if (parameter.start == parameter.end) continue;
            const colon = findTopLevelByte(signature_clean, parameter, ':');
            const name_range = trimByteRange(signature_clean, .{
                .start = parameter.start,
                .end = colon orelse parameter.end,
            });
            var variable_name: []const u8 = signature_clean[name_range.start..name_range.end];
            const variadic = std.mem.endsWith(u8, variable_name, "...");
            if (variadic) variable_name = std.mem.trimRight(
                u8,
                variable_name[0 .. variable_name.len - 3],
                " \t\r\n\x0c",
            );
            if (variable_name.len == 0 or variable_name[0] != '@') return false;
            const normalized_name = try normalizeVariableName(variable_name);
            if (colon) |colon_index| {
                const default_range = trimByteRange(signature_clean, .{
                    .start = colon_index + 1,
                    .end = parameter.end,
                });
                const default_span = try self.relativeSpan(
                    definition.signature,
                    @intCast(default_range.start),
                    @intCast(default_range.end),
                );
                const rendered = try self.renderOwned(
                    default_span,
                    scope.cursor,
                    .binding_value,
                );
                defer self.allocator.free(rendered);
                try self.addResolvedBinding(normalized_name, rendered, scope);
            } else if (variadic) {
                try self.addResolvedBinding(normalized_name, "", scope);
            } else {
                return false;
            }
        }
        try self.addResolvedBinding("@arguments", "", scope);
        return true;
    }

    fn appendEach(
        self: *Engine,
        output: *std.ArrayList(u8),
        call_span: native_source.Span,
        caller_scope: Scope,
        parent_selector: []const u8,
    ) Error!void {
        const raw = try self.sources.slice(call_span);
        const arguments = functionArguments(raw, "each") orelse return error.InvalidDocument;
        const argument_raw = raw[arguments.start..arguments.end];
        const delimiter: u8 = if (containsTopLevel(argument_raw, ';')) ';' else ',';
        var parts = try splitTopLevelAlloc(self.allocator, raw, arguments, delimiter);
        defer parts.deinit(self.allocator);
        if (parts.items.len != 2) return error.InvalidDocument;
        const values_range = trimByteRange(raw, parts.items[0]);
        const body_range = trimByteRange(raw, parts.items[1]);
        const values_span = try self.relativeSpan(
            call_span,
            @intCast(values_range.start),
            @intCast(values_range.end),
        );
        const body_span = try self.relativeSpan(
            call_span,
            @intCast(body_range.start),
            @intCast(body_range.end),
        );
        const block = self.findBlockWithin(body_span) orelse return error.InvalidDocument;
        const block_children = self.document.children(block) catch return error.InvalidDocument;
        const raw_values = std.mem.trim(
            u8,
            raw[values_range.start..values_range.end],
            " \t\r\n\x0c",
        );
        var map_keys: std.ArrayList([]u8) = .empty;
        defer {
            for (map_keys.items) |key| self.allocator.free(key);
            map_keys.deinit(self.allocator);
        }
        var map_rendered: ?[]u8 = null;
        defer if (map_rendered) |bytes| self.allocator.free(bytes);
        var map_block: ?native_syntax.NodeId = if (raw_values.len > 1 and raw_values[0] == '@') blk: {
            const detached = self.lookupDetached(caller_scope, raw_values) orelse break :blk null;
            break :blk detached.block;
        } else if (callableName(raw_values)) |map_name| blk: {
            var definition_index = self.mixins.items.len;
            while (definition_index > 0) {
                definition_index -= 1;
                const mixin = self.mixins.items[definition_index];
                if (!std.mem.eql(u8, mixin.name, map_name) or
                    !self.scopeVisible(mixin.visible_scope, caller_scope.id)) continue;
                const map_children = self.document.children(mixin.block) catch
                    return error.InvalidDocument;
                var has_property = false;
                for (map_children) |map_child| {
                    if (try self.isPropertyDeclaration(map_child)) {
                        has_property = true;
                        break;
                    }
                }
                if (has_property) break :blk mixin.block;
            }
            break :blk null;
        } else null;
        const initially_rendered = if (map_block == null)
            try self.renderOwned(values_span, caller_scope.cursor, .value)
        else
            try self.allocator.dupe(u8, "");
        defer self.allocator.free(initially_rendered);
        if (map_block == null and std.mem.startsWith(u8, initially_rendered, "__less_block_")) {
            const id = std.fmt.parseInt(u32, initially_rendered[13..], 10) catch
                return error.InvalidDocument;
            map_block = .{ .value = id };
        }
        if (map_block) |selected_block| {
            const map_children = self.document.children(selected_block) catch
                return error.InvalidDocument;
            var generated: std.ArrayList(u8) = .empty;
            defer generated.deinit(self.allocator);
            const map_scope = try self.prepareScope(map_children, caller_scope);
            for (map_children) |map_child_id| {
                if (!try self.isPropertyDeclaration(map_child_id)) continue;
                const declaration_children = self.document.children(map_child_id) catch
                    return error.InvalidDocument;
                if (declaration_children.len != 2) continue;
                const property_node = self.document.get(declaration_children[0]) catch
                    return error.InvalidDocument;
                const value_node = self.document.get(declaration_children[1]) catch
                    return error.InvalidDocument;
                const key = std.mem.trim(
                    u8,
                    try self.sources.slice(property_node.text orelse continue),
                    " \t\r\n\x0c",
                );
                const rendered = try self.renderOwned(
                    value_node.text orelse continue,
                    map_scope.cursor,
                    .value,
                );
                defer self.allocator.free(rendered);
                if (generated.items.len > 0) try self.appendTemporary(&generated, ",");
                try self.appendTemporary(&generated, rendered);
                try map_keys.append(self.allocator, try self.allocator.dupe(u8, key));
            }
            map_rendered = try generated.toOwnedSlice(self.allocator);
        }
        const rendered_values = if (map_rendered) |bytes|
            bytes
        else
            initially_rendered;
        var escaped_scalar = false;
        if (raw_values.len > 1 and raw_values[0] == '@') {
            if (try self.environment.lookup(caller_scope.cursor, raw_values)) |holder| {
                if (self.binding_indices.get(holder)) |binding_index| {
                    const expression = try self.sources.slice(
                        self.bindings.items[binding_index].expression,
                    );
                    escaped_scalar = functionArguments(
                        std.mem.trim(u8, expression, " \t\r\n\x0c"),
                        "e",
                    ) != null;
                }
            }
        }
        var items = if (escaped_scalar) blk: {
            var scalar: std.ArrayList(ByteRange) = .empty;
            try scalar.append(self.allocator, .{ .start = 0, .end = rendered_values.len });
            break :blk scalar;
        } else try splitLessListAlloc(self.allocator, rendered_values);
        defer items.deinit(self.allocator);

        var parameter_names: [3][]const u8 = .{ "@value", "@key", "@index" };
        const body_prefix_end = std.mem.indexOfScalar(
            u8,
            raw[body_range.start..body_range.end],
            '{',
        ) orelse 0;
        const body_prefix = std.mem.trim(
            u8,
            raw[body_range.start .. body_range.start + body_prefix_end],
            " \t\r\n\x0c",
        );
        if (callableArguments(body_prefix)) |parameter_bounds| {
            const parameter_delimiter: u8 = if (containsTopLevel(
                body_prefix[parameter_bounds.start..parameter_bounds.end],
                ';',
            )) ';' else ',';
            var parameters = try splitTopLevelAlloc(
                self.allocator,
                body_prefix,
                parameter_bounds,
                parameter_delimiter,
            );
            defer parameters.deinit(self.allocator);
            for (parameters.items[0..@min(parameters.items.len, parameter_names.len)], 0..) |range, index| {
                const candidate = std.mem.trim(
                    u8,
                    body_prefix[range.start..range.end],
                    " \t\r\n\x0c",
                );
                if (candidate.len > 1 and candidate[0] == '@') parameter_names[index] = candidate;
            }
        }

        for (items.items, 0..) |item_range, item_index| {
            const item = std.mem.trim(
                u8,
                rendered_values[item_range.start..item_range.end],
                " \t\r\n\x0c",
            );
            var invocation = try self.createChildScope(caller_scope);
            const ordinal = try std.fmt.allocPrint(self.allocator, "{d}", .{item_index + 1});
            defer self.allocator.free(ordinal);
            const key = if (item_index < map_keys.items.len) map_keys.items[item_index] else ordinal;
            try self.addResolvedBinding(parameter_names[0], item, &invocation);
            try self.addResolvedBinding(parameter_names[1], key, &invocation);
            try self.addResolvedBinding(parameter_names[2], ordinal, &invocation);
            try self.populateScope(block_children, &invocation);
            try self.appendCallableBody(output, block_children, invocation, parent_selector);
            try self.emitNestedBody(block_children, invocation, parent_selector);
        }
    }

    fn findBlockWithin(
        self: *const Engine,
        span: native_source.Span,
    ) ?native_syntax.NodeId {
        var selected: ?native_syntax.NodeId = null;
        var selected_length: u32 = 0;
        for (self.document.nodes(), 0..) |node, index| {
            if (node.kind != .block or !node.span.source.eql(span.source) or
                node.span.start < span.start or node.span.end > span.end)
            {
                continue;
            }
            const length = node.span.end - node.span.start;
            if (selected == null or length > selected_length) {
                selected = .{ .value = @intCast(index) };
                selected_length = length;
            }
        }
        return selected;
    }

    fn appendMixin(
        self: *Engine,
        output: *std.ArrayList(u8),
        name: []const u8,
        call_span: native_source.Span,
        caller_scope: Scope,
        parent_selector: []const u8,
        exact_scope: ?usize,
    ) Error!void {
        var matched = false;
        var found_definition = false;
        var matched_parameters = false;
        const allow_empty_match = self.active_call_depth > 0 or
            self.scopes.items[caller_scope.id].parent != null;
        const definition_count = self.mixins.items.len;
        const prefer_parenthesized = try self.hasParenthesizedMixin(
            name,
            caller_scope,
            exact_scope,
        );
        var has_non_default_match = false;
        var probe_index: usize = 0;
        while (probe_index < definition_count) : (probe_index += 1) {
            const definition = self.mixins.items[probe_index];
            if (!std.mem.eql(u8, definition.name, name) or
                (if (exact_scope) |required|
                    definition.visible_scope != required
                else
                    !self.scopeVisible(definition.visible_scope, caller_scope.id))) continue;
            if (try self.ruleMixinIsLocked(
                definition,
                prefer_parenthesized,
                exact_scope != null,
            )) continue;
            if (definition.guard) |guard| {
                const guard_raw = try self.sources.slice(guard);
                if (std.mem.indexOf(u8, guard_raw, "default()") != null) continue;
            }
            var probe_scope = try self.createChildScope(definition.scope);
            try self.scope_fallbacks.put(
                self.allocator,
                probe_scope.cursor,
                caller_scope.cursor,
            );
            if (!try self.bindMixinParameters(
                definition,
                call_span,
                caller_scope,
                &probe_scope,
            )) continue;
            if (definition.guard) |guard| {
                const probe_children = self.document.children(definition.block) catch
                    return error.InvalidDocument;
                try self.populateScope(probe_children, &probe_scope);
                if (!try self.guardMatches(guard, probe_scope)) continue;
            }
            has_non_default_match = true;
            break;
        }
        var definition_index: usize = 0;
        while (definition_index < definition_count) : (definition_index += 1) {
            const definition = self.mixins.items[definition_index];
            if (!std.mem.eql(u8, definition.name, name) or
                (if (exact_scope) |required|
                    definition.visible_scope != required
                else
                    !self.scopeVisible(definition.visible_scope, caller_scope.id)))
            {
                continue;
            }
            if (try self.ruleMixinIsLocked(
                definition,
                prefer_parenthesized,
                exact_scope != null,
            )) continue;
            found_definition = true;
            try self.enterCallable(call_span);
            var call_open = true;
            defer if (call_open) self.transaction.leaveCall() catch {};

            var invocation = try self.createChildScope(definition.scope);
            try self.scope_fallbacks.put(
                self.allocator,
                invocation.cursor,
                caller_scope.cursor,
            );
            if (!try self.bindMixinParameters(definition, call_span, caller_scope, &invocation)) {
                try self.transaction.leaveCall();
                call_open = false;
                continue;
            }
            matched_parameters = true;
            const block_children = self.document.children(definition.block) catch
                return error.InvalidDocument;
            const nested_mixin_start = self.mixins.items.len;
            try self.populateScope(block_children, &invocation);
            try self.scope_fallbacks.put(
                self.allocator,
                invocation.cursor,
                caller_scope.cursor,
            );
            try self.exposeNestedMixins(
                nested_mixin_start,
                invocation.id,
                caller_scope.id,
            );
            try self.unlockCallableBindings(block_children, invocation);
            if (definition.guard) |guard| {
                const guard_raw = try self.sources.slice(guard);
                const uses_default = std.mem.indexOf(u8, guard_raw, "default()") != null;
                const previous_default = self.default_guard_value;
                if (uses_default) self.default_guard_value = !has_non_default_match;
                const matches_guard = self.guardMatches(guard, invocation) catch |err| {
                    self.default_guard_value = previous_default;
                    return err;
                };
                self.default_guard_value = previous_default;
                if (!matches_guard) {
                    try self.transaction.leaveCall();
                    call_open = false;
                    continue;
                }
            }
            self.active_call_depth += 1;
            defer self.active_call_depth -= 1;
            try self.appendCallableBody(output, block_children, invocation, parent_selector);
            try self.transaction.leaveCall();
            call_open = false;
            matched = true;
        }
        if (!matched and !matched_parameters and (!found_definition or !allow_empty_match)) {
            const message = try std.fmt.allocPrint(
                self.allocator,
                "native Less mixin {s} is undefined",
                .{name},
            );
            defer self.allocator.free(message);
            try self.transaction.report(.err, .undefined_variable, call_span, message, &.{});
            return error.UndefinedMixin;
        }
    }

    fn ruleMixinIsLocked(
        self: *const Engine,
        definition: MixinDefinition,
        prefer_parenthesized: bool,
        qualified: bool,
    ) Error!bool {
        const signature = try self.sources.slice(definition.signature);
        if (std.mem.indexOfScalar(u8, signature, '(') != null) return false;
        if (prefer_parenthesized) return true;
        if (!qualified) {
            const trimmed_signature = std.mem.trim(u8, signature, " \t\r\n\x0c");
            if (callableName(trimmed_signature)) |simple_name| {
                if (std.mem.eql(u8, definition.name, simple_name) and
                    !std.mem.eql(u8, simple_name, trimmed_signature)) return true;
            } else if (std.mem.indexOf(u8, trimmed_signature, "@{") == null and
                std.mem.indexOf(u8, trimmed_signature, "${") == null and
                !mixinNameIsCompound(definition.name))
            {
                return true;
            }
        }
        for (self.active_rule_blocks.items) |block| {
            for (self.mixins.items) |active_definition| {
                if (active_definition.block.value == block.value and
                    std.mem.eql(u8, active_definition.name, definition.name))
                {
                    return true;
                }
            }
        }
        return false;
    }

    fn hasParenthesizedMixin(
        self: *const Engine,
        name: []const u8,
        caller_scope: Scope,
        exact_scope: ?usize,
    ) Error!bool {
        for (self.mixins.items) |definition| {
            if (!std.mem.eql(u8, definition.name, name) or
                (if (exact_scope) |required|
                    definition.visible_scope != required
                else
                    !self.scopeVisible(definition.visible_scope, caller_scope.id))) continue;
            const signature = try self.sources.slice(definition.signature);
            if (std.mem.indexOfScalar(u8, signature, '(') != null) return true;
        }
        return false;
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
            if (self.empty_detached_parameters.contains(name)) return;
            if (self.resolveVariable(name, call_span, caller_scope.cursor)) |resolved| {
                if (std.mem.eql(
                    u8,
                    std.mem.trim(u8, resolved, " \t\r\n\x0c"),
                    "{}",
                )) return;
            } else |_| {
                // The undefined callable diagnostic below owns this failure.
            }
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
        try self.scope_fallbacks.put(self.allocator, invocation.cursor, caller_scope.cursor);
        const block_children = self.document.children(definition.block) catch
            return error.InvalidDocument;
        const nested_mixin_start = self.mixins.items.len;
        try self.populateScope(block_children, &invocation);
        try self.scope_fallbacks.put(self.allocator, invocation.cursor, caller_scope.cursor);
        try self.exposeNestedMixins(nested_mixin_start, invocation.id, caller_scope.id);
        try self.unlockCallableBindings(block_children, invocation);
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
    ) Error!bool {
        const signature_raw = try self.sources.slice(definition.signature);
        const call_raw = try self.sources.slice(call_span);
        const signature_clean = try blankCommentsOwned(self.allocator, signature_raw);
        defer self.allocator.free(signature_clean);
        const call_clean = try blankCommentsOwned(self.allocator, call_raw);
        defer self.allocator.free(call_clean);
        const signature_arguments = callableArguments(signature_clean) orelse ByteRange{
            .start = signature_clean.len,
            .end = signature_clean.len,
        };
        const call_arguments = callableArguments(call_clean) orelse ByteRange{
            .start = call_clean.len,
            .end = call_clean.len,
        };
        const signature_delimiter: u8 = if (containsTopLevel(
            signature_clean[signature_arguments.start..signature_arguments.end],
            ';',
        )) ';' else ',';
        const call_delimiter: u8 = if (containsTopLevel(
            call_clean[call_arguments.start..call_arguments.end],
            ';',
        )) ';' else ',';
        var parameters = try splitTopLevelAlloc(
            self.allocator,
            signature_clean,
            signature_arguments,
            signature_delimiter,
        );
        defer parameters.deinit(self.allocator);
        removeEmptyRanges(signature_clean, &parameters);
        var arguments = try splitTopLevelAlloc(
            self.allocator,
            call_clean,
            call_arguments,
            call_delimiter,
        );
        defer arguments.deinit(self.allocator);
        removeEmptyRanges(call_clean, &arguments);
        var consumed = try self.allocator.alloc(bool, arguments.items.len);
        defer self.allocator.free(consumed);
        @memset(consumed, false);

        const raw_call_arguments = std.mem.trim(
            u8,
            call_raw[call_arguments.start..call_arguments.end],
            " \t\r\n\x0c",
        );
        var expanded_input: ?[]const u8 = null;
        var expanded_items: std.ArrayList(ByteRange) = .empty;
        defer expanded_items.deinit(self.allocator);
        if (std.mem.endsWith(u8, raw_call_arguments, "...") and
            raw_call_arguments.len > 4 and raw_call_arguments[0] == '@')
        {
            const expanded_name = std.mem.trimRight(
                u8,
                raw_call_arguments[0 .. raw_call_arguments.len - 3],
                " \t\r\n\x0c",
            );
            const expanded = try self.resolveVariable(
                expanded_name,
                call_span,
                caller_scope.cursor,
            );
            expanded_input = expanded;
            expanded_items = try splitLessListAlloc(self.allocator, expanded);
        }

        var bound_arguments: std.ArrayList([]u8) = .empty;
        defer {
            for (bound_arguments.items) |argument| self.allocator.free(argument);
            bound_arguments.deinit(self.allocator);
        }
        var has_named_arguments = false;
        for (arguments.items) |argument_range| {
            const candidate = trimByteRange(call_clean, argument_range);
            if (findTopLevelByte(call_clean, candidate, ':') != null) {
                has_named_arguments = true;
                break;
            }
        }

        const all_arguments = raw_call_arguments;
        const rendered_all_arguments = if (all_arguments.len == 0 or has_named_arguments)
            try self.allocator.dupe(u8, "")
        else if (std.mem.startsWith(u8, all_arguments, "{"))
            try self.allocator.dupe(u8, all_arguments)
        else if (all_arguments[0] == '@' and
            self.lookupDetached(caller_scope, all_arguments) != null)
            try self.allocator.dupe(u8, "{}")
        else if (expanded_input) |expanded|
            try self.allocator.dupe(u8, expanded)
        else blk: {
            var rendered_arguments: std.ArrayList(u8) = .empty;
            errdefer rendered_arguments.deinit(self.allocator);
            for (arguments.items, 0..) |argument_range, argument_number| {
                const argument = trimByteRange(call_clean, argument_range);
                const argument_span = try self.relativeSpan(
                    call_span,
                    @intCast(argument.start),
                    @intCast(argument.end),
                );
                const rendered = try self.renderOwned(
                    argument_span,
                    caller_scope.cursor,
                    .binding_value,
                );
                defer self.allocator.free(rendered);
                if (argument_number > 0) {
                    try self.appendTemporary(
                        &rendered_arguments,
                        if (call_delimiter == ';') "; " else ", ",
                    );
                }
                const needs_group = containsTopLevel(rendered, ',');
                if (needs_group) try self.appendTemporary(&rendered_arguments, "(");
                try self.appendTemporary(&rendered_arguments, rendered);
                if (needs_group) try self.appendTemporary(&rendered_arguments, ")");
            }
            break :blk try rendered_arguments.toOwnedSlice(self.allocator);
        };
        defer self.allocator.free(rendered_all_arguments);
        try self.addResolvedBinding("@arguments", rendered_all_arguments, invocation);

        for (parameters.items, 0..) |parameter_range, parameter_index| {
            const parameter = trimByteRange(signature_clean, parameter_range);
            const colon = findTopLevelByte(signature_clean, parameter, ':');
            const name_range = trimByteRange(
                signature_clean,
                .{ .start = parameter.start, .end = colon orelse parameter.end },
            );
            const raw_parameter_name = signature_clean[name_range.start..name_range.end];
            const variadic = std.mem.endsWith(u8, raw_parameter_name, "...");
            const variable_name = if (variadic)
                std.mem.trimRight(u8, raw_parameter_name[0 .. raw_parameter_name.len - 3], " \t")
            else
                raw_parameter_name;
            const is_variable = variable_name.len > 0 and variable_name[0] == '@';
            var argument_index: ?usize = null;
            const expanded_argument = if (expanded_input) |expanded|
                if (parameter_index < expanded_items.items.len) blk: {
                    const range = expanded_items.items[parameter_index];
                    break :blk std.mem.trim(
                        u8,
                        expanded[range.start..range.end],
                        " \t\r\n\x0c",
                    );
                } else null
            else
                null;
            if (expanded_input == null and is_variable) {
                for (arguments.items, 0..) |argument_range, candidate_index| {
                    if (consumed[candidate_index]) continue;
                    const candidate = trimByteRange(call_clean, argument_range);
                    const candidate_colon = findTopLevelByte(call_clean, candidate, ':') orelse
                        continue;
                    const candidate_name = std.mem.trim(
                        u8,
                        call_clean[candidate.start..candidate_colon],
                        " \t\r\n\x0c",
                    );
                    if (std.mem.eql(u8, candidate_name, variable_name)) {
                        argument_index = candidate_index;
                        break;
                    }
                }
            }
            if (expanded_input == null and argument_index == null) {
                for (arguments.items, 0..) |argument_range, candidate_index| {
                    if (consumed[candidate_index]) continue;
                    const candidate = trimByteRange(call_clean, argument_range);
                    if (findTopLevelByte(call_clean, candidate, ':') != null) continue;
                    argument_index = candidate_index;
                    break;
                }
            }
            if (variadic) {
                var joined: std.ArrayList(u8) = .empty;
                defer joined.deinit(self.allocator);
                for (arguments.items, 0..) |argument_range, candidate_index| {
                    if (consumed[candidate_index]) continue;
                    const candidate = trimByteRange(call_clean, argument_range);
                    const candidate_span = try self.relativeSpan(
                        call_span,
                        @intCast(candidate.start),
                        @intCast(candidate.end),
                    );
                    const rendered_candidate = try self.renderOwned(
                        candidate_span,
                        caller_scope.cursor,
                        .binding_value,
                    );
                    defer self.allocator.free(rendered_candidate);
                    if (joined.items.len > 0) try self.appendTemporary(
                        &joined,
                        if (call_delimiter == ';') "; " else ", ",
                    );
                    const needs_group = containsTopLevel(rendered_candidate, ',');
                    if (needs_group) try self.appendTemporary(&joined, "(");
                    try self.appendTemporary(&joined, rendered_candidate);
                    if (needs_group) try self.appendTemporary(&joined, ")");
                    consumed[candidate_index] = true;
                }
                if (is_variable) {
                    const name = try normalizeVariableName(variable_name);
                    try self.addResolvedBinding(name, joined.items, invocation);
                }
                try appendOwnedString(self.allocator, &bound_arguments, joined.items);
                continue;
            }
            if (is_variable) {
                if (argument_index) |selected_index| {
                    var candidate = trimByteRange(call_clean, arguments.items[selected_index]);
                    if (findTopLevelByte(call_clean, candidate, ':')) |argument_colon| {
                        candidate.start = argument_colon + 1;
                        candidate = trimByteRange(call_clean, candidate);
                    }
                    if (candidate.start < candidate.end and call_clean[candidate.start] == '{') {
                        const argument_span = try self.relativeSpan(
                            call_span,
                            @intCast(candidate.start),
                            @intCast(candidate.end),
                        );
                        const normalized_name = try normalizeVariableName(variable_name);
                        if (try self.registerDetachedArgument(
                            normalized_name,
                            argument_span,
                            caller_scope,
                            invocation.*,
                        )) {
                            consumed[selected_index] = true;
                            try self.addResolvedBinding(
                                normalized_name,
                                call_raw[candidate.start..candidate.end],
                                invocation,
                            );
                            try appendOwnedString(
                                self.allocator,
                                &bound_arguments,
                                call_raw[candidate.start..candidate.end],
                            );
                            continue;
                        }
                    }
                    const referenced_name = std.mem.trim(
                        u8,
                        call_clean[candidate.start..candidate.end],
                        " \t\r\n\x0c",
                    );
                    if (referenced_name.len > 1 and referenced_name[0] == '@') {
                        if (self.lookupDetached(caller_scope, referenced_name)) |referenced| {
                            const normalized_name = try normalizeVariableName(variable_name);
                            const owned_name = try self.values.own(.{
                                .string = .{ .bytes = normalized_name },
                            });
                            try self.detached.append(self.allocator, .{
                                .name = owned_name.string.bytes,
                                .block = referenced.block,
                                .scope = referenced.scope,
                                .visible_scope = invocation.id,
                            });
                            consumed[selected_index] = true;
                            try self.addResolvedBinding(normalized_name, "{}", invocation);
                            try appendOwnedString(self.allocator, &bound_arguments, "{}");
                            continue;
                        }
                    }
                } else if (colon) |colon_index| {
                    const default_range = trimByteRange(signature_clean, .{
                        .start = colon_index + 1,
                        .end = parameter.end,
                    });
                    if (default_range.start < default_range.end and
                        signature_clean[default_range.start] == '{')
                    {
                        const default_span = try self.relativeSpan(
                            definition.signature,
                            @intCast(default_range.start),
                            @intCast(default_range.end),
                        );
                        const normalized_name = try normalizeVariableName(variable_name);
                        if (std.mem.eql(
                            u8,
                            std.mem.trim(
                                u8,
                                signature_clean[default_range.start..default_range.end],
                                " \t\r\n\x0c",
                            ),
                            "{}",
                        )) {
                            const owned_empty_name = try self.values.own(.{
                                .string = .{ .bytes = normalized_name },
                            });
                            try self.empty_detached_parameters.put(
                                self.allocator,
                                owned_empty_name.string.bytes,
                                {},
                            );
                        }
                        if (try self.registerDetachedArgument(
                            normalized_name,
                            default_span,
                            definition.scope,
                            invocation.*,
                        )) {
                            try self.addResolvedBinding(
                                normalized_name,
                                signature_raw[default_range.start..default_range.end],
                                invocation,
                            );
                            try appendOwnedString(
                                self.allocator,
                                &bound_arguments,
                                signature_raw[default_range.start..default_range.end],
                            );
                            continue;
                        }
                    }
                }
            }
            var guard_unorderable = false;
            const rendered = if (expanded_argument) |argument| blk: {
                break :blk try self.allocator.dupe(u8, argument);
            } else if (argument_index) |selected_index| blk: {
                var argument = trimByteRange(call_clean, arguments.items[selected_index]);
                if (argument.start == argument.end) return false;
                if (findTopLevelByte(call_clean, argument, ':')) |argument_colon| {
                    argument.start = argument_colon + 1;
                    argument = trimByteRange(call_clean, argument);
                }
                guard_unorderable = isUnorderableGuardArgument(
                    call_clean[argument.start..argument.end],
                );
                const argument_span = try self.relativeSpan(
                    call_span,
                    @intCast(argument.start),
                    @intCast(argument.end),
                );
                consumed[selected_index] = true;
                break :blk try self.renderOwned(
                    argument_span,
                    caller_scope.cursor,
                    .binding_value,
                );
            } else blk: {
                const colon_index = colon orelse return false;
                const default_range = trimByteRange(signature_raw, .{
                    .start = colon_index + 1,
                    .end = parameter.end,
                });
                const default_span = try self.relativeSpan(
                    definition.signature,
                    @intCast(default_range.start),
                    @intCast(default_range.end),
                );
                break :blk try self.renderOwned(
                    default_span,
                    invocation.cursor,
                    .binding_value,
                );
            };
            defer self.allocator.free(rendered);
            try appendOwnedString(self.allocator, &bound_arguments, rendered);
            if (is_variable) {
                const name = try normalizeVariableName(variable_name);
                try self.addResolvedBinding(name, rendered, invocation);
                if (guard_unorderable) {
                    const holder = try self.environment.lookup(invocation.cursor, name) orelse
                        return error.InvalidDocument;
                    try self.guard_unorderable_bindings.put(self.allocator, holder, {});
                }
            } else if (!std.mem.eql(
                u8,
                stripQuotes(std.mem.trim(u8, rendered, " \t\r\n\x0c")),
                stripQuotes(std.mem.trim(u8, variable_name, " \t\r\n\x0c")),
            )) {
                return false;
            }
        }
        if (expanded_input != null and consumed.len == 1) consumed[0] = true;
        for (consumed) |was_consumed| if (!was_consumed) return false;
        if (has_named_arguments) {
            var normalized_arguments: std.ArrayList(u8) = .empty;
            defer normalized_arguments.deinit(self.allocator);
            for (bound_arguments.items) |argument| {
                if (normalized_arguments.items.len > 0) {
                    try self.appendTemporary(&normalized_arguments, " ");
                }
                try self.appendTemporary(&normalized_arguments, argument);
            }
            try self.addResolvedBinding("@arguments", normalized_arguments.items, invocation);
        }
        return true;
    }

    fn registerDetachedArgument(
        self: *Engine,
        name: []const u8,
        span: native_source.Span,
        definition_scope: Scope,
        visible_scope: Scope,
    ) Error!bool {
        const block = self.findBlockWithin(span) orelse return false;
        const owned_name = try self.values.own(.{ .string = .{ .bytes = name } });
        try self.detached.append(self.allocator, .{
            .name = owned_name.string.bytes,
            .block = block,
            .scope = definition_scope,
            .visible_scope = visible_scope.id,
        });
        return true;
    }

    fn addResolvedBinding(
        self: *Engine,
        name: []const u8,
        rendered: []const u8,
        scope: *Scope,
    ) Error!void {
        const owned_name = try self.values.own(.{ .string = .{ .bytes = name } });
        const stable_name = owned_name.string.bytes;
        const holder = try self.values.own(.{ .string = .{ .bytes = rendered } });
        const binding_index = self.bindings.items.len;
        try self.bindings.append(self.allocator, .{
            .holder = holder,
            .name = stable_name,
            .expression = (self.document.get(self.document.root) catch
                return error.InvalidDocument).span,
            .definition_scope = scope.cursor,
            .state = .resolved,
            .resolved = holder,
        });
        try self.binding_indices.put(self.allocator, holder, binding_index);
        const previous_cursor = scope.cursor;
        scope.cursor = try self.environment.set(scope.cursor, stable_name, holder);
        if (self.scope_fallbacks.get(previous_cursor)) |fallback| {
            try self.scope_fallbacks.put(self.allocator, scope.cursor, fallback);
        }
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
                    const nested = self.document.children(child_id) catch
                        return error.InvalidDocument;
                    if (nested.len == 1) {
                        try self.appendCallable(output, child_id, scope, parent_selector);
                    } else {
                        try self.appendParentGuardedDeclarations(
                            output,
                            child_id,
                            scope,
                            parent_selector,
                        );
                    }
                },
                .comment, .detached_ruleset, .extend, .rule, .at_rule => {},
                else => return error.InvalidDocument,
            }
        }
    }

    fn unlockCallableBindings(
        self: *Engine,
        children: []const native_syntax.NodeId,
        scope: Scope,
    ) Error!void {
        for (children) |child_id| {
            if (!try self.isVariableDeclaration(child_id)) continue;
            const declaration_children = self.document.children(child_id) catch
                return error.InvalidDocument;
            const name_node = self.document.get(declaration_children[0]) catch
                return error.InvalidDocument;
            const name = try normalizeVariableName(try self.sources.slice(
                name_node.text orelse return error.InvalidDocument,
            ));
            const holder = try self.environment.lookup(scope.cursor, name) orelse continue;
            try self.unlocked_bindings.put(self.allocator, name, holder);
        }
    }

    fn exposeNestedMixins(
        self: *Engine,
        start: usize,
        invocation_scope: usize,
        caller_scope: usize,
    ) Error!void {
        const end = self.mixins.items.len;
        var index = start;
        while (index < end) : (index += 1) {
            self.mixins.items[index].visible_scope = invocation_scope;
            if (caller_scope != invocation_scope) {
                var exported = self.mixins.items[index];
                exported.visible_scope = caller_scope;
                try self.mixins.append(self.allocator, exported);
            }
        }
    }

    fn emitCallableNested(
        self: *Engine,
        call_id: native_syntax.NodeId,
        caller_scope: Scope,
        parent_selector: []const u8,
    ) Error!void {
        const children = self.document.children(call_id) catch return error.InvalidDocument;
        if (children.len != 1) return error.InvalidDocument;
        const expression = self.document.get(children[0]) catch return error.InvalidDocument;
        if (expression.kind != .expression or expression.text == null) {
            return error.InvalidDocument;
        }
        const raw = try self.sources.slice(expression.text.?);
        const force_important = std.mem.endsWith(
            u8,
            std.mem.trim(u8, raw, " \t\r\n\x0c;"),
            "!important",
        );
        if (force_important) self.force_important_depth += 1;
        defer {
            if (force_important) self.force_important_depth -= 1;
        }
        var lookup_scope = caller_scope;
        var exact_scope: ?usize = null;
        const direct_name = callableName(raw) orelse {
            if (functionArguments(raw, "each") != null) return;
            return error.InvalidDocument;
        };
        const name = if (mixinCallNeedsQualifiedLookup(raw)) blk: {
            const qualified = try self.resolveQualifiedMixin(raw, caller_scope);
            lookup_scope = qualified.scope;
            exact_scope = qualified.exact_scope;
            break :blk qualified.name;
        } else direct_name;
        if (name[0] == '@') {
            const definition = self.lookupDetached(lookup_scope, name) orelse return;
            const block_children = self.document.children(definition.block) catch
                return error.InvalidDocument;
            if (!try self.hasNestedOutput(block_children)) return;
            try self.enterCallable(expression.text.?);
            var call_open = true;
            defer if (call_open) self.transaction.leaveCall() catch {};
            var invocation = try self.createChildScope(definition.scope);
            try self.scope_fallbacks.put(self.allocator, invocation.cursor, caller_scope.cursor);
            const nested_mixin_start = self.mixins.items.len;
            try self.populateScope(block_children, &invocation);
            try self.scope_fallbacks.put(self.allocator, invocation.cursor, caller_scope.cursor);
            try self.exposeNestedMixins(
                nested_mixin_start,
                invocation.id,
                caller_scope.id,
            );
            try self.unlockCallableBindings(block_children, invocation);
            try self.emitNestedBody(block_children, invocation, parent_selector);
            try self.transaction.leaveCall();
            call_open = false;
            return;
        }
        const definition_count = self.mixins.items.len;
        const prefer_parenthesized = try self.hasParenthesizedMixin(
            name,
            lookup_scope,
            exact_scope,
        );
        var definition_index: usize = 0;
        while (definition_index < definition_count) : (definition_index += 1) {
            const definition = self.mixins.items[definition_index];
            if (!std.mem.eql(u8, definition.name, name) or
                (if (exact_scope) |required|
                    definition.visible_scope != required
                else
                    !self.scopeVisible(definition.visible_scope, lookup_scope.id))) continue;
            if (try self.ruleMixinIsLocked(
                definition,
                prefer_parenthesized,
                exact_scope != null,
            )) continue;
            const block_children = self.document.children(definition.block) catch
                return error.InvalidDocument;
            if (!try self.hasNestedOutput(block_children)) continue;
            try self.enterCallable(expression.text.?);
            var call_open = true;
            defer if (call_open) self.transaction.leaveCall() catch {};
            var invocation = try self.createChildScope(definition.scope);
            try self.scope_fallbacks.put(
                self.allocator,
                invocation.cursor,
                caller_scope.cursor,
            );
            if (!try self.bindMixinParameters(
                definition,
                expression.text.?,
                lookup_scope,
                &invocation,
            )) {
                try self.transaction.leaveCall();
                call_open = false;
                continue;
            }
            const nested_mixin_start = self.mixins.items.len;
            try self.populateScope(block_children, &invocation);
            try self.scope_fallbacks.put(
                self.allocator,
                invocation.cursor,
                caller_scope.cursor,
            );
            try self.exposeNestedMixins(
                nested_mixin_start,
                invocation.id,
                caller_scope.id,
            );
            try self.unlockCallableBindings(block_children, invocation);
            if (definition.guard) |guard| {
                if (!try self.guardMatches(guard, invocation)) {
                    try self.transaction.leaveCall();
                    call_open = false;
                    continue;
                }
            }
            try self.emitNestedBody(block_children, invocation, parent_selector);
            try self.transaction.leaveCall();
            call_open = false;
        }
    }

    fn hasNestedOutput(
        self: *const Engine,
        children: []const native_syntax.NodeId,
    ) Error!bool {
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            if (child.kind == .rule or child.kind == .at_rule) return true;
            if (child.kind == .mixin and try self.mixinDefinitionEmitsRule(child_id)) return true;
            if (child.kind == .mixin and !try self.isMixinDefinition(child_id)) return true;
        }
        return false;
    }

    fn emitNestedBody(
        self: *Engine,
        children: []const native_syntax.NodeId,
        scope: Scope,
        parent_selector: []const u8,
    ) Error!void {
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            switch (child.kind) {
                .rule => try self.emitRule(child_id, scope, parent_selector),
                .at_rule => try self.emitAtRule(child_id, scope, parent_selector),
                .mixin => if (!try self.isMixinDefinition(child_id)) {
                    const nested = self.document.children(child_id) catch
                        return error.InvalidDocument;
                    if (nested.len == 1) {
                        try self.emitCallableNested(child_id, scope, parent_selector);
                    } else if (!try self.isParentSelectorMixin(child_id)) {
                        try self.emitRule(child_id, scope, parent_selector);
                    }
                } else if (try self.mixinDefinitionEmitsRule(child_id)) {
                    try self.emitRule(child_id, scope, parent_selector);
                },
                else => {},
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
                if (definition.visible_scope == current and std.mem.eql(u8, definition.name, name)) {
                    return definition;
                }
            }
            scope_id = self.scopes.items[current].parent;
        }
        return null;
    }

    fn scopeVisible(self: *const Engine, definition_scope: usize, caller_scope: usize) bool {
        var current: ?usize = caller_scope;
        while (current) |scope_id| {
            if (scope_id == definition_scope) return true;
            current = self.scopes.items[scope_id].parent;
        }
        return false;
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
                if (definition.visible_scope == current and std.mem.eql(u8, definition.name, name)) {
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
        if (self.reference_nodes.contains(at_rule_id)) return;
        const effective_parent = if (parent_selector) |selector|
            if (selector.len == 0) null else selector
        else
            null;
        if (self.deferred_media) |deferred| {
            if (try self.isAtRuleKeyword(at_rule_id, "@media")) {
                const owned_parent = if (effective_parent) |selector|
                    try self.allocator.dupe(u8, selector)
                else
                    null;
                errdefer if (owned_parent) |selector| self.allocator.free(selector);
                try deferred.append(self.allocator, .{
                    .id = at_rule_id,
                    .scope = scope,
                    .parent_selector = owned_parent,
                });
                return;
            }
        }
        return self.emitAtRuleInternal(at_rule_id, scope, effective_parent, true);
    }

    fn emitAtRuleInternal(
        self: *Engine,
        at_rule_id: native_syntax.NodeId,
        scope: Scope,
        parent_selector: ?[]const u8,
        emit_keyword_comments: bool,
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
        var prelude = try self.renderAtRulePrelude(keyword, expression, scope.cursor);
        defer prelude.deinit(self.allocator);

        var header: std.ArrayList(u8) = .empty;
        defer header.deinit(self.allocator);
        try self.appendTemporary(&header, keyword);
        if (prelude.text().len > 0) {
            try self.appendTemporary(&header, " ");
            try self.appendTemporary(&header, prelude.text());
        }
        if (block_id == null) {
            try self.appendTemporary(&header, ";");
            try self.transaction.emitMapped(at_rule.span, null, header.items);
            if (emit_keyword_comments) {
                try self.emitAtRulePreludeComments(expression, &prelude);
            }
            return;
        }
        const previous_extension_context = self.extension_context;
        self.extension_context = extendContext(previous_extension_context, at_rule_id);
        defer self.extension_context = previous_extension_context;

        const block_children = self.document.children(block_id.?) catch
            return error.InvalidDocument;
        if (block_children.len == 0) {
            if (!std.mem.endsWith(u8, keyword, "keyframes")) return;
            if (prelude.text().len > 0) try self.appendTemporary(&header, " ");
            try self.appendTemporary(&header, "{}");
            try self.transaction.emitMapped(at_rule.span, null, header.items);
            return;
        }

        if (native_lexer.identifierEqlIgnoreCaseAscii(keyword, "@media") and
            block_children.len == 1 and
            try self.isAtRuleKeyword(block_children[0], "@media"))
        {
            const outer_scope = try self.prepareScope(block_children, scope);
            try self.emitCombinedNestedMedia(
                at_rule.span,
                prelude.text(),
                block_children[0],
                outer_scope,
                parent_selector,
            );
            return;
        }

        const block_scope = try self.prepareScope(block_children, scope);
        const flatten_nested_media = native_lexer.identifierEqlIgnoreCaseAscii(keyword, "@media");
        const emit_wrapper = !flatten_nested_media or
            try self.hasDirectMediaOutput(block_children, block_scope, 0);
        if (emit_wrapper) {
            try self.appendTemporary(&header, " ");
            try self.appendTemporary(&header, "{");
            try self.transaction.emitMapped(at_rule.span, null, header.items);
            if (emit_keyword_comments) {
                try self.emitAtRulePreludeComments(expression, &prelude);
            }
        }
        var deferred_media: std.ArrayList(DeferredMedia) = .empty;
        defer {
            for (deferred_media.items) |deferred| {
                if (deferred.parent_selector) |selector| self.allocator.free(selector);
            }
            deferred_media.deinit(self.allocator);
        }
        const previous_deferred = self.deferred_media;
        if (flatten_nested_media) self.deferred_media = &deferred_media;
        self.emitAtRuleStatements(block_children, block_scope, parent_selector) catch |err| {
            self.deferred_media = previous_deferred;
            return err;
        };
        self.deferred_media = previous_deferred;
        if (emit_wrapper) try self.transaction.emit("}");
        if (flatten_nested_media) {
            for (deferred_media.items) |deferred| {
                try self.emitCombinedNestedMedia(
                    at_rule.span,
                    prelude.text(),
                    deferred.id,
                    deferred.scope,
                    deferred.parent_selector,
                );
            }
        }
    }

    fn emitCombinedNestedMedia(
        self: *Engine,
        outer_span: native_source.Span,
        outer_prelude: []const u8,
        inner_id: native_syntax.NodeId,
        scope: Scope,
        parent_selector: ?[]const u8,
    ) Error!void {
        const inner = self.document.get(inner_id) catch return error.InvalidDocument;
        const children = self.document.children(inner_id) catch return error.InvalidDocument;
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
        const inner_block = block_id orelse return error.InvalidDocument;
        const previous_extension_context = self.extension_context;
        self.extension_context = extendContext(previous_extension_context, inner_id);
        defer self.extension_context = previous_extension_context;
        var inner_prelude = try self.renderAtRulePrelude("@media", expression, scope.cursor);
        defer inner_prelude.deinit(self.allocator);
        var combined_prelude: std.ArrayList(u8) = .empty;
        defer combined_prelude.deinit(self.allocator);
        try self.appendTemporary(&combined_prelude, outer_prelude);
        try self.appendTemporary(&combined_prelude, " and ");
        try self.appendTemporary(&combined_prelude, inner_prelude.text());
        var header: std.ArrayList(u8) = .empty;
        defer header.deinit(self.allocator);
        try self.appendTemporary(&header, "@media ");
        try self.appendTemporary(&header, combined_prelude.items);
        try self.appendTemporary(&header, " {");
        const statements = self.document.children(inner_block) catch return error.InvalidDocument;
        const inner_scope = try self.prepareScope(statements, scope);
        const emit_wrapper = try self.hasDirectMediaOutput(statements, inner_scope, 0);
        if (emit_wrapper) try self.transaction.emitMapped(outer_span, null, header.items);
        var deferred_media: std.ArrayList(DeferredMedia) = .empty;
        defer {
            for (deferred_media.items) |deferred| {
                if (deferred.parent_selector) |selector| self.allocator.free(selector);
            }
            deferred_media.deinit(self.allocator);
        }
        const previous_deferred = self.deferred_media;
        self.deferred_media = &deferred_media;
        self.emitAtRuleStatements(statements, inner_scope, parent_selector) catch |err| {
            self.deferred_media = previous_deferred;
            return err;
        };
        self.deferred_media = previous_deferred;
        if (emit_wrapper) try self.transaction.emit("}");
        for (deferred_media.items) |deferred| {
            try self.emitCombinedNestedMedia(
                outer_span,
                combined_prelude.items,
                deferred.id,
                deferred.scope,
                deferred.parent_selector,
            );
        }
        _ = inner;
    }

    fn hasDirectMediaOutput(
        self: *Engine,
        children: []const native_syntax.NodeId,
        scope: Scope,
        depth: u16,
    ) Error!bool {
        if (depth >= self.limits.max_expression_depth) return true;
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            switch (child.kind) {
                .declaration => if (!try self.isVariableDeclaration(child_id)) {
                    return true;
                },
                .at_rule => if (!try self.isAtRuleKeyword(child_id, "@media")) {
                    return true;
                },
                .rule => {
                    const rule_children = self.document.children(child_id) catch
                        return error.InvalidDocument;
                    if (rule_children.len < 2) return error.InvalidDocument;
                    const block_children = self.document.children(
                        rule_children[rule_children.len - 1],
                    ) catch return error.InvalidDocument;
                    if (try self.hasDirectMediaOutput(block_children, scope, depth + 1)) {
                        return true;
                    }
                },
                .mixin => if (try self.isMixinDefinition(child_id)) {
                    if (!try self.mixinDefinitionEmitsRule(child_id)) continue;
                    const definition_children = self.document.children(child_id) catch
                        return error.InvalidDocument;
                    const block_children = self.document.children(
                        definition_children[definition_children.len - 1],
                    ) catch return error.InvalidDocument;
                    if (try self.hasDirectMediaOutput(block_children, scope, depth + 1)) {
                        return true;
                    }
                } else {
                    const call_children = self.document.children(child_id) catch
                        return error.InvalidDocument;
                    if (call_children.len != 1) return true;
                    const expression = self.document.get(call_children[0]) catch
                        return error.InvalidDocument;
                    const raw = try self.sources.slice(expression.text orelse
                        return error.InvalidDocument);
                    const name = callableName(raw) orelse return true;
                    if (name[0] == '@') {
                        const definition = self.lookupDetached(scope, name) orelse return true;
                        const block_children = self.document.children(definition.block) catch
                            return error.InvalidDocument;
                        if (try self.hasDirectMediaOutput(
                            block_children,
                            definition.scope,
                            depth + 1,
                        )) return true;
                        continue;
                    }
                    var found = false;
                    const definition_count = self.mixins.items.len;
                    var definition_index: usize = 0;
                    while (definition_index < definition_count) : (definition_index += 1) {
                        const definition = self.mixins.items[definition_index];
                        if (!std.mem.eql(u8, definition.name, name) or
                            !self.scopeVisible(definition.visible_scope, scope.id)) continue;
                        var invocation = try self.createChildScope(definition.scope);
                        try self.scope_fallbacks.put(
                            self.allocator,
                            invocation.cursor,
                            scope.cursor,
                        );
                        if (!try self.bindMixinParameters(
                            definition,
                            expression.text.?,
                            scope,
                            &invocation,
                        )) continue;
                        const block_children = self.document.children(definition.block) catch
                            return error.InvalidDocument;
                        try self.populateScope(block_children, &invocation);
                        found = true;
                        if (try self.hasDirectMediaOutput(
                            block_children,
                            invocation,
                            depth + 1,
                        )) return true;
                    }
                    if (!found) return true;
                },
                .detached_ruleset, .extend, .comment => {},
                else => return true,
            }
        }
        return false;
    }

    fn renderAtRulePrelude(
        self: *Engine,
        keyword: []const u8,
        expression: ?*const native_syntax.Node,
        scope: native_environment.ScopeId,
    ) Error!AtRulePrelude {
        const rendered = if (expression) |node|
            try self.renderOwned(
                node.text orelse return error.InvalidDocument,
                scope,
                .at_rule,
            )
        else
            try self.allocator.dupe(u8, "");
        defer self.allocator.free(rendered);
        var result = AtRulePrelude{
            .rendered = if (native_lexer.identifierEqlIgnoreCaseAscii(keyword, "@media"))
                try self.normalizeMediaPreludeOwned(rendered)
            else
                try self.allocator.dupe(u8, rendered),
        };
        errdefer result.deinit(self.allocator);
        if (!usesKeywordCommentList(keyword)) return result;

        const tokens = try native_lexer.tokenizeAlloc(
            self.allocator,
            result.rendered,
            .less,
            .{},
        );
        defer if (tokens.len > 0) self.allocator.free(tokens);
        try self.transaction.consumeOperations(@intCast(tokens.len));

        var cleaned: std.ArrayList(u8) = .empty;
        defer cleaned.deinit(self.allocator);
        var cursor: usize = 0;
        for (tokens) |token| {
            if (token.kind == .eof) break;
            try self.appendTemporary(
                &cleaned,
                result.rendered[cursor..token.span.start],
            );
            if (token.kind == .comment) {
                try result.comments.append(self.allocator, .{
                    .start = token.span.start,
                    .end = token.span.end,
                });
            } else {
                const raw = token.raw(result.rendered);
                if (token.kind == .comma) {
                    while (cleaned.items.len > 0 and
                        isCssWhitespace(cleaned.items[cleaned.items.len - 1]))
                    {
                        _ = cleaned.pop();
                    }
                }
                try self.appendTemporary(&cleaned, raw);
            }
            cursor = token.span.end;
        }
        if (result.comments.items.len == 0) return result;
        try self.appendTemporary(&cleaned, result.rendered[cursor..]);
        result.cleaned = try cleaned.toOwnedSlice(self.allocator);
        return result;
    }

    fn normalizeMediaPreludeOwned(self: *Engine, input: []const u8) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var quote: u8 = 0;
        var escaped = false;
        for (input, 0..) |byte, index| {
            try output.append(self.allocator, byte);
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
            if (byte == ':' and index + 1 < input.len and
                !std.ascii.isWhitespace(input[index + 1]))
            {
                try output.append(self.allocator, ' ');
            }
        }
        return try output.toOwnedSlice(self.allocator);
    }

    fn emitAtRuleKeywordComments(
        self: *Engine,
        at_rule_id: native_syntax.NodeId,
        scope: Scope,
    ) Error!void {
        const at_rule = self.document.get(at_rule_id) catch return error.InvalidDocument;
        if (at_rule.kind != .at_rule or at_rule.text == null) return error.InvalidDocument;
        const keyword = try self.sources.slice(at_rule.text.?);
        const children = self.document.children(at_rule_id) catch return error.InvalidDocument;
        var expression: ?*const native_syntax.Node = null;
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            switch (child.kind) {
                .expression => expression = child,
                .block => {},
                else => return error.InvalidDocument,
            }
        }
        var prelude = try self.renderAtRulePrelude(keyword, expression, scope.cursor);
        defer prelude.deinit(self.allocator);
        try self.emitAtRulePreludeComments(expression, &prelude);
    }

    fn emitAtRulePreludeComments(
        self: *Engine,
        expression: ?*const native_syntax.Node,
        prelude: *const AtRulePrelude,
    ) Error!void {
        const span = if (expression) |node| node.span else return;
        for (prelude.comments.items) |comment| {
            try self.transaction.emitMapped(
                span,
                null,
                prelude.rendered[comment.start..comment.end],
            );
        }
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
                    const merged = try self.mergeDeclarationsOwned(rendered.items);
                    defer self.allocator.free(merged);
                    if (parent_selector) |selector| {
                        var wrapped: std.ArrayList(u8) = .empty;
                        defer wrapped.deinit(self.allocator);
                        try self.appendTemporary(&wrapped, selector);
                        try self.appendTemporary(&wrapped, "{");
                        try self.appendTemporary(&wrapped, merged);
                        try self.appendTemporary(&wrapped, "}");
                        try self.transaction.emitMapped(child.span, null, wrapped.items);
                    } else {
                        try self.transaction.emitMapped(child.span, null, merged);
                    }
                },
                .rule => try self.emitRule(child_id, scope, parent_selector),
                .at_rule => try self.emitAtRule(child_id, scope, parent_selector),
                .mixin => if (!try self.isMixinDefinition(child_id)) {
                    const nested = self.document.children(child_id) catch
                        return error.InvalidDocument;
                    if (nested.len > 1) {
                        try self.emitRule(child_id, scope, parent_selector);
                    } else {
                        var declarations: std.ArrayList(u8) = .empty;
                        defer declarations.deinit(self.allocator);
                        try self.appendCallable(
                            &declarations,
                            child_id,
                            scope,
                            parent_selector orelse "",
                        );
                        if (declarations.items.len > 0) {
                            const merged = try self.mergeDeclarationsOwned(declarations.items);
                            defer self.allocator.free(merged);
                            if (parent_selector) |selector| {
                                var wrapped: std.ArrayList(u8) = .empty;
                                defer wrapped.deinit(self.allocator);
                                try self.appendTemporary(&wrapped, selector);
                                try self.appendTemporary(&wrapped, "{");
                                try self.appendTemporary(&wrapped, merged);
                                try self.appendTemporary(&wrapped, "}");
                                try self.transaction.emitMapped(child.span, null, wrapped.items);
                            } else {
                                try self.transaction.emitMapped(child.span, null, merged);
                            }
                        }
                        try self.emitCallableNested(
                            child_id,
                            scope,
                            parent_selector orelse "",
                        );
                    }
                } else if (try self.mixinDefinitionEmitsRule(child_id)) {
                    try self.emitRule(child_id, scope, parent_selector);
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
        if (child.len == 0) {
            return self.rejectUnsupportedSelector(child);
        }
        if (self.selector_count >= self.limits.max_selectors) {
            return error.SelectorLimitExceeded;
        }
        self.selector_count += 1;
        if (parent == null or parent.?.len == 0) {
            if (std.mem.indexOfScalar(u8, child, '&') == null) {
                return try self.allocator.dupe(u8, child);
            }
            var root_selector: std.ArrayList(u8) = .empty;
            errdefer root_selector.deinit(self.allocator);
            for (child) |byte| {
                if (byte != '&') try root_selector.append(self.allocator, byte);
            }
            return try root_selector.toOwnedSlice(self.allocator);
        }

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        var parents = try splitTopLevelAlloc(
            self.allocator,
            parent.?,
            .{ .start = 0, .end = parent.?.len },
            ',',
        );
        defer parents.deinit(self.allocator);
        var children = try splitTopLevelAlloc(
            self.allocator,
            child,
            .{ .start = 0, .end = child.len },
            ',',
        );
        defer children.deinit(self.allocator);
        for (children.items) |child_range| {
            const child_item = std.mem.trim(
                u8,
                child[child_range.start..child_range.end],
                " \t\r\n\x0c",
            );
            if (std.mem.indexOfScalar(u8, child_item, '&') != null) {
                try self.appendSelectorProduct(&output, child_item, parent.?, parents.items);
                continue;
            }
            for (parents.items) |parent_range| {
                const parent_item = std.mem.trim(
                    u8,
                    parent.?[parent_range.start..parent_range.end],
                    " \t\r\n\x0c",
                );
                if (output.items.len > 0) try self.appendTemporary(&output, ",");
                try self.appendTemporary(&output, parent_item);
                try self.appendTemporary(&output, " ");
                try self.appendTemporary(&output, child_item);
            }
        }
        return try output.toOwnedSlice(self.allocator);
    }

    fn appendSelectorProduct(
        self: *Engine,
        output: *std.ArrayList(u8),
        template: []const u8,
        parents_raw: []const u8,
        parents: []const ByteRange,
    ) Error!void {
        const marker = std.mem.indexOfScalar(u8, template, '&') orelse {
            if (output.items.len > 0) try self.appendTemporary(output, ",");
            try self.appendTemporary(output, template);
            return;
        };
        for (parents) |parent_range| {
            const parent = std.mem.trim(
                u8,
                parents_raw[parent_range.start..parent_range.end],
                " \t\r\n\x0c",
            );
            const expanded = try std.fmt.allocPrint(
                self.allocator,
                "{s}{s}{s}",
                .{ template[0..marker], parent, template[marker + 1 ..] },
            );
            defer self.allocator.free(expanded);
            try self.appendSelectorProduct(output, expanded, parents_raw, parents);
        }
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
        defer output.deinit(self.allocator);
        try self.renderInto(span, scope, context, &output);
        if (std.mem.indexOf(u8, output.items, "@{") != null or
            std.mem.indexOf(u8, output.items, "${") != null)
        {
            const resolved_interpolation = try self.resolveInterpolatedTextOwned(
                output.items,
                span,
                scope,
            );
            output.clearRetainingCapacity();
            try self.appendTemporary(&output, resolved_interpolation);
            self.allocator.free(resolved_interpolation);
        }
        if (context == .value or context == .binding_value) {
            const evaluated = try self.evaluateValueOwned(span, output.items);
            defer self.allocator.free(evaluated);
            if (context == .value) {
                const flattened = try self.flattenListGroupingOwned(evaluated);
                defer self.allocator.free(flattened);
                return self.normalizeValueSpacingOwned(flattened);
            }
            return self.normalizeValueSpacingOwned(evaluated);
        }
        return try output.toOwnedSlice(self.allocator);
    }

    fn resolveInterpolatedTextOwned(
        self: *Engine,
        input: []const u8,
        use_span: native_source.Span,
        scope: native_environment.ScopeId,
    ) Error![]u8 {
        var current = try self.allocator.dupe(u8, input);
        errdefer self.allocator.free(current);
        var depth: u16 = 0;
        while (depth < self.limits.max_expression_depth) : (depth += 1) {
            const at_index = std.mem.indexOf(u8, current, "@{");
            const property_index = std.mem.indexOf(u8, current, "${");
            const opening = if (at_index) |at|
                if (property_index) |property| @min(at, property) else at
            else
                property_index orelse return current;
            const closing = std.mem.indexOfScalarPos(u8, current, opening + 2, '}') orelse
                return current;
            const prefix: u8 = current[opening];
            const bare_name = std.mem.trim(
                u8,
                current[opening + 2 .. closing],
                " \t\r\n\x0c",
            );
            if (!validBareVariableName(bare_name)) return current;
            const name = try std.fmt.allocPrint(self.allocator, "{c}{s}", .{ prefix, bare_name });
            defer self.allocator.free(name);
            const resolved = try self.resolveVariable(name, use_span, scope);
            const trimmed_resolved = std.mem.trim(u8, resolved, " \t\r\n\x0c");
            const attribute_value = opening > 0 and current[opening - 1] == '=';
            const replacement = if (attribute_value)
                trimmed_resolved
            else
                stripQuotes(trimmed_resolved);
            const next = try std.fmt.allocPrint(
                self.allocator,
                "{s}{s}{s}",
                .{ current[0..opening], replacement, current[closing + 1 ..] },
            );
            self.allocator.free(current);
            current = next;
        }
        return current;
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
                if (try self.environment.lookup(scope, indirect) != null) {
                    const resolved = try self.resolveVariable(indirect, use_span, scope);
                    try self.appendTemporary(output, resolved);
                } else {
                    try self.appendTemporary(output, unquoted);
                }
                cursor = name_token.span.end;
                index += 1;
                continue;
            }
            if (token.kind == .at_identifier) {
                if (nextSignificantKind(tokens, index + 1) == .open_square) {
                    var detached_index = self.detached.items.len;
                    while (detached_index > 0) {
                        detached_index -= 1;
                        const detached = self.detached.items[detached_index];
                        if (!std.mem.eql(u8, detached.name, token.raw(raw))) continue;
                        const marker = try std.fmt.allocPrint(
                            self.allocator,
                            "__less_block_{d}",
                            .{detached.block.value},
                        );
                        defer self.allocator.free(marker);
                        try self.appendTemporary(output, marker);
                        cursor = token_end;
                        break;
                    }
                    if (cursor == token_end) continue;
                }
                if (previousSignificantKind(tokens, index) == .open_square) {
                    try self.appendTemporary(output, token.raw(raw));
                    cursor = token_end;
                    continue;
                }
                const use_span = try self.relativeSpan(span, token.span.start, token.span.end);
                const resolved = try self.resolveVariable(token.raw(raw), use_span, scope);
                var variable_token_count: usize = 0;
                for (tokens) |candidate| {
                    if (candidate.kind == .at_identifier) variable_token_count += 1;
                }
                const preserve_list_group = (context == .value or context == .binding_value) and
                    variable_token_count > 1 and
                    containsTopLevel(resolved, ',');
                if (preserve_list_group) try self.appendTemporary(output, "(");
                try self.appendTemporary(output, resolved);
                if (preserve_list_group) try self.appendTemporary(output, ")");
                cursor = token_end;
                continue;
            }
            if (token.kind == .variable) {
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
                const inner_span = try self.relativeSpan(
                    span,
                    token.span.end,
                    close_token.span.start,
                );
                const rendered_inner_owned = if (std.mem.indexOf(u8, inner, "@{") != null or
                    std.mem.indexOf(u8, inner, "${") != null or
                    std.mem.startsWith(u8, inner, "$@"))
                    try self.renderOwned(inner_span, scope, .property)
                else
                    try self.allocator.dupe(u8, inner);
                defer self.allocator.free(rendered_inner_owned);
                const rendered_inner = std.mem.trim(
                    u8,
                    rendered_inner_owned,
                    " \t\r\n\x0c",
                );
                const property_interpolation = std.mem.startsWith(
                    u8,
                    token.raw(raw),
                    "${",
                );
                const name = if (std.mem.startsWith(u8, rendered_inner, "@") or
                    std.mem.startsWith(u8, rendered_inner, "$"))
                    try self.allocator.dupe(u8, rendered_inner)
                else if (property_interpolation)
                    try std.fmt.allocPrint(self.allocator, "${s}", .{rendered_inner})
                else
                    try self.indirectName(rendered_inner);
                defer self.allocator.free(name);
                const use_span = try self.relativeSpan(
                    span,
                    token.span.start,
                    close_token.span.end,
                );
                const resolved = try self.resolveVariable(name, use_span, scope);
                const trimmed_resolved = std.mem.trim(u8, resolved, " \t\r\n\x0c");
                const attribute_value = context == .selector and token.span.start > 0 and
                    raw[token.span.start - 1] == '=';
                try self.appendTemporary(output, if (attribute_value)
                    trimmed_resolved
                else
                    stripQuotes(trimmed_resolved));
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
        if (value.len >= 3 and value[0] == '~' and
            ((value[1] == '\'' and value[value.len - 1] == '\'') or
                (value[1] == '"' and value[value.len - 1] == '"')))
        {
            return try self.allocator.dupe(u8, value[2 .. value.len - 1]);
        }
        if (functionArguments(value, "url") != null) {
            return self.rewriteUrlOwned(span, value);
        }
        if (std.mem.indexOf(u8, value, "calc(") != null) {
            return self.simplifyCalcValueOwned(value);
        }
        const rewritten_lists = try self.rewriteListFunctionsOwned(span, value);
        defer self.allocator.free(rewritten_lists);
        if (!std.mem.eql(u8, rewritten_lists, value)) {
            return self.evaluateValueOwned(span, rewritten_lists);
        }
        const unquoted = try self.rewriteEscapedStringsOwned(value);
        defer self.allocator.free(unquoted);
        if (!std.mem.eql(u8, unquoted, value)) {
            return self.evaluateValueOwned(span, unquoted);
        }
        if (try self.resolveMapAccessOwned(span, value)) |resolved_map| {
            defer self.allocator.free(resolved_map);
            return self.evaluateValueOwned(span, resolved_map);
        }
        const rewritten_groups = self.rewriteNumericGroupsOwned(value) catch |err| switch (err) {
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
            else => return err,
        };
        defer self.allocator.free(rewritten_groups);
        if (!std.mem.eql(u8, rewritten_groups, value)) {
            return self.evaluateValueOwned(span, rewritten_groups);
        }
        if (functionArguments(value, "e")) |arguments| {
            return try self.allocator.dupe(
                u8,
                stripQuotes(std.mem.trim(
                    u8,
                    value[arguments.start..arguments.end],
                    " \t\r\n\x0c",
                )),
            );
        }
        if (functionArguments(value, "unit")) |arguments| {
            var parts = try splitTopLevelAlloc(self.allocator, value, arguments, ',');
            defer parts.deinit(self.allocator);
            if (parts.items.len == 1 or parts.items.len == 2) {
                const numeric_input = std.mem.trim(
                    u8,
                    value[parts.items[0].start..parts.items[0].end],
                    " \t\r\n\x0c",
                );
                const unitless_input = try stripNumericUnitsOwned(self.allocator, numeric_input);
                defer self.allocator.free(unitless_input);
                var parser = NumericParser{
                    .input = unitless_input,
                    .max_depth = self.limits.max_expression_depth,
                    .strict_units = self.options.strict_units,
                };
                if (parser.parse()) |numeric| {
                    const requested_unit = if (parts.items.len == 2)
                        stripQuotes(std.mem.trim(
                            u8,
                            value[parts.items[1].start..parts.items[1].end],
                            " \t\r\n\x0c",
                        ))
                    else
                        "";
                    const converted = native_numeric.Numeric.init(
                        numeric.value,
                        if (requested_unit.len > 0) requested_unit else null,
                    ) catch {
                        try self.reportInvalidOperation(span, "native Less unit() received an invalid unit");
                        return error.InvalidOperation;
                    };
                    return self.serializeNumeric(converted);
                } else |_| {}
            }
        }
        if (functionArguments(value, "alpha")) |arguments| {
            const input = std.mem.trim(
                u8,
                value[arguments.start..arguments.end],
                " \t\r\n\x0c",
            );
            if (std.mem.indexOfScalar(u8, input, '=') != null) {
                return try self.allocator.dupe(u8, value);
            }
            const color = try self.parseLessColor(input) orelse {
                try self.reportInvalidOperation(span, "native Less alpha() requires a color");
                return error.InvalidOperation;
            };
            const channels = native_color.toRgb(color) catch {
                try self.reportInvalidOperation(span, "native Less alpha() requires a color");
                return error.InvalidOperation;
            };
            return try self.formatNumber(channels[3]);
        }
        if (functionArguments(value, "red")) |arguments| {
            const input = std.mem.trim(
                u8,
                value[arguments.start..arguments.end],
                " \t\r\n\x0c",
            );
            const color = try self.parseLessColor(input) orelse {
                try self.reportInvalidOperation(span, "native Less red() requires a color");
                return error.InvalidOperation;
            };
            const channels = native_color.toRgb(color) catch {
                try self.reportInvalidOperation(span, "native Less red() requires a color");
                return error.InvalidOperation;
            };
            return try self.formatNumber(@round(channels[0]));
        }
        if (functionArguments(value, "argb")) |arguments| {
            const input = std.mem.trim(
                u8,
                value[arguments.start..arguments.end],
                " \t\r\n\x0c",
            );
            const color = try self.parseLessColor(input) orelse {
                try self.reportInvalidOperation(span, "native Less argb() requires a color");
                return error.InvalidOperation;
            };
            var buffer: [9]u8 = undefined;
            const serialized = native_color.serializeIeHex(color, &buffer) catch {
                try self.reportInvalidOperation(span, "native Less argb() requires a color");
                return error.InvalidOperation;
            };
            const result = try self.allocator.dupe(u8, serialized);
            for (result) |*byte| byte.* = std.ascii.toLower(byte.*);
            return result;
        }
        inline for (.{ "lighten", "darken", "fade", "rgb", "rgba", "hsl", "hsla", "color" }) |name| {
            if (functionArguments(value, name) != null) {
                const color = try self.parseLessColor(value) orelse {
                    if (std.mem.indexOf(u8, value, "var(") != null or
                        std.mem.indexOf(u8, value, "from ") != null or
                        std.mem.indexOf(u8, value, "calc(") != null)
                    {
                        return try self.allocator.dupe(u8, value);
                    }
                    try self.reportInvalidOperation(span, "native Less color function arguments are invalid");
                    return error.InvalidOperation;
                };
                if (std.mem.eql(u8, name, "hsl") or std.mem.eql(u8, name, "hsla")) {
                    return self.serializeLessHsl(color);
                }
                if (std.mem.eql(u8, name, "color")) {
                    const arguments = functionArguments(value, name).?;
                    return try self.allocator.dupe(
                        u8,
                        stripQuotes(std.mem.trim(
                            u8,
                            value[arguments.start..arguments.end],
                            " \t\r\n\x0c",
                        )),
                    );
                }
                return self.serializeLessRgb(color);
            }
        }
        if ((std.mem.indexOfScalar(u8, value, '#') != null or
            std.mem.indexOf(u8, value, "rgb(") != null or
            std.mem.indexOf(u8, value, "hsl(") != null) and
            std.mem.indexOfAny(u8, value, "+-*/") != null)
        {
            if (try self.evaluateColorOperation(value)) |color| {
                return self.serializeLessRgb(color);
            }
        }
        if (std.mem.indexOf(u8, value, "\n-") != null or
            std.mem.indexOf(u8, value, "\r-") != null)
        {
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
        if (!looksNumeric(value)) return try self.allocator.dupe(u8, value);
        if (std.mem.indexOf(u8, value, "/*")) |comment_start| {
            const numeric_input = std.mem.trimRight(
                u8,
                value[0..comment_start],
                " \t\r\n\x0c",
            );
            var commented_parser = NumericParser{
                .input = numeric_input,
                .max_depth = self.limits.max_expression_depth,
                .strict_units = self.options.strict_units,
            };
            if (commented_parser.parse()) |numeric| {
                const serialized = try self.serializeNumeric(numeric);
                defer self.allocator.free(serialized);
                return try std.fmt.allocPrint(
                    self.allocator,
                    "{s} {s}",
                    .{ serialized, std.mem.trimLeft(u8, value[comment_start..], " \t\r\n\x0c") },
                );
            } else |_| {}
        }
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

    fn rewriteNumericGroupsOwned(self: *Engine, input: []const u8) Error![]u8 {
        for (input, 0..) |byte, opening| {
            if (byte != '(') continue;
            if (opening > 0 and (std.ascii.isAlphanumeric(input[opening - 1]) or
                input[opening - 1] == '_' or input[opening - 1] == '-')) continue;
            const closing = matchingCloseParen(input, opening) orelse continue;
            var parser = NumericParser{
                .input = input[opening .. closing + 1],
                .max_depth = self.limits.max_expression_depth,
                .strict_units = self.options.strict_units,
            };
            const numeric = parser.parse() catch |err| switch (err) {
                error.ExpressionDepthExceeded => return error.ExpressionDepthExceeded,
                else => continue,
            };
            const serialized = try self.serializeNumeric(numeric);
            defer self.allocator.free(serialized);
            return try std.fmt.allocPrint(
                self.allocator,
                "{s}{s}{s}",
                .{ input[0..opening], serialized, input[closing + 1 ..] },
            );
        }
        return try self.allocator.dupe(u8, input);
    }

    fn resolveMapAccessOwned(
        self: *Engine,
        span: native_source.Span,
        input: []const u8,
    ) Error!?[]u8 {
        const closing = std.mem.lastIndexOfScalar(u8, input, ']') orelse return null;
        if (std.mem.trim(u8, input[closing + 1 ..], " \t\r\n\x0c").len != 0) return null;
        const opening = std.mem.lastIndexOfScalar(u8, input[0..closing], '[') orelse return null;
        var base = std.mem.trim(u8, input[0..opening], " \t\r\n\x0c");
        if (std.mem.endsWith(u8, base, "()")) base = std.mem.trimRight(
            u8,
            base[0 .. base.len - 2],
            " \t\r\n\x0c",
        );
        if (base.len == 0) return null;
        var selected_block: ?native_syntax.NodeId = null;
        var selected_scope: ?Scope = null;
        if (std.mem.startsWith(u8, base, "__less_block_")) {
            const id = std.fmt.parseInt(u32, base[13..], 10) catch return null;
            selected_block = .{ .value = id };
            selected_scope = .{ .cursor = self.environment.root(), .id = 0 };
        } else if (base[0] == '@') {
            var detached_index = self.detached.items.len;
            while (detached_index > 0) {
                detached_index -= 1;
                if (std.mem.eql(u8, self.detached.items[detached_index].name, base)) {
                    selected_block = self.detached.items[detached_index].block;
                    selected_scope = self.detached.items[detached_index].scope;
                    break;
                }
            }
            if (selected_block == null) {
                const resolved_base = self.resolveVariable(
                    base,
                    span,
                    self.environment.root(),
                ) catch return null;
                const expanded = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}{s}",
                    .{ resolved_base, input[opening..] },
                );
                defer self.allocator.free(expanded);
                if (std.mem.eql(u8, expanded, input)) return null;
                return try self.resolveMapAccessOwned(span, expanded);
            }
        } else if (base[0] == '.' or base[0] == '#') {
            var definition_index = self.mixins.items.len;
            while (definition_index > 0) {
                definition_index -= 1;
                if (std.mem.eql(u8, self.mixins.items[definition_index].name, base)) {
                    selected_block = self.mixins.items[definition_index].block;
                    selected_scope = self.mixins.items[definition_index].scope;
                    break;
                }
            }
        } else {
            return null;
        }
        const block = selected_block orelse return null;
        const parent_scope = selected_scope orelse return null;
        var key = std.mem.trim(u8, input[opening + 1 .. closing], " \t\r\n\x0c");
        if (key.len > 0 and (key[0] == '$' or key[0] == '@')) key = key[1..];
        key = stripQuotes(key);
        const block_children = self.document.children(block) catch
            return error.InvalidDocument;
        const scope = try self.prepareScope(block_children, parent_scope);
        var expression_span: ?native_source.Span = null;
        for (block_children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidDocument;
            if (child.kind == .detached_ruleset) {
                const detached_children = self.document.children(child_id) catch
                    return error.InvalidDocument;
                if (detached_children.len != 2) continue;
                const name_node = self.document.get(detached_children[0]) catch
                    return error.InvalidDocument;
                var nested_name = try self.sources.slice(name_node.text orelse continue);
                if (nested_name.len > 0 and nested_name[0] == '@') nested_name = nested_name[1..];
                if (std.mem.eql(u8, nested_name, key)) {
                    return try std.fmt.allocPrint(
                        self.allocator,
                        "__less_block_{d}",
                        .{detached_children[1].value},
                    );
                }
                continue;
            }
            if (!try self.isPropertyDeclaration(child_id) and
                !try self.isVariableDeclaration(child_id)) continue;
            const declaration_children = self.document.children(child_id) catch
                return error.InvalidDocument;
            if (declaration_children.len != 2) continue;
            const property_node = self.document.get(declaration_children[0]) catch
                return error.InvalidDocument;
            var property = std.mem.trim(
                u8,
                try self.sources.slice(property_node.text orelse continue),
                " \t\r\n\x0c",
            );
            if (property.len > 0 and property[0] == '@') property = property[1..];
            if (!std.mem.eql(u8, property, key)) continue;
            const expression = self.document.get(declaration_children[1]) catch
                return error.InvalidDocument;
            expression_span = expression.text;
        }
        const property_span = expression_span orelse {
            try self.reportUndefined(key, span);
            return error.UndefinedVariable;
        };
        return try self.renderOwned(property_span, scope.cursor, .value);
    }

    fn rewriteListFunctionsOwned(
        self: *Engine,
        span: native_source.Span,
        input: []const u8,
    ) Error![]u8 {
        var cursor: usize = 0;
        while (cursor < input.len) : (cursor += 1) {
            const name: ?[]const u8 = if (startsFunctionAt(input, cursor, "length"))
                "length"
            else if (startsFunctionAt(input, cursor, "extract"))
                "extract"
            else if (startsFunctionAt(input, cursor, "unit"))
                "unit"
            else if (startsFunctionAt(input, cursor, "e"))
                "e"
            else if (startsFunctionAt(input, cursor, "range"))
                "range"
            else if (startsFunctionAt(input, cursor, "lighten"))
                "lighten"
            else if (startsFunctionAt(input, cursor, "darken"))
                "darken"
            else if (startsFunctionAt(input, cursor, "fade"))
                "fade"
            else
                null;
            if (name == null) continue;
            const function_name = name.?;
            const opening = cursor + function_name.len;
            const closing = matchingCloseParen(input, opening) orelse continue;
            const arguments = input[opening + 1 .. closing];
            const nested = try self.rewriteListFunctionsOwned(span, arguments);
            defer self.allocator.free(nested);
            var replacement: ?[]u8 = null;
            defer if (replacement) |bytes| self.allocator.free(bytes);

            if (std.mem.eql(u8, function_name, "length")) {
                const list = stripOuterGrouping(std.mem.trim(u8, nested, " \t\r\n\x0c"));
                var items = try splitLessListAlloc(self.allocator, list);
                defer items.deinit(self.allocator);
                replacement = try std.fmt.allocPrint(self.allocator, "{d}", .{items.items.len});
            } else if (std.mem.eql(u8, function_name, "extract")) {
                const separator = findLastTopLevelByte(nested, ',') orelse continue;
                const index_raw = std.mem.trim(
                    u8,
                    nested[separator + 1 ..],
                    " \t\r\n\x0c",
                );
                const requested = std.fmt.parseInt(i64, index_raw, 10) catch continue;
                const list_raw_grouped = std.mem.trim(
                    u8,
                    nested[0..separator],
                    " \t\r\n\x0c",
                );
                const list_raw = stripOuterGrouping(list_raw_grouped);
                var items = try splitLessListAlloc(self.allocator, list_raw);
                defer items.deinit(self.allocator);
                if (requested <= 0 or @as(u64, @intCast(requested)) > items.items.len) continue;
                const item = items.items[@as(usize, @intCast(requested - 1))];
                const selected = stripOuterGrouping(std.mem.trim(
                    u8,
                    list_raw[item.start..item.end],
                    " \t\r\n\x0c",
                ));
                replacement = try self.allocator.dupe(
                    u8,
                    selected,
                );
            } else if (std.mem.eql(u8, function_name, "e")) {
                replacement = try self.allocator.dupe(
                    u8,
                    stripQuotes(std.mem.trim(u8, nested, " \t\r\n\x0c")),
                );
            } else if (std.mem.eql(u8, function_name, "lighten") or
                std.mem.eql(u8, function_name, "darken") or
                std.mem.eql(u8, function_name, "fade"))
            {
                const color_call = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}({s})",
                    .{ function_name, nested },
                );
                defer self.allocator.free(color_call);
                if (try self.parseLessColor(color_call)) |color| {
                    replacement = try self.serializeLessRgb(color);
                }
            } else if (std.mem.eql(u8, function_name, "range")) {
                var parts = try splitTopLevelAlloc(
                    self.allocator,
                    nested,
                    .{ .start = 0, .end = nested.len },
                    ',',
                );
                defer parts.deinit(self.allocator);
                if (parts.items.len >= 1 and parts.items.len <= 3) {
                    var numbers: [3]native_numeric.Numeric = undefined;
                    for (parts.items, 0..) |part, part_index| {
                        var parser = NumericParser{
                            .input = std.mem.trim(
                                u8,
                                nested[part.start..part.end],
                                " \t\r\n\x0c",
                            ),
                            .max_depth = self.limits.max_expression_depth,
                            .strict_units = false,
                        };
                        numbers[part_index] = parser.parse() catch break;
                    }
                    const first = if (parts.items.len == 1)
                        native_numeric.Numeric.init(1, null) catch continue
                    else
                        numbers[0];
                    const last = if (parts.items.len == 1) numbers[0] else numbers[1];
                    const step_value = if (parts.items.len == 3) numbers[2].value else 1;
                    if (step_value != 0) {
                        var generated: std.ArrayList(u8) = .empty;
                        defer generated.deinit(self.allocator);
                        var current = first.value;
                        var count: usize = 0;
                        while (count < @as(usize, self.limits.max_calls) and
                            (if (step_value > 0) current <= last.value else current >= last.value)) : ({
                            current += step_value;
                            count += 1;
                        }) {
                            const item = native_numeric.Numeric.init(current, simpleUnitSuffix(
                                std.mem.trim(
                                    u8,
                                    nested[parts.items[if (parts.items.len == 1) 0 else 1].start..parts.items[if (parts.items.len == 1) 0 else 1].end],
                                    " \t\r\n\x0c",
                                ),
                            )) catch continue;
                            const serialized = try self.serializeNumeric(item);
                            defer self.allocator.free(serialized);
                            if (generated.items.len > 0) try self.appendTemporary(&generated, " ");
                            try self.appendTemporary(&generated, serialized);
                        }
                        replacement = try generated.toOwnedSlice(self.allocator);
                    }
                }
            } else {
                var parts = try splitTopLevelAlloc(
                    self.allocator,
                    nested,
                    .{ .start = 0, .end = nested.len },
                    ',',
                );
                defer parts.deinit(self.allocator);
                if (parts.items.len == 1 or parts.items.len == 2) {
                    const numeric_input = std.mem.trim(
                        u8,
                        nested[parts.items[0].start..parts.items[0].end],
                        " \t\r\n\x0c",
                    );
                    const unitless_input = try stripNumericUnitsOwned(self.allocator, numeric_input);
                    defer self.allocator.free(unitless_input);
                    var parser = NumericParser{
                        .input = unitless_input,
                        .max_depth = self.limits.max_expression_depth,
                        .strict_units = self.options.strict_units,
                    };
                    if (parser.parse()) |numeric| {
                        const requested_unit = if (parts.items.len == 2)
                            stripQuotes(std.mem.trim(
                                u8,
                                nested[parts.items[1].start..parts.items[1].end],
                                " \t\r\n\x0c",
                            ))
                        else
                            "";
                        const converted = native_numeric.Numeric.init(
                            numeric.value,
                            if (requested_unit.len > 0) requested_unit else null,
                        ) catch continue;
                        replacement = try self.serializeNumeric(converted);
                    } else |_| {}
                }
            }
            const bytes = replacement orelse continue;
            var output: std.ArrayList(u8) = .empty;
            errdefer output.deinit(self.allocator);
            try self.appendTemporary(&output, input[0..cursor]);
            try self.appendTemporary(&output, bytes);
            try self.appendTemporary(&output, input[closing + 1 ..]);
            return try output.toOwnedSlice(self.allocator);
        }
        return try self.allocator.dupe(u8, input);
    }

    fn rewriteEscapedStringsOwned(self: *Engine, input: []const u8) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var cursor: usize = 0;
        var changed = false;
        var outer_quote: u8 = 0;
        var outer_escaped = false;
        while (cursor + 2 < input.len) {
            if (outer_quote != 0) {
                const byte = input[cursor];
                try output.append(self.allocator, byte);
                if (outer_escaped) {
                    outer_escaped = false;
                } else if (byte == '\\') {
                    outer_escaped = true;
                } else if (byte == outer_quote) {
                    outer_quote = 0;
                }
                cursor += 1;
                continue;
            }
            if (input[cursor] == '\'' or input[cursor] == '"') {
                outer_quote = input[cursor];
                try output.append(self.allocator, input[cursor]);
                cursor += 1;
                continue;
            }
            if (input[cursor] != '~' or
                (input[cursor + 1] != '\'' and input[cursor + 1] != '"'))
            {
                try output.append(self.allocator, input[cursor]);
                cursor += 1;
                continue;
            }
            const quote = input[cursor + 1];
            var closing = cursor + 2;
            var escaped = false;
            while (closing < input.len) : (closing += 1) {
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (input[closing] == '\\') {
                    escaped = true;
                    continue;
                }
                if (input[closing] == quote) break;
            }
            if (closing >= input.len) {
                try output.append(self.allocator, input[cursor]);
                cursor += 1;
                continue;
            }
            try self.appendTemporary(&output, input[cursor + 2 .. closing]);
            cursor = closing + 1;
            changed = true;
        }
        try self.appendTemporary(&output, input[cursor..]);
        if (!changed) {
            output.clearRetainingCapacity();
            try self.appendTemporary(&output, input);
        }
        return try output.toOwnedSlice(self.allocator);
    }

    fn normalizeValueSpacingOwned(self: *Engine, input: []const u8) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var index: usize = 0;
        var quote: u8 = 0;
        var escaped = false;
        var block_comment = false;
        while (index < input.len) {
            const byte = input[index];
            if (block_comment) {
                try output.append(self.allocator, byte);
                if (byte == '*' and index + 1 < input.len and input[index + 1] == '/') {
                    try output.append(self.allocator, '/');
                    index += 2;
                    block_comment = false;
                    continue;
                }
                index += 1;
                continue;
            }
            if (quote != 0) {
                try output.append(self.allocator, byte);
                if (escaped) {
                    escaped = false;
                } else if (byte == '\\') {
                    escaped = true;
                } else if (byte == quote) {
                    quote = 0;
                }
                index += 1;
                continue;
            }
            if (byte == '/' and index + 1 < input.len and input[index + 1] == '*') {
                try self.appendTemporary(&output, "/*");
                index += 2;
                block_comment = true;
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte;
                try output.append(self.allocator, byte);
                index += 1;
                continue;
            }
            if (std.ascii.isWhitespace(byte)) {
                if (output.items.len == 0 or
                    !std.ascii.isWhitespace(output.items[output.items.len - 1]))
                {
                    try output.append(self.allocator, ' ');
                }
                index += 1;
                while (index < input.len and std.ascii.isWhitespace(input[index])) index += 1;
                continue;
            }
            if (byte == ',') {
                while (output.items.len > 0 and std.ascii.isWhitespace(output.items[output.items.len - 1])) {
                    _ = output.pop();
                }
                try self.appendTemporary(&output, ",");
                index += 1;
                while (index < input.len and std.ascii.isWhitespace(input[index])) index += 1;
                if (index < input.len) try self.appendTemporary(&output, " ");
                continue;
            }
            if (byte == '=') {
                while (output.items.len > 0 and output.items[output.items.len - 1] == ' ') {
                    _ = output.pop();
                }
                try output.append(self.allocator, '=');
                index += 1;
                while (index < input.len and input[index] == ' ') index += 1;
                continue;
            }
            if (byte == '.' and index + 1 < input.len and
                std.ascii.isDigit(input[index + 1]))
            {
                const previous_is_boundary = output.items.len == 0 or
                    std.ascii.isWhitespace(output.items[output.items.len - 1]) or
                    std.mem.indexOfScalar(u8, "(:,;+-*/", output.items[output.items.len - 1]) != null;
                if (previous_is_boundary) try output.append(self.allocator, '0');
            }
            try output.append(self.allocator, byte);
            index += 1;
        }
        return try output.toOwnedSlice(self.allocator);
    }

    fn flattenListGroupingOwned(self: *Engine, input: []const u8) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var cursor: usize = 0;
        var index: usize = 0;
        while (index < input.len) : (index += 1) {
            if (input[index] != '(' or (index > 0 and
                (std.ascii.isAlphanumeric(input[index - 1]) or
                    input[index - 1] == '-' or input[index - 1] == '_')))
            {
                continue;
            }
            const closing = matchingCloseParen(input, index) orelse continue;
            const inner = input[index + 1 .. closing];
            if (!containsTopLevel(inner, ',')) continue;
            try self.appendTemporary(&output, input[cursor..index]);
            try self.appendTemporary(&output, inner);
            cursor = closing + 1;
            index = closing;
        }
        try self.appendTemporary(&output, input[cursor..]);
        return try output.toOwnedSlice(self.allocator);
    }

    fn normalizeImportantOwned(self: *Engine, input: []const u8) Error![]u8 {
        const marker = "!important";
        if (std.mem.indexOf(u8, input, marker) == null) {
            return try self.allocator.dupe(u8, input);
        }
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, input, cursor, marker)) |index| {
            try self.appendTemporary(&output, input[cursor..index]);
            cursor = index + marker.len;
        }
        try self.appendTemporary(&output, input[cursor..]);
        const trimmed = std.mem.trim(u8, output.items, " \t\r\n\x0c");
        var normalized: std.ArrayList(u8) = .empty;
        errdefer normalized.deinit(self.allocator);
        var previous_space = false;
        for (trimmed) |byte| {
            const whitespace = std.ascii.isWhitespace(byte);
            if (whitespace and previous_space) continue;
            try normalized.append(self.allocator, if (whitespace) ' ' else byte);
            previous_space = whitespace;
        }
        while (normalized.items.len > 0 and normalized.items[normalized.items.len - 1] == ' ') {
            _ = normalized.pop();
        }
        try self.appendTemporary(&normalized, " !important");
        return try normalized.toOwnedSlice(self.allocator);
    }

    fn simplifyCalcValueOwned(self: *Engine, value: []const u8) Error![]u8 {
        const rewritten = try self.rewriteCalcFunctions(value);
        defer self.allocator.free(rewritten);
        const divided = try self.rewriteCalcDivisions(rewritten);
        defer self.allocator.free(divided);
        const collapsed = try self.collapseCalcParentheses(divided);
        defer self.allocator.free(collapsed);

        const calc_start = std.mem.indexOf(u8, collapsed, "calc(") orelse
            return try self.allocator.dupe(u8, collapsed);
        if (calc_start == 0 and matchingCloseParen(collapsed, 4) == collapsed.len - 1) {
            return try self.allocator.dupe(u8, collapsed);
        }
        const calc_end = matchingCloseParen(collapsed, calc_start + 4) orelse
            return try self.allocator.dupe(u8, collapsed);
        const before = std.mem.trim(u8, collapsed[0..calc_start], " \t\r\n\x0c");
        const after = std.mem.trim(u8, collapsed[calc_end + 1 ..], " \t\r\n\x0c");
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        if (before.len > 0) {
            var parser = NumericParser{
                .input = before,
                .max_depth = self.limits.max_expression_depth,
                .strict_units = self.options.strict_units,
            };
            if (parser.parse()) |numeric| {
                const serialized = try self.serializeNumeric(numeric);
                defer self.allocator.free(serialized);
                try self.appendTemporary(&output, serialized);
                try self.appendTemporary(&output, " ");
            } else |_| {
                try self.appendTemporary(&output, collapsed[0..calc_start]);
            }
        }
        try self.appendTemporary(&output, collapsed[calc_start .. calc_end + 1]);
        if (after.len > 0) {
            var parser = NumericParser{
                .input = after,
                .max_depth = self.limits.max_expression_depth,
                .strict_units = self.options.strict_units,
            };
            if (parser.parse()) |numeric| {
                const serialized = try self.serializeNumeric(numeric);
                defer self.allocator.free(serialized);
                try self.appendTemporary(&output, " ");
                try self.appendTemporary(&output, serialized);
            } else |_| {
                try self.appendTemporary(&output, collapsed[calc_end + 1 ..]);
            }
        }
        return try output.toOwnedSlice(self.allocator);
    }

    fn rewriteCalcFunctions(self: *Engine, input: []const u8) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var index: usize = 0;
        while (index < input.len) {
            if (input[index] == '~' and index + 2 < input.len and
                (input[index + 1] == '\'' or input[index + 1] == '"'))
            {
                const quote = input[index + 1];
                const closing = std.mem.indexOfScalarPos(u8, input, index + 2, quote) orelse {
                    try self.appendTemporary(&output, input[index..]);
                    break;
                };
                try self.appendTemporary(&output, input[index + 2 .. closing]);
                index = closing + 1;
                continue;
            }
            const known: ?[]const u8 = if (std.mem.startsWith(u8, input[index..], "floor("))
                "floor"
            else if (std.mem.startsWith(u8, input[index..], "min("))
                "min"
            else if (std.mem.startsWith(u8, input[index..], "e("))
                "e"
            else
                null;
            if (known) |name| {
                const opening = index + name.len;
                const closing = matchingCloseParen(input, opening) orelse {
                    try self.appendTemporary(&output, input[index..]);
                    break;
                };
                const raw_argument = std.mem.trim(
                    u8,
                    input[opening + 1 .. closing],
                    " \t\r\n\x0c",
                );
                if (std.mem.eql(u8, name, "e")) {
                    try self.appendTemporary(&output, stripQuotes(raw_argument));
                } else {
                    var parser = NumericParser{
                        .input = raw_argument,
                        .max_depth = self.limits.max_expression_depth,
                        .strict_units = self.options.strict_units,
                    };
                    const numeric = parser.parse() catch {
                        try self.appendTemporary(&output, input[index .. closing + 1]);
                        index = closing + 1;
                        continue;
                    };
                    const adjusted = if (std.mem.eql(u8, name, "floor")) blk: {
                        var result = numeric;
                        result.value = @floor(result.value);
                        break :blk result;
                    } else numeric;
                    const serialized = try self.serializeNumeric(adjusted);
                    defer self.allocator.free(serialized);
                    try self.appendTemporary(&output, serialized);
                }
                index = closing + 1;
                continue;
            }
            try output.append(self.allocator, input[index]);
            index += 1;
        }
        return try output.toOwnedSlice(self.allocator);
    }

    fn rewriteCalcDivisions(self: *Engine, input: []const u8) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var index: usize = 0;
        while (index < input.len) {
            if (!(std.ascii.isDigit(input[index]) or input[index] == '.')) {
                try output.append(self.allocator, input[index]);
                index += 1;
                continue;
            }
            var end = index;
            while (end < input.len and
                (std.ascii.isAlphanumeric(input[end]) or input[end] == '.' or input[end] == '%'))
            {
                end += 1;
            }
            var slash = end;
            while (slash < input.len and std.ascii.isWhitespace(input[slash])) slash += 1;
            if (slash >= input.len or input[slash] != '/') {
                try self.appendTemporary(&output, input[index..end]);
                index = end;
                continue;
            }
            var right_start = slash + 1;
            while (right_start < input.len and std.ascii.isWhitespace(input[right_start])) {
                right_start += 1;
            }
            var right_end = right_start;
            while (right_end < input.len and
                (std.ascii.isAlphanumeric(input[right_end]) or
                    input[right_end] == '.' or input[right_end] == '%'))
            {
                right_end += 1;
            }
            if (right_end == right_start) {
                try self.appendTemporary(&output, input[index..end]);
                index = end;
                continue;
            }
            const grouped = try std.fmt.allocPrint(
                self.allocator,
                "({s})",
                .{input[index..right_end]},
            );
            defer self.allocator.free(grouped);
            var parser = NumericParser{
                .input = grouped,
                .max_depth = self.limits.max_expression_depth,
                .strict_units = self.options.strict_units,
            };
            if (parser.parse()) |numeric| {
                const serialized = try self.serializeNumeric(numeric);
                defer self.allocator.free(serialized);
                try self.appendTemporary(&output, serialized);
                index = right_end;
            } else |_| {
                try self.appendTemporary(&output, input[index..end]);
                index = end;
            }
        }
        return try output.toOwnedSlice(self.allocator);
    }

    fn collapseCalcParentheses(self: *Engine, input: []const u8) Error![]u8 {
        var current = try self.allocator.dupe(u8, input);
        var changed = true;
        while (changed) {
            changed = false;
            var output: std.ArrayList(u8) = .empty;
            errdefer output.deinit(self.allocator);
            var index: usize = 0;
            while (index < current.len) {
                if (current[index] != '(' or (index > 0 and
                    (std.ascii.isAlphanumeric(current[index - 1]) or
                        current[index - 1] == '-' or current[index - 1] == '_')))
                {
                    try output.append(self.allocator, current[index]);
                    index += 1;
                    continue;
                }
                const closing = matchingCloseParen(current, index) orelse {
                    try self.appendTemporary(&output, current[index..]);
                    index = current.len;
                    break;
                };
                const inner = std.mem.trim(
                    u8,
                    current[index + 1 .. closing],
                    " \t\r\n\x0c",
                );
                const duplicate = inner.len >= 2 and inner[0] == '(' and
                    matchingCloseParen(inner, 0) == inner.len - 1;
                const numeric_literal = isSimpleNumericLiteral(inner);
                if (duplicate or numeric_literal) {
                    try self.appendTemporary(
                        &output,
                        if (duplicate) inner else inner,
                    );
                    changed = true;
                } else {
                    try self.appendTemporary(&output, current[index .. closing + 1]);
                }
                index = closing + 1;
            }
            self.allocator.free(current);
            current = try output.toOwnedSlice(self.allocator);
        }
        return current;
    }

    fn parseLessColor(self: *Engine, input_raw: []const u8) Error!?native_value.Color {
        const input = std.mem.trim(u8, input_raw, " \t\r\n\x0c");
        if (native_color.parseLiteral(input)) |color| return color;
        if (functionArguments(input, "color")) |arguments| {
            return native_color.parseLiteral(stripQuotes(std.mem.trim(
                u8,
                input[arguments.start..arguments.end],
                " \t\r\n\x0c",
            )));
        }
        inline for (.{ "lighten", "darken", "fade" }) |name| {
            if (functionArguments(input, name)) |arguments| {
                var parts = try splitTopLevelAlloc(self.allocator, input, arguments, ',');
                defer parts.deinit(self.allocator);
                if (parts.items.len != 2) return null;
                const color_range = trimByteRange(input, parts.items[0]);
                const amount_range = trimByteRange(input, parts.items[1]);
                const color = try self.parseLessColor(input[color_range.start..color_range.end]) orelse
                    return null;
                const amount = parseLessScalar(input[amount_range.start..amount_range.end]) orelse
                    return null;
                if (std.mem.eql(u8, name, "fade")) {
                    const rgb = native_color.toRgb(color) catch return null;
                    return native_color.rgb(rgb[0], rgb[1], rgb[2], amount / 100) catch return null;
                }
                return adjustLessLightness(
                    color,
                    if (std.mem.eql(u8, name, "darken")) -amount else amount,
                );
            }
        }
        inline for (.{ "rgb", "rgba" }) |name| {
            if (functionArguments(input, name)) |arguments| {
                var parts = try splitColorArguments(self.allocator, input, arguments);
                defer parts.deinit(self.allocator);
                if (parts.items.len == 1 or parts.items.len == 2) {
                    const color_range = trimByteRange(input, parts.items[0]);
                    if (try self.parseLessColor(input[color_range.start..color_range.end])) |color| {
                        if (parts.items.len == 1) return color;
                        const alpha_range = trimByteRange(input, parts.items[1]);
                        var alpha = parseLessScalar(input[alpha_range.start..alpha_range.end]) orelse
                            return null;
                        if (std.mem.endsWith(u8, input[alpha_range.start..alpha_range.end], "%")) {
                            alpha /= 100;
                        }
                        const channels = native_color.toRgb(color) catch return null;
                        return native_color.rgb(channels[0], channels[1], channels[2], alpha) catch
                            return null;
                    }
                }
                if (parts.items.len != 3 and parts.items.len != 4) return null;
                var channels: [4]f64 = .{ 0, 0, 0, 1 };
                for (parts.items, 0..) |part, index| {
                    const range = trimByteRange(input, part);
                    const raw = input[range.start..range.end];
                    var parsed = parseLessScalar(raw) orelse return null;
                    if (index < 3 and std.mem.endsWith(u8, raw, "%")) {
                        parsed = parsed * 255 / 100;
                    } else if (index == 3 and std.mem.endsWith(u8, raw, "%")) {
                        parsed /= 100;
                    }
                    channels[index] = parsed;
                }
                return native_color.rgb(
                    channels[0],
                    channels[1],
                    channels[2],
                    channels[3],
                ) catch return null;
            }
        }
        inline for (.{ "hsl", "hsla" }) |name| {
            if (functionArguments(input, name)) |arguments| {
                var parts = try splitColorArguments(self.allocator, input, arguments);
                defer parts.deinit(self.allocator);
                if (parts.items.len == 1 or parts.items.len == 2) {
                    const color_range = trimByteRange(input, parts.items[0]);
                    if (try self.parseLessColor(input[color_range.start..color_range.end])) |color| {
                        var channels = native_color.toHsl(color) catch return null;
                        if (parts.items.len == 2) {
                            const alpha_range = trimByteRange(input, parts.items[1]);
                            channels[3] = parseLessScalar(
                                input[alpha_range.start..alpha_range.end],
                            ) orelse return null;
                        }
                        return native_color.hsl(
                            channels[0],
                            channels[1],
                            channels[2],
                            channels[3],
                        ) catch return null;
                    }
                }
                if (parts.items.len != 3 and parts.items.len != 4) return null;
                var channels: [4]f64 = .{ 0, 0, 0, 1 };
                for (parts.items, 0..) |part, index| {
                    const range = trimByteRange(input, part);
                    const raw = input[range.start..range.end];
                    var parsed = parseLessScalar(raw) orelse return null;
                    if (index == 3 and std.mem.endsWith(u8, raw, "%")) parsed /= 100;
                    channels[index] = parsed;
                }
                return native_color.hsl(
                    channels[0],
                    channels[1],
                    channels[2],
                    channels[3],
                ) catch return null;
            }
        }
        return null;
    }

    fn serializeLessRgb(self: *Engine, color: native_value.Color) Error![]u8 {
        const channels = native_color.toRgb(color) catch return error.InvalidOperation;
        const red = lessColorChannel(channels[0]);
        const green = lessColorChannel(channels[1]);
        const blue = lessColorChannel(channels[2]);
        const alpha = std.math.clamp(channels[3], 0, 1);
        if (@abs(alpha - 1) < 1e-9) {
            const result = try self.allocator.alloc(u8, 7);
            result[0] = '#';
            for ([_]u8{ red, green, blue }, 0..) |channel, index| {
                result[1 + index * 2] = hexDigit(channel >> 4);
                result[2 + index * 2] = hexDigit(channel & 0x0f);
            }
            return result;
        }
        const alpha_text = try self.formatNumber(alpha);
        defer self.allocator.free(alpha_text);
        return try std.fmt.allocPrint(
            self.allocator,
            "rgba({d}, {d}, {d}, {s})",
            .{ red, green, blue, alpha_text },
        );
    }

    fn serializeLessHsl(self: *Engine, color: native_value.Color) Error![]u8 {
        const channels = native_color.toHsl(color) catch return error.InvalidOperation;
        const hue = try self.formatNumber(channels[0]);
        defer self.allocator.free(hue);
        const saturation = try self.formatNumber(@round(channels[1] * 1e8) / 1e8);
        defer self.allocator.free(saturation);
        const lightness = try self.formatNumber(@round(channels[2] * 1e8) / 1e8);
        defer self.allocator.free(lightness);
        if (@abs(channels[3] - 1) < 1e-9) {
            return try std.fmt.allocPrint(
                self.allocator,
                "hsl({s}, {s}%, {s}%)",
                .{ hue, saturation, lightness },
            );
        }
        const alpha = try self.formatNumber(channels[3]);
        defer self.allocator.free(alpha);
        return try std.fmt.allocPrint(
            self.allocator,
            "hsla({s}, {s}%, {s}%, {s})",
            .{ hue, saturation, lightness, alpha },
        );
    }

    fn formatNumber(self: *Engine, value: f64) Error![]u8 {
        var buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
        const serialized = native_numeric.serialize(value, &buffer, true) catch
            return error.InvalidOperation;
        if (std.mem.startsWith(u8, serialized, ".")) {
            return try std.fmt.allocPrint(self.allocator, "0{s}", .{serialized});
        }
        if (std.mem.startsWith(u8, serialized, "-.")) {
            return try std.fmt.allocPrint(self.allocator, "-0{s}", .{serialized[1..]});
        }
        return try self.allocator.dupe(u8, serialized);
    }

    fn evaluateColorOperation(
        self: *Engine,
        input: []const u8,
    ) Error!?native_value.Color {
        const inner = if (input.len >= 2 and input[0] == '(' and input[input.len - 1] == ')')
            std.mem.trim(u8, input[1 .. input.len - 1], " \t\r\n\x0c")
        else
            std.mem.trim(u8, input, " \t\r\n\x0c");
        var cursor: usize = 0;
        var depth: usize = 0;
        var operator_index: ?usize = null;
        while (cursor < inner.len) : (cursor += 1) {
            switch (inner[cursor]) {
                '(' => depth += 1,
                ')' => depth -|= 1,
                '+', '-', '*', '/' => if (depth == 0 and cursor > 0) {
                    operator_index = cursor;
                },
                else => {},
            }
        }
        const index = operator_index orelse return self.parseLessColor(inner);
        const left_raw = std.mem.trim(u8, inner[0..index], " \t\r\n\x0c");
        const right_raw = std.mem.trim(u8, inner[index + 1 ..], " \t\r\n\x0c");
        const left = try self.colorOperand(left_raw) orelse return null;
        const right = try self.colorOperand(right_raw) orelse return null;
        const left_channels = native_color.toRgb(left) catch return null;
        const right_channels = native_color.toRgb(right) catch return null;
        var result: [3]f64 = undefined;
        for (&result, 0..) |*channel, channel_index| {
            channel.* = switch (inner[index]) {
                '+' => left_channels[channel_index] + right_channels[channel_index],
                '-' => left_channels[channel_index] - right_channels[channel_index],
                '*' => left_channels[channel_index] * right_channels[channel_index],
                '/' => if (@abs(right_channels[channel_index]) < 1e-12)
                    255
                else
                    left_channels[channel_index] / right_channels[channel_index],
                else => unreachable,
            };
        }
        return native_color.rgb(result[0], result[1], result[2], left_channels[3]) catch null;
    }

    fn colorOperand(self: *Engine, raw: []const u8) Error!?native_value.Color {
        if (raw.len >= 2 and raw[0] == '(' and raw[raw.len - 1] == ')') {
            return self.evaluateColorOperation(raw);
        }
        if (try self.parseLessColor(raw)) |color| return color;
        if (std.mem.indexOfAny(u8, raw, "+-*/") != null) {
            const grouped = try std.fmt.allocPrint(self.allocator, "({s})", .{raw});
            defer self.allocator.free(grouped);
            return self.evaluateColorOperation(grouped);
        }
        var numeric = raw;
        while (numeric.len > 0 and
            (std.ascii.isAlphabetic(numeric[numeric.len - 1]) or numeric[numeric.len - 1] == '%'))
        {
            numeric = numeric[0 .. numeric.len - 1];
        }
        const value = std.fmt.parseFloat(f64, numeric) catch return null;
        return native_color.rgb(value, value, value, 1) catch null;
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
        const scaled = number.value * 1e8;
        const rounded_value = if (std.math.isFinite(scaled)) @round(scaled) / 1e8 else number.value;
        const value = native_numeric.serialize(rounded_value, &number_buffer, false) catch
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
        if (span.source.eql(self.root_source) or self.inline_sources.contains(span.source)) {
            return try self.allocator.dupe(u8, value);
        }
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
        const previous_unorderable = self.guard_has_unorderable_operand;
        defer self.guard_has_unorderable_operand = previous_unorderable;
        self.guard_has_unorderable_operand = false;
        const guard_source = try self.sources.slice(span);
        const guard_tokens = try native_lexer.tokenizeAlloc(
            self.allocator,
            guard_source,
            .less,
            .{},
        );
        defer if (guard_tokens.len > 0) self.allocator.free(guard_tokens);
        for (guard_tokens) |token| {
            if (token.kind != .at_identifier) continue;
            const name = token.raw(guard_source);
            var holder = try self.environment.lookup(scope.cursor, name);
            if (holder == null) {
                if (self.scope_fallbacks.get(scope.cursor)) |fallback| {
                    holder = try self.environment.lookup(fallback, name);
                }
            }
            if (holder == null) holder = self.unlocked_bindings.get(name);
            if (holder) |binding_holder| {
                if (self.guard_unorderable_bindings.contains(binding_holder)) {
                    self.guard_has_unorderable_operand = true;
                    break;
                }
            }
        }
        const rendered = try self.renderOwned(span, scope.cursor, .at_rule);
        defer self.allocator.free(rendered);
        const evaluated = try self.rewriteListFunctionsOwned(span, rendered);
        defer self.allocator.free(evaluated);
        var raw = std.mem.trim(u8, evaluated, " \t\r\n\x0c");
        if (!std.mem.startsWith(u8, raw, "when")) return error.InvalidOperation;
        raw = std.mem.trim(u8, raw[4..], " \t\r\n\x0c");
        var alternatives = try splitTopLevelAlloc(
            self.allocator,
            raw,
            .{ .start = 0, .end = raw.len },
            ',',
        );
        defer alternatives.deinit(self.allocator);
        for (alternatives.items) |alternative| {
            if (try self.guardGroupMatches(raw[alternative.start..alternative.end])) return true;
        }
        return false;
    }

    fn guardGroupMatches(self: *Engine, input: []const u8) Error!bool {
        return self.guardExpressionMatches(input);
    }

    fn guardExpressionMatches(self: *Engine, input_raw: []const u8) Error!bool {
        var input = std.mem.trim(u8, input_raw, " \t\r\n\x0c");
        while (input.len >= 2 and input[0] == '(' and
            matchingCloseParen(input, 0) == input.len - 1)
        {
            input = std.mem.trim(u8, input[1 .. input.len - 1], " \t\r\n\x0c");
        }

        var cursor: usize = 0;
        if (findTopLevelWord(input, cursor, "or")) |_| {
            while (findTopLevelWord(input, cursor, "or")) |word| {
                if (try self.guardExpressionMatches(input[cursor..word.start])) return true;
                cursor = word.end;
            }
            return self.guardExpressionMatches(input[cursor..]);
        }

        cursor = 0;
        if (findTopLevelWord(input, cursor, "and")) |_| {
            while (findTopLevelWord(input, cursor, "and")) |word| {
                if (!try self.guardExpressionMatches(input[cursor..word.start])) return false;
                cursor = word.end;
            }
            return self.guardExpressionMatches(input[cursor..]);
        }

        return self.guardAtomMatches(input);
    }

    fn guardValuesEqual(
        self: *Engine,
        left_raw: []const u8,
        right_raw: []const u8,
    ) Error!bool {
        const left_grouped = stripOuterGrouping(std.mem.trim(u8, left_raw, " \t\r\n\x0c"));
        const right_grouped = stripOuterGrouping(std.mem.trim(u8, right_raw, " \t\r\n\x0c"));
        var left_flattened: ?[]u8 = null;
        defer if (left_flattened) |owned| self.allocator.free(owned);
        var right_flattened: ?[]u8 = null;
        defer if (right_flattened) |owned| self.allocator.free(owned);
        if (containsTopLevel(left_grouped, ',') != containsTopLevel(right_grouped, ',')) {
            left_flattened = try self.flattenListGroupingOwned(left_grouped);
            right_flattened = try self.flattenListGroupingOwned(right_grouped);
        }
        const left = std.mem.trim(
            u8,
            left_flattened orelse left_grouped,
            " \t\r\n\x0c",
        );
        const right = std.mem.trim(
            u8,
            right_flattened orelse right_grouped,
            " \t\r\n\x0c",
        );
        const left_comma = containsTopLevel(left, ',');
        const right_comma = containsTopLevel(right, ',');
        if (left_comma != right_comma) return false;

        var left_items = try splitLessListAlloc(self.allocator, left);
        defer left_items.deinit(self.allocator);
        var right_items = try splitLessListAlloc(self.allocator, right);
        defer right_items.deinit(self.allocator);
        if (left_items.items.len != right_items.items.len) return false;
        if (left_items.items.len > 1) {
            for (left_items.items, right_items.items) |left_item, right_item| {
                if (!try self.guardValuesEqual(
                    left[left_item.start..left_item.end],
                    right[right_item.start..right_item.end],
                )) return false;
            }
            return true;
        }

        var left_numeric = NumericParser{
            .input = left,
            .max_depth = self.limits.max_expression_depth,
            .strict_units = false,
        };
        var right_numeric = NumericParser{
            .input = right,
            .max_depth = self.limits.max_expression_depth,
            .strict_units = false,
        };
        if (left_numeric.parse()) |left_number| {
            if (right_numeric.parse()) |right_number| {
                return (native_numeric.compare(left_number, right_number) catch return false) == .equal;
            } else |_| {}
        } else |_| {}

        const left_quoted = left.len >= 2 and (left[0] == '\'' or left[0] == '"') and
            left[left.len - 1] == left[0];
        const right_quoted = right.len >= 2 and (right[0] == '\'' or right[0] == '"') and
            right[right.len - 1] == right[0];
        if (left_quoted != right_quoted) return false;
        return if (left_quoted)
            std.mem.eql(u8, stripQuotes(left), stripQuotes(right))
        else
            std.mem.eql(u8, left, right);
    }

    fn guardStringOrdering(
        left: []const u8,
        right: []const u8,
    ) ?std.math.Order {
        const left_trimmed = std.mem.trim(u8, left, " \t\r\n\x0c");
        const right_trimmed = std.mem.trim(u8, right, " \t\r\n\x0c");
        const left_quoted = left_trimmed.len >= 2 and
            (left_trimmed[0] == '\'' or left_trimmed[0] == '"') and
            left_trimmed[left_trimmed.len - 1] == left_trimmed[0];
        const right_quoted = right_trimmed.len >= 2 and
            (right_trimmed[0] == '\'' or right_trimmed[0] == '"') and
            right_trimmed[right_trimmed.len - 1] == right_trimmed[0];
        if (!left_quoted or !right_quoted) return null;
        return std.mem.order(u8, stripQuotes(left_trimmed), stripQuotes(right_trimmed));
    }

    fn guardConjunctionMatches(self: *Engine, input: []const u8) Error!bool {
        var cursor: usize = 0;
        while (findTopLevelWord(input, cursor, "and")) |word| {
            if (!try self.guardAtomMatches(input[cursor..word.start])) return false;
            cursor = word.end;
        }
        return self.guardAtomMatches(input[cursor..]);
    }

    fn guardAtomMatches(self: *Engine, input_raw: []const u8) Error!bool {
        var input = std.mem.trim(u8, input_raw, " \t\r\n\x0c");
        var negate = false;
        while (true) {
            if (std.mem.startsWith(u8, input, "not") and input.len > 3 and
                (std.ascii.isWhitespace(input[3]) or input[3] == '('))
            {
                negate = !negate;
                input = std.mem.trim(u8, input[3..], " \t\r\n\x0c");
                continue;
            }
            break;
        }
        if (input.len >= 2 and input[0] == '(' and
            matchingCloseParen(input, 0) == input.len - 1)
        {
            const grouped = try self.guardExpressionMatches(input[1 .. input.len - 1]);
            return if (negate) !grouped else grouped;
        }
        const result = if (findComparison(input)) |comparison| blk: {
            const left_raw = std.mem.trim(u8, input[0..comparison.index], " \t\r\n\x0c");
            const right_raw = std.mem.trim(
                u8,
                input[comparison.index + comparison.length ..],
                " \t\r\n\x0c",
            );
            const left = try self.guardOperandOwned(left_raw);
            defer self.allocator.free(left);
            const right = try self.guardOperandOwned(right_raw);
            defer self.allocator.free(right);
            var left_numeric = NumericParser{
                .input = left,
                .max_depth = self.limits.max_expression_depth,
                .strict_units = false,
            };
            var right_numeric = NumericParser{
                .input = right,
                .max_depth = self.limits.max_expression_depth,
                .strict_units = false,
            };
            if (left_numeric.parse()) |left_number| {
                if (right_numeric.parse()) |right_number| {
                    if (self.guard_has_unorderable_operand and
                        comparison.kind != .equal and comparison.kind != .not_equal)
                    {
                        break :blk false;
                    }
                    const ordering = native_numeric.compare(left_number, right_number) catch
                        break :blk false;
                    break :blk switch (comparison.kind) {
                        .less => ordering == .less,
                        .less_equal => ordering != .greater,
                        .greater => ordering == .greater,
                        .greater_equal => ordering != .less,
                        .equal => ordering == .equal,
                        .not_equal => ordering != .equal,
                    };
                } else |_| {}
            } else |_| {}
            if (comparison.kind != .equal and comparison.kind != .not_equal) {
                if (guardStringOrdering(left, right)) |ordering| {
                    break :blk switch (comparison.kind) {
                        .less => ordering == .lt,
                        .less_equal => ordering != .gt,
                        .greater => ordering == .gt,
                        .greater_equal => ordering != .lt,
                        else => unreachable,
                    };
                }
                break :blk false;
            }
            const equal = try self.guardValuesEqual(left, right);
            break :blk if (comparison.kind == .not_equal) !equal else equal;
        } else blk: {
            const value = try self.guardOperandOwned(input);
            defer self.allocator.free(value);
            break :blk std.ascii.eqlIgnoreCase(
                std.mem.trim(u8, value, " \t\r\n\x0c"),
                "true",
            );
        };
        return if (negate) !result else result;
    }

    fn guardOperandOwned(self: *Engine, input: []const u8) Error![]u8 {
        const trimmed = std.mem.trim(u8, input, " \t\r\n\x0c");
        if (trimmed.len >= 3 and trimmed[0] == '~' and
            (trimmed[1] == '\'' or trimmed[1] == '"') and
            trimmed[trimmed.len - 1] == trimmed[1])
        {
            return try self.allocator.dupe(u8, trimmed[2 .. trimmed.len - 1]);
        }
        if (functionArguments(input, "lightness")) |arguments| {
            const color = try self.parseLessColor(std.mem.trim(
                u8,
                input[arguments.start..arguments.end],
                " \t\r\n\x0c",
            )) orelse return try self.allocator.dupe(u8, input);
            const hsl = native_color.toHsl(color) catch return try self.allocator.dupe(u8, input);
            const number = try self.formatNumber(hsl[2]);
            defer self.allocator.free(number);
            return try std.fmt.allocPrint(self.allocator, "{s}%", .{number});
        }
        inline for (.{
            "iscolor",
            "isstring",
            "isnumber",
            "ispixel",
            "ispercentage",
            "isem",
            "iskeyword",
            "isurl",
        }) |name| {
            if (functionArguments(input, name)) |arguments| {
                const raw = std.mem.trim(
                    u8,
                    input[arguments.start..arguments.end],
                    " \t\r\n\x0c",
                );
                const numeric = parseLessScalar(raw);
                const matches = if (std.mem.eql(u8, name, "iscolor"))
                    (try self.parseLessColor(raw)) != null
                else if (std.mem.eql(u8, name, "isstring"))
                    raw.len >= 2 and (raw[0] == '\'' or raw[0] == '"')
                else if (std.mem.eql(u8, name, "isnumber"))
                    numeric != null
                else if (std.mem.eql(u8, name, "ispixel"))
                    numeric != null and std.mem.endsWith(u8, raw, "px")
                else if (std.mem.eql(u8, name, "ispercentage"))
                    numeric != null and std.mem.endsWith(u8, raw, "%")
                else if (std.mem.eql(u8, name, "isem"))
                    numeric != null and std.mem.endsWith(u8, raw, "em")
                else if (std.mem.eql(u8, name, "isurl"))
                    functionArguments(raw, "url") != null
                else
                    numeric == null and native_color.parseLiteral(raw) == null and
                        !(raw.len >= 2 and (raw[0] == '\'' or raw[0] == '"'));
                return try self.allocator.dupe(u8, if (matches) "true" else "false");
            }
        }
        if (functionArguments(input, "default") != null) {
            return try self.allocator.dupe(
                u8,
                if (self.default_guard_value) "true" else "false",
            );
        }
        return try self.allocator.dupe(u8, input);
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
        const name = normalizeReferenceName(raw_name) catch {
            try self.reportUndefined(raw_name, use_span);
            return error.UndefinedVariable;
        };
        var holder_optional = try self.environment.lookup(scope, name);
        if (holder_optional == null) {
            if (self.scope_fallbacks.get(scope)) |fallback| {
                holder_optional = try self.environment.lookup(fallback, name);
            }
        }
        if (holder_optional == null) holder_optional = self.unlocked_bindings.get(name);
        const holder = holder_optional orelse {
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
        const rendered = try self.renderOwned(
            binding.expression,
            binding.definition_scope,
            .binding_value,
        );
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

fn appendOwnedString(
    allocator: std.mem.Allocator,
    output: *std.ArrayList([]u8),
    input: []const u8,
) std.mem.Allocator.Error!void {
    const owned = try allocator.dupe(u8, input);
    errdefer allocator.free(owned);
    try output.append(allocator, owned);
}

const ComparisonKind = enum {
    less,
    less_equal,
    greater,
    greater_equal,
    equal,
    not_equal,
};

const Comparison = struct {
    index: usize,
    length: usize,
    kind: ComparisonKind,
};

const WordRange = struct {
    start: usize,
    end: usize,
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
            const left = result;
            var left_numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
            var left_denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
            var right_numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
            var right_denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
            const left_number = try left.toNumber(&left_numerator, &left_denominator);
            const right_number = try right.toNumber(&right_numerator, &right_denominator);
            const collapse_css_units = !left.isDimensionless() and
                !right.isDimensionless() and left.isCssNumber() and right.isCssNumber() and
                left_number.numerator_units.len == 1 and
                right_number.numerator_units.len == 1 and
                isLessMultiplicativeUnit(left_number.numerator_units[0]) and
                isLessMultiplicativeUnit(right_number.numerator_units[0]);
            if (collapse_css_units) {
                if (operation == '/' and right.value == 0) return error.DivisionByZero;
                result = try native_numeric.Numeric.init(
                    if (operation == '*') left.value * right.value else left.value / right.value,
                    left_number.numerator_units[0],
                );
            } else {
                result = try native_numeric.multiply(left, right, operation);
            }
        }
    }

    fn parsePrimary(self: *NumericParser, depth: u16) ParseError!native_numeric.Numeric {
        self.skipWhitespace();
        if (self.peek() == '+' or self.peek() == '-') {
            const sign = self.peek();
            const saved = self.cursor;
            self.cursor += 1;
            self.skipWhitespace();
            if (self.peek() == '(') {
                const grouped = try self.parsePrimary(depth);
                if (sign == '+') return grouped;
                return try native_numeric.multiply(
                    try native_numeric.Numeric.init(-1, null),
                    grouped,
                    '*',
                );
            }
            self.cursor = saved;
        }
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
    if (std.mem.startsWith(u8, input, "@{") or
        std.mem.startsWith(u8, input, "${")) return null;
    var end: usize = 0;
    while (end < input.len and input[end] != '(' and
        !std.ascii.isWhitespace(input[end])) : (end += 1)
    {}
    if (end == 0 or (input[0] != '.' and input[0] != '#' and input[0] != '@')) {
        return null;
    }
    return input[0..end];
}

fn mixinNameIsCompound(name: []const u8) bool {
    if (name.len < 2) return false;
    for (name[1..]) |byte| {
        if (byte == '.' or byte == '#') return true;
    }
    return false;
}

fn mixinCallNeedsQualifiedLookup(raw: []const u8) bool {
    const prefix_end = std.mem.lastIndexOfScalar(u8, raw, '(') orelse
        (std.mem.indexOfScalar(u8, raw, ';') orelse raw.len);
    const prefix = std.mem.trim(u8, raw[0..prefix_end], " \t\r\n\x0c");
    const name = callableName(prefix) orelse return false;
    if (mixinNameIsCompound(name)) return true;
    const suffix = std.mem.trim(u8, prefix[name.len..], " \t\r\n\x0c");
    return suffix.len > 0 and
        (suffix[0] == '.' or suffix[0] == '#' or suffix[0] == '>');
}

fn startsFunctionAt(input: []const u8, start: usize, name: []const u8) bool {
    if (start + name.len >= input.len or
        !std.ascii.eqlIgnoreCase(input[start .. start + name.len], name) or
        input[start + name.len] != '(')
    {
        return false;
    }
    return start == 0 or (!std.ascii.isAlphanumeric(input[start - 1]) and
        input[start - 1] != '_' and input[start - 1] != '-');
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
                const trailing = std.mem.trim(
                    u8,
                    raw[index + 1 ..],
                    " \t\r\n\x0c;",
                );
                if (trailing.len != 0 and !std.mem.eql(u8, trailing, "!important")) {
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

fn findLastTopLevelByte(raw: []const u8, needle: u8) ?usize {
    var result: ?usize = null;
    var depth: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
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
        if (byte == needle and depth == 0) result = index;
    }
    return result;
}

fn splitLessListAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
) std.mem.Allocator.Error!std.ArrayList(ByteRange) {
    const bounds = ByteRange{ .start = 0, .end = raw.len };
    if (findTopLevelByte(raw, bounds, ',') != null) {
        var parts = try splitTopLevelAlloc(allocator, raw, bounds, ',');
        var index: usize = 0;
        while (index < parts.items.len) {
            const part = trimByteRange(raw, parts.items[index]);
            if (part.start == part.end) {
                _ = parts.orderedRemove(index);
            } else {
                parts.items[index] = part;
                index += 1;
            }
        }
        return parts;
    }
    if (findTopLevelByte(raw, bounds, ';') != null) {
        var parts = try splitTopLevelAlloc(allocator, raw, bounds, ';');
        var index: usize = 0;
        while (index < parts.items.len) {
            const part = trimByteRange(raw, parts.items[index]);
            if (part.start == part.end) {
                _ = parts.orderedRemove(index);
            } else {
                parts.items[index] = part;
                index += 1;
            }
        }
        return parts;
    }
    var result: std.ArrayList(ByteRange) = .empty;
    errdefer result.deinit(allocator);
    const trimmed = trimByteRange(raw, bounds);
    if (trimmed.start == trimmed.end) return result;
    var depth: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    var start: ?usize = null;
    var index = trimmed.start;
    while (index <= trimmed.end) : (index += 1) {
        const byte = if (index < trimmed.end) raw[index] else 0;
        if (quote != 0) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == quote) {
                quote = 0;
            }
        } else if (byte == '\'' or byte == '"') {
            quote = byte;
        } else {
            switch (byte) {
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -|= 1,
                else => {},
            }
        }
        const separator = index == trimmed.end or
            (quote == 0 and depth == 0 and std.ascii.isWhitespace(byte));
        if (separator) {
            if (start) |item_start| {
                try result.append(allocator, .{ .start = item_start, .end = index });
                start = null;
            }
        } else if (start == null) {
            start = index;
        }
    }
    return result;
}

fn splitColorArguments(
    allocator: std.mem.Allocator,
    raw: []const u8,
    bounds: ByteRange,
) std.mem.Allocator.Error!std.ArrayList(ByteRange) {
    var comma_parts = try splitTopLevelAlloc(allocator, raw, bounds, ',');
    if (comma_parts.items.len != 1 or
        std.mem.indexOfScalar(u8, raw[bounds.start..bounds.end], ',') != null)
    {
        return comma_parts;
    }
    comma_parts.deinit(allocator);

    var result: std.ArrayList(ByteRange) = .empty;
    errdefer result.deinit(allocator);
    var start: ?usize = null;
    var depth: usize = 0;
    var index = bounds.start;
    while (index <= bounds.end) : (index += 1) {
        const byte = if (index < bounds.end) raw[index] else 0;
        if (byte == '(') depth += 1;
        if (byte == ')') depth -|= 1;
        const separator = depth == 0 and
            (index == bounds.end or std.ascii.isWhitespace(byte) or byte == '/');
        if (separator) {
            if (start) |item_start| {
                try result.append(allocator, .{ .start = item_start, .end = index });
                start = null;
            }
            continue;
        }
        if (start == null) start = index;
    }
    return result;
}

fn parseLessScalar(raw_input: []const u8) ?f64 {
    var raw = std.mem.trim(u8, raw_input, " \t\r\n\x0c");
    if (std.mem.endsWith(u8, raw, "%")) raw = raw[0 .. raw.len - 1];
    if (std.mem.endsWith(u8, raw, "deg")) raw = raw[0 .. raw.len - 3];
    return std.fmt.parseFloat(f64, raw) catch null;
}

fn simpleUnitSuffix(input: []const u8) ?[]const u8 {
    var index = input.len;
    while (index > 0 and
        (std.ascii.isAlphabetic(input[index - 1]) or input[index - 1] == '%'))
    {
        index -= 1;
    }
    return if (index < input.len) input[index..] else null;
}

fn stripNumericUnitsOwned(
    allocator: std.mem.Allocator,
    input: []const u8,
) std.mem.Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        try output.append(allocator, byte);
        index += 1;
        if (!std.ascii.isDigit(byte) and byte != '.') continue;
        while (index < input.len and
            (std.ascii.isAlphabetic(input[index]) or input[index] == '%'))
        {
            index += 1;
        }
    }
    return output.toOwnedSlice(allocator);
}

fn lessColorChannel(value: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 255)));
}

fn adjustLessLightness(
    color: native_value.Color,
    amount: f64,
) ?native_value.Color {
    const channels = native_color.toHsl(color) catch return null;
    const hue = @mod(channels[0], 360) / 360;
    const saturation = std.math.clamp(channels[1] / 100, 0, 1);
    const lightness = std.math.clamp(channels[2] / 100 + amount / 100, 0, 1);
    const maximum = if (lightness <= 0.5)
        lightness * (saturation + 1)
    else
        lightness + saturation - lightness * saturation;
    const minimum = lightness * 2 - maximum;
    return native_color.rgb(
        lessHslChannel(minimum, maximum, hue + 1.0 / 3.0) * 255,
        lessHslChannel(minimum, maximum, hue) * 255,
        lessHslChannel(minimum, maximum, hue - 1.0 / 3.0) * 255,
        channels[3],
    ) catch null;
}

fn lessHslChannel(minimum: f64, maximum: f64, input_hue: f64) f64 {
    const hue = if (input_hue < 0)
        input_hue + 1
    else if (input_hue > 1)
        input_hue - 1
    else
        input_hue;
    if (hue * 6 < 1) return minimum + (maximum - minimum) * hue * 6;
    if (hue * 2 < 1) return maximum;
    if (hue * 3 < 2) return minimum + (maximum - minimum) * (2.0 / 3.0 - hue) * 6;
    return minimum;
}

fn matchingCloseParen(input: []const u8, opening: usize) ?usize {
    if (opening >= input.len or input[opening] != '(') return null;
    var depth: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    for (input[opening..], opening..) |byte, index| {
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
            if (depth == 0) return index;
        }
    }
    return null;
}

fn isSimpleNumericLiteral(input: []const u8) bool {
    if (input.len == 0) return false;
    var index: usize = 0;
    if (input[index] == '+' or input[index] == '-') index += 1;
    var saw_digit = false;
    while (index < input.len and std.ascii.isDigit(input[index])) : (index += 1) {
        saw_digit = true;
    }
    if (index < input.len and input[index] == '.') {
        index += 1;
        while (index < input.len and std.ascii.isDigit(input[index])) : (index += 1) {
            saw_digit = true;
        }
    }
    if (!saw_digit) return false;
    while (index < input.len and
        (std.ascii.isAlphabetic(input[index]) or input[index] == '%')) : (index += 1)
    {}
    return index == input.len;
}

fn blankCommentsOwned(
    allocator: std.mem.Allocator,
    raw: []const u8,
) ![]u8 {
    const result = try allocator.dupe(u8, raw);
    errdefer allocator.free(result);
    const tokens = try native_lexer.tokenizeAlloc(allocator, raw, .less, .{});
    defer if (tokens.len > 0) allocator.free(tokens);
    for (tokens) |token| {
        if (token.kind != .comment) continue;
        @memset(result[token.span.start..token.span.end], ' ');
    }
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

fn removeEmptyRanges(raw: []const u8, ranges: *std.ArrayList(ByteRange)) void {
    var index: usize = 0;
    while (index < ranges.items.len) {
        const trimmed = trimByteRange(raw, ranges.items[index]);
        if (trimmed.start == trimmed.end) {
            _ = ranges.orderedRemove(index);
        } else {
            ranges.items[index] = trimmed;
            index += 1;
        }
    }
}

fn stripOuterGrouping(input: []const u8) []const u8 {
    if (input.len >= 2 and input[0] == '(' and
        matchingCloseParen(input, 0) == input.len - 1)
    {
        return std.mem.trim(u8, input[1 .. input.len - 1], " \t\r\n\x0c");
    }
    return input;
}

fn compactMixinSelectorOwned(
    allocator: std.mem.Allocator,
    selector: []const u8,
) std.mem.Allocator.Error![]u8 {
    var compact: std.ArrayList(u8) = .empty;
    errdefer compact.deinit(allocator);
    for (selector) |byte| {
        if (byte == '&' or std.ascii.isWhitespace(byte)) continue;
        try compact.append(allocator, byte);
    }
    return try compact.toOwnedSlice(allocator);
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

fn replaceAllSelectorTargetsOwned(
    allocator: std.mem.Allocator,
    selector: []const u8,
    target: []const u8,
    extender: []const u8,
) std.mem.Allocator.Error!?[]u8 {
    if (target.len == 0) return null;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var cursor: usize = 0;
    var search_cursor: usize = 0;
    var replaced = false;
    while (std.mem.indexOfPos(u8, selector, search_cursor, target)) |index| {
        const end = index + target.len;
        const before_ok = index == 0 or !selectorNameByte(selector[index - 1]) or
            !selectorNameByte(target[0]);
        const after_ok = end == selector.len or !selectorNameByte(selector[end]) or
            !selectorNameByte(target[target.len - 1]);
        if (before_ok and after_ok) {
            try output.appendSlice(allocator, selector[cursor..index]);
            try output.appendSlice(allocator, extender);
            cursor = end;
            replaced = true;
            search_cursor = end;
            continue;
        }
        search_cursor = index + 1;
    }
    if (!replaced) {
        output.deinit(allocator);
        return null;
    }
    try output.appendSlice(allocator, selector[cursor..]);
    return try output.toOwnedSlice(allocator);
}

fn selectorContainsTarget(selector: []const u8, target: []const u8) bool {
    if (target.len == 0) return false;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, selector, cursor, target)) |index| {
        const end = index + target.len;
        const before_ok = index == 0 or !selectorNameByte(selector[index - 1]) or
            !selectorNameByte(target[0]);
        const after_ok = end == selector.len or !selectorNameByte(selector[end]) or
            !selectorNameByte(target[target.len - 1]);
        if (before_ok and after_ok) return true;
        cursor = index + 1;
    }
    return false;
}

fn selectorNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '\\';
}

fn extendContext(parent: u64, node_id: native_syntax.NodeId) u64 {
    return (parent *% 0x9e3779b97f4a7c15) ^ (@as(u64, node_id.value) + 1);
}

fn looksNumeric(raw: []const u8) bool {
    return raw.len > 0 and (std.ascii.isDigit(raw[0]) or raw[0] == '.' or
        raw[0] == '(' or raw[0] == '+' or raw[0] == '-');
}

fn isLessMultiplicativeUnit(unit: []const u8) bool {
    inline for (.{
        "%",    "px",   "em",   "rem",  "ex",  "ch",   "cap", "ic", "lh", "rlh",
        "cm",   "mm",   "q",    "in",   "pt",  "pc",   "vw",  "vh", "vi", "vb",
        "vmin", "vmax", "deg",  "grad", "rad", "turn", "s",   "ms", "Hz", "kHz",
        "dpi",  "dpcm", "dppx", "x",
    }) |known| {
        if (std.mem.eql(u8, unit, known)) return true;
    }
    return false;
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

fn findComparison(raw: []const u8) ?Comparison {
    for (raw, 0..) |byte, index| {
        if (byte == '!' and index + 1 < raw.len and raw[index + 1] == '=') {
            return .{ .index = index, .length = 2, .kind = .not_equal };
        }
        if (byte != '<' and byte != '>' and byte != '=') continue;
        if (byte == '=' and index + 1 < raw.len and
            (raw[index + 1] == '<' or raw[index + 1] == '>'))
        {
            return .{
                .index = index,
                .length = 2,
                .kind = if (raw[index + 1] == '<') .less_equal else .greater_equal,
            };
        }
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

fn findTopLevelWord(input: []const u8, start: usize, word: []const u8) ?WordRange {
    var depth: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    var index = start;
    while (index + word.len <= input.len) : (index += 1) {
        const byte = input[index];
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
        if (byte == '(' or byte == '[' or byte == '{') depth += 1;
        if (byte == ')' or byte == ']' or byte == '}') depth -|= 1;
        if (depth != 0 or !std.ascii.eqlIgnoreCase(input[index .. index + word.len], word)) {
            continue;
        }
        const before_ok = index == 0 or std.ascii.isWhitespace(input[index - 1]);
        const after = index + word.len;
        const after_ok = after == input.len or std.ascii.isWhitespace(input[after]);
        if (before_ok and after_ok) return .{ .start = index, .end = after };
    }
    return null;
}

fn normalizeVariableName(raw: []const u8) error{InvalidDocument}![]const u8 {
    if (raw.len < 2 or raw[0] != '@' or !validBareVariableName(raw[1..])) {
        return error.InvalidDocument;
    }
    return raw;
}

fn normalizeReferenceName(raw: []const u8) error{InvalidDocument}![]const u8 {
    if (raw.len < 2 or (raw[0] != '@' and raw[0] != '$') or
        !validBareVariableName(raw[1..]))
    {
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

fn isUnorderableGuardArgument(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\x0c");
    return (trimmed.len >= 2 and trimmed[0] == '~' and
        (trimmed[1] == '\'' or trimmed[1] == '"')) or
        functionArguments(trimmed, "e") != null;
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

fn usesKeywordCommentList(keyword: []const u8) bool {
    return native_lexer.identifierEqlIgnoreCaseAscii(keyword, "@import") or
        native_lexer.identifierEqlIgnoreCaseAscii(keyword, "@media") or
        std.mem.endsWith(u8, keyword, "keyframes");
}

fn isCssWhitespace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r', 0x0c => true,
        else => false,
    };
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
