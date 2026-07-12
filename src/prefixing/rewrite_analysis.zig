const std = @import("std");
const ast = @import("../css/ast.zig");
const source = @import("../source.zig");
const syntax = @import("../syntax.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidAst,
    InvalidSpan,
    InvalidToken,
    SourceMismatch,
};

pub const DeclarationOutput = struct {
    name: []const u8,
    /// Null retains the authored semantic value. A non-null value is one
    /// closed compatibility keyword emitted in its place.
    value: ?[]const u8 = null,
};

pub const PseudoOutput = struct {
    element: bool,
    name: []const u8,
};

pub fn declarationOutput(
    feature: ast.CompatibilityDeclarationFeature,
    form: ast.CompatibilityForm,
) ?DeclarationOutput {
    if (!ast.compatibilityDeclarationFormAllowed(feature, form)) return null;
    return switch (feature) {
        .appearance => .{ .name = switch (form) {
            .webkit => "-webkit-appearance",
            .moz => "-moz-appearance",
            else => unreachable,
        } },
        .user_select => .{ .name = switch (form) {
            .khtml => "-khtml-user-select",
            .webkit => "-webkit-user-select",
            .moz => "-moz-user-select",
            .ms => "-ms-user-select",
        } },
        .backdrop_filter => .{ .name = "-webkit-backdrop-filter" },
        .position_sticky => .{ .name = "position", .value = "-webkit-sticky" },
        .display_flex => .{ .name = "display", .value = switch (form) {
            .webkit => "-webkit-flex",
            .ms => "-ms-flexbox",
            else => unreachable,
        } },
    };
}

pub fn pseudoOutput(
    feature: ast.CompatibilityRuleFeature,
    form: ast.CompatibilityForm,
) ?PseudoOutput {
    if (!ast.compatibilityRuleFormAllowed(feature, form)) return null;
    return switch (feature) {
        .placeholder => switch (form) {
            .webkit => .{ .element = true, .name = "-webkit-input-placeholder" },
            .moz => .{ .element = true, .name = "-moz-placeholder" },
            .ms => .{ .element = false, .name = "-ms-input-placeholder" },
            else => unreachable,
        },
        .fullscreen => switch (form) {
            .webkit => .{ .element = false, .name = "-webkit-full-screen" },
            .moz => .{ .element = false, .name = "-moz-full-screen" },
            .ms => .{ .element = false, .name = "-ms-fullscreen" },
            else => unreachable,
        },
        .keyframes => null,
    };
}

pub fn atRuleName(
    feature: ast.CompatibilityRuleFeature,
    form: ast.CompatibilityForm,
) ?[]const u8 {
    if (feature != .keyframes or !ast.compatibilityRuleFormAllowed(feature, form)) return null;
    return switch (form) {
        .webkit => "-webkit-keyframes",
        .moz => "-moz-keyframes",
        else => null,
    };
}

pub fn declarationMatchesFeature(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    declaration: ast.Declaration,
    feature: ast.CompatibilityDeclarationFeature,
) Error!bool {
    _ = ast.Declaration.init(declaration) catch return error.InvalidAst;
    _ = file.slice(declaration.span) catch |err| return mapSliceError(err);
    const expected_name: []const u8 = switch (feature) {
        .appearance => "appearance",
        .user_select => "user-select",
        .backdrop_filter => "backdrop-filter",
        .position_sticky => "position",
        .display_flex => "display",
    };
    if (!std.ascii.eqlIgnoreCase(declaration.name.value, expected_name)) return false;
    return switch (feature) {
        .appearance, .user_select, .backdrop_filter => hasSemanticValue(declaration),
        .position_sticky => try singleIdentEquals(
            allocator,
            file,
            declaration,
            "sticky",
        ),
        .display_flex => try singleIdentEquals(
            allocator,
            file,
            declaration,
            "flex",
        ),
    };
}

pub fn declarationListHasAuthoredForm(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    list: *const ast.DeclarationList,
    feature: ast.CompatibilityDeclarationFeature,
) Error!bool {
    for (list.declarations) |declaration| {
        if (try declarationIsAuthoredForm(allocator, file, declaration, feature)) return true;
    }
    return false;
}

