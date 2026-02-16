# Container Queries

zcss supports CSS Container Queries, allowing styles to be applied based on the size of a containing element rather than the viewport.

## Basic Container Query

```css
.card {
    container-type: inline-size;
}

@container (min-width: 400px) {
    .card {
        padding: 2rem;
    }
}
```

## Multiple Container Queries

```css
.card {
    container-type: inline-size;
}

@container (min-width: 400px) {
    .card {
        padding: 2rem;
    }
}

@container (min-width: 600px) {
    .card {
        display: grid;
        grid-template-columns: 1fr 1fr;
    }
}
```

## Container Query Merging

zcss automatically merges identical container queries:

**Input:**

```css
@container (min-width: 400px) {
    .card { padding: 2rem; }
}

@container (min-width: 400px) {
    .card { margin: 1rem; }
}
```

**Output:**

```css
@container (min-width: 400px) {
    .card { padding: 2rem; margin: 1rem; }
}
```

## Named Containers

```css
.sidebar {
    container-name: sidebar;
    container-type: inline-size;
}

@container sidebar (min-width: 300px) {
    .sidebar-content {
        display: flex;
        flex-direction: column;
    }
}
```

## Complex Example

```css
.card {
    container-type: inline-size;
    padding: 1rem;
}

@container (min-width: 400px) {
    .card {
        padding: 2rem;
    }
    
    .card-header {
        font-size: 1.5rem;
    }
}

@container (min-width: 600px) {
    .card {
        display: grid;
        grid-template-columns: 1fr 1fr;
        gap: 2rem;
    }
}
```

## Next Steps

- [Cascade Layers](/examples/cascade-layers) — CSS cascade layers
- [Tailwind @apply](/examples/tailwind-apply) — Utility class expansion
