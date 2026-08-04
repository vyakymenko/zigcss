//! Private bounded semantic evaluator for native Less syntax.
//!
//! This first internal slice admits only already-valid plain CSS through the
//! transactional core validator. Less variables, mixins, imports, functions,
//! operations, and other evaluation semantics remain unavailable. JavaScript
//! and plugin execution are permanently rejected before any CSS is staged.

const std = @import("std");
const native_diagnostics = @import("diagnostics.zig");
const native_evaluator = @import("evaluator.zig");
const native_lexer = @import("lexer.zig");
const native_source = @import("source.zig");
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
    native_syntax.Error || error{
    InvalidDocument,
    InvalidLimits,
    JavaScriptDisabled,
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

    try transaction.emitMapped(root.span, null, input);
}

fn validateLimits(limits: Limits) Error!void {
    if (limits.max_source_bytes == 0 or limits.max_source_bytes > hard_source_bytes or
        limits.max_nodes == 0 or limits.max_nodes > hard_nodes)
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
        .variable,
        .interpolation,
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
