const std = @import("std");
const ast = @import("ast.zig");
const compilation = @import("../compilation.zig");
const diagnostics = @import("../diagnostics.zig");
const source = @import("../source.zig");
const syntax = @import("../syntax.zig");
const tokenizer = @import("../tokenizer.zig");

pub const Options = struct {
    max_declarations: usize = 100_000,
};

pub const Error = std.mem.Allocator.Error || error{
    DeclarationLimit,
    InternalInvariant,
    InvalidInput,
    UnknownSource,
};

pub fn parse(
    context: *compilation.Compilation,
    source_id: source.SourceId,
    input: ast.ComponentValueList,
) Error!*const ast.DeclarationList {
    return parseWithOptions(context, source_id, input, .{});
}

pub fn parseWithOptions(
    context: *compilation.Compilation,
    source_id: source.SourceId,
    input: ast.ComponentValueList,
    options: Options,
) Error!*const ast.DeclarationList {
    const file = try context.sources.get(source_id);
    if (!input.span.source.eql(source_id)) return error.InvalidInput;
    _ = ast.ComponentValueList.init(input.span, input.values) catch return error.InvalidInput;
    var parser = Parser{
        .allocator = context.arenaAllocator(),
        .context = context,
        .file = file,
        .options = options,
    };
    return parser.parseList(input);
}

