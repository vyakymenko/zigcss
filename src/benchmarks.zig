const std = @import("std");
const profiler = @import("profiler.zig");
const parser = @import("parser.zig");
const codegen = @import("codegen.zig");
const optimizer = @import("optimizer.zig");

const test_css = 
    \\.header { color: #333; background: white; padding: 20px; margin: 10px; }
    \\.footer { color: #666; background: #f0f0f0; padding: 15px; margin: 5px; }
    \\.sidebar { width: 250px; float: left; background: #fff; }
    \\.content { margin-left: 270px; padding: 20px; }
    \\.button { background: #007bff; color: white; padding: 10px 20px; border-radius: 4px; }
    \\.button:hover { background: #0056b3; }
    \\.card { border: 1px solid #ddd; border-radius: 8px; padding: 20px; margin: 10px; }
    \\.card-title { font-size: 1.5em; font-weight: bold; margin-bottom: 10px; }
    \\.card-body { color: #666; line-height: 1.6; }
    \\.nav { list-style: none; padding: 0; margin: 0; }
    \\.nav li { display: inline-block; margin-right: 20px; }
    \\.nav a { text-decoration: none; color: #007bff; }
    \\.nav a:hover { text-decoration: underline; }
    \\.container { max-width: 1200px; margin: 0 auto; padding: 0 20px; }
    \\.grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; }
    \\.flex { display: flex; justify-content: space-between; align-items: center; }
    \\.text-center { text-align: center; }
    \\.text-bold { font-weight: bold; }
    \\.mt-1 { margin-top: 0.25rem; }
    \\.mt-2 { margin-top: 0.5rem; }
    \\.mt-3 { margin-top: 1rem; }
    \\.mb-1 { margin-bottom: 0.25rem; }
    \\.mb-2 { margin-bottom: 0.5rem; }
    \\.mb-3 { margin-bottom: 1rem; }
    \\.p-1 { padding: 0.25rem; }
    \\.p-2 { padding: 0.5rem; }
    \\.p-3 { padding: 1rem; }
    \\.bg-primary { background-color: #007bff; }
    \\.bg-secondary { background-color: #6c757d; }
    \\.bg-success { background-color: #28a745; }
    \\.bg-danger { background-color: #dc3545; }
    \\.text-primary { color: #007bff; }
    \\.text-secondary { color: #6c757d; }
    \\.text-success { color: #28a745; }
    \\.text-danger { color: #dc3545; }
    \\.border { border: 1px solid #ddd; }
    \\.rounded { border-radius: 4px; }
    \\.shadow { box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
    \\.hidden { display: none; }
    \\.visible { display: block; }
    \\.w-full { width: 100%; }
    \\.h-full { height: 100%; }
    \\.w-50 { width: 50%; }
    \\.h-50 { height: 50%; }
    \\.m-auto { margin: auto; }
    \\.p-auto { padding: auto; }
    \\.flex-row { flex-direction: row; }
    \\.flex-column { flex-direction: column; }
    \\.justify-start { justify-content: flex-start; }
    \\.justify-end { justify-content: flex-end; }
    \\.justify-center { justify-content: center; }
    \\.align-start { align-items: flex-start; }
    \\.align-end { align-items: flex-end; }
    \\.align-center { align-items: center; }
    \\.gap-1 { gap: 0.25rem; }
    \\.gap-2 { gap: 0.5rem; }
    \\.gap-3 { gap: 1rem; }
    \\.opacity-50 { opacity: 0.5; }
    \\.opacity-75 { opacity: 0.75; }
    \\.opacity-100 { opacity: 1.0; }
    \\.transition { transition: all 0.3s ease; }
    \\.hover-scale:hover { transform: scale(1.05); }
    \\.hover-rotate:hover { transform: rotate(5deg); }
    \\.focus-outline:focus { outline: 2px solid #007bff; }
    \\.disabled { opacity: 0.6; cursor: not-allowed; }
    \\.active { background-color: #007bff; color: white; }
    \\.loading { opacity: 0.7; pointer-events: none; }
    \\.error { color: #dc3545; border-color: #dc3545; }
    \\.success { color: #28a745; border-color: #28a745; }
    \\.warning { color: #ffc107; border-color: #ffc107; }
    \\.info { color: #17a2b8; border-color: #17a2b8; }
    \\.responsive { width: 100%; max-width: 100%; }
    \\.mobile-hidden { display: none; }
    \\.desktop-only { display: block; }
    \\.tablet-only { display: block; }
    \\.dark-mode { background-color: #1a1a1a; color: #ffffff; }
    \\.light-mode { background-color: #ffffff; color: #000000; }
    \\.gradient-bg { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); }
    \\.text-gradient { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
    \\.blur { filter: blur(5px); }
    \\.brightness { filter: brightness(1.2); }
    \\.contrast { filter: contrast(1.2); }
    \\.grayscale { filter: grayscale(100%); }
    \\.sepia { filter: sepia(100%); }
    \\.invert { filter: invert(100%); }
    \\.saturate { filter: saturate(150%); }
    \\.hue-rotate { filter: hue-rotate(90deg); }
    \\.backdrop-blur { backdrop-filter: blur(10px); }
    \\.backdrop-brightness { backdrop-filter: brightness(1.2); }
    \\.backdrop-contrast { backdrop-filter: contrast(1.2); }
    \\.backdrop-grayscale { backdrop-filter: grayscale(100%); }
    \\.backdrop-sepia { backdrop-filter: sepia(100%); }
    \\.backdrop-invert { backdrop-filter: invert(100%); }
    \\.backdrop-saturate { backdrop-filter: saturate(150%); }
    \\.backdrop-hue-rotate { backdrop-filter: hue-rotate(90deg); }
    \\.transform-origin-center { transform-origin: center; }
    \\.transform-origin-top { transform-origin: top; }
    \\.transform-origin-bottom { transform-origin: bottom; }
    \\.transform-origin-left { transform-origin: left; }
    \\.transform-origin-right { transform-origin: right; }
    \\.transform-scale { transform: scale(1.1); }
    \\.transform-rotate { transform: rotate(45deg); }
    \\.transform-translate { transform: translate(10px, 10px); }
    \\.transform-skew { transform: skew(10deg, 10deg); }
    \\.animation-spin { animation: spin 1s linear infinite; }
    \\.animation-pulse { animation: pulse 2s ease-in-out infinite; }
    \\.animation-bounce { animation: bounce 1s ease-in-out infinite; }
    \\.animation-fade { animation: fade 1s ease-in-out infinite; }
    \\.animation-slide { animation: slide 1s ease-in-out infinite; }
    \\.animation-zoom { animation: zoom 1s ease-in-out infinite; }
    \\.animation-rotate { animation: rotate 1s linear infinite; }
    \\.animation-scale { animation: scale 1s ease-in-out infinite; }
    \\.z-index-0 { z-index: 0; }
    \\.z-index-10 { z-index: 10; }
    \\.z-index-20 { z-index: 20; }
    \\.z-index-30 { z-index: 30; }
    \\.z-index-40 { z-index: 40; }
    \\.z-index-50 { z-index: 50; }
    \\.position-static { position: static; }
    \\.position-relative { position: relative; }
    \\.position-absolute { position: absolute; }
    \\.position-fixed { position: fixed; }
    \\.position-sticky { position: sticky; }
    \\.top-0 { top: 0; }
    \\.right-0 { right: 0; }
    \\.bottom-0 { bottom: 0; }
    \\.left-0 { left: 0; }
    \\.inset-0 { top: 0; right: 0; bottom: 0; left: 0; }
    \\.overflow-hidden { overflow: hidden; }
    \\.overflow-auto { overflow: auto; }
    \\.overflow-scroll { overflow: scroll; }
    \\.overflow-visible { overflow: visible; }
    \\.cursor-pointer { cursor: pointer; }
    \\.cursor-not-allowed { cursor: not-allowed; }
    \\.cursor-wait { cursor: wait; }
    \\.cursor-text { cursor: text; }
    \\.cursor-move { cursor: move; }
    \\.user-select-none { user-select: none; }
    \\.user-select-auto { user-select: auto; }
    \\.user-select-text { user-select: text; }
    \\.user-select-all { user-select: all; }
    \\.pointer-events-none { pointer-events: none; }
    \\.pointer-events-auto { pointer-events: auto; }
    \\.appearance-none { appearance: none; }
    \\.outline-none { outline: none; }
    \\.outline-2 { outline: 2px solid; }
    \\.outline-4 { outline: 4px solid; }
    \\.transition { transition: all 0.3s ease; }
    \\.hover-scale:hover { transform: scale(1.05); }
    \\.hover-rotate:hover { transform: rotate(5deg); }
    \\.focus-outline:focus { outline: 2px solid #007bff; }
    \\.disabled { opacity: 0.6; cursor: not-allowed; }
    \\.active { background-color: #007bff; color: white; }
    \\.loading { opacity: 0.7; pointer-events: none; }
    \\.error { color: #dc3545; border-color: #dc3545; }
    \\.success { color: #28a745; border-color: #28a745; }
    \\.warning { color: #ffc107; border-color: #ffc107; }
    \\.info { color: #17a2b8; border-color: #17a2b8; }
    \\.responsive { width: 100%; max-width: 100%; }
    \\.mobile-hidden { display: none; }
    \\.desktop-only { display: block; }
    \\.tablet-only { display: block; }
    \\.dark-mode { background-color: #1a1a1a; color: #ffffff; }
    \\.light-mode { background-color: #ffffff; color: #000000; }
    \\.gradient-bg { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); }
    \\.text-gradient { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
    \\.blur { filter: blur(5px); }
    \\.brightness { filter: brightness(1.2); }
    \\.contrast { filter: contrast(1.2); }
    \\.grayscale { filter: grayscale(100%); }
    \\.sepia { filter: sepia(100%); }
    \\.invert { filter: invert(100%); }
    \\.saturate { filter: saturate(150%); }
    \\.hue-rotate { filter: hue-rotate(90deg); }
    \\.backdrop-blur { backdrop-filter: blur(10px); }
    \\.backdrop-brightness { backdrop-filter: brightness(1.2); }
    \\.backdrop-contrast { backdrop-filter: contrast(1.2); }
    \\.backdrop-grayscale { backdrop-filter: grayscale(100%); }
    \\.backdrop-sepia { backdrop-filter: sepia(100%); }
    \\.backdrop-invert { backdrop-filter: invert(100%); }
    \\.backdrop-saturate { backdrop-filter: saturate(150%); }
    \\.backdrop-hue-rotate { backdrop-filter: hue-rotate(90deg); }
    \\.transform-origin-center { transform-origin: center; }
    \\.transform-origin-top { transform-origin: top; }
    \\.transform-origin-bottom { transform-origin: bottom; }
    \\.transform-origin-left { transform-origin: left; }
    \\.transform-origin-right { transform-origin: right; }
    \\.transform-scale { transform: scale(1.1); }
    \\.transform-rotate { transform: rotate(45deg); }
    \\.transform-translate { transform: translate(10px, 10px); }
    \\.transform-skew { transform: skew(10deg, 10deg); }
    \\.animation-spin { animation: spin 1s linear infinite; }
    \\.animation-pulse { animation: pulse 2s ease-in-out infinite; }
    \\.animation-bounce { animation: bounce 1s ease-in-out infinite; }
    \\.animation-fade { animation: fade 1s ease-in-out infinite; }
    \\.animation-slide { animation: slide 1s ease-in-out infinite; }
    \\.animation-zoom { animation: zoom 1s ease-in-out infinite; }
    \\.animation-rotate { animation: rotate 1s linear infinite; }
    \\.animation-scale { animation: scale 1s ease-in-out infinite; }
    \\.z-index-0 { z-index: 0; }
    \\.z-index-10 { z-index: 10; }
    \\.z-index-20 { z-index: 20; }
    \\.z-index-30 { z-index: 30; }
    \\.z-index-40 { z-index: 40; }
    \\.z-index-50 { z-index: 50; }
    \\.position-static { position: static; }
    \\.position-relative { position: relative; }
    \\.position-absolute { position: absolute; }
    \\.position-fixed { position: fixed; }
    \\.position-sticky { position: sticky; }
    \\.top-0 { top: 0; }
    \\.right-0 { right: 0; }
    \\.bottom-0 { bottom: 0; }
    \\.left-0 { left: 0; }
    \\.inset-0 { top: 0; right: 0; bottom: 0; left: 0; }
    \\.overflow-hidden { overflow: hidden; }
    \\.overflow-auto { overflow: auto; }
    \\.overflow-scroll { overflow: scroll; }
    \\.overflow-visible { overflow: visible; }
    \\.cursor-pointer { cursor: pointer; }
    \\.cursor-not-allowed { cursor: not-allowed; }
    \\.cursor-wait { cursor: wait; }
    \\.cursor-text { cursor: text; }
    \\.cursor-move { cursor: move; }
    \\.user-select-none { user-select: none; }
    \\.user-select-auto { user-select: auto; }
    \\.user-select-text { user-select: text; }
    \\.user-select-all { user-select: all; }
    \\.pointer-events-none { pointer-events: none; }
    \\.pointer-events-auto { pointer-events: auto; }
    \\.appearance-none { appearance: none; }
    \\.outline-none { outline: none; }
    \\.outline-2 { outline: 2px solid; }
    \\.outline-4 { outline: 4px solid; }
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Running benchmarks...\n\n", .{});

    const iterations = 100;
    const result = try profiler.benchmarkCompilation(allocator, test_css, iterations);
    result.print();

    std.debug.print("Running detailed benchmark...\n\n", .{});
    try runDetailedBenchmark(allocator);
}

fn runDetailedBenchmark(allocator: std.mem.Allocator) !void {
    const small_css = ".container { color: red; background: white; padding: 10px; margin: 5px; }";
    const medium_css = test_css;
    
    var large_css_buf = try std.ArrayList(u8).initCapacity(allocator, 1024 * 1024);
    defer large_css_buf.deinit(allocator);
    var writer = large_css_buf.writer(allocator);
    for (0..1000) |i| {
        try writer.print(".class-{d} {{ color: #{x:0>6}; padding: {d}px; margin: {d}px; }}\n", .{ i, i * 1000, i * 2, i * 3 });
    }
    const large_css = try large_css_buf.toOwnedSlice(allocator);
    defer allocator.free(large_css);
    
    const test_cases = [_]struct { name: []const u8, css: []const u8 }{
        .{ .name = "Small CSS (~100 bytes)", .css = small_css },
        .{ .name = "Medium CSS (~10KB)", .css = medium_css },
        .{ .name = "Large CSS (~100KB)", .css = large_css },
    };

    for (test_cases) |test_case| {
        std.debug.print("Benchmarking: {s}\n", .{test_case.name});
        
        var total_parse: u64 = 0;
        var total_optimize: u64 = 0;
        var total_codegen: u64 = 0;
        const runs = 50;
        
        for (0..runs) |_| {
            const parse_start = std.time.nanoTimestamp();
            var css_parser = parser.Parser.init(allocator, test_case.css);
            defer if (css_parser.owns_pool) {
                css_parser.string_pool.deinit();
                allocator.destroy(css_parser.string_pool);
            };
            
            var parse_result = css_parser.parseWithErrorInfo();
            const parse_end = std.time.nanoTimestamp();
            
            switch (parse_result) {
                .success => |*stylesheet_ptr| {
                    const stylesheet = @constCast(stylesheet_ptr);
                    defer stylesheet.deinit();
                    
                    total_parse += @as(u64, @intCast(@abs(parse_end - parse_start)));
                    
                    const optimize_start = std.time.nanoTimestamp();
                    var opt = optimizer.Optimizer.init(allocator);
                    try opt.optimize(stylesheet);
                    const optimize_end = std.time.nanoTimestamp();
                    total_optimize += @as(u64, @intCast(@abs(optimize_end - optimize_start)));
                    
                    const codegen_start = std.time.nanoTimestamp();
                    const result = try codegen.generate(allocator, stylesheet, .{ .optimize = true, .minify = true });
                    defer allocator.free(result);
                    const codegen_end = std.time.nanoTimestamp();
                    total_codegen += @as(u64, @intCast(@abs(codegen_end - codegen_start)));
                },
                .parse_error => return error.ParseError,
            }
        }
        
        const avg_parse = @as(f64, @floatFromInt(total_parse)) / @as(f64, @floatFromInt(runs)) / 1_000_000.0;
        const avg_optimize = @as(f64, @floatFromInt(total_optimize)) / @as(f64, @floatFromInt(runs)) / 1_000_000.0;
        const avg_codegen = @as(f64, @floatFromInt(total_codegen)) / @as(f64, @floatFromInt(runs)) / 1_000_000.0;
        const total = avg_parse + avg_optimize + avg_codegen;
        const throughput = if (total > 0) (@as(f64, @floatFromInt(test_case.css.len)) / total) / 1024.0 / 1024.0 else 0.0;
        
        std.debug.print("  Parse:    {d:.3} ms\n", .{avg_parse});
        std.debug.print("  Optimize: {d:.3} ms\n", .{avg_optimize});
        std.debug.print("  Codegen:  {d:.3} ms\n", .{avg_codegen});
        std.debug.print("  Total:    {d:.3} ms\n", .{total});
        std.debug.print("  Throughput: {d:.2} MB/s\n\n", .{throughput});
    }
}
