# Azure Data Lab Toolkit documentation

This site uses [Astro](https://astro.build/), [Starlight](https://starlight.astro.build/), and [Slidev](https://sli.dev/).

## Local development

```bash
npm ci
npm run dev
```

Astro serves the documentation under `/Azure-Data-Lab-Toolkit/`.

## Production build and preview

```bash
npm run build
npm run check:links
npm run preview
```

The combined Starlight site and Slidev deck are written to `dist/`. The preview command preserves the GitHub Pages base path.

## Pitch deck

The deck source is `pitch.md`.

```bash
npm run slides
```

The production route is `/Azure-Data-Lab-Toolkit/pitch/deck/`.

## Deployment

`.github/workflows/deploy-docs.yml` builds and deploys `docs-site/dist` to GitHub Pages on changes to `main`.