pub fn validateDeclarationExpansion(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    list: *const ast.DeclarationList,
    generated: ast.GeneratedDeclaration,
) Error!void {
    list.validate() catch return error.InvalidAst;
    if (generated.kind != .compatibility) return error.InvalidAst;
    const compatibility = generated.compatibility orelse return error.InvalidAst;
    if (generated.first_declaration >= list.declarations.len or
        !generated.source_span.source.eql(file.id) or
        !spansEqual(generated.source_span, list.declarations[generated.first_declaration].span))
    {
        return error.InvalidAst;
    }
    _ = file.slice(generated.source_span) catch |err| return mapSliceError(err);
    if (!try declarationMatchesFeature(
        allocator,
        file,
        list.declarations[generated.first_declaration],
        compatibility.feature,
    )) return error.InvalidAst;
    if (try declarationListHasAuthoredForm(allocator, file, list, compatibility.feature)) {
        return error.InvalidAst;
    }
    try requireConsistentDeclarationForms(list, compatibility);
}

pub fn ruleMatchesFeature(rule: ast.Rule, feature: ast.CompatibilityRuleFeature) bool {
    return ast.compatibilityRuleMatchesStructure(rule, feature);
}

pub fn ruleListHasAuthoredForm(
    list: *const ast.RuleList,
    feature: ast.CompatibilityRuleFeature,
) bool {
    for (list.rules) |rule| {
        if (ruleIsAuthoredForm(rule, feature)) return true;
    }
    return false;
}

pub fn validateRuleExpansion(
    file: *const source.SourceFile,
    list: *const ast.RuleList,
    generated: ast.GeneratedRule,
) Error!void {
    list.validate() catch return error.InvalidAst;
    if (generated.kind != .compatibility) return error.InvalidAst;
    const compatibility = generated.compatibility orelse return error.InvalidAst;
    if (generated.first_rule >= list.rules.len or
        !generated.source_span.source.eql(file.id) or
        !spansEqual(generated.source_span, list.rules[generated.first_rule].span()) or
        !ruleMatchesFeature(list.rules[generated.first_rule], compatibility.feature) or
        ruleListHasAuthoredForm(list, compatibility.feature))
    {
        return error.InvalidAst;
    }
    _ = file.slice(generated.source_span) catch |err| return mapSliceError(err);
    try requireConsistentRuleForms(list, compatibility);
}

pub fn simpleMatchesFeature(
    simple: ast.SimpleSelector,
    feature: ast.CompatibilityRuleFeature,
) bool {
    return switch (feature) {
        .placeholder => switch (simple) {
            .pseudo_element => |pseudo| pseudo.arguments == null and
                std.ascii.eqlIgnoreCase(pseudo.name.value, "placeholder"),
            else => false,
        },
        .fullscreen => switch (simple) {
            .pseudo_class => |pseudo| pseudo.arguments == null and
                std.ascii.eqlIgnoreCase(pseudo.name.value, "fullscreen"),
            else => false,
        },
        .keyframes => false,
    };
}

fn declarationIsAuthoredForm(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    declaration: ast.Declaration,
    feature: ast.CompatibilityDeclarationFeature,
) Error!bool {
    _ = ast.Declaration.init(declaration) catch return error.InvalidAst;
    _ = file.slice(declaration.span) catch |err| return mapSliceError(err);
    return switch (feature) {
        .appearance => nameIsAny(declaration.name.value, &.{
            "-webkit-appearance",
            "-moz-appearance",
        }),
        .user_select => nameIsAny(declaration.name.value, &.{
            "-khtml-user-select",
            "-webkit-user-select",
            "-moz-user-select",
            "-ms-user-select",
        }),
        .backdrop_filter => std.ascii.eqlIgnoreCase(
            declaration.name.value,
            "-webkit-backdrop-filter",
        ),
        .position_sticky => std.ascii.eqlIgnoreCase(declaration.name.value, "position") and
            try singleIdentEquals(allocator, file, declaration, "-webkit-sticky"),
        .display_flex => std.ascii.eqlIgnoreCase(declaration.name.value, "display") and
            (try singleIdentEquals(allocator, file, declaration, "-webkit-flex") or
                try singleIdentEquals(allocator, file, declaration, "-ms-flexbox")),
    };
}

