# SCSS Advanced Features

zcss supports advanced SCSS features including mixins with content blocks and variable arguments.

## Mixins with @content

Mixins can accept content blocks using `@content`:

**Input:**

```scss
@mixin button {
    padding: 10px;
    border: 1px solid #ccc;
    @content;
}

.btn {
    @include button {
        color: red;
        background: blue;
    }
}
```

**Output:**

```css
.btn {
    padding: 10px;
    border: 1px solid #ccc;
    color: red;
    background: blue;
}
```

## Variable Arguments

Mixins and functions can accept variable arguments using `...` syntax:

**Input:**

```scss
@mixin box-shadow($shadows...) {
    box-shadow: $shadows;
}

.card {
    @include box-shadow(0 1px 3px rgba(0,0,0,0.12), 0 1px 2px rgba(0,0,0,0.24));
}
```

**Output:**

```css
.card {
    box-shadow: 0 1px 3px rgba(0,0,0,0.12), 0 1px 2px rgba(0,0,0,0.24);
}
```

## Variables

SCSS variables are fully supported:

```scss
$primary-color: #007bff;
$spacing-unit: 8px;
$border-radius: 4px;

.button {
    background-color: $primary-color;
    padding: $spacing-unit * 2;
    border-radius: $border-radius;
}
```

## Nesting

SCSS nesting works seamlessly:

```scss
.card {
    padding: 1rem;
    
    &:hover {
        border-color: #007bff;
    }
    
    .title {
        font-size: 1.5rem;
        font-weight: bold;
    }
}
```

## Functions

SCSS functions are supported:

```scss
@function calculate-width($columns, $gap) {
    @return ($columns * 100%) + ($gap * ($columns - 1));
}

.grid {
    width: calculate-width(3, 2rem);
}
```

## Complex Example

```scss
$breakpoints: (
    sm: 576px,
    md: 768px,
    lg: 992px,
);

@mixin respond-to($breakpoint) {
    @media (min-width: map-get($breakpoints, $breakpoint)) {
        @content;
    }
}

.container {
    width: 100%;
    
    @include respond-to(md) {
        width: 750px;
        margin: 0 auto;
    }
}
```

## Next Steps

- [CSS Nesting](/examples/css-nesting) — CSS nesting examples
- [Custom Properties](/examples/custom-properties) — CSS variables
