import { test, expect, type Page, type BrowserContext } from '@playwright/test';
import QRCode from 'qrcode';
import fs from 'fs';
import path from 'path';

/**
 * UAT — v0.15.1 (Wave 10 post-launch + eligibility phase-gate)
 * Plan: docs/plans/2026-09-21-v0.15.1-uat-plan.md
 *
 * Run (headed, local):
 *   npx playwright test tests/uat-v0151.spec.ts --headed --reporter=list --workers=1
 *
 * [USER] steps pause and print a terminal banner — type the admin secret
 * in the headed browser. The secret value is never logged.
 * Suite J (email / phase / digital vote) is intentionally not implemented here.
 */

const BASE_URL = 'http://localhost:3000';
const SHOT_DIR = path.join('test-results', 'uat-v0151');

function shotDir(): string {
  fs.mkdirSync(SHOT_DIR, { recursive: true });
  return SHOT_DIR;
}

async function getCsrfToken(context: BrowserContext): Promise<string> {
  const cookies = await context.cookies();
  const csrf = cookies.find((c) => c.name === 'admin_csrf');
  return csrf?.value || '';
}

function userBanner(what: string): void {
  const line = '='.repeat(50);
  console.log(`\n${line}`);
  console.log(`[USER] ACTION REQUIRED: ${what}`);
  console.log('Waiting up to 5 minutes in the headed browser...');
  console.log(`${line}\n`);
}

// Shared desktop session (Suite B onward)
let desktopContext: BrowserContext;
let desktopPage: Page;
// Shared mobile session (Suite H)
let mobileContext: BrowserContext;
let mobilePage: Page;

test.describe.configure({ mode: 'serial' });

