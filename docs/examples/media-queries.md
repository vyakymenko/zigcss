# Media Queries

zcss supports advanced media query parsing and optimization, including automatic merging of identical media queries.

## Basic Media Query

```css
.container {
    width: 100%;
}

@media (min-width: 768px) {
    .container {
        width: 750px;
        margin: 0 auto;
    }
}
```

## Multiple Breakpoints

```css
.container {
    width: 100%;
}

@media (min-width: 768px) {
    .container {
        width: 750px;
    }
}

@media (min-width: 992px) {
    .container {
        width: 970px;
    }
}

@media (min-width: 1200px) {
    .container {
        width: 1170px;
    }
}
```

## Complex Media Queries

```css
@media screen and (min-width: 768px) and (max-width: 1024px) {
    .sidebar {
        display: block;
    }
}

@media (prefers-color-scheme: dark) {
    .theme {
        background: #000;
        color: #fff;
    }
}

@media print {
    .no-print {
        display: none;
    }
}
```

## Media Query Merging

zcss automatically merges identical media queries:

**Input:**

```css
@media (min-width: 768px) {
    .container { width: 750px; }
}

@media (min-width: 768px) {
    .header { padding: 1rem; }
}
```

**Output:**

```css
@media (min-width: 768px) {
    .container { width: 750px; }
    .header { padding: 1rem; }
}
```

## Responsive Design Example

```css
.grid {
    display: grid;
    grid-template-columns: 1fr;
    gap: 1rem;
}

@media (min-width: 768px) {
    .grid {
        grid-template-columns: repeat(2, 1fr);
    }
}

@media (min-width: 1024px) {
    .grid {
        grid-template-columns: repeat(3, 1fr);
    }
}
```

## Next Steps

- [Container Queries](/examples/container-queries) — Container-based queries
- [Tailwind @apply](/examples/tailwind-apply) — Utility class expansion
