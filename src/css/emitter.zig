const std = @import("std");
const ast = @import("ast.zig");
const compilation = @import("../compilation.zig");
const compatibility_analysis = @import("../prefixing/rewrite_analysis.zig");
const extraction_analysis = @import("../transform/selector_extraction_analysis.zig");
const module_names = @import("module_names.zig");
const rule_parser = @import("rule_parser.zig");
const rule_merge = @import("rule_merge.zig");
const shorthand = @import("shorthand.zig");
const source = @import("../source.zig");
const sourcemap = @import("../sourcemap.zig");
const syntax = @import("../syntax.zig");
const tokenizer = @import("../tokenizer.zig");

pub const Mode = enum {
    pretty,
    minified,
};

pub const Options = struct {
    mode: Mode = .pretty,
    indent_width: u8 = 2,
    /// Defaults to true for pretty output and false for minified output.
    final_newline: ?bool = null,
    /// Internal generated-identifier view. A non-null slice must be strictly
    /// sorted and contain every class selector reached during emission.
    class_names: ?[]const module_names.Entry = null,
    /// Occurrence-sensitive class rewrites used by explicit CSS Modules scope.
    class_rewrites: ?[]const module_names.Occurrence = null,
    /// Functional scope wrappers removed after their replacement compound is
    /// validated by the CSS Modules adapter.
    scope_rewrites: ?[]const module_names.Scope = null,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidAst,
    InvalidMappings,
    InvalidPosition,
    InvalidSpan,
    SourceMismatch,
    UnterminatedSyntax,
    UnrepresentableRecovery,
    ValueOverflow,
    GeneratedPositionOverflow,
};

pub const MappedOutput = struct {
    allocator: std.mem.Allocator,
    css: []u8,
    source_map: []u8,

    pub fn deinit(self: *MappedOutput) void {
        const allocator = self.allocator;
        if (self.css.len > 0) allocator.free(self.css);
        if (self.source_map.len > 0) allocator.free(self.source_map);
        self.* = .{ .allocator = allocator, .css = &.{}, .source_map = &.{} };
    }
};

pub fn emit(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    rules: *const ast.RuleList,
    options: Options,
) Error![]u8 {
    return emitInternal(allocator, file, rules, options, null);
}

pub fn emitWithSourceMap(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    rules: *const ast.RuleList,
    options: Options,
    source_map_options: sourcemap.Options,
) Error!MappedOutput {
    var builder = try sourcemap.Builder.init(allocator, file, source_map_options);
    defer builder.deinit();
    const css = try emitInternal(allocator, file, rules, options, &builder);
    errdefer if (css.len > 0) allocator.free(css);
    const source_map = try builder.toJson(allocator);
    return .{ .allocator = allocator, .css = css, .source_map = source_map };
}

fn emitInternal(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    rules: *const ast.RuleList,
    options: Options,
    source_map_builder: ?*sourcemap.Builder,
) Error![]u8 {
    if (options.class_names != null and options.class_rewrites != null) {
        return error.InvalidMappings;
    }
    if (options.class_names) |entries| {
        module_names.validate(entries) catch return error.InvalidMappings;
    }
    if (options.class_rewrites) |entries| {
        module_names.validateOccurrences(entries) catch return error.InvalidMappings;
    }
    if (options.scope_rewrites) |entries| {
        if (options.class_rewrites == null) return error.InvalidMappings;
        module_names.validateScopes(entries) catch return error.InvalidMappings;
    }
    rules.validate() catch return error.InvalidAst;
    if (!rules.span.source.eql(file.id)) return error.SourceMismatch;

    var emitter = Emitter{
        .allocator = allocator,
        .file = file,
        .options = options,
        .output = try std.ArrayList(u8).initCapacity(allocator, 0),
        .source_map_builder = source_map_builder,
    };
    errdefer emitter.output.deinit(allocator);
    try emitter.writeRuleList(rules, 0, true, false, false);
    if ((options.final_newline orelse (options.mode == .pretty)) and emitter.output.items.len > 0) {
        try emitter.appendByte('\n');
    }
    return emitter.output.toOwnedSlice(allocator);
}

pub fn serializeIdentifierAlloc(allocator: std.mem.Allocator, value: []const u8) Error![]u8 {
    var output = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer output.deinit(allocator);
    try appendIdentifier(&output, allocator, value);
    return output.toOwnedSlice(allocator);
}

pub fn serializeStringAlloc(allocator: std.mem.Allocator, value: []const u8) Error![]u8 {
    var output = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer output.deinit(allocator);
    try appendString(&output, allocator, value);
    return output.toOwnedSlice(allocator);
}

