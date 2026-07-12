pub const target_query = @import("prefixing/target_query.zig");
pub const compatibility = @import("prefixing/compatibility.zig");
pub const compatibility_types = @import("prefixing/compatibility_types.zig");
pub const rewrite = @import("prefixing/rewrite.zig");

pub const Browser = target_query.Browser;
pub const TargetVersion = target_query.Version;
pub const Target = target_query.Target;
pub const TargetQuery = target_query.Query;
pub const TargetQueryFailure = target_query.Failure;
pub const TargetQueryFailureKind = target_query.FailureKind;
pub const TargetQueryResult = target_query.Result;
pub const CompatibilityFeature = compatibility_types.Feature;
pub const CompatibilityFeatureKind = compatibility_types.FeatureKind;
pub const CompatibilityForm = compatibility_types.Form;
pub const CompatibilityFormKind = compatibility_types.FormKind;
pub const CompatibilityResolution = compatibility.Resolution;

test {
    _ = target_query;
    _ = compatibility;
    _ = compatibility_types;
    _ = rewrite;
}
