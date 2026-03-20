const std = @import("std");
const ast = @import("../ast.zig");
const css_parser = @import("../parser.zig");

const Mixin = struct {
    name: []const u8,
    body: []const u8,
    params: std.ArrayList([]const u8),
    defaults: std.StringHashMap([]const u8),
    variable_args: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, body: []const u8) !Mixin {
        return Mixin{
            .name = name,
            .body = body,
            .params = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .defaults = std.StringHashMap([]const u8).init(allocator),
            .variable_args = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Mixin) void {
        for (self.params.items) |param| {
            self.allocator.free(param);
        }
        self.params.deinit(self.allocator);
        var it = self.defaults.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.defaults.deinit();
    }
};

const Function = struct {
    name: []const u8,
    body: []const u8,
    params: std.ArrayList([]const u8),
    defaults: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, body: []const u8) !Function {
        return Function{
            .name = name,
            .body = body,
            .params = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .defaults = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Function) void {
        for (self.params.items) |param| {
            self.allocator.free(param);
        }
        self.params.deinit(self.allocator);
        var it = self.defaults.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.defaults.deinit();
    }
};

pub const Parser = struct {
    input: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,
    variables: std.StringHashMap([]const u8),
    mixins: std.StringHashMap(*Mixin),
    functions: std.StringHashMap(*Function),
    placeholders: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        return .{
            .input = input,
            .pos = 0,
            .allocator = allocator,
            .variables = std.StringHashMap([]const u8).init(allocator),
            .mixins = std.StringHashMap(*Mixin).init(allocator),
            .functions = std.StringHashMap(*Function).init(allocator),
            .placeholders = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn parse(self: *Parser) !ast.Stylesheet {
        self.skipWhitespace();

        // First pass: scan entire file for $variables, @mixin, @function definitions
        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos >= self.input.len) break;

            if (self.peek() == '$') {
                try self.parseVariable();
            } else if (self.peek() == '@') {
                const saved_pos = self.pos;
                self.advance();
                if (self.matchKeyword("mixin")) {
                    try self.parseMixin();
                } else if (self.matchKeyword("function")) {
                    try self.parseFunction();
                } else {
                    self.pos = saved_pos;
                    // Skip past this @ directive
                    self.advance(); // skip @
                    // Skip to the end of the directive (either ';' or matched '{}' block)
                    while (self.pos < self.input.len and self.peek() != '{' and self.peek() != ';') {
                        self.advance();
                    }
                    if (self.pos < self.input.len and self.peek() == '{') {
                        self.advance();
                        var brace_d: usize = 1;
                        while (self.pos < self.input.len and brace_d > 0) {
                            if (self.peek() == '{') brace_d += 1
                            else if (self.peek() == '}') brace_d -= 1;
                            self.advance();
                        }
                    } else if (self.pos < self.input.len and self.peek() == ';') {
                        self.advance();
                    }
                }
            } else if (self.peek() == '/' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '/') {
                // Skip single-line comments
                while (self.pos < self.input.len and self.peek() != '\n') {
                    self.advance();
                }
            } else {
                // Skip non-definition content (rule blocks, etc.)
                if (self.peek() == '{') {
                    self.advance();
                    var brace_d: usize = 1;
                    while (self.pos < self.input.len and brace_d > 0) {
                        if (self.peek() == '{') brace_d += 1
                        else if (self.peek() == '}') brace_d -= 1;
                        self.advance();
                    }
                } else {
                    self.advance();
                }
            }
        }

        // Reset position for the actual parsing pass
        self.pos = 0;

        const input_without_directives = try self.removeDirectives();
        defer self.allocator.free(input_without_directives);

        // Expand control flow (@for, @each, @if, @while) before variable substitution
        const expanded_input = try self.expandControlFlow(input_without_directives);
        defer self.allocator.free(expanded_input);

        const processed_input = try self.processDirectives(expanded_input);
        defer self.allocator.free(processed_input);

        // Flatten nested SCSS rules (& parent references, nested selectors)
        const flattened = try self.flattenNesting(processed_input);
        defer self.allocator.free(flattened);

        // Process @extend and %placeholder selectors
        const extended = try self.processExtendAndPlaceholders(flattened);
        defer self.allocator.free(extended);

        var css_p = css_parser.Parser.init(self.allocator, extended);
        const stylesheet = try css_p.parse();
        return stylesheet;
    }

    /// Flatten nested SCSS rules into flat CSS.
    /// Handles & parent selector references and deeply nested blocks.
    fn flattenNesting(self: *Parser, input: []const u8) std.mem.Allocator.Error![]const u8 {
        var output = try std.ArrayList(u8).initCapacity(self.allocator, input.len);
        errdefer output.deinit(self.allocator);

        var i: usize = 0;
        while (i < input.len) {
            // Skip whitespace
            while (i < input.len and std.ascii.isWhitespace(input[i])) {
                try output.append(self.allocator, input[i]);
                i += 1;
            }
            if (i >= input.len) break;

            // Check for @-rule (e.g., @media, @keyframes, @supports, @layer)
            if (input[i] == '@') {
                const at_start = i;
                i += 1;
                // Read the at-rule name
                while (i < input.len and (std.ascii.isAlphabetic(input[i]) or input[i] == '-')) {
                    i += 1;
                }
                const at_name = input[at_start + 1 .. i];
                // Skip prelude
                while (i < input.len and input[i] != '{' and input[i] != ';') {
                    i += 1;
                }
                if (i < input.len and input[i] == '{') {
                    // Find the matching closing brace for the at-rule body
                    const body_start = i + 1;
                    i += 1;
                    var depth: usize = 1;
                    while (i < input.len and depth > 0) {
                        if (input[i] == '{') depth += 1
                        else if (input[i] == '}') depth -= 1;
                        if (depth > 0) i += 1;
                    }
                    const body_end = i;
                    if (i < input.len) i += 1;

                    // For @keyframes, don't flatten nested content
                    if (std.mem.eql(u8, at_name, "keyframes")) {
                        try output.appendSlice(self.allocator, input[at_start..i]);
                    } else {
                        // Recursively flatten the body, then wrap in the at-rule
                        const body = input[body_start..body_end];
                        const flattened_body = try self.flattenNesting(body);
                        defer self.allocator.free(flattened_body);
                        try output.appendSlice(self.allocator, input[at_start..body_start]);
                        try output.appendSlice(self.allocator, flattened_body);
                        try output.append(self.allocator, '}');
                    }
                } else {
                    // At-rule without block (e.g., @import)
                    if (i < input.len) i += 1;
                    try output.appendSlice(self.allocator, input[at_start..i]);
                }
                continue;
            }

            // Read selector
            const selector_start = i;
            while (i < input.len and input[i] != '{' and input[i] != '}') {
                i += 1;
            }
            if (i >= input.len or input[i] != '{') {
                // No opening brace found, copy remaining
                try output.appendSlice(self.allocator, input[selector_start..i]);
                break;
            }
            const selector = std.mem.trim(u8, input[selector_start..i], " \t\n\r");
            if (selector.len == 0) {
                i += 1;
                continue;
            }

            // Find the matching closing brace
            const block_start = i + 1;
            i += 1;
            var depth: usize = 1;
            while (i < input.len and depth > 0) {
                if (input[i] == '{') depth += 1
                else if (input[i] == '}') depth -= 1;
                if (depth > 0) i += 1;
            }
            const block_end = i;
            if (i < input.len) i += 1;

            const block_content = input[block_start..block_end];

            // Flatten this block: extract declarations and nested rules
            try self.flattenBlock(&output, selector, block_content);
        }

        return try output.toOwnedSlice(self.allocator);
    }

    /// Flatten a single block. `parent_selector` is the selector for this block.
    /// `block_content` is the content inside { }.
    fn flattenBlock(self: *Parser, output: *std.ArrayList(u8), parent_selector: []const u8, block_content: []const u8) std.mem.Allocator.Error!void {
        var declarations = try std.ArrayList(u8).initCapacity(self.allocator, block_content.len);
        defer declarations.deinit(self.allocator);
        var nested_rules = try std.ArrayList(u8).initCapacity(self.allocator, 256);
        defer nested_rules.deinit(self.allocator);

        var i: usize = 0;
        while (i < block_content.len) {
            // Skip whitespace
            while (i < block_content.len and std.ascii.isWhitespace(block_content[i])) {
                i += 1;
            }
            if (i >= block_content.len) break;

            // Check if this is a nested rule or a declaration
            // Heuristic: if we find a '{' before a ';' (or if it starts with '&', '.', '#', etc.), it's a nested rule
            if (self.isNestedRule(block_content, i)) {
                // Read nested selector
                const nested_sel_start = i;
                while (i < block_content.len and block_content[i] != '{') {
                    i += 1;
                }
                const nested_selector_raw = std.mem.trim(u8, block_content[nested_sel_start..i], " \t\n\r");

                if (i >= block_content.len) break;



                // Find matching close brace for nested block
                const nested_body_start = i + 1;
                i += 1;
                var depth: usize = 1;
                while (i < block_content.len and depth > 0) {
                    if (block_content[i] == '{') depth += 1
                    else if (block_content[i] == '}') depth -= 1;
                    if (depth > 0) i += 1;
                }
                const nested_body_end = i;
                if (i < block_content.len) i += 1;

                const nested_body = block_content[nested_body_start..nested_body_end];

                // Handle @-rules inside a rule (e.g., @media inside .container)
                if (nested_selector_raw.len > 0 and nested_selector_raw[0] == '@') {
                    // Flatten the nested @-rule body with the parent selector
                    const inner_flattened = try self.flattenNesting(nested_body);
                    defer self.allocator.free(inner_flattened);

                    // Re-wrap declarations in parent selector inside the at-rule
                    try nested_rules.appendSlice(self.allocator, nested_selector_raw);
                    try nested_rules.appendSlice(self.allocator, " {\n");

                    // Check if inner_flattened has content — wrap in parent selector
                    const trimmed_inner = std.mem.trim(u8, inner_flattened, " \t\n\r");
                    if (trimmed_inner.len > 0) {
                        // The inner content may already have selectors (from recursive flattening)
                        // or may be raw declarations. If it contains '{', it's already flattened.
                        if (std.mem.indexOf(u8, trimmed_inner, "{") != null) {
                            try nested_rules.appendSlice(self.allocator, trimmed_inner);
                        } else {
                            try nested_rules.appendSlice(self.allocator, parent_selector);
                            try nested_rules.appendSlice(self.allocator, " {\n");
                            try nested_rules.appendSlice(self.allocator, trimmed_inner);
                            try nested_rules.appendSlice(self.allocator, "\n}\n");
                        }
                    }
                    try nested_rules.appendSlice(self.allocator, "\n}\n");
                    continue;
                }

                // Resolve the nested selector with parent reference
                const resolved = try self.resolveNestedSelector(parent_selector, nested_selector_raw);
                defer self.allocator.free(resolved);

                // Recursively flatten the nested block
                try self.flattenBlock(&nested_rules, resolved, nested_body);
            } else {
                // It's a declaration: read until ';' or end of block
                const decl_start = i;
                while (i < block_content.len and block_content[i] != ';') {
                    if (block_content[i] == '{') break; // oops, it's actually nested
                    i += 1;
                }
                if (i < block_content.len and block_content[i] == ';') {
                    i += 1;
                }
                const decl = std.mem.trim(u8, block_content[decl_start..i], " \t\n\r");
                if (decl.len > 0) {
                    if (declarations.items.len > 0) {
                        try declarations.appendSlice(self.allocator, "\n");
                    }
                    try declarations.appendSlice(self.allocator, "  ");
                    try declarations.appendSlice(self.allocator, decl);
                    // Ensure it ends with ;
                    if (decl[decl.len - 1] != ';') {
                        try declarations.append(self.allocator, ';');
                    }
                }
            }
        }

        // Emit the parent rule with its declarations (if any)
        if (declarations.items.len > 0) {
            try output.appendSlice(self.allocator, parent_selector);
            try output.appendSlice(self.allocator, " {\n");
            try output.appendSlice(self.allocator, declarations.items);
            try output.appendSlice(self.allocator, "\n}\n");
        }

        // Emit nested rules after the parent rule
        if (nested_rules.items.len > 0) {
            try output.appendSlice(self.allocator, nested_rules.items);
        }
    }

    /// Determine if the content at position `start` within `block` is a nested rule (not a declaration).
    fn isNestedRule(self: *Parser, block: []const u8, start: usize) bool {
        _ = self;
        const ch = block[start];

        // & always starts a nested rule
        if (ch == '&') return true;

        // @ within a block could be nested at-rule, but @extend/@include are declarations
        if (ch == '@') {
            // @extend is not a nested rule, it's a directive that ends with ;
            const remaining = block[start..];
            if (std.mem.startsWith(u8, remaining, "@extend") or
                std.mem.startsWith(u8, remaining, "@include") or
                std.mem.startsWith(u8, remaining, "@warn") or
                std.mem.startsWith(u8, remaining, "@error") or
                std.mem.startsWith(u8, remaining, "@debug") or
                std.mem.startsWith(u8, remaining, "@return"))
            {
                return false;
            }
            return true;
        }

        // Look ahead: if we find '{' before ';', it's likely a nested rule
        var i = start;
        var paren_depth: usize = 0;
        while (i < block.len) {
            const c = block[i];
            if (c == '(') {
                paren_depth += 1;
            } else if (c == ')') {
                if (paren_depth > 0) paren_depth -= 1;
            } else if (paren_depth == 0) {
                if (c == '{') return true;
                if (c == ';') return false;
                if (c == '}') return false;
            }
            i += 1;
        }
        return false;
    }

    /// Resolve a nested selector with its parent.
    /// If the nested selector contains '&', replace it with the parent.
    /// Otherwise, combine them as descendant selector.
    fn resolveNestedSelector(self: *Parser, parent: []const u8, nested: []const u8) std.mem.Allocator.Error![]const u8 {
        // Handle comma-separated selectors in nested
        if (std.mem.indexOf(u8, nested, ",") != null) {
            var result = try std.ArrayList(u8).initCapacity(self.allocator, nested.len + parent.len * 2);
            errdefer result.deinit(self.allocator);

            var iter = std.mem.splitSequence(u8, nested, ",");
            var first = true;
            while (iter.next()) |part| {
                if (!first) {
                    try result.appendSlice(self.allocator, ", ");
                }
                first = false;
                const trimmed = std.mem.trim(u8, part, " \t\n\r");
                const resolved = try self.resolveNestedSelector(parent, trimmed);
                defer self.allocator.free(resolved);
                try result.appendSlice(self.allocator, resolved);
            }
            return try result.toOwnedSlice(self.allocator);
        }

        if (std.mem.indexOf(u8, nested, "&") != null) {
            // Replace all occurrences of & with the parent selector
            var result = try std.ArrayList(u8).initCapacity(self.allocator, nested.len + parent.len);
            errdefer result.deinit(self.allocator);

            var i: usize = 0;
            while (i < nested.len) {
                if (nested[i] == '&') {
                    try result.appendSlice(self.allocator, parent);
                    i += 1;
                } else {
                    try result.append(self.allocator, nested[i]);
                    i += 1;
                }
            }
            return try result.toOwnedSlice(self.allocator);
        } else {
            // No & — it's a descendant combinator
            return try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ parent, nested });
        }
    }

    /// Expand control flow directives (@for, @each, @if, @while) in the input text.
    fn expandControlFlow(self: *Parser, input: []const u8) std.mem.Allocator.Error![]const u8 {
        return self.expandControlFlowWithDepth(input, 0);
    }

    fn expandControlFlowWithDepth(self: *Parser, input: []const u8, depth: usize) std.mem.Allocator.Error![]const u8 {
        if (depth > 20) return try self.allocator.dupe(u8, input);

        var result = try std.ArrayList(u8).initCapacity(self.allocator, input.len);
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < input.len) {
            // Strip single-line comments
            if (input[i] == '/' and i + 1 < input.len and input[i + 1] == '/') {
                while (i < input.len and input[i] != '\n') {
                    i += 1;
                }
                if (i < input.len) i += 1;
                continue;
            }

            if (input[i] == '@' and i + 1 < input.len) {
                // Check for @for
                if (i + 4 <= input.len and std.mem.eql(u8, input[i .. i + 4], "@for")) {
                    const expanded = try self.expandForLoop(input, &i, depth);
                    defer self.allocator.free(expanded);
                    try result.appendSlice(self.allocator, expanded);
                    continue;
                }
                // Check for @each
                if (i + 5 <= input.len and std.mem.eql(u8, input[i .. i + 5], "@each")) {
                    const expanded = try self.expandEachLoop(input, &i, depth);
                    defer self.allocator.free(expanded);
                    try result.appendSlice(self.allocator, expanded);
                    continue;
                }
                // Check for @if
                if (i + 3 <= input.len and std.mem.eql(u8, input[i .. i + 3], "@if")) {
                    const expanded = try self.expandIfElse(input, &i, depth);
                    defer self.allocator.free(expanded);
                    try result.appendSlice(self.allocator, expanded);
                    continue;
                }
                // Check for @while
                if (i + 6 <= input.len and std.mem.eql(u8, input[i .. i + 6], "@while")) {
                    const expanded = try self.expandWhileLoop(input, &i, depth);
                    defer self.allocator.free(expanded);
                    try result.appendSlice(self.allocator, expanded);
                    continue;
                }
            }

            try result.append(self.allocator, input[i]);
            i += 1;
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Expand @for $var from X through Y { body }
    fn expandForLoop(self: *Parser, input: []const u8, pos: *usize, depth: usize) std.mem.Allocator.Error![]const u8 {
        var i = pos.* + 4; // skip @for
        skipWhitespaceInSlice(input, &i);

        // Parse $variable
        if (i >= input.len or input[i] != '$') {
            pos.* = i;
            return try self.allocator.dupe(u8, "");
        }
        i += 1;
        const var_start = i;
        while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '-' or input[i] == '_')) {
            i += 1;
        }
        const var_name = input[var_start..i];
        skipWhitespaceInSlice(input, &i);

        // Parse "from"
        if (i + 4 <= input.len and std.mem.eql(u8, input[i .. i + 4], "from")) {
            i += 4;
        }
        skipWhitespaceInSlice(input, &i);

        // Parse start value
        const start_val_begin = i;
        while (i < input.len and !std.ascii.isWhitespace(input[i])) {
            i += 1;
        }
        const start_str = std.mem.trim(u8, input[start_val_begin..i], " \t");
        const start_val = self.parseNumericValue(start_str);
        skipWhitespaceInSlice(input, &i);

        // Parse "through" or "to"
        var inclusive = true;
        if (i + 7 <= input.len and std.mem.eql(u8, input[i .. i + 7], "through")) {
            i += 7;
            inclusive = true;
        } else if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "to")) {
            i += 2;
            inclusive = false;
        }
        skipWhitespaceInSlice(input, &i);

        // Parse end value
        const end_val_begin = i;
        while (i < input.len and input[i] != '{' and !std.ascii.isWhitespace(input[i])) {
            i += 1;
        }
        const end_str = std.mem.trim(u8, input[end_val_begin..i], " \t");
        const end_val = self.parseNumericValue(end_str);
        skipWhitespaceInSlice(input, &i);

        // Extract body
        const body = self.extractBraceBlock(input, &i);

        // Expand loop iterations
        var expanded = try std.ArrayList(u8).initCapacity(self.allocator, body.len * @as(usize, @intCast(@max(1, end_val - start_val + 1))));
        errdefer expanded.deinit(self.allocator);

        const actual_end = if (inclusive) end_val else end_val - 1;
        var iter_val = start_val;
        while (iter_val <= actual_end) : (iter_val += 1) {
            const val_str = try std.fmt.allocPrint(self.allocator, "{}", .{iter_val});
            defer self.allocator.free(val_str);

            // Replace #{$var} and $var in the body
            const interp_pattern = try std.fmt.allocPrint(self.allocator, "#{{${s}}}", .{var_name});
            defer self.allocator.free(interp_pattern);
            const var_pattern = try std.fmt.allocPrint(self.allocator, "${s}", .{var_name});
            defer self.allocator.free(var_pattern);

            const pass1 = try replaceAllOccurrences(self.allocator, body, interp_pattern, val_str);
            defer self.allocator.free(pass1);
            const pass2 = try replaceAllOccurrences(self.allocator, pass1, var_pattern, val_str);
            defer self.allocator.free(pass2);

            // Recursively expand any nested control flow
            const recursed = try self.expandControlFlowWithDepth(pass2, depth + 1);
            defer self.allocator.free(recursed);

            try expanded.appendSlice(self.allocator, recursed);
            try expanded.append(self.allocator, '\n');
        }

        pos.* = i;
        return try expanded.toOwnedSlice(self.allocator);
    }

    /// Expand @each $var [, $val] in $list-or-values { body }
    fn expandEachLoop(self: *Parser, input: []const u8, pos: *usize, depth: usize) std.mem.Allocator.Error![]const u8 {
        var i = pos.* + 5; // skip @each
        skipWhitespaceInSlice(input, &i);

        // Parse variable names (could be $key, $value for maps)
        var var_names = try std.ArrayList([]const u8).initCapacity(self.allocator, 2);
        defer {
            for (var_names.items) |v| self.allocator.free(v);
            var_names.deinit(self.allocator);
        }

        while (i < input.len and input[i] == '$') {
            i += 1;
            const vn_start = i;
            while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '-' or input[i] == '_')) {
                i += 1;
            }
            const vn = try self.allocator.dupe(u8, input[vn_start..i]);
            try var_names.append(self.allocator, vn);
            skipWhitespaceInSlice(input, &i);
            if (i < input.len and input[i] == ',') {
                i += 1;
                skipWhitespaceInSlice(input, &i);
            }
        }

        // Parse "in"
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "in")) {
            i += 2;
        }
        skipWhitespaceInSlice(input, &i);

        // Parse the list/values (everything until '{')
        const list_start = i;
        while (i < input.len and input[i] != '{') {
            i += 1;
        }
        const list_str = std.mem.trim(u8, input[list_start..i], " \t\n\r");

        // Extract body
        const body = self.extractBraceBlock(input, &i);

        // Parse the list items — handle both parenthesized map-style and comma-separated lists
        var items = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
        defer {
            for (items.items) |item| self.allocator.free(item);
            items.deinit(self.allocator);
        }

        // Check if it's a $variable reference to a previously parsed map/list
        // For now, parse as comma-separated values
        try self.parseListItems(list_str, &items);

        // Expand loop
        var expanded = try std.ArrayList(u8).initCapacity(self.allocator, body.len * items.items.len);
        errdefer expanded.deinit(self.allocator);

        if (var_names.items.len >= 2) {
            // Map-style iteration: @each $key, $value in (key: val, ...)
            for (items.items) |item| {
                // Try to split on ':' for key-value pairs
                if (std.mem.indexOf(u8, item, ":")) |colon_pos| {
                    const key = std.mem.trim(u8, item[0..colon_pos], " \t'\"");
                    const val = std.mem.trim(u8, item[colon_pos + 1 ..], " \t'\"");

                    // Replace first variable (key)
                    const key_interp = try std.fmt.allocPrint(self.allocator, "#{{${s}}}", .{var_names.items[0]});
                    defer self.allocator.free(key_interp);
                    const key_var = try std.fmt.allocPrint(self.allocator, "${s}", .{var_names.items[0]});
                    defer self.allocator.free(key_var);

                    const r1 = try replaceAllOccurrences(self.allocator, body, key_interp, key);
                    defer self.allocator.free(r1);
                    const r2 = try replaceAllOccurrences(self.allocator, r1, key_var, key);
                    defer self.allocator.free(r2);

                    // Replace second variable (value)
                    const val_interp = try std.fmt.allocPrint(self.allocator, "#{{${s}}}", .{var_names.items[1]});
                    defer self.allocator.free(val_interp);
                    const val_var = try std.fmt.allocPrint(self.allocator, "${s}", .{var_names.items[1]});
                    defer self.allocator.free(val_var);

                    const r3 = try replaceAllOccurrences(self.allocator, r2, val_interp, val);
                    defer self.allocator.free(r3);
                    const r4 = try replaceAllOccurrences(self.allocator, r3, val_var, val);
                    defer self.allocator.free(r4);

                    const recursed = try self.expandControlFlowWithDepth(r4, depth + 1);
                    defer self.allocator.free(recursed);
                    try expanded.appendSlice(self.allocator, recursed);
                    try expanded.append(self.allocator, '\n');
                }
            }
        } else if (var_names.items.len == 1) {
            // Simple list iteration
            for (items.items) |item| {
                const clean_item = std.mem.trim(u8, item, " \t'\"");

                const interp_pattern = try std.fmt.allocPrint(self.allocator, "#{{${s}}}", .{var_names.items[0]});
                defer self.allocator.free(interp_pattern);
                const var_pattern = try std.fmt.allocPrint(self.allocator, "${s}", .{var_names.items[0]});
                defer self.allocator.free(var_pattern);

                const r1 = try replaceAllOccurrences(self.allocator, body, interp_pattern, clean_item);
                defer self.allocator.free(r1);
                const r2 = try replaceAllOccurrences(self.allocator, r1, var_pattern, clean_item);
                defer self.allocator.free(r2);

                const recursed = try self.expandControlFlowWithDepth(r2, depth + 1);
                defer self.allocator.free(recursed);
                try expanded.appendSlice(self.allocator, recursed);
                try expanded.append(self.allocator, '\n');
            }
        }

        pos.* = i;
        return try expanded.toOwnedSlice(self.allocator);
    }

    /// Expand @if condition { body } @else if condition { body } @else { body }
    fn expandIfElse(self: *Parser, input: []const u8, pos: *usize, depth: usize) std.mem.Allocator.Error![]const u8 {
        var i = pos.* + 3; // skip @if
        skipWhitespaceInSlice(input, &i);

        // Parse condition
        const cond_start = i;
        while (i < input.len and input[i] != '{') {
            i += 1;
        }
        const condition = std.mem.trim(u8, input[cond_start..i], " \t\n\r");

        // Extract body
        const body = self.extractBraceBlock(input, &i);

        if (self.evaluateCondition(condition)) {
            const recursed = try self.expandControlFlowWithDepth(body, depth + 1);
            // Skip any @else if / @else blocks
            self.skipElseBlocks(input, &i);
            pos.* = i;
            return recursed;
        }

        // Check for @else if / @else
        skipWhitespaceInSlice(input, &i);
        while (i + 5 <= input.len and std.mem.eql(u8, input[i .. i + 5], "@else")) {
            i += 5;
            skipWhitespaceInSlice(input, &i);

            if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "if")) {
                // @else if
                i += 2;
                skipWhitespaceInSlice(input, &i);

                const else_cond_start = i;
                while (i < input.len and input[i] != '{') {
                    i += 1;
                }
                const else_condition = std.mem.trim(u8, input[else_cond_start..i], " \t\n\r");
                const else_body = self.extractBraceBlock(input, &i);

                if (self.evaluateCondition(else_condition)) {
                    const recursed = try self.expandControlFlowWithDepth(else_body, depth + 1);
                    self.skipElseBlocks(input, &i);
                    pos.* = i;
                    return recursed;
                }
                skipWhitespaceInSlice(input, &i);
            } else {
                // @else (final)
                const else_body = self.extractBraceBlock(input, &i);
                const recursed = try self.expandControlFlowWithDepth(else_body, depth + 1);
                pos.* = i;
                return recursed;
            }
        }

        pos.* = i;
        return try self.allocator.dupe(u8, "");
    }

    /// Expand @while condition { body }
    fn expandWhileLoop(self: *Parser, input: []const u8, pos: *usize, depth: usize) std.mem.Allocator.Error![]const u8 {
        var i = pos.* + 6; // skip @while
        skipWhitespaceInSlice(input, &i);

        const cond_start = i;
        while (i < input.len and input[i] != '{') {
            i += 1;
        }
        const condition = std.mem.trim(u8, input[cond_start..i], " \t\n\r");
        const body = self.extractBraceBlock(input, &i);

        var expanded = try std.ArrayList(u8).initCapacity(self.allocator, body.len * 10);
        errdefer expanded.deinit(self.allocator);

        var iteration: usize = 0;
        const max_iterations: usize = 1000;
        while (self.evaluateCondition(condition) and iteration < max_iterations) : (iteration += 1) {
            const recursed = try self.expandControlFlowWithDepth(body, depth + 1);
            defer self.allocator.free(recursed);
            try expanded.appendSlice(self.allocator, recursed);
            try expanded.append(self.allocator, '\n');
        }

        pos.* = i;
        return try expanded.toOwnedSlice(self.allocator);
    }

    /// Skip @else if / @else blocks (used when a prior condition was true)
    fn skipElseBlocks(self: *Parser, input: []const u8, pos: *usize) void {
        _ = self;
        var i = pos.*;
        skipWhitespaceInSlice(input, &i);
        while (i + 5 <= input.len and std.mem.eql(u8, input[i .. i + 5], "@else")) {
            i += 5;
            skipWhitespaceInSlice(input, &i);
            // skip optional "if condition"
            if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "if")) {
                i += 2;
            }
            // skip to opening brace
            while (i < input.len and input[i] != '{') {
                i += 1;
            }
            // skip brace block
            if (i < input.len and input[i] == '{') {
                i += 1;
                var brace_d: usize = 1;
                while (i < input.len and brace_d > 0) {
                    if (input[i] == '{') brace_d += 1
                    else if (input[i] == '}') brace_d -= 1;
                    i += 1;
                }
            }
            skipWhitespaceInSlice(input, &i);
        }
        pos.* = i;
    }

    /// Extract the content inside a { } block. Advances pos past the closing }.
    fn extractBraceBlock(self: *Parser, input: []const u8, pos: *usize) []const u8 {
        _ = self;
        var i = pos.*;
        skipWhitespaceInSlice(input, &i);
        if (i >= input.len or input[i] != '{') {
            pos.* = i;
            return "";
        }
        i += 1;
        const body_start = i;
        var brace_d: usize = 1;
        while (i < input.len and brace_d > 0) {
            if (input[i] == '{') brace_d += 1
            else if (input[i] == '}') brace_d -= 1;
            if (brace_d > 0) i += 1;
        }
        const body_end = i;
        if (i < input.len) i += 1;
        pos.* = i;
        return input[body_start..body_end];
    }

    /// Evaluate a simple condition (for @if). Supports:
    /// - true/false literals
    /// - variable == value, variable != value
    /// - variable > value comparisons for numbers
    fn evaluateCondition(self: *Parser, condition: []const u8) bool {
        const trimmed = std.mem.trim(u8, condition, " \t\n\r");
        if (trimmed.len == 0) return false;

        // Try equality check: x == y
        if (std.mem.indexOf(u8, trimmed, "==")) |eq_pos| {
            const lhs = std.mem.trim(u8, trimmed[0..eq_pos], " \t'\"");
            const rhs = std.mem.trim(u8, trimmed[eq_pos + 2 ..], " \t'\"");
            const lhs_val = self.resolveValue(lhs);
            const rhs_val = self.resolveValue(rhs);
            return std.mem.eql(u8, lhs_val, rhs_val);
        }

        // Try inequality: x != y
        if (std.mem.indexOf(u8, trimmed, "!=")) |neq_pos| {
            const lhs = std.mem.trim(u8, trimmed[0..neq_pos], " \t'\"");
            const rhs = std.mem.trim(u8, trimmed[neq_pos + 2 ..], " \t'\"");
            const lhs_val = self.resolveValue(lhs);
            const rhs_val = self.resolveValue(rhs);
            return !std.mem.eql(u8, lhs_val, rhs_val);
        }

        // Try >= comparison
        if (std.mem.indexOf(u8, trimmed, ">=")) |pos| {
            const lhs = std.mem.trim(u8, trimmed[0..pos], " \t");
            const rhs = std.mem.trim(u8, trimmed[pos + 2 ..], " \t");
            const lhs_num = self.parseNumericValue(self.resolveValue(lhs));
            const rhs_num = self.parseNumericValue(self.resolveValue(rhs));
            return lhs_num >= rhs_num;
        }

        // Try <= comparison
        if (std.mem.indexOf(u8, trimmed, "<=")) |pos| {
            const lhs = std.mem.trim(u8, trimmed[0..pos], " \t");
            const rhs = std.mem.trim(u8, trimmed[pos + 2 ..], " \t");
            const lhs_num = self.parseNumericValue(self.resolveValue(lhs));
            const rhs_num = self.parseNumericValue(self.resolveValue(rhs));
            return lhs_num <= rhs_num;
        }

        // Try > comparison (must check after >= )
        if (std.mem.indexOf(u8, trimmed, ">")) |pos| {
            const lhs = std.mem.trim(u8, trimmed[0..pos], " \t");
            const rhs = std.mem.trim(u8, trimmed[pos + 1 ..], " \t");
            const lhs_num = self.parseNumericValue(self.resolveValue(lhs));
            const rhs_num = self.parseNumericValue(self.resolveValue(rhs));
            return lhs_num > rhs_num;
        }

        // Try < comparison (must check after <= )
        if (std.mem.indexOf(u8, trimmed, "<")) |pos| {
            const lhs = std.mem.trim(u8, trimmed[0..pos], " \t");
            const rhs = std.mem.trim(u8, trimmed[pos + 1 ..], " \t");
            const lhs_num = self.parseNumericValue(self.resolveValue(lhs));
            const rhs_num = self.parseNumericValue(self.resolveValue(rhs));
            return lhs_num < rhs_num;
        }

        // Check for "and" / "or" / "not"
        if (std.mem.indexOf(u8, trimmed, " and ")) |and_pos| {
            const lhs = self.evaluateCondition(trimmed[0..and_pos]);
            const rhs = self.evaluateCondition(trimmed[and_pos + 5 ..]);
            return lhs and rhs;
        }
        if (std.mem.indexOf(u8, trimmed, " or ")) |or_pos| {
            const lhs = self.evaluateCondition(trimmed[0..or_pos]);
            const rhs = self.evaluateCondition(trimmed[or_pos + 4 ..]);
            return lhs or rhs;
        }
        if (std.mem.startsWith(u8, trimmed, "not ")) {
            return !self.evaluateCondition(trimmed[4..]);
        }

        // Simple variable truthiness
        const resolved = self.resolveValue(trimmed);
        if (std.mem.eql(u8, resolved, "true")) return true;
        if (std.mem.eql(u8, resolved, "false")) return false;
        if (std.mem.eql(u8, resolved, "null")) return false;
        if (resolved.len == 0) return false;
        return true; // non-empty value is truthy
    }

    /// Resolve a value: if it starts with $, look up the variable
    fn resolveValue(self: *Parser, val: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, val, " \t'\"");
        if (trimmed.len > 0 and trimmed[0] == '$') {
            if (self.variables.get(trimmed[1..])) |v| {
                return v;
            }
        }
        return trimmed;
    }

    /// Parse a numeric value from a string (strip units like px, rem, etc.)
    fn parseNumericValue(self: *Parser, val: []const u8) i64 {
        _ = self;
        const trimmed = std.mem.trim(u8, val, " \t");
        // Find end of numeric part
        var end: usize = 0;
        if (end < trimmed.len and (trimmed[end] == '-' or trimmed[end] == '+')) {
            end += 1;
        }
        while (end < trimmed.len and (std.ascii.isDigit(trimmed[end]) or trimmed[end] == '.')) {
            end += 1;
        }
        if (end == 0) return 0;
        const num_str = trimmed[0..end];
        // Try integer parse first
        return std.fmt.parseInt(i64, num_str, 10) catch 0;
    }

    /// Parse comma-separated list items, handling parenthesized groups
    fn parseListItems(self: *Parser, list_str: []const u8, items: *std.ArrayList([]const u8)) std.mem.Allocator.Error!void {
        // Check if the whole thing is a map reference ($variable)
        const trimmed = std.mem.trim(u8, list_str, " \t\n\r");

        // Check if it starts with '(' — map/list literal
        if (trimmed.len > 0 and trimmed[0] == '(') {
            // Strip outer parens
            const inner = if (trimmed[trimmed.len - 1] == ')')
                trimmed[1 .. trimmed.len - 1]
            else
                trimmed[1..];
            return self.parseListItems(inner, items);
        }

        // Split by comma, respecting parentheses
        var i: usize = 0;
        var item_start: usize = 0;
        var paren_depth: usize = 0;
        while (i < trimmed.len) {
            if (trimmed[i] == '(') {
                paren_depth += 1;
            } else if (trimmed[i] == ')') {
                if (paren_depth > 0) paren_depth -= 1;
            } else if (trimmed[i] == ',' and paren_depth == 0) {
                const item = std.mem.trim(u8, trimmed[item_start..i], " \t\n\r");
                if (item.len > 0) {
                    const dup = try self.allocator.dupe(u8, item);
                    try items.append(self.allocator, dup);
                }
                i += 1;
                item_start = i;
                continue;
            }
            i += 1;
        }
        // Last item
        const last = std.mem.trim(u8, trimmed[item_start..], " \t\n\r");
        if (last.len > 0) {
            const dup = try self.allocator.dupe(u8, last);
            try items.append(self.allocator, dup);
        }
    }

    fn matchKeyword(self: *Parser, keyword: []const u8) bool {
        const saved_pos = self.pos;
        var i: usize = 0;
        while (i < keyword.len and self.pos < self.input.len) {
            if (std.ascii.toLower(self.peek()) != keyword[i]) {
                self.pos = saved_pos;
                return false;
            }
            self.advance();
            i += 1;
        }
        if (i == keyword.len and (self.pos >= self.input.len or !std.ascii.isAlphanumeric(self.peek()))) {
            return true;
        }
        self.pos = saved_pos;
        return false;
    }

    fn parseMixin(self: *Parser) !void {
        
        self.skipWhitespace();

        const name_start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.peek();
            if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                self.advance();
            } else {
                break;
            }
        }

        if (self.pos == name_start) {
            return error.InvalidMixinName;
        }

        const name = self.input[name_start..self.pos];
        
        self.skipWhitespace();

        var params = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        errdefer {
            for (params.items) |param| {
                self.allocator.free(param);
            }
            params.deinit(self.allocator);
        }
        var defaults = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var it = defaults.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            defaults.deinit();
        }
        var variable_args: ?[]const u8 = null;

        if (self.peek() == '(') {
            
            self.advance();
            self.skipWhitespace();

            var param_loop_count: usize = 0;
            var param_loop_last_pos: usize = self.pos;
            const max_param_iterations = self.input.len * 2;
            while (self.pos < self.input.len and self.peek() != ')') {
                param_loop_count += 1;
                
                if (param_loop_count > max_param_iterations) {
                    
                    return error.OutOfMemory;
                }
                if (self.pos == param_loop_last_pos and param_loop_count > 5) {
                    
                    return error.OutOfMemory;
                }
                param_loop_last_pos = self.pos;
                const param_start = self.pos;
                while (self.pos < self.input.len) {
                    const ch = self.peek();
                    if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                        self.advance();
                    } else {
                        break;
                    }
                }

                if (self.pos > param_start) {
                    const param_name = try self.allocator.dupe(u8, self.input[param_start..self.pos]);
                    try params.append(self.allocator, param_name);
                }

                self.skipWhitespace();
                
                if (self.pos + 2 < self.input.len and self.input[self.pos] == '.' and self.input[self.pos + 1] == '.' and self.input[self.pos + 2] == '.') {
                    if (params.items.len > 0) {
                        variable_args = params.items[params.items.len - 1];
                    }
                    self.pos += 3;
                    self.skipWhitespace();
                    if (self.peek() == ')') {
                        break;
                    }
                    continue;
                }
                
                if (self.peek() == ':') {
                    self.advance();
                    self.skipWhitespace();
                    const default_start = self.pos;
                    var default_loop_count: usize = 0;
                    const max_default_iterations = self.input.len * 2;
                    while (self.pos < self.input.len and self.peek() != ',' and self.peek() != ')') {
                        default_loop_count += 1;
                        if (default_loop_count > max_default_iterations) {
                            
                            return error.OutOfMemory;
                        }
                        self.advance();
                    }
                    const default_value = std.mem.trim(u8, self.input[default_start..self.pos], " \t");
                    if (default_value.len > 0 and params.items.len > 0) {
                        const last_param = params.items[params.items.len - 1];
                        const param_copy = try self.allocator.dupe(u8, last_param);
                        const default_copy = try self.allocator.dupe(u8, default_value);
                        try defaults.put(param_copy, default_copy);
                    }
                    self.skipWhitespace();
                }

                if (self.peek() == ',') {
                    self.advance();
                    self.skipWhitespace();
                } else if (self.peek() != ')') {
                    // If we're not at ',' or ')', we need to advance to avoid infinite loop
                    self.advance();
                }
            }

            if (self.peek() == ')') {
                self.advance();
            }
            
        }

        self.skipWhitespace();
        
        if (self.peek() != '{') {
            return error.ExpectedBrace;
        }
        self.advance();

        const body_start = self.pos;
        
        var brace_count: usize = 1;
        var loop_iter: usize = 0;
        var last_pos: usize = self.pos;
        const max_body_iterations = self.input.len * 5;
        while (self.pos < self.input.len and brace_count > 0) {
            loop_iter += 1;
            
            if (loop_iter > max_body_iterations) {
                
                return error.OutOfMemory;
            }
            if (self.pos == last_pos and loop_iter > 10) {
                
                return error.OutOfMemory;
            }
            last_pos = self.pos;
            const ch = self.peek();
            
            if (ch == '{') {
                brace_count += 1;
                self.advance();
            } else if (ch == '}') {
                brace_count -= 1;
                
                if (brace_count == 0) {
                    break;
                }
                self.advance();
            } else {
                self.advance();
            }
        }

        const body = self.input[body_start..self.pos];
        if (self.peek() == '}') {
            self.advance();
        }
        

        const name_copy = try self.allocator.dupe(u8, name);
        const body_copy = try self.allocator.dupe(u8, body);
        var mixin = try self.allocator.create(Mixin);
        mixin.* = try Mixin.init(self.allocator, name_copy, body_copy);
        mixin.params = params;
        mixin.defaults = defaults;
        mixin.variable_args = variable_args;
        try self.mixins.put(name_copy, mixin);
    }

    fn parseFunction(self: *Parser) !void {
        
        self.skipWhitespace();

        const name_start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.peek();
            if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                self.advance();
            } else {
                break;
            }
        }

        if (self.pos == name_start) {
            return error.InvalidFunctionName;
        }

        const name = self.input[name_start..self.pos];
        self.skipWhitespace();

        var params = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        errdefer {
            for (params.items) |param| {
                self.allocator.free(param);
            }
            params.deinit(self.allocator);
        }
        var defaults = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var it = defaults.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            defaults.deinit();
        }

        if (self.peek() == '(') {
            self.advance();
            self.skipWhitespace();
            

            var param_loop_iter: usize = 0;
            const max_param_iterations = self.input.len * 5;
            while (self.pos < self.input.len and self.peek() != ')') {
                param_loop_iter += 1;
                
                if (param_loop_iter > max_param_iterations) {
                    
                    return error.OutOfMemory;
                }
                const param_start = self.pos;
                while (self.pos < self.input.len) {
                    const ch = self.peek();
                    if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                        self.advance();
                    } else {
                        break;
                    }
                }

                if (self.pos > param_start) {
                    const param_name = try self.allocator.dupe(u8, self.input[param_start..self.pos]);
                    try params.append(self.allocator, param_name);
                }

                self.skipWhitespace();
                if (self.peek() == ':') {
                    self.advance();
                    self.skipWhitespace();
                    const default_start = self.pos;
                    while (self.pos < self.input.len and self.peek() != ',' and self.peek() != ')') {
                        self.advance();
                    }
                    const default_value = std.mem.trim(u8, self.input[default_start..self.pos], " \t");
                    if (default_value.len > 0 and params.items.len > 0) {
                        const last_param = params.items[params.items.len - 1];
                        const param_copy = try self.allocator.dupe(u8, last_param);
                        const default_copy = try self.allocator.dupe(u8, default_value);
                        try defaults.put(param_copy, default_copy);
                    }
                    self.skipWhitespace();
                }

                if (self.peek() == ',') {
                    self.advance();
                    self.skipWhitespace();
                } else if (self.peek() != ')') {
                    // Unexpected character - advance to avoid infinite loop
                    self.advance();
                }
            }

            if (self.peek() == ')') {
                self.advance();
            }
        }

        self.skipWhitespace();
        if (self.peek() != '{') {
            return error.ExpectedBrace;
        }
        self.advance();

        const body_start = self.pos;
        
        var brace_count: usize = 1;
        var func_loop_iter: usize = 0;
        const max_func_iterations = self.input.len * 5;
        while (self.pos < self.input.len and brace_count > 0) {
            func_loop_iter += 1;
            
            if (func_loop_iter > max_func_iterations) {
                
                return error.OutOfMemory;
            }
            const ch = self.peek();
            if (ch == '{') {
                brace_count += 1;
            } else if (ch == '}') {
                brace_count -= 1;
                
                if (brace_count == 0) {
                    break;
                }
            }
            if (brace_count > 0) {
                self.advance();
            }
        }

        const body = self.input[body_start..self.pos];
        if (self.peek() == '}') {
            self.advance();
        }

        const name_copy = try self.allocator.dupe(u8, name);
        const body_copy = try self.allocator.dupe(u8, body);
        var func = try self.allocator.create(Function);
        func.* = try Function.init(self.allocator, name_copy, body_copy);
        func.params = params;
        func.defaults = defaults;
        try self.functions.put(name_copy, func);
    }

    fn removeDirectives(self: *Parser) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, self.input.len);
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < self.input.len) {
            // Strip single-line comments (// ... \n)
            if (self.input[i] == '/' and i + 1 < self.input.len and self.input[i + 1] == '/') {
                while (i < self.input.len and self.input[i] != '\n') {
                    i += 1;
                }
                if (i < self.input.len) {
                    i += 1; // skip the newline
                }
                continue;
            }
            if (self.input[i] == '$' and i + 1 < self.input.len) {
                const var_start = i;
                i += 1;

                while (i < self.input.len and (std.ascii.isAlphanumeric(self.input[i]) or self.input[i] == '-' or self.input[i] == '_')) {
                    i += 1;
                }

                if (i < self.input.len and self.input[i] == ':') {
                    i += 1;
                    self.skipWhitespaceAt(&i);

                    while (i < self.input.len) {
                        if (self.input[i] == ';' or self.input[i] == '\n') {
                            i += 1;
                            break;
                        }
                        i += 1;
                    }
                    continue;
                } else {
                    i = var_start;
                }
            } else if (self.input[i] == '@' and i + 1 < self.input.len) {
                const at_start = i;
                i += 1;
                const keyword_start = i;

                while (i < self.input.len and std.ascii.isAlphabetic(self.input[i])) {
                    i += 1;
                }

                const keyword = self.input[keyword_start..i];
                if (std.mem.eql(u8, keyword, "mixin") or std.mem.eql(u8, keyword, "function")) {
                    self.skipWhitespaceAt(&i);
                    while (i < self.input.len and self.input[i] != '{') {
                        i += 1;
                    }
                    if (i < self.input.len) {
                        i += 1;
                        var brace_count: usize = 1;
                        while (i < self.input.len and brace_count > 0) {
                            if (self.input[i] == '{') {
                                brace_count += 1;
                            } else if (self.input[i] == '}') {
                                brace_count -= 1;
                            }
                            i += 1;
                        }
                    }
                    continue;
                } else if (std.mem.eql(u8, keyword, "warn") or std.mem.eql(u8, keyword, "error") or
                    std.mem.eql(u8, keyword, "debug") or std.mem.eql(u8, keyword, "use") or
                    std.mem.eql(u8, keyword, "forward") or std.mem.eql(u8, keyword, "import"))
                {
                    // Strip these directives — skip to the next ';' or newline
                    while (i < self.input.len and self.input[i] != ';' and self.input[i] != '\n') {
                        i += 1;
                    }
                    if (i < self.input.len and self.input[i] == ';') {
                        i += 1;
                    }
                    continue;
                } else {
                    i = at_start;
                }
            }

            try result.append(self.allocator, self.input[i]);
            i += 1;
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn skipWhitespaceAt(self: *Parser, pos: *usize) void {
        while (pos.* < self.input.len and std.ascii.isWhitespace(self.input[pos.*])) {
            pos.* += 1;
        }
    }

    fn skipWhitespaceInSlice(input: []const u8, pos: *usize) void {
        while (pos.* < input.len and std.ascii.isWhitespace(input[pos.*])) {
            pos.* += 1;
        }
    }

    fn processDirectives(self: *Parser, input: []const u8) std.mem.Allocator.Error![]const u8 {
        return self.processDirectivesWithDepth(input, 0);
    }

    fn processDirectivesWithDepth(self: *Parser, input: []const u8, depth: usize) std.mem.Allocator.Error![]const u8 {
        if (depth > 10) {
            return error.OutOfMemory;
        }
        
        var result = try std.ArrayList(u8).initCapacity(self.allocator, input.len);
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        var loop_count: usize = 0;
        var last_i: usize = 0;
        var stuck_count: usize = 0;
        const max_iterations = input.len * 10;
        while (i < input.len) {
            loop_count += 1;
            if (loop_count > max_iterations) {
                
                return error.OutOfMemory;
            }
            if (i == last_i) {
                stuck_count += 1;
                if (stuck_count > 100) {
                    
                    return error.OutOfMemory;
                }
            } else {
                stuck_count = 0;
                last_i = i;
            }
            
            // Strip single-line comments in preprocessed input
            if (input[i] == '/' and i + 1 < input.len and input[i + 1] == '/') {
                while (i < input.len and input[i] != '\n') {
                    i += 1;
                }
                if (i < input.len) {
                    i += 1;
                }
                continue;
            }

            // Handle #{expr} interpolation
            if (input[i] == '#' and i + 1 < input.len and input[i + 1] == '{') {
                i += 2; // skip #{
                const expr_start = i;
                var brace_depth: usize = 1;
                while (i < input.len and brace_depth > 0) {
                    if (input[i] == '{') {
                        brace_depth += 1;
                    } else if (input[i] == '}') {
                        brace_depth -= 1;
                    }
                    if (brace_depth > 0) {
                        i += 1;
                    }
                }
                const expr = std.mem.trim(u8, input[expr_start..i], " \t");
                if (i < input.len) {
                    i += 1; // skip closing }
                }
                // Evaluate expression: try variable lookup first, then pass through
                const evaluated = try self.processDirectivesWithDepth(expr, depth + 1);
                defer self.allocator.free(evaluated);
                try result.appendSlice(self.allocator, evaluated);
                continue;
            }

            if (input[i] == '$' and i + 1 < input.len) {
                const var_start = i + 1;
                var var_end = var_start;

                while (var_end < input.len) {
                    const ch = input[var_end];
                    if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                        var_end += 1;
                    } else {
                        break;
                    }
                }

                if (var_end > var_start) {
                    const var_name = input[var_start..var_end];
                    if (self.variables.get(var_name)) |value| {
                        try result.appendSlice(self.allocator, value);
                        i = var_end;
                        continue;
                    }
                }
            } else if (input[i] == '@' and i + 7 <= input.len) {
                
                const saved_i = i;
                i += 1;
                
                if (i + 7 <= input.len and std.mem.eql(u8, input[i..i+7], "include")) {
                    
                    i += 7;
                    skipWhitespaceInSlice(input, &i);
                    const mixin_start = i;
                    
                    while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '-' or input[i] == '_')) {
                        i += 1;
                    }
                    const mixin_name = input[mixin_start..i];
                    
                    skipWhitespaceInSlice(input, &i);

                    var args = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
                    defer {
                        for (args.items) |arg| {
                            self.allocator.free(arg);
                        }
                        args.deinit(self.allocator);
                    }

                    if (i < input.len and input[i] == '(') {
                        
                        i += 1;
                        skipWhitespaceInSlice(input, &i);
                        var arg_start = i;
                        var paren_count: usize = 0;
                        var arg_loop_count: usize = 0;
                        const max_arg_iterations = input.len * 2;
                        while (i < input.len) {
                            arg_loop_count += 1;
                            
                            if (arg_loop_count > max_arg_iterations) {
                                
                                return error.OutOfMemory;
                            }
                            if (input[i] == '(') {
                                paren_count += 1;
                            } else if (input[i] == ')') {
                                if (paren_count == 0) {
                                    
                                    break;
                                }
                                paren_count -= 1;
                            } else if (input[i] == ',' and paren_count == 0) {
                                const arg = std.mem.trim(u8, input[arg_start..i], " \t");
                                if (arg.len > 0) {
                                    const arg_copy = try self.allocator.dupe(u8, arg);
                                    try args.append(self.allocator, arg_copy);
                                }
                                i += 1;
                                skipWhitespaceInSlice(input, &i);
                                arg_start = i;
                                continue;
                            }
                            i += 1;
                        }
                        const arg = std.mem.trim(u8, input[arg_start..i], " \t");
                        if (arg.len > 0) {
                            const arg_copy = try self.allocator.dupe(u8, arg);
                            try args.append(self.allocator, arg_copy);
                        }
                        if (i < input.len and input[i] == ')') {
                            i += 1;
                        }
                        
                    }
                    
                    while (i < input.len and (std.ascii.isWhitespace(input[i]) or input[i] == ';')) {
                        i += 1;
                    }
                    
                    var content_block: ?[]const u8 = null;
                    if (i < input.len and input[i] == '{') {
                        const content_start = i + 1;
                        i += 1;
                        var brace_count: usize = 1;
                        while (i < input.len and brace_count > 0) {
                            if (input[i] == '{') {
                                brace_count += 1;
                            } else if (input[i] == '}') {
                                brace_count -= 1;
                            }
                            if (brace_count > 0) {
                                i += 1;
                            }
                        }
                        if (brace_count == 0) {
                            content_block = input[content_start..i];
                            i += 1;
                        }
                    }

                    if (self.mixins.get(mixin_name)) |mixin| {
                        
                        var mixin_body: []u8 = try self.allocator.dupe(u8, mixin.body);
                        defer self.allocator.free(mixin_body);

                        var j: usize = 0;
                        var variable_args_start: usize = mixin.params.items.len;
                        const var_arg_name = mixin.variable_args;
                        if (var_arg_name) |_| {
                            variable_args_start = mixin.params.items.len - 1;
                        }
                        
                        while (j < variable_args_start and j < args.items.len) {
                            const param_name = mixin.params.items[j];
                            const arg_value = args.items[j];
                            const param_pattern = try std.fmt.allocPrint(self.allocator, "${s}", .{param_name});
                            defer self.allocator.free(param_pattern);
                            const new_body = try self.replaceInString(mixin_body, param_pattern, arg_value);
                            self.allocator.free(mixin_body);
                            mixin_body = new_body;
                            j += 1;
                        }

                        if (var_arg_name) |var_name| {
                            if (args.items.len > variable_args_start) {
                                var var_args_list = try std.ArrayList(u8).initCapacity(self.allocator, 100);
                                defer var_args_list.deinit(self.allocator);
                                
                                for (args.items[variable_args_start..], 0..) |arg, idx| {
                                    if (idx > 0) {
                                        try var_args_list.append(self.allocator, ',');
                                        try var_args_list.append(self.allocator, ' ');
                                    }
                                    try var_args_list.appendSlice(self.allocator, arg);
                                }
                                
                                const var_args_str = try var_args_list.toOwnedSlice(self.allocator);
                                defer self.allocator.free(var_args_str);
                                
                                const param_pattern = try std.fmt.allocPrint(self.allocator, "${s}", .{var_name});
                                defer self.allocator.free(param_pattern);
                                const new_body = try self.replaceInString(mixin_body, param_pattern, var_args_str);
                                self.allocator.free(mixin_body);
                                mixin_body = new_body;
                            } else {
                                const param_pattern = try std.fmt.allocPrint(self.allocator, "${s}", .{var_name});
                                defer self.allocator.free(param_pattern);
                                const new_body = try self.replaceInString(mixin_body, param_pattern, "");
                                self.allocator.free(mixin_body);
                                mixin_body = new_body;
                            }
                        }

                        if (args.items.len < variable_args_start) {
                            for (mixin.params.items[args.items.len..variable_args_start]) |param_name| {
                                if (mixin.defaults.get(param_name)) |default_value| {
                                    const param_pattern = try std.fmt.allocPrint(self.allocator, "${s}", .{param_name});
                                    defer self.allocator.free(param_pattern);
                                    const new_body = try self.replaceInString(mixin_body, param_pattern, default_value);
                                    self.allocator.free(mixin_body);
                                    mixin_body = new_body;
                                }
                            }
                        }

                        if (content_block) |content| {
                            const content_pattern = "@content";
                            if (std.mem.indexOf(u8, mixin_body, content_pattern)) |content_pos| {
                                const before_content = mixin_body[0..content_pos];
                                var after_content = mixin_body[content_pos + content_pattern.len..];
                                
                                while (after_content.len > 0 and (std.ascii.isWhitespace(after_content[0]) or after_content[0] == ';')) {
                                    after_content = after_content[1..];
                                }
                                
                                const trimmed_content = std.mem.trim(u8, content, " \t\n\r");
                                if (trimmed_content.len > 0) {
                                    const processed_content = try self.processDirectivesWithDepth(trimmed_content, depth + 1);
                                    defer self.allocator.free(processed_content);
                                    
                                    const new_body = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ before_content, processed_content, after_content });
                                    self.allocator.free(mixin_body);
                                    mixin_body = new_body;
                                } else {
                                    const new_body = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ before_content, after_content });
                                    self.allocator.free(mixin_body);
                                    mixin_body = new_body;
                                }
                            }
                        }
                        
                        const expanded_body = try self.processDirectivesWithDepth(mixin_body, depth + 1);
                        defer self.allocator.free(expanded_body);
                        
                        try result.appendSlice(self.allocator, expanded_body);
                        
                        if (i <= saved_i) {
                            const data_str6 = std.fmt.allocPrint(self.allocator, "{{\"i\":{},\"saved_i\":{},\"ERROR\":\"i_not_advancing\"}}", .{ i, saved_i }) catch "";
                            defer self.allocator.free(data_str6);                            return error.OutOfMemory;
                        }
                        
                        continue;
                    } else {
                        
                        i = saved_i;
                    }
                } else {
                    i = saved_i;
                }
            } else if ((std.ascii.isAlphabetic(input[i]) or input[i] == '-') and (i == 0 or !std.ascii.isAlphanumeric(input[i - 1]) and input[i - 1] != '_' and input[i - 1] != '-')) {
                
                const func_start = i;
                var func_end = i;
                while (func_end < input.len and (std.ascii.isAlphanumeric(input[func_end]) or input[func_end] == '-' or input[func_end] == '_')) {
                    func_end += 1;
                }

                if (func_end < input.len and input[func_end] == '(') {
                    const func_name = input[func_start..func_end];
                    if (self.functions.get(func_name)) |func| {
                        func_end += 1;
                        skipWhitespaceInSlice(input, &func_end);
                        const arg_start = func_end;
                        var paren_count: usize = 1;
                        while (func_end < input.len and paren_count > 0) {
                            if (input[func_end] == '(') {
                                paren_count += 1;
                            } else if (input[func_end] == ')') {
                                paren_count -= 1;
                            }
                            if (paren_count > 0) {
                                func_end += 1;
                            }
                        }
                        const args_str = std.mem.trim(u8, input[arg_start..func_end], " \t");
                        const result_value = try self.evaluateFunctionWithDepth(func, args_str, depth);
                        defer self.allocator.free(result_value);
                        try result.appendSlice(self.allocator, result_value);
                        i = func_end + 1;
                        continue;
                    }
                }
            }

            
            try result.append(self.allocator, input[i]);
            i += 1;
            if (i > input.len) break;
        }
        

        return try result.toOwnedSlice(self.allocator);
    }

    fn replaceInString(self: *Parser, input: []const u8, pattern: []const u8, replacement: []const u8) ![]u8 {
        
        var result = try std.ArrayList(u8).initCapacity(self.allocator, input.len);
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < input.len) {
            if (i + pattern.len <= input.len and std.mem.eql(u8, input[i..i+pattern.len], pattern)) {
                const before = i;
                const after = i + pattern.len;
                if ((before == 0 or !std.ascii.isAlphanumeric(input[before - 1])) and
                    (after >= input.len or !std.ascii.isAlphanumeric(input[after]))) {
                    try result.appendSlice(self.allocator, replacement);
                    i = after;
                    continue;
                }
            }
            try result.append(self.allocator, input[i]);
            i += 1;
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn evaluateFunction(self: *Parser, func: *Function, args_str: []const u8) std.mem.Allocator.Error![]const u8 {
        return self.evaluateFunctionWithDepth(func, args_str, 0);
    }

    fn evaluateFunctionWithDepth(self: *Parser, func: *Function, args_str: []const u8, depth: usize) std.mem.Allocator.Error![]const u8 {
                    var args = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
                    defer {
                        for (args.items) |arg| {
                            self.allocator.free(arg);
                        }
                        args.deinit(self.allocator);
                    }

        var i: usize = 0;
        var arg_start: usize = 0;
        var paren_count: usize = 0;
        while (i < args_str.len) {
            if (args_str[i] == '(') {
                paren_count += 1;
            } else if (args_str[i] == ')') {
                paren_count -= 1;
            } else if (args_str[i] == ',' and paren_count == 0) {
                const arg = std.mem.trim(u8, args_str[arg_start..i], " \t");
                if (arg.len > 0) {
                    const arg_copy = try self.allocator.dupe(u8, arg);
                    try args.append(self.allocator, arg_copy);
                }
                i += 1;
                self.skipWhitespaceAt(&i);
                arg_start = i;
                continue;
            }
            i += 1;
        }
        const arg = std.mem.trim(u8, args_str[arg_start..], " \t");
        if (arg.len > 0) {
            const arg_copy = try self.allocator.dupe(u8, arg);
            try args.append(self.allocator, arg_copy);
        }

        var func_body: []u8 = try self.allocator.dupe(u8, func.body);
        defer self.allocator.free(func_body);

        var j: usize = 0;
        while (j < func.params.items.len and j < args.items.len) {
            const param_name = func.params.items[j];
            const arg_value = args.items[j];
            const param_pattern = try std.fmt.allocPrint(self.allocator, "${s}", .{param_name});
            defer self.allocator.free(param_pattern);
            const new_body = try self.replaceInString(func_body, param_pattern, arg_value);
            self.allocator.free(func_body);
            func_body = new_body;
            j += 1;
        }

        for (func.params.items[args.items.len..]) |param_name| {
            if (func.defaults.get(param_name)) |default_value| {
                const param_pattern = try std.fmt.allocPrint(self.allocator, "${s}", .{param_name});
                defer self.allocator.free(param_pattern);
                const new_body = try self.replaceInString(func_body, param_pattern, default_value);
                self.allocator.free(func_body);
                func_body = new_body;
            }
        }

        var return_start: ?usize = null;
        i = 0;
        while (i < func_body.len) {
            if (i + 6 < func_body.len and std.mem.eql(u8, func_body[i..i+6], "@return")) {
                i += 6;
                self.skipWhitespaceAt(&i);
                return_start = i;
                break;
            }
            i += 1;
        }

        if (return_start) |start| {
            var end = start;
            while (end < func_body.len and func_body[end] != ';' and func_body[end] != '}') {
                end += 1;
            }
            const return_value = std.mem.trim(u8, func_body[start..end], " \t");
            const processed_value = try self.processDirectivesWithDepth(return_value, depth);
            defer self.allocator.free(processed_value);
            return try self.allocator.dupe(u8, processed_value);
        }

        return try self.allocator.dupe(u8, "");
    }

    fn parseVariable(self: *Parser) !void {
        if (self.peek() != '$') {
            return error.ExpectedDollarSign;
        }
        self.advance();

        const name_start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.peek();
            if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                self.advance();
            } else {
                break;
            }
        }

        if (self.pos == name_start) {
            return error.InvalidVariableName;
        }

        const name = self.input[name_start..self.pos];
        self.skipWhitespace();

        if (self.peek() != ':') {
            return error.ExpectedColon;
        }
        self.advance();
        self.skipWhitespace();

        const value_start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.peek();
            if (ch == ';' or ch == '\n') {
                break;
            }
            self.advance();
        }

        var value = self.input[value_start..self.pos];
        value = std.mem.trim(u8, value, " \t");

        // Handle !default flag: only set variable if not already defined
        var is_default = false;
        if (value.len >= 8 and std.mem.endsWith(u8, value, "!default")) {
            is_default = true;
            value = std.mem.trimRight(u8, value[0 .. value.len - 8], " \t");
        }

        if (is_default and self.variables.contains(name)) {
            // Variable already defined, skip
        } else {
            const value_copy = try self.allocator.dupe(u8, value);
            const name_copy = try self.allocator.dupe(u8, name);

            // Free old value if overwriting
            if (self.variables.fetchRemove(name_copy)) |old| {
                self.allocator.free(old.key);
                self.allocator.free(old.value);
            }

            try self.variables.put(name_copy, value_copy);
        }

        if (self.peek() == ';') {
            self.advance();
        }
    }

    fn parseAtRule(self: *Parser) !ast.AtRule {
        if (self.peek() != '@') {
            return error.ExpectedAtSign;
        }
        self.advance();

        const name_start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.peek();
            if (std.ascii.isAlphabetic(ch)) {
                self.advance();
            } else {
                break;
            }
        }

        const name = try self.allocator.dupe(u8, self.input[name_start..self.pos]);
        self.skipWhitespace();

        const prelude_start = self.pos;
        var prelude_end = self.pos;

        while (self.pos < self.input.len) {
            const ch = self.peek();
            if (ch == '{' or ch == ';') {
                prelude_end = self.pos;
                break;
            }
            self.advance();
            prelude_end = self.pos;
        }

        var prelude_raw = self.input[prelude_start..prelude_end];
        prelude_raw = std.mem.trim(u8, prelude_raw, " \t\n\r");
        const prelude = try self.allocator.dupe(u8, prelude_raw);

        var at_rule = ast.AtRule.init(self.allocator);
        at_rule.name = name;
        at_rule.prelude = prelude;

        if (self.peek() == '{') {
            self.advance();
            self.skipWhitespace();

            var rules = try std.ArrayList(ast.Rule).initCapacity(self.allocator, 0);
            errdefer rules.deinit(self.allocator);

            const nested_start = self.pos;
            var brace_count: usize = 1;
            while (self.pos < self.input.len and brace_count > 0) {
                const ch = self.peek();
                if (ch == '{') {
                    brace_count += 1;
                } else if (ch == '}') {
                    brace_count -= 1;
                }
                if (brace_count > 0) {
                    self.advance();
                }
            }
            
            const nested_input = self.input[nested_start..self.pos];
            var css_p = css_parser.Parser.init(self.allocator, nested_input);
            var nested_stylesheet = try css_p.parse();
            defer nested_stylesheet.deinit();
            
            for (nested_stylesheet.rules.items) |rule| {
                try rules.append(self.allocator, rule);
            }

            if (self.peek() == '}') {
                self.advance();
            }

            at_rule.rules = rules;
        } else if (self.peek() == ';') {
            self.advance();
        }

        return at_rule;
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (std.ascii.isWhitespace(ch)) {
                self.advance();
            } else if (ch == '/' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '*') {
                self.skipBlockComment();
            } else if (ch == '/' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '/') {
                self.skipLineComment();
            } else {
                break;
            }
        }
    }

    fn skipBlockComment(self: *Parser) void {
        self.pos += 2;
        while (self.pos < self.input.len - 1) {
            if (self.input[self.pos] == '*' and self.input[self.pos + 1] == '/') {
                self.pos += 2;
                return;
            }
            self.advance();
        }
    }

    fn skipLineComment(self: *Parser) void {
        self.pos += 2; // skip //
        while (self.pos < self.input.len and self.input[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.pos < self.input.len) {
            self.pos += 1; // skip the newline
        }
    }

    fn peek(self: *const Parser) u8 {
        if (self.pos >= self.input.len) {
            return 0;
        }
        return self.input[self.pos];
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.input.len) {
            self.pos += 1;
        }
    }

    pub fn deinit(self: *Parser) void {
        var it = self.variables.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.variables.deinit();

        var mixin_it = self.mixins.iterator();
        while (mixin_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.free(entry.value_ptr.*.body);
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.mixins.deinit();

        var func_it = self.functions.iterator();
        while (func_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.free(entry.value_ptr.*.body);
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.functions.deinit();

        var ph_it = self.placeholders.iterator();
        while (ph_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.placeholders.deinit();
    }

    /// Process @extend directives and %placeholder selectors.
    /// 1. Extract %placeholder rules and store their bodies
    /// 2. Replace @extend %name with the placeholder's declarations  
    /// 3. Strip %placeholder rules from output (they don't emit CSS directly)
    fn processExtendAndPlaceholders(self: *Parser, input: []const u8) std.mem.Allocator.Error![]const u8 {
        // First pass: extract %placeholder rules and store their bodies
        var first_pass = try std.ArrayList(u8).initCapacity(self.allocator, input.len);
        defer first_pass.deinit(self.allocator);

        var i: usize = 0;
        while (i < input.len) {
            // Skip whitespace
            while (i < input.len and std.ascii.isWhitespace(input[i])) {
                try first_pass.append(self.allocator, input[i]);
                i += 1;
            }
            if (i >= input.len) break;

            // Check for %placeholder selector
            if (input[i] == '%') {
                const sel_start = i;
                i += 1;
                while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '-' or input[i] == '_')) {
                    i += 1;
                }
                const placeholder_name = input[sel_start + 1 .. i];

                // Skip to opening brace
                while (i < input.len and std.ascii.isWhitespace(input[i])) {
                    i += 1;
                }

                if (i < input.len and input[i] == '{') {
                    i += 1;
                    const body_start = i;
                    var depth: usize = 1;
                    while (i < input.len and depth > 0) {
                        if (input[i] == '{') depth += 1
                        else if (input[i] == '}') depth -= 1;
                        if (depth > 0) i += 1;
                    }
                    const body_end = i;
                    if (i < input.len) i += 1;

                    // Store the placeholder body
                    const name_copy = try self.allocator.dupe(u8, placeholder_name);
                    const body_copy = try self.allocator.dupe(u8, std.mem.trim(u8, input[body_start..body_end], " \t\n\r"));
                    try self.placeholders.put(name_copy, body_copy);
                    // Don't emit the placeholder rule
                    continue;
                } else {
                    // Not a valid placeholder, emit as-is
                    try first_pass.appendSlice(self.allocator, input[sel_start..i]);
                }
                continue;
            }

            try first_pass.append(self.allocator, input[i]);
            i += 1;
        }

        // Second pass: replace @extend %name with placeholder body
        var result = try std.ArrayList(u8).initCapacity(self.allocator, first_pass.items.len);
        errdefer result.deinit(self.allocator);

        i = 0;
        while (i < first_pass.items.len) {
            // Look for @extend
            if (first_pass.items[i] == '@' and i + 7 <= first_pass.items.len and
                std.mem.eql(u8, first_pass.items[i .. i + 7], "@extend"))
            {
                i += 7;
                // Skip whitespace after @extend
                while (i < first_pass.items.len and std.ascii.isWhitespace(first_pass.items[i])) {
                    i += 1;
                }

                // Read the selector to extend
                const ext_start = i;
                while (i < first_pass.items.len and first_pass.items[i] != ';' and first_pass.items[i] != '}' and first_pass.items[i] != '\n') {
                    i += 1;
                }
                const ext_selector = std.mem.trim(u8, first_pass.items[ext_start..i], " \t\n\r");
                if (i < first_pass.items.len and first_pass.items[i] == ';') {
                    i += 1;
                }

                // Check if it's a %placeholder
                if (ext_selector.len > 0 and ext_selector[0] == '%') {
                    const ph_name = ext_selector[1..];
                    if (self.placeholders.get(ph_name)) |ph_body| {
                        // Insert the placeholder's declarations
                        try result.appendSlice(self.allocator, ph_body);
                        try result.append(self.allocator, '\n');
                    }
                }
                // For regular selectors, @extend is more complex (selector extension)
                // For now, we skip non-placeholder extends
                continue;
            }

            try result.append(self.allocator, first_pass.items[i]);
            i += 1;
        }

        return try result.toOwnedSlice(self.allocator);
    }
};