const Emitter = struct {
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    options: Options,
    output: std.ArrayList(u8),
    source_map_builder: ?*sourcemap.Builder,
    generated_line: usize = 0,
    generated_column: usize = 0,
    generated_last_was_cr: bool = false,

    fn writeRuleList(
        self: *Emitter,
        rules: *const ast.RuleList,
        depth: usize,
        top_level: bool,
        allow_nested_declarations: bool,
        external_following_rule: bool,
    ) Error!void {
        try self.validateRuleCoverage(rules, top_level, allow_nested_declarations);
        const output_count = try logicalRuleCount(rules);
        var rule_index: usize = 0;
        var generated_index: usize = 0;
        var output_index: usize = 0;
        while (rule_index < rules.rules.len) {
            if (generated_index < rules.generated_rules.len and
                rules.generated_rules[generated_index].first_rule == rule_index)
            {
                const generated = rules.generated_rules[generated_index];
                const generated_output_count = generated.outputCount() catch return error.InvalidAst;
                if (generated_output_count > 0 and self.pretty()) {
                    if (output_index > 0) try self.appendByte('\n');
                    try self.writeIndent(depth);
                }
                const has_following = output_index + generated_output_count < output_count or
                    external_following_rule;
                try self.writeGeneratedRule(rules, generated, depth, has_following);
                rule_index += generated.kind.inputCount();
                generated_index += 1;
                output_index += generated_output_count;
            } else {
                if (generated_index < rules.generated_rules.len and
                    rules.generated_rules[generated_index].first_rule < rule_index)
                {
                    return error.InvalidAst;
                }
                const rule = rules.rules[rule_index];
                if (self.pretty()) {
                    if (output_index > 0) try self.appendByte('\n');
                    if (rule != .nested_declarations) try self.writeIndent(depth);
                }
                try self.writeRule(
                    rule,
                    depth,
                    output_index + 1 < output_count or external_following_rule,
                );
                rule_index += 1;
                output_index += 1;
            }
        }
        if (generated_index != rules.generated_rules.len or output_index != output_count) {
            return error.InvalidAst;
        }
    }

    fn writeGeneratedRule(
        self: *Emitter,
        rules: *const ast.RuleList,
        generated: ast.GeneratedRule,
        depth: usize,
        external_following_rule: bool,
    ) Error!void {
        const count = generated.kind.inputCount();
        const end = std.math.add(usize, generated.first_rule, count) catch return error.InvalidAst;
        if (end > rules.rules.len) return error.InvalidAst;
        const inputs = rules.rules[generated.first_rule..end];
        switch (generated.kind) {
            .selector_list_merge => {
                const proof = rule_merge.analyzeSelectorMerge(self.allocator, self.file, inputs) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.SourceMismatch => return error.SourceMismatch,
                    error.InvalidSpan => return error.InvalidSpan,
                    error.InvalidAst, error.InvalidToken => return error.InvalidAst,
                } orelse return error.InvalidAst;
                if (!spansEqual(proof.source_span, generated.source_span)) return error.InvalidAst;
                const first = inputs[0].style_rule;
                const second = inputs[1].style_rule;
                try self.mark(first.span);
                try self.writeSelectorList(&first.selectors);
                _ = ast.SelectorList.init(
                    second.selectors.span,
                    second.selectors.selectors,
                ) catch return error.InvalidAst;
                for (second.selectors.selectors) |selector| {
                    try self.appendSlice(if (self.pretty()) ", " else ",");
                    try self.writeComplexSelector(selector);
                }
                try self.writePrettySpace();
                try self.writeStyleBlock(&first.block, depth);
            },
            .group_at_rule_merge => {
                const proof = rule_merge.analyzeAtRuleMerge(self.allocator, self.file, inputs) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.SourceMismatch => return error.SourceMismatch,
                    error.InvalidSpan => return error.InvalidSpan,
                    error.InvalidAst, error.InvalidToken => return error.InvalidAst,
                } orelse return error.InvalidAst;
                if (!spansEqual(proof.source_span, generated.source_span)) return error.InvalidAst;
                const first = inputs[0].at_rule;
                const second = inputs[1].at_rule;
                const first_block = switch (first.block) {
                    .rules => |value| value,
                    else => return error.InvalidAst,
                };
                const second_block = switch (second.block) {
                    .rules => |value| value,
                    else => return error.InvalidAst,
                };
                try self.mark(first.span);
                try self.writeAtRuleHeader(first);
                try self.writeAtRuleBlockSeparator(first);
                try self.writeMergedRulesBlock(first_block, second_block, depth);
            },
            .compatibility => {
                compatibility_analysis.validateRuleExpansion(self.file, rules, generated) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.SourceMismatch => return error.SourceMismatch,
                    error.InvalidSpan => return error.InvalidSpan,
                    else => return error.InvalidAst,
                };
                const compatibility = generated.compatibility orelse return error.InvalidAst;
                const input = inputs[0];
                for (compatibility.forms, 0..) |form, index| {
                    if (index > 0 and self.pretty()) {
                        try self.appendByte('\n');
                        try self.writeIndent(depth);
                    }
                    try self.writeCompatibilityRule(input, compatibility.feature, form, depth);
                }
                if (self.pretty()) {
                    try self.appendByte('\n');
                    try self.writeIndent(depth);
                }
                try self.writeRule(input, depth, external_following_rule);
            },
            .extraction => extraction_analysis.validateRuleExpansionAssumeListValid(
                self.file,
                rules,
                generated,
            ) catch |err| switch (err) {
                error.SourceMismatch => return error.SourceMismatch,
                error.InvalidSpan => return error.InvalidSpan,
                error.InvalidAst => return error.InvalidAst,
            },
        }
    }

    fn writeCompatibilityRule(
        self: *Emitter,
        rule: ast.Rule,
        feature: ast.CompatibilityRuleFeature,
        form: ast.CompatibilityForm,
        depth: usize,
    ) Error!void {
        try self.mark(rule.span());
        switch (feature) {
            .placeholder, .fullscreen => {
                const style = switch (rule) {
                    .style_rule => |value| value,
                    else => return error.InvalidAst,
                };
                try self.writeCompatibilitySelectorList(&style.selectors, feature, form);
                try self.writePrettySpace();
                try self.writeStyleBlock(&style.block, depth);
            },
            .keyframes => {
                const at_rule = switch (rule) {
                    .at_rule => |value| value,
                    else => return error.InvalidAst,
                };
                const name = compatibility_analysis.atRuleName(feature, form) orelse return error.InvalidAst;
                const block = switch (at_rule.block) {
                    .keyframes => |value| value,
                    else => return error.InvalidAst,
                };
                try self.appendByte('@');
                try self.mark(at_rule.name.span);
                try self.appendSlice(name);
                if (hasNonWhitespace(at_rule.prelude.values)) {
                    try self.appendByte(' ');
                    try self.writeComponentValues(at_rule.prelude.values);
                }
                try self.writeAtRuleBlockSeparator(at_rule);
                try self.writeKeyframesBlock(block, depth);
            },
        }
    }

    fn writeCompatibilitySelectorList(
        self: *Emitter,
        list: *const ast.SelectorList,
        feature: ast.CompatibilityRuleFeature,
        form: ast.CompatibilityForm,
    ) Error!void {
        _ = ast.SelectorList.init(list.span, list.selectors) catch return error.InvalidAst;
        for (list.selectors, 0..) |selector, index| {
            if (index > 0) try self.appendSlice(if (self.pretty()) ", " else ",");
            try self.writeCompatibilityComplexSelector(selector, feature, form);
        }
    }

    fn writeCompatibilityComplexSelector(
        self: *Emitter,
        selector: ast.ComplexSelector,
        feature: ast.CompatibilityRuleFeature,
        form: ast.CompatibilityForm,
    ) Error!void {
        if (selector.leading_combinator) |combinator| try self.writeCombinator(combinator.kind, true);
        try self.writeCompatibilityCompoundSelector(selector.head, feature, form);
        for (selector.tails) |tail| {
            try self.writeCombinator(tail.combinator.kind, false);
            try self.writeCompatibilityCompoundSelector(tail.compound, feature, form);
        }
    }

    fn writeCompatibilityCompoundSelector(
        self: *Emitter,
        compound: ast.CompoundSelector,
        feature: ast.CompatibilityRuleFeature,
        form: ast.CompatibilityForm,
    ) Error!void {
        _ = ast.CompoundSelector.init(compound.span, compound.simple_selectors) catch return error.InvalidAst;
        for (compound.simple_selectors) |simple| {
            if (!compatibility_analysis.simpleMatchesFeature(simple, feature)) {
                try self.writeSimpleSelector(simple);
                continue;
            }
            const output = compatibility_analysis.pseudoOutput(feature, form) orelse return error.InvalidAst;
            try self.mark(simple.span());
            try self.appendSlice(if (output.element) "::" else ":");
            try self.appendSlice(output.name);
        }
    }

    fn writeMergedRulesBlock(
        self: *Emitter,
        first: *const ast.RulesBlock,
        second: *const ast.RulesBlock,
        depth: usize,
    ) Error!void {
        _ = (if (first.nested)
            ast.RulesBlock.initNested(first.envelope, first.rules)
        else
            ast.RulesBlock.init(first.envelope, first.rules)) catch return error.InvalidAst;
        _ = (if (second.nested)
            ast.RulesBlock.initNested(second.envelope, second.rules)
        else
            ast.RulesBlock.init(second.envelope, second.rules)) catch return error.InvalidAst;
        if (first.nested != second.nested) return error.InvalidAst;
        if (!first.envelope.terminated() or !second.envelope.terminated()) {
            return error.UnterminatedSyntax;
        }
        const first_count = try logicalRuleCount(&first.rules);
        const second_count = try logicalRuleCount(&second.rules);
        const total_count = std.math.add(usize, first_count, second_count) catch {
            return error.InvalidAst;
        };
        try self.appendByte('{');
        if (total_count == 0) {
            try self.appendByte('}');
            return;
        }
        if (self.pretty()) try self.appendByte('\n');
        if (first_count > 0) {
            try self.writeRuleList(
                &first.rules,
                depth + 1,
                false,
                first.nested,
                second_count > 0,
            );
        }
        if (first_count > 0 and second_count > 0 and self.pretty()) try self.appendByte('\n');
        if (second_count > 0) {
            try self.writeRuleList(
                &second.rules,
                depth + 1,
                false,
                second.nested,
                false,
            );
        }
        if (self.pretty()) {
            try self.appendByte('\n');
            try self.writeIndent(depth);
        }
        try self.appendByte('}');
    }

    fn writeRule(self: *Emitter, rule: ast.Rule, depth: usize, terminate_nested: bool) Error!void {
        try self.mark(rule.span());
        switch (rule) {
            .style_rule => |style_rule| try self.writeStyleRule(style_rule, depth),
            .at_rule => |at_rule| try self.writeAtRule(at_rule, depth),
            .nested_declarations => |declarations| try self.writeNestedDeclarations(
                declarations,
                depth,
                terminate_nested,
            ),
        }
    }

    fn writeStyleRule(self: *Emitter, rule: *const ast.StyleRule, depth: usize) Error!void {
        _ = ast.StyleRule.init(rule.*) catch return error.InvalidAst;
        try self.writeSelectorList(&rule.selectors);
        try self.writePrettySpace();
        try self.writeStyleBlock(&rule.block, depth);
    }

    fn writeSelectorList(self: *Emitter, list: *const ast.SelectorList) Error!void {
        try self.writeSelectorListMode(list, false);
    }

    fn writeSelectorListMode(
        self: *Emitter,
        list: *const ast.SelectorList,
        allow_empty: bool,
    ) Error!void {
        _ = (if (allow_empty)
            ast.SelectorList.initForgiving(list.span, list.selectors)
        else
            ast.SelectorList.init(list.span, list.selectors)) catch return error.InvalidAst;
        for (list.selectors, 0..) |selector, index| {
            if (index > 0) try self.appendSlice(if (self.pretty()) ", " else ",");
            try self.writeComplexSelector(selector);
        }
    }

    fn writeComplexSelector(self: *Emitter, selector: ast.ComplexSelector) Error!void {
        if (selector.leading_combinator) |combinator| {
            try self.writeCombinator(combinator.kind, true);
        }
        try self.writeCompoundSelector(selector.head);
        for (selector.tails) |tail| {
            try self.writeCombinator(tail.combinator.kind, false);
            try self.writeCompoundSelector(tail.compound);
        }
    }

    fn writeCombinator(self: *Emitter, kind: ast.CombinatorKind, leading: bool) Error!void {
        if (leading and kind == .descendant) return error.InvalidAst;
        if (!self.pretty()) {
            try self.appendSlice(switch (kind) {
                .descendant => " ",
                .child => ">",
                .next_sibling => "+",
                .subsequent_sibling => "~",
                .column => "||",
            });
            return;
        }
        switch (kind) {
            .descendant => try self.appendByte(' '),
            .child => try self.appendSlice(if (leading) "> " else " > "),
            .next_sibling => try self.appendSlice(if (leading) "+ " else " + "),
            .subsequent_sibling => try self.appendSlice(if (leading) "~ " else " ~ "),
            .column => try self.appendSlice(if (leading) "|| " else " || "),
        }
    }

    fn writeCompoundSelector(self: *Emitter, compound: ast.CompoundSelector) Error!void {
        _ = ast.CompoundSelector.init(compound.span, compound.simple_selectors) catch return error.InvalidAst;
        for (compound.simple_selectors) |simple| try self.writeSimpleSelector(simple);
    }

    fn writeSimpleSelector(self: *Emitter, simple: ast.SimpleSelector) Error!void {
        try self.mark(simple.span());
        switch (simple) {
            .type_selector => |selector| {
                try self.writeNamespace(selector.namespace);
                try self.writeIdentifier(selector.name.value);
            },
            .universal => |selector| {
                try self.writeNamespace(selector.namespace);
                try self.appendByte('*');
            },
            .id => |selector| {
                try self.appendByte('#');
                try self.writeIdentifier(selector.name.value);
            },
            .class => |selector| {
                try self.appendByte('.');
                const name = if (self.options.class_rewrites) |entries|
                    module_names.findOccurrence(entries, selector.span) orelse
                        return error.InvalidMappings
                else if (self.options.class_names) |entries|
                    module_names.find(entries, selector.name.value) orelse
                        return error.InvalidMappings
                else
                    selector.name.value;
                try self.writeIdentifier(name);
            },
            .attribute => |selector| try self.writeAttributeSelector(selector),
            .pseudo_class => |selector| try self.writePseudo(
                selector.name,
                selector.arguments,
                selector.span,
                false,
            ),
            .pseudo_element => |selector| try self.writePseudo(
                selector.name,
                selector.arguments,
                selector.span,
                true,
            ),
            .nesting => try self.appendByte('&'),
        }
    }

    fn writeNamespace(self: *Emitter, namespace: ast.Namespace) Error!void {
        switch (namespace) {
            .implicit => {},
            .any => try self.appendSlice("*|"),
            .empty => try self.appendByte('|'),
            .named => |name| {
                try self.writeIdentifier(name.value);
                try self.appendByte('|');
            },
        }
    }

    fn writeAttributeSelector(self: *Emitter, selector: *const ast.AttributeSelector) Error!void {
        _ = ast.AttributeSelector.init(selector.*) catch return error.InvalidAst;
        try self.appendByte('[');
        try self.writeNamespace(selector.namespace);
        try self.writeIdentifier(selector.name.value);
        if (selector.matcher) |matcher| {
            try self.appendSlice(switch (matcher.kind) {
                .exact => "=",
                .includes => "~=",
                .dash => "|=",
                .prefix => "^=",
                .suffix => "$=",
                .substring => "*=",
            });
            const value = selector.value orelse return error.InvalidAst;
            switch (value) {
                .identifier => |identifier| try self.writeIdentifier(identifier.value),
                .string => |string| try self.writeString(string.value),
            }
        } else if (selector.value != null) return error.InvalidAst;
        if (selector.modifier) |modifier| {
            try self.appendByte(' ');
            switch (modifier) {
                .insensitive => try self.appendByte('i'),
                .sensitive => try self.appendByte('s'),
                .unknown => |identifier| try self.writeIdentifier(identifier.value),
            }
        }
        try self.appendByte(']');
    }

    fn writePseudo(
        self: *Emitter,
        name: ast.Identifier,
        arguments: ?ast.PseudoArguments,
        span: source.Span,
        element: bool,
    ) Error!void {
        if (self.options.scope_rewrites) |entries| {
            if (module_names.findScope(entries, span)) |compound| {
                if (element) return error.InvalidMappings;
                try self.writeCompoundSelector(compound.*);
                return;
            }
        }
        try self.appendSlice(if (element) "::" else ":");
        try self.writeIdentifier(name.value);
        if (arguments) |value| {
            try self.appendByte('(');
            if (self.hasClassMappings()) {
                const parsed = value.parsed orelse return error.InvalidMappings;
                switch (parsed) {
                    .selector_list => |list| try self.writeSelectorListMode(
                        list,
                        std.ascii.eqlIgnoreCase(name.value, "is") or
                            std.ascii.eqlIgnoreCase(name.value, "where"),
                    ),
                }
            } else {
                try self.writeComponentValuesWithEdges(value.values, false);
            }
            try self.appendByte(')');
        }
    }

    fn hasClassMappings(self: *const Emitter) bool {
        return self.options.class_names != null or self.options.class_rewrites != null;
    }

    fn writeAtRule(self: *Emitter, rule: *const ast.AtRule, depth: usize) Error!void {
        _ = ast.AtRule.init(rule.*) catch return error.InvalidAst;
        if (!structuredDetailsMatch(rule)) return error.UnrepresentableRecovery;
        try self.writeAtRuleHeader(rule);

        switch (rule.block) {
            .none => try self.appendByte(';'),
            .declarations => |block| {
                try self.writeAtRuleBlockSeparator(rule);
                try self.writeDeclarationBlock(block, depth);
            },
            .rules => |block| {
                try self.writeAtRuleBlockSeparator(rule);
                try self.writeRulesBlock(block, depth);
            },
            .keyframes => |block| {
                try self.writeAtRuleBlockSeparator(rule);
                try self.writeKeyframesBlock(block, depth);
            },
            .raw => |block| {
                try self.writeAtRuleBlockSeparator(rule);
                if (pageDetails(rule.details)) |details| {
                    try self.writePageBlock(details, block, depth);
                } else {
                    try self.writeRawBlock(block);
                }
            },
        }
    }

    fn writeAtRuleHeader(self: *Emitter, rule: *const ast.AtRule) Error!void {
        try self.appendByte('@');
        try self.writeIdentifier(rule.name.value);

        const page = pageDetails(rule.details);
        if (page) |details| {
            if (details.selectors.len > 0) {
                try self.appendByte(' ');
                try self.writePageSelectors(details.selectors);
            }
        } else if (hasNonWhitespace(rule.prelude.values)) {
            if (rule.details != null or beginsWithWhitespace(rule.prelude.values)) try self.appendByte(' ');
            try self.writeComponentValues(rule.prelude.values);
        }
    }

    fn writeRulesBlock(self: *Emitter, block: *const ast.RulesBlock, depth: usize) Error!void {
        _ = (if (block.nested)
            ast.RulesBlock.initNested(block.envelope, block.rules)
        else
            ast.RulesBlock.init(block.envelope, block.rules)) catch return error.InvalidAst;
        if (!block.envelope.terminated()) return error.UnterminatedSyntax;
        try self.appendByte('{');
        if (block.rules.rules.len == 0) {
            try self.validateRuleCoverage(&block.rules, false, block.nested);
            try self.appendByte('}');
            return;
        }
        if (self.pretty()) try self.appendByte('\n');
        try self.writeRuleList(&block.rules, depth + 1, false, block.nested, false);
        if (self.pretty()) {
            try self.appendByte('\n');
            try self.writeIndent(depth);
        }
        try self.appendByte('}');
    }

    fn writeStyleBlock(self: *Emitter, block: *const ast.StyleBlock, depth: usize) Error!void {
        _ = ast.StyleBlock.init(block.envelope, block.declarations, block.rules) catch return error.InvalidAst;
        if (!block.envelope.terminated()) return error.UnterminatedSyntax;
        try self.validateDeclarationCoverage(&block.declarations);
        try self.validateRuleCoverage(&block.rules, false, true);

        try self.appendByte('{');
        const has_declarations = block.declarations.declarations.len > 0;
        const has_rules = block.rules.rules.len > 0;
        if (!has_declarations and !has_rules) {
            try self.appendByte('}');
            return;
        }
        if (self.pretty()) try self.appendByte('\n');
        if (has_declarations) {
            try self.writeDeclarationSequence(
                &block.declarations,
                depth + 1,
                has_rules,
            );
        }
        if (has_rules) {
            if (has_declarations and self.pretty()) try self.appendByte('\n');
            try self.writeRuleList(&block.rules, depth + 1, false, true, false);
        }
        if (self.pretty()) {
            try self.appendByte('\n');
            try self.writeIndent(depth);
        }
        try self.appendByte('}');
    }

    fn writeNestedDeclarations(
        self: *Emitter,
        nested: *const ast.NestedDeclarationsRule,
        depth: usize,
        terminate_last: bool,
    ) Error!void {
        _ = ast.NestedDeclarationsRule.init(nested.*) catch return error.InvalidAst;
        try self.validateDeclarationCoverage(&nested.declarations);
        try self.writeDeclarationSequence(&nested.declarations, depth, terminate_last);
    }

    fn writeDeclarationSequence(
        self: *Emitter,
        declarations: *const ast.DeclarationList,
        depth: usize,
        terminate_last: bool,
    ) Error!void {
        const output_count = try logicalDeclarationCount(declarations);
        var declaration_index: usize = 0;
        var generated_index: usize = 0;
        var output_index: usize = 0;
        while (declaration_index < declarations.declarations.len) {
            if (output_index > 0 and self.pretty()) try self.appendByte('\n');
            if (self.pretty()) try self.writeIndent(depth);
            const terminate = self.pretty() or output_index + 1 < output_count or terminate_last;
            if (generated_index < declarations.generated_declarations.len and
                declarations.generated_declarations[generated_index].first_declaration == declaration_index)
            {
                const generated = declarations.generated_declarations[generated_index];
                const generated_output_count = generated.outputCount() catch return error.InvalidAst;
                const terminate_generated = self.pretty() or
                    output_index + generated_output_count < output_count or terminate_last;
                try self.writeGeneratedDeclaration(
                    declarations,
                    generated,
                    depth,
                    terminate_generated,
                );
                declaration_index += generated.kind.inputCount();
                generated_index += 1;
                output_index += generated_output_count;
            } else {
                if (generated_index < declarations.generated_declarations.len and
                    declarations.generated_declarations[generated_index].first_declaration < declaration_index)
                {
                    return error.InvalidAst;
                }
                try self.writeDeclaration(declarations.declarations[declaration_index], terminate);
                declaration_index += 1;
                output_index += 1;
            }
        }
        if (generated_index != declarations.generated_declarations.len or output_index != output_count) {
            return error.InvalidAst;
        }
    }

    fn writeDeclarationBlock(self: *Emitter, block: *const ast.DeclarationBlock, depth: usize) Error!void {
        try self.writeDeclarationListBlock(&block.declarations, block.envelope, depth);
    }

    fn writeDeclarationListBlock(
        self: *Emitter,
        declarations: *const ast.DeclarationList,
        envelope: ast.BlockSpan,
        depth: usize,
    ) Error!void {
        if (!envelope.terminated()) return error.UnterminatedSyntax;
        if (!spansEqual(declarations.span, envelope.content)) return error.InvalidAst;
        try self.validateDeclarationCoverage(declarations);
        try self.appendByte('{');
        if (declarations.declarations.len == 0) {
            try self.appendByte('}');
            return;
        }
        if (self.pretty()) try self.appendByte('\n');
        try self.writeDeclarationSequence(declarations, depth + 1, false);
        if (self.pretty()) {
            try self.appendByte('\n');
            try self.writeIndent(depth);
        }
        try self.appendByte('}');
    }

    fn writeDeclaration(self: *Emitter, declaration: ast.Declaration, terminate: bool) Error!void {
        _ = ast.Declaration.init(declaration) catch return error.InvalidAst;
        try self.mark(declaration.span);
        try self.writeIdentifier(declaration.name.value);
        try self.appendSlice(if (self.pretty()) ": " else ":");
        const value = declaration.valueWithoutImportance();
        if (declaration.generated_value) |generated| {
            _ = ast.GeneratedValue.init(generated) catch return error.InvalidAst;
            try self.mark(generated.sourceSpan());
            var buffer: [ast.generated_value_buffer_size]u8 = undefined;
            try self.appendSlice(generated.serialize(&buffer) catch return error.InvalidAst);
        } else {
            try self.writeComponentValues(value);
        }
        if (declaration.important != null) {
            if (self.pretty() and
                (declaration.generated_value != null or hasNonWhitespace(value)))
            {
                try self.appendByte(' ');
            }
            try self.appendSlice("!important");
        }
        if (terminate) try self.appendByte(';');
    }

    fn writeGeneratedDeclaration(
        self: *Emitter,
        declarations: *const ast.DeclarationList,
        generated: ast.GeneratedDeclaration,
        depth: usize,
        terminate: bool,
    ) Error!void {
        const count = generated.kind.inputCount();
        const end = std.math.add(usize, generated.first_declaration, count) catch return error.InvalidAst;
        if (end > declarations.declarations.len) return error.InvalidAst;
        const inputs = declarations.declarations[generated.first_declaration..end];
        switch (generated.kind) {
            .margin => {
                const proof = shorthand.analyzeMargin(self.allocator, self.file, inputs) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.SourceMismatch => return error.SourceMismatch,
                    error.InvalidSpan => return error.InvalidSpan,
                    error.InvalidAst => return error.InvalidAst,
                } orelse return error.InvalidAst;
                if (!spansEqual(proof.source_span, generated.source_span)) return error.InvalidAst;
                try self.mark(generated.source_span);
                try self.appendSlice("margin");
                try self.appendSlice(if (self.pretty()) ": " else ":");
                try self.appendSlice(try self.raw(proof.value_span));
                if (proof.important) {
                    if (self.pretty()) try self.appendByte(' ');
                    try self.appendSlice("!important");
                }
                if (terminate) try self.appendByte(';');
            },
            .compatibility => {
                compatibility_analysis.validateDeclarationExpansion(
                    self.allocator,
                    self.file,
                    declarations,
                    generated,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.SourceMismatch => return error.SourceMismatch,
                    error.InvalidSpan => return error.InvalidSpan,
                    else => return error.InvalidAst,
                };
                const compatibility = generated.compatibility orelse return error.InvalidAst;
                const input = inputs[0];
                for (compatibility.forms, 0..) |form, index| {
                    if (index > 0 and self.pretty()) {
                        try self.appendByte('\n');
                        try self.writeIndent(depth);
                    }
                    try self.writeCompatibilityDeclaration(input, compatibility.feature, form);
                }
                if (self.pretty()) {
                    try self.appendByte('\n');
                    try self.writeIndent(depth);
                }
                try self.writeDeclaration(input, terminate);
            },
        }
    }

    fn writeCompatibilityDeclaration(
        self: *Emitter,
        declaration: ast.Declaration,
        feature: ast.CompatibilityDeclarationFeature,
        form: ast.CompatibilityForm,
    ) Error!void {
        const output = compatibility_analysis.declarationOutput(feature, form) orelse return error.InvalidAst;
        try self.mark(declaration.span);
        try self.appendSlice(output.name);
        try self.appendSlice(if (self.pretty()) ": " else ":");
        const value = declaration.valueWithoutImportance();
        if (output.value) |generated_value| {
            try self.mark(declaration.value.span);
            try self.appendSlice(generated_value);
        } else if (declaration.generated_value) |generated_value| {
            _ = ast.GeneratedValue.init(generated_value) catch return error.InvalidAst;
            try self.mark(generated_value.sourceSpan());
            var buffer: [ast.generated_value_buffer_size]u8 = undefined;
            try self.appendSlice(generated_value.serialize(&buffer) catch return error.InvalidAst);
        } else {
            try self.writeComponentValues(value);
        }
        if (declaration.important != null) {
            if (self.pretty() and (output.value != null or
                declaration.generated_value != null or hasNonWhitespace(value)))
            {
                try self.appendByte(' ');
            }
            try self.appendSlice("!important");
        }
        try self.appendByte(';');
    }

    fn writeKeyframesBlock(self: *Emitter, block: *const ast.KeyframesBlock, depth: usize) Error!void {
        if (!block.envelope.terminated()) return error.UnterminatedSyntax;
        try self.validateKeyframesCoverage(block);
        try self.appendByte('{');
        if (block.frames.len == 0) {
            try self.appendByte('}');
            return;
        }
        if (self.pretty()) try self.appendByte('\n');
        for (block.frames, 0..) |frame, index| {
            if (index > 0 and self.pretty()) try self.appendByte('\n');
            if (self.pretty()) try self.writeIndent(depth + 1);
            try self.writeKeyframeRule(frame, depth + 1);
        }
        if (self.pretty()) {
            try self.appendByte('\n');
            try self.writeIndent(depth);
        }
        try self.appendByte('}');
    }

    fn writeKeyframeRule(self: *Emitter, frame: ast.KeyframeRule, depth: usize) Error!void {
        _ = ast.KeyframeRule.init(frame) catch return error.InvalidAst;
        if (frame.selectors.len == 0) return error.UnrepresentableRecovery;
        for (frame.selectors, 0..) |selector, index| {
            if (index > 0) try self.appendSlice(if (self.pretty()) ", " else ",");
            try self.mark(selector.span());
            switch (selector) {
                .from => try self.appendSlice("from"),
                .to => try self.appendSlice("to"),
                .percentage => |percentage| try self.appendSlice(try self.raw(percentage.span)),
            }
        }
        try self.writePrettySpace();
        try self.writeDeclarationBlock(&frame.block, depth);
    }

    fn writePageSelectors(self: *Emitter, selectors: []const ast.PageSelector) Error!void {
        for (selectors, 0..) |selector, index| {
            if (index > 0) try self.appendSlice(if (self.pretty()) ", " else ",");
            try self.mark(selector.span);
            if (selector.name) |name| try self.writeIdentifier(name.value);
            for (selector.pseudos) |pseudo| {
                try self.appendByte(':');
                try self.writeIdentifier(pseudo.value);
            }
        }
    }

    fn writePageBlock(
        self: *Emitter,
        page: *const ast.PageRule,
        raw_block: *const ast.RawBlock,
        depth: usize,
    ) Error!void {
        if (!raw_block.envelope.terminated()) return error.UnterminatedSyntax;
        try self.validatePageCoverage(page, raw_block.envelope.content);
        const total = page.declarations.declarations.len + page.margins.len;
        try self.appendByte('{');
        if (total == 0) {
            try self.appendByte('}');
            return;
        }
        if (self.pretty()) try self.appendByte('\n');
        var declaration_index: usize = 0;
        var margin_index: usize = 0;
        var emitted: usize = 0;
        while (emitted < total) : (emitted += 1) {
            if (emitted > 0 and self.pretty()) try self.appendByte('\n');
            if (self.pretty()) try self.writeIndent(depth + 1);
            if (nextPageItemIsDeclaration(page, declaration_index, margin_index)) {
                try self.writeDeclaration(
                    page.declarations.declarations[declaration_index],
                    self.pretty() or emitted + 1 < total,
                );
                declaration_index += 1;
            } else {
                try self.writePageMargin(page.margins[margin_index], depth + 1);
                margin_index += 1;
            }
        }
        if (self.pretty()) {
            try self.appendByte('\n');
            try self.writeIndent(depth);
        }
        try self.appendByte('}');
    }

    fn writePageMargin(self: *Emitter, margin: ast.PageMarginRule, depth: usize) Error!void {
        try self.mark(margin.span);
        try self.appendByte('@');
        try self.writeIdentifier(margin.name.value);
        try self.writePrettySpace();
        try self.writeDeclarationListBlock(margin.declarations, margin.envelope, depth);
    }

    fn writeRawBlock(self: *Emitter, block: *const ast.RawBlock) Error!void {
        if (!block.envelope.terminated()) return error.UnterminatedSyntax;
        try self.appendByte('{');
        try self.writeComponentValuesWithEdges(block.values.values, false);
        try self.appendByte('}');
    }

    fn writeComponentValues(self: *Emitter, values: []const syntax.ComponentValue) Error!void {
        try self.writeComponentValuesWithEdges(values, true);
    }

    fn writeComponentValuesWithEdges(
        self: *Emitter,
        values: []const syntax.ComponentValue,
        trim_edges: bool,
    ) Error!void {
        var wrote_significant = false;
        var pending_space = false;
        for (values) |value| {
            try self.validateComponent(value);
            if (isWhitespace(value)) {
                if (wrote_significant or !trim_edges) pending_space = true;
                continue;
            }
            if (pending_space) try self.appendByte(' ');
            try self.mark(value.span());
            if (self.pretty()) {
                try self.appendSlice(try self.raw(value.span()));
            } else {
                try self.writeMinifiedComponent(value);
            }
            wrote_significant = true;
            pending_space = false;
        }
        if (pending_space and !trim_edges) try self.appendByte(' ');
    }

    fn writeMinifiedComponent(self: *Emitter, value: syntax.ComponentValue) Error!void {
        switch (value) {
            .token => |token| try self.appendSlice(try self.raw(token.span)),
            .simple_block => |block| {
                try self.appendSlice(try self.raw(block.opening.span));
                try self.writeComponentValuesWithEdges(block.values, false);
                try self.appendSlice(try self.raw(block.closing.?.span));
            },
            .function => |function| {
                try self.appendSlice(try self.raw(function.opening.span));
                try self.writeComponentValuesWithEdges(function.values, false);
                try self.appendSlice(try self.raw(function.closing.?.span));
            },
        }
    }

    fn validateComponent(self: *Emitter, value: syntax.ComponentValue) Error!void {
        _ = try self.raw(value.span());
        switch (value) {
            .token => |token| switch (token.kind) {
                .bad_string, .bad_url, .close_curly, .close_square, .close_paren => return error.UnrepresentableRecovery,
                .comment, .string, .url => if (!token.isTerminated()) return error.UnterminatedSyntax,
                else => {},
            },
            .simple_block => |block| {
                if (!block.terminated()) return error.UnterminatedSyntax;
                for (block.values) |child| try self.validateComponent(child);
            },
            .function => |function| {
                if (!function.terminated()) return error.UnterminatedSyntax;
                for (function.values) |child| try self.validateComponent(child);
            },
        }
    }

    fn validateRuleCoverage(
        self: *Emitter,
        rules: *const ast.RuleList,
        top_level: bool,
        allow_nested_declarations: bool,
    ) Error!void {
        rules.validate() catch return error.InvalidAst;
        _ = try self.raw(rules.span);
        var cursor = rules.span.start;
        var rule_index: usize = 0;
        var omission_index: usize = 0;
        while (rule_index < rules.rules.len or omission_index < rules.omitted_rules.len) {
            const take_rule = omission_index == rules.omitted_rules.len or
                (rule_index < rules.rules.len and
                    rules.rules[rule_index].span().start <= rules.omitted_rules[omission_index].span().start);
            const span = if (take_rule)
                rules.rules[rule_index].span()
            else
                rules.omitted_rules[omission_index].span();
            if (!try self.gapAllowed(cursor, span.start, allow_nested_declarations, top_level)) {
                return error.UnrepresentableRecovery;
            }
            cursor = span.end;
            if (take_rule) {
                if (rules.rules[rule_index] == .nested_declarations and !allow_nested_declarations) {
                    return error.InvalidAst;
                }
                rule_index += 1;
            } else {
                try self.validateOmittedRule(rules.omitted_rules[omission_index]);
                omission_index += 1;
            }
        }
        if (!try self.gapAllowed(cursor, rules.span.end, allow_nested_declarations, top_level)) {
            return error.UnrepresentableRecovery;
        }
    }

    fn validateOmittedRule(self: *Emitter, rule: ast.Rule) Error!void {
        if (!ast.isOmittableRule(rule)) return error.InvalidAst;
        switch (rule) {
            .style_rule => |style| {
                _ = ast.StyleRule.init(style.*) catch return error.InvalidAst;
                if (!style.block.envelope.terminated()) return error.UnterminatedSyntax;
                try self.validateDeclarationCoverage(&style.block.declarations);
                try self.validateRuleCoverage(&style.block.rules, false, true);
            },
            .at_rule => |at_rule| {
                _ = ast.AtRule.init(at_rule.*) catch return error.InvalidAst;
                if (!structuredDetailsMatch(at_rule)) return error.UnrepresentableRecovery;
                const block = switch (at_rule.block) {
                    .rules => |value| value,
                    else => return error.InvalidAst,
                };
                if (!block.envelope.terminated()) return error.UnterminatedSyntax;
                try self.validateRuleCoverage(&block.rules, false, block.nested);
            },
            .nested_declarations => return error.InvalidAst,
        }
    }

    fn validateDeclarationCoverage(self: *Emitter, declarations: *const ast.DeclarationList) Error!void {
        declarations.validate() catch return error.InvalidAst;
        var cursor = declarations.span.start;
        for (declarations.declarations) |declaration| {
            if (declaration.span.start < cursor) return error.InvalidAst;
            if (!try self.gapAllowed(cursor, declaration.span.start, true, false)) return error.UnrepresentableRecovery;
            cursor = declaration.span.end;
        }
        if (!try self.gapAllowed(cursor, declarations.span.end, true, false)) return error.UnrepresentableRecovery;
    }

    fn validateKeyframesCoverage(self: *Emitter, block: *const ast.KeyframesBlock) Error!void {
        var cursor = block.envelope.content.start;
        for (block.frames) |frame| {
            try validateChildSpan(block.envelope.content, frame.span);
            if (frame.span.start < cursor) return error.InvalidAst;
            if (!try self.gapAllowed(cursor, frame.span.start, false, false)) return error.UnrepresentableRecovery;
            cursor = frame.span.end;
        }
        if (!try self.gapAllowed(cursor, block.envelope.content.end, false, false)) return error.UnrepresentableRecovery;
    }

    fn validatePageCoverage(self: *Emitter, page: *const ast.PageRule, content: source.Span) Error!void {
        // Page margin at-rules are interleaved with this declaration array.
        // A declaration-only proof cannot establish source adjacency here.
        if (page.declarations.generated_declarations.len != 0) return error.InvalidAst;
        var declaration_index: usize = 0;
        var margin_index: usize = 0;
        var cursor = content.start;
        const total = page.declarations.declarations.len + page.margins.len;
        var visited: usize = 0;
        while (visited < total) : (visited += 1) {
            const span = if (nextPageItemIsDeclaration(page, declaration_index, margin_index)) blk: {
                const declaration = page.declarations.declarations[declaration_index];
                declaration_index += 1;
                break :blk declaration.span;
            } else blk: {
                const margin = page.margins[margin_index];
                margin_index += 1;
                break :blk margin.span;
            };
            try validateChildSpan(content, span);
            if (span.start < cursor) return error.InvalidAst;
            if (!try self.gapAllowed(cursor, span.start, true, false)) return error.UnrepresentableRecovery;
            cursor = span.end;
        }
        if (!try self.gapAllowed(cursor, content.end, true, false)) return error.UnrepresentableRecovery;
    }

    fn gapAllowed(
        self: *Emitter,
        start: usize,
        end: usize,
        allow_semicolon: bool,
        allow_cdo_cdc: bool,
    ) Error!bool {
        const bytes = try self.raw(.{ .source = self.file.id, .start = start, .end = end });
        var index: usize = 0;
        while (index < bytes.len) {
            if (isCssWhitespace(bytes[index]) or (allow_semicolon and bytes[index] == ';')) {
                index += 1;
                continue;
            }
            if (index + 1 < bytes.len and bytes[index] == '/' and bytes[index + 1] == '*') {
                var closing = index + 2;
                while (closing + 1 < bytes.len and !(bytes[closing] == '*' and bytes[closing + 1] == '/')) {
                    closing += 1;
                }
                if (closing + 1 >= bytes.len) return false;
                index = closing + 2;
                continue;
            }
            if (allow_cdo_cdc and startsWithAt(bytes, index, "<!--")) {
                index += 4;
                continue;
            }
            if (allow_cdo_cdc and startsWithAt(bytes, index, "-->")) {
                index += 3;
                continue;
            }
            return false;
        }
        return true;
    }

    fn raw(self: *Emitter, span: source.Span) Error![]const u8 {
        return self.file.slice(span) catch |err| switch (err) {
            error.SourceMismatch => return error.SourceMismatch,
            error.InvalidSpan => return error.InvalidSpan,
        };
    }

    fn writeIdentifier(self: *Emitter, value: []const u8) Error!void {
        const start = self.output.items.len;
        try appendIdentifier(&self.output, self.allocator, value);
        try self.advanceGenerated(self.output.items[start..]);
    }

    fn writeString(self: *Emitter, value: []const u8) Error!void {
        const start = self.output.items.len;
        try appendString(&self.output, self.allocator, value);
        try self.advanceGenerated(self.output.items[start..]);
    }

    fn pretty(self: *const Emitter) bool {
        return self.options.mode == .pretty;
    }

    fn writePrettySpace(self: *Emitter) Error!void {
        if (self.pretty()) try self.appendByte(' ');
    }

    fn writeAtRuleBlockSeparator(self: *Emitter, rule: *const ast.AtRule) Error!void {
        if (self.pretty() and (rule.details != null or endsWithWhitespace(rule.prelude.values))) {
            try self.appendByte(' ');
        }
    }

    fn writeIndent(self: *Emitter, depth: usize) Error!void {
        var level: usize = 0;
        while (level < depth) : (level += 1) {
            var column: u8 = 0;
            while (column < self.options.indent_width) : (column += 1) try self.appendByte(' ');
        }
    }

    fn appendSlice(self: *Emitter, bytes: []const u8) Error!void {
        try self.output.appendSlice(self.allocator, bytes);
        try self.advanceGenerated(bytes);
    }

    fn appendByte(self: *Emitter, byte: u8) Error!void {
        try self.output.append(self.allocator, byte);
        try self.advanceGenerated(&.{byte});
    }

    fn mark(self: *Emitter, span: source.Span) Error!void {
        const builder = self.source_map_builder orelse return;
        if (!span.source.eql(self.file.id)) return error.SourceMismatch;
        if (self.generated_line > std.math.maxInt(u32) or self.generated_column > std.math.maxInt(u32)) {
            return error.GeneratedPositionOverflow;
        }
        try builder.addMapping(
            @intCast(self.generated_line),
            @intCast(self.generated_column),
            span.start,
        );
    }

    fn advanceGenerated(self: *Emitter, bytes: []const u8) Error!void {
        var index: usize = 0;
        while (index < bytes.len) {
            if (bytes[index] == '\n' and self.generated_last_was_cr) {
                self.generated_last_was_cr = false;
                index += 1;
                continue;
            }
            self.generated_last_was_cr = false;
            if (bytes[index] == '\r') {
                self.generated_line = std.math.add(usize, self.generated_line, 1) catch return error.GeneratedPositionOverflow;
                self.generated_column = 0;
                self.generated_last_was_cr = true;
                index += 1;
                continue;
            }
            if (bytes[index] == '\n' or bytes[index] == '\x0c') {
                self.generated_line = std.math.add(usize, self.generated_line, 1) catch return error.GeneratedPositionOverflow;
                self.generated_column = 0;
                index += 1;
                continue;
            }
            const scalar = decodeScalar(bytes, index);
            index += scalar.len;
            self.generated_column = std.math.add(
                usize,
                self.generated_column,
                if (scalar.value > 0xffff) 2 else 1,
            ) catch return error.GeneratedPositionOverflow;
        }
    }
};

