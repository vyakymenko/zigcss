const std = @import("std");
const ast = @import("css/ast.zig");
const dependencies = @import("dependencies.zig");
const diagnostics = @import("diagnostics.zig");
const module_names = @import("css/module_names.zig");
const pipeline = @import("css/pipeline.zig");
const selector_parser = @import("css/selector_parser.zig");
const source = @import("source.zig");
const syntax = @import("syntax.zig");
const tokenizer = @import("tokenizer.zig");

pub const DependencyReference = struct {
    name: []const u8,
    specifier: []const u8,
};

pub const Reference = union(enum) {
    local: []const u8,
    global: []const u8,
    dependency: DependencyReference,
};

pub const Export = struct {
    name: []const u8,
    value: []const u8,
    composes: []const Reference = &.{},
};

/// Hard limits for result-owned CSS Modules metadata and source identity work.
pub const Limits = struct {
    max_exports: usize = 100_000,
    max_owned_bytes: usize = 64 * 1024 * 1024,
    max_source_name_bytes: usize = 64 * 1024,
    max_rewrites: usize = 1_000_000,
    max_references: usize = 100_000,
};

/// Compilation-temporary lookup data plus result-transferable export entries.
/// `lookup_entries` borrows the strings owned by `exports`.
pub const Prepared = struct {
    allocator: std.mem.Allocator,
    exports: []Export,
    class_rewrites: []module_names.Occurrence,
    scope_rewrites: []module_names.Scope,
    dependency_candidates: []dependencies.Candidate,
    omitted_declarations: []source.Span,
    value_rewrites: []module_names.Replacement,
    omitted_rules: []source.Span,

    pub fn init(allocator: std.mem.Allocator) Prepared {
        return .{
            .allocator = allocator,
            .exports = &.{},
            .class_rewrites = &.{},
            .scope_rewrites = &.{},
            .dependency_candidates = &.{},
            .omitted_declarations = &.{},
            .value_rewrites = &.{},
            .omitted_rules = &.{},
        };
    }

    pub fn deinit(self: *Prepared) void {
        const allocator = self.allocator;
        if (self.class_rewrites.len > 0) allocator.free(self.class_rewrites);
        if (self.scope_rewrites.len > 0) allocator.free(self.scope_rewrites);
        if (self.dependency_candidates.len > 0) allocator.free(self.dependency_candidates);
        if (self.omitted_declarations.len > 0) allocator.free(self.omitted_declarations);
        if (self.value_rewrites.len > 0) allocator.free(self.value_rewrites);
        if (self.omitted_rules.len > 0) allocator.free(self.omitted_rules);
        release(allocator, self.exports);
        self.* = init(allocator);
    }

    pub fn classes(self: *const Prepared) []const module_names.Occurrence {
        return self.class_rewrites;
    }

    pub fn scopes(self: *const Prepared) []const module_names.Scope {
        return self.scope_rewrites;
    }

    pub fn dependencyCandidates(self: *const Prepared) []const dependencies.Candidate {
        return self.dependency_candidates;
    }

    pub fn declarationsToOmit(self: *const Prepared) []const source.Span {
        return self.omitted_declarations;
    }

    pub fn values(self: *const Prepared) []const module_names.Replacement {
        return self.value_rewrites;
    }

    pub fn rulesToOmit(self: *const Prepared) []const source.Span {
        return self.omitted_rules;
    }

    pub fn takeExports(self: *Prepared) []Export {
        if (self.class_rewrites.len > 0) self.allocator.free(self.class_rewrites);
        if (self.scope_rewrites.len > 0) self.allocator.free(self.scope_rewrites);
        if (self.dependency_candidates.len > 0) self.allocator.free(self.dependency_candidates);
        if (self.omitted_declarations.len > 0) self.allocator.free(self.omitted_declarations);
        if (self.value_rewrites.len > 0) self.allocator.free(self.value_rewrites);
        if (self.omitted_rules.len > 0) self.allocator.free(self.omitted_rules);
        self.class_rewrites = &.{};
        self.scope_rewrites = &.{};
        self.dependency_candidates = &.{};
        self.omitted_declarations = &.{};
        self.value_rewrites = &.{};
        self.omitted_rules = &.{};
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
        releaseReferences(allocator, entry.composes);
    }
    allocator.free(entries);
}

fn releaseReferences(allocator: std.mem.Allocator, references: []const Reference) void {
    if (references.len == 0) return;
    for (references) |reference| switch (reference) {
        .local => |name| if (name.len > 0) allocator.free(name),
        .global => |name| if (name.len > 0) allocator.free(name),
        .dependency => |dependency| {
            if (dependency.name.len > 0) allocator.free(dependency.name);
            if (dependency.specifier.len > 0) allocator.free(dependency.specifier);
        },
    };
    allocator.free(references);
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
    walker.collectValueDefinitions(parsed.rules) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Rejected => return Prepared.init(allocator),
    };
    walker.ruleList(parsed.rules, true) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Rejected => return Prepared.init(allocator),
    };
    walker.resolveCompositions() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Rejected => return Prepared.init(allocator),
    };
    return builder.finish();
}

const CompositionName = struct {
    value: []const u8,
    span: source.Span,
};

const CompositionSource = union(enum) {
    local,
    global,
    dependency: struct {
        specifier: []const u8,
        span: source.Span,
    },
};

const CompositionSpec = struct {
    target_name: []const u8,
    target_span: source.Span,
    names: []CompositionName,
    source_kind: CompositionSource,
    declaration_span: source.Span,
};

const CompositionFailure = struct {
    kind: enum { unsupported, limit },
    span: source.Span,
    message: []const u8,
};

const LocalEdge = struct {
    from: usize,
    to: usize,
    span: source.Span,
};

const ValueDefinition = struct {
    name: []const u8,
    name_span: source.Span,
    value: []u8,
    single_identifier: ?[]const u8,
    single_string: ?[]const u8,
    rule_span: source.Span,
    published: bool = false,
};

