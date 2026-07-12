const std = @import("std");
const source = @import("../source.zig");
const syntax = @import("../syntax.zig");
const tokenizer = @import("../tokenizer.zig");

pub const Error = std.mem.Allocator.Error || error{
    ArgumentLimit,
    InstructionLimit,
    InvalidExpression,
    InvalidSpan,
    NestingLimit,
    SourceMismatch,
    UnsupportedSyntax,
    UnterminatedSyntax,
};

pub const PercentHint = enum {
    length,
    angle,
    time,
    frequency,
    resolution,
    flex,
};

pub const BaseDimension = enum {
    length,
    angle,
    time,
    frequency,
    resolution,
    flex,
    percent,
};

/// CSS Typed OM type map. A number is the empty map. Multiplication and
/// division may produce compound intermediate types; callers can separately
/// ask whether the final map is representable by a CSS numeric production.
pub const CalcType = struct {
    exponents: [7]i8 = .{0} ** 7,
    percent_hint: ?PercentHint = null,

    pub fn number() CalcType {
        return .{};
    }

    pub fn dimension(base: BaseDimension) CalcType {
        var result = CalcType{};
        result.exponents[@intFromEnum(base)] = 1;
        return result;
    }

    pub fn percentage(hint: ?PercentHint) CalcType {
        if (hint) |value| {
            var result = dimension(hintBase(value));
            result.percent_hint = value;
            return result;
        }
        return dimension(.percent);
    }

    pub fn exponent(self: CalcType, base: BaseDimension) i8 {
        return self.exponents[@intFromEnum(base)];
    }

    pub fn eql(self: CalcType, other: CalcType) bool {
        return self.percent_hint == other.percent_hint and
            std.mem.eql(i8, &self.exponents, &other.exponents);
    }

    pub fn isNumber(self: CalcType) bool {
        if (self.percent_hint != null) return false;
        for (self.exponents) |exponent_value| {
            if (exponent_value != 0) return false;
        }
        return true;
    }

    pub fn isRepresentableNumeric(self: CalcType) bool {
        var nonzero: usize = 0;
        var exponent_value: i8 = 0;
        for (self.exponents) |candidate| {
            if (candidate == 0) continue;
            nonzero += 1;
            exponent_value = candidate;
        }
        return nonzero == 0 or (nonzero == 1 and exponent_value == 1);
    }
};

pub const TypeError = enum {
    conflicting_percent_hints,
    exponent_overflow,
    incompatible_types,
    none_in_arithmetic,
    unknown_unit,
};

const TypeOperationError = error{
    ConflictingPercentHints,
    ExponentOverflow,
};

pub const ResultType = union(enum) {
    valid: CalcType,
    invalid: TypeError,
    none,
};

pub const Unit = enum {
    number,
    percent,

    // Absolute lengths.
    px,
    cm,
    mm,
    q,
    in,
    pc,
    pt,

    // Font-relative lengths.
    em,
    rem,
    ex,
    rex,
    cap,
    rcap,
    ch,
    rch,
    ic,
    ric,
    lh,
    rlh,

    // Viewport-relative lengths.
    vw,
    vh,
    vi,
    vb,
    vmin,
    vmax,
    svw,
    svh,
    svi,
    svb,
    svmin,
    svmax,
    lvw,
    lvh,
    lvi,
    lvb,
    lvmin,
    lvmax,
    dvw,
    dvh,
    dvi,
    dvb,
    dvmin,
    dvmax,

    // Container-relative lengths.
    cqw,
    cqh,
    cqi,
    cqb,
    cqmin,
    cqmax,

    deg,
    grad,
    rad,
    turn,
    s,
    ms,
    hz,
    khz,
    dpi,
    dpcm,
    dppx,
    x,
    fr,
    unknown,

    pub fn baseDimension(self: Unit) ?BaseDimension {
        return switch (self) {
            .number => null,
            .percent => .percent,
            .px,
            .cm,
            .mm,
            .q,
            .in,
            .pc,
            .pt,
            .em,
            .rem,
            .ex,
            .rex,
            .cap,
            .rcap,
            .ch,
            .rch,
            .ic,
            .ric,
            .lh,
            .rlh,
            .vw,
            .vh,
            .vi,
            .vb,
            .vmin,
            .vmax,
            .svw,
            .svh,
            .svi,
            .svb,
            .svmin,
            .svmax,
            .lvw,
            .lvh,
            .lvi,
            .lvb,
            .lvmin,
            .lvmax,
            .dvw,
            .dvh,
            .dvi,
            .dvb,
            .dvmin,
            .dvmax,
            .cqw,
            .cqh,
            .cqi,
            .cqb,
            .cqmin,
            .cqmax,
            => .length,
            .deg, .grad, .rad, .turn => .angle,
            .s, .ms => .time,
            .hz, .khz => .frequency,
            .dpi, .dpcm, .dppx, .x => .resolution,
            .fr => .flex,
            .unknown => null,
        };
    }

    /// Static factor to the category's canonical unit: px, deg, s, hz, dppx,
    /// or fr. Context-dependent length units deliberately return null.
    pub fn canonicalScale(self: Unit) ?f64 {
        return switch (self) {
            .number, .percent, .px, .deg, .s, .hz, .dppx, .x, .fr => 1,
            .cm => 96.0 / 2.54,
            .mm => 96.0 / 25.4,
            .q => 96.0 / 101.6,
            .in => 96,
            .pc => 16,
            .pt => 96.0 / 72.0,
            .grad => 0.9,
            .rad => 180.0 / std.math.pi,
            .turn => 360,
            .ms => 0.001,
            .khz => 1000,
            .dpi => 1.0 / 96.0,
            .dpcm => 2.54 / 96.0,
            .em,
            .rem,
            .ex,
            .rex,
            .cap,
            .rcap,
            .ch,
            .rch,
            .ic,
            .ric,
            .lh,
            .rlh,
            .vw,
            .vh,
            .vi,
            .vb,
            .vmin,
            .vmax,
            .svw,
            .svh,
            .svi,
            .svb,
            .svmin,
            .svmax,
            .lvw,
            .lvh,
            .lvi,
            .lvb,
            .lvmin,
            .lvmax,
            .dvw,
            .dvh,
            .dvi,
            .dvb,
            .dvmin,
            .dvmax,
            .cqw,
            .cqh,
            .cqi,
            .cqb,
            .cqmin,
            .cqmax,
            .unknown,
            => null,
        };
    }
};

