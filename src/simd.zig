const std = @import("std");

pub fn skipWhitespaceSimd(input: []const u8, pos: *usize) void {
    const start_pos = pos.*;
    if (start_pos >= input.len) return;

    const arch = @import("builtin").cpu.arch;
    const simd_available = arch != .wasm32 and arch != .wasm64;
    const remaining = input.len - start_pos;
    
    if (!simd_available or remaining < 32) {
        skipWhitespaceScalar(input, pos);
        return;
    }

    var i = start_pos;
    const end = input.len - 32;

    while (i <= end) {
        const Vec32 = @Vector(32, u8);
        const chunk_ptr: [*]const u8 = input[i..].ptr;
        const chunk: Vec32 = @as(*const Vec32, @ptrCast(@alignCast(chunk_ptr))).*;
        
        const space_vec: Vec32 = @splat(' ');
        const tab_vec: Vec32 = @splat('\t');
        const newline_vec: Vec32 = @splat('\n');
        const cr_vec: Vec32 = @splat('\r');
        
        const is_space = chunk == space_vec;
        const is_tab = chunk == tab_vec;
        const is_newline = chunk == newline_vec;
        const is_cr = chunk == cr_vec;
        const is_whitespace = is_space | is_tab | is_newline | is_cr;
        
        const all_whitespace = @reduce(.And, is_whitespace);
        
        if (!all_whitespace) {
            break;
        }
        i += 32;
    }

    skipWhitespaceScalar(input, &i);
    pos.* = i;
}

fn skipWhitespaceScalar(input: []const u8, pos: *usize) void {
    var i = pos.*;
    const len = input.len;
    
    while (i < len) {
        const ch = input[i];
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            i += 1;
        } else {
            break;
        }
    }
    
    pos.* = i;
}