const Parser = struct {
    allocator: std.mem.Allocator,
    context: *compilation.Compilation,
    file: *const source.SourceFile,
    options: Options,

    fn parseList(self: *Parser, input: ast.ComponentValueList) Error!*const ast.DeclarationList {
        var declarations = try std.ArrayList(ast.Declaration).initCapacity(self.allocator, 0);
        errdefer declarations.deinit(self.allocator);
        var segment_start: usize = 0;
        var index: usize = 0;
        while (index <= input.values.len) : (index += 1) {
            if (index != input.values.len and !isSemicolon(input.values[index])) continue;
            const terminator = if (index < input.values.len) tokenAt(input.values[index]) else null;
            if (try self.parseCandidate(input.values, segment_start, index, terminator)) |declaration| {
                if (declarations.items.len >= self.options.max_declarations) {
                    try self.report(.resource_limit, declaration.span, "declaration count limit exceeded");
                    return error.DeclarationLimit;
                }
                try declarations.append(self.allocator, declaration);
            }
            segment_start = index + 1;
        }

        const owned = try declarations.toOwnedSlice(self.allocator);
        const list = self.allocator.create(ast.DeclarationList) catch return error.OutOfMemory;
        list.* = ast.DeclarationList.init(input.span, owned) catch {
            try self.report(.internal, input.span, "declaration-list span invariant failed");
            return error.InternalInvariant;
        };
        return list;
    }

    fn parseCandidate(
        self: *Parser,
        values: []const syntax.ComponentValue,
        raw_start: usize,
        raw_end: usize,
        terminator: ?tokenizer.Token,
    ) Error!?ast.Declaration {
        const start = trimTriviaStart(values, raw_start, raw_end);
        const end = trimTriviaEnd(values, start, raw_end);
        if (start == end) return null;
        const candidate_span = makeSpan(
            values[start].span().source,
            values[start].span().start,
            values[end - 1].span().end,
        );

        const name_token = tokenAt(values[start]) orelse {
            try self.report(.unexpected_token, candidate_span, "declaration must start with a property name");
            return null;
        };
        if (name_token.kind != .ident) {
            try self.report(.unexpected_token, name_token.span, "declaration must start with an identifier");
            return null;
        }
        const after_name = scanTrivia(values, start + 1, end);
        if (after_name >= end) {
            try self.report(.unexpected_token, candidate_span, "declaration is missing ':'");
            return null;
        }
        const colon = tokenAt(values[after_name]) orelse {
            try self.report(.unexpected_token, values[after_name].span(), "declaration is missing ':'");
            return null;
        };
        if (colon.kind != .colon) {
            try self.report(.unexpected_token, colon.span, "expected ':' after property name");
            return null;
        }

        const value_start = after_name + 1;
        const value_slice = values[value_start..raw_end];
        const value_span = if (value_slice.len == 0)
            makeSpan(name_token.span.source, colon.span.end, colon.span.end)
        else
            makeSpan(
                value_slice[0].span().source,
                value_slice[0].span().start,
                value_slice[value_slice.len - 1].span().end,
            );
        const value = ast.ComponentValueList.init(value_span, value_slice) catch {
            try self.report(.internal, candidate_span, "declaration value is not contiguous");
            return error.InternalInvariant;
        };
        const important = try self.detectImportant(value);
        const declaration_end = if (terminator) |token| token.span.end else value.span.end;
        return ast.Declaration.init(.{
            .name = try self.identifier(name_token),
            .colon = colon.span,
            .value = value,
            .important = important,
            .terminator = if (terminator) |token| token.span else null,
            .span = makeSpan(name_token.span.source, name_token.span.start, declaration_end),
        }) catch {
            try self.report(.internal, candidate_span, "declaration span invariant failed");
            return error.InternalInvariant;
        };
    }

    fn detectImportant(self: *Parser, value: ast.ComponentValueList) Error!?ast.ImportantAnnotation {
        if (value.values.len == 0) return null;
        var keyword_index = value.values.len;
        while (keyword_index > 0 and isTrivia(value.values[keyword_index - 1])) keyword_index -= 1;
        if (keyword_index == 0) return null;
        keyword_index -= 1;
        const keyword_token = tokenAt(value.values[keyword_index]) orelse return null;
        if (keyword_token.kind != .ident or !try self.mightBeImportant(keyword_token)) return null;

        var bang_index = keyword_index;
        while (bang_index > 0 and isTrivia(value.values[bang_index - 1])) bang_index -= 1;
        if (bang_index == 0) return null;
        bang_index -= 1;
        if (!isDelimiter(value.values[bang_index], '!')) return null;

        var value_end = bang_index;
        while (value_end > 0 and isTrivia(value.values[value_end - 1])) value_end -= 1;
        const keyword = try self.identifier(keyword_token);
        return ast.ImportantAnnotation.init(
            value,
            value_end,
            bang_index,
            keyword_index,
            keyword,
        ) catch {
            try self.report(.internal, value.span, "important annotation invariant failed");
            return error.InternalInvariant;
        };
    }

    fn mightBeImportant(self: *Parser, token: tokenizer.Token) Error!bool {
        const value_span = token.valueSpan() orelse return false;
        const raw = self.file.slice(value_span) catch return error.InvalidInput;
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) {
            return std.ascii.eqlIgnoreCase(raw, "important");
        }
        const decoded = try self.decode(token);
        return std.ascii.eqlIgnoreCase(decoded, "important");
    }

    fn identifier(self: *Parser, token: tokenizer.Token) Error!ast.Identifier {
        const value_span = token.valueSpan() orelse return error.InvalidInput;
        return .{ .value = try self.decode(token), .span = value_span };
    }

    fn decode(self: *Parser, token: tokenizer.Token) Error![]const u8 {
        return token.decodedTextAlloc(self.allocator, self.file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidInput,
        };
    }

    fn report(
        self: *Parser,
        code: diagnostics.Code,
        span: source.Span,
        message: []const u8,
    ) std.mem.Allocator.Error!void {
        self.context.report(.err, code, span, message) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSpan, error.UnknownSource, error.SourceMismatch => unreachable,
        };
    }
};

fn tokenAt(value: syntax.ComponentValue) ?tokenizer.Token {
    return switch (value) {
        .token => |token| token,
        else => null,
    };
}

fn isSemicolon(value: syntax.ComponentValue) bool {
    const token = tokenAt(value) orelse return false;
    return token.kind == .semicolon;
}

