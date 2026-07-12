const std = @import("std");
const ast = @import("css/ast.zig");
const diagnostics = @import("diagnostics.zig");
const module_names = @import("css/module_names.zig");
const pipeline = @import("css/pipeline.zig");
const source = @import("source.zig");

pub const Export = module_names.Entry;

/// Hard limits for result-owned CSS Modules metadata and source identity work.
pub const Limits = struct {
    max_exports: usize = 100_000,
    max_owned_bytes: usize = 64 * 1024 * 1024,
    max_source_name_bytes: usize = 64 * 1024,
};

/// Compilation-temporary lookup data plus result-transferable export entries.
/// `lookup_entries` borrows the strings owned by `exports`.
pub const Prepared = struct {
    allocator: std.mem.Allocator,
    exports: []Export,
    lookup_entries: []Export,

    pub fn init(allocator: std.mem.Allocator) Prepared {
        return .{ .allocator = allocator, .exports = &.{}, .lookup_entries = &.{} };
    }

    pub fn deinit(self: *Prepared) void {
        const allocator = self.allocator;
        if (self.lookup_entries.len > 0) allocator.free(self.lookup_entries);
        release(allocator, self.exports);
        self.* = init(allocator);
    }

    pub fn lookup(self: *const Prepared) []const Export {
        return self.lookup_entries;
    }

    pub fn takeExports(self: *Prepared) []Export {
        if (self.lookup_entries.len > 0) self.allocator.free(self.lookup_entries);
        self.lookup_entries = &.{};
        const exports = self.exports;
        self.exports = &.{};
        return exports;
    }
};

pub fn release(allocator: std.mem.Allocator, entries: []const Export) void {
    if (entries.len == 0) return;
    for (entries) |entry| {
        if (entry.name.len > 0) allocator.free(entry.name);
        if (entry.value.len > 0) allocator.free(entry.value);
    }
    allocator.free(entries);
}

pub fn prepare(
    allocator: std.mem.Allocator,
    parsed: *pipeline.ParsedStylesheet,
    limits: Limits,
) !Prepared {
    if (parsed.hasErrors()) return Prepared.init(allocator);
    const file = parsed.file();
    if (file.name.len == 0) {
        try reportAtStart(
            parsed,
            .invalid_option,
            "CSS Modules requires a non-empty source identity",
        );
        return Prepared.init(allocator);
    }
    if (file.name.len > limits.max_source_name_bytes) {
        try reportAtStart(
            parsed,
            .resource_limit,
            "CSS Modules source identity limit exceeded",
        );
        return Prepared.init(allocator);
    }

    var builder = try Builder.init(allocator, file.name, limits);
    defer builder.deinit();
    var walker = Walker{ .parsed = parsed, .builder = &builder };
    walker.ruleList(parsed.rules) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Rejected => return Prepared.init(allocator),
    };
    return builder.finish();
}

const Builder = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    items: std.ArrayList(Export),
    digests: std.AutoHashMapUnmanaged([std.crypto.hash.sha2.Sha256.digest_length]u8, usize),
    module_hasher: std.crypto.hash.sha2.Sha256,
    owned_bytes: usize = 0,

    fn init(allocator: std.mem.Allocator, source_name: []const u8, limits: Limits) !Builder {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("zigcss.css-modules.v1\x00");
        updateLength(&hasher, source_name.len);
        updateNormalizedSourceName(&hasher, source_name);
        return .{
            .allocator = allocator,
            .limits = limits,
            .items = try std.ArrayList(Export).initCapacity(allocator, 0),
            .digests = .empty,
            .module_hasher = hasher,
        };
    }

    fn deinit(self: *Builder) void {
        for (self.items.items) |entry| {
            if (entry.name.len > 0) self.allocator.free(entry.name);
            if (entry.value.len > 0) self.allocator.free(entry.value);
        }
        self.items.deinit(self.allocator);
        self.digests.deinit(self.allocator);
    }

    fn add(self: *Builder, name: []const u8) (std.mem.Allocator.Error || error{
        LimitExceeded,
        NameCollision,
    })!void {
        const digest = classDigest(self.module_hasher, name);
        if (self.digests.get(digest)) |index| {
            if (std.mem.eql(u8, self.items.items[index].name, name)) return;
            return error.NameCollision;
        }
        const generated_len = generatedNameLength(name);
        const entry_bytes = std.math.add(usize, name.len, generated_len) catch return error.LimitExceeded;
        const next_owned = std.math.add(usize, self.owned_bytes, entry_bytes) catch return error.LimitExceeded;
        if (self.items.items.len >= self.limits.max_exports or
            next_owned > self.limits.max_owned_bytes)
        {
            return error.LimitExceeded;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        const generated = generatedName(self.allocator, name, digest) catch |err| {
            if (owned_name.len > 0) self.allocator.free(owned_name);
            return err;
        };
        self.items.append(self.allocator, .{ .name = owned_name, .value = generated }) catch |err| {
            if (owned_name.len > 0) self.allocator.free(owned_name);
            if (generated.len > 0) self.allocator.free(generated);
            return err;
        };
        self.digests.put(self.allocator, digest, self.items.items.len - 1) catch |err| {
            const removed = self.items.pop().?;
            if (removed.name.len > 0) self.allocator.free(removed.name);
            if (removed.value.len > 0) self.allocator.free(removed.value);
            return err;
        };
        self.owned_bytes = next_owned;
    }

    fn finish(self: *Builder) !Prepared {
        const exports = try self.items.toOwnedSlice(self.allocator);
        errdefer release(self.allocator, exports);
        if (exports.len == 0) return Prepared.init(self.allocator);
        const lookup_entries = try self.allocator.dupe(Export, exports);
        errdefer self.allocator.free(lookup_entries);
        std.mem.sort(Export, lookup_entries, {}, lessThanExportName);
        try module_names.validate(lookup_entries);
        return .{
            .allocator = self.allocator,
            .exports = exports,
            .lookup_entries = lookup_entries,
        };
    }
};

