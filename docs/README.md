# ZigCSS package website

The React site publishes the consumer-facing ZigCSS overview, installation path, explicit CSS and alternate-format boundaries, and evidence-linked documentation. The public compile playground remains disabled.

## Run locally

```bash
npm ci --ignore-scripts
npm run dev
```

Open the Vite URL under `/zigcss/`, for example `http://localhost:5173/zigcss/`.

## Test and build

From the documentation folder:

```bash
npm run test:run
npm run build
```

From the repository root:

```bash
npm run build:website
```

Output is written to `docs/dist/`. The production base is `/zigcss/`, matching the GitHub Pages project URL `https://vyakymenko.github.io/zigcss/`. `public/404.html` and the route-restoration script in `index.html` preserve direct links to client-side routes on GitHub Pages.

The workflow in `.github/workflows/docs.yml` tests, builds, uploads, and deploys the directory. Do not publish the source tree or development server.