fn logicalDeclarationCount(declarations: *const ast.DeclarationList) Error!usize {
    declarations.validate() catch return error.InvalidAst;
    var count = declarations.declarations.len;
    for (declarations.generated_declarations) |generated| {
        const inputs = generated.kind.inputCount();
        const outputs = generated.outputCount() catch return error.InvalidAst;
        if (inputs > count) return error.InvalidAst;
        count -= inputs;
        count = std.math.add(usize, count, outputs) catch return error.ValueOverflow;
    }
    return count;
}

fn logicalRuleCount(rules: *const ast.RuleList) Error!usize {
    rules.validate() catch return error.InvalidAst;
    var count = rules.rules.len;
    for (rules.generated_rules) |generated| {
        const inputs = generated.kind.inputCount();
        const outputs = generated.outputCount() catch return error.InvalidAst;
        if (inputs > count) return error.InvalidAst;
        count -= inputs;
        count = std.math.add(usize, count, outputs) catch return error.ValueOverflow;
    }
    return count;
}

fn pageDetails(details: ?ast.AtRuleDetails) ?*const ast.PageRule {
    const value = details orelse return null;
    return switch (value) {
        .page => |page| page,
        else => null,
    };
}

fn structuredDetailsMatch(rule: *const ast.AtRule) bool {
    const details = rule.details;
    if (std.ascii.eqlIgnoreCase(rule.name.value, "media")) return details != null and details.? == .media;
    if (std.ascii.eqlIgnoreCase(rule.name.value, "supports")) return details != null and details.? == .supports;
    if (std.ascii.eqlIgnoreCase(rule.name.value, "container")) return details != null and details.? == .container;
    if (std.ascii.eqlIgnoreCase(rule.name.value, "layer")) return details != null and details.? == .layer;
    if (std.ascii.eqlIgnoreCase(rule.name.value, "property")) return details != null and details.? == .property;
    if (std.ascii.eqlIgnoreCase(rule.name.value, "page")) return details != null and details.? == .page;
    if (std.ascii.eqlIgnoreCase(rule.name.value, "font-face")) return details != null and details.? == .font_face;
    if (std.ascii.eqlIgnoreCase(rule.name.value, "keyframes") or
        std.ascii.eqlIgnoreCase(rule.name.value, "-webkit-keyframes") or
        std.ascii.eqlIgnoreCase(rule.name.value, "-moz-keyframes"))
    {
        return details != null and details.? == .keyframes;
    }
    return true;
}

