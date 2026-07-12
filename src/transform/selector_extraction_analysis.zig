const std = @import("std");
const ast = @import("../css/ast.zig");
const compilation = @import("../compilation.zig");
const rule_parser = @import("../css/rule_parser.zig");
const source = @import("../source.zig");
const syntax = @import("../syntax.zig");

pub const Error = error{
    InvalidAst,
    InvalidSpan,
    SourceMismatch,
};

pub fn validateRuleExpansion(
    file: *const source.SourceFile,
    list: *const ast.RuleList,
    generated: ast.GeneratedRule,
) Error!void {
    list.validate() catch return error.InvalidAst;
    return validateRuleExpansionAssumeListValid(file, list, generated);
}

pub fn validateRuleExpansionAssumeListValid(
    file: *const source.SourceFile,
    list: *const ast.RuleList,
    generated: ast.GeneratedRule,
) Error!void {
    if (generated.kind != .extraction or generated.compatibility != null) {
        return error.InvalidAst;
    }
    const extraction = generated.extraction orelse return error.InvalidAst;
    if (generated.first_rule >= list.rules.len) return error.InvalidAst;
    const rule = list.rules[generated.first_rule];
    if (!spansEqual(generated.source_span, rule.span()) or
        !generated.source_span.source.eql(file.id))
    {
        return error.InvalidAst;
    }
    _ = file.slice(generated.source_span) catch |err| return mapSliceError(err);
    if (!ruleImpossibleAssumeValid(rule, extraction.inventory)) return error.InvalidAst;
}

pub fn ruleImpossible(
    rule: ast.Rule,
    inventory: ast.CompleteSelectorInventory,
) bool {
    ast.validateCompleteSelectorInventory(inventory) catch return false;
    const style = switch (rule) {
        .style_rule => |value| value,
        else => return false,
    };
    _ = ast.StyleRule.init(style.*) catch return false;
    return selectorListImpossible(&style.selectors, inventory);
}

pub fn ruleImpossibleAssumeValid(
    rule: ast.Rule,
    inventory: ast.CompleteSelectorInventory,
) bool {
    const style = switch (rule) {
        .style_rule => |value| value,
        else => return false,
    };
    return selectorListImpossible(&style.selectors, inventory);
}

pub fn selectorListImpossible(
    list: *const ast.SelectorList,
    inventory: ast.CompleteSelectorInventory,
) bool {
    _ = ast.SelectorList.init(list.span, list.selectors) catch return false;
    for (list.selectors) |selector| {
        if (!complexSelectorImpossible(selector, inventory)) return false;
    }
    return true;
}

pub fn extractionEqual(
    left: ast.GeneratedExtractionRule,
    right: ast.GeneratedExtractionRule,
) bool {
    return left.mode == right.mode and
        optionalEntriesEqual(left.inventory.classes, right.inventory.classes) and
        optionalEntriesEqual(left.inventory.ids, right.inventory.ids);
}

fn complexSelectorImpossible(
    selector: ast.ComplexSelector,
    inventory: ast.CompleteSelectorInventory,
) bool {
    if (compoundHasAbsentRequirement(selector.head, inventory)) return true;
    for (selector.tails) |tail| {
        if (compoundHasAbsentRequirement(tail.compound, inventory)) return true;
    }
    return false;
}

fn compoundHasAbsentRequirement(
    compound: ast.CompoundSelector,
    inventory: ast.CompleteSelectorInventory,
) bool {
    for (compound.simple_selectors) |simple| switch (simple) {
        .class => |class| if (inventory.classes) |known| {
            if (!containsConservatively(known, class.name.value)) return true;
        },
        .id => |id| if (inventory.ids) |known| {
            if (!containsConservatively(known, id.name.value)) return true;
        },
        // Type/attribute matching depends on the document language and
        // namespaces. Functional pseudo arguments have positive, negative, or
        // relational polarity. None of those shapes grant absence authority
        // in the initial class/ID-only contract.
        .type_selector,
        .universal,
        .attribute,
        .pseudo_class,
        .pseudo_element,
        .nesting,
        => {},
    };
    return false;
}

fn containsConservatively(entries: []const []const u8, expected: []const u8) bool {
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (ast.conservativeSelectorNameOrder(entries[middle], expected)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return true,
        }
    }
    return false;
}

fn optionalEntriesEqual(
    left: ?[]const []const u8,
    right: ?[]const []const u8,
) bool {
    if (left == null or right == null) return left == null and right == null;
    if (left.?.len != right.?.len) return false;
    for (left.?, right.?) |left_entry, right_entry| {
        if (!std.mem.eql(u8, left_entry, right_entry)) return false;
    }
    return true;
}

fn spansEqual(left: source.Span, right: source.Span) bool {
    return left.source.eql(right.source) and left.start == right.start and left.end == right.end;
}

fn mapSliceError(err: anyerror) Error {
    return switch (err) {
        error.SourceMismatch => error.SourceMismatch,
        error.InvalidSpan => error.InvalidSpan,
        else => error.InvalidSpan,
    };
}

fn parseSource(
    context: *compilation.Compilation,
    css: []const u8,
) !struct { *const source.SourceFile, *const ast.RuleList } {
    const source_id = try context.addSource("selector-extraction-analysis.css", css);
    const document = try syntax.parse(context, source_id);
    const values = try ast.ComponentValueList.init(document.span, document.values);
    return .{
        try context.sources.get(source_id),
        try rule_parser.parse(context, source_id, values),
    };
}

test "only direct exhaustive class and ID absence proves selector impossibility" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        ".missing{x:1}.used.missing{x:2}.missing,.used{x:3}" ++
            ":not(.missing){x:4}:is(.missing){x:5}.missing:not(.used){x:6}" ++
            "#gone{x:7}#hero{x:8}.USED{x:9}.\\75 sed{x:10}.\\6d issing{x:11}",
    );
    const classes = [_][]const u8{"used"};
    const ids = [_][]const u8{"hero"};
    const inventory = ast.CompleteSelectorInventory{
        .classes = &classes,
        .ids = &ids,
    };
    const expected = [_]bool{ true, true, false, false, false, true, true, false, false, false, true };
    for (parsed[1].rules, expected) |rule, impossible| {
        try std.testing.expectEqual(impossible, ruleImpossible(rule, inventory));
    }

    const ids_only = ast.CompleteSelectorInventory{ .ids = &ids };
    try std.testing.expect(!ruleImpossible(parsed[1].rules[0], ids_only));
}

test "extraction validation rejects a forged omission proof" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, ".used{x:1}.gone{x:2}");
    const classes = [_][]const u8{"used"};
    const extraction = ast.GeneratedExtractionRule{
        .mode = .dead_code,
        .inventory = .{ .classes = &classes },
    };
    const forged = ast.GeneratedRule{
        .kind = .extraction,
        .first_rule = 0,
        .source_span = parsed[1].rules[0].span(),
        .extraction = extraction,
    };
    const valid = ast.GeneratedRule{
        .kind = .extraction,
        .first_rule = 1,
        .source_span = parsed[1].rules[1].span(),
        .extraction = extraction,
    };
    try std.testing.expectError(
        error.InvalidAst,
        validateRuleExpansion(parsed[0], parsed[1], forged),
    );
    try validateRuleExpansion(parsed[0], parsed[1], valid);
}
