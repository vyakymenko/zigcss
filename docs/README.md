# ZigCSS documentation

Official documentation site for ZigCSS (guide, API, examples, playground).

## Run locally

```bash
npm install
npm run dev
```

Open the URL shown in the terminal (e.g. http://localhost:5173/zigcss/).

## Build

From the docs folder:

```bash
npm run build
```

From the repo root:

```bash
npm run build:website
```

Output is in `docs/dist/`. Deploy the **contents** of `dist/` to your host. The app is built with `base: '/zigcss/'`, so:

- **GitHub Pages** (project site): set the publish directory to `docs/dist` and set the base URL in the repo to `/<repo-name>/` (e.g. `/zigcss/`), or use a custom domain and set base to `/`.
- **Static host (Netlify, Vercel, etc.)**: upload `dist/` and set the site to be served at `https://yourdomain.com/zigcss/`, or set base to `/` in `vite.config.ts` and serve at the root.

## Test

```bash
npm run test:run
```

Runs unit tests with Vitest. Use `npm run test` for watch mode.