pub const LiteralKind = enum {
    numeric,
    e,
    pi,
    infinity,
    negative_infinity,
    nan,
    none,
};

pub const Literal = struct {
    kind: LiteralKind,
    value: f64,
    unit: Unit,
    number_type: ?tokenizer.NumberType,
    sign: tokenizer.Sign,
    representation: ?source.Span,
    unit_span: ?source.Span,
    span: source.Span,
    result_type: ResultType,
};

pub const Operator = struct {
    span: source.Span,
    result_type: ResultType,
};

pub const FunctionKind = enum {
    calc,
    min,
    max,
    clamp,
};

pub const Call = struct {
    kind: FunctionKind,
    argument_count: u32,
    span: source.Span,
    result_type: ResultType,
};

/// Postfix instructions preserve precedence without owning a pointer graph.
pub const Instruction = union(enum) {
    literal: Literal,
    add: Operator,
    subtract: Operator,
    multiply: Operator,
    divide: Operator,
    call: Call,
};

pub const Expression = struct {
    allocator: std.mem.Allocator,
    instructions: []const Instruction,
    span: source.Span,
    result_type: ResultType,

    pub fn deinit(self: *Expression) void {
        const allocator = self.allocator;
        if (self.instructions.len > 0) allocator.free(self.instructions);
        self.* = .{
            .allocator = allocator,
            .instructions = &.{},
            .span = .{ .source = self.span.source, .start = 0, .end = 0 },
            .result_type = .{ .invalid = .incompatible_types },
        };
    }

    pub fn isRepresentableNumeric(self: *const Expression) bool {
        return switch (self.result_type) {
            .valid => |value| value.isRepresentableNumeric(),
            else => false,
        };
    }
};

pub const Options = struct {
    percentage_hint: ?PercentHint = null,
    max_instructions: usize = 100_000,
    max_nesting: usize = 128,
    max_arguments: usize = 4096,
};

/// Parses one standalone number, percentage, dimension, or supported CSS math
/// function. Type-incompatible syntax returns an Expression with an invalid
/// result type; malformed, unsupported, unbounded, or foreign syntax fails.
/// The input component tree is never mutated and no value is folded or emitted.
pub fn parse(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    values: []const syntax.ComponentValue,
    options: Options,
) Error!Expression {
    try validateValues(file, values, 0, options.max_nesting, null);
    var instructions = try std.ArrayList(Instruction).initCapacity(allocator, 0);
    errdefer instructions.deinit(allocator);
    var parser = Parser{
        .allocator = allocator,
        .file = file,
        .values = values,
        .options = options,
        .instructions = &instructions,
    };
    const typed = try parser.parseRoot();
    const trailing = parser.triviaInfo(parser.cursor);
    if (trailing.index != values.len or typed.result_type == .none) return error.InvalidExpression;
    const owned = try instructions.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .instructions = owned,
        .span = typed.span,
        .result_type = typed.result_type,
    };
}

const Typed = struct {
    span: source.Span,
    result_type: ResultType,
};

const TriviaInfo = struct {
    index: usize,
    has_whitespace: bool,
};

