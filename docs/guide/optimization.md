# Optimization

zcss includes a comprehensive optimization pipeline that reduces CSS size while maintaining functionality.

## Optimization Passes

### 1. Empty Rule Removal

Removes rules with no declarations:

```css
/* Before */
.empty-rule {
}

/* After */
/* Removed */
```

### 2. Selector Merging

Merges rules with identical selectors (hash-based, O(n) complexity):

```css
/* Before */
.button { color: red; }
.button { padding: 10px; }

/* After */
.button { color: red; padding: 10px; }
```

### 3. Redundant Selector Removal

Removes selectors that are subsets of other selectors:

```css
/* Before */
div.button { color: red; }
.button { color: red; }

/* After */
.button { color: red; }
```

### 4. Shorthand Property Optimization

Combines longhand properties into shorthand:

```css
/* Before */
.element {
    margin-top: 10px;
    margin-right: 20px;
    margin-bottom: 10px;
    margin-left: 20px;
}

/* After */
.element {
    margin: 10px 20px;
}
```

Supported shorthand optimizations:
- `margin-*` → `margin`
- `padding-*` → `padding`
- `border-*` → `border`
- `font-*` → `font`
- `background-*` → `background`
- `flex-*` → `flex`
- `grid-template-*` → `grid-template`
- `*-gap` → `gap`

### 5. Advanced Selector Optimization

- Universal selector removal (`*` removed when redundant)
- Selector simplification (redundant combinators removed)
- Specificity-based optimization

### 6. Duplicate Declaration Removal

Removes duplicate properties (keeps last):

```css
/* Before */
.button {
    color: red;
    color: blue;
}

/* After */
.button {
    color: blue;
}
```

### 7. Value Optimization

Advanced value optimizations:

- Hex color minification (`#ffffff` → `#fff`)
- RGB to hex conversion (`rgb(255, 255, 255)` → `#fff`)
- CSS color name to hex (`red` → `#f00`)
- Zero unit removal (`0px` → `0`)

### 8. Media Query Merging

Merges identical `@media` rules:

```css
/* Before */
@media (min-width: 768px) { .container { width: 750px; } }
@media (min-width: 768px) { .header { padding: 1rem; } }

/* After */
@media (min-width: 768px) {
    .container { width: 750px; }
    .header { padding: 1rem; }
}
```

### 9. Container Query Merging

Merges identical `@container` rules:

```css
/* Before */
@container (min-width: 400px) { .card { padding: 1rem; } }
@container (min-width: 400px) { .card { margin: 1rem; } }

/* After */
@container (min-width: 400px) {
    .card { padding: 1rem; margin: 1rem; }
}
```

### 10. Cascade Layer Merging

Merges identical `@layer` rules:

```css
/* Before */
@layer theme { .button { color: red; } }
@layer theme { .link { color: blue; } }

/* After */
@layer theme {
    .button { color: red; }
    .link { color: blue; }
}
```

## Enabling Optimization

### Command Line

```bash
# Enable all optimizations
zcss input.css -o output.css --optimize

# With minification
zcss input.css -o output.css --optimize --minify
```

### Library API

```zig
const options = zcss.CompileOptions{
    .optimize = true,
    .minify = true,
    .remove_comments = true,
    .optimize_selectors = true,
    .remove_empty_rules = true,
};
```

## Performance Impact

Optimizations are designed to be fast:
- Hash-based selector merging: O(n) instead of O(n²)
- Single-pass optimizations where possible
- Minimal memory allocations

## Next Steps

- [Performance Guide](/guide/performance) — Learn about zcss performance
- [Examples](/examples/css-nesting) — See optimization in action
