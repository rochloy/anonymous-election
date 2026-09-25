# Software Bill of Materials (SBOM)

**Project:** anonymous-election (`v0.15.2`)
**Generated:** 2026-09-25 · CycloneDX spec **1.6** · 499 components (full transitive tree)
**Tool:** [`@cyclonedx/bom`](https://github.com/CycloneDX/cyclonedx-npm) via `npx cyclonedx-npm`

## Regenerating

```bash
npm run sbom          # writes sbom.json (CycloneDX JSON, gitignored — regenerates per dependency change)
npm audit             # vulnerability audit (audit-level=high)
npm run security:check  # audit + sbom together
```

`sbom.json` is a point-in-time snapshot of the dependency tree and goes stale whenever `package.json`/`package-lock.json` change — regenerate before any compliance review or release.

## Runtime dependencies

| Package | Version | License | Purpose |
|---|---|---|---|
| `next` | 16.2.12 | MIT | App framework (App Router, Turbopack, proxy) |
| `react` / `react-dom` | 19.2.4 | MIT | UI runtime |
| `@supabase/supabase-js` | 2.111.0 | MIT | Database (PostgREST + RPCs), auth, storage |
| `qrcode` | 1.5.4 | MIT | QR generation (ballot QRs, Mobile Wizard QR) |
| `html5-qrcode` | 2.3.8 | Apache-2.0 | In-app QR scanning (camera + photo fallback) |
| `resend` | 6.18.1 | MIT | Transactional email (tokens, phase confirmations) |
| `@types/qrcode` | 1.5.6 | MIT | TypeScript definitions for `qrcode` |

> Packaging note: `@types/qrcode` sits in `dependencies` but is a type-only package — it belongs in `devDependencies`. Harmless (types are erased at build), listed here for accuracy.

## Development dependencies

| Package | Version | License | Purpose |
|---|---|---|---|
| `typescript` | 5.9.3 | Apache-2.0 | Language + type-checking |
| `tailwindcss` / `@tailwindcss/postcss` | 4.3.3 | MIT | Styling (v4, `prefers-color-scheme` dark variant) |
| `eslint` / `eslint-config-next` | 9.39.5 / 16.2.12 | MIT | Linting |
| `@playwright/test` | 1.62.1 | Apache-2.0 | UAT / E2E tests (`tests/*.spec.ts`) |
| `@cyclonedx/bom` | 4.1.6 | Apache-2.0 | SBOM generation (this document) |
| `dotenv` | 17.4.2 | BSD-2-Clause | `.env.local` loading for test runs |
| `@types/node` / `@types/react` / `@types/react-dom` | 20 / 19 / 19 | MIT | Type definitions |

## Transitive tree

The full CycloneDX JSON (`sbom.json`) enumerates **499 components** including transitive dependencies. Notable transitive packages:

- **Supabase stack:** `auth-js`, `postgrest-js`, `realtime-js`, `storage-js`, `functions-js` (all 2.111.0, MIT)
- **Turbopack/Next native:** `@next/oxide`, WASM runtime packages (MIT)
- **Zxing (via html5-qrcode):** bundled third_party zxing-js — the QR decoder used on iOS Safari (no native BarcodeDetector); see the AGENTS.md gotcha on EC Q detectability

## License summary

All direct dependencies are permissive licenses (MIT, Apache-2.0, BSD-2-Clause). No copyleft (GPL/AGPL) dependencies in the direct tree. For the full transitive license inventory, query `sbom.json` (`components[].licenses`).

## Security posture

- `npm audit --audit-level=high` gates (`audit` script) — run before releases
- Service-role key is server-only (`lib/supabase-server.ts`), never bundled to the client
- CSP is per-request with nonce (`proxy.ts`); see AGENTS.md for the `blob:` img-src requirement (file-scan)
