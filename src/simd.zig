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
    const Vec32 = @Vector(32, u8);
    
    var aligned_buffer: [32]u8 align(32) = undefined;

    while (i <= end) {
        const chunk_ptr: [*]const u8 = input[i..].ptr;
        const alignment = @intFromPtr(chunk_ptr) % 32;
        
        const chunk: Vec32 = if (alignment == 0) blk: {
            const aligned_ptr = @as(*const Vec32, @ptrCast(@alignCast(chunk_ptr)));
            break :blk aligned_ptr.*;
        } else blk: {
            @memcpy(&aligned_buffer, input[i..][0..32]);
            const aligned_ptr = @as(*const Vec32, @ptrCast(@alignCast(&aligned_buffer)));
            break :blk aligned_ptr.*;
        };
        
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