fn ruleIsAuthoredForm(rule: ast.Rule, feature: ast.CompatibilityRuleFeature) bool {
    return switch (feature) {
        .placeholder, .fullscreen => switch (rule) {
            .style_rule => |style| selectorListHasAuthoredForm(&style.selectors, feature),
            else => false,
        },
        .keyframes => switch (rule) {
            .at_rule => |at_rule| std.ascii.eqlIgnoreCase(at_rule.name.value, "-webkit-keyframes") or
                std.ascii.eqlIgnoreCase(at_rule.name.value, "-moz-keyframes"),
            else => false,
        },
    };
}

fn selectorListHasAuthoredForm(
    list: *const ast.SelectorList,
    feature: ast.CompatibilityRuleFeature,
) bool {
    for (list.selectors) |selector| {
        if (compoundHasAuthoredForm(selector.head, feature)) return true;
        for (selector.tails) |tail| {
            if (compoundHasAuthoredForm(tail.compound, feature)) return true;
        }
    }
    return false;
}

fn compoundHasAuthoredForm(
    compound: ast.CompoundSelector,
    feature: ast.CompatibilityRuleFeature,
) bool {
    for (compound.simple_selectors) |simple| switch (simple) {
        .pseudo_class => |pseudo| if (authoredPseudoName(pseudo.name.value, feature)) return true,
        .pseudo_element => |pseudo| if (authoredPseudoName(pseudo.name.value, feature)) return true,
        else => {},
    };
    return false;
}

fn authoredPseudoName(name: []const u8, feature: ast.CompatibilityRuleFeature) bool {
    return switch (feature) {
        .placeholder => nameIsAny(name, &.{
            "-webkit-input-placeholder",
            "-moz-placeholder",
            "-ms-input-placeholder",
        }),
        .fullscreen => nameIsAny(name, &.{
            "-webkit-full-screen",
            "-moz-full-screen",
            "-ms-fullscreen",
        }),
        .keyframes => false,
    };
}

fn requireConsistentDeclarationForms(
    list: *const ast.DeclarationList,
    expected: ast.GeneratedCompatibilityDeclaration,
) Error!void {
    for (list.generated_declarations) |proof| {
        if (proof.kind != .compatibility) continue;
        const compatibility = proof.compatibility orelse return error.InvalidAst;
        if (compatibility.feature == expected.feature and
            !std.mem.eql(ast.CompatibilityForm, compatibility.forms, expected.forms))
        {
            return error.InvalidAst;
        }
    }
}

fn requireConsistentRuleForms(
    list: *const ast.RuleList,
    expected: ast.GeneratedCompatibilityRule,
) Error!void {
    for (list.generated_rules) |proof| {
        if (proof.kind != .compatibility) continue;
        const compatibility = proof.compatibility orelse return error.InvalidAst;
        if (compatibility.feature == expected.feature and
            !std.mem.eql(ast.CompatibilityForm, compatibility.forms, expected.forms))
        {
            return error.InvalidAst;
        }
    }
}

fn singleIdentEquals(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    declaration: ast.Declaration,
    expected: []const u8,
) Error!bool {
    const values = declaration.valueWithoutImportance();
    var token: ?@import("../tokenizer.zig").Token = null;
    for (values) |value| {
        if (isTrivia(value)) continue;
        if (token != null or value != .token or value.token.kind != .ident) return false;
        token = value.token;
    }
    const ident = token orelse return false;
    const decoded = ident.decodedTextAlloc(allocator, file) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SourceMismatch => return error.SourceMismatch,
        error.InvalidSpan => return error.InvalidSpan,
        else => return error.InvalidToken,
    };
    defer allocator.free(decoded);
    return std.ascii.eqlIgnoreCase(decoded, expected);
}

fn hasSemanticValue(declaration: ast.Declaration) bool {
    for (declaration.valueWithoutImportance()) |value| if (!isTrivia(value)) return true;
    return false;
}

fn isTrivia(value: syntax.ComponentValue) bool {
    return value == .token and value.token.isTrivia();
}

fn nameIsAny(name: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    return false;
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