const BinaryKind = enum {
    add,
    subtract,
    multiply,
    divide,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    values: []const syntax.ComponentValue,
    options: Options,
    instructions: *std.ArrayList(Instruction),
    cursor: usize = 0,

    fn parseRoot(self: *Parser) Error!Typed {
        const leading = self.triviaInfo(self.cursor);
        self.cursor = leading.index;
        if (self.cursor >= self.values.len) return error.InvalidExpression;
        const value = self.values[self.cursor];
        try self.validateSpan(value.span());
        self.cursor += 1;
        return switch (value) {
            .token => |token| switch (token.kind) {
                .number => try self.appendNumeric(token, .number),
                .percentage => try self.appendNumeric(token, .percent),
                .dimension => try self.appendDimension(token),
                else => error.UnsupportedSyntax,
            },
            .simple_block => error.UnsupportedSyntax,
            .function => |function| try self.parseFunction(function, 0),
        };
    }

    fn parseSum(self: *Parser, depth: usize) Error!Typed {
        var left = try self.parseProduct(depth);
        while (true) {
            const before = self.triviaInfo(self.cursor);
            const operator = self.delimiterAt(before.index) orelse return left;
            if (operator.value != '+' and operator.value != '-') return left;
            const after = self.triviaInfo(before.index + 1);
            if (!before.has_whitespace or !after.has_whitespace) return error.InvalidExpression;
            self.cursor = after.index;
            const right = try self.parseProduct(depth);
            const kind: BinaryKind = if (operator.value == '+') .add else .subtract;
            left = try self.appendBinary(kind, operator.span, left, right);
        }
    }

    fn parseProduct(self: *Parser, depth: usize) Error!Typed {
        var left = try self.parsePrimary(depth);
        while (true) {
            const before = self.triviaInfo(self.cursor);
            const operator = self.delimiterAt(before.index) orelse return left;
            if (operator.value != '*' and operator.value != '/') return left;
            const after = self.triviaInfo(before.index + 1);
            self.cursor = after.index;
            const right = try self.parsePrimary(depth);
            const kind: BinaryKind = if (operator.value == '*') .multiply else .divide;
            left = try self.appendBinary(kind, operator.span, left, right);
        }
    }

    fn parsePrimary(self: *Parser, depth: usize) Error!Typed {
        const leading = self.triviaInfo(self.cursor);
        self.cursor = leading.index;
        if (self.cursor >= self.values.len) return error.InvalidExpression;
        const value = self.values[self.cursor];
        try self.validateSpan(value.span());
        self.cursor += 1;
        return switch (value) {
            .token => |token| try self.parseToken(token),
            .simple_block => |block| try self.parseParentheses(block, depth),
            .function => |function| try self.parseFunction(function, depth),
        };
    }

    fn parseToken(self: *Parser, token: tokenizer.Token) Error!Typed {
        return switch (token.kind) {
            .number => try self.appendNumeric(token, .number),
            .percentage => try self.appendNumeric(token, .percent),
            .dimension => try self.appendDimension(token),
            .ident => try self.appendKeyword(token),
            else => error.UnsupportedSyntax,
        };
    }

    fn appendNumeric(self: *Parser, token: tokenizer.Token, unit: Unit) Error!Typed {
        const numeric = switch (token.data) {
            .numeric => |value| value,
            else => return error.InvalidExpression,
        };
        const result_type: ResultType = .{ .valid = if (unit == .number)
            CalcType.number()
        else
            CalcType.percentage(self.options.percentage_hint) };
        const literal = Literal{
            .kind = .numeric,
            .value = numeric.value,
            .unit = unit,
            .number_type = numeric.number_type,
            .sign = numeric.sign,
            .representation = numeric.representation,
            .unit_span = null,
            .span = token.span,
            .result_type = result_type,
        };
        try self.appendInstruction(.{ .literal = literal });
        return .{ .span = token.span, .result_type = result_type };
    }

    fn appendDimension(self: *Parser, token: tokenizer.Token) Error!Typed {
        const dimension = switch (token.data) {
            .dimension => |value| value,
            else => return error.InvalidExpression,
        };
        const decoded = try self.decodeText(token);
        defer self.allocator.free(decoded);
        const unit = classifyUnit(decoded);
        const result_type: ResultType = if (unit.baseDimension()) |base|
            .{ .valid = CalcType.dimension(base) }
        else
            .{ .invalid = .unknown_unit };
        const literal = Literal{
            .kind = .numeric,
            .value = dimension.numeric.value,
            .unit = unit,
            .number_type = dimension.numeric.number_type,
            .sign = dimension.numeric.sign,
            .representation = dimension.numeric.representation,
            .unit_span = dimension.unit,
            .span = token.span,
            .result_type = result_type,
        };
        try self.appendInstruction(.{ .literal = literal });
        return .{ .span = token.span, .result_type = result_type };
    }

    fn appendKeyword(self: *Parser, token: tokenizer.Token) Error!Typed {
        const decoded = try self.decodeText(token);
        defer self.allocator.free(decoded);
        const kind: LiteralKind = if (std.ascii.eqlIgnoreCase(decoded, "e"))
            .e
        else if (std.ascii.eqlIgnoreCase(decoded, "pi"))
            .pi
        else if (std.ascii.eqlIgnoreCase(decoded, "infinity"))
            .infinity
        else if (std.ascii.eqlIgnoreCase(decoded, "-infinity"))
            .negative_infinity
        else if (std.ascii.eqlIgnoreCase(decoded, "nan"))
            .nan
        else
            return error.UnsupportedSyntax;
        const result_type: ResultType = .{ .valid = CalcType.number() };
        const literal = Literal{
            .kind = kind,
            .value = switch (kind) {
                .e => std.math.e,
                .pi => std.math.pi,
                .infinity => std.math.inf(f64),
                .negative_infinity => -std.math.inf(f64),
                .nan => std.math.nan(f64),
                .none => 0,
                .numeric => unreachable,
            },
            .unit = .number,
            .number_type = null,
            .sign = .none,
            .representation = token.valueSpan(),
            .unit_span = null,
            .span = token.span,
            .result_type = result_type,
        };
        try self.appendInstruction(.{ .literal = literal });
        return .{ .span = token.span, .result_type = result_type };
    }

    fn parseParentheses(self: *Parser, block: *const syntax.SimpleBlock, depth: usize) Error!Typed {
        if (block.opening.kind != .open_paren) return error.UnsupportedSyntax;
        if (!block.terminated()) return error.UnterminatedSyntax;
        const next_depth = try self.nextDepth(depth);
        var child = Parser{
            .allocator = self.allocator,
            .file = self.file,
            .values = block.values,
            .options = self.options,
            .instructions = self.instructions,
        };
        const result = try child.parseSum(next_depth);
        if (child.triviaInfo(child.cursor).index != child.values.len or result.result_type == .none) {
            return error.InvalidExpression;
        }
        return .{ .span = block.span, .result_type = result.result_type };
    }

    fn parseFunction(self: *Parser, function: *const syntax.Function, depth: usize) Error!Typed {
        if (!function.terminated()) return error.UnterminatedSyntax;
        const decoded = try self.decodeText(function.opening);
        defer self.allocator.free(decoded);
        const kind: FunctionKind = if (std.ascii.eqlIgnoreCase(decoded, "calc"))
            .calc
        else if (std.ascii.eqlIgnoreCase(decoded, "min"))
            .min
        else if (std.ascii.eqlIgnoreCase(decoded, "max"))
            .max
        else if (std.ascii.eqlIgnoreCase(decoded, "clamp"))
            .clamp
        else
            return error.UnsupportedSyntax;

        const next_depth = try self.nextDepth(depth);
        var child = Parser{
            .allocator = self.allocator,
            .file = self.file,
            .values = function.values,
            .options = self.options,
            .instructions = self.instructions,
        };
        var arguments: [3]ResultType = undefined;
        var argument_count: usize = 0;
        var combined: ?ResultType = null;
        while (true) {
            const leading = child.triviaInfo(child.cursor);
            if (leading.index == child.values.len) break;
            child.cursor = leading.index;
            if (argument_count >= self.options.max_arguments) return error.ArgumentLimit;
            const argument = if (kind == .clamp and
                (argument_count == 0 or argument_count == 2))
                (try child.parseClampNone()) orelse try child.parseSum(next_depth)
            else
                try child.parseSum(next_depth);
            if (kind == .clamp and argument_count < arguments.len) {
                arguments[argument_count] = argument.result_type;
            }
            argument_count = std.math.add(usize, argument_count, 1) catch {
                return error.ArgumentLimit;
            };
            if (kind != .clamp) {
                if (argument.result_type == .none) return error.InvalidExpression;
                combined = if (combined) |current|
                    addResults(current, argument.result_type)
                else
                    argument.result_type;
            }

            const trailing = child.triviaInfo(child.cursor);
            if (trailing.index == child.values.len) {
                child.cursor = trailing.index;
                break;
            }
            if (!isTokenKind(child.values[trailing.index], .comma)) return error.InvalidExpression;
            child.cursor = trailing.index + 1;
            if (child.triviaInfo(child.cursor).index == child.values.len) return error.InvalidExpression;
        }

        if (argument_count == 0 or argument_count > std.math.maxInt(u32)) {
            return error.InvalidExpression;
        }
        const result_type: ResultType = switch (kind) {
            .calc => blk: {
                if (argument_count != 1) return error.InvalidExpression;
                if (combined.? == .none) return error.InvalidExpression;
                break :blk combined.?;
            },
            .min, .max => combined.?,
            .clamp => blk: {
                if (argument_count != 3 or arguments[1] == .none) return error.InvalidExpression;
                var result = arguments[1];
                if (arguments[0] != .none) result = addResults(result, arguments[0]);
                if (arguments[2] != .none) result = addResults(result, arguments[2]);
                break :blk result;
            },
        };
        const call = Call{
            .kind = kind,
            .argument_count = @intCast(argument_count),
            .span = function.span,
            .result_type = result_type,
        };
        try self.appendInstruction(.{ .call = call });
        return .{ .span = function.span, .result_type = result_type };
    }

    fn parseClampNone(self: *Parser) Error!?Typed {
        if (self.cursor >= self.values.len) return null;
        const token = switch (self.values[self.cursor]) {
            .token => |value| value,
            else => return null,
        };
        if (token.kind != .ident) return null;
        const decoded = try self.decodeText(token);
        defer self.allocator.free(decoded);
        if (!std.ascii.eqlIgnoreCase(decoded, "none")) return null;

        self.cursor += 1;
        const result_type: ResultType = .none;
        try self.appendInstruction(.{ .literal = .{
            .kind = .none,
            .value = 0,
            .unit = .number,
            .number_type = null,
            .sign = .none,
            .representation = token.valueSpan(),
            .unit_span = null,
            .span = token.span,
            .result_type = result_type,
        } });
        return .{ .span = token.span, .result_type = result_type };
    }

    fn appendBinary(
        self: *Parser,
        kind: BinaryKind,
        operator_span: source.Span,
        left: Typed,
        right: Typed,
    ) Error!Typed {
        const result_type = switch (kind) {
            .add, .subtract => addResults(left.result_type, right.result_type),
            .multiply => multiplyResults(left.result_type, right.result_type, false),
            .divide => multiplyResults(left.result_type, right.result_type, true),
        };
        const operator = Operator{ .span = operator_span, .result_type = result_type };
        try self.appendInstruction(switch (kind) {
            .add => .{ .add = operator },
            .subtract => .{ .subtract = operator },
            .multiply => .{ .multiply = operator },
            .divide => .{ .divide = operator },
        });
        return .{
            .span = try mergeSpan(left.span, right.span),
            .result_type = result_type,
        };
    }

    fn appendInstruction(self: *Parser, instruction: Instruction) Error!void {
        if (self.instructions.items.len >= self.options.max_instructions) {
            return error.InstructionLimit;
        }
        try self.instructions.append(self.allocator, instruction);
    }

    fn nextDepth(self: *const Parser, depth: usize) Error!usize {
        if (depth >= self.options.max_nesting) return error.NestingLimit;
        return std.math.add(usize, depth, 1) catch return error.NestingLimit;
    }

    fn triviaInfo(self: *const Parser, start: usize) TriviaInfo {
        var index = start;
        var has_whitespace = false;
        while (index < self.values.len) : (index += 1) {
            const token = switch (self.values[index]) {
                .token => |value| value,
                else => break,
            };
            if (!token.isTrivia()) break;
            has_whitespace = has_whitespace or token.kind == .whitespace;
        }
        return .{ .index = index, .has_whitespace = has_whitespace };
    }

    fn delimiterAt(self: *const Parser, index: usize) ?struct { value: u21, span: source.Span } {
        if (index >= self.values.len) return null;
        const token = switch (self.values[index]) {
            .token => |value| value,
            else => return null,
        };
        if (token.kind != .delim) return null;
        const value = switch (token.data) {
            .delim => |delimiter| delimiter,
            else => return null,
        };
        return .{ .value = value, .span = token.span };
    }

    fn validateSpan(self: *const Parser, span: source.Span) Error!void {
        if (!span.source.eql(self.file.id)) return error.SourceMismatch;
        if (span.start > span.end or span.end > self.file.bytes.len) return error.InvalidSpan;
    }

    fn decodeText(self: *const Parser, token: tokenizer.Token) Error![]u8 {
        return token.decodedTextAlloc(self.allocator, self.file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SourceMismatch => return error.SourceMismatch,
            else => return error.InvalidExpression,
        };
    }
};

