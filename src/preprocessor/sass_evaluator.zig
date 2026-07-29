//! Private bounded semantic evaluator for the native SCSS and indented-Sass
//! parser. This module is intentionally unreachable from every production API
//! until the native Sass conformance row graduates.

const std = @import("std");
const native_diagnostics = @import("diagnostics.zig");
const native_environment = @import("environment.zig");
const native_evaluator = @import("evaluator.zig");
const native_lexer = @import("lexer.zig");
const native_arguments = @import("sass_arguments.zig");
const native_color = @import("sass_color.zig");
const native_numeric = @import("sass_numeric.zig");
const native_selector = @import("sass_selector.zig");
const native_string = @import("sass_string.zig");
const native_source = @import("source.zig");
const native_syntax = @import("syntax.zig");
const native_value = @import("value.zig");

const hard_selectors = 1_000_000;
const hard_selector_bytes = 20 * 1024 * 1024;
const hard_temporary_bytes = 20 * 1024 * 1024;
const hard_expression_tokens = 1_000_000;
const hard_function_arguments = 65_536;
const hard_callables = 65_536;
const hard_modules = 65_536;
const hard_loop_variables = 65_536;
const hard_evaluation_depth: u16 = 256;

pub const Limits = struct {
    values: native_value.Limits = .{},
    environment: native_environment.Limits = .{},
    max_selectors: usize = 200_000,
    max_selector_bytes: usize = 10 * 1024 * 1024,
    max_temporary_bytes: usize = 10 * 1024 * 1024,
    max_expression_tokens: usize = 200_000,
    max_function_arguments: usize = 4_096,
    max_callables: usize = 4_096,
    max_modules: usize = 4_096,
    max_loop_variables: usize = 4_096,
    max_evaluation_depth: u16 = 128,
};

pub const Error = native_evaluator.Error ||
    native_environment.Error ||
    native_lexer.Error ||
    native_arguments.Error ||
    native_color.Error ||
    native_numeric.Error ||
    native_selector.Error ||
    native_string.Error ||
    native_source.Error ||
    native_value.Error || error{
    EvaluationDepthExceeded,
    CallableLimitExceeded,
    FunctionArgumentLimitExceeded,
    InvalidExpression,
    InvalidLimits,
    InvalidSassSyntax,
    LoopVariableLimitExceeded,
    ModuleLimitExceeded,
    SelectorLimitExceeded,
    TemporaryLimitExceeded,
    UndefinedVariable,
    UnsupportedFeature,
};

pub fn evaluate(
    allocator: std.mem.Allocator,
    sources: *const native_source.Table,
    document: *const native_syntax.Document,
    transaction: *native_evaluator.Transaction,
    limits: Limits,
) Error!void {
    errdefer transaction.abort();
    var engine = try Engine.init(allocator, sources, document, transaction, limits);
    defer engine.deinit();
    try engine.run();
}

const SelectorList = struct {
    items: [][]u8,

    fn deinit(self: *SelectorList, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item);
        if (self.items.len > 0) allocator.free(self.items);
        self.* = undefined;
    }
};

const Numeric = native_numeric.Numeric;

const VariableAssignment = struct {
    value: []const u8,
    default: bool = false,
    global: bool = false,
};

const ExpressionRange = native_arguments.Range;

const SplitSeparator = enum {
    comma,
    slash,
    whitespace,
    color_whitespace,
};

const Builtin = enum {
    map_get,
    map_has_key,
    map_keys,
    map_values,
    map_merge,
    map_remove,
    map_set,
    map_deep_merge,
    map_deep_remove,
    nth,
    length,
    list_index,
    list_separator,
    list_is_bracketed,
    list_append,
    list_set_nth,
    list_join,
    list_zip,
    list_slash,
    math_abs,
    math_acos,
    math_asin,
    math_atan,
    math_atan2,
    math_ceil,
    math_compatible,
    math_cos,
    math_div,
    math_floor,
    math_hypot,
    math_is_unitless,
    math_log,
    math_max,
    math_min,
    math_percentage,
    math_pow,
    math_random,
    math_round,
    math_sin,
    math_sqrt,
    math_tan,
    math_unit,
    math_clamp,
    meta_accepts_content,
    meta_calc_args,
    meta_calc_name,
    meta_call,
    meta_content_exists,
    meta_feature_exists,
    meta_function_exists,
    meta_get_function,
    meta_get_mixin,
    meta_global_variable_exists,
    meta_inspect,
    meta_keywords,
    meta_mixin_exists,
    meta_type_of,
    meta_variable_exists,
    selector_append,
    selector_extend,
    selector_is_superselector,
    selector_nest,
    selector_parse,
    selector_replace,
    selector_simple_selectors,
    selector_unify,
    quote,
    unquote,
    str_length,
    str_index,
    str_slice,
    str_insert,
    to_upper_case,
    to_lower_case,
    rgb,
    rgba,
    hsl,
    hsla,
    hwb,
    lab,
    lch,
    oklab,
    oklch,
    color,
    red,
    green,
    blue,
    alpha,
    opacity,
    hue,
    saturation,
    lightness,
    whiteness,
    blackness,
    mix,
    lighten,
    darken,
    saturate,
    desaturate,
    adjust_hue,
    complement,
    grayscale,
    invert,
    opacify,
    fade_in,
    transparentize,
    fade_out,
    ie_hex_str,
    adjust_color,
    change_color,
    scale_color,
    calculation,
    minimum,
    maximum,
    clamp,
};

const ColorTransformSpace = enum {
    rgb,
    hsl,
    hwb,
    lab,
    lch,
    oklab,
    oklch,
    srgb,
    srgb_linear,
    display_p3,
    a98_rgb,
    prophoto_rgb,
    rec2020,
    xyz_d50,
    xyz,
};

const ColorTransformChannel = enum {
    red,
    green,
    blue,
    hue,
    saturation,
    lightness,
    whiteness,
    blackness,
    lab_a,
    lab_b,
    chroma,
    x,
    y,
    z,
};

const color_transform_parameters = [17]native_arguments.Parameter{
    .{ .name = "color" },
    .{ .name = "red", .required = false },
    .{ .name = "green", .required = false },
    .{ .name = "blue", .required = false },
    .{ .name = "hue", .required = false },
    .{ .name = "saturation", .required = false },
    .{ .name = "lightness", .required = false },
    .{ .name = "whiteness", .required = false },
    .{ .name = "blackness", .required = false },
    .{ .name = "alpha", .required = false },
    .{ .name = "space", .required = false },
    .{ .name = "a", .required = false },
    .{ .name = "b", .required = false },
    .{ .name = "chroma", .required = false },
    .{ .name = "x", .required = false },
    .{ .name = "y", .required = false },
    .{ .name = "z", .required = false },
};

fn transformSpaceForColorSpace(space: native_value.ColorSpace) ColorTransformSpace {
    return switch (space) {
        .rgb => .rgb,
        .hsl => .hsl,
        .hwb => .hwb,
        .lab => .lab,
        .lch => .lch,
        .oklab => .oklab,
        .oklch => .oklch,
        .srgb => .srgb,
        .srgb_linear => .srgb_linear,
        .display_p3 => .display_p3,
        .a98_rgb => .a98_rgb,
        .prophoto_rgb => .prophoto_rgb,
        .rec2020 => .rec2020,
        .xyz_d50 => .xyz_d50,
        .xyz => .xyz,
    };
}

fn nativeColorTransformSpace(space: ColorTransformSpace) native_value.ColorSpace {
    return switch (space) {
        .rgb => .rgb,
        .hsl => .hsl,
        .hwb => .hwb,
        .lab => .lab,
        .lch => .lch,
        .oklab => .oklab,
        .oklch => .oklch,
        .srgb => .srgb,
        .srgb_linear => .srgb_linear,
        .display_p3 => .display_p3,
        .a98_rgb => .a98_rgb,
        .prophoto_rgb => .prophoto_rgb,
        .rec2020 => .rec2020,
        .xyz_d50 => .xyz_d50,
        .xyz => .xyz,
    };
}

fn colorTransformSpaceSupports(
    space: ColorTransformSpace,
    channel: ColorTransformChannel,
) bool {
    return switch (channel) {
        .red, .green, .blue => switch (space) {
            .rgb,
            .srgb,
            .srgb_linear,
            .display_p3,
            .a98_rgb,
            .prophoto_rgb,
            .rec2020,
            => true,
            else => false,
        },
        .hue => switch (space) {
            .hsl, .hwb, .lch, .oklch => true,
            else => false,
        },
        .saturation => space == .hsl,
        .lightness => switch (space) {
            .hsl, .lab, .lch, .oklab, .oklch => true,
            else => false,
        },
        .whiteness, .blackness => space == .hwb,
        .lab_a, .lab_b => space == .lab or space == .oklab,
        .chroma => space == .lch or space == .oklch,
        .x, .y, .z => space == .xyz_d50 or space == .xyz,
    };
}

const ModernColorChannelKind = enum {
    lab_lightness,
    oklab_lightness,
    lab_axis,
    oklab_axis,
    lch_chroma,
    oklch_chroma,
    predefined,
    hue,
    alpha,
};

const ModernColorChannel = struct {
    value: f64 = 0,
    missing: bool = false,
};

const ConditionalDirective = enum {
    if_branch,
    else_branch,
};

const ConditionalSelection = struct {
    consumed: usize,
    block: ?native_syntax.NodeId,
};

const ScopeKind = enum {
    global,
    lexical,
    flow,
};

const ScopeFrame = struct {
    cursor: native_environment.ScopeId,
    owned_markers: ?native_environment.ScopeId = null,
    kind: ScopeKind,
    parent: ?*ScopeFrame,
};

const LoopBodyContext = union(enum) {
    root,
    rule: struct {
        owner_span: native_source.Span,
        selectors: *const SelectorList,
        declarations: *std.ArrayList(u8),
    },
    callable: *?*const native_value.Value,
};

const CallableParameter = struct {
    name: []u8,
    default_value: ?[]const u8,
    rest: bool = false,
};

const UserFunction = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    parameters: []CallableParameter,
    block: native_syntax.NodeId,
    owner: *ScopeFrame,
    span: native_source.Span,

    fn deinit(self: *UserFunction) void {
        self.allocator.free(self.name);
        for (self.parameters) |parameter| self.allocator.free(parameter.name);
        if (self.parameters.len > 0) self.allocator.free(self.parameters);
        self.* = undefined;
    }
};

const UserMixin = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    parameters: []CallableParameter,
    block: native_syntax.NodeId,
    owner: *ScopeFrame,
    span: native_source.Span,
    accepts_content: bool,

    fn deinit(self: *UserMixin) void {
        self.allocator.free(self.name);
        for (self.parameters) |parameter| self.allocator.free(parameter.name);
        if (self.parameters.len > 0) self.allocator.free(self.parameters);
        self.* = undefined;
    }
};

const ContentInvocation = struct {
    block: native_syntax.NodeId,
    owner: *ScopeFrame,
    captured_content: ?*const ContentInvocation,
    parameters: []const CallableParameter,
};

const EvaluatedKeywordArgument = struct {
    name: []const u8,
    value: *const native_value.Value,
    normalize_name: bool,
};

const EvaluatedCallArguments = struct {
    allocator: std.mem.Allocator,
    positional: std.ArrayList(*const native_value.Value) = .empty,
    keywords: std.ArrayList(EvaluatedKeywordArgument) = .empty,
    splat_keywords: std.ArrayList(EvaluatedKeywordArgument) = .empty,

    fn deinit(self: *EvaluatedCallArguments) void {
        self.positional.deinit(self.allocator);
        self.keywords.deinit(self.allocator);
        self.splat_keywords.deinit(self.allocator);
        self.* = undefined;
    }
};

const BoundCallableArguments = struct {
    allocator: std.mem.Allocator,
    values: []?*const native_value.Value,
    rest_value: ?*const native_value.Value,

    fn deinit(self: *BoundCallableArguments) void {
        if (self.values.len > 0) self.allocator.free(self.values);
        self.* = undefined;
    }
};

const BoundEvaluatedArguments = struct {
    allocator: std.mem.Allocator,
    values: []?*const native_value.Value,

    fn deinit(self: *BoundEvaluatedArguments) void {
        if (self.values.len > 0) self.allocator.free(self.values);
        self.* = undefined;
    }
};

const IncludePrelude = struct {
    call: []const u8,
    content_parameter_body: ?[]const u8,
};

const CallableValidationContext = struct {
    in_function: bool = false,
    in_control: bool = false,
    in_mixin: bool = false,
    allows_content: bool = false,
};

const ParsedForLoop = struct {
    name: []u8,
    start: []const u8,
    end: []const u8,
    inclusive: bool,
};

const ParsedEachLoop = struct {
    allocator: std.mem.Allocator,
    names: [][]u8,
    iterable: []const u8,

    fn deinit(self: *ParsedEachLoop) void {
        for (self.names) |name| self.allocator.free(name);
        if (self.names.len > 0) self.allocator.free(self.names);
        self.* = undefined;
    }
};

const ArithmeticProbe = union(enum) {
    none,
    numeric: Numeric,
    incompatible,
    invalid,
};

const ArithmeticContext = enum {
    sass,
    calculation,
    numeric_function,
};

const BuiltinModule = enum {
    color,
    list,
    map,
    math,
    meta,
    selector,
    string,
};

const BuiltinMixin = enum(u32) {
    meta_load_css,
    meta_apply,
};

const max_random_limit: u64 = 1 << 32;
const MathConstantDefinition = struct {
    name: []const u8,
    value: f64,
};
const math_constants = [_]MathConstantDefinition{
    .{ .name = "e", .value = std.math.e },
    .{ .name = "epsilon", .value = std.math.floatEps(f64) },
    .{ .name = "max-number", .value = std.math.floatMax(f64) },
    .{ .name = "max-safe-integer", .value = 9_007_199_254_740_991.0 },
    .{ .name = "min-number", .value = std.math.floatTrueMin(f64) },
    .{ .name = "min-safe-integer", .value = -9_007_199_254_740_991.0 },
    .{ .name = "pi", .value = std.math.pi },
};

const ModuleBinding = struct {
    kind: BuiltinModule,
    namespace: ?[]const u8,
};

const ParsedUse = struct {
    url: []const u8,
    namespace: ?[]const u8 = null,
    unprefixed: bool = false,
};

const QualifiedName = struct {
    namespace: []const u8,
    member: []const u8,
};

const CalculationArgument = union(enum) {
    number: *const native_value.Value,
    deferred: *const native_value.Value,
};

const SassCalculationValue = struct {
    name: []const u8,
    body: []const u8,
};

const CalculationDimension = enum {
    number,
    percentage,
    length,
    angle,
    time,
    frequency,
    resolution,
    unknown,
};

const MapMutationScratch = struct {
    allocator: std.mem.Allocator,
    reserved_bytes: usize = 0,
};

const MaterializedList = struct {
    items: []native_value.Value,
    pair_items: ?[]native_value.Value = null,
    separator: native_value.Separator,
    bracketed: bool,

    fn deinit(self: *MaterializedList, allocator: std.mem.Allocator) void {
        if (self.pair_items) |items| allocator.free(items);
        allocator.free(self.items);
        self.* = undefined;
    }
};

const MaterializedZip = struct {
    rows: []native_value.Value,
    row_items: []native_value.Value,
    pair_items: ?[]native_value.Value = null,

    fn deinit(self: *MaterializedZip, allocator: std.mem.Allocator) void {
        if (self.pair_items) |items| allocator.free(items);
        allocator.free(self.row_items);
        allocator.free(self.rows);
        self.* = undefined;
    }
};

const LogicalOperator = enum {
    logical_or,
    logical_and,
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
};

const OperatorMatch = struct {
    operation: LogicalOperator,
    start: usize,
    end: usize,
};

const Engine = struct {
    allocator: std.mem.Allocator,
    sources: *const native_source.Table,
    document: *const native_syntax.Document,
    transaction: *native_evaluator.Transaction,
    limits: Limits,
    values: native_value.Store,
    environment: native_environment.Environment,
    global_scope: native_environment.ScopeId,
    user_functions: std.ArrayList(UserFunction) = .empty,
    user_mixins: std.ArrayList(UserMixin) = .empty,
    modules: std.ArrayList(ModuleBinding) = .empty,
    active_content: ?*const ContentInvocation = null,
    active_mixin_body: bool = false,
    expression_depth: u16 = 0,
    selector_count: usize = 0,
    selector_bytes: usize = 0,
    legacy_if_deprecation_count: usize = 0,
    misplaced_rest_deprecation_count: usize = 0,
    random_state: u64,

    fn init(
        allocator: std.mem.Allocator,
        sources: *const native_source.Table,
        document: *const native_syntax.Document,
        transaction: *native_evaluator.Transaction,
        limits: Limits,
    ) Error!Engine {
        try validateLimits(limits);
        var environment = try native_environment.Environment.init(allocator, limits.environment);
        errdefer environment.deinit();
        const root = document.get(document.root) catch return error.InvalidSassSyntax;
        const root_source = try sources.get(root.span.source);
        return .{
            .allocator = allocator,
            .sources = sources,
            .document = document,
            .transaction = transaction,
            .limits = limits,
            .values = native_value.Store.init(allocator, limits.values),
            .environment = environment,
            .global_scope = environment.root(),
            .random_state = deterministicRandomSeed(root_source.bytes),
        };
    }

    fn deinit(self: *Engine) void {
        for (self.user_functions.items) |*function| function.deinit();
        self.user_functions.deinit(self.allocator);
        for (self.user_mixins.items) |*mixin| mixin.deinit();
        self.user_mixins.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.environment.deinit();
        self.values.deinit();
        self.* = undefined;
    }

    fn run(self: *Engine) Error!void {
        const root = self.document.get(self.document.root) catch return error.InvalidSassSyntax;
        if (root.kind != .stylesheet) {
            try self.report(.syntax, root.span, "native Sass document root is not a stylesheet");
            return error.InvalidSassSyntax;
        }
        const children = self.document.children(self.document.root) catch
            return error.InvalidSassSyntax;
        try self.validateModulePlacement(children);
        try self.validateCallableStructure(self.document.root, .{});
        var scope = ScopeFrame{
            .cursor = self.global_scope,
            .kind = .global,
            .parent = null,
        };
        try self.executeRootChildren(children, &scope, 1);
        try self.reportLegacyIfDeprecationSummary(root.span);
        self.global_scope = scope.cursor;
    }

    fn validateModulePlacement(
        self: *Engine,
        children: []const native_syntax.NodeId,
    ) Error!void {
        var saw_rule = false;
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidSassSyntax;
            if (child.kind == .module) {
                if (saw_rule) {
                    try self.report(.syntax, child.span, "Sass module directives must precede all rules");
                    return error.InvalidSassSyntax;
                }
                continue;
            }
            const is_variable = child.kind == .declaration and
                try self.isVariableDeclaration(child_id);
            if (child.kind != .comment and !is_variable) saw_rule = true;
            try self.rejectNestedModuleDirectives(child_id);
        }
    }

    fn rejectNestedModuleDirectives(
        self: *Engine,
        node_id: native_syntax.NodeId,
    ) Error!void {
        const children = self.document.children(node_id) catch return error.InvalidSassSyntax;
        for (children) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidSassSyntax;
            if (child.kind == .module) {
                try self.report(.syntax, child.span, "Sass module directives are only valid at the stylesheet root");
                return error.InvalidSassSyntax;
            }
            try self.rejectNestedModuleDirectives(child_id);
        }
    }

    fn validateCallableStructure(
        self: *Engine,
        node_id: native_syntax.NodeId,
        context: CallableValidationContext,
    ) Error!void {
        const node = self.document.get(node_id) catch return error.InvalidSassSyntax;
        var child_context = context;
        switch (node.kind) {
            .function => {
                if (context.in_function or context.in_control or context.in_mixin) {
                    try self.report(.syntax, node.span, "native Sass function declaration is not allowed here");
                    return error.InvalidSassSyntax;
                }
                child_context = .{ .in_function = true };
            },
            .conditional, .loop => child_context.in_control = true,
            .mixin => {
                const keyword_span = node.text orelse return error.InvalidSassSyntax;
                const keyword = try self.sources.slice(keyword_span);
                if (std.ascii.eqlIgnoreCase(keyword, "@mixin")) {
                    if (context.in_function or context.in_control or context.in_mixin) {
                        try self.report(.syntax, node.span, "native Sass mixin declaration is not allowed here");
                        return error.InvalidSassSyntax;
                    }
                    child_context = .{ .in_mixin = true, .allows_content = true };
                } else if (std.ascii.eqlIgnoreCase(keyword, "@include")) {
                    if (context.in_function) {
                        try self.report(.syntax, node.span, "Sass functions may not include mixins");
                        return error.InvalidSassSyntax;
                    }
                    try self.validateMixinCallSyntax(node_id);
                    child_context.in_mixin = true;
                } else {
                    try self.report(.syntax, node.span, "unknown native Sass mixin directive");
                    return error.InvalidSassSyntax;
                }
            },
            .return_statement => {
                if (!context.in_function) {
                    try self.report(.syntax, node.span, "Sass @return is only valid inside a function");
                    return error.InvalidSassSyntax;
                }
                const return_children = self.document.children(node_id) catch
                    return error.InvalidSassSyntax;
                if (return_children.len != 1) {
                    try self.report(.syntax, node.span, "malformed native Sass @return");
                    return error.InvalidSassSyntax;
                }
                const expression = self.document.get(return_children[0]) catch
                    return error.InvalidSassSyntax;
                if (expression.kind != .expression or expression.text == null) {
                    try self.report(.syntax, node.span, "native Sass @return requires an expression");
                    return error.InvalidSassSyntax;
                }
            },
            .rule => {
                if (context.in_function) {
                    try self.report(.syntax, node.span, "Sass functions may not contain style rules");
                    return error.InvalidSassSyntax;
                }
            },
            .declaration => {
                if (context.in_function and !try self.isVariableDeclaration(node_id)) {
                    try self.report(.syntax, node.span, "Sass functions may not emit declarations");
                    return error.InvalidSassSyntax;
                }
            },
            .content => {
                if (!context.allows_content) {
                    try self.report(.syntax, node.span, "Sass @content is only valid inside a mixin declaration");
                    return error.InvalidSassSyntax;
                }
                var ranges: std.ArrayList(ExpressionRange) = .empty;
                defer ranges.deinit(self.allocator);
                const body = try self.parseContentArgumentBody(node_id, &ranges);
                var parsed = native_arguments.parseAlloc(
                    self.allocator,
                    body,
                    ranges.items,
                    self.limits.max_function_arguments,
                ) catch |err| return self.argumentsFailure(err, node.span);
                defer parsed.deinit();
                for (parsed.items, 0..) |argument, index| {
                    const name = argument.name orelse continue;
                    for (parsed.items[0..index]) |previous| {
                        const previous_name = previous.name orelse continue;
                        if (native_arguments.nameEql(name, previous_name)) {
                            return self.argumentsFailure(error.DuplicateArgument, node.span);
                        }
                    }
                }
            },
            .import, .module => {
                if (context.in_function) {
                    try self.report(.syntax, node.span, "at-rule is not valid inside a Sass function");
                    return error.InvalidSassSyntax;
                }
            },
            .at_rule => {
                if (context.in_function) {
                    const keyword_span = node.text orelse return error.InvalidSassSyntax;
                    const keyword = try self.sources.slice(keyword_span);
                    if (!std.ascii.eqlIgnoreCase(keyword, "@warn") and
                        !std.ascii.eqlIgnoreCase(keyword, "@error") and
                        !std.ascii.eqlIgnoreCase(keyword, "@debug"))
                    {
                        try self.report(.syntax, node.span, "at-rule is not valid inside a Sass function");
                        return error.InvalidSassSyntax;
                    }
                }
            },
            else => {},
        }
        const children = self.document.children(node_id) catch return error.InvalidSassSyntax;
        for (children) |child_id| try self.validateCallableStructure(child_id, child_context);
    }

    fn executeRootChildren(
        self: *Engine,
        children: []const native_syntax.NodeId,
        scope: *ScopeFrame,
        depth: u16,
    ) Error!void {
        if (depth > self.limits.max_evaluation_depth) {
            const span = if (children.len > 0)
                (self.document.get(children[0]) catch return error.InvalidSassSyntax).span
            else
                (self.document.get(self.document.root) catch return error.InvalidSassSyntax).span;
            try self.report(.resource_limit, span, "native Sass evaluation depth exceeded");
            return error.EvaluationDepthExceeded;
        }
        var index: usize = 0;
        while (index < children.len) {
            try self.transaction.consumeOperations(1);
            const child_id = children[index];
            const child = self.document.get(child_id) catch return error.InvalidSassSyntax;
            switch (child.kind) {
                .declaration => {
                    if (!try self.isVariableDeclaration(child_id)) {
                        try self.report(.syntax, child.span, "top-level Sass declaration is not a variable");
                        return error.InvalidSassSyntax;
                    }
                    try self.assignVariable(child_id, scope);
                },
                .rule => try self.evaluateRule(child_id, null, scope, depth),
                .comment => try self.emitRootComment(child),
                .conditional => {
                    const selection = try self.selectConditionalChain(
                        children,
                        index,
                        scope.cursor,
                    );
                    if (selection.block) |block_id| {
                        const block_children = self.document.children(block_id) catch
                            return error.InvalidSassSyntax;
                        var branch_scope = try self.beginFlowScope(scope);
                        try self.executeRootChildren(
                            block_children,
                            &branch_scope,
                            depth + 1,
                        );
                    }
                    index += selection.consumed;
                    continue;
                },
                .loop => try self.executeLoop(child_id, scope, depth, .root),
                .mixin => try self.executeMixinDirective(child_id, scope, depth, .root),
                .content => try self.executeContentDirective(child_id, scope, depth, .root),
                .function => try self.defineUserFunction(child_id, scope),
                .module => try self.executeModuleDirective(child_id),
                .return_statement => {
                    try self.report(.syntax, child.span, "Sass @return is only valid inside a function");
                    return error.InvalidSassSyntax;
                },
                else => {
                    try self.report(
                        .unsupported_feature,
                        child.span,
                        "Sass directive is not implemented by the native evaluator yet",
                    );
                    return error.UnsupportedFeature;
                },
            }
            index += 1;
        }
    }

    fn executeModuleDirective(
        self: *Engine,
        node_id: native_syntax.NodeId,
    ) Error!void {
        const node = self.document.get(node_id) catch return error.InvalidSassSyntax;
        const keyword_span = node.text orelse return error.InvalidSassSyntax;
        const keyword = try self.sources.slice(keyword_span);
        if (std.ascii.eqlIgnoreCase(keyword, "@forward")) {
            try self.report(
                .unsupported_feature,
                node.span,
                "native Sass @forward is not implemented yet",
            );
            return error.UnsupportedFeature;
        }
        if (!std.ascii.eqlIgnoreCase(keyword, "@use")) {
            try self.report(.syntax, node.span, "unknown native Sass module directive");
            return error.InvalidSassSyntax;
        }

        const children = self.document.children(node_id) catch return error.InvalidSassSyntax;
        if (children.len != 1) {
            try self.report(.syntax, node.span, "native Sass @use requires one module URL and no block");
            return error.InvalidSassSyntax;
        }
        const prelude_node = self.document.get(children[0]) catch return error.InvalidSassSyntax;
        if (prelude_node.kind != .expression or prelude_node.text == null) {
            try self.report(.syntax, node.span, "native Sass @use requires a module URL");
            return error.InvalidSassSyntax;
        }
        const prelude = try self.sources.slice(prelude_node.text.?);
        const parsed = parseUseDirective(prelude) orelse {
            try self.report(.syntax, node.span, "malformed native Sass @use directive");
            return error.InvalidSassSyntax;
        };
        const module_kind: BuiltinModule = if (std.mem.eql(u8, parsed.url, "sass:color"))
            .color
        else if (std.mem.eql(u8, parsed.url, "sass:list"))
            .list
        else if (std.mem.eql(u8, parsed.url, "sass:map"))
            .map
        else if (std.mem.eql(u8, parsed.url, "sass:math"))
            .math
        else if (std.mem.eql(u8, parsed.url, "sass:meta"))
            .meta
        else if (std.mem.eql(u8, parsed.url, "sass:selector"))
            .selector
        else if (std.mem.eql(u8, parsed.url, "sass:string"))
            .string
        else {
            try self.report(
                .unsupported_feature,
                node.span,
                "native Sass module is not implemented yet",
            );
            return error.UnsupportedFeature;
        };
        if (self.modules.items.len >= self.limits.max_modules) {
            try self.report(.resource_limit, node.span, "native Sass module limit exceeded");
            return error.ModuleLimitExceeded;
        }

        const namespace: ?[]const u8 = if (parsed.unprefixed)
            null
        else
            parsed.namespace orelse switch (module_kind) {
                .color => "color",
                .list => "list",
                .map => "map",
                .math => "math",
                .meta => "meta",
                .selector => "selector",
                .string => "string",
            };
        if (namespace == null and module_kind == .math) {
            for (math_constants) |constant| {
                if (try self.environment.lookup(self.global_scope, constant.name) == null) continue;
                try self.report(
                    .duplicate_binding,
                    node.span,
                    "unprefixed Sass module variable conflicts with an existing variable",
                );
                return error.InvalidExpression;
            }
        }
        if (namespace) |candidate| {
            for (self.modules.items) |binding| {
                if (binding.namespace) |existing| {
                    if (std.mem.eql(u8, candidate, existing)) {
                        try self.report(.syntax, node.span, "Sass module namespace is already in use");
                        return error.InvalidSassSyntax;
                    }
                }
            }
        }
        try self.modules.append(self.allocator, .{
            .kind = module_kind,
            .namespace = namespace,
        });
    }

    fn emitRootComment(self: *Engine, node: *const native_syntax.Node) Error!void {
        const text_span = node.text orelse return;
        const raw = try self.sources.slice(text_span);
        if (!std.mem.startsWith(u8, raw, "/*")) return;
        try self.transaction.emitMapped(node.span, null, raw);
        try self.transaction.emit("\n");
    }

    fn evaluateRule(
        self: *Engine,
        rule_id: native_syntax.NodeId,
        parents: ?*const SelectorList,
        inherited_scope: *ScopeFrame,
        depth: u16,
    ) Error!void {
        if (depth > self.limits.max_evaluation_depth) {
            const node = self.document.get(rule_id) catch return error.InvalidSassSyntax;
            try self.report(.resource_limit, node.span, "native Sass evaluation depth exceeded");
            return error.EvaluationDepthExceeded;
        }
        const rule = self.document.get(rule_id) catch return error.InvalidSassSyntax;
        const rule_children = self.document.children(rule_id) catch return error.InvalidSassSyntax;
        if (rule.kind != .rule or rule_children.len != 2) {
            try self.report(.syntax, rule.span, "malformed native Sass style rule");
            return error.InvalidSassSyntax;
        }
        const selector_node = self.document.get(rule_children[0]) catch return error.InvalidSassSyntax;
        const block_node = self.document.get(rule_children[1]) catch return error.InvalidSassSyntax;
        if (selector_node.kind != .selector or block_node.kind != .block or selector_node.text == null) {
            try self.report(.syntax, rule.span, "malformed native Sass rule children");
            return error.InvalidSassSyntax;
        }

        var selectors = try self.buildSelectors(selector_node.text.?, parents, inherited_scope.cursor);
        defer selectors.deinit(self.allocator);
        var scope = ScopeFrame{
            .cursor = try self.environment.push(inherited_scope.cursor),
            .kind = .lexical,
            .parent = inherited_scope,
        };
        var declarations: std.ArrayList(u8) = .empty;
        defer declarations.deinit(self.allocator);

        const block_children = self.document.children(rule_children[1]) catch
            return error.InvalidSassSyntax;
        try self.executeRuleChildren(
            block_children,
            rule.span,
            &selectors,
            &scope,
            &declarations,
            depth,
        );

        try self.emitRuleChunk(rule.span, &selectors, &declarations);
    }

    fn executeRuleChildren(
        self: *Engine,
        children: []const native_syntax.NodeId,
        owner_span: native_source.Span,
        selectors: *const SelectorList,
        scope: *ScopeFrame,
        declarations: *std.ArrayList(u8),
        depth: u16,
    ) Error!void {
        if (depth > self.limits.max_evaluation_depth) {
            try self.report(.resource_limit, owner_span, "native Sass evaluation depth exceeded");
            return error.EvaluationDepthExceeded;
        }
        var index: usize = 0;
        while (index < children.len) {
            try self.transaction.consumeOperations(1);
            const child_id = children[index];
            const child = self.document.get(child_id) catch return error.InvalidSassSyntax;
            switch (child.kind) {
                .declaration => {
                    if (try self.isVariableDeclaration(child_id)) {
                        try self.assignVariable(child_id, scope);
                    } else {
                        try self.appendDeclaration(
                            child_id,
                            "",
                            scope,
                            declarations,
                            depth,
                        );
                    }
                },
                .rule => {
                    try self.emitRuleChunk(owner_span, selectors, declarations);
                    try self.evaluateRule(child_id, selectors, scope, depth + 1);
                },
                .comment => try self.appendBlockComment(child, declarations),
                .conditional => {
                    const selection = try self.selectConditionalChain(
                        children,
                        index,
                        scope.cursor,
                    );
                    if (selection.block) |block_id| {
                        const block_children = self.document.children(block_id) catch
                            return error.InvalidSassSyntax;
                        var branch_scope = try self.beginFlowScope(scope);
                        try self.executeRuleChildren(
                            block_children,
                            owner_span,
                            selectors,
                            &branch_scope,
                            declarations,
                            depth + 1,
                        );
                    }
                    index += selection.consumed;
                    continue;
                },
                .loop => try self.executeLoop(child_id, scope, depth, .{ .rule = .{
                    .owner_span = owner_span,
                    .selectors = selectors,
                    .declarations = declarations,
                } }),
                .mixin => try self.executeMixinDirective(child_id, scope, depth, .{ .rule = .{
                    .owner_span = owner_span,
                    .selectors = selectors,
                    .declarations = declarations,
                } }),
                .content => try self.executeContentDirective(child_id, scope, depth, .{ .rule = .{
                    .owner_span = owner_span,
                    .selectors = selectors,
                    .declarations = declarations,
                } }),
                .function => try self.defineUserFunction(child_id, scope),
                .return_statement => {
                    try self.report(.syntax, child.span, "Sass @return is only valid inside a function");
                    return error.InvalidSassSyntax;
                },
                else => {
                    try self.report(
                        .unsupported_feature,
                        child.span,
                        "Sass directive is not implemented by the native evaluator yet",
                    );
                    return error.UnsupportedFeature;
                },
            }
            index += 1;
        }
    }

    fn beginFlowScope(
        self: *Engine,
        parent_scope: *ScopeFrame,
    ) Error!ScopeFrame {
        return .{
            .cursor = try self.environment.push(parent_scope.cursor),
            .owned_markers = try self.environment.push(self.environment.root()),
            .kind = .flow,
            .parent = parent_scope,
        };
    }

    fn parseIncludePrelude(
        self: *Engine,
        prelude: []const u8,
        span: native_source.Span,
    ) Error!IncludePrelude {
        var search_start: usize = 0;
        while (search_start < prelude.len) {
            const relative = findTopLevelWord(prelude[search_start..], "using") orelse break;
            const index = search_start + relative;
            const call = trimWhitespace(prelude[0..index]);
            if (call.len == 0) {
                search_start = index + "using".len;
                continue;
            }
            const clause = trimWhitespace(prelude[index + "using".len ..]);
            if (!fullyWrapped(clause, '(', ')')) {
                try self.report(.syntax, span, "malformed native Sass content parameter list");
                return error.InvalidSassSyntax;
            }
            return .{
                .call = call,
                .content_parameter_body = clause[1 .. clause.len - 1],
            };
        }
        return .{ .call = prelude, .content_parameter_body = null };
    }

    fn deinitCallableParameters(
        self: *Engine,
        parameters: []CallableParameter,
    ) void {
        for (parameters) |parameter| self.allocator.free(parameter.name);
        if (parameters.len > 0) self.allocator.free(parameters);
    }

    fn validateMixinCallSyntax(
        self: *Engine,
        directive_id: native_syntax.NodeId,
    ) Error!void {
        const directive = self.document.get(directive_id) catch return error.InvalidSassSyntax;
        const children = self.document.children(directive_id) catch return error.InvalidSassSyntax;
        if (directive.kind != .mixin or children.len < 1 or children.len > 2) {
            try self.report(.syntax, directive.span, "malformed native Sass @include");
            return error.InvalidSassSyntax;
        }
        const prelude_node = self.document.get(children[0]) catch return error.InvalidSassSyntax;
        if (prelude_node.kind != .expression or prelude_node.text == null) {
            try self.report(.syntax, directive.span, "native Sass @include requires a mixin name");
            return error.InvalidSassSyntax;
        }
        if (children.len == 2) {
            const block = self.document.get(children[1]) catch return error.InvalidSassSyntax;
            if (block.kind != .block) {
                try self.report(.syntax, directive.span, "native Sass @include content requires a block");
                return error.InvalidSassSyntax;
            }
        }

        const prelude = trimWhitespace(try self.sources.slice(prelude_node.text.?));
        const include = try self.parseIncludePrelude(prelude, prelude_node.span);
        if (include.content_parameter_body) |parameter_body| {
            if (children.len != 2) {
                try self.report(.syntax, prelude_node.span, "Sass content parameters require a content block");
                return error.InvalidSassSyntax;
            }
            const parameters = try self.parseCallableParameters(parameter_body, prelude_node.span);
            self.deinitCallableParameters(parameters);
        }
        const opening = std.mem.indexOfScalar(u8, include.call, '(');
        const raw_name = trimWhitespace(if (opening) |index| include.call[0..index] else include.call);
        if (!isSimpleIdentifier(raw_name)) {
            try self.report(.syntax, prelude_node.span, "invalid native Sass mixin name");
            return error.InvalidSassSyntax;
        }
        const body = if (opening) |index| blk: {
            if (!fullyWrapped(include.call[index..], '(', ')')) {
                try self.report(.syntax, prelude_node.span, "malformed native Sass mixin argument list");
                return error.InvalidSassSyntax;
            }
            break :blk include.call[index + 1 .. include.call.len - 1];
        } else "";
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        _ = try splitTopLevelRanges(self.allocator, body, .comma, &ranges);
        if (trimWhitespace(body).len == 0) ranges.clearRetainingCapacity();
        if (ranges.items.len > 0) {
            const final = ranges.items[ranges.items.len - 1];
            if (trimWhitespace(body[final.start..final.end]).len == 0) ranges.items.len -= 1;
        }
        var parsed = native_arguments.parseAlloc(
            self.allocator,
            body,
            ranges.items,
            self.limits.max_function_arguments,
        ) catch |err| switch (err) {
            else => return self.argumentsFailure(err, prelude_node.span),
        };
        defer parsed.deinit();
        for (parsed.items, 0..) |argument, index| {
            const name = argument.name orelse continue;
            for (parsed.items[0..index]) |previous| {
                const previous_name = previous.name orelse continue;
                if (native_arguments.nameEql(name, previous_name)) {
                    return self.argumentsFailure(error.DuplicateArgument, prelude_node.span);
                }
            }
        }
    }

    fn executeMixinDirective(
        self: *Engine,
        directive_id: native_syntax.NodeId,
        scope: *ScopeFrame,
        depth: u16,
        context: LoopBodyContext,
    ) Error!void {
        const directive = self.document.get(directive_id) catch return error.InvalidSassSyntax;
        if (directive.kind != .mixin or directive.text == null) {
            try self.report(.syntax, directive.span, "malformed native Sass mixin directive");
            return error.InvalidSassSyntax;
        }
        const keyword = try self.sources.slice(directive.text.?);
        if (std.ascii.eqlIgnoreCase(keyword, "@mixin")) {
            try self.defineUserMixin(directive_id, scope);
            return;
        }
        if (!std.ascii.eqlIgnoreCase(keyword, "@include")) {
            try self.report(.syntax, directive.span, "unknown native Sass mixin directive");
            return error.InvalidSassSyntax;
        }

        const children = self.document.children(directive_id) catch return error.InvalidSassSyntax;
        if (children.len < 1 or children.len > 2) {
            try self.report(.syntax, directive.span, "malformed native Sass @include");
            return error.InvalidSassSyntax;
        }
        const prelude_node = self.document.get(children[0]) catch return error.InvalidSassSyntax;
        if (prelude_node.kind != .expression or prelude_node.text == null) {
            try self.report(.syntax, directive.span, "native Sass @include requires a mixin name");
            return error.InvalidSassSyntax;
        }
        const prelude = trimWhitespace(try self.sources.slice(prelude_node.text.?));
        const include = try self.parseIncludePrelude(prelude, prelude_node.span);
        if (include.content_parameter_body != null and children.len != 2) {
            try self.report(.syntax, prelude_node.span, "Sass content parameters require a content block");
            return error.InvalidSassSyntax;
        }

        const opening = std.mem.indexOfScalar(u8, include.call, '(');
        const raw_name = trimWhitespace(if (opening) |index| include.call[0..index] else include.call);
        if (!isSimpleIdentifier(raw_name)) {
            try self.report(.syntax, prelude_node.span, "invalid native Sass mixin name");
            return error.InvalidSassSyntax;
        }
        const body = if (opening) |index| blk: {
            if (!fullyWrapped(include.call[index..], '(', ')')) {
                try self.report(.syntax, prelude_node.span, "malformed native Sass mixin argument list");
                return error.InvalidSassSyntax;
            }
            break :blk include.call[index + 1 .. include.call.len - 1];
        } else "";
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        _ = try splitTopLevelRanges(self.allocator, body, .comma, &ranges);
        if (trimWhitespace(body).len == 0) ranges.clearRetainingCapacity();
        if (ranges.items.len > 0) {
            const final = ranges.items[ranges.items.len - 1];
            if (trimWhitespace(body[final.start..final.end]).len == 0) ranges.items.len -= 1;
        }

        const mixin_id = try self.lookupUserMixin(raw_name, scope.cursor) orelse {
            try self.report(.syntax, prelude_node.span, "undefined native Sass mixin");
            return error.InvalidSassSyntax;
        };
        const content_block = if (children.len == 2) blk: {
            const block = self.document.get(children[1]) catch return error.InvalidSassSyntax;
            if (block.kind != .block) {
                try self.report(.syntax, directive.span, "native Sass @include content requires a block");
                return error.InvalidSassSyntax;
            }
            break :blk children[1];
        } else null;
        const content_parameters = try self.parseCallableParameters(
            include.content_parameter_body orelse "",
            prelude_node.span,
        );
        defer self.deinitCallableParameters(content_parameters);
        try self.callUserMixin(
            mixin_id,
            body,
            ranges.items,
            scope,
            content_block,
            content_parameters,
            prelude_node.span,
            depth,
            context,
        );
    }

    fn defineUserMixin(
        self: *Engine,
        mixin_id: native_syntax.NodeId,
        scope: *ScopeFrame,
    ) Error!void {
        const mixin_node = self.document.get(mixin_id) catch return error.InvalidSassSyntax;
        if (scope.kind == .flow) {
            try self.report(.syntax, mixin_node.span, "Sass mixins may not be declared in control flow");
            return error.InvalidSassSyntax;
        }
        if (self.callableLimitReached() or self.user_mixins.items.len >= std.math.maxInt(u32)) {
            try self.report(.resource_limit, mixin_node.span, "native Sass callable limit exceeded");
            return error.CallableLimitExceeded;
        }

        var mixin = try self.parseUserMixin(mixin_id, scope);
        errdefer mixin.deinit();
        const callable_id: u32 = @intCast(self.user_mixins.items.len);
        const callable = try self.values.own(.{ .callable = .{
            .kind = .mixin,
            .id = callable_id,
        } });
        const key = try self.callableKey("@mixin:", mixin.name);
        defer self.allocator.free(key);
        if (scope.kind == .global) {
            try self.assignGlobalVariable(scope, key, callable);
        } else {
            scope.cursor = try self.environment.set(scope.cursor, key, callable);
        }
        try self.user_mixins.append(self.allocator, mixin);
    }

    fn parseUserMixin(
        self: *Engine,
        mixin_id: native_syntax.NodeId,
        owner: *ScopeFrame,
    ) Error!UserMixin {
        const mixin_node = self.document.get(mixin_id) catch return error.InvalidSassSyntax;
        const children = self.document.children(mixin_id) catch return error.InvalidSassSyntax;
        if (mixin_node.kind != .mixin or mixin_node.text == null or children.len != 2) {
            try self.report(.syntax, mixin_node.span, "malformed native Sass mixin declaration");
            return error.InvalidSassSyntax;
        }
        const keyword = try self.sources.slice(mixin_node.text.?);
        const prelude_node = self.document.get(children[0]) catch return error.InvalidSassSyntax;
        const block_node = self.document.get(children[1]) catch return error.InvalidSassSyntax;
        if (!std.ascii.eqlIgnoreCase(keyword, "@mixin") or
            prelude_node.kind != .expression or prelude_node.text == null or
            block_node.kind != .block)
        {
            try self.report(.syntax, mixin_node.span, "native Sass mixin requires a signature and block");
            return error.InvalidSassSyntax;
        }

        const prelude = trimWhitespace(try self.sources.slice(prelude_node.text.?));
        const opening = std.mem.indexOfScalar(u8, prelude, '(');
        const raw_name = trimWhitespace(if (opening) |index| prelude[0..index] else prelude);
        if (!isSimpleIdentifier(raw_name) or std.mem.startsWith(u8, raw_name, "--")) {
            try self.report(.syntax, prelude_node.span, "invalid native Sass mixin name");
            return error.InvalidSassSyntax;
        }
        const accepts_content = try self.containsContentDirective(children[1]);
        const name = try self.normalizeCallableName(raw_name);
        errdefer self.allocator.free(name);
        const parameter_body = if (opening) |index| blk: {
            if (!fullyWrapped(prelude[index..], '(', ')')) {
                try self.report(.syntax, prelude_node.span, "malformed native Sass mixin parameter list");
                return error.InvalidSassSyntax;
            }
            break :blk prelude[index + 1 .. prelude.len - 1];
        } else "";
        const parameters = try self.parseCallableParameters(parameter_body, prelude_node.span);
        return .{
            .allocator = self.allocator,
            .name = name,
            .parameters = parameters,
            .block = children[1],
            .owner = owner,
            .span = mixin_node.span,
            .accepts_content = accepts_content,
        };
    }

    fn containsContentDirective(
        self: *Engine,
        node_id: native_syntax.NodeId,
    ) Error!bool {
        const node = self.document.get(node_id) catch return error.InvalidSassSyntax;
        if (node.kind == .content) return true;
        const children = self.document.children(node_id) catch return error.InvalidSassSyntax;
        for (children) |child_id| {
            if (try self.containsContentDirective(child_id)) return true;
        }
        return false;
    }

    fn parseCallableParameters(
        self: *Engine,
        body: []const u8,
        span: native_source.Span,
    ) Error![]CallableParameter {
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        _ = try splitTopLevelRanges(self.allocator, body, .comma, &ranges);
        if (trimWhitespace(body).len == 0) ranges.clearRetainingCapacity();
        if (ranges.items.len > 0) {
            const final = ranges.items[ranges.items.len - 1];
            if (trimWhitespace(body[final.start..final.end]).len == 0) ranges.items.len -= 1;
        }
        if (ranges.items.len > self.limits.max_function_arguments) {
            try self.report(.resource_limit, span, "native Sass callable parameter limit exceeded");
            return error.FunctionArgumentLimitExceeded;
        }

        var parameters: std.ArrayList(CallableParameter) = .empty;
        errdefer {
            for (parameters.items) |parameter| self.allocator.free(parameter.name);
            parameters.deinit(self.allocator);
        }
        for (ranges.items, 0..) |range, parameter_index| {
            const raw_parameter = trimWhitespace(body[range.start..range.end]);
            if (raw_parameter.len == 0) {
                try self.report(.syntax, span, "empty native Sass callable parameter");
                return error.InvalidSassSyntax;
            }
            const rest = std.mem.endsWith(u8, raw_parameter, "...");
            if (rest and parameter_index + 1 != ranges.items.len) {
                try self.report(.syntax, span, "native Sass rest parameter must be final");
                return error.InvalidSassSyntax;
            }
            const parameter_source = trimWhitespace(if (rest)
                raw_parameter[0 .. raw_parameter.len - "...".len]
            else
                raw_parameter);
            const colon = findTopLevelByte(parameter_source, ':');
            if (rest and colon != null) {
                try self.report(.syntax, span, "native Sass rest parameter may not have a default");
                return error.InvalidSassSyntax;
            }
            const raw_parameter_name = trimWhitespace(
                parameter_source[0 .. colon orelse parameter_source.len],
            );
            if (raw_parameter_name.len < 2 or raw_parameter_name[0] != '$' or
                !isSimpleIdentifier(raw_parameter_name[1..]))
            {
                try self.report(.syntax, span, "invalid native Sass callable parameter");
                return error.InvalidSassSyntax;
            }
            const parameter_name = try self.normalizeCallableName(raw_parameter_name[1..]);
            errdefer self.allocator.free(parameter_name);
            for (parameters.items) |parameter| {
                if (std.mem.eql(u8, parameter.name, parameter_name)) {
                    try self.report(.syntax, span, "duplicate native Sass callable parameter");
                    return error.InvalidSassSyntax;
                }
            }
            const default_value = if (colon) |separator| blk: {
                const value = trimWhitespace(parameter_source[separator + 1 ..]);
                if (value.len == 0) {
                    try self.report(.syntax, span, "native Sass callable parameter default is missing");
                    return error.InvalidSassSyntax;
                }
                break :blk value;
            } else null;
            try parameters.append(self.allocator, .{
                .name = parameter_name,
                .default_value = default_value,
                .rest = rest,
            });
        }
        return parameters.toOwnedSlice(self.allocator);
    }

    fn evaluateCallArguments(
        self: *Engine,
        body: []const u8,
        ranges: []const ExpressionRange,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!EvaluatedCallArguments {
        var result = EvaluatedCallArguments{ .allocator = self.allocator };
        errdefer result.deinit();
        var parsed = native_arguments.parseAlloc(
            self.allocator,
            body,
            ranges,
            self.limits.max_function_arguments,
        ) catch |err| return self.argumentsFailure(err, span);
        defer parsed.deinit();

        for (parsed.items) |argument| {
            const item = try self.evaluateExpressionBytes(
                body[argument.value.start..argument.value.end],
                scope,
                span,
            );
            if (argument.splat) {
                try self.expandCallSplat(&result, item, span);
            } else if (argument.name) |name| {
                try self.appendEvaluatedKeyword(&result, .{
                    .name = name,
                    .value = item,
                    .normalize_name = true,
                }, span);
            } else {
                try self.appendEvaluatedPositional(&result, item, span);
            }
        }
        try self.mergeEvaluatedSplatKeywords(&result);
        return result;
    }

    fn expandCallSplat(
        self: *Engine,
        output: *EvaluatedCallArguments,
        item: *const native_value.Value,
        span: native_source.Span,
    ) Error!void {
        switch (item.*) {
            .list => |list| {
                if (list.separator == .legacy_slash) {
                    try self.appendEvaluatedPositional(output, item, span);
                    return;
                }
                for (list.items) |*value| {
                    try self.appendEvaluatedPositional(output, value, span);
                }
            },
            .map => try self.expandCallKeywordSplat(output, item, span),
            .argument_list => |argument_list| {
                argument_list.state.keywords_accessed = true;
                for (argument_list.positional) |*value| {
                    try self.appendEvaluatedPositional(output, value, span);
                }
                for (argument_list.keywords) |*keyword| {
                    try self.appendEvaluatedSplatKeyword(output, .{
                        .name = keyword.name,
                        .value = &keyword.value,
                        .normalize_name = keyword.normalize_name,
                    }, span);
                }
            },
            else => try self.appendEvaluatedPositional(output, item, span),
        }
    }

    fn expandCallKeywordSplat(
        self: *Engine,
        output: *EvaluatedCallArguments,
        item: *const native_value.Value,
        span: native_source.Span,
    ) Error!void {
        const map = switch (item.*) {
            .map => |map| map,
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "native Sass variable keyword arguments require a map",
                );
                return error.InvalidExpression;
            },
        };
        for (map.entries) |*entry| {
            const name = switch (entry.key) {
                .string, .selector => |string| string.bytes,
                else => {
                    try self.report(
                        .type_mismatch,
                        span,
                        "native Sass keyword splat map requires string keys",
                    );
                    return error.InvalidExpression;
                },
            };
            try self.appendEvaluatedSplatKeyword(output, .{
                .name = name,
                .value = &entry.value,
                .normalize_name = false,
            }, span);
        }
    }

    fn appendEvaluatedPositional(
        self: *Engine,
        output: *EvaluatedCallArguments,
        item: *const native_value.Value,
        span: native_source.Span,
    ) Error!void {
        try self.reserveExpandedCallArgument(output, span);
        try output.positional.append(self.allocator, item);
    }

    fn appendEvaluatedKeyword(
        self: *Engine,
        output: *EvaluatedCallArguments,
        keyword: EvaluatedKeywordArgument,
        span: native_source.Span,
    ) Error!void {
        try self.reserveExpandedCallArgument(output, span);
        for (output.keywords.items) |previous| {
            if (callKeywordNamesEqual(previous, keyword)) {
                return self.argumentsFailure(error.DuplicateArgument, span);
            }
        }
        try output.keywords.append(self.allocator, keyword);
    }

    fn appendEvaluatedSplatKeyword(
        self: *Engine,
        output: *EvaluatedCallArguments,
        keyword: EvaluatedKeywordArgument,
        span: native_source.Span,
    ) Error!void {
        try self.reserveExpandedCallArgument(output, span);
        try output.splat_keywords.append(self.allocator, keyword);
    }

    fn mergeEvaluatedSplatKeywords(
        self: *Engine,
        output: *EvaluatedCallArguments,
    ) Error!void {
        for (output.splat_keywords.items) |keyword| {
            var matched = false;
            for (output.keywords.items) |*previous| {
                if (!callKeywordNamesEqual(previous.*, keyword)) continue;
                previous.value = keyword.value;
                matched = true;
                break;
            }
            if (!matched) try output.keywords.append(self.allocator, keyword);
        }
    }

    fn reserveExpandedCallArgument(
        self: *Engine,
        output: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!void {
        const direct_count = std.math.add(
            usize,
            output.positional.items.len,
            output.keywords.items.len,
        ) catch return self.argumentsFailure(error.ArgumentLimitExceeded, span);
        const count = std.math.add(
            usize,
            direct_count,
            output.splat_keywords.items.len,
        ) catch return self.argumentsFailure(error.ArgumentLimitExceeded, span);
        if (count >= self.limits.max_function_arguments) {
            return self.argumentsFailure(error.ArgumentLimitExceeded, span);
        }
    }

    fn bindCallableArguments(
        self: *Engine,
        parameters: []const CallableParameter,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!BoundCallableArguments {
        const values = try self.allocator.alloc(?*const native_value.Value, parameters.len);
        errdefer if (values.len > 0) self.allocator.free(values);
        @memset(values, null);

        const rest_index: ?usize = if (parameters.len > 0 and parameters[parameters.len - 1].rest)
            parameters.len - 1
        else
            null;
        const fixed_count = rest_index orelse parameters.len;
        var rest_positional: std.ArrayList(native_value.Value) = .empty;
        defer rest_positional.deinit(self.allocator);
        var rest_keywords: std.ArrayList(native_value.ArgumentKeyword) = .empty;
        defer rest_keywords.deinit(self.allocator);

        for (arguments.positional.items, 0..) |item, index| {
            if (index < fixed_count) {
                if (values[index] != null) {
                    return self.argumentsFailure(error.DuplicateArgument, span);
                }
                values[index] = item;
            } else if (rest_index != null) {
                try rest_positional.append(self.allocator, item.*);
            } else {
                return self.argumentsFailure(error.PositionalLimitExceeded, span);
            }
        }

        for (arguments.keywords.items) |keyword| {
            var matched: ?usize = null;
            for (parameters[0..fixed_count], 0..) |parameter, index| {
                const matches = if (keyword.normalize_name)
                    native_arguments.nameEql(keyword.name, parameter.name)
                else
                    std.mem.eql(u8, keyword.name, parameter.name);
                if (matches) {
                    matched = index;
                    break;
                }
            }
            if (matched) |index| {
                if (values[index] != null) {
                    return self.argumentsFailure(error.DuplicateArgument, span);
                }
                values[index] = keyword.value;
            } else if (rest_index != null) {
                try rest_keywords.append(self.allocator, .{
                    .name = keyword.name,
                    .value = keyword.value.*,
                    .normalize_name = keyword.normalize_name,
                });
            } else {
                return self.argumentsFailure(error.UnknownArgument, span);
            }
        }

        for (parameters[0..fixed_count], values[0..fixed_count]) |parameter, value| {
            if (parameter.default_value == null and value == null) {
                return self.argumentsFailure(error.MissingArgument, span);
            }
        }

        var rest_value: ?*const native_value.Value = null;
        if (rest_index) |index| {
            var state = native_value.ArgumentListState{};
            rest_value = try self.values.own(.{ .argument_list = .{
                .positional = rest_positional.items,
                .keywords = rest_keywords.items,
                .state = &state,
            } });
            values[index] = rest_value;
        }
        return .{
            .allocator = self.allocator,
            .values = values,
            .rest_value = rest_value,
        };
    }

    fn bindEvaluatedArguments(
        self: *Engine,
        parameters: []const native_arguments.Parameter,
        maximum_positional: usize,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!BoundEvaluatedArguments {
        if (maximum_positional > parameters.len) {
            return self.argumentsFailure(error.InvalidLimits, span);
        }
        const values = try self.allocator.alloc(
            ?*const native_value.Value,
            parameters.len,
        );
        errdefer if (values.len > 0) self.allocator.free(values);
        @memset(values, null);

        for (arguments.positional.items, 0..) |item, index| {
            if (index >= maximum_positional) {
                return self.argumentsFailure(error.PositionalLimitExceeded, span);
            }
            values[index] = item;
        }
        for (arguments.keywords.items) |keyword| {
            var matched: ?usize = null;
            for (parameters, 0..) |parameter, index| {
                const matches = if (keyword.normalize_name)
                    native_arguments.nameEql(keyword.name, parameter.name)
                else
                    std.mem.eql(u8, keyword.name, parameter.name);
                if (!matches) continue;
                matched = index;
                break;
            }
            const index = matched orelse
                return self.argumentsFailure(error.UnknownArgument, span);
            if (values[index] != null) {
                return self.argumentsFailure(error.DuplicateArgument, span);
            }
            values[index] = keyword.value;
        }
        for (parameters, values) |parameter, value| {
            if (parameter.required and value == null) {
                return self.argumentsFailure(error.MissingArgument, span);
            }
        }
        return .{
            .allocator = self.allocator,
            .values = values,
        };
    }

    fn ensureRestKeywordsConsumed(
        self: *Engine,
        rest_value: ?*const native_value.Value,
        span: native_source.Span,
    ) Error!void {
        const item = rest_value orelse return;
        const argument_list = switch (item.*) {
            .argument_list => |value| value,
            else => return error.InvalidSassSyntax,
        };
        if (argument_list.keywords.len > 0 and !argument_list.state.keywords_accessed) {
            return self.argumentsFailure(error.UnknownArgument, span);
        }
    }

    fn lookupUserMixin(
        self: *Engine,
        raw_name: []const u8,
        scope: native_environment.ScopeId,
    ) Error!?u32 {
        const name = try self.normalizeCallableName(raw_name);
        defer self.allocator.free(name);
        const key = try self.callableKey("@mixin:", name);
        defer self.allocator.free(key);
        const item = if (try self.environment.lookupNonGlobal(scope, key)) |local|
            local
        else
            try self.environment.lookup(self.global_scope, key) orelse return null;
        return switch (item.*) {
            .callable => |callable| if (callable.kind == .mixin and
                callable.id < self.user_mixins.items.len)
                callable.id
            else
                error.InvalidSassSyntax,
            else => error.InvalidSassSyntax,
        };
    }

    fn callUserMixin(
        self: *Engine,
        mixin_id: u32,
        body: []const u8,
        ranges: []const ExpressionRange,
        caller_scope: *ScopeFrame,
        content_block: ?native_syntax.NodeId,
        content_parameters: []const CallableParameter,
        span: native_source.Span,
        depth: u16,
        context: LoopBodyContext,
    ) Error!void {
        if (mixin_id >= self.user_mixins.items.len or context == .callable) {
            return error.InvalidSassSyntax;
        }
        const mixin = &self.user_mixins.items[mixin_id];
        if (content_block != null and !mixin.accepts_content) {
            try self.report(.syntax, span, "native Sass mixin does not accept a content block");
            return error.InvalidSassSyntax;
        }
        var evaluated = try self.evaluateCallArguments(
            body,
            ranges,
            caller_scope.cursor,
            span,
        );
        defer evaluated.deinit();
        var bound = try self.bindCallableArguments(mixin.parameters, &evaluated, span);
        defer bound.deinit();

        const previous_mixin_body = self.active_mixin_body;
        self.active_mixin_body = false;
        defer self.active_mixin_body = previous_mixin_body;

        try self.transaction.enterCall();
        var active_call = true;
        defer if (active_call) self.transaction.leaveCall() catch {};
        var call_scope = ScopeFrame{
            .cursor = try self.environment.push(mixin.owner.cursor),
            .kind = .lexical,
            .parent = mixin.owner,
        };
        for (mixin.parameters, 0..) |parameter, index| {
            const item = bound.values[index] orelse try self.evaluateExpressionBytes(
                parameter.default_value orelse return error.InvalidSassSyntax,
                call_scope.cursor,
                mixin.span,
            );
            try self.defineOwnedVariable(&call_scope, parameter.name, item);
        }

        const previous_content = self.active_content;
        var invocation: ContentInvocation = undefined;
        self.active_content = if (content_block) |block| blk: {
            invocation = .{
                .block = block,
                .owner = caller_scope,
                .captured_content = previous_content,
                .parameters = content_parameters,
            };
            break :blk &invocation;
        } else null;
        defer self.active_content = previous_content;

        self.active_mixin_body = true;
        const children = self.document.children(mixin.block) catch return error.InvalidSassSyntax;
        try self.executeLoopBody(children, &call_scope, depth + 1, context);
        try self.ensureRestKeywordsConsumed(bound.rest_value, span);
        active_call = false;
        try self.transaction.leaveCall();
    }

    fn parseContentArgumentBody(
        self: *Engine,
        content_id: native_syntax.NodeId,
        ranges: *std.ArrayList(ExpressionRange),
    ) Error![]const u8 {
        const content_node = self.document.get(content_id) catch return error.InvalidSassSyntax;
        const children = self.document.children(content_id) catch return error.InvalidSassSyntax;
        if (content_node.kind != .content or children.len > 1) {
            try self.report(.syntax, content_node.span, "malformed native Sass @content");
            return error.InvalidSassSyntax;
        }
        if (children.len == 0) return "";
        const expression = self.document.get(children[0]) catch return error.InvalidSassSyntax;
        if (expression.kind != .expression or expression.text == null) {
            try self.report(.syntax, content_node.span, "malformed native Sass @content arguments");
            return error.InvalidSassSyntax;
        }
        const raw = trimWhitespace(try self.sources.slice(expression.text.?));
        if (!fullyWrapped(raw, '(', ')')) {
            try self.report(.syntax, expression.span, "malformed native Sass @content argument list");
            return error.InvalidSassSyntax;
        }
        const body = raw[1 .. raw.len - 1];
        _ = try splitTopLevelRanges(self.allocator, body, .comma, ranges);
        if (trimWhitespace(body).len == 0) ranges.clearRetainingCapacity();
        if (ranges.items.len > 0) {
            const final = ranges.items[ranges.items.len - 1];
            if (trimWhitespace(body[final.start..final.end]).len == 0) ranges.items.len -= 1;
        }
        return body;
    }

    fn executeContentDirective(
        self: *Engine,
        content_id: native_syntax.NodeId,
        scope: *ScopeFrame,
        depth: u16,
        context: LoopBodyContext,
    ) Error!void {
        const content_node = self.document.get(content_id) catch return error.InvalidSassSyntax;
        if (content_node.kind != .content or context == .callable) {
            try self.report(.syntax, content_node.span, "malformed native Sass @content");
            return error.InvalidSassSyntax;
        }
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        const body = try self.parseContentArgumentBody(content_id, &ranges);
        const invocation = self.active_content orelse return;
        var evaluated = try self.evaluateCallArguments(
            body,
            ranges.items,
            scope.cursor,
            content_node.span,
        );
        defer evaluated.deinit();
        var bound = try self.bindCallableArguments(
            invocation.parameters,
            &evaluated,
            content_node.span,
        );
        defer bound.deinit();

        const previous_mixin_body = self.active_mixin_body;
        self.active_mixin_body = false;
        defer self.active_mixin_body = previous_mixin_body;

        try self.transaction.enterCall();
        var active_call = true;
        defer if (active_call) self.transaction.leaveCall() catch {};
        const previous_content = self.active_content;
        self.active_content = invocation.captured_content;
        defer self.active_content = previous_content;

        var content_scope = ScopeFrame{
            .cursor = try self.environment.push(invocation.owner.cursor),
            .kind = .lexical,
            .parent = invocation.owner,
        };
        for (invocation.parameters, 0..) |parameter, index| {
            const item = bound.values[index] orelse try self.evaluateExpressionBytes(
                parameter.default_value orelse return error.InvalidSassSyntax,
                content_scope.cursor,
                content_node.span,
            );
            try self.defineOwnedVariable(&content_scope, parameter.name, item);
        }
        const content_children = self.document.children(invocation.block) catch
            return error.InvalidSassSyntax;
        try self.executeLoopBody(content_children, &content_scope, depth + 1, context);
        try self.ensureRestKeywordsConsumed(bound.rest_value, content_node.span);
        active_call = false;
        try self.transaction.leaveCall();
    }

    fn callableLimitReached(self: *const Engine) bool {
        const total = std.math.add(
            usize,
            self.user_functions.items.len,
            self.user_mixins.items.len,
        ) catch return true;
        return total >= self.limits.max_callables;
    }

    fn defineUserFunction(
        self: *Engine,
        function_id: native_syntax.NodeId,
        scope: *ScopeFrame,
    ) Error!void {
        const function_node = self.document.get(function_id) catch return error.InvalidSassSyntax;
        if (scope.kind == .flow) {
            try self.report(.syntax, function_node.span, "Sass functions may not be declared in control flow");
            return error.InvalidSassSyntax;
        }
        if (self.callableLimitReached() or
            self.user_functions.items.len >= std.math.maxInt(u32))
        {
            try self.report(.resource_limit, function_node.span, "native Sass callable limit exceeded");
            return error.CallableLimitExceeded;
        }

        var function = try self.parseUserFunction(function_id, scope);
        errdefer function.deinit();
        const callable_id: u32 = @intCast(self.user_functions.items.len);
        const callable = try self.values.own(.{ .callable = .{
            .kind = .user_function,
            .id = callable_id,
        } });
        const key = try self.callableKey("@function:", function.name);
        defer self.allocator.free(key);
        if (scope.kind == .global) {
            try self.assignGlobalVariable(scope, key, callable);
        } else {
            scope.cursor = try self.environment.set(scope.cursor, key, callable);
        }
        try self.user_functions.append(self.allocator, function);
    }

    fn parseUserFunction(
        self: *Engine,
        function_id: native_syntax.NodeId,
        owner: *ScopeFrame,
    ) Error!UserFunction {
        const function_node = self.document.get(function_id) catch return error.InvalidSassSyntax;
        const children = self.document.children(function_id) catch return error.InvalidSassSyntax;
        if (function_node.kind != .function or function_node.text == null or children.len != 2) {
            try self.report(.syntax, function_node.span, "malformed native Sass function declaration");
            return error.InvalidSassSyntax;
        }
        const prelude_node = self.document.get(children[0]) catch return error.InvalidSassSyntax;
        const block_node = self.document.get(children[1]) catch return error.InvalidSassSyntax;
        if (prelude_node.kind != .expression or prelude_node.text == null or block_node.kind != .block) {
            try self.report(.syntax, function_node.span, "native Sass function requires a signature and block");
            return error.InvalidSassSyntax;
        }

        const prelude = trimWhitespace(try self.sources.slice(prelude_node.text.?));
        const opening = std.mem.indexOfScalar(u8, prelude, '(') orelse {
            try self.report(.syntax, prelude_node.span, "native Sass function signature requires parentheses");
            return error.InvalidSassSyntax;
        };
        if (!fullyWrapped(prelude[opening..], '(', ')')) {
            try self.report(.syntax, prelude_node.span, "malformed native Sass function parameter list");
            return error.InvalidSassSyntax;
        }
        const raw_name = trimWhitespace(prelude[0..opening]);
        if (!isSimpleIdentifier(raw_name) or std.mem.startsWith(u8, raw_name, "--")) {
            try self.report(.syntax, prelude_node.span, "invalid native Sass function name");
            return error.InvalidSassSyntax;
        }
        const name = try self.normalizeCallableName(raw_name);
        errdefer self.allocator.free(name);

        const body = prelude[opening + 1 .. prelude.len - 1];
        const owned_parameters = try self.parseCallableParameters(body, prelude_node.span);
        return .{
            .allocator = self.allocator,
            .name = name,
            .parameters = owned_parameters,
            .block = children[1],
            .owner = owner,
            .span = function_node.span,
        };
    }

    fn tryUserFunctionCall(
        self: *Engine,
        raw: []const u8,
        caller_scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const opening = std.mem.indexOfScalar(u8, raw, '(') orelse return null;
        if (opening == 0 or !fullyWrapped(raw[opening..], '(', ')')) return null;
        const raw_name = raw[0..opening];
        if (legacyIfIdentifierEql(raw_name)) return null;
        if (!isSimpleIdentifier(raw_name)) return null;
        const function_id = try self.lookupUserFunction(raw_name, caller_scope) orelse return null;
        const body = raw[opening + 1 .. raw.len - 1];
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        _ = try splitTopLevelRanges(self.allocator, body, .comma, &ranges);
        if (trimWhitespace(body).len == 0) ranges.clearRetainingCapacity();
        if (ranges.items.len > 0) {
            const final = ranges.items[ranges.items.len - 1];
            if (trimWhitespace(body[final.start..final.end]).len == 0) ranges.items.len -= 1;
        }
        return try self.callUserFunction(
            function_id,
            body,
            ranges.items,
            caller_scope,
            span,
        );
    }

    fn lookupUserFunction(
        self: *Engine,
        raw_name: []const u8,
        scope: native_environment.ScopeId,
    ) Error!?u32 {
        const name = try self.normalizeCallableName(raw_name);
        defer self.allocator.free(name);
        const key = try self.callableKey("@function:", name);
        defer self.allocator.free(key);
        const item = if (try self.environment.lookupNonGlobal(scope, key)) |local|
            local
        else
            try self.environment.lookup(self.global_scope, key) orelse return null;
        return switch (item.*) {
            .callable => |callable| if (callable.kind == .user_function and
                callable.id < self.user_functions.items.len)
                callable.id
            else
                error.InvalidSassSyntax,
            else => error.InvalidSassSyntax,
        };
    }

    fn callUserFunction(
        self: *Engine,
        function_id: u32,
        body: []const u8,
        ranges: []const ExpressionRange,
        caller_scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (function_id >= self.user_functions.items.len) return error.InvalidSassSyntax;
        var evaluated = try self.evaluateCallArguments(
            body,
            ranges,
            caller_scope,
            span,
        );
        defer evaluated.deinit();
        return self.invokeUserFunction(function_id, &evaluated, span);
    }

    fn invokeUserFunction(
        self: *Engine,
        function_id: u32,
        evaluated: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (function_id >= self.user_functions.items.len) return error.InvalidSassSyntax;
        const function = &self.user_functions.items[function_id];
        var bound = try self.bindCallableArguments(function.parameters, evaluated, span);
        defer bound.deinit();

        const previous_mixin_body = self.active_mixin_body;
        self.active_mixin_body = false;
        defer self.active_mixin_body = previous_mixin_body;

        try self.transaction.enterCall();
        var active_call = true;
        defer if (active_call) self.transaction.leaveCall() catch {};
        var call_scope = ScopeFrame{
            .cursor = try self.environment.push(function.owner.cursor),
            .kind = .lexical,
            .parent = function.owner,
        };
        for (function.parameters, 0..) |parameter, index| {
            const item = bound.values[index] orelse try self.evaluateExpressionBytes(
                parameter.default_value orelse return error.InvalidSassSyntax,
                call_scope.cursor,
                function.span,
            );
            try self.defineOwnedVariable(&call_scope, parameter.name, item);
        }

        var return_value: ?*const native_value.Value = null;
        const children = self.document.children(function.block) catch return error.InvalidSassSyntax;
        try self.executeFunctionChildren(children, &call_scope, 1, &return_value);
        if (return_value == null) {
            try self.report(.syntax, function.span, "native Sass function finished without @return");
            return error.InvalidSassSyntax;
        }
        try self.ensureRestKeywordsConsumed(bound.rest_value, span);
        active_call = false;
        try self.transaction.leaveCall();
        return return_value.?;
    }

    fn executeFunctionChildren(
        self: *Engine,
        children: []const native_syntax.NodeId,
        scope: *ScopeFrame,
        depth: u16,
        return_value: *?*const native_value.Value,
    ) Error!void {
        if (depth > self.limits.max_evaluation_depth) {
            const span = if (children.len > 0)
                (self.document.get(children[0]) catch return error.InvalidSassSyntax).span
            else
                (self.document.get(self.document.root) catch return error.InvalidSassSyntax).span;
            try self.report(.resource_limit, span, "native Sass function evaluation depth exceeded");
            return error.EvaluationDepthExceeded;
        }
        var index: usize = 0;
        while (index < children.len) {
            if (return_value.* != null) return;
            try self.transaction.consumeOperations(1);
            const child_id = children[index];
            const child = self.document.get(child_id) catch return error.InvalidSassSyntax;
            switch (child.kind) {
                .declaration => {
                    if (!try self.isVariableDeclaration(child_id)) {
                        try self.report(.syntax, child.span, "Sass functions may not emit declarations");
                        return error.InvalidSassSyntax;
                    }
                    try self.assignVariable(child_id, scope);
                },
                .comment => {},
                .return_statement => try self.evaluateFunctionReturn(child_id, scope, return_value),
                .conditional => {
                    const selection = try self.selectConditionalChain(children, index, scope.cursor);
                    if (selection.block) |block_id| {
                        const block_children = self.document.children(block_id) catch
                            return error.InvalidSassSyntax;
                        var branch_scope = try self.beginFlowScope(scope);
                        try self.executeFunctionChildren(
                            block_children,
                            &branch_scope,
                            depth + 1,
                            return_value,
                        );
                    }
                    index += selection.consumed;
                    continue;
                },
                .loop => try self.executeLoop(child_id, scope, depth, .{ .callable = return_value }),
                else => {
                    try self.report(.syntax, child.span, "statement is not valid inside a native Sass function");
                    return error.InvalidSassSyntax;
                },
            }
            index += 1;
        }
    }

    fn evaluateFunctionReturn(
        self: *Engine,
        return_id: native_syntax.NodeId,
        scope: *ScopeFrame,
        return_value: *?*const native_value.Value,
    ) Error!void {
        const return_node = self.document.get(return_id) catch return error.InvalidSassSyntax;
        const children = self.document.children(return_id) catch return error.InvalidSassSyntax;
        if (return_node.kind != .return_statement or children.len != 1) {
            try self.report(.syntax, return_node.span, "malformed native Sass @return");
            return error.InvalidSassSyntax;
        }
        const expression = self.document.get(children[0]) catch return error.InvalidSassSyntax;
        if (expression.kind != .expression or expression.text == null) {
            try self.report(.syntax, return_node.span, "native Sass @return requires an expression");
            return error.InvalidSassSyntax;
        }
        return_value.* = try self.evaluateExpression(expression.text.?, scope.cursor);
    }

    fn normalizeCallableName(self: *Engine, raw_name: []const u8) Error![]u8 {
        if (!isSimpleIdentifier(raw_name) or raw_name.len > self.limits.max_temporary_bytes) {
            return error.InvalidSassSyntax;
        }
        const normalized = try self.allocator.dupe(u8, raw_name);
        for (normalized) |*byte| {
            if (byte.* == '_') byte.* = '-';
        }
        return normalized;
    }

    fn callableKey(self: *Engine, prefix: []const u8, name: []const u8) Error![]u8 {
        const length = std.math.add(usize, prefix.len, name.len) catch
            return error.TemporaryLimitExceeded;
        if (length > self.limits.max_temporary_bytes) return error.TemporaryLimitExceeded;
        const key = try self.allocator.alloc(u8, length);
        @memcpy(key[0..prefix.len], prefix);
        @memcpy(key[prefix.len..], name);
        return key;
    }

    fn executeLoop(
        self: *Engine,
        loop_id: native_syntax.NodeId,
        parent_scope: *ScopeFrame,
        depth: u16,
        context: LoopBodyContext,
    ) Error!void {
        const loop_node = self.document.get(loop_id) catch return error.InvalidSassSyntax;
        const children = self.document.children(loop_id) catch return error.InvalidSassSyntax;
        if (loop_node.kind != .loop or loop_node.text == null or children.len != 2) {
            try self.report(.syntax, loop_node.span, "malformed native Sass loop directive");
            return error.InvalidSassSyntax;
        }
        const prelude_node = self.document.get(children[0]) catch return error.InvalidSassSyntax;
        const block_node = self.document.get(children[1]) catch return error.InvalidSassSyntax;
        if (prelude_node.kind != .expression or prelude_node.text == null or
            block_node.kind != .block)
        {
            try self.report(.syntax, loop_node.span, "native Sass loop requires a prelude and block");
            return error.InvalidSassSyntax;
        }
        const keyword = try self.sources.slice(loop_node.text.?);
        const prelude = try self.sources.slice(prelude_node.text.?);
        const body = self.document.children(children[1]) catch return error.InvalidSassSyntax;
        if (std.ascii.eqlIgnoreCase(keyword, "@for")) {
            try self.executeForLoop(prelude, prelude_node.span, body, parent_scope, depth, context);
        } else if (std.ascii.eqlIgnoreCase(keyword, "@each")) {
            try self.executeEachLoop(prelude, prelude_node.span, body, parent_scope, depth, context);
        } else if (std.ascii.eqlIgnoreCase(keyword, "@while")) {
            try self.executeWhileLoop(prelude, prelude_node.span, body, parent_scope, depth, context);
        } else {
            try self.report(.syntax, loop_node.span, "unknown native Sass loop directive");
            return error.InvalidSassSyntax;
        }
    }

    fn executeForLoop(
        self: *Engine,
        prelude: []const u8,
        span: native_source.Span,
        body: []const native_syntax.NodeId,
        parent_scope: *ScopeFrame,
        depth: u16,
        context: LoopBodyContext,
    ) Error!void {
        const parsed = try self.parseForLoop(prelude, span);
        defer self.allocator.free(parsed.name);
        const start_value = try self.evaluateExpressionBytes(parsed.start, parent_scope.cursor, span);
        const end_value = try self.evaluateExpressionBytes(parsed.end, parent_scope.cursor, span);
        var current = try self.requireLoopInteger(start_value.*, span);
        const end = try self.requireLoopInteger(end_value.*, span);
        const initial_order = try self.compareLoopNumbers(current, end, span);
        const descending = initial_order == .greater;
        var loop_scope = try self.beginFlowScope(parent_scope);

        while (true) {
            const ordering = try self.compareLoopNumbers(current, end, span);
            const execute = if (descending)
                if (parsed.inclusive) ordering != .less else ordering == .greater
            else if (parsed.inclusive)
                ordering != .greater
            else
                ordering == .less;
            if (!execute) break;

            try self.transaction.consumeLoopIterations(1);
            var numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
            var denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
            const item = try self.values.own(.{ .number = try current.toNumber(
                &numerator,
                &denominator,
            ) });
            try self.assignOwnedVariable(&loop_scope, parsed.name, item);
            try self.executeLoopBody(body, &loop_scope, depth + 1, context);
            if (loopBodyReturned(context)) return;
            if (parsed.inclusive and ordering == .equal) break;

            const step: f64 = if (descending) -1 else 1;
            const next = current.value + step;
            if (!std.math.isFinite(next) or next == current.value) {
                try self.report(.invalid_operation, span, "native Sass @for range cannot advance");
                return error.InvalidExpression;
            }
            current.value = next;
        }
    }

    fn executeEachLoop(
        self: *Engine,
        prelude: []const u8,
        span: native_source.Span,
        body: []const native_syntax.NodeId,
        parent_scope: *ScopeFrame,
        depth: u16,
        context: LoopBodyContext,
    ) Error!void {
        var parsed = try self.parseEachLoop(prelude, span);
        defer parsed.deinit();
        const iterable = try self.evaluateExpressionBytes(parsed.iterable, parent_scope.cursor, span);
        var loop_scope = try self.beginFlowScope(parent_scope);
        switch (iterable.*) {
            .list => |list| {
                for (list.items, 0..) |_, index| {
                    try self.executeEachIteration(
                        &loop_scope,
                        parsed.names,
                        &list.items[index],
                        null,
                        body,
                        depth,
                        context,
                    );
                    if (loopBodyReturned(context)) return;
                }
            },
            .argument_list => |argument_list| {
                for (argument_list.positional, 0..) |_, index| {
                    try self.executeEachIteration(
                        &loop_scope,
                        parsed.names,
                        &argument_list.positional[index],
                        null,
                        body,
                        depth,
                        context,
                    );
                    if (loopBodyReturned(context)) return;
                }
            },
            .map => |map| {
                for (map.entries, 0..) |_, index| {
                    try self.executeEachIteration(
                        &loop_scope,
                        parsed.names,
                        null,
                        &map.entries[index],
                        body,
                        depth,
                        context,
                    );
                    if (loopBodyReturned(context)) return;
                }
            },
            else => try self.executeEachIteration(
                &loop_scope,
                parsed.names,
                iterable,
                null,
                body,
                depth,
                context,
            ),
        }
    }

    fn executeEachIteration(
        self: *Engine,
        loop_scope: *ScopeFrame,
        names: []const []u8,
        item: ?*const native_value.Value,
        map_entry: ?*const native_value.Entry,
        body: []const native_syntax.NodeId,
        depth: u16,
        context: LoopBodyContext,
    ) Error!void {
        try self.transaction.consumeLoopIterations(1);
        if (names.len == 1 and map_entry != null) {
            const entry = map_entry.?;
            const pair = [_]native_value.Value{ entry.key, entry.value };
            const pair_value = try self.values.own(.{ .list = .{
                .items = &pair,
                .separator = .space,
            } });
            try self.assignOwnedVariable(loop_scope, names[0], pair_value);
        } else {
            var null_value: ?*const native_value.Value = null;
            for (names, 0..) |name, index| {
                const value = if (map_entry) |entry|
                    if (index == 0) &entry.key else if (index == 1) &entry.value else null
                else if (item) |single|
                    switch (single.*) {
                        .list => |list| if (index < list.items.len) &list.items[index] else null,
                        .argument_list => |argument_list| if (index < argument_list.positional.len)
                            &argument_list.positional[index]
                        else
                            null,
                        else => if (index == 0) single else null,
                    }
                else
                    null;
                if (value) |present| {
                    try self.assignOwnedVariable(loop_scope, name, present);
                } else {
                    if (null_value == null) {
                        null_value = try self.values.own(.{ .null_value = {} });
                    }
                    try self.assignOwnedVariable(loop_scope, name, null_value.?);
                }
            }
        }
        try self.executeLoopBody(body, loop_scope, depth + 1, context);
    }

    fn executeWhileLoop(
        self: *Engine,
        prelude: []const u8,
        span: native_source.Span,
        body: []const native_syntax.NodeId,
        parent_scope: *ScopeFrame,
        depth: u16,
        context: LoopBodyContext,
    ) Error!void {
        if (trimWhitespace(prelude).len == 0) {
            try self.report(.syntax, span, "native Sass @while requires a condition");
            return error.InvalidSassSyntax;
        }
        var loop_scope = try self.beginFlowScope(parent_scope);
        while (true) {
            const condition = try self.evaluateExpressionBytes(prelude, loop_scope.cursor, span);
            if (!sassTruthy(condition.*)) break;
            try self.transaction.consumeLoopIterations(1);
            try self.executeLoopBody(body, &loop_scope, depth + 1, context);
            if (loopBodyReturned(context)) return;
        }
    }

    fn executeLoopBody(
        self: *Engine,
        body: []const native_syntax.NodeId,
        scope: *ScopeFrame,
        depth: u16,
        context: LoopBodyContext,
    ) Error!void {
        switch (context) {
            .root => try self.executeRootChildren(body, scope, depth),
            .rule => |rule| try self.executeRuleChildren(
                body,
                rule.owner_span,
                rule.selectors,
                scope,
                rule.declarations,
                depth,
            ),
            .callable => |return_value| try self.executeFunctionChildren(
                body,
                scope,
                depth,
                return_value,
            ),
        }
    }

    fn requireLoopInteger(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!Numeric {
        const number = switch (item) {
            .number => |number| number,
            else => {
                try self.report(.type_mismatch, span, "native Sass @for bounds must be integers");
                return error.InvalidExpression;
            },
        };
        if (!std.math.isFinite(number.value) or @floor(number.value) != number.value) {
            try self.report(.invalid_operation, span, "native Sass @for bounds must be integers");
            return error.InvalidExpression;
        }
        return native_numeric.Numeric.fromNumber(number);
    }

    fn compareLoopNumbers(
        self: *Engine,
        left: Numeric,
        right: Numeric,
        span: native_source.Span,
    ) Error!native_numeric.Ordering {
        return native_numeric.compare(left, right) catch |err| {
            try self.report(.invalid_operation, span, "native Sass @for bounds use incompatible units");
            return err;
        };
    }

    fn assignOwnedVariable(
        self: *Engine,
        scope: *ScopeFrame,
        name: []const u8,
        item: *const native_value.Value,
    ) Error!void {
        if (try self.scopeOwnsVariable(scope, name)) {
            scope.cursor = try self.environment.set(scope.cursor, name, item);
        } else {
            try self.defineOwnedVariable(scope, name, item);
        }
    }

    fn parseForLoop(
        self: *Engine,
        prelude: []const u8,
        span: native_source.Span,
    ) Error!ParsedForLoop {
        var options = native_lexer.Options{};
        options.max_input_bytes = @max(prelude.len, 1);
        options.max_tokens = self.limits.max_expression_tokens;
        const tokens = try native_lexer.tokenizeAlloc(self.allocator, prelude, .scss, options);
        defer self.allocator.free(tokens);

        var cursor: usize = 0;
        while (cursor < tokens.len and isExpressionTrivia(tokens[cursor].kind)) cursor += 1;
        if (cursor >= tokens.len or tokens[cursor].kind != .variable) {
            try self.report(.syntax, span, "native Sass @for requires one loop variable");
            return error.InvalidSassSyntax;
        }
        const name = try self.normalizeVariable(tokens[cursor].raw(prelude));
        errdefer self.allocator.free(name);
        cursor += 1;
        while (cursor < tokens.len and isExpressionTrivia(tokens[cursor].kind)) cursor += 1;
        if (cursor >= tokens.len or tokens[cursor].kind != .identifier or
            !std.ascii.eqlIgnoreCase(tokens[cursor].raw(prelude), "from"))
        {
            try self.report(.syntax, span, "native Sass @for requires 'from'");
            return error.InvalidSassSyntax;
        }
        cursor += 1;

        var start_offset: ?u32 = null;
        var start_end: u32 = 0;
        var separator: ?native_lexer.Token = null;
        var inclusive = false;
        var nesting: usize = 0;
        while (cursor < tokens.len) : (cursor += 1) {
            const token = tokens[cursor];
            if (token.kind == .eof) break;
            if (isExpressionTrivia(token.kind)) continue;
            if (nesting == 0 and token.kind == .identifier and start_offset != null) {
                const word = token.raw(prelude);
                if (std.ascii.eqlIgnoreCase(word, "through") or
                    std.ascii.eqlIgnoreCase(word, "to"))
                {
                    separator = token;
                    inclusive = std.ascii.eqlIgnoreCase(word, "through");
                    cursor += 1;
                    break;
                }
            }
            if (start_offset == null) start_offset = token.span.start;
            start_end = token.span.end;
            switch (token.kind) {
                .open_paren, .open_square, .open_curly, .interpolation_start => nesting += 1,
                .close_paren, .close_square, .close_curly, .interpolation_end => {
                    if (nesting > 0) nesting -= 1;
                },
                else => {},
            }
        }
        if (start_offset == null or separator == null) {
            try self.report(.syntax, span, "native Sass @for requires 'to' or 'through'");
            return error.InvalidSassSyntax;
        }

        var end_offset: ?u32 = null;
        var end_end: u32 = 0;
        while (cursor < tokens.len) : (cursor += 1) {
            const token = tokens[cursor];
            if (token.kind == .eof) break;
            if (isExpressionTrivia(token.kind)) continue;
            if (end_offset == null) end_offset = token.span.start;
            end_end = token.span.end;
        }
        if (end_offset == null) {
            try self.report(.syntax, span, "native Sass @for range is missing its end");
            return error.InvalidSassSyntax;
        }
        return .{
            .name = name,
            .start = trimWhitespace(prelude[start_offset.?..start_end]),
            .end = trimWhitespace(prelude[end_offset.?..end_end]),
            .inclusive = inclusive,
        };
    }

    fn parseEachLoop(
        self: *Engine,
        prelude: []const u8,
        span: native_source.Span,
    ) Error!ParsedEachLoop {
        var options = native_lexer.Options{};
        options.max_input_bytes = @max(prelude.len, 1);
        options.max_tokens = self.limits.max_expression_tokens;
        const tokens = try native_lexer.tokenizeAlloc(self.allocator, prelude, .scss, options);
        defer self.allocator.free(tokens);

        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit(self.allocator);
        }
        var cursor: usize = 0;
        var found_in = false;
        while (true) {
            while (cursor < tokens.len and isExpressionTrivia(tokens[cursor].kind)) cursor += 1;
            if (cursor >= tokens.len or tokens[cursor].kind != .variable) {
                try self.report(.syntax, span, "native Sass @each requires comma-separated variables");
                return error.InvalidSassSyntax;
            }
            if (names.items.len >= self.limits.max_loop_variables) {
                try self.report(.resource_limit, span, "native Sass loop variable limit exceeded");
                return error.LoopVariableLimitExceeded;
            }
            const name = try self.normalizeVariable(tokens[cursor].raw(prelude));
            names.append(self.allocator, name) catch |err| {
                self.allocator.free(name);
                return err;
            };
            cursor += 1;
            while (cursor < tokens.len and isExpressionTrivia(tokens[cursor].kind)) cursor += 1;
            if (cursor < tokens.len and tokens[cursor].kind == .identifier and
                std.ascii.eqlIgnoreCase(tokens[cursor].raw(prelude), "in"))
            {
                found_in = true;
                cursor += 1;
                break;
            }
            if (cursor >= tokens.len or tokens[cursor].kind != .comma) {
                try self.report(.syntax, span, "native Sass @each requires 'in'");
                return error.InvalidSassSyntax;
            }
            cursor += 1;
        }
        if (!found_in or names.items.len == 0) {
            try self.report(.syntax, span, "native Sass @each requires variables and 'in'");
            return error.InvalidSassSyntax;
        }

        var iterable_offset: ?u32 = null;
        var iterable_end: u32 = 0;
        while (cursor < tokens.len) : (cursor += 1) {
            const token = tokens[cursor];
            if (token.kind == .eof) break;
            if (isExpressionTrivia(token.kind)) continue;
            if (iterable_offset == null) iterable_offset = token.span.start;
            iterable_end = token.span.end;
        }
        if (iterable_offset == null) {
            try self.report(.syntax, span, "native Sass @each iterable is missing");
            return error.InvalidSassSyntax;
        }
        return .{
            .allocator = self.allocator,
            .names = try names.toOwnedSlice(self.allocator),
            .iterable = trimWhitespace(prelude[iterable_offset.?..iterable_end]),
        };
    }

    fn selectConditionalChain(
        self: *Engine,
        siblings: []const native_syntax.NodeId,
        start: usize,
        scope: native_environment.ScopeId,
    ) Error!ConditionalSelection {
        if (start >= siblings.len) return error.InvalidSassSyntax;

        var selected: ?native_syntax.NodeId = null;
        var consumed: usize = 0;
        var saw_else = false;
        var index = start;
        while (index < siblings.len) : (index += 1) {
            const node_id = siblings[index];
            const node = self.document.get(node_id) catch return error.InvalidSassSyntax;
            if (node.kind != .conditional) break;

            const directive = try self.classifyConditionalDirective(node);
            if (index == start) {
                if (directive != .if_branch) {
                    try self.report(.syntax, node.span, "Sass @else must follow an @if branch");
                    return error.InvalidSassSyntax;
                }
            } else {
                if (directive == .if_branch) break;
                try self.transaction.consumeOperations(1);
            }

            const children = self.document.children(node_id) catch
                return error.InvalidSassSyntax;
            var condition: ?struct {
                bytes: []const u8,
                span: native_source.Span,
            } = null;
            var block_id: native_syntax.NodeId = undefined;

            switch (directive) {
                .if_branch => {
                    if (children.len != 2) {
                        try self.report(
                            .syntax,
                            node.span,
                            "Sass @if requires a condition and a block",
                        );
                        return error.InvalidSassSyntax;
                    }
                    const expression = self.document.get(children[0]) catch
                        return error.InvalidSassSyntax;
                    if (expression.kind != .expression or expression.text == null) {
                        try self.report(.syntax, node.span, "Sass @if condition is malformed");
                        return error.InvalidSassSyntax;
                    }
                    const raw = trimWhitespace(try self.sources.slice(expression.text.?));
                    if (raw.len == 0) {
                        try self.report(.syntax, expression.span, "Sass @if condition is empty");
                        return error.InvalidSassSyntax;
                    }
                    condition = .{ .bytes = raw, .span = expression.span };
                    block_id = children[1];
                },
                .else_branch => {
                    if (children.len == 1) {
                        if (saw_else) {
                            try self.report(.syntax, node.span, "Sass conditional has multiple @else branches");
                            return error.InvalidSassSyntax;
                        }
                        saw_else = true;
                        block_id = children[0];
                    } else if (children.len == 2) {
                        if (saw_else) {
                            try self.report(.syntax, node.span, "Sass @else if cannot follow @else");
                            return error.InvalidSassSyntax;
                        }
                        const expression = self.document.get(children[0]) catch
                            return error.InvalidSassSyntax;
                        if (expression.kind != .expression or expression.text == null) {
                            try self.report(.syntax, node.span, "Sass @else if condition is malformed");
                            return error.InvalidSassSyntax;
                        }
                        const prelude = trimWhitespace(try self.sources.slice(expression.text.?));
                        if (prelude.len <= 2 or
                            !std.ascii.eqlIgnoreCase(prelude[0..2], "if") or
                            !isExpressionWhitespace(prelude[2]))
                        {
                            try self.report(
                                .syntax,
                                expression.span,
                                "Sass @else only accepts an optional 'if' condition",
                            );
                            return error.InvalidSassSyntax;
                        }
                        const raw = trimWhitespace(prelude[2..]);
                        if (raw.len == 0) {
                            try self.report(.syntax, expression.span, "Sass @else if condition is empty");
                            return error.InvalidSassSyntax;
                        }
                        condition = .{ .bytes = raw, .span = expression.span };
                        block_id = children[1];
                    } else {
                        try self.report(
                            .syntax,
                            node.span,
                            "Sass @else requires a block and an optional 'if' condition",
                        );
                        return error.InvalidSassSyntax;
                    }
                },
            }

            const block = self.document.get(block_id) catch return error.InvalidSassSyntax;
            if (block.kind != .block) {
                try self.report(.syntax, node.span, "Sass conditional branch is missing a block");
                return error.InvalidSassSyntax;
            }

            if (selected == null) {
                if (condition) |candidate| {
                    const value = try self.evaluateExpressionBytes(
                        candidate.bytes,
                        scope,
                        candidate.span,
                    );
                    if (sassTruthy(value.*)) selected = block_id;
                } else {
                    selected = block_id;
                }
            }
            consumed += 1;
        }

        return .{ .consumed = consumed, .block = selected };
    }

    fn classifyConditionalDirective(
        self: *Engine,
        node: *const native_syntax.Node,
    ) Error!ConditionalDirective {
        const text_span = node.text orelse {
            try self.report(.syntax, node.span, "Sass conditional directive is missing a keyword");
            return error.InvalidSassSyntax;
        };
        const keyword = try self.sources.slice(text_span);
        if (std.ascii.eqlIgnoreCase(keyword, "@if")) return .if_branch;
        if (std.ascii.eqlIgnoreCase(keyword, "@else")) return .else_branch;
        try self.report(.syntax, node.span, "unknown Sass conditional directive");
        return error.InvalidSassSyntax;
    }

    fn emitRuleChunk(
        self: *Engine,
        span: native_source.Span,
        selectors: *const SelectorList,
        declarations: *std.ArrayList(u8),
    ) Error!void {
        if (declarations.items.len == 0) return;
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        for (selectors.items, 0..) |selector, index| {
            if (index > 0) try self.appendTemporary(&output, ", ");
            try self.appendTemporary(&output, selector);
        }
        try self.appendTemporary(&output, " { ");
        try self.appendTemporary(&output, declarations.items);
        try self.appendTemporary(&output, " }\n");
        try self.transaction.emitMapped(span, null, output.items);
        declarations.clearRetainingCapacity();
    }

    fn appendBlockComment(
        self: *Engine,
        node: *const native_syntax.Node,
        output: *std.ArrayList(u8),
    ) Error!void {
        const text_span = node.text orelse return;
        const raw = try self.sources.slice(text_span);
        if (!std.mem.startsWith(u8, raw, "/*")) return;
        try self.appendTemporary(output, raw);
        try self.appendTemporary(output, " ");
    }

    fn isVariableDeclaration(self: *Engine, declaration_id: native_syntax.NodeId) Error!bool {
        const children = self.document.children(declaration_id) catch return error.InvalidSassSyntax;
        if (children.len == 0) return false;
        const first = self.document.get(children[0]) catch return error.InvalidSassSyntax;
        return first.kind == .variable;
    }

    fn assignVariable(
        self: *Engine,
        declaration_id: native_syntax.NodeId,
        scope: *ScopeFrame,
    ) Error!void {
        const declaration = self.document.get(declaration_id) catch return error.InvalidSassSyntax;
        const children = self.document.children(declaration_id) catch return error.InvalidSassSyntax;
        if (children.len != 2) {
            try self.report(.syntax, declaration.span, "malformed Sass variable declaration");
            return error.InvalidSassSyntax;
        }
        const name_node = self.document.get(children[0]) catch return error.InvalidSassSyntax;
        const expression_node = self.document.get(children[1]) catch return error.InvalidSassSyntax;
        if (name_node.kind != .variable or name_node.text == null or
            expression_node.kind != .expression or expression_node.text == null)
        {
            try self.report(.syntax, declaration.span, "malformed Sass variable declaration");
            return error.InvalidSassSyntax;
        }
        const raw_name = try self.sources.slice(name_node.text.?);
        const normalized = try self.normalizeVariable(raw_name);
        defer self.allocator.free(normalized);
        const expression_bytes = try self.sources.slice(expression_node.text.?);
        const assignment = try self.parseVariableAssignment(expression_bytes, expression_node.span);
        if (self.unprefixedMathConstant(normalized) != null and
            (scope.kind == .global or assignment.global))
        {
            try self.report(.invalid_operation, declaration.span, "cannot modify a native Sass built-in variable");
            return error.InvalidExpression;
        }
        const existing = if (assignment.global)
            try self.environment.lookup(self.global_scope, normalized)
        else
            try self.lookupVisibleVariable(scope.cursor, normalized);
        if (assignment.default) {
            if (existing) |item| {
                if (item.* != .null_value) return;
            }
        }
        const item = try self.evaluateExpressionBytes(
            assignment.value,
            scope.cursor,
            expression_node.span,
        );
        if (assignment.global) {
            if (existing == null) {
                try self.transaction.report(
                    .warning,
                    .syntax,
                    expression_node.span,
                    "!global assignment declares a new variable; Sass 2.0 will reject it",
                    &.{},
                );
            }
            try self.assignGlobalVariable(scope, normalized, item);
        } else {
            try self.assignScopedVariable(scope, normalized, item);
        }
    }

    fn assignScopedVariable(
        self: *Engine,
        scope: *ScopeFrame,
        name: []const u8,
        item: *const native_value.Value,
    ) Error!void {
        if (scope.kind == .global) {
            try self.assignGlobalVariable(scope, name, item);
            return;
        }
        if (try self.updateExistingNonGlobalVariable(scope, name, item)) return;

        if (!self.hasLexicalScope(scope) and
            try self.environment.lookup(self.global_scope, name) != null)
        {
            try self.assignGlobalVariable(scope, name, item);
            return;
        }
        try self.defineOwnedVariable(scope, name, item);
    }

    fn updateExistingNonGlobalVariable(
        self: *Engine,
        scope: *ScopeFrame,
        name: []const u8,
        item: *const native_value.Value,
    ) Error!bool {
        if (scope.kind == .global) return false;
        if (try self.scopeOwnsVariable(scope, name)) {
            scope.cursor = try self.environment.set(scope.cursor, name, item);
            return true;
        }

        const parent = scope.parent orelse return false;
        if (!try self.updateExistingNonGlobalVariable(parent, name, item)) return false;
        scope.cursor = try self.environment.set(scope.cursor, name, item);
        return true;
    }

    fn scopeOwnsVariable(
        self: *Engine,
        scope: *const ScopeFrame,
        name: []const u8,
    ) Error!bool {
        const markers = scope.owned_markers orelse return false;
        return try self.environment.lookupLocal(markers, name) != null;
    }

    fn defineOwnedVariable(
        self: *Engine,
        scope: *ScopeFrame,
        name: []const u8,
        item: *const native_value.Value,
    ) Error!void {
        scope.cursor = try self.environment.set(scope.cursor, name, item);
        if (scope.owned_markers == null) {
            scope.owned_markers = try self.environment.push(self.environment.root());
        }
        scope.owned_markers = try self.environment.define(scope.owned_markers.?, name, item);
    }

    fn assignGlobalVariable(
        self: *Engine,
        scope: *ScopeFrame,
        name: []const u8,
        item: *const native_value.Value,
    ) Error!void {
        self.global_scope = try self.environment.set(self.global_scope, name, item);
        var root = scope;
        while (root.parent) |parent| {
            root = parent;
        }
        root.cursor = self.global_scope;
    }

    fn hasLexicalScope(self: *const Engine, scope: *const ScopeFrame) bool {
        _ = self;
        var cursor: ?*const ScopeFrame = scope;
        while (cursor) |frame| : (cursor = frame.parent) {
            if (frame.kind == .lexical) return true;
        }
        return false;
    }

    fn parseVariableAssignment(
        self: *Engine,
        raw: []const u8,
        span: native_source.Span,
    ) Error!VariableAssignment {
        var options = native_lexer.Options{};
        options.max_input_bytes = @max(raw.len, 1);
        options.max_tokens = self.limits.max_expression_tokens;
        const tokens = try native_lexer.tokenizeAlloc(self.allocator, raw, .scss, options);
        defer self.allocator.free(tokens);

        var result = VariableAssignment{ .value = trimWhitespace(raw) };
        var first_modifier: ?usize = null;
        var depth: usize = 0;
        var index: usize = 0;
        while (index < tokens.len) : (index += 1) {
            const token = tokens[index];
            switch (token.kind) {
                .open_paren, .open_square, .open_curly, .interpolation_start => {
                    depth += 1;
                    continue;
                },
                .close_paren, .close_square, .close_curly, .interpolation_end => {
                    if (depth > 0) depth -= 1;
                    continue;
                },
                else => {},
            }
            if (depth != 0 or isExpressionTrivia(token.kind) or token.kind == .eof) continue;

            if (token.kind == .operator and std.mem.eql(u8, token.raw(raw), "!")) {
                var word_index = index + 1;
                while (word_index < tokens.len and isExpressionTrivia(tokens[word_index].kind)) {
                    word_index += 1;
                }
                if (word_index < tokens.len and tokens[word_index].kind == .identifier) {
                    const word = tokens[word_index].raw(raw);
                    const is_default = std.ascii.eqlIgnoreCase(word, "default");
                    const is_global = std.ascii.eqlIgnoreCase(word, "global");
                    if (is_default or is_global) {
                        if ((is_default and result.default) or (is_global and result.global)) {
                            try self.report(.syntax, span, "duplicate Sass variable modifier");
                            return error.InvalidExpression;
                        }
                        if (first_modifier == null) first_modifier = token.span.start;
                        result.default = result.default or is_default;
                        result.global = result.global or is_global;
                        index = word_index;
                        continue;
                    }
                }
            }
            if (first_modifier != null) {
                try self.report(.syntax, span, "Sass variable modifiers must end the declaration");
                return error.InvalidExpression;
            }
        }
        if (first_modifier) |offset| result.value = trimWhitespace(raw[0..offset]);
        if (result.value.len == 0) {
            try self.report(.syntax, span, "Sass variable declaration is missing a value");
            return error.InvalidExpression;
        }
        return result;
    }

    fn appendDeclaration(
        self: *Engine,
        declaration_id: native_syntax.NodeId,
        prefix: []const u8,
        scope: *ScopeFrame,
        output: *std.ArrayList(u8),
        depth: u16,
    ) Error!void {
        if (depth > self.limits.max_evaluation_depth) {
            const declaration = self.document.get(declaration_id) catch return error.InvalidSassSyntax;
            try self.report(.resource_limit, declaration.span, "nested Sass property depth exceeded");
            return error.EvaluationDepthExceeded;
        }
        const declaration = self.document.get(declaration_id) catch return error.InvalidSassSyntax;
        const children = self.document.children(declaration_id) catch return error.InvalidSassSyntax;
        if (children.len == 0) {
            try self.report(.syntax, declaration.span, "malformed Sass declaration");
            return error.InvalidSassSyntax;
        }
        const property_node = self.document.get(children[0]) catch return error.InvalidSassSyntax;
        if (property_node.kind != .identifier or property_node.text == null) {
            try self.report(.syntax, declaration.span, "malformed Sass property name");
            return error.InvalidSassSyntax;
        }
        const property = try self.renderTemplate(property_node.text.?, scope.cursor, false);
        defer self.allocator.free(property);
        const trimmed_property = trimWhitespace(property);
        if (trimmed_property.len == 0) {
            try self.report(.syntax, property_node.span, "empty Sass property name");
            return error.InvalidSassSyntax;
        }

        var expression: ?native_source.Span = null;
        var block: ?native_syntax.NodeId = null;
        for (children[1..]) |child_id| {
            const child = self.document.get(child_id) catch return error.InvalidSassSyntax;
            switch (child.kind) {
                .expression => expression = child.text orelse return error.InvalidSassSyntax,
                .block => block = child_id,
                else => {
                    try self.report(.syntax, child.span, "malformed Sass declaration child");
                    return error.InvalidSassSyntax;
                },
            }
        }

        if (expression) |expression_span| {
            if (std.mem.startsWith(u8, trimmed_property, "--")) {
                const rendered = try self.renderTemplate(expression_span, scope.cursor, false);
                defer self.allocator.free(rendered);
                try self.appendTemporary(output, prefix);
                try self.appendTemporary(output, trimmed_property);
                try self.appendTemporary(output, ": ");
                try self.appendTemporary(output, trimWhitespace(rendered));
                try self.appendTemporary(output, "; ");
            } else {
                const item = try self.evaluateExpression(expression_span, scope.cursor);
                if (item.* != .null_value) {
                    try self.ensureCssValue(item.*, expression_span);
                    try self.appendTemporary(output, prefix);
                    try self.appendTemporary(output, trimmed_property);
                    try self.appendTemporary(output, ": ");
                    try self.appendValue(output, item.*, false);
                    try self.appendTemporary(output, "; ");
                }
            }
        }

        if (block) |block_id| {
            var next_prefix: std.ArrayList(u8) = .empty;
            defer next_prefix.deinit(self.allocator);
            try self.appendTemporary(&next_prefix, prefix);
            try self.appendTemporary(&next_prefix, trimmed_property);
            try self.appendTemporary(&next_prefix, "-");
            const nested_children = self.document.children(block_id) catch
                return error.InvalidSassSyntax;
            for (nested_children) |nested_id| {
                const nested_node = self.document.get(nested_id) catch return error.InvalidSassSyntax;
                if (nested_node.kind != .declaration) {
                    try self.report(
                        .unsupported_feature,
                        nested_node.span,
                        "nested Sass properties may contain declarations only",
                    );
                    return error.UnsupportedFeature;
                }
                if (try self.isVariableDeclaration(nested_id)) {
                    try self.assignVariable(nested_id, scope);
                } else {
                    try self.appendDeclaration(
                        nested_id,
                        next_prefix.items,
                        scope,
                        output,
                        depth + 1,
                    );
                }
            }
        }
    }

    fn evaluateExpression(
        self: *Engine,
        span: native_source.Span,
        scope: native_environment.ScopeId,
    ) Error!*const native_value.Value {
        return self.evaluateExpressionBytes(try self.sources.slice(span), scope, span);
    }

    fn tryArithmetic(
        self: *Engine,
        raw: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!?Numeric {
        return switch (try self.probeArithmetic(raw, scope, span, .sass)) {
            .none => null,
            .numeric => |numeric| numeric,
            .incompatible, .invalid => {
                try self.report(.invalid_operation, span, "invalid native Sass arithmetic expression");
                return error.InvalidExpression;
            },
        };
    }

    fn probeArithmetic(
        self: *Engine,
        raw: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
        context: ArithmeticContext,
    ) Error!ArithmeticProbe {
        if (raw.len == 0) return .none;
        if (try self.hasTopLevelListStructure(raw)) return .none;
        if (fullyWrapped(raw, '(', ')') and
            try self.hasTopLevelListStructure(trimWhitespace(raw[1 .. raw.len - 1])))
        {
            // Collection parsing owns parenthesized comma, map, and space
            // lists. Arithmetic probing may execute numeric user functions,
            // so it must not speculatively evaluate a list's first item.
            return .none;
        }
        var options = native_lexer.Options{};
        options.max_input_bytes = @max(raw.len, 1);
        options.max_tokens = self.limits.max_expression_tokens;
        const tokens = try native_lexer.tokenizeAlloc(self.allocator, raw, .scss, options);
        defer self.allocator.free(tokens);

        var first: usize = 0;
        while (first < tokens.len and isExpressionTrivia(tokens[first].kind)) first += 1;
        if (first >= tokens.len or !arithmeticStart(tokens[first], raw)) return .none;
        var parser = ArithmeticParser{
            .engine = self,
            .raw = raw,
            .tokens = tokens,
            .cursor = first,
            .scope = scope,
            .span = span,
            .allows_slash_division = context == .numeric_function or slashDivisionEnabled(raw),
            .strict_additive_units = context == .calculation,
        };
        const numeric = parser.parseExpression() catch |err| {
            if (!parser.saw_operator) {
                return switch (err) {
                    error.UndefinedVariable => err,
                    error.InvalidSassSyntax,
                    error.InvalidExpression,
                    error.DivisionByZero,
                    error.IncompatibleUnits,
                    error.InvalidNumber,
                    error.UnitLimitExceeded,
                    => .none,
                    else => err,
                };
            }
            switch (err) {
                error.UndefinedVariable => return err,
                error.IncompatibleUnits => return if (parser.invalid_additive_units)
                    .invalid
                else
                    .incompatible,
                error.InvalidSassSyntax,
                error.InvalidExpression,
                error.DivisionByZero,
                error.InvalidNumber,
                error.UnitLimitExceeded,
                => return .invalid,
                else => return err,
            }
        };
        parser.skipTrivia();
        if (parser.current().kind != .eof) {
            if (!parser.saw_operator) return .none;
            return .invalid;
        }
        return .{ .numeric = numeric };
    }

    fn renderTemplate(
        self: *Engine,
        span: native_source.Span,
        scope: native_environment.ScopeId,
        replace_variables: bool,
    ) Error![]u8 {
        return self.renderBytes(try self.sources.slice(span), scope, span, replace_variables);
    }

    fn renderBytes(
        self: *Engine,
        raw: []const u8,
        scope: native_environment.ScopeId,
        diagnostic_span: native_source.Span,
        replace_variables: bool,
    ) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var index: usize = 0;
        while (index < raw.len) {
            if (raw[index] == '\\' and index + 1 < raw.len) {
                try self.appendTemporary(&output, raw[index .. index + 2]);
                index += 2;
                continue;
            }
            if (raw[index] == '\'' or raw[index] == '"') {
                const quote = raw[index];
                try self.appendTemporary(&output, raw[index .. index + 1]);
                index += 1;
                while (index < raw.len) {
                    if (raw[index] == '\\' and index + 1 < raw.len) {
                        try self.appendTemporary(&output, raw[index .. index + 2]);
                        index += 2;
                        continue;
                    }
                    if (raw[index] == quote) {
                        try self.appendTemporary(&output, raw[index .. index + 1]);
                        index += 1;
                        break;
                    }
                    if (index + 1 < raw.len and raw[index] == '#' and raw[index + 1] == '{') {
                        index = try self.appendInterpolation(
                            &output,
                            raw,
                            index,
                            scope,
                            diagnostic_span,
                        );
                        continue;
                    }
                    try self.appendTemporary(&output, raw[index .. index + 1]);
                    index += 1;
                }
                continue;
            }
            if (index + 1 < raw.len and raw[index] == '#' and raw[index + 1] == '{') {
                index = try self.appendInterpolation(
                    &output,
                    raw,
                    index,
                    scope,
                    diagnostic_span,
                );
                continue;
            }
            if (replace_variables and raw[index] == '$' and
                index + 1 < raw.len and isVariableNameStart(raw[index + 1]))
            {
                const end = variableEnd(raw, index + 1);
                const item = try self.lookupVariable(raw[index..end], scope, diagnostic_span);
                try self.ensureCssValue(item.*, diagnostic_span);
                try self.appendValue(&output, item.*, false);
                index = end;
                continue;
            }
            try self.appendTemporary(&output, raw[index .. index + 1]);
            index += 1;
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn appendInterpolation(
        self: *Engine,
        output: *std.ArrayList(u8),
        raw: []const u8,
        opening: usize,
        scope: native_environment.ScopeId,
        diagnostic_span: native_source.Span,
    ) Error!usize {
        const closing = findInterpolationEnd(raw, opening + 2) orelse {
            try self.report(.syntax, diagnostic_span, "unterminated Sass interpolation");
            return error.InvalidSassSyntax;
        };
        const inner = trimWhitespace(raw[opening + 2 .. closing]);
        if (inner.len == 0) {
            try self.report(.syntax, diagnostic_span, "empty Sass interpolation");
            return error.InvalidExpression;
        }
        const item = try self.evaluateExpressionBytes(inner, scope, diagnostic_span);
        try self.ensureCssValue(item.*, diagnostic_span);
        try self.appendValue(output, item.*, true);
        return closing + 1;
    }

    fn evaluateExpressionBytes(
        self: *Engine,
        raw: []const u8,
        scope: native_environment.ScopeId,
        diagnostic_span: native_source.Span,
    ) Error!*const native_value.Value {
        const trimmed = trimWhitespace(raw);
        if (self.expression_depth >= self.limits.max_evaluation_depth) {
            try self.report(.resource_limit, diagnostic_span, "native Sass expression depth exceeded");
            return error.EvaluationDepthExceeded;
        }
        self.expression_depth += 1;
        defer self.expression_depth -= 1;
        try self.transaction.consumeOperations(@intCast(trimmed.len + 1));
        if (try self.tryModuleVariable(trimmed, diagnostic_span)) |item| return item;
        if (trimmed.len > 0 and trimmed[0] == '$' and variableEnd(trimmed, 1) == trimmed.len) {
            return self.lookupVariable(trimmed, scope, diagnostic_span);
        }
        if (std.mem.eql(u8, trimmed, "true")) return self.values.own(.{ .boolean = true });
        if (std.mem.eql(u8, trimmed, "false")) return self.values.own(.{ .boolean = false });
        if (std.mem.eql(u8, trimmed, "null")) return self.values.own(.{ .null_value = {} });
        if (trimmed.len >= 2 and (trimmed[0] == '\'' or trimmed[0] == '"') and
            trimmed[trimmed.len - 1] == trimmed[0])
        {
            const rendered = try self.renderBytes(
                trimmed[1 .. trimmed.len - 1],
                scope,
                diagnostic_span,
                false,
            );
            defer self.allocator.free(rendered);
            return self.values.own(.{ .string = .{ .bytes = rendered, .quoted = true } });
        }
        if (try self.tryLegacyIfFunctionCall(trimmed, scope, diagnostic_span)) |item| {
            return item;
        }
        if (try self.tryUserFunctionCall(trimmed, scope, diagnostic_span)) |item| return item;
        if (try self.tryBuiltinCall(trimmed, scope, diagnostic_span)) |item| return item;
        if (sassCalculationValue(trimmed) != null) {
            const rendered = try self.renderBytes(trimmed, scope, diagnostic_span, true);
            defer self.allocator.free(rendered);
            return self.values.own(.{ .string = .{ .bytes = rendered } });
        }
        if (native_color.parseLiteral(trimmed)) |color| {
            return self.values.own(.{ .color = color });
        }
        if (try self.tryLogicalExpression(trimmed, scope, diagnostic_span)) |item| return item;
        if (try self.tryArithmetic(trimmed, scope, diagnostic_span)) |numeric| {
            var numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
            var denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
            return self.values.own(.{ .number = try numeric.toNumber(&numerator, &denominator) });
        }
        if (try self.tryPlainCssFunctionCall(trimmed, scope, diagnostic_span)) |item| {
            return item;
        }
        if (try self.tryCollection(trimmed, scope, diagnostic_span)) |item| return item;
        const rendered = try self.renderBytes(trimmed, scope, diagnostic_span, true);
        defer self.allocator.free(rendered);
        return self.values.own(.{ .string = .{ .bytes = rendered, .quoted = false } });
    }

    fn tryLegacyIfFunctionCall(
        self: *Engine,
        raw: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const opening = findTopLevelByte(raw, '(') orelse return null;
        if (opening == 0 or !fullyWrapped(raw[opening..], '(', ')')) return null;
        if (!legacyIfIdentifierEql(raw[0..opening])) return null;

        const body = raw[opening + 1 .. raw.len - 1];
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        _ = try splitTopLevelRanges(
            self.allocator,
            body,
            .comma,
            &ranges,
        );
        if (trimWhitespace(body).len == 0) ranges.clearRetainingCapacity();

        // Modern CSS if() clauses put their first top-level colon before any
        // comma. Legacy keyword calls instead begin that clause with `$`.
        if (findTopLevelByte(body, ':')) |colon| {
            const comma = findTopLevelByte(body, ',');
            if (comma == null or colon < comma.?) {
                const clause = trimWhitespace(body[0..colon]);
                if (clause.len > 0 and clause[0] != '$' and isModernCssIfClause(clause)) {
                    return null;
                }
            }
        }

        if (ranges.items.len > 0) {
            const final = ranges.items[ranges.items.len - 1];
            if ((try self.expressionWithoutOuterTrivia(
                body[final.start..final.end],
            )).len == 0) {
                ranges.items.len -= 1;
            }
        }

        if (ranges.items.len > self.limits.max_function_arguments) {
            return self.argumentsFailure(error.ArgumentLimitExceeded, span);
        }
        var parsed = native_arguments.parseAlloc(
            self.allocator,
            body,
            ranges.items,
            self.limits.max_function_arguments,
        ) catch |err| return self.argumentsFailure(err, span);
        defer parsed.deinit();
        var splat_index: ?usize = null;
        var keyword_splat_index: ?usize = null;
        for (parsed.items, 0..) |argument, index| {
            if (!argument.splat) continue;
            if (splat_index == null) {
                splat_index = index;
                continue;
            }
            if (keyword_splat_index == null) {
                keyword_splat_index = index;
                continue;
            }
            try self.report(
                .unsupported_feature,
                span,
                "three or more legacy if() splats are not implemented by the native evaluator",
            );
            return error.UnsupportedFeature;
        }
        if (keyword_splat_index) |keyword_index| {
            const positional_index = splat_index.?;
            if (positional_index + 1 != keyword_index or
                keyword_index + 1 != parsed.items.len)
            {
                try self.report(
                    .unsupported_feature,
                    span,
                    "only a terminal positional and keyword legacy if() splat pair is implemented by the native evaluator",
                );
                return error.UnsupportedFeature;
            }
            try self.reportLegacyIfDeprecation(span);
            return try self.evaluateLegacyIfSplatCall(
                body,
                parsed.items,
                positional_index,
                keyword_index,
                scope,
                span,
            );
        }
        if (splat_index) |index| {
            if (index + 1 != parsed.items.len) {
                try self.reportMisplacedRestDeprecation(
                    parsed.items[index + 1].name != null,
                    span,
                );
            }
            try self.reportLegacyIfDeprecation(span);
            return try self.evaluateLegacyIfSplatCall(
                body,
                parsed.items,
                index,
                null,
                scope,
                span,
            );
        }

        try self.reportLegacyIfDeprecation(span);
        const parameters = [_]native_arguments.Parameter{
            .{ .name = "condition" },
            .{ .name = "if-true" },
            .{ .name = "if-false" },
        };
        var bound = native_arguments.bindAlloc(
            self.allocator,
            parsed.items,
            &parameters,
            parameters.len,
        ) catch |err| return self.argumentsFailure(err, span);
        defer bound.deinit();

        const condition_range = bound.values[0].?;
        const condition_source = try self.expressionWithoutOuterTrivia(
            body[condition_range.start..condition_range.end],
        );
        if (condition_source.len == 0) {
            try self.report(.syntax, span, "legacy Sass if() condition is empty");
            return error.InvalidExpression;
        }
        const condition = try self.evaluateExpressionBytes(
            condition_source,
            scope,
            span,
        );
        const selected_range = bound.values[if (sassTruthy(condition.*)) 1 else 2].?;
        const selected_source = try self.expressionWithoutOuterTrivia(
            body[selected_range.start..selected_range.end],
        );
        if (selected_source.len == 0) {
            try self.report(.syntax, span, "selected legacy Sass if() branch is empty");
            return error.InvalidExpression;
        }
        return try self.evaluateExpressionBytes(
            selected_source,
            scope,
            span,
        );
    }

    fn evaluateLegacyIfSplatCall(
        self: *Engine,
        body: []const u8,
        arguments: []const native_arguments.Argument,
        splat_index: usize,
        keyword_splat_index: ?usize,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        std.debug.assert(splat_index < arguments.len and arguments[splat_index].splat);
        std.debug.assert(keyword_splat_index == null or
            (keyword_splat_index.? < arguments.len and
                arguments[keyword_splat_index.?].splat));
        const splat = arguments[splat_index];
        const splat_item = try self.evaluateExpressionBytes(
            body[splat.value.start..splat.value.end],
            scope,
            span,
        );
        var expanded = EvaluatedCallArguments{ .allocator = self.allocator };
        defer expanded.deinit();
        try self.expandCallSplat(&expanded, splat_item, span);
        if (keyword_splat_index) |index| {
            const keyword_splat = arguments[index];
            const keyword_item = try self.evaluateExpressionBytes(
                body[keyword_splat.value.start..keyword_splat.value.end],
                scope,
                span,
            );
            try self.expandCallKeywordSplat(&expanded, keyword_item, span);
        }

        var evaluated = EvaluatedCallArguments{ .allocator = self.allocator };
        defer evaluated.deinit();
        for (arguments, 0..) |argument, index| {
            if (index == splat_index) continue;
            if (keyword_splat_index != null and index == keyword_splat_index.?) continue;
            const item = try self.evaluateExpressionBytes(
                body[argument.value.start..argument.value.end],
                scope,
                span,
            );
            if (argument.name) |name| {
                try self.appendEvaluatedKeyword(&evaluated, .{
                    .name = name,
                    .value = item,
                    .normalize_name = true,
                }, span);
            } else {
                try self.appendEvaluatedPositional(&evaluated, item, span);
            }
        }
        for (expanded.positional.items) |item| {
            try self.appendEvaluatedPositional(&evaluated, item, span);
        }
        for (expanded.keywords.items) |keyword| {
            try self.appendEvaluatedSplatKeyword(&evaluated, keyword, span);
        }
        for (expanded.splat_keywords.items) |keyword| {
            try self.appendEvaluatedSplatKeyword(&evaluated, keyword, span);
        }
        try self.mergeEvaluatedSplatKeywords(&evaluated);

        var condition_name = [_]u8{ 'c', 'o', 'n', 'd', 'i', 't', 'i', 'o', 'n' };
        var if_true_name = [_]u8{ 'i', 'f', '-', 't', 'r', 'u', 'e' };
        var if_false_name = [_]u8{ 'i', 'f', '-', 'f', 'a', 'l', 's', 'e' };
        const parameters = [_]CallableParameter{
            .{
                .name = condition_name[0..],
                .default_value = null,
            },
            .{
                .name = if_true_name[0..],
                .default_value = null,
            },
            .{
                .name = if_false_name[0..],
                .default_value = null,
            },
        };
        var bound = try self.bindCallableArguments(&parameters, &evaluated, span);
        defer bound.deinit();

        const condition = bound.values[0].?;
        return bound.values[if (sassTruthy(condition.*)) 1 else 2].?;
    }

    fn reportMisplacedRestDeprecation(
        self: *Engine,
        named: bool,
        span: native_source.Span,
    ) Error!void {
        self.misplaced_rest_deprecation_count +|= 1;
        if (self.misplaced_rest_deprecation_count > 5) return;
        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            if (named)
                "Named arguments must come before rest arguments. This will be an error in Dart Sass 2.0.0."
            else
                "Positional arguments must come before rest arguments. This will be an error in Dart Sass 2.0.0.",
            &.{},
        );
    }

    fn reportLegacyIfDeprecation(
        self: *Engine,
        span: native_source.Span,
    ) Error!void {
        self.legacy_if_deprecation_count +|= 1;
        if (self.legacy_if_deprecation_count > 5) return;
        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            "The Sass if() syntax is deprecated in favor of the modern CSS syntax.",
            &.{},
        );
    }

    fn reportLegacyIfDeprecationSummary(
        self: *Engine,
        span: native_source.Span,
    ) Error!void {
        const omitted = (self.legacy_if_deprecation_count -| 5) +|
            (self.misplaced_rest_deprecation_count -| 5);
        if (omitted == 0) return;
        var buffer: [96]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "{d} repetitive deprecation warnings omitted.",
            .{omitted},
        ) catch unreachable;
        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            message,
            &.{},
        );
    }

    fn expressionWithoutOuterTrivia(
        self: *Engine,
        raw: []const u8,
    ) Error![]const u8 {
        if (trimWhitespace(raw).len == 0) return "";
        var options = native_lexer.Options{};
        options.max_input_bytes = @max(raw.len, 1);
        options.max_tokens = self.limits.max_expression_tokens;
        const tokens = try native_lexer.tokenizeAlloc(self.allocator, raw, .scss, options);
        defer self.allocator.free(tokens);

        var start: ?usize = null;
        var end: usize = 0;
        for (tokens) |token| {
            if (token.kind == .eof or isExpressionTrivia(token.kind)) continue;
            if (start == null) start = token.span.start;
            end = token.span.end;
        }
        return if (start) |offset| raw[offset..end] else "";
    }

    fn hasTopLevelListStructure(self: *Engine, raw: []const u8) Error!bool {
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        if (try splitTopLevelRanges(self.allocator, raw, .comma, &ranges)) return true;
        ranges.clearRetainingCapacity();
        return try splitTopLevelRanges(self.allocator, raw, .whitespace, &ranges);
    }

    fn tryLogicalExpression(
        self: *Engine,
        raw: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        if (raw.len == 0 or try self.hasTopLevelListStructure(raw)) return null;
        var options = native_lexer.Options{};
        options.max_input_bytes = @max(raw.len, 1);
        options.max_tokens = self.limits.max_expression_tokens;
        const tokens = try native_lexer.tokenizeAlloc(self.allocator, raw, .scss, options);
        defer self.allocator.free(tokens);

        var depth: usize = 0;
        var first: ?native_lexer.Token = null;
        var logical_or: ?OperatorMatch = null;
        var logical_and: ?OperatorMatch = null;
        var equality: ?OperatorMatch = null;
        var relational: ?OperatorMatch = null;
        for (tokens) |token| {
            switch (token.kind) {
                .open_paren, .open_square, .open_curly, .interpolation_start => {
                    depth += 1;
                    continue;
                },
                .close_paren, .close_square, .close_curly, .interpolation_end => {
                    if (depth > 0) depth -= 1;
                    continue;
                },
                else => {},
            }
            if (depth != 0 or isExpressionTrivia(token.kind) or token.kind == .eof) continue;
            if (first == null) first = token;
            if (token.kind == .identifier) {
                const word = token.raw(raw);
                if (std.mem.eql(u8, word, "or")) {
                    logical_or = .{ .operation = .logical_or, .start = token.span.start, .end = token.span.end };
                } else if (std.mem.eql(u8, word, "and")) {
                    logical_and = .{ .operation = .logical_and, .start = token.span.start, .end = token.span.end };
                }
                continue;
            }
            if (token.kind != .operator) continue;
            const operation = token.raw(raw);
            const match: ?LogicalOperator = if (std.mem.eql(u8, operation, "=="))
                .equal
            else if (std.mem.eql(u8, operation, "!="))
                .not_equal
            else if (std.mem.eql(u8, operation, "<"))
                .less
            else if (std.mem.eql(u8, operation, "<="))
                .less_equal
            else if (std.mem.eql(u8, operation, ">"))
                .greater
            else if (std.mem.eql(u8, operation, ">="))
                .greater_equal
            else
                null;
            if (match) |matched| {
                const item = OperatorMatch{
                    .operation = matched,
                    .start = token.span.start,
                    .end = token.span.end,
                };
                switch (matched) {
                    .equal, .not_equal => equality = item,
                    .less, .less_equal, .greater, .greater_equal => relational = item,
                    else => unreachable,
                }
            }
        }

        if (logical_or) |match| return try self.evaluateLogicalMatch(raw, match, scope, span);
        if (logical_and) |match| return try self.evaluateLogicalMatch(raw, match, scope, span);
        if (equality) |match| return try self.evaluateLogicalMatch(raw, match, scope, span);
        if (relational) |match| return try self.evaluateLogicalMatch(raw, match, scope, span);
        if (first) |token| {
            if (token.kind == .identifier and std.mem.eql(u8, token.raw(raw), "not")) {
                const operand_raw = trimWhitespace(raw[token.span.end..]);
                if (operand_raw.len == 0) {
                    try self.report(.syntax, span, "not requires a native Sass expression");
                    return error.InvalidExpression;
                }
                const operand = try self.evaluateExpressionBytes(operand_raw, scope, span);
                return try self.values.own(.{ .boolean = !sassTruthy(operand.*) });
            }
        }
        return null;
    }

    fn evaluateLogicalMatch(
        self: *Engine,
        raw: []const u8,
        match: OperatorMatch,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const left_raw = trimWhitespace(raw[0..match.start]);
        const right_raw = trimWhitespace(raw[match.end..]);
        if (left_raw.len == 0 or right_raw.len == 0) {
            try self.report(.syntax, span, "native Sass binary operator is missing an operand");
            return error.InvalidExpression;
        }
        const left = try self.evaluateExpressionBytes(left_raw, scope, span);
        switch (match.operation) {
            .logical_or => {
                if (sassTruthy(left.*)) return left;
                return self.evaluateExpressionBytes(right_raw, scope, span);
            },
            .logical_and => {
                if (!sassTruthy(left.*)) return left;
                return self.evaluateExpressionBytes(right_raw, scope, span);
            },
            else => {},
        }

        const right = try self.evaluateExpressionBytes(right_raw, scope, span);
        const result = switch (match.operation) {
            .equal => sassValuesEqual(left.*, right.*),
            .not_equal => !sassValuesEqual(left.*, right.*),
            .less, .less_equal, .greater, .greater_equal => try self.compareValues(
                left.*,
                right.*,
                match.operation,
                span,
            ),
            else => unreachable,
        };
        return self.values.own(.{ .boolean = result });
    }

    fn compareValues(
        self: *Engine,
        left: native_value.Value,
        right: native_value.Value,
        operation: LogicalOperator,
        span: native_source.Span,
    ) Error!bool {
        const left_number = switch (left) {
            .number => |number| number,
            else => {
                try self.report(.type_mismatch, span, "native Sass ordering requires numbers");
                return error.InvalidExpression;
            },
        };
        const right_number = switch (right) {
            .number => |number| number,
            else => {
                try self.report(.type_mismatch, span, "native Sass ordering requires numbers");
                return error.InvalidExpression;
            },
        };
        const ordering = native_numeric.compare(
            try native_numeric.Numeric.fromNumber(left_number),
            try native_numeric.Numeric.fromNumber(right_number),
        ) catch |err| {
            try self.report(.invalid_operation, span, "native Sass ordering uses incompatible units");
            return err;
        };
        return switch (operation) {
            .less => ordering == .less,
            .less_equal => ordering != .greater,
            .greater => ordering == .greater,
            .greater_equal => ordering != .less,
            else => unreachable,
        };
    }

    fn callMathUnitPredicate(
        self: *Engine,
        builtin: Builtin,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const result = switch (builtin) {
            .math_compatible => blk: {
                if (arguments.len != 2) {
                    try self.report(
                        .invalid_operation,
                        span,
                        "math compatible() requires exactly two numbers",
                    );
                    return error.InvalidExpression;
                }
                const left = try self.mathNumericArgument(arguments[0].*, span);
                const right = try self.mathNumericArgument(arguments[1].*, span);
                break :blk native_numeric.compatible(left, right);
            },
            .math_is_unitless => blk: {
                if (arguments.len != 1) {
                    try self.report(
                        .invalid_operation,
                        span,
                        "math is-unitless() requires exactly one number",
                    );
                    return error.InvalidExpression;
                }
                const number = try self.mathNumericArgument(arguments[0].*, span);
                break :blk number.isDimensionless();
            },
            else => unreachable,
        };
        return self.values.own(.{ .boolean = result });
    }

    fn callMathExtremum(
        self: *Engine,
        builtin: Builtin,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len == 0) {
            try self.report(.invalid_operation, span, "math min() and max() require at least one number");
            return error.InvalidExpression;
        }
        try self.transaction.consumeOperations(arguments.len);

        var selected = arguments[0];
        var selected_number = try self.mathNumericArgument(selected.*, span);
        for (arguments[1..]) |argument| {
            const number = try self.mathNumericArgument(argument.*, span);
            const ordering = native_numeric.compare(selected_number, number) catch |err| {
                try self.report(.invalid_operation, span, "native Sass extremum arguments have incompatible units");
                return err;
            };
            const replace = switch (builtin) {
                .math_min => ordering == .greater,
                .math_max => ordering == .less,
                else => unreachable,
            };
            if (replace) {
                selected = argument;
                selected_number = number;
            }
        }
        return selected;
    }

    fn callMathClamp(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 3) {
            try self.report(.invalid_operation, span, "math clamp() requires exactly three numbers");
            return error.InvalidExpression;
        }
        try self.transaction.consumeOperations(3);

        const minimum = try self.mathNumericArgument(arguments[0].*, span);
        const number = try self.mathNumericArgument(arguments[1].*, span);
        const maximum = try self.mathNumericArgument(arguments[2].*, span);
        _ = native_numeric.convertValueToMatch(number, minimum) catch |err| {
            try self.report(.invalid_operation, span, "native Sass clamp() arguments have incompatible units");
            return err;
        };
        _ = native_numeric.convertValueToMatch(maximum, minimum) catch |err| {
            try self.report(.invalid_operation, span, "native Sass clamp() arguments have incompatible units");
            return err;
        };

        const number_maximum = native_numeric.compare(number, maximum) catch |err| {
            try self.report(.invalid_operation, span, "native Sass clamp() arguments have incompatible units");
            return err;
        };
        const bounded_index: usize = if (number_maximum == .greater) 2 else 1;
        const bounded = if (bounded_index == 2) maximum else number;
        const minimum_bounded = native_numeric.compare(minimum, bounded) catch |err| {
            try self.report(.invalid_operation, span, "native Sass clamp() arguments have incompatible units");
            return err;
        };
        return if (minimum_bounded == .less)
            arguments[bounded_index]
        else
            arguments[0];
    }

    fn callMathHypot(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len == 0) {
            try self.report(.invalid_operation, span, "math hypot() requires at least one number");
            return error.InvalidExpression;
        }
        try self.transaction.consumeOperations(arguments.len);

        const first_number = try self.mathNumberArgument(arguments[0].*, span);
        const target = native_numeric.Numeric.fromNumber(first_number) catch |err| {
            try self.report(
                if (err == error.UnitLimitExceeded) .resource_limit else .invalid_operation,
                span,
                "invalid native Sass hypot() argument",
            );
            return err;
        };
        var result: f64 = 0;
        for (arguments) |argument| {
            const numeric = try self.mathNumericArgument(argument.*, span);
            const converted = native_numeric.convertValueToMatch(numeric, target) catch |err| {
                try self.report(.invalid_operation, span, "native Sass hypot() arguments have incompatible units");
                return err;
            };
            result = std.math.hypot(result, converted);
            if (!std.math.isFinite(result)) {
                try self.report(.invalid_operation, span, "non-finite native Sass hypot() result");
                return error.InvalidNumber;
            }
        }
        return self.values.own(.{ .number = .{
            .value = result,
            .numerator_units = first_number.numerator_units,
            .denominator_units = first_number.denominator_units,
        } });
    }

    fn callMathUnary(
        self: *Engine,
        builtin: Builtin,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 1) {
            try self.report(.invalid_operation, span, "unary math function requires exactly one number");
            return error.InvalidExpression;
        }
        var number = try self.mathNumberArgument(arguments[0].*, span);
        try self.transaction.consumeOperations(1);
        number.value = switch (builtin) {
            .math_abs => @abs(number.value),
            .math_ceil => @ceil(number.value),
            .math_floor => @floor(number.value),
            .math_round => @round(number.value),
            .math_percentage => blk: {
                if (number.numerator_units.len != 0 or number.denominator_units.len != 0) {
                    try self.report(
                        .invalid_operation,
                        span,
                        "math percentage() requires a unitless number",
                    );
                    return error.InvalidExpression;
                }
                const percentage = number.value * 100;
                if (!std.math.isFinite(percentage)) {
                    try self.report(.invalid_operation, span, "invalid math percentage() result");
                    return error.InvalidNumber;
                }
                number.numerator_units = &.{"%"};
                break :blk percentage;
            },
            else => unreachable,
        };
        return self.values.own(.{ .number = number });
    }

    fn callMathDiv(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 2) {
            try self.report(.invalid_operation, span, "math div() requires exactly two arguments");
            return error.InvalidExpression;
        }
        if (arguments[0].* != .number or arguments[1].* != .number) {
            if (arguments[0].* == .color and
                (arguments[1].* == .number or arguments[1].* == .color))
            {
                try self.report(
                    .invalid_operation,
                    span,
                    "undefined native Sass color division",
                );
                return error.InvalidExpression;
            }
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(self.allocator);
            try self.transaction.consumeOperations(2);
            self.appendMathDivOperand(&output, arguments[0].*) catch |err| {
                try self.report(
                    if (err == error.TemporaryLimitExceeded) .resource_limit else .invalid_operation,
                    span,
                    "invalid native Sass legacy math division operand",
                );
                return err;
            };
            self.appendTemporary(&output, "/") catch |err| {
                try self.report(.resource_limit, span, "native Sass math division output limit exceeded");
                return err;
            };
            self.appendMathDivOperand(&output, arguments[1].*) catch |err| {
                try self.report(
                    if (err == error.TemporaryLimitExceeded) .resource_limit else .invalid_operation,
                    span,
                    "invalid native Sass legacy math division operand",
                );
                return err;
            };
            return self.values.own(.{ .string = .{ .bytes = output.items } });
        }

        try self.transaction.consumeOperations(1);
        const left = native_numeric.Numeric.fromNumber(arguments[0].number) catch |err| {
            try self.report(
                if (err == error.UnitLimitExceeded) .resource_limit else .invalid_operation,
                span,
                "invalid native Sass math division operand",
            );
            return err;
        };
        const right = native_numeric.Numeric.fromNumber(arguments[1].number) catch |err| {
            try self.report(
                if (err == error.UnitLimitExceeded) .resource_limit else .invalid_operation,
                span,
                "invalid native Sass math division operand",
            );
            return err;
        };
        const quotient = native_numeric.multiply(
            left,
            right,
            '/',
        ) catch |err| {
            try self.report(
                if (err == error.UnitLimitExceeded) .resource_limit else .invalid_operation,
                span,
                "invalid native Sass math division",
            );
            return err;
        };
        var numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
        var denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
        const number = quotient.toNumber(&numerator, &denominator) catch |err| {
            try self.report(
                if (err == error.UnitLimitExceeded) .resource_limit else .invalid_operation,
                span,
                "invalid native Sass math division result",
            );
            return err;
        };
        return self.values.own(.{ .number = number });
    }

    fn appendMathDivOperand(
        self: *Engine,
        output: *std.ArrayList(u8),
        item: native_value.Value,
    ) Error!void {
        switch (item) {
            .null_value => {},
            .list => |list| {
                if (list.items.len == 0 and !list.bracketed) return error.InvalidExpression;
                if (list.bracketed) try self.appendTemporary(output, "[");
                var emitted: usize = 0;
                for (list.items) |child| {
                    if (child == .null_value) continue;
                    if (emitted > 0) try self.appendTemporary(output, switch (list.separator) {
                        .comma => ", ",
                        .slash, .legacy_slash => "/",
                        .undecided, .space => " ",
                    });
                    try self.appendMathDivOperand(output, child);
                    emitted += 1;
                }
                if (list.bracketed) try self.appendTemporary(output, "]");
            },
            .argument_list => |argument_list| {
                if (argument_list.keywords.len != 0) return error.InvalidExpression;
                var emitted: usize = 0;
                for (argument_list.positional) |child| {
                    if (child == .null_value) continue;
                    if (emitted > 0) try self.appendTemporary(output, ", ");
                    try self.appendMathDivOperand(output, child);
                    emitted += 1;
                }
            },
            .map, .callable => return error.InvalidExpression,
            else => try self.appendValue(output, item, false),
        }
    }

    fn callMathPower(
        self: *Engine,
        builtin: Builtin,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const valid_arity = switch (builtin) {
            .math_pow => arguments.len == 2,
            .math_sqrt => arguments.len == 1,
            .math_log => arguments.len == 1 or arguments.len == 2,
            else => unreachable,
        };
        if (!valid_arity) {
            try self.report(.invalid_operation, span, "invalid math power function arity");
            return error.InvalidExpression;
        }

        var numbers: [2]f64 = undefined;
        for (arguments, 0..) |argument, index| {
            const number = try self.mathNumberArgument(argument.*, span);
            if (number.numerator_units.len != 0 or number.denominator_units.len != 0) {
                try self.report(
                    .invalid_operation,
                    span,
                    "native Sass power function requires unitless numbers",
                );
                return error.InvalidExpression;
            }
            numbers[index] = number.value;
        }
        try self.transaction.consumeOperations(@intCast(arguments.len));
        const result = switch (builtin) {
            .math_pow => std.math.pow(f64, numbers[0], numbers[1]),
            .math_sqrt => @sqrt(numbers[0]),
            .math_log => if (arguments.len == 1)
                @log(numbers[0])
            else
                @log(numbers[0]) / @log(numbers[1]),
            else => unreachable,
        };
        if (!std.math.isFinite(result)) {
            try self.report(.invalid_operation, span, "non-finite native Sass power result");
            return error.InvalidNumber;
        }
        return self.values.own(.{ .number = .{ .value = result } });
    }

    fn mathAngleRadians(
        self: *Engine,
        number: native_value.Number,
        span: native_source.Span,
    ) Error!f64 {
        if (number.numerator_units.len == 0 and number.denominator_units.len == 0) {
            return number.value;
        }
        if (number.numerator_units.len != 1 or number.denominator_units.len != 0) {
            try self.report(.invalid_operation, span, "native Sass trigonometric input requires an angle");
            return error.InvalidExpression;
        }
        const unit = number.numerator_units[0];
        const radians = if (std.mem.eql(u8, unit, "deg"))
            number.value * std.math.pi / 180
        else if (std.mem.eql(u8, unit, "grad"))
            number.value * std.math.pi / 200
        else if (std.mem.eql(u8, unit, "rad"))
            number.value
        else if (std.mem.eql(u8, unit, "turn"))
            number.value * 2 * std.math.pi
        else {
            try self.report(.invalid_operation, span, "native Sass trigonometric input requires an angle");
            return error.InvalidExpression;
        };
        if (!std.math.isFinite(radians)) {
            try self.report(.invalid_operation, span, "non-finite native Sass angle");
            return error.InvalidNumber;
        }
        return radians;
    }

    fn callMathTrigonometric(
        self: *Engine,
        builtin: Builtin,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const valid_arity = if (builtin == .math_atan2)
            arguments.len == 2
        else
            arguments.len == 1;
        if (!valid_arity) {
            try self.report(.invalid_operation, span, "invalid trigonometric function arity");
            return error.InvalidExpression;
        }
        try self.transaction.consumeOperations(@intCast(arguments.len));

        var degrees = false;
        const result = switch (builtin) {
            .math_sin, .math_cos, .math_tan => blk: {
                const number = try self.mathNumberArgument(arguments[0].*, span);
                const radians = try self.mathAngleRadians(number, span);
                break :blk switch (builtin) {
                    .math_sin => @sin(radians),
                    .math_cos => @cos(radians),
                    .math_tan => @tan(radians),
                    else => unreachable,
                };
            },
            .math_asin, .math_acos, .math_atan => blk: {
                const number = try self.mathNumberArgument(arguments[0].*, span);
                if (number.numerator_units.len != 0 or number.denominator_units.len != 0) {
                    try self.report(
                        .invalid_operation,
                        span,
                        "native Sass inverse trigonometric input must be unitless",
                    );
                    return error.InvalidExpression;
                }
                degrees = true;
                const radians = switch (builtin) {
                    .math_asin => std.math.asin(number.value),
                    .math_acos => std.math.acos(number.value),
                    .math_atan => std.math.atan(number.value),
                    else => unreachable,
                };
                break :blk radians * 180 / std.math.pi;
            },
            .math_atan2 => blk: {
                const y = try self.mathNumericArgument(arguments[0].*, span);
                const x = try self.mathNumericArgument(arguments[1].*, span);
                const converted_x = native_numeric.convertValueToMatch(x, y) catch |err| {
                    try self.report(
                        if (err == error.UnitLimitExceeded) .resource_limit else .invalid_operation,
                        span,
                        "native Sass atan2() arguments have incompatible units",
                    );
                    return err;
                };
                degrees = true;
                break :blk std.math.atan2(y.value, converted_x) * 180 / std.math.pi;
            },
            else => unreachable,
        };
        if (!std.math.isFinite(result)) {
            try self.report(.invalid_operation, span, "non-finite native Sass trigonometric result");
            return error.InvalidNumber;
        }
        return self.values.own(.{ .number = .{
            .value = result,
            .numerator_units = if (degrees) &.{"deg"} else &.{},
        } });
    }

    fn mathNumericArgument(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!Numeric {
        const number = try self.mathNumberArgument(item, span);
        return native_numeric.Numeric.fromNumber(number) catch |err| {
            try self.report(
                if (err == error.UnitLimitExceeded) .resource_limit else .invalid_operation,
                span,
                "invalid native Sass math predicate number",
            );
            return err;
        };
    }

    fn mathNumberArgument(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!native_value.Number {
        return switch (item) {
            .number => |value| value,
            else => {
                try self.report(.type_mismatch, span, "native Sass math function requires a number");
                return error.InvalidExpression;
            },
        };
    }

    fn callMathUnit(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 1) {
            try self.report(.invalid_operation, span, "math unit() requires exactly one number");
            return error.InvalidExpression;
        }
        const number = try self.mathNumberArgument(arguments[0].*, span);
        const unit_count = std.math.add(
            usize,
            number.numerator_units.len,
            number.denominator_units.len,
        ) catch {
            try self.report(.resource_limit, span, "native Sass math unit limit exceeded");
            return error.UnitLimitExceeded;
        };
        const operation_count = std.math.add(usize, unit_count, 1) catch {
            try self.report(.resource_limit, span, "native Sass math unit limit exceeded");
            return error.UnitLimitExceeded;
        };
        try self.transaction.consumeOperations(operation_count);
        const length = native_numeric.unitStringLength(number) catch |err| {
            try self.report(
                switch (err) {
                    error.UnitLimitExceeded, error.SerializationLimitExceeded => .resource_limit,
                    else => .invalid_operation,
                },
                span,
                "invalid native Sass math unit serialization",
            );
            return err;
        };
        if (length > self.limits.max_temporary_bytes) {
            try self.report(.resource_limit, span, "native Sass math unit output limit exceeded");
            return error.TemporaryLimitExceeded;
        }
        if (length == 0) {
            return self.values.own(.{ .string = .{ .bytes = "", .quoted = true } });
        }
        const bytes = try self.allocator.alloc(u8, length);
        defer self.allocator.free(bytes);
        const serialized = native_numeric.serializeUnits(number, bytes) catch |err| {
            try self.report(.invalid_operation, span, "invalid native Sass math unit serialization");
            return err;
        };
        return self.values.own(.{ .string = .{ .bytes = serialized, .quoted = true } });
    }

    fn evaluateMathNumericArgument(
        self: *Engine,
        raw: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        switch (try self.probeArithmetic(raw, scope, span, .numeric_function)) {
            .numeric => |numeric| {
                var numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
                var denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
                return self.values.own(.{
                    .number = try numeric.toNumber(&numerator, &denominator),
                });
            },
            .none => return self.evaluateExpressionBytes(raw, scope, span),
            .incompatible, .invalid => {
                try self.report(
                    .invalid_operation,
                    span,
                    "invalid native Sass math function expression",
                );
                return error.InvalidExpression;
            },
        }
    }

    fn tryModuleBuiltin(
        self: *Engine,
        name: []const u8,
        span: native_source.Span,
    ) Error!?Builtin {
        if (isSimpleIdentifier(name)) {
            for (self.modules.items) |binding| {
                if (binding.namespace != null) continue;
                const builtin = switch (binding.kind) {
                    .color => colorModuleBuiltin(name),
                    .list => listModuleBuiltin(name),
                    .map => mapModuleBuiltin(name),
                    .math => mathModuleBuiltin(name),
                    .meta => metaModuleBuiltin(name),
                    .selector => selectorModuleBuiltin(name),
                    .string => stringModuleBuiltin(name),
                };
                if (builtin) |resolved| return resolved;
                if ((binding.kind == .math and mathModuleOwnsFunction(name)) or
                    (binding.kind == .selector and selectorModuleOwnsFunction(name)))
                {
                    try self.report(
                        .invalid_operation,
                        span,
                        "undefined native Sass module function",
                    );
                    return error.InvalidExpression;
                }
            }
            return null;
        }

        const qualified = parseQualifiedName(name) orelse return null;
        var matched: ?BuiltinModule = null;
        for (self.modules.items) |binding| {
            const namespace = binding.namespace orelse continue;
            if (std.mem.eql(u8, namespace, qualified.namespace)) {
                matched = binding.kind;
                break;
            }
        }
        const module = matched orelse {
            try self.report(.invalid_operation, span, "Sass module namespace is not loaded");
            return error.InvalidExpression;
        };
        const builtin = switch (module) {
            .color => colorModuleBuiltin(qualified.member),
            .list => listModuleBuiltin(qualified.member),
            .map => mapModuleBuiltin(qualified.member),
            .math => mathModuleBuiltin(qualified.member),
            .meta => metaModuleBuiltin(qualified.member),
            .selector => selectorModuleBuiltin(qualified.member),
            .string => stringModuleBuiltin(qualified.member),
        };
        return builtin orelse {
            try self.report(.invalid_operation, span, "undefined native Sass module function");
            return error.InvalidExpression;
        };
    }

    fn tryModuleVariable(
        self: *Engine,
        raw: []const u8,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const constant = (try self.tryModuleConstant(raw, span)) orelse return null;
        return self.values.own(.{ .number = .{ .value = constant } });
    }

    fn tryModuleConstant(
        self: *Engine,
        raw: []const u8,
        span: native_source.Span,
    ) Error!?f64 {
        const qualified = parseQualifiedVariable(raw) orelse return null;
        var matched: ?BuiltinModule = null;
        for (self.modules.items) |binding| {
            const namespace = binding.namespace orelse continue;
            if (std.mem.eql(u8, namespace, qualified.namespace)) {
                matched = binding.kind;
                break;
            }
        }
        const module = matched orelse {
            try self.report(.invalid_operation, span, "Sass module namespace is not loaded");
            return error.InvalidExpression;
        };
        const value = if (module == .math)
            mathModuleConstant(qualified.member)
        else
            null;
        return value orelse {
            try self.report(.undefined_variable, span, "undefined native Sass module variable");
            return error.InvalidExpression;
        };
    }

    fn tryBuiltinCall(
        self: *Engine,
        raw: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const opening = std.mem.indexOfScalar(u8, raw, '(') orelse return null;
        if (opening == 0 or !fullyWrapped(raw[opening..], '(', ')')) return null;
        const name = raw[0..opening];
        const module_builtin = try self.tryModuleBuiltin(name, span);
        const builtin = module_builtin orelse blk: {
            if (!isSimpleIdentifier(name)) return null;
            break :blk globalBuiltin(name) orelse return null;
        };

        const body = raw[opening + 1 .. raw.len - 1];
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        const comma_separated = try splitTopLevelRanges(self.allocator, body, .comma, &ranges);
        if (trimWhitespace(body).len == 0) ranges.clearRetainingCapacity();
        if (ranges.items.len > self.limits.max_function_arguments) {
            try self.report(.resource_limit, span, "native Sass function argument limit exceeded");
            return error.FunctionArgumentLimitExceeded;
        }
        for (ranges.items) |range| {
            if (trimWhitespace(body[range.start..range.end]).len == 0) {
                try self.report(.syntax, span, "empty native Sass function argument");
                return error.InvalidExpression;
            }
        }

        switch (builtin) {
            .meta_call => return try self.callMetaCallRaw(
                module_builtin != null,
                body,
                ranges.items,
                scope,
                span,
            ),
            .map_get, .map_has_key => return try self.callMapQueryRaw(
                builtin,
                body,
                ranges.items,
                scope,
                span,
            ),
            .map_merge,
            .map_remove,
            .map_set,
            .map_deep_merge,
            .map_deep_remove,
            => return try self.callMapMutationRaw(
                builtin,
                body,
                ranges.items,
                scope,
                span,
            ),
            .list_zip => return try self.callListZipRaw(
                body,
                ranges.items,
                scope,
                span,
            ),
            .list_slash => return try self.callListSlashRaw(
                body,
                ranges.items,
                scope,
                span,
            ),
            .math_min, .math_max, .math_hypot => return try self.callMathVariadicRaw(
                builtin,
                module_builtin != null,
                raw,
                body,
                ranges.items,
                scope,
                span,
            ),
            .selector_append, .selector_nest => return try self.callSelectorCompositionRaw(
                builtin,
                body,
                ranges.items,
                scope,
                span,
            ),
            .nth,
            .length,
            .list_index,
            .list_separator,
            .list_is_bracketed,
            .list_append,
            .list_set_nth,
            .list_join,
            .map_keys,
            .map_values,
            .math_abs,
            .math_acos,
            .math_asin,
            .math_atan,
            .math_atan2,
            .math_ceil,
            .math_compatible,
            .math_cos,
            .math_clamp,
            .math_div,
            .math_floor,
            .math_is_unitless,
            .math_log,
            .math_percentage,
            .math_pow,
            .math_round,
            .math_sin,
            .math_sqrt,
            .math_tan,
            .math_unit,
            .meta_accepts_content,
            .meta_calc_args,
            .meta_calc_name,
            .meta_content_exists,
            .meta_feature_exists,
            .meta_function_exists,
            .meta_get_function,
            .meta_get_mixin,
            .meta_global_variable_exists,
            .meta_inspect,
            .meta_keywords,
            .meta_mixin_exists,
            .meta_type_of,
            .meta_variable_exists,
            .selector_extend,
            .selector_is_superselector,
            .selector_replace,
            .selector_unify,
            .selector_parse,
            .selector_simple_selectors,
            .red,
            .green,
            .blue,
            .alpha,
            .opacity,
            .hue,
            .saturation,
            .lightness,
            .mix,
            .lighten,
            .darken,
            .saturate,
            .desaturate,
            .adjust_hue,
            .complement,
            .grayscale,
            .invert,
            .opacify,
            .fade_in,
            .transparentize,
            .fade_out,
            .ie_hex_str,
            => return try self.callFixedBuiltinRaw(
                builtin,
                module_builtin != null,
                raw,
                body,
                ranges.items,
                scope,
                span,
            ),
            .math_random => return try self.callMathRandomRaw(
                body,
                ranges.items,
                scope,
                span,
            ),
            .quote,
            .unquote,
            .str_length,
            .str_index,
            .str_slice,
            .str_insert,
            .to_upper_case,
            .to_lower_case,
            => return try self.callStringBuiltinRaw(
                builtin,
                body,
                ranges.items,
                scope,
                span,
            ),
            .adjust_color, .change_color, .scale_color => return try self.callColorTransformRaw(
                builtin,
                body,
                ranges.items,
                scope,
                span,
            ),
            .calculation, .minimum, .maximum, .clamp => return try self.callCalculation(
                builtin,
                raw,
                body,
                ranges.items,
                scope,
                span,
            ),
            // Dart Sass 1.101.0 exposes whiteness and blackness only as
            // sass:color callable references here. Direct calls remain
            // outside these evidence-closed slices.
            .whiteness, .blackness => return null,
            .rgb, .rgba, .hsl, .hsla, .hwb => return try self.callColorConstructorRaw(
                builtin,
                raw,
                body,
                ranges.items,
                comma_separated,
                scope,
                span,
            ),
            .lab, .lch, .oklab, .oklch => return try self.callModernColorConstructorRaw(
                builtin,
                raw,
                body,
                ranges.items,
                comma_separated,
                scope,
                span,
            ),
            .color => return try self.callPredefinedColorRaw(
                raw,
                body,
                ranges.items,
                comma_separated,
                scope,
                span,
            ),
        }
    }

    fn callPredefinedColorRaw(
        self: *Engine,
        raw: []const u8,
        body: []const u8,
        ranges: []const ExpressionRange,
        comma_separated: bool,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (comma_separated) {
            try self.report(.syntax, span, "color() requires one space-separated description");
            return error.InvalidExpression;
        }
        var parsed = native_arguments.parseAlloc(
            self.allocator,
            body,
            ranges,
            self.limits.max_function_arguments,
        ) catch |err| return self.argumentsFailure(err, span);
        defer parsed.deinit();
        const parameters = [_]native_arguments.Parameter{.{ .name = "description" }};
        var bound = native_arguments.bindAlloc(
            self.allocator,
            parsed.items,
            &parameters,
            1,
        ) catch |err| return self.argumentsFailure(err, span);
        defer bound.deinit();
        const description_range = bound.values[0].?;
        const allow_deferred = parsed.items.len == 1 and parsed.items[0].name == null;
        return self.callPredefinedColor(
            raw,
            body[description_range.start..description_range.end],
            allow_deferred,
            scope,
            span,
        );
    }

    fn callPredefinedColor(
        self: *Engine,
        raw: []const u8,
        body: []const u8,
        allow_deferred: bool,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        const slash = findTopLevelByte(body, '/');
        if (slash) |separator| {
            if (findTopLevelByte(body[separator + 1 ..], '/') != null) {
                try self.report(.syntax, span, "color() has multiple alpha separators");
                return error.InvalidExpression;
            }
            if (trimWhitespace(body[separator + 1 ..]).len == 0) {
                try self.report(.syntax, span, "color() is missing its alpha channel");
                return error.InvalidExpression;
            }
        }
        const description_end = slash orelse body.len;
        _ = try splitTopLevelRanges(
            self.allocator,
            body[0..description_end],
            .color_whitespace,
            &ranges,
        );
        if (trimWhitespace(body[0..description_end]).len == 0) ranges.clearRetainingCapacity();
        const total_parts = ranges.items.len + @intFromBool(slash != null);
        if (total_parts > self.limits.max_function_arguments) {
            try self.report(.resource_limit, span, "native Sass function argument limit exceeded");
            return error.FunctionArgumentLimitExceeded;
        }
        if (containsDeferredCssCalculation(body)) {
            if (allow_deferred) return self.preserveColorFunction(raw, scope, span);
            try self.report(
                .unsupported_feature,
                span,
                "deferred Sass keyword color descriptions are not implemented by the native evaluator yet",
            );
            return error.UnsupportedFeature;
        }
        if (ranges.items.len != 4) {
            try self.report(
                .invalid_operation,
                span,
                "color() requires one predefined space and exactly three channels",
            );
            return error.InvalidExpression;
        }
        if (slash) |separator| {
            try ranges.append(self.allocator, .{ .start = separator + 1, .end = body.len });
        }
        for (ranges.items) |range| {
            if (trimWhitespace(body[range.start..range.end]).len == 0) {
                try self.report(.syntax, span, "empty color() description component");
                return error.InvalidExpression;
            }
        }

        const space_item = try self.evaluateExpressionBytes(
            body[ranges.items[0].start..ranges.items[0].end],
            scope,
            span,
        );
        if (isDeferredColorValue(space_item.*)) {
            if (allow_deferred) return self.preserveColorFunction(raw, scope, span);
            try self.report(
                .unsupported_feature,
                span,
                "deferred Sass keyword color descriptions are not implemented by the native evaluator yet",
            );
            return error.UnsupportedFeature;
        }
        const space = try self.predefinedColorSpace(space_item.*, span);
        var channels = [4]f64{ 0, 0, 0, 1 };
        var missing_mask: u4 = 0;
        const missing_bits = [4]u4{ 0b0001, 0b0010, 0b0100, 0b1000 };
        for (ranges.items[1..], 0..) |range, index| {
            const item = try self.evaluateExpressionBytes(body[range.start..range.end], scope, span);
            if (isDeferredColorValue(item.*)) {
                if (allow_deferred) return self.preserveColorFunction(raw, scope, span);
                try self.report(
                    .unsupported_feature,
                    span,
                    "deferred Sass keyword color descriptions are not implemented by the native evaluator yet",
                );
                return error.UnsupportedFeature;
            }
            const kind: ModernColorChannelKind = if (index == 3) .alpha else .predefined;
            const channel = try self.modernColorChannel(item.*, kind, span);
            channels[index] = channel.value;
            if (channel.missing) missing_mask |= missing_bits[index];
        }
        return self.values.own(.{
            .color = try native_color.predefined(space, channels, missing_mask),
        });
    }

    fn callModernColorConstructorRaw(
        self: *Engine,
        builtin: Builtin,
        raw: []const u8,
        body: []const u8,
        ranges: []const ExpressionRange,
        comma_separated: bool,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (comma_separated) {
            try self.report(.syntax, span, "modern Sass colors require one space-separated channel list");
            return error.InvalidExpression;
        }
        var parsed = native_arguments.parseAlloc(
            self.allocator,
            body,
            ranges,
            self.limits.max_function_arguments,
        ) catch |err| return self.argumentsFailure(err, span);
        defer parsed.deinit();
        const parameters = [_]native_arguments.Parameter{.{ .name = "channels" }};
        var bound = native_arguments.bindAlloc(
            self.allocator,
            parsed.items,
            &parameters,
            1,
        ) catch |err| return self.argumentsFailure(err, span);
        defer bound.deinit();
        const channel_range = bound.values[0].?;
        const allow_deferred = parsed.items.len == 1 and parsed.items[0].name == null;
        return self.callModernColorConstructor(
            builtin,
            raw,
            body[channel_range.start..channel_range.end],
            allow_deferred,
            scope,
            span,
        );
    }

    fn callModernColorConstructor(
        self: *Engine,
        builtin: Builtin,
        raw: []const u8,
        body: []const u8,
        allow_deferred: bool,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        const slash = findTopLevelByte(body, '/');
        if (slash) |separator| {
            if (findTopLevelByte(body[separator + 1 ..], '/') != null) {
                try self.report(.syntax, span, "modern Sass color has multiple alpha separators");
                return error.InvalidExpression;
            }
            if (trimWhitespace(body[separator + 1 ..]).len == 0) {
                try self.report(.syntax, span, "modern Sass color is missing its alpha channel");
                return error.InvalidExpression;
            }
        }
        const channel_end = slash orelse body.len;
        _ = try splitTopLevelRanges(
            self.allocator,
            body[0..channel_end],
            .color_whitespace,
            &ranges,
        );
        if (trimWhitespace(body[0..channel_end]).len == 0) ranges.clearRetainingCapacity();
        const total_channels = ranges.items.len + @intFromBool(slash != null);
        if (total_channels > self.limits.max_function_arguments) {
            try self.report(.resource_limit, span, "native Sass function argument limit exceeded");
            return error.FunctionArgumentLimitExceeded;
        }
        if (containsDeferredCssCalculation(body)) {
            if (allow_deferred) return self.preserveColorFunction(raw, scope, span);
            try self.report(
                .unsupported_feature,
                span,
                "deferred Sass keyword color constructors are not implemented by the native evaluator yet",
            );
            return error.UnsupportedFeature;
        }
        if (ranges.items.len != 3) {
            try self.report(
                .invalid_operation,
                span,
                "modern Sass colors require exactly three space-separated channels",
            );
            return error.InvalidExpression;
        }
        if (slash) |separator| {
            const alpha_start = separator + 1;
            try ranges.append(self.allocator, .{ .start = alpha_start, .end = body.len });
        }
        for (ranges.items) |range| {
            if (trimWhitespace(body[range.start..range.end]).len == 0) {
                try self.report(.syntax, span, "empty modern Sass color channel");
                return error.InvalidExpression;
            }
        }
        var arguments: [4]*const native_value.Value = undefined;
        for (ranges.items, 0..) |range, index| {
            const item = try self.evaluateExpressionBytes(body[range.start..range.end], scope, span);
            if (isDeferredColorValue(item.*)) {
                if (allow_deferred) return self.preserveColorFunction(raw, scope, span);
                try self.report(
                    .unsupported_feature,
                    span,
                    "deferred Sass keyword color constructors are not implemented by the native evaluator yet",
                );
                return error.UnsupportedFeature;
            }
            arguments[index] = item;
        }

        const space: native_value.ColorSpace = switch (builtin) {
            .lab => .lab,
            .lch => .lch,
            .oklab => .oklab,
            .oklch => .oklch,
            else => unreachable,
        };
        const kinds: [4]ModernColorChannelKind = switch (builtin) {
            .lab => .{ .lab_lightness, .lab_axis, .lab_axis, .alpha },
            .lch => .{ .lab_lightness, .lch_chroma, .hue, .alpha },
            .oklab => .{ .oklab_lightness, .oklab_axis, .oklab_axis, .alpha },
            .oklch => .{ .oklab_lightness, .oklch_chroma, .hue, .alpha },
            else => unreachable,
        };
        var channels = [4]f64{ 0, 0, 0, 1 };
        var missing_mask: u4 = 0;
        const missing_bits = [4]u4{ 0b0001, 0b0010, 0b0100, 0b1000 };
        for (arguments[0..ranges.items.len], 0..) |argument, index| {
            const channel = try self.modernColorChannel(argument.*, kinds[index], span);
            channels[index] = channel.value;
            if (channel.missing) missing_mask |= missing_bits[index];
        }
        return self.values.own(.{
            .color = try native_color.modern(space, channels, missing_mask),
        });
    }

    fn callColorConstructorRaw(
        self: *Engine,
        builtin: Builtin,
        raw: []const u8,
        body: []const u8,
        ranges: []const ExpressionRange,
        comma_separated: bool,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var parsed = native_arguments.parseAlloc(
            self.allocator,
            body,
            ranges,
            self.limits.max_function_arguments,
        ) catch |err| return self.argumentsFailure(err, span);
        defer parsed.deinit();

        var has_keyword = false;
        var has_channels = false;
        var has_color = false;
        for (parsed.items) |argument| {
            if (argument.splat) return self.argumentsFailure(error.SplatUnsupported, span);
            const name = argument.name orelse continue;
            has_keyword = true;
            has_channels = has_channels or native_arguments.nameEql(name, "channels");
            has_color = has_color or native_arguments.nameEql(name, "color");
        }
        if (!has_keyword) {
            return self.callColorConstructor(
                builtin,
                raw,
                body,
                ranges,
                comma_separated,
                true,
                scope,
                span,
            );
        }

        const channels_parameters = [_]native_arguments.Parameter{
            .{ .name = "channels" },
        };
        const color_parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
            .{ .name = "alpha" },
        };
        const rgb_parameters = [_]native_arguments.Parameter{
            .{ .name = "red" },
            .{ .name = "green" },
            .{ .name = "blue" },
            .{ .name = "alpha", .required = false },
        };
        const hsl_parameters = [_]native_arguments.Parameter{
            .{ .name = "hue" },
            .{ .name = "saturation" },
            .{ .name = "lightness" },
            .{ .name = "alpha", .required = false },
        };
        const parameters: []const native_arguments.Parameter = if (has_channels)
            &channels_parameters
        else if (has_color and (builtin == .rgb or builtin == .rgba))
            &color_parameters
        else switch (builtin) {
            .rgb, .rgba => &rgb_parameters,
            .hsl, .hsla => &hsl_parameters,
            .hwb => &channels_parameters,
            else => unreachable,
        };
        var bound = native_arguments.bindAlloc(
            self.allocator,
            parsed.items,
            parameters,
            parameters.len,
        ) catch |err| return self.argumentsFailure(err, span);
        defer bound.deinit();

        if (has_channels) {
            const channel_range = bound.values[0].?;
            return self.callColorConstructor(
                builtin,
                raw,
                body[channel_range.start..channel_range.end],
                &.{},
                false,
                false,
                scope,
                span,
            );
        }

        var ordered_ranges: [4]ExpressionRange = undefined;
        var ordered_count: usize = 0;
        for (bound.values) |value_range| {
            const range = value_range orelse continue;
            ordered_ranges[ordered_count] = range;
            ordered_count += 1;
        }
        return self.callColorConstructor(
            builtin,
            raw,
            body,
            ordered_ranges[0..ordered_count],
            true,
            false,
            scope,
            span,
        );
    }

    fn callColorConstructor(
        self: *Engine,
        builtin: Builtin,
        raw: []const u8,
        body: []const u8,
        comma_ranges: []const ExpressionRange,
        comma_separated: bool,
        allow_deferred: bool,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        if (comma_separated) {
            if (builtin == .hwb) {
                try self.report(.syntax, span, "hwb() requires modern space-separated syntax");
                return error.InvalidExpression;
            }
            if (findTopLevelByte(body, '/') != null) {
                try self.report(.syntax, span, "native Sass color cannot mix comma and slash syntax");
                return error.InvalidExpression;
            }
            try ranges.appendSlice(self.allocator, comma_ranges);
        } else {
            const slash = findTopLevelByte(body, '/');
            const channel_end = slash orelse body.len;
            _ = try splitTopLevelRanges(
                self.allocator,
                body[0..channel_end],
                .color_whitespace,
                &ranges,
            );
            if (trimWhitespace(body[0..channel_end]).len == 0) ranges.clearRetainingCapacity();
            if (slash) |separator| {
                if (findTopLevelByte(body[separator + 1 ..], '/') != null) {
                    try self.report(.syntax, span, "native Sass color has multiple alpha separators");
                    return error.InvalidExpression;
                }
                const alpha_start = separator + 1;
                if (trimWhitespace(body[alpha_start..]).len == 0) {
                    try self.report(.syntax, span, "native Sass color is missing its alpha channel");
                    return error.InvalidExpression;
                }
                try ranges.append(self.allocator, .{ .start = alpha_start, .end = body.len });
            }
        }
        if (ranges.items.len > self.limits.max_function_arguments) {
            try self.report(.resource_limit, span, "native Sass function argument limit exceeded");
            return error.FunctionArgumentLimitExceeded;
        }
        for (ranges.items) |range| {
            if (trimWhitespace(body[range.start..range.end]).len == 0) {
                try self.report(.syntax, span, "empty native Sass color channel");
                return error.InvalidExpression;
            }
        }
        if (containsDeferredCssCalculation(body)) {
            if (allow_deferred) return self.preserveColorFunction(raw, scope, span);
            try self.report(
                .unsupported_feature,
                span,
                "deferred Sass keyword color constructors are not implemented by the native evaluator yet",
            );
            return error.UnsupportedFeature;
        }

        var arguments: std.ArrayList(*const native_value.Value) = .empty;
        defer arguments.deinit(self.allocator);
        for (ranges.items) |range| {
            const item = try self.evaluateExpressionBytes(body[range.start..range.end], scope, span);
            if (isDeferredColorValue(item.*)) {
                if (allow_deferred) return self.preserveColorFunction(raw, scope, span);
                try self.report(
                    .unsupported_feature,
                    span,
                    "deferred Sass keyword color constructors are not implemented by the native evaluator yet",
                );
                return error.UnsupportedFeature;
            }
            try arguments.append(self.allocator, item);
        }

        if ((builtin == .rgb or builtin == .rgba) and comma_separated and
            arguments.items.len == 2 and
            arguments.items[0].* == .color)
        {
            const alpha = try self.colorAlpha(arguments.items[1].*, span);
            var result = arguments.items[0].color;
            result.channels[3] = alpha;
            return self.values.own(.{ .color = result });
        }
        if (arguments.items.len != 3 and arguments.items.len != 4) {
            try self.report(
                .invalid_operation,
                span,
                "native Sass color constructors require three channels and optional alpha",
            );
            return error.InvalidExpression;
        }
        const alpha = if (arguments.items.len == 4)
            try self.colorAlpha(arguments.items[3].*, span)
        else
            1;
        const result = switch (builtin) {
            .rgb, .rgba => try native_color.rgb(
                try self.rgbChannel(arguments.items[0].*, span),
                try self.rgbChannel(arguments.items[1].*, span),
                try self.rgbChannel(arguments.items[2].*, span),
                alpha,
            ),
            .hsl, .hsla => try native_color.hsl(
                try self.colorHue(arguments.items[0].*, span),
                try self.colorPercentage(arguments.items[1].*, span),
                try self.colorPercentage(arguments.items[2].*, span),
                alpha,
            ),
            .hwb => try native_color.hwb(
                try self.colorHue(arguments.items[0].*, span),
                try self.colorPercentage(arguments.items[1].*, span),
                try self.colorPercentage(arguments.items[2].*, span),
                alpha,
            ),
            else => unreachable,
        };
        return self.values.own(.{ .color = result });
    }

    fn callColorChannel(
        self: *Engine,
        builtin: Builtin,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 1 or arguments[0].* != .color) {
            try self.report(.type_mismatch, span, "native Sass color channel functions require one color");
            return error.InvalidExpression;
        }
        const color = arguments[0].color;
        var unit: ?[]const u8 = null;
        const value = switch (builtin) {
            .red => (try native_color.toRgb(color))[0],
            .green => (try native_color.toRgb(color))[1],
            .blue => (try native_color.toRgb(color))[2],
            .alpha => (try native_color.toRgb(color))[3],
            .hue => blk: {
                unit = "deg";
                break :blk (try native_color.toHsl(color))[0];
            },
            .saturation => blk: {
                unit = "%";
                break :blk (try native_color.toHsl(color))[1];
            },
            .lightness => blk: {
                unit = "%";
                break :blk (try native_color.toHsl(color))[2];
            },
            else => unreachable,
        };
        if (unit) |name| {
            const units = [_][]const u8{name};
            return self.values.own(.{ .number = .{
                .value = value,
                .numerator_units = &units,
            } });
        }
        return self.values.own(.{ .number = .{ .value = value } });
    }

    fn callColorOpacity(
        self: *Engine,
        raw: []const u8,
        arguments: []const *const native_value.Value,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 1) {
            try self.report(.invalid_operation, span, "opacity() requires exactly one argument");
            return error.InvalidExpression;
        }
        return switch (arguments[0].*) {
            .color => |color| self.values.own(.{
                .number = .{ .value = (try native_color.toRgb(color))[3] },
            }),
            .number => self.preserveColorFunction(raw, scope, span),
            else => if (isDeferredColorValue(arguments[0].*))
                self.preserveColorFunction(raw, scope, span)
            else blk: {
                try self.report(.type_mismatch, span, "opacity() requires a color or CSS filter amount");
                break :blk error.InvalidExpression;
            },
        };
    }

    fn callIeHexStr(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 1 or arguments[0].* != .color) {
            try self.report(.type_mismatch, span, "ie-hex-str() requires exactly one color");
            return error.InvalidExpression;
        }
        var buffer: [9]u8 = undefined;
        return self.values.own(.{ .string = .{
            .bytes = try native_color.serializeIeHex(arguments[0].color, &buffer),
        } });
    }

    fn callColorManipulation(
        self: *Engine,
        builtin: Builtin,
        raw: []const u8,
        arguments: []const *const native_value.Value,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if ((builtin == .saturate or builtin == .grayscale or builtin == .invert) and
            arguments.len == 1 and arguments[0].* != .color)
        {
            const css_filter = switch (arguments[0].*) {
                .number => true,
                else => isDeferredColorValue(arguments[0].*),
            };
            if (css_filter) return self.preserveColorFunction(raw, scope, span);
        }

        const result = switch (builtin) {
            .mix => blk: {
                if (arguments.len != 2 and arguments.len != 3) {
                    try self.report(.invalid_operation, span, "mix() requires two colors and optional weight");
                    return error.InvalidExpression;
                }
                const weight = if (arguments.len == 3)
                    try self.legacyColorAmount(arguments[2].*, 0, 100, span)
                else
                    50;
                break :blk try native_color.mix(
                    try self.colorArgument(arguments[0].*, span),
                    try self.colorArgument(arguments[1].*, span),
                    weight,
                );
            },
            .lighten, .darken, .saturate, .desaturate => blk: {
                if (arguments.len != 2) {
                    try self.report(.invalid_operation, span, "legacy Sass color adjustment requires two arguments");
                    return error.InvalidExpression;
                }
                const color = try self.colorArgument(arguments[0].*, span);
                var amount = try self.legacyColorAmount(arguments[1].*, 0, 100, span);
                if (builtin == .darken or builtin == .desaturate) amount = -amount;
                break :blk if (builtin == .lighten or builtin == .darken)
                    try native_color.adjustLightness(color, amount)
                else
                    try native_color.adjustSaturation(color, amount);
            },
            .adjust_hue => blk: {
                if (arguments.len != 2) {
                    try self.report(.invalid_operation, span, "adjust-hue() requires a color and angle");
                    return error.InvalidExpression;
                }
                break :blk try native_color.adjustHue(
                    try self.colorArgument(arguments[0].*, span),
                    try self.colorHue(arguments[1].*, span),
                );
            },
            .complement => blk: {
                if (arguments.len != 1) {
                    try self.report(.invalid_operation, span, "complement() requires exactly one color");
                    return error.InvalidExpression;
                }
                break :blk try native_color.adjustHue(
                    try self.colorArgument(arguments[0].*, span),
                    180,
                );
            },
            .grayscale => blk: {
                if (arguments.len != 1) {
                    try self.report(.invalid_operation, span, "grayscale() requires exactly one color");
                    return error.InvalidExpression;
                }
                break :blk try native_color.grayscale(
                    try self.colorArgument(arguments[0].*, span),
                );
            },
            .invert => blk: {
                if (arguments.len != 1 and arguments.len != 2) {
                    try self.report(.invalid_operation, span, "invert() requires a color and optional weight");
                    return error.InvalidExpression;
                }
                const weight = if (arguments.len == 2)
                    try self.legacyColorAmount(arguments[1].*, 0, 100, span)
                else
                    100;
                break :blk try native_color.invert(
                    try self.colorArgument(arguments[0].*, span),
                    weight,
                );
            },
            .opacify, .fade_in, .transparentize, .fade_out => blk: {
                if (arguments.len != 2) {
                    try self.report(.invalid_operation, span, "alpha adjustment requires a color and amount");
                    return error.InvalidExpression;
                }
                var amount = try self.alphaAdjustmentAmount(arguments[1].*, span);
                if (builtin == .transparentize or builtin == .fade_out) amount = -amount;
                break :blk try native_color.adjustAlpha(
                    try self.colorArgument(arguments[0].*, span),
                    amount,
                );
            },
            else => unreachable,
        };
        return self.values.own(.{ .color = result });
    }

    fn callColorTransformRaw(
        self: *Engine,
        builtin: Builtin,
        body: []const u8,
        ranges: []const ExpressionRange,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var parsed = native_arguments.parseAlloc(
            self.allocator,
            body,
            ranges,
            self.limits.max_function_arguments,
        ) catch |err| return self.argumentsFailure(err, span);
        defer parsed.deinit();
        var bound = native_arguments.bindAlloc(
            self.allocator,
            parsed.items,
            &color_transform_parameters,
            1,
        ) catch |err| return self.argumentsFailure(err, span);
        defer bound.deinit();

        var values: [color_transform_parameters.len]?*const native_value.Value = @splat(null);
        for (bound.values, 0..) |value_range, index| {
            const range = value_range orelse continue;
            values[index] = try self.evaluateExpressionBytes(
                body[range.start..range.end],
                scope,
                span,
            );
        }
        return self.callColorTransform(builtin, &values, span);
    }

    fn callColorTransform(
        self: *Engine,
        builtin: Builtin,
        values: []const ?*const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        std.debug.assert(values.len == color_transform_parameters.len);
        const color_index = 0;
        const red_index = 1;
        const green_index = 2;
        const blue_index = 3;
        const hue_index = 4;
        const saturation_index = 5;
        const lightness_index = 6;
        const whiteness_index = 7;
        const blackness_index = 8;
        const alpha_index = 9;
        const space_index = 10;
        const a_index = 11;
        const b_index = 12;
        const chroma_index = 13;
        const x_index = 14;
        const y_index = 15;
        const z_index = 16;
        const color = try self.colorArgument(values[color_index].?.*, span);
        const kind: native_color.TransformKind = switch (builtin) {
            .adjust_color => .adjust,
            .change_color => .change,
            .scale_color => .scale,
            else => unreachable,
        };
        if (kind == .scale and values[hue_index] != null) {
            try self.report(.invalid_operation, span, "scale-color() cannot scale a hue channel");
            return error.InvalidExpression;
        }

        const has_rgb = values[red_index] != null or values[green_index] != null or
            values[blue_index] != null;
        const has_hue = values[hue_index] != null;
        const has_hsl = values[saturation_index] != null or values[lightness_index] != null;
        const has_hwb = values[whiteness_index] != null or values[blackness_index] != null;
        const has_modern_only = values[a_index] != null or values[b_index] != null or
            values[chroma_index] != null or values[x_index] != null or
            values[y_index] != null or values[z_index] != null;
        const channel_bindings = [_]struct {
            index: usize,
            channel: ColorTransformChannel,
        }{
            .{ .index = red_index, .channel = .red },
            .{ .index = green_index, .channel = .green },
            .{ .index = blue_index, .channel = .blue },
            .{ .index = hue_index, .channel = .hue },
            .{ .index = saturation_index, .channel = .saturation },
            .{ .index = lightness_index, .channel = .lightness },
            .{ .index = whiteness_index, .channel = .whiteness },
            .{ .index = blackness_index, .channel = .blackness },
            .{ .index = a_index, .channel = .lab_a },
            .{ .index = b_index, .channel = .lab_b },
            .{ .index = chroma_index, .channel = .chroma },
            .{ .index = x_index, .channel = .x },
            .{ .index = y_index, .channel = .y },
            .{ .index = z_index, .channel = .z },
        };
        var has_color_channel = false;
        for (channel_bindings) |binding| {
            if (values[binding.index] != null) has_color_channel = true;
        }
        const explicit_space = if (values[space_index]) |item|
            try self.colorTransformSpace(item.*, span)
        else
            null;
        const input_is_modern = switch (color.space) {
            .rgb, .hsl, .hwb => false,
            else => true,
        };
        const selected_space: ?ColorTransformSpace = if (explicit_space) |space|
            space
        else if (has_color_channel and input_is_modern)
            transformSpaceForColorSpace(color.space)
        else blk: {
            if (has_modern_only) {
                try self.report(
                    .invalid_operation,
                    span,
                    "native Sass modern color channel requires an inferable or explicit color space",
                );
                return error.InvalidExpression;
            }
            break :blk if (has_rgb)
                .rgb
            else if (has_hwb)
                .hwb
            else if (has_hsl)
                .hsl
            else if (has_hue)
                if (color.space == .hwb) .hwb else .hsl
            else
                null;
        };
        if (selected_space) |space| {
            for (channel_bindings) |binding| {
                if (values[binding.index] != null and
                    !colorTransformSpaceSupports(space, binding.channel))
                {
                    try self.report(
                        .invalid_operation,
                        span,
                        "native Sass color channel does not belong to the selected color space",
                    );
                    return error.InvalidExpression;
                }
            }
        }
        const alpha = if (values[alpha_index]) |item|
            try self.colorTransformAlpha(item.*, kind, span)
        else
            null;

        const effective_space = selected_space orelse .rgb;
        const result = switch (effective_space) {
            .rgb => native_color.transformRgb(color, kind, .{
                .red = if (values[red_index]) |item|
                    try self.colorTransformRgbChannel(item.*, kind, span)
                else
                    null,
                .green = if (values[green_index]) |item|
                    try self.colorTransformRgbChannel(item.*, kind, span)
                else
                    null,
                .blue = if (values[blue_index]) |item|
                    try self.colorTransformRgbChannel(item.*, kind, span)
                else
                    null,
                .alpha = alpha,
            }),
            .hsl => native_color.transformHsl(color, kind, .{
                .hue = if (values[hue_index]) |item| try self.colorHue(item.*, span) else null,
                .saturation = if (values[saturation_index]) |item|
                    try self.colorTransformPercentage(item.*, kind, span)
                else
                    null,
                .lightness = if (values[lightness_index]) |item|
                    try self.colorTransformPercentage(item.*, kind, span)
                else
                    null,
                .alpha = alpha,
            }),
            .hwb => native_color.transformHwb(color, kind, .{
                .hue = if (values[hue_index]) |item| try self.colorHue(item.*, span) else null,
                .whiteness = if (values[whiteness_index]) |item|
                    try self.colorTransformPercentage(item.*, kind, span)
                else
                    null,
                .blackness = if (values[blackness_index]) |item|
                    try self.colorTransformPercentage(item.*, kind, span)
                else
                    null,
                .alpha = alpha,
            }),
            .lab => native_color.transformModern(
                color,
                nativeColorTransformSpace(.lab),
                kind,
                .{
                    .channels = .{
                        try self.colorTransformModernChannel(
                            values[lightness_index],
                            kind,
                            .lab_lightness,
                            span,
                        ),
                        try self.colorTransformModernChannel(
                            values[a_index],
                            kind,
                            .lab_axis,
                            span,
                        ),
                        try self.colorTransformModernChannel(
                            values[b_index],
                            kind,
                            .lab_axis,
                            span,
                        ),
                    },
                    .alpha = alpha,
                },
            ),
            .lch => native_color.transformModern(
                color,
                nativeColorTransformSpace(.lch),
                kind,
                .{
                    .channels = .{
                        try self.colorTransformModernChannel(
                            values[lightness_index],
                            kind,
                            .lab_lightness,
                            span,
                        ),
                        try self.colorTransformModernChannel(
                            values[chroma_index],
                            kind,
                            .lch_chroma,
                            span,
                        ),
                        try self.colorTransformModernChannel(
                            values[hue_index],
                            kind,
                            .hue,
                            span,
                        ),
                    },
                    .alpha = alpha,
                },
            ),
            .oklab => native_color.transformModern(
                color,
                nativeColorTransformSpace(.oklab),
                kind,
                .{
                    .channels = .{
                        try self.colorTransformModernChannel(
                            values[lightness_index],
                            kind,
                            .oklab_lightness,
                            span,
                        ),
                        try self.colorTransformModernChannel(
                            values[a_index],
                            kind,
                            .oklab_axis,
                            span,
                        ),
                        try self.colorTransformModernChannel(
                            values[b_index],
                            kind,
                            .oklab_axis,
                            span,
                        ),
                    },
                    .alpha = alpha,
                },
            ),
            .oklch => native_color.transformModern(
                color,
                nativeColorTransformSpace(.oklch),
                kind,
                .{
                    .channels = .{
                        try self.colorTransformModernChannel(
                            values[lightness_index],
                            kind,
                            .oklab_lightness,
                            span,
                        ),
                        try self.colorTransformModernChannel(
                            values[chroma_index],
                            kind,
                            .oklch_chroma,
                            span,
                        ),
                        try self.colorTransformModernChannel(
                            values[hue_index],
                            kind,
                            .hue,
                            span,
                        ),
                    },
                    .alpha = alpha,
                },
            ),
            .srgb,
            .srgb_linear,
            .display_p3,
            .a98_rgb,
            .prophoto_rgb,
            .rec2020,
            => native_color.transformModern(
                color,
                nativeColorTransformSpace(effective_space),
                kind,
                .{
                    .channels = .{
                        try self.colorTransformModernChannel(
                            values[red_index],
                            kind,
                            .predefined,
                            span,
                        ),
                        try self.colorTransformModernChannel(
                            values[green_index],
                            kind,
                            .predefined,
                            span,
                        ),
                        try self.colorTransformModernChannel(
                            values[blue_index],
                            kind,
                            .predefined,
                            span,
                        ),
                    },
                    .alpha = alpha,
                },
            ),
            .xyz_d50, .xyz => native_color.transformModern(
                color,
                nativeColorTransformSpace(effective_space),
                kind,
                .{
                    .channels = .{
                        try self.colorTransformModernChannel(
                            values[x_index],
                            kind,
                            .predefined,
                            span,
                        ),
                        try self.colorTransformModernChannel(
                            values[y_index],
                            kind,
                            .predefined,
                            span,
                        ),
                        try self.colorTransformModernChannel(
                            values[z_index],
                            kind,
                            .predefined,
                            span,
                        ),
                    },
                    .alpha = alpha,
                },
            ),
        } catch |err| return self.colorTransformFailure(err, span);
        return self.values.own(.{ .color = result });
    }

    fn colorTransformSpace(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!ColorTransformSpace {
        const string = switch (item) {
            .string => |value| value,
            else => {
                try self.report(.type_mismatch, span, "native Sass color space must be an identifier");
                return error.InvalidExpression;
            },
        };
        if (string.quoted) {
            try self.report(.type_mismatch, span, "native Sass color space must be an unquoted identifier");
            return error.InvalidExpression;
        }
        if (std.mem.eql(u8, string.bytes, "rgb")) return .rgb;
        if (std.mem.eql(u8, string.bytes, "hsl")) return .hsl;
        if (std.mem.eql(u8, string.bytes, "hwb")) return .hwb;
        if (std.mem.eql(u8, string.bytes, "lab")) return .lab;
        if (std.mem.eql(u8, string.bytes, "lch")) return .lch;
        if (std.mem.eql(u8, string.bytes, "oklab")) return .oklab;
        if (std.mem.eql(u8, string.bytes, "oklch")) return .oklch;
        if (std.mem.eql(u8, string.bytes, "srgb")) return .srgb;
        if (std.mem.eql(u8, string.bytes, "srgb-linear")) return .srgb_linear;
        if (std.mem.eql(u8, string.bytes, "display-p3")) return .display_p3;
        if (std.mem.eql(u8, string.bytes, "a98-rgb")) return .a98_rgb;
        if (std.mem.eql(u8, string.bytes, "prophoto-rgb")) return .prophoto_rgb;
        if (std.mem.eql(u8, string.bytes, "rec2020")) return .rec2020;
        if (std.mem.eql(u8, string.bytes, "xyz-d50")) return .xyz_d50;
        if (std.mem.eql(u8, string.bytes, "xyz") or
            std.mem.eql(u8, string.bytes, "xyz-d65")) return .xyz;
        try self.report(.invalid_operation, span, "unknown native Sass color space");
        return error.InvalidExpression;
    }

    fn colorTransformRgbChannel(
        self: *Engine,
        item: native_value.Value,
        kind: native_color.TransformKind,
        span: native_source.Span,
    ) Error!f64 {
        return if (kind == .scale)
            self.colorScalePercentage(item, span)
        else
            self.rgbChannel(item, span);
    }

    fn colorTransformPercentage(
        self: *Engine,
        item: native_value.Value,
        kind: native_color.TransformKind,
        span: native_source.Span,
    ) Error!f64 {
        return if (kind == .scale)
            self.colorScalePercentage(item, span)
        else
            self.colorPercentage(item, span);
    }

    fn colorTransformModernChannel(
        self: *Engine,
        item: ?*const native_value.Value,
        kind: native_color.TransformKind,
        channel_kind: ModernColorChannelKind,
        span: native_source.Span,
    ) Error!?f64 {
        const present = item orelse return null;
        if (kind == .scale) return try self.colorScalePercentage(present.*, span);
        const channel = try self.modernColorChannel(present.*, channel_kind, span);
        if (channel.missing) {
            try self.report(
                .unsupported_feature,
                span,
                "native Sass transformed missing color channels are not implemented yet",
            );
            return error.UnsupportedFeature;
        }
        return channel.value;
    }

    fn colorTransformAlpha(
        self: *Engine,
        item: native_value.Value,
        kind: native_color.TransformKind,
        span: native_source.Span,
    ) Error!f64 {
        const value = switch (kind) {
            .adjust => try self.colorPercentage(item, span),
            .change => try self.colorAlpha(item, span),
            .scale => try self.colorScalePercentage(item, span),
        };
        if (kind == .change and (value < 0 or value > 1)) {
            try self.report(.invalid_operation, span, "changed color alpha must be between zero and one");
            return error.InvalidExpression;
        }
        return value;
    }

    fn colorScalePercentage(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!f64 {
        const number = try self.colorNumber(item, span);
        if (number.numerator_units.len != 1 or
            !std.mem.eql(u8, number.numerator_units[0], "%"))
        {
            try self.report(.type_mismatch, span, "scaled color channel requires a percentage");
            return error.InvalidExpression;
        }
        if (number.value < -100 or number.value > 100) {
            try self.report(.invalid_operation, span, "scaled color channel must be within -100% and 100%");
            return error.InvalidExpression;
        }
        return number.value;
    }

    fn colorTransformFailure(
        self: *Engine,
        failure: native_color.Error,
        span: native_source.Span,
    ) Error {
        if (failure != error.InvalidColor) return failure;
        self.report(.invalid_operation, span, "invalid native Sass color transformation") catch |err| {
            return err;
        };
        return error.InvalidExpression;
    }

    fn colorArgument(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!native_value.Color {
        return switch (item) {
            .color => |color| color,
            else => {
                try self.report(.type_mismatch, span, "legacy Sass color function requires a color");
                return error.InvalidExpression;
            },
        };
    }

    fn legacyColorAmount(
        self: *Engine,
        item: native_value.Value,
        minimum: f64,
        maximum: f64,
        span: native_source.Span,
    ) Error!f64 {
        const number = try self.colorNumber(item, span);
        if (number.value < minimum or number.value > maximum) {
            try self.report(.invalid_operation, span, "legacy Sass color amount is outside its range");
            return error.InvalidExpression;
        }
        return number.value;
    }

    fn alphaAdjustmentAmount(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!f64 {
        const number = try self.colorNumber(item, span);
        if (number.numerator_units.len != 0 or number.value < 0 or number.value > 1) {
            try self.report(.invalid_operation, span, "legacy Sass alpha amount must be unitless from zero to one");
            return error.InvalidExpression;
        }
        return number.value;
    }

    fn rgbChannel(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!f64 {
        const number = try self.colorNumber(item, span);
        if (number.numerator_units.len == 0) return number.value;
        if (number.numerator_units.len == 1 and
            std.mem.eql(u8, number.numerator_units[0], "%"))
        {
            return number.value * 255 / 100;
        }
        try self.report(.type_mismatch, span, "RGB channels require unitless numbers or percentages");
        return error.InvalidExpression;
    }

    fn colorAlpha(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!f64 {
        const number = try self.colorNumber(item, span);
        if (number.numerator_units.len == 0) return number.value;
        if (number.numerator_units.len == 1 and
            std.mem.eql(u8, number.numerator_units[0], "%"))
        {
            return number.value / 100;
        }
        try self.report(.type_mismatch, span, "color alpha requires a unitless number or percentage");
        return error.InvalidExpression;
    }

    fn colorPercentage(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!f64 {
        const number = try self.colorNumber(item, span);
        if (number.numerator_units.len == 0) return number.value;
        if (number.numerator_units.len == 1 and
            std.mem.eql(u8, number.numerator_units[0], "%"))
        {
            return number.value;
        }
        try self.report(.type_mismatch, span, "color channel requires a percentage");
        return error.InvalidExpression;
    }

    fn colorHue(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!f64 {
        const number = try self.colorNumber(item, span);
        if (number.numerator_units.len == 0) return number.value;
        if (number.numerator_units.len != 1) {
            try self.report(.type_mismatch, span, "color hue requires an angle");
            return error.InvalidExpression;
        }
        const unit = number.numerator_units[0];
        if (std.ascii.eqlIgnoreCase(unit, "deg")) return number.value;
        if (std.ascii.eqlIgnoreCase(unit, "grad")) return number.value * 0.9;
        if (std.ascii.eqlIgnoreCase(unit, "rad")) return number.value * 180 / std.math.pi;
        if (std.ascii.eqlIgnoreCase(unit, "turn")) return number.value * 360;
        try self.report(.type_mismatch, span, "color hue requires an angle");
        return error.InvalidExpression;
    }

    fn modernColorChannel(
        self: *Engine,
        item: native_value.Value,
        kind: ModernColorChannelKind,
        span: native_source.Span,
    ) Error!ModernColorChannel {
        if (item == .string and !item.string.quoted and
            std.mem.eql(u8, item.string.bytes, "none"))
        {
            return .{ .missing = true };
        }
        if (kind == .hue) return .{ .value = try self.colorHue(item, span) };
        if (kind == .alpha) return .{ .value = try self.colorAlpha(item, span) };

        const number = try self.colorNumber(item, span);
        const percentage = number.numerator_units.len == 1 and
            std.mem.eql(u8, number.numerator_units[0], "%");
        if (number.numerator_units.len != 0 and !percentage) {
            try self.report(
                .type_mismatch,
                span,
                "modern Sass color channels require unitless numbers or percentages",
            );
            return error.InvalidExpression;
        }
        return .{ .value = switch (kind) {
            .lab_lightness => number.value,
            .oklab_lightness => if (percentage) number.value / 100 else number.value,
            .lab_axis => if (percentage) number.value * 1.25 else number.value,
            .oklab_axis => if (percentage) number.value * 0.004 else number.value,
            .lch_chroma => if (percentage) number.value * 1.5 else number.value,
            .oklch_chroma => if (percentage) number.value * 0.004 else number.value,
            .predefined => if (percentage) number.value / 100 else number.value,
            .hue, .alpha => unreachable,
        } };
    }

    fn predefinedColorSpace(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!native_value.ColorSpace {
        const name = switch (item) {
            .string => |string| if (!string.quoted) string.bytes else {
                try self.report(.type_mismatch, span, "color() space must be an unquoted string");
                return error.InvalidExpression;
            },
            else => {
                try self.report(.type_mismatch, span, "color() space must be an unquoted string");
                return error.InvalidExpression;
            },
        };
        if (predefinedColorSpaceName(name)) |space| return space;
        try self.report(.invalid_operation, span, "unknown predefined color() space");
        return error.InvalidExpression;
    }

    fn colorNumber(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!native_value.Number {
        const number = switch (item) {
            .number => |value| value,
            else => {
                try self.report(.type_mismatch, span, "native Sass color channel requires a number");
                return error.InvalidExpression;
            },
        };
        if (number.denominator_units.len != 0 or number.numerator_units.len > 1) {
            try self.report(.type_mismatch, span, "native Sass color channel has compound units");
            return error.InvalidExpression;
        }
        return number;
    }

    fn preserveColorFunction(
        self: *Engine,
        raw: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const rendered = try self.renderBytes(raw, scope, span, true);
        defer self.allocator.free(rendered);
        return self.values.own(.{
            .string = .{ .bytes = minifyCalculationArgumentCommas(rendered) },
        });
    }

    fn preserveEvaluatedFunction(
        self: *Engine,
        raw: []const u8,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const opening = std.mem.indexOfScalar(u8, raw, '(') orelse {
            try self.report(.invalid_operation, span, "malformed deferred CSS function");
            return error.InvalidExpression;
        };
        const name = trimWhitespace(raw[0..opening]);
        if (name.len == 0) {
            try self.report(.invalid_operation, span, "malformed deferred CSS function");
            return error.InvalidExpression;
        }

        var rendered: std.ArrayList(u8) = .empty;
        defer rendered.deinit(self.allocator);
        try self.appendTemporary(&rendered, name);
        try self.appendTemporary(&rendered, "(");
        for (arguments, 0..) |argument, index| {
            if (index != 0) try self.appendTemporary(&rendered, ",");
            try self.appendValue(&rendered, argument.*, false);
        }
        try self.appendTemporary(&rendered, ")");
        return self.values.own(.{ .string = .{ .bytes = rendered.items } });
    }

    fn tryPlainCssFunctionCall(
        self: *Engine,
        raw: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const opening = findTopLevelByte(raw, '(') orelse return null;
        if (opening == 0 or !fullyWrapped(raw[opening..], '(', ')')) return null;

        const rendered_name = try self.renderBytes(raw[0..opening], scope, span, false);
        defer self.allocator.free(rendered_name);
        const name = (try self.decodeCssFunctionName(trimWhitespace(rendered_name))) orelse
            return null;
        defer self.allocator.free(name);

        const body = raw[opening + 1 .. raw.len - 1];
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        if (std.ascii.eqlIgnoreCase(name, "url")) {
            if (trimWhitespace(body).len != 0) {
                try ranges.append(self.allocator, .{ .start = 0, .end = body.len });
            }
        } else {
            _ = try splitTopLevelRanges(self.allocator, body, .comma, &ranges);
        }
        if (trimWhitespace(body).len == 0) ranges.clearRetainingCapacity();

        var empty_var_fallback = false;
        if (ranges.items.len > 0) {
            const final = ranges.items[ranges.items.len - 1];
            if (trimWhitespace(body[final.start..final.end]).len == 0) {
                empty_var_fallback = std.ascii.eqlIgnoreCase(name, "var") and
                    ranges.items.len > 1;
                ranges.items.len -= 1;
            }
        }

        var evaluated = try self.evaluateCallArguments(
            body,
            ranges.items,
            scope,
            span,
        );
        defer evaluated.deinit();
        if (evaluated.keywords.items.len != 0) {
            try self.report(
                .invalid_operation,
                span,
                "plain CSS functions do not accept Sass keyword arguments",
            );
            return error.InvalidExpression;
        }
        for (evaluated.positional.items) |argument| {
            try self.ensureCssValue(argument.*, span);
        }
        return self.preservePlainCssFunction(
            name,
            evaluated.positional.items,
            empty_var_fallback,
        );
    }

    fn decodeCssFunctionName(
        self: *Engine,
        raw: []const u8,
    ) Error!?[]u8 {
        if (raw.len == 0) return null;
        var decoded: std.ArrayList(u8) = .empty;
        errdefer decoded.deinit(self.allocator);
        var index: usize = 0;
        var ordinal: usize = 0;
        while (index < raw.len) : (ordinal += 1) {
            const escaped = raw[index] == '\\';
            const scalar = decodeCalculationIdentifierScalar(raw, index) orelse {
                decoded.deinit(self.allocator);
                return null;
            };
            if (!cssFunctionNameScalarAllowed(scalar.scalar, ordinal, escaped)) {
                decoded.deinit(self.allocator);
                return null;
            }
            if (escaped and !cssFunctionNameScalarAllowed(scalar.scalar, ordinal, false)) {
                try self.appendTemporary(&decoded, raw[index..scalar.end]);
            } else {
                var encoded: [4]u8 = undefined;
                const encoded_length = std.unicode.utf8Encode(scalar.scalar, &encoded) catch {
                    decoded.deinit(self.allocator);
                    return null;
                };
                try self.appendTemporary(&decoded, encoded[0..encoded_length]);
            }
            index = scalar.end;
        }
        return try decoded.toOwnedSlice(self.allocator);
    }

    fn preservePlainCssFunction(
        self: *Engine,
        name: []const u8,
        arguments: []const *const native_value.Value,
        empty_var_fallback: bool,
    ) Error!*const native_value.Value {
        var rendered: std.ArrayList(u8) = .empty;
        defer rendered.deinit(self.allocator);
        try self.appendTemporary(&rendered, name);
        try self.appendTemporary(&rendered, "(");
        for (arguments, 0..) |argument, index| {
            if (index != 0) try self.appendTemporary(&rendered, ", ");
            try self.appendValue(&rendered, argument.*, false);
        }
        if (empty_var_fallback) try self.appendTemporary(&rendered, ", ");
        try self.appendTemporary(&rendered, ")");
        return self.values.own(.{ .string = .{ .bytes = rendered.items } });
    }

    fn callCalculation(
        self: *Engine,
        builtin: Builtin,
        raw: []const u8,
        body: []const u8,
        ranges: []const ExpressionRange,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const valid_arity = switch (builtin) {
            .calculation => ranges.len == 1,
            .minimum, .maximum => ranges.len >= 1,
            .clamp => ranges.len == 3,
            else => unreachable,
        };
        if (!valid_arity) {
            try self.report(.invalid_operation, span, switch (builtin) {
                .calculation => "calc() requires exactly one argument",
                .minimum => "min() requires at least one argument",
                .maximum => "max() requires at least one argument",
                .clamp => "clamp() requires exactly three arguments",
                else => unreachable,
            });
            return error.InvalidExpression;
        }

        var arguments: std.ArrayList(*const native_value.Value) = .empty;
        defer arguments.deinit(self.allocator);
        var deferred = false;
        for (ranges) |range| {
            const argument_raw = trimWhitespace(body[range.start..range.end]);
            switch (try self.evaluateCalculationArgument(argument_raw, builtin, scope, span)) {
                .number => |number| try arguments.append(self.allocator, number),
                .deferred => |value| {
                    try arguments.append(self.allocator, value);
                    deferred = true;
                },
            }
        }
        if (builtin == .clamp) {
            var dimensionless: ?bool = null;
            for (arguments.items) |argument| {
                if (argument.* != .number) continue;
                const current = (try native_numeric.Numeric.fromNumber(argument.number)).isDimensionless();
                if (dimensionless) |expected| {
                    if (current != expected) {
                        try self.report(
                            .invalid_operation,
                            span,
                            "clamp() requires compatible dimensionality",
                        );
                        return error.InvalidExpression;
                    }
                } else {
                    dimensionless = current;
                }
            }
        }
        if (deferred) return self.preserveEvaluatedFunction(raw, arguments.items, span);

        if (builtin == .calculation) {
            return arguments.items[0];
        }

        var selected: usize = if (builtin == .clamp) 1 else 0;
        if (builtin == .clamp) {
            selected = try self.selectCalculationNumber(
                arguments.items,
                selected,
                2,
                .minimum,
                span,
            ) orelse return self.preserveEvaluatedFunction(raw, arguments.items, span);
            selected = try self.selectCalculationNumber(
                arguments.items,
                0,
                selected,
                .maximum,
                span,
            ) orelse return self.preserveEvaluatedFunction(raw, arguments.items, span);
        } else {
            for (arguments.items[1..], 1..) |_, index| {
                selected = try self.selectCalculationNumber(
                    arguments.items,
                    selected,
                    index,
                    builtin,
                    span,
                ) orelse return self.preserveEvaluatedFunction(raw, arguments.items, span);
            }
        }
        return arguments.items[selected];
    }

    fn evaluateCalculationArgument(
        self: *Engine,
        raw: []const u8,
        builtin: Builtin,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!CalculationArgument {
        const context: ArithmeticContext = if (builtin == .calculation or builtin == .clamp)
            .calculation
        else
            .sass;
        switch (try self.probeArithmetic(raw, scope, span, context)) {
            .numeric => |numeric| {
                if (!numeric.isCssNumber()) {
                    if (builtin == .calculation) {
                        const rendered = try self.renderBytes(raw, scope, span, true);
                        defer self.allocator.free(rendered);
                        return .{ .deferred = try self.values.own(.{
                            .string = .{ .bytes = rendered },
                        }) };
                    }
                    try self.report(
                        .invalid_operation,
                        span,
                        "native Sass calculation produced a non-CSS compound number",
                    );
                    return error.InvalidExpression;
                }
                var numerator: [native_numeric.max_unit_instances][]const u8 = undefined;
                var denominator: [native_numeric.max_unit_instances][]const u8 = undefined;
                const owned = try self.values.own(.{
                    .number = try numeric.toNumber(&numerator, &denominator),
                });
                return .{ .number = owned };
            },
            .incompatible => {
                const rendered = try self.renderBytes(raw, scope, span, true);
                defer self.allocator.free(rendered);
                return .{ .deferred = try self.values.own(.{
                    .string = .{ .bytes = rendered },
                }) };
            },
            .invalid => {
                const rendered = try self.renderBytes(raw, scope, span, true);
                defer self.allocator.free(rendered);
                if (containsDeferredCssCalculation(rendered)) {
                    return .{ .deferred = try self.values.own(.{
                        .string = .{ .bytes = rendered },
                    }) };
                }
                try self.report(.invalid_operation, span, "invalid native Sass calculation expression");
                return error.InvalidExpression;
            },
            .none => {},
        }

        const item = try self.evaluateExpressionBytes(raw, scope, span);
        return switch (item.*) {
            .number => .{ .number = item },
            .string, .selector => |string| if (!string.quoted and
                (containsDeferredCssCalculation(string.bytes) or builtin != .calculation))
                .{ .deferred = item }
            else blk: {
                try self.report(.type_mismatch, span, "native Sass calculation requires numbers");
                break :blk error.InvalidExpression;
            },
            else => blk: {
                try self.report(.type_mismatch, span, "native Sass calculation requires numbers");
                break :blk error.InvalidExpression;
            },
        };
    }

    fn selectCalculationNumber(
        self: *Engine,
        arguments: []const *const native_value.Value,
        left: usize,
        right: usize,
        builtin: Builtin,
        span: native_source.Span,
    ) Error!?usize {
        const ordering = native_numeric.compare(
            try native_numeric.Numeric.fromNumber(arguments[left].number),
            try native_numeric.Numeric.fromNumber(arguments[right].number),
        ) catch |err| switch (err) {
            error.IncompatibleUnits => return null,
            else => {
                try self.report(.invalid_operation, span, "invalid native Sass calculation comparison");
                return error.InvalidExpression;
            },
        };
        return switch (builtin) {
            .minimum => if (ordering == .greater) right else left,
            .maximum => if (ordering == .less) right else left,
            else => unreachable,
        };
    }

    fn callMapGet(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len < 2) {
            try self.report(.invalid_operation, span, "map-get() requires a map and at least one key");
            return error.InvalidExpression;
        }
        var map = nativeMapView(arguments[0].*) orelse {
            try self.report(.type_mismatch, span, "map-get() requires a map value");
            return error.InvalidExpression;
        };
        for (arguments[1..], 0..) |key, index| {
            const current = (try self.findMapValue(map, key.*)) orelse
                return self.values.own(.{ .null_value = {} });
            if (index + 1 == arguments.len - 1) return current;
            map = nativeMapView(current.*) orelse
                return self.values.own(.{ .null_value = {} });
        }
        unreachable;
    }

    fn callMapHasKey(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len < 2) {
            try self.report(.invalid_operation, span, "map-has-key() requires a map and at least one key");
            return error.InvalidExpression;
        }
        var map = nativeMapView(arguments[0].*) orelse {
            try self.report(.type_mismatch, span, "map-has-key() requires a map value");
            return error.InvalidExpression;
        };
        for (arguments[1..], 0..) |key, index| {
            const current = (try self.findMapValue(map, key.*)) orelse
                return self.values.own(.{ .boolean = false });
            if (index + 1 == arguments.len - 1) {
                return self.values.own(.{ .boolean = true });
            }
            map = nativeMapView(current.*) orelse
                return self.values.own(.{ .boolean = false });
        }
        unreachable;
    }

    fn findMapValue(
        self: *Engine,
        map: native_value.Map,
        key: native_value.Value,
    ) Error!?*const native_value.Value {
        for (map.entries, 0..) |entry, index| {
            try self.transaction.consumeOperations(1);
            if (sassValuesEqual(entry.key, key)) return &map.entries[index].value;
        }
        return null;
    }

    fn callMapQueryRaw(
        self: *Engine,
        builtin: Builtin,
        body: []const u8,
        ranges: []const ExpressionRange,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var parsed = native_arguments.parseAlloc(
            self.allocator,
            body,
            ranges,
            self.limits.max_function_arguments,
        ) catch |err| return self.argumentsFailure(err, span);
        defer parsed.deinit();

        var has_keyword = false;
        for (parsed.items) |argument| {
            if (argument.splat) return self.argumentsFailure(error.SplatUnsupported, span);
            if (argument.name != null) has_keyword = true;
        }
        if (!has_keyword) {
            var arguments: std.ArrayList(*const native_value.Value) = .empty;
            defer arguments.deinit(self.allocator);
            for (parsed.items) |argument| {
                try arguments.append(
                    self.allocator,
                    try self.evaluateExpressionBytes(
                        body[argument.value.start..argument.value.end],
                        scope,
                        span,
                    ),
                );
            }
            return switch (builtin) {
                .map_get => self.callMapGet(arguments.items, span),
                .map_has_key => self.callMapHasKey(arguments.items, span),
                else => unreachable,
            };
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "map" },
            .{ .name = "key" },
        };
        var bound = native_arguments.bindAlloc(
            self.allocator,
            parsed.items,
            &parameters,
            parameters.len,
        ) catch |err| return self.argumentsFailure(err, span);
        defer bound.deinit();

        var arguments: [parameters.len]*const native_value.Value = undefined;
        for (bound.values, 0..) |value_range, index| {
            const range = value_range.?;
            arguments[index] = try self.evaluateExpressionBytes(
                body[range.start..range.end],
                scope,
                span,
            );
        }
        return switch (builtin) {
            .map_get => self.callMapGet(&arguments, span),
            .map_has_key => self.callMapHasKey(&arguments, span),
            else => unreachable,
        };
    }

    fn callMapEntries(
        self: *Engine,
        builtin: Builtin,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 1) {
            try self.report(.invalid_operation, span, switch (builtin) {
                .map_keys => "map-keys() requires exactly one map",
                .map_values => "map-values() requires exactly one map",
                else => unreachable,
            });
            return error.InvalidExpression;
        }
        const map = nativeMapView(arguments[0].*) orelse {
            try self.report(.type_mismatch, span, switch (builtin) {
                .map_keys => "map-keys() requires a map value",
                .map_values => "map-values() requires a map value",
                else => unreachable,
            });
            return error.InvalidExpression;
        };
        var items: std.ArrayList(native_value.Value) = .empty;
        defer items.deinit(self.allocator);
        for (map.entries) |entry| {
            try self.transaction.consumeOperations(1);
            try items.append(self.allocator, switch (builtin) {
                .map_keys => entry.key,
                .map_values => entry.value,
                else => unreachable,
            });
        }
        return self.values.own(.{ .list = .{
            .items = items.items,
            .separator = .comma,
        } });
    }

    fn callMapMutationRaw(
        self: *Engine,
        builtin: Builtin,
        body: []const u8,
        ranges: []const ExpressionRange,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var parsed = native_arguments.parseAlloc(
            self.allocator,
            body,
            ranges,
            self.limits.max_function_arguments,
        ) catch |err| return self.argumentsFailure(err, span);
        defer parsed.deinit();

        var has_keyword = false;
        for (parsed.items) |argument| {
            if (argument.splat) return self.argumentsFailure(error.SplatUnsupported, span);
            if (argument.name != null) has_keyword = true;
        }

        if (!has_keyword) {
            var arguments: std.ArrayList(*const native_value.Value) = .empty;
            defer arguments.deinit(self.allocator);
            for (parsed.items) |argument| {
                try arguments.append(
                    self.allocator,
                    try self.evaluateExpressionBytes(
                        body[argument.value.start..argument.value.end],
                        scope,
                        span,
                    ),
                );
            }
            return self.callMapMutation(builtin, arguments.items, span);
        }

        const parameters: []const native_arguments.Parameter = switch (builtin) {
            .map_merge, .map_deep_merge => &.{
                .{ .name = "map1" },
                .{ .name = "map2" },
            },
            .map_remove => &.{.{ .name = "map" }},
            .map_set => &.{
                .{ .name = "map" },
                .{ .name = "key" },
                .{ .name = "value" },
            },
            .map_deep_remove => &.{
                .{ .name = "map" },
                .{ .name = "key" },
            },
            else => unreachable,
        };
        var bound = native_arguments.bindAlloc(
            self.allocator,
            parsed.items,
            parameters,
            parameters.len,
        ) catch |err| return self.argumentsFailure(err, span);
        defer bound.deinit();

        var evaluated: [3]*const native_value.Value = undefined;
        for (parsed.items, 0..) |argument, index| {
            evaluated[index] = try self.evaluateExpressionBytes(
                body[argument.value.start..argument.value.end],
                scope,
                span,
            );
        }

        var arguments: [3]*const native_value.Value = undefined;
        for (bound.values, 0..) |value_range, parameter_index| {
            const range = value_range.?;
            for (parsed.items, 0..) |argument, argument_index| {
                if (argument.value.start != range.start or argument.value.end != range.end) continue;
                arguments[parameter_index] = evaluated[argument_index];
                break;
            }
        }
        return self.callMapMutation(builtin, arguments[0..parameters.len], span);
    }

    fn callMapMutation(
        self: *Engine,
        builtin: Builtin,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        return switch (builtin) {
            .map_merge => self.callMapMerge(arguments, span),
            .map_remove => self.callMapRemove(arguments, span),
            .map_set => self.callMapSet(arguments, span),
            .map_deep_merge => self.callMapDeepMerge(arguments, span),
            .map_deep_remove => self.callMapDeepRemove(arguments, span),
            else => unreachable,
        };
    }

    fn callMapMerge(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len < 2) {
            try self.report(
                .invalid_operation,
                span,
                "map-merge() requires a map, zero or more keys, and a map",
            );
            return error.InvalidExpression;
        }
        const left = nativeMapView(arguments[0].*) orelse {
            try self.report(.type_mismatch, span, "map-merge() requires a map as its first value");
            return error.InvalidExpression;
        };
        const right = nativeMapView(arguments[arguments.len - 1].*) orelse {
            try self.report(.type_mismatch, span, "map-merge() requires a map as its final value");
            return error.InvalidExpression;
        };

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var mutation_scratch = MapMutationScratch{ .allocator = scratch.allocator() };
        const result = if (arguments.len == 2)
            try self.mergeMapsShallow(&mutation_scratch, left, right, span)
        else
            try self.mergeMapPath(
                &mutation_scratch,
                left,
                arguments[1 .. arguments.len - 1],
                right,
                0,
                span,
            );
        return self.values.own(result);
    }

    fn callMapRemove(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len == 0) {
            try self.report(.invalid_operation, span, "map-remove() requires a map");
            return error.InvalidExpression;
        }
        const map = nativeMapView(arguments[0].*) orelse {
            try self.report(.type_mismatch, span, "map-remove() requires a map value");
            return error.InvalidExpression;
        };

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var mutation_scratch = MapMutationScratch{ .allocator = scratch.allocator() };
        return self.values.own(try self.removeMapKeys(
            &mutation_scratch,
            map,
            arguments[1..],
            span,
        ));
    }

    fn callMapSet(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len < 3) {
            try self.report(
                .invalid_operation,
                span,
                "map.set() requires a map, one or more keys, and a value",
            );
            return error.InvalidExpression;
        }
        const map = nativeMapView(arguments[0].*) orelse {
            try self.report(.type_mismatch, span, "map.set() requires a map value");
            return error.InvalidExpression;
        };

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var mutation_scratch = MapMutationScratch{ .allocator = scratch.allocator() };
        return self.values.own(try self.setMapPath(
            &mutation_scratch,
            map,
            arguments[1 .. arguments.len - 1],
            arguments[arguments.len - 1].*,
            0,
            span,
        ));
    }

    fn callMapDeepMerge(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 2) {
            try self.report(.invalid_operation, span, "map.deep-merge() requires exactly two maps");
            return error.InvalidExpression;
        }
        const left = nativeMapView(arguments[0].*) orelse {
            try self.report(
                .type_mismatch,
                span,
                "map.deep-merge() requires a map as its first value",
            );
            return error.InvalidExpression;
        };
        const right = nativeMapView(arguments[1].*) orelse {
            try self.report(
                .type_mismatch,
                span,
                "map.deep-merge() requires a map as its second value",
            );
            return error.InvalidExpression;
        };

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var mutation_scratch = MapMutationScratch{ .allocator = scratch.allocator() };
        return self.values.own(try self.mergeMapsDeep(
            &mutation_scratch,
            left,
            right,
            0,
            span,
        ));
    }

    fn callMapDeepRemove(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len < 2) {
            try self.report(
                .invalid_operation,
                span,
                "map.deep-remove() requires a map and at least one key",
            );
            return error.InvalidExpression;
        }
        const map = nativeMapView(arguments[0].*) orelse {
            try self.report(.type_mismatch, span, "map.deep-remove() requires a map value");
            return error.InvalidExpression;
        };

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var mutation_scratch = MapMutationScratch{ .allocator = scratch.allocator() };
        return self.values.own(try self.deepRemoveMapPath(
            &mutation_scratch,
            map,
            arguments[1..],
            0,
            span,
        ));
    }

    fn mergeMapsShallow(
        self: *Engine,
        scratch: *MapMutationScratch,
        left: native_value.Map,
        right: native_value.Map,
        span: native_source.Span,
    ) Error!native_value.Value {
        var entries: std.ArrayList(native_value.Entry) = .empty;
        try self.reserveMapMutationEntries(
            scratch,
            &entries,
            std.math.add(usize, left.entries.len, right.entries.len) catch {
                try self.report(.resource_limit, span, "native Sass temporary limit exceeded");
                return error.TemporaryLimitExceeded;
            },
            span,
        );
        for (left.entries) |entry| {
            try self.transaction.consumeOperations(1);
            entries.appendAssumeCapacity(entry);
        }
        for (right.entries) |right_entry| {
            var replaced = false;
            for (entries.items) |*entry| {
                try self.transaction.consumeOperations(1);
                if (!sassValuesEqual(entry.key, right_entry.key)) continue;
                entry.value = right_entry.value;
                replaced = true;
                break;
            }
            if (!replaced) {
                try self.transaction.consumeOperations(1);
                entries.appendAssumeCapacity(right_entry);
            }
        }
        return .{ .map = .{ .entries = entries.items } };
    }

    fn setMapEntry(
        self: *Engine,
        scratch: *MapMutationScratch,
        map: native_value.Map,
        key: native_value.Value,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!native_value.Value {
        var entries: std.ArrayList(native_value.Entry) = .empty;
        try self.reserveMapMutationEntries(
            scratch,
            &entries,
            std.math.add(usize, map.entries.len, 1) catch {
                try self.report(.resource_limit, span, "native Sass temporary limit exceeded");
                return error.TemporaryLimitExceeded;
            },
            span,
        );
        var replaced = false;
        for (map.entries) |entry| {
            try self.transaction.consumeOperations(1);
            const next = if (!replaced and sassValuesEqual(entry.key, key)) blk: {
                replaced = true;
                break :blk native_value.Entry{ .key = entry.key, .value = value };
            } else entry;
            entries.appendAssumeCapacity(next);
        }
        if (!replaced) {
            try self.transaction.consumeOperations(1);
            entries.appendAssumeCapacity(.{ .key = key, .value = value });
        }
        return .{ .map = .{ .entries = entries.items } };
    }

    fn removeMapKeys(
        self: *Engine,
        scratch: *MapMutationScratch,
        map: native_value.Map,
        keys: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!native_value.Value {
        var entries: std.ArrayList(native_value.Entry) = .empty;
        try self.reserveMapMutationEntries(scratch, &entries, map.entries.len, span);
        for (map.entries) |entry| {
            var removed = false;
            for (keys) |key| {
                try self.transaction.consumeOperations(1);
                if (!sassValuesEqual(entry.key, key.*)) continue;
                removed = true;
                break;
            }
            if (!removed) {
                try self.transaction.consumeOperations(1);
                entries.appendAssumeCapacity(entry);
            }
        }
        return .{ .map = .{ .entries = entries.items } };
    }

    fn copyMap(
        self: *Engine,
        scratch: *MapMutationScratch,
        map: native_value.Map,
        span: native_source.Span,
    ) Error!native_value.Value {
        var entries: std.ArrayList(native_value.Entry) = .empty;
        try self.reserveMapMutationEntries(scratch, &entries, map.entries.len, span);
        for (map.entries) |entry| {
            try self.transaction.consumeOperations(1);
            entries.appendAssumeCapacity(entry);
        }
        return .{ .map = .{ .entries = entries.items } };
    }

    fn mergeMapPath(
        self: *Engine,
        scratch: *MapMutationScratch,
        map: native_value.Map,
        keys: []const *const native_value.Value,
        right: native_value.Map,
        depth: u16,
        span: native_source.Span,
    ) Error!native_value.Value {
        try self.checkMapMutationDepth(depth, span);
        std.debug.assert(keys.len > 0);
        const current = try self.findMapValue(map, keys[0].*);
        const child_map: native_value.Map = if (current) |value|
            nativeMapView(value.*) orelse .{ .entries = &.{} }
        else
            .{ .entries = &.{} };
        const replacement = if (keys.len == 1)
            try self.mergeMapsShallow(scratch, child_map, right, span)
        else
            try self.mergeMapPath(
                scratch,
                child_map,
                keys[1..],
                right,
                depth + 1,
                span,
            );
        return self.setMapEntry(scratch, map, keys[0].*, replacement, span);
    }

    fn setMapPath(
        self: *Engine,
        scratch: *MapMutationScratch,
        map: native_value.Map,
        keys: []const *const native_value.Value,
        value: native_value.Value,
        depth: u16,
        span: native_source.Span,
    ) Error!native_value.Value {
        try self.checkMapMutationDepth(depth, span);
        std.debug.assert(keys.len > 0);
        if (keys.len == 1) return self.setMapEntry(scratch, map, keys[0].*, value, span);

        const current = try self.findMapValue(map, keys[0].*);
        const child_map: native_value.Map = if (current) |child|
            nativeMapView(child.*) orelse .{ .entries = &.{} }
        else
            .{ .entries = &.{} };
        const replacement = try self.setMapPath(
            scratch,
            child_map,
            keys[1..],
            value,
            depth + 1,
            span,
        );
        return self.setMapEntry(scratch, map, keys[0].*, replacement, span);
    }

    fn mergeMapsDeep(
        self: *Engine,
        scratch: *MapMutationScratch,
        left: native_value.Map,
        right: native_value.Map,
        depth: u16,
        span: native_source.Span,
    ) Error!native_value.Value {
        try self.checkMapMutationDepth(depth, span);
        var entries: std.ArrayList(native_value.Entry) = .empty;
        try self.reserveMapMutationEntries(
            scratch,
            &entries,
            std.math.add(usize, left.entries.len, right.entries.len) catch {
                try self.report(.resource_limit, span, "native Sass temporary limit exceeded");
                return error.TemporaryLimitExceeded;
            },
            span,
        );
        for (left.entries) |entry| {
            try self.transaction.consumeOperations(1);
            entries.appendAssumeCapacity(entry);
        }
        for (right.entries) |right_entry| {
            var replaced = false;
            for (entries.items) |*entry| {
                try self.transaction.consumeOperations(1);
                if (!sassValuesEqual(entry.key, right_entry.key)) continue;
                const left_child = nativeMapView(entry.value);
                const right_child = nativeMapView(right_entry.value);
                entry.value = if (left_child != null and right_child != null)
                    try self.mergeMapsDeep(
                        scratch,
                        left_child.?,
                        right_child.?,
                        depth + 1,
                        span,
                    )
                else
                    right_entry.value;
                replaced = true;
                break;
            }
            if (!replaced) {
                try self.transaction.consumeOperations(1);
                entries.appendAssumeCapacity(right_entry);
            }
        }
        return .{ .map = .{ .entries = entries.items } };
    }

    fn deepRemoveMapPath(
        self: *Engine,
        scratch: *MapMutationScratch,
        map: native_value.Map,
        keys: []const *const native_value.Value,
        depth: u16,
        span: native_source.Span,
    ) Error!native_value.Value {
        try self.checkMapMutationDepth(depth, span);
        std.debug.assert(keys.len > 0);
        if (keys.len == 1) return self.removeMapKeys(scratch, map, keys, span);

        const current = (try self.findMapValue(map, keys[0].*)) orelse
            return self.copyMap(scratch, map, span);
        const child_map = nativeMapView(current.*) orelse
            return self.copyMap(scratch, map, span);
        const replacement = try self.deepRemoveMapPath(
            scratch,
            child_map,
            keys[1..],
            depth + 1,
            span,
        );
        return self.setMapEntry(scratch, map, keys[0].*, replacement, span);
    }

    fn reserveMapMutationEntries(
        self: *Engine,
        scratch: *MapMutationScratch,
        entries: *std.ArrayList(native_value.Entry),
        capacity: usize,
        span: native_source.Span,
    ) Error!void {
        const bytes = std.math.mul(usize, capacity, @sizeOf(native_value.Entry)) catch {
            try self.report(.resource_limit, span, "native Sass temporary limit exceeded");
            return error.TemporaryLimitExceeded;
        };
        const next = std.math.add(usize, scratch.reserved_bytes, bytes) catch {
            try self.report(.resource_limit, span, "native Sass temporary limit exceeded");
            return error.TemporaryLimitExceeded;
        };
        if (next > self.limits.max_temporary_bytes) {
            try self.report(.resource_limit, span, "native Sass temporary limit exceeded");
            return error.TemporaryLimitExceeded;
        }
        try entries.ensureTotalCapacityPrecise(scratch.allocator, capacity);
        scratch.reserved_bytes = next;
    }

    fn checkMapMutationDepth(
        self: *Engine,
        depth: u16,
        span: native_source.Span,
    ) Error!void {
        if (depth <= self.limits.max_evaluation_depth) return;
        try self.report(.resource_limit, span, "native Sass map mutation depth exceeded");
        return error.EvaluationDepthExceeded;
    }

    fn callNth(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 2) {
            try self.report(.invalid_operation, span, "nth() requires exactly two arguments");
            return error.InvalidExpression;
        }
        const length = sassListLength(arguments[0].*);
        const index = try self.resolveListIndex(arguments[1].*, length, span);
        return switch (arguments[0].*) {
            .list => |list| if (list.separator == .legacy_slash) blk: {
                if (!list.bracketed) break :blk arguments[0];
                break :blk try self.values.own(.{ .list = .{
                    .items = list.items,
                    .separator = .legacy_slash,
                } });
            } else &list.items[index],
            .argument_list => |argument_list| &argument_list.positional[index],
            .map => |map| blk: {
                const pair = [_]native_value.Value{
                    map.entries[index].key,
                    map.entries[index].value,
                };
                break :blk try self.values.own(.{ .list = .{
                    .items = &pair,
                    .separator = .space,
                } });
            },
            else => arguments[0],
        };
    }

    fn callLength(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 1) {
            try self.report(.invalid_operation, span, "length() requires exactly one argument");
            return error.InvalidExpression;
        }
        const length = sassListLength(arguments[0].*);
        return self.values.own(.{ .number = .{ .value = @floatFromInt(length) } });
    }

    fn callListIndex(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 2) {
            try self.report(.invalid_operation, span, "list index() requires exactly two arguments");
            return error.InvalidExpression;
        }
        const target = arguments[1].*;
        switch (arguments[0].*) {
            .list => |list| {
                if (list.separator == .legacy_slash) {
                    try self.transaction.consumeOperations(1);
                    const candidate = if (list.bracketed)
                        native_value.Value{ .list = .{
                            .items = list.items,
                            .separator = .legacy_slash,
                        } }
                    else
                        arguments[0].*;
                    return self.listIndexResult(sassValuesEqual(candidate, target), 0);
                }
                for (list.items, 0..) |item, index| {
                    try self.transaction.consumeOperations(1);
                    if (sassValuesEqual(item, target)) return self.listIndexResult(true, index);
                }
            },
            .argument_list => |argument_list| {
                for (argument_list.positional, 0..) |item, index| {
                    try self.transaction.consumeOperations(1);
                    if (sassValuesEqual(item, target)) return self.listIndexResult(true, index);
                }
            },
            .map => |map| {
                for (map.entries, 0..) |entry, index| {
                    try self.transaction.consumeOperations(1);
                    const pair = [_]native_value.Value{ entry.key, entry.value };
                    const item = native_value.Value{ .list = .{
                        .items = &pair,
                        .separator = .space,
                    } };
                    if (sassValuesEqual(item, target)) return self.listIndexResult(true, index);
                }
            },
            else => {
                try self.transaction.consumeOperations(1);
                if (sassValuesEqual(arguments[0].*, target)) return self.listIndexResult(true, 0);
            },
        }
        return self.listIndexResult(false, 0);
    }

    fn listIndexResult(
        self: *Engine,
        found: bool,
        index: usize,
    ) Error!*const native_value.Value {
        if (!found) return self.values.own(.{ .null_value = {} });
        return self.values.own(.{ .number = .{ .value = @floatFromInt(index + 1) } });
    }

    fn callListSeparator(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 1) {
            try self.report(.invalid_operation, span, "list separator() requires exactly one argument");
            return error.InvalidExpression;
        }
        const separator: []const u8 = switch (arguments[0].*) {
            .map => |map| if (map.entries.len == 0) "space" else "comma",
            .argument_list => "comma",
            .list => |list| switch (list.separator) {
                .comma => "comma",
                .slash => "slash",
                .space, .legacy_slash, .undecided => "space",
            },
            else => "space",
        };
        return self.values.own(.{ .string = .{ .bytes = separator } });
    }

    fn callListIsBracketed(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 1) {
            try self.report(.invalid_operation, span, "list is-bracketed() requires exactly one argument");
            return error.InvalidExpression;
        }
        return self.values.own(.{ .boolean = switch (arguments[0].*) {
            .list => |list| list.bracketed,
            else => false,
        } });
    }

    fn callListZipRaw(
        self: *Engine,
        body: []const u8,
        ranges: []const ExpressionRange,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var arguments = try self.evaluateCallArguments(body, ranges, scope, span);
        defer arguments.deinit();
        if (arguments.keywords.items.len != 0) {
            return self.argumentsFailure(error.UnknownArgument, span);
        }
        return self.callListZip(arguments.positional.items, span);
    }

    fn callListSlashRaw(
        self: *Engine,
        body: []const u8,
        ranges: []const ExpressionRange,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var arguments = try self.evaluateCallArguments(body, ranges, scope, span);
        defer arguments.deinit();
        if (arguments.positional.items.len < 2) {
            return self.callListSlash(arguments.positional.items, span);
        }
        if (arguments.keywords.items.len != 0) {
            return self.argumentsFailure(error.UnknownArgument, span);
        }
        return self.callListSlash(arguments.positional.items, span);
    }

    fn callListAppend(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len < 2 or arguments.len > 3) {
            try self.report(.invalid_operation, span, "list append() requires two or three arguments");
            return error.InvalidExpression;
        }
        const separator = try self.resolveListSeparator(
            canonicalAppendSeparator(sassListSeparator(arguments[0].*)),
            if (arguments.len == 3) arguments[2].* else null,
            span,
        );
        var list = try self.materializeList(arguments[0].*, 1, span);
        defer list.deinit(self.allocator);
        try self.transaction.consumeOperations(1);
        list.items[list.items.len - 1] = arguments[1].*;
        return self.values.own(.{ .list = .{
            .items = list.items,
            .separator = separator,
            .bracketed = list.bracketed,
        } });
    }

    fn callListSetNth(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 3) {
            try self.report(.invalid_operation, span, "list set-nth() requires exactly three arguments");
            return error.InvalidExpression;
        }
        const length = sassListLength(arguments[0].*);
        const index = try self.resolveListIndex(arguments[1].*, length, span);
        var list = try self.materializeList(arguments[0].*, 0, span);
        defer list.deinit(self.allocator);
        try self.transaction.consumeOperations(1);
        list.items[index] = arguments[2].*;
        return self.values.own(.{ .list = .{
            .items = list.items,
            .separator = list.separator,
            .bracketed = list.bracketed,
        } });
    }

    fn callListJoin(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len < 2 or arguments.len > 4) {
            try self.report(.invalid_operation, span, "list join() requires two to four arguments");
            return error.InvalidExpression;
        }
        const separator = try self.resolveListSeparator(
            sassJoinSeparator(arguments[0].*, arguments[1].*),
            if (arguments.len >= 3) arguments[2].* else null,
            span,
        );
        const bracketed = self.resolveListJoinBracketed(
            arguments[0].*,
            if (arguments.len == 4) arguments[3].* else null,
        );
        const sources = [_]native_value.Value{ arguments[0].*, arguments[1].* };
        var list = try self.materializeLists(&sources, 0, span);
        defer list.deinit(self.allocator);
        return self.values.own(.{ .list = .{
            .items = list.items,
            .separator = separator,
            .bracketed = bracketed,
        } });
    }

    fn callListZip(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len == 0) {
            return self.values.own(.{ .list = .{
                .items = &.{},
                .separator = .comma,
            } });
        }

        var row_count = sassListLength(arguments[0].*);
        for (arguments[1..]) |argument| {
            row_count = @min(row_count, sassListLength(argument.*));
        }
        if (row_count == 0) {
            return self.values.own(.{ .list = .{
                .items = &.{},
                .separator = .comma,
            } });
        }

        const row_item_count = std.math.mul(usize, row_count, arguments.len) catch
            return self.listTemporaryFailure(span);
        var pair_count: usize = 0;
        for (arguments) |argument| {
            if (argument.* != .map) continue;
            const source_pairs = std.math.mul(usize, row_count, 2) catch
                return self.listTemporaryFailure(span);
            pair_count = std.math.add(usize, pair_count, source_pairs) catch
                return self.listTemporaryFailure(span);
        }
        const primary_count = std.math.add(usize, row_count, row_item_count) catch
            return self.listTemporaryFailure(span);
        const temporary_count = std.math.add(usize, primary_count, pair_count) catch
            return self.listTemporaryFailure(span);
        const temporary_bytes = std.math.mul(
            usize,
            temporary_count,
            @sizeOf(native_value.Value),
        ) catch return self.listTemporaryFailure(span);
        if (temporary_bytes > self.limits.max_temporary_bytes) {
            return self.listTemporaryFailure(span);
        }

        const rows = try self.allocator.alloc(native_value.Value, row_count);
        errdefer self.allocator.free(rows);
        const row_items = try self.allocator.alloc(native_value.Value, row_item_count);
        errdefer self.allocator.free(row_items);
        const allocated_pair_items = if (pair_count > 0)
            try self.allocator.alloc(native_value.Value, pair_count)
        else
            null;
        errdefer if (allocated_pair_items) |items| self.allocator.free(items);
        var materialized = MaterializedZip{
            .rows = rows,
            .row_items = row_items,
            .pair_items = allocated_pair_items,
        };

        var pair_index: usize = 0;
        for (0..row_count) |row_index| {
            const row_start = row_index * arguments.len;
            for (arguments, 0..) |argument, argument_index| {
                try self.transaction.consumeOperations(1);
                materialized.row_items[row_start + argument_index] = switch (argument.*) {
                    .list => |list| if (list.separator == .legacy_slash)
                        .{ .list = .{
                            .items = list.items,
                            .separator = .legacy_slash,
                        } }
                    else
                        list.items[row_index],
                    .argument_list => |argument_list| argument_list.positional[row_index],
                    .map => |map| blk: {
                        const pair_items = materialized.pair_items.?;
                        const entry = map.entries[row_index];
                        pair_items[pair_index] = entry.key;
                        pair_items[pair_index + 1] = entry.value;
                        const pair = native_value.Value{ .list = .{
                            .items = pair_items[pair_index .. pair_index + 2],
                            .separator = .space,
                        } };
                        pair_index += 2;
                        break :blk pair;
                    },
                    else => argument.*,
                };
            }
            materialized.rows[row_index] = .{ .list = .{
                .items = materialized.row_items[row_start .. row_start + arguments.len],
                .separator = .space,
            } };
        }
        std.debug.assert(pair_index == pair_count);
        const result = try self.values.own(.{ .list = .{
            .items = materialized.rows,
            .separator = .comma,
        } });
        materialized.deinit(self.allocator);
        return result;
    }

    fn callListSlash(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len < 2) {
            try self.report(.invalid_operation, span, "list slash() requires at least two elements");
            return error.InvalidExpression;
        }
        const temporary_bytes = std.math.mul(
            usize,
            arguments.len,
            @sizeOf(native_value.Value),
        ) catch return self.listTemporaryFailure(span);
        if (temporary_bytes > self.limits.max_temporary_bytes) {
            return self.listTemporaryFailure(span);
        }

        const items = try self.allocator.alloc(native_value.Value, arguments.len);
        errdefer self.allocator.free(items);
        for (arguments, 0..) |argument, index| {
            try self.transaction.consumeOperations(1);
            items[index] = argument.*;
        }
        const result = try self.values.own(.{ .list = .{
            .items = items,
            .separator = .slash,
        } });
        self.allocator.free(items);
        return result;
    }

    fn resolveListSeparator(
        self: *Engine,
        automatic: native_value.Separator,
        requested: ?native_value.Value,
        span: native_source.Span,
    ) Error!native_value.Separator {
        const value = requested orelse return automatic;
        const string = switch (value) {
            .string => |item| item,
            else => {
                try self.report(.type_mismatch, span, "list separator must be auto, space, comma, or slash");
                return error.InvalidExpression;
            },
        };
        if (std.mem.eql(u8, string.bytes, "auto")) return automatic;
        if (std.mem.eql(u8, string.bytes, "space")) return .space;
        if (std.mem.eql(u8, string.bytes, "comma")) return .comma;
        if (std.mem.eql(u8, string.bytes, "slash")) return .slash;
        try self.report(.invalid_operation, span, "unknown list separator");
        return error.InvalidExpression;
    }

    fn resolveListJoinBracketed(
        _: *Engine,
        first: native_value.Value,
        requested: ?native_value.Value,
    ) bool {
        const automatic = switch (first) {
            .list => |list| list.bracketed,
            else => false,
        };
        const value = requested orelse return automatic;
        return switch (value) {
            .string => |string| if (std.mem.eql(u8, string.bytes, "auto"))
                automatic
            else
                true,
            else => sassTruthy(value),
        };
    }

    fn materializeList(
        self: *Engine,
        source: native_value.Value,
        extra_items: usize,
        span: native_source.Span,
    ) Error!MaterializedList {
        const sources = [_]native_value.Value{source};
        return self.materializeLists(&sources, extra_items, span);
    }

    fn materializeLists(
        self: *Engine,
        sources: []const native_value.Value,
        extra_items: usize,
        span: native_source.Span,
    ) Error!MaterializedList {
        std.debug.assert(sources.len > 0);
        var source_length: usize = 0;
        var pair_count: usize = 0;
        for (sources) |source| {
            source_length = std.math.add(usize, source_length, sassListLength(source)) catch
                return self.listTemporaryFailure(span);
            if (source == .map) {
                const source_pairs = std.math.mul(usize, source.map.entries.len, 2) catch
                    return self.listTemporaryFailure(span);
                pair_count = std.math.add(usize, pair_count, source_pairs) catch
                    return self.listTemporaryFailure(span);
            }
        }
        const item_count = std.math.add(usize, source_length, extra_items) catch
            return self.listTemporaryFailure(span);
        const item_bytes = std.math.mul(usize, item_count, @sizeOf(native_value.Value)) catch
            return self.listTemporaryFailure(span);
        const pair_bytes = std.math.mul(usize, pair_count, @sizeOf(native_value.Value)) catch
            return self.listTemporaryFailure(span);
        const temporary_bytes = std.math.add(usize, item_bytes, pair_bytes) catch
            return self.listTemporaryFailure(span);
        if (temporary_bytes > self.limits.max_temporary_bytes) {
            return self.listTemporaryFailure(span);
        }

        const items = try self.allocator.alloc(native_value.Value, item_count);
        errdefer self.allocator.free(items);
        const allocated_pair_items = if (pair_count > 0)
            try self.allocator.alloc(native_value.Value, pair_count)
        else
            null;
        errdefer if (allocated_pair_items) |owned| self.allocator.free(owned);
        var result = MaterializedList{
            .items = items,
            .pair_items = allocated_pair_items,
            .separator = sassListSeparator(sources[0]),
            .bracketed = switch (sources[0]) {
                .list => |list| list.bracketed,
                else => false,
            },
        };

        var output_index: usize = 0;
        var pair_index: usize = 0;
        for (sources) |source| {
            switch (source) {
                .list => |list| if (list.separator == .legacy_slash) {
                    try self.transaction.consumeOperations(1);
                    result.items[output_index] = .{ .list = .{
                        .items = list.items,
                        .separator = .legacy_slash,
                    } };
                    output_index += 1;
                } else {
                    for (list.items) |item| {
                        try self.transaction.consumeOperations(1);
                        result.items[output_index] = item;
                        output_index += 1;
                    }
                },
                .argument_list => |argument_list| for (argument_list.positional) |item| {
                    try self.transaction.consumeOperations(1);
                    result.items[output_index] = item;
                    output_index += 1;
                },
                .map => |map| if (map.entries.len > 0) {
                    const pair_items = result.pair_items.?;
                    for (map.entries) |entry| {
                        try self.transaction.consumeOperations(1);
                        pair_items[pair_index] = entry.key;
                        pair_items[pair_index + 1] = entry.value;
                        result.items[output_index] = .{ .list = .{
                            .items = pair_items[pair_index .. pair_index + 2],
                            .separator = .space,
                        } };
                        pair_index += 2;
                        output_index += 1;
                    }
                },
                else => {
                    try self.transaction.consumeOperations(1);
                    result.items[output_index] = source;
                    output_index += 1;
                },
            }
        }
        std.debug.assert(output_index == source_length);
        std.debug.assert(pair_index == pair_count);
        return result;
    }

    fn listTemporaryFailure(
        self: *Engine,
        span: native_source.Span,
    ) Error {
        self.report(.resource_limit, span, "native Sass list temporary limit exceeded") catch |err| return err;
        return error.TemporaryLimitExceeded;
    }

    fn callMetaCalcName(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const calculation = try self.metaCalculationValue(arguments, span);
        try self.transaction.consumeOperations(1);
        return self.values.own(.{ .string = .{
            .bytes = calculation.name,
            .quoted = true,
        } });
    }

    fn callMetaCalcArgs(
        self: *Engine,
        arguments: []const *const native_value.Value,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const calculation = try self.metaCalculationValue(arguments, span);
        const argument_count = calculationArgumentCount(calculation.body);
        if (argument_count == 0) {
            try self.report(.invalid_operation, span, "native Sass calculation has no arguments");
            return error.InvalidExpression;
        }
        if (argument_count > self.limits.max_function_arguments) {
            try self.report(.resource_limit, span, "native Sass function argument limit exceeded");
            return error.FunctionArgumentLimitExceeded;
        }
        const canonical_capacity = std.math.add(
            usize,
            calculation.body.len,
            argument_count - 1,
        ) catch return self.metaCalculationTemporaryFailure(span);
        const range_bytes = std.math.mul(
            usize,
            argument_count,
            @sizeOf(ExpressionRange),
        ) catch return self.metaCalculationTemporaryFailure(span);
        const value_bytes = std.math.mul(
            usize,
            argument_count,
            @sizeOf(native_value.Value),
        ) catch return self.metaCalculationTemporaryFailure(span);
        const metadata_bytes = std.math.add(usize, range_bytes, value_bytes) catch
            return self.metaCalculationTemporaryFailure(span);
        const temporary_bytes = std.math.add(usize, canonical_capacity, metadata_bytes) catch
            return self.metaCalculationTemporaryFailure(span);
        if (temporary_bytes > self.limits.max_temporary_bytes) {
            return self.metaCalculationTemporaryFailure(span);
        }

        var canonical_body: std.ArrayList(u8) = .empty;
        defer canonical_body.deinit(self.allocator);
        try canonical_body.ensureTotalCapacityPrecise(self.allocator, canonical_capacity);
        try self.appendCanonicalCalculationBody(&canonical_body, calculation.body);

        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        try ranges.ensureTotalCapacityPrecise(self.allocator, argument_count);
        _ = try splitTopLevelRanges(
            self.allocator,
            canonical_body.items,
            .comma,
            &ranges,
        );
        if (ranges.items.len != argument_count) {
            try self.report(.invalid_operation, span, "malformed native Sass calculation arguments");
            return error.InvalidExpression;
        }

        const items = try self.allocator.alloc(native_value.Value, argument_count);
        defer self.allocator.free(items);
        for (ranges.items, 0..) |range, index| {
            try self.transaction.consumeOperations(1);
            const raw = trimWhitespace(canonical_body.items[range.start..range.end]);
            if (raw.len == 0) {
                try self.report(.invalid_operation, span, "empty native Sass calculation argument");
                return error.InvalidExpression;
            }
            items[index] = if (sassCalculationValue(raw) != null)
                .{ .string = .{ .bytes = raw } }
            else switch (try self.probeArithmetic(raw, scope, span, .sass)) {
                .numeric => (try self.evaluateExpressionBytes(raw, scope, span)).*,
                .none, .incompatible, .invalid => .{ .string = .{ .bytes = raw } },
            };
        }
        return self.values.own(.{ .list = .{
            .items = items,
            .separator = .comma,
        } });
    }

    fn metaCalculationValue(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!SassCalculationValue {
        if (arguments.len != 1) {
            try self.report(
                .invalid_operation,
                span,
                "meta calculation introspection requires exactly one argument",
            );
            return error.InvalidExpression;
        }
        const string = switch (arguments[0].*) {
            .string => |value| if (!value.quoted) value else return self.metaCalculationTypeFailure(span),
            else => return self.metaCalculationTypeFailure(span),
        };
        if (string.bytes.len > self.limits.max_temporary_bytes) {
            return self.metaCalculationTemporaryFailure(span);
        }
        const operation_count = std.math.cast(u64, string.bytes.len) orelse
            std.math.maxInt(u64);
        try self.transaction.consumeOperations(operation_count);
        return sassCalculationValue(string.bytes) orelse
            return self.metaCalculationTypeFailure(span);
    }

    fn metaCalculationTypeFailure(
        self: *Engine,
        span: native_source.Span,
    ) Error {
        self.report(
            .type_mismatch,
            span,
            "meta calculation introspection requires a calculation",
        ) catch |err| return err;
        return error.InvalidExpression;
    }

    fn metaCalculationTemporaryFailure(
        self: *Engine,
        span: native_source.Span,
    ) Error {
        self.report(
            .resource_limit,
            span,
            "native Sass meta calculation temporary limit exceeded",
        ) catch |err| return err;
        return error.TemporaryLimitExceeded;
    }

    fn callMetaContentExists(
        self: *Engine,
        module_owned: bool,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (!module_owned) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        try self.transaction.consumeOperations(1);
        if (!self.active_mixin_body) {
            try self.report(
                .invalid_operation,
                span,
                "content-exists() may only be called within a mixin.",
            );
            return error.InvalidExpression;
        }
        return self.values.own(.{ .boolean = self.active_content != null });
    }

    fn callMetaAcceptsContent(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 1) {
            try self.report(
                .invalid_operation,
                span,
                "meta.accepts-content() requires exactly one argument",
            );
            return error.InvalidExpression;
        }
        try self.transaction.consumeOperations(1);
        const callable = switch (arguments[0].*) {
            .callable => |value| value,
            else => return self.metaAcceptsContentTypeFailure(span),
        };
        const accepts_content = switch (callable.kind) {
            .mixin => if (callable.id < self.user_mixins.items.len)
                self.user_mixins.items[callable.id].accepts_content
            else
                return self.metaAcceptsContentTypeFailure(span),
            .builtin_mixin => switch (std.meta.intToEnum(BuiltinMixin, callable.id) catch
                return self.metaAcceptsContentTypeFailure(span)) {
                .meta_load_css => false,
                .meta_apply => true,
            },
            .builtin_function, .user_function => return self.metaAcceptsContentTypeFailure(span),
        };
        return self.values.own(.{ .boolean = accepts_content });
    }

    fn metaAcceptsContentTypeFailure(
        self: *Engine,
        span: native_source.Span,
    ) Error {
        self.report(
            .type_mismatch,
            span,
            "meta.accepts-content() requires a mixin reference",
        ) catch |err| return err;
        return error.InvalidExpression;
    }

    fn callMetaGetMixin(
        self: *Engine,
        module_owned: bool,
        arguments: []const *const native_value.Value,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (!module_owned) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        try self.transaction.consumeOperations(1);

        const name_string = try self.metaExistenceString(arguments[0].*, "name", span);
        const raw_name = native_string.decodeAlloc(
            self.allocator,
            name_string.bytes,
            name_string.quoted,
            self.limits.max_temporary_bytes,
        ) catch |err| return self.stringFailure(err, span);
        defer self.allocator.free(raw_name);
        const normalized = (try self.normalizeMetaExistenceName(raw_name, span)) orelse {
            try self.report(.invalid_operation, span, "native Sass mixin reference was not found");
            return error.InvalidExpression;
        };
        defer self.allocator.free(normalized);

        const callable: native_value.Callable = if (arguments.len == 2) blk: {
            const module = try self.metaExistenceModule(arguments[1].*, span) orelse {
                const mixin_id = try self.lookupUserMixin(normalized, scope) orelse {
                    try self.report(
                        .invalid_operation,
                        span,
                        "native Sass mixin reference was not found",
                    );
                    return error.InvalidExpression;
                };
                break :blk .{ .kind = .mixin, .id = mixin_id };
            };
            const builtin = moduleBuiltinMixin(module, normalized) orelse {
                try self.report(
                    .invalid_operation,
                    span,
                    "native Sass mixin reference was not found",
                );
                return error.InvalidExpression;
            };
            break :blk .{
                .kind = .builtin_mixin,
                .id = @intFromEnum(builtin),
            };
        } else blk: {
            const mixin_id = try self.lookupUserMixin(normalized, scope) orelse {
                try self.report(
                    .invalid_operation,
                    span,
                    "native Sass mixin reference was not found",
                );
                return error.InvalidExpression;
            };
            break :blk .{ .kind = .mixin, .id = mixin_id };
        };
        return self.values.own(.{ .callable = callable });
    }

    fn callMetaGetFunction(
        self: *Engine,
        module_owned: bool,
        arguments: []const *const native_value.Value,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (!module_owned) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        try self.transaction.consumeOperations(1);

        const name_string = try self.metaExistenceString(arguments[0].*, "name", span);
        const raw_name = native_string.decodeAlloc(
            self.allocator,
            name_string.bytes,
            name_string.quoted,
            self.limits.max_temporary_bytes,
        ) catch |err| return self.stringFailure(err, span);
        defer self.allocator.free(raw_name);
        const normalized = (try self.normalizeMetaExistenceName(raw_name, span)) orelse {
            try self.report(.invalid_operation, span, "native Sass function reference was not found");
            return error.InvalidExpression;
        };
        defer self.allocator.free(normalized);

        if (arguments.len >= 2 and sassTruthy(arguments[1].*)) {
            try self.report(
                .invalid_operation,
                span,
                "native Sass CSS function references are not yet available",
            );
            return error.InvalidExpression;
        }
        const module = if (arguments.len == 3)
            try self.metaExistenceModule(arguments[2].*, span)
        else
            null;
        const callable = if (module) |kind| blk: {
            const builtin = moduleCallableBuiltin(kind, normalized) orelse {
                try self.report(
                    .invalid_operation,
                    span,
                    "native Sass function reference was not found",
                );
                return error.InvalidExpression;
            };
            break :blk builtinFunctionCallable(builtin, kind);
        } else (try self.metaGlobalFunctionReference(normalized, scope)) orelse {
            try self.report(
                .invalid_operation,
                span,
                "native Sass function reference was not found",
            );
            return error.InvalidExpression;
        };
        return self.values.own(.{ .callable = callable });
    }

    fn callMetaCallRaw(
        self: *Engine,
        module_owned: bool,
        body: []const u8,
        ranges: []const ExpressionRange,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var evaluated = try self.evaluateCallArguments(body, ranges, scope, span);
        defer evaluated.deinit();

        var function_name = [_]u8{ 'f', 'u', 'n', 'c', 't', 'i', 'o', 'n' };
        var arguments_name = [_]u8{ 'a', 'r', 'g', 's' };
        const parameters = [_]CallableParameter{
            .{
                .name = function_name[0..],
                .default_value = null,
            },
            .{
                .name = arguments_name[0..],
                .default_value = null,
                .rest = true,
            },
        };
        var bound = try self.bindCallableArguments(&parameters, &evaluated, span);
        defer bound.deinit();

        if (!module_owned) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        try self.transaction.consumeOperations(1);

        const callable = switch (bound.values[0].?.*) {
            .callable => |value| value,
            else => return self.metaCallFunctionFailure(span),
        };

        var forwarded = EvaluatedCallArguments{ .allocator = self.allocator };
        defer forwarded.deinit();
        const positional_start: usize = if (evaluated.positional.items.len > 0) 1 else 0;
        for (evaluated.positional.items[positional_start..]) |item| {
            try self.appendEvaluatedPositional(&forwarded, item, span);
        }
        for (evaluated.keywords.items) |keyword| {
            if (positional_start == 0) {
                const is_function = if (keyword.normalize_name)
                    native_arguments.nameEql(keyword.name, parameters[0].name)
                else
                    std.mem.eql(u8, keyword.name, parameters[0].name);
                if (is_function) continue;
            }
            try self.appendEvaluatedKeyword(&forwarded, .{
                .name = keyword.name,
                .value = keyword.value,
                .normalize_name = keyword.normalize_name,
            }, span);
        }
        return switch (callable.kind) {
            .user_function => if (callable.id < self.user_functions.items.len)
                self.invokeUserFunction(callable.id, &forwarded, span)
            else
                self.metaCallFunctionFailure(span),
            .builtin_function => blk: {
                if (try self.invokeListFunction(callable, &forwarded, span)) |value| {
                    break :blk value;
                }
                if (try self.invokeMapQueryFunction(callable, &forwarded, span)) |value| {
                    break :blk value;
                }
                if (try self.invokeMapMutationFunction(callable, &forwarded, span)) |value| {
                    break :blk value;
                }
                if (try self.invokeMetaInspectionFunction(callable, &forwarded, span)) |value| {
                    break :blk value;
                }
                if (try self.invokeMetaKeywordsFunction(callable, &forwarded, span)) |value| {
                    break :blk value;
                }
                if (try self.invokeMetaContentAcceptanceFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeMetaCalculationFunction(
                    callable,
                    &forwarded,
                    scope,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeMetaExistenceFunction(
                    callable,
                    &forwarded,
                    scope,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeMathUnaryFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeMathUnitFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeMathTrigonometricFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeMathLogFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeMathPowFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeMathSqrtFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeMathDivFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeMathClampFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeMathHypotFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeMathMinFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeMathMaxFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeMathRandomFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeStringFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorTransformFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorRgbFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorHslFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorHwbFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorLabFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorLchFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorOklabFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorOklchFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorRedFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorGreenFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorBlueFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorAlphaFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorOpacityFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorHueFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorSaturationFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorLightnessFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorWhitenessFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorBlacknessFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorMixFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorLightenFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorDarkenFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorSaturateFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorDesaturateFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorAdjustHueFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorComplementFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorGrayscaleFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorInvertFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeColorLegacyAlphaFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeSelectorParseFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeSelectorSimpleSelectorsFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeSelectorIsSuperselectorFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeSelectorUnifyFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeSelectorAppendFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeSelectorNestFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeSelectorExtendFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                if (try self.invokeSelectorReplaceFunction(
                    callable,
                    &forwarded,
                    span,
                )) |value| {
                    break :blk value;
                }
                break :blk self.metaCallFunctionFailure(span);
            },
            .builtin_mixin, .mixin => self.metaCallFunctionFailure(span),
        };
    }

    fn invokeListFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner != null and reference.owner.? != .list) return null;
        switch (reference.builtin) {
            .nth,
            .length,
            .list_index,
            .list_separator,
            .list_is_bracketed,
            .list_append,
            .list_set_nth,
            .list_join,
            .list_zip,
            .list_slash,
            => {},
            else => return null,
        }
        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }

        return switch (reference.builtin) {
            .list_zip => blk: {
                if (arguments.keywords.items.len != 0) {
                    return self.argumentsFailure(error.UnknownArgument, span);
                }
                break :blk try self.callListZip(arguments.positional.items, span);
            },
            .list_slash => blk: {
                if (arguments.positional.items.len < 2) {
                    break :blk try self.callListSlash(arguments.positional.items, span);
                }
                if (arguments.keywords.items.len != 0) {
                    return self.argumentsFailure(error.UnknownArgument, span);
                }
                break :blk try self.callListSlash(arguments.positional.items, span);
            },
            else => try self.invokeFixedListFunction(
                reference.builtin,
                arguments,
                span,
            ),
        };
    }

    fn invokeFixedListFunction(
        self: *Engine,
        builtin: Builtin,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const parameters = fixedListBuiltinParameters(builtin) orelse unreachable;
        var bound = try self.bindEvaluatedArguments(
            parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const automatic = native_value.Value{ .string = .{ .bytes = "auto" } };
        var ordered: [4]*const native_value.Value = undefined;
        if (builtin == .list_join) {
            ordered[2] = &automatic;
            ordered[3] = &automatic;
        }
        var count: usize = 0;
        for (bound.values, 0..) |value, index| {
            const item = value orelse continue;
            ordered[index] = item;
            count = index + 1;
        }
        const values = ordered[0..count];
        return switch (builtin) {
            .nth => self.callNth(values, span),
            .length => self.callLength(values, span),
            .list_index => self.callListIndex(values, span),
            .list_separator => self.callListSeparator(values, span),
            .list_is_bracketed => self.callListIsBracketed(values, span),
            .list_append => self.callListAppend(values, span),
            .list_set_nth => self.callListSetNth(values, span),
            .list_join => self.callListJoin(values, span),
            else => unreachable,
        };
    }

    fn invokeMapQueryFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner != null and reference.owner.? != .map) return null;
        switch (reference.builtin) {
            .map_get,
            .map_has_key,
            .map_keys,
            .map_values,
            => {},
            else => return null,
        }
        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }

        return switch (reference.builtin) {
            .map_get, .map_has_key => self.invokeMapLookupFunction(
                reference.builtin,
                arguments,
                span,
            ),
            .map_keys, .map_values => self.invokeMapEntriesFunction(
                reference.builtin,
                arguments,
                span,
            ),
            else => unreachable,
        };
    }

    fn invokeMapLookupFunction(
        self: *Engine,
        builtin: Builtin,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.keywords.items.len == 0) {
            return switch (builtin) {
                .map_get => self.callMapGet(arguments.positional.items, span),
                .map_has_key => self.callMapHasKey(arguments.positional.items, span),
                else => unreachable,
            };
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "map" },
            .{ .name = "key" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const ordered = [_]*const native_value.Value{
            bound.values[0].?,
            bound.values[1].?,
        };
        return switch (builtin) {
            .map_get => self.callMapGet(&ordered, span),
            .map_has_key => self.callMapHasKey(&ordered, span),
            else => unreachable,
        };
    }

    fn invokeMapEntriesFunction(
        self: *Engine,
        builtin: Builtin,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const parameters = [_]native_arguments.Parameter{.{ .name = "map" }};
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const ordered = [_]*const native_value.Value{bound.values[0].?};
        return self.callMapEntries(builtin, &ordered, span);
    }

    fn invokeMapMutationFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner != null and reference.owner.? != .map) return null;
        switch (reference.builtin) {
            .map_merge,
            .map_remove,
            .map_set,
            .map_deep_merge,
            .map_deep_remove,
            => {},
            else => return null,
        }
        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }

        if (arguments.keywords.items.len == 0) {
            return try self.callMapMutation(
                reference.builtin,
                arguments.positional.items,
                span,
            );
        }
        return try self.invokeKeywordMapMutationFunction(
            reference.builtin,
            arguments,
            span,
        );
    }

    fn invokeKeywordMapMutationFunction(
        self: *Engine,
        builtin: Builtin,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const parameters: []const native_arguments.Parameter = switch (builtin) {
            .map_merge, .map_deep_merge => &.{
                .{ .name = "map1" },
                .{ .name = "map2" },
            },
            .map_remove => &.{
                .{ .name = "map" },
                .{ .name = "key", .required = false },
            },
            .map_set => &.{
                .{ .name = "map" },
                .{ .name = "key" },
                .{ .name = "value" },
            },
            .map_deep_remove => &.{
                .{ .name = "map" },
                .{ .name = "key" },
            },
            else => unreachable,
        };
        var bound = try self.bindEvaluatedArguments(
            parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        var ordered: [3]*const native_value.Value = undefined;
        var count: usize = 0;
        for (bound.values, 0..) |value, index| {
            const item = value orelse continue;
            ordered[index] = item;
            count = index + 1;
        }
        return self.callMapMutation(builtin, ordered[0..count], span);
    }

    fn invokeMetaInspectionFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner != null and reference.owner.? != .meta) return null;
        switch (reference.builtin) {
            .meta_inspect, .meta_type_of => {},
            else => return null,
        }
        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }

        const parameters = [_]native_arguments.Parameter{.{ .name = "value" }};
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const ordered = [_]*const native_value.Value{bound.values[0].?};
        return switch (reference.builtin) {
            .meta_inspect => try self.callMetaInspect(&ordered, span),
            .meta_type_of => try self.callMetaTypeOf(&ordered, span),
            else => unreachable,
        };
    }

    fn invokeMetaKeywordsFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner != null and reference.owner.? != .meta) return null;
        if (reference.builtin != .meta_keywords) return null;
        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }

        const parameters = [_]native_arguments.Parameter{.{ .name = "args" }};
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const ordered = [_]*const native_value.Value{bound.values[0].?};
        return try self.callMetaKeywords(&ordered, span);
    }

    fn invokeMetaContentAcceptanceFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner == null or reference.owner.? != .meta) return null;
        if (reference.builtin != .meta_accepts_content) return null;

        const parameters = [_]native_arguments.Parameter{.{ .name = "mixin" }};
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const ordered = [_]*const native_value.Value{bound.values[0].?};
        return try self.callMetaAcceptsContent(&ordered, span);
    }

    fn invokeMetaCalculationFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner == null or reference.owner.? != .meta) return null;
        switch (reference.builtin) {
            .meta_calc_args, .meta_calc_name => {},
            else => return null,
        }

        const parameters = [_]native_arguments.Parameter{.{ .name = "calc" }};
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const ordered = [_]*const native_value.Value{bound.values[0].?};
        return switch (reference.builtin) {
            .meta_calc_args => try self.callMetaCalcArgs(&ordered, scope, span),
            .meta_calc_name => try self.callMetaCalcName(&ordered, span),
            else => unreachable,
        };
    }

    fn invokeMetaExistenceFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner != null and reference.owner.? != .meta) return null;
        const parameters: []const native_arguments.Parameter = switch (reference.builtin) {
            .meta_feature_exists => &.{.{ .name = "feature" }},
            .meta_function_exists,
            .meta_global_variable_exists,
            .meta_mixin_exists,
            => &.{
                .{ .name = "name" },
                .{ .name = "module", .required = false },
            },
            .meta_variable_exists => &.{.{ .name = "name" }},
            else => return null,
        };

        var bound = try self.bindEvaluatedArguments(
            parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        var ordered: [2]*const native_value.Value = undefined;
        var count: usize = 0;
        for (bound.values, 0..) |value, index| {
            ordered[index] = value orelse continue;
            count = index + 1;
        }
        return try self.callMetaExistence(
            reference.builtin,
            reference.owner != null,
            ordered[0..count],
            scope,
            span,
        );
    }

    fn invokeMathUnaryFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner != null and reference.owner.? != .math) return null;
        switch (reference.builtin) {
            .math_abs,
            .math_ceil,
            .math_floor,
            .math_percentage,
            .math_round,
            => {},
            else => return null,
        }
        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }

        const parameters = [_]native_arguments.Parameter{.{ .name = "number" }};
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const ordered = [_]*const native_value.Value{bound.values[0].?};
        return try self.callMathUnary(reference.builtin, &ordered, span);
    }

    fn invokeMathUnitFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner != null and reference.owner.? != .math) return null;
        const parameters: []const native_arguments.Parameter = switch (reference.builtin) {
            .math_compatible => &.{
                .{ .name = "number1" },
                .{ .name = "number2" },
            },
            .math_is_unitless, .math_unit => &.{.{ .name = "number" }},
            else => return null,
        };
        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }

        var bound = try self.bindEvaluatedArguments(
            parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        var ordered: [2]*const native_value.Value = undefined;
        var count: usize = 0;
        for (bound.values, 0..) |value, index| {
            ordered[index] = value orelse continue;
            count = index + 1;
        }
        return switch (reference.builtin) {
            .math_compatible, .math_is_unitless => try self.callMathUnitPredicate(
                reference.builtin,
                ordered[0..count],
                span,
            ),
            .math_unit => try self.callMathUnit(ordered[0..count], span),
            else => unreachable,
        };
    }

    fn invokeMathTrigonometricFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner == null or reference.owner.? != .math) return null;
        switch (reference.builtin) {
            .math_acos, .math_asin, .math_atan, .math_atan2, .math_sin, .math_cos, .math_tan => {},
            else => return null,
        }

        const parameters: []const native_arguments.Parameter = switch (reference.builtin) {
            .math_atan2 => &.{
                .{ .name = "y" },
                .{ .name = "x" },
            },
            else => &.{.{ .name = "number" }},
        };
        var bound = try self.bindEvaluatedArguments(
            parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        var ordered: [2]*const native_value.Value = undefined;
        var count: usize = 0;
        for (bound.values, 0..) |value, index| {
            ordered[index] = value orelse continue;
            count = index + 1;
        }
        return try self.callMathTrigonometric(
            reference.builtin,
            ordered[0..count],
            span,
        );
    }

    fn invokeMathLogFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner == null or reference.owner.? != .math or
            reference.builtin != .math_log)
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "number" },
            .{ .name = "base", .required = false },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        var ordered: [2]*const native_value.Value = undefined;
        var count: usize = 0;
        for (bound.values, 0..) |value, index| {
            ordered[index] = value orelse continue;
            count = index + 1;
        }
        return try self.callMathPower(.math_log, ordered[0..count], span);
    }

    fn invokeMathPowFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner == null or reference.owner.? != .math or
            reference.builtin != .math_pow)
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "base" },
            .{ .name = "exponent" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const ordered = [_]*const native_value.Value{
            bound.values[0].?,
            bound.values[1].?,
        };
        return try self.callMathPower(.math_pow, &ordered, span);
    }

    fn invokeMathSqrtFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner == null or reference.owner.? != .math or
            reference.builtin != .math_sqrt)
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "number" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const ordered = [_]*const native_value.Value{
            bound.values[0].?,
        };
        return try self.callMathPower(.math_sqrt, &ordered, span);
    }

    fn invokeMathDivFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner == null or reference.owner.? != .math or
            reference.builtin != .math_div)
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "number1" },
            .{ .name = "number2" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const ordered = [_]*const native_value.Value{
            bound.values[0].?,
            bound.values[1].?,
        };
        return try self.callMathDiv(&ordered, span);
    }

    fn invokeMathClampFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner == null or reference.owner.? != .math or
            reference.builtin != .math_clamp)
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "min" },
            .{ .name = "number" },
            .{ .name = "max" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const ordered = [_]*const native_value.Value{
            bound.values[0].?,
            bound.values[1].?,
            bound.values[2].?,
        };
        return try self.callMathClamp(&ordered, span);
    }

    fn invokeMathHypotFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner == null or reference.owner.? != .math or
            reference.builtin != .math_hypot)
        {
            return null;
        }
        if (arguments.keywords.items.len != 0) {
            return self.argumentsFailure(error.UnknownArgument, span);
        }
        return try self.callMathHypot(arguments.positional.items, span);
    }

    fn invokeMathMinFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        const is_module = reference.owner != null and
            reference.owner.? == .math and
            reference.builtin == .math_min;
        const is_global = reference.owner == null and reference.builtin == .minimum;
        if (!is_module and !is_global) return null;
        if (is_global) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        if (arguments.keywords.items.len != 0) {
            return self.argumentsFailure(error.UnknownArgument, span);
        }
        return try self.callMathExtremum(.math_min, arguments.positional.items, span);
    }

    fn invokeMathMaxFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        const is_module = reference.owner != null and
            reference.owner.? == .math and
            reference.builtin == .math_max;
        const is_global = reference.owner == null and reference.builtin == .maximum;
        if (!is_module and !is_global) return null;
        if (is_global) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        if (arguments.keywords.items.len != 0) {
            return self.argumentsFailure(error.UnknownArgument, span);
        }
        return try self.callMathExtremum(.math_max, arguments.positional.items, span);
    }

    fn invokeMathRandomFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .math_random or
            (reference.owner != null and reference.owner.? != .math))
        {
            return null;
        }
        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "limit", .required = false },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        return try self.callMathRandom(bound.values[0], span);
    }

    fn invokeStringFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if ((reference.builtin != .quote and
            reference.builtin != .unquote and
            reference.builtin != .str_length and
            reference.builtin != .str_index and
            reference.builtin != .str_slice and
            reference.builtin != .str_insert and
            reference.builtin != .to_upper_case and
            reference.builtin != .to_lower_case) or
            (reference.owner != null and reference.owner.? != .string))
        {
            return null;
        }
        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }

        return switch (reference.builtin) {
            .str_index => blk: {
                const parameters = [_]native_arguments.Parameter{
                    .{ .name = "string" },
                    .{ .name = "substring" },
                };
                var bound = try self.bindEvaluatedArguments(
                    &parameters,
                    parameters.len,
                    arguments,
                    span,
                );
                defer bound.deinit();

                const ordered = [_]*const native_value.Value{
                    bound.values[0].?,
                    bound.values[1].?,
                };
                break :blk try self.callStringBuiltin(reference.builtin, &ordered, span);
            },
            .str_slice => blk: {
                const parameters = [_]native_arguments.Parameter{
                    .{ .name = "string" },
                    .{ .name = "start-at" },
                    .{ .name = "end-at", .required = false },
                };
                var bound = try self.bindEvaluatedArguments(
                    &parameters,
                    parameters.len,
                    arguments,
                    span,
                );
                defer bound.deinit();

                if (bound.values[2]) |end| {
                    const ordered = [_]*const native_value.Value{
                        bound.values[0].?,
                        bound.values[1].?,
                        end,
                    };
                    break :blk try self.callStringBuiltin(reference.builtin, &ordered, span);
                }
                const ordered = [_]*const native_value.Value{
                    bound.values[0].?,
                    bound.values[1].?,
                };
                break :blk try self.callStringBuiltin(reference.builtin, &ordered, span);
            },
            .str_insert => blk: {
                const parameters = [_]native_arguments.Parameter{
                    .{ .name = "string" },
                    .{ .name = "insert" },
                    .{ .name = "index" },
                };
                var bound = try self.bindEvaluatedArguments(
                    &parameters,
                    parameters.len,
                    arguments,
                    span,
                );
                defer bound.deinit();

                const ordered = [_]*const native_value.Value{
                    bound.values[0].?,
                    bound.values[1].?,
                    bound.values[2].?,
                };
                break :blk try self.callStringBuiltin(reference.builtin, &ordered, span);
            },
            else => blk: {
                const parameters = [_]native_arguments.Parameter{
                    .{ .name = "string" },
                };
                var bound = try self.bindEvaluatedArguments(
                    &parameters,
                    parameters.len,
                    arguments,
                    span,
                );
                defer bound.deinit();

                const ordered = [_]*const native_value.Value{
                    bound.values[0].?,
                };
                break :blk try self.callStringBuiltin(reference.builtin, &ordered, span);
            },
        };
    }

    fn invokeColorTransformFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        const builtin: Builtin = switch (reference.builtin) {
            .adjust_color, .change_color, .scale_color => reference.builtin,
            else => return null,
        };
        if (reference.owner != null and reference.owner.? != .color) return null;
        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }

        var bound = try self.bindEvaluatedArguments(
            &color_transform_parameters,
            1,
            arguments,
            span,
        );
        defer bound.deinit();
        return try self.callColorTransform(builtin, bound.values, span);
    }

    fn invokeColorRgbFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner != null or
            (reference.builtin != .rgb and reference.builtin != .rgba))
        {
            return null;
        }

        var has_channels = false;
        var has_color = false;
        var has_alpha = false;
        var has_rgb_channel = false;
        for (arguments.keywords.items) |keyword| {
            has_channels = has_channels or evaluatedKeywordNameEql(keyword, "channels");
            has_color = has_color or evaluatedKeywordNameEql(keyword, "color");
            has_alpha = has_alpha or evaluatedKeywordNameEql(keyword, "alpha");
            has_rgb_channel = has_rgb_channel or
                evaluatedKeywordNameEql(keyword, "red") or
                evaluatedKeywordNameEql(keyword, "green") or
                evaluatedKeywordNameEql(keyword, "blue");
        }

        const channels_parameters = [_]native_arguments.Parameter{
            .{ .name = "channels" },
        };
        const color_parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
            .{ .name = "alpha" },
        };
        const rgb_parameters = [_]native_arguments.Parameter{
            .{ .name = "red" },
            .{ .name = "green" },
            .{ .name = "blue" },
            .{ .name = "alpha", .required = false },
        };
        const positional_count = arguments.positional.items.len;
        const channels_overload = has_channels or
            (positional_count == 1 and arguments.keywords.items.len == 0);
        const color_overload = !channels_overload and
            (has_color or
                (positional_count == 2 and arguments.keywords.items.len == 0) or
                (positional_count == 1 and has_alpha and !has_rgb_channel));
        const parameters: []const native_arguments.Parameter = if (channels_overload)
            &channels_parameters
        else if (color_overload)
            &color_parameters
        else
            &rgb_parameters;
        var bound = try self.bindEvaluatedArguments(
            parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        if (channels_overload) {
            return try self.callRgbChannelsValue(bound.values[0].?.*, span);
        }
        if (color_overload) {
            return try self.callRgbColorAlpha(
                bound.values[0].?.*,
                bound.values[1].?.*,
                span,
            );
        }
        return try self.callRgbValues(
            bound.values[0].?.*,
            bound.values[1].?.*,
            bound.values[2].?.*,
            if (bound.values[3]) |alpha| alpha.* else null,
            span,
        );
    }

    fn callRgbChannelsValue(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const outer = switch (value) {
            .list => |list| list,
            else => return self.invalidRgbChannels(span),
        };
        if (outer.bracketed) return self.invalidRgbChannels(span);

        var channels = outer;
        var alpha: ?native_value.Value = null;
        if (outer.separator == .slash or outer.separator == .legacy_slash) {
            if (outer.items.len != 2) return self.invalidRgbChannels(span);
            channels = switch (outer.items[0]) {
                .list => |list| list,
                else => return self.invalidRgbChannels(span),
            };
            alpha = outer.items[1];
        }
        if (channels.bracketed or channels.separator != .space or channels.items.len != 3) {
            return self.invalidRgbChannels(span);
        }
        return try self.callRgbValues(
            channels.items[0],
            channels.items[1],
            channels.items[2],
            alpha,
            span,
        );
    }

    fn callRgbColorAlpha(
        self: *Engine,
        color_value: native_value.Value,
        alpha_value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var color = switch (color_value) {
            .color => |value| value,
            else => {
                try self.report(.type_mismatch, span, "rgb() color overload requires a color");
                return error.InvalidExpression;
            },
        };
        switch (color.space) {
            .rgb, .hsl, .hwb => {},
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "rgb() color overload requires a legacy RGB, HSL, or HWB color",
                );
                return error.InvalidExpression;
            },
        }
        color.channels[3] = std.math.clamp(try self.colorAlpha(alpha_value, span), 0, 1);
        return self.values.own(.{ .color = color });
    }

    fn callRgbValues(
        self: *Engine,
        red_value: native_value.Value,
        green_value: native_value.Value,
        blue_value: native_value.Value,
        alpha_value: ?native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const color = native_color.rgb(
            try self.rgbChannel(red_value, span),
            try self.rgbChannel(green_value, span),
            try self.rgbChannel(blue_value, span),
            if (alpha_value) |alpha| try self.colorAlpha(alpha, span) else 1,
        ) catch |err| return self.colorTransformFailure(err, span);
        return self.values.own(.{ .color = color });
    }

    fn invokeColorHslFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner != null or
            (reference.builtin != .hsl and reference.builtin != .hsla))
        {
            return null;
        }

        var has_channels = false;
        for (arguments.keywords.items) |keyword| {
            has_channels = has_channels or evaluatedKeywordNameEql(keyword, "channels");
        }

        const channels_parameters = [_]native_arguments.Parameter{
            .{ .name = "channels" },
        };
        const hsl_parameters = [_]native_arguments.Parameter{
            .{ .name = "hue" },
            .{ .name = "saturation" },
            .{ .name = "lightness" },
            .{ .name = "alpha", .required = false },
        };
        const channels_overload = has_channels or
            (arguments.positional.items.len == 1 and arguments.keywords.items.len == 0);
        const parameters: []const native_arguments.Parameter = if (channels_overload)
            &channels_parameters
        else
            &hsl_parameters;
        var bound = try self.bindEvaluatedArguments(
            parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        if (channels_overload) {
            return try self.callHslChannelsValue(bound.values[0].?.*, span);
        }
        return try self.callHslValues(
            bound.values[0].?.*,
            bound.values[1].?.*,
            bound.values[2].?.*,
            if (bound.values[3]) |alpha| alpha.* else null,
            span,
        );
    }

    fn callHslChannelsValue(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const outer = switch (value) {
            .list => |list| list,
            else => return self.invalidHslChannels(span),
        };
        if (outer.bracketed) return self.invalidHslChannels(span);

        var channels = outer;
        var alpha: ?native_value.Value = null;
        if (outer.separator == .slash or outer.separator == .legacy_slash) {
            if (outer.items.len != 2) return self.invalidHslChannels(span);
            channels = switch (outer.items[0]) {
                .list => |list| list,
                else => return self.invalidHslChannels(span),
            };
            alpha = outer.items[1];
        }
        if (channels.bracketed or channels.separator != .space) {
            return self.invalidHslChannels(span);
        }
        if (channels.items.len == 2 and channels.items[1] == .string and
            !channels.items[1].string.quoted)
        {
            const percentages = parseColorPercentagePair(channels.items[1].string.bytes) orelse
                return self.invalidHslChannels(span);
            const color = native_color.hsl(
                try self.colorHue(channels.items[0], span),
                percentages[0],
                percentages[1],
                if (alpha) |alpha_channel| try self.colorAlpha(alpha_channel, span) else 1,
            ) catch |err| return self.colorTransformFailure(err, span);
            return self.values.own(.{ .color = color });
        }
        if (channels.items.len != 3) return self.invalidHslChannels(span);
        return try self.callHslValues(
            channels.items[0],
            channels.items[1],
            channels.items[2],
            alpha,
            span,
        );
    }

    fn callHslValues(
        self: *Engine,
        hue_value: native_value.Value,
        saturation_value: native_value.Value,
        lightness_value: native_value.Value,
        alpha_value: ?native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const color = native_color.hsl(
            try self.colorHue(hue_value, span),
            try self.requiredColorPercentage(saturation_value, span),
            try self.requiredColorPercentage(lightness_value, span),
            if (alpha_value) |alpha| try self.colorAlpha(alpha, span) else 1,
        ) catch |err| return self.colorTransformFailure(err, span);
        return self.values.own(.{ .color = color });
    }

    fn requiredColorPercentage(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!f64 {
        const number = try self.colorNumber(item, span);
        if (number.numerator_units.len == 1 and
            std.mem.eql(u8, number.numerator_units[0], "%"))
        {
            return number.value;
        }
        try self.report(.type_mismatch, span, "HSL saturation and lightness require percentages");
        return error.InvalidExpression;
    }

    fn invokeColorHwbFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .hwb or
            (reference.owner != null and reference.owner.? != .color))
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "channels" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        return try self.callHwbChannelsValue(bound.values[0].?.*, span);
    }

    fn callHwbChannelsValue(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const outer = switch (value) {
            .list => |list| list,
            else => return self.invalidHwbChannels(span),
        };
        if (outer.bracketed) return self.invalidHwbChannels(span);

        var channels = outer;
        var alpha: ?native_value.Value = null;
        if (outer.separator == .slash or outer.separator == .legacy_slash) {
            if (outer.items.len != 2) return self.invalidHwbChannels(span);
            channels = switch (outer.items[0]) {
                .list => |list| list,
                else => return self.invalidHwbChannels(span),
            };
            alpha = outer.items[1];
        }
        if (channels.bracketed or channels.separator != .space) {
            return self.invalidHwbChannels(span);
        }
        if (channels.items.len == 2 and channels.items[1] == .string and
            !channels.items[1].string.quoted)
        {
            const percentages = parseColorPercentagePair(channels.items[1].string.bytes) orelse
                return self.invalidHwbChannels(span);
            const color = native_color.hwb(
                try self.colorHue(channels.items[0], span),
                percentages[0],
                percentages[1],
                if (alpha) |alpha_channel| try self.colorAlpha(alpha_channel, span) else 1,
            ) catch |err| return self.colorTransformFailure(err, span);
            return self.values.own(.{ .color = color });
        }
        if (channels.items.len != 3) return self.invalidHwbChannels(span);
        const color = native_color.hwb(
            try self.colorHue(channels.items[0], span),
            try self.requiredHwbPercentage(channels.items[1], span),
            try self.requiredHwbPercentage(channels.items[2], span),
            if (alpha) |alpha_channel| try self.colorAlpha(alpha_channel, span) else 1,
        ) catch |err| return self.colorTransformFailure(err, span);
        return self.values.own(.{ .color = color });
    }

    fn requiredHwbPercentage(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!f64 {
        const number = try self.colorNumber(item, span);
        if (number.numerator_units.len == 1 and
            std.mem.eql(u8, number.numerator_units[0], "%"))
        {
            return number.value;
        }
        try self.report(.type_mismatch, span, "HWB whiteness and blackness require percentages");
        return error.InvalidExpression;
    }

    fn invalidHwbChannels(
        self: *Engine,
        span: native_source.Span,
    ) Error {
        self.report(
            .type_mismatch,
            span,
            "hwb() channels require an unbracketed three-item space list and optional slash alpha",
        ) catch |err| return err;
        return error.InvalidExpression;
    }

    fn invokeColorLabFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner != null or reference.builtin != .lab) return null;

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "channels" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        return try self.callLabChannelsValue(bound.values[0].?.*, span);
    }

    fn callLabChannelsValue(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var channels = value;
        var alpha: ?native_value.Value = null;
        if (value == .list) {
            const outer = value.list;
            if (outer.bracketed) return self.invalidLabChannels(span);
            if (outer.separator == .slash or outer.separator == .legacy_slash) {
                if (outer.items.len != 2) return self.invalidLabChannels(span);
                channels = outer.items[0];
                alpha = outer.items[1];
            }
        }

        var color_channels = [4]f64{ 0, 0, 0, 1 };
        var missing_mask: u4 = 0;
        try self.populateLabChannels(
            channels,
            &color_channels,
            &missing_mask,
            span,
        );
        if (alpha) |alpha_value| {
            const channel = try self.modernColorChannel(alpha_value, .alpha, span);
            color_channels[3] = channel.value;
            if (channel.missing) missing_mask |= 0b1000;
        }
        const color = native_color.modern(
            .lab,
            color_channels,
            missing_mask,
        ) catch |err| return self.colorTransformFailure(err, span);
        return self.values.own(.{ .color = color });
    }

    fn populateLabChannels(
        self: *Engine,
        value: native_value.Value,
        output: *[4]f64,
        missing_mask: *u4,
        span: native_source.Span,
    ) Error!void {
        const kinds = [_]ModernColorChannelKind{
            .lab_lightness,
            .lab_axis,
            .lab_axis,
        };
        const missing_bits = [_]u4{ 0b0001, 0b0010, 0b0100 };
        switch (value) {
            .string => |string| {
                if (string.quoted) return self.invalidLabChannels(span);
                var parsed: [3]ModernColorChannel = undefined;
                if (!parseStaticModernColorChannels(string.bytes, &kinds, &parsed)) {
                    return self.invalidLabChannels(span);
                }
                for (parsed, 0..) |channel, index| {
                    output[index] = channel.value;
                    if (channel.missing) missing_mask.* |= missing_bits[index];
                }
            },
            .list => |list| {
                if (list.bracketed or list.separator != .space) {
                    return self.invalidLabChannels(span);
                }
                if (list.items.len == 2 and list.items[0] == .string and
                    !list.items[0].string.quoted)
                {
                    const leading_kinds = [_]ModernColorChannelKind{
                        .lab_lightness,
                        .lab_axis,
                    };
                    var leading: [2]ModernColorChannel = undefined;
                    if (!parseStaticModernColorChannels(
                        list.items[0].string.bytes,
                        &leading_kinds,
                        &leading,
                    )) return self.invalidLabChannels(span);
                    const trailing = try self.modernColorChannel(
                        list.items[1],
                        .lab_axis,
                        span,
                    );
                    for (leading, 0..) |channel, index| {
                        output[index] = channel.value;
                        if (channel.missing) missing_mask.* |= missing_bits[index];
                    }
                    output[2] = trailing.value;
                    if (trailing.missing) missing_mask.* |= missing_bits[2];
                    return;
                }
                if (list.items.len == 2 and list.items[1] == .string and
                    !list.items[1].string.quoted)
                {
                    const lightness = try self.modernColorChannel(
                        list.items[0],
                        .lab_lightness,
                        span,
                    );
                    const axes_kinds = [_]ModernColorChannelKind{ .lab_axis, .lab_axis };
                    var axes: [2]ModernColorChannel = undefined;
                    if (!parseStaticModernColorChannels(
                        list.items[1].string.bytes,
                        &axes_kinds,
                        &axes,
                    )) return self.invalidLabChannels(span);
                    output[0] = lightness.value;
                    if (lightness.missing) missing_mask.* |= missing_bits[0];
                    for (axes, 1..) |channel, index| {
                        output[index] = channel.value;
                        if (channel.missing) missing_mask.* |= missing_bits[index];
                    }
                    return;
                }
                if (list.items.len != 3) return self.invalidLabChannels(span);
                for (list.items, kinds, 0..) |item, kind, index| {
                    const channel = try self.modernColorChannel(item, kind, span);
                    output[index] = channel.value;
                    if (channel.missing) missing_mask.* |= missing_bits[index];
                }
            },
            else => return self.invalidLabChannels(span),
        }
    }

    fn invalidLabChannels(
        self: *Engine,
        span: native_source.Span,
    ) Error {
        self.report(
            .type_mismatch,
            span,
            "lab() channels require an unbracketed three-item space list and optional slash alpha",
        ) catch |err| return err;
        return error.InvalidExpression;
    }

    fn invokeColorLchFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner != null or reference.builtin != .lch) return null;

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "channels" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        return try self.callLchChannelsValue(bound.values[0].?.*, span);
    }

    fn callLchChannelsValue(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var channels = value;
        var alpha: ?native_value.Value = null;
        if (value == .list) {
            const outer = value.list;
            if (outer.bracketed) return self.invalidLchChannels(span);
            if (outer.separator == .slash or outer.separator == .legacy_slash) {
                if (outer.items.len != 2) return self.invalidLchChannels(span);
                channels = outer.items[0];
                alpha = outer.items[1];
            }
        }

        var color_channels = [4]f64{ 0, 0, 0, 1 };
        var missing_mask: u4 = 0;
        try self.populateLchChannels(
            channels,
            &color_channels,
            &missing_mask,
            span,
        );
        if (alpha) |alpha_value| {
            const channel = try self.modernColorChannel(alpha_value, .alpha, span);
            color_channels[3] = channel.value;
            if (channel.missing) missing_mask |= 0b1000;
        }
        const color = native_color.modern(
            .lch,
            color_channels,
            missing_mask,
        ) catch |err| return self.colorTransformFailure(err, span);
        return self.values.own(.{ .color = color });
    }

    fn populateLchChannels(
        self: *Engine,
        value: native_value.Value,
        output: *[4]f64,
        missing_mask: *u4,
        span: native_source.Span,
    ) Error!void {
        const kinds = [_]ModernColorChannelKind{
            .lab_lightness,
            .lch_chroma,
            .hue,
        };
        const missing_bits = [_]u4{ 0b0001, 0b0010, 0b0100 };
        switch (value) {
            .string => |string| {
                if (string.quoted) return self.invalidLchChannels(span);
                var parsed: [3]ModernColorChannel = undefined;
                if (!parseStaticModernColorChannels(string.bytes, &kinds, &parsed)) {
                    return self.invalidLchChannels(span);
                }
                for (parsed, 0..) |channel, index| {
                    output[index] = channel.value;
                    if (channel.missing) missing_mask.* |= missing_bits[index];
                }
            },
            .list => |list| {
                if (list.bracketed or list.separator != .space) {
                    return self.invalidLchChannels(span);
                }
                if (list.items.len == 2 and list.items[0] == .string and
                    !list.items[0].string.quoted)
                {
                    const leading_kinds = [_]ModernColorChannelKind{
                        .lab_lightness,
                        .lch_chroma,
                    };
                    var leading: [2]ModernColorChannel = undefined;
                    if (!parseStaticModernColorChannels(
                        list.items[0].string.bytes,
                        &leading_kinds,
                        &leading,
                    )) return self.invalidLchChannels(span);
                    const trailing = try self.modernColorChannel(
                        list.items[1],
                        .hue,
                        span,
                    );
                    for (leading, 0..) |channel, index| {
                        output[index] = channel.value;
                        if (channel.missing) missing_mask.* |= missing_bits[index];
                    }
                    output[2] = trailing.value;
                    if (trailing.missing) missing_mask.* |= missing_bits[2];
                    return;
                }
                if (list.items.len == 2 and list.items[1] == .string and
                    !list.items[1].string.quoted)
                {
                    const lightness = try self.modernColorChannel(
                        list.items[0],
                        .lab_lightness,
                        span,
                    );
                    const trailing_kinds = [_]ModernColorChannelKind{
                        .lch_chroma,
                        .hue,
                    };
                    var trailing: [2]ModernColorChannel = undefined;
                    if (!parseStaticModernColorChannels(
                        list.items[1].string.bytes,
                        &trailing_kinds,
                        &trailing,
                    )) return self.invalidLchChannels(span);
                    output[0] = lightness.value;
                    if (lightness.missing) missing_mask.* |= missing_bits[0];
                    for (trailing, 1..) |channel, index| {
                        output[index] = channel.value;
                        if (channel.missing) missing_mask.* |= missing_bits[index];
                    }
                    return;
                }
                if (list.items.len != 3) return self.invalidLchChannels(span);
                for (list.items, kinds, 0..) |item, kind, index| {
                    const channel = try self.modernColorChannel(item, kind, span);
                    output[index] = channel.value;
                    if (channel.missing) missing_mask.* |= missing_bits[index];
                }
            },
            else => return self.invalidLchChannels(span),
        }
    }

    fn invalidLchChannels(
        self: *Engine,
        span: native_source.Span,
    ) Error {
        self.report(
            .type_mismatch,
            span,
            "lch() channels require an unbracketed three-item space list and optional slash alpha",
        ) catch |err| return err;
        return error.InvalidExpression;
    }

    fn invokeColorOklabFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner != null or reference.builtin != .oklab) return null;

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "channels" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        return try self.callOklabChannelsValue(bound.values[0].?.*, span);
    }

    fn callOklabChannelsValue(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var channels = value;
        var alpha: ?native_value.Value = null;
        if (value == .list) {
            const outer = value.list;
            if (outer.bracketed) return self.invalidOklabChannels(span);
            if (outer.separator == .slash or outer.separator == .legacy_slash) {
                if (outer.items.len != 2) return self.invalidOklabChannels(span);
                channels = outer.items[0];
                alpha = outer.items[1];
            }
        }

        var color_channels = [4]f64{ 0, 0, 0, 1 };
        var missing_mask: u4 = 0;
        try self.populateOklabChannels(
            channels,
            &color_channels,
            &missing_mask,
            span,
        );
        if (alpha) |alpha_value| {
            const channel = try self.modernColorChannel(alpha_value, .alpha, span);
            color_channels[3] = channel.value;
            if (channel.missing) missing_mask |= 0b1000;
        }
        const color = native_color.modern(
            .oklab,
            color_channels,
            missing_mask,
        ) catch |err| return self.colorTransformFailure(err, span);
        return self.values.own(.{ .color = color });
    }

    fn populateOklabChannels(
        self: *Engine,
        value: native_value.Value,
        output: *[4]f64,
        missing_mask: *u4,
        span: native_source.Span,
    ) Error!void {
        const kinds = [_]ModernColorChannelKind{
            .oklab_lightness,
            .oklab_axis,
            .oklab_axis,
        };
        const missing_bits = [_]u4{ 0b0001, 0b0010, 0b0100 };
        switch (value) {
            .string => |string| {
                if (string.quoted) return self.invalidOklabChannels(span);
                var parsed: [3]ModernColorChannel = undefined;
                if (!parseStaticModernColorChannels(string.bytes, &kinds, &parsed)) {
                    return self.invalidOklabChannels(span);
                }
                for (parsed, 0..) |channel, index| {
                    output[index] = channel.value;
                    if (channel.missing) missing_mask.* |= missing_bits[index];
                }
            },
            .list => |list| {
                if (list.bracketed or list.separator != .space) {
                    return self.invalidOklabChannels(span);
                }
                if (list.items.len == 2 and list.items[0] == .string and
                    !list.items[0].string.quoted)
                {
                    const leading_kinds = [_]ModernColorChannelKind{
                        .oklab_lightness,
                        .oklab_axis,
                    };
                    var leading: [2]ModernColorChannel = undefined;
                    if (!parseStaticModernColorChannels(
                        list.items[0].string.bytes,
                        &leading_kinds,
                        &leading,
                    )) return self.invalidOklabChannels(span);
                    const trailing = try self.modernColorChannel(
                        list.items[1],
                        .oklab_axis,
                        span,
                    );
                    for (leading, 0..) |channel, index| {
                        output[index] = channel.value;
                        if (channel.missing) missing_mask.* |= missing_bits[index];
                    }
                    output[2] = trailing.value;
                    if (trailing.missing) missing_mask.* |= missing_bits[2];
                    return;
                }
                if (list.items.len == 2 and list.items[1] == .string and
                    !list.items[1].string.quoted)
                {
                    const lightness = try self.modernColorChannel(
                        list.items[0],
                        .oklab_lightness,
                        span,
                    );
                    const axes_kinds = [_]ModernColorChannelKind{
                        .oklab_axis,
                        .oklab_axis,
                    };
                    var axes: [2]ModernColorChannel = undefined;
                    if (!parseStaticModernColorChannels(
                        list.items[1].string.bytes,
                        &axes_kinds,
                        &axes,
                    )) return self.invalidOklabChannels(span);
                    output[0] = lightness.value;
                    if (lightness.missing) missing_mask.* |= missing_bits[0];
                    for (axes, 1..) |channel, index| {
                        output[index] = channel.value;
                        if (channel.missing) missing_mask.* |= missing_bits[index];
                    }
                    return;
                }
                if (list.items.len != 3) return self.invalidOklabChannels(span);
                for (list.items, kinds, 0..) |item, kind, index| {
                    const channel = try self.modernColorChannel(item, kind, span);
                    output[index] = channel.value;
                    if (channel.missing) missing_mask.* |= missing_bits[index];
                }
            },
            else => return self.invalidOklabChannels(span),
        }
    }

    fn invalidOklabChannels(
        self: *Engine,
        span: native_source.Span,
    ) Error {
        self.report(
            .type_mismatch,
            span,
            "oklab() channels require an unbracketed three-item space list and optional slash alpha",
        ) catch |err| return err;
        return error.InvalidExpression;
    }

    fn invokeColorOklchFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner != null or reference.builtin != .oklch) return null;

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "channels" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        return try self.callOklchChannelsValue(bound.values[0].?.*, span);
    }

    fn callOklchChannelsValue(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var channels = value;
        var alpha: ?native_value.Value = null;
        if (value == .list) {
            const outer = value.list;
            if (outer.bracketed) return self.invalidOklchChannels(span);
            if (outer.separator == .slash or outer.separator == .legacy_slash) {
                if (outer.items.len != 2) return self.invalidOklchChannels(span);
                channels = outer.items[0];
                alpha = outer.items[1];
            }
        }

        var color_channels = [4]f64{ 0, 0, 0, 1 };
        var missing_mask: u4 = 0;
        try self.populateOklchChannels(
            channels,
            &color_channels,
            &missing_mask,
            span,
        );
        if (alpha) |alpha_value| {
            const channel = try self.modernColorChannel(alpha_value, .alpha, span);
            color_channels[3] = channel.value;
            if (channel.missing) missing_mask |= 0b1000;
        }
        const color = native_color.modern(
            .oklch,
            color_channels,
            missing_mask,
        ) catch |err| return self.colorTransformFailure(err, span);
        return self.values.own(.{ .color = color });
    }

    fn populateOklchChannels(
        self: *Engine,
        value: native_value.Value,
        output: *[4]f64,
        missing_mask: *u4,
        span: native_source.Span,
    ) Error!void {
        const kinds = [_]ModernColorChannelKind{
            .oklab_lightness,
            .oklch_chroma,
            .hue,
        };
        const missing_bits = [_]u4{ 0b0001, 0b0010, 0b0100 };
        switch (value) {
            .string => |string| {
                if (string.quoted) return self.invalidOklchChannels(span);
                var parsed: [3]ModernColorChannel = undefined;
                if (!parseStaticModernColorChannels(string.bytes, &kinds, &parsed)) {
                    return self.invalidOklchChannels(span);
                }
                for (parsed, 0..) |channel, index| {
                    output[index] = channel.value;
                    if (channel.missing) missing_mask.* |= missing_bits[index];
                }
            },
            .list => |list| {
                if (list.bracketed or list.separator != .space) {
                    return self.invalidOklchChannels(span);
                }
                if (list.items.len == 2 and list.items[0] == .string and
                    !list.items[0].string.quoted)
                {
                    const leading_kinds = [_]ModernColorChannelKind{
                        .oklab_lightness,
                        .oklch_chroma,
                    };
                    var leading: [2]ModernColorChannel = undefined;
                    if (!parseStaticModernColorChannels(
                        list.items[0].string.bytes,
                        &leading_kinds,
                        &leading,
                    )) return self.invalidOklchChannels(span);
                    const trailing = try self.modernColorChannel(
                        list.items[1],
                        .hue,
                        span,
                    );
                    for (leading, 0..) |channel, index| {
                        output[index] = channel.value;
                        if (channel.missing) missing_mask.* |= missing_bits[index];
                    }
                    output[2] = trailing.value;
                    if (trailing.missing) missing_mask.* |= missing_bits[2];
                    return;
                }
                if (list.items.len == 2 and list.items[1] == .string and
                    !list.items[1].string.quoted)
                {
                    const lightness = try self.modernColorChannel(
                        list.items[0],
                        .oklab_lightness,
                        span,
                    );
                    const trailing_kinds = [_]ModernColorChannelKind{
                        .oklch_chroma,
                        .hue,
                    };
                    var trailing: [2]ModernColorChannel = undefined;
                    if (!parseStaticModernColorChannels(
                        list.items[1].string.bytes,
                        &trailing_kinds,
                        &trailing,
                    )) return self.invalidOklchChannels(span);
                    output[0] = lightness.value;
                    if (lightness.missing) missing_mask.* |= missing_bits[0];
                    for (trailing, 1..) |channel, index| {
                        output[index] = channel.value;
                        if (channel.missing) missing_mask.* |= missing_bits[index];
                    }
                    return;
                }
                if (list.items.len != 3) return self.invalidOklchChannels(span);
                for (list.items, kinds, 0..) |item, kind, index| {
                    const channel = try self.modernColorChannel(item, kind, span);
                    output[index] = channel.value;
                    if (channel.missing) missing_mask.* |= missing_bits[index];
                }
            },
            else => return self.invalidOklchChannels(span),
        }
    }

    fn invalidOklchChannels(
        self: *Engine,
        span: native_source.Span,
    ) Error {
        self.report(
            .type_mismatch,
            span,
            "oklch() channels require an unbracketed three-item space list and optional slash alpha",
        ) catch |err| return err;
        return error.InvalidExpression;
    }

    fn invokeColorFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner != null or reference.builtin != .color) return null;

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "description" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        return try self.callPredefinedColorDescriptionValue(
            bound.values[0].?.*,
            span,
        );
    }

    fn callPredefinedColorDescriptionValue(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var description = value;
        var alpha: ?native_value.Value = null;
        if (value == .list) {
            const outer = value.list;
            if (outer.bracketed) return self.invalidPredefinedColorDescription(span);
            if (outer.separator == .slash or outer.separator == .legacy_slash) {
                if (outer.items.len != 2) {
                    return self.invalidPredefinedColorDescription(span);
                }
                description = outer.items[0];
                alpha = outer.items[1];
            }
        }

        var space: ?native_value.ColorSpace = null;
        var channels = [4]f64{ 0, 0, 0, 1 };
        var missing_mask: u4 = 0;
        var component_index: usize = 0;
        try self.populatePredefinedColorDescription(
            description,
            &space,
            &channels,
            &missing_mask,
            &component_index,
            span,
        );
        if (component_index != 4 or space == null) {
            return self.invalidPredefinedColorDescription(span);
        }
        if (alpha) |alpha_value| {
            const channel = try self.predefinedColorDescriptionChannel(
                alpha_value,
                .alpha,
                span,
            );
            channels[3] = channel.value;
            if (channel.missing) missing_mask |= 0b1000;
        }
        const color = native_color.predefined(
            space.?,
            channels,
            missing_mask,
        ) catch |err| return self.colorTransformFailure(err, span);
        return self.values.own(.{ .color = color });
    }

    fn populatePredefinedColorDescription(
        self: *Engine,
        value: native_value.Value,
        space: *?native_value.ColorSpace,
        channels: *[4]f64,
        missing_mask: *u4,
        component_index: *usize,
        span: native_source.Span,
    ) Error!void {
        switch (value) {
            .string => |string| {
                if (string.quoted) return self.invalidPredefinedColorDescription(span);
                const trimmed = trimWhitespace(string.bytes);
                var cursor: usize = 0;
                while (cursor < trimmed.len) {
                    while (cursor < trimmed.len and isExpressionWhitespace(trimmed[cursor])) {
                        cursor += 1;
                    }
                    const start = cursor;
                    while (cursor < trimmed.len and !isExpressionWhitespace(trimmed[cursor])) {
                        cursor += 1;
                    }
                    if (start == cursor or component_index.* >= 4) {
                        return self.invalidPredefinedColorDescription(span);
                    }
                    try self.appendPredefinedColorDescriptionString(
                        trimmed[start..cursor],
                        space,
                        channels,
                        missing_mask,
                        component_index,
                        span,
                    );
                }
            },
            .list => |list| {
                if (list.bracketed or list.separator != .space) {
                    return self.invalidPredefinedColorDescription(span);
                }
                for (list.items) |item| {
                    if (item == .string) {
                        try self.populatePredefinedColorDescription(
                            item,
                            space,
                            channels,
                            missing_mask,
                            component_index,
                            span,
                        );
                        continue;
                    }
                    if (component_index.* == 0 or component_index.* >= 4) {
                        return self.invalidPredefinedColorDescription(span);
                    }
                    const channel = try self.predefinedColorDescriptionChannel(
                        item,
                        .predefined,
                        span,
                    );
                    const channel_index = component_index.* - 1;
                    channels[channel_index] = channel.value;
                    if (channel.missing) {
                        missing_mask.* |= @as(u4, 1) << @intCast(channel_index);
                    }
                    component_index.* += 1;
                }
            },
            else => return self.invalidPredefinedColorDescription(span),
        }
    }

    fn appendPredefinedColorDescriptionString(
        self: *Engine,
        component: []const u8,
        space: *?native_value.ColorSpace,
        channels: *[4]f64,
        missing_mask: *u4,
        component_index: *usize,
        span: native_source.Span,
    ) Error!void {
        if (component_index.* == 0) {
            space.* = predefinedColorSpaceName(component) orelse
                return self.invalidPredefinedColorDescription(span);
        } else {
            const channel = parseStaticModernColorChannel(
                component,
                .predefined,
            ) orelse return self.invalidPredefinedColorDescription(span);
            const channel_index = component_index.* - 1;
            channels[channel_index] = channel.value;
            if (channel.missing) {
                missing_mask.* |= @as(u4, 1) << @intCast(channel_index);
            }
        }
        component_index.* += 1;
    }

    fn predefinedColorDescriptionChannel(
        self: *Engine,
        value: native_value.Value,
        kind: ModernColorChannelKind,
        span: native_source.Span,
    ) Error!ModernColorChannel {
        if (value == .string and !value.string.quoted) {
            return parseStaticModernColorChannel(value.string.bytes, kind) orelse
                self.invalidPredefinedColorDescription(span);
        }
        return self.modernColorChannel(value, kind, span);
    }

    fn invalidPredefinedColorDescription(
        self: *Engine,
        span: native_source.Span,
    ) Error {
        self.report(
            .type_mismatch,
            span,
            "color() description requires an unbracketed predefined space and three static channels with optional slash alpha",
        ) catch |err| return err;
        return error.InvalidExpression;
    }

    fn invokeColorRedFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .red or
            (reference.owner != null and reference.owner.? != .color))
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        const result = try self.callRedChannelValue(bound.values[0].?.*, span);

        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            if (reference.owner == null)
                "red() is deprecated. Use color.channel($color, \"red\", $space: rgb)."
            else
                "color.red() is deprecated. Use color.channel($color, \"red\", $space: rgb).",
            &.{},
        );
        return result;
    }

    fn callRedChannelValue(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const color = switch (value) {
            .color => |color| color,
            else => {
                try self.report(.type_mismatch, span, "red() requires one color");
                return error.InvalidExpression;
            },
        };
        switch (color.space) {
            .rgb, .hsl, .hwb => {},
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "red() is available only for legacy RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
        return self.values.own(.{ .number = .{
            .value = @round((try native_color.toRgb(color))[0]),
        } });
    }

    fn invokeColorGreenFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .green or
            (reference.owner != null and reference.owner.? != .color))
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        const result = try self.callGreenChannelValue(bound.values[0].?.*, span);

        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            if (reference.owner == null)
                "green() is deprecated. Use color.channel($color, \"green\", $space: rgb)."
            else
                "color.green() is deprecated. Use color.channel($color, \"green\", $space: rgb).",
            &.{},
        );
        return result;
    }

    fn callGreenChannelValue(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const color = switch (value) {
            .color => |color| color,
            else => {
                try self.report(.type_mismatch, span, "green() requires one color");
                return error.InvalidExpression;
            },
        };
        switch (color.space) {
            .rgb, .hsl, .hwb => {},
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "green() is available only for legacy RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
        return self.values.own(.{ .number = .{
            .value = @round((try native_color.toRgb(color))[1]),
        } });
    }

    fn invokeColorBlueFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .blue or
            (reference.owner != null and reference.owner.? != .color))
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        const result = try self.callBlueChannelValue(bound.values[0].?.*, span);

        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            if (reference.owner == null)
                "blue() is deprecated. Use color.channel($color, \"blue\", $space: rgb)."
            else
                "color.blue() is deprecated. Use color.channel($color, \"blue\", $space: rgb).",
            &.{},
        );
        return result;
    }

    fn callBlueChannelValue(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const color = switch (value) {
            .color => |color| color,
            else => {
                try self.report(.type_mismatch, span, "blue() requires one color");
                return error.InvalidExpression;
            },
        };
        switch (color.space) {
            .rgb, .hsl, .hwb => {},
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "blue() is available only for legacy RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
        return self.values.own(.{ .number = .{
            .value = @round((try native_color.toRgb(color))[2]),
        } });
    }

    fn invokeColorAlphaFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .alpha or
            (reference.owner != null and reference.owner.? != .color))
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        const result = try self.callAlphaChannelValue(bound.values[0].?.*, span);

        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        return result;
    }

    fn callAlphaChannelValue(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const color = switch (value) {
            .color => |color| color,
            else => {
                try self.report(.type_mismatch, span, "alpha() requires one color");
                return error.InvalidExpression;
            },
        };
        switch (color.space) {
            .rgb, .hsl, .hwb => {},
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "color.alpha() is available only for legacy RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
        return self.values.own(.{ .number = .{
            .value = (try native_color.toRgb(color))[3],
        } });
    }

    fn invokeColorOpacityFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .opacity or
            (reference.owner != null and reference.owner.? != .color))
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        const argument = bound.values[0].?;
        const result = switch (argument.*) {
            .color => |color| try self.values.own(.{ .number = .{
                .value = color.channels[3],
            } }),
            .number => blk: {
                if (reference.owner != null) {
                    try self.transaction.report(
                        .warning,
                        .invalid_operation,
                        span,
                        "Passing a number to color.opacity() is deprecated.",
                        &.{},
                    );
                }
                break :blk try self.preserveOpacityNumber(argument.number);
            },
            else => blk: {
                if (reference.owner == null and isDeferredColorValue(argument.*)) {
                    const forwarded = [_]*const native_value.Value{argument};
                    break :blk try self.preserveEvaluatedFunction(
                        "opacity()",
                        &forwarded,
                        span,
                    );
                }
                try self.report(
                    .type_mismatch,
                    span,
                    "opacity() requires one color or CSS filter amount",
                );
                return error.InvalidExpression;
            },
        };

        if (reference.owner == null and argument.* == .color) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        return result;
    }

    fn preserveOpacityNumber(
        self: *Engine,
        number: native_value.Number,
    ) Error!*const native_value.Value {
        var rendered: std.ArrayList(u8) = .empty;
        defer rendered.deinit(self.allocator);
        try self.appendTemporary(&rendered, "opacity(");
        var buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
        try self.appendTemporary(
            &rendered,
            try native_numeric.serialize(number.value, &buffer, false),
        );
        for (number.numerator_units, 0..) |unit, index| {
            if (index > 0) try self.appendTemporary(&rendered, "*");
            try self.appendTemporary(&rendered, unit);
        }
        for (number.denominator_units) |unit| {
            try self.appendTemporary(&rendered, "/");
            try self.appendTemporary(&rendered, unit);
        }
        try self.appendTemporary(&rendered, ")");
        return self.values.own(.{ .string = .{ .bytes = rendered.items } });
    }

    fn invokeColorHueFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .hue or
            (reference.owner != null and reference.owner.? != .color))
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        const result = try self.callHueChannelValue(bound.values[0].?.*, span);

        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            if (reference.owner == null)
                "hue() is deprecated. Use color.channel($color, \"hue\", $space: hsl)."
            else
                "color.hue() is deprecated. Use color.channel($color, \"hue\", $space: hsl).",
            &.{},
        );
        return result;
    }

    fn callHueChannelValue(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const color = switch (value) {
            .color => |color| color,
            else => {
                try self.report(.type_mismatch, span, "hue() requires one color");
                return error.InvalidExpression;
            },
        };
        switch (color.space) {
            .rgb, .hsl, .hwb => {},
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "color.hue() is available only for legacy RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
        const units = [_][]const u8{"deg"};
        return self.values.own(.{ .number = .{
            .value = (try native_color.toHsl(color))[0],
            .numerator_units = &units,
        } });
    }

    fn invokeColorSaturationFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .saturation or
            (reference.owner != null and reference.owner.? != .color))
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        const result = try self.callSaturationChannelValue(bound.values[0].?.*, span);

        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            if (reference.owner == null)
                "saturation() is deprecated. Use color.channel($color, \"saturation\", $space: hsl)."
            else
                "color.saturation() is deprecated. Use color.channel($color, \"saturation\", $space: hsl).",
            &.{},
        );
        return result;
    }

    fn callSaturationChannelValue(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const color = switch (value) {
            .color => |color| color,
            else => {
                try self.report(.type_mismatch, span, "saturation() requires one color");
                return error.InvalidExpression;
            },
        };
        switch (color.space) {
            .rgb, .hsl, .hwb => {},
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "color.saturation() is available only for legacy RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
        const units = [_][]const u8{"%"};
        return self.values.own(.{ .number = .{
            .value = (try native_color.toHsl(color))[1],
            .numerator_units = &units,
        } });
    }

    fn invokeColorLightnessFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .lightness or
            (reference.owner != null and reference.owner.? != .color))
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        const result = try self.callLightnessChannelValue(bound.values[0].?.*, span);

        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            if (reference.owner == null)
                "lightness() is deprecated. Use color.channel($color, \"lightness\", $space: hsl)."
            else
                "color.lightness() is deprecated. Use color.channel($color, \"lightness\", $space: hsl).",
            &.{},
        );
        return result;
    }

    fn callLightnessChannelValue(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const color = switch (value) {
            .color => |color| color,
            else => {
                try self.report(.type_mismatch, span, "lightness() requires one color");
                return error.InvalidExpression;
            },
        };
        switch (color.space) {
            .rgb, .hsl, .hwb => {},
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "color.lightness() is available only for legacy RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
        const units = [_][]const u8{"%"};
        return self.values.own(.{ .number = .{
            .value = (try native_color.toHsl(color))[2],
            .numerator_units = &units,
        } });
    }

    fn invokeColorWhitenessFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .whiteness or reference.owner != .color) return null;

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        const result = try self.callWhitenessChannelValue(bound.values[0].?.*, span);

        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            "color.whiteness() is deprecated. Use color.channel($color, \"whiteness\", $space: hwb).",
            &.{},
        );
        return result;
    }

    fn callWhitenessChannelValue(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const color = switch (value) {
            .color => |color| color,
            else => {
                try self.report(.type_mismatch, span, "whiteness() requires one color");
                return error.InvalidExpression;
            },
        };
        switch (color.space) {
            .rgb, .hsl, .hwb => {},
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "color.whiteness() is available only for legacy RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
        const units = [_][]const u8{"%"};
        return self.values.own(.{ .number = .{
            .value = (try native_color.toHwb(color))[1],
            .numerator_units = &units,
        } });
    }

    fn invokeColorBlacknessFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .blackness or reference.owner != .color) return null;

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        const result = try self.callBlacknessChannelValue(bound.values[0].?.*, span);

        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            "color.blackness() is deprecated. Use color.channel($color, \"blackness\", $space: hwb).",
            &.{},
        );
        return result;
    }

    fn callBlacknessChannelValue(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const color = switch (value) {
            .color => |color| color,
            else => {
                try self.report(.type_mismatch, span, "blackness() requires one color");
                return error.InvalidExpression;
            },
        };
        switch (color.space) {
            .rgb, .hsl, .hwb => {},
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "color.blackness() is available only for legacy RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
        const units = [_][]const u8{"%"};
        return self.values.own(.{ .number = .{
            .value = (try native_color.toHwb(color))[2],
            .numerator_units = &units,
        } });
    }

    fn invokeColorMixFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .mix or
            (reference.owner != null and reference.owner.? != .color))
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color1" },
            .{ .name = "color2" },
            .{ .name = "weight", .required = false },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const first = try self.legacyMixColorArgument(bound.values[0].?.*, span);
        const second = try self.legacyMixColorArgument(bound.values[1].?.*, span);
        const weight = if (bound.values[2]) |value|
            try self.legacyMixWeight(value.*, span)
        else
            50;
        const result = native_color.mix(first, second, weight) catch |failure| {
            return self.colorTransformFailure(failure, span);
        };

        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        return self.values.own(.{ .color = result });
    }

    fn legacyMixColorArgument(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!native_value.Color {
        const color = switch (value) {
            .color => |color| color,
            else => {
                try self.report(.type_mismatch, span, "mix() requires two colors");
                return error.InvalidExpression;
            },
        };
        if (color.missing_mask != 0) {
            try self.report(
                .type_mismatch,
                span,
                "native legacy mix() does not support missing color channels",
            );
            return error.InvalidExpression;
        }
        switch (color.space) {
            .rgb, .hsl, .hwb => return color,
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "native legacy mix() supports only RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
    }

    fn legacyMixWeight(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!f64 {
        const number = switch (value) {
            .number => |number| number,
            else => {
                try self.report(.type_mismatch, span, "mix() weight requires a percentage");
                return error.InvalidExpression;
            },
        };
        if (number.numerator_units.len != 1 or
            number.denominator_units.len != 0 or
            !std.mem.eql(u8, number.numerator_units[0], "%"))
        {
            try self.report(.type_mismatch, span, "mix() weight requires a percentage");
            return error.InvalidExpression;
        }
        if (!std.math.isFinite(number.value) or number.value < 0 or number.value > 100) {
            try self.report(
                .invalid_operation,
                span,
                "mix() weight must be between 0% and 100%",
            );
            return error.InvalidExpression;
        }
        return number.value;
    }

    fn invokeColorLightenFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .lighten) return null;
        if (reference.owner) |owner| {
            if (owner != .color) return null;
            try self.report(
                .unsupported_feature,
                span,
                "lighten() is not callable from the sass:color module",
            );
            return error.InvalidExpression;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
            .{ .name = "amount" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const color = try self.legacyLightenColorArgument(bound.values[0].?.*, span);
        const amount = try self.legacyColorAmount(bound.values[1].?.*, 0, 100, span);
        const result = native_color.adjustLightness(color, amount) catch |failure| {
            return self.colorTransformFailure(failure, span);
        };

        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
            &.{},
        );
        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            "lighten() is deprecated. Use color.adjust($color, $lightness: $amount).",
            &.{},
        );
        return self.values.own(.{ .color = result });
    }

    fn legacyLightenColorArgument(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!native_value.Color {
        const color = switch (value) {
            .color => |color| color,
            else => {
                try self.report(.type_mismatch, span, "lighten() requires a color");
                return error.InvalidExpression;
            },
        };
        if (color.missing_mask != 0) {
            try self.report(
                .unsupported_feature,
                span,
                "native legacy lighten() does not support missing color channels",
            );
            return error.UnsupportedFeature;
        }
        switch (color.space) {
            .rgb, .hsl, .hwb => return color,
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "native legacy lighten() supports only RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
    }

    fn invokeColorDarkenFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .darken) return null;
        if (reference.owner) |owner| {
            if (owner != .color) return null;
            try self.report(
                .unsupported_feature,
                span,
                "darken() is not callable from the sass:color module",
            );
            return error.InvalidExpression;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
            .{ .name = "amount" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const color = try self.legacyDarkenColorArgument(bound.values[0].?.*, span);
        const amount = try self.legacyColorAmount(bound.values[1].?.*, 0, 100, span);
        const result = native_color.adjustLightness(color, -amount) catch |failure| {
            return self.colorTransformFailure(failure, span);
        };

        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
            &.{},
        );
        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            "darken() is deprecated. Use color.adjust($color, $lightness: -$amount).",
            &.{},
        );
        return self.values.own(.{ .color = result });
    }

    fn legacyDarkenColorArgument(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!native_value.Color {
        const color = switch (value) {
            .color => |color| color,
            else => {
                try self.report(.type_mismatch, span, "darken() requires a color");
                return error.InvalidExpression;
            },
        };
        if (color.missing_mask != 0) {
            try self.report(
                .unsupported_feature,
                span,
                "native legacy darken() does not support missing color channels",
            );
            return error.UnsupportedFeature;
        }
        switch (color.space) {
            .rgb, .hsl, .hwb => return color,
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "native legacy darken() supports only RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
    }

    fn invokeColorSaturateFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .saturate) return null;
        if (reference.owner) |owner| {
            if (owner != .color) return null;
            try self.report(
                .unsupported_feature,
                span,
                "saturate() is not callable from the sass:color module",
            );
            return error.InvalidExpression;
        }

        const filter_form = blk: {
            if (arguments.positional.items.len == 0 and arguments.keywords.items.len == 0) {
                break :blk true;
            }
            if (arguments.positional.items.len == 1 and arguments.keywords.items.len == 0) {
                break :blk true;
            }
            if (arguments.positional.items.len != 0 or arguments.keywords.items.len != 1) {
                break :blk false;
            }
            const keyword = arguments.keywords.items[0];
            break :blk if (keyword.normalize_name)
                native_arguments.nameEql(keyword.name, "amount")
            else
                std.mem.eql(u8, keyword.name, "amount");
        };
        if (filter_form) {
            const parameters = [_]native_arguments.Parameter{.{ .name = "amount" }};
            var bound = try self.bindEvaluatedArguments(
                &parameters,
                parameters.len,
                arguments,
                span,
            );
            defer bound.deinit();

            const amount = bound.values[0].?;
            const valid_filter = switch (amount.*) {
                .number => true,
                else => isDeferredColorValue(amount.*),
            };
            if (!valid_filter) {
                try self.report(
                    .type_mismatch,
                    span,
                    "saturate() CSS filter amount requires a number or deferred CSS value",
                );
                return error.InvalidExpression;
            }
            const rendered = [_]*const native_value.Value{amount};
            return self.preservePlainCssFunction("saturate", &rendered, false);
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
            .{ .name = "amount" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const color = try self.legacySaturateColorArgument(bound.values[0].?.*, span);
        const amount = try self.legacyColorAmount(bound.values[1].?.*, 0, 100, span);
        const result = native_color.adjustSaturation(color, amount) catch |failure| {
            return self.colorTransformFailure(failure, span);
        };

        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
            &.{},
        );
        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            "saturate() is deprecated. Use color.adjust($color, $saturation: $amount).",
            &.{},
        );
        return self.values.own(.{ .color = result });
    }

    fn legacySaturateColorArgument(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!native_value.Color {
        const color = switch (value) {
            .color => |color| color,
            else => {
                try self.report(.type_mismatch, span, "saturate() requires a color");
                return error.InvalidExpression;
            },
        };
        if (color.missing_mask != 0) {
            try self.report(
                .unsupported_feature,
                span,
                "native legacy saturate() does not support missing color channels",
            );
            return error.UnsupportedFeature;
        }
        switch (color.space) {
            .rgb, .hsl, .hwb => return color,
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "native legacy saturate() supports only RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
    }

    fn invokeColorDesaturateFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .desaturate) return null;
        if (reference.owner) |owner| {
            if (owner != .color) return null;
            try self.report(
                .unsupported_feature,
                span,
                "desaturate() is not callable from the sass:color module",
            );
            return error.InvalidExpression;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
            .{ .name = "amount" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const color = try self.legacyDesaturateColorArgument(bound.values[0].?.*, span);
        const amount = try self.legacyColorAmount(bound.values[1].?.*, 0, 100, span);
        const result = native_color.adjustSaturation(color, -amount) catch |failure| {
            return self.colorTransformFailure(failure, span);
        };

        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
            &.{},
        );
        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            "desaturate() is deprecated. Use color.adjust($color, $saturation: -$amount).",
            &.{},
        );
        return self.values.own(.{ .color = result });
    }

    fn legacyDesaturateColorArgument(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!native_value.Color {
        const color = switch (value) {
            .color => |color| color,
            else => {
                try self.report(.type_mismatch, span, "desaturate() requires a color");
                return error.InvalidExpression;
            },
        };
        if (color.missing_mask != 0) {
            try self.report(
                .unsupported_feature,
                span,
                "native legacy desaturate() does not support missing color channels",
            );
            return error.UnsupportedFeature;
        }
        switch (color.space) {
            .rgb, .hsl, .hwb => return color,
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "native legacy desaturate() supports only RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
    }

    fn invokeColorAdjustHueFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .adjust_hue) return null;
        if (reference.owner) |owner| {
            if (owner != .color) return null;
            try self.report(
                .unsupported_feature,
                span,
                "adjust-hue() is not callable from the sass:color module",
            );
            return error.InvalidExpression;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
            .{ .name = "degrees" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const color = try self.legacyAdjustHueColorArgument(bound.values[0].?.*, span);
        const degrees = try self.legacyAdjustHueAngle(bound.values[1].?.*, span);
        const result = native_color.adjustHue(color, degrees) catch |failure| {
            return self.colorTransformFailure(failure, span);
        };

        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
            &.{},
        );
        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            "adjust-hue() is deprecated. Use color.adjust($color, $hue: $degrees).",
            &.{},
        );
        return self.values.own(.{ .color = result });
    }

    fn legacyAdjustHueColorArgument(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!native_value.Color {
        const color = switch (value) {
            .color => |color| color,
            else => {
                try self.report(.type_mismatch, span, "adjust-hue() requires a color");
                return error.InvalidExpression;
            },
        };
        if (color.missing_mask != 0) {
            try self.report(
                .unsupported_feature,
                span,
                "native legacy adjust-hue() does not support missing color channels",
            );
            return error.UnsupportedFeature;
        }
        switch (color.space) {
            .rgb, .hsl, .hwb => return color,
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "native legacy adjust-hue() supports only RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
    }

    fn legacyAdjustHueAngle(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!f64 {
        const number = try self.colorNumber(value, span);
        if (number.numerator_units.len == 0) return number.value;

        const unit = number.numerator_units[0];
        if (std.ascii.eqlIgnoreCase(unit, "grad")) return number.value * 0.9;
        if (std.ascii.eqlIgnoreCase(unit, "rad")) return number.value * 180 / std.math.pi;
        if (std.ascii.eqlIgnoreCase(unit, "turn")) return number.value * 360;

        // Dart Sass 1.101.0 treats unitless values, degrees, and deprecated
        // arbitrary simple units as degree magnitudes for this legacy global.
        return number.value;
    }

    fn invokeColorComplementFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .complement or
            (reference.owner != null and reference.owner.? != .color))
        {
            return null;
        }

        const global_parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
        };
        const module_parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
            .{ .name = "space", .required = false },
        };
        const parameters: []const native_arguments.Parameter = if (reference.owner == null)
            &global_parameters
        else
            &module_parameters;
        var bound = try self.bindEvaluatedArguments(
            parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        if (reference.owner != null and bound.values[1] != null) {
            try self.report(
                .unsupported_feature,
                span,
                "native complement() interpolation spaces are not implemented",
            );
            return error.UnsupportedFeature;
        }
        const color = try self.legacyComplementColorArgument(bound.values[0].?.*, span);
        const result = native_color.adjustHue(color, 180) catch |failure| {
            return self.colorTransformFailure(failure, span);
        };

        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        return self.values.own(.{ .color = result });
    }

    fn legacyComplementColorArgument(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!native_value.Color {
        const color = switch (value) {
            .color => |color| color,
            else => {
                try self.report(.type_mismatch, span, "complement() requires a color");
                return error.InvalidExpression;
            },
        };
        if (color.missing_mask != 0) {
            try self.report(
                .unsupported_feature,
                span,
                "native legacy complement() does not support missing color channels",
            );
            return error.UnsupportedFeature;
        }
        switch (color.space) {
            .rgb, .hsl, .hwb => return color,
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "native legacy complement() supports only RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
    }

    fn invokeColorGrayscaleFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .grayscale or
            (reference.owner != null and reference.owner.? != .color))
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();
        const argument = bound.values[0].?;
        const result = switch (argument.*) {
            .color => |color| blk: {
                const legacy = try self.legacyGrayscaleColorArgument(color, span);
                const grayscale = native_color.grayscale(legacy) catch |failure| {
                    return self.colorTransformFailure(failure, span);
                };
                break :blk try self.values.own(.{ .color = grayscale });
            },
            .number => blk: {
                if (reference.owner != null) {
                    try self.transaction.report(
                        .warning,
                        .invalid_operation,
                        span,
                        "Passing a number to color.grayscale() is deprecated.",
                        &.{},
                    );
                }
                const rendered = [_]*const native_value.Value{argument};
                break :blk try self.preservePlainCssFunction(
                    "grayscale",
                    &rendered,
                    false,
                );
            },
            else => blk: {
                if (reference.owner == null and isDeferredColorValue(argument.*)) {
                    const rendered = [_]*const native_value.Value{argument};
                    break :blk try self.preservePlainCssFunction(
                        "grayscale",
                        &rendered,
                        false,
                    );
                }
                try self.report(
                    .type_mismatch,
                    span,
                    "grayscale() requires one color or CSS filter amount",
                );
                return error.InvalidExpression;
            },
        };

        if (reference.owner == null and argument.* == .color) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        return result;
    }

    fn legacyGrayscaleColorArgument(
        self: *Engine,
        color: native_value.Color,
        span: native_source.Span,
    ) Error!native_value.Color {
        if (color.missing_mask != 0) {
            try self.report(
                .unsupported_feature,
                span,
                "native legacy grayscale() does not support missing color channels",
            );
            return error.UnsupportedFeature;
        }
        switch (color.space) {
            .rgb, .hsl, .hwb => return color,
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "native legacy grayscale() supports only RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
    }

    fn invokeColorInvertFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .invert or
            (reference.owner != null and reference.owner.? != .color))
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
            .{ .name = "weight", .required = false },
            .{ .name = "space", .required = false },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        if (bound.values[2] != null) {
            try self.report(
                .unsupported_feature,
                span,
                "native invert() interpolation spaces are not implemented",
            );
            return error.UnsupportedFeature;
        }

        const argument = bound.values[0].?;
        const result = switch (argument.*) {
            .color => |color| blk: {
                const legacy = try self.legacyInvertColorArgument(color, span);
                const weight = if (bound.values[1]) |value|
                    try self.legacyInvertWeight(value.*, span)
                else
                    100;
                const inverted = native_color.invert(legacy, weight) catch |failure| {
                    return self.colorTransformFailure(failure, span);
                };
                break :blk try self.values.own(.{ .color = inverted });
            },
            .number => blk: {
                if (bound.values[1] != null) {
                    try self.report(
                        .invalid_operation,
                        span,
                        "invert() CSS filter form accepts only one argument",
                    );
                    return error.InvalidExpression;
                }
                if (reference.owner != null) {
                    try self.transaction.report(
                        .warning,
                        .invalid_operation,
                        span,
                        "Passing a number to color.invert() is deprecated.",
                        &.{},
                    );
                }
                const rendered = [_]*const native_value.Value{argument};
                break :blk try self.preservePlainCssFunction(
                    "invert",
                    &rendered,
                    false,
                );
            },
            else => blk: {
                if (reference.owner == null and
                    bound.values[1] == null and
                    isDeferredColorValue(argument.*))
                {
                    const rendered = [_]*const native_value.Value{argument};
                    break :blk try self.preservePlainCssFunction(
                        "invert",
                        &rendered,
                        false,
                    );
                }
                try self.report(
                    .type_mismatch,
                    span,
                    "invert() requires a color or one CSS filter amount",
                );
                return error.InvalidExpression;
            },
        };

        if (reference.owner == null and argument.* == .color) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        return result;
    }

    fn legacyInvertColorArgument(
        self: *Engine,
        color: native_value.Color,
        span: native_source.Span,
    ) Error!native_value.Color {
        if (color.missing_mask != 0) {
            try self.report(
                .unsupported_feature,
                span,
                "native legacy invert() does not support missing color channels",
            );
            return error.UnsupportedFeature;
        }
        switch (color.space) {
            .rgb, .hsl, .hwb => return color,
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    "native legacy invert() supports only RGB, HSL, or HWB colors",
                );
                return error.InvalidExpression;
            },
        }
    }

    fn legacyInvertWeight(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!f64 {
        const number = switch (value) {
            .number => |number| number,
            else => {
                try self.report(.type_mismatch, span, "invert() weight requires a percentage");
                return error.InvalidExpression;
            },
        };
        if (number.numerator_units.len != 1 or
            number.denominator_units.len != 0 or
            !std.mem.eql(u8, number.numerator_units[0], "%"))
        {
            try self.report(.type_mismatch, span, "invert() weight requires a percentage");
            return error.InvalidExpression;
        }
        if (!std.math.isFinite(number.value) or number.value < 0 or number.value > 100) {
            try self.report(
                .invalid_operation,
                span,
                "invert() weight must be between 0% and 100%",
            );
            return error.InvalidExpression;
        }
        return number.value;
    }

    fn invokeColorLegacyAlphaFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .opacify and
            reference.builtin != .fade_in and
            reference.builtin != .transparentize) return null;
        if (reference.owner) |owner| {
            if (owner != .color) return null;
            try self.report(
                .unsupported_feature,
                span,
                switch (reference.builtin) {
                    .opacify => "opacify() is not callable from the sass:color module",
                    .fade_in => "fade-in() is not callable from the sass:color module",
                    .transparentize => "transparentize() is not callable from the sass:color module",
                    else => unreachable,
                },
            );
            return error.InvalidExpression;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "color" },
            .{ .name = "amount" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const color = try self.legacyAlphaColorArgument(
            reference.builtin,
            bound.values[0].?.*,
            span,
        );
        const amount = try self.legacyAlphaAmount(
            reference.builtin,
            bound.values[1].?.*,
            span,
        );
        const delta = if (reference.builtin == .transparentize) -amount else amount;
        const result = native_color.adjustAlpha(color, delta) catch |failure| {
            return self.colorTransformFailure(failure, span);
        };

        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
            &.{},
        );
        try self.transaction.report(
            .warning,
            .invalid_operation,
            span,
            switch (reference.builtin) {
                .opacify => "opacify() is deprecated. Use color.adjust($color, $alpha: $amount).",
                .fade_in => "fade-in() is deprecated. Use color.adjust($color, $alpha: $amount).",
                .transparentize => "transparentize() is deprecated. Use color.adjust($color, $alpha: -$amount).",
                else => unreachable,
            },
            &.{},
        );
        return self.values.own(.{ .color = result });
    }

    fn legacyAlphaColorArgument(
        self: *Engine,
        builtin: Builtin,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!native_value.Color {
        const color = switch (value) {
            .color => |color| color,
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    switch (builtin) {
                        .opacify => "opacify() requires a color",
                        .fade_in => "fade-in() requires a color",
                        .transparentize => "transparentize() requires a color",
                        else => unreachable,
                    },
                );
                return error.InvalidExpression;
            },
        };
        if (color.missing_mask != 0) {
            try self.report(
                .unsupported_feature,
                span,
                switch (builtin) {
                    .opacify => "native legacy opacify() does not support missing color channels",
                    .fade_in => "native legacy fade-in() does not support missing color channels",
                    .transparentize => "native legacy transparentize() does not support missing color channels",
                    else => unreachable,
                },
            );
            return error.UnsupportedFeature;
        }
        switch (color.space) {
            .rgb => return color,
            .hsl, .hwb => {
                const channels = native_color.toRgb(color) catch |failure| {
                    return self.colorTransformFailure(failure, span);
                };
                return native_color.rgb(
                    channels[0],
                    channels[1],
                    channels[2],
                    channels[3],
                ) catch |failure| {
                    return self.colorTransformFailure(failure, span);
                };
            },
            else => {
                try self.report(
                    .type_mismatch,
                    span,
                    switch (builtin) {
                        .opacify => "native legacy opacify() supports only RGB, HSL, or HWB colors",
                        .fade_in => "native legacy fade-in() supports only RGB, HSL, or HWB colors",
                        .transparentize => "native legacy transparentize() supports only RGB, HSL, or HWB colors",
                        else => unreachable,
                    },
                );
                return error.InvalidExpression;
            },
        }
    }

    fn legacyAlphaAmount(
        self: *Engine,
        builtin: Builtin,
        value: native_value.Value,
        span: native_source.Span,
    ) Error!f64 {
        const number = try self.colorNumber(value, span);
        if (!std.math.isFinite(number.value) or number.value < 0 or number.value > 1) {
            try self.report(
                .invalid_operation,
                span,
                switch (builtin) {
                    .opacify => "opacify() amount must be between zero and one",
                    .fade_in => "fade-in() amount must be between zero and one",
                    .transparentize => "transparentize() amount must be between zero and one",
                    else => unreachable,
                },
            );
            return error.InvalidExpression;
        }
        return number.value;
    }

    fn invalidHslChannels(
        self: *Engine,
        span: native_source.Span,
    ) Error {
        self.report(
            .type_mismatch,
            span,
            "hsl() channels require an unbracketed three-item space list and optional slash alpha",
        ) catch |err| return err;
        return error.InvalidExpression;
    }

    fn invalidRgbChannels(
        self: *Engine,
        span: native_source.Span,
    ) Error {
        self.report(
            .type_mismatch,
            span,
            "rgb() channels require an unbracketed three-item space list and optional slash alpha",
        ) catch |err| return err;
        return error.InvalidExpression;
    }

    fn invokeSelectorParseFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner == null or reference.owner.? != .selector or
            reference.builtin != .selector_parse)
        {
            return null;
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "selector" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const ordered = [_]*const native_value.Value{
            bound.values[0].?,
        };
        return try self.callSelectorParse(&ordered, span);
    }

    fn invokeSelectorSimpleSelectorsFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .selector_simple_selectors or
            (reference.owner != null and reference.owner.? != .selector))
        {
            return null;
        }
        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "selector" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const ordered = [_]*const native_value.Value{
            bound.values[0].?,
        };
        return try self.callSelectorSimpleSelectors(&ordered, span);
    }

    fn invokeSelectorIsSuperselectorFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .selector_is_superselector or
            (reference.owner != null and reference.owner.? != .selector))
        {
            return null;
        }
        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "super" },
            .{ .name = "sub" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const ordered = [_]*const native_value.Value{
            bound.values[0].?,
            bound.values[1].?,
        };
        return try self.callSelectorIsSuperselector(&ordered, span);
    }

    fn invokeSelectorUnifyFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .selector_unify or
            (reference.owner != null and reference.owner.? != .selector))
        {
            return null;
        }
        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "selector1" },
            .{ .name = "selector2" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const ordered = [_]*const native_value.Value{
            bound.values[0].?,
            bound.values[1].?,
        };
        return try self.callSelectorUnify(&ordered, span);
    }

    fn invokeSelectorAppendFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.owner == null or reference.owner.? != .selector or
            reference.builtin != .selector_append)
        {
            return null;
        }
        return try self.callSelectorComposition(.selector_append, arguments, span);
    }

    fn invokeSelectorNestFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .selector_nest or
            (reference.owner != null and reference.owner.? != .selector))
        {
            return null;
        }
        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        return try self.callSelectorComposition(.selector_nest, arguments, span);
    }

    fn invokeSelectorExtendFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .selector_extend or
            (reference.owner != null and reference.owner.? != .selector))
        {
            return null;
        }
        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "selector" },
            .{ .name = "extendee" },
            .{ .name = "extender" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const ordered = [_]*const native_value.Value{
            bound.values[0].?,
            bound.values[1].?,
            bound.values[2].?,
        };
        return try self.callSelectorExtension(.selector_extend, &ordered, span);
    }

    fn invokeSelectorReplaceFunction(
        self: *Engine,
        callable: native_value.Callable,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        const reference = decodeBuiltinFunctionCallable(callable.id) orelse return null;
        if (reference.builtin != .selector_replace or
            (reference.owner != null and reference.owner.? != .selector))
        {
            return null;
        }
        if (reference.owner == null) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }

        const parameters = [_]native_arguments.Parameter{
            .{ .name = "selector" },
            .{ .name = "original" },
            .{ .name = "replacement" },
        };
        var bound = try self.bindEvaluatedArguments(
            &parameters,
            parameters.len,
            arguments,
            span,
        );
        defer bound.deinit();

        const ordered = [_]*const native_value.Value{
            bound.values[0].?,
            bound.values[1].?,
            bound.values[2].?,
        };
        return try self.callSelectorExtension(.selector_replace, &ordered, span);
    }

    fn metaCallFunctionFailure(
        self: *Engine,
        span: native_source.Span,
    ) Error {
        self.report(
            .type_mismatch,
            span,
            "native Sass meta.call() requires an available user, list, map, meta inspection, meta keywords, meta content acceptance, meta calculation, meta existence, unary math, math unit, math trigonometric, math logarithm, math power, math root, math division, math clamp, math hypotenuse, math minimum, math maximum, math random, string quote, unquote, length, index, slice, insert, upper-case, or lower-case, color adjust, change, scale, rgb, rgba, hsl, hsla, hwb, or lab, selector parse, selector simple-selectors, selector is-superselector, selector unify, selector append, selector nest, selector extend, or selector replace function reference",
        ) catch |err| return err;
        return error.InvalidExpression;
    }

    fn metaGlobalFunctionReference(
        self: *Engine,
        name: []const u8,
        scope: native_environment.ScopeId,
    ) Error!?native_value.Callable {
        if (try self.lookupUserFunction(name, scope)) |function_id| {
            return .{ .kind = .user_function, .id = function_id };
        }
        if (std.mem.eql(u8, name, "if")) return builtinIfFunctionCallable();

        for (self.modules.items) |binding| {
            try self.transaction.consumeOperations(1);
            if (binding.namespace != null) continue;
            if (moduleCallableBuiltin(binding.kind, name)) |builtin| {
                return builtinFunctionCallable(builtin, binding.kind);
            }
        }
        const builtin = globalCallableBuiltin(name) orelse return null;
        return builtinFunctionCallable(builtin, null);
    }

    fn callMetaExistence(
        self: *Engine,
        builtin: Builtin,
        module_owned: bool,
        arguments: []const *const native_value.Value,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (!module_owned) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "Global built-in functions are deprecated and will be removed in Dart Sass 3.0.0.",
                &.{},
            );
        }
        if (builtin == .meta_feature_exists) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "The feature-exists() function is deprecated.",
                &.{},
            );
        }
        try self.transaction.consumeOperations(1);

        const name_string = try self.metaExistenceString(arguments[0].*, "name", span);
        const raw_name = native_string.decodeAlloc(
            self.allocator,
            name_string.bytes,
            name_string.quoted,
            self.limits.max_temporary_bytes,
        ) catch |err| return self.stringFailure(err, span);
        defer self.allocator.free(raw_name);
        if (builtin == .meta_feature_exists) {
            return self.values.own(.{ .boolean = metaFeatureExists(raw_name) });
        }

        const module = if (arguments.len == 2)
            try self.metaExistenceModule(arguments[1].*, span)
        else
            null;
        const normalized = (try self.normalizeMetaExistenceName(raw_name, span)) orelse
            return self.values.own(.{ .boolean = false });
        defer self.allocator.free(normalized);

        const exists = switch (builtin) {
            .meta_function_exists => if (module) |kind|
                moduleFunctionExists(kind, normalized)
            else
                try self.metaGlobalFunctionExists(normalized, scope),
            .meta_mixin_exists => if (module) |kind|
                moduleBuiltinMixin(kind, normalized) != null
            else
                (try self.lookupUserMixin(normalized, scope)) != null,
            .meta_variable_exists => (try self.lookupVisibleVariable(scope, normalized)) != null or
                self.unprefixedMathConstant(normalized) != null,
            .meta_global_variable_exists => if (module) |kind|
                kind == .math and mathModuleConstant(normalized) != null
            else
                (try self.environment.lookup(self.global_scope, normalized)) != null or
                    self.unprefixedMathConstant(normalized) != null,
            else => unreachable,
        };
        return self.values.own(.{ .boolean = exists });
    }

    fn metaExistenceString(
        self: *Engine,
        item: native_value.Value,
        label: []const u8,
        span: native_source.Span,
    ) Error!native_value.String {
        return switch (item) {
            .string => |string| string,
            else => {
                const message = if (std.mem.eql(u8, label, "module"))
                    "native Sass meta existence module must be null or a string namespace"
                else
                    "native Sass meta existence name must be a string";
                try self.report(.type_mismatch, span, message);
                return error.InvalidExpression;
            },
        };
    }

    fn metaExistenceModule(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!?BuiltinModule {
        if (item == .null_value) return null;
        const module_string = try self.metaExistenceString(item, "module", span);
        const namespace = native_string.decodeAlloc(
            self.allocator,
            module_string.bytes,
            module_string.quoted,
            self.limits.max_temporary_bytes,
        ) catch |err| return self.stringFailure(err, span);
        defer self.allocator.free(namespace);
        for (self.modules.items) |binding| {
            try self.transaction.consumeOperations(1);
            const loaded = binding.namespace orelse continue;
            if (std.mem.eql(u8, loaded, namespace)) return binding.kind;
        }
        try self.report(.invalid_operation, span, "Sass module namespace is not loaded");
        return error.InvalidExpression;
    }

    fn normalizeMetaExistenceName(
        self: *Engine,
        raw_name: []const u8,
        span: native_source.Span,
    ) Error!?[]u8 {
        if (raw_name.len > self.limits.max_temporary_bytes) {
            try self.report(.resource_limit, span, "native Sass meta existence name limit exceeded");
            return error.TemporaryLimitExceeded;
        }
        if (!isSimpleIdentifier(raw_name)) return null;
        const normalized = try self.allocator.dupe(u8, raw_name);
        for (normalized) |*byte| {
            if (byte.* == '_') byte.* = '-';
        }
        return normalized;
    }

    fn metaGlobalFunctionExists(
        self: *Engine,
        name: []const u8,
        scope: native_environment.ScopeId,
    ) Error!bool {
        if (std.mem.eql(u8, name, "if") or
            (try self.lookupUserFunction(name, scope)) != null or
            globalCallableBuiltin(name) != null)
        {
            return true;
        }
        for (self.modules.items) |binding| {
            try self.transaction.consumeOperations(1);
            if (binding.namespace != null) continue;
            if (moduleBuiltin(binding.kind, name) != null) return true;
        }
        return false;
    }

    fn callMetaInspect(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 1) {
            try self.report(.invalid_operation, span, "meta.inspect() requires exactly one argument");
            return error.InvalidExpression;
        }
        var rendered: std.ArrayList(u8) = .empty;
        defer rendered.deinit(self.allocator);
        self.appendInspectedValue(&rendered, arguments[0].*, .root) catch |err| switch (err) {
            error.InvalidExpression => {
                try self.report(.type_mismatch, span, "native Sass callable reference is invalid");
                return error.InvalidExpression;
            },
            else => return err,
        };
        return self.values.own(.{ .string = .{ .bytes = rendered.items } });
    }

    fn callMetaTypeOf(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 1) {
            try self.report(.invalid_operation, span, "meta.type-of() requires exactly one argument");
            return error.InvalidExpression;
        }
        const name: []const u8 = switch (arguments[0].*) {
            .null_value => "null",
            .boolean => "bool",
            .number => "number",
            .color => "color",
            .string => |string| if (!string.quoted and isSassCalculationValue(string.bytes))
                "calculation"
            else
                "string",
            .selector, .list => "list",
            .map => "map",
            .argument_list => "arglist",
            .callable => |callable| switch (callable.kind) {
                .builtin_mixin, .mixin => "mixin",
                .builtin_function, .user_function => "function",
            },
        };
        return self.values.own(.{ .string = .{ .bytes = name } });
    }

    fn callSelectorParse(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 1) {
            try self.report(.invalid_operation, span, "selector.parse() requires exactly one argument");
            return error.InvalidExpression;
        }
        const input = try self.selectorInput(arguments[0].*, span);
        defer self.allocator.free(input);
        var parsed = try self.parseSelectorValue(input, false, span);
        defer parsed.deinit();
        return self.ownSelectorValues(&parsed, true, span);
    }

    fn callSelectorIsSuperselector(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 2) {
            try self.report(
                .invalid_operation,
                span,
                "selector.is-superselector() requires exactly two arguments",
            );
            return error.InvalidExpression;
        }
        const super_input = try self.selectorInput(arguments[0].*, span);
        defer self.allocator.free(super_input);
        const sub_input = try self.selectorInput(arguments[1].*, span);
        defer self.allocator.free(sub_input);
        const input_bytes = std.math.add(usize, super_input.len, sub_input.len) catch
            return self.selectorTemporaryFailure(span);
        if (input_bytes >= self.limits.max_temporary_bytes) {
            return self.selectorTemporaryFailure(span);
        }
        const relation_operations = std.math.mul(
            u64,
            @as(u64, @intCast(super_input.len + 1)),
            @as(u64, @intCast(sub_input.len + 1)),
        ) catch {
            try self.transaction.consumeOperations(std.math.maxInt(u64));
            unreachable;
        };
        try self.transaction.consumeOperations(relation_operations);
        const remaining_temporary = self.limits.max_temporary_bytes - input_bytes;
        const relation_limits = native_selector.Limits{
            .max_selectors = self.limits.max_selectors -| self.selector_count,
            .max_bytes = @min(
                self.limits.max_selector_bytes -| self.selector_bytes,
                remaining_temporary,
            ),
            .max_complex_components = self.limits.max_selectors -| self.selector_count,
            .max_temporary_bytes = remaining_temporary,
            .max_relation_operations = relation_operations,
        };
        const is_superselector = native_selector.isSuperselector(
            self.allocator,
            super_input,
            sub_input,
            relation_limits,
        ) catch |err| switch (err) {
            error.InvalidSelector => {
                try self.report(.invalid_operation, span, "invalid native Sass selector relation");
                return error.InvalidExpression;
            },
            error.UnsupportedSelectorRelation => {
                try self.report(
                    .invalid_operation,
                    span,
                    "native Sass selector relation semantics are not yet available for this selector",
                );
                return error.UnsupportedFeature;
            },
            error.SelectorLimitExceeded => {
                try self.report(.resource_limit, span, "native Sass selector relation limit exceeded");
                return err;
            },
            else => return err,
        };
        return self.values.own(.{ .boolean = is_superselector });
    }

    fn callSelectorExtension(
        self: *Engine,
        builtin: Builtin,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 3) {
            try self.report(
                .invalid_operation,
                span,
                "selector.extend()/replace() requires exactly three arguments",
            );
            return error.InvalidExpression;
        }
        const selector_input = try self.selectorInput(arguments[0].*, span);
        defer self.allocator.free(selector_input);
        const extendee_input = try self.selectorInput(arguments[1].*, span);
        defer self.allocator.free(extendee_input);
        const extender_input = try self.selectorInput(arguments[2].*, span);
        defer self.allocator.free(extender_input);
        const first_input_bytes = std.math.add(
            usize,
            selector_input.len,
            extendee_input.len,
        ) catch return self.selectorTemporaryFailure(span);
        const input_bytes = std.math.add(
            usize,
            first_input_bytes,
            extender_input.len,
        ) catch return self.selectorTemporaryFailure(span);
        if (input_bytes >= self.limits.max_temporary_bytes) {
            return self.selectorTemporaryFailure(span);
        }
        const remaining_selectors = self.limits.max_selectors -| self.selector_count;
        const extension_operations = selectorExtensionOperationBudget(
            selector_input,
            extendee_input,
            extender_input,
            remaining_selectors,
            builtin == .selector_extend,
        ) orelse {
            try self.transaction.consumeOperations(std.math.maxInt(u64));
            unreachable;
        };
        try self.transaction.consumeOperations(extension_operations);
        const remaining_temporary = self.limits.max_temporary_bytes - input_bytes;
        const extension_limits = native_selector.Limits{
            .max_selectors = remaining_selectors,
            .max_bytes = @min(
                self.limits.max_selector_bytes -| self.selector_bytes,
                remaining_temporary,
            ),
            .max_complex_components = remaining_selectors,
            .max_temporary_bytes = remaining_temporary,
            .max_relation_operations = extension_operations,
        };
        const native_result = switch (builtin) {
            .selector_extend => native_selector.extend(
                self.allocator,
                selector_input,
                extendee_input,
                extender_input,
                extension_limits,
            ),
            .selector_replace => native_selector.replace(
                self.allocator,
                selector_input,
                extendee_input,
                extender_input,
                extension_limits,
            ),
            else => unreachable,
        };
        var extended = native_result catch |err| switch (err) {
            error.InvalidSelector => {
                try self.report(.invalid_operation, span, "invalid native Sass selector extension");
                return error.InvalidExpression;
            },
            error.UnsupportedSelectorExtension => {
                try self.report(
                    .invalid_operation,
                    span,
                    "native Sass selector extension semantics are not yet available for this selector",
                );
                return error.UnsupportedFeature;
            },
            error.SelectorLimitExceeded => {
                try self.report(.resource_limit, span, "native Sass selector extension limit exceeded");
                return err;
            },
            else => return err,
        };
        defer extended.deinit();
        return self.ownSelectorValues(&extended, true, span);
    }

    fn callSelectorUnify(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 2) {
            try self.report(
                .invalid_operation,
                span,
                "selector.unify() requires exactly two arguments",
            );
            return error.InvalidExpression;
        }
        const left_input = try self.selectorInput(arguments[0].*, span);
        defer self.allocator.free(left_input);
        const right_input = try self.selectorInput(arguments[1].*, span);
        defer self.allocator.free(right_input);
        const input_bytes = std.math.add(usize, left_input.len, right_input.len) catch
            return self.selectorTemporaryFailure(span);
        if (input_bytes >= self.limits.max_temporary_bytes) {
            return self.selectorTemporaryFailure(span);
        }
        const unify_operations = selectorUnifyOperationBudget(
            left_input,
            right_input,
        ) orelse {
            try self.transaction.consumeOperations(std.math.maxInt(u64));
            unreachable;
        };
        try self.transaction.consumeOperations(unify_operations);
        const remaining_temporary = self.limits.max_temporary_bytes - input_bytes;
        const unify_limits = native_selector.Limits{
            .max_selectors = self.limits.max_selectors -| self.selector_count,
            .max_bytes = @min(
                self.limits.max_selector_bytes -| self.selector_bytes,
                remaining_temporary,
            ),
            .max_complex_components = self.limits.max_selectors -| self.selector_count,
            .max_temporary_bytes = remaining_temporary,
            .max_relation_operations = unify_operations,
        };
        const native_result = native_selector.unify(
            self.allocator,
            left_input,
            right_input,
            unify_limits,
        ) catch |err| switch (err) {
            error.InvalidSelector => {
                try self.report(.invalid_operation, span, "invalid native Sass selector unification");
                return error.InvalidExpression;
            },
            error.UnsupportedSelectorUnification => {
                try self.report(
                    .invalid_operation,
                    span,
                    "native Sass selector unification semantics are not yet available for this selector",
                );
                return error.UnsupportedFeature;
            },
            error.SelectorLimitExceeded => {
                try self.report(.resource_limit, span, "native Sass selector unification limit exceeded");
                return err;
            },
            else => return err,
        };
        var unified = native_result orelse
            return self.values.own(.{ .null_value = {} });
        defer unified.deinit();
        return self.ownSelectorValues(&unified, true, span);
    }

    fn callSelectorCompositionRaw(
        self: *Engine,
        builtin: Builtin,
        body: []const u8,
        ranges: []const ExpressionRange,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var evaluated = try self.evaluateCallArguments(body, ranges, scope, span);
        defer evaluated.deinit();
        return self.callSelectorComposition(builtin, &evaluated, span);
    }

    fn callSelectorComposition(
        self: *Engine,
        builtin: Builtin,
        arguments: *const EvaluatedCallArguments,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.keywords.items.len != 0) {
            try self.report(
                .invalid_operation,
                span,
                "variadic native Sass selector functions do not accept keyword arguments",
            );
            return error.InvalidExpression;
        }
        const positional = arguments.positional.items;
        if (positional.len == 0) {
            try self.report(
                .invalid_operation,
                span,
                "native Sass selector composition requires an argument",
            );
            return error.InvalidExpression;
        }

        const pointer_bytes = std.math.mul(
            usize,
            positional.len,
            @sizeOf([]const u8),
        ) catch return self.selectorTemporaryFailure(span);
        if (pointer_bytes > self.limits.max_temporary_bytes) {
            return self.selectorTemporaryFailure(span);
        }
        const inputs = try self.allocator.alloc([]const u8, positional.len);
        var input_count: usize = 0;
        defer {
            for (inputs[0..input_count]) |input| self.allocator.free(input);
            self.allocator.free(inputs);
        }
        var temporary_bytes = pointer_bytes;
        for (positional) |argument| {
            const input = try self.selectorInput(argument.*, span);
            const next = std.math.add(usize, temporary_bytes, input.len) catch {
                self.allocator.free(input);
                return self.selectorTemporaryFailure(span);
            };
            if (next > self.limits.max_temporary_bytes) {
                self.allocator.free(input);
                return self.selectorTemporaryFailure(span);
            }
            inputs[input_count] = input;
            input_count += 1;
            temporary_bytes = next;
            try self.transaction.consumeOperations(1);
        }

        const composition_bytes = self.limits.max_temporary_bytes - temporary_bytes;
        if (composition_bytes == 0) return self.selectorTemporaryFailure(span);
        const limits = native_selector.Limits{
            .max_selectors = self.limits.max_selectors -| self.selector_count,
            .max_bytes = @min(
                self.limits.max_selector_bytes -| self.selector_bytes,
                composition_bytes,
            ),
        };
        const native_result = switch (builtin) {
            .selector_append => native_selector.append(self.allocator, inputs, limits),
            .selector_nest => native_selector.nest(self.allocator, inputs, limits),
            else => unreachable,
        };
        var composed = native_result catch |err| switch (err) {
            error.InvalidSelector => {
                try self.report(.invalid_operation, span, "invalid native Sass selector composition");
                return error.InvalidExpression;
            },
            error.SelectorLimitExceeded => {
                try self.report(.resource_limit, span, "native Sass selector composition limit exceeded");
                return err;
            },
            else => return err,
        };
        defer composed.deinit();
        return self.ownSelectorValues(&composed, true, span);
    }

    fn callSelectorSimpleSelectors(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 1) {
            try self.report(
                .invalid_operation,
                span,
                "selector.simple-selectors() requires exactly one argument",
            );
            return error.InvalidExpression;
        }
        const input = try self.selectorInput(arguments[0].*, span);
        defer self.allocator.free(input);
        var parsed = try self.parseSelectorValue(input, true, span);
        defer parsed.deinit();
        return self.ownSelectorValues(&parsed, false, span);
    }

    fn selectorInput(
        self: *Engine,
        value: native_value.Value,
        span: native_source.Span,
    ) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        self.appendSelectorInput(&output, value, span) catch |err| switch (err) {
            error.TemporaryLimitExceeded => {
                try self.report(.resource_limit, span, "native Sass selector temporary limit exceeded");
                return err;
            },
            else => return err,
        };
        return output.toOwnedSlice(self.allocator);
    }

    fn appendSelectorInput(
        self: *Engine,
        output: *std.ArrayList(u8),
        value: native_value.Value,
        span: native_source.Span,
    ) Error!void {
        switch (value) {
            .string => |string| try self.appendSelectorString(output, string, span),
            .selector => |selector| try self.appendTemporary(output, selector.bytes),
            .list => |list| {
                if (list.items.len == 0 or list.separator == .slash or
                    list.separator == .legacy_slash)
                {
                    return self.invalidSelectorInput(span);
                }
                switch (list.separator) {
                    .comma => for (list.items, 0..) |item, index| {
                        if (index > 0) try self.appendTemporary(output, ", ");
                        switch (item) {
                            .string => |string| try self.appendSelectorString(output, string, span),
                            .selector => |selector| try self.appendTemporary(output, selector.bytes),
                            .list => |compound| {
                                if (compound.separator != .space and
                                    compound.separator != .undecided)
                                {
                                    return self.invalidSelectorInput(span);
                                }
                                try self.appendSelectorCompoundInput(output, compound, span);
                            },
                            else => return self.invalidSelectorInput(span),
                        }
                        try self.transaction.consumeOperations(1);
                    },
                    .space, .undecided => try self.appendSelectorCompoundInput(output, list, span),
                    .slash, .legacy_slash => unreachable,
                }
            },
            else => return self.invalidSelectorInput(span),
        }
    }

    fn appendSelectorCompoundInput(
        self: *Engine,
        output: *std.ArrayList(u8),
        list: native_value.List,
        span: native_source.Span,
    ) Error!void {
        if (list.items.len == 0) return self.invalidSelectorInput(span);
        for (list.items, 0..) |item, index| {
            if (index > 0) try self.appendTemporary(output, " ");
            switch (item) {
                .string => |string| try self.appendSelectorString(output, string, span),
                .selector => |selector| try self.appendTemporary(output, selector.bytes),
                else => return self.invalidSelectorInput(span),
            }
            try self.transaction.consumeOperations(1);
        }
    }

    fn appendSelectorString(
        self: *Engine,
        output: *std.ArrayList(u8),
        string: native_value.String,
        span: native_source.Span,
    ) Error!void {
        const decoded = native_string.decodeAlloc(
            self.allocator,
            string.bytes,
            string.quoted,
            self.limits.max_temporary_bytes,
        ) catch |err| switch (err) {
            error.InvalidString => return self.invalidSelectorInput(span),
            error.OutputLimitExceeded => return self.selectorTemporaryFailure(span),
            else => return err,
        };
        defer self.allocator.free(decoded);
        try self.appendTemporary(output, decoded);
    }

    fn invalidSelectorInput(self: *Engine, span: native_source.Span) Error {
        self.report(
            .type_mismatch,
            span,
            "native Sass selector value must be a nonempty string or compatible string list",
        ) catch |err| return err;
        return error.InvalidExpression;
    }

    fn parseSelectorValue(
        self: *Engine,
        input: []const u8,
        simple: bool,
        span: native_source.Span,
    ) Error!native_selector.SelectorList {
        const limits = native_selector.Limits{
            .max_selectors = self.limits.max_selectors -| self.selector_count,
            .max_bytes = @min(
                self.limits.max_selector_bytes -| self.selector_bytes,
                self.limits.max_temporary_bytes,
            ),
        };
        const result = if (simple)
            native_selector.simpleSelectors(self.allocator, input, limits)
        else
            native_selector.parse(self.allocator, input, limits);
        return result catch |err| switch (err) {
            error.InvalidSelector => {
                try self.report(.invalid_operation, span, "invalid native Sass selector value");
                return error.InvalidExpression;
            },
            error.SelectorLimitExceeded => {
                try self.report(.resource_limit, span, "native Sass selector value limit exceeded");
                return err;
            },
            else => return err,
        };
    }

    fn ownSelectorValues(
        self: *Engine,
        parsed: *const native_selector.SelectorList,
        selector_values: bool,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const temporary_bytes = std.math.mul(
            usize,
            parsed.items.len,
            @sizeOf(native_value.Value),
        ) catch return self.selectorTemporaryFailure(span);
        if (temporary_bytes > self.limits.max_temporary_bytes) {
            return self.selectorTemporaryFailure(span);
        }
        const values = try self.allocator.alloc(native_value.Value, parsed.items.len);
        defer self.allocator.free(values);
        try self.admitSelectorValueCount(parsed.items.len, span);
        for (parsed.items, 0..) |bytes, index| {
            try self.transaction.consumeOperations(1);
            try self.admitSelectorBytes(bytes.len, span);
            values[index] = if (selector_values)
                .{ .selector = .{ .bytes = bytes } }
            else
                .{ .string = .{ .bytes = bytes } };
        }
        return self.values.own(.{ .list = .{
            .items = values,
            .separator = .comma,
        } });
    }

    fn admitSelectorValueCount(
        self: *Engine,
        count: usize,
        span: native_source.Span,
    ) Error!void {
        const next = std.math.add(usize, self.selector_count, count) catch {
            try self.report(.resource_limit, span, "native Sass selector limit exceeded");
            return error.SelectorLimitExceeded;
        };
        if (next > self.limits.max_selectors) {
            try self.report(.resource_limit, span, "native Sass selector limit exceeded");
            return error.SelectorLimitExceeded;
        }
        self.selector_count = next;
    }

    fn selectorTemporaryFailure(
        self: *Engine,
        span: native_source.Span,
    ) Error {
        self.report(.resource_limit, span, "native Sass selector temporary limit exceeded") catch |err| return err;
        return error.TemporaryLimitExceeded;
    }

    fn callMetaKeywords(
        self: *Engine,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        if (arguments.len != 1) {
            try self.report(.invalid_operation, span, "meta.keywords() requires one argument list");
            return error.InvalidExpression;
        }
        const argument_list = switch (arguments[0].*) {
            .argument_list => |item| item,
            else => {
                try self.report(.type_mismatch, span, "meta.keywords() requires an argument list");
                return error.InvalidExpression;
            },
        };
        argument_list.state.keywords_accessed = true;

        var entries: std.ArrayList(native_value.Entry) = .empty;
        defer entries.deinit(self.allocator);
        var normalized_names: std.ArrayList([]u8) = .empty;
        defer {
            for (normalized_names.items) |name| self.allocator.free(name);
            normalized_names.deinit(self.allocator);
        }
        var normalized_bytes: usize = 0;
        for (argument_list.keywords) |keyword| {
            const name = if (keyword.normalize_name) blk: {
                normalized_bytes = std.math.add(
                    usize,
                    normalized_bytes,
                    keyword.name.len,
                ) catch {
                    try self.report(.resource_limit, span, "native Sass temporary limit exceeded");
                    return error.TemporaryLimitExceeded;
                };
                if (normalized_bytes > self.limits.max_temporary_bytes) {
                    try self.report(.resource_limit, span, "native Sass temporary limit exceeded");
                    return error.TemporaryLimitExceeded;
                }
                const normalized = try self.normalizeCallableName(keyword.name);
                normalized_names.append(self.allocator, normalized) catch |err| {
                    self.allocator.free(normalized);
                    return err;
                };
                break :blk normalized;
            } else keyword.name;
            try entries.append(self.allocator, .{
                .key = .{ .string = .{ .bytes = name } },
                .value = keyword.value,
            });
        }
        return self.values.own(.{ .map = .{ .entries = entries.items } });
    }

    fn callStringBuiltin(
        self: *Engine,
        builtin: Builtin,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        switch (builtin) {
            .quote, .unquote => {
                if (arguments.len != 1) {
                    try self.report(.invalid_operation, span, "quote functions require exactly one string");
                    return error.InvalidExpression;
                }
                const string = try self.stringArgument(arguments[0].*, span);
                if (!string.quoted and
                    isSassCalculationValue(string.bytes))
                {
                    try self.report(
                        .type_mismatch,
                        span,
                        "native Sass string function requires a string",
                    );
                    return error.InvalidExpression;
                }
                const quoted = builtin == .quote;
                const bytes = native_string.reencodeAlloc(
                    self.allocator,
                    string.bytes,
                    string.quoted,
                    quoted,
                    self.limits.max_temporary_bytes,
                ) catch |err| return self.stringFailure(err, span);
                defer self.allocator.free(bytes);
                return self.values.own(.{ .string = .{
                    .bytes = bytes,
                    .quoted = quoted,
                } });
            },
            .str_length => {
                if (arguments.len != 1) {
                    try self.report(.invalid_operation, span, "str-length() requires exactly one string");
                    return error.InvalidExpression;
                }
                const string = try self.stringArgument(arguments[0].*, span);
                if (!string.quoted and isSassCalculationValue(string.bytes)) {
                    try self.report(
                        .type_mismatch,
                        span,
                        "native Sass string function requires a string",
                    );
                    return error.InvalidExpression;
                }
                const count = native_string.length(
                    self.allocator,
                    string.bytes,
                    string.quoted,
                    self.limits.max_temporary_bytes,
                ) catch |err| return self.stringFailure(err, span);
                return self.values.own(.{ .number = .{ .value = @floatFromInt(count) } });
            },
            .str_index => {
                if (arguments.len != 2) {
                    try self.report(.invalid_operation, span, "str-index() requires two strings");
                    return error.InvalidExpression;
                }
                const string = try self.stringArgument(arguments[0].*, span);
                const needle = try self.stringArgument(arguments[1].*, span);
                if ((!string.quoted and isSassCalculationValue(string.bytes)) or
                    (!needle.quoted and isSassCalculationValue(needle.bytes)))
                {
                    try self.report(
                        .type_mismatch,
                        span,
                        "native Sass string function requires a string",
                    );
                    return error.InvalidExpression;
                }
                const index = native_string.indexOf(
                    self.allocator,
                    string.bytes,
                    string.quoted,
                    needle.bytes,
                    needle.quoted,
                    self.limits.max_temporary_bytes,
                ) catch |err| return self.stringFailure(err, span);
                return if (index) |found|
                    self.values.own(.{ .number = .{ .value = @floatFromInt(found) } })
                else
                    self.values.own(.{ .null_value = {} });
            },
            .str_slice => {
                if (arguments.len != 2 and arguments.len != 3) {
                    try self.report(.invalid_operation, span, "str-slice() requires a string and one or two indexes");
                    return error.InvalidExpression;
                }
                const string = try self.stringArgument(arguments[0].*, span);
                if (!string.quoted and isSassCalculationValue(string.bytes)) {
                    try self.report(
                        .type_mismatch,
                        span,
                        "native Sass string function requires a string",
                    );
                    return error.InvalidExpression;
                }
                const start = try self.stringIndex(arguments[1].*, span);
                const end = if (arguments.len == 3)
                    try self.stringIndex(arguments[2].*, span)
                else
                    null;
                const bytes = native_string.sliceAlloc(
                    self.allocator,
                    string.bytes,
                    string.quoted,
                    start,
                    end,
                    self.limits.max_temporary_bytes,
                ) catch |err| return self.stringFailure(err, span);
                defer self.allocator.free(bytes);
                return self.values.own(.{ .string = .{
                    .bytes = bytes,
                    .quoted = string.quoted,
                } });
            },
            .str_insert => {
                if (arguments.len != 3) {
                    try self.report(.invalid_operation, span, "str-insert() requires two strings and an index");
                    return error.InvalidExpression;
                }
                const string = try self.stringArgument(arguments[0].*, span);
                const inserted = try self.stringArgument(arguments[1].*, span);
                if ((!string.quoted and isSassCalculationValue(string.bytes)) or
                    (!inserted.quoted and isSassCalculationValue(inserted.bytes)))
                {
                    try self.report(
                        .type_mismatch,
                        span,
                        "native Sass string function requires a string",
                    );
                    return error.InvalidExpression;
                }
                const index = try self.stringIndex(arguments[2].*, span);
                const bytes = native_string.insertAlloc(
                    self.allocator,
                    string.bytes,
                    string.quoted,
                    inserted.bytes,
                    inserted.quoted,
                    index,
                    self.limits.max_temporary_bytes,
                ) catch |err| return self.stringFailure(err, span);
                defer self.allocator.free(bytes);
                return self.values.own(.{ .string = .{
                    .bytes = bytes,
                    .quoted = string.quoted,
                } });
            },
            .to_upper_case, .to_lower_case => {
                if (arguments.len != 1) {
                    try self.report(.invalid_operation, span, "case conversion requires exactly one string");
                    return error.InvalidExpression;
                }
                const string = try self.stringArgument(arguments[0].*, span);
                if (!string.quoted and isSassCalculationValue(string.bytes)) {
                    try self.report(
                        .type_mismatch,
                        span,
                        "native Sass string function requires a string",
                    );
                    return error.InvalidExpression;
                }
                const bytes = native_string.changeCaseAlloc(
                    self.allocator,
                    string.bytes,
                    string.quoted,
                    if (builtin == .to_upper_case) .upper else .lower,
                    self.limits.max_temporary_bytes,
                ) catch |err| return self.stringFailure(err, span);
                defer self.allocator.free(bytes);
                return self.values.own(.{ .string = .{
                    .bytes = bytes,
                    .quoted = string.quoted,
                } });
            },
            else => unreachable,
        }
    }

    fn callStringBuiltinRaw(
        self: *Engine,
        builtin: Builtin,
        body: []const u8,
        ranges: []const ExpressionRange,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const parameters: []const native_arguments.Parameter = switch (builtin) {
            .quote, .unquote, .str_length, .to_upper_case, .to_lower_case => &.{
                .{ .name = "string" },
            },
            .str_index => &.{
                .{ .name = "string" },
                .{ .name = "substring" },
            },
            .str_slice => &.{
                .{ .name = "string" },
                .{ .name = "start-at" },
                .{ .name = "end-at", .required = false },
            },
            .str_insert => &.{
                .{ .name = "string" },
                .{ .name = "insert" },
                .{ .name = "index" },
            },
            else => unreachable,
        };
        var parsed = native_arguments.parseAlloc(
            self.allocator,
            body,
            ranges,
            self.limits.max_function_arguments,
        ) catch |err| return self.argumentsFailure(err, span);
        defer parsed.deinit();
        var bound = native_arguments.bindAlloc(
            self.allocator,
            parsed.items,
            parameters,
            parameters.len,
        ) catch |err| return self.argumentsFailure(err, span);
        defer bound.deinit();

        var evaluated: [3]*const native_value.Value = undefined;
        for (parsed.items, 0..) |argument, index| {
            evaluated[index] = try self.evaluateExpressionBytes(
                body[argument.value.start..argument.value.end],
                scope,
                span,
            );
        }

        var arguments: [3]*const native_value.Value = undefined;
        var count: usize = 0;
        for (bound.values, 0..) |value_range, parameter_index| {
            const range = value_range orelse continue;
            for (parsed.items, 0..) |argument, argument_index| {
                if (argument.value.start != range.start or argument.value.end != range.end) continue;
                arguments[parameter_index] = evaluated[argument_index];
                count = parameter_index + 1;
                break;
            }
        }
        return self.callStringBuiltin(builtin, arguments[0..count], span);
    }

    fn callMathVariadicRaw(
        self: *Engine,
        builtin: Builtin,
        module_owned: bool,
        raw: []const u8,
        body: []const u8,
        ranges: []const ExpressionRange,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var evaluated = try self.evaluateCallArguments(body, ranges, scope, span);
        defer evaluated.deinit();
        if (evaluated.keywords.items.len != 0) {
            try self.report(.invalid_operation, span, "variadic native Sass math functions do not accept keyword arguments");
            return error.InvalidExpression;
        }
        const arguments = evaluated.positional.items;
        if (arguments.len == 0) {
            try self.report(.invalid_operation, span, "variadic native Sass math function requires an argument");
            return error.InvalidExpression;
        }

        if (!module_owned) {
            var preserve_css = false;
            var valid_css_calculation = true;
            for (arguments) |argument| {
                switch (argument.*) {
                    .number => {},
                    .string, .selector => |string| {
                        if (string.quoted) {
                            valid_css_calculation = false;
                        } else {
                            preserve_css = true;
                        }
                    },
                    else => valid_css_calculation = false,
                }
            }
            if (valid_css_calculation) {
                if (try self.preserveGlobalHypotIfNeeded(raw, arguments, span)) |value| {
                    return value;
                }
                if (preserve_css) return self.preserveEvaluatedFunction(raw, arguments, span);
            }
        }

        return switch (builtin) {
            .math_min, .math_max => self.callMathExtremum(builtin, arguments, span),
            .math_hypot => self.callMathHypot(arguments, span),
            else => unreachable,
        };
    }

    fn callMathRandomRaw(
        self: *Engine,
        body: []const u8,
        ranges: []const ExpressionRange,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        var evaluated = try self.evaluateCallArguments(body, ranges, scope, span);
        defer evaluated.deinit();
        if (evaluated.positional.items.len > 1) {
            return self.argumentsFailure(error.PositionalLimitExceeded, span);
        }

        var limit: ?*const native_value.Value = if (evaluated.positional.items.len == 1)
            evaluated.positional.items[0]
        else
            null;
        for (evaluated.keywords.items) |keyword| {
            const matches = if (keyword.normalize_name)
                native_arguments.nameEql(keyword.name, "limit")
            else
                std.mem.eql(u8, keyword.name, "limit");
            if (!matches) return self.argumentsFailure(error.UnknownArgument, span);
            if (limit != null) return self.argumentsFailure(error.DuplicateArgument, span);
            limit = keyword.value;
        }
        return self.callMathRandom(limit, span);
    }

    fn callMathRandom(
        self: *Engine,
        limit_value: ?*const native_value.Value,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const item = limit_value orelse return self.randomUnitValue();
        if (item.* == .null_value) return self.randomUnitValue();
        const number = try self.mathNumberArgument(item.*, span);
        if (!std.math.isFinite(number.value) or @floor(number.value) != number.value or
            number.value <= 0 or number.value > @as(f64, @floatFromInt(max_random_limit)))
        {
            try self.report(.invalid_operation, span, "math random() limit must be a positive 32-bit integer");
            return error.InvalidExpression;
        }
        if (number.numerator_units.len != 0 or number.denominator_units.len != 0) {
            try self.transaction.report(
                .warning,
                .invalid_operation,
                span,
                "math.random() currently ignores $limit units",
                &.{},
            );
        }
        const limit: u64 = @intFromFloat(number.value);
        const threshold = ((~limit) +% 1) % limit;
        while (true) {
            try self.transaction.consumeOperations(1);
            const candidate = self.nextRandomU64();
            if (candidate < threshold) continue;
            const selected = candidate % limit + 1;
            return self.values.own(.{ .number = .{ .value = @floatFromInt(selected) } });
        }
    }

    fn randomUnitValue(self: *Engine) Error!*const native_value.Value {
        try self.transaction.consumeOperations(1);
        const mantissa = self.nextRandomU64() >> 11;
        const value = @as(f64, @floatFromInt(mantissa)) * (1.0 / 9_007_199_254_740_992.0);
        return self.values.own(.{ .number = .{ .value = value } });
    }

    fn nextRandomU64(self: *Engine) u64 {
        // A fixed SplitMix64 stream makes the intrinsically nondeterministic
        // upstream Sass function reproducible for identical source bytes. This
        // is a build-reproducibility primitive, never a cryptographic RNG.
        self.random_state +%= 0x9e3779b97f4a7c15;
        var value = self.random_state;
        value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
        value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
        return value ^ (value >> 31);
    }

    fn preserveGlobalHypotIfNeeded(
        self: *Engine,
        raw: []const u8,
        arguments: []const *const native_value.Value,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        var target_number: ?native_value.Number = null;
        var target_numeric: ?Numeric = null;
        var preserve = false;
        for (arguments) |argument| {
            const number = switch (argument.*) {
                .number => |value| value,
                else => continue,
            };
            const numeric = native_numeric.Numeric.fromNumber(number) catch |err| {
                try self.report(
                    if (err == error.UnitLimitExceeded) .resource_limit else .invalid_operation,
                    span,
                    "invalid global Sass hypot() argument",
                );
                return err;
            };
            if (target_numeric) |target| {
                _ = native_numeric.convertValueToMatch(numeric, target) catch |err| switch (err) {
                    error.IncompatibleUnits => {
                        if (calculationDimensionsProvablyIncompatible(target_number.?, number)) {
                            try self.report(
                                .invalid_operation,
                                span,
                                "global Sass hypot() arguments have incompatible units",
                            );
                            return err;
                        }
                        preserve = true;
                    },
                    else => {
                        try self.report(.invalid_operation, span, "invalid global Sass hypot() argument");
                        return err;
                    },
                };
            } else {
                target_number = number;
                target_numeric = numeric;
            }
        }
        if (!preserve) return null;
        return try self.preserveEvaluatedFunction(raw, arguments, span);
    }

    fn callFixedBuiltinRaw(
        self: *Engine,
        builtin: Builtin,
        module_owned: bool,
        raw: []const u8,
        body: []const u8,
        ranges: []const ExpressionRange,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const parameters: []const native_arguments.Parameter = fixedListBuiltinParameters(builtin) orelse switch (builtin) {
            .map_keys, .map_values => &.{.{ .name = "map" }},
            .math_abs,
            .math_acos,
            .math_asin,
            .math_atan,
            .math_ceil,
            .math_cos,
            .math_floor,
            .math_percentage,
            .math_round,
            .math_sin,
            .math_tan,
            => &.{.{ .name = "number" }},
            .math_atan2 => &.{
                .{ .name = "y" },
                .{ .name = "x" },
            },
            .math_clamp => &.{
                .{ .name = "min" },
                .{ .name = "number" },
                .{ .name = "max" },
            },
            .math_div => &.{
                .{ .name = "number1" },
                .{ .name = "number2" },
            },
            .math_log => &.{
                .{ .name = "number" },
                .{ .name = "base", .required = false },
            },
            .math_pow => &.{
                .{ .name = "base" },
                .{ .name = "exponent" },
            },
            .math_sqrt => &.{.{ .name = "number" }},
            .math_compatible => &.{
                .{ .name = "number1" },
                .{ .name = "number2" },
            },
            .math_is_unitless => &.{.{ .name = "number" }},
            .math_unit => &.{.{ .name = "number" }},
            .meta_accepts_content => &.{.{ .name = "mixin" }},
            .meta_calc_args, .meta_calc_name => &.{.{ .name = "calc" }},
            .meta_content_exists => &.{},
            .meta_feature_exists => &.{.{ .name = "feature" }},
            .meta_function_exists,
            .meta_get_mixin,
            .meta_global_variable_exists,
            .meta_mixin_exists,
            => &.{
                .{ .name = "name" },
                .{ .name = "module", .required = false },
            },
            .meta_get_function => &.{
                .{ .name = "name" },
                .{ .name = "css", .required = false },
                .{ .name = "module", .required = false },
            },
            .meta_inspect, .meta_type_of => &.{.{ .name = "value" }},
            .meta_keywords => &.{.{ .name = "args" }},
            .meta_variable_exists => &.{.{ .name = "name" }},
            .selector_is_superselector => &.{
                .{ .name = "super" },
                .{ .name = "sub" },
            },
            .selector_extend, .selector_replace => &.{
                .{ .name = "selector" },
                .{ .name = "extendee" },
                .{ .name = "extender" },
            },
            .selector_unify => &.{
                .{ .name = "selector1" },
                .{ .name = "selector2" },
            },
            .selector_parse, .selector_simple_selectors => &.{.{ .name = "selector" }},
            .red,
            .green,
            .blue,
            .alpha,
            .opacity,
            .hue,
            .saturation,
            .lightness,
            .complement,
            .grayscale,
            .ie_hex_str,
            => &.{.{ .name = "color" }},
            .mix => &.{
                .{ .name = "color1" },
                .{ .name = "color2" },
                .{ .name = "weight", .required = false },
            },
            .saturate => &.{
                .{ .name = "color" },
                .{ .name = "amount", .required = false },
            },
            .lighten,
            .darken,
            .desaturate,
            .opacify,
            .fade_in,
            .transparentize,
            .fade_out,
            => &.{
                .{ .name = "color" },
                .{ .name = "amount" },
            },
            .adjust_hue => &.{
                .{ .name = "color" },
                .{ .name = "degrees" },
            },
            .invert => &.{
                .{ .name = "color" },
                .{ .name = "weight", .required = false },
            },
            else => unreachable,
        };
        var parsed = native_arguments.parseAlloc(
            self.allocator,
            body,
            ranges,
            self.limits.max_function_arguments,
        ) catch |err| return self.argumentsFailure(err, span);
        defer parsed.deinit();
        var has_keyword = false;
        for (parsed.items) |argument| {
            if (argument.name != null) {
                has_keyword = true;
                break;
            }
        }
        // The global name also owns CSS round() calculations with a step and
        // optional strategy. Preserve that existing deferred surface; the
        // sass:math function and its unprefixed import remain strictly unary.
        if (builtin == .math_round and !module_owned and !has_keyword and
            (parsed.items.len == 2 or parsed.items.len == 3))
        {
            return self.preserveColorFunction(raw, scope, span);
        }
        var bound = native_arguments.bindAlloc(
            self.allocator,
            parsed.items,
            parameters,
            parameters.len,
        ) catch |err| return self.argumentsFailure(err, span);
        defer bound.deinit();

        var evaluated: [4]*const native_value.Value = undefined;
        for (parsed.items, 0..) |argument, index| {
            const argument_raw = body[argument.value.start..argument.value.end];
            evaluated[index] = switch (builtin) {
                .math_abs,
                .math_acos,
                .math_asin,
                .math_atan,
                .math_atan2,
                .math_ceil,
                .math_clamp,
                .math_compatible,
                .math_cos,
                .math_div,
                .math_floor,
                .math_is_unitless,
                .math_log,
                .math_percentage,
                .math_pow,
                .math_round,
                .math_sin,
                .math_sqrt,
                .math_tan,
                .math_unit,
                => try self.evaluateMathNumericArgument(
                    argument_raw,
                    scope,
                    span,
                ),
                else => try self.evaluateExpressionBytes(argument_raw, scope, span),
            };
        }

        const automatic_list_option = native_value.Value{ .string = .{ .bytes = "auto" } };
        const false_option = native_value.Value{ .boolean = false };
        const null_option = native_value.Value{ .null_value = {} };
        var ordered: [4]*const native_value.Value = undefined;
        if (builtin == .list_join) {
            // `$bracketed` may be supplied by name while `$separator` is omitted.
            // Keep the bound argument slice dense so an omitted optional slot can
            // never expose undefined stack memory to the evaluator.
            ordered[2] = &automatic_list_option;
            ordered[3] = &automatic_list_option;
        } else if (builtin == .meta_get_function) {
            // `$module` may be supplied by name while `$css` is omitted.
            // Materialize both canonical defaults before filling bound slots.
            ordered[1] = &false_option;
            ordered[2] = &null_option;
        }
        var count: usize = 0;
        for (bound.values, 0..) |value_range, parameter_index| {
            const range = value_range orelse continue;
            for (parsed.items, 0..) |argument, argument_index| {
                if (argument.value.start != range.start or argument.value.end != range.end) continue;
                ordered[parameter_index] = evaluated[argument_index];
                count = parameter_index + 1;
                break;
            }
        }
        const arguments = ordered[0..count];
        // Global abs()/round() may defer an unquoted CSS calculation. Module
        // calls are always Sass numeric functions and reject the same value.
        if (!module_owned and !has_keyword and
            (builtin == .math_abs or builtin == .math_round) and
            arguments.len == 1 and arguments[0].* == .string and
            !arguments[0].string.quoted)
        {
            return self.preserveEvaluatedFunction(raw, arguments, span);
        }
        if (!module_owned and !has_keyword and
            (builtin == .math_acos or builtin == .math_asin or
                builtin == .math_atan or builtin == .math_atan2 or
                builtin == .math_cos or builtin == .math_log or
                builtin == .math_pow or builtin == .math_sin or
                builtin == .math_sqrt or builtin == .math_tan))
        {
            var preserve_css = false;
            var valid_css_calculation = true;
            for (arguments) |argument| {
                switch (argument.*) {
                    .number => {},
                    .string => |string| {
                        if (string.quoted) {
                            valid_css_calculation = false;
                        } else {
                            preserve_css = true;
                        }
                    },
                    else => valid_css_calculation = false,
                }
            }
            if (preserve_css and valid_css_calculation) {
                return self.preserveEvaluatedFunction(raw, arguments, span);
            }
        }
        const filter_conflict = builtin == .saturate or builtin == .grayscale or
            builtin == .invert or builtin == .opacity;
        if (has_keyword and filter_conflict and arguments.len == 1 and arguments[0].* != .color) {
            try self.report(
                .type_mismatch,
                span,
                "named Sass color-filter function requires a color",
            );
            return error.InvalidExpression;
        }
        return switch (builtin) {
            .nth => self.callNth(arguments, span),
            .length => self.callLength(arguments, span),
            .list_index => self.callListIndex(arguments, span),
            .list_separator => self.callListSeparator(arguments, span),
            .list_is_bracketed => self.callListIsBracketed(arguments, span),
            .list_append => self.callListAppend(arguments, span),
            .list_set_nth => self.callListSetNth(arguments, span),
            .list_join => self.callListJoin(arguments, span),
            .map_keys, .map_values => self.callMapEntries(builtin, arguments, span),
            .math_abs,
            .math_ceil,
            .math_floor,
            .math_percentage,
            .math_round,
            => self.callMathUnary(builtin, arguments, span),
            .math_div => self.callMathDiv(arguments, span),
            .math_log, .math_pow, .math_sqrt => self.callMathPower(
                builtin,
                arguments,
                span,
            ),
            .math_acos,
            .math_asin,
            .math_atan,
            .math_atan2,
            .math_cos,
            .math_sin,
            .math_tan,
            => self.callMathTrigonometric(builtin, arguments, span),
            .math_clamp => self.callMathClamp(arguments, span),
            .math_compatible, .math_is_unitless => self.callMathUnitPredicate(
                builtin,
                arguments,
                span,
            ),
            .math_unit => self.callMathUnit(arguments, span),
            .meta_accepts_content => self.callMetaAcceptsContent(arguments, span),
            .meta_calc_args => self.callMetaCalcArgs(arguments, scope, span),
            .meta_calc_name => self.callMetaCalcName(arguments, span),
            .meta_content_exists => self.callMetaContentExists(module_owned, span),
            .meta_get_function => self.callMetaGetFunction(
                module_owned,
                arguments,
                scope,
                span,
            ),
            .meta_get_mixin => self.callMetaGetMixin(
                module_owned,
                arguments,
                scope,
                span,
            ),
            .meta_feature_exists,
            .meta_function_exists,
            .meta_global_variable_exists,
            .meta_mixin_exists,
            .meta_variable_exists,
            => self.callMetaExistence(
                builtin,
                module_owned,
                arguments,
                scope,
                span,
            ),
            .meta_inspect => self.callMetaInspect(arguments, span),
            .meta_keywords => self.callMetaKeywords(arguments, span),
            .meta_type_of => self.callMetaTypeOf(arguments, span),
            .selector_extend, .selector_replace => self.callSelectorExtension(
                builtin,
                arguments,
                span,
            ),
            .selector_is_superselector => self.callSelectorIsSuperselector(arguments, span),
            .selector_unify => self.callSelectorUnify(arguments, span),
            .selector_parse => self.callSelectorParse(arguments, span),
            .selector_simple_selectors => self.callSelectorSimpleSelectors(arguments, span),
            .red, .green, .blue, .alpha, .hue, .saturation, .lightness => self.callColorChannel(
                builtin,
                arguments,
                span,
            ),
            .opacity => self.callColorOpacity(raw, arguments, scope, span),
            .ie_hex_str => self.callIeHexStr(arguments, span),
            .mix,
            .lighten,
            .darken,
            .saturate,
            .desaturate,
            .adjust_hue,
            .complement,
            .grayscale,
            .invert,
            .opacify,
            .fade_in,
            .transparentize,
            .fade_out,
            => self.callColorManipulation(builtin, raw, arguments, scope, span),
            else => unreachable,
        };
    }

    fn argumentsFailure(
        self: *Engine,
        failure: native_arguments.Error,
        span: native_source.Span,
    ) Error {
        const message: []const u8 = switch (failure) {
            error.ArgumentLimitExceeded => "native Sass function argument limit exceeded",
            error.DuplicateArgument => "duplicate native Sass keyword argument",
            error.InvalidArgument => "invalid native Sass function argument",
            error.InvalidLimits => "invalid native Sass argument binding limits",
            error.MissingArgument => "required native Sass function argument is missing",
            error.PositionalAfterKeyword => "positional Sass argument cannot follow a keyword argument",
            error.PositionalLimitExceeded => "native Sass function received too many positional arguments",
            error.SplatUnsupported => "Sass argument-list expansion is not supported by this native built-in yet",
            error.UnknownArgument => "unknown native Sass keyword argument",
            error.OutOfMemory => return error.OutOfMemory,
        };
        const kind: native_diagnostics.Code = switch (failure) {
            error.ArgumentLimitExceeded => .resource_limit,
            error.SplatUnsupported => .unsupported_feature,
            else => .invalid_operation,
        };
        self.report(kind, span, message) catch |err| return err;
        return switch (failure) {
            error.ArgumentLimitExceeded => error.FunctionArgumentLimitExceeded,
            error.InvalidLimits => error.InvalidLimits,
            error.SplatUnsupported => error.UnsupportedFeature,
            else => error.InvalidExpression,
        };
    }

    fn stringArgument(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!native_value.String {
        return switch (item) {
            .string => |string| string,
            else => {
                try self.report(.type_mismatch, span, "native Sass string function requires a string");
                return error.InvalidExpression;
            },
        };
    }

    fn stringIndex(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!i64 {
        const number = switch (item) {
            .number => |number| number,
            else => {
                try self.report(.type_mismatch, span, "native Sass string index must be a unitless integer");
                return error.InvalidExpression;
            },
        };
        if (number.numerator_units.len != 0 or number.denominator_units.len != 0 or
            !std.math.isFinite(number.value) or @floor(number.value) != number.value)
        {
            try self.report(.invalid_operation, span, "native Sass string index must be a unitless integer");
            return error.InvalidExpression;
        }
        // Native strings are bounded far below this threshold. Saturating larger
        // exact Sass integers preserves their required clamping behavior without
        // relying on an overflowing float-to-integer conversion.
        if (number.value > 2_147_483_647) return std.math.maxInt(i64);
        if (number.value < -2_147_483_647) return std.math.minInt(i64);
        return @intFromFloat(number.value);
    }

    fn stringFailure(
        self: *Engine,
        failure: native_string.Error,
        span: native_source.Span,
    ) Error {
        return switch (failure) {
            error.InvalidString => blk: {
                self.report(.syntax, span, "native Sass string contains an invalid escape or code point") catch |err| return err;
                break :blk error.InvalidExpression;
            },
            error.OutputLimitExceeded => blk: {
                self.report(.resource_limit, span, "native Sass string temporary limit exceeded") catch |err| return err;
                break :blk error.TemporaryLimitExceeded;
            },
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn resolveListIndex(
        self: *Engine,
        item: native_value.Value,
        length: usize,
        span: native_source.Span,
    ) Error!usize {
        const number = switch (item) {
            .number => |value| value,
            else => {
                try self.report(.type_mismatch, span, "Sass list index must be a unitless integer");
                return error.InvalidExpression;
            },
        };
        if (number.numerator_units.len != 0 or number.denominator_units.len != 0 or
            !std.math.isFinite(number.value) or @floor(number.value) != number.value or
            number.value == 0)
        {
            try self.report(.invalid_operation, span, "Sass list index must be a non-zero unitless integer");
            return error.InvalidExpression;
        }
        const maximum: f64 = @floatFromInt(length);
        if (number.value > maximum or number.value < -maximum) {
            try self.report(.invalid_operation, span, "Sass list index is outside the list");
            return error.InvalidExpression;
        }
        const magnitude: usize = @intFromFloat(@abs(number.value));
        return if (number.value > 0) magnitude - 1 else length - magnitude;
    }

    fn tryCollection(
        self: *Engine,
        raw: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        var body = raw;
        var parenthesized = false;
        var bracketed = false;
        if (fullyWrapped(raw, '(', ')')) {
            parenthesized = true;
            body = trimWhitespace(raw[1 .. raw.len - 1]);
        } else if (fullyWrapped(raw, '[', ']')) {
            bracketed = true;
            body = trimWhitespace(raw[1 .. raw.len - 1]);
        }

        if (parenthesized) {
            if (body.len == 0) {
                return try self.values.own(.{ .list = .{ .items = &.{} } });
            }
            if (try self.tryMap(body, scope, span)) |map| return map;
        } else if (bracketed and body.len == 0) {
            return try self.values.own(.{ .list = .{ .items = &.{}, .bracketed = true } });
        }

        const separators = [_]struct {
            split: SplitSeparator,
            value: native_value.Separator,
        }{
            .{ .split = .comma, .value = .comma },
            .{ .split = .slash, .value = .legacy_slash },
            .{ .split = .whitespace, .value = .space },
        };
        for (separators) |separator| {
            if (try self.trySeparatedList(body, scope, span, separator.split, separator.value, bracketed)) |list| {
                return list;
            }
        }

        if (bracketed) {
            const child = try self.evaluateExpressionBytes(body, scope, span);
            const items = [_]native_value.Value{child.*};
            return try self.values.ownCollectionWithSharedArgumentLists(.{ .list = .{
                .items = &items,
                .separator = .undecided,
                .bracketed = true,
            } });
        }
        if (parenthesized) return try self.evaluateExpressionBytes(body, scope, span);
        return null;
    }

    fn tryMap(
        self: *Engine,
        body: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!?*const native_value.Value {
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        _ = try splitTopLevelRanges(self.allocator, body, .comma, &ranges);
        if (ranges.items.len == 0) return null;
        const final = ranges.items[ranges.items.len - 1];
        if (trimWhitespace(body[final.start..final.end]).len == 0) ranges.items.len -= 1;
        if (ranges.items.len == 0) return null;
        if (findTopLevelByte(body[ranges.items[0].start..ranges.items[0].end], ':') == null) {
            return null;
        }

        var entries: std.ArrayList(native_value.Entry) = .empty;
        defer entries.deinit(self.allocator);
        for (ranges.items) |range| {
            const entry_raw = body[range.start..range.end];
            const colon = findTopLevelByte(entry_raw, ':') orelse {
                try self.report(.syntax, span, "every native Sass map entry requires a key and value");
                return error.InvalidExpression;
            };
            const key_raw = trimWhitespace(entry_raw[0..colon]);
            const value_raw = trimWhitespace(entry_raw[colon + 1 ..]);
            if (key_raw.len == 0 or value_raw.len == 0) {
                try self.report(.syntax, span, "native Sass map entry has an empty key or value");
                return error.InvalidExpression;
            }
            const key = try self.evaluateExpressionBytes(key_raw, scope, span);
            const value = try self.evaluateExpressionBytes(value_raw, scope, span);
            for (entries.items) |existing| {
                if (sassValuesEqual(existing.key, key.*)) {
                    try self.report(.duplicate_binding, span, "duplicate native Sass map key");
                    return error.InvalidExpression;
                }
            }
            try entries.append(self.allocator, .{ .key = key.*, .value = value.* });
        }
        return try self.values.ownCollectionWithSharedArgumentLists(.{
            .map = .{ .entries = entries.items },
        });
    }

    fn trySeparatedList(
        self: *Engine,
        body: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
        split: SplitSeparator,
        separator: native_value.Separator,
        bracketed: bool,
    ) Error!?*const native_value.Value {
        var ranges: std.ArrayList(ExpressionRange) = .empty;
        defer ranges.deinit(self.allocator);
        if (!try splitTopLevelRanges(self.allocator, body, split, &ranges)) return null;
        if (split == .comma and ranges.items.len > 0) {
            const final = ranges.items[ranges.items.len - 1];
            if (trimWhitespace(body[final.start..final.end]).len == 0) ranges.items.len -= 1;
        }
        if (ranges.items.len == 0) {
            try self.report(.syntax, span, "native Sass list is missing an item");
            return error.InvalidExpression;
        }

        var items: std.ArrayList(native_value.Value) = .empty;
        defer items.deinit(self.allocator);
        for (ranges.items) |range| {
            const item_raw = trimWhitespace(body[range.start..range.end]);
            if (item_raw.len == 0) {
                try self.report(.syntax, span, "native Sass list contains an empty item");
                return error.InvalidExpression;
            }
            const item = try self.evaluateExpressionBytes(item_raw, scope, span);
            try items.append(self.allocator, item.*);
        }
        return try self.values.ownCollectionWithSharedArgumentLists(.{
            .list = .{
                .items = items.items,
                .separator = separator,
                .bracketed = bracketed,
            },
        });
    }

    fn lookupVariable(
        self: *Engine,
        raw_name: []const u8,
        scope: native_environment.ScopeId,
        span: native_source.Span,
    ) Error!*const native_value.Value {
        const normalized = try self.normalizeVariable(raw_name);
        defer self.allocator.free(normalized);
        if (try self.lookupVisibleVariable(scope, normalized)) |item| return item;
        if (self.unprefixedMathConstant(normalized)) |constant| {
            return self.values.own(.{ .number = .{ .value = constant } });
        }
        try self.report(.undefined_variable, span, "undefined Sass variable");
        return error.UndefinedVariable;
    }

    fn unprefixedMathConstant(self: *const Engine, name: []const u8) ?f64 {
        for (self.modules.items) |binding| {
            if (binding.kind != .math or binding.namespace != null) continue;
            return mathModuleConstant(name);
        }
        return null;
    }

    fn lookupVisibleVariable(
        self: *Engine,
        scope: native_environment.ScopeId,
        normalized: []const u8,
    ) Error!?*const native_value.Value {
        if (try self.environment.lookupNonGlobal(scope, normalized)) |item| return item;
        return self.environment.lookup(self.global_scope, normalized);
    }

    fn normalizeVariable(self: *Engine, raw_name: []const u8) Error![]u8 {
        const name = if (raw_name.len > 0 and raw_name[0] == '$') raw_name[1..] else raw_name;
        if (name.len == 0) return error.InvalidSassSyntax;
        if (name.len > self.limits.max_temporary_bytes) return error.TemporaryLimitExceeded;
        const normalized = try self.allocator.dupe(u8, name);
        for (normalized) |*byte| {
            if (byte.* == '_') byte.* = '-';
        }
        return normalized;
    }

    fn buildSelectors(
        self: *Engine,
        span: native_source.Span,
        parents: ?*const SelectorList,
        scope: native_environment.ScopeId,
    ) Error!SelectorList {
        const rendered = try self.renderTemplate(span, scope, false);
        defer self.allocator.free(rendered);
        var children: std.ArrayList([]const u8) = .empty;
        defer children.deinit(self.allocator);
        try splitSelectors(self.allocator, rendered, &children);
        if (children.items.len == 0) {
            try self.report(.syntax, span, "empty Sass selector");
            return error.InvalidSassSyntax;
        }
        const parent_count = if (parents) |list| list.items.len else 1;
        var expansions_per_parent: usize = 0;
        for (children.items) |child| {
            const ampersands = replaceableAmpersandCount(child);
            const child_expansions = if (ampersands == 0)
                1
            else
                selectorPower(parent_count, ampersands - 1) catch {
                    try self.report(.resource_limit, span, "native Sass selector limit exceeded");
                    return error.SelectorLimitExceeded;
                };
            expansions_per_parent = std.math.add(
                usize,
                expansions_per_parent,
                child_expansions,
            ) catch {
                try self.report(.resource_limit, span, "native Sass selector limit exceeded");
                return error.SelectorLimitExceeded;
            };
        }
        const added_count = std.math.mul(usize, parent_count, expansions_per_parent) catch {
            try self.report(.resource_limit, span, "native Sass selector limit exceeded");
            return error.SelectorLimitExceeded;
        };
        const next_count = std.math.add(usize, self.selector_count, added_count) catch {
            try self.report(.resource_limit, span, "native Sass selector limit exceeded");
            return error.SelectorLimitExceeded;
        };
        if (next_count > self.limits.max_selectors) {
            try self.report(.resource_limit, span, "native Sass selector limit exceeded");
            return error.SelectorLimitExceeded;
        }

        var items: std.ArrayList([]u8) = .empty;
        errdefer {
            for (items.items) |item| self.allocator.free(item);
            items.deinit(self.allocator);
        }
        if (parents) |parent_list| {
            for (parent_list.items) |parent| {
                for (children.items) |child| {
                    const ampersands = replaceableAmpersandCount(child);
                    const expansion_count = if (ampersands == 0)
                        1
                    else
                        selectorPower(parent_list.items.len, ampersands - 1) catch unreachable;
                    for (0..expansion_count) |ordinal| {
                        const combined = try self.combineSelector(
                            parent_list,
                            parent,
                            child,
                            ampersands,
                            ordinal,
                            span,
                        );
                        errdefer self.allocator.free(combined);
                        try items.append(self.allocator, combined);
                    }
                }
            }
        } else {
            for (children.items) |child| {
                if (replaceableAmpersandCount(child) != 0) {
                    try self.report(.syntax, span, "top-level Sass selector contains '&'");
                    return error.InvalidSassSyntax;
                }
                const owned = try self.allocator.dupe(u8, child);
                try self.admitSelectorBytes(owned.len, span);
                errdefer self.allocator.free(owned);
                try items.append(self.allocator, owned);
            }
        }
        self.selector_count = next_count;
        return .{ .items = try items.toOwnedSlice(self.allocator) };
    }

    fn combineSelector(
        self: *Engine,
        parents: *const SelectorList,
        parent: []const u8,
        child: []const u8,
        ampersand_count: usize,
        ordinal: usize,
        span: native_source.Span,
    ) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        if (ampersand_count == 0) {
            try self.appendSelectorBytes(&output, parent, span);
            try self.appendSelectorBytes(&output, " ", span);
            try self.appendSelectorBytes(&output, child, span);
        } else {
            var start: usize = 0;
            var index: usize = 0;
            var occurrence: usize = 0;
            var quote: ?u8 = null;
            while (index < child.len) : (index += 1) {
                const byte = child[index];
                if (quote) |active| {
                    if (byte == '\\' and index + 1 < child.len) {
                        index += 1;
                    } else if (byte == active) {
                        quote = null;
                    }
                    continue;
                }
                if (byte == '\'' or byte == '"') {
                    quote = byte;
                    continue;
                }
                if (byte == '\\' and index + 1 < child.len) {
                    index += 1;
                    continue;
                }
                if (byte != '&') continue;
                try self.appendSelectorBytes(&output, child[start..index], span);
                const replacement = if (occurrence == 0)
                    parent
                else
                    parents.items[
                        selectorParentIndex(
                            parents.items.len,
                            ampersand_count - 1,
                            occurrence - 1,
                            ordinal,
                        )
                    ];
                try self.appendSelectorBytes(&output, replacement, span);
                start = index + 1;
                occurrence += 1;
            }
            try self.appendSelectorBytes(&output, child[start..], span);
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn admitSelectorBytes(self: *Engine, count: usize, span: native_source.Span) Error!void {
        const next = std.math.add(usize, self.selector_bytes, count) catch {
            try self.report(.resource_limit, span, "native Sass selector byte limit exceeded");
            return error.SelectorLimitExceeded;
        };
        if (next > self.limits.max_selector_bytes) {
            try self.report(.resource_limit, span, "native Sass selector byte limit exceeded");
            return error.SelectorLimitExceeded;
        }
        self.selector_bytes = next;
    }

    fn appendSelectorBytes(
        self: *Engine,
        output: *std.ArrayList(u8),
        bytes: []const u8,
        span: native_source.Span,
    ) Error!void {
        const next = std.math.add(usize, output.items.len, bytes.len) catch
            return error.SelectorLimitExceeded;
        if (next > self.limits.max_selector_bytes) {
            try self.report(.resource_limit, span, "native Sass selector byte limit exceeded");
            return error.SelectorLimitExceeded;
        }
        try output.appendSlice(self.allocator, bytes);
        try self.admitSelectorBytes(bytes.len, span);
    }

    fn appendValue(
        self: *Engine,
        output: *std.ArrayList(u8),
        item: native_value.Value,
        interpolation: bool,
    ) Error!void {
        switch (item) {
            .null_value => {},
            .boolean => |value| try self.appendTemporary(output, if (value) "true" else "false"),
            .number => |number| try self.appendNumber(output, number),
            .color => |color| {
                var buffer: [native_color.max_serialized_bytes]u8 = undefined;
                try self.appendTemporary(output, try native_color.serialize(color, &buffer, true));
            },
            .string, .selector => |string| {
                if (string.quoted and !interpolation) {
                    try self.appendTemporary(output, "\"");
                    var index: usize = 0;
                    while (index < string.bytes.len) {
                        if (string.bytes[index] == '\\' and index + 1 < string.bytes.len) {
                            try self.appendTemporary(output, string.bytes[index .. index + 2]);
                            index += 2;
                        } else if (string.bytes[index] == '"') {
                            try self.appendTemporary(output, "\\\"");
                            index += 1;
                        } else {
                            try self.appendTemporary(output, string.bytes[index .. index + 1]);
                            index += 1;
                        }
                    }
                    try self.appendTemporary(output, "\"");
                } else {
                    try self.appendTemporary(output, string.bytes);
                }
            },
            .list => |list| {
                if (list.bracketed) try self.appendTemporary(output, "[");
                var emitted: usize = 0;
                for (list.items) |child| {
                    if (child == .null_value) continue;
                    if (emitted > 0) try self.appendTemporary(output, switch (list.separator) {
                        .comma => ",",
                        .slash, .legacy_slash => "/",
                        .undecided, .space => " ",
                    });
                    try self.appendValue(output, child, interpolation);
                    emitted += 1;
                }
                if (list.bracketed) try self.appendTemporary(output, "]");
            },
            .argument_list => |argument_list| {
                if (argument_list.keywords.len > 0) return error.InvalidExpression;
                var emitted: usize = 0;
                for (argument_list.positional) |child| {
                    if (child == .null_value) continue;
                    if (emitted > 0) try self.appendTemporary(output, ",");
                    try self.appendValue(output, child, interpolation);
                    emitted += 1;
                }
            },
            .map, .callable => return error.InvalidExpression,
        }
    }

    const InspectionContext = enum { root, collection };

    fn appendInspectedValue(
        self: *Engine,
        output: *std.ArrayList(u8),
        item: native_value.Value,
        context: InspectionContext,
    ) Error!void {
        try self.transaction.consumeOperations(1);
        switch (item) {
            .null_value => try self.appendTemporary(output, "null"),
            .boolean, .number, .color, .selector => try self.appendValue(output, item, false),
            .string => |string| if (!string.quoted) {
                if (sassCalculationValue(string.bytes)) |calculation| {
                    try self.appendInspectedCalculation(output, calculation);
                } else {
                    try self.appendValue(output, item, false);
                }
            } else {
                try self.appendValue(output, item, false);
            },
            .list => |list| {
                if (list.items.len == 0 and !list.bracketed) {
                    try self.appendTemporary(output, "()");
                    return;
                }
                const parenthesized = !list.bracketed and list.separator == .comma and
                    (context == .collection or list.items.len == 1);
                if (list.bracketed) try self.appendTemporary(output, "[");
                if (parenthesized) try self.appendTemporary(output, "(");
                for (list.items, 0..) |child, index| {
                    if (index > 0) try self.appendTemporary(output, switch (list.separator) {
                        .comma => ", ",
                        .slash, .legacy_slash => " / ",
                        .undecided, .space => " ",
                    });
                    try self.appendInspectedValue(output, child, .collection);
                }
                if (list.separator == .comma and list.items.len == 1) {
                    try self.appendTemporary(output, ",");
                }
                if (parenthesized) try self.appendTemporary(output, ")");
                if (list.bracketed) try self.appendTemporary(output, "]");
            },
            .map => |map| {
                try self.appendTemporary(output, "(");
                for (map.entries, 0..) |entry, index| {
                    if (index > 0) try self.appendTemporary(output, ", ");
                    try self.appendInspectedValue(output, entry.key, .collection);
                    try self.appendTemporary(output, ": ");
                    try self.appendInspectedValue(output, entry.value, .collection);
                }
                try self.appendTemporary(output, ")");
            },
            .argument_list => |argument_list| {
                if (argument_list.positional.len == 0) {
                    try self.appendTemporary(output, "()");
                    return;
                }
                const parenthesized = argument_list.positional.len == 1;
                if (parenthesized) try self.appendTemporary(output, "(");
                for (argument_list.positional, 0..) |child, index| {
                    if (index > 0) try self.appendTemporary(output, ", ");
                    try self.appendInspectedValue(output, child, .collection);
                }
                if (parenthesized) try self.appendTemporary(output, ",)");
            },
            .callable => |callable| try self.appendInspectedCallable(output, callable),
        }
    }

    fn appendInspectedCallable(
        self: *Engine,
        output: *std.ArrayList(u8),
        callable: native_value.Callable,
    ) Error!void {
        const kind: []const u8 = switch (callable.kind) {
            .builtin_function, .user_function => "function",
            .builtin_mixin, .mixin => "mixin",
        };
        const name: []const u8 = switch (callable.kind) {
            .user_function => if (callable.id < self.user_functions.items.len)
                self.user_functions.items[callable.id].name
            else
                return error.InvalidExpression,
            .mixin => if (callable.id < self.user_mixins.items.len)
                self.user_mixins.items[callable.id].name
            else
                return error.InvalidExpression,
            .builtin_function => builtinFunctionCallableName(callable.id) orelse
                return error.InvalidExpression,
            .builtin_mixin => switch (std.meta.intToEnum(BuiltinMixin, callable.id) catch
                return error.InvalidExpression) {
                .meta_load_css => "load-css",
                .meta_apply => "apply",
            },
        };

        try self.appendTemporary(output, "get-");
        try self.appendTemporary(output, kind);
        try self.appendTemporary(output, "(\"");
        var segment_start: usize = 0;
        for (name, 0..) |byte, index| {
            if (byte != '_') continue;
            try self.appendTemporary(output, name[segment_start..index]);
            try self.appendTemporary(output, "-");
            segment_start = index + 1;
        }
        try self.appendTemporary(output, name[segment_start..]);
        try self.appendTemporary(output, "\")");
    }

    fn appendInspectedCalculation(
        self: *Engine,
        output: *std.ArrayList(u8),
        calculation: SassCalculationValue,
    ) Error!void {
        try self.transaction.consumeOperations(1);
        try self.appendTemporary(output, calculation.name);
        try self.appendTemporary(output, "(");
        try self.appendCanonicalCalculationBody(output, calculation.body);
        try self.appendTemporary(output, ")");
    }

    fn appendCanonicalCalculationBody(
        self: *Engine,
        output: *std.ArrayList(u8),
        body: []const u8,
    ) Error!void {
        const operation_count = std.math.cast(u64, body.len) orelse
            std.math.maxInt(u64);
        try self.transaction.consumeOperations(operation_count);
        var index: usize = 0;
        var quote: ?u8 = null;
        var pending_whitespace = false;
        while (index < body.len) {
            const byte = body[index];
            if (quote) |active| {
                try self.appendTemporary(output, body[index .. index + 1]);
                index += 1;
                if (byte == '\\' and index < body.len) {
                    try self.appendTemporary(output, body[index .. index + 1]);
                    index += 1;
                } else if (byte == active) {
                    quote = null;
                }
                continue;
            }
            if (byte == '\'' or byte == '"') {
                if (pending_whitespace and output.items.len > 0 and
                    output.items[output.items.len - 1] != '(' and
                    output.items[output.items.len - 1] != '[' and
                    output.items[output.items.len - 1] != ' ')
                {
                    try self.appendTemporary(output, " ");
                }
                pending_whitespace = false;
                quote = byte;
                try self.appendTemporary(output, body[index .. index + 1]);
                index += 1;
                continue;
            }
            if (byte == '\\' and index + 1 < body.len) {
                if (pending_whitespace and output.items.len > 0 and output.items[output.items.len - 1] != '(') {
                    try self.appendTemporary(output, " ");
                }
                pending_whitespace = false;
                try self.appendTemporary(output, body[index .. index + 2]);
                index += 2;
                continue;
            }
            if (commentEnd(body, index)) |end| {
                pending_whitespace = true;
                index = end;
                continue;
            }
            if (isExpressionWhitespace(byte)) {
                pending_whitespace = true;
                index += 1;
                continue;
            }
            if (byte != ',') {
                const closes_group = byte == ')' or byte == ']';
                if (pending_whitespace and !closes_group and output.items.len > 0 and
                    output.items[output.items.len - 1] != '(' and
                    output.items[output.items.len - 1] != '[' and
                    output.items[output.items.len - 1] != ' ')
                {
                    try self.appendTemporary(output, " ");
                }
                pending_whitespace = false;
                try self.appendTemporary(output, body[index .. index + 1]);
                index += 1;
                continue;
            }
            while (output.items.len > 0 and isExpressionWhitespace(output.items[output.items.len - 1])) {
                output.items.len -= 1;
            }
            try self.appendTemporary(output, ", ");
            pending_whitespace = false;
            index += 1;
            while (index < body.len and isExpressionWhitespace(body[index])) {
                index += 1;
            }
        }
    }

    fn ensureCssValue(
        self: *Engine,
        item: native_value.Value,
        span: native_source.Span,
    ) Error!void {
        if (cssValueIsValid(item, 0)) return;
        try self.report(.type_mismatch, span, "native Sass value cannot be emitted as CSS");
        return error.InvalidExpression;
    }

    fn appendNumber(
        self: *Engine,
        output: *std.ArrayList(u8),
        number: native_value.Number,
    ) Error!void {
        var buffer: [native_numeric.max_serialized_bytes]u8 = undefined;
        const formatted = try native_numeric.serialize(number.value, &buffer, true);
        try self.appendTemporary(output, formatted);
        for (number.numerator_units, 0..) |unit, index| {
            if (index > 0) try self.appendTemporary(output, "*");
            try self.appendTemporary(output, unit);
        }
        for (number.denominator_units) |unit| {
            try self.appendTemporary(output, "/");
            try self.appendTemporary(output, unit);
        }
    }

    fn appendTemporary(
        self: *Engine,
        output: *std.ArrayList(u8),
        bytes: []const u8,
    ) Error!void {
        const next = std.math.add(usize, output.items.len, bytes.len) catch
            return error.TemporaryLimitExceeded;
        if (next > self.limits.max_temporary_bytes) return error.TemporaryLimitExceeded;
        try output.appendSlice(self.allocator, bytes);
    }

    fn report(
        self: *Engine,
        code: native_diagnostics.Code,
        span: native_source.Span,
        message: []const u8,
    ) Error!void {
        try self.transaction.report(.err, code, span, message, &.{});
    }
};

const ArithmeticParser = struct {
    engine: *Engine,
    raw: []const u8,
    tokens: []const native_lexer.Token,
    cursor: usize,
    scope: native_environment.ScopeId,
    span: native_source.Span,
    saw_operator: bool = false,
    allows_slash_division: bool,
    strict_additive_units: bool,
    invalid_additive_units: bool = false,

    fn parseExpression(self: *ArithmeticParser) Error!Numeric {
        var left = try self.parseTerm();
        while (true) {
            self.skipTrivia();
            const token = self.current();
            if (token.kind != .operator) return left;
            const operation = token.raw(self.raw);
            if (!std.mem.eql(u8, operation, "+") and !std.mem.eql(u8, operation, "-")) return left;
            self.saw_operator = true;
            self.cursor += 1;
            const right = try self.parseTerm();
            if (self.strict_additive_units and
                left.isDimensionless() != right.isDimensionless())
            {
                self.invalid_additive_units = true;
                return error.IncompatibleUnits;
            }
            left = try native_numeric.add(left, right, operation[0]);
        }
    }

    fn parseTerm(self: *ArithmeticParser) Error!Numeric {
        var left = try self.parseUnary();
        while (true) {
            self.skipTrivia();
            const token = self.current();
            if (token.kind != .operator) return left;
            const operation = token.raw(self.raw);
            if (!std.mem.eql(u8, operation, "*") and
                !std.mem.eql(u8, operation, "/") and
                !std.mem.eql(u8, operation, "%")) return left;
            if (std.mem.eql(u8, operation, "/") and !self.allows_slash_division) return left;
            self.saw_operator = true;
            self.cursor += 1;
            const right = try self.parseUnary();
            left = if (operation[0] == '%')
                try native_numeric.modulo(left, right)
            else
                try native_numeric.multiply(left, right, operation[0]);
        }
    }

    fn parseUnary(self: *ArithmeticParser) Error!Numeric {
        self.skipTrivia();
        const token = self.current();
        if (token.kind == .operator) {
            const operation = token.raw(self.raw);
            if (std.mem.eql(u8, operation, "+") or std.mem.eql(u8, operation, "-")) {
                self.saw_operator = true;
                self.cursor += 1;
                var result = try self.parseUnary();
                if (operation[0] == '-') result.value = -result.value;
                return result;
            }
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *ArithmeticParser) Error!Numeric {
        self.skipTrivia();
        const token = self.current();
        switch (token.kind) {
            .number => {
                self.cursor += 1;
                const number = std.fmt.parseFloat(f64, token.raw(self.raw)) catch
                    return error.InvalidExpression;
                if (!std.math.isFinite(number)) return error.InvalidExpression;
                var unit: ?[]const u8 = null;
                if (self.cursor < self.tokens.len) {
                    const next = self.tokens[self.cursor];
                    if (next.span.start == token.span.end and next.kind == .identifier) {
                        unit = next.raw(self.raw);
                        self.cursor += 1;
                    } else if (next.span.start == token.span.end and next.kind == .operator and
                        std.mem.eql(u8, next.raw(self.raw), "%"))
                    {
                        unit = "%";
                        self.cursor += 1;
                    }
                }
                return native_numeric.Numeric.init(number, unit);
            },
            .variable => {
                self.cursor += 1;
                const raw_name = token.raw(self.raw);
                const normalized = try self.engine.normalizeVariable(raw_name);
                defer self.engine.allocator.free(normalized);
                if (self.engine.unprefixedMathConstant(normalized)) |constant| {
                    return native_numeric.Numeric.fromBuiltinConstant(constant);
                }
                const item = try self.engine.lookupVariable(token.raw(self.raw), self.scope, self.span);
                return switch (item.*) {
                    .number => |number| native_numeric.Numeric.fromNumber(number),
                    else => error.InvalidExpression,
                };
            },
            .identifier => {
                if (self.cursor + 2 < self.tokens.len) {
                    const separator = self.tokens[self.cursor + 1];
                    const variable = self.tokens[self.cursor + 2];
                    if (separator.kind == .delimiter and variable.kind == .variable and
                        token.span.end == separator.span.start and
                        separator.span.end == variable.span.start and
                        std.mem.eql(u8, separator.raw(self.raw), "."))
                    {
                        const qualified = self.raw[token.span.start..variable.span.end];
                        const constant = (try self.engine.tryModuleConstant(qualified, self.span)) orelse
                            return error.InvalidExpression;
                        self.cursor += 3;
                        return native_numeric.Numeric.fromBuiltinConstant(constant);
                    }
                }
                var opening_index = self.cursor + 1;
                while (opening_index < self.tokens.len and
                    isExpressionTrivia(self.tokens[opening_index].kind))
                {
                    opening_index += 1;
                }
                if (opening_index >= self.tokens.len or
                    self.tokens[opening_index].kind != .open_paren or
                    self.tokens[opening_index].span.start != token.span.end)
                {
                    return error.InvalidExpression;
                }
                var depth: usize = 0;
                var closing_index: ?usize = null;
                var index = opening_index;
                while (index < self.tokens.len) : (index += 1) {
                    switch (self.tokens[index].kind) {
                        .open_paren => depth += 1,
                        .close_paren => {
                            if (depth == 0) return error.InvalidExpression;
                            depth -= 1;
                            if (depth == 0) {
                                closing_index = index;
                                break;
                            }
                        },
                        else => {},
                    }
                }
                const closing = closing_index orelse return error.InvalidExpression;
                const call = self.raw[token.span.start..self.tokens[closing].span.end];
                self.cursor = closing + 1;
                const item = if (try self.engine.tryLegacyIfFunctionCall(
                    call,
                    self.scope,
                    self.span,
                )) |selected|
                    selected
                else blk: {
                    if (legacyIfIdentifierEql(token.raw(self.raw))) {
                        return error.InvalidExpression;
                    }
                    _ = try self.engine.lookupUserFunction(
                        token.raw(self.raw),
                        self.scope,
                    ) orelse return error.InvalidExpression;
                    break :blk (try self.engine.tryUserFunctionCall(
                        call,
                        self.scope,
                        self.span,
                    )) orelse return error.InvalidExpression;
                };
                return switch (item.*) {
                    .number => |number| native_numeric.Numeric.fromNumber(number),
                    else => error.InvalidExpression,
                };
            },
            .open_paren => {
                self.cursor += 1;
                const result = try self.parseExpression();
                self.skipTrivia();
                if (self.current().kind != .close_paren) return error.InvalidExpression;
                self.cursor += 1;
                return result;
            },
            else => return error.InvalidExpression,
        }
    }

    fn skipTrivia(self: *ArithmeticParser) void {
        while (self.cursor < self.tokens.len and isExpressionTrivia(self.tokens[self.cursor].kind)) {
            self.cursor += 1;
        }
    }

    fn current(self: *const ArithmeticParser) native_lexer.Token {
        return self.tokens[@min(self.cursor, self.tokens.len - 1)];
    }
};

fn validateLimits(limits: Limits) Error!void {
    const value_limits = limits.values;
    const environment_limits = limits.environment;
    if (value_limits.max_values == 0 or value_limits.max_values > 1_000_000 or
        value_limits.max_depth == 0 or value_limits.max_depth > 64 or
        value_limits.max_collection_items > 1_000_000 or
        value_limits.max_owned_bytes == 0 or value_limits.max_owned_bytes > 64 * 1024 * 1024 or
        environment_limits.max_scopes == 0 or environment_limits.max_scopes > 65_536 or
        environment_limits.max_scope_depth == 0 or environment_limits.max_scope_depth > 1_024 or
        environment_limits.max_bindings > 1_000_000 or
        environment_limits.max_name_bytes == 0 or
        environment_limits.max_name_bytes > 16 * 1024 * 1024 or
        limits.max_selectors == 0 or limits.max_selectors > hard_selectors or
        limits.max_selector_bytes == 0 or limits.max_selector_bytes > hard_selector_bytes or
        limits.max_temporary_bytes == 0 or limits.max_temporary_bytes > hard_temporary_bytes or
        limits.max_expression_tokens == 0 or
        limits.max_expression_tokens > hard_expression_tokens or
        limits.max_function_arguments == 0 or
        limits.max_function_arguments > hard_function_arguments or
        limits.max_callables == 0 or limits.max_callables > hard_callables or
        limits.max_modules == 0 or limits.max_modules > hard_modules or
        limits.max_loop_variables == 0 or limits.max_loop_variables > hard_loop_variables or
        limits.max_evaluation_depth == 0 or limits.max_evaluation_depth > hard_evaluation_depth)
    {
        return error.InvalidLimits;
    }
}

fn loopBodyReturned(context: LoopBodyContext) bool {
    return switch (context) {
        .callable => |return_value| return_value.* != null,
        .root, .rule => false,
    };
}

fn fullyWrapped(input: []const u8, opening: u8, closing: u8) bool {
    if (input.len < 2 or input[0] != opening) return false;
    var depth: usize = 0;
    var quote: ?u8 = null;
    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\' and index + 1 < input.len) {
                index += 2;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            index += 1;
            continue;
        }
        if (byte == '\\' and index + 1 < input.len) {
            index += 2;
            continue;
        }
        if (commentEnd(input, index)) |end| {
            index = end;
            continue;
        }
        if (byte == opening) {
            depth += 1;
        } else if (byte == closing) {
            if (depth == 0) return false;
            depth -= 1;
            if (depth == 0) return index == input.len - 1;
        }
        index += 1;
    }
    return false;
}

fn splitTopLevelRanges(
    allocator: std.mem.Allocator,
    input: []const u8,
    separator: SplitSeparator,
    output: *std.ArrayList(ExpressionRange),
) std.mem.Allocator.Error!bool {
    var start: usize = 0;
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var curly_depth: usize = 0;
    var quote: ?u8 = null;
    var saw_separator = false;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\' and index + 1 < input.len) {
                index += 2;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            index += 1;
            continue;
        }
        if (byte == '\\' and index + 1 < input.len) {
            index = sassEscapeEnd(input, index);
            continue;
        }
        if (commentEnd(input, index)) |end| {
            index = end;
            continue;
        }
        switch (byte) {
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => if (square_depth > 0) {
                square_depth -= 1;
            },
            '{' => curly_depth += 1,
            '}' => if (curly_depth > 0) {
                curly_depth -= 1;
            },
            else => {},
        }
        const top_level = paren_depth == 0 and square_depth == 0 and curly_depth == 0;
        const is_separator = top_level and switch (separator) {
            .comma => byte == ',',
            .slash => byte == '/',
            .whitespace, .color_whitespace => isExpressionWhitespace(byte),
        };
        if (!is_separator) {
            index += 1;
            continue;
        }

        if (separator == .whitespace or separator == .color_whitespace) {
            var end = index + 1;
            while (end < input.len and isExpressionWhitespace(input[end])) end += 1;
            const operator_padding = if (separator == .color_whitespace)
                colorWhitespaceIsOperatorPadding(input, index, end)
            else
                whitespaceIsOperatorPadding(input, index, end);
            if (operator_padding) {
                index = end;
                continue;
            }
            if (trimWhitespace(input[start..index]).len == 0) {
                start = end;
                index = end;
                continue;
            }
            if (trimWhitespace(input[end..]).len == 0) {
                index = end;
                continue;
            }
            try output.append(allocator, .{ .start = start, .end = index });
            saw_separator = true;
            start = end;
            index = end;
            continue;
        }

        try output.append(allocator, .{ .start = start, .end = index });
        saw_separator = true;
        start = index + 1;
        index += 1;
    }
    if (input.len > 0 or saw_separator) {
        try output.append(allocator, .{ .start = start, .end = input.len });
    }
    return saw_separator;
}

fn sassEscapeEnd(input: []const u8, opening: usize) usize {
    std.debug.assert(opening < input.len and input[opening] == '\\');
    var index = opening + 1;
    if (index == input.len) return index;

    if (std.ascii.isHex(input[index])) {
        var digits: u8 = 0;
        while (index < input.len and digits < 6 and std.ascii.isHex(input[index])) {
            index += 1;
            digits += 1;
        }
        if (index < input.len and isExpressionWhitespace(input[index])) {
            if (input[index] == '\r' and index + 1 < input.len and input[index + 1] == '\n') {
                return index + 2;
            }
            return index + 1;
        }
        return index;
    }

    const scalar_length = std.unicode.utf8ByteSequenceLength(input[index]) catch return index + 1;
    return @min(input.len, index + scalar_length);
}

fn findTopLevelByte(input: []const u8, target: u8) ?usize {
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var curly_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\' and index + 1 < input.len) {
                index += 2;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            index += 1;
            continue;
        }
        if (byte == '\\' and index + 1 < input.len) {
            index += 2;
            continue;
        }
        if (commentEnd(input, index)) |end| {
            index = end;
            continue;
        }
        if (paren_depth == 0 and square_depth == 0 and curly_depth == 0 and byte == target) {
            return index;
        }
        switch (byte) {
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => if (square_depth > 0) {
                square_depth -= 1;
            },
            '{' => curly_depth += 1,
            '}' => if (curly_depth > 0) {
                curly_depth -= 1;
            },
            else => {},
        }
        index += 1;
    }
    return null;
}

fn findTopLevelWord(input: []const u8, word: []const u8) ?usize {
    if (word.len == 0 or input.len < word.len) return null;

    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var curly_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\' and index + 1 < input.len) {
                index += 2;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            index += 1;
            continue;
        }
        if (byte == '\\' and index + 1 < input.len) {
            index += 2;
            continue;
        }
        if (commentEnd(input, index)) |end| {
            index = end;
            continue;
        }

        const top_level = paren_depth == 0 and square_depth == 0 and curly_depth == 0;
        const word_end = std.math.add(usize, index, word.len) catch input.len +| 1;
        if (top_level and word_end <= input.len and
            std.ascii.eqlIgnoreCase(input[index..word_end], word) and
            (index == 0 or !isVariableNameContinue(input[index - 1])) and
            (word_end == input.len or !isVariableNameContinue(input[word_end])))
        {
            return index;
        }

        switch (byte) {
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => if (square_depth > 0) {
                square_depth -= 1;
            },
            '{' => curly_depth += 1,
            '}' => if (curly_depth > 0) {
                curly_depth -= 1;
            },
            else => {},
        }
        index += 1;
    }
    return null;
}

fn commentEnd(input: []const u8, start: usize) ?usize {
    if (start + 1 >= input.len or input[start] != '/') return null;
    if (input[start + 1] == '*') {
        const closing = std.mem.indexOf(u8, input[start + 2 ..], "*/") orelse return input.len;
        return start + 2 + closing + 2;
    }
    if (input[start + 1] == '/') {
        const newline = std.mem.indexOfScalar(u8, input[start + 2 ..], '\n') orelse return input.len;
        return start + 2 + newline;
    }
    return null;
}

fn isSimpleIdentifier(input: []const u8) bool {
    if (input.len == 0 or !isVariableNameStart(input[0])) return false;
    for (input[1..]) |byte| {
        if (!isVariableNameContinue(byte)) return false;
    }
    return true;
}

fn sassNameEql(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        const normalized = if (left_byte == '_') '-' else left_byte;
        if (normalized != right_byte) return false;
    }
    return true;
}

fn callKeywordNamesEqual(
    left: EvaluatedKeywordArgument,
    right: EvaluatedKeywordArgument,
) bool {
    if (left.name.len != right.name.len) return false;
    for (left.name, right.name) |left_byte, right_byte| {
        const normalized_left = if (left.normalize_name and left_byte == '_') '-' else left_byte;
        const normalized_right = if (right.normalize_name and right_byte == '_') '-' else right_byte;
        if (normalized_left != normalized_right) return false;
    }
    return true;
}

fn evaluatedKeywordNameEql(
    keyword: EvaluatedKeywordArgument,
    expected: []const u8,
) bool {
    return if (keyword.normalize_name)
        native_arguments.nameEql(keyword.name, expected)
    else
        std.mem.eql(u8, keyword.name, expected);
}

fn fixedListBuiltinParameters(
    builtin: Builtin,
) ?[]const native_arguments.Parameter {
    return switch (builtin) {
        .nth => &.{
            .{ .name = "list" },
            .{ .name = "n" },
        },
        .length => &.{.{ .name = "list" }},
        .list_index => &.{
            .{ .name = "list" },
            .{ .name = "value" },
        },
        .list_separator, .list_is_bracketed => &.{.{ .name = "list" }},
        .list_append => &.{
            .{ .name = "list" },
            .{ .name = "val" },
            .{ .name = "separator", .required = false },
        },
        .list_set_nth => &.{
            .{ .name = "list" },
            .{ .name = "n" },
            .{ .name = "value" },
        },
        .list_join => &.{
            .{ .name = "list1" },
            .{ .name = "list2" },
            .{ .name = "separator", .required = false },
            .{ .name = "bracketed", .required = false },
        },
        else => null,
    };
}

fn moduleBuiltin(kind: BuiltinModule, name: []const u8) ?Builtin {
    return switch (kind) {
        .color => colorModuleBuiltin(name),
        .list => listModuleBuiltin(name),
        .map => mapModuleBuiltin(name),
        .math => mathModuleBuiltin(name),
        .meta => metaModuleBuiltin(name),
        .selector => selectorModuleBuiltin(name),
        .string => stringModuleBuiltin(name),
    };
}

fn moduleCallableBuiltin(kind: BuiltinModule, name: []const u8) ?Builtin {
    if (moduleBuiltin(kind, name)) |builtin| return builtin;
    if (kind == .color and sassNameEql(name, "red")) return .red;
    if (kind == .color and sassNameEql(name, "green")) return .green;
    if (kind == .color and sassNameEql(name, "blue")) return .blue;
    if (kind == .color and sassNameEql(name, "alpha")) return .alpha;
    if (kind == .color and sassNameEql(name, "opacity")) return .opacity;
    if (kind == .color and sassNameEql(name, "hue")) return .hue;
    if (kind == .color and sassNameEql(name, "saturation")) return .saturation;
    if (kind == .color and sassNameEql(name, "lightness")) return .lightness;
    if (kind == .color and sassNameEql(name, "whiteness")) return .whiteness;
    if (kind == .color and sassNameEql(name, "blackness")) return .blackness;
    if (kind == .color and sassNameEql(name, "mix")) return .mix;
    if (kind == .color and sassNameEql(name, "lighten")) return .lighten;
    if (kind == .color and sassNameEql(name, "darken")) return .darken;
    if (kind == .color and sassNameEql(name, "saturate")) return .saturate;
    if (kind == .color and sassNameEql(name, "desaturate")) return .desaturate;
    if (kind == .color and sassNameEql(name, "adjust-hue")) return .adjust_hue;
    if (kind == .color and sassNameEql(name, "complement")) return .complement;
    if (kind == .color and sassNameEql(name, "grayscale")) return .grayscale;
    if (kind == .color and sassNameEql(name, "invert")) return .invert;
    if (kind == .color and sassNameEql(name, "opacify")) return .opacify;
    if (kind == .color and sassNameEql(name, "fade-in")) return .fade_in;
    if (kind == .color and sassNameEql(name, "transparentize")) return .transparentize;
    return null;
}

fn moduleFunctionExists(kind: BuiltinModule, name: []const u8) bool {
    if (moduleCallableBuiltin(kind, name) != null) return true;
    // Dart Sass 1.101.0 reports modern global color constructors as existing
    // in sass:color even though qualified calls and module-owned references
    // remain unavailable. Preserve that measured split only for constructors
    // with their own evidence-closed invocation slices.
    return kind == .color and
        (sassNameEql(name, "lab") or
            sassNameEql(name, "lch") or
            sassNameEql(name, "oklab") or
            sassNameEql(name, "oklch") or
            sassNameEql(name, "color"));
}

// Built-in function identity includes its owner: a legacy global and the
// corresponding module member are distinct, while module aliases are equal.
// Reserve origin zero's largest member for the special legacy `if()` function.
const builtin_function_member_mask: u32 = 0x0fff_ffff;
const builtin_function_origin_shift: u5 = 28;

const BuiltinFunctionReference = struct {
    builtin: Builtin,
    owner: ?BuiltinModule,
};

fn builtinFunctionCallable(
    builtin: Builtin,
    owner: ?BuiltinModule,
) native_value.Callable {
    const member: u32 = @intCast(@intFromEnum(builtin));
    std.debug.assert(member < builtin_function_member_mask);
    const origin: u32 = if (owner) |kind| @as(u32, @intFromEnum(kind)) + 1 else 0;
    return .{
        .kind = .builtin_function,
        .id = (origin << builtin_function_origin_shift) | member,
    };
}

fn builtinIfFunctionCallable() native_value.Callable {
    return .{
        .kind = .builtin_function,
        .id = builtin_function_member_mask,
    };
}

fn builtinFunctionCallableName(id: u32) ?[]const u8 {
    if (id == builtin_function_member_mask) return "if";

    const reference = decodeBuiltinFunctionCallable(id) orelse return null;
    return if (reference.owner) |owner|
        moduleBuiltinCallableName(owner, reference.builtin)
    else
        globalBuiltinCallableName(reference.builtin);
}

fn decodeBuiltinFunctionCallable(id: u32) ?BuiltinFunctionReference {
    if (id == builtin_function_member_mask) return null;

    const member = std.meta.intToEnum(Builtin, id & builtin_function_member_mask) catch
        return null;
    const encoded_origin = id >> builtin_function_origin_shift;
    if (encoded_origin == 0) {
        _ = globalBuiltinCallableName(member) orelse return null;
        return .{ .builtin = member, .owner = null };
    }

    const owner = std.meta.intToEnum(BuiltinModule, encoded_origin - 1) catch
        return null;
    _ = moduleBuiltinCallableName(owner, member) orelse return null;
    return .{ .builtin = member, .owner = owner };
}

fn globalBuiltinCallableName(builtin: Builtin) ?[]const u8 {
    const tag_name = @tagName(builtin);
    const candidate: []const u8 = switch (builtin) {
        .math_compatible => "comparable",
        .math_is_unitless => "unitless",
        .selector_extend => "selector-extend",
        .selector_replace => "selector-replace",
        .selector_is_superselector => "is-superselector",
        .selector_simple_selectors => "simple-selectors",
        .selector_nest => "selector-nest",
        .selector_unify => "selector-unify",
        .minimum => "min",
        .maximum => "max",
        .calculation => "calc",
        .list_index,
        .list_is_bracketed,
        .list_append,
        .list_set_nth,
        .list_join,
        .list_zip,
        => tag_name["list_".len..],
        else => if (std.mem.startsWith(u8, tag_name, "math_"))
            tag_name["math_".len..]
        else if (std.mem.startsWith(u8, tag_name, "meta_"))
            tag_name["meta_".len..]
        else
            tag_name,
    };
    return if (globalCallableBuiltin(candidate) == builtin) candidate else null;
}

fn moduleBuiltinCallableName(owner: BuiltinModule, builtin: Builtin) ?[]const u8 {
    const tag_name = @tagName(builtin);
    const candidate: []const u8 = switch (owner) {
        .color => if (std.mem.endsWith(u8, tag_name, "_color"))
            tag_name[0 .. tag_name.len - "_color".len]
        else
            tag_name,
        .list => if (std.mem.startsWith(u8, tag_name, "list_"))
            tag_name["list_".len..]
        else
            tag_name,
        .map => if (std.mem.startsWith(u8, tag_name, "map_"))
            tag_name["map_".len..]
        else
            return null,
        .math => if (std.mem.startsWith(u8, tag_name, "math_"))
            tag_name["math_".len..]
        else
            return null,
        .meta => if (std.mem.startsWith(u8, tag_name, "meta_"))
            tag_name["meta_".len..]
        else
            return null,
        .selector => if (std.mem.startsWith(u8, tag_name, "selector_"))
            tag_name["selector_".len..]
        else
            return null,
        .string => if (std.mem.startsWith(u8, tag_name, "str_"))
            tag_name["str_".len..]
        else
            tag_name,
    };
    return if (moduleCallableBuiltin(owner, candidate) == builtin) candidate else null;
}

fn moduleBuiltinMixin(kind: BuiltinModule, name: []const u8) ?BuiltinMixin {
    if (kind != .meta) return null;
    if (sassNameEql(name, "load-css")) return .meta_load_css;
    if (sassNameEql(name, "apply")) return .meta_apply;
    return null;
}

fn metaFeatureExists(name: []const u8) bool {
    const features = [_][]const u8{
        "global-variable-shadowing",
        "extend-selector-pseudoclass",
        "units-level-3",
        "at-error",
        "custom-property",
    };
    for (features) |feature| {
        if (std.mem.eql(u8, name, feature)) return true;
    }
    return false;
}

fn colorModuleBuiltin(name: []const u8) ?Builtin {
    if (sassNameEql(name, "adjust")) return .adjust_color;
    if (sassNameEql(name, "change")) return .change_color;
    if (sassNameEql(name, "scale")) return .scale_color;
    if (sassNameEql(name, "hwb")) return .hwb;
    return null;
}

fn listModuleBuiltin(name: []const u8) ?Builtin {
    if (sassNameEql(name, "nth")) return .nth;
    if (sassNameEql(name, "length")) return .length;
    if (sassNameEql(name, "index")) return .list_index;
    if (sassNameEql(name, "separator")) return .list_separator;
    if (sassNameEql(name, "is-bracketed")) return .list_is_bracketed;
    if (sassNameEql(name, "append")) return .list_append;
    if (sassNameEql(name, "set-nth")) return .list_set_nth;
    if (sassNameEql(name, "join")) return .list_join;
    if (sassNameEql(name, "zip")) return .list_zip;
    if (sassNameEql(name, "slash")) return .list_slash;
    return null;
}

fn mapModuleBuiltin(name: []const u8) ?Builtin {
    if (sassNameEql(name, "get")) return .map_get;
    if (sassNameEql(name, "has-key")) return .map_has_key;
    if (sassNameEql(name, "keys")) return .map_keys;
    if (sassNameEql(name, "values")) return .map_values;
    if (sassNameEql(name, "merge")) return .map_merge;
    if (sassNameEql(name, "remove")) return .map_remove;
    if (sassNameEql(name, "set")) return .map_set;
    if (sassNameEql(name, "deep-merge")) return .map_deep_merge;
    if (sassNameEql(name, "deep-remove")) return .map_deep_remove;
    return null;
}

fn mathModuleBuiltin(name: []const u8) ?Builtin {
    if (sassNameEql(name, "abs")) return .math_abs;
    if (sassNameEql(name, "acos")) return .math_acos;
    if (sassNameEql(name, "asin")) return .math_asin;
    if (sassNameEql(name, "atan")) return .math_atan;
    if (sassNameEql(name, "atan2")) return .math_atan2;
    if (sassNameEql(name, "ceil")) return .math_ceil;
    if (sassNameEql(name, "compatible")) return .math_compatible;
    if (sassNameEql(name, "clamp")) return .math_clamp;
    if (sassNameEql(name, "cos")) return .math_cos;
    if (sassNameEql(name, "div")) return .math_div;
    if (sassNameEql(name, "floor")) return .math_floor;
    if (sassNameEql(name, "hypot")) return .math_hypot;
    if (sassNameEql(name, "is-unitless")) return .math_is_unitless;
    if (sassNameEql(name, "log")) return .math_log;
    if (sassNameEql(name, "max")) return .math_max;
    if (sassNameEql(name, "min")) return .math_min;
    if (sassNameEql(name, "percentage")) return .math_percentage;
    if (sassNameEql(name, "pow")) return .math_pow;
    if (sassNameEql(name, "random")) return .math_random;
    if (sassNameEql(name, "round")) return .math_round;
    if (sassNameEql(name, "sin")) return .math_sin;
    if (sassNameEql(name, "sqrt")) return .math_sqrt;
    if (sassNameEql(name, "tan")) return .math_tan;
    if (sassNameEql(name, "unit")) return .math_unit;
    return null;
}

fn mathModuleConstant(name: []const u8) ?f64 {
    for (math_constants) |constant| {
        if (sassNameEql(name, constant.name)) return constant.value;
    }
    return null;
}

fn mathModuleOwnsFunction(name: []const u8) bool {
    const functions = [_][]const u8{
        "abs",   "acos", "asin",       "atan",  "atan2",      "ceil",
        "clamp", "cos",  "div",        "floor", "hypot",      "log",
        "max",   "min",  "percentage", "pow",   "random",     "round",
        "sin",   "sqrt", "tan",        "unit",  "compatible", "is-unitless",
    };
    for (functions) |function| {
        if (sassNameEql(name, function)) return true;
    }
    return false;
}

fn globalBuiltin(name: []const u8) ?Builtin {
    const definitions = [_]struct {
        name: []const u8,
        builtin: Builtin,
    }{
        .{ .name = "map-get", .builtin = .map_get },
        .{ .name = "map-has-key", .builtin = .map_has_key },
        .{ .name = "map-keys", .builtin = .map_keys },
        .{ .name = "map-values", .builtin = .map_values },
        .{ .name = "map-merge", .builtin = .map_merge },
        .{ .name = "map-remove", .builtin = .map_remove },
        .{ .name = "nth", .builtin = .nth },
        .{ .name = "length", .builtin = .length },
        .{ .name = "index", .builtin = .list_index },
        .{ .name = "list-separator", .builtin = .list_separator },
        .{ .name = "is-bracketed", .builtin = .list_is_bracketed },
        .{ .name = "append", .builtin = .list_append },
        .{ .name = "set-nth", .builtin = .list_set_nth },
        .{ .name = "join", .builtin = .list_join },
        .{ .name = "zip", .builtin = .list_zip },
        .{ .name = "abs", .builtin = .math_abs },
        .{ .name = "acos", .builtin = .math_acos },
        .{ .name = "asin", .builtin = .math_asin },
        .{ .name = "atan", .builtin = .math_atan },
        .{ .name = "atan2", .builtin = .math_atan2 },
        .{ .name = "ceil", .builtin = .math_ceil },
        .{ .name = "comparable", .builtin = .math_compatible },
        .{ .name = "cos", .builtin = .math_cos },
        .{ .name = "floor", .builtin = .math_floor },
        .{ .name = "unitless", .builtin = .math_is_unitless },
        .{ .name = "log", .builtin = .math_log },
        .{ .name = "percentage", .builtin = .math_percentage },
        .{ .name = "pow", .builtin = .math_pow },
        .{ .name = "random", .builtin = .math_random },
        .{ .name = "round", .builtin = .math_round },
        .{ .name = "sin", .builtin = .math_sin },
        .{ .name = "sqrt", .builtin = .math_sqrt },
        .{ .name = "tan", .builtin = .math_tan },
        .{ .name = "unit", .builtin = .math_unit },
        .{ .name = "content-exists", .builtin = .meta_content_exists },
        .{ .name = "call", .builtin = .meta_call },
        .{ .name = "feature-exists", .builtin = .meta_feature_exists },
        .{ .name = "function-exists", .builtin = .meta_function_exists },
        .{ .name = "get-function", .builtin = .meta_get_function },
        .{ .name = "get-mixin", .builtin = .meta_get_mixin },
        .{ .name = "global-variable-exists", .builtin = .meta_global_variable_exists },
        .{ .name = "inspect", .builtin = .meta_inspect },
        .{ .name = "mixin-exists", .builtin = .meta_mixin_exists },
        .{ .name = "type-of", .builtin = .meta_type_of },
        .{ .name = "variable-exists", .builtin = .meta_variable_exists },
        .{ .name = "quote", .builtin = .quote },
        .{ .name = "unquote", .builtin = .unquote },
        .{ .name = "str-length", .builtin = .str_length },
        .{ .name = "str-index", .builtin = .str_index },
        .{ .name = "str-slice", .builtin = .str_slice },
        .{ .name = "str-insert", .builtin = .str_insert },
        .{ .name = "to-upper-case", .builtin = .to_upper_case },
        .{ .name = "to-lower-case", .builtin = .to_lower_case },
        .{ .name = "rgb", .builtin = .rgb },
        .{ .name = "rgba", .builtin = .rgba },
        .{ .name = "hsl", .builtin = .hsl },
        .{ .name = "hsla", .builtin = .hsla },
        .{ .name = "hwb", .builtin = .hwb },
        .{ .name = "lab", .builtin = .lab },
        .{ .name = "lch", .builtin = .lch },
        .{ .name = "oklab", .builtin = .oklab },
        .{ .name = "oklch", .builtin = .oklch },
        .{ .name = "color", .builtin = .color },
        .{ .name = "red", .builtin = .red },
        .{ .name = "green", .builtin = .green },
        .{ .name = "blue", .builtin = .blue },
        .{ .name = "alpha", .builtin = .alpha },
        .{ .name = "opacity", .builtin = .opacity },
        .{ .name = "hue", .builtin = .hue },
        .{ .name = "saturation", .builtin = .saturation },
        .{ .name = "lightness", .builtin = .lightness },
        .{ .name = "mix", .builtin = .mix },
        .{ .name = "lighten", .builtin = .lighten },
        .{ .name = "darken", .builtin = .darken },
        .{ .name = "saturate", .builtin = .saturate },
        .{ .name = "desaturate", .builtin = .desaturate },
        .{ .name = "adjust-hue", .builtin = .adjust_hue },
        .{ .name = "complement", .builtin = .complement },
        .{ .name = "grayscale", .builtin = .grayscale },
        .{ .name = "invert", .builtin = .invert },
        .{ .name = "opacify", .builtin = .opacify },
        .{ .name = "fade-in", .builtin = .fade_in },
        .{ .name = "transparentize", .builtin = .transparentize },
        .{ .name = "fade-out", .builtin = .fade_out },
        .{ .name = "ie-hex-str", .builtin = .ie_hex_str },
        .{ .name = "adjust-color", .builtin = .adjust_color },
        .{ .name = "change-color", .builtin = .change_color },
        .{ .name = "scale-color", .builtin = .scale_color },
        .{ .name = "calc", .builtin = .calculation },
        .{ .name = "min", .builtin = .minimum },
        .{ .name = "max", .builtin = .maximum },
        .{ .name = "clamp", .builtin = .clamp },
        .{ .name = "hypot", .builtin = .math_hypot },
    };
    for (definitions) |definition| {
        if (sassNameEql(name, definition.name)) return definition.builtin;
    }
    return null;
}

fn globalCallableBuiltin(name: []const u8) ?Builtin {
    if (sassNameEql(name, "is-superselector")) return .selector_is_superselector;
    if (sassNameEql(name, "keywords")) return .meta_keywords;
    if (sassNameEql(name, "selector-extend")) return .selector_extend;
    if (sassNameEql(name, "selector-replace")) return .selector_replace;
    if (sassNameEql(name, "selector-nest")) return .selector_nest;
    if (sassNameEql(name, "selector-unify")) return .selector_unify;
    if (sassNameEql(name, "simple-selectors")) return .selector_simple_selectors;
    const builtin = globalBuiltin(name) orelse return null;
    // A CSS-compatible calculation name can have native direct-call behavior
    // without being a legacy Sass function that reflection may construct.
    // Keep this list evidence-driven rather than inferring sibling functions.
    return switch (builtin) {
        .math_acos,
        .math_asin,
        .math_atan,
        .math_atan2,
        .math_log,
        .math_pow,
        .math_sqrt,
        .math_sin,
        .math_cos,
        .math_tan,
        .math_hypot,
        .clamp,
        => null,
        else => builtin,
    };
}

fn metaModuleBuiltin(name: []const u8) ?Builtin {
    if (sassNameEql(name, "accepts-content")) return .meta_accepts_content;
    if (sassNameEql(name, "calc-args")) return .meta_calc_args;
    if (sassNameEql(name, "calc-name")) return .meta_calc_name;
    if (sassNameEql(name, "call")) return .meta_call;
    if (sassNameEql(name, "content-exists")) return .meta_content_exists;
    if (sassNameEql(name, "feature-exists")) return .meta_feature_exists;
    if (sassNameEql(name, "function-exists")) return .meta_function_exists;
    if (sassNameEql(name, "get-function")) return .meta_get_function;
    if (sassNameEql(name, "get-mixin")) return .meta_get_mixin;
    if (sassNameEql(name, "global-variable-exists")) return .meta_global_variable_exists;
    if (sassNameEql(name, "inspect")) return .meta_inspect;
    if (sassNameEql(name, "keywords")) return .meta_keywords;
    if (sassNameEql(name, "mixin-exists")) return .meta_mixin_exists;
    if (sassNameEql(name, "type-of")) return .meta_type_of;
    if (sassNameEql(name, "variable-exists")) return .meta_variable_exists;
    return null;
}

fn selectorModuleBuiltin(name: []const u8) ?Builtin {
    if (sassNameEql(name, "append")) return .selector_append;
    if (sassNameEql(name, "extend")) return .selector_extend;
    if (sassNameEql(name, "is-superselector")) return .selector_is_superselector;
    if (sassNameEql(name, "nest")) return .selector_nest;
    if (sassNameEql(name, "parse")) return .selector_parse;
    if (sassNameEql(name, "replace")) return .selector_replace;
    if (sassNameEql(name, "simple-selectors")) return .selector_simple_selectors;
    if (sassNameEql(name, "unify")) return .selector_unify;
    return null;
}

fn selectorModuleOwnsFunction(name: []const u8) bool {
    const functions = [_][]const u8{
        "append",
        "extend",
        "is-superselector",
        "nest",
        "parse",
        "replace",
        "simple-selectors",
        "unify",
    };
    for (functions) |function| {
        if (sassNameEql(name, function)) return true;
    }
    return false;
}

fn stringModuleBuiltin(name: []const u8) ?Builtin {
    if (sassNameEql(name, "quote")) return .quote;
    if (sassNameEql(name, "unquote")) return .unquote;
    if (sassNameEql(name, "length")) return .str_length;
    if (sassNameEql(name, "index")) return .str_index;
    if (sassNameEql(name, "slice")) return .str_slice;
    if (sassNameEql(name, "insert")) return .str_insert;
    if (sassNameEql(name, "to-upper-case")) return .to_upper_case;
    if (sassNameEql(name, "to-lower-case")) return .to_lower_case;
    return null;
}

fn calculationDimensionsProvablyIncompatible(
    left: native_value.Number,
    right: native_value.Number,
) bool {
    const left_dimension = calculationDimension(left);
    const right_dimension = calculationDimension(right);
    if (left_dimension == .unknown or right_dimension == .unknown) return false;
    if (left_dimension == right_dimension) return false;
    return !((left_dimension == .percentage and right_dimension == .length) or
        (left_dimension == .length and right_dimension == .percentage));
}

fn calculationDimension(number: native_value.Number) CalculationDimension {
    if (number.denominator_units.len != 0 or number.numerator_units.len > 1) return .unknown;
    if (number.numerator_units.len == 0) return .number;
    const unit = number.numerator_units[0];
    if (std.mem.eql(u8, unit, "%")) return .percentage;
    if (calculationUnitIn(unit, &.{
        "px",    "cm",    "mm",    "q",    "in",  "pc",    "pt",
        "em",    "rem",   "ex",    "rex",  "cap", "rcap",  "ch",
        "rch",   "ic",    "ric",   "lh",   "rlh", "vw",    "vh",
        "vi",    "vb",    "vmin",  "vmax", "svw", "svh",   "svi",
        "svb",   "svmin", "svmax", "lvw",  "lvh", "lvi",   "lvb",
        "lvmin", "lvmax", "dvw",   "dvh",  "dvi", "dvb",   "dvmin",
        "dvmax", "cqw",   "cqh",   "cqi",  "cqb", "cqmin", "cqmax",
    })) return .length;
    if (calculationUnitIn(unit, &.{ "deg", "grad", "rad", "turn" })) return .angle;
    if (calculationUnitIn(unit, &.{ "s", "ms" })) return .time;
    if (calculationUnitIn(unit, &.{ "Hz", "kHz" })) return .frequency;
    if (calculationUnitIn(unit, &.{ "dpi", "dpcm", "dppx" })) return .resolution;
    return .unknown;
}

fn calculationUnitIn(unit: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, unit, candidate)) return true;
    }
    return false;
}

fn containsDeferredCssCalculation(input: []const u8) bool {
    const functions = [_][]const u8{
        "var",
        "env",
        "attr",
        "calc",
        "min",
        "max",
        "clamp",
        "round",
        "mod",
        "rem",
        "sin",
        "cos",
        "tan",
        "asin",
        "acos",
        "atan",
        "atan2",
        "pow",
        "sqrt",
        "hypot",
        "log",
        "exp",
        "abs",
        "sign",
    };
    var index: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\' and index + 1 < input.len) {
                index += 2;
            } else {
                if (byte == active) quote = null;
                index += 1;
            }
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            index += 1;
            continue;
        }
        if (byte == '\\' and index + 1 < input.len) {
            index += 2;
            continue;
        }
        if (commentEnd(input, index)) |end| {
            index = end;
            continue;
        }
        if (index > 0 and isVariableNameContinue(input[index - 1])) {
            index += 1;
            continue;
        }
        for (functions) |name| {
            if (index + name.len >= input.len or input[index + name.len] != '(') continue;
            if (std.ascii.eqlIgnoreCase(input[index .. index + name.len], name)) return true;
        }
        index += 1;
    }
    return false;
}

const sass_calculation_names = [_][]const u8{
    "calc", "min",  "max",   "clamp", "round", "mod",  "rem",
    "sin",  "cos",  "tan",   "asin",  "acos",  "atan", "atan2",
    "pow",  "sqrt", "hypot", "log",   "exp",   "abs",  "sign",
};

fn sassCalculationValue(input: []const u8) ?SassCalculationValue {
    const opening = std.mem.indexOfScalar(u8, input, '(') orelse return null;
    if (opening == 0 or !fullyWrapped(input[opening..], '(', ')')) return null;
    const raw_name = input[0..opening];
    for (sass_calculation_names) |name| {
        if (calculationIdentifierEql(raw_name, name)) {
            return .{
                .name = name,
                .body = input[opening + 1 .. input.len - 1],
            };
        }
    }
    return null;
}

fn isSassCalculationValue(input: []const u8) bool {
    return sassCalculationValue(input) != null;
}

const DecodedCalculationScalar = struct {
    scalar: u21,
    end: usize,
};

fn legacyIfIdentifierEql(input: []const u8) bool {
    var input_index: usize = 0;
    for ("if") |expected| {
        const decoded = decodeCalculationIdentifierScalar(input, input_index) orelse
            return false;
        if (decoded.scalar != expected) return false;
        input_index = decoded.end;
    }
    return input_index == input.len;
}

fn isModernCssIfClause(input: []const u8) bool {
    var clause = trimWhitespace(input);
    while (std.mem.startsWith(u8, clause, "not") and clause.len > "not".len and
        isExpressionWhitespace(clause["not".len]))
    {
        clause = trimWhitespace(clause["not".len..]);
    }
    while (fullyWrapped(clause, '(', ')')) {
        clause = trimWhitespace(clause[1 .. clause.len - 1]);
    }
    const opening = std.mem.indexOfScalar(u8, clause, '(') orelse return false;
    const name = clause[0..opening];
    const functions = [_][]const u8{ "sass", "style", "media", "supports" };
    for (functions) |function| {
        if (calculationIdentifierEql(name, function)) return true;
    }
    return false;
}

fn calculationIdentifierEql(input: []const u8, expected: []const u8) bool {
    var input_index: usize = 0;
    var expected_index: usize = 0;
    while (input_index < input.len) {
        const decoded = decodeCalculationIdentifierScalar(input, input_index) orelse return false;
        input_index = decoded.end;
        if (decoded.scalar > std.math.maxInt(u8) or expected_index >= expected.len) {
            return false;
        }
        const byte: u8 = @intCast(decoded.scalar);
        if (std.ascii.toLower(byte) != expected[expected_index]) return false;
        expected_index += 1;
    }
    return expected_index == expected.len;
}

fn cssFunctionNameScalarAllowed(scalar: u21, ordinal: usize, escaped: bool) bool {
    if (scalar >= 0x80) return true;
    const byte: u8 = @intCast(scalar);
    if (escaped) return byte != 0;
    if (std.ascii.isAlphabetic(byte) or byte == '_' or byte == '-') return true;
    return ordinal > 0 and std.ascii.isDigit(byte);
}

fn decodeCalculationIdentifierScalar(
    input: []const u8,
    start: usize,
) ?DecodedCalculationScalar {
    if (start >= input.len) return null;
    if (input[start] != '\\') {
        const length = std.unicode.utf8ByteSequenceLength(input[start]) catch return null;
        const end = std.math.add(usize, start, length) catch return null;
        if (end > input.len) return null;
        return .{
            .scalar = std.unicode.utf8Decode(input[start..end]) catch return null,
            .end = end,
        };
    }
    var cursor = start + 1;
    if (cursor >= input.len or input[cursor] == 0 or input[cursor] == '\n' or
        input[cursor] == '\r' or input[cursor] == '\x0c')
    {
        return null;
    }
    if (std.ascii.isHex(input[cursor])) {
        var scalar: u32 = 0;
        var digits: usize = 0;
        while (cursor < input.len and digits < 6 and std.ascii.isHex(input[cursor])) {
            scalar = scalar * 16 + calculationHexValue(input[cursor]);
            cursor += 1;
            digits += 1;
        }
        if (cursor < input.len and isExpressionWhitespace(input[cursor])) {
            if (input[cursor] == '\r' and cursor + 1 < input.len and input[cursor + 1] == '\n') {
                cursor += 2;
            } else {
                cursor += 1;
            }
        }
        const normalized: u21 = if (scalar == 0 or scalar > 0x10ffff or
            (scalar >= 0xd800 and scalar <= 0xdfff))
            0xfffd
        else
            @intCast(scalar);
        return .{ .scalar = normalized, .end = cursor };
    }
    const length = std.unicode.utf8ByteSequenceLength(input[cursor]) catch return null;
    const end = std.math.add(usize, cursor, length) catch return null;
    if (end > input.len) return null;
    return .{
        .scalar = std.unicode.utf8Decode(input[cursor..end]) catch return null,
        .end = end,
    };
}

fn calculationHexValue(byte: u8) u32 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    return byte - 'A' + 10;
}

fn calculationArgumentCount(input: []const u8) usize {
    if (trimWhitespace(input).len == 0) return 0;
    var count: usize = 1;
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var curly_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\' and index + 1 < input.len) {
                index += 2;
                continue;
            }
            if (byte == active) quote = null;
            index += 1;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            index += 1;
            continue;
        }
        if (byte == '\\' and index + 1 < input.len) {
            index += 2;
            continue;
        }
        if (commentEnd(input, index)) |end| {
            index = end;
            continue;
        }
        switch (byte) {
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => if (square_depth > 0) {
                square_depth -= 1;
            },
            '{' => curly_depth += 1,
            '}' => if (curly_depth > 0) {
                curly_depth -= 1;
            },
            ',' => if (paren_depth == 0 and square_depth == 0 and curly_depth == 0) {
                count +|= 1;
            },
            else => {},
        }
        index += 1;
    }
    return count;
}

fn minifyCalculationArgumentCommas(input: []u8) []const u8 {
    var read: usize = 0;
    var write: usize = 0;
    var paren_depth: usize = 0;
    var quote: ?u8 = null;
    while (read < input.len) {
        const byte = input[read];
        if (quote) |active| {
            input[write] = byte;
            write += 1;
            read += 1;
            if (byte == '\\' and read < input.len) {
                input[write] = input[read];
                write += 1;
                read += 1;
            } else if (byte == active) {
                quote = null;
            }
            continue;
        }
        if (byte == '\\' and read + 1 < input.len) {
            input[write] = byte;
            input[write + 1] = input[read + 1];
            write += 2;
            read += 2;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            input[write] = byte;
            write += 1;
            read += 1;
            continue;
        }
        if (commentEnd(input, read)) |end| {
            std.mem.copyForwards(u8, input[write .. write + end - read], input[read..end]);
            write += end - read;
            read = end;
            continue;
        }
        if (byte == '(') paren_depth += 1;
        if (byte == ')' and paren_depth > 0) paren_depth -= 1;
        if (byte != ',' or paren_depth != 1) {
            input[write] = byte;
            write += 1;
            read += 1;
            continue;
        }
        while (write > 0 and isExpressionWhitespace(input[write - 1])) write -= 1;
        input[write] = ',';
        write += 1;
        read += 1;
        while (read < input.len and isExpressionWhitespace(input[read])) read += 1;
    }
    return input[0..write];
}

fn whitespaceIsOperatorPadding(input: []const u8, start: usize, end: usize) bool {
    if (end < input.len) {
        const next = input[end];
        if (isSymbolicExpressionOperator(next) or startsSassWord(input, end, "and") or
            startsSassWord(input, end, "or"))
        {
            return true;
        }
    }
    if (start > 0) {
        const previous = input[start - 1];
        if (isSymbolicExpressionOperator(previous) or endsSassWord(input, start, "and") or
            endsSassWord(input, start, "or") or endsSassWord(input, start, "not"))
        {
            return true;
        }
    }
    return false;
}

fn colorWhitespaceIsOperatorPadding(input: []const u8, start: usize, end: usize) bool {
    if (end < input.len) {
        const next = input[end];
        if ((next == '+' or next == '-') and
            end + 1 < input.len and !isExpressionWhitespace(input[end + 1]))
        {
            return false;
        }
        if ((isSymbolicExpressionOperator(next) and next != '%') or
            startsSassWord(input, end, "and") or startsSassWord(input, end, "or"))
        {
            return true;
        }
    }
    if (start > 0) {
        const previous = input[start - 1];
        if ((isSymbolicExpressionOperator(previous) and previous != '%') or
            endsSassWord(input, start, "and") or endsSassWord(input, start, "or") or
            endsSassWord(input, start, "not"))
        {
            return true;
        }
    }
    return false;
}

fn isSymbolicExpressionOperator(byte: u8) bool {
    return switch (byte) {
        '+', '-', '*', '/', '%', '=', '!', '<', '>', '&', '|', '^', '~', '?' => true,
        else => false,
    };
}

fn startsSassWord(input: []const u8, start: usize, word: []const u8) bool {
    if (start + word.len > input.len or !std.mem.eql(u8, input[start .. start + word.len], word)) {
        return false;
    }
    const end = start + word.len;
    return end == input.len or !isVariableNameContinue(input[end]);
}

fn endsSassWord(input: []const u8, end: usize, word: []const u8) bool {
    if (end < word.len or !std.mem.eql(u8, input[end - word.len .. end], word)) return false;
    return end == word.len or !isVariableNameContinue(input[end - word.len - 1]);
}

fn nativeMapView(item: native_value.Value) ?native_value.Map {
    return switch (item) {
        .map => |map| map,
        .list => |list| if (list.items.len == 0) .{ .entries = &.{} } else null,
        .argument_list => |argument_list| if (argument_list.positional.len == 0)
            .{ .entries = &.{} }
        else
            null,
        else => null,
    };
}

fn sassListSeparator(item: native_value.Value) native_value.Separator {
    return switch (item) {
        .list => |list| if (list.separator == .legacy_slash) .space else list.separator,
        .map => |map| if (map.entries.len == 0) .undecided else .comma,
        .argument_list => .comma,
        else => .space,
    };
}

fn sassKnownListSeparator(item: native_value.Value) ?native_value.Separator {
    return switch (item) {
        .list => |list| switch (list.separator) {
            .undecided, .legacy_slash => null,
            .space, .comma, .slash => list.separator,
        },
        .map => |map| if (map.entries.len == 0) null else .comma,
        .argument_list => .comma,
        else => null,
    };
}

fn sassJoinSeparator(
    first: native_value.Value,
    second: native_value.Value,
) native_value.Separator {
    return sassKnownListSeparator(first) orelse
        sassKnownListSeparator(second) orelse
        .space;
}

fn canonicalAppendSeparator(separator: native_value.Separator) native_value.Separator {
    return switch (separator) {
        .undecided, .legacy_slash => .space,
        .space, .comma, .slash => separator,
    };
}

fn sassListLength(item: native_value.Value) usize {
    return switch (item) {
        .list => |list| if (list.separator == .legacy_slash) 1 else list.items.len,
        .map => |map| map.entries.len,
        .argument_list => |argument_list| argument_list.positional.len,
        else => 1,
    };
}

fn sassTruthy(item: native_value.Value) bool {
    return switch (item) {
        .null_value => false,
        .boolean => |value| value,
        else => true,
    };
}

fn sassValuesEqual(left: native_value.Value, right: native_value.Value) bool {
    return sassValuesEqualDepth(left, right, 0);
}

fn sassValuesEqualDepth(left: native_value.Value, right: native_value.Value, depth: u16) bool {
    if (depth > 64) return false;
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) {
        return switch (left) {
            .argument_list => |argument_list| switch (right) {
                .list => |list| argumentListEqualsList(argument_list, list, depth),
                else => false,
            },
            .list => |list| switch (right) {
                .argument_list => |argument_list| argumentListEqualsList(
                    argument_list,
                    list,
                    depth,
                ),
                else => false,
            },
            else => false,
        };
    }
    return switch (left) {
        .null_value => true,
        .boolean => |value| value == right.boolean,
        .number => |number| native_numeric.equal(
            native_numeric.Numeric.fromNumber(number) catch return false,
            native_numeric.Numeric.fromNumber(right.number) catch return false,
        ),
        .color => |color| native_color.equal(color, right.color),
        .string => |string| std.mem.eql(u8, string.bytes, right.string.bytes),
        .selector => |selector| std.mem.eql(u8, selector.bytes, right.selector.bytes),
        .callable => |callable| std.meta.eql(callable, right.callable),
        .list => |list| blk: {
            const other = right.list;
            if (list.separator != other.separator or list.bracketed != other.bracketed or
                list.items.len != other.items.len)
            {
                break :blk false;
            }
            for (list.items, other.items) |item, other_item| {
                if (!sassValuesEqualDepth(item, other_item, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .map => |map| blk: {
            const other = right.map;
            if (map.entries.len != other.entries.len) break :blk false;
            for (map.entries) |entry| {
                var matched = false;
                for (other.entries) |other_entry| {
                    if (sassValuesEqualDepth(entry.key, other_entry.key, depth + 1) and
                        sassValuesEqualDepth(entry.value, other_entry.value, depth + 1))
                    {
                        matched = true;
                        break;
                    }
                }
                if (!matched) break :blk false;
            }
            break :blk true;
        },
        .argument_list => |argument_list| blk: {
            const other = right.argument_list;
            if (argument_list.positional.len != other.positional.len or
                argument_list.keywords.len != other.keywords.len)
            {
                break :blk false;
            }
            for (argument_list.positional, other.positional) |item, other_item| {
                if (!sassValuesEqualDepth(item, other_item, depth + 1)) break :blk false;
            }
            for (argument_list.keywords, other.keywords) |keyword, other_keyword| {
                if (keyword.normalize_name != other_keyword.normalize_name or
                    !std.mem.eql(u8, keyword.name, other_keyword.name) or
                    !sassValuesEqualDepth(keyword.value, other_keyword.value, depth + 1))
                {
                    break :blk false;
                }
            }
            break :blk true;
        },
    };
}

fn argumentListEqualsList(
    argument_list: native_value.ArgumentList,
    list: native_value.List,
    depth: u16,
) bool {
    if (argument_list.keywords.len > 0 or list.bracketed or
        argument_list.positional.len != list.items.len)
    {
        return false;
    }
    if (list.items.len > 1 and list.separator != .comma) return false;
    for (argument_list.positional, list.items) |item, other_item| {
        if (!sassValuesEqualDepth(item, other_item, depth + 1)) return false;
    }
    return true;
}

fn cssValueIsValid(item: native_value.Value, depth: u16) bool {
    if (depth > 64) return false;
    return switch (item) {
        .null_value, .boolean, .string, .selector => true,
        .number => |number| blk: {
            const numeric = native_numeric.Numeric.fromNumber(number) catch break :blk false;
            break :blk numeric.isCssNumber();
        },
        .list => |list| blk: {
            var emitted: usize = 0;
            for (list.items) |child| {
                if (child == .null_value) continue;
                if (!cssValueIsValid(child, depth + 1)) break :blk false;
                emitted += 1;
            }
            break :blk list.bracketed or emitted > 0;
        },
        .argument_list => |argument_list| blk: {
            if (argument_list.keywords.len > 0) break :blk false;
            var emitted: usize = 0;
            for (argument_list.positional) |child| {
                if (child == .null_value) continue;
                if (!cssValueIsValid(child, depth + 1)) break :blk false;
                emitted += 1;
            }
            break :blk emitted > 0;
        },
        .color => |color| blk: {
            var buffer: [native_color.max_serialized_bytes]u8 = undefined;
            _ = native_color.serialize(color, &buffer, true) catch break :blk false;
            break :blk true;
        },
        .map, .callable => false,
    };
}

fn isDeferredColorValue(item: native_value.Value) bool {
    return switch (item) {
        .string, .selector => |string| !string.quoted and
            containsDeferredCssCalculation(string.bytes),
        else => false,
    };
}

fn parseColorPercentagePair(input: []const u8) ?[2]f64 {
    const trimmed = trimWhitespace(input);
    var separator: usize = 0;
    while (separator < trimmed.len and !isExpressionWhitespace(trimmed[separator])) {
        separator += 1;
    }
    if (separator == 0 or separator == trimmed.len) return null;
    var second_start = separator;
    while (second_start < trimmed.len and isExpressionWhitespace(trimmed[second_start])) {
        second_start += 1;
    }
    if (second_start == trimmed.len) return null;
    for (trimmed[second_start..]) |byte| {
        if (isExpressionWhitespace(byte)) return null;
    }
    const pieces = [2][]const u8{ trimmed[0..separator], trimmed[second_start..] };
    var result: [2]f64 = undefined;
    for (pieces, 0..) |piece, index| {
        if (piece.len < 2 or piece[piece.len - 1] != '%') return null;
        const value = std.fmt.parseFloat(f64, piece[0 .. piece.len - 1]) catch return null;
        if (!std.math.isFinite(value)) return null;
        result[index] = value;
    }
    return result;
}

fn parseStaticModernColorChannels(
    input: []const u8,
    kinds: []const ModernColorChannelKind,
    output: []ModernColorChannel,
) bool {
    if (kinds.len == 0 or kinds.len != output.len) return false;
    const trimmed = trimWhitespace(input);
    var cursor: usize = 0;
    for (kinds, output) |kind, *channel| {
        while (cursor < trimmed.len and isExpressionWhitespace(trimmed[cursor])) {
            cursor += 1;
        }
        const start = cursor;
        while (cursor < trimmed.len and !isExpressionWhitespace(trimmed[cursor])) {
            cursor += 1;
        }
        if (start == cursor) return false;
        channel.* = parseStaticModernColorChannel(trimmed[start..cursor], kind) orelse return false;
    }
    while (cursor < trimmed.len and isExpressionWhitespace(trimmed[cursor])) {
        cursor += 1;
    }
    return cursor == trimmed.len;
}

fn parseStaticModernColorChannel(
    input: []const u8,
    kind: ModernColorChannelKind,
) ?ModernColorChannel {
    if (std.mem.eql(u8, input, "none")) return .{ .missing = true };
    if (kind == .hue) return parseStaticColorHue(input);
    const percentage = input.len > 1 and input[input.len - 1] == '%';
    const number_bytes = if (percentage) input[0 .. input.len - 1] else input;
    const value = std.fmt.parseFloat(f64, number_bytes) catch return null;
    if (!std.math.isFinite(value)) return null;
    return .{ .value = switch (kind) {
        .lab_lightness => value,
        .oklab_lightness => if (percentage) value / 100 else value,
        .lab_axis => if (percentage) value * 1.25 else value,
        .oklab_axis => if (percentage) value * 0.004 else value,
        .lch_chroma => if (percentage) value * 1.5 else value,
        .oklch_chroma => if (percentage) value * 0.004 else value,
        .predefined, .alpha => if (percentage) value / 100 else value,
        .hue => unreachable,
    } };
}

fn predefinedColorSpaceName(name: []const u8) ?native_value.ColorSpace {
    if (std.ascii.eqlIgnoreCase(name, "srgb")) return .srgb;
    if (std.ascii.eqlIgnoreCase(name, "srgb-linear")) return .srgb_linear;
    if (std.ascii.eqlIgnoreCase(name, "display-p3")) return .display_p3;
    if (std.ascii.eqlIgnoreCase(name, "a98-rgb")) return .a98_rgb;
    if (std.ascii.eqlIgnoreCase(name, "prophoto-rgb")) return .prophoto_rgb;
    if (std.ascii.eqlIgnoreCase(name, "rec2020")) return .rec2020;
    if (std.ascii.eqlIgnoreCase(name, "xyz-d50")) return .xyz_d50;
    if (std.ascii.eqlIgnoreCase(name, "xyz") or
        std.ascii.eqlIgnoreCase(name, "xyz-d65")) return .xyz;
    return null;
}

fn parseStaticColorHue(input: []const u8) ?ModernColorChannel {
    const units = [_]struct {
        name: []const u8,
        factor: f64,
    }{
        .{ .name = "deg", .factor = 1 },
        .{ .name = "grad", .factor = 0.9 },
        .{ .name = "rad", .factor = 180.0 / std.math.pi },
        .{ .name = "turn", .factor = 360 },
    };
    for (units) |unit| {
        if (input.len <= unit.name.len) continue;
        const suffix = input[input.len - unit.name.len ..];
        if (!std.ascii.eqlIgnoreCase(suffix, unit.name)) continue;
        const value = std.fmt.parseFloat(
            f64,
            input[0 .. input.len - unit.name.len],
        ) catch return null;
        if (!std.math.isFinite(value)) return null;
        return .{ .value = value * unit.factor };
    }
    const value = std.fmt.parseFloat(f64, input) catch return null;
    if (!std.math.isFinite(value)) return null;
    return .{ .value = value };
}

fn isExpressionWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '\x0c';
}

fn splitSelectors(
    allocator: std.mem.Allocator,
    input: []const u8,
    output: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    var start: usize = 0;
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\' and index + 1 < input.len) {
                index += 1;
            } else if (byte == active) {
                quote = null;
            }
            continue;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => square_depth += 1,
            ']' => if (square_depth > 0) {
                square_depth -= 1;
            },
            ',' => if (paren_depth == 0 and square_depth == 0) {
                const item = trimWhitespace(input[start..index]);
                if (item.len > 0) try output.append(allocator, item);
                start = index + 1;
            },
            else => {},
        }
    }
    const final = trimWhitespace(input[start..]);
    if (final.len > 0) try output.append(allocator, final);
}

const SelectorOperationStats = struct {
    count: u64 = 0,
    length_sum: u64 = 0,
    length_square_sum: u64 = 0,
};

fn selectorExtensionOperationBudget(
    selector_input: []const u8,
    extendee_input: []const u8,
    extender_input: []const u8,
    max_results: usize,
    retains_original_paths: bool,
) ?u64 {
    if (max_results == 0) return 1;
    const first_length = std.math.add(
        usize,
        selector_input.len,
        extendee_input.len,
    ) catch return null;
    const total_length = std.math.add(
        usize,
        first_length,
        extender_input.len,
    ) catch return null;
    const width = std.math.add(usize, total_length, 1) catch return null;
    const width_u64 = std.math.cast(u64, width) orelse return null;
    const width_square = std.math.mul(u64, width_u64, width_u64) catch return null;

    var result_bound: u64 = 1;
    if (retains_original_paths) {
        // Count structural simple selectors, including members nested inside
        // selector-list pseudos. This remains an upper bound on independently
        // replaceable compounds without treating every identifier byte as a
        // separate exponential branch.
        const occurrence_bound = selectorExtensionSimpleBound(selector_input) orelse
            return null;
        const maximum = std.math.cast(u64, max_results) orelse return null;
        for (0..occurrence_bound) |_| {
            if (result_bound >= maximum) break;
            result_bound = std.math.mul(u64, result_bound, 2) catch return null;
            result_bound = @min(result_bound, maximum);
        }
    } else {
        const selector_stats = selectorOperationStats(selector_input) orelse return null;
        const maximum = std.math.cast(u64, max_results) orelse return null;
        result_bound = @max(@min(selector_stats.count, maximum), 1);
    }
    const comparison_bound = std.math.mul(
        u64,
        result_bound,
        result_bound,
    ) catch return null;
    const work = std.math.mul(u64, width_square, comparison_bound) catch return null;
    return std.math.mul(u64, work, 8) catch return null;
}

fn selectorExtensionSimpleBound(input: []const u8) ?usize {
    var count: usize = 0;
    var index: usize = 0;
    var compound_start = true;
    while (index < input.len) {
        const byte = input[index];
        if (byte == '\\') {
            if (index + 1 >= input.len) return null;
            index += 2;
            compound_start = false;
            continue;
        }
        if (std.ascii.isWhitespace(byte) or
            byte == ',' or byte == '>' or byte == '+' or byte == '~' or
            byte == '(')
        {
            compound_start = true;
            index += 1;
            continue;
        }
        if (byte == ')') {
            compound_start = false;
            index += 1;
            continue;
        }
        if (byte == '[') {
            count = std.math.add(usize, count, 1) catch return null;
            var depth: usize = 1;
            var quote: ?u8 = null;
            index += 1;
            while (index < input.len and depth != 0) {
                const nested = input[index];
                if (quote) |active| {
                    if (nested == '\\') {
                        if (index + 1 >= input.len) return null;
                        index += 2;
                        continue;
                    }
                    if (nested == active) quote = null;
                    index += 1;
                    continue;
                }
                switch (nested) {
                    '\'', '"' => quote = nested,
                    '[' => depth = std.math.add(usize, depth, 1) catch return null,
                    ']' => depth -= 1,
                    else => {},
                }
                index += 1;
            }
            if (depth != 0 or quote != null) return null;
            compound_start = false;
            continue;
        }
        if (byte == '.' or byte == '#' or byte == '%' or byte == '&') {
            count = std.math.add(usize, count, 1) catch return null;
            compound_start = false;
            index += 1;
            continue;
        }
        if (byte == ':') {
            count = std.math.add(usize, count, 1) catch return null;
            index += 1;
            if (index < input.len and input[index] == ':') index += 1;
            while (index < input.len) {
                const name_byte = input[index];
                if (name_byte == '\\') {
                    if (index + 1 >= input.len) return null;
                    index += 2;
                    continue;
                }
                if (name_byte == '(' or name_byte == ')' or name_byte == ',' or
                    name_byte == '.' or name_byte == '#' or name_byte == '%' or
                    name_byte == '[' or name_byte == ']' or name_byte == ':' or
                    name_byte == '>' or name_byte == '+' or name_byte == '~' or
                    std.ascii.isWhitespace(name_byte))
                {
                    break;
                }
                index += 1;
            }
            compound_start = false;
            continue;
        }
        if (compound_start) {
            count = std.math.add(usize, count, 1) catch return null;
            compound_start = false;
        }
        index += 1;
    }
    return @max(count, 1);
}

fn selectorUnifyOperationBudget(left: []const u8, right: []const u8) ?u64 {
    const left_stats = selectorOperationStats(left) orelse return null;
    const right_stats = selectorOperationStats(right) orelse return null;
    const left_term = std.math.mul(
        u64,
        right_stats.count,
        left_stats.length_square_sum,
    ) catch return null;
    const right_term = std.math.mul(
        u64,
        left_stats.count,
        right_stats.length_square_sum,
    ) catch return null;
    const cross_product = std.math.mul(
        u64,
        left_stats.length_sum,
        right_stats.length_sum,
    ) catch return null;
    const cross_term = std.math.mul(u64, cross_product, 2) catch return null;
    const partial = std.math.add(u64, left_term, right_term) catch return null;
    return std.math.add(u64, partial, cross_term) catch return null;
}

fn selectorOperationStats(input: []const u8) ?SelectorOperationStats {
    var stats = SelectorOperationStats{};
    var start: usize = 0;
    var index: usize = 0;
    var paren_depth: usize = 0;
    var square_depth: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\' and index + 1 < input.len) {
                index += 1;
            } else if (byte == active) {
                quote = null;
            }
            continue;
        }
        if (byte == '\\' and index + 1 < input.len) {
            index += 1;
            continue;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '(' => paren_depth += 1,
            ')' => paren_depth -|= 1,
            '[' => square_depth += 1,
            ']' => square_depth -|= 1,
            ',' => if (paren_depth == 0 and square_depth == 0) {
                addSelectorOperationSegment(&stats, input[start..index]) orelse
                    return null;
                start = index + 1;
            },
            else => {},
        }
    }
    addSelectorOperationSegment(&stats, input[start..]) orelse return null;
    if (stats.count == 0) {
        stats.count = 1;
        stats.length_sum = 1;
        stats.length_square_sum = 1;
    }
    return stats;
}

fn addSelectorOperationSegment(
    stats: *SelectorOperationStats,
    raw: []const u8,
) ?void {
    const segment = trimWhitespace(raw);
    if (segment.len == 0) return {};
    const length = std.math.add(
        u64,
        @as(u64, @intCast(segment.len)),
        1,
    ) catch return null;
    const square = std.math.mul(u64, length, length) catch return null;
    stats.count = std.math.add(u64, stats.count, 1) catch return null;
    stats.length_sum = std.math.add(u64, stats.length_sum, length) catch return null;
    stats.length_square_sum = std.math.add(
        u64,
        stats.length_square_sum,
        square,
    ) catch return null;
}

fn findInterpolationEnd(input: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var index = start;
    var quote: ?u8 = null;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\' and index + 1 < input.len) {
                index += 1;
            } else if (byte == active) {
                quote = null;
            }
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '{') {
            depth += 1;
        } else if (byte == '}') {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

fn arithmeticStart(token: native_lexer.Token, raw: []const u8) bool {
    return switch (token.kind) {
        .number, .variable, .identifier, .open_paren => true,
        .operator => blk: {
            const operation = token.raw(raw);
            break :blk std.mem.eql(u8, operation, "+") or std.mem.eql(u8, operation, "-");
        },
        else => false,
    };
}

fn isExpressionTrivia(kind: native_lexer.Kind) bool {
    return switch (kind) {
        .whitespace, .newline, .comment => true,
        else => false,
    };
}

fn trimWhitespace(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n\x0c");
}

fn parseUseDirective(input: []const u8) ?ParsedUse {
    const raw = trimWhitespace(input);
    if (raw.len < 3 or (raw[0] != '\'' and raw[0] != '"')) return null;
    const quote = raw[0];
    var closing: ?usize = null;
    var index: usize = 1;
    while (index < raw.len) : (index += 1) {
        if (raw[index] == '\\') return null;
        if (raw[index] == quote) {
            closing = index;
            break;
        }
    }
    const end = closing orelse return null;
    const url = raw[1..end];
    if (url.len == 0 or std.mem.indexOf(u8, url, "#{") != null) return null;

    const tail = trimWhitespace(raw[end + 1 ..]);
    if (tail.len == 0) return .{ .url = url };
    if (tail.len < 3 or !std.mem.startsWith(u8, tail, "as") or
        std.mem.indexOfScalar(u8, " \t\r\n\x0c", tail[2]) == null)
    {
        return null;
    }
    const alias = trimWhitespace(tail[2..]);
    if (std.mem.eql(u8, alias, "*")) {
        return .{ .url = url, .unprefixed = true };
    }
    if (!isSimpleIdentifier(alias)) return null;
    return .{ .url = url, .namespace = alias };
}

fn parseQualifiedName(input: []const u8) ?QualifiedName {
    const dot = std.mem.indexOfScalar(u8, input, '.') orelse return null;
    if (std.mem.indexOfScalar(u8, input[dot + 1 ..], '.') != null) return null;
    const namespace = input[0..dot];
    const member = input[dot + 1 ..];
    if (!isSimpleIdentifier(namespace) or !isSimpleIdentifier(member)) return null;
    return .{ .namespace = namespace, .member = member };
}

fn parseQualifiedVariable(input: []const u8) ?QualifiedName {
    const dot = std.mem.indexOfScalar(u8, input, '.') orelse return null;
    const namespace = input[0..dot];
    const variable = input[dot + 1 ..];
    if (!isSimpleIdentifier(namespace) or variable.len < 2 or variable[0] != '$') return null;
    if (!isVariableNameStart(variable[1]) or variableEnd(variable, 1) != variable.len) return null;
    return .{ .namespace = namespace, .member = variable[1..] };
}

fn deterministicRandomSeed(bytes: []const u8) u64 {
    // Stable FNV-1a over the root bytes deliberately excludes paths, process
    // state, clocks, and host entropy so serial and parallel builds agree.
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    hash ^= @as(u64, @intCast(bytes.len));
    return hash;
}

fn variableEnd(input: []const u8, start: usize) usize {
    var index = start;
    while (index < input.len and isVariableNameContinue(input[index])) index += 1;
    return index;
}

fn isVariableNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '-' or byte >= 0x80;
}

fn isVariableNameContinue(byte: u8) bool {
    return isVariableNameStart(byte) or std.ascii.isDigit(byte);
}

fn replaceableAmpersandCount(input: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    var quote: ?u8 = null;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (quote) |active| {
            if (byte == '\\' and index + 1 < input.len) {
                index += 1;
            } else if (byte == active) {
                quote = null;
            }
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '\\' and index + 1 < input.len) {
            index += 1;
        } else if (byte == '&') {
            count += 1;
        }
    }
    return count;
}

fn selectorPower(base: usize, exponent: usize) error{SelectorLimitExceeded}!usize {
    var result: usize = 1;
    for (0..exponent) |_| {
        result = std.math.mul(usize, result, base) catch return error.SelectorLimitExceeded;
        if (result > hard_selectors) return error.SelectorLimitExceeded;
    }
    return result;
}

fn selectorParentIndex(
    parent_count: usize,
    varying_ampersands: usize,
    occurrence: usize,
    ordinal: usize,
) usize {
    var divisor: usize = 1;
    const following = varying_ampersands - occurrence - 1;
    for (0..following) |_| divisor *= parent_count;
    return (ordinal / divisor) % parent_count;
}

fn slashDivisionEnabled(input: []const u8) bool {
    const trimmed = trimWhitespace(input);
    return std.mem.indexOfScalar(u8, trimmed, '$') != null or
        (trimmed.len >= 2 and trimmed[0] == '(' and trimmed[trimmed.len - 1] == ')');
}
