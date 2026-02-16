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

// Create Tailwind input files
fs.writeFileSync('bench-tailwind-small.css', '@tailwind base; @tailwind components; @tailwind utilities;');
fs.writeFileSync('bench-tailwind-medium.css', '@tailwind base; @tailwind components; @tailwind utilities;');
fs.writeFileSync('bench-tailwind-large.css', '@tailwind base; @tailwind components; @tailwind utilities;');

// Create Tailwind content files with utility classes
const smallTailwindContent = '<div class="container mx-auto p-4 bg-white text-black"></div>';
const mediumTailwindContent = generateMediumTailwindContent();
const largeTailwindContent = generateLargeTailwindContent();

fs.writeFileSync('bench-tailwind-small.html', smallTailwindContent);
fs.writeFileSync('bench-tailwind-medium.html', mediumTailwindContent);
fs.writeFileSync('bench-tailwind-large.html', largeTailwindContent);

function generateMediumTailwindContent() {
    let html = '<div class="container mx-auto p-4 bg-white text-black">';
    const classes = [
        'flex', 'grid', 'hidden', 'block', 'inline', 'inline-block',
        'w-full', 'h-full', 'w-1/2', 'h-1/2', 'w-1/3', 'h-1/3',
        'p-2', 'p-4', 'p-6', 'm-2', 'm-4', 'm-6',
        'bg-blue-500', 'bg-red-500', 'bg-green-500', 'bg-yellow-500',
        'text-white', 'text-black', 'text-gray-500', 'text-blue-500',
        'rounded', 'rounded-lg', 'rounded-xl', 'shadow', 'shadow-lg',
        'border', 'border-2', 'border-gray-300', 'border-blue-500',
        'hover:bg-blue-600', 'focus:outline-none', 'active:scale-95',
        'transition', 'duration-300', 'ease-in-out'
    ];
    for (let i = 0; i < 50; i++) {
        const randomClasses = classes.sort(() => 0.5 - Math.random()).slice(0, 5).join(' ');
        html += `<div class="${randomClasses}">Item ${i}</div>`;
    }
    html += '</div>';
    return html;
}

function generateLargeTailwindContent() {
    let html = '<div class="container mx-auto p-4 bg-white text-black">';
    const spacing = ['p-1', 'p-2', 'p-3', 'p-4', 'p-5', 'p-6', 'p-8', 'p-10', 'p-12', 'm-1', 'm-2', 'm-3', 'm-4', 'm-5', 'm-6', 'm-8', 'm-10', 'm-12'];
    const colors = ['bg-red', 'bg-blue', 'bg-green', 'bg-yellow', 'bg-purple', 'bg-pink', 'bg-indigo', 'bg-gray'];
    const shades = ['50', '100', '200', '300', '400', '500', '600', '700', '800', '900'];
    const sizes = ['w-1', 'w-2', 'w-4', 'w-8', 'w-12', 'w-16', 'w-20', 'w-24', 'w-32', 'w-48', 'w-64', 'w-full', 'h-1', 'h-2', 'h-4', 'h-8', 'h-12', 'h-16', 'h-20', 'h-24', 'h-32', 'h-48', 'h-64', 'h-full'];
    const utilities = ['flex', 'grid', 'hidden', 'block', 'rounded', 'shadow', 'border', 'hover:scale-105', 'transition', 'duration-300'];
    
    for (let i = 0; i < 500; i++) {
        const parts = [];
        if (Math.random() > 0.5) parts.push(spacing[Math.floor(Math.random() * spacing.length)]);
        if (Math.random() > 0.5) parts.push(colors[Math.floor(Math.random() * colors.length)] + '-' + shades[Math.floor(Math.random() * shades.length)]);
        if (Math.random() > 0.5) parts.push(sizes[Math.floor(Math.random() * sizes.length)]);
        if (Math.random() > 0.5) parts.push(utilities[Math.floor(Math.random() * utilities.length)]);
        const randomClasses = parts.join(' ');
        html += `<div class="${randomClasses}">Item ${i}</div>`;
    }
    html += '</div>';
    return html;
}

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

function benchmarkLightningCSS(file) {
    const cmd = `npx --yes lightningcss-cli ${file} --minify -o /dev/null 2>/dev/null`;
    return timeCommand(cmd);
}

function benchmarkCssnano(file) {
    const cmd = `npx --yes cssnano-cli ${file} /dev/null 2>/dev/null`;
    return timeCommand(cmd);
}