fn nextPageItemIsDeclaration(
    page: *const ast.PageRule,
    declaration_index: usize,
    margin_index: usize,
) bool {
    if (declaration_index == page.declarations.declarations.len) return false;
    if (margin_index == page.margins.len) return true;
    return page.declarations.declarations[declaration_index].span.start <= page.margins[margin_index].span.start;
}

fn appendIdentifier(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
) std.mem.Allocator.Error!void {
    var byte_index: usize = 0;
    var position: usize = 0;
    var first_was_hyphen = false;
    while (byte_index < value.len) : (position += 1) {
        const scalar = decodeScalar(value, byte_index);
        const codepoint = scalar.value;
        if (position == 0) first_was_hyphen = codepoint == '-';
        if (codepoint == 0) {
            try output.appendSlice(allocator, "�");
        } else if (isControl(codepoint) or
            (position == 0 and isAsciiDigit(codepoint)) or
            (position == 1 and first_was_hyphen and isAsciiDigit(codepoint)))
        {
            try appendCodepointEscape(output, allocator, codepoint);
        } else if (position == 0 and codepoint == '-' and scalar.len == value.len) {
            try output.appendSlice(allocator, "\\-");
        } else if (codepoint >= 0x80 or codepoint == '-' or codepoint == '_' or
            isAsciiDigit(codepoint) or isAsciiLetter(codepoint))
        {
            try appendScalar(output, allocator, value[byte_index .. byte_index + scalar.len], scalar.valid);
        } else {
            try output.append(allocator, '\\');
            try appendScalar(output, allocator, value[byte_index .. byte_index + scalar.len], scalar.valid);
        }
        byte_index += scalar.len;
    }
}