fn addResults(left: ResultType, right: ResultType) ResultType {
    const left_type = switch (left) {
        .valid => |value| value,
        .invalid => |reason| return .{ .invalid = reason },
        .none => return .{ .invalid = .none_in_arithmetic },
    };
    const right_type = switch (right) {
        .valid => |value| value,
        .invalid => |reason| return .{ .invalid = reason },
        .none => return .{ .invalid = .none_in_arithmetic },
    };
    return addTypes(left_type, right_type);
}

fn addTypes(left_input: CalcType, right_input: CalcType) ResultType {
    var left = left_input;
    var right = right_input;
    if (left.percent_hint != null and right.percent_hint != null and
        left.percent_hint != right.percent_hint)
    {
        return .{ .invalid = .conflicting_percent_hints };
    }
    if (left.percent_hint) |hint| {
        if (right.percent_hint == null) applyPercentHint(&right, hint) catch |reason| {
            return .{ .invalid = typeOperationReason(reason) };
        };
    } else if (right.percent_hint) |hint| {
        applyPercentHint(&left, hint) catch |reason| {
            return .{ .invalid = typeOperationReason(reason) };
        };
    }
    if (exponentsEqual(left, right)) {
        left.percent_hint = left.percent_hint orelse right.percent_hint;
        return .{ .valid = left };
    }

    if (containsPercent(left, right) and containsNonPercent(left, right)) {
        const hints = [_]PercentHint{ .length, .angle, .time, .frequency, .resolution, .flex };
        for (hints) |hint| {
            var provisional_left = left;
            var provisional_right = right;
            applyPercentHint(&provisional_left, hint) catch continue;
            applyPercentHint(&provisional_right, hint) catch continue;
            if (exponentsEqual(provisional_left, provisional_right)) {
                provisional_left.percent_hint = hint;
                return .{ .valid = provisional_left };
            }
        }
    }
    return .{ .invalid = .incompatible_types };
}

fn multiplyResults(left: ResultType, right: ResultType, invert_right: bool) ResultType {
    const left_type = switch (left) {
        .valid => |value| value,
        .invalid => |reason| return .{ .invalid = reason },
        .none => return .{ .invalid = .none_in_arithmetic },
    };
    var right_type = switch (right) {
        .valid => |value| value,
        .invalid => |reason| return .{ .invalid = reason },
        .none => return .{ .invalid = .none_in_arithmetic },
    };
    if (invert_right) {
        right_type = invertType(right_type) catch |reason| {
            return .{ .invalid = typeOperationReason(reason) };
        };
    }
    return multiplyTypes(left_type, right_type);
}

