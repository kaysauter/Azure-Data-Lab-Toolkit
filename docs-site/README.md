# Azure Data Lab Toolkit documentation

This site uses [Astro](https://astro.build/), [Starlight](https://starlight.astro.build/), and [Slidev](https://sli.dev/).

## Local development

```bash
npm ci
npm run dev
```

Astro serves the documentation under `/Azure-Data-Lab-Toolkit/`.
The Astro development server does not embed Slidev. Run `npm run slides` in a
second terminal when editing the deck; use the production preview below to test
the combined GitHub Pages routes.

## Production build and preview

```bash
npm run build
npm run check:links
npm run preview
```

The combined Starlight site and Slidev deck are written to `dist/`. The preview command preserves the GitHub Pages base path.
Run `npm run check:docs` to build both surfaces and verify internal routes and same-site anchors in one command.

## Pitch deck

The deck source is `pitch.md`.

```bash
npm run slides
```

The production route is `/Azure-Data-Lab-Toolkit/pitch/deck/`.

## Deployment

`.github/workflows/docs-checks.yml` checks the combined site for pull requests.
`.github/workflows/deploy-docs.yml` builds and deploys `docs-site/dist` to GitHub Pages on changes to `main`.

The repository's Pages source must be set to **GitHub Actions**. The production
site uses `/Azure-Data-Lab-Toolkit/` and the pitch deck uses
`/Azure-Data-Lab-Toolkit/pitch/deck/`.
