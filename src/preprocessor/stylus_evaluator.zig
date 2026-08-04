//! Private bounded semantic evaluator for native Stylus syntax.
//!
//! The evaluator owns a fixed four-slice implementation plan. Its terminal
//! slice adds confined deterministic imports, require-once expansion, sorted
//! local globs, source-owned diagnostics, dependency edges, and imported
//! mappings. Project plugins and custom evaluator hooks are permanently
//! outside this module's execution boundary.
//! In particular, external custom evaluator hooks are permanently disabled.

const std = @import("std");
const native_environment = @import("environment.zig");
const native_evaluator = @import("evaluator.zig");
const native_lexer = @import("lexer.zig");
const native_color = @import("sass_color.zig");
const native_numeric = @import("sass_numeric.zig");
const native_resolver = @import("resolver.zig");
const native_source = @import("source.zig");
const native_stylus = @import("stylus.zig");
const native_syntax = @import("syntax.zig");
const native_value = @import("value.zig");

const hard_source_bytes = 10 * 1024 * 1024;
const hard_nodes = 1_000_000;
const hard_expression_depth: u16 = 64;
const hard_call_depth: u16 = 1_024;
const hard_loop_iterations: usize = 10_000_000;
const hard_selectors = 1_000_000;
const hard_temporary_bytes = 20 * 1024 * 1024;
const hard_import_statements = 200_000;

pub const Limits = struct {
    max_source_bytes: usize = hard_source_bytes,
    max_nodes: usize = 200_000,
    environment: native_environment.Limits = .{},
    values: native_value.Limits = .{},
    max_expression_depth: u16 = 32,
    max_call_depth: u16 = 128,
    max_loop_iterations: usize = 1_000_000,
    max_selectors: usize = 200_000,
    max_temporary_bytes: usize = 10 * 1024 * 1024,
};

pub const Error = native_environment.Error ||
    native_evaluator.Error ||
    native_lexer.Error ||
    native_resolver.Error ||
    native_source.Error ||
    native_stylus.Error ||
    native_syntax.Error ||
    native_value.Error || error{
    ExpressionDepthExceeded,
    InvalidDocument,
    InvalidArguments,
    InvalidImport,
    InvalidLimits,
    InvalidOperation,
    NodeLimitExceeded,
    PluginDisabled,
    SelectorLimitExceeded,
    SourceLimitExceeded,
    TemporaryLimitExceeded,
    UndefinedCallable,
    UndefinedVariable,
    UnsupportedFeature,
};

pub fn evaluate(
    sources: *native_source.Table,
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
        expanded_document = expander.expand(document) catch |failure| switch (failure) {
            error.SyntaxDepthExceeded,
            error.SyntaxEdgeLimitExceeded,
            error.SyntaxNodeLimitExceeded,
            => {
                try transaction.report(
                    .err,
                    .resource_limit,
                    root.span,
                    "native Stylus imported syntax limit exceeded",
                    &.{},
                );
                return failure;
            },
            else => return failure,
        };
    }
    const active_document = if (expanded_document) |*expanded| expanded else document;
    if (active_document.nodes().len > limits.max_nodes) {
        try transaction.report(
            .err,
            .resource_limit,
            root.span,
            "native Stylus evaluator node limit exceeded",
            &.{},
        );
        return error.NodeLimitExceeded;
    }

    try transaction.consumeOperations(@intCast(active_document.nodes().len));
    try rejectUsePlugins(sources, root.span, input, transaction);
    const semantic = expanded_document != null or
        try requiresSemanticEvaluation(active_document, input);
    try preflightStatements(
        active_document,
        try active_document.children(active_document.root),
        transaction,
        semantic,
    );
    if (semantic) try rejectDeferredBuiltins(sources, active_document, transaction);
    if (!semantic) {
        try transaction.emitMapped(root.span, null, input);
        return;
    }

    var engine = try Engine.init(
        transaction.allocator,
        sources,
        active_document,
        transaction,
        limits,
    );
    defer engine.deinit();
    try engine.run();
}

fn containsImports(document: *const native_syntax.Document) bool {
    for (document.nodes()) |node| {
        if (node.kind == .import) return true;
    }
    return false;
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
        limits.max_call_depth == 0 or limits.max_call_depth > hard_call_depth or
        limits.max_loop_iterations == 0 or
        limits.max_loop_iterations > hard_loop_iterations or
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
    if (try containsSemanticStatement(document, try document.children(document.root))) return true;
    if (std.mem.indexOfScalar(u8, input, '{') != null) return false;
    for (document.nodes(), 0..) |node, index| {
        if (node.kind != .rule) continue;
        if ((try document.children(.{ .value = @intCast(index) })).len > 1) return true;
    }
    return false;
}

