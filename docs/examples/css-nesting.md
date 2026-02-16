# CSS Nesting

zcss supports the CSS Nesting specification, allowing you to nest selectors for better organization and readability.

## Basic Nesting

```css
.card {
    padding: 1rem;
    border: 1px solid #ddd;
    
    &:hover {
        border-color: #007bff;
    }
    
    .title {
        font-size: 1.5rem;
        font-weight: bold;
        
        &::after {
            content: " →";
        }
    }
}
```

**Compiled output:**

```css
.card{padding:1rem;border:1px solid #ddd}.card:hover{border-color:#007bff}.card .title{font-size:1.5rem;font-weight:bold}.card .title::after{content:" →"}
```

## Parent Selector (`&`)

The `&` selector refers to the parent selector:

```css
.button {
    background: blue;
    
    &:hover {
        background: darkblue;
    }
    
    &.active {
        background: green;
    }
    
    &::before {
        content: "→";
    }
}
```

## Nested Selectors

Child selectors are automatically combined with parent:

```css
.container {
    width: 100%;
    
    .header {
        padding: 1rem;
    }
    
    .content {
        margin: 1rem;
    }
}
```

**Compiled output:**

```css
.container{width:100%}.container .header{padding:1rem}.container .content{margin:1rem}
```

## Complex Nesting

You can nest multiple levels:

```css
.card {
    padding: 1rem;
    
    .header {
        display: flex;
        
        .title {
            font-size: 1.5rem;
            
            &:hover {
                color: blue;
            }
        }
    }
    
    .body {
        margin-top: 1rem;
    }
}
```

## Next Steps

- [Custom Properties](/examples/custom-properties) — Learn about CSS variables
- [Media Queries](/examples/media-queries) — Responsive design examples
