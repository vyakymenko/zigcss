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
const hard_asset_load_paths = 64;
const hard_asset_load_path_bytes = 4_096;
const block_value_prefix = "\x1fzigcss-native-stylus-block:";

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
    asset_load_paths: []const []const u8 = &.{},
};

pub const OutputStyle = enum {
    expanded,
    compressed,
};

pub const Options = struct {
    output_style: OutputStyle = .expanded,
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
    try validateAssetLoadPaths(limits.asset_load_paths);

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

    const normalized_input = normalizeInlineAtBlocks(
        transaction.allocator,
        input,
        limits.max_temporary_bytes,
    ) catch |failure| {
        if (failure == error.TemporaryLimitExceeded) {
            try transaction.report(
                .err,
                .resource_limit,
                root.span,
                "native Stylus temporary byte limit exceeded",
                &.{},
            );
        }
        return failure;
    };
    defer if (normalized_input) |bytes| transaction.allocator.free(bytes);
    var normalized_document: ?native_syntax.Document = null;
    defer if (normalized_document) |*normalized| normalized.deinit();
    if (normalized_input) |bytes| {
        if (bytes.len > limits.max_source_bytes) {
            try transaction.report(
                .err,
                .resource_limit,
                root.span,
                "native Stylus evaluator source limit exceeded",
                &.{},
            );
            return error.SourceLimitExceeded;
        }
        const original_file = try sources.get(root.span.source);
        const normalized_name = try std.fmt.allocPrint(
            transaction.allocator,
            "{s}#zigcss-native-atblock-{d}",
            .{ original_file.name, sources.count() },
        );
        defer transaction.allocator.free(normalized_name);
        const normalized_source = try sources.add(normalized_name, bytes);
        var parser = try native_stylus.Parser.init(
            transaction.allocator,
            sources,
            normalized_source,
            .{},
            .{},
        );
        defer parser.deinit();
        normalized_document = try parser.parse();
    }
    const base_document = if (normalized_document) |*normalized| normalized else document;
    const base_root = try base_document.get(base_document.root);
    const base_input = try sources.slice(base_root.span);

    var expanded_document: ?native_syntax.Document = null;
    defer if (expanded_document) |*expanded| expanded.deinit();
    if (containsImports(base_document)) {
        var expander = ImportExpander.init(
            transaction.allocator,
            sources,
            transaction,
            limits,
        );
        defer expander.deinit();
        expanded_document = expander.expand(base_document) catch |failure| switch (failure) {
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
    const active_document = if (expanded_document) |*expanded| expanded else base_document;
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
    try rejectUsePlugins(sources, base_root.span, base_input, transaction);
    const semantic = normalized_document != null or expanded_document != null or
        try requiresSemanticEvaluation(sources, active_document, base_input);
    try preflightStatements(
        active_document,
        try active_document.children(active_document.root),
        transaction,
        semantic,
    );
    if (!semantic) {
        try transaction.emitMapped(base_root.span, null, base_input);
        return;
    }

    var cache_plan: CachePlan = .{};
    defer cache_plan.deinit(transaction.allocator);
    if (try containsCacheBlock(sources, active_document)) {
        var cache_seed: CachePlan = .{};
        defer cache_seed.deinit(transaction.allocator);
        const maximum_iterations = std.math.add(
            usize,
            @as(usize, limits.max_call_depth),
            2,
        ) catch return error.CallDepthExceeded;
        var iteration: usize = 0;
        while (iteration < maximum_iterations) : (iteration += 1) {
            var discovered: CachePlan = .{};
            errdefer discovered.deinit(transaction.allocator);
            var discovery = try Engine.init(
                transaction.allocator,
                sources,
                active_document,
                transaction,
                limits,
                options,
                .discover_cache,
                &cache_seed,
                &discovered,
                null,
            );
            defer discovery.deinit();
            try discovery.run();
            if (CachePlan.eql(&cache_seed, &discovered)) {
                cache_plan = discovered;
                break;
            }
            cache_seed.deinit(transaction.allocator);
            cache_seed = discovered;
        } else {
            try transaction.report(
                .err,
                .call_limit,
                root.span,
                "native Stylus cache plan did not converge within the call-depth bound",
                &.{},
            );
            return error.CallDepthExceeded;
        }
    }

    var dynamic_extension_plan: DynamicExtensionPlan = .{};
    defer dynamic_extension_plan.deinit(transaction.allocator);
    const contains_loop_extension = try containsLoopExtensionCandidate(
        sources,
        active_document,
        try active_document.children(active_document.root),
        false,
    );
    const contains_callable_extension = if (contains_loop_extension)
        false
    else
        try containsCallableExtensionCandidate(
            sources,
            active_document,
            try active_document.children(active_document.root),
            false,
        );
    const contains_runtime_extension = try containsRuntimeExtensionCandidate(
        sources,
        active_document,
    );
    if (contains_loop_extension or contains_callable_extension or
        contains_runtime_extension)
    {
        var discovery = try Engine.init(
            transaction.allocator,
            sources,
            active_document,
            transaction,
            limits,
            options,
            .discover_extensions,
            &cache_plan,
            null,
            &dynamic_extension_plan,
        );
        defer discovery.deinit();
        try discovery.run();
    }

    const extension_checkpoint = if (dynamic_extension_plan.extensions.items.len > 0 or
        try containsExtensionDirective(sources, active_document))
        try transaction.stagingCheckpoint()
    else
        null;
    errdefer if (extension_checkpoint) |checkpoint_value| {
        transaction.restoreStaging(checkpoint_value) catch {};
    };
    var engine = try Engine.init(
        transaction.allocator,
        sources,
        active_document,
        transaction,
        limits,
        options,
        .emit,
        &cache_plan,
        null,
        &dynamic_extension_plan,
    );
    defer engine.deinit();
    try engine.run();
}

const InlineAtBlock = struct {
    marker: usize,
    opening: usize,
    closing: usize,
    name: []u8,
};

fn normalizeInlineAtBlocks(
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum: usize,
) Error!?[]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var input_cursor: usize = 0;
    var search_cursor: usize = 0;
    var generated_index: usize = 0;
    var changed = false;

    while (findInlineAtBlock(input, search_cursor)) |first| {
        const line_start = (std.mem.lastIndexOfScalar(u8, input[0..first.marker], '\n') orelse
            std.math.maxInt(usize)) +% 1;
        const opening_paren = std.mem.lastIndexOfScalar(
            u8,
            input[line_start..first.marker],
            '(',
        ) orelse return error.InvalidDocument;
        const call_opening = line_start + opening_paren;
        const call_closing = matchingParen(input, call_opening) orelse
            return error.InvalidDocument;
        if (call_closing < first.closing) return error.InvalidDocument;

        var blocks: std.ArrayList(InlineAtBlock) = .empty;
        defer {
            for (blocks.items) |block| allocator.free(block.name);
            blocks.deinit(allocator);
        }
        var block_cursor = first.marker;
        while (findInlineAtBlock(input[0 .. call_closing + 1], block_cursor)) |found| {
            var name: []u8 = undefined;
            while (true) : (generated_index += 1) {
                name = try std.fmt.allocPrint(
                    allocator,
                    "__zigcss_native_atblock_{d}",
                    .{generated_index},
                );
                if (std.mem.indexOf(u8, input, name) == null) break;
                allocator.free(name);
            }
            generated_index += 1;
            blocks.append(allocator, .{
                .marker = found.marker,
                .opening = found.opening,
                .closing = found.closing,
                .name = name,
            }) catch |failure| {
                allocator.free(name);
                return failure;
            };
            block_cursor = found.closing + 1;
        }
        if (blocks.items.len == 0) return error.InvalidDocument;

        var line_end = call_closing + 1;
        while (line_end < input.len and input[line_end] != '\r' and input[line_end] != '\n') {
            line_end += 1;
        }
        var next_line = line_end;
        if (next_line < input.len and input[next_line] == '\r') next_line += 1;
        if (next_line < input.len and input[next_line] == '\n') next_line += 1 else if (next_line == line_end and next_line < input.len and input[next_line] == '\n') next_line += 1;

        if (line_start < input_cursor) return error.InvalidDocument;
        try appendBounded(&output, allocator, input[input_cursor..line_start], maximum);
        var indent_end = line_start;
        while (indent_end < input.len and
            (input[indent_end] == ' ' or input[indent_end] == '\t'))
        {
            indent_end += 1;
        }
        const indent = input[line_start..indent_end];
        for (blocks.items) |block| {
            try appendBounded(&output, allocator, indent, maximum);
            try appendBounded(&output, allocator, block.name, maximum);
            try appendBounded(&output, allocator, " = @block {", maximum);
            const body = std.mem.trimRight(
                u8,
                input[block.opening + 1 .. block.closing],
                " \t",
            );
            try appendBounded(&output, allocator, body, maximum);
            if (body.len == 0 or (body[body.len - 1] != '\n' and body[body.len - 1] != '\r')) {
                try appendBounded(&output, allocator, "\n", maximum);
            }
            try appendBounded(&output, allocator, indent, maximum);
            try appendBounded(&output, allocator, "}\n", maximum);
        }

        var normalized_call: std.ArrayList(u8) = .empty;
        defer normalized_call.deinit(allocator);
        var call_cursor = line_start;
        for (blocks.items) |block| {
            try normalized_call.appendSlice(allocator, input[call_cursor..block.marker]);
            try normalized_call.appendSlice(allocator, block.name);
            call_cursor = block.closing + 1;
        }
        try normalized_call.appendSlice(allocator, input[call_cursor .. call_closing + 1]);
        try appendBounded(&output, allocator, indent, maximum);
        try appendCollapsedWhitespace(
            &output,
            allocator,
            normalized_call.items,
            maximum,
        );
        try appendBounded(
            &output,
            allocator,
            std.mem.trimRight(u8, input[call_closing + 1 .. line_end], " \t"),
            maximum,
        );
        if (next_line > line_end) {
            try appendBounded(&output, allocator, input[line_end..next_line], maximum);
        } else if (line_end == input.len) {
            // Preserve an input without a final newline.
        }

        input_cursor = next_line;
        search_cursor = next_line;
        changed = true;
    }
    if (!changed) return null;
    try appendBounded(&output, allocator, input[input_cursor..], maximum);
    return try output.toOwnedSlice(allocator);
}

fn findInlineAtBlock(input: []const u8, start: usize) ?struct {
    marker: usize,
    opening: usize,
    closing: usize,
} {
    var cursor: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    var line_comment = false;
    var block_comment = false;
    while (cursor < input.len) : (cursor += 1) {
        const byte = input[cursor];
        if (line_comment) {
            if (byte == '\r' or byte == '\n') line_comment = false;
            continue;
        }
        if (block_comment) {
            if (byte == '*' and cursor + 1 < input.len and input[cursor + 1] == '/') {
                block_comment = false;
                cursor += 1;
            }
            continue;
        }
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
        if (byte == '/' and cursor + 1 < input.len and input[cursor + 1] == '/') {
            line_comment = true;
            cursor += 1;
            continue;
        }
        if (byte == '/' and cursor + 1 < input.len and input[cursor + 1] == '*') {
            block_comment = true;
            cursor += 1;
            continue;
        }
        if (cursor < start or !std.mem.startsWith(u8, input[cursor..], "@block")) continue;
        const marker = cursor;
        cursor = marker + "@block".len;
        if ((marker > 0 and isSelectorNameByte(input[marker - 1])) or
            (cursor < input.len and isSelectorNameByte(input[cursor])))
        {
            continue;
        }
        var opening = cursor;
        while (opening < input.len and
            (input[opening] == ' ' or input[opening] == '\t'))
        {
            opening += 1;
        }
        if (opening >= input.len or input[opening] != '{') continue;
        var previous = marker;
        while (previous > 0 and std.ascii.isWhitespace(input[previous - 1])) previous -= 1;
        if (previous == 0 or (input[previous - 1] != '(' and input[previous - 1] != ',')) {
            continue;
        }
        const closing = matchingAtBlockCurly(input, opening) orelse return null;
        return .{ .marker = marker, .opening = opening, .closing = closing };
    }
    return null;
}

fn matchingAtBlockCurly(raw: []const u8, opening: usize) ?usize {
    if (opening >= raw.len or raw[opening] != '{') return null;
    var quote: u8 = 0;
    var escaped = false;
    var line_comment = false;
    var block_comment = false;
    var depth: usize = 0;
    var index = opening;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        if (line_comment) {
            if (byte == '\r' or byte == '\n') line_comment = false;
            continue;
        }
        if (block_comment) {
            if (byte == '*' and index + 1 < raw.len and raw[index + 1] == '/') {
                block_comment = false;
                index += 1;
            }
            continue;
        }
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
        if (byte == '/' and index + 1 < raw.len and raw[index + 1] == '/') {
            line_comment = true;
            index += 1;
            continue;
        }
        if (byte == '/' and index + 1 < raw.len and raw[index + 1] == '*') {
            block_comment = true;
            index += 1;
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

fn appendBounded(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    bytes: []const u8,
    maximum: usize,
) Error!void {
    const next = std.math.add(usize, output.items.len, bytes.len) catch
        return error.TemporaryLimitExceeded;
    if (next > maximum) return error.TemporaryLimitExceeded;
    try output.appendSlice(allocator, bytes);
}

fn appendCollapsedWhitespace(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    raw: []const u8,
    maximum: usize,
) Error!void {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\x0c");
    var quote: u8 = 0;
    var escaped = false;
    var pending_space = false;
    for (trimmed) |byte| {
        if (quote != 0) {
            if (pending_space) {
                try appendBounded(output, allocator, " ", maximum);
                pending_space = false;
            }
            try appendBounded(output, allocator, (&[_]u8{byte})[0..], maximum);
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
            if (pending_space) {
                try appendBounded(output, allocator, " ", maximum);
                pending_space = false;
            }
            quote = byte;
            try appendBounded(output, allocator, (&[_]u8{byte})[0..], maximum);
        } else if (std.ascii.isWhitespace(byte)) {
            pending_space = output.items.len > 0;
        } else {
            if (pending_space) {
                try appendBounded(output, allocator, " ", maximum);
                pending_space = false;
            }
            try appendBounded(output, allocator, (&[_]u8{byte})[0..], maximum);
        }
    }
}

fn containsImports(document: *const native_syntax.Document) bool {
    for (document.nodes()) |node| {
        if (node.kind == .import) return true;
    }
    return false;
}

fn containsCacheBlock(
    sources: *const native_source.Table,
    document: *const native_syntax.Document,
) Error!bool {
    for (document.nodes(), 0..) |node, index| {
        if (node.kind != .rule) continue;
        const children = try document.children(.{ .value = @intCast(index) });
        if (children.len != 2) continue;
        const selector = try document.get(children[0]);
        const block = try document.get(children[1]);
        if (selector.kind != .selector or selector.text == null or block.kind != .block) continue;
        const raw_selector = std.mem.trim(
            u8,
            try sources.slice(selector.text.?),
            " \t\r\n\x0c;",
        );
        if (raw_selector.len < 2 or raw_selector[0] != '+') continue;
        const raw_call = std.mem.trimLeft(u8, raw_selector[1..], " \t");
        const call = parseCall(raw_call) orelse parseBareCall(raw_call) orelse continue;
        if (nameEql(raw_call[call.name.start..call.name.end], "cache")) return true;
    }
    return false;
}

fn containsExtensionDirective(
    sources: *const native_source.Table,
    document: *const native_syntax.Document,
) Error!bool {
    for (document.nodes()) |node| {
        if (node.kind != .at_rule or node.text == null) continue;
        const raw = std.mem.trim(
            u8,
            try sources.slice(node.text.?),
            " \t\r\n\x0c;",
        );
        if (parseExtendDirective(raw) != null) return true;
    }
    return false;
}

fn containsRuntimeExtensionCandidate(
    sources: *const native_source.Table,
    document: *const native_syntax.Document,
) Error!bool {
    for (document.nodes()) |node| {
        if (node.kind != .at_rule or node.text == null) continue;
        const raw = std.mem.trim(
            u8,
            try sources.slice(node.text.?),
            " \t\r\n\x0c;",
        );
        const directive = parseExtendDirective(raw) orelse continue;
        if (multipleExtensionTargetsNeedRuntimeRendering(directive.targets)) return true;
    }
    return false;
}

fn multipleExtensionTargetsNeedRuntimeRendering(raw: []const u8) bool {
    return findTopLevelScalar(raw, ',') != null and
        extensionTargetNeedsRuntimeRendering(raw);
}

fn extensionTargetNeedsRuntimeRendering(raw: []const u8) bool {
    var escaped = false;
    var line_comment = false;
    var block_comment = false;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        if (line_comment) {
            if (byte == '\n' or byte == '\r' or byte == '\x0c') line_comment = false;
            continue;
        }
        if (block_comment) {
            if (byte == '*' and index + 1 < raw.len and raw[index + 1] == '/') {
                block_comment = false;
                index += 1;
            }
            continue;
        }
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte == '/' and index + 1 < raw.len) {
            if (raw[index + 1] == '/') {
                line_comment = true;
                index += 1;
                continue;
            }
            if (raw[index + 1] == '*') {
                block_comment = true;
                index += 1;
                continue;
            }
        }
        if (byte == '{') return true;
    }
    return false;
}

fn containsLoopExtensionCandidate(
    sources: *const native_source.Table,
    document: *const native_syntax.Document,
    statements: []const native_syntax.NodeId,
    inside_loop: bool,
) Error!bool {
    for (statements) |statement_id| {
        const statement = try document.get(statement_id);
        const descendant_inside_loop = inside_loop or statement.kind == .loop;
        if (descendant_inside_loop and statement.kind == .at_rule and statement.text != null) {
            const raw = std.mem.trim(
                u8,
                try sources.slice(statement.text.?),
                " \t\r\n\x0c;",
            );
            if (parseExtendDirective(raw)) |directive| {
                var targets = directive.targets;
                if (std.mem.indexOf(u8, targets, " !optional")) |optional| {
                    targets = std.mem.trimRight(
                        u8,
                        targets[0..optional],
                        " \t\r\n\x0c;",
                    );
                }
                if (targets.len > 0) return true;
            }
        }
        for (try document.children(statement_id)) |child_id| {
            const child = try document.get(child_id);
            if (child.kind == .block and try containsLoopExtensionCandidate(
                sources,
                document,
                try document.children(child_id),
                descendant_inside_loop,
            )) return true;
        }
    }
    return false;
}

fn containsCallableExtensionCandidate(
    sources: *const native_source.Table,
    document: *const native_syntax.Document,
    statements: []const native_syntax.NodeId,
    inside_callable: bool,
) Error!bool {
    for (statements) |statement_id| {
        const statement = try document.get(statement_id);
        const descendant_inside_callable = inside_callable or
            statement.kind == .function or statement.kind == .mixin;
        if (descendant_inside_callable and
            statement.kind == .at_rule and statement.text != null)
        {
            const raw = std.mem.trim(
                u8,
                try sources.slice(statement.text.?),
                " \t\r\n\x0c;",
            );
            if (parseExtendDirective(raw) != null) return true;
        }
        for (try document.children(statement_id)) |child_id| {
            const child = try document.get(child_id);
            if (child.kind == .block and try containsCallableExtensionCandidate(
                sources,
                document,
                try document.children(child_id),
                descendant_inside_callable,
            )) return true;
        }
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

fn validateAssetLoadPaths(paths: []const []const u8) Error!void {
    if (paths.len > hard_asset_load_paths) return error.InvalidLimits;
    for (paths, 0..) |path, index| {
        if (path.len == 0 or path.len > hard_asset_load_path_bytes or
            !std.fs.path.isAbsolute(path) or
            std.mem.indexOfAny(u8, path, "\x00\r\n") != null)
        {
            return error.InvalidLimits;
        }
        for (paths[0..index]) |prior| {
            if (std.mem.eql(u8, prior, path)) return error.InvalidLimits;
        }
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
    sources: *const native_source.Table,
    document: *const native_syntax.Document,
    input: []const u8,
) Error!bool {
    if (try containsSemanticStatement(document, try document.children(document.root))) return true;
    if (inputContainsBuiltinCall(input)) return true;
    if (std.mem.indexOf(u8, input, "@extend") != null) return true;
    for (document.nodes(), 0..) |node, index| {
        if (node.kind == .declaration and node.text != null) {
            const raw = std.mem.trim(
                u8,
                try sources.slice(node.text.?),
                " \t\r\n\x0c;",
            );
            if (splitDeclaration(raw)) |parts| {
                const separator = raw[parts[0].end..parts[1].start];
                if (std.mem.indexOfScalar(u8, separator, ':')) |colon| {
                    if (colon + 1 == separator.len or
                        !std.ascii.isWhitespace(separator[colon + 1]))
                    {
                        return true;
                    }
                }
            }
        }
        if (node.kind != .rule) continue;
        const children = try document.children(.{ .value = @intCast(index) });
        if (children.len <= 1 or node.text == null) continue;
        const block = try document.get(children[children.len - 1]);
        if (block.kind != .block or block.span.source.value != node.text.?.source.value) continue;
        for (try document.children(children[children.len - 1])) |child_id| {
            if ((try document.get(child_id)).kind == .rule) return true;
        }
        const gap_start: usize = @intCast(node.text.?.end);
        const gap_end: usize = @intCast(block.span.start);
        if (gap_start > gap_end or gap_end > input.len) continue;
        if (std.mem.indexOfScalar(u8, input[gap_start..gap_end], '{') == null) return true;
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
    css_required_urls: std.ArrayList([]u8) = .empty,
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
        for (self.css_required_urls.items) |url| self.allocator.free(url);
        self.css_required_urls.deinit(self.allocator);
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
        const raw_directive = try self.sources.slice(text);
        const raw_trimmed = std.mem.trim(u8, raw_directive, " \t\r\n\x0c;");
        if (raw_trimmed.len >= "@import".len and
            std.ascii.eqlIgnoreCase(raw_trimmed[0.."@import".len], "@import"))
        {
            const argument = std.mem.trim(u8, raw_trimmed["@import".len..], " \t\r\n\x0c;");
            if (argument.len >= 4 and std.ascii.eqlIgnoreCase(argument[0..4], "url(")) {
                try output.append(self.allocator, try self.builder.add(.at_rule, text, text, &.{}));
                return;
            }
        }
        const parsed = parseImportDirective(raw_directive) orelse {
            try self.reportImport(text, "native Stylus import syntax is unsupported");
            return error.InvalidImport;
        };
        const parent_url = self.ancestry.items[self.ancestry.items.len - 1];
        const import_basename = std.fs.path.basename(parsed.target);
        const css_inline = import_basename.len > 0 and
            (import_basename[0] == '_' or std.mem.indexOf(u8, import_basename, "._") != null);
        if (std.ascii.eqlIgnoreCase(std.fs.path.extension(parsed.target), ".css") and !css_inline) {
            if (try self.cssImportNode(parsed, text, parent_url)) |node| {
                try output.append(self.allocator, node);
            }
            return;
        }
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

    fn cssImportNode(
        self: *ImportExpander,
        parsed: ParsedImport,
        original_span: native_source.Span,
        parent_url: []const u8,
    ) Error!?native_syntax.NodeId {
        if (!parsed.require_once) {
            return @as(?native_syntax.NodeId, try self.builder.add(
                .at_rule,
                original_span,
                original_span,
                &.{},
            ));
        }
        const canonical_url = try importCandidateUrl(self.allocator, parent_url, parsed.target);
        for (self.css_required_urls.items) |prior| {
            if (std.mem.eql(u8, prior, canonical_url)) {
                self.allocator.free(canonical_url);
                return null;
            }
        }
        try self.css_required_urls.append(self.allocator, canonical_url);
        const directive = try std.fmt.allocPrint(
            self.allocator,
            "@import \"{s}\"",
            .{parsed.target},
        );
        defer self.allocator.free(directive);
        const source_name = try std.fmt.allocPrint(
            self.allocator,
            "memory:///native-stylus-css-import-{d}-{d}.css",
            .{ original_span.source.value, original_span.start },
        );
        defer self.allocator.free(source_name);
        const source_id = try self.sources.add(source_name, directive);
        const span = try self.sources.span(source_id, 0, @intCast(directive.len));
        return @as(?native_syntax.NodeId, try self.builder.add(.at_rule, span, span, &.{}));
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

fn assetCandidateUrl(
    allocator: std.mem.Allocator,
    base_directory: []const u8,
    target: []const u8,
) native_resolver.Error![]u8 {
    if (hasNonLocalScheme(target) or std.mem.indexOfAny(u8, target, "\x00\r\n?#") != null) {
        return error.SchemeNotAllowed;
    }
    const absolute = if (std.fs.path.isAbsolute(target))
        try std.fs.path.resolve(allocator, &.{target})
    else
        try std.fs.path.resolve(allocator, &.{ base_directory, target });
    defer allocator.free(absolute);
    return native_resolver.pathToFileUrl(allocator, absolute);
}

const ImageDimensions = struct {
    width: f64,
    height: f64,
};

const JsonOptions = struct {
    leave_strings: bool = false,
    optional: bool = false,
};

fn parseImageDimensions(bytes: []const u8) ?ImageDimensions {
    if (parseGifDimensions(bytes)) |dimensions| return dimensions;
    if (parsePngDimensions(bytes)) |dimensions| return dimensions;
    if (parseJpegDimensions(bytes)) |dimensions| return dimensions;
    return parseSvgDimensions(bytes);
}

fn parseGifDimensions(bytes: []const u8) ?ImageDimensions {
    if (bytes.len < 10 or
        (!std.mem.startsWith(u8, bytes, "GIF87a") and
            !std.mem.startsWith(u8, bytes, "GIF89a")))
    {
        return null;
    }
    const width = readLittleU16(bytes[6..10], 0);
    const height = readLittleU16(bytes[6..10], 2);
    if (width == 0 or height == 0) return null;
    return .{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
}

fn parsePngDimensions(bytes: []const u8) ?ImageDimensions {
    const signature = "\x89PNG\r\n\x1a\n";
    if (bytes.len < 24 or !std.mem.startsWith(u8, bytes, signature) or
        readBigU32(bytes[8..12]) != 13 or
        !std.mem.eql(u8, bytes[12..16], "IHDR"))
    {
        return null;
    }
    const width = readBigU32(bytes[16..20]);
    const height = readBigU32(bytes[20..24]);
    if (width == 0 or height == 0) return null;
    return .{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
}

fn parseJpegDimensions(bytes: []const u8) ?ImageDimensions {
    if (bytes.len < 4 or bytes[0] != 0xff or bytes[1] != 0xd8) return null;
    var cursor: usize = 2;
    while (cursor < bytes.len) {
        while (cursor < bytes.len and bytes[cursor] != 0xff) : (cursor += 1) {}
        if (cursor == bytes.len) return null;
        while (cursor < bytes.len and bytes[cursor] == 0xff) : (cursor += 1) {}
        if (cursor == bytes.len) return null;
        const marker = bytes[cursor];
        cursor += 1;
        if (marker == 0x00) continue;
        if (marker == 0xd9 or marker == 0xda) return null;
        if (marker == 0xd8 or marker == 0x01 or
            (marker >= 0xd0 and marker <= 0xd7))
        {
            continue;
        }
        if (cursor + 2 > bytes.len) return null;
        const segment_length: usize = readBigU16(bytes[cursor .. cursor + 2]);
        if (segment_length < 2 or segment_length > bytes.len - cursor) return null;
        if (isJpegStartOfFrame(marker)) {
            if (segment_length < 7) return null;
            const height = readBigU16(bytes[cursor + 3 .. cursor + 5]);
            const width = readBigU16(bytes[cursor + 5 .. cursor + 7]);
            if (width == 0 or height == 0) return null;
            return .{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
        }
        cursor += segment_length;
    }
    return null;
}

fn isJpegStartOfFrame(marker: u8) bool {
    return (marker >= 0xc0 and marker <= 0xcf) and
        marker != 0xc4 and marker != 0xc8 and marker != 0xcc;
}

fn parseSvgDimensions(bytes: []const u8) ?ImageDimensions {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, search, "<svg")) |opening| {
        const after_name = opening + "<svg".len;
        if (after_name < bytes.len and
            (std.ascii.isWhitespace(bytes[after_name]) or bytes[after_name] == '>'))
        {
            const closing = findSvgTagEnd(bytes, after_name) orelse return null;
            const attributes = bytes[after_name..closing];
            const width_value = svgAttribute(attributes, "width");
            const height_value = svgAttribute(attributes, "height");
            if (width_value != null and height_value != null) {
                const width = parseSvgLength(width_value.?) orelse return null;
                const height = parseSvgLength(height_value.?) orelse return null;
                return .{ .width = width, .height = height };
            }
            const view_box = svgAttribute(attributes, "viewBox") orelse return null;
            return parseSvgViewBox(view_box);
        }
        search = after_name;
    }
    return null;
}

fn findSvgTagEnd(bytes: []const u8, start: usize) ?usize {
    var quote: u8 = 0;
    var cursor = start;
    while (cursor < bytes.len) : (cursor += 1) {
        const byte = bytes[cursor];
        if (quote != 0) {
            if (byte == quote) quote = 0;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '>') {
            return cursor;
        }
    }
    return null;
}

fn svgAttribute(attributes: []const u8, wanted: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < attributes.len) {
        while (cursor < attributes.len and std.ascii.isWhitespace(attributes[cursor])) cursor += 1;
        if (cursor == attributes.len or attributes[cursor] == '/') return null;
        const name_start = cursor;
        while (cursor < attributes.len and isSvgAttributeNameByte(attributes[cursor])) cursor += 1;
        if (cursor == name_start) return null;
        const name = attributes[name_start..cursor];
        while (cursor < attributes.len and std.ascii.isWhitespace(attributes[cursor])) cursor += 1;
        if (cursor == attributes.len or attributes[cursor] != '=') return null;
        cursor += 1;
        while (cursor < attributes.len and std.ascii.isWhitespace(attributes[cursor])) cursor += 1;
        if (cursor == attributes.len or (attributes[cursor] != '\'' and attributes[cursor] != '"')) {
            return null;
        }
        const quote = attributes[cursor];
        cursor += 1;
        const value_start = cursor;
        while (cursor < attributes.len and attributes[cursor] != quote) cursor += 1;
        if (cursor == attributes.len) return null;
        const value = attributes[value_start..cursor];
        cursor += 1;
        if (std.mem.eql(u8, name, wanted)) return value;
    }
    return null;
}

fn isSvgAttributeNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or
        byte == ':' or byte == '.';
}

fn parseSvgLength(raw: []const u8) ?f64 {
    var value = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (value.len >= 2 and std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "px")) {
        value = std.mem.trimRight(u8, value[0 .. value.len - 2], " \t\r\n\x0c");
    }
    if (value.len == 0) return null;
    const parsed = std.fmt.parseFloat(f64, value) catch return null;
    if (!std.math.isFinite(parsed) or parsed <= 0) return null;
    return parsed;
}

fn parseSvgViewBox(raw: []const u8) ?ImageDimensions {
    var values: [4]f64 = undefined;
    var count: usize = 0;
    var cursor: usize = 0;
    while (cursor < raw.len) {
        while (cursor < raw.len and
            (std.ascii.isWhitespace(raw[cursor]) or raw[cursor] == ',')) cursor += 1;
        if (cursor == raw.len) break;
        if (count == values.len) return null;
        const start = cursor;
        while (cursor < raw.len and
            !std.ascii.isWhitespace(raw[cursor]) and raw[cursor] != ',') cursor += 1;
        values[count] = std.fmt.parseFloat(f64, raw[start..cursor]) catch return null;
        if (!std.math.isFinite(values[count])) return null;
        count += 1;
    }
    if (count != values.len or values[2] <= 0 or values[3] <= 0) return null;
    return .{ .width = values[2], .height = values[3] };
}

fn readLittleU16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn readBigU16(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]);
}

fn readBigU32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
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
    identifier_interpolation,
};

const ByteRange = struct {
    start: usize,
    end: usize,
};

const StylusMatchFlags = struct {
    global: bool = false,
    ignore_case: bool = false,
    multiline: bool = false,
};

const StylusLiteralPattern = struct {
    bytes: []const u8,
    anchor_start: bool,
    anchor_end: bool,
};

const StylusStructuredMatchPattern = struct {
    alternatives: []const u8,
    character_class: []const u8,
    minimum: usize,
};

const Assignment = struct {
    name: []const u8,
    value: []const u8,
    conditional: bool,
    operator: ?u8 = null,
};

const MemberReference = union(enum) {
    key: []const u8,
    index: usize,
    expression: []const u8,
};

const MemberAssignment = struct {
    base: []const u8,
    member: MemberReference,
    value: []const u8,
    value_empty: bool,
};

const Call = struct {
    name: ByteRange,
    arguments: ByteRange,
    parenthesized: bool = true,
    property_syntax: bool = false,
};

const Parameter = struct {
    name: []const u8,
    default_value: ?[]const u8 = null,
    rest: bool = false,
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

const MutationAlias = struct {
    local_name: []const u8,
    target: union(enum) {
        binding: struct {
            scope: native_environment.ScopeId,
            name: []const u8,
        },
        current_property_index: usize,
    },
};

const BindingReference = struct {
    scope: native_environment.ScopeId,
    name: []const u8,
};

const CurrentPropertyBinding = struct {
    scope: native_environment.ScopeId,
    name: []const u8,
};

const StaticExtension = struct {
    target: []u8,
    extender: []u8,
    directive_order: usize,
    prefixed_target: bool,
};

const DynamicExtensionPlan = struct {
    extensions: std.ArrayList(StaticExtension) = .empty,
    directives: std.AutoHashMapUnmanaged(u32, void) = .empty,

    fn deinit(self: *DynamicExtensionPlan, allocator: std.mem.Allocator) void {
        for (self.extensions.items) |extension| {
            allocator.free(extension.target);
            allocator.free(extension.extender);
        }
        self.extensions.deinit(allocator);
        self.directives.deinit(allocator);
        self.* = undefined;
    }
};

const ExtendDirective = struct {
    targets: []const u8,
    plural: bool,
};

const StaticConditionalState = enum {
    none,
    unknown,
    selected,
    not_selected,
};

const RenderedDeclaration = struct {
    span: native_source.Span,
    property: []u8,
    value: []u8,
    semantic_value: *const native_value.Value,
    side_effect: bool,

    fn deinit(self: *RenderedDeclaration, allocator: std.mem.Allocator) void {
        allocator.free(self.property);
        allocator.free(self.value);
        self.* = undefined;
    }
};

const InlineCommentAnchor = struct {
    start: usize,
    end: usize,
    leaf_count: usize,
    comma_count: usize,
    after_comma: bool,
    leading_space: bool,
    trailing_space: bool,
};

const CommentedDeclarationValue = struct {
    bytes: []u8,
    semantic: *const native_value.Value,
};

const ActiveProperty = struct {
    property: []const u8,
    value_span: native_source.Span,
    scope: native_environment.ScopeId,
};

const NestedRule = struct {
    id: native_syntax.NodeId,
    scope: native_environment.ScopeId,
    class_prefix: ?[]const u8 = null,
    active_callables: []const []const u8 = &.{},

    fn deinit(self: *NestedRule, allocator: std.mem.Allocator) void {
        allocator.free(self.active_callables);
        self.* = undefined;
    }
};

const CacheSelector = struct {
    bytes: []u8,
    order: u64,
};

const CacheEntry = struct {
    key: []u8,
    selectors: std.ArrayList(CacheSelector) = .empty,

    fn deinit(self: *CacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        for (self.selectors.items) |selector| allocator.free(selector.bytes);
        self.selectors.deinit(allocator);
        self.* = undefined;
    }
};

const CachePlan = struct {
    entries: std.ArrayList(CacheEntry) = .empty,

    fn deinit(self: *CachePlan, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    fn find(self: *const CachePlan, key: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.key, key)) return index;
        }
        return null;
    }

    fn record(
        self: *CachePlan,
        allocator: std.mem.Allocator,
        key: []const u8,
        selector: []const u8,
        orders: []const u64,
    ) Error!usize {
        const entry_index = self.find(key) orelse blk: {
            const owned_key = try allocator.dupe(u8, key);
            errdefer allocator.free(owned_key);
            try self.entries.append(allocator, .{ .key = owned_key });
            break :blk self.entries.items.len - 1;
        };
        var selectors = try splitTopLevel(allocator, selector, ',');
        defer selectors.deinit(allocator);
        if (selectors.items.len != orders.len) return error.InvalidDocument;
        for (selectors.items, orders) |range, order| {
            const candidate = std.mem.trim(u8, selector[range.start..range.end], " \t\r\n\x0c");
            if (candidate.len == 0) continue;
            var existing_index: ?usize = null;
            for (self.entries.items[entry_index].selectors.items, 0..) |existing, index| {
                if (std.mem.eql(u8, existing.bytes, candidate)) {
                    existing_index = index;
                    break;
                }
            }
            if (existing_index) |index| {
                const selectors_list = &self.entries.items[entry_index].selectors;
                if (order >= selectors_list.items[index].order) continue;
                var updated = selectors_list.orderedRemove(index);
                updated.order = order;
                var insertion = selectors_list.items.len;
                for (selectors_list.items, 0..) |existing, insert_index| {
                    if (order < existing.order) {
                        insertion = insert_index;
                        break;
                    }
                }
                selectors_list.insertAssumeCapacity(insertion, updated);
                continue;
            }
            const owned_selector = try allocator.dupe(u8, candidate);
            var insertion = self.entries.items[entry_index].selectors.items.len;
            for (self.entries.items[entry_index].selectors.items, 0..) |existing, index| {
                if (order < existing.order) {
                    insertion = index;
                    break;
                }
            }
            self.entries.items[entry_index].selectors.insert(allocator, insertion, .{
                .bytes = owned_selector,
                .order = order,
            }) catch |failure| {
                allocator.free(owned_selector);
                return failure;
            };
        }
        return entry_index;
    }

    fn eql(left: *const CachePlan, right: *const CachePlan) bool {
        if (left.entries.items.len != right.entries.items.len) return false;
        for (left.entries.items, right.entries.items) |left_entry, right_entry| {
            if (!std.mem.eql(u8, left_entry.key, right_entry.key) or
                left_entry.selectors.items.len != right_entry.selectors.items.len)
            {
                return false;
            }
            for (left_entry.selectors.items, right_entry.selectors.items) |left_selector, right_selector| {
                if (left_selector.order != right_selector.order or
                    !std.mem.eql(u8, left_selector.bytes, right_selector.bytes))
                {
                    return false;
                }
            }
        }
        return true;
    }
};

const CachedRule = struct {
    span: native_source.Span,
    entry_index: usize,
    declarations: std.ArrayList(RenderedDeclaration) = .empty,
    nested: std.ArrayList(NestedRule) = .empty,
    at_rules: std.ArrayList(NestedRule) = .empty,

    fn deinit(self: *CachedRule, allocator: std.mem.Allocator) void {
        for (self.declarations.items) |*declaration| declaration.deinit(allocator);
        self.declarations.deinit(allocator);
        for (self.nested.items) |*child| child.deinit(allocator);
        self.nested.deinit(allocator);
        for (self.at_rules.items) |*child| child.deinit(allocator);
        self.at_rules.deinit(allocator);
        self.* = undefined;
    }
};

const RuleOutput = struct {
    declarations: *std.ArrayList(RenderedDeclaration),
    nested: *std.ArrayList(NestedRule),
    at_rules: *std.ArrayList(NestedRule),
    cached: *std.ArrayList(CachedRule),
};

const StatementResult = struct {
    value: *const native_value.Value,
    explicit: bool,
};

const BlockValue = struct {
    block_id: native_syntax.NodeId,
    scope: native_environment.ScopeId,
    replay_side_effects: bool,
};

const EngineMode = enum {
    discover_cache,
    discover_extensions,
    emit,
};

const Engine = struct {
    allocator: std.mem.Allocator,
    sources: *const native_source.Table,
    document: *const native_syntax.Document,
    transaction: *native_evaluator.Transaction,
    limits: Limits,
    options: Options,
    values: native_value.Store,
    environment: native_environment.Environment,
    callables: std.ArrayList(Callable) = .empty,
    block_values: std.ArrayList(BlockValue) = .empty,
    active_callables: std.ArrayList([]const u8) = .empty,
    mutation_aliases: std.ArrayList(MutationAlias) = .empty,
    map_binding_aliases: std.ArrayList(BindingReference) = .empty,
    current_property_bindings: std.ArrayList(CurrentPropertyBinding) = .empty,
    json_local_names: std.ArrayList([]const u8) = .empty,
    selector_parts: std.ArrayList([]u8) = .empty,
    selector_identities: std.StringHashMapUnmanaged(void) = .empty,
    selector_identity_storage: std.ArrayList([]u8) = .empty,
    media_stack: std.ArrayList([]u8) = .empty,
    cache_seen: std.ArrayList([]const u8) = .empty,
    extensions: std.ArrayList(StaticExtension) = .empty,
    static_group_orders: std.AutoHashMapUnmanaged(u32, usize) = .empty,
    static_extension_directives: std.AutoHashMapUnmanaged(u32, void) = .empty,
    mode: EngineMode,
    cache_seed: *const CachePlan,
    cache_discovered: ?*CachePlan,
    dynamic_extension_plan: ?*DynamicExtensionPlan,
    call_depth: u16 = 0,
    loop_iterations: usize = 0,
    active_loop_depth: usize = 0,
    selector_count: usize = 0,
    selector_order: u64 = 0,
    static_group_count: usize = 0,
    temporary_bytes: usize = 0,
    active_selector_scope: ?[]u8 = null,
    active_class_prefix: ?[]const u8 = null,
    active_output: ?RuleOutput = null,
    active_property: ?ActiveProperty = null,
    active_property_value: ?*const native_value.Value = null,
    active_property_call_span: ?native_source.Span = null,
    pending_content_block: ?*const native_value.Value = null,
    active_keyframe_header: ?[]const u8 = null,
    active_rule_selector: ?[]const u8 = null,
    active_selector_identity: ?[]const u8 = null,
    active_rule_orders: ?[]const u64 = null,
    active_rule_group_order: ?usize = null,
    global_scope: ?*native_environment.ScopeId = null,
    cache_context_depth: u16 = 0,

    fn init(
        allocator: std.mem.Allocator,
        sources: *const native_source.Table,
        document: *const native_syntax.Document,
        transaction: *native_evaluator.Transaction,
        limits: Limits,
        options: Options,
        mode: EngineMode,
        cache_seed: *const CachePlan,
        cache_discovered: ?*CachePlan,
        dynamic_extension_plan: ?*DynamicExtensionPlan,
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
            .options = options,
            .mode = mode,
            .cache_seed = cache_seed,
            .cache_discovered = cache_discovered,
            .dynamic_extension_plan = dynamic_extension_plan,
            .values = values,
            .environment = environment,
        };
    }

    fn deinit(self: *Engine) void {
        if (self.active_selector_scope) |selector| self.allocator.free(selector);
        for (self.selector_parts.items) |part| self.allocator.free(part);
        self.selector_parts.deinit(self.allocator);
        self.selector_identities.deinit(self.allocator);
        for (self.selector_identity_storage.items) |selector| self.allocator.free(selector);
        self.selector_identity_storage.deinit(self.allocator);
        for (self.media_stack.items) |media| self.allocator.free(media);
        self.media_stack.deinit(self.allocator);
        self.cache_seen.deinit(self.allocator);
        for (self.extensions.items) |extension| {
            self.allocator.free(extension.target);
            self.allocator.free(extension.extender);
        }
        self.extensions.deinit(self.allocator);
        self.static_group_orders.deinit(self.allocator);
        self.static_extension_directives.deinit(self.allocator);
        self.mutation_aliases.deinit(self.allocator);
        self.map_binding_aliases.deinit(self.allocator);
        self.current_property_bindings.deinit(self.allocator);
        for (self.json_local_names.items) |name| self.allocator.free(name);
        self.json_local_names.deinit(self.allocator);
        self.block_values.deinit(self.allocator);
        self.active_callables.deinit(self.allocator);
        self.callables.deinit(self.allocator);
        self.environment.deinit();
        self.values.deinit();
        self.* = undefined;
    }

    fn emit(self: *Engine, bytes: []const u8) Error!void {
        if (self.mode == .emit) try self.transaction.emit(bytes);
    }

    fn emitMapped(
        self: *Engine,
        original: native_source.Span,
        name: ?[]const u8,
        bytes: []const u8,
    ) Error!void {
        if (self.mode == .emit) try self.transaction.emitMapped(original, name, bytes);
    }

    fn run(self: *Engine) Error!void {
        const root = self.document.get(self.document.root) catch
            return error.InvalidDocument;
        if (root.kind != .stylesheet) return error.InvalidDocument;
        var scope = self.environment.root();
        self.global_scope = &scope;
        defer self.global_scope = null;
        const root_statements = try self.document.children(self.document.root);
        if (self.mode == .emit) try self.seedDynamicExtensions();
        try self.collectStaticExtensions(root_statements, null, false);
        var ordinary: std.ArrayList(native_syntax.NodeId) = .empty;
        defer ordinary.deinit(self.allocator);
        for ([_][]const u8{ "@charset", "@import" }) |keyword| {
            for (root_statements) |statement_id| {
                const statement = try self.document.get(statement_id);
                if (statement.kind != .at_rule or statement.text == null) continue;
                const raw = std.mem.trim(u8, try self.sources.slice(statement.text.?), " \t\r\n\x0c;");
                if (startsWordAscii(raw, keyword)) try self.emitAtRule(statement_id, scope, null);
            }
        }
        for (root_statements) |statement_id| {
            const statement = try self.document.get(statement_id);
            if (statement.kind == .at_rule and statement.text != null) {
                const raw = std.mem.trim(u8, try self.sources.slice(statement.text.?), " \t\r\n\x0c;");
                if (startsWordAscii(raw, "@charset") or startsWordAscii(raw, "@import") or
                    startsWordAscii(raw, "@keyframes"))
                {
                    continue;
                }
            }
            try ordinary.append(self.allocator, statement_id);
        }
        const returned = try self.executeStatements(
            ordinary.items,
            &scope,
            null,
            false,
        );
        if (returned != null) return error.InvalidDocument;
        for (root_statements) |statement_id| {
            const statement = try self.document.get(statement_id);
            if (statement.kind != .at_rule or statement.text == null) continue;
            const raw = std.mem.trim(u8, try self.sources.slice(statement.text.?), " \t\r\n\x0c;");
            if (startsWordAscii(raw, "@keyframes")) {
                try self.emitAtRule(statement_id, scope, null);
            }
        }
    }

    fn seedDynamicExtensions(self: *Engine) Error!void {
        const plan = self.dynamic_extension_plan orelse return;
        for (plan.extensions.items) |extension| {
            const owned_target = try self.allocator.dupe(u8, extension.target);
            const owned_extender = self.allocator.dupe(u8, extension.extender) catch |failure| {
                self.allocator.free(owned_target);
                return failure;
            };
            self.extensions.append(self.allocator, .{
                .target = owned_target,
                .extender = owned_extender,
                .directive_order = extension.directive_order,
                .prefixed_target = extension.prefixed_target,
            }) catch |failure| {
                self.allocator.free(owned_target);
                self.allocator.free(owned_extender);
                return failure;
            };
        }
        var directive_iterator = plan.directives.keyIterator();
        while (directive_iterator.next()) |directive_id| {
            try self.static_extension_directives.put(
                self.allocator,
                directive_id.*,
                {},
            );
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
        const normalized = try self.normalizeEolEscapesOwned(text, raw);
        defer if (normalized) |owned| self.allocator.free(owned);
        const definition_raw = normalized orelse raw;
        const definition = parseDefinition(definition_raw) orelse {
            try self.reportInvalidArguments(text);
            return error.InvalidArguments;
        };
        const name = raw[definition.name.start..definition.name.end];
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
        if (parseMemberAssignment(raw)) |member| {
            if (!member.value_empty) {
                try self.assignMemberValue(text, member, scope.*);
                return;
            }
            if (try self.hasExplicitOpeningBrace(node_id)) {
                try self.reportInvalidOperation(text);
                return error.InvalidOperation;
            }
            const block_value = try self.ownBlockValue(
                text,
                try self.statementBlock(node_id),
                scope.*,
                true,
            );
            try self.assignMemberBlock(text, member, block_value, scope.*);
            return;
        }
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
            try self.lookupBinding(scope.*, assignment.name) != null)
        {
            return;
        }
        var map_alias_name: ?[]const u8 = null;
        var evaluated = if (std.mem.eql(u8, assignment.value, "@block") or
            (assignment.value.len == 0 and !try self.hasExplicitOpeningBrace(node_id)))
            try self.ownBlockValue(text, try self.statementBlock(node_id), scope.*, true)
        else if (assignment.value.len == 0)
            try self.evaluateObjectBlock(node_id, scope.*)
        else alias: {
            if (assignment.operator == null and validVariableName(assignment.value)) {
                if (try self.lookupBinding(scope.*, assignment.value)) |candidate| {
                    if (candidate.* == .map) {
                        map_alias_name = assignment.value;
                        break :alias candidate;
                    }
                }
            }
            break :alias try self.evaluateValue(text, assignment.value, scope.*, 0);
        };
        if (assignment.operator) |operator| {
            const current = (try self.lookupBinding(scope.*, assignment.name)) orelse {
                try self.reportUndefinedVariable(text);
                return error.UndefinedVariable;
            };
            evaluated = try self.evaluateGenericBinary(text, current, evaluated, operator);
        }
        self.detachMutationAlias(assignment.name);
        try self.detachMapBindingAliases(scope.*, assignment.name);
        const aliases_current_property = self.active_property_value != null and
            evaluated == self.active_property_value.?;
        scope.* = try self.setBinding(scope.*, assignment.name, evaluated, text);
        if (map_alias_name) |source_name| {
            try self.registerMapBindingAlias(
                scope.*,
                assignment.name,
                source_name,
                text,
            );
        }
        if (aliases_current_property) {
            try self.current_property_bindings.append(self.allocator, .{
                .scope = scope.*,
                .name = assignment.name,
            });
        }
    }

    fn hasExplicitOpeningBrace(
        self: *const Engine,
        node_id: native_syntax.NodeId,
    ) Error!bool {
        const node = try self.document.get(node_id);
        const text = node.text orelse return error.InvalidDocument;
        const block = try self.document.get(try self.statementBlock(node_id));
        if (text.source.value != block.span.source.value or text.end > block.span.start) {
            return error.InvalidDocument;
        }
        const file = try self.sources.get(text.source);
        return std.mem.indexOfScalar(
            u8,
            file.bytes[@intCast(text.end)..@intCast(block.span.start)],
            '{',
        ) != null;
    }

    fn ownBlockValue(
        self: *Engine,
        span: native_source.Span,
        block_id: native_syntax.NodeId,
        scope: native_environment.ScopeId,
        replay_side_effects: bool,
    ) Error!*const native_value.Value {
        if (self.block_values.items.len >= std.math.maxInt(u32)) {
            try self.reportResource(span, "native Stylus value limit exceeded");
            return error.ValueLimitExceeded;
        }
        const index = self.block_values.items.len;
        try self.block_values.append(self.allocator, .{
            .block_id = block_id,
            .scope = scope,
            .replay_side_effects = replay_side_effects,
        });
        errdefer _ = self.block_values.pop();
        var marker_buffer: [block_value_prefix.len + 10]u8 = undefined;
        const marker = std.fmt.bufPrint(
            &marker_buffer,
            "{s}{d}",
            .{ block_value_prefix, index },
        ) catch return error.ValueLimitExceeded;
        return self.ownValue(span, .{ .string = .{ .bytes = marker } });
    }

    fn blockValue(self: *const Engine, value: *const native_value.Value) ?BlockValue {
        if (value.* != .string or value.string.quoted or
            !std.mem.startsWith(u8, value.string.bytes, block_value_prefix))
        {
            return null;
        }
        const index = std.fmt.parseUnsigned(
            usize,
            value.string.bytes[block_value_prefix.len..],
            10,
        ) catch return null;
        if (index >= self.block_values.items.len) return null;
        return self.block_values.items[index];
    }

    fn assignMemberBlock(
        self: *Engine,
        span: native_source.Span,
        assignment: MemberAssignment,
        block_value: *const native_value.Value,
        scope: native_environment.ScopeId,
    ) Error!void {
        const current = (try self.lookupBinding(scope, assignment.base)) orelse {
            try self.reportUndefinedVariable(span);
            return error.UndefinedVariable;
        };
        const replacement = switch (assignment.member) {
            .key => |key| blk: {
                if (current.* != .map) {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                }
                var entries: std.ArrayList(native_value.Entry) = .empty;
                defer entries.deinit(self.allocator);
                var replaced = false;
                for (current.map.entries) |entry| {
                    if (entry.key == .string and std.mem.eql(u8, entry.key.string.bytes, key)) {
                        try entries.append(self.allocator, .{
                            .key = entry.key,
                            .value = block_value.*,
                        });
                        replaced = true;
                    } else {
                        try entries.append(self.allocator, entry);
                    }
                }
                if (!replaced) try entries.append(self.allocator, .{
                    .key = .{ .string = .{ .bytes = key } },
                    .value = block_value.*,
                });
                break :blk try self.ownValue(span, .{ .map = .{ .entries = entries.items } });
            },
            .index => |index| blk: {
                if (current.* != .list or index > current.list.items.len) {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                }
                var items: std.ArrayList(native_value.Value) = .empty;
                defer items.deinit(self.allocator);
                try items.appendSlice(self.allocator, current.list.items);
                if (index == items.items.len) {
                    try items.append(self.allocator, block_value.*);
                } else {
                    items.items[index] = block_value.*;
                }
                break :blk try self.ownValue(span, .{ .list = .{
                    .items = items.items,
                    .separator = current.list.separator,
                    .bracketed = current.list.bracketed,
                } });
            },
            .expression => {
                try self.reportInvalidOperation(span);
                return error.InvalidOperation;
            },
        };
        if (!(try self.updateBinding(scope, assignment.base, replacement))) {
            return error.UndefinedVariable;
        }
    }

    fn assignMemberValue(
        self: *Engine,
        span: native_source.Span,
        assignment: MemberAssignment,
        scope: native_environment.ScopeId,
    ) Error!void {
        const postfix = splitPostfixCondition(assignment.value);
        if (postfix.condition) |condition| {
            var selected = try self.evaluateCondition(
                span,
                assignment.value[condition.expression.start..condition.expression.end],
                scope,
            );
            if (condition.negated) selected = !selected;
            if (!selected) return;
        }
        const value_raw = assignment.value[postfix.declaration.start..postfix.declaration.end];
        const value = try self.evaluateValue(span, value_raw, scope, 0);
        const current = (try self.lookupBinding(scope, assignment.base)) orelse {
            try self.reportUndefinedVariable(span);
            return error.UndefinedVariable;
        };

        const resolved_member: union(enum) { key: []const u8, index: usize } = switch (assignment.member) {
            .key => |key| .{ .key = key },
            .index => |index| .{ .index = index },
            .expression => |raw_member| blk: {
                const member_value = try self.evaluateValue(span, raw_member, scope, 0);
                if (stringBytes(member_value.*)) |key| break :blk .{ .key = key };
                const signed = integerScalar(member_value.*) orelse {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                };
                const index = std.math.cast(usize, signed) orelse {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                };
                break :blk .{ .index = index };
            },
        };
        const replacement = switch (resolved_member) {
            .key => |key| blk: {
                if (current.* != .map) {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                }
                var entries: std.ArrayList(native_value.Entry) = .empty;
                defer entries.deinit(self.allocator);
                var replaced = false;
                for (current.map.entries) |entry| {
                    if (entry.key == .string and std.mem.eql(u8, entry.key.string.bytes, key)) {
                        try entries.append(self.allocator, .{ .key = entry.key, .value = value.* });
                        replaced = true;
                    } else {
                        try entries.append(self.allocator, entry);
                    }
                }
                if (!replaced) try entries.append(self.allocator, .{
                    .key = .{ .string = .{ .bytes = key } },
                    .value = value.*,
                });
                break :blk try self.ownValue(span, .{ .map = .{ .entries = entries.items } });
            },
            .index => |index| blk: {
                if (current.* != .list) {
                    if (index == 0) break :blk value;
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                }
                if (index >= current.list.items.len) {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                }
                var items: std.ArrayList(native_value.Value) = .empty;
                defer items.deinit(self.allocator);
                try items.appendSlice(self.allocator, current.list.items);
                items.items[index] = value.*;
                break :blk try self.ownValue(span, .{ .list = .{
                    .items = items.items,
                    .separator = current.list.separator,
                    .bracketed = current.list.bracketed,
                } });
            },
        };
        if (!(try self.updateMutationBinding(scope, assignment.base, replacement))) {
            return error.UndefinedVariable;
        }
    }

    fn evaluateObjectBlock(
        self: *Engine,
        node_id: native_syntax.NodeId,
        scope: native_environment.ScopeId,
    ) Error!*const native_value.Value {
        const block = try self.statementBlock(node_id);
        var entries: std.ArrayList(native_value.Entry) = .empty;
        defer entries.deinit(self.allocator);
        for (try self.document.children(block)) |child_id| {
            const child = try self.document.get(child_id);
            const text = child.text orelse continue;
            const raw = std.mem.trim(u8, try self.sources.slice(text), " \t\r\n\x0c;,{");
            if (child.kind == .comment) continue;
            if (child.kind == .rule and (try self.document.children(child_id)).len > 1) {
                const key = std.mem.trimRight(u8, raw, " \t\r\n\x0c:");
                const value = try self.evaluateObjectBlock(child_id, scope);
                try entries.append(self.allocator, .{
                    .key = .{ .string = .{ .bytes = key, .quoted = true } },
                    .value = value.*,
                });
                continue;
            }
            // The parser retains a same-line object literal as one declaration
            // node, so split its finite top-level members here.
            var member_ranges = try splitTopLevel(self.allocator, raw, ',');
            defer member_ranges.deinit(self.allocator);
            for (member_ranges.items) |range| {
                const member_raw = std.mem.trim(
                    u8,
                    raw[range.start..range.end],
                    " \t\r\n\x0c",
                );
                const parts = splitDeclaration(member_raw) orelse return error.InvalidDocument;
                const key = std.mem.trim(
                    u8,
                    member_raw[parts[0].start..parts[0].end],
                    " \t\r\n\x0c'\"",
                );
                const value = try self.evaluateValue(
                    text,
                    member_raw[parts[1].start..parts[1].end],
                    scope,
                    0,
                );
                try entries.append(self.allocator, .{
                    .key = .{ .string = .{ .bytes = key, .quoted = true } },
                    .value = value.*,
                });
            }
        }
        return self.ownValue((try self.document.get(node_id)).span, .{ .map = .{ .entries = entries.items } });
    }

    fn evaluateMemberChain(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        scope: native_environment.ScopeId,
    ) Error!?*const native_value.Value {
        if (raw.len < 3 or !isNameStart(raw, 0)) return null;
        const cursor = nameEnd(raw, 0);
        if (cursor >= raw.len or (raw[cursor] != '.' and raw[cursor] != '[')) return null;
        const base = raw[0..cursor];
        const current = if (nameEql(base, "current-property")) blk: {
            if (try self.lookupBinding(scope, base)) |bound| break :blk bound;
            break :blk (try self.currentPropertyValue(span, scope)) orelse return null;
        } else (try self.lookupBinding(scope, base)) orelse return null;
        return self.evaluateMemberSuffix(span, raw, cursor, current, scope);
    }

    fn evaluateCallMemberChain(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        scope: native_environment.ScopeId,
        depth: u16,
    ) Error!?*const native_value.Value {
        if (raw.len < 4 or !isNameStart(raw, 0)) return null;
        const name_end = nameEnd(raw, 0);
        var opening = name_end;
        while (opening < raw.len and std.ascii.isWhitespace(raw[opening])) opening += 1;
        if (opening >= raw.len or raw[opening] != '(') return null;
        const closing = matchingParen(raw, opening) orelse return null;
        const cursor = closing + 1;
        if (cursor >= raw.len or (raw[cursor] != '.' and raw[cursor] != '[')) return null;
        const current = try self.evaluateValue(span, raw[0..cursor], scope, depth + 1);
        return self.evaluateMemberSuffix(span, raw, cursor, current, scope);
    }

    fn evaluateMemberSuffix(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        initial_cursor: usize,
        initial: *const native_value.Value,
        scope: native_environment.ScopeId,
    ) Error!?*const native_value.Value {
        var cursor = initial_cursor;
        var current = initial;
        while (cursor < raw.len) {
            if (raw[cursor] == '.') {
                cursor += 1;
                if (cursor >= raw.len or !isNameStart(raw, cursor)) return null;
                const end = nameEnd(raw, cursor);
                if (current.* != .map) return null;
                var selected: ?native_value.Value = null;
                for (current.map.entries) |entry| {
                    if (entry.key == .string and std.mem.eql(u8, entry.key.string.bytes, raw[cursor..end])) {
                        selected = entry.value;
                    }
                }
                current = try self.ownValue(span, selected orelse .{ .null_value = {} });
                cursor = end;
                continue;
            }
            if (raw[cursor] == '[') {
                const closing = std.mem.indexOfScalarPos(u8, raw, cursor + 1, ']') orelse return null;
                const index_value = try self.evaluateValue(span, raw[cursor + 1 .. closing], scope, 0);
                current = switch (current.*) {
                    .list => |list| blk: {
                        const index = integerScalar(index_value.*) orelse return null;
                        const normalized = normalizeIndex(index, list.items.len) orelse
                            break :blk try self.ownValue(span, .{ .null_value = {} });
                        break :blk try self.ownValue(span, list.items[normalized]);
                    },
                    .map => |map| blk: {
                        var selected: ?native_value.Value = null;
                        for (map.entries) |entry| {
                            if (stylusValueEqual(entry.key, index_value.*)) selected = entry.value;
                        }
                        break :blk try self.ownValue(span, selected orelse .{ .null_value = {} });
                    },
                    else => return null,
                };
                cursor = closing + 1;
                continue;
            }
            return null;
        }
        return self.ownValue(span, current.*);
    }

    fn collectStaticExtensions(
        self: *Engine,
        statements: []const native_syntax.NodeId,
        parent_selector: ?[]const u8,
        current_selector_nested: bool,
    ) Error!void {
        var previous_condition: StaticConditionalState = .none;
        for (statements) |statement_id| {
            const statement = try self.document.get(statement_id);
            if (statement.kind == .at_rule) {
                previous_condition = .none;
                const text = statement.text orelse continue;
                const raw = std.mem.trim(
                    u8,
                    try self.sources.slice(text),
                    " \t\r\n\x0c;",
                );
                if (startsWordAscii(raw, "@media")) {
                    const children = try self.document.children(statement_id);
                    if (children.len > 0) {
                        const block_id = children[children.len - 1];
                        if ((try self.document.get(block_id)).kind == .block) {
                            try self.collectStaticExtensions(
                                try self.document.children(block_id),
                                parent_selector,
                                current_selector_nested,
                            );
                        }
                    }
                    continue;
                }
                const extender = parent_selector orelse continue;
                const directive = parseExtendDirective(raw) orelse continue;
                var targets_raw = directive.targets;
                if (std.mem.indexOf(u8, targets_raw, " !optional")) |optional| {
                    targets_raw = std.mem.trimRight(
                        u8,
                        targets_raw[0..optional],
                        " \t\r\n\x0c;",
                    );
                }
                if (targets_raw.len == 0) continue;
                var targets = try splitTopLevel(self.allocator, targets_raw, ',');
                defer targets.deinit(self.allocator);
                if (directive.plural) {
                    if (current_selector_nested or targets.items.len != 1) {
                        continue;
                    }
                    var extenders = try splitTopLevel(self.allocator, extender, ',');
                    defer extenders.deinit(self.allocator);
                    if (extenders.items.len != 1) continue;
                }
                try self.static_extension_directives.put(
                    self.allocator,
                    statement_id.value,
                    {},
                );
                for (targets.items) |range| {
                    const target = std.mem.trim(
                        u8,
                        targets_raw[range.start..range.end],
                        " \t\r\n\x0c;",
                    );
                    if (target.len == 0 or std.mem.indexOfScalar(u8, target, '{') != null) {
                        continue;
                    }
                    const owned_target = try self.allocator.dupe(u8, target);
                    const owned_extender = self.allocator.dupe(u8, extender) catch |failure| {
                        self.allocator.free(owned_target);
                        return failure;
                    };
                    self.extensions.append(self.allocator, .{
                        .target = owned_target,
                        .extender = owned_extender,
                        .directive_order = self.static_group_count,
                        .prefixed_target = current_selector_nested,
                    }) catch |failure| {
                        self.allocator.free(owned_target);
                        self.allocator.free(owned_extender);
                        return failure;
                    };
                }
                continue;
            }
            if (statement.kind == .conditional) {
                const text = statement.text orelse {
                    previous_condition = .unknown;
                    continue;
                };
                const raw = std.mem.trim(
                    u8,
                    try self.sources.slice(text),
                    " \t\r\n\x0c;",
                );
                var branch_selected = false;
                if (startsWordAscii(raw, "else")) {
                    const remainder = std.mem.trim(
                        u8,
                        raw["else".len..],
                        " \t\r\n\x0c;",
                    );
                    switch (previous_condition) {
                        .selected => previous_condition = .selected,
                        .not_selected => {
                            if (remainder.len == 0) {
                                branch_selected = true;
                                previous_condition = .selected;
                            } else if (staticConditionSelected(remainder)) |selected| {
                                branch_selected = selected;
                                previous_condition = if (selected) .selected else .not_selected;
                            } else {
                                previous_condition = .unknown;
                            }
                        },
                        .none, .unknown => previous_condition = .unknown,
                    }
                } else if (staticConditionSelected(raw)) |selected| {
                    branch_selected = selected;
                    previous_condition = if (selected) .selected else .not_selected;
                } else {
                    previous_condition = .unknown;
                }
                if (branch_selected) {
                    const block = try self.statementBlock(statement_id);
                    try self.collectStaticExtensions(
                        try self.document.children(block),
                        parent_selector,
                        current_selector_nested,
                    );
                }
                continue;
            }
            if (statement.kind == .loop) {
                previous_condition = .none;
                const block = try self.statementBlock(statement_id);
                for (try self.document.children(block)) |child_id| {
                    try self.indexLoopRuleGroups(child_id);
                }
                continue;
            }
            previous_condition = .none;
            if (statement.kind != .rule) continue;
            try self.static_group_orders.put(
                self.allocator,
                statement_id.value,
                self.static_group_count,
            );
            self.static_group_count += 1;
            const children = try self.document.children(statement_id);
            if (children.len != 2) continue;
            const selector_node = try self.document.get(children[0]);
            const block_node = try self.document.get(children[1]);
            if (selector_node.kind != .selector or selector_node.text == null or block_node.kind != .block) continue;
            const raw_selector = try self.sources.slice(selector_node.text.?);
            const rendered = try self.renderStaticSelectorOwned(
                selector_node.text.?,
                raw_selector,
                parent_selector,
            );
            defer self.allocator.free(rendered);
            const normalized = try self.normalizeSelectorLines(selector_node.text.?, rendered);
            defer self.allocator.free(normalized);
            const saved_selector_count = self.selector_count;
            const full_selector = if (std.mem.startsWith(
                u8,
                std.mem.trim(u8, normalized, " \t\r\n\x0c"),
                "/",
            ))
                try self.resolveSelectorBranchOwned(
                    selector_node.text.?,
                    std.mem.trim(u8, normalized, " \t\r\n\x0c"),
                )
            else
                try self.combineSelectorsLiteral(
                    parent_selector,
                    normalized,
                    selector_node.text.?,
                );
            self.selector_count = saved_selector_count;
            defer self.allocator.free(full_selector);

            const block_statements = try self.document.children(children[1]);
            try self.collectStaticExtensions(
                block_statements,
                full_selector,
                parent_selector != null,
            );
        }
    }

    fn indexLoopRuleGroups(
        self: *Engine,
        node_id: native_syntax.NodeId,
    ) Error!void {
        const node = try self.document.get(node_id);
        if (node.kind == .rule and !self.static_group_orders.contains(node_id.value)) {
            try self.static_group_orders.put(
                self.allocator,
                node_id.value,
                self.static_group_count,
            );
            self.static_group_count += 1;
        }
        for (try self.document.children(node_id)) |child_id| {
            try self.indexLoopRuleGroups(child_id);
        }
    }

    fn discoverDynamicExtension(
        self: *Engine,
        statement_id: native_syntax.NodeId,
        span: native_source.Span,
        directive: ExtendDirective,
        scope: native_environment.ScopeId,
    ) Error!bool {
        if (self.mode != .discover_extensions) return false;
        const plan = self.dynamic_extension_plan orelse return false;
        const extender = self.active_selector_identity orelse return false;
        var targets_raw = directive.targets;
        if (std.mem.indexOf(u8, targets_raw, " !optional")) |optional| {
            targets_raw = std.mem.trimRight(
                u8,
                targets_raw[0..optional],
                " \t\r\n\x0c;",
            );
        }
        if (targets_raw.len == 0) return false;
        const statically_collected = self.static_extension_directives.contains(
            statement_id.value,
        );
        const nested = self.selector_parts.items.len > 1;
        if (statically_collected) {
            if (!multipleExtensionTargetsNeedRuntimeRendering(targets_raw) or
                directive.plural)
            {
                return false;
            }
            var original_targets = try splitTopLevel(self.allocator, targets_raw, ',');
            defer original_targets.deinit(self.allocator);
            var appended = false;
            for (original_targets.items) |range| {
                const original_target = std.mem.trim(
                    u8,
                    targets_raw[range.start..range.end],
                    " \t\r\n\x0c;",
                );
                if (!extensionTargetNeedsRuntimeRendering(original_target)) continue;
                const rendered = try self.renderRawOwned(
                    span,
                    original_target,
                    scope,
                    .selector,
                    0,
                );
                defer self.allocator.free(rendered);
                const normalized = try self.normalizeSelectorLines(span, rendered);
                defer self.allocator.free(normalized);
                var rendered_targets = try splitTopLevel(self.allocator, normalized, ',');
                defer rendered_targets.deinit(self.allocator);
                for (rendered_targets.items) |rendered_range| {
                    const target = std.mem.trim(
                        u8,
                        normalized[rendered_range.start..rendered_range.end],
                        " \t\r\n\x0c;",
                    );
                    if (try self.appendDiscoveredExtension(
                        plan,
                        span,
                        target,
                        extender,
                        nested,
                    )) appended = true;
                }
            }
            if (appended) try plan.directives.put(self.allocator, statement_id.value, {});
            return appended;
        }
        if (self.active_loop_depth == 0 and self.active_callables.items.len == 0) return false;

        const rendered_targets = try self.renderRawOwned(
            span,
            targets_raw,
            scope,
            .selector,
            0,
        );
        defer self.allocator.free(rendered_targets);
        const normalized_targets = try self.normalizeSelectorLines(span, rendered_targets);
        defer self.allocator.free(normalized_targets);
        var targets = try splitTopLevel(self.allocator, normalized_targets, ',');
        defer targets.deinit(self.allocator);
        if (directive.plural) {
            if (nested or targets.items.len != 1 or
                !selectorHasTopLevelCombinator(normalized_targets))
            {
                return false;
            }
            var extenders = try splitTopLevel(self.allocator, extender, ',');
            defer extenders.deinit(self.allocator);
            if (extenders.items.len != 1) return false;
        }

        var appended = false;
        for (targets.items) |range| {
            const target = std.mem.trim(
                u8,
                normalized_targets[range.start..range.end],
                " \t\r\n\x0c;",
            );
            if (try self.appendDiscoveredExtension(
                plan,
                span,
                target,
                extender,
                nested,
            )) appended = true;
        }
        if (appended) try plan.directives.put(self.allocator, statement_id.value, {});
        return appended;
    }

    fn appendDiscoveredExtension(
        self: *Engine,
        plan: *DynamicExtensionPlan,
        span: native_source.Span,
        target: []const u8,
        extender: []const u8,
        nested: bool,
    ) Error!bool {
        if (target.len == 0 or std.mem.indexOfScalar(u8, target, '{') != null) return false;
        if (plan.extensions.items.len >= self.limits.max_selectors) {
            try self.reportSelectorLimit(span);
            return error.SelectorLimitExceeded;
        }
        const owned_target = try self.allocator.dupe(u8, target);
        const owned_extender = self.allocator.dupe(u8, extender) catch |failure| {
            self.allocator.free(owned_target);
            return failure;
        };
        plan.extensions.append(self.allocator, .{
            .target = owned_target,
            .extender = owned_extender,
            .directive_order = if (self.active_rule_group_order) |order|
                order + 1
            else
                self.static_group_count,
            .prefixed_target = nested,
        }) catch |failure| {
            self.allocator.free(owned_target);
            self.allocator.free(owned_extender);
            return failure;
        };
        return true;
    }

    fn renderStaticSelectorOwned(
        self: *Engine,
        span: native_source.Span,
        selector: []const u8,
        parent_selector: ?[]const u8,
    ) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var cursor: usize = 0;
        while (cursor < selector.len) {
            const opening = std.mem.indexOfScalarPos(u8, selector, cursor, '{') orelse {
                try self.appendTemporary(&output, span, selector[cursor..]);
                break;
            };
            try self.appendTemporary(&output, span, selector[cursor..opening]);
            const closing = matchingCurly(selector, opening) orelse {
                try self.appendTemporary(&output, span, selector[opening..]);
                break;
            };
            const expression = std.mem.trim(
                u8,
                selector[opening + 1 .. closing],
                " \t\r\n\x0c",
            );
            if (std.mem.eql(u8, expression, "selector()")) {
                try self.appendTemporary(&output, span, parent_selector orelse "&");
            } else {
                try self.appendTemporary(&output, span, selector[opening .. closing + 1]);
            }
            cursor = closing + 1;
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn expandExtendedSelectorOwned(
        self: *Engine,
        span: native_source.Span,
        selector: []const u8,
        rule_id: native_syntax.NodeId,
    ) Error![]u8 {
        var selectors = try splitTopLevelOwnedStrings(self.allocator, selector, ',');
        defer {
            for (selectors.items) |item| self.allocator.free(item);
            selectors.deinit(self.allocator);
        }
        const original_selector_count = selectors.items.len;
        const group_order = self.static_group_orders.get(rule_id.value);
        for (0..self.extensions.items.len + 1) |_| {
            var changed = false;
            for (self.extensions.items) |extension| {
                if (group_order) |order| {
                    if (order >= extension.directive_order) continue;
                }
                const current_len = selectors.items.len;
                var candidate_index: usize = 0;
                while (candidate_index < current_len) : (candidate_index += 1) {
                    const candidate = selectors.items[candidate_index];
                    const match: ByteRange = if (std.mem.eql(
                        u8,
                        candidate,
                        extension.target,
                    ) or selectorsEqualForExtension(candidate, extension.target))
                        .{ .start = 0, .end = candidate.len }
                    else if (candidate_index < original_selector_count and
                        !extension.prefixed_target)
                        continue
                    else blk: {
                        const marker = selectorTokenIndex(
                            candidate,
                            extension.target,
                        ) orelse continue;
                        break :blk .{
                            .start = marker,
                            .end = marker + extension.target.len,
                        };
                    };
                    var extenders = try splitTopLevel(self.allocator, extension.extender, ',');
                    defer extenders.deinit(self.allocator);
                    for (extenders.items) |range| {
                        const extender = std.mem.trim(
                            u8,
                            extension.extender[range.start..range.end],
                            " \t\r\n\x0c",
                        );
                        const prefix = candidate[0..match.start];
                        const suffix = candidate[match.end..];
                        const prefix_bytes = if (prefix.len > 0 and
                            std.mem.startsWith(u8, extender, prefix)) 0 else prefix.len;
                        const replacement_len = std.math.add(
                            usize,
                            std.math.add(usize, prefix_bytes, extender.len) catch {
                                try self.reportResource(span, "native Stylus temporary byte limit exceeded");
                                return error.TemporaryLimitExceeded;
                            },
                            suffix.len,
                        ) catch {
                            try self.reportResource(span, "native Stylus temporary byte limit exceeded");
                            return error.TemporaryLimitExceeded;
                        };
                        try self.reserveTemporary(span, replacement_len);
                        try self.transaction.consumeOperations(replacement_len);
                        const replacement = if (prefix_bytes == 0)
                            try std.fmt.allocPrint(
                                self.allocator,
                                "{s}{s}",
                                .{ extender, suffix },
                            )
                        else
                            try std.fmt.allocPrint(
                                self.allocator,
                                "{s}{s}{s}",
                                .{ prefix, extender, suffix },
                            );
                        var duplicate = false;
                        for (selectors.items) |prior| {
                            if (std.mem.eql(u8, prior, replacement)) {
                                duplicate = true;
                                break;
                            }
                        }
                        if (duplicate) {
                            self.allocator.free(replacement);
                        } else {
                            if (self.selector_count >= self.limits.max_selectors) {
                                self.allocator.free(replacement);
                                try self.reportSelectorLimit(span);
                                return error.SelectorLimitExceeded;
                            }
                            selectors.append(self.allocator, replacement) catch |failure| {
                                self.allocator.free(replacement);
                                return failure;
                            };
                            self.selector_count += 1;
                            changed = true;
                        }
                    }
                }
            }
            if (!changed) break;
        }
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        for (selectors.items, 0..) |item, index| {
            if (index > 0) try self.appendTemporary(&output, span, ",");
            try self.appendTemporary(&output, span, item);
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn evaluateInlineMap(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        scope: native_environment.ScopeId,
    ) Error!*const native_value.Value {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n\x0c;");
        if (trimmed.len == 0) return self.ownValue(span, .{ .map = .{ .entries = &.{} } });
        var ranges = try splitTopLevel(self.allocator, trimmed, ',');
        defer ranges.deinit(self.allocator);
        var entries: std.ArrayList(native_value.Entry) = .empty;
        defer entries.deinit(self.allocator);
        for (ranges.items) |range| {
            const entry_raw = trimmed[range.start..range.end];
            const colon = findTopLevelScalar(entry_raw, ':') orelse return error.InvalidDocument;
            const key = std.mem.trim(u8, entry_raw[0..colon], " \t\r\n\x0c'\"");
            const value_raw = std.mem.trim(u8, entry_raw[colon + 1 ..], " \t\r\n\x0c");
            const value = try self.evaluateValue(span, value_raw, scope, 0);
            try entries.append(self.allocator, .{
                .key = .{ .string = .{ .bytes = key } },
                .value = value.*,
            });
        }
        return self.ownValue(span, .{ .map = .{ .entries = entries.items } });
    }

    fn emitNestedOutput(
        self: *Engine,
        child: NestedRule,
        parent_selector: ?[]const u8,
        at_rule: bool,
    ) Error!void {
        const previous_prefix = self.active_class_prefix;
        self.active_class_prefix = child.class_prefix;
        defer self.active_class_prefix = previous_prefix;
        const callable_count = self.active_callables.items.len;
        try self.active_callables.appendSlice(self.allocator, child.active_callables);
        defer self.active_callables.shrinkRetainingCapacity(callable_count);
        if (at_rule) {
            try self.emitAtRule(child.id, child.scope, parent_selector);
        } else {
            try self.emitRule(child.id, child.scope, parent_selector);
        }
    }

    fn replayNestedSelectorMemberAssignments(
        self: *Engine,
        rule_id: native_syntax.NodeId,
        parent_scope: native_environment.ScopeId,
        parent_selector: ?[]const u8,
    ) Error!void {
        const children = try self.document.children(rule_id);
        if (children.len != 2) return;
        const selector_node = try self.document.get(children[0]);
        const block_node = try self.document.get(children[1]);
        if (selector_node.kind != .selector or selector_node.text == null or
            block_node.kind != .block)
        {
            return;
        }
        const statements = try self.document.children(children[1]);
        var owns_selector_assignment = false;
        for (statements) |statement_id| {
            const statement = try self.document.get(statement_id);
            if (statement.kind != .variable or statement.text == null) continue;
            const assignment = parseMemberAssignment(
                try self.sources.slice(statement.text.?),
            ) orelse continue;
            if (std.mem.eql(
                u8,
                std.mem.trim(u8, assignment.value, " \t\r\n\x0c"),
                "selector()",
            )) {
                owns_selector_assignment = true;
                break;
            }
        }
        if (!owns_selector_assignment) return;

        const rendered = try self.renderTextOwned(
            selector_node.text.?,
            parent_scope,
            .selector,
            0,
        );
        defer self.allocator.free(rendered);
        const normalized = try self.normalizeSelectorLines(selector_node.text.?, rendered);
        defer self.allocator.free(normalized);
        const prefixed = if (self.active_class_prefix) |prefix|
            if (prefix.len > 0)
                try self.prefixClassSelectorsOwned(selector_node.text.?, normalized, prefix)
            else
                null
        else
            null;
        defer if (prefixed) |owned| self.allocator.free(owned);
        const scoped = prefixed orelse normalized;
        const selector = try self.combineSelectors(parent_selector, scoped, selector_node.text.?);
        defer self.allocator.free(selector);

        const previous_rule_selector = self.active_rule_selector;
        const previous_selector_identity = self.active_selector_identity;
        self.active_rule_selector = selector;
        self.active_selector_identity = selector;
        defer {
            self.active_rule_selector = previous_rule_selector;
            self.active_selector_identity = previous_selector_identity;
        }
        const selector_part = try self.selectorPartOwned(
            selector_node.text.?,
            scoped,
            parent_selector != null,
        );
        self.selector_parts.append(self.allocator, selector_part) catch |failure| {
            self.allocator.free(selector_part);
            return failure;
        };
        defer self.allocator.free(self.selector_parts.pop().?);

        var assignment_scope = self.environment.push(parent_scope) catch |failure| {
            try self.reportResource(
                block_node.span,
                "native Stylus lexical scope limit exceeded",
            );
            return failure;
        };
        for (statements) |statement_id| {
            const statement = try self.document.get(statement_id);
            if (statement.kind != .variable or statement.text == null) continue;
            const assignment = parseMemberAssignment(
                try self.sources.slice(statement.text.?),
            ) orelse continue;
            if (!std.mem.eql(
                u8,
                std.mem.trim(u8, assignment.value, " \t\r\n\x0c"),
                "selector()",
            )) continue;
            try self.assign(statement_id, &assignment_scope);
        }
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
        const normalized_rendered = try self.normalizeSelectorLines(
            selector_node.text.?,
            rendered,
        );
        defer self.allocator.free(normalized_rendered);
        const prefixed_rendered = if (self.active_class_prefix) |prefix|
            if (prefix.len > 0)
                try self.prefixClassSelectorsOwned(
                    selector_node.text.?,
                    normalized_rendered,
                    prefix,
                )
            else
                null
        else
            null;
        defer if (prefixed_rendered) |owned| self.allocator.free(owned);
        const scoped_rendered = prefixed_rendered orelse normalized_rendered;
        const base_selector = try self.combineSelectors(
            parent_selector,
            scoped_rendered,
            selector_node.text.?,
        );
        defer self.allocator.free(base_selector);
        try self.registerSelectorIdentities(selector_node.text.?, base_selector);
        const selector = try self.expandExtendedSelectorOwned(
            selector_node.text.?,
            base_selector,
            rule_id,
        );
        defer self.allocator.free(selector);
        if (std.mem.trim(u8, selector, " \t\r\n\x0c").len == 0) return;
        const visible_selector = try self.visibleSelectorOwned(selector_node.text.?, selector);
        defer self.allocator.free(visible_selector);
        const selector_orders = try self.selectorOrdersOwned(parent_selector, selector);
        defer self.allocator.free(selector_orders);
        const previous_rule_selector = self.active_rule_selector;
        const previous_selector_identity = self.active_selector_identity;
        const previous_rule_orders = self.active_rule_orders;
        const previous_rule_group_order = self.active_rule_group_order;
        self.active_rule_selector = visible_selector;
        self.active_selector_identity = base_selector;
        self.active_rule_orders = selector_orders;
        self.active_rule_group_order = self.static_group_orders.get(rule_id.value);
        defer {
            self.active_rule_selector = previous_rule_selector;
            self.active_selector_identity = previous_selector_identity;
            self.active_rule_orders = previous_rule_orders;
            self.active_rule_group_order = previous_rule_group_order;
        }
        const selector_part = try self.selectorPartOwned(
            selector_node.text.?,
            scoped_rendered,
            parent_selector != null,
        );
        self.selector_parts.append(self.allocator, selector_part) catch |failure| {
            self.allocator.free(selector_part);
            return failure;
        };
        defer {
            self.allocator.free(self.selector_parts.pop().?);
        }

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
        defer {
            for (nested.items) |*child| child.deinit(self.allocator);
            nested.deinit(self.allocator);
        }
        var at_rules: std.ArrayList(NestedRule) = .empty;
        defer {
            for (at_rules.items) |*child| child.deinit(self.allocator);
            at_rules.deinit(self.allocator);
        }
        var cached: std.ArrayList(CachedRule) = .empty;
        defer {
            for (cached.items) |*item| item.deinit(self.allocator);
            cached.deinit(self.allocator);
        }

        const returned = try self.executeStatements(
            try self.document.children(children[1]),
            &scope,
            .{
                .declarations = &declarations,
                .nested = &nested,
                .at_rules = &at_rules,
                .cached = &cached,
            },
            false,
        );
        if (returned != null) return error.InvalidDocument;

        if (declarations.items.len > 0 and visible_selector.len > 0) {
            try self.emitMapped(selector_node.text.?, null, visible_selector);
            try self.emit(if (self.emittingOKeyframes()) " {\n    " else "{");
            for (declarations.items, 0..) |declaration, declaration_index| {
                try self.emitMapped(declaration.span, null, declaration.property);
                try self.emit(if (self.emittingOKeyframes()) ": " else ":");
                try self.emitMapped(declaration.span, null, declaration.value);
                try self.emit(";");
                if (self.emittingOKeyframes() and declaration_index + 1 < declarations.items.len) {
                    try self.emit("\n    ");
                }
            }
            try self.emit(if (self.emittingOKeyframes()) "\n  } " else "}");
        }
        for (nested.items) |child| {
            try self.emitNestedOutput(child, selector, false);
        }
        for (at_rules.items) |child| {
            try self.emitNestedOutput(child, selector, true);
        }
        for (cached.items) |*item| try self.emitCachedRule(item);
    }

    fn visibleSelectorOwned(
        self: *Engine,
        span: native_source.Span,
        selector: []const u8,
    ) Error![]u8 {
        var branches = try splitTopLevel(self.allocator, selector, ',');
        defer branches.deinit(self.allocator);
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        for (branches.items) |range| {
            const branch = std.mem.trim(
                u8,
                selector[range.start..range.end],
                " \t\r\n\x0c",
            );
            if (branch.len == 0) return error.InvalidDocument;
            if (selectorBranchContainsPlaceholder(branch)) continue;
            if (output.items.len > 0) try self.appendTemporary(&output, span, ",");
            try self.appendTemporary(&output, span, branch);
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn emitCachedRule(self: *Engine, cached: *const CachedRule) Error!void {
        const discovered_entry = self.cacheEntry(cached.entry_index) orelse return error.InvalidDocument;
        const entry = if (self.mode == .discover_cache)
            if (self.cache_seed.find(discovered_entry.key)) |seed_index|
                &self.cache_seed.entries.items[seed_index]
            else
                discovered_entry
        else
            discovered_entry;
        const selector = try self.cacheSelectorOwned(cached.span, entry);
        defer self.allocator.free(selector);
        const orders = try self.allocator.alloc(u64, entry.selectors.items.len);
        defer self.allocator.free(orders);
        for (entry.selectors.items, 0..) |cached_selector, index| {
            orders[index] = cached_selector.order;
        }
        const previous_rule_selector = self.active_rule_selector;
        const previous_rule_orders = self.active_rule_orders;
        self.active_rule_selector = selector;
        self.active_rule_orders = orders;
        if (self.cache_context_depth == std.math.maxInt(u16)) return error.CallDepthExceeded;
        self.cache_context_depth += 1;
        defer {
            self.cache_context_depth -= 1;
            self.active_rule_selector = previous_rule_selector;
            self.active_rule_orders = previous_rule_orders;
        }
        if (cached.declarations.items.len > 0) {
            try self.emitMapped(cached.span, null, selector);
            try self.emit("{");
            for (cached.declarations.items) |declaration| {
                try self.emitMapped(declaration.span, null, declaration.property);
                try self.emit(":");
                try self.emitMapped(declaration.span, null, declaration.value);
                try self.emit(";");
            }
            try self.emit("}");
        }
        for (cached.nested.items) |child| {
            try self.emitNestedOutput(child, selector, false);
        }
        for (cached.at_rules.items) |child| {
            try self.emitNestedOutput(child, selector, true);
        }
    }

    fn cacheEntry(self: *const Engine, index: usize) ?*const CacheEntry {
        const plan: *const CachePlan = if (self.mode == .discover_cache and self.cache_discovered != null)
            self.cache_discovered.?
        else
            self.cache_seed;
        if (index >= plan.entries.items.len) return null;
        return &plan.entries.items[index];
    }

    fn cacheSelectorOwned(
        self: *Engine,
        span: native_source.Span,
        entry: *const CacheEntry,
    ) Error![]u8 {
        if (entry.selectors.items.len == 0) return error.InvalidDocument;
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        for (entry.selectors.items, 0..) |selector, index| {
            if (index > 0) try self.appendTemporary(&output, span, ",");
            try self.appendTemporary(&output, span, selector.bytes);
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn selectorOrdersOwned(
        self: *Engine,
        parent_selector: ?[]const u8,
        selector: []const u8,
    ) Error![]u64 {
        var selector_ranges = try splitTopLevel(self.allocator, selector, ',');
        defer selector_ranges.deinit(self.allocator);
        if (selector_ranges.items.len == 0) return error.InvalidDocument;
        const orders = try self.allocator.alloc(u64, selector_ranges.items.len);
        errdefer self.allocator.free(orders);
        if (parent_selector != null and self.active_rule_orders != null) {
            var parent_ranges = try splitTopLevel(self.allocator, parent_selector.?, ',');
            defer parent_ranges.deinit(self.allocator);
            const parent_orders = self.active_rule_orders.?;
            if (parent_ranges.items.len == parent_orders.len and
                selector_ranges.items.len % parent_orders.len == 0)
            {
                for (orders, 0..) |*order, index| {
                    order.* = parent_orders[index % parent_orders.len];
                }
                return orders;
            }
        }
        for (orders) |*order| {
            order.* = self.selector_order;
            self.selector_order = std.math.add(u64, self.selector_order, 1) catch
                return error.SelectorLimitExceeded;
        }
        return orders;
    }

    fn emitAtRule(
        self: *Engine,
        at_rule_id: native_syntax.NodeId,
        parent_scope: native_environment.ScopeId,
        parent_selector: ?[]const u8,
    ) Error!void {
        const at_rule = try self.document.get(at_rule_id);
        if (at_rule.kind != .at_rule or at_rule.text == null) return error.InvalidDocument;
        const children = try self.document.children(at_rule_id);
        const header_owned = try self.renderTextOwned(at_rule.text.?, parent_scope, .interpolation, 0);
        defer self.allocator.free(header_owned);
        const normalized_header = try self.normalizeUrlQuotesOwned(at_rule.text.?, header_owned);
        defer self.allocator.free(normalized_header);
        const header = std.mem.trimRight(u8, normalized_header, " \t\r\n\x0c;");
        const keyframes = "@keyframes";
        const is_official_keyframes = startsWordAscii(header, keyframes);
        if (is_official_keyframes and self.active_keyframe_header == null) {
            const vendors = try self.evaluateValue(
                at_rule.text.?,
                "vendors",
                parent_scope,
                0,
            );
            try self.emitKeyframeVariants(
                at_rule_id,
                parent_scope,
                parent_selector,
                vendors,
            );
            return;
        }
        const prefixed_header = if (is_official_keyframes and
            !std.mem.eql(u8, self.active_keyframe_header.?, keyframes))
            try std.fmt.allocPrint(
                self.allocator,
                "{s}{s}",
                .{ self.active_keyframe_header.?, header[keyframes.len..] },
            )
        else
            null;
        defer if (prefixed_header) |owned| self.allocator.free(owned);
        const emitted_header = prefixed_header orelse header;

        var block_id: ?native_syntax.NodeId = null;
        if (children.len > 0 and (try self.document.get(children[children.len - 1])).kind == .block) {
            block_id = children[children.len - 1];
        }
        const is_media = emitted_header.len > "@media".len and
            std.ascii.eqlIgnoreCase(emitted_header[0.."@media".len], "@media");
        const spaced_media_header = if (is_media)
            try self.spaceMediaFeaturesOwned(at_rule.text.?, emitted_header)
        else
            null;
        defer if (spaced_media_header) |owned| self.allocator.free(owned);
        const final_header = spaced_media_header orelse emitted_header;
        const media_checkpoint = if (is_media and self.mode == .emit)
            try self.transaction.stagingCheckpoint()
        else
            null;
        errdefer if (media_checkpoint) |checkpoint_value| {
            self.transaction.restoreStaging(checkpoint_value) catch {};
        };
        try self.emitMapped(at_rule.text.?, null, final_header);
        if (block_id == null) {
            try self.emit(";");
            return;
        }

        var scope = self.environment.push(parent_scope) catch |failure| {
            try self.reportResource(at_rule.span, "native Stylus lexical scope limit exceeded");
            return failure;
        };
        if (is_media) {
            const current_media = try self.formatCurrentMediaOwned(at_rule.text.?, final_header);
            self.media_stack.append(self.allocator, current_media) catch |failure| {
                self.allocator.free(current_media);
                return failure;
            };
        }
        defer if (is_media) self.allocator.free(self.media_stack.pop().?);
        var declarations: std.ArrayList(RenderedDeclaration) = .empty;
        defer {
            for (declarations.items) |*declaration| declaration.deinit(self.allocator);
            declarations.deinit(self.allocator);
        }
        var nested: std.ArrayList(NestedRule) = .empty;
        defer {
            for (nested.items) |*child| child.deinit(self.allocator);
            nested.deinit(self.allocator);
        }
        var at_rules: std.ArrayList(NestedRule) = .empty;
        defer {
            for (at_rules.items) |*child| child.deinit(self.allocator);
            at_rules.deinit(self.allocator);
        }
        var cached: std.ArrayList(CachedRule) = .empty;
        defer {
            for (cached.items) |*item| item.deinit(self.allocator);
            cached.deinit(self.allocator);
        }
        const returned = try self.executeStatements(
            try self.document.children(block_id.?),
            &scope,
            .{
                .declarations = &declarations,
                .nested = &nested,
                .at_rules = &at_rules,
                .cached = &cached,
            },
            false,
        );
        if (returned != null) return error.InvalidDocument;

        try self.emit(if (self.emittingOKeyframes()) " { " else "{");
        const content_start = if (media_checkpoint != null)
            self.transaction.position()
        else
            null;
        if (declarations.items.len > 0) {
            if (parent_selector) |selector| {
                try self.emit(selector);
                try self.emit("{");
            }
            for (declarations.items) |declaration| {
                try self.emitMapped(declaration.span, null, declaration.property);
                try self.emit(":");
                try self.emitMapped(declaration.span, null, declaration.value);
                try self.emit(";");
            }
            if (parent_selector != null) try self.emit("}");
        }
        for (nested.items) |child| {
            try self.emitNestedOutput(child, parent_selector, false);
        }
        for (at_rules.items) |child| {
            try self.emitNestedOutput(child, parent_selector, true);
        }
        for (cached.items) |*item| try self.emitCachedRule(item);
        if (media_checkpoint) |checkpoint_value| {
            if (std.meta.eql(content_start.?, self.transaction.position())) {
                try self.transaction.restoreStaging(checkpoint_value);
                return;
            }
        }
        try self.emit("}");
    }

    fn emitKeyframeVariants(
        self: *Engine,
        at_rule_id: native_syntax.NodeId,
        parent_scope: native_environment.ScopeId,
        parent_selector: ?[]const u8,
        vendors: *const native_value.Value,
    ) Error!void {
        switch (vendors.*) {
            .list => |list| for (list.items) |*vendor| {
                try self.emitKeyframeVariants(
                    at_rule_id,
                    parent_scope,
                    parent_selector,
                    vendor,
                );
            },
            .string, .selector => |vendor| {
                if (std.mem.eql(u8, vendor.bytes, "ms")) return;
                if (vendor.bytes.len == 0 or vendor.bytes[0] == '$' or
                    !validVariableName(vendor.bytes))
                {
                    const at_rule = try self.document.get(at_rule_id);
                    try self.reportInvalidArguments(at_rule.text orelse at_rule.span);
                    return error.InvalidArguments;
                }
                const header = if (std.mem.eql(u8, vendor.bytes, "official"))
                    "@keyframes"
                else
                    try std.fmt.allocPrint(
                        self.allocator,
                        "@-{s}-keyframes",
                        .{vendor.bytes},
                    );
                defer if (!std.mem.eql(u8, vendor.bytes, "official")) {
                    self.allocator.free(header);
                };
                const previous_header = self.active_keyframe_header;
                self.active_keyframe_header = header;
                defer self.active_keyframe_header = previous_header;
                try self.emitAtRule(at_rule_id, parent_scope, parent_selector);
            },
            else => {
                const at_rule = try self.document.get(at_rule_id);
                try self.reportInvalidArguments(at_rule.text orelse at_rule.span);
                return error.InvalidArguments;
            },
        }
    }

    fn emittingOKeyframes(self: *const Engine) bool {
        return if (self.active_keyframe_header) |header|
            std.mem.eql(u8, header, "@-o-keyframes")
        else
            false;
    }

    fn executeStatements(
        self: *Engine,
        statements: []const native_syntax.NodeId,
        scope: *native_environment.ScopeId,
        output: ?RuleOutput,
        allow_return: bool,
    ) Error!?StatementResult {
        const previous_output = self.active_output;
        if (output) |destination| self.active_output = destination;
        defer self.active_output = previous_output;

        var previous_condition: ?bool = null;
        var implicit_result: ?*const native_value.Value = null;
        var pending_define_closing = false;
        for (statements) |statement_id| {
            const statement = try self.document.get(statement_id);
            if (pending_define_closing) {
                const text = statement.text orelse return error.InvalidDocument;
                const raw = std.mem.trim(
                    u8,
                    try self.sources.slice(text),
                    " \t\r\n\x0c;",
                );
                if (statement.kind != .expression or !std.mem.eql(u8, raw, ")")) {
                    return error.InvalidDocument;
                }
                pending_define_closing = false;
                previous_condition = null;
                continue;
            }
            if (statement.kind == .function and statement.text != null and
                try self.executeDefineObjectStatement(
                    statement_id,
                    statement.text.?,
                    scope,
                ))
            {
                pending_define_closing = true;
                previous_condition = null;
                if (allow_return) {
                    implicit_result = try self.ownValue(
                        statement.text.?,
                        .{ .null_value = {} },
                    );
                }
                continue;
            }
            if (statement.kind == .expression and statement.text != null) {
                const statement_raw = try self.sources.slice(statement.text.?);
                if (try self.executeDefineStatement(
                    statement.text.?,
                    statement_raw,
                    scope,
                )) {
                    previous_condition = null;
                    if (allow_return) {
                        implicit_result = try self.ownValue(
                            statement.text.?,
                            .{ .null_value = {} },
                        );
                    }
                    continue;
                }
                if (try self.executeJsonStatement(
                    statement.text.?,
                    statement_raw,
                    scope,
                )) {
                    previous_condition = null;
                    if (allow_return) {
                        implicit_result = try self.ownValue(
                            statement.text.?,
                            .{ .null_value = {} },
                        );
                    }
                    continue;
                }
            }
            if (statement.kind == .expression and statement.text != null and
                try self.executeBlockInsertion(
                    statement.text.?,
                    scope.*,
                    output,
                    allow_return,
                ))
            {
                previous_condition = null;
                continue;
            }
            if ((statement.kind == .variable or statement.kind == .return_statement) and
                statement.text != null)
            {
                const statement_raw = try self.sources.slice(statement.text.?);
                if (parsePostfixLoop(statement_raw) != null) {
                    if (try self.executePostfixLoop(statement.text.?, statement_raw, scope)) |returned| {
                        if (returned.explicit) return returned;
                        if (allow_return) implicit_result = returned.value;
                    }
                    previous_condition = null;
                    continue;
                }
            }
            if ((statement.kind == .expression or statement.kind == .declaration) and
                statement.text != null and output != null)
            {
                const statement_raw = try self.sources.slice(statement.text.?);
                if (parsePostfixLoop(statement_raw)) |postfix| {
                    const expression = std.mem.trim(u8, postfix.expression, " \t\r\n\x0c;");
                    const call = parseCall(expression) orelse parseBareCall(expression);
                    if (call == null or self.findCallable(expression[call.?.name.start..call.?.name.end]) == null) {
                        // Ordinary declaration postfix loops are handled by their declaration path.
                    } else {
                        try self.executePostfixMixin(statement.text.?, statement_raw, scope, output.?);
                        previous_condition = null;
                        continue;
                    }
                }
            }
            switch (statement.kind) {
                .variable => {
                    previous_condition = null;
                    try self.assign(statement_id, scope);
                    if (allow_return and output == null) {
                        const text = statement.text orelse return error.InvalidDocument;
                        const raw = try self.sources.slice(text);
                        const name = if (parseAssignment(raw)) |assignment|
                            assignment.name
                        else if (parseMemberAssignment(raw)) |assignment|
                            assignment.base
                        else
                            return error.InvalidDocument;
                        implicit_result = (try self.lookupBinding(scope.*, name)) orelse
                            return error.InvalidDocument;
                    }
                },
                .function, .mixin => {
                    previous_condition = null;
                    try self.registerCallable(statement_id, scope.*);
                },
                .declaration => {
                    previous_condition = null;
                    const destination = output orelse {
                        if (!allow_return) return error.InvalidDocument;
                        const text = statement.text orelse return error.InvalidDocument;
                        const raw = std.mem.trim(
                            u8,
                            try self.sources.slice(text),
                            " \t\r\n\x0c;",
                        );
                        implicit_result = try self.evaluateImplicitStatement(
                            text,
                            raw,
                            scope.*,
                        );
                        continue;
                    };
                    const text = statement.text orelse return error.InvalidDocument;
                    const raw = std.mem.trim(u8, try self.sources.slice(text), " \t\r\n\x0c;");
                    if (parsePostfixLoop(raw) != null) {
                        try self.executePostfixDeclaration(
                            statement_id,
                            scope,
                            destination,
                        );
                        continue;
                    }
                    if (parseDeclarationCall(raw)) |call| {
                        const name = raw[call.name.start..call.name.end];
                        if (self.findCallable(name) != null and !self.isActiveCallable(name)) {
                            const previous_property = self.active_property;
                            const previous_property_value = self.active_property_value;
                            const previous_property_call_span = self.active_property_call_span;
                            const property_binding_start = self.current_property_bindings.items.len;
                            self.active_property = .{
                                .property = name,
                                .value_span = try self.relativeSpan(text, call.arguments),
                                .scope = scope.*,
                            };
                            self.active_property_value = null;
                            self.active_property_call_span = null;
                            defer {
                                self.active_property = previous_property;
                                self.active_property_value = previous_property_value;
                                self.active_property_call_span = previous_property_call_span;
                                self.current_property_bindings.shrinkRetainingCapacity(
                                    property_binding_start,
                                );
                            }
                            const returned = try self.invokeUserCallable(
                                text,
                                raw,
                                call,
                                scope.*,
                                destination,
                                false,
                            );
                            if (returned != null) return error.InvalidDocument;
                            continue;
                        }
                    }
                    var declaration = (try self.renderDeclaration(statement_id, scope.*)) orelse continue;
                    errdefer declaration.deinit(self.allocator);
                    const reference_name = try std.fmt.allocPrint(self.allocator, "@{s}", .{declaration.property});
                    defer self.allocator.free(reference_name);
                    scope.* = try self.setBinding(scope.*, reference_name, declaration.semantic_value, declaration.span);
                    try destination.declarations.append(self.allocator, declaration);
                },
                .rule => {
                    previous_condition = null;
                    if (try self.invokeBlockMixinRule(statement_id, scope.*, output)) {
                        continue;
                    }
                    if (output == null and allow_return) {
                        const children = try self.document.children(statement_id);
                        if (children.len == 1) {
                            const selector = try self.document.get(children[0]);
                            if (selector.kind == .selector and selector.text != null) {
                                const raw = std.mem.trim(
                                    u8,
                                    try self.sources.slice(selector.text.?),
                                    " \t\r\n\x0c;",
                                );
                                implicit_result = try self.evaluateValue(
                                    selector.text.?,
                                    raw,
                                    scope.*,
                                    0,
                                );
                                continue;
                            }
                        }
                    }
                    const destination = output orelse {
                        try self.emitRule(statement_id, scope.*, self.active_selector_scope);
                        continue;
                    };
                    try self.replayNestedSelectorMemberAssignments(
                        statement_id,
                        scope.*,
                        self.active_selector_identity,
                    );
                    const active_callables = try self.allocator.dupe(
                        []const u8,
                        self.active_callables.items,
                    );
                    destination.nested.append(self.allocator, .{
                        .id = statement_id,
                        .scope = scope.*,
                        .class_prefix = self.active_class_prefix,
                        .active_callables = active_callables,
                    }) catch |failure| {
                        self.allocator.free(active_callables);
                        return failure;
                    };
                },
                .at_rule => {
                    previous_condition = null;
                    const text = statement.text orelse return error.InvalidDocument;
                    const raw = std.mem.trim(u8, try self.sources.slice(text), " \t\r\n\x0c;");
                    if (output != null) {
                        if (parseExtendDirective(raw)) |directive| {
                            if (try self.discoverDynamicExtension(
                                statement_id,
                                text,
                                directive,
                                scope.*,
                            )) continue;
                            if (!directive.plural or
                                self.static_extension_directives.contains(statement_id.value))
                            {
                                continue;
                            }
                        }
                    }
                    if (output == null and startsWordAscii(raw, "@scope")) {
                        const selector_raw = std.mem.trim(u8, raw["@scope".len..], " \t\r\n\x0c;");
                        const scope_children = try self.document.children(statement_id);
                        const owns_block = scope_children.len > 0 and
                            (try self.document.get(scope_children[scope_children.len - 1])).kind == .block;
                        if (selector_raw.len == 0 or owns_block) {
                            try self.reportInvalidArguments(text);
                            return error.InvalidArguments;
                        }
                        const rendered = try self.renderRawOwned(text, selector_raw, scope.*, .selector, 0);
                        if (self.active_selector_scope) |prior| self.allocator.free(prior);
                        self.active_selector_scope = rendered;
                        continue;
                    }
                    const destination = output orelse {
                        try self.emitAtRule(statement_id, scope.*, self.active_selector_scope);
                        continue;
                    };
                    const active_callables = try self.allocator.dupe(
                        []const u8,
                        self.active_callables.items,
                    );
                    destination.at_rules.append(self.allocator, .{
                        .id = statement_id,
                        .scope = scope.*,
                        .class_prefix = self.active_class_prefix,
                        .active_callables = active_callables,
                    }) catch |failure| {
                        self.allocator.free(active_callables);
                        return failure;
                    };
                },
                .expression => {
                    previous_condition = null;
                    if (output) |destination| {
                        try self.invokeMixinStatement(statement_id, scope, destination);
                    } else if (allow_return) {
                        const text = statement.text orelse return error.InvalidDocument;
                        const raw = std.mem.trim(
                            u8,
                            try self.sources.slice(text),
                            " \t\r\n\x0c;",
                        );
                        implicit_result = try self.evaluateImplicitStatement(
                            text,
                            raw,
                            scope.*,
                        );
                    } else {
                        const text = statement.text orelse return error.InvalidDocument;
                        const raw = std.mem.trim(
                            u8,
                            try self.sources.slice(text),
                            " \t\r\n\x0c;",
                        );
                        const call = parseCall(raw) orelse parseBareCall(raw);
                        if (call != null and
                            self.findCallable(raw[call.?.name.start..call.?.name.end]) != null)
                        {
                            const returned = try self.invokeUserCallable(
                                text,
                                raw,
                                call.?,
                                scope.*,
                                null,
                                false,
                            );
                            if (returned != null) return error.InvalidDocument;
                        } else {
                            _ = try self.evaluateValue(text, raw, scope.*, 0);
                        }
                    }
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
                        const prior_selected = previous_condition orelse {
                            try self.reportInvalidOperation(text);
                            return error.InvalidOperation;
                        };
                        const remainder = std.mem.trim(u8, raw["else".len..], " \t\r\n\x0c;");
                        if (remainder.len == 0) {
                            selected = !prior_selected;
                            previous_condition = null;
                        } else {
                            const condition = parseConditionHeader(remainder) orelse {
                                try self.reportInvalidOperation(text);
                                return error.InvalidOperation;
                            };
                            var condition_selected = try self.evaluateCondition(
                                text,
                                condition.expression,
                                scope.*,
                            );
                            if (condition.negated) condition_selected = !condition_selected;
                            selected = !prior_selected and condition_selected;
                            previous_condition = prior_selected or selected;
                        }
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
                    )) |returned| {
                        if (returned.explicit) return returned;
                        implicit_result = returned.value;
                    }
                    scope.* = child_scope;
                },
                .loop => {
                    previous_condition = null;
                    if (try self.executeLoop(statement_id, scope, output, allow_return)) |returned| {
                        if (returned.explicit) return returned;
                        implicit_result = returned.value;
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
                    const postfix = splitPostfixCondition(raw);
                    if (postfix.condition) |condition| {
                        var selected = try self.evaluateCondition(
                            text,
                            raw[condition.expression.start..condition.expression.end],
                            scope.*,
                        );
                        if (condition.negated) selected = !selected;
                        if (!selected) continue;
                    }
                    const return_raw = raw[postfix.declaration.start..postfix.declaration.end];
                    const expression = std.mem.trim(u8, return_raw["return".len..], " \t\r\n\x0c");
                    if (expression.len == 0) return .{
                        .value = try self.ownValue(text, .{ .null_value = {} }),
                        .explicit = true,
                    };
                    if (std.mem.eql(u8, expression, "@block")) return .{
                        .value = try self.ownBlockValue(
                            text,
                            try self.statementBlock(statement_id),
                            scope.*,
                            true,
                        ),
                        .explicit = true,
                    };
                    return .{
                        .value = try self.evaluateValue(text, expression, scope.*, 0),
                        .explicit = true,
                    };
                },
                .comment => previous_condition = null,
                else => return error.InvalidDocument,
            }
        }
        if (pending_define_closing) return error.InvalidDocument;
        if (allow_return) {
            if (implicit_result) |value| return .{ .value = value, .explicit = false };
        }
        return null;
    }

    fn evaluateImplicitStatement(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        scope: native_environment.ScopeId,
    ) Error!*const native_value.Value {
        const postfix = splitPostfixCondition(raw);
        if (postfix.condition) |condition| {
            var selected = try self.evaluateCondition(
                span,
                raw[condition.expression.start..condition.expression.end],
                scope,
            );
            if (condition.negated) selected = !selected;
            if (!selected) {
                return self.ownValue(span, .{ .null_value = {} });
            }
        }
        return self.evaluateValue(
            span,
            raw[postfix.declaration.start..postfix.declaration.end],
            scope,
            0,
        );
    }

    fn executeBlockInsertion(
        self: *Engine,
        span: native_source.Span,
        scope: native_environment.ScopeId,
        output: ?RuleOutput,
        allow_return: bool,
    ) Error!bool {
        const raw = std.mem.trim(u8, try self.sources.slice(span), " \t\r\n\x0c;");
        if (raw.len < 3 or raw[0] != '{' or matchingCurly(raw, 0) != raw.len - 1) {
            return false;
        }
        const inner = std.mem.trim(u8, raw[1 .. raw.len - 1], " \t\r\n\x0c");
        if (inner.len == 0) return false;
        const value = try self.evaluateValue(span, inner, scope, 0);
        const block_value = self.blockValue(value) orelse return false;
        const block = try self.document.get(block_value.block_id);
        if (block.kind != .block) return error.InvalidDocument;
        var block_scope = block_value.scope;
        const declaration_start = if (output) |destination|
            destination.declarations.items.len
        else
            0;
        const returned = try self.executeStatements(
            try self.document.children(block_value.block_id),
            &block_scope,
            output,
            allow_return,
        );
        if (returned != null) {
            try self.reportInvalidOperation(span);
            return error.InvalidOperation;
        }
        if (block_value.replay_side_effects) {
            if (output) |destination| {
                var duplicates: std.ArrayList(RenderedDeclaration) = .empty;
                defer {
                    for (duplicates.items) |*declaration| declaration.deinit(self.allocator);
                    duplicates.deinit(self.allocator);
                }
                for (destination.declarations.items[declaration_start..]) |declaration| {
                    if (!declaration.side_effect) continue;
                    var duplicate = try self.cloneRenderedDeclaration(declaration);
                    duplicates.append(self.allocator, duplicate) catch |failure| {
                        duplicate.deinit(self.allocator);
                        return failure;
                    };
                }
                if (duplicates.items.len > 0) {
                    try destination.declarations.insertSlice(
                        self.allocator,
                        declaration_start,
                        duplicates.items,
                    );
                    duplicates.clearRetainingCapacity();
                }
            }
        }
        return true;
    }

    fn cloneRenderedDeclaration(
        self: *Engine,
        declaration: RenderedDeclaration,
    ) Error!RenderedDeclaration {
        const property = try self.allocator.dupe(u8, declaration.property);
        errdefer self.allocator.free(property);
        const value = try self.allocator.dupe(u8, declaration.value);
        errdefer self.allocator.free(value);
        return .{
            .span = declaration.span,
            .property = property,
            .value = value,
            .semantic_value = declaration.semantic_value,
            .side_effect = declaration.side_effect,
        };
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
        const call = parseCall(raw) orelse parseBareCall(raw) orelse {
            try self.reportUndefinedCallable(text);
            return error.UndefinedCallable;
        };
        const name = raw[call.name.start..call.name.end];
        if (self.findCallable(name) == null) {
            if (call.parenthesized and isBuiltinCallableName(name)) {
                _ = try self.evaluateValue(text, raw, scope.*, 0);
                return;
            }
            try self.reportUndefinedCallable(text);
            return error.UndefinedCallable;
        }
        const returned = try self.invokeUserCallable(text, raw, call, scope.*, output, false);
        if (returned != null) return error.InvalidDocument;
    }

    fn invokeBlockMixinRule(
        self: *Engine,
        statement_id: native_syntax.NodeId,
        scope: native_environment.ScopeId,
        output: ?RuleOutput,
    ) Error!bool {
        const children = try self.document.children(statement_id);
        if (children.len != 2) return false;
        const selector = try self.document.get(children[0]);
        const block = try self.document.get(children[1]);
        if (selector.kind != .selector or selector.text == null or block.kind != .block) return false;
        const selector_raw = std.mem.trim(
            u8,
            try self.sources.slice(selector.text.?),
            " \t\r\n\x0c;",
        );
        if (selector_raw.len < 2 or selector_raw[0] != '+') return false;
        const raw = std.mem.trimLeft(u8, selector_raw[1..], " \t");
        const call = parseCall(raw) orelse parseBareCall(raw) orelse return false;
        const name = raw[call.name.start..call.name.end];
        if (nameEql(name, "prefix-classes")) {
            return self.invokePrefixClassesBlockRule(
                selector.text.?,
                children[1],
                raw,
                call,
                scope,
                output,
            );
        }
        if (nameEql(name, "cache")) {
            const destination = output orelse return false;
            return self.invokeCacheBlockRule(
                selector.text.?,
                children[1],
                raw,
                call,
                scope,
                destination,
            );
        }
        if (self.findCallable(name) == null) return false;

        const content = try self.ownBlockValue(selector.text.?, children[1], scope, false);
        const previous_content = self.pending_content_block;
        self.pending_content_block = content;
        defer self.pending_content_block = previous_content;
        const returned = try self.invokeUserCallable(
            selector.text.?,
            raw,
            call,
            scope,
            output,
            false,
        );
        if (returned != null) return error.InvalidDocument;
        return true;
    }

    fn invokePrefixClassesBlockRule(
        self: *Engine,
        span: native_source.Span,
        block_id: native_syntax.NodeId,
        raw: []const u8,
        call: Call,
        scope: native_environment.ScopeId,
        output: ?RuleOutput,
    ) Error!bool {
        var arguments = try self.evaluateCallArguments(span, raw, call, scope);
        defer arguments.deinit(self.allocator);
        if (arguments.items.len != 1 or arguments.items[0].* != .string or
            !validClassPrefix(arguments.items[0].string.bytes))
        {
            try self.reportInvalidArguments(span);
            return error.InvalidArguments;
        }

        const previous_prefix = self.active_class_prefix;
        self.active_class_prefix = arguments.items[0].string.bytes;
        defer self.active_class_prefix = previous_prefix;
        var content_scope = scope;
        const returned = try self.executeStatements(
            try self.document.children(block_id),
            &content_scope,
            output,
            false,
        );
        if (returned != null) return error.InvalidDocument;
        return true;
    }

    fn invokeCacheBlockRule(
        self: *Engine,
        span: native_source.Span,
        block_id: native_syntax.NodeId,
        raw: []const u8,
        call: Call,
        scope: native_environment.ScopeId,
        output: RuleOutput,
    ) Error!bool {
        const selector = self.active_rule_selector orelse {
            try self.reportInvalidOperation(span);
            return error.InvalidOperation;
        };
        if (self.active_callables.items.len == 0) {
            try self.reportInvalidOperation(span);
            return error.InvalidOperation;
        }
        const caller = self.active_callables.items[self.active_callables.items.len - 1];
        var arguments = try self.evaluateCallArguments(span, raw, call, scope);
        defer arguments.deinit(self.allocator);
        const key = try self.cacheKeyOwned(span, caller, arguments.items);
        defer self.allocator.free(key);

        const selector_orders = self.active_rule_orders orelse return error.InvalidDocument;
        for (self.cache_seen.items) |seen| {
            if (!std.mem.eql(u8, seen, key)) continue;
            if (self.mode == .discover_cache) {
                _ = try self.cache_discovered.?.record(
                    self.allocator,
                    key,
                    selector,
                    selector_orders,
                );
            } else if (self.cache_seed.find(key) == null) {
                return error.InvalidDocument;
            }
            return true;
        }

        if (self.cache_context_depth > 0) {
            var inline_scope = scope;
            const returned = try self.executeStatements(
                try self.document.children(block_id),
                &inline_scope,
                output,
                false,
            );
            if (returned != null) return error.InvalidDocument;
            return true;
        }

        const entry_index = if (self.mode == .discover_cache)
            try self.cache_discovered.?.record(
                self.allocator,
                key,
                selector,
                selector_orders,
            )
        else
            self.cache_seed.find(key) orelse return error.InvalidDocument;
        const entry = self.cacheEntry(entry_index) orelse return error.InvalidDocument;
        try self.cache_seen.append(self.allocator, entry.key);

        var cached: CachedRule = .{ .span = span, .entry_index = entry_index };
        var appended = false;
        defer if (!appended) cached.deinit(self.allocator);
        var cache_scope = scope;
        if (self.cache_context_depth == std.math.maxInt(u16)) return error.CallDepthExceeded;
        self.cache_context_depth += 1;
        defer self.cache_context_depth -= 1;
        const returned = try self.executeStatements(
            try self.document.children(block_id),
            &cache_scope,
            .{
                .declarations = &cached.declarations,
                .nested = &cached.nested,
                .at_rules = &cached.at_rules,
                .cached = output.cached,
            },
            false,
        );
        if (returned != null) return error.InvalidDocument;
        try output.cached.append(self.allocator, cached);
        appended = true;
        return true;
    }

    fn cacheKeyOwned(
        self: *Engine,
        span: native_source.Span,
        caller: []const u8,
        arguments: []const *const native_value.Value,
    ) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        const media = if (self.media_stack.items.len > 0)
            self.media_stack.items[self.media_stack.items.len - 1]
        else
            "no-media";
        try self.appendTemporary(&output, span, media);
        try self.appendTemporary(&output, span, "__");
        try self.appendTemporary(&output, span, caller);
        try self.appendTemporary(&output, span, "__");
        for (arguments, 0..) |argument, index| {
            if (index > 0) try self.appendTemporary(&output, span, " ");
            const serialized = try self.serializeValueOwned(argument, .value, span);
            defer self.allocator.free(serialized);
            try self.appendTemporary(&output, span, serialized);
        }
        return output.toOwnedSlice(self.allocator);
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
        var callable = self.findCallable(name);
        if (callable == null) {
            if (try self.lookupBinding(caller_scope, name)) |alias| {
                if (alias.* == .string) callable = self.findCallable(alias.string.bytes);
            }
        }
        const resolved_callable = callable orelse {
            try self.reportUndefinedCallable(span);
            return error.UndefinedCallable;
        };
        const previous_property_call_span = self.active_property_call_span;
        if (self.active_property_call_span == null) {
            if (self.active_property) |property| {
                const property_source = try self.sources.slice(property.value_span);
                if (std.mem.indexOf(u8, property_source, std.mem.trim(u8, raw, " \t\r\n\x0c;"))) |relative| {
                    const call_start = std.math.add(u32, property.value_span.start, @intCast(relative)) catch
                        return error.InvalidDocument;
                    const call_end = std.math.add(
                        u32,
                        call_start,
                        @intCast(std.mem.trim(u8, raw, " \t\r\n\x0c;").len),
                    ) catch return error.InvalidDocument;
                    self.active_property_call_span = try self.sources.span(
                        property.value_span.source,
                        call_start,
                        call_end,
                    );
                } else if (span.source.value == property.value_span.source.value and
                    span.start >= property.value_span.start and span.end <= property.value_span.end)
                {
                    self.active_property_call_span = span;
                }
            }
        }
        defer self.active_property_call_span = previous_property_call_span;
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
        self.active_callables.append(self.allocator, resolved_callable.name) catch |failure| {
            self.call_depth -= 1;
            return failure;
        };
        self.transaction.enterCall() catch |failure| {
            _ = self.active_callables.pop();
            self.call_depth -= 1;
            return failure;
        };
        defer {
            _ = self.active_callables.pop();
            self.call_depth -= 1;
            self.transaction.leaveCall() catch {};
        }

        const definition_node = try self.document.get(resolved_callable.node_id);
        const definition_span = definition_node.text orelse return error.InvalidDocument;
        const source_definition_raw = try self.sources.slice(definition_span);
        const normalized_definition = try self.normalizeEolEscapesOwned(
            definition_span,
            source_definition_raw,
        );
        defer if (normalized_definition) |owned| self.allocator.free(owned);
        const definition_raw = normalized_definition orelse source_definition_raw;
        const definition = parseDefinition(definition_raw) orelse return error.InvalidDocument;
        var parameters = try splitTopLevel(
            self.allocator,
            definition_raw[definition.parameters.start..definition.parameters.end],
            ',',
        );
        defer parameters.deinit(self.allocator);
        var arguments = if (call.property_syntax and parameters.items.len > 1)
            try splitTopLevelWhitespace(
                self.allocator,
                raw[call.arguments.start..call.arguments.end],
            )
        else if (call.parenthesized)
            try splitTopLevel(
                self.allocator,
                raw[call.arguments.start..call.arguments.end],
                ',',
            )
        else
            try splitTopLevelWhitespace(
                self.allocator,
                raw[call.arguments.start..call.arguments.end],
            );
        defer arguments.deinit(self.allocator);
        if (definition.parameters.start == definition.parameters.end) parameters.clearRetainingCapacity();
        if (call.arguments.start == call.arguments.end) arguments.clearRetainingCapacity();

        var call_scope = self.environment.push(resolved_callable.scope) catch |failure| {
            try self.reportResource(span, "native Stylus lexical scope limit exceeded");
            return failure;
        };
        const content_block = self.pending_content_block;
        self.pending_content_block = null;
        defer self.pending_content_block = content_block;
        if (content_block) |content| {
            call_scope = try self.setBinding(call_scope, "block", content, span);
        }
        const alias_start = self.mutation_aliases.items.len;
        defer self.mutation_aliases.shrinkRetainingCapacity(alias_start);
        const current_property_binding_start = self.current_property_bindings.items.len;
        defer self.current_property_bindings.shrinkRetainingCapacity(
            current_property_binding_start,
        );

        var argument_values: std.ArrayList(*const native_value.Value) = .empty;
        defer argument_values.deinit(self.allocator);
        var argument_names: std.ArrayList(?[]const u8) = .empty;
        defer argument_names.deinit(self.allocator);
        var argument_used: std.ArrayList(bool) = .empty;
        defer argument_used.deinit(self.allocator);
        try argument_values.ensureTotalCapacity(self.allocator, arguments.items.len);
        try argument_names.ensureTotalCapacity(self.allocator, arguments.items.len);
        try argument_used.ensureTotalCapacity(self.allocator, arguments.items.len);
        for (arguments.items) |argument_range| {
            const argument_text = std.mem.trim(
                u8,
                raw[call.arguments.start + argument_range.start .. call.arguments.start + argument_range.end],
                " \t\r\n\x0c",
            );
            if (argument_text.len == 0) {
                try self.reportInvalidArguments(span);
                return error.InvalidArguments;
            }
            const named = splitNamedArgument(argument_text);
            const value_raw = if (named) |item| item.value else argument_text;
            const argument = try self.evaluateValue(span, value_raw, caller_scope, 0);
            argument_values.appendAssumeCapacity(argument);
            argument_names.appendAssumeCapacity(if (named) |item| item.name else null);
            argument_used.appendAssumeCapacity(false);
        }

        var positional_cursor: usize = 0;
        for (parameters.items, 0..) |parameter_range, parameter_index| {
            _ = parameter_index;
            const parameter_text = std.mem.trim(
                u8,
                definition_raw[definition.parameters.start + parameter_range.start .. definition.parameters.start + parameter_range.end],
                " \t\r\n\x0c",
            );
            const parameter = parseParameter(parameter_text) orelse {
                try self.reportInvalidArguments(definition_span);
                return error.InvalidArguments;
            };
            if (parameter.rest) {
                var rest_values: std.ArrayList(native_value.Value) = .empty;
                defer rest_values.deinit(self.allocator);
                while (positional_cursor < argument_values.items.len) : (positional_cursor += 1) {
                    if (argument_names.items[positional_cursor] != null) continue;
                    try rest_values.append(self.allocator, argument_values.items[positional_cursor].*);
                    argument_used.items[positional_cursor] = true;
                }
                const rest = try self.ownValue(span, .{ .list = .{
                    .items = rest_values.items,
                    .separator = .space,
                } });
                call_scope = try self.setBinding(call_scope, parameter.name, rest, span);
                continue;
            }

            var selected: ?usize = null;
            for (argument_names.items, 0..) |argument_name, index| {
                if (!argument_used.items[index] and argument_name != null and
                    std.mem.eql(u8, argument_name.?, parameter.name))
                {
                    selected = index;
                    break;
                }
            }
            if (selected == null) {
                while (positional_cursor < argument_values.items.len and
                    (argument_used.items[positional_cursor] or argument_names.items[positional_cursor] != null))
                {
                    positional_cursor += 1;
                }
                if (positional_cursor < argument_values.items.len) {
                    selected = positional_cursor;
                    positional_cursor += 1;
                }
            }
            const argument = if (selected) |index| blk: {
                argument_used.items[index] = true;
                const selected_text = std.mem.trim(
                    u8,
                    raw[call.arguments.start + arguments.items[index].start .. call.arguments.start + arguments.items[index].end],
                    " \t\r\n\x0c",
                );
                const caller_name = if (splitNamedArgument(selected_text)) |named|
                    named.value
                else
                    selected_text;
                if (validVariableName(caller_name)) {
                    try self.mutation_aliases.append(self.allocator, .{
                        .local_name = parameter.name,
                        .target = .{ .binding = .{
                            .scope = caller_scope,
                            .name = caller_name,
                        } },
                    });
                } else if (currentPropertyArgumentIndex(caller_name)) |property_index| {
                    try self.mutation_aliases.append(self.allocator, .{
                        .local_name = parameter.name,
                        .target = .{ .current_property_index = property_index },
                    });
                }
                break :blk argument_values.items[index];
            } else if (parameter.default_value) |default_value|
                try self.evaluateValue(definition_span, default_value, call_scope, 0)
            else {
                try self.reportInvalidArguments(span);
                return error.InvalidArguments;
            };
            call_scope = try self.setBinding(call_scope, parameter.name, argument, span);
        }
        var all_arguments: std.ArrayList(native_value.Value) = .empty;
        defer all_arguments.deinit(self.allocator);
        try all_arguments.ensureTotalCapacity(self.allocator, argument_values.items.len);
        for (argument_values.items) |argument| all_arguments.appendAssumeCapacity(argument.*);
        const arguments_value = try self.ownValue(span, .{ .list = .{
            .items = all_arguments.items,
            .separator = if (arguments.items.len > 1 and call.parenthesized)
                .comma
            else
                .space,
        } });
        call_scope = try self.setBinding(call_scope, "arguments", arguments_value, span);
        const current_property = (try self.currentPropertyValue(span, caller_scope)) orelse
            try self.ownValue(span, .{ .null_value = {} });
        call_scope = try self.setBinding(
            call_scope,
            "current-property",
            current_property,
            span,
        );
        if (self.active_property_value != null and
            current_property == self.active_property_value.?)
        {
            try self.current_property_bindings.append(self.allocator, .{
                .scope = call_scope,
                .name = "current-property",
            });
        }

        const block = try self.statementBlock(resolved_callable.node_id);
        const returned = try self.executeStatements(
            try self.document.children(block),
            &call_scope,
            output,
            true,
        );
        if (!require_return) return null;
        if (require_return and returned == null) {
            try self.reportInvalidOperation(span);
            return error.InvalidOperation;
        }
        return if (returned) |result| result.value else null;
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

    fn isActiveCallable(self: *const Engine, name: []const u8) bool {
        for (self.active_callables.items) |active| {
            if (std.mem.eql(u8, active, name)) return true;
        }
        return false;
    }

    fn executeLoop(
        self: *Engine,
        statement_id: native_syntax.NodeId,
        parent_scope: *native_environment.ScopeId,
        output: ?RuleOutput,
        allow_return: bool,
    ) Error!?StatementResult {
        const statement = try self.document.get(statement_id);
        const text = statement.text orelse return error.InvalidDocument;
        const raw = std.mem.trim(u8, try self.sources.slice(text), " \t\r\n\x0c;");
        const loop = parseLoop(raw) orelse {
            try self.reportInvalidOperation(text);
            return error.InvalidOperation;
        };
        const collection = try self.evaluateValue(text, loop.items, parent_scope.*, 0);
        const item_count: usize = switch (collection.*) {
            .list => |list| list.items.len,
            .map => |map| map.entries.len,
            else => 1,
        };
        const block = try self.statementBlock(statement_id);
        var implicit_result: ?StatementResult = null;
        self.active_loop_depth += 1;
        defer self.active_loop_depth -= 1;
        for (0..item_count) |index| {
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
            var loop_scope = self.environment.push(parent_scope.*) catch |failure| {
                try self.reportResource(text, "native Stylus lexical scope limit exceeded");
                return failure;
            };
            const item = switch (collection.*) {
                .list => |list| list.items[index],
                .map => |map| map.entries[index].key,
                else => collection.*,
            };
            const value = try self.ownValue(text, item);
            loop_scope = try self.setBinding(loop_scope, loop.name, value, text);
            if (loop.index_name) |index_name| {
                const index_value = switch (collection.*) {
                    .map => |map| try self.ownValue(text, map.entries[index].value),
                    else => try self.ownUnitlessNumber(text, @floatFromInt(index)),
                };
                loop_scope = try self.setBinding(loop_scope, index_name, index_value, text);
            }
            if (try self.executeStatements(
                try self.document.children(block),
                &loop_scope,
                output,
                allow_return,
            )) |returned| {
                if (returned.explicit) return returned;
                implicit_result = returned;
            }
            parent_scope.* = loop_scope;
        }
        return implicit_result;
    }

    fn executePostfixLoop(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        parent_scope: *native_environment.ScopeId,
    ) Error!?StatementResult {
        const postfix = parsePostfixLoop(raw) orelse return null;
        const collection = try self.evaluateValue(span, postfix.header.items, parent_scope.*, 0);
        const items = if (collection.* == .list)
            collection.list.items
        else
            @as([]const native_value.Value, &.{collection.*});
        var last: ?StatementResult = null;
        for (items, 0..) |item, item_index| {
            if (self.loop_iterations >= self.limits.max_loop_iterations) {
                try self.transaction.report(
                    .err,
                    .loop_limit,
                    span,
                    "native Stylus loop iteration limit exceeded",
                    &.{},
                );
                return error.LoopLimitExceeded;
            }
            self.loop_iterations += 1;
            try self.transaction.consumeLoopIterations(1);
            var loop_scope = try self.environment.push(parent_scope.*);
            loop_scope = try self.setBinding(
                loop_scope,
                postfix.header.name,
                try self.ownValue(span, item),
                span,
            );
            if (postfix.header.index_name) |index_name| {
                loop_scope = try self.setBinding(
                    loop_scope,
                    index_name,
                    try self.ownUnitlessNumber(span, @floatFromInt(item_index)),
                    span,
                );
            }
            if (!try self.postfixLoopSelected(span, postfix.conditions, loop_scope)) {
                parent_scope.* = loop_scope;
                continue;
            }

            const is_return = startsWordAscii(postfix.expression, "return");
            const candidate = if (is_return)
                std.mem.trim(u8, postfix.expression["return".len..], " \t\r\n\x0c;")
            else
                postfix.expression;
            const conditional = splitPostfixCondition(candidate);
            if (conditional.condition) |condition| {
                var selected = try self.evaluateCondition(
                    span,
                    candidate[condition.expression.start..condition.expression.end],
                    loop_scope,
                );
                if (condition.negated) selected = !selected;
                if (!selected) {
                    parent_scope.* = loop_scope;
                    continue;
                }
            }
            const expression = candidate[conditional.declaration.start..conditional.declaration.end];
            var value: *const native_value.Value = undefined;
            if (parseMemberAssignment(expression)) |assignment| {
                try self.assignMemberValue(span, assignment, loop_scope);
                value = (try self.lookupBinding(loop_scope, assignment.base)) orelse
                    return error.UndefinedVariable;
            } else if (parseAssignment(expression)) |assignment| {
                value = try self.evaluateValue(span, assignment.value, loop_scope, 0);
                if (assignment.operator) |operator| {
                    const current = (try self.lookupBinding(loop_scope, assignment.name)) orelse {
                        try self.reportUndefinedVariable(span);
                        return error.UndefinedVariable;
                    };
                    value = try self.evaluateGenericBinary(span, current, value, operator);
                }
                if (!(try self.updateBinding(loop_scope, assignment.name, value))) {
                    loop_scope = try self.setBinding(loop_scope, assignment.name, value, span);
                }
            } else {
                value = try self.evaluateValue(span, expression, loop_scope, 0);
            }
            parent_scope.* = loop_scope;
            last = .{ .value = value, .explicit = is_return };
            if (is_return) return last;
        }
        return last;
    }

    fn postfixLoopSelected(
        self: *Engine,
        span: native_source.Span,
        conditions: []const u8,
        scope: native_environment.ScopeId,
    ) Error!bool {
        var remaining = conditions;
        while (std.mem.trim(u8, remaining, " \t\r\n\x0c;").len != 0) {
            const condition = parsePostfixLoopCondition(remaining) orelse {
                try self.reportInvalidOperation(span);
                return error.InvalidOperation;
            };
            var selected = try self.evaluateCondition(
                span,
                condition.expression,
                scope,
            );
            if (condition.negated) selected = !selected;
            if (!selected) return false;
            remaining = condition.remaining;
        }
        return true;
    }

    fn executePostfixDeclaration(
        self: *Engine,
        declaration_id: native_syntax.NodeId,
        parent_scope: *native_environment.ScopeId,
        output: RuleOutput,
    ) Error!void {
        const declaration = try self.document.get(declaration_id);
        const text = declaration.text orelse return error.InvalidDocument;
        const raw = try self.sources.slice(text);
        const postfix = parsePostfixLoop(raw) orelse return error.InvalidDocument;
        const expression_start = @intFromPtr(postfix.expression.ptr) - @intFromPtr(raw.ptr);
        const expression_span = try self.relativeSpan(text, .{
            .start = expression_start,
            .end = expression_start + postfix.expression.len,
        });
        const collection = try self.evaluateValue(
            text,
            postfix.header.items,
            parent_scope.*,
            0,
        );
        const items = if (collection.* == .list)
            collection.list.items
        else
            @as([]const native_value.Value, &.{collection.*});
        for (items, 0..) |item, item_index| {
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
            var loop_scope = self.environment.push(parent_scope.*) catch |failure| {
                try self.reportResource(text, "native Stylus lexical scope limit exceeded");
                return failure;
            };
            loop_scope = try self.setBinding(
                loop_scope,
                postfix.header.name,
                try self.ownValue(text, item),
                text,
            );
            if (postfix.header.index_name) |index_name| {
                loop_scope = try self.setBinding(
                    loop_scope,
                    index_name,
                    try self.ownUnitlessNumber(text, @floatFromInt(item_index)),
                    text,
                );
            }
            if (!try self.postfixLoopSelected(text, postfix.conditions, loop_scope)) {
                parent_scope.* = loop_scope;
                continue;
            }

            var rendered = (try self.renderDeclarationText(
                expression_span,
                declaration.span,
                loop_scope,
            )) orelse {
                parent_scope.* = loop_scope;
                continue;
            };
            errdefer rendered.deinit(self.allocator);
            const reference_name = try std.fmt.allocPrint(
                self.allocator,
                "@{s}",
                .{rendered.property},
            );
            defer self.allocator.free(reference_name);
            loop_scope = try self.setBinding(
                loop_scope,
                reference_name,
                rendered.semantic_value,
                rendered.span,
            );
            try output.declarations.append(self.allocator, rendered);
            parent_scope.* = loop_scope;
        }
    }

    fn executePostfixMixin(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        parent_scope: *native_environment.ScopeId,
        output: RuleOutput,
    ) Error!void {
        const postfix = parsePostfixLoop(raw) orelse return error.InvalidDocument;
        const collection = try self.evaluateValue(span, postfix.header.items, parent_scope.*, 0);
        const items = if (collection.* == .list)
            collection.list.items
        else
            @as([]const native_value.Value, &.{collection.*});
        for (items, 0..) |item, item_index| {
            if (self.loop_iterations >= self.limits.max_loop_iterations) return error.LoopLimitExceeded;
            self.loop_iterations += 1;
            try self.transaction.consumeLoopIterations(1);
            var loop_scope = try self.environment.push(parent_scope.*);
            loop_scope = try self.setBinding(
                loop_scope,
                postfix.header.name,
                try self.ownValue(span, item),
                span,
            );
            if (postfix.header.index_name) |index_name| {
                loop_scope = try self.setBinding(
                    loop_scope,
                    index_name,
                    try self.ownUnitlessNumber(span, @floatFromInt(item_index)),
                    span,
                );
            }
            if (!try self.postfixLoopSelected(span, postfix.conditions, loop_scope)) {
                parent_scope.* = loop_scope;
                continue;
            }
            const expression = std.mem.trim(u8, postfix.expression, " \t\r\n\x0c;");
            const call = parseCall(expression) orelse parseBareCall(expression) orelse {
                try self.reportUndefinedCallable(span);
                return error.UndefinedCallable;
            };
            const returned = try self.invokeUserCallable(
                span,
                expression,
                call,
                loop_scope,
                output,
                false,
            );
            if (returned != null) return error.InvalidDocument;
            parent_scope.* = loop_scope;
        }
    }

    fn renderDeclaration(
        self: *Engine,
        declaration_id: native_syntax.NodeId,
        scope: native_environment.ScopeId,
    ) Error!?RenderedDeclaration {
        const declaration = try self.document.get(declaration_id);
        const text = declaration.text orelse return error.InvalidDocument;
        return self.renderDeclarationText(text, declaration.span, scope);
    }

    fn renderDeclarationText(
        self: *Engine,
        text: native_source.Span,
        declaration_span: native_source.Span,
        scope: native_environment.ScopeId,
    ) Error!?RenderedDeclaration {
        const raw = try self.sources.slice(text);
        const postfix_split = splitPostfixCondition(raw);
        if (postfix_split.condition) |postfix| {
            var selected = try self.evaluateCondition(
                text,
                raw[postfix.expression.start..postfix.expression.end],
                scope,
            );
            if (postfix.negated) selected = !selected;
            if (!selected) return null;
        }
        const declaration_raw = raw[postfix_split.declaration.start..postfix_split.declaration.end];
        const relative_parts = splitDeclaration(declaration_raw) orelse {
            try self.transaction.report(
                .err,
                .syntax,
                text,
                "native Stylus property declaration is invalid",
                &.{},
            );
            return error.InvalidDocument;
        };
        const parts = [2]ByteRange{
            .{
                .start = postfix_split.declaration.start + relative_parts[0].start,
                .end = postfix_split.declaration.start + relative_parts[0].end,
            },
            .{
                .start = postfix_split.declaration.start + relative_parts[1].start,
                .end = postfix_split.declaration.start + relative_parts[1].end,
            },
        };
        const property_span = try self.relativeSpan(text, parts[0]);
        const value_span = try self.relativeSpan(text, parts[1]);
        const property = try self.renderTextOwned(property_span, scope, .property, 0);
        errdefer self.allocator.free(property);
        const source_file = try self.sources.get(text.source);
        if (std.ascii.eqlIgnoreCase(std.fs.path.extension(source_file.name), ".css")) {
            const value = try self.renderTextOwned(value_span, scope, .value, 0);
            return .{
                .span = declaration_span,
                .property = property,
                .value = value,
                .semantic_value = try self.ownValue(value_span, .{ .string = .{ .bytes = value } }),
                .side_effect = false,
            };
        }
        const previous_property = self.active_property;
        const previous_property_value = self.active_property_value;
        const property_binding_start = self.current_property_bindings.items.len;
        self.active_property = .{
            .property = property,
            .value_span = value_span,
            .scope = scope,
        };
        self.active_property_value = null;
        defer {
            self.active_property = previous_property;
            self.active_property_value = previous_property_value;
            self.current_property_bindings.shrinkRetainingCapacity(property_binding_start);
        }
        const value_raw = raw[parts[1].start..parts[1].end];
        if (sourceQuotedValue(value_raw)) |quote| {
            const semantic = try self.evaluateValue(value_span, value_raw, scope, 0);
            if (semantic.* != .string or !semantic.string.quoted) return error.InvalidDocument;
            var quoted: std.ArrayList(u8) = .empty;
            errdefer quoted.deinit(self.allocator);
            try self.appendTemporary(&quoted, value_span, &.{quote});
            try self.appendTemporary(&quoted, value_span, semantic.string.bytes);
            try self.appendTemporary(&quoted, value_span, &.{quote});
            return .{
                .span = declaration_span,
                .property = property,
                .value = try quoted.toOwnedSlice(self.allocator),
                .semantic_value = semantic,
                .side_effect = false,
            };
        }
        if (try self.renderCommentedDeclarationValueOwned(
            value_span,
            value_raw,
            scope,
        )) |commented| {
            return .{
                .span = declaration_span,
                .property = property,
                .value = commented.bytes,
                .semantic_value = commented.semantic,
                .side_effect = false,
            };
        }
        const value = try self.evaluateDeclarationValue(
            value_span,
            value_raw,
            scope,
            0,
        );
        const serialized = try self.serializeDeclarationValueOwned(
            value,
            value_span,
            value_raw,
        );
        return .{
            .span = declaration_span,
            .property = property,
            .value = serialized,
            .semantic_value = value,
            .side_effect = false,
        };
    }

    fn renderCommentedDeclarationValueOwned(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        scope: native_environment.ScopeId,
    ) Error!?CommentedDeclarationValue {
        if (std.mem.indexOfScalar(u8, raw, '/') == null) return null;

        try self.transaction.consumeOperations(@intCast(raw.len));
        try self.reserveTemporary(span, raw.len);
        const sanitized = try self.allocator.dupe(u8, raw);
        defer self.allocator.free(sanitized);
        var anchors: std.ArrayList(InlineCommentAnchor) = .empty;
        defer anchors.deinit(self.allocator);

        var lexer = try native_lexer.Lexer.init(raw, .stylus, .{});
        var depth: usize = 0;
        var leaf_count: usize = 0;
        var comma_count: usize = 0;
        var in_item = false;
        var last_significant: ?native_lexer.Kind = null;
        var saw_comment = false;
        while (true) {
            const token = try lexer.next();
            if (token.kind == .eof) break;
            const start: usize = @intCast(token.span.start);
            const end: usize = @intCast(token.span.end);
            switch (token.kind) {
                .comment => {
                    saw_comment = true;
                    @memset(sanitized[start..end], ' ');
                    if (depth == 0) in_item = false;
                    const comment = raw[start..end];
                    if (depth == 0 and std.mem.startsWith(u8, comment, "/*") and
                        !(last_significant == .comma and commentEndsContinuedLine(raw, end)))
                    {
                        try anchors.append(self.allocator, .{
                            .start = start,
                            .end = end,
                            .leaf_count = leaf_count,
                            .comma_count = comma_count,
                            .after_comma = last_significant == .comma,
                            .leading_space = start > 0 and std.ascii.isWhitespace(raw[start - 1]),
                            .trailing_space = end < raw.len and std.ascii.isWhitespace(raw[end]),
                        });
                    }
                },
                .whitespace, .newline, .indent, .dedent => {
                    if (depth == 0) in_item = false;
                },
                .open_paren, .open_square, .open_curly, .interpolation_start => {
                    if (depth == 0 and !in_item) {
                        leaf_count += 1;
                        in_item = true;
                    }
                    depth += 1;
                    if (depth == 1) last_significant = token.kind;
                },
                .close_paren, .close_square, .close_curly, .interpolation_end => {
                    depth -|= 1;
                    if (depth == 0) {
                        in_item = true;
                        last_significant = token.kind;
                    }
                },
                .comma => if (depth == 0) {
                    comma_count += 1;
                    in_item = false;
                    last_significant = .comma;
                },
                else => if (depth == 0) {
                    if (!in_item) {
                        leaf_count += 1;
                        in_item = true;
                    }
                    last_significant = token.kind;
                },
            }
        }
        if (!saw_comment) return null;

        const semantic = try self.evaluateValue(span, sanitized, scope, 0);
        const serialized = try self.serializeValueOwned(semantic, .value, span);
        if (anchors.items.len == 0) return .{ .bytes = serialized, .semantic = semantic };
        defer self.allocator.free(serialized);

        var leaf_ends: std.ArrayList(usize) = .empty;
        defer leaf_ends.deinit(self.allocator);
        var comma_ends: std.ArrayList(usize) = .empty;
        defer comma_ends.deinit(self.allocator);
        try collectSerializedValueBoundaries(
            self.allocator,
            serialized,
            &leaf_ends,
            &comma_ends,
        );

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var serialized_cursor: usize = 0;
        for (anchors.items) |anchor| {
            const insertion = if (anchor.after_comma) blk: {
                if (anchor.comma_count == 0 or anchor.comma_count > comma_ends.items.len) {
                    return error.InvalidDocument;
                }
                break :blk comma_ends.items[anchor.comma_count - 1];
            } else if (anchor.leaf_count == 0)
                0
            else blk: {
                if (anchor.leaf_count > leaf_ends.items.len) return error.InvalidDocument;
                break :blk leaf_ends.items[anchor.leaf_count - 1];
            };
            if (insertion < serialized_cursor or insertion > serialized.len) {
                return error.InvalidDocument;
            }
            try self.appendTemporary(&output, span, serialized[serialized_cursor..insertion]);
            if (anchor.leading_space and output.items.len > 0 and
                !std.ascii.isWhitespace(output.items[output.items.len - 1]))
            {
                try self.appendTemporary(&output, span, " ");
            }
            try self.appendTemporary(&output, span, raw[anchor.start..anchor.end]);
            if (anchor.trailing_space and
                (insertion == serialized.len or !std.ascii.isWhitespace(serialized[insertion])))
            {
                try self.appendTemporary(&output, span, " ");
            }
            serialized_cursor = insertion;
        }
        try self.appendTemporary(&output, span, serialized[serialized_cursor..]);
        return .{ .bytes = try output.toOwnedSlice(self.allocator), .semantic = semantic };
    }

    fn evaluateValue(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        scope: native_environment.ScopeId,
        depth: u16,
    ) Error!*const native_value.Value {
        if (try self.normalizeEolEscapesOwned(span, raw)) |normalized| {
            defer self.allocator.free(normalized);
            return self.evaluateValue(span, normalized, scope, depth);
        }
        if (depth >= self.limits.max_expression_depth) {
            try self.reportExpressionDepth(span);
            return error.ExpressionDepthExceeded;
        }
        if (parseDefinedTernary(raw)) |ternary| {
            const selected = if (try self.lookupBinding(scope, ternary.name) != null)
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
        if (memberAccessBase(raw)) |base| {
            if (!nameEql(base, "current-property") and
                try self.lookupBinding(scope, base) == null)
            {
                try self.transaction.report(
                    .err,
                    .undefined_variable,
                    span,
                    "native Stylus object is undefined",
                    &.{},
                );
                return error.UndefinedVariable;
            }
        }
        const source_input = std.mem.trim(u8, raw, " \t\r\n\x0c;");
        if (nameEql(source_input, "current-property")) {
            if (try self.lookupBinding(scope, "current-property")) |bound| {
                return bound;
            }
            return (try self.currentPropertyValue(span, scope)) orelse
                self.ownValue(span, .{ .null_value = {} });
        }
        if (nameEql(source_input, "vendors")) {
            if (try self.lookupBinding(scope, source_input)) |resolved| {
                return self.ownValue(span, resolved.*);
            }
            const items = [_]native_value.Value{
                .{ .string = .{ .bytes = "moz" } },
                .{ .string = .{ .bytes = "webkit" } },
                .{ .string = .{ .bytes = "o" } },
                .{ .string = .{ .bytes = "ms" } },
                .{ .string = .{ .bytes = "official" } },
            };
            return self.ownValue(span, .{ .list = .{
                .items = &items,
                .separator = .space,
            } });
        }
        if (isUnicodeRangeValue(source_input)) {
            return self.ownValue(span, .{ .string = .{ .bytes = source_input } });
        }
        if (nameEql(source_input, "called-from")) {
            var names: std.ArrayList(native_value.Value) = .empty;
            defer names.deinit(self.allocator);
            var index = self.active_callables.items.len;
            if (index > 0) index -= 1;
            while (index > 0) {
                index -= 1;
                try names.append(self.allocator, .{ .string = .{
                    .bytes = self.active_callables.items[index],
                } });
            }
            return self.ownValue(span, .{ .list = .{ .items = names.items, .separator = .space } });
        }
        if (parseAssignment(source_input)) |assignment| {
            if (assignment.value.len > 0) {
                var assigned = try self.evaluateValue(span, assignment.value, scope, depth + 1);
                if (assignment.operator) |operator| {
                    const current = (try self.lookupBinding(scope, assignment.name)) orelse {
                        try self.reportUndefinedVariable(span);
                        return error.UndefinedVariable;
                    };
                    assigned = try self.evaluateGenericBinary(span, current, assigned, operator);
                }
                _ = try self.updateBinding(scope, assignment.name, assigned);
                return assigned;
            }
        }
        if (source_input.len >= 2 and source_input[0] == '{' and source_input[source_input.len - 1] == '}') {
            return self.evaluateInlineMap(span, source_input[1 .. source_input.len - 1], scope);
        }
        if (try self.evaluateCallMemberChain(span, source_input, scope, depth)) |member| return member;
        if (try self.evaluateMemberChain(span, source_input, scope)) |member| return member;
        if (validVariableName(source_input)) {
            if (try self.lookupBinding(scope, source_input)) |resolved| {
                return self.ownValue(span, resolved.*);
            }
        }
        if (parseCall(source_input)) |call| {
            const name = source_input[call.name.start..call.name.end];
            if (self.findCallable(name) != null) {
                return (try self.invokeUserCallable(
                    span,
                    source_input,
                    call,
                    scope,
                    null,
                    true,
                )).?;
            }
            if (try self.evaluateBuiltin(span, source_input, call, scope)) |builtin| return builtin;
            if (try callHasEmptyArgument(self.allocator, source_input, call)) {
                try self.reportInvalidArguments(span);
                return error.InvalidArguments;
            }
        }
        // Preserve null operands until logical fallback runs. Rendering first
        // intentionally omits null bytes, which would erase the left operand.
        if (std.mem.indexOf(u8, source_input, "||") != null) {
            const source_ungrouped = stripOuterParentheses(source_input);
            if (source_ungrouped.len != source_input.len) {
                return self.evaluateValue(span, source_ungrouped, scope, depth + 1);
            }
            if (findLogicalOperator(source_input, .or_value)) |logical| {
                const left = try self.evaluateValue(
                    span,
                    source_input[logical.left.start..logical.left.end],
                    scope,
                    depth + 1,
                );
                if (isTruthy(left)) return left;
                return self.evaluateValue(
                    span,
                    source_input[logical.right.start..logical.right.end],
                    scope,
                    depth + 1,
                );
            }
            if (findGenericBinary(source_input)) |binary| {
                const left = try self.evaluateValue(
                    span,
                    source_input[binary.left.start..binary.left.end],
                    scope,
                    depth + 1,
                );
                const right = try self.evaluateValue(
                    span,
                    source_input[binary.right.start..binary.right.end],
                    scope,
                    depth + 1,
                );
                return self.evaluateGenericBinary(span, left, right, binary.operator);
            }
        }
        if (findComparison(source_input)) |comparison| {
            const left = try self.evaluateValue(
                span,
                source_input[0..comparison.start],
                scope,
                depth + 1,
            );
            const right = try self.evaluateValue(
                span,
                source_input[comparison.end..],
                scope,
                depth + 1,
            );
            return self.ownValue(
                span,
                .{ .boolean = try self.compareValues(span, left, right, comparison.operator) },
            );
        }
        const rendered = try self.renderRawOwned(span, raw, scope, .value, depth + 1);
        defer self.allocator.free(rendered);
        const input = std.mem.trim(u8, rendered, " \t\r\n\x0c;");
        if (std.mem.eql(u8, input, "()")) {
            return self.ownValue(span, .{ .list = .{ .items = &.{}, .separator = .space } });
        }
        if (looksNumeric(input)) {
            var grouped_numeric = NumericParser{
                .input = input,
                .max_depth = self.limits.max_expression_depth,
            };
            if (grouped_numeric.parse()) |numeric| {
                var numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
                var denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
                var number = numeric.toNumber(&numerator, &denominator) catch {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                };
                if (std.mem.indexOfScalar(u8, input, '*') != null) {
                    number.value = roundDecimal(number.value, 15);
                }
                return self.ownValue(span, .{ .number = number });
            } else |failure| switch (failure) {
                error.ExpressionDepthExceeded => {
                    try self.reportExpressionDepth(span);
                    return error.ExpressionDepthExceeded;
                },
                error.InvalidExpression => {},
                else => {},
            }
        }
        const ungrouped = stripOuterParentheses(input);
        if (ungrouped.len != input.len) {
            return self.evaluateValue(span, ungrouped, scope, depth + 1);
        }
        if (parseGenericTernary(input)) |ternary| {
            const condition = input[ternary.condition.start..ternary.condition.end];
            const selected = if (try self.evaluateCondition(span, condition, scope))
                ternary.when_true
            else
                ternary.when_false;
            return self.evaluateValue(
                span,
                input[selected.start..selected.end],
                scope,
                depth + 1,
            );
        }
        if (parseUnitCast(input)) |cast| {
            const value = try self.evaluateValue(
                span,
                input[cast.expression.start..cast.expression.end],
                scope,
                depth + 1,
            );
            if (value.* == .number) return self.ownNumberWithUnit(span, value.number.value, cast.unit);
        }
        if (findLogicalOperator(input, .or_value)) |logical| {
            const left = try self.evaluateValue(
                span,
                input[logical.left.start..logical.left.end],
                scope,
                depth + 1,
            );
            if (isTruthy(left)) return left;
            return self.evaluateValue(
                span,
                input[logical.right.start..logical.right.end],
                scope,
                depth + 1,
            );
        }
        if (findLogicalOperator(input, .and_value)) |logical| {
            const left = try self.evaluateValue(
                span,
                input[logical.left.start..logical.left.end],
                scope,
                depth + 1,
            );
            if (!isTruthy(left)) return left;
            return self.evaluateValue(
                span,
                input[logical.right.start..logical.right.end],
                scope,
                depth + 1,
            );
        }
        if (std.ascii.eqlIgnoreCase(input, "!important")) {
            return self.ownValue(span, .{ .string = .{ .bytes = "!important" } });
        }
        if (findGenericBinary(input)) |binary| {
            const left = try self.evaluateValue(span, input[binary.left.start..binary.left.end], scope, depth + 1);
            const right = try self.evaluateValue(span, input[binary.right.start..binary.right.end], scope, depth + 1);
            return self.evaluateGenericBinary(span, left, right, binary.operator);
        }
        if (findRangeOperator(input)) |range| {
            const first = try self.evaluateValue(span, input[range.left.start..range.left.end], scope, depth + 1);
            const last = try self.evaluateValue(span, input[range.right.start..range.right.end], scope, depth + 1);
            const arguments = [2]*const native_value.Value{ first, last };
            const values = try self.evaluateRangeBuiltin(span, &arguments);
            if (!range.inclusive and values.* == .list and values.list.items.len > 0) {
                return self.ownValue(span, .{ .list = .{
                    .items = values.list.items[0 .. values.list.items.len - 1],
                    .separator = .space,
                } });
            }
            return values;
        }
        if (findComparison(input)) |comparison| {
            const left = try self.evaluateValue(span, input[0..comparison.start], scope, depth + 1);
            const right = try self.evaluateValue(span, input[comparison.end..], scope, depth + 1);
            return self.ownValue(
                span,
                .{ .boolean = try self.compareValues(span, left, right, comparison.operator) },
            );
        }
        if (unaryPrefix(input)) |unary| {
            const operand = try self.evaluateValue(span, input[unary.end..], scope, depth + 1);
            return switch (unary.kind) {
                .logical_not => self.ownValue(span, .{ .boolean = !isTruthy(operand) }),
                .positive, .negative, .bitwise_not => blk: {
                    if (operand.* != .number) {
                        try self.reportInvalidOperation(span);
                        return error.InvalidOperation;
                    }
                    var number = operand.number;
                    switch (unary.kind) {
                        .positive => {},
                        .negative => number.value = -number.value,
                        .bitwise_not => {
                            const integer = integerScalar(operand.*) orelse {
                                try self.reportInvalidOperation(span);
                                return error.InvalidOperation;
                            };
                            number.value = @floatFromInt(~integer);
                        },
                        else => unreachable,
                    }
                    break :blk self.ownValue(span, .{ .number = number });
                },
            };
        }
        if (findTrailingIndex(input)) |indexing| {
            const collection = try self.evaluateValue(
                span,
                input[indexing.base.start..indexing.base.end],
                scope,
                depth + 1,
            );
            const index_value = try self.evaluateValue(
                span,
                input[indexing.index.start..indexing.index.end],
                scope,
                depth + 1,
            );
            if (index_value.* != .number or index_value.number.numerator_units.len != 0 or
                index_value.number.denominator_units.len != 0 or
                @trunc(index_value.number.value) != index_value.number.value)
            {
                try self.reportInvalidOperation(span);
                return error.InvalidOperation;
            }
            const signed_index = integerScalar(index_value.*) orelse {
                try self.reportInvalidOperation(span);
                return error.InvalidOperation;
            };
            return switch (collection.*) {
                .list => |list| blk: {
                    const normalized = normalizeIndex(signed_index, list.items.len) orelse
                        break :blk self.ownValue(span, .{ .null_value = {} });
                    break :blk self.ownValue(span, list.items[normalized]);
                },
                .string => |string| blk: {
                    const normalized = normalizeIndex(signed_index, string.bytes.len) orelse
                        break :blk self.ownValue(span, .{ .null_value = {} });
                    break :blk self.ownValue(span, .{ .string = .{
                        .bytes = string.bytes[normalized .. normalized + 1],
                        .quoted = string.quoted,
                    } });
                },
                else => {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                },
            };
        }
        if (input.len >= 2 and (input[0] == '\'' or input[0] == '"') and
            closingQuote(input, 0) == input.len - 1)
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
        if (std.mem.eql(u8, input, "null")) {
            return self.ownValue(span, .{ .null_value = {} });
        }
        if (std.mem.eql(u8, input, "PI")) {
            return self.ownUnitlessNumber(span, std.math.pi);
        }
        if (std.ascii.eqlIgnoreCase(input, "transparent")) {
            return self.ownValue(span, .{ .string = .{ .bytes = "transparent" } });
        }
        if (native_color.parseLiteral(input)) |color| {
            return self.ownValue(span, .{ .color = color });
        }

        if (parseCall(input)) |call| {
            const name = input[call.name.start..call.name.end];
            if (self.findCallable(name) != null) {
                return (try self.invokeUserCallable(
                    span,
                    input,
                    call,
                    scope,
                    null,
                    true,
                )).?;
            }
            if (try self.evaluateBuiltin(span, input, call, scope)) |builtin| return builtin;
            if (try callHasEmptyArgument(self.allocator, input, call)) {
                try self.reportInvalidArguments(span);
                return error.InvalidArguments;
            }
            return self.ownValue(span, .{ .string = .{ .bytes = input } });
        }
        if (parseBareCall(input)) |call| {
            const name = input[call.name.start..call.name.end];
            if (self.findCallable(name) != null) {
                return (try self.invokeUserCallable(
                    span,
                    input,
                    call,
                    scope,
                    null,
                    true,
                )).?;
            }
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
        var comma_items = try splitTopLevel(self.allocator, input, ',');
        defer comma_items.deinit(self.allocator);
        if (comma_items.items.len > 1) {
            return self.evaluateList(span, input, comma_items.items, .comma, scope, depth + 1);
        }
        var space_items = try splitTopLevelWhitespace(self.allocator, input);
        defer space_items.deinit(self.allocator);
        if (space_items.items.len > 1) {
            return self.evaluateList(span, input, space_items.items, .space, scope, depth + 1);
        }
        return self.ownValue(span, .{ .string = .{ .bytes = input } });
    }

    fn evaluateList(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        ranges: []const ByteRange,
        separator: native_value.Separator,
        scope: native_environment.ScopeId,
        depth: u16,
    ) Error!*const native_value.Value {
        var items: std.ArrayList(native_value.Value) = .empty;
        defer items.deinit(self.allocator);
        try items.ensureTotalCapacity(self.allocator, ranges.len);
        for (ranges) |range| {
            const item = try self.evaluateValue(
                span,
                raw[range.start..range.end],
                scope,
                depth + 1,
            );
            items.appendAssumeCapacity(item.*);
        }
        return self.ownValue(span, .{ .list = .{
            .items = items.items,
            .separator = separator,
        } });
    }

    fn evaluateDeclarationValue(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        scope: native_environment.ScopeId,
        depth: u16,
    ) Error!*const native_value.Value {
        var slash_parts = try splitTopLevel(self.allocator, raw, '/');
        defer slash_parts.deinit(self.allocator);
        if (slash_parts.items.len == 1) {
            return self.evaluateValue(span, raw, scope, depth);
        }

        var comma_parts = try splitTopLevel(self.allocator, raw, ',');
        defer comma_parts.deinit(self.allocator);
        if (comma_parts.items.len == 1) {
            return self.evaluatePropertySlashGroup(span, raw, scope, depth + 1);
        }

        var items: std.ArrayList(native_value.Value) = .empty;
        defer items.deinit(self.allocator);
        try items.ensureTotalCapacity(self.allocator, comma_parts.items.len);
        for (comma_parts.items) |range| {
            const item = try self.evaluatePropertySlashGroup(
                span,
                raw[range.start..range.end],
                scope,
                depth + 1,
            );
            items.appendAssumeCapacity(item.*);
        }
        return self.ownValue(span, .{ .list = .{
            .items = items.items,
            .separator = .comma,
        } });
    }

    fn evaluatePropertySlashGroup(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        scope: native_environment.ScopeId,
        depth: u16,
    ) Error!*const native_value.Value {
        var parts = try splitTopLevel(self.allocator, raw, '/');
        defer parts.deinit(self.allocator);
        if (parts.items.len == 1) {
            return self.evaluateValue(span, raw, scope, depth);
        }

        var items: std.ArrayList(native_value.Value) = .empty;
        defer items.deinit(self.allocator);
        for (parts.items, 0..) |range, index| {
            const item_raw = std.mem.trim(
                u8,
                raw[range.start..range.end],
                " \t\r\n\x0c",
            );
            if (item_raw.len == 0) {
                try self.reportInvalidOperation(span);
                return error.InvalidOperation;
            }
            const item = try self.evaluateValue(span, item_raw, scope, depth + 1);
            if (item.* == .list and item.list.separator == .space and
                !item.list.bracketed)
            {
                try items.appendSlice(self.allocator, item.list.items);
            } else {
                try items.append(self.allocator, item.*);
            }
            if (index + 1 < parts.items.len) {
                try items.append(self.allocator, .{ .string = .{ .bytes = "/" } });
            }
        }
        return self.ownValue(span, .{ .list = .{
            .items = items.items,
            .separator = .space,
        } });
    }

    fn evaluateGenericBinary(
        self: *Engine,
        span: native_source.Span,
        left: *const native_value.Value,
        right: *const native_value.Value,
        operator: u8,
    ) Error!*const native_value.Value {
        // Stylus Unit.coerce() follows JavaScript parseFloat() when the right
        // operand is a quoted string and retains the left number's unit.
        if (left.* == .number and right.* == .string and operator == '+') {
            if (parseStylusFloatPrefix(right.string.bytes)) |right_value| {
                var number = left.number;
                number.value += right_value;
                if (!std.math.isFinite(number.value)) {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                }
                return self.ownValue(span, .{ .number = number });
            }
        }
        if (left.* == .color and (operator == '+' or operator == '-')) {
            const sign: f64 = if (operator == '+') 1 else -1;
            var result: native_value.Color = undefined;
            if (right.* == .color) {
                if (right.color.space == .hsl) {
                    const left_channels = native_color.toHsl(left.color) catch
                        return error.InvalidOperation;
                    const right_channels = native_color.toHsl(right.color) catch
                        return error.InvalidOperation;
                    result = native_color.hsl(
                        left_channels[0] + sign * right_channels[0],
                        left_channels[1] + sign * right_channels[1],
                        left_channels[2] + sign * right_channels[2],
                        left_channels[3],
                    ) catch return error.InvalidOperation;
                } else {
                    const left_channels = native_color.toRgb(left.color) catch
                        return error.InvalidOperation;
                    const right_channels = native_color.toRgb(right.color) catch
                        return error.InvalidOperation;
                    const alpha = if (operator == '-' and right_channels[3] == 1)
                        left_channels[3]
                    else
                        left_channels[3] + sign * right_channels[3];
                    result = native_color.rgb(
                        left_channels[0] + sign * right_channels[0],
                        left_channels[1] + sign * right_channels[1],
                        left_channels[2] + sign * right_channels[2],
                        alpha,
                    ) catch return error.InvalidOperation;
                }
            } else if (right.* == .number) {
                const unit = singleUnit(right.number);
                if (unit != null and std.mem.eql(u8, unit.?, "deg")) {
                    result = native_color.adjustHue(left.color, sign * right.number.value) catch return error.InvalidOperation;
                } else if (unit != null and std.mem.eql(u8, unit.?, "%")) {
                    const channels = native_color.toHsl(left.color) catch
                        return error.InvalidOperation;
                    const amount = if (operator == '+')
                        (100 - channels[2]) * right.number.value / 100
                    else
                        -channels[2] * right.number.value / 100;
                    result = native_color.adjustLightness(left.color, amount) catch
                        return error.InvalidOperation;
                } else if (unit == null) {
                    const channels = native_color.toRgb(left.color) catch return error.InvalidOperation;
                    result = native_color.rgb(
                        channels[0] + sign * right.number.value,
                        channels[1] + sign * right.number.value,
                        channels[2] + sign * right.number.value,
                        channels[3],
                    ) catch return error.InvalidOperation;
                } else {
                    return error.InvalidOperation;
                }
            } else {
                return error.InvalidOperation;
            }
            return self.ownValue(span, .{ .color = quantizeColor(result, .nearest) catch return error.InvalidOperation });
        }
        if (left.* == .number and right.* == .number) {
            const left_numeric = native_numeric.Numeric.fromNumber(left.number) catch {
                try self.reportInvalidOperation(span);
                return error.InvalidOperation;
            };
            const right_numeric = native_numeric.Numeric.fromNumber(right.number) catch {
                try self.reportInvalidOperation(span);
                return error.InvalidOperation;
            };
            const result = switch (operator) {
                '+', '-' => native_numeric.addPermissive(left_numeric, right_numeric, operator),
                '*' => native_numeric.multiply(left_numeric, right_numeric, operator),
                '/' => divideStylusNumbers(left_numeric, right_numeric),
                '%' => native_numeric.modulo(left_numeric, right_numeric),
                else => return error.InvalidOperation,
            } catch {
                try self.reportInvalidOperation(span);
                return error.InvalidOperation;
            };
            var numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
            var denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
            var number = result.toNumber(&numerator, &denominator) catch {
                try self.reportInvalidOperation(span);
                return error.InvalidOperation;
            };
            if (operator == '*') number.value = roundDecimal(number.value, 15);
            return self.ownValue(span, .{ .number = number });
        }
        if (operator == '+' and (left.* == .list or right.* == .list)) {
            var values: std.ArrayList(native_value.Value) = .empty;
            defer values.deinit(self.allocator);
            if (left.* == .list) try values.appendSlice(self.allocator, left.list.items) else try values.append(self.allocator, left.*);
            if (right.* == .list) try values.appendSlice(self.allocator, right.list.items) else try values.append(self.allocator, right.*);
            return self.ownValue(span, .{ .list = .{ .items = values.items, .separator = .space } });
        }
        if (operator == '-' and left.* == .list) {
            var values: std.ArrayList(native_value.Value) = .empty;
            defer values.deinit(self.allocator);
            for (left.list.items) |item| if (!native_value.eql(item, right.*)) try values.append(self.allocator, item);
            return self.ownValue(span, .{ .list = .{ .items = values.items, .separator = left.list.separator } });
        }
        if (operator == '%' and left.* == .string) {
            const arguments = if (right.* == .list)
                right.list.items
            else
                @as([]const native_value.Value, &.{right.*});
            var pointers: std.ArrayList(*const native_value.Value) = .empty;
            defer pointers.deinit(self.allocator);
            try pointers.ensureTotalCapacity(self.allocator, arguments.len + 1);
            pointers.appendAssumeCapacity(left);
            for (arguments) |*argument| pointers.appendAssumeCapacity(argument);
            return self.evaluateStringBuiltin(span, "s", pointers.items);
        }
        if (operator == '*' and left.* == .string and integerScalar(right.*) != null) {
            if (right.number.numerator_units.len != 0 or right.number.denominator_units.len != 0) {
                return self.invalidBuiltinArguments(span);
            }
            const count = std.math.cast(usize, integerScalar(right.*).?) orelse
                return self.invalidBuiltinArguments(span);
            if (left.string.bytes.len == 0 or count == 0) {
                return self.ownValue(span, .{ .string = .{
                    .bytes = "",
                    .quoted = left.string.quoted,
                } });
            }
            const total = std.math.mul(usize, left.string.bytes.len, count) catch {
                try self.reportResource(span, "native Stylus temporary byte limit exceeded");
                return error.TemporaryLimitExceeded;
            };
            try self.reserveTemporary(span, total);
            try self.transaction.consumeOperations(total);
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(self.allocator);
            try output.ensureTotalCapacity(self.allocator, total);
            for (0..count) |_| output.appendSliceAssumeCapacity(left.string.bytes);
            return self.ownValue(span, .{ .string = .{ .bytes = output.items, .quoted = left.string.quoted } });
        }
        if (operator == '+') {
            const left_serialized = try self.serializeValueOwned(left, .value, span);
            defer self.allocator.free(left_serialized);
            const right_serialized = try self.serializeValueOwned(right, .value, span);
            defer self.allocator.free(right_serialized);
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(self.allocator);
            const left_bytes = if (left.* == .string) left.string.bytes else left_serialized;
            const right_bytes = if (right.* == .string) right.string.bytes else right_serialized;
            try self.appendTemporary(&output, span, left_bytes);
            try self.appendTemporary(&output, span, right_bytes);
            return self.ownStringResult(
                span,
                output.items,
                (left.* == .string and left.string.quoted) or (right.* == .string and right.string.quoted),
            );
        }
        try self.reportInvalidOperation(span);
        return error.InvalidOperation;
    }

    fn evaluateBuiltin(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        call: Call,
        scope: native_environment.ScopeId,
    ) Error!?*const native_value.Value {
        const name = raw[call.name.start..call.name.end];
        if (nameEql(name, "url")) {
            return try self.evaluateUrlBuiltin(span, raw, call, scope);
        }
        if (nameEql(name, "selector")) {
            return try self.evaluateSelectorBuiltin(span, raw, call, scope);
        }
        if (nameEql(name, "selector-exists")) {
            return try self.evaluateSelectorExistsBuiltin(span, raw, call, scope);
        }
        if (nameEql(name, "prefix-classes")) {
            try self.transaction.report(
                .err,
                .unsupported_feature,
                span,
                "native Stylus prefix-classes() requires a content block",
                &.{},
            );
            return error.UnsupportedFeature;
        }
        if (nameEql(name, "define")) {
            try self.transaction.report(
                .err,
                .unsupported_feature,
                span,
                "native Stylus define() is supported only as a statement",
                &.{},
            );
            return error.UnsupportedFeature;
        }
        if (nameEql(name, "append") or nameEql(name, "push") or
            nameEql(name, "prepend") or nameEql(name, "unshift") or
            nameEql(name, "pop") or nameEql(name, "shift"))
        {
            return try self.evaluateMutationBuiltin(span, raw, call, scope, name);
        }
        if (nameEql(name, "add-property")) {
            return try self.evaluateAddPropertyBuiltin(span, raw, call, scope);
        }
        if (nameEql(name, "error")) {
            var arguments = try self.evaluateCallArguments(span, raw, call, scope);
            defer arguments.deinit(self.allocator);
            if (arguments.items.len != 1 or stringBytes(arguments.items[0].*) == null) {
                return self.invalidBuiltinArguments(span);
            }
            try self.transaction.report(
                .err,
                .invalid_operation,
                span,
                "native Stylus error() was invoked",
                &.{},
            );
            return error.InvalidOperation;
        }
        if (nameEql(name, "match")) {
            var match_arguments = try self.evaluateMatchArguments(span, raw, call, scope);
            defer match_arguments.deinit(self.allocator);
            return self.evaluateMatchBuiltin(span, match_arguments.items);
        }
        if (nameEql(name, "operate")) {
            return self.evaluateOperateBuiltin(span, raw, call, scope);
        }
        if (nameEql(name, "json")) {
            var json_arguments = try self.evaluateCallArguments(span, raw, call, scope);
            defer json_arguments.deinit(self.allocator);
            if (json_arguments.items.len != 2 or json_arguments.items[1].* != .map) {
                try self.transaction.report(
                    .err,
                    .unsupported_feature,
                    span,
                    "native Stylus legacy json() is supported only as a statement",
                    &.{},
                );
                return error.UnsupportedFeature;
            }
            return self.evaluateJsonBuiltin(span, json_arguments.items, scope);
        }
        if (nameEql(name, "merge") or nameEql(name, "extend")) {
            return try self.evaluateMergeBuiltin(span, raw, call, scope);
        }
        var arguments = if (nameEql(name, "join"))
            try self.evaluateJoinCallArguments(span, raw, call, scope)
        else
            try self.evaluateCallArguments(span, raw, call, scope);
        defer arguments.deinit(self.allocator);

        if (nameEql(name, "image-size")) {
            return try self.evaluateImageSizeBuiltin(span, arguments.items);
        }
        if (nameEql(name, "length")) {
            if (arguments.items.len > 1) return self.invalidBuiltinArguments(span);
            const count: usize = if (arguments.items.len == 0)
                0
            else switch (arguments.items[0].*) {
                .list => |list| list.items.len,
                .map => |map| map.entries.len,
                .string => |string| if (string.quoted)
                    std.unicode.calcUtf16LeLen(string.bytes) catch
                        return self.invalidBuiltinArguments(span)
                else
                    1,
                else => 1,
            };
            return try self.ownUnitlessNumber(span, @floatFromInt(count));
        }
        if (nameEql(name, "selectors")) {
            if (arguments.items.len != 0) return self.invalidBuiltinArguments(span);
            var parts: std.ArrayList(native_value.Value) = .empty;
            defer parts.deinit(self.allocator);
            for (self.selector_parts.items) |part| {
                try parts.append(self.allocator, .{ .string = .{
                    .bytes = part,
                    .quoted = true,
                } });
            }
            return self.ownValue(span, .{ .list = .{
                .items = parts.items,
                .separator = .comma,
            } });
        }
        if (nameEql(name, "current-media")) {
            if (arguments.items.len != 0) return self.invalidBuiltinArguments(span);
            const media = if (self.media_stack.items.len > 0)
                self.media_stack.items[self.media_stack.items.len - 1]
            else
                "";
            return self.ownValue(span, .{ .string = .{ .bytes = media, .quoted = true } });
        }
        if (nameEql(name, "type") or nameEql(name, "typeof") or nameEql(name, "type-of")) {
            if (arguments.items.len != 1) return self.invalidBuiltinArguments(span);
            const kind: []const u8 = switch (arguments.items[0].*) {
                .null_value => "null",
                .boolean => "boolean",
                .number => "unit",
                .color => |color| if (color.space == .hsl) "hsla" else "rgba",
                .string => |string| if (string.quoted) "string" else if (self.findCallable(string.bytes) != null or isBuiltinCallableName(string.bytes)) "function" else "ident",
                .list => "unit",
                .map => "object",
                .callable => "function",
                else => "ident",
            };
            return try self.ownValue(span, .{ .string = .{ .bytes = kind, .quoted = true } });
        }
        if (nameEql(name, "convert")) {
            if (arguments.items.len != 1 or arguments.items[0].* != .string) {
                return self.invalidBuiltinArguments(span);
            }
            return self.evaluateConvertedString(span, arguments.items[0].string.bytes, 0);
        }
        if (nameEql(name, "lookup")) {
            if (arguments.items.len != 1) return self.invalidBuiltinArguments(span);
            const binding_name = stringBytes(arguments.items[0].*) orelse return self.invalidBuiltinArguments(span);
            if (try self.lookupBinding(scope, binding_name)) |value| return self.ownValue(span, value.*);
            return try self.ownValue(span, .{ .null_value = {} });
        }
        if (nameEql(name, "clone")) {
            if (arguments.items.len != 1) return self.invalidBuiltinArguments(span);
            return self.ownValue(span, arguments.items[0].*);
        }
        if (nameEql(name, "rgb") or nameEql(name, "rgba")) {
            if (arguments.items.len == 2 and arguments.items[0].* == .color) {
                const alpha = alphaScalar(arguments.items[1].*) orelse
                    return self.invalidBuiltinArguments(span);
                var color = arguments.items[0].color;
                color.channels[3] = std.math.clamp(alpha, 0, 1);
                return try self.ownValue(span, .{ .color = color });
            }
            const expected: usize = if (nameEql(name, "rgb")) 3 else 4;
            if (arguments.items.len != expected) return self.invalidBuiltinArguments(span);
            const red = channelScalar(arguments.items[0].*) orelse return self.invalidBuiltinArguments(span);
            const green = channelScalar(arguments.items[1].*) orelse return self.invalidBuiltinArguments(span);
            const blue = channelScalar(arguments.items[2].*) orelse return self.invalidBuiltinArguments(span);
            const alpha = if (expected == 4)
                alphaScalar(arguments.items[3].*) orelse return self.invalidBuiltinArguments(span)
            else
                1;
            const color = native_color.rgb(red, green, blue, alpha) catch
                return self.invalidBuiltinArguments(span);
            return try self.ownValue(span, .{ .color = color });
        }
        if (nameEql(name, "hsl") or nameEql(name, "hsla")) {
            if ((arguments.items.len == 1 or arguments.items.len == 2) and
                arguments.items[0].* == .color)
            {
                var color = arguments.items[0].color;
                if (arguments.items.len == 2) {
                    color.channels[3] = alphaScalar(arguments.items[1].*) orelse
                        return self.invalidBuiltinArguments(span);
                }
                return try self.ownValue(span, .{ .color = color });
            }
            const expected: usize = if (nameEql(name, "hsl")) 3 else 4;
            if (arguments.items.len != expected) return self.invalidBuiltinArguments(span);
            const hue = angleScalar(arguments.items[0].*) orelse return self.invalidBuiltinArguments(span);
            const saturation = percentScalar(arguments.items[1].*) orelse return self.invalidBuiltinArguments(span);
            const lightness = percentScalar(arguments.items[2].*) orelse return self.invalidBuiltinArguments(span);
            const alpha = if (expected == 4)
                alphaScalar(arguments.items[3].*) orelse return self.invalidBuiltinArguments(span)
            else
                1;
            const color = native_color.hsl(hue, saturation, lightness, alpha) catch
                return self.invalidBuiltinArguments(span);
            return try self.ownValue(span, .{ .color = color });
        }
        if (nameEql(name, "contrast")) {
            if (arguments.items.len == 0 or arguments.items[0].* != .color) {
                var literal: std.ArrayList(u8) = .empty;
                defer literal.deinit(self.allocator);
                try self.appendTemporary(&literal, span, "contrast(");
                if (arguments.items.len > 0) {
                    const serialized = try self.serializeValueOwned(arguments.items[0], .value, span);
                    defer self.allocator.free(serialized);
                    try self.appendTemporary(&literal, span, serialized);
                }
                try self.appendTemporary(&literal, span, ")");
                return self.ownStringResult(span, literal.items, false);
            }
            if (arguments.items.len > 2 or
                (arguments.items.len == 2 and arguments.items[1].* != .color))
            {
                return self.invalidBuiltinArguments(span);
            }
            const background = if (arguments.items.len == 2)
                arguments.items[1].color
            else
                native_color.parseLiteral("white").?;
            const contrast = stylusContrast(arguments.items[0].color, background) catch
                return self.invalidBuiltinArguments(span);
            const entries = [_]native_value.Entry{
                .{
                    .key = .{ .string = .{ .bytes = "ratio", .quoted = true } },
                    .value = .{ .number = .{ .value = contrast.ratio } },
                },
                .{
                    .key = .{ .string = .{ .bytes = "error", .quoted = true } },
                    .value = .{ .number = .{ .value = contrast.error_value } },
                },
                .{
                    .key = .{ .string = .{ .bytes = "min", .quoted = true } },
                    .value = .{ .number = .{ .value = contrast.minimum } },
                },
                .{
                    .key = .{ .string = .{ .bytes = "max", .quoted = true } },
                    .value = .{ .number = .{ .value = contrast.maximum } },
                },
            };
            return self.ownValue(span, .{ .map = .{ .entries = &entries } });
        }

        if (nameEql(name, "red") or nameEql(name, "green") or nameEql(name, "blue") or
            nameEql(name, "alpha") or nameEql(name, "hue") or
            nameEql(name, "saturation") or nameEql(name, "lightness") or
            nameEql(name, "luminosity"))
        {
            if (arguments.items.len == 2 and arguments.items[0].* == .color and
                !nameEql(name, "luminosity"))
            {
                const input_color = arguments.items[0].color;
                var channels = if (nameEql(name, "hue") or nameEql(name, "saturation") or
                    nameEql(name, "lightness"))
                    native_color.toHsl(input_color) catch return self.invalidBuiltinArguments(span)
                else
                    native_color.toRgb(input_color) catch return self.invalidBuiltinArguments(span);
                const index: usize = if (nameEql(name, "red") or nameEql(name, "hue"))
                    0
                else if (nameEql(name, "green") or nameEql(name, "saturation"))
                    1
                else if (nameEql(name, "blue") or nameEql(name, "lightness"))
                    2
                else
                    3;
                channels[index] = if (nameEql(name, "hue"))
                    angleScalar(arguments.items[1].*) orelse return self.invalidBuiltinArguments(span)
                else if (nameEql(name, "saturation") or nameEql(name, "lightness"))
                    percentScalar(arguments.items[1].*) orelse return self.invalidBuiltinArguments(span)
                else if (nameEql(name, "alpha"))
                    alphaScalar(arguments.items[1].*) orelse return self.invalidBuiltinArguments(span)
                else
                    channelScalar(arguments.items[1].*) orelse return self.invalidBuiltinArguments(span);
                const color = if (nameEql(name, "hue") or nameEql(name, "saturation") or
                    nameEql(name, "lightness"))
                    native_color.hsl(channels[0], channels[1], channels[2], channels[3])
                else
                    native_color.rgb(channels[0], channels[1], channels[2], channels[3]);
                return try self.ownValue(span, .{ .color = quantizeColor(
                    color catch return self.invalidBuiltinArguments(span),
                    .nearest,
                ) catch return self.invalidBuiltinArguments(span) });
            }
            if (arguments.items.len != 1 or arguments.items[0].* != .color) return null;
            const color = arguments.items[0].color;
            if (nameEql(name, "luminosity")) {
                return try self.ownUnitlessNumber(span, colorLuminosity(color) catch
                    return self.invalidBuiltinArguments(span));
            }
            const channels = if (nameEql(name, "hue") or nameEql(name, "saturation") or
                nameEql(name, "lightness"))
                native_color.toHsl(color) catch return self.invalidBuiltinArguments(span)
            else
                native_color.toRgb(color) catch return self.invalidBuiltinArguments(span);
            const index: usize = if (nameEql(name, "red") or nameEql(name, "hue"))
                0
            else if (nameEql(name, "green") or nameEql(name, "saturation"))
                1
            else if (nameEql(name, "blue") or nameEql(name, "lightness"))
                2
            else
                3;
            if (nameEql(name, "hue")) return try self.ownNumberWithUnit(span, channels[index], "deg");
            if (nameEql(name, "saturation") or nameEql(name, "lightness")) {
                return try self.ownNumberWithUnit(span, channels[index], "%");
            }
            return try self.ownUnitlessNumber(span, channels[index]);
        }

        if (nameEql(name, "lighten") or nameEql(name, "darken") or
            nameEql(name, "saturate") or nameEql(name, "desaturate") or
            nameEql(name, "fade-in") or nameEql(name, "fade-out") or
            nameEql(name, "adjust-hue"))
        {
            if (arguments.items.len != 2 or arguments.items[0].* != .color) return null;
            const amount = if (nameEql(name, "fade-in") or nameEql(name, "fade-out"))
                alphaScalar(arguments.items[1].*) orelse return self.invalidBuiltinArguments(span)
            else
                numberScalar(arguments.items[1].*) orelse return self.invalidBuiltinArguments(span);
            var adjusted_amount = amount;
            if (arguments.items[1].* == .number and
                optionalUnitEqual(singleUnit(arguments.items[1].number), "%"))
            {
                const hsl_channels = native_color.toHsl(arguments.items[0].color) catch
                    return self.invalidBuiltinArguments(span);
                if (nameEql(name, "lighten")) adjusted_amount = (100 - hsl_channels[2]) * amount / 100;
                if (nameEql(name, "darken")) adjusted_amount = hsl_channels[2] * amount / 100;
                if (nameEql(name, "saturate") or nameEql(name, "desaturate")) {
                    adjusted_amount = hsl_channels[1] * amount / 100;
                }
            }
            const signed = if (nameEql(name, "darken") or nameEql(name, "desaturate") or
                nameEql(name, "fade-out")) -adjusted_amount else adjusted_amount;
            const color = if (nameEql(name, "lighten") or nameEql(name, "darken"))
                native_color.adjustLightness(arguments.items[0].color, signed)
            else if (nameEql(name, "saturate") or nameEql(name, "desaturate"))
                adjustStylusSaturation(arguments.items[0].color, signed)
            else if (nameEql(name, "adjust-hue"))
                native_color.adjustHue(arguments.items[0].color, signed)
            else
                native_color.adjustAlpha(arguments.items[0].color, signed);
            return try self.ownValue(span, .{ .color = quantizeColor(
                color catch return self.invalidBuiltinArguments(span),
                .nearest,
            ) catch return self.invalidBuiltinArguments(span) });
        }
        if (nameEql(name, "complement") or nameEql(name, "grayscale") or
            nameEql(name, "invert"))
        {
            if (arguments.items.len != 1 or arguments.items[0].* != .color) return null;
            const color = if (nameEql(name, "complement"))
                native_color.adjustHue(arguments.items[0].color, 180)
            else if (nameEql(name, "grayscale"))
                native_color.grayscale(arguments.items[0].color)
            else
                native_color.invert(arguments.items[0].color, 100);
            const resolved = color catch return self.invalidBuiltinArguments(span);
            return try self.ownValue(span, .{ .color = if (nameEql(name, "invert"))
                resolved
            else
                quantizeColor(resolved, .nearest) catch return self.invalidBuiltinArguments(span) });
        }
        if (nameEql(name, "mix") or nameEql(name, "tint") or nameEql(name, "shade")) {
            if (arguments.items.len < 1 or arguments.items.len > 3) return self.invalidBuiltinArguments(span);
            var first: native_value.Color = undefined;
            var second: native_value.Color = undefined;
            var weight: f64 = 50;
            if (nameEql(name, "mix")) {
                if (arguments.items.len < 2 or arguments.items[1].* != .color) {
                    return self.invalidBuiltinArguments(span);
                }
                if (arguments.items[0].* == .color) {
                    first = arguments.items[0].color;
                } else if (arguments.items[0].* == .list and arguments.items[0].list.items.len == 2 and
                    arguments.items[0].list.items[1] == .color)
                {
                    weight = percentScalar(arguments.items[0].list.items[0]) orelse
                        return self.invalidBuiltinArguments(span);
                    first = arguments.items[0].list.items[1].color;
                } else {
                    return self.invalidBuiltinArguments(span);
                }
                second = arguments.items[1].color;
                if (arguments.items.len == 3) weight = percentScalar(arguments.items[2].*) orelse
                    return self.invalidBuiltinArguments(span);
            } else {
                if (arguments.items[0].* != .color) return self.invalidBuiltinArguments(span);
                first = if (nameEql(name, "tint")) native_color.parseLiteral("white").? else native_color.parseLiteral("black").?;
                second = arguments.items[0].color;
                if (arguments.items.len >= 2) weight = percentScalar(arguments.items[1].*) orelse
                    return self.invalidBuiltinArguments(span);
            }
            const color = quantizeColor(
                native_color.mix(first, second, weight) catch return self.invalidBuiltinArguments(span),
                .down,
            ) catch return self.invalidBuiltinArguments(span);
            return try self.ownValue(span, .{ .color = color });
        }
        if (nameEql(name, "transparentify")) {
            if (arguments.items.len < 1 or arguments.items.len > 3 or
                arguments.items[0].* != .color)
            {
                return self.invalidBuiltinArguments(span);
            }
            var background = native_color.parseLiteral("white").?;
            var explicit_alpha: ?f64 = null;
            if (arguments.items.len == 2) {
                if (arguments.items[1].* == .color) {
                    background = arguments.items[1].color;
                } else {
                    explicit_alpha = alphaScalar(arguments.items[1].*) orelse
                        return self.invalidBuiltinArguments(span);
                }
            } else if (arguments.items.len == 3) {
                if (arguments.items[1].* != .color) {
                    return self.invalidBuiltinArguments(span);
                }
                background = arguments.items[1].color;
                explicit_alpha = alphaScalar(arguments.items[2].*) orelse
                    return self.invalidBuiltinArguments(span);
            }
            try self.transaction.consumeOperations(3);
            const color = stylusTransparentify(
                arguments.items[0].color,
                background,
                explicit_alpha,
            ) catch return self.invalidBuiltinArguments(span);
            return try self.ownValue(span, .{ .color = color });
        }
        if (nameEql(name, "blend")) {
            if (arguments.items.len < 1 or arguments.items.len > 2) return self.invalidBuiltinArguments(span);
            const foreground_color = colorValue(arguments.items[0].*) orelse return self.invalidBuiltinArguments(span);
            const foreground = native_color.toRgb(foreground_color) catch
                return self.invalidBuiltinArguments(span);
            const background_color = if (arguments.items.len == 2)
                colorValue(arguments.items[1].*) orelse return self.invalidBuiltinArguments(span)
            else
                native_color.parseLiteral("white").?;
            const background = native_color.toRgb(background_color) catch
                return self.invalidBuiltinArguments(span);
            const alpha = foreground[3];
            const color = native_color.rgb(
                foreground[0] * alpha + background[0] * (1 - alpha),
                foreground[1] * alpha + background[1] * (1 - alpha),
                foreground[2] * alpha + background[2] * (1 - alpha),
                alpha + background[3] * (1 - alpha),
            ) catch return self.invalidBuiltinArguments(span);
            return try self.ownValue(span, .{ .color = quantizeColor(color, .nearest) catch
                return self.invalidBuiltinArguments(span) });
        }
        if (nameEql(name, "light") or nameEql(name, "dark")) {
            if (arguments.items.len != 1 or arguments.items[0].* != .color) return self.invalidBuiltinArguments(span);
            const light = (colorLuminosity(arguments.items[0].color) catch
                return self.invalidBuiltinArguments(span)) >= 0.5;
            return try self.ownValue(span, .{ .boolean = if (nameEql(name, "light")) light else !light });
        }

        if (nameEql(name, "ceil") or nameEql(name, "floor") or nameEql(name, "round")) {
            if (arguments.items.len < 1 or arguments.items.len > 2 or arguments.items[0].* != .number) {
                return self.invalidBuiltinArguments(span);
            }
            var precision: i32 = 0;
            if (arguments.items.len == 2) {
                const raw_precision = integerScalar(arguments.items[1].*) orelse
                    return self.invalidBuiltinArguments(span);
                precision = std.math.cast(i32, raw_precision) orelse return self.invalidBuiltinArguments(span);
            }
            var number = arguments.items[0].number;
            const scale = std.math.pow(f64, 10, @floatFromInt(precision));
            const scaled = number.value * scale;
            number.value = (if (nameEql(name, "ceil")) @ceil(scaled) else if (nameEql(name, "floor")) @floor(scaled) else @round(scaled)) / scale;
            return try self.ownValue(span, .{ .number = number });
        }
        if (nameEql(name, "sin") or nameEql(name, "cos") or nameEql(name, "tan") or
            nameEql(name, "asin") or nameEql(name, "acos") or nameEql(name, "atan"))
        {
            if (arguments.items.len != 1 or arguments.items[0].* != .number) return self.invalidBuiltinArguments(span);
            const inverse = nameEql(name, "asin") or nameEql(name, "acos") or nameEql(name, "atan");
            const input = if (inverse)
                arguments.items[0].number.value
            else
                angleRadians(arguments.items[0].number) orelse return self.invalidBuiltinArguments(span);
            if (nameEql(name, "tan") and @abs(@cos(input)) < 0.000000000001) {
                return try self.ownValue(span, .{ .string = .{ .bytes = "Infinity" } });
            }
            const result = if (nameEql(name, "sin"))
                @sin(input)
            else if (nameEql(name, "cos"))
                @cos(input)
            else if (nameEql(name, "tan"))
                @tan(input)
            else if (nameEql(name, "asin"))
                std.math.radiansToDegrees(std.math.asin(input))
            else if (nameEql(name, "acos"))
                std.math.radiansToDegrees(std.math.acos(input))
            else
                std.math.radiansToDegrees(std.math.atan(input));
            if (inverse) {
                return try self.ownNumberWithUnit(span, roundDecimal(result, 9), "deg");
            }
            return try self.ownUnitlessNumber(span, roundDecimal(result, 9));
        }

        if (nameEql(name, "unit")) {
            if (arguments.items.len < 1 or arguments.items.len > 2 or arguments.items[0].* != .number) {
                return self.invalidBuiltinArguments(span);
            }
            if (arguments.items.len == 1) {
                const unit = singleUnit(arguments.items[0].number) orelse "";
                return try self.ownValue(span, .{ .string = .{ .bytes = unit, .quoted = true } });
            }
            const unit = stringBytes(arguments.items[1].*) orelse return self.invalidBuiltinArguments(span);
            return try self.ownNumberWithUnit(span, arguments.items[0].number.value, unit);
        }
        if (nameEql(name, "remove-unit")) {
            if (arguments.items.len != 1) return self.invalidBuiltinArguments(span);
            if (arguments.items[0].* != .number) return arguments.items[0];
            return try self.ownUnitlessNumber(span, arguments.items[0].number.value);
        }
        if (nameEql(name, "percentage")) {
            if (arguments.items.len != 1 or arguments.items[0].* != .number) return self.invalidBuiltinArguments(span);
            return try self.ownNumberWithUnit(span, arguments.items[0].number.value * 100, "%");
        }
        if (nameEql(name, "percent-to-decimal")) {
            if (arguments.items.len != 1 or arguments.items[0].* != .number) return self.invalidBuiltinArguments(span);
            const value = if (singleUnit(arguments.items[0].number)) |unit|
                if (std.mem.eql(u8, unit, "%")) arguments.items[0].number.value / 100 else arguments.items[0].number.value
            else
                arguments.items[0].number.value;
            return try self.ownUnitlessNumber(span, value);
        }

        if (nameEql(name, "first") or nameEql(name, "last")) {
            if (arguments.items.len != 1) return self.invalidBuiltinArguments(span);
            if (arguments.items[0].* != .list) return arguments.items[0];
            const list = arguments.items[0].list;
            if (list.items.len == 0) return try self.ownValue(span, .{ .null_value = {} });
            return try self.ownValue(span, if (nameEql(name, "first")) list.items[0] else list.items[list.items.len - 1]);
        }
        if (nameEql(name, "index")) {
            if (arguments.items.len != 2) return self.invalidBuiltinArguments(span);
            const haystack = arguments.items[0];
            if (haystack.* == .list) {
                for (haystack.list.items, 0..) |item, index| {
                    if (stylusValueEqual(item, arguments.items[1].*)) return try self.ownUnitlessNumber(span, @floatFromInt(index));
                }
            } else if (stylusValueEqual(haystack.*, arguments.items[1].*)) {
                return try self.ownUnitlessNumber(span, 0);
            }
            return try self.ownValue(span, .{ .null_value = {} });
        }
        if (nameEql(name, "list-separator")) {
            if (arguments.items.len != 1) return self.invalidBuiltinArguments(span);
            const separator: []const u8 = if (arguments.items[0].* == .list and arguments.items[0].list.separator == .comma) "," else " ";
            return try self.ownValue(span, .{ .string = .{ .bytes = separator, .quoted = true } });
        }
        if (nameEql(name, "keys") or nameEql(name, "values")) {
            if (arguments.items.len != 1 or arguments.items[0].* != .list) return self.invalidBuiltinArguments(span);
            var selected: std.ArrayList(native_value.Value) = .empty;
            defer selected.deinit(self.allocator);
            for (arguments.items[0].list.items) |entry| {
                if (entry != .list or entry.list.items.len < 2) return self.invalidBuiltinArguments(span);
                try selected.append(
                    self.allocator,
                    entry.list.items[if (nameEql(name, "keys")) 0 else 1],
                );
            }
            return try self.ownValue(span, .{ .list = .{ .items = selected.items, .separator = .space } });
        }
        if (nameEql(name, "range")) return try self.evaluateRangeBuiltin(span, arguments.items);
        if (nameEql(name, "opposite-position")) return try self.evaluateOppositeBuiltin(span, arguments.items);
        if (nameEql(name, "split") or nameEql(name, "substr") or nameEql(name, "slice") or
            nameEql(name, "join") or nameEql(name, "replace") or nameEql(name, "s") or
            nameEql(name, "unquote"))
        {
            return try self.evaluateStringBuiltin(span, name, arguments.items);
        }
        if (nameEql(name, "base-convert")) {
            if (arguments.items.len < 2 or arguments.items.len > 3) return self.invalidBuiltinArguments(span);
            const input = integerScalar(arguments.items[0].*) orelse return self.invalidBuiltinArguments(span);
            const base = integerScalar(arguments.items[1].*) orelse return self.invalidBuiltinArguments(span);
            const width: usize = if (arguments.items.len == 3)
                std.math.cast(usize, integerScalar(arguments.items[2].*) orelse return self.invalidBuiltinArguments(span)) orelse
                    return self.invalidBuiltinArguments(span)
            else
                0;
            if (input < 0 or base < 2 or base > 36) return self.invalidBuiltinArguments(span);
            var buffer: [128]u8 = undefined;
            const converted = baseConvert(@intCast(input), @intCast(base), &buffer) orelse
                return self.invalidBuiltinArguments(span);
            if (converted.len >= width) return try self.ownValue(span, .{ .string = .{ .bytes = converted } });
            try self.reserveTemporary(span, width);
            try self.transaction.consumeOperations(width);
            var padded: std.ArrayList(u8) = .empty;
            defer padded.deinit(self.allocator);
            try padded.ensureTotalCapacity(self.allocator, width);
            try padded.appendNTimes(self.allocator, '0', width - converted.len);
            padded.appendSliceAssumeCapacity(converted);
            return try self.ownValue(span, .{ .string = .{ .bytes = padded.items } });
        }
        return null;
    }

    fn evaluateImageSizeBuiltin(
        self: *Engine,
        span: native_source.Span,
        arguments: []const *const native_value.Value,
    ) Error!*const native_value.Value {
        if (arguments.len < 1 or arguments.len > 2 or arguments[0].* != .string) {
            return self.invalidBuiltinArguments(span);
        }
        const target = arguments[0].string.bytes;
        if (target.len == 0 or std.mem.indexOfAny(u8, target, "\x00\r\n?#") != null or
            hasNonLocalScheme(target))
        {
            try self.reportImageAssetRejected(span);
            return error.InvalidOperation;
        }

        var loaded = (try self.loadImageAsset(span, target)) orelse {
            if (arguments.len == 2) return self.imageSizeValue(span, .{ .width = 0, .height = 0 }, false);
            try self.transaction.report(
                .err,
                .invalid_operation,
                span,
                "native Stylus image asset was not found",
                &.{},
            );
            return error.InvalidOperation;
        };
        defer loaded.deinit();
        try self.transaction.consumeOperations(@intCast(loaded.contents.len));
        const dimensions = parseImageDimensions(loaded.contents) orelse {
            try self.transaction.report(
                .err,
                .invalid_operation,
                span,
                "native Stylus image asset is invalid",
                &.{},
            );
            return error.InvalidOperation;
        };
        return self.imageSizeValue(span, dimensions, true);
    }

    fn loadImageAsset(
        self: *Engine,
        span: native_source.Span,
        target: []const u8,
    ) Error!?native_resolver.Loaded {
        const source_file = try self.sources.get(span.source);
        const parent_path = native_resolver.fileUrlToPath(self.allocator, source_file.name) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        defer if (parent_path) |path| self.allocator.free(path);
        const ancestry: []const []const u8 = if (parent_path != null)
            &.{source_file.name}
        else
            &.{};

        if (parent_path) |path| {
            const parent_directory = std.fs.path.dirname(path) orelse {
                try self.reportImageAssetRejected(span);
                return error.InvalidOperation;
            };
            const candidate_url = assetCandidateUrl(
                self.allocator,
                parent_directory,
                target,
            ) catch |failure| return self.failImageCandidate(failure, span);
            defer self.allocator.free(candidate_url);
            if (try self.loadImageCandidate(candidate_url, ancestry, span)) |loaded| return loaded;
        }
        for (self.limits.asset_load_paths) |load_path| {
            const candidate_url = assetCandidateUrl(
                self.allocator,
                load_path,
                target,
            ) catch |failure| return self.failImageCandidate(failure, span);
            defer self.allocator.free(candidate_url);
            if (try self.loadImageCandidate(candidate_url, ancestry, span)) |loaded| return loaded;
        }
        return null;
    }

    fn loadImageCandidate(
        self: *Engine,
        candidate_url: []const u8,
        ancestry: []const []const u8,
        span: native_source.Span,
    ) Error!?native_resolver.Loaded {
        const session = try self.transaction.resolverSession();
        return session.load(candidate_url, .{
            .kind = .reference,
            .ancestry = ancestry,
        }) catch |failure| switch (failure) {
            error.Missing, error.IsDirectory => null,
            else => return self.failImageCandidate(failure, span),
        };
    }

    fn failImageCandidate(
        self: *Engine,
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
                self.reportResource(
                    span,
                    "native Stylus image asset resource limit exceeded",
                ) catch |err| return err;
                return failure;
            },
            else => {
                self.reportImageAssetRejected(span) catch |err| return err;
                return error.InvalidOperation;
            },
        }
    }

    fn reportImageAssetRejected(
        self: *Engine,
        span: native_source.Span,
    ) Error!void {
        try self.transaction.report(
            .err,
            .invalid_operation,
            span,
            "native Stylus image asset load was rejected",
            &.{},
        );
    }

    fn imageSizeValue(
        self: *Engine,
        span: native_source.Span,
        dimensions: ImageDimensions,
        pixels: bool,
    ) Error!*const native_value.Value {
        const units: []const []const u8 = if (pixels) &.{"px"} else &.{};
        const items = [_]native_value.Value{
            .{ .number = .{ .value = dimensions.width, .numerator_units = units } },
            .{ .number = .{ .value = dimensions.height, .numerator_units = units } },
        };
        return self.ownValue(span, .{ .list = .{
            .items = &items,
            .separator = .space,
            .truthy_override = if (pixels) null else false,
        } });
    }

    fn executeJsonStatement(
        self: *Engine,
        span: native_source.Span,
        raw_input: []const u8,
        scope: *native_environment.ScopeId,
    ) Error!bool {
        const raw = std.mem.trim(u8, raw_input, " \t\r\n\x0c;");
        const call = parseCall(raw) orelse return false;
        const name = raw[call.name.start..call.name.end];
        if (!nameEql(name, "json") or self.findCallable(name) != null) return false;

        var arguments = try self.evaluateCallArguments(span, raw, call, scope.*);
        defer arguments.deinit(self.allocator);
        if (arguments.items.len < 1 or arguments.items.len > 3 or
            arguments.items[0].* != .string)
        {
            return self.invalidBuiltinArguments(span);
        }
        if (arguments.items.len >= 2 and arguments.items[1].* == .map) {
            if (arguments.items.len != 2) return self.invalidBuiltinArguments(span);
            _ = try self.evaluateJsonBuiltin(span, arguments.items, scope.*);
            return true;
        }
        if (arguments.items.len >= 2 and arguments.items[1].* != .boolean) {
            return self.invalidBuiltinArguments(span);
        }
        if (arguments.items.len == 3 and arguments.items[2].* != .string) {
            return self.invalidBuiltinArguments(span);
        }

        const converted = try self.loadJsonValue(
            span,
            arguments.items[0].string.bytes,
            .{},
            scope.*,
        );
        if (converted.* != .map) return self.invalidJsonAsset(span);
        const local = arguments.items.len >= 2 and arguments.items[1].boolean;
        const target_scope = if (local)
            scope
        else
            self.global_scope orelse return error.InvalidDocument;
        const prefix = if (arguments.items.len == 3)
            arguments.items[2].string.bytes
        else
            "";
        try self.bindJsonVariables(span, target_scope, converted.map, prefix, local);
        return true;
    }

    fn evaluateJsonBuiltin(
        self: *Engine,
        span: native_source.Span,
        arguments: []const *const native_value.Value,
        scope: native_environment.ScopeId,
    ) Error!*const native_value.Value {
        if (arguments.len != 2 or arguments[0].* != .string or
            arguments[1].* != .map)
        {
            return self.invalidBuiltinArguments(span);
        }
        const options = try self.parseJsonOptions(span, arguments[1].map);
        return self.loadJsonValue(span, arguments[0].string.bytes, options, scope);
    }

    fn parseJsonOptions(
        self: *Engine,
        span: native_source.Span,
        map: native_value.Map,
    ) Error!JsonOptions {
        var options = JsonOptions{};
        var has_hash = false;
        for (map.entries) |entry| {
            if (entry.key != .string or entry.value != .boolean) {
                return self.invalidBuiltinArguments(span);
            }
            const key = entry.key.string.bytes;
            if (nameEql(key, "hash")) {
                if (has_hash or !entry.value.boolean) return self.invalidBuiltinArguments(span);
                has_hash = true;
            } else if (nameEql(key, "leave-strings")) {
                options.leave_strings = entry.value.boolean;
            } else if (nameEql(key, "optional")) {
                options.optional = entry.value.boolean;
            } else {
                return self.invalidBuiltinArguments(span);
            }
        }
        if (!has_hash) return self.invalidBuiltinArguments(span);
        return options;
    }

    fn loadJsonValue(
        self: *Engine,
        span: native_source.Span,
        target: []const u8,
        options: JsonOptions,
        scope: native_environment.ScopeId,
    ) Error!*const native_value.Value {
        if (target.len == 0 or std.mem.indexOfAny(u8, target, "\x00\r\n?#") != null or
            hasNonLocalScheme(target))
        {
            try self.reportJsonAssetRejected(span);
            return error.InvalidOperation;
        }

        var loaded = (try self.loadJsonAsset(span, target)) orelse {
            if (options.optional) return self.ownValue(span, .{ .null_value = {} });
            try self.transaction.report(
                .err,
                .invalid_operation,
                span,
                "native Stylus JSON asset was not found",
                &.{},
            );
            return error.InvalidOperation;
        };
        defer loaded.deinit();
        try self.transaction.consumeOperations(@intCast(loaded.contents.len));
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            loaded.contents,
            .{ .max_value_len = loaded.contents.len },
        ) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.invalidJsonAsset(span),
        };
        defer parsed.deinit();
        if (parsed.value != .object) return self.invalidJsonAsset(span);
        return self.convertJsonValue(span, parsed.value, options.leave_strings, scope, 0);
    }

    fn convertJsonValue(
        self: *Engine,
        span: native_source.Span,
        input: std.json.Value,
        leave_strings: bool,
        scope: native_environment.ScopeId,
        depth: u16,
    ) Error!*const native_value.Value {
        if (depth >= self.limits.max_expression_depth) {
            try self.reportExpressionDepth(span);
            return error.ExpressionDepthExceeded;
        }
        try self.transaction.consumeOperations(1);
        return switch (input) {
            .null => self.ownValue(span, .{ .null_value = {} }),
            .bool => |value| self.ownValue(span, .{ .boolean = value }),
            .integer => |value| self.ownUnitlessNumber(span, @floatFromInt(value)),
            .float => |value| if (std.math.isFinite(value))
                self.ownUnitlessNumber(span, value)
            else
                self.invalidJsonAsset(span),
            .number_string => |bytes| blk: {
                const value = std.fmt.parseFloat(f64, bytes) catch
                    return self.invalidJsonAsset(span);
                if (!std.math.isFinite(value)) return self.invalidJsonAsset(span);
                break :blk self.ownUnitlessNumber(span, value);
            },
            .string => |bytes| if (leave_strings)
                self.ownValue(span, .{ .string = .{ .bytes = bytes, .quoted = true } })
            else
                self.convertJsonString(span, bytes, scope, depth + 1),
            .array => self.unsupportedJsonArray(span),
            .object => |object| blk: {
                var entries: std.ArrayList(native_value.Entry) = .empty;
                defer entries.deinit(self.allocator);
                try entries.ensureTotalCapacity(self.allocator, object.count());
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    const value = try self.convertJsonValue(
                        span,
                        entry.value_ptr.*,
                        leave_strings,
                        scope,
                        depth + 1,
                    );
                    entries.appendAssumeCapacity(.{
                        .key = .{ .string = .{
                            .bytes = entry.key_ptr.*,
                            .quoted = true,
                        } },
                        .value = value.*,
                    });
                }
                break :blk self.ownValue(span, .{ .map = .{ .entries = entries.items } });
            },
        };
    }

    fn convertJsonString(
        self: *Engine,
        span: native_source.Span,
        bytes: []const u8,
        scope: native_environment.ScopeId,
        depth: u16,
    ) Error!*const native_value.Value {
        if (parseCall(bytes)) |call| {
            const name = bytes[call.name.start..call.name.end];
            if (nameEql(name, "rgb") or nameEql(name, "rgba") or
                nameEql(name, "hsl") or nameEql(name, "hsla"))
            {
                return (try self.evaluateBuiltin(span, bytes, call, scope)) orelse
                    self.invalidJsonAsset(span);
            }
        }
        return self.evaluateConvertedString(span, bytes, depth);
    }

    fn bindJsonVariables(
        self: *Engine,
        span: native_source.Span,
        scope: *native_environment.ScopeId,
        map: native_value.Map,
        prefix: []const u8,
        local: bool,
    ) Error!void {
        var name: std.ArrayList(u8) = .empty;
        defer name.deinit(self.allocator);
        try self.appendTemporary(&name, span, prefix);
        try self.bindJsonMap(span, scope, map, &name, prefix.len, local);
    }

    fn bindJsonMap(
        self: *Engine,
        span: native_source.Span,
        scope: *native_environment.ScopeId,
        map: native_value.Map,
        name: *std.ArrayList(u8),
        prefix_len: usize,
        local: bool,
    ) Error!void {
        for (map.entries) |entry| {
            if (entry.key != .string or entry.key.string.bytes.len == 0) {
                return self.invalidJsonAsset(span);
            }
            const checkpoint = name.items.len;
            defer name.shrinkRetainingCapacity(checkpoint);
            if (name.items.len > prefix_len) try self.appendTemporary(name, span, "-");
            try self.appendTemporary(name, span, entry.key.string.bytes);
            if (entry.value == .map) {
                try self.bindJsonMap(span, scope, entry.value.map, name, prefix_len, local);
                continue;
            }
            if (!validVariableName(name.items)) return self.invalidJsonAsset(span);
            if (local) try self.recordJsonLocalName(name.items);
            self.detachMutationAlias(name.items);
            scope.* = try self.setBinding(scope.*, name.items, try self.ownValue(span, entry.value), span);
        }
    }

    fn recordJsonLocalName(self: *Engine, name: []const u8) Error!void {
        for (self.json_local_names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.json_local_names.append(self.allocator, owned);
    }

    fn isJsonLocalName(self: *const Engine, name: []const u8) bool {
        for (self.json_local_names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return true;
        }
        return false;
    }

    fn loadJsonAsset(
        self: *Engine,
        span: native_source.Span,
        target: []const u8,
    ) Error!?native_resolver.Loaded {
        const source_file = try self.sources.get(span.source);
        const parent_path = native_resolver.fileUrlToPath(self.allocator, source_file.name) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        defer if (parent_path) |path| self.allocator.free(path);
        const ancestry: []const []const u8 = if (parent_path != null)
            &.{source_file.name}
        else
            &.{};

        if (parent_path) |path| {
            const parent_directory = std.fs.path.dirname(path) orelse {
                try self.reportJsonAssetRejected(span);
                return error.InvalidOperation;
            };
            const candidate_url = assetCandidateUrl(
                self.allocator,
                parent_directory,
                target,
            ) catch |failure| return self.failJsonCandidate(failure, span);
            defer self.allocator.free(candidate_url);
            if (try self.loadJsonCandidate(candidate_url, ancestry, span)) |loaded| return loaded;
        }
        for (self.limits.asset_load_paths) |load_path| {
            const candidate_url = assetCandidateUrl(
                self.allocator,
                load_path,
                target,
            ) catch |failure| return self.failJsonCandidate(failure, span);
            defer self.allocator.free(candidate_url);
            if (try self.loadJsonCandidate(candidate_url, ancestry, span)) |loaded| return loaded;
        }
        return null;
    }

    fn loadJsonCandidate(
        self: *Engine,
        candidate_url: []const u8,
        ancestry: []const []const u8,
        span: native_source.Span,
    ) Error!?native_resolver.Loaded {
        const session = try self.transaction.resolverSession();
        return session.load(candidate_url, .{
            .kind = .reference,
            .ancestry = ancestry,
        }) catch |failure| switch (failure) {
            error.Missing, error.IsDirectory => null,
            else => return self.failJsonCandidate(failure, span),
        };
    }

    fn failJsonCandidate(
        self: *Engine,
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
                self.reportResource(
                    span,
                    "native Stylus JSON asset resource limit exceeded",
                ) catch |err| return err;
                return failure;
            },
            else => {
                self.reportJsonAssetRejected(span) catch |err| return err;
                return error.InvalidOperation;
            },
        }
    }

    fn invalidJsonAsset(
        self: *Engine,
        span: native_source.Span,
    ) Error {
        self.transaction.report(
            .err,
            .invalid_operation,
            span,
            "native Stylus JSON asset is invalid",
            &.{},
        ) catch |failure| return failure;
        return error.InvalidOperation;
    }

    fn unsupportedJsonArray(
        self: *Engine,
        span: native_source.Span,
    ) Error {
        self.transaction.report(
            .err,
            .unsupported_feature,
            span,
            "native Stylus JSON arrays are unavailable",
            &.{},
        ) catch |failure| return failure;
        return error.UnsupportedFeature;
    }

    fn reportJsonAssetRejected(
        self: *Engine,
        span: native_source.Span,
    ) Error!void {
        try self.transaction.report(
            .err,
            .invalid_operation,
            span,
            "native Stylus JSON asset load was rejected",
            &.{},
        );
    }

    fn executeDefineStatement(
        self: *Engine,
        span: native_source.Span,
        raw_input: []const u8,
        scope: *native_environment.ScopeId,
    ) Error!bool {
        const raw = std.mem.trim(u8, raw_input, " \t\r\n\x0c;");
        const call = parseCall(raw) orelse parseBareCall(raw) orelse return false;
        const name = raw[call.name.start..call.name.end];
        if (!nameEql(name, "define") or self.findCallable(name) != null) return false;

        var arguments = try self.evaluateCallArguments(span, raw, call, scope.*);
        defer arguments.deinit(self.allocator);
        if (arguments.items.len < 2 or arguments.items.len > 3) {
            return self.invalidBuiltinArguments(span);
        }

        const global = arguments.items.len == 3 and isTruthy(arguments.items[2]);
        try self.bindDefinedValue(
            span,
            scope,
            arguments.items[0],
            arguments.items[1],
            global,
        );
        return true;
    }

    fn executeDefineObjectStatement(
        self: *Engine,
        statement_id: native_syntax.NodeId,
        span: native_source.Span,
        scope: *native_environment.ScopeId,
    ) Error!bool {
        const raw = std.mem.trim(
            u8,
            try self.sources.slice(span),
            " \t\r\n\x0c;",
        );
        if (raw.len < "define(, {".len or !isNameStart(raw, 0) or
            raw[raw.len - 1] != '{')
        {
            return false;
        }
        const name_end = nameEnd(raw, 0);
        if (!nameEql(raw[0..name_end], "define") or
            self.findCallable(raw[0..name_end]) != null)
        {
            return false;
        }
        var opening = name_end;
        while (opening < raw.len and std.ascii.isWhitespace(raw[opening])) opening += 1;
        if (opening >= raw.len or raw[opening] != '(') return false;
        const prefix = std.mem.trim(
            u8,
            raw[opening + 1 .. raw.len - 1],
            " \t\r\n\x0c",
        );
        const comma = findTopLevelScalar(prefix, ',') orelse return false;
        if (std.mem.trim(u8, prefix[comma + 1 ..], " \t\r\n\x0c").len != 0) {
            return false;
        }
        const name_raw = std.mem.trim(u8, prefix[0..comma], " \t\r\n\x0c");
        if (name_raw.len == 0) return self.invalidBuiltinArguments(span);
        const binding_name = try self.evaluateValue(span, name_raw, scope.*, 0);
        const object = try self.evaluateObjectBlock(statement_id, scope.*);
        try self.bindDefinedValue(span, scope, binding_name, object, false);
        return true;
    }

    fn bindDefinedValue(
        self: *Engine,
        span: native_source.Span,
        scope: *native_environment.ScopeId,
        name: *const native_value.Value,
        value: *const native_value.Value,
        global: bool,
    ) Error!void {
        if (name.* != .string or !name.string.quoted or
            !validVariableName(name.string.bytes))
        {
            return self.invalidBuiltinArguments(span);
        }
        const binding_name = name.string.bytes;
        if (global) {
            const global_scope = self.global_scope orelse return error.InvalidDocument;
            if (!(try self.environment.update(
                global_scope.*,
                binding_name,
                value,
            ))) {
                global_scope.* = try self.setBinding(
                    global_scope.*,
                    binding_name,
                    value,
                    span,
                );
            }
        } else {
            self.detachMutationAlias(binding_name);
            scope.* = try self.setBinding(
                scope.*,
                binding_name,
                value,
                span,
            );
        }
    }

    fn evaluateAddPropertyBuiltin(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        call: Call,
        scope: native_environment.ScopeId,
    ) Error!*const native_value.Value {
        const destination = self.active_output orelse return self.invalidBuiltinArguments(span);
        var arguments = try self.evaluateCallArguments(span, raw, call, scope);
        defer arguments.deinit(self.allocator);
        if (arguments.items.len != 2) return self.invalidBuiltinArguments(span);
        const property_bytes = stringBytes(arguments.items[0].*) orelse
            return self.invalidBuiltinArguments(span);
        if (property_bytes.len == 0) return self.invalidBuiltinArguments(span);

        const property = try self.allocator.dupe(u8, property_bytes);
        const value = self.serializeValueOwned(arguments.items[1], .value, span) catch |failure| {
            self.allocator.free(property);
            return failure;
        };
        destination.declarations.append(self.allocator, .{
            .span = span,
            .property = property,
            .value = value,
            .semantic_value = arguments.items[1],
            .side_effect = true,
        }) catch |failure| {
            self.allocator.free(property);
            self.allocator.free(value);
            return failure;
        };
        return self.ownValue(span, .{ .null_value = {} });
    }

    fn currentPropertyValue(
        self: *Engine,
        span: native_source.Span,
        _: native_environment.ScopeId,
    ) Error!?*const native_value.Value {
        const property = self.active_property orelse return null;
        if (self.active_property_value) |value| return value;
        const source_value = try self.sources.slice(property.value_span);
        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(self.allocator);
        if (self.active_property_call_span) |call_span| {
            if (call_span.source.value != property.value_span.source.value or
                call_span.start < property.value_span.start or
                call_span.end > property.value_span.end)
            {
                return error.InvalidDocument;
            }
            const start: usize = @intCast(call_span.start - property.value_span.start);
            const end: usize = @intCast(call_span.end - property.value_span.start);
            try self.appendTemporary(&normalized, span, source_value[0..start]);
            try self.appendTemporary(&normalized, span, "__CALL__");
            try self.appendTemporary(&normalized, span, source_value[end..]);
        } else {
            try self.appendTemporary(&normalized, span, source_value);
        }

        const previous_property = self.active_property;
        self.active_property = null;
        defer self.active_property = previous_property;
        const property_value = try self.ownValue(span, .{ .string = .{
            .bytes = property.property,
            .quoted = true,
        } });
        const expression_value = try self.evaluateValue(
            span,
            normalized.items,
            property.scope,
            0,
        );
        const items = [_]native_value.Value{ property_value.*, expression_value.* };
        const value = try self.ownValue(span, .{ .list = .{
            .items = &items,
            .separator = .space,
        } });
        self.active_property_value = value;
        return value;
    }

    fn evaluateMutationBuiltin(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        call: Call,
        scope: native_environment.ScopeId,
        name: []const u8,
    ) Error!*const native_value.Value {
        var ranges = try splitTopLevel(self.allocator, raw[call.arguments.start..call.arguments.end], ',');
        defer ranges.deinit(self.allocator);
        if (ranges.items.len == 0) return self.invalidBuiltinArguments(span);
        const variable = std.mem.trim(
            u8,
            raw[call.arguments.start + ranges.items[0].start .. call.arguments.start + ranges.items[0].end],
            " \t\r\n\x0c",
        );
        if (!validVariableName(variable)) return self.invalidBuiltinArguments(span);
        const current = (try self.lookupBinding(scope, variable)) orelse
            return self.invalidBuiltinArguments(span);
        var values: std.ArrayList(native_value.Value) = .empty;
        defer values.deinit(self.allocator);
        if (current.* == .list) try values.appendSlice(self.allocator, current.list.items) else if (current.* != .null_value) try values.append(self.allocator, current.*);

        const remove = nameEql(name, "pop") or nameEql(name, "shift");
        if (remove) {
            if (ranges.items.len != 1) return self.invalidBuiltinArguments(span);
            const removed = if (values.items.len == 0)
                try self.ownValue(span, .{ .null_value = {} })
            else if (nameEql(name, "shift"))
                try self.ownValue(span, values.orderedRemove(0))
            else
                try self.ownValue(span, values.pop().?);
            const replacement = try self.ownValue(span, .{ .list = .{
                .items = values.items,
                .separator = if (current.* == .list) current.list.separator else .space,
            } });
            if (!(try self.updateMutationBinding(scope, variable, replacement))) {
                return self.invalidBuiltinArguments(span);
            }
            return removed;
        }

        if (ranges.items.len < 2) return self.invalidBuiltinArguments(span);
        var additions: std.ArrayList(native_value.Value) = .empty;
        defer additions.deinit(self.allocator);
        for (ranges.items[1..]) |range| {
            const argument = try self.evaluateValue(
                span,
                raw[call.arguments.start + range.start .. call.arguments.start + range.end],
                scope,
                0,
            );
            if ((nameEql(name, "append") or nameEql(name, "prepend")) and argument.* == .list) {
                try additions.appendSlice(self.allocator, argument.list.items);
            } else {
                try additions.append(self.allocator, argument.*);
            }
        }
        if (nameEql(name, "prepend") or nameEql(name, "unshift")) {
            var combined: std.ArrayList(native_value.Value) = .empty;
            defer combined.deinit(self.allocator);
            var addition_index = additions.items.len;
            while (addition_index > 0) {
                addition_index -= 1;
                try combined.append(self.allocator, additions.items[addition_index]);
            }
            try combined.appendSlice(self.allocator, values.items);
            values.clearRetainingCapacity();
            try values.appendSlice(self.allocator, combined.items);
        } else {
            try values.appendSlice(self.allocator, additions.items);
        }
        const replacement = try self.ownValue(span, .{ .list = .{
            .items = values.items,
            .separator = if (current.* == .list) current.list.separator else .space,
        } });
        if (!(try self.updateMutationBinding(scope, variable, replacement))) {
            return self.invalidBuiltinArguments(span);
        }
        return self.ownUnitlessNumber(span, @floatFromInt(values.items.len));
    }

    fn updateMutationBinding(
        self: *Engine,
        scope: native_environment.ScopeId,
        name: []const u8,
        replacement: *const native_value.Value,
    ) Error!bool {
        const original = (try self.lookupBinding(scope, name)) orelse return false;
        if (!(try self.updateBinding(scope, name, replacement))) return false;
        var index = self.mutation_aliases.items.len;
        while (index > 0) {
            index -= 1;
            const alias = self.mutation_aliases.items[index];
            if (!std.mem.eql(u8, alias.local_name, name)) continue;
            switch (alias.target) {
                .binding => |binding| {
                    const target_original = try self.lookupBinding(
                        binding.scope,
                        binding.name,
                    );
                    _ = try self.updateBinding(binding.scope, binding.name, replacement);
                    if (target_original) |target| {
                        try self.propagateMapBindingAliases(target, replacement);
                    }
                },
                .current_property_index => |property_index| {
                    if (!(try self.updateCurrentPropertyIndex(property_index, replacement))) {
                        return false;
                    }
                },
            }
            break;
        }
        try self.propagateMapBindingAliases(original, replacement);
        return true;
    }

    fn evaluateMergeBuiltin(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        call: Call,
        scope: native_environment.ScopeId,
    ) Error!*const native_value.Value {
        var ranges = try splitTopLevel(
            self.allocator,
            raw[call.arguments.start..call.arguments.end],
            ',',
        );
        defer ranges.deinit(self.allocator);
        if (call.arguments.start == call.arguments.end) ranges.clearRetainingCapacity();
        if (ranges.items.len == 0) return self.invalidBuiltinArguments(span);

        var arguments = try self.evaluateCallArguments(span, raw, call, scope);
        defer arguments.deinit(self.allocator);
        if (arguments.items[0].* != .map) return self.invalidBuiltinArguments(span);

        const has_recursive_flag = arguments.items.len > 1 and
            arguments.items[arguments.items.len - 1].* == .boolean;
        const recursive = has_recursive_flag and
            arguments.items[arguments.items.len - 1].boolean;
        const source_end = arguments.items.len - @intFromBool(has_recursive_flag);
        var merged = arguments.items[0];
        for (arguments.items[1..source_end]) |source_value| {
            if (source_value.* != .map) return self.invalidBuiltinArguments(span);
            merged = try self.mergeMaps(
                span,
                merged.map,
                source_value.map,
                recursive,
                0,
            );
        }

        const destination_range = ranges.items[0];
        const destination_name = std.mem.trim(
            u8,
            raw[call.arguments.start + destination_range.start .. call.arguments.start + destination_range.end],
            " \t\r\n\x0c",
        );
        if (validVariableName(destination_name) and
            !(try self.updateMutationBinding(scope, destination_name, merged)))
        {
            return self.invalidBuiltinArguments(span);
        }
        return merged;
    }

    fn mergeMaps(
        self: *Engine,
        span: native_source.Span,
        destination: native_value.Map,
        source_map: native_value.Map,
        recursive: bool,
        depth: u16,
    ) Error!*const native_value.Value {
        if (depth >= self.limits.values.max_depth) {
            try self.reportResource(span, "native Stylus value limit exceeded");
            return error.ValueDepthExceeded;
        }
        var entries: std.ArrayList(native_value.Entry) = .empty;
        defer entries.deinit(self.allocator);
        try entries.appendSlice(self.allocator, destination.entries);
        for (source_map.entries) |source_entry| {
            try self.transaction.consumeOperations(1);
            var existing: ?usize = null;
            for (entries.items, 0..) |entry, entry_index| {
                if (stylusValueEqual(entry.key, source_entry.key)) existing = entry_index;
            }
            if (existing) |entry_index| {
                const prior = entries.items[entry_index];
                entries.items[entry_index].value = if (recursive and
                    prior.value == .map and source_entry.value == .map)
                    (try self.mergeMaps(
                        span,
                        prior.value.map,
                        source_entry.value.map,
                        true,
                        depth + 1,
                    )).*
                else
                    source_entry.value;
                continue;
            }
            if (entries.items.len >= self.limits.values.max_collection_items) {
                try self.reportResource(span, "native Stylus value limit exceeded");
                return error.ValueLimitExceeded;
            }
            try entries.append(self.allocator, source_entry);
        }
        return self.ownValue(span, .{ .map = .{ .entries = entries.items } });
    }

    fn registerMapBindingAlias(
        self: *Engine,
        scope: native_environment.ScopeId,
        left: []const u8,
        right: []const u8,
        span: native_source.Span,
    ) Error!void {
        if (std.mem.eql(u8, left, right)) return;
        for ([_]BindingReference{
            .{ .scope = scope, .name = left },
            .{ .scope = scope, .name = right },
        }) |reference| {
            const reference_value = try self.lookupBinding(reference.scope, reference.name);
            var registered = false;
            for (self.map_binding_aliases.items) |existing| {
                if (!std.mem.eql(u8, existing.name, reference.name)) continue;
                if (existing.scope.value == reference.scope.value) {
                    registered = true;
                    break;
                }
                const existing_value = try self.lookupBinding(existing.scope, existing.name);
                if (reference_value != null and existing_value == reference_value) {
                    registered = true;
                    break;
                }
            }
            if (registered) continue;
            if (self.map_binding_aliases.items.len >= self.limits.max_nodes) {
                try self.reportResource(span, "native Stylus evaluator node limit exceeded");
                return error.NodeLimitExceeded;
            }
            try self.map_binding_aliases.append(self.allocator, reference);
        }
    }

    fn detachMapBindingAliases(
        self: *Engine,
        scope: native_environment.ScopeId,
        name: []const u8,
    ) Error!void {
        const current = try self.lookupBinding(scope, name);
        if (current == null) return;
        var index = self.map_binding_aliases.items.len;
        while (index > 0) {
            index -= 1;
            const reference = self.map_binding_aliases.items[index];
            if (!std.mem.eql(u8, reference.name, name)) continue;
            const value = try self.lookupBinding(reference.scope, reference.name);
            if (value != null and value.? == current.?) {
                _ = self.map_binding_aliases.orderedRemove(index);
            }
        }
    }

    fn propagateMapBindingAliases(
        self: *Engine,
        original: *const native_value.Value,
        replacement: *const native_value.Value,
    ) Error!void {
        if (original.* != .map or replacement.* != .map) return;
        for (self.map_binding_aliases.items) |reference| {
            const current = try self.lookupBinding(reference.scope, reference.name);
            if (current != null and current.? == original) {
                _ = try self.updateBinding(
                    reference.scope,
                    reference.name,
                    replacement,
                );
            }
        }
    }

    fn updateCurrentPropertyIndex(
        self: *Engine,
        index: usize,
        replacement: *const native_value.Value,
    ) Error!bool {
        const current = self.active_property_value orelse return false;
        const property = self.active_property orelse return false;
        if (current.* != .list or index >= current.list.items.len) return false;
        var items: std.ArrayList(native_value.Value) = .empty;
        defer items.deinit(self.allocator);
        try items.appendSlice(self.allocator, current.list.items);
        items.items[index] = replacement.*;
        const updated = try self.ownValue(property.value_span, .{ .list = .{
            .items = items.items,
            .separator = current.list.separator,
            .bracketed = current.list.bracketed,
        } });
        self.active_property_value = updated;
        for (self.current_property_bindings.items) |binding| {
            _ = try self.environment.update(binding.scope, binding.name, updated);
        }
        return true;
    }

    fn detachMutationAlias(self: *Engine, name: []const u8) void {
        var index = self.mutation_aliases.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.mutation_aliases.items[index].local_name, name)) {
                _ = self.mutation_aliases.orderedRemove(index);
                return;
            }
        }
    }

    fn evaluateCallArguments(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        call: Call,
        scope: native_environment.ScopeId,
    ) Error!std.ArrayList(*const native_value.Value) {
        var output: std.ArrayList(*const native_value.Value) = .empty;
        errdefer output.deinit(self.allocator);
        var ranges = try splitTopLevel(self.allocator, raw[call.arguments.start..call.arguments.end], ',');
        defer ranges.deinit(self.allocator);
        if (call.arguments.start == call.arguments.end) ranges.clearRetainingCapacity();
        try output.ensureTotalCapacity(self.allocator, ranges.items.len);
        for (ranges.items) |range| {
            const argument = std.mem.trim(
                u8,
                raw[call.arguments.start + range.start .. call.arguments.start + range.end],
                " \t\r\n\x0c",
            );
            if (argument.len == 0) {
                try self.reportInvalidArguments(span);
                return error.InvalidArguments;
            }
            output.appendAssumeCapacity(try self.evaluateValue(span, argument, scope, 0));
        }
        return output;
    }

    fn evaluateSelectorBuiltin(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        call: Call,
        scope: native_environment.ScopeId,
    ) Error!*const native_value.Value {
        var arguments = try self.evaluateCallArguments(span, raw, call, scope);
        defer arguments.deinit(self.allocator);
        if (arguments.items.len == 0) {
            return self.ownStringResult(
                span,
                self.active_selector_identity orelse self.active_rule_selector orelse "&",
                true,
            );
        }

        if (arguments.items.len == 1 and
            (arguments.items[0].* == .string or arguments.items[0].* == .selector))
        {
            const string = switch (arguments.items[0].*) {
                .string => |value| value,
                .selector => |value| value,
                else => unreachable,
            };
            if (!selectorStringNeedsStack(string.bytes)) {
                return self.ownStringResult(span, string.bytes, true);
            }
        }

        var parts: std.ArrayList([]u8) = .empty;
        defer {
            for (parts.items) |part| self.allocator.free(part);
            parts.deinit(self.allocator);
        }
        if (arguments.items.len == 1 and arguments.items[0].* == .list) {
            const list = arguments.items[0].list;
            if (list.items.len == 0) return self.invalidBuiltinArguments(span);
            if (list.separator == .comma) {
                for (list.items) |*item| {
                    try self.appendSelectorArgumentPart(span, &parts, item);
                }
            } else {
                var joined: std.ArrayList(u8) = .empty;
                defer joined.deinit(self.allocator);
                for (list.items, 0..) |*item, index| {
                    const bytes = selectorArgumentBytes(item) orelse
                        return self.invalidBuiltinArguments(span);
                    if (index > 0) try self.appendTemporary(&joined, span, " ");
                    try self.appendTemporary(&joined, span, bytes);
                }
                const owned = try joined.toOwnedSlice(self.allocator);
                parts.append(self.allocator, owned) catch |failure| {
                    self.allocator.free(owned);
                    return failure;
                };
            }
        } else {
            for (arguments.items) |argument| {
                const item = if (argument.* == .list and argument.list.items.len > 0)
                    &argument.list.items[0]
                else
                    argument;
                try self.appendSelectorArgumentPart(span, &parts, item);
            }
        }
        if (parts.items.len == 0) return self.invalidBuiltinArguments(span);

        const compiled = try self.compileSelectorPartsOwned(span, parts.items);
        defer self.allocator.free(compiled);
        return self.ownStringResult(span, compiled, true);
    }

    fn evaluateSelectorExistsBuiltin(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        call: Call,
        scope: native_environment.ScopeId,
    ) Error!*const native_value.Value {
        var ranges = try splitTopLevel(
            self.allocator,
            raw[call.arguments.start..call.arguments.end],
            ',',
        );
        defer ranges.deinit(self.allocator);
        if (call.arguments.start == call.arguments.end) ranges.clearRetainingCapacity();
        if (ranges.items.len != 1) return self.invalidBuiltinArguments(span);

        const range = ranges.items[0];
        const argument = std.mem.trim(
            u8,
            raw[call.arguments.start + range.start .. call.arguments.start + range.end],
            " \t\r\n\x0c",
        );
        if (argument.len == 0) return self.invalidBuiltinArguments(span);

        var rendered_query: ?[]u8 = null;
        defer if (rendered_query) |owned| self.allocator.free(owned);
        const query = if (argument.len >= 2 and
            (argument[0] == '\'' or argument[0] == '"') and
            closingQuote(argument, 0) == argument.len - 1)
        blk: {
            const value = try self.evaluateValue(span, argument, scope, 0);
            break :blk stringBytes(value.*) orelse
                return self.invalidBuiltinArguments(span);
        } else if (validVariableName(argument) and
            try self.lookupBinding(scope, argument) != null)
        blk: {
            const value = try self.evaluateValue(span, argument, scope, 0);
            break :blk stringBytes(value.*) orelse
                return self.invalidBuiltinArguments(span);
        } else blk: {
            const rendered = try self.renderRawOwned(span, argument, scope, .selector, 0);
            rendered_query = rendered;
            const trimmed = std.mem.trim(u8, rendered, " \t\r\n\x0c");
            if (!selectorExistsQueryIsStringLike(trimmed)) {
                return self.invalidBuiltinArguments(span);
            }
            break :blk trimmed;
        };
        if (query.len == 0) return self.invalidBuiltinArguments(span);
        try self.transaction.consumeOperations(1);
        return self.ownValue(span, .{ .boolean = self.selector_identities.contains(query) });
    }

    fn registerSelectorIdentities(
        self: *Engine,
        span: native_source.Span,
        selector: []const u8,
    ) Error!void {
        var branches = try splitTopLevel(self.allocator, selector, ',');
        defer branches.deinit(self.allocator);
        for (branches.items) |range| {
            const identity = std.mem.trim(
                u8,
                selector[range.start..range.end],
                " \t\r\n\x0c",
            );
            if (identity.len == 0) continue;
            if (self.selector_identities.contains(identity)) continue;
            if (self.selector_identity_storage.items.len >= self.limits.max_selectors) {
                try self.reportSelectorLimit(span);
                return error.SelectorLimitExceeded;
            }
            const owned = try self.allocator.dupe(u8, identity);
            self.selector_identity_storage.append(self.allocator, owned) catch |failure| {
                self.allocator.free(owned);
                return failure;
            };
            self.selector_identities.put(self.allocator, owned, {}) catch |failure| {
                self.allocator.free(self.selector_identity_storage.pop().?);
                return failure;
            };
        }
    }

    fn appendSelectorArgumentPart(
        self: *Engine,
        span: native_source.Span,
        parts: *std.ArrayList([]u8),
        argument: *const native_value.Value,
    ) Error!void {
        const bytes = selectorArgumentBytes(argument) orelse
            return self.invalidBuiltinArguments(span);
        try self.reserveTemporary(span, bytes.len);
        try self.transaction.consumeOperations(@intCast(bytes.len));
        const owned = try self.allocator.dupe(u8, bytes);
        parts.append(self.allocator, owned) catch |failure| {
            self.allocator.free(owned);
            return failure;
        };
    }

    fn compileSelectorPartsOwned(
        self: *Engine,
        span: native_source.Span,
        parts: []const []u8,
    ) Error![]u8 {
        const original_part_count = self.selector_parts.items.len;
        defer while (self.selector_parts.items.len > original_part_count) {
            self.allocator.free(self.selector_parts.pop().?);
        };

        var current: ?[]u8 = if (self.active_selector_identity) |selector|
            try self.allocator.dupe(u8, selector)
        else
            null;
        errdefer if (current) |owned| self.allocator.free(owned);
        for (parts) |part| {
            const nested = current != null;
            const combined = try self.combineSelectors(current, part, span);
            if (current) |owned| self.allocator.free(owned);
            current = combined;

            const stack_part = try self.selectorPartOwned(span, part, nested);
            self.selector_parts.append(self.allocator, stack_part) catch |failure| {
                self.allocator.free(stack_part);
                return failure;
            };
        }
        return current orelse self.allocator.dupe(u8, "&");
    }

    fn evaluateJoinCallArguments(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        call: Call,
        scope: native_environment.ScopeId,
    ) Error!std.ArrayList(*const native_value.Value) {
        var output: std.ArrayList(*const native_value.Value) = .empty;
        errdefer output.deinit(self.allocator);
        var ranges = try splitTopLevel(self.allocator, raw[call.arguments.start..call.arguments.end], ',');
        defer ranges.deinit(self.allocator);
        if (call.arguments.start == call.arguments.end) ranges.clearRetainingCapacity();
        try output.ensureTotalCapacity(self.allocator, ranges.items.len);
        for (ranges.items, 0..) |range, index| {
            const argument = std.mem.trim(
                u8,
                raw[call.arguments.start + range.start .. call.arguments.start + range.end],
                " \t\r\n\x0c",
            );
            if (argument.len == 0) {
                try self.reportInvalidArguments(span);
                return error.InvalidArguments;
            }
            if (index == 0) {
                output.appendAssumeCapacity(try self.evaluateValue(span, argument, scope, 0));
                continue;
            }

            var space_items = try splitTopLevelWhitespace(self.allocator, argument);
            defer space_items.deinit(self.allocator);
            const value = if (space_items.items.len > 1 and !joinArgumentIsOperation(argument))
                try self.evaluateList(span, argument, space_items.items, .space, scope, 0)
            else
                try self.evaluateValue(span, argument, scope, 0);
            output.appendAssumeCapacity(value);
        }
        return output;
    }

    fn evaluateMatchArguments(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        call: Call,
        scope: native_environment.ScopeId,
    ) Error!std.ArrayList(*const native_value.Value) {
        var output: std.ArrayList(*const native_value.Value) = .empty;
        errdefer output.deinit(self.allocator);
        var ranges = try splitTopLevel(self.allocator, raw[call.arguments.start..call.arguments.end], ',');
        defer ranges.deinit(self.allocator);
        if (call.arguments.start == call.arguments.end) ranges.clearRetainingCapacity();
        try output.ensureTotalCapacity(self.allocator, ranges.items.len);
        for (ranges.items, 0..) |range, index| {
            const argument = std.mem.trim(
                u8,
                raw[call.arguments.start + range.start .. call.arguments.start + range.end],
                " \t\r\n\x0c",
            );
            if (argument.len == 0) return self.invalidBuiltinArguments(span);
            if (index == 0 and argument.len >= 2 and
                (argument[0] == '\'' or argument[0] == '"') and
                closingQuote(argument, 0) == argument.len - 1)
            {
                output.appendAssumeCapacity(try self.ownValue(span, .{ .string = .{
                    .bytes = argument[1 .. argument.len - 1],
                    .quoted = true,
                } }));
            } else {
                output.appendAssumeCapacity(try self.evaluateValue(span, argument, scope, 0));
            }
        }
        return output;
    }

    fn evaluateOperateBuiltin(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        call: Call,
        scope: native_environment.ScopeId,
    ) Error!*const native_value.Value {
        var ranges = try splitTopLevel(self.allocator, raw[call.arguments.start..call.arguments.end], ',');
        defer ranges.deinit(self.allocator);
        if (ranges.items.len != 3) return self.invalidBuiltinArguments(span);
        var arguments: [3][]const u8 = undefined;
        for (ranges.items, 0..) |range, index| {
            arguments[index] = std.mem.trim(
                u8,
                raw[call.arguments.start + range.start .. call.arguments.start + range.end],
                " \t\r\n\x0c",
            );
            if (arguments[index].len == 0) return self.invalidBuiltinArguments(span);
        }
        const operation = if (parseGenericTernary(arguments[0])) |ternary| blk: {
            const condition = arguments[0][ternary.condition.start..ternary.condition.end];
            const selected = if (try self.evaluateCondition(span, condition, scope))
                ternary.when_true
            else
                ternary.when_false;
            break :blk try self.evaluateValue(
                span,
                arguments[0][selected.start..selected.end],
                scope,
                0,
            );
        } else try self.evaluateValue(span, arguments[0], scope, 0);
        if (operation.* != .string or !operation.string.quoted or operation.string.bytes.len != 1 or
            std.mem.indexOfScalar(u8, "+-*/%", operation.string.bytes[0]) == null)
        {
            return self.invalidBuiltinArguments(span);
        }
        const left = try self.evaluateValue(span, arguments[1], scope, 0);
        const right = try self.evaluateValue(span, arguments[2], scope, 0);
        return self.evaluateGenericBinary(span, left, right, operation.string.bytes[0]);
    }

    fn invalidBuiltinArguments(self: *Engine, span: native_source.Span) Error {
        self.reportInvalidArguments(span) catch |failure| return failure;
        return error.InvalidArguments;
    }

    fn ownUnitlessNumber(self: *Engine, span: native_source.Span, value: f64) Error!*const native_value.Value {
        const numeric = native_numeric.Numeric.init(value, null) catch return error.InvalidOperation;
        var numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
        var denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
        return self.ownValue(span, .{ .number = numeric.toNumber(&numerator, &denominator) catch return error.InvalidOperation });
    }

    fn ownNumberWithUnit(
        self: *Engine,
        span: native_source.Span,
        value: f64,
        unit: []const u8,
    ) Error!*const native_value.Value {
        if (unit.len == 0) return self.ownUnitlessNumber(span, value);
        const units = [1][]const u8{unit};
        return self.ownValue(span, .{ .number = .{ .value = value, .numerator_units = &units } });
    }

    fn evaluateRangeBuiltin(
        self: *Engine,
        span: native_source.Span,
        arguments: []const *const native_value.Value,
    ) Error!*const native_value.Value {
        if (arguments.len < 2 or arguments.len > 3 or arguments[0].* != .number or arguments[1].* != .number) {
            return self.invalidBuiltinArguments(span);
        }
        const unit = singleUnit(arguments[0].number);
        if (!optionalUnitEqual(unit, singleUnit(arguments[1].number))) return self.invalidBuiltinArguments(span);
        const step: f64 = if (arguments.len == 3) blk: {
            if (arguments[2].* != .number or !optionalUnitEqual(unit, singleUnit(arguments[2].number))) {
                return self.invalidBuiltinArguments(span);
            }
            break :blk arguments[2].number.value;
        } else if (arguments[0].number.value <= arguments[1].number.value) 1 else -1;
        if (step == 0) return self.invalidBuiltinArguments(span);
        var values: std.ArrayList(native_value.Value) = .empty;
        defer values.deinit(self.allocator);
        var current = arguments[0].number.value;
        while ((step > 0 and current <= arguments[1].number.value) or
            (step < 0 and current >= arguments[1].number.value))
        {
            if (values.items.len >= self.limits.max_loop_iterations) {
                try self.transaction.report(
                    .err,
                    .loop_limit,
                    span,
                    "native Stylus loop iteration limit exceeded",
                    &.{},
                );
                return error.LoopLimitExceeded;
            }
            const item = if (unit) |item_unit|
                try self.ownNumberWithUnit(span, current, item_unit)
            else
                try self.ownUnitlessNumber(span, current);
            try values.append(self.allocator, item.*);
            current += step;
        }
        return self.ownValue(span, .{ .list = .{ .items = values.items, .separator = .space } });
    }

    fn evaluateOppositeBuiltin(
        self: *Engine,
        span: native_source.Span,
        arguments: []const *const native_value.Value,
    ) Error!*const native_value.Value {
        if (arguments.len == 0) return self.ownValue(span, .{ .list = .{ .items = &.{}, .separator = .space } });
        if (arguments.len != 1) return self.invalidBuiltinArguments(span);
        const input = arguments[0];
        var output: std.ArrayList(native_value.Value) = .empty;
        defer output.deinit(self.allocator);
        const items = if (input.* == .list) input.list.items else @as([]const native_value.Value, &.{input.*});
        try output.ensureTotalCapacity(self.allocator, items.len);
        for (items) |item| {
            const word = stringBytes(item) orelse return self.invalidBuiltinArguments(span);
            const opposite: []const u8 = if (nameEql(word, "top"))
                "bottom"
            else if (nameEql(word, "bottom"))
                "top"
            else if (nameEql(word, "left"))
                "right"
            else if (nameEql(word, "right"))
                "left"
            else
                word;
            output.appendAssumeCapacity(.{ .string = .{ .bytes = opposite } });
        }
        if (output.items.len == 1) return self.ownValue(span, output.items[0]);
        return self.ownValue(span, .{ .list = .{ .items = output.items, .separator = .space } });
    }

    fn evaluateStringBuiltin(
        self: *Engine,
        span: native_source.Span,
        name: []const u8,
        arguments: []const *const native_value.Value,
    ) Error!*const native_value.Value {
        if (nameEql(name, "unquote")) {
            if (arguments.len != 1) return self.invalidBuiltinArguments(span);
            const bytes = stringBytes(arguments[0].*) orelse return self.invalidBuiltinArguments(span);
            return self.ownValue(span, .{ .string = .{ .bytes = bytes } });
        }
        if (nameEql(name, "split")) {
            if (arguments.len != 2) return self.invalidBuiltinArguments(span);
            const delimiter = stringBytes(arguments[0].*) orelse return self.invalidBuiltinArguments(span);
            const bytes = stringBytes(arguments[1].*) orelse return self.invalidBuiltinArguments(span);
            if (delimiter.len == 0) return self.invalidBuiltinArguments(span);
            var values: std.ArrayList(native_value.Value) = .empty;
            defer values.deinit(self.allocator);
            var iterator = std.mem.splitSequence(u8, bytes, delimiter);
            while (iterator.next()) |part| {
                if (values.items.len >= self.limits.values.max_collection_items) {
                    try self.reportResource(span, "native Stylus value limit exceeded");
                    return error.ValueLimitExceeded;
                }
                try self.transaction.consumeOperations(1);
                try values.append(self.allocator, .{ .string = .{
                    .bytes = part,
                    .quoted = arguments[1].* == .string and arguments[1].string.quoted,
                } });
            }
            return self.ownValue(span, .{ .list = .{ .items = values.items, .separator = .space } });
        }
        if (nameEql(name, "substr")) {
            if (arguments.len < 2 or arguments.len > 3) return self.invalidBuiltinArguments(span);
            const bytes = stringBytes(arguments[0].*) orelse return self.invalidBuiltinArguments(span);
            const start_raw = integerScalar(arguments[1].*) orelse return self.invalidBuiltinArguments(span);
            const start = normalizeSliceBound(start_raw, bytes.len);
            const length = if (arguments.len == 3)
                std.math.cast(usize, integerScalar(arguments[2].*) orelse return self.invalidBuiltinArguments(span)) orelse 0
            else
                bytes.len - start;
            const end = @min(bytes.len, start + length);
            return self.ownStringResult(
                span,
                bytes[start..end],
                arguments[0].* == .string and arguments[0].string.quoted,
            );
        }
        if (nameEql(name, "slice")) {
            if (arguments.len < 2 or arguments.len > 3) return self.invalidBuiltinArguments(span);
            const start_raw = integerScalar(arguments[1].*) orelse return self.invalidBuiltinArguments(span);
            if (arguments[0].* == .list) {
                const list = arguments[0].list;
                const start = normalizeSliceBound(start_raw, list.items.len);
                const end = if (arguments.len == 3)
                    normalizeSliceBound(integerScalar(arguments[2].*) orelse return self.invalidBuiltinArguments(span), list.items.len)
                else
                    list.items.len;
                return self.ownValue(span, .{ .list = .{
                    .items = list.items[@min(start, end)..end],
                    .separator = list.separator,
                    .bracketed = list.bracketed,
                } });
            }
            const bytes = stringBytes(arguments[0].*) orelse return self.invalidBuiltinArguments(span);
            const start = normalizeSliceBound(start_raw, bytes.len);
            const end = if (arguments.len == 3)
                normalizeSliceBound(integerScalar(arguments[2].*) orelse return self.invalidBuiltinArguments(span), bytes.len)
            else
                bytes.len;
            return self.ownStringResult(
                span,
                bytes[@min(start, end)..end],
                arguments[0].* == .string and arguments[0].string.quoted,
            );
        }
        if (nameEql(name, "replace")) {
            if (arguments.len != 3) return self.invalidBuiltinArguments(span);
            const pattern = stringBytes(arguments[0].*) orelse return self.invalidBuiltinArguments(span);
            const replacement = stringBytes(arguments[1].*) orelse return self.invalidBuiltinArguments(span);
            const bytes = stringBytes(arguments[2].*) orelse return self.invalidBuiltinArguments(span);
            if (pattern.len == 0) return self.invalidBuiltinArguments(span);
            const output_len = boundedReplacementSize(
                bytes,
                pattern,
                replacement,
                self.limits.max_temporary_bytes -| self.temporary_bytes,
            ) orelse {
                try self.reportResource(span, "native Stylus temporary byte limit exceeded");
                return error.TemporaryLimitExceeded;
            };
            try self.reserveTemporary(span, output_len);
            try self.transaction.consumeOperations(output_len);
            const replaced = try self.allocator.alloc(u8, output_len);
            defer self.allocator.free(replaced);
            _ = std.mem.replace(u8, bytes, pattern, replacement, replaced);
            return self.ownStringResult(
                span,
                replaced,
                arguments[2].* == .string and arguments[2].string.quoted,
            );
        }
        if (nameEql(name, "join")) {
            if (arguments.len == 0) return self.invalidBuiltinArguments(span);
            const separator = stringBytes(arguments[0].*) orelse return self.invalidBuiltinArguments(span);
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(self.allocator);
            var emitted: usize = 0;
            for (arguments[1..]) |argument| {
                const items = if (arguments.len == 2 and argument.* == .list)
                    argument.list.items
                else
                    @as([]const native_value.Value, &.{argument.*});
                for (items) |*item| {
                    if (emitted > 0) try self.appendTemporary(&output, span, separator);
                    const serialized = try self.serializeJoinValueOwned(item, span);
                    defer self.allocator.free(serialized);
                    try self.appendTemporary(&output, span, serialized);
                    emitted += 1;
                }
            }
            if (emitted == 0) return self.ownValue(span, .{ .null_value = {} });
            return self.ownValue(span, .{ .string = .{ .bytes = output.items, .quoted = true } });
        }
        if (nameEql(name, "s")) {
            if (arguments.len == 0) return self.invalidBuiltinArguments(span);
            const format = stringBytes(arguments[0].*) orelse return self.invalidBuiltinArguments(span);
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(self.allocator);
            var cursor: usize = 0;
            var argument_index: usize = 1;
            while (cursor < format.len) {
                const marker = std.mem.indexOfScalarPos(u8, format, cursor, '%') orelse {
                    try self.appendTemporary(&output, span, format[cursor..]);
                    break;
                };
                try self.appendTemporary(&output, span, format[cursor..marker]);
                if (marker + 1 < format.len and format[marker + 1] == 's') {
                    if (argument_index < arguments.len) {
                        const serialized = try self.serializeValueOwned(arguments[argument_index], .value, span);
                        defer self.allocator.free(serialized);
                        try self.appendTemporary(&output, span, serialized);
                        argument_index += 1;
                    }
                    cursor = marker + 2;
                } else {
                    try self.appendTemporary(&output, span, "%");
                    cursor = marker + 1;
                }
            }
            return self.ownValue(span, .{ .string = .{ .bytes = output.items } });
        }
        return self.invalidBuiltinArguments(span);
    }

    fn serializeJoinValueOwned(
        self: *Engine,
        input: *const native_value.Value,
        span: native_source.Span,
    ) Error![]u8 {
        if (input.* != .color or input.color.space != .hsl) {
            return self.serializeValueForStyleOwned(
                input,
                .interpolation,
                span,
                .expanded,
            );
        }

        const channels = native_color.toHsl(input.color) catch {
            try self.reportInvalidOperation(span);
            return error.InvalidOperation;
        };
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        try self.appendTemporary(&output, span, "hsla(");
        var buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
        const hue = serializeStylusNumberForStyle(
            channels[0],
            .expanded,
            &buffer,
        ) catch {
            try self.reportInvalidOperation(span);
            return error.InvalidOperation;
        };
        try self.appendTemporary(&output, span, hue);
        try self.appendTemporary(&output, span, ",");
        const saturation = serializeStylusNumberForStyle(
            @round(channels[1]),
            .expanded,
            &buffer,
        ) catch {
            try self.reportInvalidOperation(span);
            return error.InvalidOperation;
        };
        try self.appendTemporary(&output, span, saturation);
        try self.appendTemporary(&output, span, "%,");
        const lightness = serializeStylusNumberForStyle(
            @round(channels[2]),
            .expanded,
            &buffer,
        ) catch {
            try self.reportInvalidOperation(span);
            return error.InvalidOperation;
        };
        try self.appendTemporary(&output, span, lightness);
        try self.appendTemporary(&output, span, "%,");
        const alpha = serializeStylusNumberForStyle(
            channels[3],
            .expanded,
            &buffer,
        ) catch {
            try self.reportInvalidOperation(span);
            return error.InvalidOperation;
        };
        try self.appendTemporary(&output, span, alpha);
        try self.appendTemporary(&output, span, ")");
        return output.toOwnedSlice(self.allocator);
    }

    fn evaluateConvertedString(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        depth: u16,
    ) Error!*const native_value.Value {
        if (depth >= self.limits.max_expression_depth) {
            try self.reportExpressionDepth(span);
            return error.ExpressionDepthExceeded;
        }
        try self.transaction.consumeOperations(@intCast(raw.len));
        const input = std.mem.trim(u8, raw, " \t\r\n\x0c");
        if (input.len >= 2 and (input[0] == '\'' or input[0] == '"') and
            closingQuote(input, 0) == input.len - 1)
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
        if (std.mem.eql(u8, input, "null")) {
            return self.ownValue(span, .{ .null_value = {} });
        }
        if (native_color.parseLiteral(input)) |color| {
            return self.ownValue(span, .{ .color = color });
        }
        if (looksNumeric(input)) {
            var parser = NumericParser{
                .input = input,
                .max_depth = self.limits.max_expression_depth,
            };
            if (parser.parse()) |numeric| {
                var numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
                var denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
                if (numeric.toNumber(&numerator, &denominator)) |number| {
                    return self.ownValue(span, .{ .number = number });
                } else |_| {}
            } else |failure| switch (failure) {
                error.ExpressionDepthExceeded => {
                    try self.reportExpressionDepth(span);
                    return error.ExpressionDepthExceeded;
                },
                else => {},
            }
        }

        var comma_items = try splitTopLevel(self.allocator, input, ',');
        defer comma_items.deinit(self.allocator);
        if (comma_items.items.len > 1) {
            return self.evaluateConvertedList(span, input, comma_items.items, .comma, depth + 1);
        }
        var space_items = try splitTopLevelWhitespace(self.allocator, input);
        defer space_items.deinit(self.allocator);
        if (space_items.items.len > 1) {
            return self.evaluateConvertedList(span, input, space_items.items, .space, depth + 1);
        }
        return self.ownValue(span, .{ .string = .{ .bytes = input } });
    }

    fn evaluateConvertedList(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        ranges: []const ByteRange,
        separator: native_value.Separator,
        depth: u16,
    ) Error!*const native_value.Value {
        var items: std.ArrayList(native_value.Value) = .empty;
        defer items.deinit(self.allocator);
        try items.ensureTotalCapacity(self.allocator, ranges.len);
        for (ranges) |range| {
            const item = try self.evaluateConvertedString(
                span,
                raw[range.start..range.end],
                depth + 1,
            );
            items.appendAssumeCapacity(item.*);
        }
        return self.ownValue(span, .{ .list = .{
            .items = items.items,
            .separator = separator,
        } });
    }

    fn evaluateMatchBuiltin(
        self: *Engine,
        span: native_source.Span,
        arguments: []const *const native_value.Value,
    ) Error!*const native_value.Value {
        if (arguments.len < 2 or arguments.len > 3 or
            arguments[0].* != .string or !arguments[0].string.quoted or
            arguments[1].* != .string)
        {
            return self.invalidBuiltinArguments(span);
        }
        const pattern = arguments[0].string.bytes;
        const subject = arguments[1].string.bytes;
        const flags = if (arguments.len == 3 and arguments[2].* == .string)
            parseStylusMatchFlags(arguments[2].string.bytes) orelse StylusMatchFlags{}
        else
            StylusMatchFlags{};
        const pattern_work: u64 = @intCast(pattern.len +| 1);
        const subject_work: u64 = @intCast(subject.len +| 1);
        const work = std.math.mul(u64, pattern_work, subject_work) catch
            std.math.maxInt(u64);
        try self.transaction.consumeOperations(work);

        var items: std.ArrayList(native_value.Value) = .empty;
        defer items.deinit(self.allocator);
        // The pinned provider family needs literal/prefix matching and one
        // anchored capture grammar. Every other regex form fails closed.
        const matched = if (parseStylusStructuredMatchPattern(pattern)) |structured|
            try self.appendStructuredMatches(&items, subject, structured, flags)
        else if (parseStylusLiteralPattern(pattern)) |literal|
            try self.appendLiteralMatches(&items, subject, literal, flags)
        else
            return self.invalidBuiltinArguments(span);
        if (!matched) return self.ownValue(span, .{ .null_value = {} });
        return self.ownValue(span, .{ .list = .{
            .items = items.items,
            .separator = .space,
        } });
    }

    fn appendStructuredMatches(
        self: *Engine,
        items: *std.ArrayList(native_value.Value),
        subject: []const u8,
        pattern: StylusStructuredMatchPattern,
        flags: StylusMatchFlags,
    ) Error!bool {
        _ = flags.multiline;
        var cursor: usize = 0;
        var first_capture: ?ByteRange = null;
        var alternatives = std.mem.splitScalar(u8, pattern.alternatives, '|');
        while (alternatives.next()) |alternative| {
            if (sliceStartsWith(subject[cursor..], alternative, flags.ignore_case)) {
                first_capture = .{ .start = cursor, .end = cursor + alternative.len };
                cursor += alternative.len;
                break;
            }
        }
        const operator_start = cursor;
        while (cursor < subject.len and
            stylusCharacterClassContains(pattern.character_class, subject[cursor], flags.ignore_case))
        {
            cursor += 1;
        }
        if (cursor - operator_start < pattern.minimum) return false;

        try items.append(self.allocator, quotedMatchValue(subject));
        if (flags.global) return true;
        try items.append(
            self.allocator,
            if (first_capture) |range|
                quotedMatchValue(subject[range.start..range.end])
            else
                .{ .null_value = {} },
        );
        try items.append(self.allocator, quotedMatchValue(subject[operator_start..cursor]));
        try items.append(self.allocator, quotedMatchValue(subject[cursor..]));
        return true;
    }

    fn appendLiteralMatches(
        self: *Engine,
        items: *std.ArrayList(native_value.Value),
        subject: []const u8,
        pattern: StylusLiteralPattern,
        flags: StylusMatchFlags,
    ) Error!bool {
        var search_start: usize = 0;
        var matched = false;
        while (search_start <= subject.len) {
            const found = findStylusLiteralMatch(subject, pattern, flags, search_start) orelse break;
            try items.append(
                self.allocator,
                quotedMatchValue(subject[found.start..found.end]),
            );
            matched = true;
            if (!flags.global or pattern.anchor_start or pattern.anchor_end) break;
            search_start = if (found.end > found.start) found.end else found.start + 1;
        }
        return matched;
    }

    fn ownStringResult(
        self: *Engine,
        span: native_source.Span,
        bytes: []const u8,
        quoted: bool,
    ) Error!*const native_value.Value {
        if (!quoted) {
            if (native_color.parseLiteral(bytes)) |color| {
                return self.ownValue(span, .{ .color = color });
            }
        }
        return self.ownValue(span, .{ .string = .{ .bytes = bytes, .quoted = quoted } });
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
        const source_condition = std.mem.trim(u8, raw, " \t\r\n\x0c;");
        if (findTopLevelSequence(source_condition, " is defined")) |marker| {
            if (marker + " is defined".len == source_condition.len) {
                const name = std.mem.trim(u8, source_condition[0..marker], " \t\r\n\x0c");
                if (validVariableName(name)) return try self.lookupBinding(scope, name) != null;
            }
        }
        if (findTopLevelSequence(source_condition, " is a ")) |marker| {
            const value = try self.evaluateValue(span, source_condition[0..marker], scope, 0);
            const expected_raw = std.mem.trim(u8, source_condition[marker + " is a ".len ..], " \t\r\n\x0c");
            const expected = if (expected_raw.len >= 2 and
                ((expected_raw[0] == '\'' and expected_raw[expected_raw.len - 1] == '\'') or
                    (expected_raw[0] == '"' and expected_raw[expected_raw.len - 1] == '"')))
                expected_raw[1 .. expected_raw.len - 1]
            else
                expected_raw;
            return valueIsType(value.*, expected, self);
        }
        if (findTopLevelSequence(source_condition, " in ")) |marker| {
            const needle = try self.evaluateValue(span, source_condition[0..marker], scope, 0);
            const haystack = try self.evaluateValue(
                span,
                source_condition[marker + " in ".len ..],
                scope,
                0,
            );
            if (haystack.* == .list) {
                for (haystack.list.items) |item| if (native_value.eql(needle.*, item)) return true;
                return false;
            }
            return native_value.eql(needle.*, haystack.*);
        }
        if (parseCall(source_condition)) |call| {
            const name = source_condition[call.name.start..call.name.end];
            if (nameEql(name, "selector-exists") and self.findCallable(name) == null) {
                return isTruthy(try self.evaluateSelectorExistsBuiltin(
                    span,
                    source_condition,
                    call,
                    scope,
                ));
            }
        }
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
            const equal = stylusValueEqual(left.*, right.*);
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
                if (eolEscapeEnd(raw, index)) |escape_end| {
                    index = escape_end;
                    continue;
                }
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
                        if (context == .selector or context == .property)
                            .identifier_interpolation
                        else
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
                    if (context == .selector or context == .property)
                        .identifier_interpolation
                    else
                        .interpolation,
                    inner_span,
                );
                defer self.allocator.free(replacement);
                try self.appendTemporary(&output, span, replacement);
                index = closing + 1;
                continue;
            }
            if (byte == '@' and index + 1 < raw.len and isNameStart(raw, index + 1)) {
                const start = index;
                index = nameEnd(raw, index + 1);
                const name = raw[start..index];
                if (try self.lookupBinding(scope, name)) |resolved| {
                    const replacement = try self.serializeValueOwned(resolved, context, span);
                    defer self.allocator.free(replacement);
                    try self.appendTemporary(&output, span, replacement);
                    continue;
                }
                try self.appendTemporary(&output, span, name);
                continue;
            }
            if (isNameStart(raw, index)) {
                const start = index;
                index = nameEnd(raw, index);
                const name = raw[start..index];
                const unit_suffix = start > 0 and
                    (std.ascii.isDigit(raw[start - 1]) or raw[start - 1] == '.');
                const substitute = (context == .value or context == .interpolation) and !unit_suffix;
                if (substitute) {
                    if (try self.lookupBinding(scope, name) != null) {
                        const chain_end = memberChainEnd(raw, index);
                        if (chain_end > index) {
                            const member = (try self.evaluateMemberChain(
                                span,
                                raw[start..chain_end],
                                scope,
                            )) orelse return error.InvalidOperation;
                            const replacement = try self.serializeValueOwned(
                                member,
                                context,
                                span,
                            );
                            defer self.allocator.free(replacement);
                            try self.appendTemporary(&output, span, replacement);
                            index = chain_end;
                            continue;
                        }
                    }
                    if (try self.lookupBinding(scope, name)) |resolved| {
                        const replacement = try self.serializeValueOwned(
                            resolved,
                            context,
                            span,
                        );
                        defer self.allocator.free(replacement);
                        try self.appendTemporary(&output, span, replacement);
                        continue;
                    }
                    if (name[0] == '$' and !self.isJsonLocalName(name)) {
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

    fn normalizeEolEscapesOwned(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
    ) Error!?[]u8 {
        var normalized: ?[]u8 = null;
        errdefer if (normalized) |owned| self.allocator.free(owned);
        var quote: u8 = 0;
        var block_comment = false;
        var line_comment = false;
        var index: usize = 0;
        while (index < raw.len) {
            const byte = raw[index];
            if (line_comment) {
                if (byte == '\n' or byte == '\r') line_comment = false;
                index += 1;
                continue;
            }
            if (block_comment) {
                if (byte == '*' and index + 1 < raw.len and raw[index + 1] == '/') {
                    block_comment = false;
                    index += 2;
                } else {
                    index += 1;
                }
                continue;
            }
            if (quote != 0) {
                if (byte == '\\') {
                    if (eolEscapeEnd(raw, index)) |escape_end| {
                        index = escape_end;
                    } else {
                        index += @min(@as(usize, 2), raw.len - index);
                    }
                } else {
                    if (byte == quote) quote = 0;
                    index += 1;
                }
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte;
                index += 1;
                continue;
            }
            if (byte == '/' and index + 1 < raw.len and raw[index + 1] == '/') {
                line_comment = true;
                index += 2;
                continue;
            }
            if (byte == '/' and index + 1 < raw.len and raw[index + 1] == '*') {
                block_comment = true;
                index += 2;
                continue;
            }
            if (byte == '\\') {
                if (eolEscapeEnd(raw, index)) |escape_end| {
                    if (normalized == null) {
                        try self.reserveTemporary(span, raw.len);
                        normalized = try self.allocator.dupe(u8, raw);
                    }
                    @memset(normalized.?[index..escape_end], ' ');
                    index = escape_end;
                } else {
                    index += @min(@as(usize, 2), raw.len - index);
                }
                continue;
            }
            index += 1;
        }
        return normalized;
    }

    fn serializeValueOwned(
        self: *Engine,
        input: *const native_value.Value,
        context: RenderContext,
        span: native_source.Span,
    ) Error![]u8 {
        return self.serializeValueForStyleOwned(
            input,
            context,
            span,
            self.options.output_style,
        );
    }

    fn serializeDeclarationValueOwned(
        self: *Engine,
        input: *const native_value.Value,
        span: native_source.Span,
        raw: []const u8,
    ) Error![]u8 {
        const source_value = std.mem.trim(u8, raw, " \t\r\n\x0c;");
        if (input.* == .string and input.string.quoted) {
            if (sourceQuotedValue(source_value)) |quote| {
                var output: std.ArrayList(u8) = .empty;
                errdefer output.deinit(self.allocator);
                try self.appendTemporary(&output, span, &.{quote});
                try self.appendTemporary(&output, span, input.string.bytes);
                try self.appendTemporary(&output, span, &.{quote});
                return output.toOwnedSlice(self.allocator);
            }
        }
        if (input.* != .list or input.list.bracketed) {
            return self.serializeValueOwned(input, .value, span);
        }

        var ranges: std.ArrayList(ByteRange) = switch (input.list.separator) {
            .comma => try splitTopLevel(self.allocator, source_value, ','),
            .space => if (listContainsLiteralSlash(input.list.items))
                try splitTopLevelPropertyItems(self.allocator, source_value)
            else
                try splitTopLevelWhitespace(self.allocator, source_value),
            else => return self.serializeValueOwned(input, .value, span),
        };
        defer ranges.deinit(self.allocator);
        if (ranges.items.len != input.list.items.len) {
            return self.serializeValueOwned(input, .value, span);
        }

        const separator = if (input.list.separator == .comma) ", " else " ";
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        for (input.list.items, ranges.items, 0..) |*item, range, index| {
            if (index > 0 and !literalSlashAdjacent(input.list.items, index)) {
                try self.appendTemporary(&output, span, separator);
            }
            const serialized = try self.serializeDeclarationValueOwned(
                item,
                span,
                source_value[range.start..range.end],
            );
            defer self.allocator.free(serialized);
            try self.appendTemporary(&output, span, serialized);
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn serializeValueForStyleOwned(
        self: *Engine,
        input: *const native_value.Value,
        context: RenderContext,
        span: native_source.Span,
        output_style: OutputStyle,
    ) Error![]u8 {
        if (self.blockValue(input) != null) {
            try self.reportInvalidOperation(span);
            return error.InvalidOperation;
        }
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        switch (input.*) {
            .null_value => {},
            .boolean => |item| try self.appendTemporary(
                &output,
                span,
                if (item) "true" else "false",
            ),
            .number => |number| {
                var number_buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
                const scalar = serializeStylusNumberForStyle(
                    number.value,
                    output_style,
                    &number_buffer,
                ) catch {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                };
                var unit_buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
                const units = native_numeric.serializeUnits(number, &unit_buffer) catch {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                };
                try self.appendTemporary(&output, span, scalar);
                if (!omitCompressedZeroUnit(
                    number.value,
                    units,
                    output_style,
                )) {
                    try self.appendTemporary(&output, span, units);
                }
            },
            .color => |color| {
                var color_buffer: [native_color.max_serialized_bytes]u8 = undefined;
                const channels = native_color.toRgb(color) catch {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                };
                const stylus_color = native_color.rgb(
                    @floor(channels[0]),
                    @floor(channels[1]),
                    @floor(channels[2]),
                    @trunc(channels[3] * 1000) / 1000,
                ) catch {
                    try self.reportInvalidOperation(span);
                    return error.InvalidOperation;
                };
                const serialized = (if (channels[3] < 1 and color.space == .rgb)
                    native_color.serializeRgbFunctional(stylus_color, &color_buffer, false)
                else
                    native_color.serializePreferHex(stylus_color, &color_buffer, false)) catch {
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
            .list => |list| {
                if (context == .identifier_interpolation) {
                    if (list.items.len > 0) {
                        const serialized = try self.serializeValueForStyleOwned(
                            &list.items[0],
                            context,
                            span,
                            output_style,
                        );
                        defer self.allocator.free(serialized);
                        try self.appendTemporary(&output, span, serialized);
                    }
                } else {
                    const separator: []const u8 = switch (list.separator) {
                        .comma => ", ",
                        .slash, .legacy_slash => "/",
                        else => " ",
                    };
                    if (list.bracketed) try self.appendTemporary(&output, span, "[");
                    for (list.items, 0..) |*item, index| {
                        if (index > 0 and !literalSlashAdjacent(list.items, index)) {
                            try self.appendTemporary(&output, span, separator);
                        }
                        const serialized = try self.serializeValueForStyleOwned(
                            item,
                            context,
                            span,
                            output_style,
                        );
                        defer self.allocator.free(serialized);
                        try self.appendTemporary(&output, span, serialized);
                    }
                    if (list.bracketed) try self.appendTemporary(&output, span, "]");
                }
            },
            else => return error.InvalidDocument,
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn prefixClassSelectorsOwned(
        self: *Engine,
        span: native_source.Span,
        selector: []const u8,
        prefix: []const u8,
    ) Error![]u8 {
        try self.transaction.consumeOperations(@intCast(selector.len));
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var quote: u8 = 0;
        var escaped = false;
        var attribute_depth: usize = 0;
        for (selector, 0..) |byte, index| {
            if (escaped) {
                try self.appendTemporary(&output, span, selector[index .. index + 1]);
                escaped = false;
                continue;
            }
            if (byte == '\\') {
                try self.appendTemporary(&output, span, selector[index .. index + 1]);
                escaped = true;
                continue;
            }
            if (quote != 0) {
                try self.appendTemporary(&output, span, selector[index .. index + 1]);
                if (byte == quote) quote = 0;
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte;
                try self.appendTemporary(&output, span, selector[index .. index + 1]);
                continue;
            }
            if (byte == '[') {
                attribute_depth += 1;
                try self.appendTemporary(&output, span, selector[index .. index + 1]);
                continue;
            }
            if (byte == ']') {
                attribute_depth -|= 1;
                try self.appendTemporary(&output, span, selector[index .. index + 1]);
                continue;
            }
            if (byte == '.' and attribute_depth == 0 and index + 1 < selector.len and
                isClassSelectorStart(selector[index + 1]))
            {
                try self.transaction.consumeOperations(@intCast(prefix.len));
                try self.appendTemporary(&output, span, ".");
                try self.appendTemporary(&output, span, prefix);
                continue;
            }
            try self.appendTemporary(&output, span, selector[index .. index + 1]);
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn combineSelectors(
        self: *Engine,
        parent_selector: ?[]const u8,
        child_selector: []const u8,
        span: native_source.Span,
    ) Error![]u8 {
        var branches = try splitTopLevel(self.allocator, child_selector, ',');
        defer branches.deinit(self.allocator);
        var owns_special_branch = false;
        for (branches.items) |range| {
            const branch = std.mem.trim(
                u8,
                child_selector[range.start..range.end],
                " \t\r\n\x0c",
            );
            if (selectorBranchNeedsResolution(branch) or
                (parent_selector == null and std.mem.indexOfScalar(u8, branch, '&') != null))
            {
                owns_special_branch = true;
                break;
            }
        }
        if (!owns_special_branch) {
            return self.combineSelectorsLiteral(parent_selector, child_selector, span);
        }

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        for (branches.items) |range| {
            const branch = std.mem.trim(
                u8,
                child_selector[range.start..range.end],
                " \t\r\n\x0c",
            );
            if (branch.len == 0) return error.InvalidDocument;
            const resolved = if (selectorBranchNeedsResolution(branch))
                try self.resolveSelectorBranchOwned(span, branch)
            else
                try self.combineSelectorsLiteral(parent_selector, branch, span);
            defer self.allocator.free(resolved);
            if (resolved.len == 0) continue;
            if (output.items.len > 0) try self.appendTemporary(&output, span, ",");
            try self.appendTemporary(&output, span, resolved);
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn resolveSelectorBranchOwned(
        self: *Engine,
        span: native_source.Span,
        branch: []const u8,
    ) Error![]u8 {
        if (branch[0] == '/' and !std.mem.startsWith(u8, branch, "/deep")) {
            const absolute = std.mem.trimLeft(u8, branch[1..], " \t\r\n\x0c");
            if (absolute.len == 0) {
                try self.reportInvalidOperation(span);
                return error.InvalidOperation;
            }
            var output: std.ArrayList(u8) = .empty;
            errdefer output.deinit(self.allocator);
            try self.appendTemporary(&output, span, absolute);
            return output.toOwnedSlice(self.allocator);
        }

        var relative_cursor: usize = 0;
        var relative_hops: usize = 0;
        while (std.mem.startsWith(u8, branch[relative_cursor..], "../")) {
            relative_hops += 1;
            relative_cursor += 3;
        }
        if (relative_hops > 0) {
            const separated = relative_cursor < branch.len and
                std.ascii.isWhitespace(branch[relative_cursor]);
            const remainder = std.mem.trim(u8, branch[relative_cursor..], " \t\r\n\x0c");
            if (relative_hops >= self.selector_parts.items.len) {
                try self.reportInvalidOperation(span);
                return error.InvalidOperation;
            }
            const saved_selector_count = self.selector_count;
            const base = try self.selectorFromPartsOwned(
                span,
                self.selector_parts.items[0 .. self.selector_parts.items.len - relative_hops],
            );
            self.selector_count = saved_selector_count;
            if (remainder.len == 0) return base;
            defer self.allocator.free(base);
            if (separated) {
                return self.combineSelectorsLiteral(base, remainder, span);
            }
            return self.appendSelectorSuffixOwned(span, base, remainder);
        }

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var cursor: usize = 0;
        var found_reference = false;
        while (cursor < branch.len) {
            const marker = std.mem.indexOfPos(u8, branch, cursor, "^[") orelse {
                try self.appendTemporary(&output, span, branch[cursor..]);
                break;
            };
            try self.appendTemporary(&output, span, branch[cursor..marker]);
            const closing = std.mem.indexOfScalarPos(u8, branch, marker + 2, ']') orelse {
                try self.reportInvalidOperation(span);
                return error.InvalidOperation;
            };
            const expansion = try self.selectorReferenceExpansionOwned(
                span,
                branch[marker + 2 .. closing],
            );
            defer self.allocator.free(expansion);
            try self.appendTemporary(&output, span, expansion);
            found_reference = true;
            cursor = closing + 1;
        }
        if (!found_reference) return error.InvalidDocument;
        return output.toOwnedSlice(self.allocator);
    }

    fn selectorReferenceExpansionOwned(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
    ) Error![]u8 {
        if (self.selector_parts.items.len == 0) {
            try self.reportInvalidOperation(span);
            return error.InvalidOperation;
        }
        const selected_parts = if (std.mem.indexOf(u8, raw, "..") != null) blk: {
            const range = parseSelectorSlice(raw, self.selector_parts.items.len) orelse {
                try self.reportInvalidOperation(span);
                return error.InvalidOperation;
            };
            break :blk self.selector_parts.items[range.start .. range.end + 1];
        } else blk: {
            const index = selectorSliceIndex(
                std.mem.trim(u8, raw, " \t\r\n\x0c"),
                self.selector_parts.items.len,
            ) orelse {
                try self.reportInvalidOperation(span);
                return error.InvalidOperation;
            };
            break :blk self.selector_parts.items[0 .. index + 1];
        };
        const saved_selector_count = self.selector_count;
        defer self.selector_count = saved_selector_count;
        return self.selectorFromPartsOwned(span, selected_parts);
    }

    fn appendSelectorSuffixOwned(
        self: *Engine,
        span: native_source.Span,
        selector: []const u8,
        suffix: []const u8,
    ) Error![]u8 {
        var selectors = try splitTopLevel(self.allocator, selector, ',');
        defer selectors.deinit(self.allocator);
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        for (selectors.items) |range| {
            if (output.items.len > 0) try self.appendTemporary(&output, span, ",");
            try self.appendTemporary(
                &output,
                span,
                std.mem.trim(u8, selector[range.start..range.end], " \t\r\n\x0c"),
            );
            try self.appendTemporary(&output, span, suffix);
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn selectorFromPartsOwned(
        self: *Engine,
        span: native_source.Span,
        parts: []const []u8,
    ) Error![]u8 {
        if (parts.len == 0) return error.InvalidDocument;
        var first = std.mem.trim(u8, parts[0], " \t\r\n\x0c");
        if (first.len > 0 and first[0] == '&') {
            first = std.mem.trimLeft(u8, first[1..], " \t\r\n\x0c");
        }
        if (first.len > 0 and std.mem.indexOfScalar(u8, ">+~", first[0]) != null) {
            first = std.mem.trimLeft(u8, first[1..], " \t\r\n\x0c");
        }
        if (first.len == 0) return error.InvalidDocument;
        var initial: std.ArrayList(u8) = .empty;
        errdefer initial.deinit(self.allocator);
        try self.appendTemporary(&initial, span, first);
        var current = try initial.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(current);
        for (parts[1..]) |part| {
            const combined = try self.combineSelectorsLiteral(current, part, span);
            self.allocator.free(current);
            current = combined;
        }
        return current;
    }

    fn combineSelectorsLiteral(
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
                if (parent_selector) |parent_raw| {
                    if (output.items.len > 0) try self.appendTemporary(&output, span, ",");
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
                    var root: std.ArrayList(u8) = .empty;
                    defer root.deinit(self.allocator);
                    try self.appendReplacingAmpersands(&root, span, child, "");
                    var normalized = std.mem.trim(u8, root.items, " \t\r\n\x0c");
                    if (normalized.len > 0 and
                        std.mem.indexOfScalar(u8, ">+~", normalized[0]) != null)
                    {
                        normalized = std.mem.trimLeft(
                            u8,
                            normalized[1..],
                            " \t\r\n\x0c",
                        );
                    }
                    if (normalized.len == 0) continue;
                    if (output.items.len > 0) try self.appendTemporary(&output, span, ",");
                    try self.appendTemporary(&output, span, normalized);
                }
            }
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn normalizeSelectorLines(
        self: *Engine,
        span: native_source.Span,
        selector: []const u8,
    ) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var cursor: usize = 0;
        while (cursor < selector.len) {
            const newline = std.mem.indexOfAnyPos(u8, selector, cursor, "\r\n") orelse {
                try self.appendTemporary(&output, span, selector[cursor..]);
                break;
            };
            try self.appendTemporary(&output, span, selector[cursor..newline]);
            while (output.items.len > 0 and std.ascii.isWhitespace(output.items[output.items.len - 1])) {
                _ = output.pop();
            }
            cursor = newline + 1;
            if (selector[newline] == '\r' and cursor < selector.len and selector[cursor] == '\n') {
                cursor += 1;
            }
            while (cursor < selector.len and
                (selector[cursor] == ' ' or selector[cursor] == '\t' or selector[cursor] == '\x0c'))
            {
                cursor += 1;
            }
            if (output.items.len > 0 and output.items[output.items.len - 1] != ',') {
                try self.appendTemporary(&output, span, ",");
            }
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn selectorPartOwned(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        nested: bool,
    ) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        if (nested and std.mem.indexOfScalar(u8, raw, '&') == null) {
            try self.appendTemporary(&output, span, "& ");
        }
        var cursor: usize = 0;
        while (cursor < raw.len) {
            if (raw[cursor] == ',') {
                while (output.items.len > 0 and std.ascii.isWhitespace(output.items[output.items.len - 1])) {
                    _ = output.pop();
                }
                try self.appendTemporary(&output, span, ",");
                cursor += 1;
                while (cursor < raw.len and std.ascii.isWhitespace(raw[cursor])) cursor += 1;
                continue;
            }
            try self.appendTemporary(&output, span, raw[cursor .. cursor + 1]);
            cursor += 1;
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn formatCurrentMediaOwned(
        self: *Engine,
        span: native_source.Span,
        header: []const u8,
    ) Error![]u8 {
        const body = std.mem.trim(u8, header["@media".len..], " \t\r\n\x0c;");
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        try self.appendTemporary(&output, span, "@media (");
        var cursor: usize = 0;
        while (cursor < body.len) {
            if (body[cursor] == ':') {
                try self.appendTemporary(&output, span, ": (");
                cursor += 1;
                while (cursor < body.len and std.ascii.isWhitespace(body[cursor])) cursor += 1;
                const closing = std.mem.indexOfScalarPos(u8, body, cursor, ')') orelse {
                    try self.appendTemporary(&output, span, body[cursor..]);
                    try self.appendTemporary(&output, span, ")");
                    cursor = body.len;
                    break;
                };
                try self.appendTemporary(&output, span, std.mem.trimRight(u8, body[cursor..closing], " \t\r\n\x0c"));
                try self.appendTemporary(&output, span, ")");
                cursor = closing;
                continue;
            }
            try self.appendTemporary(&output, span, body[cursor .. cursor + 1]);
            cursor += 1;
        }
        try self.appendTemporary(&output, span, ")");
        return output.toOwnedSlice(self.allocator);
    }

    fn spaceMediaFeaturesOwned(
        self: *Engine,
        span: native_source.Span,
        header: []const u8,
    ) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var depth: usize = 0;
        var quote: u8 = 0;
        var escaped = false;
        for (header, 0..) |byte, index| {
            try self.appendTemporary(&output, span, header[index .. index + 1]);
            if (escaped) {
                escaped = false;
                continue;
            }
            if (quote != 0) {
                if (byte == '\\') {
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
            if (byte == '(') {
                depth += 1;
                continue;
            }
            if (byte == ')') {
                if (depth > 0) depth -= 1;
                continue;
            }
            if (byte == ':' and depth > 0 and index + 1 < header.len and
                !std.ascii.isWhitespace(header[index + 1]))
            {
                try self.appendTemporary(&output, span, " ");
            }
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn evaluateUrlBuiltin(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
        call: Call,
        scope: native_environment.ScopeId,
    ) Error!*const native_value.Value {
        // Stylus evaluates URL expression nodes but never resolves the URL as
        // an asset. The compiler then concatenates the nodes inside one quote.
        const arguments = raw[call.arguments.start..call.arguments.end];
        try self.transaction.consumeOperations(@intCast(arguments.len));
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        try self.appendTemporary(&output, span, "url(\"");
        try self.appendUrlExpression(&output, span, arguments, scope);
        try self.appendTemporary(&output, span, "\")");
        return self.ownValue(span, .{ .string = .{ .bytes = output.items } });
    }

    fn appendUrlExpression(
        self: *Engine,
        output: *std.ArrayList(u8),
        span: native_source.Span,
        raw: []const u8,
        scope: native_environment.ScopeId,
    ) Error!void {
        var cursor: usize = 0;
        while (cursor < raw.len) {
            const byte = raw[cursor];
            if (std.ascii.isWhitespace(byte) or byte == '+') {
                cursor += 1;
                continue;
            }
            if (byte == '\'' or byte == '"') {
                const closing = closingQuote(raw, cursor) orelse return error.InvalidDocument;
                const value = try self.evaluateValue(span, raw[cursor .. closing + 1], scope, 0);
                const serialized = try self.serializeValueOwned(value, .interpolation, span);
                defer self.allocator.free(serialized);
                try self.appendTemporary(output, span, serialized);
                cursor = closing + 1;
                continue;
            }
            if (byte == '{') {
                const closing = matchingCurly(raw, cursor) orelse return error.InvalidDocument;
                const value = try self.evaluateValue(span, raw[cursor + 1 .. closing], scope, 0);
                const serialized = try self.serializeValueOwned(value, .interpolation, span);
                defer self.allocator.free(serialized);
                try self.appendTemporary(output, span, serialized);
                cursor = closing + 1;
                continue;
            }
            if (isNameStart(raw, cursor)) {
                const name_end = nameEnd(raw, cursor);
                const name = raw[cursor..name_end];
                var token_end = memberChainEnd(raw, name_end);
                var opening = name_end;
                while (opening < raw.len and std.ascii.isWhitespace(raw[opening])) {
                    opening += 1;
                }
                if (opening < raw.len and raw[opening] == '(') {
                    const closing = matchingParen(raw, opening) orelse
                        return error.InvalidDocument;
                    token_end = memberChainEnd(raw, closing + 1);
                }
                const ignore_color = native_color.parseLiteral(name) != null;
                const should_evaluate = !ignore_color and
                    ((try self.lookupBinding(scope, name)) != null or
                        self.findCallable(name) != null or isBuiltinCallableName(name) or
                        nameEql(name, "url") or name[0] == '$');
                if (should_evaluate) {
                    const value = try self.evaluateValue(span, raw[cursor..token_end], scope, 0);
                    const serialized = try self.serializeValueOwned(value, .interpolation, span);
                    defer self.allocator.free(serialized);
                    try self.appendTemporary(output, span, serialized);
                } else {
                    try self.appendTemporary(output, span, raw[cursor..token_end]);
                }
                cursor = token_end;
                continue;
            }
            try self.appendTemporary(output, span, raw[cursor .. cursor + 1]);
            cursor += 1;
        }
    }

    fn normalizeUrlQuotesOwned(
        self: *Engine,
        span: native_source.Span,
        raw: []const u8,
    ) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, raw, cursor, "url('")) |opening| {
            const closing = std.mem.indexOfScalarPos(u8, raw, opening + 5, '\'') orelse break;
            if (closing + 1 >= raw.len or raw[closing + 1] != ')') break;
            try self.appendTemporary(&output, span, raw[cursor..opening]);
            try self.appendTemporary(&output, span, "url(\"");
            try self.appendTemporary(&output, span, raw[opening + 5 .. closing]);
            try self.appendTemporary(&output, span, "\")");
            cursor = closing + 2;
        }
        try self.appendTemporary(&output, span, raw[cursor..]);
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
        try self.reserveTemporary(span, bytes.len);
        try output.appendSlice(self.allocator, bytes);
    }

    fn reserveTemporary(
        self: *Engine,
        span: native_source.Span,
        byte_count: usize,
    ) Error!void {
        const next = std.math.add(usize, self.temporary_bytes, byte_count) catch {
            try self.reportResource(span, "native Stylus temporary byte limit exceeded");
            return error.TemporaryLimitExceeded;
        };
        if (next > self.limits.max_temporary_bytes) {
            try self.reportResource(span, "native Stylus temporary byte limit exceeded");
            return error.TemporaryLimitExceeded;
        }
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

    fn lookupBinding(
        self: *const Engine,
        scope: native_environment.ScopeId,
        name: []const u8,
    ) Error!?*const native_value.Value {
        if (try self.environment.lookup(scope, name)) |value| return value;
        const global_scope = self.global_scope orelse return null;
        if (global_scope.value == scope.value) return null;
        return self.environment.lookup(global_scope.*, name);
    }

    fn updateBinding(
        self: *Engine,
        scope: native_environment.ScopeId,
        name: []const u8,
        value: *const native_value.Value,
    ) Error!bool {
        if (try self.environment.update(scope, name, value)) return true;
        const global_scope = self.global_scope orelse return false;
        if (global_scope.value == scope.value) return false;
        return self.environment.update(global_scope.*, name, value);
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

    fn reportUndefinedVariable(self: *Engine, span: native_source.Span) Error!void {
        try self.transaction.report(
            .err,
            .undefined_variable,
            span,
            "native Stylus variable is undefined",
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

fn eolEscapeEnd(raw: []const u8, opening: usize) ?usize {
    if (opening >= raw.len or raw[opening] != '\\') return null;
    var cursor = opening + 1;
    while (cursor < raw.len and
        (raw[cursor] == ' ' or raw[cursor] == '\t' or raw[cursor] == '\x0c'))
    {
        cursor += 1;
    }
    if (cursor >= raw.len) return null;
    if (raw[cursor] == '\n') return cursor + 1;
    if (raw[cursor] != '\r') return null;
    return if (cursor + 1 < raw.len and raw[cursor + 1] == '\n')
        cursor + 2
    else
        cursor + 1;
}

const ConditionHeader = struct {
    expression: []const u8,
    negated: bool,
};

const PostfixCondition = struct {
    expression: ByteRange,
    negated: bool,
};

const PostfixSplit = struct {
    declaration: ByteRange,
    condition: ?PostfixCondition = null,
};

const LoopHeader = struct {
    name: []const u8,
    index_name: ?[]const u8 = null,
    items: []const u8,
};

const PostfixLoop = struct {
    expression: []const u8,
    header: LoopHeader,
    conditions: []const u8 = "",
};

const PostfixLoopCondition = struct {
    expression: []const u8,
    remaining: []const u8,
    negated: bool,
};

const PostfixConditionMarker = struct {
    start: usize,
    end: usize,
    negated: bool,
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

const GenericTernary = struct {
    condition: ByteRange,
    when_true: ByteRange,
    when_false: ByteRange,
};

const LogicalKind = enum { or_value, and_value };

const LogicalExpression = struct {
    left: ByteRange,
    right: ByteRange,
};

const RangeExpression = struct {
    left: ByteRange,
    right: ByteRange,
    inclusive: bool,
};

const GenericBinary = struct {
    left: ByteRange,
    right: ByteRange,
    operator: u8,
};

const UnitCast = struct {
    expression: ByteRange,
    unit: []const u8,
};

const UnaryKind = enum { logical_not, positive, negative, bitwise_not };

const UnaryPrefix = struct {
    kind: UnaryKind,
    end: usize,
};

const NamedArgument = struct {
    name: []const u8,
    value: []const u8,
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

fn parseBareCall(raw_input: []const u8) ?Call {
    const raw = std.mem.trim(u8, raw_input, " \t\r\n\x0c;");
    if (raw.len < 3 or !isNameStart(raw, 0)) return null;
    const name_end = nameEnd(raw, 0);
    if (name_end >= raw.len or !std.ascii.isWhitespace(raw[name_end])) return null;
    var arguments_start = name_end;
    while (arguments_start < raw.len and std.ascii.isWhitespace(raw[arguments_start])) {
        arguments_start += 1;
    }
    if (arguments_start == raw.len) return null;
    return .{
        .name = .{ .start = 0, .end = name_end },
        .arguments = .{ .start = arguments_start, .end = raw.len },
        .parenthesized = false,
    };
}

fn parseDeclarationCall(raw: []const u8) ?Call {
    const parts = splitDeclaration(raw) orelse return null;
    const name = raw[parts[0].start..parts[0].end];
    if (!validVariableName(name)) return null;
    const separator = raw[parts[0].end..parts[1].start];
    return .{
        .name = parts[0],
        .arguments = parts[1],
        .parenthesized = std.mem.indexOfScalar(u8, separator, ':') != null,
        .property_syntax = std.mem.indexOfScalar(u8, separator, ':') != null,
    };
}

fn parseParameter(raw_input: []const u8) ?Parameter {
    var raw = std.mem.trim(u8, raw_input, " \t\r\n\x0c");
    var rest = false;
    if (std.mem.endsWith(u8, raw, "...")) {
        rest = true;
        raw = std.mem.trimRight(u8, raw[0 .. raw.len - 3], " \t\r\n\x0c");
    }
    const equals = findTopLevelScalar(raw, '=');
    const name = std.mem.trim(
        u8,
        if (equals) |index| raw[0..index] else raw,
        " \t\r\n\x0c",
    );
    if (!validVariableName(name)) return null;
    if (rest and equals != null) return null;
    const default_value = if (equals) |index| blk: {
        const value = std.mem.trim(u8, raw[index + 1 ..], " \t\r\n\x0c");
        if (value.len == 0) return null;
        break :blk value;
    } else null;
    return .{ .name = name, .default_value = default_value, .rest = rest };
}

fn splitNamedArgument(raw: []const u8) ?NamedArgument {
    const colon = findTopLevelScalar(raw, ':') orelse return null;
    const name = std.mem.trim(u8, raw[0..colon], " \t\r\n\x0c");
    const value = std.mem.trim(u8, raw[colon + 1 ..], " \t\r\n\x0c");
    if (!validVariableName(name) or value.len == 0) return null;
    return .{ .name = name, .value = value };
}

fn findTopLevelScalar(raw: []const u8, needle: u8) ?usize {
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    for (raw, 0..) |byte, index| {
        if (quote != 0) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == quote) quote = 0;
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
        if (depth == 0 and byte == needle) return index;
    }
    return null;
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

fn staticConditionSelected(raw: []const u8) ?bool {
    const condition = parseConditionHeader(raw) orelse return null;
    const expression = std.mem.trim(u8, condition.expression, " \t\r\n\x0c;");
    var selected = if (std.ascii.eqlIgnoreCase(expression, "true"))
        true
    else if (std.ascii.eqlIgnoreCase(expression, "false") or
        std.ascii.eqlIgnoreCase(expression, "null"))
        false
    else
        return null;
    if (condition.negated) selected = !selected;
    return selected;
}

fn findFirstPostfixConditionMarker(
    raw: []const u8,
    minimum_start: usize,
) ?PostfixConditionMarker {
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    for (raw, 0..) |byte, index| {
        if (quote != 0) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == quote) quote = 0;
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
        if (depth != 0 or index < minimum_start or
            (index != 0 and !std.ascii.isWhitespace(raw[index - 1])))
        {
            continue;
        }
        const words = [_]struct { text: []const u8, negated: bool }{
            .{ .text = "if", .negated = false },
            .{ .text = "unless", .negated = true },
        };
        for (words) |word| {
            if (word.text.len >= raw.len - index) continue;
            const end = index + word.text.len;
            if (std.ascii.eqlIgnoreCase(raw[index..end], word.text) and
                std.ascii.isWhitespace(raw[end]))
            {
                return .{ .start = index, .end = end, .negated = word.negated };
            }
        }
    }
    return null;
}

fn parsePostfixLoopCondition(raw_input: []const u8) ?PostfixLoopCondition {
    const raw = std.mem.trim(u8, raw_input, " \t\r\n\x0c;");
    const marker = findFirstPostfixConditionMarker(raw, 0) orelse return null;
    if (marker.start != 0) return null;
    const body = std.mem.trimLeft(u8, raw[marker.end..], " \t\r\n\x0c");
    const next = findFirstPostfixConditionMarker(body, 0);
    const expression_end = if (next) |found| found.start else body.len;
    const expression = std.mem.trim(u8, body[0..expression_end], " \t\r\n\x0c;");
    if (expression.len == 0) return null;
    return .{
        .expression = expression,
        .remaining = if (next) |found| body[found.start..] else "",
        .negated = marker.negated,
    };
}

fn splitPostfixCondition(raw: []const u8) PostfixSplit {
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    var candidate: ?struct { start: usize, end: usize, negated: bool } = null;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        if (quote != 0) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == quote) quote = 0;
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
        if (depth != 0 or !std.ascii.isWhitespace(byte)) continue;
        var word_start = index;
        while (word_start < raw.len and std.ascii.isWhitespace(raw[word_start])) word_start += 1;
        const words = [_]struct { text: []const u8, negated: bool }{
            .{ .text = "if", .negated = false },
            .{ .text = "unless", .negated = true },
        };
        for (words) |word| {
            if (word_start + word.text.len <= raw.len and
                std.ascii.eqlIgnoreCase(raw[word_start .. word_start + word.text.len], word.text) and
                word_start + word.text.len < raw.len and
                std.ascii.isWhitespace(raw[word_start + word.text.len]))
            {
                candidate = .{
                    .start = word_start,
                    .end = word_start + word.text.len,
                    .negated = word.negated,
                };
            }
        }
    }
    const found = candidate orelse return .{ .declaration = trimRange(raw, .{ .start = 0, .end = raw.len }) };
    const declaration = trimRange(raw, .{ .start = 0, .end = found.start });
    const expression = trimRange(raw, .{ .start = found.end, .end = raw.len });
    if (declaration.start == declaration.end or expression.start == expression.end) {
        return .{ .declaration = trimRange(raw, .{ .start = 0, .end = raw.len }) };
    }
    return .{
        .declaration = declaration,
        .condition = .{ .expression = expression, .negated = found.negated },
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
    while (cursor < body.len and !std.ascii.isWhitespace(body[cursor]) and body[cursor] != ',') cursor += 1;
    const name = body[0..cursor];
    if (!validVariableName(name)) return null;
    while (cursor < body.len and std.ascii.isWhitespace(body[cursor])) cursor += 1;
    var index_name: ?[]const u8 = null;
    if (cursor < body.len and body[cursor] == ',') {
        cursor += 1;
        while (cursor < body.len and std.ascii.isWhitespace(body[cursor])) cursor += 1;
        const index_start = cursor;
        while (cursor < body.len and !std.ascii.isWhitespace(body[cursor])) cursor += 1;
        const candidate = body[index_start..cursor];
        if (!validVariableName(candidate)) return null;
        index_name = candidate;
        while (cursor < body.len and std.ascii.isWhitespace(body[cursor])) cursor += 1;
    }
    if (cursor + 2 > body.len or !std.ascii.eqlIgnoreCase(body[cursor .. cursor + 2], "in")) {
        return null;
    }
    cursor += 2;
    if (cursor < body.len and !std.ascii.isWhitespace(body[cursor])) return null;
    const items = std.mem.trim(u8, body[cursor..], " \t\r\n\x0c;");
    if (items.len == 0) return null;
    return .{ .name = name, .index_name = index_name, .items = items };
}

fn parsePostfixLoop(raw_input: []const u8) ?PostfixLoop {
    const raw = std.mem.trim(u8, raw_input, " \t\r\n\x0c;");
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    var candidate: ?usize = null;
    var index: usize = 0;
    while (index + 5 <= raw.len) : (index += 1) {
        const byte = raw[index];
        if (quote != 0) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == quote) quote = 0;
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
        if (depth == 0 and std.mem.startsWith(u8, raw[index..], " for ")) candidate = index;
    }
    const marker = candidate orelse return null;
    const expression = std.mem.trim(u8, raw[0..marker], " \t\r\n\x0c;");
    const header_raw = std.mem.trim(u8, raw[marker + 1 ..], " \t\r\n\x0c;");
    if (expression.len == 0) return null;
    var header = parseLoop(header_raw) orelse return null;
    var conditions: []const u8 = "";
    if (findFirstPostfixConditionMarker(header.items, 0)) |condition| {
        if (condition.start == 0) return null;
        conditions = std.mem.trim(u8, header.items[condition.start..], " \t\r\n\x0c;");
        header.items = std.mem.trim(u8, header.items[0..condition.start], " \t\r\n\x0c;");
        if (header.items.len == 0) return null;
        var remaining = conditions;
        while (std.mem.trim(u8, remaining, " \t\r\n\x0c;").len != 0) {
            const parsed = parsePostfixLoopCondition(remaining) orelse return null;
            remaining = parsed.remaining;
        }
    }
    return .{ .expression = expression, .header = header, .conditions = conditions };
}

fn startsWordAscii(raw: []const u8, expected: []const u8) bool {
    if (raw.len < expected.len or !std.ascii.eqlIgnoreCase(raw[0..expected.len], expected)) {
        return false;
    }
    return raw.len == expected.len or std.ascii.isWhitespace(raw[expected.len]) or
        raw[expected.len] == '(' or raw[expected.len] == ';';
}

fn parseExtendDirective(raw: []const u8) ?ExtendDirective {
    const plural = startsWordAscii(raw, "@extends");
    const keyword: []const u8 = if (plural)
        "@extends"
    else if (startsWordAscii(raw, "@extend"))
        "@extend"
    else
        return null;
    return .{
        .targets = std.mem.trim(u8, raw[keyword.len..], " \t\r\n\x0c;"),
        .plural = plural,
    };
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

fn closingQuote(raw: []const u8, opening: usize) ?usize {
    if (opening >= raw.len or (raw[opening] != '\'' and raw[opening] != '"')) return null;
    const quote = raw[opening];
    var escaped = false;
    var index = opening + 1;
    while (index < raw.len) : (index += 1) {
        if (escaped) {
            escaped = false;
        } else if (raw[index] == '\\') {
            escaped = true;
        } else if (raw[index] == quote) {
            return index;
        }
    }
    return null;
}

fn sourceQuotedValue(raw: []const u8) ?u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\x0c;");
    if (trimmed.len < 2 or (trimmed[0] != '\'' and trimmed[0] != '"') or
        closingQuote(trimmed, 0) != trimmed.len - 1)
    {
        return null;
    }
    return trimmed[0];
}

fn commentEndsContinuedLine(raw: []const u8, comment_end: usize) bool {
    var cursor = comment_end;
    while (cursor < raw.len and
        (raw[cursor] == ' ' or raw[cursor] == '\t' or raw[cursor] == '\x0c'))
    {
        cursor += 1;
    }
    if (cursor >= raw.len or (raw[cursor] != '\r' and raw[cursor] != '\n')) return false;
    while (cursor < raw.len and std.ascii.isWhitespace(raw[cursor])) cursor += 1;
    return cursor < raw.len;
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

fn splitTopLevelPropertyItems(
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
        if (escaped) {
            escaped = false;
            if (start == null) start = index;
            continue;
        }
        if (byte == '\\') {
            if (start == null) start = index;
            escaped = true;
            continue;
        }
        if (quote != 0) {
            if (byte == quote) quote = 0;
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
        if (depth == 0 and (std.ascii.isWhitespace(byte) or byte == '/')) {
            if (start) |item_start| {
                try output.append(allocator, .{ .start = item_start, .end = index });
                start = null;
            }
            if (byte == '/') {
                try output.append(allocator, .{ .start = index, .end = index + 1 });
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

fn isLiteralSlash(value: native_value.Value) bool {
    return switch (value) {
        .string, .selector => |item| !item.quoted and std.mem.eql(u8, item.bytes, "/"),
        else => false,
    };
}

fn listContainsLiteralSlash(items: []const native_value.Value) bool {
    for (items) |item| if (isLiteralSlash(item)) return true;
    return false;
}

fn literalSlashAdjacent(items: []const native_value.Value, index: usize) bool {
    return index > 0 and index < items.len and
        (isLiteralSlash(items[index - 1]) or isLiteralSlash(items[index]));
}

fn collectSerializedValueBoundaries(
    allocator: std.mem.Allocator,
    serialized: []const u8,
    leaf_ends: *std.ArrayList(usize),
    comma_ends: *std.ArrayList(usize),
) std.mem.Allocator.Error!void {
    var index: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    var in_item = false;
    while (index < serialized.len) {
        const byte = serialized[index];
        if (escaped) {
            escaped = false;
            index += 1;
            continue;
        }
        if (byte == '\\') {
            if (depth == 0 and !in_item) in_item = true;
            escaped = true;
            index += 1;
            continue;
        }
        if (quote != 0) {
            if (byte == quote) quote = 0;
            index += 1;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            if (depth == 0 and !in_item) in_item = true;
            quote = byte;
            index += 1;
            continue;
        }
        if (byte == '(' or byte == '[' or byte == '{') {
            if (depth == 0 and !in_item) in_item = true;
            depth += 1;
            index += 1;
            continue;
        }
        if (byte == ')' or byte == ']' or byte == '}') {
            depth -|= 1;
            index += 1;
            continue;
        }
        if (depth == 0 and byte == ',') {
            if (in_item) {
                try leaf_ends.append(allocator, index);
                in_item = false;
            }
            index += 1;
            while (index < serialized.len and std.ascii.isWhitespace(serialized[index])) {
                index += 1;
            }
            try comma_ends.append(allocator, index);
            continue;
        }
        if (depth == 0 and std.ascii.isWhitespace(byte)) {
            if (in_item) {
                try leaf_ends.append(allocator, index);
                in_item = false;
            }
            while (index < serialized.len and std.ascii.isWhitespace(serialized[index])) {
                index += 1;
            }
            continue;
        }
        if (depth == 0 and !in_item) in_item = true;
        index += 1;
    }
    if (in_item) try leaf_ends.append(allocator, serialized.len);
}

fn joinArgumentIsOperation(raw: []const u8) bool {
    return parseAssignment(raw) != null or
        parseDefinedTernary(raw) != null or
        parseGenericTernary(raw) != null or
        parseUnitCast(raw) != null or
        findLogicalOperator(raw, .or_value) != null or
        findLogicalOperator(raw, .and_value) != null or
        findGenericBinary(raw) != null or
        findRangeOperator(raw) != null or
        findComparison(raw) != null or
        unaryPrefix(raw) != null;
}

fn parseUnitCast(raw: []const u8) ?UnitCast {
    if (raw.len >= 3 and raw[0] == '(') {
        const closing = matchingParen(raw, 0) orelse return null;
        const suffix = std.mem.trim(u8, raw[closing + 1 ..], " \t\r\n\x0c");
        if (suffix.len > 0 and isStylusUnit(suffix)) {
            return .{ .expression = trimRange(raw, .{ .start = 1, .end = closing }), .unit = suffix };
        }
    }
    const whitespace = std.mem.lastIndexOfAny(u8, raw, " \t") orelse return null;
    var unit_start = whitespace;
    while (unit_start < raw.len and std.ascii.isWhitespace(raw[unit_start])) unit_start += 1;
    const unit = std.mem.trim(u8, raw[unit_start..], " \t\r\n\x0c");
    if (!isStylusUnit(unit)) return null;
    const expression = trimRange(raw, .{ .start = 0, .end = whitespace });
    if (expression.start == expression.end) return null;
    return .{ .expression = expression, .unit = unit };
}

fn isStylusUnit(unit: []const u8) bool {
    inline for (.{
        "%",   "px",   "em",   "rem",  "ex", "ch", "cm", "mm",  "q",   "in",   "pt",   "pc",
        "deg", "grad", "rad",  "turn", "s",  "ms", "Hz", "kHz", "dpi", "dpcm", "dppx", "vw",
        "vh",  "vmin", "vmax", "fr",
    }) |candidate| if (std.mem.eql(u8, unit, candidate)) return true;
    return false;
}

fn findGenericBinary(raw: []const u8) ?GenericBinary {
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    var candidate: ?GenericBinary = null;
    for (raw, 0..) |byte, index| {
        if (quote != 0) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == quote) quote = 0;
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
        if (depth != 0 or (byte != '+' and byte != '-' and byte != '%' and byte != '*' and byte != '/')) continue;
        const previous = previousSignificantByte(raw, index);
        if ((byte == '+' or byte == '-') and
            (previous == null or std.mem.indexOfScalar(
                u8,
                "+-*/%~!<>=&|?:([{,",
                previous.?,
            ) != null))
        {
            continue;
        }
        if ((byte == '+' or byte == '-') and index > 0 and
            std.ascii.isWhitespace(raw[index - 1]) and index + 1 < raw.len and
            !std.ascii.isWhitespace(raw[index + 1]) and
            (std.ascii.isDigit(raw[index + 1]) or raw[index + 1] == '.'))
        {
            continue;
        }
        if (byte == '%' and index > 0 and
            (std.ascii.isDigit(raw[index - 1]) or raw[index - 1] == '.') and
            (index + 1 == raw.len or std.ascii.isWhitespace(raw[index + 1]))) continue;
        if (byte == '-' and !((index > 0 and std.ascii.isWhitespace(raw[index - 1])) or
            (index + 1 < raw.len and std.ascii.isWhitespace(raw[index + 1])))) continue;
        const left = trimRange(raw, .{ .start = 0, .end = index });
        const right = trimRange(raw, .{ .start = index + 1, .end = raw.len });
        if (left.start == left.end or right.start == right.end) continue;
        const next = GenericBinary{ .left = left, .right = right, .operator = byte };
        const low_precedence = byte == '+' or byte == '-';
        const candidate_low = candidate != null and (candidate.?.operator == '+' or candidate.?.operator == '-');
        if (candidate == null or low_precedence or (!candidate_low and (byte == '%' or byte == '/'))) candidate = next;
    }
    return candidate;
}

fn previousSignificantByte(raw: []const u8, end: usize) ?u8 {
    var cursor = end;
    while (cursor > 0) {
        cursor -= 1;
        if (!std.ascii.isWhitespace(raw[cursor])) return raw[cursor];
    }
    return null;
}

fn findRangeOperator(raw: []const u8) ?RangeExpression {
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    var index: usize = 0;
    while (index + 1 < raw.len) : (index += 1) {
        const byte = raw[index];
        if (quote != 0) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == quote) quote = 0;
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
        if (depth != 0 or byte != '.' or raw[index + 1] != '.') continue;
        const end = if (index + 2 < raw.len and raw[index + 2] == '.') index + 3 else index + 2;
        const left = trimRange(raw, .{ .start = 0, .end = index });
        const right = trimRange(raw, .{ .start = end, .end = raw.len });
        if (left.start == left.end or right.start == right.end) return null;
        return .{ .left = left, .right = right, .inclusive = end == index + 2 };
    }
    return null;
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
        if (wordAt(raw, index, "isnt")) return .{
            .start = index,
            .end = index + 4,
            .operator = .not_equal,
        };
        if (wordAt(raw, index, "is")) {
            var end = index + 2;
            while (end < raw.len and std.ascii.isWhitespace(raw[end])) end += 1;
            if (wordAt(raw, end, "not")) return .{
                .start = index,
                .end = end + 3,
                .operator = .not_equal,
            };
            return .{ .start = index, .end = index + 2, .operator = .equal };
        }
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

fn wordAt(raw: []const u8, start: usize, word: []const u8) bool {
    if (start + word.len > raw.len or !std.ascii.eqlIgnoreCase(raw[start .. start + word.len], word)) return false;
    const before = start == 0 or std.ascii.isWhitespace(raw[start - 1]) or raw[start - 1] == '(';
    const after = start + word.len == raw.len or std.ascii.isWhitespace(raw[start + word.len]) or raw[start + word.len] == ')';
    return before and after;
}

fn isTruthy(value: *const native_value.Value) bool {
    return switch (value.*) {
        .null_value => false,
        .boolean => |item| item,
        .number => |number| number.value != 0,
        .string => |string| string.bytes.len != 0,
        .list => |list| list.truthy_override orelse true,
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

fn parseGenericTernary(raw: []const u8) ?GenericTernary {
    const bounds = trimRange(raw, .{ .start = 0, .end = raw.len });
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    var nested: usize = 0;
    var question: ?usize = null;
    var index = bounds.start;
    while (index < bounds.end) : (index += 1) {
        const byte = raw[index];
        if (quote != 0) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == quote) quote = 0;
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
            if (question == null) question = index else nested += 1;
            continue;
        }
        if (byte == ':' and question != null) {
            if (nested > 0) {
                nested -= 1;
                continue;
            }
            const condition = trimRange(raw, .{ .start = bounds.start, .end = question.? });
            const when_true = trimRange(raw, .{ .start = question.? + 1, .end = index });
            const when_false = trimRange(raw, .{ .start = index + 1, .end = bounds.end });
            if (condition.start == condition.end or when_true.start == when_true.end or
                when_false.start == when_false.end) return null;
            return .{
                .condition = condition,
                .when_true = when_true,
                .when_false = when_false,
            };
        }
    }
    return null;
}

fn findLogicalOperator(raw: []const u8, kind: LogicalKind) ?LogicalExpression {
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        if (quote != 0) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == quote) quote = 0;
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
        const symbolic: []const u8 = switch (kind) {
            .or_value => "||",
            .and_value => "&&",
        };
        const word: []const u8 = switch (kind) {
            .or_value => "or",
            .and_value => "and",
        };
        var operator_end: ?usize = null;
        if (index + symbolic.len <= raw.len and
            std.mem.eql(u8, raw[index .. index + symbolic.len], symbolic))
        {
            operator_end = index + symbolic.len;
        } else if (index + word.len <= raw.len and
            std.ascii.eqlIgnoreCase(raw[index .. index + word.len], word) and
            (index == 0 or std.ascii.isWhitespace(raw[index - 1])) and
            (index + word.len == raw.len or std.ascii.isWhitespace(raw[index + word.len])))
        {
            operator_end = index + word.len;
        }
        if (operator_end) |end| {
            const left = trimRange(raw, .{ .start = 0, .end = index });
            const right = trimRange(raw, .{ .start = end, .end = raw.len });
            if (left.start != left.end and right.start != right.end) return .{ .left = left, .right = right };
        }
    }
    return null;
}

fn unaryPrefix(raw: []const u8) ?UnaryPrefix {
    if (raw.len == 0) return null;
    if (startsWordAscii(raw, "not")) {
        var end: usize = 3;
        while (end < raw.len and std.ascii.isWhitespace(raw[end])) end += 1;
        if (end < raw.len) return .{ .kind = .logical_not, .end = end };
    }
    const kind: UnaryKind = switch (raw[0]) {
        '!' => .logical_not,
        '+' => .positive,
        '-' => if (raw.len > 1 and (std.ascii.isAlphabetic(raw[1]) or raw[1] == '_')) return null else .negative,
        '~' => .bitwise_not,
        else => return null,
    };
    var end: usize = 1;
    while (end < raw.len and std.ascii.isWhitespace(raw[end])) end += 1;
    if (end >= raw.len) return null;
    return .{ .kind = kind, .end = end };
}

fn stripOuterParentheses(raw: []const u8) []const u8 {
    var result = std.mem.trim(u8, raw, " \t\r\n\x0c;");
    while (result.len >= 2 and result[0] == '(') {
        const closing = matchingParen(result, 0) orelse break;
        if (closing != result.len - 1) break;
        result = std.mem.trim(u8, result[1 .. result.len - 1], " \t\r\n\x0c");
    }
    return result;
}

const IndexExpression = struct {
    base: ByteRange,
    index: ByteRange,
};

fn findTrailingIndex(raw: []const u8) ?IndexExpression {
    if (raw.len < 3 or raw[raw.len - 1] != ']') return null;
    var quote: u8 = 0;
    var escaped = false;
    var round_depth: usize = 0;
    var square_depth: usize = 0;
    var opening: ?usize = null;
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
            '(' => round_depth += 1,
            ')' => round_depth -|= 1,
            '[' => {
                if (round_depth == 0 and square_depth == 0) opening = index;
                square_depth += 1;
            },
            ']' => {
                if (square_depth == 0) return null;
                square_depth -= 1;
                if (round_depth == 0 and square_depth == 0 and index != raw.len - 1) opening = null;
            },
            else => {},
        }
    }
    if (quote != 0 or round_depth != 0 or square_depth != 0) return null;
    const open = opening orelse return null;
    const base = trimRange(raw, .{ .start = 0, .end = open });
    const index = trimRange(raw, .{ .start = open + 1, .end = raw.len - 1 });
    if (base.start == base.end or index.start == index.end) return null;
    return .{ .base = base, .index = index };
}

fn normalizeIndex(index: i64, length: usize) ?usize {
    const signed_length: i64 = std.math.cast(i64, length) orelse return null;
    const normalized = if (index < 0) index + signed_length else index;
    if (normalized < 0 or normalized >= signed_length) return null;
    return @intCast(normalized);
}

fn currentPropertyArgumentIndex(raw_input: []const u8) ?usize {
    const raw = std.mem.trim(u8, raw_input, " \t\r\n\x0c;");
    const prefix = "current-property[";
    if (!std.mem.startsWith(u8, raw, prefix) or raw.len <= prefix.len + 1 or
        raw[raw.len - 1] != ']')
    {
        return null;
    }
    return std.fmt.parseUnsigned(usize, raw[prefix.len .. raw.len - 1], 10) catch null;
}

fn memberChainEnd(raw: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < raw.len) {
        if (raw[cursor] == '.') {
            if (cursor + 1 >= raw.len or !isNameStart(raw, cursor + 1)) break;
            cursor = nameEnd(raw, cursor + 1);
            continue;
        }
        if (raw[cursor] == '[') {
            const closing = std.mem.indexOfScalarPos(u8, raw, cursor + 1, ']') orelse break;
            cursor = closing + 1;
            continue;
        }
        break;
    }
    return cursor;
}

fn nameEql(left: []const u8, right: []const u8) bool {
    return native_lexer.identifierEqlIgnoreCaseAscii(left, right);
}

fn isBuiltinCallableName(name: []const u8) bool {
    if (isDeferredBuiltin(name)) return true;
    inline for (.{
        "rgb",     "rgba",   "hsl",      "hsla",       "type", "length",  "ceil",               "floor",      "round",
        "sin",     "cos",    "tan",      "first",      "last", "index",   "percentage",         "fade-in",    "fade-out",
        "lighten", "darken", "saturate", "desaturate", "mix",  "tint",    "shade",              "complement", "grayscale",
        "invert",  "split",  "substr",   "slice",      "join", "unquote", "percent-to-decimal", "selector",
    }) |builtin| if (nameEql(name, builtin)) return true;
    return false;
}

fn inputContainsBuiltinCall(input: []const u8) bool {
    var index: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    while (index < input.len) {
        const byte = input[index];
        if (quote != 0) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == quote) quote = 0;
            index += 1;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            index += 1;
            continue;
        }
        if (!isNameStart(input, index)) {
            index += 1;
            continue;
        }
        const end = nameEnd(input, index);
        var opening = end;
        while (opening < input.len and std.ascii.isWhitespace(input[opening])) opening += 1;
        if (opening < input.len and input[opening] == '(' and
            isBuiltinCallableName(input[index..end])) return true;
        index = end;
    }
    return false;
}

fn findTopLevelSequence(raw: []const u8, sequence: []const u8) ?usize {
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    var index: usize = 0;
    while (index + sequence.len <= raw.len) : (index += 1) {
        const byte = raw[index];
        if (quote != 0) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == quote) quote = 0;
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
        if (depth == 0 and std.mem.eql(u8, raw[index .. index + sequence.len], sequence)) return index;
    }
    return null;
}

fn valueIsType(value: native_value.Value, expected: []const u8, engine: *const Engine) bool {
    if (nameEql(expected, "null")) return value == .null_value;
    if (nameEql(expected, "bool") or nameEql(expected, "boolean")) return value == .boolean;
    if (nameEql(expected, "unit") or nameEql(expected, "number")) return value == .number;
    if (nameEql(expected, "rgba") or nameEql(expected, "hsla") or nameEql(expected, "color")) return value == .color;
    if (nameEql(expected, "string")) return value == .string and value.string.quoted;
    if (nameEql(expected, "ident")) return value == .string and !value.string.quoted;
    if (nameEql(expected, "function")) return value == .callable or
        (value == .string and (engine.findCallable(value.string.bytes) != null or isBuiltinCallableName(value.string.bytes)));
    if (nameEql(expected, "object")) return value == .map;
    return false;
}

fn stylusValueEqual(left: native_value.Value, right: native_value.Value) bool {
    if (native_value.eql(left, right)) return true;
    if (left == .string and right == .string) return std.mem.eql(u8, left.string.bytes, right.string.bytes);
    return false;
}

fn singleUnit(number: native_value.Number) ?[]const u8 {
    if (number.numerator_units.len == 1 and number.denominator_units.len == 0) {
        return number.numerator_units[0];
    }
    return null;
}

fn numberScalar(value: native_value.Value) ?f64 {
    if (value != .number or value.number.denominator_units.len != 0 or
        value.number.numerator_units.len > 1)
    {
        return null;
    }
    return value.number.value;
}

fn integerScalar(value: native_value.Value) ?i64 {
    const number = numberScalar(value) orelse return null;
    if (!std.math.isFinite(number) or @trunc(number) != number or
        number < @as(f64, @floatFromInt(std.math.minInt(i64))) or
        number > @as(f64, @floatFromInt(std.math.maxInt(i64))))
    {
        return null;
    }
    return @intFromFloat(number);
}

fn percentScalar(value: native_value.Value) ?f64 {
    return numberScalar(value);
}

fn alphaScalar(value: native_value.Value) ?f64 {
    const scalar = numberScalar(value) orelse return null;
    if (value.number.numerator_units.len == 1) {
        if (!std.mem.eql(u8, value.number.numerator_units[0], "%")) return null;
        return scalar / 100;
    }
    return scalar;
}

fn channelScalar(value: native_value.Value) ?f64 {
    const scalar = numberScalar(value) orelse return null;
    if (value.number.numerator_units.len == 1) {
        if (!std.mem.eql(u8, value.number.numerator_units[0], "%")) return null;
        return scalar * 2.55;
    }
    return scalar;
}

fn angleScalar(value: native_value.Value) ?f64 {
    const scalar = numberScalar(value) orelse return null;
    const unit = singleUnit(value.number) orelse return scalar;
    if (std.mem.eql(u8, unit, "deg")) return scalar;
    if (std.mem.eql(u8, unit, "rad")) return std.math.radiansToDegrees(scalar);
    if (std.mem.eql(u8, unit, "turn")) return scalar * 360;
    if (std.mem.eql(u8, unit, "grad")) return scalar * 0.9;
    return null;
}

fn angleRadians(number: native_value.Number) ?f64 {
    const unit = singleUnit(number) orelse return number.value;
    if (std.mem.eql(u8, unit, "deg")) return std.math.degreesToRadians(number.value);
    if (std.mem.eql(u8, unit, "rad")) return number.value;
    if (std.mem.eql(u8, unit, "turn")) return number.value * 2 * std.math.pi;
    if (std.mem.eql(u8, unit, "grad")) return std.math.degreesToRadians(number.value * 0.9);
    return null;
}

fn stringBytes(value: native_value.Value) ?[]const u8 {
    return switch (value) {
        .string, .selector => |string| string.bytes,
        else => null,
    };
}

fn colorValue(value: native_value.Value) ?native_value.Color {
    return switch (value) {
        .color => |color| color,
        .string => |string| native_color.parseLiteral(string.bytes),
        else => null,
    };
}

fn optionalUnitEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn normalizeSliceBound(index: i64, length: usize) usize {
    const signed_length: i64 = std.math.cast(i64, length) orelse return length;
    const normalized = if (index < 0) index + signed_length else index;
    if (normalized <= 0) return 0;
    if (normalized >= signed_length) return length;
    return @intCast(normalized);
}

fn colorLuminosity(color: native_value.Color) native_color.Error!f64 {
    const channels = try native_color.toRgb(color);
    var linear: [3]f64 = undefined;
    for (channels[0..3], 0..) |channel, index| {
        const normalized = @round(channel) / 255;
        linear[index] = if (normalized <= 0.03928)
            normalized / 12.92
        else
            std.math.pow(f64, (normalized + 0.055) / 1.055, 2.4);
    }
    return roundDecimal(linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722, 15);
}

const StylusContrast = struct {
    ratio: f64,
    error_value: f64,
    minimum: f64,
    maximum: f64,
};

fn stylusContrast(
    foreground: native_value.Color,
    background: native_value.Color,
) native_color.Error!StylusContrast {
    const background_channels = try native_color.toRgb(background);
    if (background_channels[3] >= 1) {
        const ratio = try stylusContrastRatio(foreground, background);
        return .{
            .ratio = ratio,
            .error_value = 0,
            .minimum = ratio,
            .maximum = ratio,
        };
    }

    const black = native_color.parseLiteral("black").?;
    const white = native_color.parseLiteral("white").?;
    const on_black = try stylusContrastRatio(
        foreground,
        try stylusBlend(background, black),
    );
    const on_white = try stylusContrastRatio(
        foreground,
        try stylusBlend(background, white),
    );
    const maximum = @max(on_black, on_white);
    var closest_channels: [3]f64 = undefined;
    const foreground_channels = try native_color.toRgb(foreground);
    for (&closest_channels, 0..) |*channel, index| {
        channel.* = std.math.clamp(
            (foreground_channels[index] -
                background_channels[index] * background_channels[3]) /
                (1 - background_channels[3]),
            0,
            255,
        );
    }
    const closest = try native_color.rgb(
        @round(closest_channels[0]),
        @round(closest_channels[1]),
        @round(closest_channels[2]),
        1,
    );
    const minimum = try stylusContrastRatio(
        foreground,
        try stylusBlend(background, closest),
    );
    return .{
        .ratio = @round((minimum + maximum) * 50) / 100,
        .error_value = @round((maximum - minimum) * 50) / 100,
        .minimum = minimum,
        .maximum = maximum,
    };
}

fn stylusContrastRatio(
    foreground_input: native_value.Color,
    background: native_value.Color,
) native_color.Error!f64 {
    var foreground = foreground_input;
    const foreground_channels = try native_color.toRgb(foreground);
    if (foreground_channels[3] < 1) foreground = try stylusBlend(foreground, background);
    const background_luminosity = try colorLuminosity(background) + 0.05;
    const foreground_luminosity = try colorLuminosity(foreground) + 0.05;
    const ratio = @max(background_luminosity, foreground_luminosity) /
        @min(background_luminosity, foreground_luminosity);
    return @round(ratio * 10) / 10;
}

fn stylusBlend(
    foreground: native_value.Color,
    background: native_value.Color,
) native_color.Error!native_value.Color {
    const top = try native_color.toRgb(foreground);
    const bottom = try native_color.toRgb(background);
    return native_color.rgb(
        @round(top[0] * top[3] + bottom[0] * (1 - top[3])),
        @round(top[1] * top[3] + bottom[1] * (1 - top[3])),
        @round(top[2] * top[3] + bottom[2] * (1 - top[3])),
        top[3] + bottom[3] - top[3] * bottom[3],
    );
}

fn stylusTransparentify(
    top_color: native_value.Color,
    bottom_color: native_value.Color,
    explicit_alpha: ?f64,
) native_color.Error!native_value.Color {
    var top = try native_color.toRgb(top_color);
    var bottom = try native_color.toRgb(bottom_color);
    for (0..3) |index| {
        top[index] = @round(top[index]);
        bottom[index] = @round(bottom[index]);
    }

    var best_alpha = explicit_alpha orelse blk: {
        var maximum: ?f64 = null;
        for (0..3) |index| {
            const difference = top[index] - bottom[index];
            const limit: f64 = if (difference > 0) 255 else 0;
            const denominator = limit - bottom[index];
            if (denominator == 0) return error.InvalidColor;
            const candidate = difference / denominator;
            if (!std.math.isFinite(candidate)) return error.InvalidColor;
            maximum = if (maximum) |current| @max(current, candidate) else candidate;
        }
        break :blk maximum orelse return error.InvalidColor;
    };
    if (!std.math.isFinite(best_alpha)) return error.InvalidColor;
    best_alpha = std.math.clamp(best_alpha, 0, 1);

    var result: [3]f64 = undefined;
    for (&result, 0..) |*channel, index| {
        channel.* = @round(if (best_alpha == 0)
            bottom[index]
        else
            bottom[index] + (top[index] - bottom[index]) / best_alpha);
    }
    return native_color.rgb(
        result[0],
        result[1],
        result[2],
        @round(best_alpha * 100) / 100,
    );
}

fn isUnicodeRangeValue(raw: []const u8) bool {
    if (raw.len < 3 or (raw[0] != 'u' and raw[0] != 'U') or raw[1] != '+') return false;
    var index: usize = 2;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        if (std.ascii.isHex(byte) or byte == '?' or byte == '-' or byte == ',' or
            std.ascii.isWhitespace(byte))
        {
            continue;
        }
        if ((byte == 'u' or byte == 'U') and index + 1 < raw.len and raw[index + 1] == '+') {
            index += 1;
            continue;
        }
        return false;
    }
    return true;
}

const ColorQuantization = enum { down, nearest };

fn quantizeColor(
    color: native_value.Color,
    mode: ColorQuantization,
) native_color.Error!native_value.Color {
    const channels = try native_color.toRgb(color);
    const red = if (mode == .nearest) @round(channels[0]) else @floor(channels[0]);
    const green = if (mode == .nearest) @round(channels[1]) else @floor(channels[1]);
    const blue = if (mode == .nearest) @round(channels[2]) else @floor(channels[2]);
    return native_color.rgb(red, green, blue, @trunc(channels[3] * 1000) / 1000);
}

fn adjustStylusSaturation(
    color: native_value.Color,
    amount: f64,
) native_color.Error!native_value.Color {
    var channels = try native_color.toHsl(color);
    channels[1] += amount;
    return native_color.hsl(channels[0], channels[1], channels[2], channels[3]);
}

fn roundDecimal(value: f64, places: i32) f64 {
    const scale = std.math.pow(f64, 10, @floatFromInt(places));
    const rounded = @round(value * scale) / scale;
    return if (@abs(rounded) < 1 / scale) 0 else rounded;
}

fn callHasEmptyArgument(
    allocator: std.mem.Allocator,
    raw: []const u8,
    call: Call,
) std.mem.Allocator.Error!bool {
    if (call.arguments.start == call.arguments.end) return false;
    var arguments = try splitTopLevel(allocator, raw[call.arguments.start..call.arguments.end], ',');
    defer arguments.deinit(allocator);
    for (arguments.items) |range| {
        if (std.mem.trim(u8, raw[call.arguments.start + range.start .. call.arguments.start + range.end], " \t\r\n\x0c").len == 0) {
            return true;
        }
    }
    return false;
}

fn boundedReplacementSize(
    input: []const u8,
    needle: []const u8,
    replacement: []const u8,
    maximum: usize,
) ?usize {
    if (needle.len == 0) return null;
    var output_len: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, input, cursor, needle)) |match| {
        output_len = std.math.add(usize, output_len, match - cursor) catch return null;
        output_len = std.math.add(usize, output_len, replacement.len) catch return null;
        if (output_len > maximum) return null;
        cursor = match + needle.len;
    }
    output_len = std.math.add(usize, output_len, input.len - cursor) catch return null;
    return if (output_len <= maximum) output_len else null;
}

fn baseConvert(
    value: u64,
    base: u8,
    buffer: []u8,
) ?[]const u8 {
    if (base < 2 or base > 36 or buffer.len == 0) return null;
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var remaining = value;
    var cursor = buffer.len;
    while (remaining > 0) {
        if (cursor == 0) return null;
        cursor -= 1;
        buffer[cursor] = digits[@intCast(remaining % base)];
        remaining /= base;
    }
    if (cursor == buffer.len) {
        cursor -= 1;
        buffer[cursor] = '0';
    }
    return buffer[cursor..];
}

fn serializeStylusNumberForStyle(
    value: f64,
    output_style: OutputStyle,
    buffer: *[native_numeric.max_serialized_bytes]u8,
) error{ InvalidNumber, SerializationLimitExceeded }![]const u8 {
    if (!std.math.isFinite(value)) return error.InvalidNumber;
    const normalized = if (value == 0) @as(f64, 0) else value;
    const serialized = std.fmt.bufPrint(buffer, "{d}", .{normalized}) catch
        return error.SerializationLimitExceeded;
    if (output_style != .compressed or normalized <= -1 or normalized >= 1 or normalized == 0) {
        return serialized;
    }
    if (std.mem.startsWith(u8, serialized, "0.")) return serialized[1..];
    if (std.mem.startsWith(u8, serialized, "-0.")) {
        std.mem.copyForwards(u8, buffer[1 .. serialized.len - 1], serialized[2..]);
        return buffer[0 .. serialized.len - 1];
    }
    return serialized;
}

fn omitCompressedZeroUnit(
    value: f64,
    units: []const u8,
    output_style: OutputStyle,
) bool {
    if (output_style != .compressed or value != 0) return false;
    for ([_][]const u8{ "%", "s", "ms", "deg", "fr" }) |retained| {
        if (std.mem.eql(u8, units, retained)) return false;
    }
    return true;
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
        if (index + 1 < raw.len and raw[index + 1] == '=') continue;
        const prefix = if (index > 0) raw[index - 1] else 0;
        const has_prefix = std.mem.indexOfScalar(u8, "?+-*/%:", prefix) != null;
        const operator_start = if (has_prefix) index - 1 else index;
        const name = std.mem.trim(u8, raw[0..operator_start], " \t\r\n\x0c");
        const value = std.mem.trim(u8, raw[index + 1 ..], " \t\r\n\x0c");
        if (!validVariableName(name)) return null;
        return .{
            .name = name,
            .value = value,
            .conditional = prefix == '?',
            .operator = if (has_prefix and prefix != '?' and prefix != ':') prefix else null,
        };
    }
    return null;
}

fn parseMemberAssignment(raw_input: []const u8) ?MemberAssignment {
    const raw = std.mem.trim(u8, raw_input, " \t\r\n\x0c;");
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    var equals: ?usize = null;
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
            '=' => if (depth == 0) {
                equals = index;
                break;
            },
            else => {},
        }
    }
    const separator = equals orelse return null;
    const left = std.mem.trim(u8, raw[0..separator], " \t\r\n\x0c");
    const value = std.mem.trim(u8, raw[separator + 1 ..], " \t\r\n\x0c");
    if (left.len < 3) return null;
    if (!isNameStart(left, 0)) return null;
    const base_end = nameEnd(left, 0);
    const base = left[0..base_end];
    if (!validVariableName(base) or base_end >= left.len) return null;

    if (left[base_end] == '.') {
        const key = left[base_end + 1 ..];
        if (!validVariableName(key)) return null;
        return .{
            .base = base,
            .member = .{ .key = key },
            .value = value,
            .value_empty = value.len == 0,
        };
    }
    if (left[base_end] != '[' or left[left.len - 1] != ']') return null;
    const raw_key = std.mem.trim(u8, left[base_end + 1 .. left.len - 1], " \t\r\n\x0c");
    if (raw_key.len >= 2 and
        ((raw_key[0] == '\'' and raw_key[raw_key.len - 1] == '\'') or
            (raw_key[0] == '"' and raw_key[raw_key.len - 1] == '"')))
    {
        return .{
            .base = base,
            .member = .{ .key = raw_key[1 .. raw_key.len - 1] },
            .value = value,
            .value_empty = value.len == 0,
        };
    }
    const member: MemberReference = if (std.fmt.parseUnsigned(usize, raw_key, 10)) |index|
        .{ .index = index }
    else |_|
        .{ .expression = raw_key };
    return .{
        .base = base,
        .member = member,
        .value = value,
        .value_empty = value.len == 0,
    };
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

fn selectorBranchContainsPlaceholder(selector: []const u8) bool {
    var quote: u8 = 0;
    var escaped = false;
    for (selector, 0..) |byte, index| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (quote != 0) {
            if (byte == quote) quote = 0;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        if (byte == '$' and index + 1 < selector.len and
            (std.ascii.isAlphabetic(selector[index + 1]) or
                selector[index + 1] == '_' or selector[index + 1] == '-'))
        {
            return true;
        }
    }
    return false;
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

fn splitTopLevelOwnedStrings(
    allocator: std.mem.Allocator,
    raw: []const u8,
    delimiter: u8,
) std.mem.Allocator.Error!std.ArrayList([]u8) {
    var ranges = try splitTopLevel(allocator, raw, delimiter);
    defer ranges.deinit(allocator);
    var output: std.ArrayList([]u8) = .empty;
    errdefer {
        for (output.items) |item| allocator.free(item);
        output.deinit(allocator);
    }
    for (ranges.items) |range| {
        const item = std.mem.trim(u8, raw[range.start..range.end], " \t\r\n\x0c");
        const owned = try allocator.dupe(u8, item);
        output.append(allocator, owned) catch |failure| {
            allocator.free(owned);
            return failure;
        };
    }
    return output;
}

fn parseStylusMatchFlags(raw: []const u8) ?StylusMatchFlags {
    var flags = StylusMatchFlags{};
    for (raw) |flag| switch (flag) {
        'g' => {
            if (flags.global) return null;
            flags.global = true;
        },
        'i' => {
            if (flags.ignore_case) return null;
            flags.ignore_case = true;
        },
        'm' => {
            if (flags.multiline) return null;
            flags.multiline = true;
        },
        else => return null,
    };
    return flags;
}

fn parseStylusLiteralPattern(raw: []const u8) ?StylusLiteralPattern {
    var start: usize = 0;
    var end = raw.len;
    var anchor_start = false;
    var anchor_end = false;
    if (start < end and raw[start] == '^') {
        anchor_start = true;
        start += 1;
    }
    if (start < end and raw[end - 1] == '$') {
        anchor_end = true;
        end -= 1;
    }
    for (raw[start..end]) |byte| {
        if (std.mem.indexOfScalar(u8, "\\.^$*+?()[]{}|", byte) != null) return null;
    }
    return .{
        .bytes = raw[start..end],
        .anchor_start = anchor_start,
        .anchor_end = anchor_end,
    };
}

fn parseStylusStructuredMatchPattern(raw: []const u8) ?StylusStructuredMatchPattern {
    if (raw.len < 12 or !std.mem.startsWith(u8, raw, "^(")) return null;
    const alternatives_end = std.mem.indexOfScalarPos(u8, raw, 2, ')') orelse return null;
    if (alternatives_end + 3 >= raw.len or raw[alternatives_end + 1] != '?' or
        raw[alternatives_end + 2] != '(')
    {
        return null;
    }
    const alternatives = raw[2..alternatives_end];
    if (!validStylusRegexAlternatives(alternatives)) return null;

    const repeated_start = alternatives_end + 3;
    const repeated_end = std.mem.indexOfScalarPos(u8, raw, repeated_start, ')') orelse return null;
    if (!std.mem.eql(u8, raw[repeated_end + 1 ..], "(.*)")) return null;
    const repeated = raw[repeated_start..repeated_end];
    if (repeated.len < 6 or repeated[0] != '[') return null;
    const class_end = std.mem.indexOfScalarPos(u8, repeated, 1, ']') orelse return null;
    const character_class = repeated[1..class_end];
    if (character_class.len == 0) return null;
    const quantifier = repeated[class_end + 1 ..];
    if (quantifier.len < 4 or quantifier[0] != '{' or
        quantifier[quantifier.len - 2] != ',' or quantifier[quantifier.len - 1] != '}')
    {
        return null;
    }
    const minimum = std.fmt.parseInt(usize, quantifier[1 .. quantifier.len - 2], 10) catch
        return null;
    if (minimum == 0) return null;
    return .{
        .alternatives = alternatives,
        .character_class = character_class,
        .minimum = minimum,
    };
}

fn validStylusRegexAlternatives(raw: []const u8) bool {
    var alternatives = std.mem.splitScalar(u8, raw, '|');
    var count: usize = 0;
    while (alternatives.next()) |alternative| {
        if (alternative.len == 0) return false;
        for (alternative) |byte| {
            if (std.mem.indexOfScalar(u8, "\\.^$*+?()[]{}|", byte) != null) return false;
        }
        count += 1;
    }
    return count > 0;
}

fn stylusCharacterClassContains(raw: []const u8, target: u8, ignore_case: bool) bool {
    var index: usize = 0;
    while (index < raw.len) {
        if (index + 2 < raw.len and raw[index + 1] == '-') {
            const start = foldStylusMatchByte(raw[index], ignore_case);
            const end = foldStylusMatchByte(raw[index + 2], ignore_case);
            const folded = foldStylusMatchByte(target, ignore_case);
            if (start <= folded and folded <= end) return true;
            index += 3;
            continue;
        }
        if (foldStylusMatchByte(raw[index], ignore_case) ==
            foldStylusMatchByte(target, ignore_case)) return true;
        index += 1;
    }
    return false;
}

fn findStylusLiteralMatch(
    subject: []const u8,
    pattern: StylusLiteralPattern,
    flags: StylusMatchFlags,
    search_start: usize,
) ?ByteRange {
    if (pattern.bytes.len > subject.len or search_start > subject.len) return null;
    const terminal = subject.len - pattern.bytes.len;
    var index = search_start;
    while (index <= terminal) : (index += 1) {
        if (pattern.anchor_start and index != 0 and
            !(flags.multiline and subject[index - 1] == '\n'))
        {
            continue;
        }
        if (pattern.anchor_end and index + pattern.bytes.len != subject.len and
            !(flags.multiline and subject[index + pattern.bytes.len] == '\n'))
        {
            continue;
        }
        if (sliceEql(subject[index .. index + pattern.bytes.len], pattern.bytes, flags.ignore_case)) {
            return .{ .start = index, .end = index + pattern.bytes.len };
        }
        if (pattern.anchor_start and !flags.multiline) break;
    }
    return null;
}

fn sliceStartsWith(subject: []const u8, prefix: []const u8, ignore_case: bool) bool {
    return subject.len >= prefix.len and sliceEql(subject[0..prefix.len], prefix, ignore_case);
}

fn sliceEql(left: []const u8, right: []const u8, ignore_case: bool) bool {
    if (left.len != right.len) return false;
    if (!ignore_case) return std.mem.eql(u8, left, right);
    for (left, right) |left_byte, right_byte| {
        if (foldStylusMatchByte(left_byte, true) != foldStylusMatchByte(right_byte, true)) {
            return false;
        }
    }
    return true;
}

fn foldStylusMatchByte(byte: u8, ignore_case: bool) u8 {
    return if (ignore_case) std.ascii.toLower(byte) else byte;
}

fn quotedMatchValue(bytes: []const u8) native_value.Value {
    return .{ .string = .{ .bytes = bytes, .quoted = true } };
}

const QuotedSelectorUnit = union(enum) {
    byte: u8,
    closing_quote,
};

fn nextQuotedSelectorUnit(
    raw: []const u8,
    index: *usize,
    quote: u8,
) ?QuotedSelectorUnit {
    if (index.* >= raw.len) return null;
    const byte = raw[index.*];
    if (byte == quote) {
        index.* += 1;
        return .closing_quote;
    }
    if (byte == '\\' and index.* + 1 < raw.len) {
        const escaped = raw[index.* + 1];
        if (!std.ascii.isHex(escaped) and escaped != '\n' and escaped != '\r' and
            escaped != '\x0c')
        {
            index.* += 2;
            return .{ .byte = escaped };
        }
    }
    index.* += 1;
    return .{ .byte = byte };
}

fn selectorsEqualForExtension(left: []const u8, right: []const u8) bool {
    var left_index: usize = 0;
    var right_index: usize = 0;
    var quote: u8 = 0;
    while (left_index < left.len and right_index < right.len) {
        if (quote == 0) {
            const left_byte = left[left_index];
            if (left_byte != right[right_index]) return false;
            left_index += 1;
            right_index += 1;
            if (left_byte == '\'' or left_byte == '"') quote = left_byte;
            continue;
        }
        const left_unit = nextQuotedSelectorUnit(left, &left_index, quote) orelse
            return false;
        const right_unit = nextQuotedSelectorUnit(right, &right_index, quote) orelse
            return false;
        switch (left_unit) {
            .closing_quote => if (right_unit == .closing_quote) {
                quote = 0;
            } else return false,
            .byte => |left_byte| switch (right_unit) {
                .byte => |right_byte| if (left_byte != right_byte) return false,
                .closing_quote => return false,
            },
        }
    }
    return left_index == left.len and right_index == right.len and quote == 0;
}

fn selectorTokenIndex(selector: []const u8, target: []const u8) ?usize {
    if (target.len == 0) return null;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, selector, cursor, target)) |index| {
        const before_ok = index == 0 or !isSelectorNameByte(selector[index - 1]);
        const end = index + target.len;
        const after_ok = end == selector.len or !isSelectorNameByte(selector[end]);
        if (before_ok and after_ok) return index;
        cursor = index + 1;
    }
    return null;
}

fn selectorHasTopLevelCombinator(selector: []const u8) bool {
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    for (selector) |byte| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (quote != 0) {
            if (byte == quote) quote = 0;
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
        if (depth == 0 and
            (std.ascii.isWhitespace(byte) or std.mem.indexOfScalar(u8, ">+~", byte) != null))
        {
            return true;
        }
    }
    return false;
}

fn selectorArgumentBytes(value: *const native_value.Value) ?[]const u8 {
    return switch (value.*) {
        .string => |string| string.bytes,
        .selector => |selector| selector.bytes,
        else => null,
    };
}

fn selectorExistsQueryIsStringLike(query: []const u8) bool {
    if (query.len == 0 or looksNumeric(query) or
        std.ascii.eqlIgnoreCase(query, "true") or
        std.ascii.eqlIgnoreCase(query, "false") or
        std.ascii.eqlIgnoreCase(query, "null") or
        native_color.parseLiteral(query) != null)
    {
        return false;
    }
    return !(query.len >= 2 and query[0] == '{' and query[query.len - 1] == '}');
}

fn selectorStringNeedsStack(selector: []const u8) bool {
    const trimmed = std.mem.trim(u8, selector, " \t\r\n\x0c");
    return std.mem.indexOfScalar(u8, trimmed, '&') != null or
        std.mem.indexOf(u8, trimmed, "^[") != null or
        std.mem.startsWith(u8, trimmed, "../") or
        std.mem.startsWith(u8, trimmed, "~/") or
        (std.mem.startsWith(u8, trimmed, "/") and
            !std.mem.startsWith(u8, trimmed, "/deep"));
}

fn selectorBranchNeedsResolution(selector: []const u8) bool {
    return std.mem.indexOf(u8, selector, "^[") != null or
        std.mem.startsWith(u8, selector, "../") or
        std.mem.startsWith(u8, selector, "~/") or
        (std.mem.startsWith(u8, selector, "/") and
            !std.mem.startsWith(u8, selector, "/deep"));
}

const SelectorSlice = struct {
    start: usize,
    end: usize,
};

fn parseSelectorSlice(raw: []const u8, part_count: usize) ?SelectorSlice {
    const separator = std.mem.indexOf(u8, raw, "..") orelse return null;
    if (std.mem.indexOfPos(u8, raw, separator + 2, "..") != null) return null;
    const start_raw = std.mem.trim(u8, raw[0..separator], " \t\r\n\x0c");
    const end_raw = std.mem.trim(u8, raw[separator + 2 ..], " \t\r\n\x0c");
    if (start_raw.len == 0 or end_raw.len == 0) return null;
    const first = selectorSliceIndex(start_raw, part_count) orelse return null;
    const second = selectorSliceIndex(end_raw, part_count) orelse return null;
    return .{
        .start = @min(first, second),
        .end = @max(first, second),
    };
}

fn selectorSliceIndex(raw: []const u8, part_count: usize) ?usize {
    if (part_count == 0) return null;
    const value = std.fmt.parseInt(i32, raw, 10) catch return null;
    if (value >= 0) {
        const index: usize = @intCast(value);
        return if (index < part_count) index else null;
    }
    const magnitude: usize = @intCast(-@as(i64, value));
    return if (magnitude <= part_count) part_count - magnitude else null;
}

fn validClassPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (!std.unicode.utf8ValidateSlice(prefix) or
        !(std.ascii.isAlphabetic(prefix[0]) or prefix[0] == '_' or prefix[0] == '-' or
            prefix[0] >= 0x80))
    {
        return false;
    }
    for (prefix[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte < 0x80) {
            return false;
        }
    }
    return true;
}

fn isClassSelectorStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '-' or
        byte == '\\' or byte >= 0x80;
}

fn isSelectorNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
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

fn memberAccessBase(raw_input: []const u8) ?[]const u8 {
    const raw = std.mem.trim(u8, raw_input, " \t\r\n\x0c;");
    const dot = std.mem.indexOfScalar(u8, raw, '.') orelse return null;
    if (dot == 0 or dot + 1 >= raw.len or
        std.mem.indexOfAny(u8, raw, " ()[]{}'\"+-*/%<>=!?:,") != null)
    {
        return null;
    }
    const base = raw[0..dot];
    if (!validVariableName(base)) return null;
    return base;
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
            if (self.cursor > 0 and std.ascii.isWhitespace(self.input[self.cursor - 1]) and
                self.cursor + 1 < self.input.len and
                !std.ascii.isWhitespace(self.input[self.cursor + 1]) and
                (std.ascii.isDigit(self.input[self.cursor + 1]) or
                    self.input[self.cursor + 1] == '.'))
            {
                return result;
            }
            self.cursor += 1;
            const right = try self.parseMultiply(depth);
            if (result.isDimensionless() and numericHasSingleUnit(right, "%")) {
                var percent = right;
                percent.value = result.value +
                    (if (operation == '+') @as(f64, 1.0) else -1.0) *
                        result.value * right.value / 100.0;
                result = percent;
            } else {
                result = try native_numeric.addPermissive(result, right, operation);
            }
        }
    }

    fn parseMultiply(self: *NumericParser, depth: u16) ParseError!native_numeric.Numeric {
        var result = try self.parsePrimary(depth);
        while (true) {
            self.skipWhitespace();
            const operation = self.peek();
            if (operation != '*' and operation != '/' and operation != '%') return result;
            if (operation == '*' and self.cursor + 1 < self.input.len and
                self.input[self.cursor + 1] == '*')
            {
                self.cursor += 2;
                const exponent = try self.parsePrimary(depth);
                if (!exponent.isDimensionless()) return error.InvalidExpression;
                result.value = std.math.pow(f64, result.value, exponent.value);
                if (!std.math.isFinite(result.value)) return error.InvalidNumber;
                continue;
            }
            if (operation == '/' and depth == 0) return result;
            self.cursor += 1;
            const right = try self.parsePrimary(depth);
            if (operation == '%') {
                if (!right.isDimensionless() or right.value == 0) {
                    return error.InvalidExpression;
                }
                result.value = @mod(result.value, right.value);
            } else if (operation == '/') {
                result = try divideStylusNumbers(result, right);
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

fn numericHasSingleUnit(input: native_numeric.Numeric, expected: []const u8) bool {
    var numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
    var denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
    const number = input.toNumber(&numerator, &denominator) catch return false;
    return number.denominator_units.len == 0 and number.numerator_units.len == 1 and
        std.mem.eql(u8, number.numerator_units[0], expected);
}

fn divideStylusNumbers(
    left: native_numeric.Numeric,
    right: native_numeric.Numeric,
) native_numeric.Error!native_numeric.Numeric {
    if (right.value == 0) return error.DivisionByZero;

    var left_numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
    var left_denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
    const left_number = try left.toNumber(&left_numerator, &left_denominator);
    var right_numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
    var right_denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
    const right_number = try right.toNumber(&right_numerator, &right_denominator);

    // Stylus models a number as one scalar plus one optional unit. Division
    // converts the right scalar to the left unit but retains a result unit.
    const simple_left = left_number.denominator_units.len == 0 and
        left_number.numerator_units.len <= 1;
    const simple_right = right_number.denominator_units.len == 0 and
        right_number.numerator_units.len <= 1;
    if (!simple_left or !simple_right) return native_numeric.multiply(left, right, '/');

    const result_unit = if (left_number.numerator_units.len == 1)
        left_number.numerator_units[0]
    else if (right_number.numerator_units.len == 1)
        right_number.numerator_units[0]
    else
        null;
    const right_value = if (left_number.numerator_units.len == 1 and
        right_number.numerator_units.len == 1)
        native_numeric.convertValueToMatch(right, left) catch right.value
    else
        right.value;
    return native_numeric.Numeric.init(left.value / right_value, result_unit);
}

fn parseStylusFloatPrefix(raw: []const u8) ?f64 {
    var index: usize = 0;
    while (index < raw.len and std.ascii.isWhitespace(raw[index])) index += 1;
    const start = index;
    if (index < raw.len and (raw[index] == '+' or raw[index] == '-')) index += 1;

    var saw_digit = false;
    while (index < raw.len and std.ascii.isDigit(raw[index])) : (index += 1) {
        saw_digit = true;
    }
    if (index < raw.len and raw[index] == '.') {
        index += 1;
        while (index < raw.len and std.ascii.isDigit(raw[index])) : (index += 1) {
            saw_digit = true;
        }
    }
    if (!saw_digit) return null;

    const exponent_start = index;
    if (index < raw.len and (raw[index] == 'e' or raw[index] == 'E')) {
        index += 1;
        if (index < raw.len and (raw[index] == '+' or raw[index] == '-')) index += 1;
        const exponent_digits = index;
        while (index < raw.len and std.ascii.isDigit(raw[index])) : (index += 1) {}
        if (index == exponent_digits) index = exponent_start;
    }

    const value = std.fmt.parseFloat(f64, raw[start..index]) catch return null;
    return if (std.math.isFinite(value)) value else null;
}
