pub const pass_manager = @import("transform/pass_manager.zig");
pub const at_rule_merge = @import("transform/at_rule_merge.zig");
pub const custom_property_guard = @import("transform/custom_property_guard.zig");
pub const empty_cleanup = @import("transform/empty_cleanup.zig");
pub const duplicate_declarations = @import("transform/duplicate_declarations.zig");
pub const color_zero_shortening = @import("transform/color_zero_shortening.zig");
pub const math_folding = @import("transform/math_folding.zig");
pub const shorthand_synthesis = @import("transform/shorthand_synthesis.zig");
pub const value_rewrite = @import("transform/value_rewrite.zig");
pub const rule_rewrite = @import("transform/rule_rewrite.zig");
pub const selector_rule_merge = @import("transform/selector_rule_merge.zig");
pub const selector_extraction = @import("transform/selector_extraction.zig");
pub const verified_optimizer = @import("transform/verified_optimizer.zig");

test {
    _ = pass_manager;
    _ = at_rule_merge;
    _ = custom_property_guard;
    _ = empty_cleanup;
    _ = duplicate_declarations;
    _ = color_zero_shortening;
    _ = math_folding;
    _ = shorthand_synthesis;
    _ = value_rewrite;
    _ = rule_rewrite;
    _ = selector_rule_merge;
    _ = selector_extraction;
    _ = verified_optimizer;
}

const std = @import("std");
const pipeline = @import("css/pipeline.zig");
const equivalence = @import("css/equivalence.zig");

test "verified pass composition preserves custom definitions substitutions and cycles" {
    const input = ":root{--Theme:#ffffff;--theme:calc(1px + 2px);" ++
        "--cycle-a:var(--cycle-b);--cycle-b:var(--cycle-a)}" ++
        ".scope{--Theme:blue;color:var(--Theme);width:calc(var(--theme) + 1px);" ++
        "margin-top:var(--gap,1px);margin-right:var(--gap,1px);" ++
        "margin-bottom:var(--gap,1px);margin-left:var(--gap,1px)}" ++
        ".logical{direction:rtl;writing-mode:vertical-rl;text-orientation:upright;" ++
        "margin-inline-start:calc(1px + 2px);border-inline-end-color:#ffffff;" ++
        "inset-block-start:0px;float:inline-start;text-align:end;" ++
        "margin-top:1px;margin-right:1px;margin-inline-end:4px;" ++
        "margin-bottom:1px;margin-left:1px}" ++
        ".cleanup{.empty{}.keep{x:1}}.safe{width:calc(1px + 2px);color:#ffffff;" ++
        "margin-top:1px;margin-right:1px;margin-bottom:1px;margin-left:1px}" ++
        ".merge-a{--token:a/**/b}.merge-b{--token:a/**/b}" ++
        ".host{@media all{.m1{x:1}}@media all{.m2{y:2}}}";
    var parsed = try pipeline.parse(std.testing.allocator, "custom-property-passes.css", input);
    defer parsed.deinit();
    for (verified_optimizer.passDefinitions()) |pass| {
        try std.testing.expectEqual(
            pass_manager.CustomPropertyEffect.preserves,
            pass.metadata.custom_property_effect,
        );
        try std.testing.expectEqual(
            pass_manager.LogicalPropertyEffect.preserves,
            pass.metadata.logical_property_effect,
        );
    }
    var plan = try verified_optimizer.buildPlan(std.testing.allocator);
    defer plan.deinit();
    try parsed.applyPassPlan(std.testing.allocator, &plan, .{ .verify_idempotence = true });

    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        ":root{--Theme:#ffffff;--theme:calc(1px + 2px);" ++
            "--cycle-a:var(--cycle-b);--cycle-b:var(--cycle-a)}" ++
            ".scope{--Theme:blue;color:var(--Theme);width:calc(var(--theme) + 1px);" ++
            "margin-top:var(--gap,1px);margin-right:var(--gap,1px);" ++
            "margin-bottom:var(--gap,1px);margin-left:var(--gap,1px)}" ++
            ".logical{direction:rtl;writing-mode:vertical-rl;text-orientation:upright;" ++
            "margin-inline-start:3px;border-inline-end-color:#fff;" ++
            "inset-block-start:0;float:inline-start;text-align:end;" ++
            "margin-top:1px;margin-right:1px;margin-inline-end:4px;" ++
            "margin-bottom:1px;margin-left:1px}" ++
            ".cleanup{.keep{x:1}}" ++
            ".safe{width:3px;color:#fff;margin:1px}" ++
            ".merge-a,.merge-b{--token:a/**/b}" ++
            ".host{@media all{.m1{x:1}.m2{y:2}}}",
        result.css,
    );
    var reparsed = try pipeline.parse(
        std.testing.allocator,
        "custom-property-passes-output.css",
        result.css,
    );
    defer reparsed.deinit();
    try std.testing.expect(try equivalence.equivalent(
        std.testing.allocator,
        parsed.file(),
        parsed.rules,
        reparsed.file(),
        reparsed.rules,
    ));
}
