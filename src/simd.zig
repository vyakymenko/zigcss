const std = @import("std");

pub fn skipWhitespaceSimd(input: []const u8, pos: *usize) void {
    if (pos.* >= input.len) return;

    const simd_available = @import("builtin").cpu.arch != .wasm32 and @import("builtin").cpu.arch != .wasm64;
    
    if (!simd_available or input.len - pos.* < 16) {
        skipWhitespaceScalar(input, pos);
        return;
    }

    const tab: u8 = 0x09;
    const newline: u8 = 0x0A;
    const cr: u8 = 0x0D;
    const space: u8 = 0x20;

    var i = pos.*;
    const end = input.len - 16;

    while (i <= end) {
        const chunk = input[i..][0..16];
        var all_whitespace = true;

        for (chunk) |ch| {
            if (ch != space and ch != tab and ch != newline and ch != cr) {
                all_whitespace = false;
                break;
            }
        }

        if (!all_whitespace) {
            break;
        }
        i += 16;
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