const WalkError = std.mem.Allocator.Error || error{Rejected};

const Walker = struct {
    parsed: *pipeline.ParsedStylesheet,
    builder: *Builder,

    fn ruleList(self: *Walker, list: *const ast.RuleList) WalkError!void {
        for (list.rules) |rule| switch (rule) {
            .style_rule => |style| {
                try self.selectorList(&style.selectors);
                try self.declarationList(&style.block.declarations);
                try self.ruleList(&style.block.rules);
            },
            .at_rule => |at_rule| try self.atRule(at_rule),
            .nested_declarations => |nested| try self.declarationList(&nested.declarations),
        };
    }

    fn atRule(self: *Walker, at_rule: *const ast.AtRule) WalkError!void {
        if (std.ascii.eqlIgnoreCase(at_rule.name.value, "value")) {
            return self.reject(
                at_rule.span,
                "CSS Modules @value semantics are deferred to MODULE-002",
            );
        }
        if (!isAllowedAtRule(at_rule.name.value)) {
            return self.reject(
                at_rule.span,
                "at-rule is outside the CSS Modules native subset",
            );
        }
        switch (at_rule.block) {
            .none => {},
            .declarations => |block| try self.declarationList(&block.declarations),
            .rules => |block| try self.ruleList(&block.rules),
            .keyframes => |block| for (block.frames) |frame| {
                try self.declarationList(&frame.block.declarations);
            },
            .raw => return self.reject(
                at_rule.span,
                "raw at-rule blocks are outside the CSS Modules native subset",
            ),
        }
    }

    fn declarationList(self: *Walker, list: *const ast.DeclarationList) WalkError!void {
        for (list.declarations) |declaration| {
            if (std.ascii.eqlIgnoreCase(declaration.name.value, "composes") or
                std.ascii.eqlIgnoreCase(declaration.name.value, "composes-with"))
            {
                return self.reject(
                    declaration.span,
                    "CSS Modules composition semantics are deferred to MODULE-002",
                );
            }
        }
    }

    fn selectorList(self: *Walker, list: *const ast.SelectorList) WalkError!void {
        for (list.selectors) |selector| {
            try self.compound(selector.head);
            for (selector.tails) |tail| try self.compound(tail.compound);
        }
    }

    fn compound(self: *Walker, value: ast.CompoundSelector) WalkError!void {
        for (value.simple_selectors) |simple| switch (simple) {
            .class => |class| self.builder.add(class.name.value) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LimitExceeded => return self.rejectLimit(class.span),
                error.NameCollision => return self.rejectCollision(class.span),
            },
            .pseudo_class => |selector| try self.pseudo(
                selector.name,
                selector.arguments,
                selector.span,
            ),
            .pseudo_element => |selector| try self.pseudo(
                selector.name,
                selector.arguments,
                selector.span,
            ),
            else => {},
        };
    }

    fn pseudo(
        self: *Walker,
        name: ast.Identifier,
        arguments: ?ast.PseudoArguments,
        span: source.Span,
    ) WalkError!void {
        if (isDeferredPseudo(name.value)) {
            return self.reject(
                span,
                "CSS Modules local/global, import, and export semantics are deferred to MODULE-002",
            );
        }
        const args = arguments orelse return;
        const parsed = args.parsed orelse return self.reject(
            span,
            "untyped functional pseudos are outside the CSS Modules native subset",
        );
        switch (parsed) {
            .selector_list => |list| try self.selectorList(list),
        }
    }

    fn reject(self: *Walker, span: source.Span, message: []const u8) WalkError!void {
        self.parsed.compilation.report(
            .err,
            .unsupported_syntax,
            span,
            message,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSpan, error.UnknownSource, error.SourceMismatch => unreachable,
        };
        return error.Rejected;
    }

    fn rejectLimit(self: *Walker, span: source.Span) WalkError!void {
        self.parsed.compilation.report(
            .err,
            .resource_limit,
            span,
            "CSS Modules export metadata limit exceeded",
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSpan, error.UnknownSource, error.SourceMismatch => unreachable,
        };
        return error.Rejected;
    }

    fn rejectCollision(self: *Walker, span: source.Span) WalkError!void {
        self.parsed.compilation.report(
            .err,
            .internal,
            span,
            "CSS Modules generated-name collision",
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSpan, error.UnknownSource, error.SourceMismatch => unreachable,
        };
        return error.Rejected;
    }
};