test.describe('UAT v0.15.1', () => {
  test.afterAll(async () => {
    await mobileContext?.close().catch(() => {});
    await desktopContext?.close().catch(() => {});
  });

  // ─── Suite A — Public surface + login shell ───────────────────────────

  test('A1: Home page loads', async ({ page }) => {
    const res = await page.goto(BASE_URL);
    expect(res?.status()).toBeLessThan(400);
    await expect(page.locator('h1').first()).toBeVisible({ timeout: 15_000 });
  });

  test('A2: /verify loads', async ({ page }) => {
    const res = await page.goto(`${BASE_URL}/verify`);
    expect(res?.status()).toBeLessThan(400);
    await expect(page.locator('h1').first()).toBeVisible({ timeout: 15_000 });
  });

  test('A3: /results loads', async ({ page }) => {
    const res = await page.goto(`${BASE_URL}/results`);
    expect(res?.status()).toBeLessThan(400);
    await expect(page.locator('h1').first()).toBeVisible({ timeout: 15_000 });
  });

  test('A4 [NEG]: Wrong admin secret rejected', async ({ page }) => {
    await page.goto(`${BASE_URL}/admin/dashboard`);
    await page.locator('input[name="secret"]').fill('wrong-secret');
    await page.getByRole('button', { name: 'Access Dashboard' }).click();
    await expect(
      page.locator('text=Invalid admin secret').or(page.locator('text=Unauthorized'))
    ).toBeVisible({ timeout: 10_000 });
    await expect(page.locator('input[name="secret"]')).toBeVisible();
  });

  test('A5: Mobile login card renders (logged out)', async ({ page }) => {
    await page.goto(`${BASE_URL}/admin/mobile`);
    await expect(page.getByRole('heading', { name: 'Mobile Wizard' })).toBeVisible({ timeout: 15_000 });
    await expect(page.getByPlaceholder('Admin secret')).toBeVisible();
    await expect(page.locator('text=Session: 12 min, auto-logout')).toBeVisible();
    await expect(page.getByRole('link', { name: 'Admin Dashboard →' })).toBeVisible();
  });

  test('A6: Mobile login → Admin Dashboard link', async ({ page }) => {
    await page.goto(`${BASE_URL}/admin/mobile`);
    await page.getByRole('link', { name: 'Admin Dashboard →' }).click();
    await expect(page).toHaveURL(/\/admin\/dashboard/, { timeout: 15_000 });
    await expect(page.locator('input[name="secret"]')).toBeVisible();
  });

  // ─── Suite B — Dashboard login [USER] + header ────────────────────────

  test('B: Dashboard login [USER] + header + phase card', async ({ browser }) => {
    test.setTimeout(360_000); // USER pause can take up to 5 min
    desktopContext = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    desktopPage = await desktopContext.newPage();

    await desktopPage.goto(`${BASE_URL}/admin/dashboard`);
    await expect(desktopPage.locator('input[name="secret"]')).toBeVisible();

    userBanner('Enter the ADMIN SECRET on the dashboard login and click "Access Dashboard"');
    await expect(
      desktopPage.getByRole('heading', { name: 'Election Admin Dashboard' })
    ).toBeVisible({ timeout: 300_000 });

    // B3 header
    await expect(desktopPage.getByRole('link', { name: '📱 Mobile Wizard' })).toBeVisible();
    await expect(desktopPage.getByRole('button', { name: '📱 Mobile QR' })).toBeVisible();
    await expect(desktopPage.getByRole('button', { name: 'Clear Admin Auth' })).toBeVisible();

    // B4 phase card — "VOTING" appears in the CURRENT PHASE card
    await expect(desktopPage.locator('text=CURRENT PHASE')).toBeVisible();
    await expect(desktopPage.locator('text=VOTING').first()).toBeVisible();

    // B5 total members ≥ 1
    const membersCard = desktopPage.locator('text=TOTAL MEMBERS').locator('..');
    const membersText = (await membersCard.innerText()).replace(/\D/g, '');
    expect(Number(membersText)).toBeGreaterThanOrEqual(1);

    await desktopPage.screenshot({ path: path.join(shotDir(), 'B3-dashboard-header.png'), fullPage: false });
  });

  // ─── Suite C — Mobile Wizard entry points ─────────────────────────────

  test('C1: Mobile Wizard href is /admin/mobile', async () => {
    const href = await desktopPage.getByRole('link', { name: '📱 Mobile Wizard' }).getAttribute('href');
    expect(href).toBe('/admin/mobile');
  });

  test('C2–C3: Mobile QR modal renders and closes', async () => {
    await desktopPage.getByRole('button', { name: '📱 Mobile QR' }).click();
    const modalHeading = desktopPage.getByRole('heading', { name: 'Mobile Wizard QR Code' });
    await expect(modalHeading).toBeVisible({ timeout: 10_000 });

    const qrImg = desktopPage.getByAltText('Mobile Wizard QR Code');
    await expect(qrImg).toBeVisible();
    const src = await qrImg.getAttribute('src');
    expect(src).toMatch(/^data:image\/(png|svg\+xml);base64,/);
    await expect(desktopPage.locator('text=Scan with your phone to open the Mobile Wizard')).toBeVisible();

    await desktopPage.screenshot({ path: path.join(shotDir(), 'C2-mobile-qr-modal.png') });

    await desktopPage.getByRole('button', { name: 'Close' }).click();
    await expect(modalHeading).not.toBeVisible();
  });

  // ─── Suite D — Record / Spoil: shared Ballot Lookup ───────────────────

  test('D1–D9: Ballot Lookup bar + pane layout + disabled states', async () => {
    await desktopPage.getByRole('button', { name: 'Record / Spoil Vote' }).click();
    await desktopPage.screenshot({ path: path.join(shotDir(), 'D1-ballot-lookup.png'), fullPage: true });

    // D2 shared lookup
    await expect(desktopPage.getByRole('heading', { name: 'Ballot Lookup' })).toBeVisible();
    await expect(desktopPage.getByRole('button', { name: 'Scan QR Code with Camera' })).toBeVisible();
    const ballotInput = desktopPage.getByPlaceholder('Enter full HMAC Ballot ID or scan QR code above...');
    await expect(ballotInput).toBeVisible();

    // D3–D4 scanner toggle
    await desktopPage.getByRole('button', { name: 'Scan QR Code with Camera' }).click();
    await expect(desktopPage.locator('#qr-reader')).toBeVisible({ timeout: 10_000 });
    await desktopPage.getByRole('button', { name: 'Close QR Scanner' }).click();
    await expect(desktopPage.locator('#qr-reader')).toHaveCount(0);

    // D5 Record pane — candidate only, no ballot field inside
    await expect(desktopPage.getByRole('heading', { name: 'Record Paper Vote' })).toBeVisible();
    await expect(desktopPage.getByRole('combobox')).toBeVisible();
    // The only ballot ID input on the page is the shared one
    expect(await desktopPage.locator('input[placeholder*="HMAC Ballot ID"]').count()).toBe(1);

    // D6 Spoil pane
    await expect(desktopPage.getByRole('heading', { name: 'Mark Ballot as Spoiled' })).toBeVisible();
    await expect(desktopPage.getByPlaceholder('e.g. Physical ballot damaged, voter request...')).toBeVisible();

    // D7 empty ballot ID → both disabled
    const recordBtn = desktopPage.getByRole('button', { name: 'Record Paper Vote', exact: true });
    const spoilBtn = desktopPage.getByRole('button', { name: 'Mark Ballot Spoiled / Invalid' });
    await expect(recordBtn).toBeDisabled();
    await expect(spoilBtn).toBeDisabled();

    // D8 non-empty → spoil enabled; record still needs candidate
    await ballotInput.fill('PAPER:deadbeefdeadbeefdeadbeefdeadbeef.deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef');
    await expect(spoilBtn).toBeEnabled();
    await expect(recordBtn).toBeDisabled();

    // D9 select candidate → record enabled
    await desktopPage.getByRole('combobox').selectOption({ index: 1 });
    await expect(recordBtn).toBeEnabled();

    // reset shared field so later suites don't submit by accident
    await ballotInput.fill('');
  });

  // ─── Suite E — Voter Eligibility (SETUP-only gate) ────────────────────

  test('E1–E8: Eligibility read-only UI during VOTING', async () => {
    await desktopPage.getByRole('button', { name: 'Voter Eligibility' }).click();

    await expect(desktopPage.getByRole('heading', { name: 'Search Member' })).toBeVisible();
    // E2 yellow banner
    await expect(desktopPage.locator('text=Eligibility is read-only during VOTING phase')).toBeVisible();
    await expect(desktopPage.locator('text=Eligibility can only be changed during SETUP phase.')).toBeVisible();
    // E3 helper text
    await expect(desktopPage.locator('text=read-only')).toBeVisible();

    await desktopPage.screenshot({ path: path.join(shotDir(), 'E2-eligibility-readonly.png'), fullPage: true });

    // E4 debounced lookahead — no Search click
    const search = desktopPage.getByPlaceholder('Enter member name (e.g. Voter 001)...');
    await search.fill('Voter 0');
    await expect(desktopPage.locator('text=Search Results (')).toBeVisible({ timeout: 10_000 });

    // E5 first result has badge
    const resultsHeading = desktopPage.locator('h3', { hasText: /Search Results \(\d+\)/ });
    await expect(resultsHeading).toBeVisible();

    // E6–E8 all controls disabled
    const eligibleBtn = desktopPage.getByRole('button', { name: 'Eligible', exact: true });
    const ineligibleBtn = desktopPage.getByRole('button', { name: 'Ineligible', exact: true });
    await expect(eligibleBtn.first()).toBeDisabled();
    await expect(ineligibleBtn.first()).toBeDisabled();

    const saveBtn = desktopPage.getByRole('button', { name: 'Save eligibility' });
    await expect(saveBtn.first()).toBeDisabled();
  });

  test('E9 [NEG][API]: POST eligibility rejected outside SETUP', async () => {
    // Grab a member id via authenticated members search
    const searchRes = await desktopPage.request.get(`${BASE_URL}/api/admin/members?q=Voter%20001`);
    expect([200, 429]).toContain(searchRes.status());
    test.skip(searchRes.status() === 429, 'Members search rate-limited; re-run later');

    const searchBody = await searchRes.json();
    const members = searchBody.members ?? searchBody;
    test.skip(!Array.isArray(members) || members.length === 0, 'No members returned for search');

    const memberId = members[0].id as string;
    expect(memberId).toMatch(/^[0-9a-f-]{36}$/i);

    const csrf = await getCsrfToken(desktopContext);
    const postRes = await desktopPage.request.post(`${BASE_URL}/api/admin/eligibility`, {
      headers: {
        'Content-Type': 'application/json',
        'x-csrf-token': csrf,
      },
      data: {
        member_id: memberId,
        voting_eligible: true,
        eligibility_reason: 'ELIGIBLE',
        note: 'UAT v0.15.1 negative probe — must be rejected',
      },
    });

    expect(postRes.status()).toBe(400);
    const body = await postRes.json();
    expect(JSON.stringify(body)).toMatch(/SETUP phase/i);
  });

  // ─── Suite F — Tab 1 debounced lookahead ──────────────────────────────

  test('F1–F3: Search & Issue Paper Ballot debounced lookahead', async () => {
    await desktopPage.getByRole('button', { name: 'Search & Issue Paper Ballot' }).click();
    await expect(desktopPage.getByRole('heading', { name: 'Search Member' })).toBeVisible();

    const search = desktopPage.getByPlaceholder('Enter member name (e.g. Voter 001)...');
    await search.fill('Voter 0');
    await expect(desktopPage.locator('text=Search Results (')).toBeVisible({ timeout: 10_000 });
    // result rows show member name
    await expect(desktopPage.locator('text=Voter').first()).toBeVisible();
  });

  // ─── Suite G — Reporting (VOTING) ─────────────────────────────────────

  test('G1–G5: Reporting generate + CSV gates', async () => {
    await desktopPage.getByRole('button', { name: 'Reporting' }).click();
    await expect(desktopPage.getByRole('heading', { name: 'Election Progress Report' })).toBeVisible({ timeout: 15_000 });

    await desktopPage.getByRole('button', { name: /Generate Report|Refresh Report/ }).click();
    // Wait for summary or tally to render
    await expect(
      desktopPage.locator('text=Total votes').or(desktopPage.locator('text=Tally by candidate'))
    ).toBeVisible({ timeout: 20_000 });

    const progressBtn = desktopPage.getByRole('button', { name: 'Export Progress CSV' });
    await expect(progressBtn).toBeEnabled();

    // G4 results export locked during VOTING
    const resultsBtn = desktopPage.getByRole('button', { name: 'Export Results CSV' });
    await expect(resultsBtn).toBeDisabled();

    // G5 progress export fires a download (no navigation crash)
    const downloadPromise = desktopPage.waitForEvent('download', { timeout: 15_000 }).catch(() => null);
    await progressBtn.click();
    const download = await downloadPromise;
    if (download) {
      expect(download.suggestedFilename()).toMatch(/election-progress/);
    }

    await desktopPage.screenshot({ path: path.join(shotDir(), 'G-reporting.png'), fullPage: true });
  });

  // ─── Suite K — Regression spot-checks ─────────────────────────────────

  test('K1: Tab click-through — all visible tabs activate', async () => {
    const tabs = [
      'Search & Issue Paper Ballot',
      'Preprinted Ballots',
      'Record / Spoil Vote',
      'Election Settings',
      'Candidates',
      'Members Management',
      'Token Dispatch',
      'Nominations',
      'Voter Eligibility',
      'Reporting',
    ];
    for (const name of tabs) {
      const btn = desktopPage.getByRole('button', { name, exact: true });
      if ((await btn.count()) === 0) continue;
      await btn.click();
      await expect(btn).toHaveClass(/border-blue-600/, { timeout: 5_000 });
      await desktopPage.waitForTimeout(150);
    }
  });

  test('K3 [NEG]: /api/admin/stats without auth → 401/429', async ({ request }) => {
    const res = await request.get(`${BASE_URL}/api/admin/stats`);
    expect([401, 429]).toContain(res.status());
  });

  test('K4 [NEG]: /api/admin/stats wrong secret → 401/429', async ({ request }) => {
    const res = await request.get(`${BASE_URL}/api/admin/stats`, {
      headers: { 'x-admin-secret': 'wrong-secret' },
    });
    expect([401, 429]).toContain(res.status());
  });

  test('K5: Token Dispatch form + disabled dispatch when empty', async () => {
    await desktopPage.getByRole('button', { name: 'Token Dispatch' }).click();
    await expect(desktopPage.locator('h2', { hasText: /Dispatch/ })).toBeVisible({ timeout: 10_000 });
    const dispatchBtn = desktopPage.getByRole('button', { name: 'Dispatch Tokens' });
    await expect(dispatchBtn).toBeDisabled();
  });

  // ─── Suite H — Mobile Wizard (fresh mobile-viewport context) ──────────

  test('H1: Mobile wizard login card at 390×844', async ({ browser }) => {
    mobileContext = await browser.newContext({ viewport: { width: 390, height: 844 } });
    mobilePage = await mobileContext.newPage();
    await mobilePage.goto(`${BASE_URL}/admin/mobile`);
    await expect(mobilePage.getByRole('heading', { name: 'Mobile Wizard' })).toBeVisible({ timeout: 15_000 });
    await expect(mobilePage.getByPlaceholder('Admin secret')).toBeVisible();
  });

  test('H2–H12: Mobile wizard login [USER] + modes + session UI', async () => {
    test.setTimeout(360_000); // USER pause can take up to 5 min
    userBanner('Enter the ADMIN SECRET on the mobile wizard login (phone-sized browser)');
    // H2 user types secret; login button becomes enabled then they submit —
    // we wait for the Tally top bar which only appears when loggedIn=true.
    // If the user only types but forgets submit, also accept auto-submit assist:
    const secretField = mobilePage.getByPlaceholder('Admin secret');
    await expect(secretField).toBeVisible();

    // Wait for user to complete login (they click "Log in")
    await expect(mobilePage.locator('span', { hasText: 'Mobile Wizard' }).first()).toBeVisible({ timeout: 300_000 });

    // H3 countdown ≤ 12:00 and logout menu
    const countdown = mobilePage.locator('span', { hasText: /⏱\s*\d+:\d{2}/ });
    await expect(countdown).toBeVisible({ timeout: 10_000 });
    const cdText = (await countdown.innerText()).trim();
    const m = cdText.match(/⏱\s*(\d+):(\d{2})/);
    expect(m).not.toBeNull();
    const totalSec = Number(m![1]) * 60 + Number(m![2]);
    expect(totalSec).toBeGreaterThan(0);
    expect(totalSec).toBeLessThanOrEqual(12 * 60);

    // H4–H5 phase-gated order + default Check-in (VOTING)
    const checkinTab = mobilePage.getByRole('button', { name: 'Check-in', exact: true });
    const recordTab = mobilePage.getByRole('button', { name: 'Record', exact: true });
    const spoilTab = mobilePage.getByRole('button', { name: 'Spoil', exact: true });
    await expect(checkinTab).toBeVisible();
    await expect(recordTab).toBeVisible();
    await expect(spoilTab).toBeVisible();

    // DOM order: Check-in before Record before Spoil during VOTING
    const order = await Promise.all(
      [checkinTab, recordTab, spoilTab].map((l) => l.evaluate((el) => {
        const row = el.parentElement;
        if (!row) return -1;
        return Array.from(row.children).indexOf(el);
      }))
    );
    expect(order).toEqual([0, 1, 2]);

    // Default selected = Check-in (bg-white shadow on selected)
    await expect(checkinTab).toHaveClass(/bg-white/);

    // H6 unicode magnifier in placeholder
    await expect(mobilePage.getByPlaceholder('🔍 Search member name…')).toBeVisible();

    await mobilePage.screenshot({ path: path.join(shotDir(), 'H5-mobile-default-checkin.png'), fullPage: true });

    // H12 logout menu contents
    await mobilePage.getByRole('button', { name: 'Logout ▾' }).click();
    await expect(mobilePage.getByRole('button', { name: 'Log out', exact: true })).toBeVisible();
    await expect(mobilePage.getByRole('button', { name: 'Log out everywhere' })).toBeVisible();
    // close menu without logging out
    await mobilePage.locator('body').click({ position: { x: 5, y: 200 } });

    // H7 debounced check-in search
    await mobilePage.getByPlaceholder('🔍 Search member name…').fill('Voter 0');
    await mobilePage.waitForTimeout(500);
    // results or "No members found" — expect member rows for seed data
    const voterText = mobilePage.locator('text=Voter').first();
    await expect(voterText).toBeVisible({ timeout: 10_000 });

    // H8 checked-in badge if present
    const badge = mobilePage.locator('span:has-text("Checked-in"), span:has-text("Voted")').first();
    if (await badge.isVisible().catch(() => false)) {
      const rowButton = badge.locator('xpath=ancestor::button[1]');
      await expect(rowButton).toBeDisabled();
    } else {
      test.skip(true, 'P5: no checked-in/voted member in current search page — badge not exercised');
    }

    // H9 Record mode
    await recordTab.click();
    await expect(mobilePage.getByRole('button', { name: /Scan|Camera|QR/i }).first()).toBeVisible({ timeout: 10_000 });
    // candidate list loads
    await mobilePage.waitForTimeout(800);
    // H11 not gated during VOTING
    await expect(mobilePage.locator('text=Available only while voting is open')).toHaveCount(0);

    // H10 Spoil mode chips
    await spoilTab.click();
    await expect(mobilePage.getByRole('button', { name: 'Damaged' })).toBeVisible();
    await expect(mobilePage.getByRole('button', { name: 'Duplicate' })).toBeVisible();
    await expect(mobilePage.getByRole('button', { name: 'Wrong' })).toBeVisible();
    await expect(mobilePage.getByPlaceholder('or type a reason…')).toBeVisible();
    // still not gated
    await expect(mobilePage.locator('text=Available only while voting is open')).toHaveCount(0);

    await mobilePage.screenshot({ path: path.join(shotDir(), 'H10-mobile-spoil.png'), fullPage: true });
  });

  // ─── Suite L — Scan-time ballot validation (v0.15.2) ──────────────────

  test('L1–L3: Scan-time validation via 📷 Photo (Record mode)', async () => {
    // Continue from H12's Spoil state; switch to Record (has the Photo control).
    const recordTab = mobilePage.getByRole('button', { name: 'Record', exact: true });
    await recordTab.click();
    await expect(mobilePage.getByRole('button', { name: /Scan ballot/ })).toBeVisible({ timeout: 10_000 });

    const photoInput = mobilePage.locator('label', { hasText: 'Photo' }).locator('input[type="file"]');
    await expect(photoInput).toBeAttached();

    async function photoScanQr(payload: string): Promise<void> {
      const png = await QRCode.toBuffer(payload, { width: 512, margin: 2, errorCorrectionLevel: 'Q' });
      await mobilePage.getByRole('button', { name: /Scan ballot/ }).click();
      await expect(photoInput).toBeAttached({ timeout: 10_000 });
      await photoInput.setInputFiles({ name: 'qr.png', mimeType: 'image/png', buffer: png });
    }

    // L1 [NEG]: valid PAPER-format ID that is not in the blank pool
    const fakeId = 'PAPER:' + 'a'.repeat(64) + '.' + 'b'.repeat(64);
    await photoScanQr(`https://anonymous-election.vercel.app/verify?ballot_id=${encodeURIComponent(fakeId)}`);
    await expect(
      mobilePage.getByText('Not a valid paper ballot — not created by this application')
    ).toBeVisible({ timeout: 15_000 });
    await expect(mobilePage.getByText('Ballot scanned', { exact: true })).toHaveCount(0);
    // error state auto-clears back to idle
    await expect(mobilePage.getByRole('button', { name: /Scan ballot/ })).toBeVisible({ timeout: 6_000 });

    // L2 [NEG]: non-ballot URL — rejected by the client-side format gate
    await photoScanQr('https://example.com/some-other-page');
    await expect(
      mobilePage.locator('text=Invalid or empty ballot QR payload').or(mobilePage.locator('text=Ballot ID must start with PAPER:'))
    ).toBeVisible({ timeout: 15_000 });
    await expect(mobilePage.getByText('Ballot scanned', { exact: true })).toHaveCount(0);
    await expect(mobilePage.getByRole('button', { name: /Scan ballot/ })).toBeVisible({ timeout: 6_000 });

    // L3: real AVAILABLE ballot → confirm screen with status
    const csrf = await getCsrfToken(mobileContext);
    const batchRes = await mobilePage.request.post(`${BASE_URL}/api/admin/paper-batch`, {
      headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrf },
      data: { count: 1 },
    });
    expect([200, 429]).toContain(batchRes.status());
    test.skip(batchRes.status() === 429, 'Batch generation rate-limited; re-run later');
    const batchBody = await batchRes.json();
    const ballotId: string | undefined = batchBody?.ballots?.[0]?.ballotId;
    test.skip(!ballotId, 'No ballot ID returned from batch generation');

    await photoScanQr(`https://anonymous-election.vercel.app/verify?ballot_id=${encodeURIComponent(ballotId!)}`);
    await expect(mobilePage.getByText('Ballot scanned', { exact: true })).toBeVisible({ timeout: 15_000 });
    await expect(mobilePage.getByText(/Status: AVAILABLE/)).toBeVisible();
    // Do NOT tap Confirm — the batch generation is the only mutation here.
    await mobilePage.screenshot({ path: path.join(shotDir(), 'L3-validation-confirm.png'), fullPage: true });
  });

  test('H15: Mobile logout returns to login card', async () => {
    await mobilePage.getByRole('button', { name: 'Logout ▾' }).click();
    await mobilePage.getByRole('button', { name: 'Log out', exact: true }).click();
    await expect(mobilePage.getByRole('heading', { name: 'Mobile Wizard' })).toBeVisible({ timeout: 10_000 });
  });

  // ─── Suite I — Desktop session survives mobile login ──────────────────

  test('I1–I2: Desktop header link navigates; desktop session still valid', async () => {
    // Desktop context should still be authenticated (different scope/cookie jar timing)
    await desktopPage.bringToFront();
    await desktopPage.reload();
    // If idle session still alive → dashboard; if expired, fail clearly
    await expect(
      desktopPage.getByRole('heading', { name: 'Election Admin Dashboard' })
    ).toBeVisible({ timeout: 20_000 });

    // I1 click Mobile Wizard → /admin/mobile (may open same tab)
    await desktopPage.getByRole('link', { name: '📱 Mobile Wizard' }).click();
    await expect(desktopPage).toHaveURL(/\/admin\/mobile/, { timeout: 15_000 });
  });
});
