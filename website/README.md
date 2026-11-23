# Zedis documentation site

Astro + [Starlight](https://starlight.astro.build) sources for
<https://zedis.barddoo.com>.

This directory is self-contained: it has its own `package.json` and `bun.lock`,
and the Zig build never descends into it. Nothing here is required to build, test,
or run the server.

## Commands

```bash
bun install        # install dependencies
bun run dev        # dev server on http://localhost:4321
bun run build      # static build into ./dist
bun run preview    # serve ./dist locally
```

Use bun, not npm — the lockfile is `bun.lock` and CI installs with
`bun install --frozen-lockfile`.

## Layout

- `src/content/docs/` — one file per page; the route comes from the file path
  (`architecture/store.md` → `/architecture/store/`).
- `astro.config.mjs` — site URL, sidebar, logo, edit links.
- `public/` — copied verbatim to `dist/`. `CNAME` pins the custom domain.
- `src/assets/` — images imported by pages.

`src/content/docs/index.mdx` is the splash landing page; delete `template: splash`
to give it the sidebar.

## Mirrored pages

Four pages are copies of documents kept in the repository root:

| Page                      | Source                        |
| ------------------------- | ----------------------------- |
| `/architecture/overview/` | `docs/server-architecture.md` |
| `/architecture/memory/`   | `docs/memory-architecture.md` |
| `/architecture/store/`    | `docs/store-cache-layout.md`  |
| `/compatibility/`         | `REDIS_COMPATIBILITY.md`      |

The files in the repository root stay canonical. A change to command support, the
thread model, the memory budget, or the AOF must be made in both places; each
mirrored page says so in a note at the bottom.

Deliberately not published: `benchmark-comparison.md` (single-run results on one
machine), `CHANGELOG.md`, and `plans/`.

## Deployment

`.github/workflows/docs.yml` builds this directory with bun and publishes `dist/`
to GitHub Pages on pushes to `main` that touch `website/**` or `docs/**`. The
custom domain comes from `public/CNAME` plus the Pages settings for the repository;
DNS is a `CNAME` for `zedis` pointing at `barddoo.github.io`.
