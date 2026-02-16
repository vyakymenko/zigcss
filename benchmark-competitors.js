#!/usr/bin/env node

const fs = require('fs');
const { execSync } = require('child_process');
const path = require('path');

// Test CSS files
const smallCSS = '.container { color: red; background: white; padding: 10px; margin: 5px; }';
const mediumCSS = fs.readFileSync('test.css', 'utf8');
const largeCSS = generateLargeCSS();

// Create test files
fs.writeFileSync('bench-small.css', smallCSS);
fs.writeFileSync('bench-medium.css', mediumCSS);
fs.writeFileSync('bench-large.css', largeCSS);

function generateLargeCSS() {
    let css = '';
    for (let i = 0; i < 1000; i++) {
        css += `.class-${i} { color: #${(i * 1000).toString(16).padStart(6, '0')}; padding: ${i * 2}px; margin: ${i * 3}px; }\n`;
    }
    return css;
}

function timeCommand(cmd) {
    const start = process.hrtime.bigint();
    try {
        execSync(cmd, { 
            stdio: 'pipe',
            timeout: 30000
        });
        const end = process.hrtime.bigint();
        return Number(end - start) / 1_000_000; // Convert to milliseconds
    } catch (error) {
        return null;
    }
}

function benchmarkZcss(file) {
    const start = process.hrtime.bigint();
    try {
        execSync(`./zig-out/bin/zcss ${file} -o /dev/null --minify --optimize`, {
            stdio: 'pipe',
            timeout: 30000
        });
        const end = process.hrtime.bigint();
        return Number(end - start) / 1_000_000;
    } catch (error) {
        return null;
    }
}

function benchmarkPostCSS(file) {
    const cmd = `npx --yes postcss-cli ${file} -o /dev/null --no-map 2>/dev/null`;
    return timeCommand(cmd);
}

function benchmarkSass(file) {
    const cmd = `npx --yes sass ${file} /dev/null --style=compressed --no-source-map 2>/dev/null`;
    return timeCommand(cmd);
}

function benchmarkLess(file) {
    const cmd = `npx --yes lessc ${file} /dev/null --compress 2>/dev/null`;
    return timeCommand(cmd);
}

function benchmarkStylus(file) {
    const cmd = `npx --yes stylus ${file} -o /dev/null --compress 2>/dev/null`;
    return timeCommand(cmd);
}

const results = {
    small: { zcss: [], postcss: [], sass: [], less: [], stylus: [] },
    medium: { zcss: [], postcss: [], sass: [], less: [], stylus: [] },
    large: { zcss: [], postcss: [], sass: [], less: [], stylus: [] }
};

const iterations = 10;
const warmup = 2;

console.log('Running benchmarks (this may take a while)...\n');

// Warmup
console.log('Warming up...');
for (let i = 0; i < warmup; i++) {
    benchmarkZcss('bench-small.css');
    benchmarkPostCSS('bench-small.css');
}

// Benchmark small
console.log('Benchmarking small CSS...');
for (let i = 0; i < iterations; i++) {
    const zcss = benchmarkZcss('bench-small.css');
    if (zcss !== null) results.small.zcss.push(zcss);
    
    const postcss = benchmarkPostCSS('bench-small.css');
    if (postcss !== null) results.small.postcss.push(postcss);
    
    const sass = benchmarkSass('bench-small.css');
    if (sass !== null) results.small.sass.push(sass);
    
    const less = benchmarkLess('bench-small.css');
    if (less !== null) results.small.less.push(less);
    
    const stylus = benchmarkStylus('bench-small.css');
    if (stylus !== null) results.small.stylus.push(stylus);
}