fn isTrivia(value: syntax.ComponentValue) bool {
    const token = tokenAt(value) orelse return false;
    return token.isTrivia();
}

fn isDelimiter(value: syntax.ComponentValue, expected: u21) bool {
    const token = tokenAt(value) orelse return false;
    if (token.kind != .delim) return false;
    return switch (token.data) {
        .delim => |delimiter| delimiter == expected,
        else => false,
    };
}

fn scanTrivia(values: []const syntax.ComponentValue, start: usize, end: usize) usize {
    var index = start;
    while (index < end and isTrivia(values[index])) index += 1;
    return index;
}

fn trimTriviaStart(values: []const syntax.ComponentValue, start: usize, end: usize) usize {
    return scanTrivia(values, start, end);
}

fn trimTriviaEnd(values: []const syntax.ComponentValue, start: usize, end: usize) usize {
    var index = end;
    while (index > start and isTrivia(values[index - 1])) index -= 1;
    return index;
}

fn makeSpan(source_id: source.SourceId, start: usize, end: usize) source.Span {
    return .{ .source = source_id, .start = start, .end = end };
}

fn parseBlockSource(
    context: *compilation.Compilation,
    name: []const u8,
    css: []const u8,
) !struct { source.SourceId, *const syntax.SimpleBlock, *const ast.DeclarationList } {
    const id = try context.addSource(name, css);
    const document = try syntax.parse(context, id);
    const block = document.values[0].simple_block;
    const content_span = source.Span{
        .source = id,
        .start = block.opening.span.end,
        .end = if (block.closing) |closing| closing.span.start else block.span.end,
    };
    const values = try ast.ComponentValueList.init(content_span, block.values);
    return .{ id, block, try parse(context, id, values) };
}

test "nested delimiters never split declaration values" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseBlockSource(
        &context,
        "nested-values.css",
        "{color:fn(a;b, [c:d]);content:\"x;y\";--x:{a:b;c:d};}",
    );
    const file = try context.sources.get(parsed[0]);
    const declarations = parsed[2].declarations;

    try std.testing.expectEqual(@as(usize, 3), declarations.len);
    try std.testing.expectEqualStrings("color", declarations[0].name.value);
    try std.testing.expectEqual(@as(usize, 1), declarations[0].value.values.len);
    try std.testing.expect(declarations[0].value.values[0] == .function);
    try std.testing.expectEqual(@as(usize, 6), declarations[0].value.values[0].function.values.len);
    try std.testing.expectEqualStrings("\"x;y\"", try file.slice(declarations[1].value.span));
    try std.testing.expect(declarations[2].name.isCustomProperty());
    try std.testing.expect(declarations[2].value.values[0] == .simple_block);
    try std.testing.expectEqualStrings("{a:b;c:d}", try file.slice(declarations[2].value.span));
}

test "important detection is top-level case-insensitive and trivia-aware" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseBlockSource(
        &context,
        "important.css",
        "{a:1!important;b:2 ! /*x*/ IMPORTANT ;c:fn(!important);d:!important trailing;}",
    );
    const declarations = parsed[2].declarations;

    try std.testing.expectEqual(@as(usize, 4), declarations.len);
    try std.testing.expect(declarations[0].important != null);
    try std.testing.expect(declarations[1].important != null);
    try std.testing.expectEqualStrings("IMPORTANT", declarations[1].important.?.keyword.value);
    try std.testing.expect(declarations[1].valueWithoutImportance().len < declarations[1].value.values.len);
    try std.testing.expect(declarations[2].important == null);
    try std.testing.expect(declarations[3].important == null);
}

test "invalid declarations recover at the next top-level semicolon" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseBlockSource(
        &context,
        "recovery.css",
        "{color:red;broken ;width:1px;:bad;height:2px}",
    );
    const declarations = parsed[2].declarations;

    try std.testing.expectEqual(@as(usize, 3), declarations.len);
    try std.testing.expectEqualStrings("color", declarations[0].name.value);
    try std.testing.expectEqualStrings("width", declarations[1].name.value);
    try std.testing.expectEqualStrings("height", declarations[2].name.value);
    try std.testing.expectEqual(@as(usize, 2), context.diagnostics.items().len);
}

