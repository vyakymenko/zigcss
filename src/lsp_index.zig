const std = @import("std");
const zigcss = @import("zigcss");

const ast = zigcss.css.ast;
const syntax = zigcss.syntax;

pub const SymbolKind = enum {
    class,
    id,
    custom_property,
    keyframes,
};

pub const SymbolRole = enum {
    definition,
    reference,
};

pub const Symbol = struct {
    kind: SymbolKind,
    role: SymbolRole,
    name: []const u8,
    hit_span: zigcss.Span,
    selection_span: zigcss.Span,
    container_span: zigcss.Span,
};

pub const Property = struct {
    name: []const u8,
    name_span: zigcss.Span,
    declaration_span: zigcss.Span,
};

pub const CompletionPrefix = struct {
    value: []const u8,
    replace_span: zigcss.Span,
};

const OpaqueKind = enum {
    comment,
    string,
    url,
};

const OpaqueSpan = struct {
    kind: OpaqueKind,
    span: zigcss.Span,
};

pub const Limits = struct {
    max_symbols: usize = 100_000,
    max_properties: usize = 100_000,
    max_declaration_contexts: usize = 100_000,
    max_opaque_spans: usize = 100_000,
    max_name_bytes: usize = 4096,
    max_owned_name_bytes: usize = 8 * 1024 * 1024,
    max_allocated_bytes: usize = 32 * 1024 * 1024,
    max_completion_scan_bytes: usize = 64 * 1024,
    max_depth: usize = 256,
};