fn appendString(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
) std.mem.Allocator.Error!void {
    try output.append(allocator, '"');
    var byte_index: usize = 0;
    while (byte_index < value.len) {
        const scalar = decodeScalar(value, byte_index);
        if (scalar.value == 0) {
            try output.appendSlice(allocator, "�");
        } else if (isControl(scalar.value)) {
            try appendCodepointEscape(output, allocator, scalar.value);
        } else if (scalar.value == '"' or scalar.value == '\\') {
            try output.append(allocator, '\\');
            try appendScalar(output, allocator, value[byte_index .. byte_index + scalar.len], scalar.valid);
        } else {
            try appendScalar(output, allocator, value[byte_index .. byte_index + scalar.len], scalar.valid);
        }
        byte_index += scalar.len;
    }
    try output.append(allocator, '"');
}

const DecodedScalar = struct {
    value: u21,
    len: usize,
    valid: bool,
};

fn decodeScalar(value: []const u8, index: usize) DecodedScalar {
    const sequence_length: usize = std.unicode.utf8ByteSequenceLength(value[index]) catch {
        return .{ .value = 0xfffd, .len = 1, .valid = false };
    };
    if (index + sequence_length > value.len) return .{ .value = 0xfffd, .len = 1, .valid = false };
    const codepoint = std.unicode.utf8Decode(value[index .. index + sequence_length]) catch {
        return .{ .value = 0xfffd, .len = 1, .valid = false };
    };
    return .{ .value = codepoint, .len = sequence_length, .valid = true };
}

fn appendScalar(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    original: []const u8,
    valid: bool,
) std.mem.Allocator.Error!void {
    try output.appendSlice(allocator, if (valid) original else "�");
}

fn appendCodepointEscape(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    codepoint: u21,
) std.mem.Allocator.Error!void {
    try output.append(allocator, '\\');
    var digits: [6]u8 = undefined;
    var start = digits.len;
    var remaining: u32 = codepoint;
    while (remaining > 0) {
        start -= 1;
        const digit: u8 = @intCast(remaining & 0xf);
        digits[start] = if (digit < 10) '0' + digit else 'a' + (digit - 10);
        remaining >>= 4;
    }
    if (start == digits.len) {
        start -= 1;
        digits[start] = '0';
    }
    try output.appendSlice(allocator, digits[start..]);
    try output.append(allocator, ' ');
}

fn isControl(codepoint: u21) bool {
    return (codepoint >= 1 and codepoint <= 0x1f) or codepoint == 0x7f;
}

fn isAsciiDigit(codepoint: u21) bool {
    return codepoint >= '0' and codepoint <= '9';
}

fn isAsciiLetter(codepoint: u21) bool {
    return (codepoint >= 'a' and codepoint <= 'z') or (codepoint >= 'A' and codepoint <= 'Z');
}

fn hasNonWhitespace(values: []const syntax.ComponentValue) bool {
    for (values) |value| if (!isWhitespace(value)) return true;
    return false;
}

fn beginsWithWhitespace(values: []const syntax.ComponentValue) bool {
    return values.len > 0 and isWhitespace(values[0]);
}

fn endsWithWhitespace(values: []const syntax.ComponentValue) bool {
    return values.len > 0 and isWhitespace(values[values.len - 1]);
}

fn isWhitespace(value: syntax.ComponentValue) bool {
    return switch (value) {
        .token => |token| token.kind == .whitespace,
        else => false,
    };
}

fn isCssWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == '\x0c';
}

fn startsWithAt(bytes: []const u8, index: usize, expected: []const u8) bool {
    return index + expected.len <= bytes.len and std.mem.eql(u8, bytes[index .. index + expected.len], expected);
}

fn validateChildSpan(parent: source.Span, child: source.Span) Error!void {
    if (!parent.source.eql(child.source)) return error.SourceMismatch;
    if (child.start > child.end or child.start < parent.start or child.end > parent.end) return error.InvalidAst;
}

fn spansEqual(a: source.Span, b: source.Span) bool {
    return a.source.eql(b.source) and a.start == b.start and a.end == b.end;
}

fn parseSource(
    context: *compilation.Compilation,
    name: []const u8,
    css: []const u8,
) !struct { source.SourceId, *const ast.RuleList } {
    const id = try context.addSource(name, css);
    const document = try syntax.parse(context, id);
    const values = try ast.ComponentValueList.init(document.span, document.values);
    return .{ id, try rule_parser.parse(context, id, values) };
}

fn replaceFirstStyleDeclarations(
    context: *compilation.Compilation,
    old_root: *const ast.RuleList,
    declarations: ast.DeclarationList,
) !*const ast.RuleList {
    const arena = context.arenaAllocator();
    const old_style = old_root.rules[0].style_rule;
    const style = try arena.create(ast.StyleRule);
    style.* = try ast.StyleRule.init(.{
        .selectors = old_style.selectors,
        .block = try ast.StyleBlock.init(
            old_style.block.envelope,
            declarations,
            old_style.block.rules,
        ),
        .span = old_style.span,
    });
    const rules = try arena.dupe(ast.Rule, old_root.rules);
    rules[0] = .{ .style_rule = style };
    const root = try arena.create(ast.RuleList);
    root.* = try ast.RuleList.initWithOmissions(old_root.span, rules, old_root.omitted_rules);
    return root;
}

test "pretty emission deterministically formats typed rules without reordering" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "pretty.css",
        ".a.b,svg|button:hover > #\\31 id[data-x='a\"b' i]{color : red ;color:blue!important;--x:fn(a ; b)}" ++
            "@media  screen and (width > 1px){.c{display:grid}}" ++
            "@font-face{font-family:'A';src:url(x)}" ++
            "@unknown foo{a(b;c)}",
    );
    const file = try context.sources.get(parsed[0]);

    const first = try emit(std.testing.allocator, file, parsed[1], .{});
    defer std.testing.allocator.free(first);
    const second = try emit(std.testing.allocator, file, parsed[1], .{});
    defer std.testing.allocator.free(second);
    const expected =
        ".a.b, svg|button:hover > #\\31 id[data-x=\"a\\\"b\" i] {\n" ++
        "  color: red;\n" ++
        "  color: blue !important;\n" ++
        "  --x: fn(a ; b);\n" ++
        "}\n" ++
        "@media screen and (width > 1px) {\n" ++
        "  .c {\n" ++
        "    display: grid;\n" ++
        "  }\n" ++
        "}\n" ++
        "@font-face {\n" ++
        "  font-family: 'A';\n" ++
        "  src: url(x);\n" ++
        "}\n" ++
        "@unknown foo{a(b;c)}\n";
    try std.testing.expectEqualStrings(expected, first);
    try std.testing.expectEqualStrings(first, second);

    var reparsed_context = try compilation.Compilation.init(std.testing.allocator);
    defer reparsed_context.deinit();
    const reparsed = try parseSource(&reparsed_context, "pretty-output.css", first);
    try std.testing.expectEqual(@as(usize, 4), reparsed[1].rules.len);
    const emitted_selectors = reparsed[1].rules[0].style_rule.selectors.selectors;
    try std.testing.expectEqualStrings("1id", emitted_selectors[1].tails[0].compound.simple_selectors[0].id.name.value);
    try std.testing.expectEqual(@as(usize, 3), reparsed[1].rules[0].style_rule.block.declarations.declarations.len);
    try std.testing.expectEqualStrings("color", reparsed[1].rules[0].style_rule.block.declarations.declarations[0].name.value);
    try std.testing.expectEqualStrings("color", reparsed[1].rules[0].style_rule.block.declarations.declarations[1].name.value);
    try std.testing.expect(reparsed[1].rules[0].style_rule.block.declarations.declarations[1].important != null);
    try std.testing.expectEqual(@as(usize, 0), reparsed_context.diagnostics.items().len);
}

test "structured generated numeric values emit closed syntax with causal mappings" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "generated-numeric.css",
        ".a{x:calc(1px + 2px)!important;y:4px}",
    );
    const file = try context.sources.get(parsed[0]);
    const old_root = parsed[1];
    const old_style = old_root.rules[0].style_rule;
    const arena = context.arenaAllocator();

    const declarations = try arena.dupe(ast.Declaration, old_style.block.declarations.declarations);
    const causal_span = declarations[0].valueWithoutImportance()[0].span();
    declarations[0].generated_value = .{ .numeric = .{
        .value = 3,
        .unit = .px,
        .source_span = causal_span,
    } };
    declarations[0] = try ast.Declaration.init(declarations[0]);
    const declaration_list = try ast.DeclarationList.init(old_style.block.declarations.span, declarations);
    const style = try arena.create(ast.StyleRule);
    style.* = try ast.StyleRule.init(.{
        .selectors = old_style.selectors,
        .block = try ast.StyleBlock.init(
            old_style.block.envelope,
            declaration_list,
            old_style.block.rules,
        ),
        .span = old_style.span,
    });
    const rules = try arena.dupe(ast.Rule, old_root.rules);
    rules[0] = .{ .style_rule = style };
    const root = try arena.create(ast.RuleList);
    root.* = try ast.RuleList.initWithOmissions(old_root.span, rules, old_root.omitted_rules);

    const pretty_output = try emit(std.testing.allocator, file, root, .{});
    defer std.testing.allocator.free(pretty_output);
    try std.testing.expectEqualStrings(
        ".a {\n  x: 3px !important;\n  y: 4px;\n}\n",
        pretty_output,
    );

    var mapped = try emitWithSourceMap(
        std.testing.allocator,
        file,
        root,
        .{ .mode = .minified },
        .{},
    );
    defer mapped.deinit();
    try std.testing.expectEqualStrings(".a{x:3px!important;y:4px}", mapped.css);
    var json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mapped.source_map, .{});
    defer json.deinit();
    const mappings = try sourcemap.decodeMappings(
        std.testing.allocator,
        json.value.object.get("mappings").?.string,
    );
    defer std.testing.allocator.free(mappings);
    const generated_start = std.mem.indexOf(u8, mapped.css, "3px").?;
    try std.testing.expect(hasMapping(mappings, .{
        .generated_line = 0,
        .generated_column = @intCast(generated_start),
        .original_line = 0,
        .original_column = @intCast(causal_span.start),
    }));
    for (mappings) |mapping| {
        try std.testing.expect(mapping.generated_column != generated_start + 1);
        try std.testing.expect(mapping.generated_column != generated_start + 2);
    }
}

test "proof-carrying margin shorthand emits one causal mapping" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "generated-margin.css",
        ".a{x:0;margin-top:a\\75to!important;margin-right:a\\75to!important;" ++
            "margin-bottom:a\\75to!important;margin-left:a\\75to!important;y:2}",
    );
    const file = try context.sources.get(parsed[0]);
    const original = parsed[1].rules[0].style_rule.block.declarations;
    const generated = [_]ast.GeneratedDeclaration{.{
        .kind = .margin,
        .first_declaration = 1,
        .source_span = .{
            .source = file.id,
            .start = original.declarations[1].span.start,
            .end = original.declarations[4].span.end,
        },
    }};
    const declarations = try ast.DeclarationList.initWithGenerated(
        original.span,
        original.declarations,
        &generated,
    );
    const root = try replaceFirstStyleDeclarations(&context, parsed[1], declarations);

    const pretty_output = try emit(std.testing.allocator, file, root, .{});
    defer std.testing.allocator.free(pretty_output);
    try std.testing.expectEqualStrings(
        ".a {\n  x: 0;\n  margin: a\\75to !important;\n  y: 2;\n}\n",
        pretty_output,
    );

    var mapped = try emitWithSourceMap(
        std.testing.allocator,
        file,
        root,
        .{ .mode = .minified },
        .{},
    );
    defer mapped.deinit();
    try std.testing.expectEqualStrings(".a{x:0;margin:a\\75to!important;y:2}", mapped.css);
    var json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mapped.source_map, .{});
    defer json.deinit();
    const mappings = try sourcemap.decodeMappings(
        std.testing.allocator,
        json.value.object.get("mappings").?.string,
    );
    defer std.testing.allocator.free(mappings);
    const generated_start = std.mem.indexOf(u8, mapped.css, "margin").?;
    const sibling_start = std.mem.indexOf(u8, mapped.css, "y:2").?;
    try std.testing.expect(hasMapping(mappings, .{
        .generated_line = 0,
        .generated_column = @intCast(generated_start),
        .original_line = 0,
        .original_column = @intCast(generated[0].source_span.start),
    }));
    try std.testing.expect(hasMapping(mappings, .{
        .generated_line = 0,
        .generated_column = @intCast(sibling_start),
        .original_line = 0,
        .original_column = @intCast(original.declarations[5].span.start),
    }));
    for (mappings) |mapping| {
        try std.testing.expect(mapping.generated_column <= generated_start or
            mapping.generated_column >= sibling_start);
    }
}