const ValueMetadata = struct {
    single_identifier: ?[]const u8 = null,
    single_string: ?[]const u8 = null,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    items: std.ArrayList(Export),
    class_rewrites: std.ArrayList(module_names.Occurrence),
    scope_rewrites: std.ArrayList(module_names.Scope),
    composition_specs: std.ArrayList(CompositionSpec),
    dependency_candidates: std.ArrayList(dependencies.Candidate),
    omitted_declarations: std.ArrayList(source.Span),
    definitions: std.ArrayList(ValueDefinition),
    definition_names: std.StringHashMapUnmanaged(usize),
    export_names: std.StringHashMapUnmanaged(usize),
    value_rewrites: std.ArrayList(module_names.Replacement),
    omitted_rules: std.ArrayList(source.Span),
    digests: std.AutoHashMapUnmanaged([std.crypto.hash.sha2.Sha256.digest_length]u8, usize),
    module_hasher: std.crypto.hash.sha2.Sha256,
    owned_bytes: usize = 0,
    reference_count: usize = 0,
    next_definition_to_publish: usize = 0,

    fn init(allocator: std.mem.Allocator, source_name: []const u8, limits: Limits) !Builder {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("zigcss.css-modules.v1\x00");
        updateLength(&hasher, source_name.len);
        updateNormalizedSourceName(&hasher, source_name);
        return .{
            .allocator = allocator,
            .limits = limits,
            .items = try std.ArrayList(Export).initCapacity(allocator, 0),
            .class_rewrites = try std.ArrayList(module_names.Occurrence).initCapacity(allocator, 0),
            .scope_rewrites = try std.ArrayList(module_names.Scope).initCapacity(allocator, 0),
            .composition_specs = try std.ArrayList(CompositionSpec).initCapacity(allocator, 0),
            .dependency_candidates = try std.ArrayList(dependencies.Candidate).initCapacity(allocator, 0),
            .omitted_declarations = try std.ArrayList(source.Span).initCapacity(allocator, 0),
            .definitions = try std.ArrayList(ValueDefinition).initCapacity(allocator, 0),
            .definition_names = .empty,
            .export_names = .empty,
            .value_rewrites = try std.ArrayList(module_names.Replacement).initCapacity(allocator, 0),
            .omitted_rules = try std.ArrayList(source.Span).initCapacity(allocator, 0),
            .digests = .empty,
            .module_hasher = hasher,
        };
    }

    fn deinit(self: *Builder) void {
        for (self.items.items) |entry| {
            if (entry.name.len > 0) self.allocator.free(entry.name);
            if (entry.value.len > 0) self.allocator.free(entry.value);
            releaseReferences(self.allocator, entry.composes);
        }
        self.items.deinit(self.allocator);
        self.class_rewrites.deinit(self.allocator);
        self.scope_rewrites.deinit(self.allocator);
        for (self.composition_specs.items) |spec| {
            if (spec.names.len > 0) self.allocator.free(spec.names);
        }
        self.composition_specs.deinit(self.allocator);
        self.dependency_candidates.deinit(self.allocator);
        self.omitted_declarations.deinit(self.allocator);
        for (self.definitions.items) |definition| {
            if (!definition.published and definition.value.len > 0) {
                self.allocator.free(definition.value);
            }
        }
        self.definitions.deinit(self.allocator);
        self.definition_names.deinit(self.allocator);
        self.export_names.deinit(self.allocator);
        self.value_rewrites.deinit(self.allocator);
        self.omitted_rules.deinit(self.allocator);
        self.digests.deinit(self.allocator);
    }

    fn addClass(
        self: *Builder,
        name: []const u8,
        span: source.Span,
        scope_mode: ScopeMode,
    ) (std.mem.Allocator.Error || error{
        LimitExceeded,
        NameCollision,
        DuplicateExport,
    })!void {
        if (self.rewriteCount() >= self.limits.max_rewrites) return error.LimitExceeded;
        const replacement = switch (scope_mode) {
            .local => try self.localName(name),
            .global => name,
        };
        try self.class_rewrites.append(self.allocator, .{
            .span = span,
            .value = replacement,
        });
    }

    fn addScope(
        self: *Builder,
        span: source.Span,
        compound: *const ast.CompoundSelector,
    ) (std.mem.Allocator.Error || error{LimitExceeded})!void {
        if (self.rewriteCount() >= self.limits.max_rewrites) return error.LimitExceeded;
        try self.scope_rewrites.append(self.allocator, .{
            .span = span,
            .compound = compound,
        });
    }

    fn rewriteCount(self: *const Builder) usize {
        const selector_rewrites = std.math.add(
            usize,
            self.class_rewrites.items.len,
            self.scope_rewrites.items.len,
        ) catch std.math.maxInt(usize);
        const value_rewrites = std.math.add(
            usize,
            self.value_rewrites.items.len,
            self.omitted_rules.items.len,
        ) catch std.math.maxInt(usize);
        const semantic_omissions = std.math.add(
            usize,
            self.omitted_declarations.items.len,
            value_rewrites,
        ) catch std.math.maxInt(usize);
        return std.math.add(usize, selector_rewrites, semantic_omissions) catch
            std.math.maxInt(usize);
    }

    fn addComposition(
        self: *Builder,
        spec: CompositionSpec,
    ) (std.mem.Allocator.Error || error{LimitExceeded})!void {
        errdefer if (spec.names.len > 0) self.allocator.free(spec.names);
        if (self.rewriteCount() >= self.limits.max_rewrites) return error.LimitExceeded;
        const next_references = std.math.add(
            usize,
            self.reference_count,
            spec.names.len,
        ) catch return error.LimitExceeded;
        if (next_references > self.limits.max_references) return error.LimitExceeded;

        try self.composition_specs.append(self.allocator, spec);
        errdefer _ = self.composition_specs.pop();
        try self.omitted_declarations.append(self.allocator, spec.declaration_span);
        errdefer _ = self.omitted_declarations.pop();
        switch (spec.source_kind) {
            .dependency => |dependency| try self.dependency_candidates.append(
                self.allocator,
                .{
                    .kind = .css_module,
                    .specifier = dependency.specifier,
                    .span = dependency.span,
                },
            ),
            else => {},
        }
        self.reference_count = next_references;
    }

    fn addDefinition(
        self: *Builder,
        definition: ValueDefinition,
    ) (std.mem.Allocator.Error || error{ LimitExceeded, DuplicateValue })!void {
        errdefer if (definition.value.len > 0) self.allocator.free(definition.value);
        if (self.definitions.items.len >= self.limits.max_exports) {
            return error.LimitExceeded;
        }
        if (self.definition_names.contains(definition.name)) return error.DuplicateValue;
        try self.definitions.append(self.allocator, definition);
        errdefer _ = self.definitions.pop();
        try self.definition_names.put(
            self.allocator,
            definition.name,
            self.definitions.items.len - 1,
        );
    }

    fn findDefinition(self: *const Builder, name: []const u8) ?*const ValueDefinition {
        const index = self.definition_names.get(name) orelse return null;
        return &self.definitions.items[index];
    }

    fn publishNextDefinition(
        self: *Builder,
        span: source.Span,
    ) (std.mem.Allocator.Error || error{
        LimitExceeded,
        DuplicateExport,
        InvalidDefinitionOrder,
    })!void {
        if (self.next_definition_to_publish >= self.definitions.items.len) {
            return error.InvalidDefinitionOrder;
        }
        const definition = &self.definitions.items[self.next_definition_to_publish];
        if (!spansEqual(definition.rule_span, span) or definition.published) {
            return error.InvalidDefinitionOrder;
        }
        if (self.rewriteCount() >= self.limits.max_rewrites) return error.LimitExceeded;
        if (self.export_names.contains(definition.name)) return error.DuplicateExport;
        const entry_bytes = std.math.add(
            usize,
            definition.name.len,
            definition.value.len,
        ) catch return error.LimitExceeded;
        const next_owned = std.math.add(
            usize,
            self.owned_bytes,
            entry_bytes,
        ) catch return error.LimitExceeded;
        if (self.items.items.len >= self.limits.max_exports or
            next_owned > self.limits.max_owned_bytes)
        {
            return error.LimitExceeded;
        }

        try self.omitted_rules.append(self.allocator, span);
        errdefer _ = self.omitted_rules.pop();
        const owned_name = try self.allocator.dupe(u8, definition.name);
        self.items.append(self.allocator, .{
            .name = owned_name,
            .value = definition.value,
        }) catch |err| {
            if (owned_name.len > 0) self.allocator.free(owned_name);
            return err;
        };
        errdefer {
            _ = self.items.pop();
            if (owned_name.len > 0) self.allocator.free(owned_name);
        }
        try self.export_names.put(
            self.allocator,
            owned_name,
            self.items.items.len - 1,
        );
        definition.published = true;
        self.next_definition_to_publish += 1;
        self.owned_bytes = next_owned;
    }

    fn addValueRewrite(
        self: *Builder,
        span: source.Span,
        value: []const u8,
    ) (std.mem.Allocator.Error || error{LimitExceeded})!void {
        if (self.rewriteCount() >= self.limits.max_rewrites) return error.LimitExceeded;
        try self.value_rewrites.append(self.allocator, .{ .span = span, .value = value });
    }

    fn localName(self: *Builder, name: []const u8) (std.mem.Allocator.Error || error{
        LimitExceeded,
        NameCollision,
        DuplicateExport,
    })![]const u8 {
        const digest = classDigest(self.module_hasher, name);
        if (self.digests.get(digest)) |index| {
            if (std.mem.eql(u8, self.items.items[index].name, name)) {
                return self.items.items[index].value;
            }
            return error.NameCollision;
        }
        if (self.export_names.contains(name)) return error.DuplicateExport;
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
        self.items.append(self.allocator, .{
            .name = owned_name,
            .value = generated,
        }) catch |err| {
            if (owned_name.len > 0) self.allocator.free(owned_name);
            if (generated.len > 0) self.allocator.free(generated);
            return err;
        };
        self.digests.put(self.allocator, digest, self.items.items.len - 1) catch |err| {
            const removed = self.items.pop().?;
            if (removed.name.len > 0) self.allocator.free(removed.name);
            if (removed.value.len > 0) self.allocator.free(removed.value);
            releaseReferences(self.allocator, removed.composes);
            return err;
        };
        self.export_names.put(
            self.allocator,
            owned_name,
            self.items.items.len - 1,
        ) catch |err| {
            _ = self.digests.remove(digest);
            const removed = self.items.pop().?;
            if (removed.name.len > 0) self.allocator.free(removed.name);
            if (removed.value.len > 0) self.allocator.free(removed.value);
            return err;
        };
        self.owned_bytes = next_owned;
        return generated;
    }

    fn classIndex(self: *const Builder, name: []const u8) ?usize {
        const digest = classDigest(self.module_hasher, name);
        const index = self.digests.get(digest) orelse return null;
        if (!std.mem.eql(u8, self.items.items[index].name, name)) return null;
        return index;
    }

    fn applyCompositions(self: *Builder) std.mem.Allocator.Error!?CompositionFailure {
        if (self.composition_specs.items.len == 0) return null;

        const export_count = self.items.items.len;
        const resolved_targets = try self.allocator.alloc(usize, self.composition_specs.items.len);
        defer self.allocator.free(resolved_targets);
        const counts = try self.allocator.alloc(usize, export_count);
        defer self.allocator.free(counts);
        @memset(counts, 0);
        var edges = try std.ArrayList(LocalEdge).initCapacity(self.allocator, 0);
        defer edges.deinit(self.allocator);
        var reference_bytes: usize = 0;

        for (self.composition_specs.items, 0..) |spec, spec_index| {
            const target = self.classIndex(spec.target_name) orelse return .{
                .kind = .unsupported,
                .span = spec.target_span,
                .message = "CSS Modules composition target is not a local class export",
            };
            resolved_targets[spec_index] = target;
            counts[target] = std.math.add(usize, counts[target], spec.names.len) catch return .{
                .kind = .limit,
                .span = spec.declaration_span,
                .message = "CSS Modules composition reference limit exceeded",
            };

            for (spec.names) |name| switch (spec.source_kind) {
                .local => {
                    const referenced = self.classIndex(name.value) orelse return .{
                        .kind = .unsupported,
                        .span = name.span,
                        .message = "CSS Modules local composition references an unknown class",
                    };
                    try edges.append(self.allocator, .{
                        .from = target,
                        .to = referenced,
                        .span = name.span,
                    });
                    reference_bytes = std.math.add(
                        usize,
                        reference_bytes,
                        self.items.items[referenced].value.len,
                    ) catch return .{
                        .kind = .limit,
                        .span = name.span,
                        .message = "CSS Modules composition metadata limit exceeded",
                    };
                },
                .global => reference_bytes = std.math.add(
                    usize,
                    reference_bytes,
                    name.value.len,
                ) catch return .{
                    .kind = .limit,
                    .span = name.span,
                    .message = "CSS Modules composition metadata limit exceeded",
                },
                .dependency => |dependency| {
                    reference_bytes = std.math.add(
                        usize,
                        reference_bytes,
                        std.math.add(usize, name.value.len, dependency.specifier.len) catch
                            return .{
                                .kind = .limit,
                                .span = name.span,
                                .message = "CSS Modules composition metadata limit exceeded",
                            },
                    ) catch return .{
                        .kind = .limit,
                        .span = name.span,
                        .message = "CSS Modules composition metadata limit exceeded",
                    };
                },
            };
        }

        const next_owned = std.math.add(usize, self.owned_bytes, reference_bytes) catch return .{
            .kind = .limit,
            .span = self.composition_specs.items[0].declaration_span,
            .message = "CSS Modules composition metadata limit exceeded",
        };
        if (next_owned > self.limits.max_owned_bytes) return .{
            .kind = .limit,
            .span = self.composition_specs.items[0].declaration_span,
            .message = "CSS Modules composition metadata limit exceeded",
        };

        if (try self.compositionCycle(edges.items, export_count)) |span| return .{
            .kind = .unsupported,
            .span = span,
            .message = "CSS Modules local composition cycle is unsupported",
        };

        const positions = try self.allocator.alloc(usize, export_count);
        defer self.allocator.free(positions);
        @memset(positions, 0);
        const reference_storage = try self.allocator.alloc([]Reference, export_count);
        defer self.allocator.free(reference_storage);
        for (reference_storage) |*references| references.* = &.{};
        for (counts, 0..) |count, index| {
            if (count == 0) continue;
            const references = try self.allocator.alloc(Reference, count);
            for (references) |*reference| reference.* = .{ .local = "" };
            reference_storage[index] = references;
            self.items.items[index].composes = references;
        }

        for (self.composition_specs.items, resolved_targets) |spec, target| {
            for (spec.names) |name| {
                const position = positions[target];
                positions[target] += 1;
                const slot = &reference_storage[target][position];
                slot.* = switch (spec.source_kind) {
                    .local => local: {
                        const referenced = self.classIndex(name.value).?;
                        break :local .{
                            .local = try self.allocator.dupe(
                                u8,
                                self.items.items[referenced].value,
                            ),
                        };
                    },
                    .global => .{ .global = try self.allocator.dupe(u8, name.value) },
                    .dependency => |dependency| dependency_ref: {
                        const owned_name = try self.allocator.dupe(u8, name.value);
                        const specifier = self.allocator.dupe(
                            u8,
                            dependency.specifier,
                        ) catch |err| {
                            if (owned_name.len > 0) self.allocator.free(owned_name);
                            return err;
                        };
                        break :dependency_ref .{ .dependency = .{
                            .name = owned_name,
                            .specifier = specifier,
                        } };
                    },
                };
            }
        }
        self.owned_bytes = next_owned;
        return null;
    }

    fn compositionCycle(
        self: *Builder,
        input_edges: []LocalEdge,
        export_count: usize,
    ) std.mem.Allocator.Error!?source.Span {
        if (input_edges.len == 0) return null;
        std.mem.sort(LocalEdge, input_edges, {}, lessThanLocalEdge);
        const offsets = try self.allocator.alloc(usize, export_count + 1);
        defer self.allocator.free(offsets);
        @memset(offsets, 0);
        const indegree = try self.allocator.alloc(usize, export_count);
        defer self.allocator.free(indegree);
        @memset(indegree, 0);
        for (input_edges) |edge| {
            offsets[edge.from + 1] += 1;
            indegree[edge.to] += 1;
        }
        for (offsets[1..], 1..) |*offset, index| offset.* += offsets[index - 1];

        var queue = try std.ArrayList(usize).initCapacity(self.allocator, export_count);
        defer queue.deinit(self.allocator);
        for (indegree, 0..) |degree, index| {
            if (degree == 0) try queue.append(self.allocator, index);
        }
        var cursor: usize = 0;
        while (cursor < queue.items.len) : (cursor += 1) {
            const node = queue.items[cursor];
            for (input_edges[offsets[node]..offsets[node + 1]]) |edge| {
                indegree[edge.to] -= 1;
                if (indegree[edge.to] == 0) try queue.append(self.allocator, edge.to);
            }
        }
        if (queue.items.len == export_count) return null;
        for (input_edges) |edge| {
            if (indegree[edge.from] != 0 and indegree[edge.to] != 0) return edge.span;
        }
        return input_edges[0].span;
    }

    fn finish(self: *Builder) !Prepared {
        if (self.next_definition_to_publish != self.definitions.items.len) {
            return error.InvalidDefinitionOrder;
        }
        const exports = try self.items.toOwnedSlice(self.allocator);
        errdefer release(self.allocator, exports);
        const class_rewrites = try self.class_rewrites.toOwnedSlice(self.allocator);
        errdefer if (class_rewrites.len > 0) self.allocator.free(class_rewrites);
        const scope_rewrites = try self.scope_rewrites.toOwnedSlice(self.allocator);
        errdefer if (scope_rewrites.len > 0) self.allocator.free(scope_rewrites);
        const dependency_candidates = try self.dependency_candidates.toOwnedSlice(self.allocator);
        errdefer if (dependency_candidates.len > 0) self.allocator.free(dependency_candidates);
        const omitted_declarations = try self.omitted_declarations.toOwnedSlice(self.allocator);
        errdefer if (omitted_declarations.len > 0) self.allocator.free(omitted_declarations);
        const value_rewrites = try self.value_rewrites.toOwnedSlice(self.allocator);
        errdefer if (value_rewrites.len > 0) self.allocator.free(value_rewrites);
        const omitted_rules = try self.omitted_rules.toOwnedSlice(self.allocator);
        errdefer if (omitted_rules.len > 0) self.allocator.free(omitted_rules);
        std.mem.sort(module_names.Occurrence, class_rewrites, {}, module_names.lessThanOccurrence);
        std.mem.sort(module_names.Scope, scope_rewrites, {}, module_names.lessThanScope);
        std.mem.sort(source.Span, omitted_declarations, {}, module_names.lessThanSpan);
        std.mem.sort(module_names.Replacement, value_rewrites, {}, module_names.lessThanOccurrence);
        std.mem.sort(source.Span, omitted_rules, {}, module_names.lessThanSpan);
        try module_names.validateOccurrences(class_rewrites);
        try module_names.validateScopes(scope_rewrites);
        try module_names.validateSpans(omitted_declarations);
        try module_names.validateOccurrences(value_rewrites);
        try module_names.validateSpans(omitted_rules);
        return .{
            .allocator = self.allocator,
            .exports = exports,
            .class_rewrites = class_rewrites,
            .scope_rewrites = scope_rewrites,
            .dependency_candidates = dependency_candidates,
            .omitted_declarations = omitted_declarations,
            .value_rewrites = value_rewrites,
            .omitted_rules = omitted_rules,
        };
    }
};