pub const DocumentIndex = struct {
    backing_allocator: std.mem.Allocator,
    tracker: *zigcss.profiling.TrackingAllocator,
    arena: std.heap.ArenaAllocator,
    owned_bytes: usize,
    symbols: []const Symbol,
    properties: []const Property,
    declaration_contexts: []const zigcss.Span,
    opaque_spans: []const OpaqueSpan,
    completion_scan_bytes: usize,

    pub fn build(
        backing_allocator: std.mem.Allocator,
        name: []const u8,
        text: []const u8,
        limits: Limits,
    ) !DocumentIndex {
        var parsed = try zigcss.css.pipeline.parse(backing_allocator, name, text);
        defer parsed.deinit();

        const tracker = try backing_allocator.create(zigcss.profiling.TrackingAllocator);
        errdefer backing_allocator.destroy(tracker);
        tracker.* = zigcss.profiling.TrackingAllocator.init(backing_allocator);
        var arena = std.heap.ArenaAllocator.init(tracker.allocator());
        errdefer arena.deinit();
        var builder = Builder{
            .arena_allocator = arena.allocator(),
            .scratch_allocator = backing_allocator,
            .file = parsed.file(),
            .limits = limits,
        };
        try builder.indexOpaqueTokens();
        try builder.indexRuleList(parsed.rules, 0);

        const symbols = try builder.symbols.toOwnedSlice(builder.arena_allocator);
        const properties = try builder.properties.toOwnedSlice(builder.arena_allocator);
        const declaration_contexts = try builder.declaration_contexts.toOwnedSlice(
            builder.arena_allocator,
        );
        const opaque_spans = try builder.opaque_spans.toOwnedSlice(
            builder.arena_allocator,
        );
        const owned_bytes = tracker.snapshot().retained_result_bytes;
        if (owned_bytes > limits.max_allocated_bytes) return error.IndexLimitExceeded;

        return .{
            .backing_allocator = backing_allocator,
            .tracker = tracker,
            .arena = arena,
            .owned_bytes = owned_bytes,
            .symbols = symbols,
            .properties = properties,
            .declaration_contexts = declaration_contexts,
            .opaque_spans = opaque_spans,
            .completion_scan_bytes = limits.max_completion_scan_bytes,
        };
    }

    pub fn deinit(self: *DocumentIndex) void {
        const backing_allocator = self.backing_allocator;
        const tracker = self.tracker;
        self.arena.deinit();
        std.debug.assert(tracker.snapshot().retained_result_bytes == 0);
        backing_allocator.destroy(tracker);
        self.* = undefined;
    }

    pub fn ownedBytes(self: *const DocumentIndex) usize {
        return self.owned_bytes;
    }

    pub fn symbolAt(self: *const DocumentIndex, offset: usize) ?*const Symbol {
        for (self.symbols) |*symbol| {
            if (containsTokenCursor(symbol.hit_span, offset)) return symbol;
        }
        for (self.symbols) |*symbol| {
            if (offset == symbol.hit_span.end and symbol.hit_span.len() > 0) return symbol;
        }
        return null;
    }

    pub fn propertyAt(self: *const DocumentIndex, offset: usize) ?*const Property {
        for (self.properties) |*property| {
            if (containsTokenCursor(property.name_span, offset)) return property;
        }
        for (self.properties) |*property| {
            if (offset == property.name_span.end and property.name_span.len() > 0) {
                return property;
            }
        }
        return null;
    }

    pub fn completionPrefix(
        self: *const DocumentIndex,
        text: []const u8,
        offset: usize,
    ) ?CompletionPrefix {
        if (offset > text.len or self.opaqueAt(offset) != null) return null;

        for (self.properties) |property| {
            if (offset >= property.declaration_span.start and
                offset <= property.declaration_span.end)
            {
                if (offset == property.name_span.end) {
                    return .{
                        .value = property.name,
                        .replace_span = property.name_span,
                    };
                }
                return null;
            }
        }

        const context = self.declarationContextAt(offset) orelse return null;
        if (offset - context.start > self.completion_scan_bytes) return null;
        var segment_start = context.start;
        var index = context.start;
        while (index < offset) {
            if (self.opaqueAt(index)) |item| {
                if (item.span.end > offset or item.kind != .comment) return null;
                index = item.span.end;
                continue;
            }
            if (text[index] == ';') segment_start = index + 1;
            index += 1;
        }

        var prefix_start = offset;
        while (prefix_start > segment_start and isAsciiIdentifierByte(text[prefix_start - 1])) {
            prefix_start -= 1;
        }

        index = segment_start;
        while (index < prefix_start) {
            if (self.opaqueAt(index)) |item| {
                if (item.span.end > prefix_start or item.kind != .comment) return null;
                index = item.span.end;
                continue;
            }
            if (!std.ascii.isWhitespace(text[index])) return null;
            index += 1;
        }

        return .{
            .value = text[prefix_start..offset],
            .replace_span = .{
                .source = context.source,
                .start = prefix_start,
                .end = offset,
            },
        };
    }

    fn declarationContextAt(
        self: *const DocumentIndex,
        offset: usize,
    ) ?zigcss.Span {
        var selected: ?zigcss.Span = null;
        for (self.declaration_contexts) |context| {
            if (!containsCursor(context, offset)) continue;
            if (selected == null or context.len() < selected.?.len()) selected = context;
        }
        return selected;
    }

    fn opaqueAt(self: *const DocumentIndex, offset: usize) ?OpaqueSpan {
        var low: usize = 0;
        var high = self.opaque_spans.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.opaque_spans[middle].span.start <= offset) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low == 0) return null;
        const candidate = self.opaque_spans[low - 1];
        if (offset >= candidate.span.start and offset < candidate.span.end) {
            return candidate;
        }
        return null;
    }
};