test "proof-carrying compatibility declarations emit fallbacks before authored syntax" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "generated-prefix-declarations.css",
        ".a{appearance:none;position:st\\69 cky!important;display:flex}",
    );
    const file = try context.sources.get(parsed[0]);
    const original = parsed[1].rules[0].style_rule.block.declarations;
    const appearance_forms = [_]ast.CompatibilityForm{ .webkit, .moz };
    const sticky_forms = [_]ast.CompatibilityForm{.webkit};
    const flex_forms = [_]ast.CompatibilityForm{ .webkit, .ms };
    const generated = [_]ast.GeneratedDeclaration{
        .{
            .kind = .compatibility,
            .first_declaration = 0,
            .source_span = original.declarations[0].span,
            .compatibility = .{ .feature = .appearance, .forms = &appearance_forms },
        },
        .{
            .kind = .compatibility,
            .first_declaration = 1,
            .source_span = original.declarations[1].span,
            .compatibility = .{ .feature = .position_sticky, .forms = &sticky_forms },
        },
        .{
            .kind = .compatibility,
            .first_declaration = 2,
            .source_span = original.declarations[2].span,
            .compatibility = .{ .feature = .display_flex, .forms = &flex_forms },
        },
    };
    const declarations = try ast.DeclarationList.initWithGenerated(
        original.span,
        original.declarations,
        &generated,
    );
    const root = try replaceFirstStyleDeclarations(&context, parsed[1], declarations);

    const pretty_output = try emit(std.testing.allocator, file, root, .{});
    defer std.testing.allocator.free(pretty_output);
    try std.testing.expectEqualStrings(
        ".a {\n" ++
            "  -webkit-appearance: none;\n" ++
            "  -moz-appearance: none;\n" ++
            "  appearance: none;\n" ++
            "  position: -webkit-sticky !important;\n" ++
            "  position: st\\69 cky !important;\n" ++
            "  display: -webkit-flex;\n" ++
            "  display: -ms-flexbox;\n" ++
            "  display: flex;\n" ++
            "}\n",
        pretty_output,
    );

    var mapped = try emitWithSourceMap(
        std.testing.allocator,
        file,
        root,
        .{ .mode = .minified },
        .{},
    );
    defer mapped.deinit();
    try std.testing.expectEqualStrings(
        ".a{-webkit-appearance:none;-moz-appearance:none;appearance:none;" ++
            "position:-webkit-sticky!important;position:st\\69 cky!important;" ++
            "display:-webkit-flex;display:-ms-flexbox;display:flex}",
        mapped.css,
    );
    var json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mapped.source_map, .{});
    defer json.deinit();
    const mappings = try sourcemap.decodeMappings(
        std.testing.allocator,
        json.value.object.get("mappings").?.string,
    );
    defer std.testing.allocator.free(mappings);
    const webkit_start = std.mem.indexOf(u8, mapped.css, "-webkit-appearance").?;
    try std.testing.expect(hasMapping(mappings, .{
        .generated_line = 0,
        .generated_column = @intCast(webkit_start),
        .original_line = 0,
        .original_column = @intCast(original.declarations[0].span.start),
    }));
}

test "compatibility declaration emission rejects authored vendor conflicts" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "forged-prefix-declarations.css",
        ".a{-webkit-appearance:none;appearance:none}",
    );
    const file = try context.sources.get(parsed[0]);
    const original = parsed[1].rules[0].style_rule.block.declarations;
    const forms = [_]ast.CompatibilityForm{.webkit};
    const generated = [_]ast.GeneratedDeclaration{.{
        .kind = .compatibility,
        .first_declaration = 1,
        .source_span = original.declarations[1].span,
        .compatibility = .{ .feature = .appearance, .forms = &forms },
    }};
    const declarations = try ast.DeclarationList.initWithGenerated(
        original.span,
        original.declarations,
        &generated,
    );
    const root = try replaceFirstStyleDeclarations(&context, parsed[1], declarations);
    try std.testing.expectError(
        error.InvalidAst,
        emit(std.testing.allocator, file, root, .{ .mode = .minified }),
    );
}

test "margin shorthand emission rejects a structurally plausible forged proof" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "forged-margin.css",
        ".a{margin-top:1px;margin-right:2px;margin-bottom:1px;margin-left:1px}",
    );
    const file = try context.sources.get(parsed[0]);
    const original = parsed[1].rules[0].style_rule.block.declarations;
    const generated = [_]ast.GeneratedDeclaration{.{
        .kind = .margin,
        .first_declaration = 0,
        .source_span = .{
            .source = file.id,
            .start = original.declarations[0].span.start,
            .end = original.declarations[3].span.end,
        },
    }};
    const declarations = try ast.DeclarationList.initWithGenerated(
        original.span,
        original.declarations,
        &generated,
    );
    const root = try replaceFirstStyleDeclarations(&context, parsed[1], declarations);
    try std.testing.expectError(
        error.InvalidAst,
        emit(std.testing.allocator, file, root, .{ .mode = .minified }),
    );
}

test "proof-carrying selector and keyframes compatibility rules remain separate and standard-last" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "generated-prefix-rules.css",
        "input::placeholder,textarea::placeholder{color:red}" ++
            "@keyframes spin{from{opacity:0}to{opacity:1}}",
    );
    const file = try context.sources.get(parsed[0]);
    const placeholder_forms = [_]ast.CompatibilityForm{ .webkit, .moz, .ms };
    const keyframes_forms = [_]ast.CompatibilityForm{ .webkit, .moz };
    const generated = [_]ast.GeneratedRule{
        .{
            .kind = .compatibility,
            .first_rule = 0,
            .source_span = parsed[1].rules[0].span(),
            .compatibility = .{ .feature = .placeholder, .forms = &placeholder_forms },
        },
        .{
            .kind = .compatibility,
            .first_rule = 1,
            .source_span = parsed[1].rules[1].span(),
            .compatibility = .{ .feature = .keyframes, .forms = &keyframes_forms },
        },
    };
    const transformed = try ast.RuleList.initWithGeneratedRules(
        parsed[1].span,
        parsed[1].rules,
        parsed[1].omitted_rules,
        &generated,
    );
    var mapped = try emitWithSourceMap(
        std.testing.allocator,
        file,
        &transformed,
        .{ .mode = .minified },
        .{},
    );
    defer mapped.deinit();
    try std.testing.expectEqualStrings(
        "input::-webkit-input-placeholder,textarea::-webkit-input-placeholder{color:red}" ++
            "input::-moz-placeholder,textarea::-moz-placeholder{color:red}" ++
            "input:-ms-input-placeholder,textarea:-ms-input-placeholder{color:red}" ++
            "input::placeholder,textarea::placeholder{color:red}" ++
            "@-webkit-keyframes spin{from{opacity:0}to{opacity:1}}" ++
            "@-moz-keyframes spin{from{opacity:0}to{opacity:1}}" ++
            "@keyframes spin{from{opacity:0}to{opacity:1}}",
        mapped.css,
    );

    var json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mapped.source_map, .{});
    defer json.deinit();
    const mappings = try sourcemap.decodeMappings(
        std.testing.allocator,
        json.value.object.get("mappings").?.string,
    );
    defer std.testing.allocator.free(mappings);
    const original_style = parsed[1].rules[0].style_rule;
    const original_pseudo = original_style.selectors.selectors[0].head.simple_selectors[1].span();
    const webkit_pseudo = std.mem.indexOf(u8, mapped.css, "::-webkit-input-placeholder").?;
    try std.testing.expect(hasMapping(mappings, .{
        .generated_line = 0,
        .generated_column = @intCast(webkit_pseudo),
        .original_line = 0,
        .original_column = @intCast(original_pseudo.start),
    }));
    const keyframes = parsed[1].rules[1].at_rule;
    const webkit_keyframes = std.mem.indexOf(u8, mapped.css, "-webkit-keyframes").?;
    try std.testing.expect(hasMapping(mappings, .{
        .generated_line = 0,
        .generated_column = @intCast(webkit_keyframes),
        .original_line = 0,
        .original_column = @intCast(keyframes.name.span.start),
    }));

    var reparsed_context = try compilation.Compilation.init(std.testing.allocator);
    defer reparsed_context.deinit();
    _ = try parseSource(&reparsed_context, "generated-prefix-rules-output.css", mapped.css);
    try std.testing.expectEqual(@as(usize, 0), reparsed_context.diagnostics.items().len);
}

test "compatibility rule proofs reject mixed lists and authored vendor conflicts" {
    var mixed_context = try compilation.Compilation.init(std.testing.allocator);
    defer mixed_context.deinit();
    const mixed = try parseSource(
        &mixed_context,
        "mixed-prefix-selector.css",
        ".plain,input::placeholder{color:red}",
    );
    const forms = [_]ast.CompatibilityForm{.webkit};
    const mixed_generated = [_]ast.GeneratedRule{.{
        .kind = .compatibility,
        .first_rule = 0,
        .source_span = mixed[1].rules[0].span(),
        .compatibility = .{ .feature = .placeholder, .forms = &forms },
    }};
    try std.testing.expectError(
        error.InvalidRule,
        ast.RuleList.initWithGeneratedRules(
            mixed[1].span,
            mixed[1].rules,
            mixed[1].omitted_rules,
            &mixed_generated,
        ),
    );

    var conflict_context = try compilation.Compilation.init(std.testing.allocator);
    defer conflict_context.deinit();
    const conflict = try parseSource(
        &conflict_context,
        "conflicting-prefix-selector.css",
        "input::-webkit-input-placeholder{color:red}input::placeholder{color:red}",
    );
    const conflict_generated = [_]ast.GeneratedRule{.{
        .kind = .compatibility,
        .first_rule = 1,
        .source_span = conflict[1].rules[1].span(),
        .compatibility = .{ .feature = .placeholder, .forms = &forms },
    }};
    const transformed = try ast.RuleList.initWithGeneratedRules(
        conflict[1].span,
        conflict[1].rules,
        conflict[1].omitted_rules,
        &conflict_generated,
    );
    try std.testing.expectError(
        error.InvalidAst,
        emit(
            std.testing.allocator,
            try conflict_context.sources.get(conflict[0]),
            &transformed,
            .{ .mode = .minified },
        ),
    );
}

test "proof-carrying selector merge emits authored mappings and one declaration block" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "generated-selector-merge.css",
        ".a{x:1;color:red!important}/*gap*/.b,.c{x:1;color:red!important}.d{y:2}",
    );
    const file = try context.sources.get(parsed[0]);
    const generated = [_]ast.GeneratedRule{.{
        .kind = .selector_list_merge,
        .first_rule = 0,
        .source_span = .{
            .source = file.id,
            .start = parsed[1].rules[0].span().start,
            .end = parsed[1].rules[1].span().end,
        },
    }};
    const transformed = try ast.RuleList.initWithGeneratedRules(
        parsed[1].span,
        parsed[1].rules,
        parsed[1].omitted_rules,
        &generated,
    );

    const pretty_output = try emit(std.testing.allocator, file, &transformed, .{});
    defer std.testing.allocator.free(pretty_output);
    try std.testing.expectEqualStrings(
        ".a, .b, .c {\n  x: 1;\n  color: red !important;\n}\n.d {\n  y: 2;\n}\n",
        pretty_output,
    );

    var mapped = try emitWithSourceMap(
        std.testing.allocator,
        file,
        &transformed,
        .{ .mode = .minified },
        .{},
    );
    defer mapped.deinit();
    try std.testing.expectEqualStrings(
        ".a,.b,.c{x:1;color:red!important}.d{y:2}",
        mapped.css,
    );
    var json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mapped.source_map, .{});
    defer json.deinit();
    const mappings = try sourcemap.decodeMappings(
        std.testing.allocator,
        json.value.object.get("mappings").?.string,
    );
    defer std.testing.allocator.free(mappings);
    const first = parsed[1].rules[0].style_rule;
    const second = parsed[1].rules[1].style_rule;
    const sibling = parsed[1].rules[2].style_rule;
    const second_selector_output = std.mem.indexOf(u8, mapped.css, ".b").?;
    const declaration_output = std.mem.indexOf(u8, mapped.css, "x:1").?;
    const sibling_output = std.mem.indexOf(u8, mapped.css, ".d").?;
    try std.testing.expect(hasMapping(mappings, .{
        .generated_line = 0,
        .generated_column = @intCast(second_selector_output),
        .original_line = 0,
        .original_column = @intCast(second.selectors.selectors[0].span.start),
    }));
    try std.testing.expect(hasMapping(mappings, .{
        .generated_line = 0,
        .generated_column = @intCast(declaration_output),
        .original_line = 0,
        .original_column = @intCast(first.block.declarations.declarations[0].span.start),
    }));
    try std.testing.expect(hasMapping(mappings, .{
        .generated_line = 0,
        .generated_column = @intCast(sibling_output),
        .original_line = 0,
        .original_column = @intCast(sibling.selectors.selectors[0].span.start),
    }));
    for (mappings) |mapping| {
        try std.testing.expect(mapping.original_column !=
            second.block.declarations.declarations[0].span.start);
    }
}

test "selector merge emission rejects semantically different declaration blocks" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, "forged-selector-merge.css", ".a{x:1}.b{x:2}");
    const file = try context.sources.get(parsed[0]);
    const generated = [_]ast.GeneratedRule{.{
        .kind = .selector_list_merge,
        .first_rule = 0,
        .source_span = file.fullSpan(),
    }};
    const forged = try ast.RuleList.initWithGeneratedRules(
        parsed[1].span,
        parsed[1].rules,
        parsed[1].omitted_rules,
        &generated,
    );
    try std.testing.expectError(
        error.InvalidAst,
        emit(std.testing.allocator, file, &forged, .{ .mode = .minified }),
    );
}