fn multiplyTypes(left_input: CalcType, right_input: CalcType) ResultType {
    var left = left_input;
    var right = right_input;
    if (left.percent_hint != null and right.percent_hint != null and
        left.percent_hint != right.percent_hint)
    {
        return .{ .invalid = .conflicting_percent_hints };
    }
    if (left.percent_hint) |hint| {
        if (right.percent_hint == null) applyPercentHint(&right, hint) catch |reason| {
            return .{ .invalid = typeOperationReason(reason) };
        };
    } else if (right.percent_hint) |hint| {
        applyPercentHint(&left, hint) catch |reason| {
            return .{ .invalid = typeOperationReason(reason) };
        };
    }

    var result = CalcType{ .percent_hint = left.percent_hint orelse right.percent_hint };
    for (&result.exponents, left.exponents, right.exponents) |*output, left_value, right_value| {
        output.* = std.math.add(i8, left_value, right_value) catch {
            return .{ .invalid = .exponent_overflow };
        };
    }
    return .{ .valid = result };
}

fn invertType(input: CalcType) TypeOperationError!CalcType {
    var result = input;
    for (&result.exponents, input.exponents) |*output, value| {
        output.* = std.math.negate(value) catch return error.ExponentOverflow;
    }
    return result;
}

fn applyPercentHint(input: *CalcType, hint: PercentHint) TypeOperationError!void {
    if (input.percent_hint != null and input.percent_hint != hint) {
        return error.ConflictingPercentHints;
    }
    const percent_index = @intFromEnum(BaseDimension.percent);
    const hint_index = @intFromEnum(hintBase(hint));
    input.exponents[hint_index] = std.math.add(
        i8,
        input.exponents[hint_index],
        input.exponents[percent_index],
    ) catch return error.ExponentOverflow;
    input.exponents[percent_index] = 0;
    input.percent_hint = hint;
}

fn typeOperationReason(reason: TypeOperationError) TypeError {
    return switch (reason) {
        error.ConflictingPercentHints => .conflicting_percent_hints,
        error.ExponentOverflow => .exponent_overflow,
    };
}

fn containsPercent(left: CalcType, right: CalcType) bool {
    return left.exponent(.percent) != 0 or right.exponent(.percent) != 0;
}

fn containsNonPercent(left: CalcType, right: CalcType) bool {
    const percent_index = @intFromEnum(BaseDimension.percent);
    for (left.exponents, 0..) |value, index| {
        if (index != percent_index and value != 0) return true;
    }
    for (right.exponents, 0..) |value, index| {
        if (index != percent_index and value != 0) return true;
    }
    return false;
}

fn exponentsEqual(left: CalcType, right: CalcType) bool {
    return std.mem.eql(i8, &left.exponents, &right.exponents);
}

fn hintBase(hint: PercentHint) BaseDimension {
    return switch (hint) {
        .length => .length,
        .angle => .angle,
        .time => .time,
        .frequency => .frequency,
        .resolution => .resolution,
        .flex => .flex,
    };
}

fn classifyUnit(unit: []const u8) Unit {
    inline for (unit_table) |entry| {
        if (std.ascii.eqlIgnoreCase(unit, entry.name)) return entry.unit;
    }
    return .unknown;
}

const unit_table = [_]struct { name: []const u8, unit: Unit }{
    .{ .name = "px", .unit = .px },
    .{ .name = "cm", .unit = .cm },
    .{ .name = "mm", .unit = .mm },
    .{ .name = "q", .unit = .q },
    .{ .name = "in", .unit = .in },
    .{ .name = "pc", .unit = .pc },
    .{ .name = "pt", .unit = .pt },
    .{ .name = "em", .unit = .em },
    .{ .name = "rem", .unit = .rem },
    .{ .name = "ex", .unit = .ex },
    .{ .name = "rex", .unit = .rex },
    .{ .name = "cap", .unit = .cap },
    .{ .name = "rcap", .unit = .rcap },
    .{ .name = "ch", .unit = .ch },
    .{ .name = "rch", .unit = .rch },
    .{ .name = "ic", .unit = .ic },
    .{ .name = "ric", .unit = .ric },
    .{ .name = "lh", .unit = .lh },
    .{ .name = "rlh", .unit = .rlh },
    .{ .name = "vw", .unit = .vw },
    .{ .name = "vh", .unit = .vh },
    .{ .name = "vi", .unit = .vi },
    .{ .name = "vb", .unit = .vb },
    .{ .name = "vmin", .unit = .vmin },
    .{ .name = "vmax", .unit = .vmax },
    .{ .name = "svw", .unit = .svw },
    .{ .name = "svh", .unit = .svh },
    .{ .name = "svi", .unit = .svi },
    .{ .name = "svb", .unit = .svb },
    .{ .name = "svmin", .unit = .svmin },
    .{ .name = "svmax", .unit = .svmax },
    .{ .name = "lvw", .unit = .lvw },
    .{ .name = "lvh", .unit = .lvh },
    .{ .name = "lvi", .unit = .lvi },
    .{ .name = "lvb", .unit = .lvb },
    .{ .name = "lvmin", .unit = .lvmin },
    .{ .name = "lvmax", .unit = .lvmax },
    .{ .name = "dvw", .unit = .dvw },
    .{ .name = "dvh", .unit = .dvh },
    .{ .name = "dvi", .unit = .dvi },
    .{ .name = "dvb", .unit = .dvb },
    .{ .name = "dvmin", .unit = .dvmin },
    .{ .name = "dvmax", .unit = .dvmax },
    .{ .name = "cqw", .unit = .cqw },
    .{ .name = "cqh", .unit = .cqh },
    .{ .name = "cqi", .unit = .cqi },
    .{ .name = "cqb", .unit = .cqb },
    .{ .name = "cqmin", .unit = .cqmin },
    .{ .name = "cqmax", .unit = .cqmax },
    .{ .name = "deg", .unit = .deg },
    .{ .name = "grad", .unit = .grad },
    .{ .name = "rad", .unit = .rad },
    .{ .name = "turn", .unit = .turn },
    .{ .name = "s", .unit = .s },
    .{ .name = "ms", .unit = .ms },
    .{ .name = "hz", .unit = .hz },
    .{ .name = "khz", .unit = .khz },
    .{ .name = "dpi", .unit = .dpi },
    .{ .name = "dpcm", .unit = .dpcm },
    .{ .name = "dppx", .unit = .dppx },
    .{ .name = "x", .unit = .x },
    .{ .name = "fr", .unit = .fr },
};

fn isTokenKind(value: syntax.ComponentValue, kind: tokenizer.TokenKind) bool {
    return switch (value) {
        .token => |token| token.kind == kind,
        else => false,
    };
}