const Builder = struct {
    arena_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    file: *const zigcss.SourceFile,
    limits: Limits,
    owned_name_bytes: usize = 0,
    symbols: std.ArrayList(Symbol) = .empty,
    properties: std.ArrayList(Property) = .empty,
    declaration_contexts: std.ArrayList(zigcss.Span) = .empty,
    opaque_spans: std.ArrayList(OpaqueSpan) = .empty,

    fn indexOpaqueTokens(self: *Builder) !void {
        var tokenizer = zigcss.Tokenizer.init(self.file);
        while (true) {
            const token = tokenizer.next();
            if (token.kind == .eof) return;
            const kind: ?OpaqueKind = switch (token.kind) {
                .comment => .comment,
                .string, .bad_string => .string,
                .url, .bad_url => .url,
                else => null,
            };
            if (kind) |opaque_kind| {
                if (self.opaque_spans.items.len >= self.limits.max_opaque_spans) {
                    return error.IndexLimitExceeded;
                }
                try self.opaque_spans.append(self.arena_allocator, .{
                    .kind = opaque_kind,
                    .span = token.span,
                });
            }
        }
    }

    fn indexRuleList(self: *Builder, list: *const ast.RuleList, depth: usize) anyerror!void {
        try self.requireDepth(depth);
        for (list.rules) |rule| {
            switch (rule) {
                .style_rule => |style| {
                    try self.indexSelectorList(&style.selectors, style.span, depth + 1);
                    try self.indexDeclarationList(
                        &style.block.declarations,
                        true,
                        depth + 1,
                    );
                    try self.indexRuleList(&style.block.rules, depth + 1);
                },
                .at_rule => |at_rule| try self.indexAtRule(at_rule, depth + 1),
                .nested_declarations => |nested| try self.indexDeclarationList(
                    &nested.declarations,
                    true,
                    depth + 1,
                ),
            }
        }
    }

    fn indexAtRule(self: *Builder, rule: *const ast.AtRule, depth: usize) anyerror!void {
        try self.requireDepth(depth);
        if (rule.details) |details| switch (details) {
            .keyframes => |keyframes| try self.addSymbol(
                .keyframes,
                .definition,
                keyframes.name.value,
                keyframes.name.span,
                keyframes.name.span,
                rule.span,
            ),
            .property => |property| if (property.name.isCustomProperty()) {
                try self.addSymbol(
                    .custom_property,
                    .definition,
                    property.name.value,
                    property.name.span,
                    property.name.span,
                    rule.span,
                );
            },
            else => {},
        };

        switch (rule.block) {
            .none, .raw => {},
            .rules => |block| try self.indexRuleList(&block.rules, depth + 1),
            .declarations => |block| {
                const allow_completion = if (rule.details) |details| switch (details) {
                    .page => true,
                    else => false,
                } else false;
                try self.indexDeclarationList(
                    &block.declarations,
                    allow_completion,
                    depth + 1,
                );
            },
            .keyframes => |block| for (block.frames) |frame| {
                try self.indexDeclarationList(
                    &frame.block.declarations,
                    true,
                    depth + 1,
                );
            },
        }
    }

    fn indexSelectorList(
        self: *Builder,
        list: *const ast.SelectorList,
        container_span: zigcss.Span,
        depth: usize,
    ) anyerror!void {
        try self.requireDepth(depth);
        for (list.selectors) |selector| {
            try self.indexCompound(&selector.head, container_span, depth + 1);
            for (selector.tails) |tail| {
                try self.indexCompound(&tail.compound, container_span, depth + 1);
            }
        }
    }

    fn indexCompound(
        self: *Builder,
        compound: *const ast.CompoundSelector,
        container_span: zigcss.Span,
        depth: usize,
    ) anyerror!void {
        try self.requireDepth(depth);
        for (compound.simple_selectors) |simple| switch (simple) {
            .class => |selector| try self.addSymbol(
                .class,
                .reference,
                selector.name.value,
                selector.span,
                selector.name.span,
                container_span,
            ),
            .id => |selector| try self.addSymbol(
                .id,
                .reference,
                selector.name.value,
                selector.span,
                selector.name.span,
                container_span,
            ),
            .pseudo_class => |pseudo| try self.indexPseudoArguments(
                pseudo.arguments,
                container_span,
                depth + 1,
            ),
            .pseudo_element => |pseudo| try self.indexPseudoArguments(
                pseudo.arguments,
                container_span,
                depth + 1,
            ),
            else => {},
        };
    }

    fn indexPseudoArguments(
        self: *Builder,
        arguments: ?ast.PseudoArguments,
        container_span: zigcss.Span,
        depth: usize,
    ) anyerror!void {
        const value = arguments orelse return;
        const parsed = value.parsed orelse return;
        switch (parsed) {
            .selector_list => |list| try self.indexSelectorList(
                list,
                container_span,
                depth + 1,
            ),
        }
    }

    fn indexDeclarationList(
        self: *Builder,
        list: *const ast.DeclarationList,
        allow_completion: bool,
        depth: usize,
    ) anyerror!void {
        try self.requireDepth(depth);
        if (allow_completion) {
            if (self.declaration_contexts.items.len >=
                self.limits.max_declaration_contexts)
            {
                return error.IndexLimitExceeded;
            }
            try self.declaration_contexts.append(self.arena_allocator, list.span);
        }

        for (list.declarations) |declaration| {
            try self.addProperty(declaration);
            if (declaration.name.isCustomProperty()) {
                try self.addSymbol(
                    .custom_property,
                    .definition,
                    declaration.name.value,
                    declaration.name.span,
                    declaration.name.span,
                    declaration.span,
                );
            }
            try self.indexComponentValues(
                declaration.valueWithoutImportance(),
                declaration.span,
                depth + 1,
            );
            if (std.ascii.eqlIgnoreCase(declaration.name.value, "animation-name")) {
                try self.indexAnimationNames(declaration);
            }
        }
    }

    fn indexComponentValues(
        self: *Builder,
        values: []const syntax.ComponentValue,
        container_span: zigcss.Span,
        depth: usize,
    ) anyerror!void {
        try self.requireDepth(depth);
        for (values) |value| switch (value) {
            .token => {},
            .simple_block => |block| try self.indexComponentValues(
                block.values,
                container_span,
                depth + 1,
            ),
            .function => |function| {
                const function_name = try function.opening.decodedTextAlloc(
                    self.scratch_allocator,
                    self.file,
                );
                defer self.scratch_allocator.free(function_name);
                if (std.ascii.eqlIgnoreCase(function_name, "var")) {
                    try self.indexVarReference(function, container_span);
                }
                try self.indexComponentValues(
                    function.values,
                    container_span,
                    depth + 1,
                );
            },
        };
    }

    fn indexVarReference(
        self: *Builder,
        function: *const syntax.Function,
        container_span: zigcss.Span,
    ) !void {
        for (function.values) |value| {
            const token = switch (value) {
                .token => |token| token,
                else => return,
            };
            if (token.kind == .whitespace or token.kind == .comment) continue;
            if (token.kind != .ident) return;
            const span = token.valueSpan() orelse return;
            const name = try token.decodedTextAlloc(self.scratch_allocator, self.file);
            defer self.scratch_allocator.free(name);
            if (!std.mem.startsWith(u8, name, "--")) return;
            try self.addSymbol(
                .custom_property,
                .reference,
                name,
                span,
                span,
                container_span,
            );
            return;
        }
    }

    fn indexAnimationNames(self: *Builder, declaration: ast.Declaration) !void {
        const values = declaration.valueWithoutImportance();
        var expect_name = true;
        var saw_name = false;
        for (values) |value| {
            const token = switch (value) {
                .token => |token| token,
                else => return,
            };
            if (token.kind == .whitespace or token.kind == .comment) continue;
            if (expect_name) {
                if (token.kind != .ident and token.kind != .string) return;
                expect_name = false;
                saw_name = true;
            } else {
                if (token.kind != .comma) return;
                expect_name = true;
            }
        }
        if (!saw_name or expect_name) return;

        for (values) |value| {
            const token = value.token;
            if (token.kind != .ident and token.kind != .string) continue;
            const span = token.valueSpan() orelse continue;
            const name = try token.decodedTextAlloc(self.scratch_allocator, self.file);
            defer self.scratch_allocator.free(name);
            if (isNonKeyframesName(name)) continue;
            try self.addSymbol(
                .keyframes,
                .reference,
                name,
                span,
                span,
                declaration.span,
            );
        }
    }

    fn addProperty(self: *Builder, declaration: ast.Declaration) !void {
        if (self.properties.items.len >= self.limits.max_properties) {
            return error.IndexLimitExceeded;
        }
        const name = try self.ownName(declaration.name.value);
        try self.properties.append(self.arena_allocator, .{
            .name = name,
            .name_span = declaration.name.span,
            .declaration_span = declaration.span,
        });
    }

    fn addSymbol(
        self: *Builder,
        kind: SymbolKind,
        role: SymbolRole,
        name: []const u8,
        hit_span: zigcss.Span,
        selection_span: zigcss.Span,
        container_span: zigcss.Span,
    ) !void {
        if (self.symbols.items.len >= self.limits.max_symbols) {
            return error.IndexLimitExceeded;
        }
        const owned_name = try self.ownName(name);
        try self.symbols.append(self.arena_allocator, .{
            .kind = kind,
            .role = role,
            .name = owned_name,
            .hit_span = hit_span,
            .selection_span = selection_span,
            .container_span = container_span,
        });
    }

    fn ownName(self: *Builder, name: []const u8) ![]const u8 {
        if (name.len > self.limits.max_name_bytes) return error.IndexLimitExceeded;
        const total = std.math.add(usize, self.owned_name_bytes, name.len) catch {
            return error.IndexLimitExceeded;
        };
        if (total > self.limits.max_owned_name_bytes) return error.IndexLimitExceeded;
        const owned = try self.arena_allocator.dupe(u8, name);
        self.owned_name_bytes = total;
        return owned;
    }

    fn requireDepth(self: *const Builder, depth: usize) !void {
        if (depth > self.limits.max_depth) return error.IndexLimitExceeded;
    }
};

