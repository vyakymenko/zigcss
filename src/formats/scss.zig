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

        var css_p = css_parser.Parser.init(self.allocator, processed_input);
        const stylesheet = try css_p.parse();
        return stylesheet;
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
                            const processed_content = try self.processDirectivesWithDepth(content, depth + 1);
                            defer self.allocator.free(processed_content);
                            
                            const content_pattern = "@content";
                            if (std.mem.indexOf(u8, mixin_body, content_pattern)) |content_pos| {
                                const before_content = mixin_body[0..content_pos];
                                const after_content = mixin_body[content_pos + content_pattern.len..];
                                const new_body = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ before_content, processed_content, after_content });
                                self.allocator.free(mixin_body);
                                mixin_body = new_body;
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