fn validateValues(
    file: *const source.SourceFile,
    values: []const syntax.ComponentValue,
    depth: usize,
    max_depth: usize,
    parent: ?source.Span,
) Error!void {
    var previous_end: ?usize = null;
    for (values) |value| {
        const span = value.span();
        try validateSourceSpan(file, span);
        if (parent) |parent_span| {
            if (!parent_span.source.eql(span.source) or
                span.start < parent_span.start or span.end > parent_span.end)
            {
                return error.InvalidSpan;
            }
        }
        if (previous_end) |end| {
            if (span.start != end) return error.InvalidSpan;
        }
        previous_end = span.end;

        switch (value) {
            .token => |token| try validateToken(file, token),
            .simple_block => |block| {
                if (depth >= max_depth) return error.NestingLimit;
                const closing = block.closing orelse return error.UnterminatedSyntax;
                try validateSourceSpan(file, block.opening.span);
                try validateSourceSpan(file, closing.span);
                if (block.opening.kind != .open_curly and
                    block.opening.kind != .open_square and
                    block.opening.kind != .open_paren)
                {
                    return error.InvalidExpression;
                }
                if (closing.kind != block.expectedClosing()) return error.InvalidExpression;
                if (block.span.start != block.opening.span.start or
                    block.opening.span.end > closing.span.start or
                    block.span.end != closing.span.end)
                {
                    return error.InvalidSpan;
                }
                try validateValues(
                    file,
                    block.values,
                    depth + 1,
                    max_depth,
                    .{
                        .source = file.id,
                        .start = block.opening.span.end,
                        .end = closing.span.start,
                    },
                );
            },
            .function => |function| {
                if (depth >= max_depth) return error.NestingLimit;
                const closing = function.closing orelse return error.UnterminatedSyntax;
                try validateSourceSpan(file, function.opening.span);
                try validateSourceSpan(file, closing.span);
                if (function.opening.kind != .function or closing.kind != .close_paren) {
                    return error.InvalidExpression;
                }
                if (function.span.start != function.opening.span.start or
                    function.opening.span.end > closing.span.start or
                    function.span.end != closing.span.end)
                {
                    return error.InvalidSpan;
                }
                try validateValues(
                    file,
                    function.values,
                    depth + 1,
                    max_depth,
                    .{
                        .source = file.id,
                        .start = function.opening.span.end,
                        .end = closing.span.start,
                    },
                );
            },
        }
    }

    if (parent) |parent_span| {
        if (values.len == 0) {
            if (!parent_span.isEmpty()) return error.InvalidSpan;
        } else if (values[0].span().start != parent_span.start or
            values[values.len - 1].span().end != parent_span.end)
        {
            return error.InvalidSpan;
        }
    }
}

fn validateToken(file: *const source.SourceFile, token: tokenizer.Token) Error!void {
    try validateSourceSpan(file, token.span);
    if (!token.isTerminated()) return error.UnterminatedSyntax;

    switch (token.data) {
        .text => |span| try validateContainedSpan(file, token.span, span),
        .hash => |hash| try validateContainedSpan(file, token.span, hash.value),
        .numeric => |numeric| try validateContainedSpan(file, token.span, numeric.representation),
        .dimension => |dimension| {
            try validateContainedSpan(file, token.span, dimension.numeric.representation);
            try validateContainedSpan(file, token.span, dimension.unit);
            if (dimension.numeric.representation.start != token.span.start or
                dimension.numeric.representation.end != dimension.unit.start or
                dimension.unit.end != token.span.end)
            {
                return error.InvalidSpan;
            }
        },
        .comment => |comment| try validateContainedSpan(file, token.span, comment.content),
        .none, .delim, .unicode_range => {},
    }
}

fn validateContainedSpan(
    file: *const source.SourceFile,
    container: source.Span,
    child: source.Span,
) Error!void {
    try validateSourceSpan(file, child);
    if (!container.source.eql(child.source) or
        child.start < container.start or child.end > container.end)
    {
        return error.InvalidSpan;
    }
}

fn validateSourceSpan(file: *const source.SourceFile, span: source.Span) Error!void {
    if (!span.source.eql(file.id)) return error.SourceMismatch;
    if (span.start > span.end or span.end > file.bytes.len) return error.InvalidSpan;
}

fn mergeSpan(left: source.Span, right: source.Span) Error!source.Span {
    if (!left.source.eql(right.source)) return error.SourceMismatch;
    if (left.start > left.end or right.start > right.end) return error.InvalidSpan;
    return .{
        .source = left.source,
        .start = @min(left.start, right.start),
        .end = @max(left.end, right.end),
    };
}

const pipeline = @import("pipeline.zig");

fn parseTestDeclaration(
    allocator: std.mem.Allocator,
    parsed: *const pipeline.ParsedStylesheet,
    index: usize,
    options: Options,
) !Expression {
    const declaration = parsed.rules.rules[0].style_rule.block.declarations.declarations[index];
    return parse(allocator, parsed.file(), declaration.valueWithoutImportance(), options);
}

test "numeric values classify current CSS units and static canonical scales" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "units.css",
        ".a{a:2.54cm;b:1PX;c:1rex;d:1rcap;e:1rch;f:1ric;g:1dvh;h:1cqmin;" ++
            "i:1turn;j:1000ms;k:1kHz;l:96dpi;m:1x;n:1fr;o:50%;p:1}",
    );
    defer parsed.deinit();
    const expected = [_]Unit{
        .cm,   .px, .rex, .rcap, .rch, .ric, .dvh,     .cqmin,
        .turn, .ms, .khz, .dpi,  .x,   .fr,  .percent, .number,
    };
    for (expected, 0..) |unit, index| {
        var expression = try parseTestDeclaration(std.testing.allocator, &parsed, index, .{});
        defer expression.deinit();
        try std.testing.expectEqual(@as(usize, 1), expression.instructions.len);
        try std.testing.expectEqual(unit, expression.instructions[0].literal.unit);
    }

    try std.testing.expectApproxEqAbs(@as(f64, 96), Unit.cm.canonicalScale().? * 2.54, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 360), Unit.turn.canonicalScale().?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1), Unit.ms.canonicalScale().? * 1000, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1), Unit.dpi.canonicalScale().? * 96, 0.000001);
    try std.testing.expect(Unit.rex.canonicalScale() == null);

    try std.testing.expectEqual(std.meta.fields(Unit).len, unit_table.len + 3);
    for (unit_table, 0..) |entry, index| {
        try std.testing.expectEqual(entry.unit, classifyUnit(entry.name));
        try std.testing.expect(entry.unit.baseDimension() != null);
        for (unit_table[index + 1 ..]) |other| {
            try std.testing.expect(!std.ascii.eqlIgnoreCase(entry.name, other.name));
            try std.testing.expect(entry.unit != other.unit);
        }
    }

    for (std.meta.tags(PercentHint)) |hint| {
        var expression = try parseTestDeclaration(
            std.testing.allocator,
            &parsed,
            14,
            .{ .percentage_hint = hint },
        );
        defer expression.deinit();
        try std.testing.expectEqual(hint, expression.result_type.valid.percent_hint.?);
        try std.testing.expectEqual(@as(i8, 1), expression.result_type.valid.exponent(hintBase(hint)));
        try std.testing.expectEqual(@as(i8, 0), expression.result_type.valid.exponent(.percent));
    }
}