fn containsCursor(span: zigcss.Span, offset: usize) bool {
    return offset >= span.start and offset <= span.end;
}

fn containsTokenCursor(span: zigcss.Span, offset: usize) bool {
    return offset >= span.start and offset < span.end;
}

fn isAsciiIdentifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_';
}

fn isNonKeyframesName(name: []const u8) bool {
    const excluded = [_][]const u8{
        "none",
        "initial",
        "inherit",
        "unset",
        "revert",
        "revert-layer",
    };
    for (excluded) |keyword| {
        if (std.ascii.eqlIgnoreCase(name, keyword)) return true;
    }
    return false;
}

test "document index uses typed selectors declarations and value references" {
    const text =
        \\:root{--theme:red;color:var(--theme);content:"--theme"}
        \\.card:is(.nested,#hero){animation-name:spin}
        \\@media all{.card{background:var(--theme)}}
        \\@keyframes spin{from{opacity:0}to{opacity:1}}
        \\.new{ba}
    ;
    var index = try DocumentIndex.build(
        std.testing.allocator,
        "index.css",
        text,
        .{},
    );
    defer index.deinit();

    try std.testing.expectEqual(@as(usize, 10), index.symbols.len);
    try std.testing.expectEqual(@as(usize, 7), index.properties.len);
    try std.testing.expectEqual(@as(usize, 6), index.declaration_contexts.len);
    try std.testing.expectEqual(@as(usize, 1), index.opaque_spans.len);

    const custom_use = std.mem.indexOf(u8, text, "var(--theme)").? + 4;
    const custom = index.symbolAt(custom_use).?;
    try std.testing.expectEqual(SymbolKind.custom_property, custom.kind);
    try std.testing.expectEqual(SymbolRole.reference, custom.role);
    try std.testing.expectEqualStrings("--theme", custom.name);

    const fake = std.mem.indexOf(u8, text, "\"--theme\"").? + 1;
    try std.testing.expect(index.symbolAt(fake) == null);

    const property_offset = std.mem.indexOf(u8, text, "color").? + 5;
    try std.testing.expectEqualStrings("color", index.propertyAt(property_offset).?.name);

    const prefix_offset = std.mem.lastIndexOf(u8, text, "ba").? + 2;
    const prefix = index.completionPrefix(text, prefix_offset).?;
    try std.testing.expectEqualStrings("ba", prefix.value);
    try std.testing.expectEqual(prefix_offset - 2, prefix.replace_span.start);
    try std.testing.expect(index.completionPrefix(text, custom_use) == null);
    try std.testing.expect(index.completionPrefix(text, fake) == null);
    const selector_offset = std.mem.indexOf(u8, text, ".card").? + 3;
    try std.testing.expect(index.completionPrefix(text, selector_offset) == null);
}

test "document index enforces budgets and handles every allocation failure" {
    try std.testing.expectError(
        error.IndexLimitExceeded,
        DocumentIndex.build(
            std.testing.allocator,
            "limited.css",
            ".a,.b{}",
            .{ .max_symbols = 1 },
        ),
    );
    try std.testing.expectError(
        error.IndexLimitExceeded,
        DocumentIndex.build(
            std.testing.allocator,
            "limited-name.css",
            ".long{}",
            .{ .max_name_bytes = 3 },
        ),
    );
    try std.testing.expectError(
        error.IndexLimitExceeded,
        DocumentIndex.build(
            std.testing.allocator,
            "limited-allocation.css",
            ".a{}",
            .{ .max_allocated_bytes = 1 },
        ),
    );
    const completion_text = ".a{   ba}";
    var completion_limited = try DocumentIndex.build(
        std.testing.allocator,
        "limited-completion.css",
        completion_text,
        .{ .max_completion_scan_bytes = 2 },
    );
    defer completion_limited.deinit();
    try std.testing.expect(completion_limited.completionPrefix(
        completion_text,
        std.mem.indexOf(u8, completion_text, "ba").? + 2,
    ) == null);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseIndexAllocationFailures,
        .{},
    );
}

