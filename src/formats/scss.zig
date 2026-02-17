const std = @import("std");
const ast = @import("../ast.zig");
const css_parser = @import("../parser.zig");
const error_module = @import("../error.zig");

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

    const NumericValue = struct {
        value: f64,
        unit: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        return .{
            .input = input,
            .pos = 0,
            .allocator = allocator,
            .variables = std.StringHashMap([]const u8).init(allocator),
            .mixins = std.StringHashMap(*Mixin).init(allocator),
            .functions = std.StringHashMap(*Function).init(allocator),
        };
    }

    pub fn parse(self: *Parser) !ast.Stylesheet {
        self.skipWhitespace();

        while (self.pos < self.input.len) {
            if (self.peek() == '$') {
                try self.parseVariable();
                self.skipWhitespace();
            } else if (self.peek() == '@') {
                const saved_pos = self.pos;
                self.advance();
                if (self.matchKeyword("mixin")) {
                    try self.parseMixin();
                    self.skipWhitespace();
                } else if (self.matchKeyword("function")) {
                    try self.parseFunction();
                    self.skipWhitespace();
                } else {
                    self.pos = saved_pos;
                    break;
                }
            } else {
                break;
            }
        }

        const input_without_directives = try self.removeDirectives();
        defer self.allocator.free(input_without_directives);
        const processed_input = try self.processDirectives(input_without_directives);
        defer self.allocator.free(processed_input);
        
        const flattened_input = try self.flattenNestedSelectors(processed_input, null);
        defer self.allocator.free(flattened_input);
        
        
        var css_p = css_parser.Parser.init(self.allocator, flattened_input);
        defer if (css_p.owns_pool) {
            css_p.string_pool.deinit();
            self.allocator.destroy(css_p.string_pool);
        };
        
        const result = css_p.parseWithErrorInfo();
        switch (result) {
            .success => |s| return s,
            .parse_error => |parse_error| {
                const error_msg = error_module.formatErrorWithContext(self.allocator, processed_input, "processed_scss", parse_error) catch |err| {
                    std.debug.print("Parse error at line {d}, column {d}: {s}\n", .{ parse_error.line, parse_error.column, parse_error.message });
                    return err;
                };
                defer self.allocator.free(error_msg);
                std.debug.print("{s}\n", .{error_msg});
                return error.ParseError;
            },
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
            if (i + 1 < self.input.len and self.input[i] == '/' and self.input[i + 1] == '/') {
                while (i < self.input.len and self.input[i] != '\n') {
                    i += 1;
                }
                if (i < self.input.len) {
                    i += 1;
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
            } else if (self.input[i] == '%' and i + 1 < self.input.len) {
                const placeholder_start = i;
                i += 1;
                while (i < self.input.len and (std.ascii.isAlphanumeric(self.input[i]) or self.input[i] == '-' or self.input[i] == '_')) {
                    i += 1;
                }
                self.skipWhitespaceAt(&i);
                if (i < self.input.len and self.input[i] == '{') {
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
                    continue;
                } else {
                    i = placeholder_start;
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
                } else if (std.mem.eql(u8, keyword, "extend") or 
                           std.mem.eql(u8, keyword, "for") or 
                           std.mem.eql(u8, keyword, "if") or 
                           std.mem.eql(u8, keyword, "else") or 
                           std.mem.eql(u8, keyword, "while") or 
                           std.mem.eql(u8, keyword, "each")) {
                    self.skipWhitespaceAt(&i);
                    while (i < self.input.len and self.input[i] != '{' and self.input[i] != ';' and self.input[i] != '\n') {
                        i += 1;
                    }
                    if (i < self.input.len and self.input[i] == '{') {
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
                    } else if (i < self.input.len and (self.input[i] == ';' or self.input[i] == '\n')) {
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
                return try self.allocator.dupe(u8, input);
            }
            if (i == last_i) {
                stuck_count += 1;
                if (stuck_count > 100) {
                    return try self.allocator.dupe(u8, input);
                }
            } else {
                stuck_count = 0;
                last_i = i;
            }
            
            if (input[i] == '#' and i + 1 < input.len and input[i + 1] == '{') {
                i += 2;
                var brace_count: usize = 1;
                const interp_start = i;
                var interp_end: ?usize = null;
                
                while (i < input.len) {
                    if (input[i] == '{') {
                        brace_count += 1;
                    } else if (input[i] == '}') {
                        brace_count -= 1;
                        if (brace_count == 0) {
                            interp_end = i;
                            i += 1;
                            break;
                        }
                    }
                    i += 1;
                }
                
                if (interp_end) |end| {
                    const interp_expr = std.mem.trim(u8, input[interp_start..end], " \t\n\r");
                    const processed_expr = try self.processDirectivesWithDepth(interp_expr, depth + 1);
                    defer self.allocator.free(processed_expr);
                    
                    const evaluated = self.evaluateArithmetic(processed_expr) catch {
                        try result.appendSlice(self.allocator, processed_expr);
                        continue;
                    };
                    defer self.allocator.free(evaluated);
                    
                    try result.appendSlice(self.allocator, evaluated);
                    continue;
                } else {
                    try result.append(self.allocator, '#');
                    try result.append(self.allocator, '{');
                    i = interp_start;
                    continue;
                }
            } else if (input[i] == '$' and i + 1 < input.len) {
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
            } else if (std.ascii.isAlphabetic(input[i]) and (i == 0 or (!std.ascii.isAlphanumeric(input[i - 1]) and input[i - 1] != '_' and input[i - 1] != '-'))) {
                
                const func_start = i;
                var func_end = i;
                while (func_end < input.len and (std.ascii.isAlphanumeric(input[func_end]) or input[func_end] == '-' or input[func_end] == '_')) {
                    func_end += 1;
                }

                if (func_end < input.len and input[func_end] == '(') {
                    const func_name = input[func_start..func_end];
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
                    
                    if (try self.evaluateBuiltinFunction(func_name, args_str, depth + 1)) |result_value| {
                        defer self.allocator.free(result_value);
                        if (std.mem.eql(u8, func_name, "if")) {
                            std.debug.print("DEBUG: if function result: \"{s}\" (len={d})\n", .{ result_value, result_value.len });
                        }
                        try result.appendSlice(self.allocator, result_value);
                        i = func_end + 1;
                        continue;
                    }
                    
                    if (self.functions.get(func_name)) |func| {
                        const result_value = try self.evaluateFunctionWithDepth(func, args_str, depth + 1);
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

    fn evaluateBuiltinFunction(self: *Parser, func_name: []const u8, args_str: []const u8, depth: usize) std.mem.Allocator.Error!?[]const u8 {
        if (std.mem.eql(u8, func_name, "map-get")) {
            return try self.evaluateMapGet(args_str, depth);
        } else if (std.mem.eql(u8, func_name, "lighten")) {
            return try self.evaluateLighten(args_str, depth);
        } else if (std.mem.eql(u8, func_name, "lightness")) {
            return try self.evaluateLightness(args_str, depth);
        } else if (std.mem.eql(u8, func_name, "if")) {
            return try self.evaluateIf(args_str, depth);
        }
        return null;
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
            if (i + 7 <= func_body.len and std.mem.eql(u8, func_body[i..i+7], "@return")) {
                i += 7;
                skipWhitespaceInSlice(func_body, &i);
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
            const return_value_raw = func_body[start..end];
            const return_value = std.mem.trim(u8, return_value_raw, " \t\n\r");
            if (return_value.len == 0) {
                return try self.allocator.dupe(u8, "");
            }
            
            const processed_value = try self.processDirectivesWithDepth(return_value, depth + 1);
            defer self.allocator.free(processed_value);
            
            if (processed_value.len == 0) {
                return try self.allocator.dupe(u8, return_value);
            }
            
            const evaluated = self.evaluateArithmetic(processed_value) catch {
                if (processed_value.len > 0) {
                    return try self.allocator.dupe(u8, processed_value);
                }
                return try self.allocator.dupe(u8, return_value);
            };
            defer self.allocator.free(evaluated);
            
            if (evaluated.len == 0) {
                if (processed_value.len > 0) {
                    return try self.allocator.dupe(u8, processed_value);
                }
                return try self.allocator.dupe(u8, return_value);
            }
            
            return try self.allocator.dupe(u8, evaluated);
        }

        const processed_body = try self.processDirectivesWithDepth(func_body, depth + 1);
        defer self.allocator.free(processed_body);
        if (processed_body.len > 0) {
            return try self.allocator.dupe(u8, processed_body);
        }
        
        return try self.allocator.dupe(u8, "");
    }

    fn evaluateArithmetic(self: *Parser, expr: []const u8) std.mem.Allocator.Error![]const u8 {
        const trimmed = std.mem.trim(u8, expr, " \t\n\r");
        if (trimmed.len == 0) {
            return try self.allocator.dupe(u8, expr);
        }

        var expr_copy = try self.allocator.dupe(u8, trimmed);
        errdefer self.allocator.free(expr_copy);

        var iterations: usize = 0;
        while (iterations < 20) {
            iterations += 1;
            std.debug.print("DEBUG: evaluateArithmetic iteration {}, expr_copy=\"{s}\"\n", .{ iterations, expr_copy });
            var found_parens = false;

            var i: usize = 0;
            while (i < expr_copy.len) {
                if (expr_copy[i] == '(') {
                    found_parens = true;
                    const paren_start = i;
                    i += 1;
                    var paren_count: usize = 1;
                    var paren_end: ?usize = null;
                    
                    while (i < expr_copy.len and paren_count > 0) {
                        if (expr_copy[i] == '(') {
                            paren_count += 1;
                        } else if (expr_copy[i] == ')') {
                            paren_count -= 1;
                            if (paren_count == 0) {
                                paren_end = i;
                                break;
                            }
                        }
                        i += 1;
                    }
                    
                    if (paren_end) |end| {
                        const inner = expr_copy[paren_start + 1..end];
                        std.debug.print("DEBUG: Found parentheses, inner=\"{s}\"\n", .{inner});
                        const before_paren = std.mem.trim(u8, expr_copy[0..paren_start], " \t\n\r");
                        const is_function_call = before_paren.len > 0 and std.ascii.isAlphabetic(before_paren[before_paren.len - 1]);
                        
                        const result = try self.evaluateSimpleArithmetic(inner);
                        if (result) |res| {
                            std.debug.print("DEBUG: Evaluated inner to \"{s}\"\n", .{res});
                            var new_expr = try std.ArrayList(u8).initCapacity(self.allocator, expr_copy.len);
                            defer new_expr.deinit(self.allocator);
                            try new_expr.appendSlice(self.allocator, expr_copy[0..paren_start]);
                            try new_expr.appendSlice(self.allocator, res);
                            try new_expr.appendSlice(self.allocator, expr_copy[end + 1..]);
                            self.allocator.free(expr_copy);
                            expr_copy = try new_expr.toOwnedSlice(self.allocator);
                            std.debug.print("DEBUG: New expr_copy after replacement=\"{s}\"\n", .{expr_copy});
                            break;
                        } else {
                            std.debug.print("DEBUG: evaluateSimpleArithmetic returned null for inner\n", .{});
                            if (is_function_call or inner.len > 0 and inner[0] == '$') {
                                std.debug.print("DEBUG: Looks like a function call or variable reference, returning as-is\n", .{});
                                return expr_copy;
                            }
                        }
                    }
                }
                i += 1;
            }

            if (!found_parens) {
                std.debug.print("DEBUG: No parentheses found, evaluating \"{s}\"\n", .{expr_copy});
                const result = try self.evaluateSimpleArithmetic(expr_copy);
                if (result) |res| {
                    std.debug.print("DEBUG: evaluateSimpleArithmetic returned \"{s}\", returning it\n", .{res});
                    self.allocator.free(expr_copy);
                    return res;
                } else {
                    std.debug.print("DEBUG: evaluateSimpleArithmetic returned null, returning expr_copy=\"{s}\"\n", .{expr_copy});
                }
                return expr_copy;
            }
        }

        std.debug.print("DEBUG: Final evaluation of \"{s}\"\n", .{expr_copy});
        const final_result = try self.evaluateSimpleArithmetic(expr_copy);
        if (final_result) |res| {
            std.debug.print("DEBUG: Final result=\"{s}\"\n", .{res});
            self.allocator.free(expr_copy);
            return res;
        } else {
            std.debug.print("DEBUG: Final evaluateSimpleArithmetic returned null\n", .{});
        }
        
        if (expr_copy.len > 0) {
            return expr_copy;
        }
        
        return try self.allocator.dupe(u8, trimmed);
    }

    fn evaluateSimpleArithmetic(self: *Parser, expr: []const u8) std.mem.Allocator.Error!?[]const u8 {
        const trimmed = std.mem.trim(u8, expr, " \t\n\r");
        std.debug.print("DEBUG: evaluateSimpleArithmetic called with \"{s}\"\n", .{trimmed});
        if (trimmed.len == 0) {
            return null;
        }

        if (trimmed[0] == '$') {
            std.debug.print("DEBUG: Expression starts with $, treating as variable reference, returning null\n", .{});
            return null;
        }

        var parts = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
        defer parts.deinit(self.allocator);
        var operators = try std.ArrayList(u8).initCapacity(self.allocator, 4);
        defer operators.deinit(self.allocator);

        var i: usize = 0;
        var start: usize = 0;
        var depth: i32 = 0;

        while (i < trimmed.len) {
            const ch = trimmed[i];
            if (ch == '(') {
                depth += 1;
                i += 1;
            } else if (ch == ')') {
                depth -= 1;
                i += 1;
            } else if (ch == '$' and depth == 0) {
                var var_end = i + 1;
                while (var_end < trimmed.len) {
                    const var_ch = trimmed[var_end];
                    if (std.ascii.isAlphanumeric(var_ch) or var_ch == '-' or var_ch == '_') {
                        var_end += 1;
                    } else {
                        break;
                    }
                }
                if (var_end > i + 1) {
                    i = var_end;
                    continue;
                }
                i += 1;
            } else if ((ch == '+' or ch == '-' or ch == '*' or ch == '/') and depth == 0) {
                if (i > start and trimmed[start] == '$') {
                    return null;
                }
                if (i > start) {
                    const part = std.mem.trim(u8, trimmed[start..i], " \t\n\r");
                    if (part.len > 0) {
                        if (part[0] == '$') {
                            return null;
                        }
                        try parts.append(self.allocator, part);
                    }
                }
                try operators.append(self.allocator, ch);
                i += 1;
                start = i;
            } else {
                i += 1;
            }
        }

        if (start < trimmed.len) {
            const part = std.mem.trim(u8, trimmed[start..], " \t\n\r");
            if (part.len > 0) {
                if (part[0] == '$') {
                    return null;
                }
                try parts.append(self.allocator, part);
            }
        }

        if (parts.items.len == 0) {
            return null;
        }

        for (parts.items) |part| {
            if (part.len > 0 and part[0] == '$') {
                return null;
            }
        }

        std.debug.print("DEBUG: Parts: {d}, Operators: {d}\n", .{ parts.items.len, operators.items.len });
        for (parts.items, 0..) |part, idx| {
            std.debug.print("DEBUG:   part[{}]=\"{s}\"\n", .{ idx, part });
        }
        for (operators.items, 0..) |op, idx| {
            std.debug.print("DEBUG:   op[{}]='{c}'\n", .{ idx, op });
        }

        if (parts.items.len == 1 and operators.items.len == 0) {
            const part_str = parts.items[0];
            if (part_str.len == 0) {
                return null;
            }
            std.debug.print("DEBUG: Single part, returning \"{s}\"\n", .{part_str});
            return try self.allocator.dupe(u8, part_str);
        }

        if (parts.items.len != operators.items.len + 1) {
            std.debug.print("DEBUG: Mismatch: parts={d}, operators={d}, returning null\n", .{ parts.items.len, operators.items.len });
            return null;
        }

        var values = try std.ArrayList(NumericValue).initCapacity(self.allocator, 4);
        defer {
            for (values.items) |v| {
                if (v.unit) |u| self.allocator.free(u);
            }
            values.deinit(self.allocator);
        }

        for (parts.items) |part| {
            std.debug.print("DEBUG: Parsing part \"{s}\"\n", .{part});
            const parsed = self.parseNumericWithUnit(part) catch |err| {
                std.debug.print("DEBUG: parseNumericWithUnit failed for \"{s}\": {s}\n", .{ part, @errorName(err) });
                return null;
            };
            std.debug.print("DEBUG: Parsed: value={d}, unit={?s}\n", .{ parsed.value, parsed.unit });
            try values.append(self.allocator, parsed);
        }

        if (values.items.len == 0) {
            std.debug.print("DEBUG: No values parsed, returning null\n", .{});
            return null;
        }

        var result_value = values.items[0].value;
        var result_unit: ?[]const u8 = if (values.items[0].unit) |u| try self.allocator.dupe(u8, u) else null;
        errdefer if (result_unit) |u| self.allocator.free(u);
        std.debug.print("DEBUG: Starting with result_value={d}, result_unit={?s}\n", .{ result_value, result_unit });
        
        for (operators.items, 1..) |op, idx| {
            std.debug.print("DEBUG: Processing op='{c}', next_val.value={d}, next_val.unit={?s}\n", .{ op, values.items[idx].value, values.items[idx].unit });
            const next_val = values.items[idx];
            const old_unit = result_unit;
            
            result_value = switch (op) {
                '+' => result_value + next_val.value,
                '-' => result_value - next_val.value,
                '*' => result_value * next_val.value,
                '/' => if (next_val.value == 0) return null else result_value / next_val.value,
                else => return null,
            };
            
            result_unit = switch (op) {
                '+' => if (result_unit == null and next_val.unit != null) 
                    try self.allocator.dupe(u8, next_val.unit.?)
                    else if (result_unit != null and next_val.unit == null) 
                    result_unit
                    else if (result_unit != null and next_val.unit != null and std.mem.eql(u8, result_unit.?, next_val.unit.?)) 
                    try self.allocator.dupe(u8, result_unit.?)
                    else {
                        std.debug.print("DEBUG: Addition unit mismatch, returning null\n", .{});
                        return null;
                    },
                '-' => if (result_unit == null and next_val.unit != null) {
                        std.debug.print("DEBUG: Subtraction: result_unit null but next_val has unit, returning null\n", .{});
                        return null;
                    }
                    else if (result_unit != null and next_val.unit == null) 
                    result_unit
                    else if (result_unit != null and next_val.unit != null and std.mem.eql(u8, result_unit.?, next_val.unit.?)) 
                    try self.allocator.dupe(u8, result_unit.?)
                    else {
                        std.debug.print("DEBUG: Subtraction unit mismatch, returning null\n", .{});
                        return null;
                    },
                '*' => blk: {
                    std.debug.print("DEBUG: Multiplication: result_unit={?s}, next_val.unit={?s}\n", .{ result_unit, next_val.unit });
                    break :blk if (result_unit != null) 
                        try self.allocator.dupe(u8, result_unit.?)
                    else if (next_val.unit != null) 
                        try self.allocator.dupe(u8, next_val.unit.?)
                    else null;
                },
                '/' => if (next_val.unit == null) 
                    if (result_unit) |u| try self.allocator.dupe(u8, u) else null
                    else if (result_unit != null and std.mem.eql(u8, result_unit.?, next_val.unit.?)) 
                    null
                    else 
                    if (result_unit) |u| try self.allocator.dupe(u8, u) else null,
                else => {
                    std.debug.print("DEBUG: Unknown operator '{c}', returning null\n", .{op});
                    return null;
                },
            };
            std.debug.print("DEBUG: After op '{c}': result_value={d}, result_unit={?s}\n", .{ op, result_value, result_unit });
            
            if (old_unit) |ou| {
                if (result_unit == null or !std.mem.eql(u8, ou, result_unit.?)) {
                    self.allocator.free(ou);
                }
            }
        }
        
        const result = NumericValue{ .value = result_value, .unit = result_unit };

        const formatted = try self.formatNumericWithUnit(result.value, result.unit);
        return formatted;
    }

    fn parseNumericWithUnit(self: *Parser, value: []const u8) std.mem.Allocator.Error!NumericValue {
        const trimmed = std.mem.trim(u8, value, " \t\n\r");
        if (trimmed.len == 0) {
            return error.OutOfMemory;
        }

        const units = [_][]const u8{ "vmin", "vmax", "rem", "em", "px", "%", "pt", "pc", "in", "cm", "mm", "ex", "ch", "vw", "vh" };
        var unit: ?[]const u8 = null;
        var num_str = trimmed;

        for (units) |u| {
            if (trimmed.len >= u.len and std.mem.eql(u8, trimmed[trimmed.len - u.len..], u)) {
                unit = try self.allocator.dupe(u8, u);
                num_str = trimmed[0..trimmed.len - u.len];
                break;
            }
        }

        std.debug.print("DEBUG: parseNumericWithUnit: trimmed=\"{s}\", num_str=\"{s}\", unit={?s}\n", .{ trimmed, num_str, unit });
        const num = std.fmt.parseFloat(f64, num_str) catch |err| {
            std.debug.print("DEBUG: parseFloat failed for \"{s}\": {s}\n", .{ num_str, @errorName(err) });
            return error.OutOfMemory;
        };

        return .{ .value = num, .unit = unit };
    }

    fn formatNumericWithUnit(self: *Parser, value: f64, unit: ?[]const u8) ![]const u8 {
        if (unit) |u| {
            if (@mod(value, 1.0) == 0.0) {
                const result = try std.fmt.allocPrint(self.allocator, "{d}{s}", .{ @as(i64, @intFromFloat(value)), u });
                self.allocator.free(u);
                return result;
            } else {
                const result = try std.fmt.allocPrint(self.allocator, "{d}{s}", .{ value, u });
                self.allocator.free(u);
                return result;
            }
        } else {
            if (@mod(value, 1.0) == 0.0) {
                return try std.fmt.allocPrint(self.allocator, "{d}", .{@as(i64, @intFromFloat(value))});
            } else {
                return try std.fmt.allocPrint(self.allocator, "{d}", .{value});
            }
        }
    }

    fn parseFunctionArgs(self: *Parser, args_str: []const u8, depth: usize) std.mem.Allocator.Error!std.ArrayList([]const u8) {
        var args = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        errdefer {
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
                    const processed_arg = try self.processDirectivesWithDepth(arg, depth + 1);
                    defer self.allocator.free(processed_arg);
                    const arg_copy = try self.allocator.dupe(u8, processed_arg);
                    try args.append(self.allocator, arg_copy);
                }
                i += 1;
                skipWhitespaceInSlice(args_str, &i);
                arg_start = i;
                continue;
            }
            i += 1;
        }
        const arg = std.mem.trim(u8, args_str[arg_start..], " \t");
        if (arg.len > 0) {
            const processed_arg = try self.processDirectivesWithDepth(arg, depth + 1);
            defer self.allocator.free(processed_arg);
            const arg_copy = try self.allocator.dupe(u8, processed_arg);
            try args.append(self.allocator, arg_copy);
        }
        return args;
    }

    fn evaluateMapGet(self: *Parser, args_str: []const u8, depth: usize) std.mem.Allocator.Error!?[]const u8 {
        var args = try self.parseFunctionArgs(args_str, depth);
        defer {
            for (args.items) |arg| {
                self.allocator.free(arg);
            }
            args.deinit(self.allocator);
        }

        if (args.items.len != 2) {
            return null;
        }

        const map_var = args.items[0];
        const key = args.items[1];

        var map_value: []const u8 = undefined;
        var map_value_owned: ?[]const u8 = null;
        defer if (map_value_owned) |mv| self.allocator.free(mv);

        if (map_var.len > 0 and map_var[0] == '$') {
            const var_name = map_var[1..];
            map_value = self.variables.get(var_name) orelse return null;
        } else {
            map_value_owned = try self.processDirectivesWithDepth(map_var, depth + 1);
            map_value = map_value_owned.?;
        }

        const map_str = std.mem.trim(u8, map_value, " \t\n\r");
        if (map_str.len < 2 or map_str[0] != '(' or map_str[map_str.len - 1] != ')') {
            return null;
        }

        const map_content = map_str[1..map_str.len - 1];
        var i: usize = 0;
        while (i < map_content.len) {
            skipWhitespaceInSlice(map_content, &i);
            if (i >= map_content.len) break;

            const key_start = i;
            while (i < map_content.len and map_content[i] != ':') {
                i += 1;
            }
            if (i >= map_content.len) break;

            const map_key = std.mem.trim(u8, map_content[key_start..i], " \t");
            i += 1;
            skipWhitespaceInSlice(map_content, &i);

            const value_start = i;
            var value_paren_count: usize = 0;
            while (i < map_content.len) {
                if (map_content[i] == '(') {
                    value_paren_count += 1;
                } else if (map_content[i] == ')') {
                    if (value_paren_count == 0) break;
                    value_paren_count -= 1;
                } else if (map_content[i] == ',' and value_paren_count == 0) {
                    break;
                }
                i += 1;
            }

            const map_value_str = std.mem.trim(u8, map_content[value_start..i], " \t");
            if (std.mem.eql(u8, map_key, key)) {
                return try self.allocator.dupe(u8, map_value_str);
            }

            if (i < map_content.len and map_content[i] == ',') {
                i += 1;
            }
        }

        return null;
    }

    fn parseColor(_: *Parser, color_str: []const u8) ?[3]u8 {
        const trimmed = std.mem.trim(u8, color_str, " \t\n\r");
        if (trimmed.len == 0) return null;

        if (trimmed[0] == '#') {
            if (trimmed.len == 4) {
                const r = std.fmt.parseInt(u8, trimmed[1..2], 16) catch return null;
                const g = std.fmt.parseInt(u8, trimmed[2..3], 16) catch return null;
                const b = std.fmt.parseInt(u8, trimmed[3..4], 16) catch return null;
                return [3]u8{ r * 17, g * 17, b * 17 };
            } else if (trimmed.len == 7) {
                const r = std.fmt.parseInt(u8, trimmed[1..3], 16) catch return null;
                const g = std.fmt.parseInt(u8, trimmed[3..5], 16) catch return null;
                const b = std.fmt.parseInt(u8, trimmed[5..7], 16) catch return null;
                return [3]u8{ r, g, b };
            }
        } else if (std.mem.eql(u8, trimmed, "black")) {
            return [3]u8{ 0, 0, 0 };
        } else if (std.mem.eql(u8, trimmed, "white")) {
            return [3]u8{ 255, 255, 255 };
        }

        return null;
    }

    fn formatColor(self: *Parser, rgb: [3]u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgb[0], rgb[1], rgb[2] });
    }

    fn evaluateLighten(self: *Parser, args_str: []const u8, depth: usize) std.mem.Allocator.Error!?[]const u8 {
        var args = try self.parseFunctionArgs(args_str, depth);
        defer {
            for (args.items) |arg| {
                self.allocator.free(arg);
            }
            args.deinit(self.allocator);
        }

        if (args.items.len != 2) {
            return null;
        }

        var color_str = args.items[0];
        const amount_str = args.items[1];

        var color_resolved = color_str;
        var color_owned: ?[]const u8 = null;
        defer if (color_owned) |co| self.allocator.free(co);

        if (color_str.len > 0 and color_str[0] == '$') {
            const var_name = color_str[1..];
            if (self.variables.get(var_name)) |var_value| {
                color_owned = try self.processDirectivesWithDepth(var_value, depth + 1);
                color_resolved = color_owned.?;
            } else {
                return null;
            }
        }

        const rgb = parseColor(self, color_resolved) orelse {
            return null;
        };

        var amount_str_clean = std.mem.trim(u8, amount_str, " \t\n\r");
        if (std.mem.endsWith(u8, amount_str_clean, "%")) {
            amount_str_clean = amount_str_clean[0..amount_str_clean.len - 1];
        }
        const amount = std.fmt.parseFloat(f64, amount_str_clean) catch {
            std.debug.print("DEBUG: evaluateLighten: parseFloat failed for \"{s}\"\n", .{amount_str_clean});
            return null;
        };
        const lighten_factor = amount / 100.0;

        var new_rgb: [3]u8 = undefined;
        for (0..3) |i| {
            const old = rgb[i];
            const lightened = @as(f64, @floatFromInt(old)) + (255.0 - @as(f64, @floatFromInt(old))) * lighten_factor;
            new_rgb[i] = @as(u8, @intFromFloat(@min(255.0, @max(0.0, lightened))));
        }

        return try self.formatColor(new_rgb);
    }

    fn evaluateLightness(self: *Parser, args_str: []const u8, depth: usize) std.mem.Allocator.Error!?[]const u8 {
        var args = try self.parseFunctionArgs(args_str, depth);
        defer {
            for (args.items) |arg| {
                self.allocator.free(arg);
            }
            args.deinit(self.allocator);
        }

        if (args.items.len != 1) {
            return null;
        }

        var color_str = args.items[0];
        var color_resolved = color_str;
        var color_owned: ?[]const u8 = null;
        defer if (color_owned) |co| self.allocator.free(co);

        if (color_str.len > 0 and color_str[0] == '$') {
            const var_name = color_str[1..];
            if (self.variables.get(var_name)) |var_value| {
                color_owned = try self.processDirectivesWithDepth(var_value, depth + 1);
                color_resolved = color_owned.?;
            } else {
                return null;
            }
        }

        const rgb = parseColor(self, color_resolved) orelse return null;

        const r = @as(f64, @floatFromInt(rgb[0])) / 255.0;
        const g = @as(f64, @floatFromInt(rgb[1])) / 255.0;
        const b = @as(f64, @floatFromInt(rgb[2])) / 255.0;

        const max = @max(@max(r, g), b);
        const min = @min(@min(r, g), b);
        const lightness = ((max + min) / 2.0) * 100.0;

        return try std.fmt.allocPrint(self.allocator, "{d}%", .{lightness});
    }

    fn evaluateComparison(self: *Parser, condition: []const u8, depth: usize) std.mem.Allocator.Error!bool {
        const processed = try self.processDirectivesWithDepth(condition, depth + 1);
        defer self.allocator.free(processed);
        
        const trimmed = std.mem.trim(u8, processed, " \t\n\r");
        
        var i: usize = 0;
        while (i < trimmed.len) {
            const ch = trimmed[i];
            if (ch == '>' or ch == '<' or ch == '=' or ch == '!') {
                const op_start = i;
                i += 1;
                if (i < trimmed.len and trimmed[i] == '=') {
                    i += 1;
                }
                const op = trimmed[op_start..i];
                
                const left_str = std.mem.trim(u8, trimmed[0..op_start], " \t\n\r");
                const right_str = std.mem.trim(u8, trimmed[i..], " \t\n\r");
                
                const left_processed = try self.processDirectivesWithDepth(left_str, depth + 1);
                defer self.allocator.free(left_processed);
                const right_processed = try self.processDirectivesWithDepth(right_str, depth + 1);
                defer self.allocator.free(right_processed);
                
                const left_eval = self.evaluateArithmetic(left_processed) catch left_processed;
                defer if (left_eval.ptr != left_processed.ptr) self.allocator.free(left_eval);
                const right_eval = self.evaluateArithmetic(right_processed) catch right_processed;
                defer if (right_eval.ptr != right_processed.ptr) self.allocator.free(right_eval);
                
                const left_num = self.parseNumericWithUnit(left_eval) catch {
                    return false;
                };
                defer if (left_num.unit) |u| self.allocator.free(u);
                
                var right_str_clean = right_eval;
                if (std.mem.endsWith(u8, right_eval, "%")) {
                    right_str_clean = right_eval[0..right_eval.len - 1];
                }
                const right_num = self.parseNumericWithUnit(right_str_clean) catch {
                    return false;
                };
                defer if (right_num.unit) |u| self.allocator.free(u);
                
                const result = if (std.mem.eql(u8, op, ">"))
                    left_num.value > right_num.value
                else if (std.mem.eql(u8, op, "<"))
                    left_num.value < right_num.value
                else if (std.mem.eql(u8, op, ">="))
                    left_num.value >= right_num.value
                else if (std.mem.eql(u8, op, "<="))
                    left_num.value <= right_num.value
                else if (std.mem.eql(u8, op, "=="))
                    left_num.value == right_num.value
                else if (std.mem.eql(u8, op, "!="))
                    left_num.value != right_num.value
                else
                    return false;
                
                return result;
            }
            i += 1;
        }
        
        const evaluated = self.evaluateArithmetic(trimmed) catch trimmed;
        defer if (evaluated.ptr != trimmed.ptr) self.allocator.free(evaluated);
        
        const num_val = self.parseNumericWithUnit(evaluated) catch {
            const trimmed_eval = std.mem.trim(u8, evaluated, " \t\n\r");
            return trimmed_eval.len > 0 and !std.mem.eql(u8, trimmed_eval, "0") and !std.mem.eql(u8, trimmed_eval, "false");
        };
        defer if (num_val.unit) |u| self.allocator.free(u);
        
        return num_val.value != 0.0;
    }

    fn evaluateIf(self: *Parser, args_str: []const u8, depth: usize) std.mem.Allocator.Error!?[]const u8 {
        var args = try self.parseFunctionArgs(args_str, depth);
        defer {
            for (args.items) |arg| {
                self.allocator.free(arg);
            }
            args.deinit(self.allocator);
        }

        if (args.items.len != 3) {
            return null;
        }

        const condition_str = args.items[0];
        const if_true = args.items[1];
        const if_false = args.items[2];

        const condition = std.mem.trim(u8, condition_str, " \t\n\r");
        
        var is_true = false;
        if (std.mem.eql(u8, condition, "true")) {
            is_true = true;
        } else if (std.mem.eql(u8, condition, "false")) {
            is_true = false;
        } else {
            is_true = try self.evaluateComparison(condition, depth + 1);
        }

        return if (is_true) try self.allocator.dupe(u8, if_true) else try self.allocator.dupe(u8, if_false);
    }

    fn flattenNestedSelectors(self: *Parser, input: []const u8, parent_selector: ?[]const u8) std.mem.Allocator.Error![]const u8 {
        // #region agent log
        const log_entry = try std.fmt.allocPrint(self.allocator, "{{\"location\":\"flattenNestedSelectors:entry\",\"message\":\"Entering flattenNestedSelectors\",\"data\":{{\"input_len\":{d},\"input_preview\":\"{s}\"}},\"timestamp\":{d},\"runId\":\"run1\",\"hypothesisId\":\"A\"}}\n", .{ input.len, if (input.len > 50) input[0..50] else input, std.time.timestamp() });
        defer self.allocator.free(log_entry);
        const log_file = std.fs.cwd().createFile("/Users/vyakymenko/Documents/git/GitHub/zcss/.cursor/debug.log", .{ .truncate = false }) catch {
            _ = std.fs.cwd().writeFile(.{ .sub_path = "/Users/vyakymenko/Documents/git/GitHub/zcss/.cursor/debug.log", .data = log_entry }) catch {};
            return try self.allocator.dupe(u8, "");
        };
        defer log_file.close();
        _ = log_file.writeAll(log_entry) catch {};
        // #endregion agent log
        
        if (input.len == 0) {
            return try self.allocator.dupe(u8, "");
        }
        
        var result = try std.ArrayList(u8).initCapacity(self.allocator, input.len * 2);
        errdefer result.deinit(self.allocator);
        
        var selector_stack = try std.ArrayList([]const u8).initCapacity(self.allocator, 10);
        defer {
            for (selector_stack.items) |sel| {
                self.allocator.free(sel);
            }
            selector_stack.deinit(self.allocator);
        }
        
        var parent_selector_in_stack = false;
        if (parent_selector) |parent| {
            const parent_copy = try self.allocator.dupe(u8, parent);
            try selector_stack.append(self.allocator, parent_copy);
            parent_selector_in_stack = true;
        }
        
        var i: usize = 0;
        var has_selector = false;
        while (i < input.len) {
            const before_skip = i;
            skipWhitespaceInSlice(input, &i);
            if (i >= input.len) {
                if (before_skip < input.len) {
                    try result.appendSlice(self.allocator, input[before_skip..]);
                }
                break;
            }
            const content_start = i;
            
            if (input[i] == '}') {
                if (selector_stack.items.len > 0) {
                    const popped = selector_stack.orderedRemove(selector_stack.items.len - 1);
                    self.allocator.free(popped);
                }
                try result.append(self.allocator, input[i]);
                i += 1;
                continue;
            }
            
            const sel_start = i;
            var found_brace = false;
            var brace_pos: usize = 0;
            var paren_depth: usize = 0;
            var in_quotes = false;
            var quote_char: u8 = 0;
            
            while (i < input.len) {
                const ch = input[i];
                if (!in_quotes) {
                    if (ch == '"' or ch == '\'') {
                        in_quotes = true;
                        quote_char = ch;
                    } else if (ch == '(') {
                        paren_depth += 1;
                    } else if (ch == ')') {
                        paren_depth -= 1;
                    } else if (ch == '{' and paren_depth == 0) {
                        found_brace = true;
                        brace_pos = i;
                        break;
                    }
                } else if (ch == quote_char and (i == 0 or input[i - 1] != '\\')) {
                    in_quotes = false;
                }
                i += 1;
            }
            
            if (found_brace) {
                has_selector = true;
                const selector_raw = std.mem.trim(u8, input[sel_start..brace_pos], " \t\n\r");
                
                // #region agent log
                const log_entry2 = try std.fmt.allocPrint(self.allocator, "{{\"location\":\"flattenNestedSelectors:found_brace\",\"message\":\"Found selector with brace\",\"data\":{{\"selector_raw\":\"{s}\",\"stack_len\":{d}}},\"timestamp\":{d},\"runId\":\"run1\",\"hypothesisId\":\"A\"}}\n", .{ selector_raw, selector_stack.items.len, std.time.timestamp() });
                defer self.allocator.free(log_entry2);
                _ = log_file.writeAll(log_entry2) catch {};
                // #endregion agent log
                
                if (selector_raw.len > 0 and selector_raw[0] != '@') {
                    var full_sel = try std.ArrayList(u8).initCapacity(self.allocator, selector_raw.len * 3);
                    errdefer full_sel.deinit(self.allocator);
                    
                    for (selector_stack.items) |parent| {
                        try full_sel.appendSlice(self.allocator, parent);
                        try full_sel.append(self.allocator, ' ');
                    }
                    
                    try full_sel.appendSlice(self.allocator, selector_raw);
                    
                    const full_sel_str = try full_sel.toOwnedSlice(self.allocator);
                    defer self.allocator.free(full_sel_str);
                    
                    try result.appendSlice(self.allocator, full_sel_str);
                    try result.append(self.allocator, ' ');
                    try result.append(self.allocator, '{');
                    try result.append(self.allocator, '\n');
                    
                    i = brace_pos + 1;
                    
                    var brace_count: usize = 1;
                    const nested_start = i;
                    var content_end = i;
                    while (content_end < input.len and brace_count > 0) {
                        const ch = input[content_end];
                        if (ch == '{') {
                            brace_count += 1;
                        } else if (ch == '}') {
                            brace_count -= 1;
                        }
                        if (brace_count > 0) {
                            content_end += 1;
                        }
                    }
                    
                    const nested_content = input[nested_start..content_end];
                    // #region agent log
                    const log_entry3 = try std.fmt.allocPrint(self.allocator, "{{\"location\":\"flattenNestedSelectors:nested_content\",\"message\":\"Extracted nested content\",\"data\":{{\"nested_len\":{d},\"nested_preview\":\"{s}\",\"nested_full\":\"{s}\",\"parent_selector\":\"{s}\"}},\"timestamp\":{d},\"runId\":\"run1\",\"hypothesisId\":\"B\"}}\n", .{ nested_content.len, if (nested_content.len > 50) nested_content[0..50] else nested_content, nested_content, full_sel_str, std.time.timestamp() });
                    defer self.allocator.free(log_entry3);
                    _ = log_file.writeAll(log_entry3) catch {};
                    // #endregion agent log
                    
                    if (nested_content.len == 0) {
                        i = content_end;
                        continue;
                    }
                    
                    const parent_copy = try self.allocator.dupe(u8, full_sel_str);
                    const flattened_nested = try self.flattenNestedSelectors(nested_content, parent_copy);
                    defer {
                        self.allocator.free(flattened_nested);
                        self.allocator.free(parent_copy);
                    }
                    // #region agent log
                    const log_entry4 = try std.fmt.allocPrint(self.allocator, "{{\"location\":\"flattenNestedSelectors:flattened_result\",\"message\":\"Got flattened nested result\",\"data\":{{\"flattened_len\":{d},\"flattened_preview\":\"{s}\"}},\"timestamp\":{d},\"runId\":\"run1\",\"hypothesisId\":\"A\"}}\n", .{ flattened_nested.len, if (flattened_nested.len > 50) flattened_nested[0..50] else flattened_nested, std.time.timestamp() });
                    defer self.allocator.free(log_entry4);
                    _ = log_file.writeAll(log_entry4) catch {};
                    // #endregion agent log
                    try result.appendSlice(self.allocator, flattened_nested);
                    
                    i = content_end;
                    if (selector_stack.items.len > 0) {
                        const popped = selector_stack.orderedRemove(selector_stack.items.len - 1);
                        self.allocator.free(popped);
                    }
                    try result.append(self.allocator, '}');
                    try result.append(self.allocator, '\n');
                } else {
                    try result.appendSlice(self.allocator, input[sel_start..brace_pos + 1]);
                    i = brace_pos + 1;
                }
            } else {
                // #region agent log
                const log_entry5 = try std.fmt.allocPrint(self.allocator, "{{\"location\":\"flattenNestedSelectors:no_brace\",\"message\":\"No brace found, copying content\",\"data\":{{\"has_selector\":{},\"remaining_len\":{d},\"remaining_preview\":\"{s}\"}},\"timestamp\":{d},\"runId\":\"run1\",\"hypothesisId\":\"A\"}}\n", .{ has_selector, input.len - i, if (input.len - i > 50) input[i..i+50] else input[i..], std.time.timestamp() });
                defer self.allocator.free(log_entry5);
                _ = log_file.writeAll(log_entry5) catch {};
                // #endregion agent log
                
                if (!has_selector) {
                    if (parent_selector_in_stack and selector_stack.items.len > 0) {
                        const last_selector = selector_stack.items[selector_stack.items.len - 1];
                        if (parent_selector) |parent| {
                            if (std.mem.eql(u8, last_selector, parent)) {
                                const popped = selector_stack.orderedRemove(selector_stack.items.len - 1);
                                self.allocator.free(popped);
                                parent_selector_in_stack = false;
                            }
                        }
                    }
                    if (content_start < input.len) {
                        try result.appendSlice(self.allocator, input[content_start..]);
                    }
                    break;
                }
                while (i < input.len) {
                    if (input[i] == '}') {
                        break;
                    }
                    i += 1;
                }
                if (i > content_start) {
                    try result.appendSlice(self.allocator, input[content_start..i]);
                }
                if (i < input.len and input[i] == '}') {
                    if (selector_stack.items.len > 0) {
                        const popped = selector_stack.orderedRemove(selector_stack.items.len - 1);
                        self.allocator.free(popped);
                    }
                    try result.append(self.allocator, input[i]);
                    i += 1;
                }
            }
        }
        
        const final_result = try result.toOwnedSlice(self.allocator);
        // #region agent log
        const log_entry6 = try std.fmt.allocPrint(self.allocator, "{{\"location\":\"flattenNestedSelectors:exit\",\"message\":\"Exiting flattenNestedSelectors\",\"data\":{{\"result_len\":{d},\"result_preview\":\"{s}\"}},\"timestamp\":{d},\"runId\":\"run1\",\"hypothesisId\":\"A\"}}\n", .{ final_result.len, if (final_result.len > 50) final_result[0..50] else final_result, std.time.timestamp() });
        defer self.allocator.free(log_entry6);
        _ = log_file.writeAll(log_entry6) catch {};
        // #endregion agent log
        return final_result;
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
        const value_copy = try self.allocator.dupe(u8, value);
        const name_copy = try self.allocator.dupe(u8, name);

        try self.variables.put(name_copy, value_copy);

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
                self.skipComment();
            } else {
                break;
            }
        }
    }

    fn skipComment(self: *Parser) void {
        self.pos += 2;
        while (self.pos < self.input.len - 1) {
            if (self.input[self.pos] == '*' and self.input[self.pos + 1] == '/') {
                self.pos += 2;
                return;
            }
            self.advance();
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
    }
};

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
