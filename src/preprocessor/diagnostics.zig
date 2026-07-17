const std = @import("std");
const source = @import("source.zig");

pub const Severity = enum {
    err,
    warning,
    note,
};

pub const Code = enum {
    syntax,
    undefined_variable,
    duplicate_binding,
    type_mismatch,
    invalid_operation,
    call_limit,
    loop_limit,
    resource_limit,
    invalid_import,
    unsupported_feature,
    internal,

    pub fn label(self: Code) []const u8 {
        return switch (self) {
            .syntax => "NATIVE0001",
            .undefined_variable => "NATIVE0002",
            .duplicate_binding => "NATIVE0003",
            .type_mismatch => "NATIVE0004",
            .invalid_operation => "NATIVE0005",
            .call_limit => "NATIVE0006",
            .loop_limit => "NATIVE0007",
            .resource_limit => "NATIVE0008",
            .invalid_import => "NATIVE0009",
            .unsupported_feature => "NATIVE0010",
            .internal => "NATIVE9999",
        };
    }
};

pub const RelatedInput = struct {
    span: source.Span,
    label: []const u8,
};

pub const Related = struct {
    span: source.Span,
    label: []const u8,
};

pub const Diagnostic = struct {
    severity: Severity,
    code: Code,
    span: source.Span,
    message: []const u8,
    related: []const Related,
};

pub const Limits = struct {
    max_diagnostics: usize = 1_000,
    max_related_per_diagnostic: usize = 32,
    max_message_bytes: usize = 16 * 1024,
    max_owned_bytes: usize = 4 * 1024 * 1024,
};

pub const Error = std.mem.Allocator.Error || error{
    DiagnosticLimitExceeded,
    InvalidDiagnostic,
    InvalidSpan,
};

pub const List = struct {
    allocator: std.mem.Allocator,
    sources: *const source.Table,
    limits: Limits,
    entries: std.ArrayList(Diagnostic) = .empty,
    owned_bytes: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        sources: *const source.Table,
        limits: Limits,
    ) List {
        return .{ .allocator = allocator, .sources = sources, .limits = limits };
    }

    pub fn deinit(self: *List) void {
        for (self.entries.items) |entry| self.freeEntry(entry);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(
        self: *List,
        severity: Severity,
        code: Code,
        span: source.Span,
        message: []const u8,
        related_input: []const RelatedInput,
    ) Error!void {
        if (self.entries.items.len >= self.limits.max_diagnostics or
            related_input.len > self.limits.max_related_per_diagnostic)
        {
            return error.DiagnosticLimitExceeded;
        }
        self.sources.validateSpan(span) catch return error.InvalidSpan;
        try validateText(message, self.limits.max_message_bytes);

        var contribution = message.len;
        for (related_input) |item| {
            self.sources.validateSpan(item.span) catch return error.InvalidSpan;
            try validateText(item.label, self.limits.max_message_bytes);
            contribution = std.math.add(usize, contribution, item.label.len) catch
                return error.DiagnosticLimitExceeded;
        }
        const next_owned = std.math.add(usize, self.owned_bytes, contribution) catch
            return error.DiagnosticLimitExceeded;
        if (next_owned > self.limits.max_owned_bytes) return error.DiagnosticLimitExceeded;

        const owned_message = try self.allocator.dupe(u8, message);
        errdefer if (owned_message.len > 0) self.allocator.free(owned_message);
        const owned_related = try self.allocator.alloc(Related, related_input.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_related[0..initialized]) |item| {
                if (item.label.len > 0) self.allocator.free(item.label);
            }
            if (owned_related.len > 0) self.allocator.free(owned_related);
        }
        for (related_input, 0..) |item, index| {
            owned_related[index] = .{
                .span = item.span,
                .label = try self.allocator.dupe(u8, item.label),
            };
            initialized += 1;
        }

        try self.entries.append(self.allocator, .{
            .severity = severity,
            .code = code,
            .span = span,
            .message = owned_message,
            .related = owned_related,
        });
        self.owned_bytes = next_owned;
    }

    pub fn items(self: *const List) []const Diagnostic {
        return self.entries.items;
    }

    fn freeEntry(self: *List, entry: Diagnostic) void {
        if (entry.message.len > 0) self.allocator.free(entry.message);
        for (entry.related) |item| {
            if (item.label.len > 0) self.allocator.free(item.label);
        }
        if (entry.related.len > 0) self.allocator.free(entry.related);
    }
};

fn validateText(text: []const u8, maximum: usize) Error!void {
    if (text.len == 0 or text.len > maximum or !std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidDiagnostic;
    }
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidDiagnostic;
    }
}