test "calc parsing preserves multiplication precedence and left associative sums" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "precedence.css",
        ".a{x:calc(1px + 2px * 3 - 4px / 2)}",
    );
    defer parsed.deinit();
    var expression = try parseTestDeclaration(std.testing.allocator, &parsed, 0, .{});
    defer expression.deinit();
    const Tag = std.meta.Tag(Instruction);
    const expected = [_]Tag{
        .literal,
        .literal,
        .literal,
        .multiply,
        .add,
        .literal,
        .literal,
        .divide,
        .subtract,
        .call,
    };
    try std.testing.expectEqual(expected.len, expression.instructions.len);
    for (expected, expression.instructions) |tag, instruction| {
        try std.testing.expectEqual(tag, std.meta.activeTag(instruction));
    }
    try std.testing.expect(expression.isRepresentableNumeric());
    try std.testing.expectEqual(@as(i8, 1), expression.result_type.valid.exponent(.length));
}

test "type algebra applies percentage hints and retains compound intermediates" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "types.css",
        ".a{a:calc(1px + 5%);b:calc(1 + 5%);c:calc(1s + 1px);" ++
            "d:calc(1px / 1s);e:calc((1px / 1s) * 1s);f:calc(10% + 20%);" ++
            "g:calc(1px / 1%)}",
    );
    defer parsed.deinit();

    var length_percent = try parseTestDeclaration(std.testing.allocator, &parsed, 0, .{});
    defer length_percent.deinit();
    try std.testing.expectEqual(PercentHint.length, length_percent.result_type.valid.percent_hint.?);
    try std.testing.expectEqual(@as(i8, 1), length_percent.result_type.valid.exponent(.length));

    var number_percent = try parseTestDeclaration(std.testing.allocator, &parsed, 1, .{});
    defer number_percent.deinit();
    try std.testing.expectEqual(TypeError.incompatible_types, number_percent.result_type.invalid);

    var incompatible = try parseTestDeclaration(std.testing.allocator, &parsed, 2, .{});
    defer incompatible.deinit();
    try std.testing.expectEqual(TypeError.incompatible_types, incompatible.result_type.invalid);

    var compound = try parseTestDeclaration(std.testing.allocator, &parsed, 3, .{});
    defer compound.deinit();
    try std.testing.expectEqual(@as(i8, 1), compound.result_type.valid.exponent(.length));
    try std.testing.expectEqual(@as(i8, -1), compound.result_type.valid.exponent(.time));
    try std.testing.expect(!compound.isRepresentableNumeric());

    var reduced = try parseTestDeclaration(std.testing.allocator, &parsed, 4, .{});
    defer reduced.deinit();
    try std.testing.expectEqual(@as(i8, 1), reduced.result_type.valid.exponent(.length));
    try std.testing.expect(reduced.isRepresentableNumeric());

    var percentages = try parseTestDeclaration(std.testing.allocator, &parsed, 5, .{});
    defer percentages.deinit();
    try std.testing.expectEqual(@as(i8, 1), percentages.result_type.valid.exponent(.percent));
    try std.testing.expect(percentages.result_type.valid.percent_hint == null);

    var hinted_number = try parseTestDeclaration(
        std.testing.allocator,
        &parsed,
        6,
        .{ .percentage_hint = .length },
    );
    defer hinted_number.deinit();
    try std.testing.expect(!hinted_number.result_type.valid.isNumber());
    try std.testing.expect(hinted_number.result_type.valid.isRepresentableNumeric());
    try std.testing.expectEqual(PercentHint.length, hinted_number.result_type.valid.percent_hint.?);
    for (hinted_number.result_type.valid.exponents) |exponent_value| {
        try std.testing.expectEqual(@as(i8, 0), exponent_value);
    }
}

test "min max clamp constants and none endpoints retain typed arguments" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "functions.css",
        ".a{a:min(1px,2em + 3px);b:max(1s,2px);c:clamp(none,2px,10%);" ++
            "d:calc(pi * 1rad);e:calc(infinity * 1px);f:calc(NaN)}",
    );
    var first = try parseTestDeclaration(std.testing.allocator, &parsed, 0, .{});
    defer first.deinit();
    try std.testing.expectEqual(@as(i8, 1), first.result_type.valid.exponent(.length));

    var second = try parseTestDeclaration(std.testing.allocator, &parsed, 1, .{});
    defer second.deinit();
    try std.testing.expectEqual(TypeError.incompatible_types, second.result_type.invalid);

    var clamp = try parseTestDeclaration(std.testing.allocator, &parsed, 2, .{});
    defer clamp.deinit();
    try std.testing.expectEqual(PercentHint.length, clamp.result_type.valid.percent_hint.?);

    var pi = try parseTestDeclaration(std.testing.allocator, &parsed, 3, .{});
    defer pi.deinit();
    try std.testing.expectEqual(LiteralKind.pi, pi.instructions[0].literal.kind);
    try std.testing.expectEqual(@as(i8, 1), pi.result_type.valid.exponent(.angle));

    var infinity = try parseTestDeclaration(std.testing.allocator, &parsed, 4, .{});
    defer infinity.deinit();
    try std.testing.expectEqual(LiteralKind.infinity, infinity.instructions[0].literal.kind);
    try std.testing.expect(std.math.isInf(infinity.instructions[0].literal.value));

    var nan = try parseTestDeclaration(std.testing.allocator, &parsed, 5, .{});
    parsed.deinit();
    defer nan.deinit();
    try std.testing.expectEqual(LiteralKind.nan, nan.instructions[0].literal.kind);
    try std.testing.expect(std.math.isNan(nan.instructions[0].literal.value));
}