fn reportAtStart(
    parsed: *pipeline.ParsedStylesheet,
    code: diagnostics.Code,
    message: []const u8,
) !void {
    try parsed.compilation.report(
        .err,
        code,
        .{ .source = parsed.source_id, .start = 0, .end = 0 },
        message,
    );
}

fn isDeferredPseudo(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "local") or
        std.ascii.eqlIgnoreCase(name, "global") or
        std.ascii.eqlIgnoreCase(name, "import") or
        std.ascii.eqlIgnoreCase(name, "export");
}

fn isAllowedAtRule(name: []const u8) bool {
    const allowed = [_][]const u8{
        "charset",
        "import",
        "namespace",
        "media",
        "container",
        "layer",
        "starting-style",
        "font-face",
        "property",
        "keyframes",
        "-webkit-keyframes",
        "-moz-keyframes",
    };
    for (allowed) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn lessThanExportName(_: void, left: Export, right: Export) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

const generated_prefix = "_zigcss_";
const readable_name_bytes: usize = 32;

fn generatedNameLength(name: []const u8) usize {
    return generated_prefix.len + @min(name.len, readable_name_bytes) + 1 +
        std.crypto.hash.sha2.Sha256.digest_length * 2;
}

fn generatedName(
    allocator: std.mem.Allocator,
    name: []const u8,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
) ![]u8 {
    const hex = std.fmt.bytesToHex(digest, .lower);

    const generated = try allocator.alloc(u8, generatedNameLength(name));
    var cursor: usize = 0;
    @memcpy(generated[cursor..][0..generated_prefix.len], generated_prefix);
    cursor += generated_prefix.len;
    for (name[0..@min(name.len, readable_name_bytes)]) |byte| {
        generated[cursor] = if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')
            byte
        else
            '_';
        cursor += 1;
    }
    generated[cursor] = '_';
    cursor += 1;
    @memcpy(generated[cursor..][0..hex.len], &hex);
    return generated;
}

fn classDigest(
    module_hasher: std.crypto.hash.sha2.Sha256,
    name: []const u8,
) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var hasher = module_hasher;
    updateLength(&hasher, name.len);
    hasher.update(name);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn updateLength(hasher: *std.crypto.hash.sha2.Sha256, length: usize) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(length), .little);
    hasher.update(&bytes);
}

fn updateNormalizedSourceName(
    hasher: *std.crypto.hash.sha2.Sha256,
    name: []const u8,
) void {
    var segment_start: usize = 0;
    for (name, 0..) |byte, index| {
        if (byte != '\\') continue;
        hasher.update(name[segment_start..index]);
        hasher.update("/");
        segment_start = index + 1;
    }
    hasher.update(name[segment_start..]);
}

test "CSS Modules naming is versioned deterministic and file-specific" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "src/components/card.module.css",
        ".card,.icon,.card{x:1}",
    );
    defer parsed.deinit();
    var prepared = try prepare(std.testing.allocator, &parsed, .{});
    defer prepared.deinit();

    try std.testing.expectEqual(@as(usize, 2), prepared.exports.len);
    try std.testing.expectEqualStrings("card", prepared.exports[0].name);
    try std.testing.expectEqualStrings("icon", prepared.exports[1].name);
    try std.testing.expectEqualStrings(
        "_zigcss_card_dc24bbe8d795b4acd4603a9012d82fe05d1cbbdf460b501067387017bf4f5be3",
        prepared.exports[0].value,
    );
    try module_names.validate(prepared.lookup());
}
