const std = @import("std");

pub fn skipWhitespaceSimd(input: []const u8, pos: *usize) void {
    if (pos.* >= input.len) return;

    const arch = @import("builtin").cpu.arch;
    const simd_available = arch != .wasm32 and arch != .wasm64;
    
    if (!simd_available or input.len - pos.* < 32) {
        skipWhitespaceScalar(input, pos);
        return;
    }

    var i = pos.*;
    const end = input.len - 32;

    while (i <= end) {
        var all_whitespace = true;
        var j: usize = 0;
        
        while (j < 32) {
            const ch = input[i + j];
            if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r') {
                all_whitespace = false;
                break;
            }
            j += 1;
        }
        
        if (!all_whitespace) {
            break;
        }
        i += 32;
    }

    skipWhitespaceScalar(input, &i);
    pos.* = i;
}

fn skipWhitespaceScalar(input: []const u8, pos: *usize) void {
    while (pos.* < input.len) {
        const ch = input[pos.*];
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            pos.* += 1;
        } else {
            break;
        }
    }
}