const ScopeMode = enum {
    local,
    global,
};

const CompositionTarget = struct {
    name: []const u8,
    span: source.Span,
};

const WalkError = std.mem.Allocator.Error || error{Rejected};

const Walker = struct {
    parsed: *pipeline.ParsedStylesheet,
    builder: *Builder,

    fn collectValueDefinitions(
        self: *Walker,
        list: *const ast.RuleList,
    ) WalkError!void {
        for (list.rules) |rule| {
            const at_rule = switch (rule) {
                .at_rule => |value| value,
                else => continue,
            };
            if (!std.ascii.eqlIgnoreCase(at_rule.name.value, "value")) continue;
            if (!isTerminatedValueRule(at_rule)) {
                return self.reject(
                    at_rule.span,
                    "CSS Modules @value definitions must be top-level semicolon rules",
                );
            }
            const definition = try self.parseValueDefinition(at_rule);
            self.builder.addDefinition(definition) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LimitExceeded => return self.rejectLimit(at_rule.span),
                error.DuplicateValue => return self.reject(
                    definition.name_span,
                    "CSS Modules value names must be unique",
                ),
            };
        }
    }

    fn parseValueDefinition(
        self: *Walker,
        at_rule: *const ast.AtRule,
    ) WalkError!ValueDefinition {
        const values = at_rule.prelude.values;
        const name_index = nextSignificantValue(values, 0) orelse return self.reject(
            at_rule.span,
            "CSS Modules @value requires a local name and ':'",
        );
        const name_token = tokenAtValue(values[name_index]) orelse return self.reject(
            values[name_index].span(),
            "CSS Modules @value name must be an identifier",
        );
        if (name_token.kind != .ident) {
            return self.reject(name_token.span, "CSS Modules @value name must be an identifier");
        }
        const colon_index = nextSignificantValue(values, name_index + 1) orelse return self.reject(
            at_rule.span,
            "imported CSS Modules @value forms are outside the native subset",
        );
        const colon = tokenAtValue(values[colon_index]) orelse return self.reject(
            values[colon_index].span(),
            "CSS Modules @value requires ':' after its local name",
        );
        if (colon.kind != .colon) {
            return self.reject(
                colon.span,
                "imported CSS Modules @value forms are outside the native subset",
            );
        }
        const value_start = colon_index + 1;
        if (nextSignificantValue(values, value_start) == null) {
            return self.reject(at_rule.span, "CSS Modules @value definition is empty");
        }
        for (values[value_start..]) |value| {
            const token = tokenAtValue(value) orelse continue;
            if (tokenDelimiter(token, '!')) {
                return self.reject(
                    token.span,
                    "CSS Modules @value cannot inject a top-level importance marker",
                );
            }
        }

        const name = try self.decodeToken(name_token);
        const metadata = try self.valueMetadata(values[value_start..]);
        return .{
            .name = name,
            .name_span = name_token.valueSpan() orelse name_token.span,
            .value = try self.serializeValue(values[value_start..]),
            .single_identifier = metadata.single_identifier,
            .single_string = metadata.single_string,
            .rule_span = at_rule.span,
        };
    }

    fn valueMetadata(
        self: *Walker,
        values: []const syntax.ComponentValue,
    ) WalkError!ValueMetadata {
        const first = nextSignificantValue(values, 0) orelse return .{};
        if (nextSignificantValue(values, first + 1) != null) return .{};
        const token = tokenAtValue(values[first]) orelse return .{};
        if (token.kind == .ident) {
            const decoded = try self.decodeToken(token);
            if (self.builder.findDefinition(decoded)) |definition| {
                return .{
                    .single_identifier = definition.single_identifier,
                    .single_string = definition.single_string,
                };
            }
            return .{ .single_identifier = decoded };
        }
        if (token.kind == .string and token.isTerminated()) {
            return .{ .single_string = try self.decodeToken(token) };
        }
        return .{};
    }

    fn serializeValue(
        self: *Walker,
        values: []const syntax.ComponentValue,
    ) WalkError![]u8 {
        var output = try std.ArrayList(u8).initCapacity(self.builder.allocator, 0);
        errdefer output.deinit(self.builder.allocator);
        try self.appendValueComponents(&output, values, true);
        if (output.items.len == 0) {
            return self.reject(
                values[0].span(),
                "CSS Modules @value definition is empty after normalization",
            );
        }
        return output.toOwnedSlice(self.builder.allocator);
    }

    fn appendValueComponents(
        self: *Walker,
        output: *std.ArrayList(u8),
        values: []const syntax.ComponentValue,
        trim_edges: bool,
    ) WalkError!void {
        var wrote_significant = false;
        var pending_space = false;
        for (values) |value| {
            if (isValueTrivia(value)) {
                if (wrote_significant or !trim_edges) pending_space = true;
                continue;
            }
            if (pending_space) try output.append(self.builder.allocator, ' ');
            try self.appendValueComponent(output, value);
            wrote_significant = true;
            pending_space = false;
        }
        if (pending_space and !trim_edges) try output.append(self.builder.allocator, ' ');
    }

    fn appendValueComponent(
        self: *Walker,
        output: *std.ArrayList(u8),
        value: syntax.ComponentValue,
    ) WalkError!void {
        switch (value) {
            .token => |token| {
                if (token.kind == .ident) {
                    const decoded = try self.decodeToken(token);
                    if (self.builder.findDefinition(decoded)) |definition| {
                        try output.appendSlice(self.builder.allocator, definition.value);
                        return;
                    }
                }
                try output.appendSlice(self.builder.allocator, self.raw(token.span));
            },
            .simple_block => |block| {
                const closing = block.closing orelse return self.reject(
                    block.span,
                    "unterminated CSS Modules @value block",
                );
                try output.appendSlice(self.builder.allocator, self.raw(block.opening.span));
                try self.appendValueComponents(output, block.values, false);
                try output.appendSlice(self.builder.allocator, self.raw(closing.span));
            },
            .function => |function| {
                const closing = function.closing orelse return self.reject(
                    function.span,
                    "unterminated CSS Modules @value function",
                );
                try output.appendSlice(self.builder.allocator, self.raw(function.opening.span));
                try self.appendValueComponents(output, function.values, false);
                try output.appendSlice(self.builder.allocator, self.raw(closing.span));
            },
        }
    }

    fn raw(self: *Walker, span: source.Span) []const u8 {
        return self.parsed.file().slice(span) catch unreachable;
    }

    fn ruleList(
        self: *Walker,
        list: *const ast.RuleList,
        top_level: bool,
    ) WalkError!void {
        for (list.rules) |rule| switch (rule) {
            .style_rule => |style| {
                try self.selectorList(&style.selectors, .local, false);
                var composition_target = compositionTarget(&style.selectors);
                if (composition_target) |*target| {
                    target.name = try self.resolveClassIdentifier(target.name, target.span);
                }
                try self.declarationList(
                    &style.block.declarations,
                    composition_target,
                );
                try self.ruleList(&style.block.rules, false);
            },
            .at_rule => |at_rule| try self.atRule(at_rule, top_level),
            .nested_declarations => |nested| try self.declarationList(
                &nested.declarations,
                null,
            ),
        };
    }

    fn atRule(
        self: *Walker,
        at_rule: *const ast.AtRule,
        top_level: bool,
    ) WalkError!void {
        if (std.ascii.eqlIgnoreCase(at_rule.name.value, "value")) {
            if (!top_level or !isTerminatedValueRule(at_rule)) {
                return self.reject(
                    at_rule.span,
                    "CSS Modules @value definitions must be top-level semicolon rules",
                );
            }
            self.builder.publishNextDefinition(at_rule.span) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LimitExceeded => return self.rejectLimit(at_rule.span),
                error.DuplicateExport => return self.reject(
                    at_rule.span,
                    "CSS Modules value and class exports share one unique namespace",
                ),
                error.InvalidDefinitionOrder => return self.rejectCollision(at_rule.span),
            };
            return;
        }
        if (!isAllowedAtRule(at_rule.name.value)) {
            return self.reject(
                at_rule.span,
                "at-rule is outside the CSS Modules native subset",
            );
        }
        try self.scanValues(at_rule.prelude.values);
        switch (at_rule.block) {
            .none => {},
            .declarations => |block| try self.declarationList(&block.declarations, null),
            .rules => |block| try self.ruleList(&block.rules, false),
            .keyframes => |block| for (block.frames) |frame| {
                try self.declarationList(&frame.block.declarations, null);
            },
            .raw => return self.reject(
                at_rule.span,
                "raw at-rule blocks are outside the CSS Modules native subset",
            ),
        }
    }

    fn declarationList(
        self: *Walker,
        list: *const ast.DeclarationList,
        target: ?CompositionTarget,
    ) WalkError!void {
        var saw_ordinary = false;
        for (list.declarations) |declaration| {
            if (std.ascii.eqlIgnoreCase(declaration.name.value, "composes-with")) {
                return self.reject(
                    declaration.span,
                    "CSS Modules supports only the canonical composes property",
                );
            }
            if (!std.ascii.eqlIgnoreCase(declaration.name.value, "composes")) {
                saw_ordinary = true;
                try self.scanValues(declaration.valueWithoutImportance());
                continue;
            }
            if (saw_ordinary) {
                return self.reject(
                    declaration.span,
                    "CSS Modules composes declarations must precede ordinary declarations",
                );
            }
            const composition_target = target orelse return self.reject(
                declaration.span,
                "CSS Modules composes requires a single plain local class selector",
            );
            if (declaration.important != null) {
                return self.reject(
                    declaration.span,
                    "CSS Modules composes cannot be important",
                );
            }
            const spec = try self.parseComposition(composition_target, declaration);
            self.builder.addComposition(spec) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LimitExceeded => return self.rejectLimit(declaration.span),
            };
        }
    }

    fn parseComposition(
        self: *Walker,
        target: CompositionTarget,
        declaration: ast.Declaration,
    ) WalkError!CompositionSpec {
        var tokens = try std.ArrayList(tokenizer.Token).initCapacity(
            self.builder.allocator,
            0,
        );
        defer tokens.deinit(self.builder.allocator);
        for (declaration.valueWithoutImportance()) |value| switch (value) {
            .token => |token| {
                if (token.isTrivia()) continue;
                try tokens.append(self.builder.allocator, token);
            },
            else => return self.reject(
                value.span(),
                "CSS Modules composes accepts only identifiers and one source operand",
            ),
        };
        if (tokens.items.len == 0) {
            return self.reject(declaration.span, "CSS Modules composes requires a class name");
        }

        var from_index: ?usize = null;
        for (tokens.items, 0..) |token, index| {
            if (token.kind != .ident) continue;
            const decoded = try self.decodeToken(token);
            if (!std.ascii.eqlIgnoreCase(decoded, "from")) continue;
            if (from_index != null) {
                return self.reject(token.span, "CSS Modules composes contains multiple from clauses");
            }
            from_index = index;
        }

        const name_end = from_index orelse tokens.items.len;
        if (name_end == 0) {
            return self.reject(declaration.span, "CSS Modules composes requires a class name");
        }
        var names = try std.ArrayList(CompositionName).initCapacity(
            self.builder.allocator,
            name_end,
        );
        errdefer names.deinit(self.builder.allocator);
        for (tokens.items[0..name_end]) |token| {
            if (token.kind != .ident) {
                return self.reject(token.span, "CSS Modules composed names must be identifiers");
            }
            const name_span = token.valueSpan() orelse token.span;
            try names.append(self.builder.allocator, .{
                .value = try self.resolveClassIdentifier(
                    try self.decodeToken(token),
                    name_span,
                ),
                .span = name_span,
            });
        }

        var source_kind: CompositionSource = .local;
        if (from_index) |index| {
            if (index + 2 != tokens.items.len) {
                return self.reject(
                    tokens.items[index].span,
                    "CSS Modules composes requires exactly one source after from",
                );
            }
            const operand = tokens.items[index + 1];
            if (operand.kind == .ident) {
                const decoded = try self.decodeToken(operand);
                if (std.ascii.eqlIgnoreCase(decoded, "global")) {
                    source_kind = .global;
                } else if (self.builder.findDefinition(decoded)) |definition| {
                    const specifier = definition.single_string orelse return self.reject(
                        operand.span,
                        "CSS Modules composition path aliases must resolve to one string",
                    );
                    if (specifier.len == 0) {
                        return self.reject(
                            operand.span,
                            "CSS Modules dependency specifier is empty",
                        );
                    }
                    source_kind = .{ .dependency = .{
                        .specifier = specifier,
                        .span = operand.valueSpan() orelse operand.span,
                    } };
                } else {
                    return self.reject(
                        operand.span,
                        "CSS Modules composes source must be global, a quoted specifier, or a local string value",
                    );
                }
            } else if (operand.kind == .string and operand.isTerminated()) {
                const specifier = try self.decodeToken(operand);
                if (specifier.len == 0) {
                    return self.reject(operand.span, "CSS Modules dependency specifier is empty");
                }
                source_kind = .{ .dependency = .{
                    .specifier = specifier,
                    .span = operand.valueSpan() orelse operand.span,
                } };
            } else {
                return self.reject(
                    operand.span,
                    "CSS Modules composes source must be global or a quoted module specifier",
                );
            }
        }

        return .{
            .target_name = target.name,
            .target_span = target.span,
            .names = try names.toOwnedSlice(self.builder.allocator),
            .source_kind = source_kind,
            .declaration_span = declaration.span,
        };
    }

    fn decodeToken(self: *Walker, token: tokenizer.Token) WalkError![]const u8 {
        return token.decodedTextAlloc(
            self.parsed.compilation.arenaAllocator(),
            self.parsed.file(),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.reject(token.span, "invalid CSS Modules composition token"),
        };
    }

    fn scanValues(
        self: *Walker,
        values: []const syntax.ComponentValue,
    ) WalkError!void {
        for (values) |value| switch (value) {
            .token => |token| {
                if (token.kind != .ident) continue;
                const decoded = try self.decodeToken(token);
                const definition = self.builder.findDefinition(decoded) orelse continue;
                self.builder.addValueRewrite(token.span, definition.value) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.LimitExceeded => return self.rejectLimit(token.span),
                };
            },
            .simple_block => |block| try self.scanValues(block.values),
            .function => |function| try self.scanValues(function.values),
        };
    }

    fn resolveCompositions(self: *Walker) WalkError!void {
        const failure = try self.builder.applyCompositions() orelse return;
        return switch (failure.kind) {
            .unsupported => self.reject(failure.span, failure.message),
            .limit => self.rejectLimit(failure.span),
        };
    }

    fn selectorList(
        self: *Walker,
        list: *const ast.SelectorList,
        scope_mode: ScopeMode,
        inside_scope: bool,
    ) WalkError!void {
        for (list.selectors) |selector| {
            try self.compound(selector.head, scope_mode, inside_scope);
            for (selector.tails) |tail| {
                try self.compound(tail.compound, scope_mode, inside_scope);
            }
        }
    }

    fn compound(
        self: *Walker,
        value: ast.CompoundSelector,
        scope_mode: ScopeMode,
        inside_scope: bool,
    ) WalkError!void {
        for (value.simple_selectors) |simple| switch (simple) {
            .type_selector => |selector| {
                try self.ensureNoValueSelectorUse(selector.name);
                try self.ensureNoValueNamespaceUse(selector.namespace);
            },
            .universal => |selector| try self.ensureNoValueNamespaceUse(selector.namespace),
            .id => |selector| {
                try self.ensureNoValueSelectorUse(selector.name);
                if (inside_scope) {
                    return self.reject(
                        selector.span,
                        "explicit CSS Modules scope currently accepts class identifiers only",
                    );
                }
            },
            .class => |class| {
                const resolved = try self.resolveClassIdentifier(
                    class.name.value,
                    class.name.span,
                );
                self.builder.addClass(
                    resolved,
                    class.span,
                    scope_mode,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.LimitExceeded => return self.rejectLimit(class.span),
                    error.NameCollision => return self.rejectCollision(class.span),
                    error.DuplicateExport => return self.reject(
                        class.span,
                        "CSS Modules value and class exports share one unique namespace",
                    ),
                };
            },
            .attribute => |selector| try self.ensureNoValueAttributeUse(selector),
            .pseudo_class => |selector| try self.pseudo(
                selector.name,
                selector.arguments,
                selector.span,
                false,
                scope_mode,
                inside_scope,
            ),
            .pseudo_element => |selector| try self.pseudo(
                selector.name,
                selector.arguments,
                selector.span,
                true,
                scope_mode,
                inside_scope,
            ),
            .nesting => {},
        };
    }

    fn resolveClassIdentifier(
        self: *Walker,
        name: []const u8,
        span: source.Span,
    ) WalkError![]const u8 {
        const definition = self.builder.findDefinition(name) orelse return name;
        if (definition.single_identifier) |identifier| return identifier;
        return self.reject(
            span,
            "CSS Modules value used as a class must resolve to one identifier",
        );
    }

    fn ensureNoValueSelectorUse(
        self: *Walker,
        identifier: ast.Identifier,
    ) WalkError!void {
        if (self.builder.findDefinition(identifier.value) != null) {
            return self.reject(
                identifier.span,
                "CSS Modules local values are supported in class selectors only",
            );
        }
    }

    fn ensureNoValueNamespaceUse(
        self: *Walker,
        namespace: ast.Namespace,
    ) WalkError!void {
        switch (namespace) {
            .named => |identifier| try self.ensureNoValueSelectorUse(identifier),
            else => {},
        }
    }

    fn ensureNoValueAttributeUse(
        self: *Walker,
        selector: *const ast.AttributeSelector,
    ) WalkError!void {
        try self.ensureNoValueNamespaceUse(selector.namespace);
        try self.ensureNoValueSelectorUse(selector.name);
        if (selector.value) |value| switch (value) {
            .identifier => |identifier| try self.ensureNoValueSelectorUse(identifier),
            .string => {},
        };
        if (selector.modifier) |modifier| switch (modifier) {
            .unknown => |identifier| try self.ensureNoValueSelectorUse(identifier),
            else => {},
        };
    }

    fn pseudo(
        self: *Walker,
        name: ast.Identifier,
        arguments: ?ast.PseudoArguments,
        span: source.Span,
        is_element: bool,
        scope_mode: ScopeMode,
        inside_scope: bool,
    ) WalkError!void {
        if (scopeModeForPseudo(name.value)) |explicit_scope| {
            if (is_element or inside_scope) {
                return self.reject(
                    span,
                    "nested or pseudo-element CSS Modules scope is outside the native subset",
                );
            }
            const args = arguments orelse return self.reject(
                span,
                "CSS Modules scope switches must use functional syntax",
            );
            const input = ast.ComponentValueList.init(args.span, args.values) catch {
                return self.reject(span, "invalid CSS Modules scope selector");
            };
            const list = selector_parser.parseSilently(
                &self.parsed.compilation,
                self.parsed.source_id,
                input,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.SelectorNestingLimit => return error.Rejected,
                error.InvalidSelector => return self.reject(
                    span,
                    "invalid CSS Modules scope selector",
                ),
                error.UnknownSource => unreachable,
            };
            if (list.selectors.len != 1) {
                return self.reject(
                    span,
                    "CSS Modules scope requires exactly one compound selector",
                );
            }
            const selector = &list.selectors[0];
            if (selector.leading_combinator != null or selector.tails.len != 0 or
                !scopeCompoundCanInline(selector.head))
            {
                return self.reject(
                    span,
                    "CSS Modules scope requires one inline-safe compound selector",
                );
            }
            const before = self.builder.class_rewrites.items.len;
            try self.compound(selector.head, explicit_scope, true);
            if (self.builder.class_rewrites.items.len == before) {
                return self.reject(
                    span,
                    "CSS Modules scope requires at least one class selector",
                );
            }
            self.builder.addScope(span, &selector.head) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LimitExceeded => return self.rejectLimit(span),
            };
            return;
        }
        if (isDeferredPseudo(name.value)) {
            return self.reject(
                span,
                "CSS Modules import and export pseudos are outside the native subset",
            );
        }
        try self.ensureNoValueSelectorUse(name);
        const args = arguments orelse return;
        const parsed = args.parsed orelse return self.reject(
            span,
            "untyped functional pseudos are outside the CSS Modules native subset",
        );
        switch (parsed) {
            .selector_list => |list| try self.selectorList(
                list,
                scope_mode,
                inside_scope,
            ),
        }
    }

    fn reject(self: *Walker, span: source.Span, message: []const u8) WalkError {
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

    fn rejectLimit(self: *Walker, span: source.Span) WalkError {
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

    fn rejectCollision(self: *Walker, span: source.Span) WalkError {
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
    return std.ascii.eqlIgnoreCase(name, "import") or
        std.ascii.eqlIgnoreCase(name, "export");
}

fn scopeModeForPseudo(name: []const u8) ?ScopeMode {
    if (std.ascii.eqlIgnoreCase(name, "local")) return .local;
    if (std.ascii.eqlIgnoreCase(name, "global")) return .global;
    return null;
}

fn scopeCompoundCanInline(compound: ast.CompoundSelector) bool {
    for (compound.simple_selectors) |simple| switch (simple) {
        .type_selector, .universal, .id, .nesting => return false,
        else => {},
    };
    return true;
}

fn compositionTarget(list: *const ast.SelectorList) ?CompositionTarget {
    if (list.selectors.len != 1) return null;
    const selector = list.selectors[0];
    if (selector.leading_combinator != null or selector.tails.len != 0 or
        selector.head.simple_selectors.len != 1)
    {
        return null;
    }
    return switch (selector.head.simple_selectors[0]) {
        .class => |class| .{ .name = class.name.value, .span = class.span },
        else => null,
    };
}

fn lessThanLocalEdge(_: void, left: LocalEdge, right: LocalEdge) bool {
    if (left.from != right.from) return left.from < right.from;
    if (left.to != right.to) return left.to < right.to;
    if (left.span.start != right.span.start) return left.span.start < right.span.start;
    return left.span.end < right.span.end;
}

fn tokenAtValue(value: syntax.ComponentValue) ?tokenizer.Token {
    return switch (value) {
        .token => |token| token,
        else => null,
    };
}

fn isValueTrivia(value: syntax.ComponentValue) bool {
    const token = tokenAtValue(value) orelse return false;
    return token.isTrivia();
}

fn nextSignificantValue(
    values: []const syntax.ComponentValue,
    start: usize,
) ?usize {
    var index = start;
    while (index < values.len) : (index += 1) {
        if (!isValueTrivia(values[index])) return index;
    }
    return null;
}

fn tokenDelimiter(token: tokenizer.Token, expected: u21) bool {
    if (token.kind != .delim) return false;
    return switch (token.data) {
        .delim => |delimiter| delimiter == expected,
        else => false,
    };
}

fn spansEqual(left: source.Span, right: source.Span) bool {
    return left.source.eql(right.source) and
        left.start == right.start and
        left.end == right.end;
}

fn isTerminatedValueRule(at_rule: *const ast.AtRule) bool {
    return switch (at_rule.block) {
        .none => |no_block| no_block.terminator != null,
        else => false,
    };
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
    try module_names.validateOccurrences(prepared.classes());
}