/// Replace all occurrences of `needle` with `replacement` in `haystack`.
fn replaceAllOccurrences(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) std.mem.Allocator.Error![]const u8 {
    if (needle.len == 0) return try allocator.dupe(u8, haystack);

    var result = try std.ArrayList(u8).initCapacity(allocator, haystack.len);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < haystack.len) {
        if (i + needle.len <= haystack.len and std.mem.eql(u8, haystack[i .. i + needle.len], needle)) {
            try result.appendSlice(allocator, replacement);
            i += needle.len;
        } else {
            try result.append(allocator, haystack[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

test "parse SCSS variables" {
    const scss = "$primary-color: red;\n.container { color: $primary-color; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(rule.style.declarations.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, rule.style.declarations.items[0].value, "red"));
}

test "parse SCSS with multiple variables" {
    const scss = "$color1: red; $color2: blue; .test { color: $color1; background: $color2; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(rule.style.declarations.items.len == 2);
    try std.testing.expect(std.mem.eql(u8, rule.style.declarations.items[0].value, "red"));
    try std.testing.expect(std.mem.eql(u8, rule.style.declarations.items[1].value, "blue"));
}

test "parse SCSS mixin" {
    const scss = "@mixin button($color: blue) { background-color: $color; padding: 10px; } .btn { @include button(red); }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(std.mem.containsAtLeast(u8, rule.style.declarations.items[0].value, 1, "red"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rule.style.declarations.items[1].value, 1, "10px"));
}

test "parse SCSS mixin with default value" {
    const scss = "@mixin button($color: blue) { background-color: $color; } .btn { @include button(); }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(std.mem.containsAtLeast(u8, rule.style.declarations.items[0].value, 1, "blue"));
}

test "parse SCSS function" {
    const scss = "@function calculate-width($base, $multiplier) { @return $base * $multiplier; } .container { width: calculate-width(100px, 2); }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
}

test "parse SCSS function with default value" {
    const scss = "@function multiply($base, $multiplier: 2) { @return $base * $multiplier; } .container { width: multiply(50px); }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
}

test "parse SCSS mixin with @content" {
    const scss = "@mixin button { padding: 10px; @content; } .btn { @include button { color: red; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(rule.style.declarations.items.len >= 2);
    
    var found_padding = false;
    var found_color = false;
    for (rule.style.declarations.items) |decl| {
        if (std.mem.eql(u8, decl.property, "padding")) {
            found_padding = true;
        }
        if (std.mem.eql(u8, decl.property, "color")) {
            found_color = true;
        }
    }
    try std.testing.expect(found_padding);
    try std.testing.expect(found_color);
}

test "parse SCSS mixin with @content and parameters" {
    const scss = "@mixin button($color) { padding: 10px; background: $color; @content; } .btn { @include button(blue) { color: red; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(rule.style.declarations.items.len >= 3);
}

test "parse SCSS mixin with variable arguments" {
    const scss = "@mixin box-shadow($shadows...) { box-shadow: $shadows; } .card { @include box-shadow(0 1px 3px rgba(0,0,0,0.12), 0 1px 2px rgba(0,0,0,0.24)); }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(rule.style.declarations.items.len >= 1);
    
    var found_box_shadow = false;
    for (rule.style.declarations.items) |decl| {
        if (std.mem.eql(u8, decl.property, "box-shadow")) {
            found_box_shadow = true;
            try std.testing.expect(std.mem.containsAtLeast(u8, decl.value, 1, "rgba"));
        }
    }
    try std.testing.expect(found_box_shadow);
}

// ===== New SCSS Feature Tests =====

test "SCSS single-line comments are stripped" {
    const scss = "$color: red;\n// This is a comment\n.container { color: $color; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(std.mem.eql(u8, rule.style.declarations.items[0].value, "red"));
}

test "SCSS interpolation in values" {
    const scss = "$size: 16px;\n.text { font-size: #{$size}; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(std.mem.eql(u8, rule.style.declarations.items[0].value, "16px"));
}

test "SCSS !default flag" {
    const scss = "$color: blue;\n$color: red !default;\n.box { color: $color; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    // Should be 'blue' since it was defined first, and !default doesn't override
    try std.testing.expect(std.mem.eql(u8, rule.style.declarations.items[0].value, "blue"));
}

test "SCSS nesting with & parent selector" {
    const scss = ".nav { color: black; &__item { display: block; } &:hover { color: red; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    // Should produce: .nav { color: black; } .nav__item { display: block; } .nav:hover { color: red; }
    try std.testing.expect(stylesheet.rules.items.len >= 2);
}

test "SCSS nesting without &" {
    const scss = ".parent { .child { color: red; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    // Should produce: .parent .child { color: red; }
    try std.testing.expect(stylesheet.rules.items.len >= 1);
}

test "SCSS @for loop" {
    const scss = "@for $i from 1 through 3 { .col-#{$i} { width: $i; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    // Should produce 3 rules: .col-1, .col-2, .col-3
    try std.testing.expect(stylesheet.rules.items.len == 3);
}

test "SCSS @each loop" {
    const scss = "@each $color in red, green, blue { .text-#{$color} { color: $color; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    // Should produce 3 rules: .text-red, .text-green, .text-blue
    try std.testing.expect(stylesheet.rules.items.len == 3);
}

test "SCSS @if true condition" {
    const scss = "$theme: dark;\n@if $theme == dark { .bg { color: white; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    // Condition is true, should produce the rule
    try std.testing.expect(stylesheet.rules.items.len == 1);
}

test "SCSS @if false with @else" {
    const scss = "$theme: light;\n@if $theme == dark { .bg { color: white; } } @else { .bg { color: black; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    // Condition is false, should produce the @else rule
    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(std.mem.eql(u8, rule.style.declarations.items[0].value, "black"));
}

test "SCSS %placeholder and @extend" {
    const scss = "%reset { margin: 0; padding: 0; } .container { @extend %reset; color: red; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    // Should have one rule (.container) with placeholder declarations merged in
    try std.testing.expect(stylesheet.rules.items.len >= 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(rule.style.declarations.items.len >= 2);
}

test "SCSS @warn and @debug are stripped" {
    const scss = "$color: red;\n@warn \"This is a warning\";\n@debug \"Debug info\";\n.container { color: $color; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(std.mem.eql(u8, rule.style.declarations.items[0].value, "red"));
}

test "SCSS @import is stripped" {
    const scss = "@import 'variables';\n.container { color: blue; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, scss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
}
