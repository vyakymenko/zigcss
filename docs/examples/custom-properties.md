# Custom Properties (CSS Variables)

zigcss supports CSS custom properties (CSS variables) with full `var()` function support and fallback values.

## Basic Usage

```css
:root {
    --primary-color: #007bff;
    --spacing-unit: 8px;
    --border-radius: 4px;
}

.button {
    background-color: var(--primary-color);
    padding: calc(var(--spacing-unit) * 2);
    border-radius: var(--border-radius);
}
```

## Fallback Values

Use fallback values when a custom property might not be defined:

```css
.button {
    color: var(--text-color, #000);
    padding: var(--button-padding, 10px 20px);
}
```

## Calculations

Custom properties work with `calc()`:

```css
:root {
    --base-size: 16px;
    --scale-factor: 1.5;
}

.heading {
    font-size: calc(var(--base-size) * var(--scale-factor));
}
```

## Cascading

Custom properties follow CSS cascade rules:

```css
:root {
    --color: blue;
}

.dark-theme {
    --color: white;
}

.element {
    color: var(--color);
}
```

## Advanced Example

```css
:root {
    --primary: #007bff;
    --secondary: #6c757d;
    --success: #28a745;
    --spacing-xs: 4px;
    --spacing-sm: 8px;
    --spacing-md: 16px;
    --spacing-lg: 24px;
    --border-radius: 4px;
}

.button {
    padding: var(--spacing-sm) var(--spacing-md);
    border-radius: var(--border-radius);
    background-color: var(--primary);
    color: white;
}

.button-secondary {
    background-color: var(--secondary);
}

.button-success {
    background-color: var(--success);
}
```

## Next Steps

- [Media Queries](/examples/media-queries) — Responsive design examples
- [Container Queries](/examples/container-queries) — Container-based queries