test "proof-carrying at-rule merge composes child mappings in source order" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "generated-at-rule-merge.css",
        "@media screen{.a{x:1}}/*gap*/@media screen{.b{y:2}}.keep{z:3}",
    );
    const file = try context.sources.get(parsed[0]);
    const generated = [_]ast.GeneratedRule{.{
        .kind = .group_at_rule_merge,
        .first_rule = 0,
        .source_span = .{
            .source = file.id,
            .start = parsed[1].rules[0].span().start,
            .end = parsed[1].rules[1].span().end,
        },
    }};
    const transformed = try ast.RuleList.initWithGeneratedRules(
        parsed[1].span,
        parsed[1].rules,
        parsed[1].omitted_rules,
        &generated,
    );

    const pretty_output = try emit(std.testing.allocator, file, &transformed, .{});
    defer std.testing.allocator.free(pretty_output);
    try std.testing.expectEqualStrings(
        "@media screen {\n  .a {\n    x: 1;\n  }\n  .b {\n    y: 2;\n  }\n}\n" ++
            ".keep {\n  z: 3;\n}\n",
        pretty_output,
    );

    var mapped = try emitWithSourceMap(
        std.testing.allocator,
        file,
        &transformed,
        .{ .mode = .minified },
        .{},
    );
    defer mapped.deinit();
    try std.testing.expectEqualStrings(
        "@media screen{.a{x:1}.b{y:2}}.keep{z:3}",
        mapped.css,
    );
    var json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mapped.source_map, .{});
    defer json.deinit();
    const mappings = try sourcemap.decodeMappings(
        std.testing.allocator,
        json.value.object.get("mappings").?.string,
    );
    defer std.testing.allocator.free(mappings);
    const second = parsed[1].rules[1].at_rule.block.rules.rules.rules[0].style_rule;
    const sibling = parsed[1].rules[2].style_rule;
    try std.testing.expect(hasMapping(mappings, .{
        .generated_line = 0,
        .generated_column = @intCast(std.mem.indexOf(u8, mapped.css, ".b").?),
        .original_line = 0,
        .original_column = @intCast(second.selectors.selectors[0].span.start),
    }));
    try std.testing.expect(hasMapping(mappings, .{
        .generated_line = 0,
        .generated_column = @intCast(std.mem.indexOf(u8, mapped.css, ".keep").?),
        .original_line = 0,
        .original_column = @intCast(sibling.selectors.selectors[0].span.start),
    }));
    for (mappings) |mapping| {
        try std.testing.expect(mapping.original_column != parsed[1].rules[1].span().start);
    }
}

test "at-rule merge emission rejects a different query proof" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "forged-at-rule-merge.css",
        "@media screen{.a{x:1}}@media print{.b{y:2}}",
    );
    const file = try context.sources.get(parsed[0]);
    const generated = [_]ast.GeneratedRule{.{
        .kind = .group_at_rule_merge,
        .first_rule = 0,
        .source_span = file.fullSpan(),
    }};
    const forged = try ast.RuleList.initWithGeneratedRules(
        parsed[1].span,
        parsed[1].rules,
        parsed[1].omitted_rules,
        &generated,
    );
    try std.testing.expectError(
        error.InvalidAst,
        emit(std.testing.allocator, file, &forged, .{ .mode = .minified }),
    );
}

test "keyframes and page structures receive ordered nested pretty formatting" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "structured-pretty.css",
        "@keyframes fade{from,50%{opacity:0}100%{opacity:1}}" ++
            "@page invoice:first,:left{margin:1cm;@top-left{content:\"Invoice\"}size:A4}",
    );
    const output = try emit(std.testing.allocator, try context.sources.get(parsed[0]), parsed[1], .{});
    defer std.testing.allocator.free(output);

    const expected =
        "@keyframes fade {\n" ++
        "  from, 50% {\n" ++
        "    opacity: 0;\n" ++
        "  }\n" ++
        "  100% {\n" ++
        "    opacity: 1;\n" ++
        "  }\n" ++
        "}\n" ++
        "@page invoice:first, :left {\n" ++
        "  margin: 1cm;\n" ++
        "  @top-left {\n" ++
        "    content: \"Invoice\";\n" ++
        "  }\n" ++
        "  size: A4;\n" ++
        "}\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "conditional layer and property at-rules share deterministic block formatting" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "at-rule-pretty.css",
        "@supports (display:grid) and selector(.x){.a{x:1}}" ++
            "@container card (width>1px){.b{x:2}}" ++
            "@layer base.components, theme;" ++
            "@layer utilities{.c{x:3}}" ++
            "@property --theme{syntax:\"<color>\";inherits:false;initial-value:red}",
    );
    const output = try emit(std.testing.allocator, try context.sources.get(parsed[0]), parsed[1], .{});
    defer std.testing.allocator.free(output);

    const expected =
        "@supports (display:grid) and selector(.x) {\n" ++
        "  .a {\n" ++
        "    x: 1;\n" ++
        "  }\n" ++
        "}\n" ++
        "@container card (width>1px) {\n" ++
        "  .b {\n" ++
        "    x: 2;\n" ++
        "  }\n" ++
        "}\n" ++
        "@layer base.components, theme;\n" ++
        "@layer utilities {\n" ++
        "  .c {\n" ++
        "    x: 3;\n" ++
        "  }\n" ++
        "}\n" ++
        "@property --theme {\n" ++
        "  syntax: \"<color>\";\n" ++
        "  inherits: false;\n" ++
        "  initial-value: red;\n" ++
        "}\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "identifier and string escaping follows CSSOM serialization rules" {
    const identifier_cases = [_]struct { []const u8, []const u8 }{
        .{ "simple", "simple" },
        .{ "0start", "\\30 start" },
        .{ "-1start", "-\\31 start" },
        .{ "-", "\\-" },
        .{ "a b", "a\\ b" },
        .{ "éclair", "éclair" },
        .{ "\x00x", "�x" },
        .{ "a\x1fb", "a\\1f b" },
    };
    for (identifier_cases) |case| {
        const serialized = try serializeIdentifierAlloc(std.testing.allocator, case[0]);
        defer std.testing.allocator.free(serialized);
        try std.testing.expectEqualStrings(case[1], serialized);
    }

    const string = try serializeStringAlloc(std.testing.allocator, "a\"b\\c\n\x00");
    defer std.testing.allocator.free(string);
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\a �\"", string);
}

test "every byte serializes into one valid identifier and terminated string token" {
    var raw: [1]u8 = undefined;
    var value: usize = 0;
    while (value <= std.math.maxInt(u8)) : (value += 1) {
        raw[0] = @intCast(value);
        const identifier = try serializeIdentifierAlloc(std.testing.allocator, &raw);
        defer std.testing.allocator.free(identifier);
        const string = try serializeStringAlloc(std.testing.allocator, &raw);
        defer std.testing.allocator.free(string);

        var context = try compilation.Compilation.init(std.testing.allocator);
        defer context.deinit();
        const identifier_id = try context.addSource("escaped-identifier.css", identifier);
        var identifier_tokenizer = tokenizer.Tokenizer.init(try context.sources.get(identifier_id));
        try std.testing.expectEqual(tokenizer.TokenKind.ident, identifier_tokenizer.next().kind);
        try std.testing.expectEqual(tokenizer.TokenKind.eof, identifier_tokenizer.next().kind);

        const string_id = try context.addSource("escaped-string.css", string);
        var string_tokenizer = tokenizer.Tokenizer.init(try context.sources.get(string_id));
        const string_token = string_tokenizer.next();
        try std.testing.expectEqual(tokenizer.TokenKind.string, string_token.kind);
        try std.testing.expect(string_token.isTerminated());
        try std.testing.expectEqual(tokenizer.TokenKind.eof, string_tokenizer.next().kind);
    }
}

test "raw component values retain comments required for token boundaries" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, "token-boundaries.css", ".x{--a:a/**/b;--b:1/**/%}");
    const output = try emit(std.testing.allocator, try context.sources.get(parsed[0]), parsed[1], .{});
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings(
        ".x {\n  --a: a/**/b;\n  --b: 1/**/%;\n}\n",
        output,
    );
    var reparsed_context = try compilation.Compilation.init(std.testing.allocator);
    defer reparsed_context.deinit();
    const reparsed = try parseSource(&reparsed_context, "token-boundaries-output.css", output);
    try std.testing.expectEqual(@as(usize, 2), reparsed[1].rules[0].style_rule.block.declarations.declarations.len);
    try std.testing.expectEqual(@as(usize, 0), reparsed_context.diagnostics.items().len);
}

test "forgiving pseudo arguments retain their raw invalid alternatives" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, "forgiving-output.css", ":is(.a, ., .b){x:1}");
    const output = try emit(std.testing.allocator, try context.sources.get(parsed[0]), parsed[1], .{});
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings(":is(.a, ., .b) {\n  x: 1;\n}\n", output);
    var reparsed_context = try compilation.Compilation.init(std.testing.allocator);
    defer reparsed_context.deinit();
    const reparsed = try parseSource(&reparsed_context, "forgiving-reparse.css", output);
    const typed = reparsed[1].rules[0].style_rule.selectors.selectors[0].head.simple_selectors[0].pseudo_class.arguments.?.parsed.?.selector_list;
    try std.testing.expectEqual(@as(usize, 2), typed.selectors.len);
    try std.testing.expectEqual(@as(usize, 0), reparsed_context.diagnostics.items().len);
}

test "statements empty blocks and formatting options remain deterministic" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "empty-pretty.css",
        "@import url(x);@layer base;.empty{}.filled{x:1}@media all{}@unknown x{}",
    );
    const output = try emit(
        std.testing.allocator,
        try context.sources.get(parsed[0]),
        parsed[1],
        .{ .indent_width = 4, .final_newline = false },
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "@import url(x);\n@layer base;\n.empty {}\n.filled {\n    x: 1;\n}\n@media all {}\n@unknown x{}",
        output,
    );

    var empty_context = try compilation.Compilation.init(std.testing.allocator);
    defer empty_context.deinit();
    const empty = try parseSource(&empty_context, "empty.css", "");
    const empty_output = try emit(
        std.testing.allocator,
        try empty_context.sources.get(empty[0]),
        empty[1],
        .{},
    );
    defer std.testing.allocator.free(empty_output);
    try std.testing.expectEqual(@as(usize, 0), empty_output.len);
}

test "verified rule omissions emit surviving syntax without treating deletion as recovery" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, "omissions.css", ".empty{} /*between*/ .keep{x:1}");
    const omission = [_]ast.Rule{parsed[1].rules[0]};
    const transformed = try ast.RuleList.initWithOmissions(
        parsed[1].span,
        parsed[1].rules[1..],
        &omission,
    );

    const pretty = try emit(
        std.testing.allocator,
        try context.sources.get(parsed[0]),
        &transformed,
        .{},
    );
    defer std.testing.allocator.free(pretty);
    const minified = try emit(
        std.testing.allocator,
        try context.sources.get(parsed[0]),
        &transformed,
        .{ .mode = .minified },
    );
    defer std.testing.allocator.free(minified);
    try std.testing.expectEqualStrings(".keep {\n  x: 1;\n}\n", pretty);
    try std.testing.expectEqualStrings(".keep{x:1}", minified);
}

test "rule omission proof cannot hide a nonempty rule" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, "forged-omission.css", ".keep{x:1}");
    const forged = ast.RuleList{
        .rules = &.{},
        .omitted_rules = parsed[1].rules,
        .span = parsed[1].span,
    };
    try std.testing.expectError(
        error.InvalidAst,
        emit(
            std.testing.allocator,
            try context.sources.get(parsed[0]),
            &forged,
            .{ .mode = .minified },
        ),
    );
}

test "minified emission removes only grammar-safe structural whitespace" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "minified.css",
        ".a .b, #\\31 id[data-x=\"a b\"] { color : red ; color : blue ! IMPORTANT ; --x : a/**/b ; width : calc( 1  +  2 ) }" ++
            " @media   screen and (width > 1px) { .c > .d { margin : 0  auto } }",
    );
    const output = try emit(
        std.testing.allocator,
        try context.sources.get(parsed[0]),
        parsed[1],
        .{ .mode = .minified },
    );
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings(
        ".a .b,#\\31 id[data-x=\"a b\"]{color:red;color:blue!important;--x:a/**/b;width:calc( 1 + 2 )}" ++
            "@media screen and (width > 1px){.c>.d{margin:0 auto}}",
        output,
    );
    const repeated = try emit(
        std.testing.allocator,
        try context.sources.get(parsed[0]),
        parsed[1],
        .{ .mode = .minified },
    );
    defer std.testing.allocator.free(repeated);
    const pretty_output = try emit(std.testing.allocator, try context.sources.get(parsed[0]), parsed[1], .{});
    defer std.testing.allocator.free(pretty_output);
    try std.testing.expectEqualStrings(output, repeated);
    try std.testing.expect(output.len < pretty_output.len);
}

test "minified raw values retain token and grammar separators" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "minified-separators.css",
        ".x{--ident:foo   bar;--number:1  2;--dimension:1px  solid;--operator:1  +  2;--comment:a/**/b;--nested:var( --x,  a   b )}",
    );
    const output = try emit(
        std.testing.allocator,
        try context.sources.get(parsed[0]),
        parsed[1],
        .{ .mode = .minified },
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        ".x{--ident:foo bar;--number:1 2;--dimension:1px solid;--operator:1 + 2;--comment:a/**/b;--nested:var( --x, a b )}",
        output,
    );

    var reparsed_context = try compilation.Compilation.init(std.testing.allocator);
    defer reparsed_context.deinit();
    const reparsed = try parseSource(&reparsed_context, "minified-separators-output.css", output);
    try std.testing.expectEqual(@as(usize, 6), reparsed[1].rules[0].style_rule.block.declarations.declarations.len);
    try std.testing.expectEqual(@as(usize, 0), reparsed_context.diagnostics.items().len);
}