test "unknown units escaped units and calc whitespace fail conservatively" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "invalid-values.css",
        ".a{a:1furlong;b:1\\70x;c:calc(1px/**/+/**/2px);" ++
            "d:calc(1px /*x*/ + /*y*/ 2px);e:var(--x);f:clamp(1px,2px)}",
    );
    defer parsed.deinit();

    var unknown = try parseTestDeclaration(std.testing.allocator, &parsed, 0, .{});
    defer unknown.deinit();
    try std.testing.expectEqual(Unit.unknown, unknown.instructions[0].literal.unit);
    try std.testing.expectEqual(TypeError.unknown_unit, unknown.result_type.invalid);

    var escaped = try parseTestDeclaration(std.testing.allocator, &parsed, 1, .{});
    defer escaped.deinit();
    try std.testing.expectEqual(Unit.px, escaped.instructions[0].literal.unit);

    try std.testing.expectError(
        error.InvalidExpression,
        parseTestDeclaration(std.testing.allocator, &parsed, 2, .{}),
    );
    var comments_with_space = try parseTestDeclaration(std.testing.allocator, &parsed, 3, .{});
    defer comments_with_space.deinit();
    try std.testing.expect(comments_with_space.isRepresentableNumeric());
    try std.testing.expectError(
        error.UnsupportedSyntax,
        parseTestDeclaration(std.testing.allocator, &parsed, 4, .{}),
    );
    try std.testing.expectError(
        error.InvalidExpression,
        parseTestDeclaration(std.testing.allocator, &parsed, 5, .{}),
    );
}

test "calculation-only atoms cannot escape a math function" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "root-grammar.css",
        ".a{a:pi;b:(1px);c:1px + 2px;d:calc(pi * 1px);e:1px}",
    );
    defer parsed.deinit();

    try std.testing.expectError(
        error.UnsupportedSyntax,
        parseTestDeclaration(std.testing.allocator, &parsed, 0, .{}),
    );
    try std.testing.expectError(
        error.UnsupportedSyntax,
        parseTestDeclaration(std.testing.allocator, &parsed, 1, .{}),
    );
    try std.testing.expectError(
        error.InvalidExpression,
        parseTestDeclaration(std.testing.allocator, &parsed, 2, .{}),
    );
    var calculated = try parseTestDeclaration(std.testing.allocator, &parsed, 3, .{});
    defer calculated.deinit();
    try std.testing.expect(calculated.isRepresentableNumeric());
    var plain = try parseTestDeclaration(std.testing.allocator, &parsed, 4, .{});
    defer plain.deinit();
    try std.testing.expect(plain.isRepresentableNumeric());
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var parsed = try pipeline.parse(
        allocator,
        "numeric-oom.css",
        ".a{x:clamp(1px,calc(2em + 3px * 4),max(5%,6px))}",
    );
    defer parsed.deinit();
    var expression = try parseTestDeclaration(allocator, &parsed, 0, .{});
    defer expression.deinit();
    try std.testing.expect(expression.instructions.len > 0);
}

test "numeric parsing enforces resource limits and handles every allocation failure" {
    var parsed = try pipeline.parse(std.testing.allocator, "limits.css", ".a{x:calc((1px + 2px) * 3)}");
    defer parsed.deinit();
    try std.testing.expectError(
        error.InstructionLimit,
        parseTestDeclaration(std.testing.allocator, &parsed, 0, .{ .max_instructions = 2 }),
    );
    try std.testing.expectError(
        error.NestingLimit,
        parseTestDeclaration(std.testing.allocator, &parsed, 0, .{ .max_nesting = 0 }),
    );
    try std.testing.expectError(
        error.ArgumentLimit,
        parseTestDeclaration(std.testing.allocator, &parsed, 0, .{ .max_arguments = 0 }),
    );

    var overflow = try pipeline.parse(
        std.testing.allocator,
        "overflow.css",
        ".a{x:calc(" ++ ("1px*" ** 128) ++ "1px)}",
    );
    defer overflow.deinit();
    var overflow_expression = try parseTestDeclaration(std.testing.allocator, &overflow, 0, .{});
    defer overflow_expression.deinit();
    try std.testing.expectEqual(TypeError.exponent_overflow, overflow_expression.result_type.invalid);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

test "numeric parsing rejects foreign malformed and unterminated component trees" {
    var parsed = try pipeline.parse(std.testing.allocator, "source.css", ".a{x:calc(1px + 2px)}");
    defer parsed.deinit();
    const declaration = parsed.rules.rules[0].style_rule.block.declarations.declarations[0];

    var foreign_file = parsed.file().*;
    foreign_file.id.value += 1;
    try std.testing.expectError(
        error.SourceMismatch,
        parse(
            std.testing.allocator,
            &foreign_file,
            declaration.valueWithoutImportance(),
            .{},
        ),
    );

    var short_file = parsed.file().*;
    short_file.bytes = short_file.bytes[0..1];
    try std.testing.expectError(
        error.InvalidSpan,
        parse(
            std.testing.allocator,
            &short_file,
            declaration.valueWithoutImportance(),
            .{},
        ),
    );

    var unterminated = try pipeline.parse(std.testing.allocator, "unterminated.css", ".a{x:calc(1px");
    defer unterminated.deinit();
    try std.testing.expectError(
        error.UnterminatedSyntax,
        parseTestDeclaration(std.testing.allocator, &unterminated, 0, .{}),
    );
}

test "numeric expression cleanup is idempotent and none remains clamp-only" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "ownership.css",
        ".a{a:1px;b:calc(none);c:clamp(none,1px,none);" ++
            "d:clamp(none + 1px,2px,3px);e:clamp(1px,none,3px)}",
    );
    defer parsed.deinit();

    var expression = try parseTestDeclaration(std.testing.allocator, &parsed, 0, .{});
    expression.deinit();
    expression.deinit();
    try std.testing.expectEqual(@as(usize, 0), expression.instructions.len);

    try std.testing.expectError(
        error.UnsupportedSyntax,
        parseTestDeclaration(std.testing.allocator, &parsed, 1, .{}),
    );
    var clamp = try parseTestDeclaration(std.testing.allocator, &parsed, 2, .{});
    defer clamp.deinit();
    try std.testing.expect(clamp.isRepresentableNumeric());
    try std.testing.expectError(
        error.InvalidExpression,
        parseTestDeclaration(std.testing.allocator, &parsed, 3, .{}),
    );
    try std.testing.expectError(
        error.UnsupportedSyntax,
        parseTestDeclaration(std.testing.allocator, &parsed, 4, .{}),
    );
}