test "duplicate fallbacks and a final unterminated declaration retain source order" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseBlockSource(
        &context,
        "fallbacks.css",
        "{display:-webkit-box;display:flex;color:red}",
    );
    const declarations = parsed[2].declarations;

    try std.testing.expectEqual(@as(usize, 3), declarations.len);
    try std.testing.expectEqualStrings("display", declarations[0].name.value);
    try std.testing.expectEqualStrings("display", declarations[1].name.value);
    try std.testing.expect(declarations[0].span.start < declarations[1].span.start);
    try std.testing.expect(declarations[2].terminator == null);
}

test "escaped property names decode while retaining their original span" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseBlockSource(&context, "escaped-property.css", "{\\63 olor:red;--\\78 :1}");
    const file = try context.sources.get(parsed[0]);
    const declarations = parsed[2].declarations;

    try std.testing.expectEqualStrings("color", declarations[0].name.value);
    try std.testing.expectEqualStrings("--x", declarations[1].name.value);
    try std.testing.expectEqualStrings("\\63 olor", try file.slice(declarations[0].name.span));
}

test "escaped important keywords and empty values preserve raw spelling" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseBlockSource(
        &context,
        "escaped-important.css",
        "{;;a: ;b:1 !\\69mportant;;/*only trivia*/;}",
    );
    const file = try context.sources.get(parsed[0]);
    const declarations = parsed[2].declarations;

    try std.testing.expectEqual(@as(usize, 2), declarations.len);
    try std.testing.expectEqualStrings(" ", try file.slice(declarations[0].value.span));
    try std.testing.expect(declarations[0].important == null);
    try std.testing.expect(declarations[1].important != null);
    try std.testing.expectEqualStrings("important", declarations[1].important.?.keyword.value);
    try std.testing.expectEqualStrings("\\69mportant", try file.slice(declarations[1].important.?.keyword.span));
    try std.testing.expectEqual(@as(usize, 0), context.diagnostics.items().len);
}

test "declaration count limits fail separately from CSS diagnostics" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const id = try context.addSource("limit.css", "{a:1;b:2}");
    const document = try syntax.parse(&context, id);
    const block = document.values[0].simple_block;
    const values = try ast.ComponentValueList.init(.{
        .source = id,
        .start = block.opening.span.end,
        .end = block.closing.?.span.start,
    }, block.values);
    try std.testing.expectError(
        error.DeclarationLimit,
        parseWithOptions(&context, id, values, .{ .max_declarations = 1 }),
    );
    try std.testing.expectEqual(@as(usize, 1), context.diagnostics.items().len);
}

fn exerciseDeclarationAllocationFailures(allocator: std.mem.Allocator) !void {
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const parsed = try parseBlockSource(
        &context,
        "oom-declarations.css",
        "{color:rgb(1 2 3 / 50%);color:red !important;--x:{a:b;c:d}}",
    );
    try std.testing.expectEqual(@as(usize, 3), parsed[2].declarations.len);
}

test "declaration lowering handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDeclarationAllocationFailures,
        .{},
    );
}

fn exerciseDeclarationRecoveryAllocationFailures(allocator: std.mem.Allocator) !void {
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const parsed = try parseBlockSource(
        &context,
        "oom-declaration-recovery.css",
        "{bad; color:red; :broken; width:1px}",
    );
    try std.testing.expectEqual(@as(usize, 2), parsed[2].declarations.len);
    try std.testing.expectEqual(@as(usize, 2), context.diagnostics.items().len);
}

test "declaration diagnostic recovery handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDeclarationRecoveryAllocationFailures,
        .{},
    );
}
