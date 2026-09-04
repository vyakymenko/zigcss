# ZigCSS package website

The React site publishes the consumer-facing ZigCSS overview, installation path, explicit CSS and alternate-format boundaries, and evidence-linked documentation. The public compile playground remains disabled.

## Run the website only

```bash
cd docs
npm ci --ignore-scripts
npm run dev
```

Open the Vite URL under `/zigcss/`, for example `http://localhost:5173/zigcss/`.

## Run the compiler-aware development server

From the repository root, install both exact lockfiles without package lifecycle
downloads, then start the orchestrator:

```bash
npm ci --ignore-scripts
npm --prefix docs ci --ignore-scripts
npm run dev
```

The root `npm run dev` command completes one successful Zig build before Vite
starts, then watches the compiler and marks Docker health unhealthy while a
rebuild is pending or failed. A missing compiler or failed initial build exits
nonzero instead of serving against a stale binary. Use `node dev.js --no-zig`
only when you explicitly want the documentation website without compiler
readiness.

## Run the development container

Docker users can run the same compiler-aware path without installing Node or
Zig on the host:

```bash
npm run dev:docker
```

Open `http://127.0.0.1:5173/zigcss/`. The source checkout is mounted read-only;
documentation dependencies and compiler outputs live in project-scoped named
volumes. Stop the service without deleting those caches:

```bash
docker compose -f docker-compose.dev.yml down
```

To deliberately discard only this Compose project's dependency/compiler cache
volumes and force a clean install and build on the next start, run:

```bash
docker compose -f docker-compose.dev.yml down --volumes
```

This image and server are development-only. They are not the production static
documentation container and expose no compiler HTTP API.

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
