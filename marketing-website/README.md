# Aro marketing website

The single-page Aro product site is generated from the audited
[`features.md`](../features.md) catalogue. It is a static Next.js export hosted
at [listenaro.xyz](https://listenaro.xyz/).

## Work locally

```bash
npm install
npm run dev
```

Open <http://localhost:3000>. To run the same checks as CI:

```bash
npm run check
```

The production site is built after a successful `Development Release`. That
workflow passes the new semantic version and exact Apple Silicon/Intel release
asset URLs into the static build before deploying it to GitHub Pages.

The production export is built for the root of `listenaro.xyz`; no base path is
required.
