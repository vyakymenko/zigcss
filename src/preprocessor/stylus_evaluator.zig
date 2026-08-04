//! Private bounded semantic evaluator for native Stylus syntax.
//!
//! This first finite slice admits only already-valid plain CSS into the shared
//! transaction. Stylus imports and language semantics remain fail-closed, and
//! `use()` project plugins plus external custom evaluator hooks are permanently
//! outside this module's execution boundary.

const std = @import("std");
const native_evaluator = @import("evaluator.zig");
const native_lexer = @import("lexer.zig");
const native_source = @import("source.zig");
const native_stylus = @import("stylus.zig");
const native_syntax = @import("syntax.zig");

const hard_source_bytes = 10 * 1024 * 1024;
const hard_nodes = 1_000_000;

pub const Limits = struct {
    max_source_bytes: usize = hard_source_bytes,
    max_nodes: usize = 200_000,
};

pub const Error = native_evaluator.Error ||
    native_lexer.Error ||
    native_source.Error ||
    native_stylus.Error ||
    native_syntax.Error || error{
    InvalidDocument,
    InvalidLimits,
    NodeLimitExceeded,
    PluginDisabled,
    SourceLimitExceeded,
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
    try preflightStatements(
        sources,
        document,
        try document.children(document.root),
        transaction,
    );
    try transaction.emitMapped(root.span, null, input);
}

fn validateLimits(limits: Limits) Error!void {
    if (limits.max_source_bytes == 0 or limits.max_source_bytes > hard_source_bytes or
        limits.max_nodes == 0 or limits.max_nodes > hard_nodes)
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

fn preflightStatements(
    sources: *const native_source.Table,
    document: *const native_syntax.Document,
    statements: []const native_syntax.NodeId,
    transaction: *native_evaluator.Transaction,
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
            .variable,
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
            else => {},
        }

        for (try document.children(statement_id)) |child_id| {
            const child = try document.get(child_id);
            if (child.kind == .block) {
                try preflightStatements(
                    sources,
                    document,
                    try document.children(child_id),
                    transaction,
                );
            }
        }
    }
}
