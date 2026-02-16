# Preprocessor Support

zcss supports multiple CSS preprocessor formats, allowing you to use your preferred syntax while benefiting from zcss's performance.

## Supported Formats

### SCSS/SASS

SCSS (Sassy CSS) and SASS (Syntactically Awesome Style Sheets) are fully supported:

```scss
$primary-color: #007bff;
$spacing-unit: 8px;

.button {
    background-color: $primary-color;
    padding: $spacing-unit * 2;
    
    &:hover {
        background-color: darken($primary-color, 10%);
    }
}
```

**Features:**
- Variables (`$variable`)
- Nesting
- Mixins with `@include` and `@content`
- Functions
- Variable arguments (`...`)

### LESS

LESS support includes variables and at-rules:

```less
@primary-color: #007bff;
@spacing-unit: 8px;

.button {
    background-color: @primary-color;
    padding: @spacing-unit * 2;
}
```

### CSS Modules

CSS Modules provide scoped class names:

```css
.container {
    color: red;
}
```

Compiled output includes scoped class names to prevent conflicts.

### PostCSS

PostCSS directives are supported:

```css
@apply px-4 py-2 bg-blue-500;

@custom-media --mobile (max-width: 768px);

@media (--mobile) {
    .container {
        padding: 1rem;
    }
}
```

**Supported directives:**
- `@apply` — Expand utility classes
- `@custom-media` — Custom media queries
- `@nest` — Nesting support

### Stylus

Stylus indented syntax is supported:

```stylus
primary-color = #007bff
spacing-unit = 8px

.button
    background-color primary-color
    padding spacing-unit * 2
```

## Compilation

All formats are compiled using the same zcss command:

```bash
# SCSS
zcss styles.scss -o styles.css

# LESS
zcss styles.less -o styles.css

# PostCSS
zcss styles.postcss -o styles.css

# Stylus
zcss styles.styl -o styles.css
```

## Next Steps

- [Examples](/examples/scss-features) — See SCSS features in action
- [Optimization](/guide/optimization) — Learn about CSS optimization