test "minified structured and raw at-rules retain source order" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "minified-structures.css",
        "@keyframes fade{from,50%{opacity:0}100%{opacity:1}}" ++
            "@page invoice:first,:left{margin:1cm;@top-left{content:\"Invoice\"}size:A4}" ++
            "@font-face{font-family:'A';src:url(x)}" ++
            "@unknown foo{a( 1  ;  2 )}",
    );
    const output = try emit(
        std.testing.allocator,
        try context.sources.get(parsed[0]),
        parsed[1],
        .{ .mode = .minified },
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "@keyframes fade{from,50%{opacity:0}100%{opacity:1}}" ++
            "@page invoice:first,:left{margin:1cm;@top-left{content:\"Invoice\"}size:A4}" ++
            "@font-face{font-family:'A';src:url(x)}" ++
            "@unknown foo{a( 1 ; 2 )}",
        output,
    );

    var reparsed_context = try compilation.Compilation.init(std.testing.allocator);
    defer reparsed_context.deinit();
    const reparsed = try parseSource(&reparsed_context, "minified-structures-output.css", output);
    try std.testing.expectEqual(@as(usize, 4), reparsed[1].rules.len);
    try std.testing.expectEqual(@as(usize, 0), reparsed_context.diagnostics.items().len);
}

test "native nesting emits ordered declarations rules and group contents in both modes" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "emit-nesting.css",
        ".card{color:red;.title{font-weight:bold};;@media (width>40rem){display:grid;> .icon{opacity:1}gap:1rem}background:blue;&.active{color:green}}",
    );
    const file = try context.sources.get(parsed[0]);

    const pretty_output = try emit(std.testing.allocator, file, parsed[1], .{});
    defer std.testing.allocator.free(pretty_output);
    try std.testing.expectEqualStrings(
        ".card {\n" ++
            "  color: red;\n" ++
            "  .title {\n" ++
            "    font-weight: bold;\n" ++
            "  }\n" ++
            "  @media (width>40rem) {\n" ++
            "    display: grid;\n" ++
            "    > .icon {\n" ++
            "      opacity: 1;\n" ++
            "    }\n" ++
            "    gap: 1rem;\n" ++
            "  }\n" ++
            "  background: blue;\n" ++
            "  &.active {\n" ++
            "    color: green;\n" ++
            "  }\n" ++
            "}\n",
        pretty_output,
    );

    const minified_output = try emit(std.testing.allocator, file, parsed[1], .{ .mode = .minified });
    defer std.testing.allocator.free(minified_output);
    try std.testing.expectEqualStrings(
        ".card{color:red;.title{font-weight:bold}@media (width>40rem){display:grid;>.icon{opacity:1}gap:1rem}background:blue;&.active{color:green}}",
        minified_output,
    );

    var reparsed_context = try compilation.Compilation.init(std.testing.allocator);
    defer reparsed_context.deinit();
    const reparsed = try parseSource(&reparsed_context, "emitted-nesting.css", minified_output);
    try std.testing.expectEqual(@as(usize, 0), reparsed_context.diagnostics.items().len);
    try std.testing.expectEqual(@as(usize, 4), reparsed[1].rules[0].style_rule.block.rules.rules.len);

    var mapped = try emitWithSourceMap(
        std.testing.allocator,
        file,
        parsed[1],
        .{ .mode = .minified },
        .{},
    );
    defer mapped.deinit();
    var json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mapped.source_map, .{});
    defer json.deinit();
    const mappings = try sourcemap.decodeMappings(
        std.testing.allocator,
        json.value.object.get("mappings").?.string,
    );
    defer std.testing.allocator.free(mappings);
    const background = parsed[1].rules[0].style_rule.block.rules.rules[2].nested_declarations.declarations.declarations[0];
    try std.testing.expect(hasMapping(mappings, .{
        .generated_line = 0,
        .generated_column = @intCast(std.mem.indexOf(u8, mapped.css, "background").?),
        .original_line = 0,
        .original_column = @intCast(background.span.start),
    }));
}

test "minified unknown syntax preserves edge whitespace presence" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "unknown-whitespace.css",
        "@unknown(foo){  a(  b  )  }@unknown(bar);",
    );
    const output = try emit(
        std.testing.allocator,
        try context.sources.get(parsed[0]),
        parsed[1],
        .{ .mode = .minified },
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("@unknown(foo){ a( b ) }@unknown(bar);", output);
}

test "emission is bound to the AST source file" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, "first.css", ".a{x:1}");
    const other_id = try context.addSource("other.css", ".b{y:2}");

    try std.testing.expectError(
        error.SourceMismatch,
        emit(std.testing.allocator, try context.sources.get(other_id), parsed[1], .{}),
    );
}

test "mapped pretty and minified emission use CSS UTF-16 generated and original columns" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const input = ".🔥{color:red}@media all{.b{x:1}}";
    const parsed = try parseSource(&context, "unicode/input.css", input);
    const file = try context.sources.get(parsed[0]);

    var pretty_output = try emitWithSourceMap(
        std.testing.allocator,
        file,
        parsed[1],
        .{},
        .{ .generated_file = "output.css" },
    );
    defer pretty_output.deinit();
    const plain_pretty = try emit(std.testing.allocator, file, parsed[1], .{});
    defer std.testing.allocator.free(plain_pretty);
    try std.testing.expectEqualStrings(plain_pretty, pretty_output.css);
    try std.testing.expect(std.mem.indexOf(u8, pretty_output.css, "sourceMappingURL") == null);

    var json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, pretty_output.source_map, .{});
    defer json.deinit();
    try std.testing.expectEqual(@as(i64, 3), json.value.object.get("version").?.integer);
    try std.testing.expectEqualStrings("output.css", json.value.object.get("file").?.string);
    try std.testing.expectEqualStrings("unicode/input.css", json.value.object.get("sources").?.array.items[0].string);
    try std.testing.expectEqualStrings(input, json.value.object.get("sourcesContent").?.array.items[0].string);
    const pretty_mappings_text = json.value.object.get("mappings").?.string;
    const pretty_mappings = try sourcemap.decodeMappings(std.testing.allocator, pretty_mappings_text);
    defer std.testing.allocator.free(pretty_mappings);
    try std.testing.expect(hasMapping(pretty_mappings, .{
        .generated_line = 1,
        .generated_column = 2,
        .original_line = 0,
        .original_column = 4,
    }));
    try std.testing.expect(hasMapping(pretty_mappings, .{
        .generated_line = 3,
        .generated_column = 0,
        .original_line = 0,
        .original_column = 14,
    }));

    var minified_output = try emitWithSourceMap(
        std.testing.allocator,
        file,
        parsed[1],
        .{ .mode = .minified },
        .{},
    );
    defer minified_output.deinit();
    var minified_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, minified_output.source_map, .{});
    defer minified_json.deinit();
    const minified_mappings = try sourcemap.decodeMappings(
        std.testing.allocator,
        minified_json.value.object.get("mappings").?.string,
    );
    defer std.testing.allocator.free(minified_mappings);
    try std.testing.expect(hasMapping(minified_mappings, .{
        .generated_line = 0,
        .generated_column = 4,
        .original_line = 0,
        .original_column = 4,
    }));
    try std.testing.expect(hasMapping(minified_mappings, .{
        .generated_line = 0,
        .generated_column = 14,
        .original_line = 0,
        .original_column = 14,
    }));

    var repeated = try emitWithSourceMap(std.testing.allocator, file, parsed[1], .{}, .{ .generated_file = "output.css" });
    defer repeated.deinit();
    try std.testing.expectEqualStrings(pretty_output.css, repeated.css);
    try std.testing.expectEqualStrings(pretty_output.source_map, repeated.source_map);
}

fn hasMapping(mappings: []const sourcemap.Mapping, expected: sourcemap.Mapping) bool {
    for (mappings) |mapping| {
        if (std.meta.eql(mapping, expected)) return true;
    }
    return false;
}

test "empty mapped output owns valid metadata and supports idempotent cleanup" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(&context, "empty-mapped.css", "");
    var output = try emitWithSourceMap(
        std.testing.allocator,
        try context.sources.get(parsed[0]),
        parsed[1],
        .{ .mode = .minified },
        .{ .include_sources_content = false },
    );
    try std.testing.expectEqual(@as(usize, 0), output.css.len);
    var json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.source_map, .{});
    defer json.deinit();
    try std.testing.expectEqualStrings("", json.value.object.get("mappings").?.string);
    output.deinit();
    output.deinit();
}

test "emission refuses recovery gaps and missing closing syntax" {
    const cases = [_]struct { []const u8, Error }{
        .{ ".a{broken;color:red}", error.UnrepresentableRecovery },
        .{ ":not(.a,){x:1}.b{x:2}", error.UnrepresentableRecovery },
        .{ "@media{.a{x:1}}", error.UnrepresentableRecovery },
        .{ "@keyframes f{bad{x:1}50%{x:2}}", error.UnrepresentableRecovery },
        .{ ".a{color:red;&div{x:1}background:blue}", error.UnrepresentableRecovery },
        .{ ".a{color:red", error.UnterminatedSyntax },
    };
    for (cases) |case| {
        var context = try compilation.Compilation.init(std.testing.allocator);
        defer context.deinit();
        const parsed = try parseSource(&context, "recovered-emission.css", case[0]);
        const modes = [_]Mode{ .pretty, .minified };
        for (modes) |mode| {
            try std.testing.expectError(
                case[1],
                emit(std.testing.allocator, try context.sources.get(parsed[0]), parsed[1], .{ .mode = mode }),
            );
        }
    }
}

fn exerciseEmitterAllocationFailures(allocator: std.mem.Allocator) !void {
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "oom-emitter.css",
        ".a,.b > c{color:red;.nested{color:blue!important}@media all{display:grid;> .c{width:1px}}--x:fn(a/**/b)}@keyframes f{from{opacity:0}to{opacity:1}}",
    );
    const pretty_output = try emit(allocator, try context.sources.get(parsed[0]), parsed[1], .{});
    defer allocator.free(pretty_output);
    const minified_output = try emit(
        allocator,
        try context.sources.get(parsed[0]),
        parsed[1],
        .{ .mode = .minified },
    );
    defer allocator.free(minified_output);
    try std.testing.expect(pretty_output.len > 0);
    try std.testing.expect(minified_output.len < pretty_output.len);
}

fn exerciseMappedEmitterAllocationFailures(allocator: std.mem.Allocator) !void {
    var context = try compilation.Compilation.init(allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "oom-mapped-emitter.css",
        ".🔥,.b>.c{color:red;color:blue!important;--x:fn(a/**/b)}@media all{.d{x:1}}",
    );
    var output = try emitWithSourceMap(
        allocator,
        try context.sources.get(parsed[0]),
        parsed[1],
        .{ .mode = .minified },
        .{ .generated_file = "mapped.css" },
    );
    defer output.deinit();
    var json = try std.json.parseFromSlice(std.json.Value, allocator, output.source_map, .{});
    defer json.deinit();
    const decoded = try sourcemap.decodeMappings(allocator, json.value.object.get("mappings").?.string);
    defer allocator.free(decoded);
    try std.testing.expect(decoded.len > 0);
}

test "pretty emission handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseEmitterAllocationFailures,
        .{},
    );
}

test "mapped emission handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMappedEmitterAllocationFailures,
        .{},
    );
}

test "class mappings rewrite typed selector pseudos and reject incomplete views" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "mapped-classes.css",
        ".card:is(.icon,.card):where(){color:red}",
    );
    const file = try context.sources.get(parsed[0]);
    const mappings = [_]module_names.Entry{
        .{ .name = "card", .value = "_card" },
        .{ .name = "icon", .value = "_icon" },
    };
    const output = try emit(
        std.testing.allocator,
        file,
        parsed[1],
        .{ .mode = .minified, .class_names = &mappings },
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "._card:is(._icon,._card):where(){color:red}",
        output,
    );

    const incomplete = [_]module_names.Entry{
        .{ .name = "card", .value = "_card" },
    };
    try std.testing.expectError(
        error.InvalidMappings,
        emit(
            std.testing.allocator,
            file,
            parsed[1],
            .{ .mode = .minified, .class_names = &incomplete },
        ),
    );
    const unsorted = [_]module_names.Entry{
        .{ .name = "icon", .value = "_icon" },
        .{ .name = "card", .value = "_card" },
    };
    try std.testing.expectError(
        error.InvalidMappings,
        emit(
            std.testing.allocator,
            file,
            parsed[1],
            .{ .mode = .minified, .class_names = &unsorted },
        ),
    );
}

test "class mappings reject raw functional pseudo arguments" {
    var context = try compilation.Compilation.init(std.testing.allocator);
    defer context.deinit();
    const parsed = try parseSource(
        &context,
        "raw-pseudo.css",
        ".card:nth-child(2n of .item){color:red}",
    );
    const mappings = [_]module_names.Entry{
        .{ .name = "card", .value = "_card" },
        .{ .name = "item", .value = "_item" },
    };
    try std.testing.expectError(
        error.InvalidMappings,
        emit(
            std.testing.allocator,
            try context.sources.get(parsed[0]),
            parsed[1],
            .{ .mode = .minified, .class_names = &mappings },
        ),
    );
}