test "document index resolves adjacent tokens and validates animation name lists" {
    const text =
        \\.one.two{}
        \\@keyframes spin{}
        \\@keyframes "fade"{}
        \\.valid{animation-name:spin, "fade"}
        \\.invalid{animation-name:spin fade}
    ;
    var index = try DocumentIndex.build(
        std.testing.allocator,
        "boundaries.css",
        text,
        .{},
    );
    defer index.deinit();

    const second_selector = std.mem.indexOf(u8, text, ".two").?;
    try std.testing.expectEqualStrings(
        "two",
        index.symbolAt(second_selector).?.name,
    );

    const quoted_reference = std.mem.lastIndexOf(u8, text, "\"fade\"").? + 1;
    const fade = index.symbolAt(quoted_reference).?;
    try std.testing.expectEqual(SymbolKind.keyframes, fade.kind);
    try std.testing.expectEqual(SymbolRole.reference, fade.role);
    try std.testing.expectEqualStrings("fade", fade.name);

    const invalid_reference = std.mem.lastIndexOf(u8, text, "spin fade").?;
    try std.testing.expect(index.symbolAt(invalid_reference) == null);
    try std.testing.expect(index.symbolAt(invalid_reference + 5) == null);
}

fn exerciseIndexAllocationFailures(allocator: std.mem.Allocator) !void {
    var index = try DocumentIndex.build(
        allocator,
        "oom-index.css",
        ":root{--x:red;color:var(--x)}.a:is(.b,#c){animation-name:spin}@keyframes spin{to{opacity:1}}",
        .{},
    );
    defer index.deinit();
    try std.testing.expect(index.symbols.len > 0);
}