fn containsSemanticStatement(
    document: *const native_syntax.Document,
    statements: []const native_syntax.NodeId,
) Error!bool {
    for (statements) |statement_id| {
        const statement = try document.get(statement_id);
        switch (statement.kind) {
            .variable,
            .function,
            .mixin,
            .conditional,
            .loop,
            .return_statement,
            .expression,
            => return true,
            else => {},
        }
        for (try document.children(statement_id)) |child_id| {
            const child = try document.get(child_id);
            if (child.kind == .block and
                try containsSemanticStatement(document, try document.children(child_id)))
            {
                return true;
            }
        }
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

const ParsedImport = struct {
    target: []const u8,
    require_once: bool,
};

const ImportExpander = struct {
    allocator: std.mem.Allocator,
    sources: *native_source.Table,
    transaction: *native_evaluator.Transaction,
    limits: Limits,
    builder: native_syntax.Builder,
    source_ids: std.StringHashMapUnmanaged(native_source.SourceId) = .empty,
    required_urls: std.StringHashMapUnmanaged(void) = .empty,
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
        self.required_urls.deinit(self.allocator);
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
        try self.appendStatements(
            document,
            try document.children(document.root),
            &children,
        );
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
        statements: []const native_syntax.NodeId,
        output: *std.ArrayList(native_syntax.NodeId),
    ) Error!void {
        for (statements) |statement_id| {
            const statement = document.get(statement_id) catch return error.InvalidDocument;
            if (statement.kind == .import) {
                try self.expandImport(document, statement_id, output);
            } else {
                try output.append(
                    self.allocator,
                    try self.cloneNode(document, statement_id),
                );
            }
        }
    }

    fn cloneNode(
        self: *ImportExpander,
        document: *const native_syntax.Document,
        node_id: native_syntax.NodeId,
    ) Error!native_syntax.NodeId {
        const node = document.get(node_id) catch return error.InvalidDocument;
        var children: std.ArrayList(native_syntax.NodeId) = .empty;
        defer children.deinit(self.allocator);
        const source_children = document.children(node_id) catch return error.InvalidDocument;
        if (node.kind == .block) {
            try self.appendStatements(document, source_children, &children);
        } else {
            for (source_children) |child_id| {
                try children.append(
                    self.allocator,
                    try self.cloneNode(document, child_id),
                );
            }
        }
        return self.builder.add(node.kind, node.span, node.text, children.items);
    }

    fn expandImport(
        self: *ImportExpander,
        document: *const native_syntax.Document,
        import_id: native_syntax.NodeId,
        output: *std.ArrayList(native_syntax.NodeId),
    ) Error!void {
        const import_node = document.get(import_id) catch return error.InvalidDocument;
        const text = import_node.text orelse return error.InvalidDocument;
        const parsed = parseImportDirective(try self.sources.slice(text)) orelse {
            try self.reportImport(text, "native Stylus import syntax is unsupported");
            return error.InvalidImport;
        };
        const parent_url = self.ancestry.items[self.ancestry.items.len - 1];
        if (std.mem.indexOfAny(u8, parsed.target, "*?") != null) {
            const pattern_url = importCandidateUrl(
                self.allocator,
                parent_url,
                parsed.target,
            ) catch |failure| return self.failLoad(failure, text);
            defer self.allocator.free(pattern_url);
            const session = try self.transaction.resolverSession();
            var matches = session.glob(pattern_url, self.ancestry.items) catch |failure| switch (failure) {
                error.Missing => {
                    try self.reportImport(text, "native Stylus import was not found");
                    return error.InvalidImport;
                },
                else => return self.failLoad(failure, text),
            };
            defer matches.deinit();
            if (matches.urls.len == 0) {
                try self.reportImport(text, "native Stylus import was not found");
                return error.InvalidImport;
            }
            for (matches.urls) |candidate_url| {
                const loaded = try self.loadAndAppend(
                    candidate_url,
                    parsed.require_once,
                    text,
                    output,
                );
                if (!loaded) return error.InvalidImport;
            }
            return;
        }

        var candidates: std.ArrayList([]u8) = .empty;
        defer {
            for (candidates.items) |candidate| self.allocator.free(candidate);
            candidates.deinit(self.allocator);
        }
        const extension = std.fs.path.extension(parsed.target);
        if (extension.len > 0) {
            try self.appendCandidate(
                &candidates,
                try importCandidateUrl(self.allocator, parent_url, parsed.target),
            );
        } else {
            const direct = try importCandidateUrl(self.allocator, parent_url, parsed.target);
            try self.appendCandidate(&candidates, direct);
            const with_extension = try std.fmt.allocPrint(
                self.allocator,
                "{s}.styl",
                .{parsed.target},
            );
            defer self.allocator.free(with_extension);
            try self.appendCandidate(
                &candidates,
                try importCandidateUrl(self.allocator, parent_url, with_extension),
            );
            const basename = std.fs.path.basename(parsed.target);
            const index_target = try std.fs.path.join(
                self.allocator,
                &.{ parsed.target, "index.styl" },
            );
            defer self.allocator.free(index_target);
            try self.appendCandidate(
                &candidates,
                try importCandidateUrl(self.allocator, parent_url, index_target),
            );
            if (basename.len > 0) {
                const named_file = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}.styl",
                    .{basename},
                );
                defer self.allocator.free(named_file);
                const named_target = try std.fs.path.join(
                    self.allocator,
                    &.{ parsed.target, named_file },
                );
                defer self.allocator.free(named_target);
                try self.appendCandidate(
                    &candidates,
                    try importCandidateUrl(self.allocator, parent_url, named_target),
                );
            }
        }
        for (candidates.items) |candidate_url| {
            if (try self.loadAndAppend(
                candidate_url,
                parsed.require_once,
                text,
                output,
            )) return;
        }
        try self.reportImport(text, "native Stylus import was not found");
        return error.InvalidImport;
    }

    fn appendCandidate(
        self: *ImportExpander,
        candidates: *std.ArrayList([]u8),
        candidate: []u8,
    ) Error!void {
        errdefer self.allocator.free(candidate);
        try candidates.append(self.allocator, candidate);
    }

    fn loadAndAppend(
        self: *ImportExpander,
        candidate_url: []const u8,
        require_once: bool,
        import_span: native_source.Span,
        output: *std.ArrayList(native_syntax.NodeId),
    ) Error!bool {
        const session = try self.transaction.resolverSession();
        var loaded = session.load(candidate_url, .{
            .kind = .import,
            .ancestry = self.ancestry.items,
        }) catch |failure| switch (failure) {
            error.IsDirectory, error.Missing => return false,
            else => return self.failLoad(failure, import_span),
        };
        defer loaded.deinit();
        if (require_once and self.required_urls.contains(loaded.url)) return true;

        const source_id = self.source_ids.get(loaded.url) orelse source: {
            const added = self.sources.add(loaded.url, loaded.contents) catch |failure| {
                if (failure == error.OutOfMemory) return error.OutOfMemory;
                try self.transaction.report(
                    .err,
                    .resource_limit,
                    import_span,
                    "native Stylus imported source limit exceeded",
                    &.{},
                );
                return failure;
            };
            const source_file = try self.sources.get(added);
            try self.source_ids.put(self.allocator, source_file.name, added);
            break :source added;
        };
        const source_file = try self.sources.get(source_id);
        if (require_once) try self.required_urls.put(self.allocator, source_file.name, {});
        const full_span = try self.sources.span(source_id, 0, @intCast(source_file.bytes.len));
        try rejectUsePlugins(self.sources, full_span, source_file.bytes, self.transaction);

        var parser = native_stylus.Parser.init(
            self.allocator,
            self.sources,
            source_id,
            .{ .max_statements = @min(self.limits.max_nodes, hard_import_statements) },
            .{},
        ) catch |failure| {
            if (failure == error.OutOfMemory) return error.OutOfMemory;
            try self.transaction.report(
                .err,
                .resource_limit,
                import_span,
                "native Stylus imported parser limit exceeded",
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
        try self.appendStatements(
            &imported,
            try imported.children(imported.root),
            output,
        );
        return true;
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
                    "native Stylus import resource limit exceeded",
                    &.{},
                ) catch |err| return err;
                return failure;
            },
            error.Cycle => {
                self.reportImport(span, "native Stylus import cycle detected") catch |err|
                    return err;
                return error.InvalidImport;
            },
            else => {
                self.reportImport(span, "native Stylus import load was rejected") catch |err|
                    return err;
                return error.InvalidImport;
            },
        }
    }

    fn copyParserDiagnostics(
        self: *ImportExpander,
        diagnostics: []const @import("diagnostics.zig").Diagnostic,
    ) Error!void {
        for (diagnostics) |diagnostic| {
            var related: std.ArrayList(@import("diagnostics.zig").RelatedInput) = .empty;
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

fn parseImportDirective(raw_input: []const u8) ?ParsedImport {
    const raw = std.mem.trim(u8, raw_input, " \t\r\n\x0c;");
    const keyword: []const u8 = if (startsWordAscii(raw, "@import"))
        "@import"
    else if (startsWordAscii(raw, "@require"))
        "@require"
    else
        return null;
    const require_once = std.ascii.eqlIgnoreCase(keyword, "@require");
    const argument = std.mem.trim(u8, raw[keyword.len..], " \t\r\n\x0c;");
    if (argument.len < 2 or (argument[0] != '\'' and argument[0] != '"')) return null;
    const quote = argument[0];
    var escaped = false;
    var closing: ?usize = null;
    var index: usize = 1;
    while (index < argument.len) : (index += 1) {
        if (escaped) {
            escaped = false;
        } else if (argument[index] == '\\') {
            escaped = true;
        } else if (argument[index] == quote) {
            closing = index;
            break;
        }
    }
    const end = closing orelse return null;
    if (std.mem.trim(u8, argument[end + 1 ..], " \t\r\n\x0c;").len != 0) return null;
    const target = argument[1..end];
    if (target.len == 0 or std.mem.indexOfAny(u8, target, "\x00\r\n") != null or
        hasNonLocalScheme(target))
    {
        return null;
    }
    return .{ .target = target, .require_once = require_once };
}

fn importCandidateUrl(
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
    const absolute = if (std.fs.path.isAbsolute(target))
        try std.fs.path.resolve(allocator, &.{target})
    else
        try std.fs.path.resolve(allocator, &.{ parent_directory, target });
    defer allocator.free(absolute);
    return native_resolver.pathToFileUrl(allocator, absolute);
}

fn hasNonLocalScheme(target: []const u8) bool {
    return std.mem.indexOf(u8, target, "://") != null or
        std.mem.startsWith(u8, target, "//") or
        std.mem.startsWith(u8, target, "#");
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

const Call = struct {
    name: ByteRange,
    arguments: ByteRange,
};

const Definition = struct {
    name: ByteRange,
    parameters: ByteRange,
};

const Callable = struct {
    name: []const u8,
    node_id: native_syntax.NodeId,
    scope: native_environment.ScopeId,
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

const RuleOutput = struct {
    declarations: *std.ArrayList(RenderedDeclaration),
    nested: *std.ArrayList(NestedRule),
};

const Engine = struct {
    allocator: std.mem.Allocator,
    sources: *const native_source.Table,
    document: *const native_syntax.Document,
    transaction: *native_evaluator.Transaction,
    limits: Limits,
    values: native_value.Store,
    environment: native_environment.Environment,
    callables: std.ArrayList(Callable) = .empty,
    call_depth: u16 = 0,
    loop_iterations: usize = 0,
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
        self.callables.deinit(self.allocator);
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
                .function, .mixin => try self.registerCallable(child_id, scope),
                .rule => try self.emitRule(child_id, scope, null),
                .comment => {},
                .return_statement => {
                    try self.transaction.report(
                        .err,
                        .invalid_operation,
                        child.span,
                        "native Stylus return is only valid inside a function",
                        &.{},
                    );
                    return error.InvalidOperation;
                },
                else => return error.InvalidDocument,
            }
        }
    }

    fn registerCallable(
        self: *Engine,
        node_id: native_syntax.NodeId,
        scope: native_environment.ScopeId,
    ) Error!void {
        const node = try self.document.get(node_id);
        const text = node.text orelse return error.InvalidDocument;
        const raw = try self.sources.slice(text);
        const definition = parseDefinition(raw) orelse {
            try self.reportInvalidArguments(text);
            return error.InvalidArguments;
        };
        const name = raw[definition.name.start..definition.name.end];
        for (self.callables.items) |item| {
            if (std.mem.eql(u8, item.name, name)) {
                try self.transaction.report(
                    .err,
                    .duplicate_binding,
                    text,
                    "native Stylus callable is already defined",
                    &.{},
                );
                return error.InvalidArguments;
            }
        }
        try self.callables.append(self.allocator, .{
            .name = name,
            .node_id = node_id,
            .scope = scope,
        });
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
        scope.* = try self.setBinding(scope.*, assignment.name, evaluated, text);
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

        const returned = try self.executeStatements(
            try self.document.children(children[1]),
            &scope,
            .{ .declarations = &declarations, .nested = &nested },
            false,
        );
        if (returned != null) return error.InvalidDocument;

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

    fn executeStatements(
        self: *Engine,
        statements: []const native_syntax.NodeId,
        scope: *native_environment.ScopeId,
        output: ?RuleOutput,
        allow_return: bool,
    ) Error!?*const native_value.Value {
        var previous_condition: ?bool = null;
        for (statements) |statement_id| {
            const statement = try self.document.get(statement_id);
            switch (statement.kind) {
                .variable => {
                    previous_condition = null;
                    try self.assign(statement_id, scope);
                },
                .function, .mixin => {
                    previous_condition = null;
                    try self.registerCallable(statement_id, scope.*);
                },
                .declaration => {
                    previous_condition = null;
                    const destination = output orelse return error.InvalidDocument;
                    var declaration = try self.renderDeclaration(statement_id, scope.*);
                    errdefer declaration.deinit(self.allocator);
                    try destination.declarations.append(self.allocator, declaration);
                },
                .rule => {
                    previous_condition = null;
                    const destination = output orelse return error.InvalidDocument;
                    try destination.nested.append(
                        self.allocator,
                        .{ .id = statement_id, .scope = scope.* },
                    );
                },
                .expression => {
                    previous_condition = null;
                    const destination = output orelse return error.InvalidDocument;
                    try self.invokeMixinStatement(statement_id, scope, destination);
                },
                .conditional => {
                    const text = statement.text orelse return error.InvalidDocument;
                    const raw = std.mem.trim(
                        u8,
                        try self.sources.slice(text),
                        " \t\r\n\x0c;",
                    );
                    var selected = false;
                    if (startsWordAscii(raw, "else")) {
                        selected = !(previous_condition orelse {
                            try self.reportInvalidOperation(text);
                            return error.InvalidOperation;
                        });
                    } else {
                        const condition = parseConditionHeader(raw) orelse {
                            try self.reportInvalidOperation(text);
                            return error.InvalidOperation;
                        };
                        selected = try self.evaluateCondition(
                            text,
                            condition.expression,
                            scope.*,
                        );
                        if (condition.negated) selected = !selected;
                        previous_condition = selected;
                    }
                    if (startsWordAscii(raw, "else")) previous_condition = null;
                    if (!selected) continue;
                    const block = try self.statementBlock(statement_id);
                    var child_scope = self.environment.push(scope.*) catch |failure| {
                        try self.reportResource(
                            statement.span,
                            "native Stylus lexical scope limit exceeded",
                        );
                        return failure;
                    };
                    if (try self.executeStatements(
                        try self.document.children(block),
                        &child_scope,
                        output,
                        allow_return,
                    )) |returned| return returned;
                },
                .loop => {
                    previous_condition = null;
                    if (try self.executeLoop(statement_id, scope.*, output, allow_return)) |returned| {
                        return returned;
                    }
                },
                .return_statement => {
                    previous_condition = null;
                    if (!allow_return) {
                        try self.reportInvalidOperation(statement.span);
                        return error.InvalidOperation;
                    }
                    const text = statement.text orelse return error.InvalidDocument;
                    const raw = std.mem.trim(
                        u8,
                        try self.sources.slice(text),
                        " \t\r\n\x0c;",
                    );
                    if (!startsWordAscii(raw, "return")) return error.InvalidDocument;
                    const expression = std.mem.trim(u8, raw["return".len..], " \t\r\n\x0c");
                    if (expression.len == 0) return self.ownValue(text, .{ .null_value = {} });
                    return try self.evaluateValue(text, expression, scope.*, 0);
                },
                .comment => previous_condition = null,
                else => return error.InvalidDocument,
            }
        }
        return null;
    }

    fn statementBlock(
        self: *const Engine,
        statement_id: native_syntax.NodeId,
    ) Error!native_syntax.NodeId {
        const children = try self.document.children(statement_id);
        if (children.len == 0) return error.InvalidDocument;
        const block_id = children[children.len - 1];
        if ((try self.document.get(block_id)).kind != .block) return error.InvalidDocument;
        return block_id;
    }

    fn invokeMixinStatement(
        self: *Engine,
        statement_id: native_syntax.NodeId,
        scope: *native_environment.ScopeId,
        output: RuleOutput,
    ) Error!void {
        const statement = try self.document.get(statement_id);
        const text = statement.text orelse return error.InvalidDocument;
        const raw = std.mem.trim(u8, try self.sources.slice(text), " \t\r\n\x0c;");
        const call = parseCall(raw) orelse {
            try self.reportUndefinedCallable(text);
            return error.UndefinedCallable;
        };
        const returned = try self.invokeUserCallable(text, raw, call, scope.*, output, false);
        if (returned != null) return error.InvalidDocument;
    }

    fn invokeUserCallable(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        call: Call,
        caller_scope: native_environment.ScopeId,
        output: ?RuleOutput,
        require_return: bool,
    ) Error!?*const native_value.Value {
        const name = raw[call.name.start..call.name.end];
        const callable = self.findCallable(name) orelse {
            try self.reportUndefinedCallable(span);
            return error.UndefinedCallable;
        };
        if (self.call_depth >= self.limits.max_call_depth) {
            try self.transaction.report(
                .err,
                .call_limit,
                span,
                "native Stylus call depth exceeded",
                &.{},
            );
            return error.CallDepthExceeded;
        }
        self.call_depth += 1;
        self.transaction.enterCall() catch |failure| {
            self.call_depth -= 1;
            return failure;
        };
        defer {
            self.call_depth -= 1;
            self.transaction.leaveCall() catch {};
        }

        const definition_node = try self.document.get(callable.node_id);
        const definition_span = definition_node.text orelse return error.InvalidDocument;
        const definition_raw = try self.sources.slice(definition_span);
        const definition = parseDefinition(definition_raw) orelse return error.InvalidDocument;
        var parameters = try splitTopLevel(
            self.allocator,
            definition_raw[definition.parameters.start..definition.parameters.end],
            ',',
        );
        defer parameters.deinit(self.allocator);
        var arguments = try splitTopLevel(
            self.allocator,
            raw[call.arguments.start..call.arguments.end],
            ',',
        );
        defer arguments.deinit(self.allocator);
        if (definition.parameters.start == definition.parameters.end) parameters.clearRetainingCapacity();
        if (call.arguments.start == call.arguments.end) arguments.clearRetainingCapacity();
        if (parameters.items.len != arguments.items.len) {
            try self.reportInvalidArguments(span);
            return error.InvalidArguments;
        }

        var call_scope = self.environment.push(callable.scope) catch |failure| {
            try self.reportResource(span, "native Stylus lexical scope limit exceeded");
            return failure;
        };
        for (parameters.items, arguments.items) |parameter_range, argument_range| {
            const parameter = std.mem.trim(
                u8,
                definition_raw[definition.parameters.start + parameter_range.start .. definition.parameters.start + parameter_range.end],
                " \t\r\n\x0c",
            );
            if (!validVariableName(parameter)) {
                try self.reportInvalidArguments(definition_span);
                return error.InvalidArguments;
            }
            const argument_raw = raw[call.arguments.start + argument_range.start .. call.arguments.start + argument_range.end];
            const argument = try self.evaluateValue(span, argument_raw, caller_scope, 0);
            call_scope = try self.setBinding(call_scope, parameter, argument, span);
        }

        const block = try self.statementBlock(callable.node_id);
        const returned = try self.executeStatements(
            try self.document.children(block),
            &call_scope,
            output,
            true,
        );
        if (require_return and returned == null) {
            try self.reportInvalidOperation(span);
            return error.InvalidOperation;
        }
        return returned;
    }

    fn findCallable(self: *const Engine, name: []const u8) ?Callable {
        var index = self.callables.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.callables.items[index].name, name)) {
                return self.callables.items[index];
            }
        }
        return null;
    }

    fn executeLoop(
        self: *Engine,
        statement_id: native_syntax.NodeId,
        parent_scope: native_environment.ScopeId,
        output: ?RuleOutput,
        allow_return: bool,
    ) Error!?*const native_value.Value {
        const statement = try self.document.get(statement_id);
        const text = statement.text orelse return error.InvalidDocument;
        const raw = std.mem.trim(u8, try self.sources.slice(text), " \t\r\n\x0c;");
        const loop = parseLoop(raw) orelse {
            try self.reportInvalidOperation(text);
            return error.InvalidOperation;
        };
        var items = try splitTopLevelWhitespace(self.allocator, loop.items);
        defer items.deinit(self.allocator);
        const block = try self.statementBlock(statement_id);
        for (items.items) |item_range| {
            if (self.loop_iterations >= self.limits.max_loop_iterations) {
                try self.transaction.report(
                    .err,
                    .loop_limit,
                    text,
                    "native Stylus loop iteration limit exceeded",
                    &.{},
                );
                return error.LoopLimitExceeded;
            }
            self.loop_iterations += 1;
            try self.transaction.consumeLoopIterations(1);
            var loop_scope = self.environment.push(parent_scope) catch |failure| {
                try self.reportResource(text, "native Stylus lexical scope limit exceeded");
                return failure;
            };
            const item_raw = loop.items[item_range.start..item_range.end];
            const value = try self.evaluateValue(text, item_raw, parent_scope, 0);
            loop_scope = try self.setBinding(loop_scope, loop.name, value, text);
            if (try self.executeStatements(
                try self.document.children(block),
                &loop_scope,
                output,
                allow_return,
            )) |returned| return returned;
        }
        return null;
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
        if (parseDefinedTernary(raw)) |ternary| {
            const selected = if (try self.environment.lookup(scope, ternary.name) != null)
                ternary.when_defined
            else
                ternary.when_undefined;
            try self.transaction.consumeOperations(@intCast(raw.len - (selected.end - selected.start)));
            return self.evaluateValue(
                try self.relativeSpan(span, selected),
                raw[selected.start..selected.end],
                scope,
                depth + 1,
            );
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
        if (native_color.parseLiteral(input)) |color| {
            return self.ownValue(span, .{ .color = color });
        }

        if (parseCall(input)) |call| {
            const name = input[call.name.start..call.name.end];
            if (native_lexer.identifierEqlIgnoreCaseAscii(name, "length")) {
                return self.evaluateLengthBuiltin(span, input, call, scope);
            }
            if (native_lexer.identifierEqlIgnoreCaseAscii(name, "type")) {
                return self.evaluateTypeBuiltin(span, input, call, scope);
            }
            return (try self.invokeUserCallable(
                span,
                input,
                call,
                scope,
                null,
                true,
            )).?;
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

    fn evaluateLengthBuiltin(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        call: Call,
        scope: native_environment.ScopeId,
    ) Error!*const native_value.Value {
        _ = scope;
        var arguments = try splitTopLevel(
            self.allocator,
            raw[call.arguments.start..call.arguments.end],
            ',',
        );
        defer arguments.deinit(self.allocator);
        if (call.arguments.start == call.arguments.end) arguments.clearRetainingCapacity();
        if (arguments.items.len != 1) {
            try self.reportInvalidArguments(span);
            return error.InvalidArguments;
        }
        const argument = std.mem.trim(
            u8,
            raw[call.arguments.start + arguments.items[0].start .. call.arguments.start + arguments.items[0].end],
            " \t\r\n\x0c",
        );
        var items = try splitTopLevelWhitespace(self.allocator, argument);
        defer items.deinit(self.allocator);
        const count = if (argument.len == 0) 0 else items.items.len;
        const numeric = native_numeric.Numeric.init(@floatFromInt(count), null) catch unreachable;
        var numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
        var denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
        return self.ownValue(span, .{
            .number = numeric.toNumber(&numerator, &denominator) catch unreachable,
        });
    }

    fn evaluateTypeBuiltin(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        call: Call,
        scope: native_environment.ScopeId,
    ) Error!*const native_value.Value {
        var arguments = try splitTopLevel(
            self.allocator,
            raw[call.arguments.start..call.arguments.end],
            ',',
        );
        defer arguments.deinit(self.allocator);
        if (call.arguments.start == call.arguments.end) arguments.clearRetainingCapacity();
        if (arguments.items.len != 1) {
            try self.reportInvalidArguments(span);
            return error.InvalidArguments;
        }
        const argument = raw[call.arguments.start + arguments.items[0].start .. call.arguments.start + arguments.items[0].end];
        const value = try self.evaluateValue(span, argument, scope, 0);
        const label: []const u8 = switch (value.*) {
            .number => "unit",
            .string, .selector => "string",
            .boolean => "boolean",
            .list => "expression",
            .map => "object",
            .null_value => "null",
            .color => "rgba",
            .callable => "function",
            .argument_list => "arguments",
        };
        return self.ownValue(span, .{ .string = .{ .bytes = label, .quoted = true } });
    }

    fn evaluateCondition(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        scope: native_environment.ScopeId,
    ) Error!bool {
        const rendered = try self.renderRawOwned(span, raw, scope, .value, 0);
        defer self.allocator.free(rendered);
        const input = std.mem.trim(u8, rendered, " \t\r\n\x0c;");
        if (findComparison(input)) |comparison| {
            const left = try self.evaluateValue(
                span,
                input[0..comparison.start],
                scope,
                0,
            );
            const right = try self.evaluateValue(
                span,
                input[comparison.end..],
                scope,
                0,
            );
            return self.compareValues(span, left, right, comparison.operator);
        }
        return isTruthy(try self.evaluateValue(span, input, scope, 0));
    }

    fn compareValues(
        self: *Engine,
        span: native_source.Span,
        left: *const native_value.Value,
        right: *const native_value.Value,
        operator: ComparisonOperator,
    ) Error!bool {
        if (operator == .equal or operator == .not_equal) {
            const equal = native_value.eql(left.*, right.*);
            return if (operator == .equal) equal else !equal;
        }
        if (left.* != .number or right.* != .number or
            !numberUnitsEqual(left.number, right.number))
        {
            try self.reportInvalidOperation(span);
            return error.InvalidOperation;
        }
        return switch (operator) {
            .greater => left.number.value > right.number.value,
            .greater_equal => left.number.value >= right.number.value,
            .less => left.number.value < right.number.value,
            .less_equal => left.number.value <= right.number.value,
            else => unreachable,
        };
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
            .color => |color| {
                var color_buffer: [native_color.max_serialized_bytes]u8 = undefined;
                const serialized = native_color.serializePreferHex(
                    color,
                    &color_buffer,
                    false,
                ) catch {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                };
                try self.appendTemporary(&output, span, serialized);
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

    fn setBinding(
        self: *Engine,
        scope: native_environment.ScopeId,
        name: []const u8,
        value: *const native_value.Value,
        span: native_source.Span,
    ) Error!native_environment.ScopeId {
        return self.environment.set(scope, name, value) catch |failure| {
            switch (failure) {
                error.BindingLimitExceeded, error.NameLimitExceeded, error.ScopeLimitExceeded => try self.reportResource(span, "native Stylus lexical environment limit exceeded"),
                else => {},
            }
            return failure;
        };
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
            "native Stylus expression is invalid",
            &.{},
        );
    }

    fn reportInvalidArguments(self: *Engine, span: native_source.Span) Error!void {
        try self.transaction.report(
            .err,
            .type_mismatch,
            span,
            "native Stylus callable arguments are invalid",
            &.{},
        );
    }

    fn reportUndefinedCallable(self: *Engine, span: native_source.Span) Error!void {
        try self.transaction.report(
            .err,
            .invalid_operation,
            span,
            "native Stylus callable is undefined",
            &.{},
        );
    }
};

const ConditionHeader = struct {
    expression: []const u8,
    negated: bool,
};

const LoopHeader = struct {
    name: []const u8,
    items: []const u8,
};

const ComparisonOperator = enum {
    equal,
    not_equal,
    greater,
    greater_equal,
    less,
    less_equal,
};

const Comparison = struct {
    start: usize,
    end: usize,
    operator: ComparisonOperator,
};

const DefinedTernary = struct {
    name: []const u8,
    when_defined: ByteRange,
    when_undefined: ByteRange,
};

fn parseCall(raw_input: []const u8) ?Call {
    const raw = std.mem.trim(u8, raw_input, " \t\r\n\x0c;");
    if (raw.len < 3 or !isNameStart(raw, 0)) return null;
    const name_end = nameEnd(raw, 0);
    var opening = name_end;
    while (opening < raw.len and std.ascii.isWhitespace(raw[opening])) opening += 1;
    if (opening >= raw.len or raw[opening] != '(') return null;
    const closing = matchingParen(raw, opening) orelse return null;
    if (std.mem.trim(u8, raw[closing + 1 ..], " \t\r\n\x0c;").len != 0) return null;
    return .{
        .name = .{ .start = 0, .end = name_end },
        .arguments = .{ .start = opening + 1, .end = closing },
    };
}

fn parseDefinition(raw: []const u8) ?Definition {
    const call = parseCall(raw) orelse return null;
    return .{ .name = call.name, .parameters = call.arguments };
}

fn parseConditionHeader(raw: []const u8) ?ConditionHeader {
    const keyword: []const u8 = if (startsWordAscii(raw, "if"))
        "if"
    else if (startsWordAscii(raw, "unless"))
        "unless"
    else
        return null;
    const expression = std.mem.trim(u8, raw[keyword.len..], " \t\r\n\x0c;");
    if (expression.len == 0) return null;
    return .{
        .expression = expression,
        .negated = std.mem.eql(u8, keyword, "unless"),
    };
}

fn parseLoop(raw: []const u8) ?LoopHeader {
    const keyword: []const u8 = if (startsWordAscii(raw, "for"))
        "for"
    else if (startsWordAscii(raw, "each"))
        "each"
    else
        return null;
    const body = std.mem.trim(u8, raw[keyword.len..], " \t\r\n\x0c;");
    var cursor: usize = 0;
    while (cursor < body.len and !std.ascii.isWhitespace(body[cursor])) cursor += 1;
    const name = body[0..cursor];
    if (!validVariableName(name)) return null;
    while (cursor < body.len and std.ascii.isWhitespace(body[cursor])) cursor += 1;
    if (cursor + 2 > body.len or !std.ascii.eqlIgnoreCase(body[cursor .. cursor + 2], "in")) {
        return null;
    }
    cursor += 2;
    if (cursor < body.len and !std.ascii.isWhitespace(body[cursor])) return null;
    const items = std.mem.trim(u8, body[cursor..], " \t\r\n\x0c;");
    if (items.len == 0) return null;
    return .{ .name = name, .items = items };
}

fn startsWordAscii(raw: []const u8, expected: []const u8) bool {
    if (raw.len < expected.len or !std.ascii.eqlIgnoreCase(raw[0..expected.len], expected)) {
        return false;
    }
    return raw.len == expected.len or std.ascii.isWhitespace(raw[expected.len]) or
        raw[expected.len] == '(' or raw[expected.len] == ';';
}

fn matchingParen(raw: []const u8, opening: usize) ?usize {
    if (opening >= raw.len or raw[opening] != '(') return null;
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
        if (byte == '(') depth += 1;
        if (byte == ')') {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

fn splitTopLevelWhitespace(
    allocator: std.mem.Allocator,
    raw: []const u8,
) std.mem.Allocator.Error!std.ArrayList(ByteRange) {
    var output: std.ArrayList(ByteRange) = .empty;
    errdefer output.deinit(allocator);
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    var start: ?usize = null;
    for (raw, 0..) |byte, index| {
        if (quote != 0) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == quote) {
                quote = 0;
            }
            if (start == null) start = index;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            if (start == null) start = index;
            quote = byte;
            continue;
        }
        switch (byte) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            else => {},
        }
        if (std.ascii.isWhitespace(byte) and depth == 0) {
            if (start) |item_start| {
                try output.append(allocator, .{ .start = item_start, .end = index });
                start = null;
            }
            continue;
        }
        if (start == null) start = index;
    }
    if (start) |item_start| {
        try output.append(allocator, .{ .start = item_start, .end = raw.len });
    }
    return output;
}

fn findComparison(raw: []const u8) ?Comparison {
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
        if (depth != 0) continue;
        if (index + 1 < raw.len) {
            const pair = raw[index .. index + 2];
            if (std.mem.eql(u8, pair, "==")) return .{
                .start = index,
                .end = index + 2,
                .operator = .equal,
            };
            if (std.mem.eql(u8, pair, "!=")) return .{
                .start = index,
                .end = index + 2,
                .operator = .not_equal,
            };
            if (std.mem.eql(u8, pair, ">=")) return .{
                .start = index,
                .end = index + 2,
                .operator = .greater_equal,
            };
            if (std.mem.eql(u8, pair, "<=")) return .{
                .start = index,
                .end = index + 2,
                .operator = .less_equal,
            };
        }
        if (byte == '>') return .{ .start = index, .end = index + 1, .operator = .greater };
        if (byte == '<') return .{ .start = index, .end = index + 1, .operator = .less };
    }
    return null;
}

fn isTruthy(value: *const native_value.Value) bool {
    return switch (value.*) {
        .null_value => false,
        .boolean => |item| item,
        else => true,
    };
}

fn numberUnitsEqual(left: native_value.Number, right: native_value.Number) bool {
    if (left.numerator_units.len != right.numerator_units.len or
        left.denominator_units.len != right.denominator_units.len)
    {
        return false;
    }
    for (left.numerator_units, right.numerator_units) |unit, other| {
        if (!std.mem.eql(u8, unit, other)) return false;
    }
    for (left.denominator_units, right.denominator_units) |unit, other| {
        if (!std.mem.eql(u8, unit, other)) return false;
    }
    return true;
}

fn parseDefinedTernary(raw: []const u8) ?DefinedTernary {
    const bounds = trimRange(raw, .{ .start = 0, .end = raw.len });
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    var nested_ternaries: usize = 0;
    var question: ?usize = null;
    var colon: ?usize = null;
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
        if (byte == '?' and (index + 1 >= bounds.end or raw[index + 1] != '=')) {
            if (question == null) {
                question = index;
            } else {
                nested_ternaries += 1;
            }
            continue;
        }
        if (byte == ':' and question != null) {
            if (nested_ternaries > 0) {
                nested_ternaries -= 1;
            } else {
                colon = index;
                break;
            }
        }
    }

    const question_index = question orelse return null;
    const colon_index = colon orelse return null;
    const condition = trimRange(raw, .{ .start = bounds.start, .end = question_index });
    const when_defined = trimRange(raw, .{ .start = question_index + 1, .end = colon_index });
    const when_undefined = trimRange(raw, .{ .start = colon_index + 1, .end = bounds.end });
    if (when_defined.start == when_defined.end or when_undefined.start == when_undefined.end) {
        return null;
    }

    var cursor = condition.end;
    const defined_end = cursor;
    while (cursor > condition.start and !std.ascii.isWhitespace(raw[cursor - 1])) cursor -= 1;
    if (!std.ascii.eqlIgnoreCase(raw[cursor..defined_end], "defined")) return null;
    while (cursor > condition.start and std.ascii.isWhitespace(raw[cursor - 1])) cursor -= 1;
    const is_end = cursor;
    while (cursor > condition.start and !std.ascii.isWhitespace(raw[cursor - 1])) cursor -= 1;
    if (!std.ascii.eqlIgnoreCase(raw[cursor..is_end], "is")) return null;
    const name_range = trimRange(raw, .{ .start = condition.start, .end = cursor });
    const name = raw[name_range.start..name_range.end];
    if (!validVariableName(name)) return null;

    return .{
        .name = name,
        .when_defined = when_defined,
        .when_undefined = when_undefined,
    };
}

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
            if (operation != '*' and operation != '/' and operation != '%') return result;
            if (operation == '/' and depth == 0) return result;
            self.cursor += 1;
            const right = try self.parsePrimary(depth);
            if (operation == '%') {
                if (!right.isDimensionless() or right.value == 0) {
                    return error.InvalidExpression;
                }
                result.value = @mod(result.value, right.value);
            } else {
                result = try native_numeric.multiply(result, right, operation);
            }
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