// Benchmark medium
console.log('Benchmarking medium CSS...');
for (let i = 0; i < iterations; i++) {
    const zcss = benchmarkZcss('bench-medium.css');
    if (zcss !== null) results.medium.zcss.push(zcss);
    
    const postcss = benchmarkPostCSS('bench-medium.css');
    if (postcss !== null) results.medium.postcss.push(postcss);
    
    const sass = benchmarkSass('bench-medium.css');
    if (sass !== null) results.medium.sass.push(sass);
    
    const less = benchmarkLess('bench-medium.css');
    if (less !== null) results.medium.less.push(less);
    
    const stylus = benchmarkStylus('bench-medium.css');
    if (stylus !== null) results.medium.stylus.push(stylus);
}

// Benchmark large
console.log('Benchmarking large CSS...');
for (let i = 0; i < iterations; i++) {
    const zcss = benchmarkZcss('bench-large.css');
    if (zcss !== null) results.large.zcss.push(zcss);
    
    const postcss = benchmarkPostCSS('bench-large.css');
    if (postcss !== null) results.large.postcss.push(postcss);
    
    const sass = benchmarkSass('bench-large.css');
    if (sass !== null) results.large.sass.push(sass);
    
    const less = benchmarkLess('bench-large.css');
    if (less !== null) results.large.less.push(less);
    
    const stylus = benchmarkStylus('bench-large.css');
    if (stylus !== null) results.large.stylus.push(stylus);
}

function avg(arr) {
    if (arr.length === 0) return null;
    return arr.reduce((a, b) => a + b, 0) / arr.length;
}

function formatTime(ms) {
    if (ms === null) return 'N/A';
    if (ms < 1) return `${ms.toFixed(3)}ms`;
    return `${ms.toFixed(1)}ms`;
}

console.log('\n=== Benchmark Results ===\n');

console.log('Small CSS (~100 bytes):');
console.log(`  zcss:    ${formatTime(avg(results.small.zcss))}`);
console.log(`  PostCSS: ${formatTime(avg(results.small.postcss))}`);
console.log(`  Sass:    ${formatTime(avg(results.small.sass))}`);
console.log(`  Less:    ${formatTime(avg(results.small.less))}`);
console.log(`  Stylus:  ${formatTime(avg(results.small.stylus))}`);

console.log('\nMedium CSS (~10KB):');
console.log(`  zcss:    ${formatTime(avg(results.medium.zcss))}`);
console.log(`  PostCSS: ${formatTime(avg(results.medium.postcss))}`);
console.log(`  Sass:    ${formatTime(avg(results.medium.sass))}`);
console.log(`  Less:    ${formatTime(avg(results.medium.less))}`);
console.log(`  Stylus:  ${formatTime(avg(results.medium.stylus))}`);

console.log('\nLarge CSS (~100KB):');
console.log(`  zcss:    ${formatTime(avg(results.large.zcss))}`);
console.log(`  PostCSS: ${formatTime(avg(results.large.postcss))}`);
console.log(`  Sass:    ${formatTime(avg(results.large.sass))}`);
console.log(`  Less:    ${formatTime(avg(results.large.less))}`);
console.log(`  Stylus:  ${formatTime(avg(results.large.stylus))}`);

// Cleanup
fs.unlinkSync('bench-small.css');
fs.unlinkSync('bench-medium.css');
fs.unlinkSync('bench-large.css');

// Output JSON for README update
const jsonResults = {
    small: {
        zcss: avg(results.small.zcss),
        postcss: avg(results.small.postcss),
        sass: avg(results.small.sass),
        less: avg(results.small.less),
        stylus: avg(results.small.stylus)
    },
    medium: {
        zcss: avg(results.medium.zcss),
        postcss: avg(results.medium.postcss),
        sass: avg(results.medium.sass),
        less: avg(results.medium.less),
        stylus: avg(results.medium.stylus)
    },
    large: {
        zcss: avg(results.large.zcss),
        postcss: avg(results.large.postcss),
        sass: avg(results.large.sass),
        less: avg(results.large.less),
        stylus: avg(results.large.stylus)
    }
};

fs.writeFileSync('benchmark-results.json', JSON.stringify(jsonResults, null, 2));
console.log('\nResults saved to benchmark-results.json');