function benchmarkEsbuild(file) {
    const cmd = `npx --yes esbuild ${file} --bundle --loader:.css=css --minify --outfile=/dev/null 2>/dev/null`;
    return timeCommand(cmd);
}

function benchmarkTailwind(inputFile, contentFile, outputFile) {
    const cmd = `npx --yes tailwindcss-cli build -i ${inputFile} -o ${outputFile} --purge ${contentFile} --minify 2>/dev/null`;
    return timeCommand(cmd);
}

const results = {
    small: { zcss: [], lightningcss: [], cssnano: [], esbuild: [], postcss: [], sass: [], less: [], stylus: [] },
    medium: { zcss: [], lightningcss: [], cssnano: [], esbuild: [], postcss: [], sass: [], less: [], stylus: [] },
    large: { zcss: [], lightningcss: [], cssnano: [], esbuild: [], postcss: [], sass: [], less: [], stylus: [] }
};

const tailwindResults = {
    small: { tailwind: [], lightningcss: [], cssnano: [], esbuild: [] },
    medium: { tailwind: [], lightningcss: [], cssnano: [], esbuild: [] },
    large: { tailwind: [], lightningcss: [], cssnano: [], esbuild: [] }
};

const iterations = 10;
const warmup = 2;

console.log('Running benchmarks (this may take a while)...\n');

// Build Tailwind CSS files first (for comparison with other tools)
console.log('Building Tailwind CSS files...');
benchmarkTailwind('bench-tailwind-small.css', 'bench-tailwind-small.html', 'bench-tailwind-small-out.css');
benchmarkTailwind('bench-tailwind-medium.css', 'bench-tailwind-medium.html', 'bench-tailwind-medium-out.css');
benchmarkTailwind('bench-tailwind-large.css', 'bench-tailwind-large.html', 'bench-tailwind-large-out.css');

// Ensure Tailwind output files exist
if (!fs.existsSync('bench-tailwind-small-out.css') || 
    !fs.existsSync('bench-tailwind-medium-out.css') || 
    !fs.existsSync('bench-tailwind-large-out.css')) {
    console.error('Error: Tailwind CSS files were not generated. Exiting.');
    process.exit(1);
}

