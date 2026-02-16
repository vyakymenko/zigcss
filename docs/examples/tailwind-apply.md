# Tailwind @apply Expansion

zigcss supports Tailwind CSS `@apply` directive expansion, automatically converting utility classes into CSS declarations.

## Basic @apply

**Input:**

```css
.btn {
    @apply px-4 py-2 bg-blue-500 text-white rounded-lg shadow-md;
}
```

**Output:**

```css
.btn {
    padding-left: 1rem;
    padding-right: 1rem;
    padding-top: 0.5rem;
    padding-bottom: 0.5rem;
    background-color: #3b82f6;
    color: #fff;
    border-radius: 0.5rem;
    box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1);
}
```

## Supported Utilities

zigcss includes a comprehensive Tailwind utility registry covering:

### Spacing

- `p-*`, `px-*`, `py-*`, `pt-*`, `pr-*`, `pb-*`, `pl-*` — Padding
- `m-*`, `mx-*`, `my-*`, `mt-*`, `mr-*`, `mb-*`, `ml-*` — Margin

### Colors

- `text-*` — Text colors
- `bg-*` — Background colors

### Typography

- Font sizes, weights, styles, transforms

### Layout

- Display, width, height, overflow utilities

### Flexbox

- Flex direction, wrap, alignment utilities

### Grid

- Grid template columns utilities

### Borders

- Border width, style, radius utilities

### Effects

- Shadows, opacity utilities

## Example

```css
.card {
    @apply p-6 bg-white rounded-lg shadow-lg;
}

.card-header {
    @apply mb-4 text-2xl font-bold;
}

.card-body {
    @apply text-gray-700;
}

.card-footer {
    @apply mt-4 pt-4 border-t border-gray-200;
}
```

## Next Steps

- [SCSS Features](/examples/scss-features) — Advanced SCSS features
- [Custom Properties](/examples/custom-properties) — CSS variables
