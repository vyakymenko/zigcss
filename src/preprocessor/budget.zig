const std = @import("std");

pub const Limits = struct {
    max_call_depth: u32 = 256,
    max_calls: u64 = 1_000_000,
    max_operations: u64 = 100_000_000,
    max_loop_iterations: u64 = 10_000_000,
    max_output_bytes: u64 = 64 * 1024 * 1024,
    max_diagnostics: u32 = 1_000,
};

pub const Error = error{
    CallCountExceeded,
    CallDepthExceeded,
    DiagnosticLimitExceeded,
    LoopLimitExceeded,
    OperationLimitExceeded,
    OutputLimitExceeded,
};

pub const Budget = struct {
    limits: Limits,
    call_depth: u32 = 0,
    calls: u64 = 0,
    operations: u64 = 0,
    loop_iterations: u64 = 0,
    output_bytes: u64 = 0,
    diagnostics: u32 = 0,

    pub fn init(limits: Limits) Budget {
        return .{ .limits = limits };
    }

    pub fn enterCall(self: *Budget) Error!void {
        if (self.call_depth >= self.limits.max_call_depth) return error.CallDepthExceeded;
        if (self.calls >= self.limits.max_calls) return error.CallCountExceeded;
        self.call_depth += 1;
        self.calls += 1;
    }

    pub fn leaveCall(self: *Budget) void {
        std.debug.assert(self.call_depth > 0);
        self.call_depth -= 1;
    }

    pub fn consumeOperations(self: *Budget, count: u64) Error!void {
        self.operations = try addBounded(
            self.operations,
            count,
            self.limits.max_operations,
            error.OperationLimitExceeded,
        );
    }

    pub fn consumeLoopIterations(self: *Budget, count: u64) Error!void {
        self.loop_iterations = try addBounded(
            self.loop_iterations,
            count,
            self.limits.max_loop_iterations,
            error.LoopLimitExceeded,
        );
    }

    pub fn reserveOutput(self: *Budget, count: u64) Error!void {
        self.output_bytes = try addBounded(
            self.output_bytes,
            count,
            self.limits.max_output_bytes,
            error.OutputLimitExceeded,
        );
    }

    pub fn reserveDiagnostic(self: *Budget) Error!void {
        if (self.diagnostics >= self.limits.max_diagnostics) {
            return error.DiagnosticLimitExceeded;
        }
        self.diagnostics += 1;
    }
};

fn addBounded(current: u64, amount: u64, maximum: u64, comptime limit_error: anyerror) Error!u64 {
    const next = std.math.add(u64, current, amount) catch return limit_error;
    if (next > maximum) return limit_error;
    return next;
}