// Warmup
console.log('Warming up...');
for (let i = 0; i < warmup; i++) {
    benchmarkZcss('bench-small.css');
    benchmarkLightningCSS('bench-small.css');
    benchmarkCssnano('bench-small.css');
    benchmarkEsbuild('bench-small.css');
    benchmarkTailwind('bench-tailwind-small.css', 'bench-tailwind-small.html', 'bench-tailwind-small-out.css');
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
    
    const lightningcss = benchmarkLightningCSS('bench-small.css');
    if (lightningcss !== null) results.small.lightningcss.push(lightningcss);
    
    const cssnano = benchmarkCssnano('bench-small.css');
    if (cssnano !== null) results.small.cssnano.push(cssnano);
    
    const esbuild = benchmarkEsbuild('bench-small.css');
    if (esbuild !== null) results.small.esbuild.push(esbuild);
    
    const tailwind = benchmarkTailwind('bench-tailwind-small.css', 'bench-tailwind-small.html', 'bench-tailwind-small-out.css');
    if (tailwind !== null) tailwindResults.small.tailwind.push(tailwind);
    
    if (fs.existsSync('bench-tailwind-small-out.css')) {
        const lightningcssTailwind = benchmarkLightningCSS('bench-tailwind-small-out.css');
        if (lightningcssTailwind !== null) tailwindResults.small.lightningcss.push(lightningcssTailwind);
        
        const cssnanoTailwind = benchmarkCssnano('bench-tailwind-small-out.css');
        if (cssnanoTailwind !== null) tailwindResults.small.cssnano.push(cssnanoTailwind);
        
        const esbuildTailwind = benchmarkEsbuild('bench-tailwind-small-out.css');
        if (esbuildTailwind !== null) tailwindResults.small.esbuild.push(esbuildTailwind);
    }
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
    
    const lightningcss = benchmarkLightningCSS('bench-medium.css');
    if (lightningcss !== null) results.medium.lightningcss.push(lightningcss);
    
    const cssnano = benchmarkCssnano('bench-medium.css');
    if (cssnano !== null) results.medium.cssnano.push(cssnano);
    
    const esbuild = benchmarkEsbuild('bench-medium.css');
    if (esbuild !== null) results.medium.esbuild.push(esbuild);
    
    const tailwind = benchmarkTailwind('bench-tailwind-medium.css', 'bench-tailwind-medium.html', 'bench-tailwind-medium-out.css');
    if (tailwind !== null) tailwindResults.medium.tailwind.push(tailwind);
    
    if (fs.existsSync('bench-tailwind-medium-out.css')) {
        const lightningcssTailwind = benchmarkLightningCSS('bench-tailwind-medium-out.css');
        if (lightningcssTailwind !== null) tailwindResults.medium.lightningcss.push(lightningcssTailwind);
        
        const cssnanoTailwind = benchmarkCssnano('bench-tailwind-medium-out.css');
        if (cssnanoTailwind !== null) tailwindResults.medium.cssnano.push(cssnanoTailwind);
        
        const esbuildTailwind = benchmarkEsbuild('bench-tailwind-medium-out.css');
        if (esbuildTailwind !== null) tailwindResults.medium.esbuild.push(esbuildTailwind);
    }
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
    
    const lightningcss = benchmarkLightningCSS('bench-large.css');
    if (lightningcss !== null) results.large.lightningcss.push(lightningcss);
    
    const cssnano = benchmarkCssnano('bench-large.css');
    if (cssnano !== null) results.large.cssnano.push(cssnano);
    
    const esbuild = benchmarkEsbuild('bench-large.css');
    if (esbuild !== null) results.large.esbuild.push(esbuild);
    
    const tailwind = benchmarkTailwind('bench-tailwind-large.css', 'bench-tailwind-large.html', 'bench-tailwind-large-out.css');
    if (tailwind !== null) tailwindResults.large.tailwind.push(tailwind);
    
    if (fs.existsSync('bench-tailwind-large-out.css')) {
        const lightningcssTailwind = benchmarkLightningCSS('bench-tailwind-large-out.css');
        if (lightningcssTailwind !== null) tailwindResults.large.lightningcss.push(lightningcssTailwind);
        
        const cssnanoTailwind = benchmarkCssnano('bench-tailwind-large-out.css');
        if (cssnanoTailwind !== null) tailwindResults.large.cssnano.push(cssnanoTailwind);
        
        const esbuildTailwind = benchmarkEsbuild('bench-tailwind-large-out.css');
        if (esbuildTailwind !== null) tailwindResults.large.esbuild.push(esbuildTailwind);
    }
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
console.log(`  zcss:         ${formatTime(avg(results.small.zcss))}`);
console.log(`  LightningCSS: ${formatTime(avg(results.small.lightningcss))}`);
console.log(`  cssnano:      ${formatTime(avg(results.small.cssnano))}`);
console.log(`  esbuild:      ${formatTime(avg(results.small.esbuild))}`);
console.log(`  PostCSS:      ${formatTime(avg(results.small.postcss))}`);
console.log(`  Sass:         ${formatTime(avg(results.small.sass))}`);
console.log(`  Less:         ${formatTime(avg(results.small.less))}`);
console.log(`  Stylus:       ${formatTime(avg(results.small.stylus))}`);

console.log('\nMedium CSS (~10KB):');
console.log(`  zcss:         ${formatTime(avg(results.medium.zcss))}`);
console.log(`  LightningCSS: ${formatTime(avg(results.medium.lightningcss))}`);
console.log(`  cssnano:      ${formatTime(avg(results.medium.cssnano))}`);
console.log(`  esbuild:      ${formatTime(avg(results.medium.esbuild))}`);
console.log(`  PostCSS:      ${formatTime(avg(results.medium.postcss))}`);
console.log(`  Sass:         ${formatTime(avg(results.medium.sass))}`);
console.log(`  Less:         ${formatTime(avg(results.medium.less))}`);
console.log(`  Stylus:       ${formatTime(avg(results.medium.stylus))}`);

console.log('\nLarge CSS (~100KB):');
console.log(`  zcss:         ${formatTime(avg(results.large.zcss))}`);
console.log(`  LightningCSS: ${formatTime(avg(results.large.lightningcss))}`);
console.log(`  cssnano:      ${formatTime(avg(results.large.cssnano))}`);
console.log(`  esbuild:      ${formatTime(avg(results.large.esbuild))}`);
console.log(`  PostCSS:      ${formatTime(avg(results.large.postcss))}`);
console.log(`  Sass:         ${formatTime(avg(results.large.sass))}`);
console.log(`  Less:         ${formatTime(avg(results.large.less))}`);
console.log(`  Stylus:       ${formatTime(avg(results.large.stylus))}`);

console.log('\n=== Tailwind CSS Build Comparison ===\n');
console.log('Small Tailwind CSS:');
console.log(`  Tailwind (build): ${formatTime(avg(tailwindResults.small.tailwind))}`);
console.log(`  LightningCSS:     ${formatTime(avg(tailwindResults.small.lightningcss))}`);
console.log(`  cssnano:          ${formatTime(avg(tailwindResults.small.cssnano))}`);
console.log(`  esbuild:          ${formatTime(avg(tailwindResults.small.esbuild))}`);

console.log('\nMedium Tailwind CSS:');
console.log(`  Tailwind (build): ${formatTime(avg(tailwindResults.medium.tailwind))}`);
console.log(`  LightningCSS:     ${formatTime(avg(tailwindResults.medium.lightningcss))}`);
console.log(`  cssnano:          ${formatTime(avg(tailwindResults.medium.cssnano))}`);
console.log(`  esbuild:          ${formatTime(avg(tailwindResults.medium.esbuild))}`);

console.log('\nLarge Tailwind CSS:');
console.log(`  Tailwind (build): ${formatTime(avg(tailwindResults.large.tailwind))}`);
console.log(`  LightningCSS:     ${formatTime(avg(tailwindResults.large.lightningcss))}`);
console.log(`  cssnano:          ${formatTime(avg(tailwindResults.large.cssnano))}`);
console.log(`  esbuild:          ${formatTime(avg(tailwindResults.large.esbuild))}`);

// Cleanup
fs.unlinkSync('bench-small.css');
fs.unlinkSync('bench-medium.css');
fs.unlinkSync('bench-large.css');
try { fs.unlinkSync('bench-tailwind-small.css'); } catch (e) {}
try { fs.unlinkSync('bench-tailwind-medium.css'); } catch (e) {}
try { fs.unlinkSync('bench-tailwind-large.css'); } catch (e) {}
try { fs.unlinkSync('bench-tailwind-small.html'); } catch (e) {}
try { fs.unlinkSync('bench-tailwind-medium.html'); } catch (e) {}
try { fs.unlinkSync('bench-tailwind-large.html'); } catch (e) {}
try { fs.unlinkSync('bench-tailwind-small-out.css'); } catch (e) {}
try { fs.unlinkSync('bench-tailwind-medium-out.css'); } catch (e) {}
try { fs.unlinkSync('bench-tailwind-large-out.css'); } catch (e) {}

// Output JSON for README update
const jsonResults = {
    small: {
        zcss: avg(results.small.zcss),
        lightningcss: avg(results.small.lightningcss),
        cssnano: avg(results.small.cssnano),
        esbuild: avg(results.small.esbuild),
        postcss: avg(results.small.postcss),
        sass: avg(results.small.sass),
        less: avg(results.small.less),
        stylus: avg(results.small.stylus)
    },
    medium: {
        zcss: avg(results.medium.zcss),
        lightningcss: avg(results.medium.lightningcss),
        cssnano: avg(results.medium.cssnano),
        esbuild: avg(results.medium.esbuild),
        postcss: avg(results.medium.postcss),
        sass: avg(results.medium.sass),
        less: avg(results.medium.less),
        stylus: avg(results.medium.stylus)
    },
    large: {
        zcss: avg(results.large.zcss),
        lightningcss: avg(results.large.lightningcss),
        cssnano: avg(results.large.cssnano),
        esbuild: avg(results.large.esbuild),
        postcss: avg(results.large.postcss),
        sass: avg(results.large.sass),
        less: avg(results.large.less),
        stylus: avg(results.large.stylus)
    }
};

const tailwindJsonResults = {
    small: {
        tailwind: avg(tailwindResults.small.tailwind),
        lightningcss: avg(tailwindResults.small.lightningcss),
        cssnano: avg(tailwindResults.small.cssnano),
        esbuild: avg(tailwindResults.small.esbuild)
    },
    medium: {
        tailwind: avg(tailwindResults.medium.tailwind),
        lightningcss: avg(tailwindResults.medium.lightningcss),
        cssnano: avg(tailwindResults.medium.cssnano),
        esbuild: avg(tailwindResults.medium.esbuild)
    },
    large: {
        tailwind: avg(tailwindResults.large.tailwind),
        lightningcss: avg(tailwindResults.large.lightningcss),
        cssnano: avg(tailwindResults.large.cssnano),
        esbuild: avg(tailwindResults.large.esbuild)
    }
};

fs.writeFileSync('benchmark-results.json', JSON.stringify(jsonResults, null, 2));
fs.writeFileSync('benchmark-tailwind-results.json', JSON.stringify(tailwindJsonResults, null, 2));
console.log('\nResults saved to benchmark-results.json');
console.log('Tailwind comparison results saved to benchmark-tailwind-results.json');
