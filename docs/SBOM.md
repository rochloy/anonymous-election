# Software Bill of Materials (SBOM)

**Project:** anonymous-election (`v0.15.3`)
**Generated SBOM snapshot:** `sbom.json` (gitignored) regenerated on 2026-10-02 via `npm run sbom` after `npm ci --ignore-scripts --no-audit`.
**CycloneDX:** spec **1.6** · metadata timestamp **2026-10-02T21:39:15.852Z** · **530 components** in the installed dependency tree.
**Toolchain recorded in SBOM metadata:** npm `11.12.1`, `@cyclonedx/cyclonedx-npm` `6.0.1`.

## Scope and interpretation

- This SBOM is a **local installed-tree snapshot** of what `cyclonedx-npm` observed in this workspace at generation time.
- It includes optional/extraneous locally-installed components present under `node_modules` (for example optional WASM/native-related packages), so it is **not equivalent** to a pure lockfile BOM and **not guaranteed** to equal a Vercel production deployment artifact tree.
- A lockfile-only generation path was attempted with `npx cyclonedx-npm --package-lock-only` and failed in this environment due to npm-ls invalid optional-module resolution; this document therefore describes the installed-tree BOM only.

## Regenerating

```bash
npm ci --ignore-scripts --no-audit
npm run sbom            # writes sbom.json (CycloneDX JSON, gitignored)
npm audit               # full audit (dev + prod)
npm audit --omit=dev    # production-focused audit
```

`sbom.json` is intentionally gitignored and must be regenerated whenever dependency state changes.

## Direct runtime dependencies (from `package.json` `dependencies`)

| Package | Installed version (`npm ls`) | License (declared in SBOM) | Notes |
|---|---:|---|---|
| `@supabase/supabase-js` | 2.111.0 | MIT | Runtime SDK |
| `@types/qrcode` | 1.5.6 | MIT | Type-only package listed in runtime `dependencies` by project choice; kept here intentionally |
| `html5-qrcode` | 2.3.8 | Apache-2.0 | Runtime scanner library |
| `next` | 16.3.8 | MIT | Runtime framework |
| `qrcode` | 1.5.4 | MIT | Runtime QR generation |
| `react` | 19.2.4 | MIT | Runtime UI library |
| `react-dom` | 19.2.4 | MIT | Runtime renderer |
| `resend` | 6.18.1 | MIT | Runtime email API client |

## Direct development dependencies (from `package.json` `devDependencies`)

| Package | Installed version (`npm ls`) | License (declared in SBOM) |
|---|---:|---|
| `@cyclonedx/bom` | 4.1.6 | Apache-2.0 |
| `@playwright/test` | 1.62.1 | Apache-2.0 |
| `@tailwindcss/postcss` | 4.3.3 | MIT |
| `@types/node` | 20.19.43 | MIT |
| `@types/react` | 19.2.18 | MIT |
| `@types/react-dom` | 19.2.4 | MIT |
| `dotenv` | 17.4.2 | BSD-2-Clause |
| `eslint` | 9.39.5 | MIT |
| `eslint-config-next` | 16.3.8 | MIT |
| `tailwindcss` | 4.3.3 | MIT |
| `typescript` | 5.9.3 | Apache-2.0 |
| `vitest` | 4.1.11 | MIT |

## Transitive/installed-tree summary and risks

- Full installed tree in this snapshot contains **530 components** (transitive + optional + extraneous as reported by npm/cyclonedx).
- `npm ls --depth=0` reported extraneous optional packages in local `node_modules` (e.g. `@img/sharp-wasm32`, `@emnapi/*`, `@napi-rs/wasm-runtime`, `@tybys/wasm-util`), matching installed-tree caveats above.
- License posture for the full tree is mixed due to transitive optional entries (including LGPL expressions), so this document does **not** assert that the full 530-component tree is uniformly permissive.

## License notes from generated SBOM

- Direct dependencies remain predominantly permissive (MIT / Apache-2.0 / BSD family), but this statement applies to **direct dependencies only**.
- Transitive optional components in this snapshot include non-permissive/copyleft expressions, e.g.:
  - `@img/sharp-libvips-linux-x64@1.3.4` → `LGPL-3.0-or-later`
  - `@img/sharp-wasm32@0.35.5` → `Apache-2.0 AND LGPL-3.0-or-later AND MIT` (marked extraneous in this local snapshot)
- Some entries use SPDX expressions (not unknown licenses), e.g.:
  - `expand-template@2.0.3` → `(MIT OR WTFPL)`
  - `rc@1.2.8` → `(BSD-2-Clause OR MIT OR Apache-2.0)`

Because this is an installed-tree snapshot rather than a deployment artifact BOM, whether any optional LGPL-bearing transitive component is actually shipped/linked in production depends on build/runtime packaging. **No legal conclusion is made here**; legal/compliance counsel review is still required for release decisions.

## Security posture snapshot

- `npm audit` at generation time reported: high `0`, critical `0`, moderate `1` (dev-only advisory).
- `npm audit --omit=dev` reported: high `0`, critical `0`, moderate `0`.
- Treat these audit counts as point-in-time outputs; rerun audits for each release candidate.
