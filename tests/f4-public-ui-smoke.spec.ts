import { test, expect, type Page, type Route } from '@playwright/test';

const BASE_URL = process.env.PLAYWRIGHT_BASE_URL ?? 'http://127.0.0.1:3000';
const target = new URL(BASE_URL);
if (target.protocol !== 'http:' || !['localhost', '127.0.0.1'].includes(target.hostname) ||
    target.username || target.password || target.search || target.hash || target.pathname !== '/') {
  throw new Error('F4 UI smoke requires a localhost HTTP base URL');
}

const SYNTHETIC_VERIFY_RECEIPT = 'VC-aaaaaaaaaa';
const SYNTHETIC_PUBLISHED_RECEIPT = 'PB-abcdef1234';
const SYNTHETIC_PAPER_BALLOT_ID = 'PAPER:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

type ApiHandlerOptions = {
  published: boolean;
};

async function fulfillJson(route: Route, body: unknown): Promise<void> {
  await route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify(body),
  });
}

async function installPublicApiMock(page: Page, options: ApiHandlerOptions): Promise<{ unexpectedApiCalls: string[] }> {
  const unexpectedApiCalls: string[] = [];

  await page.route('**/api/**', async route => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname;
    const method = request.method();

    if (path === '/api/results' && method === 'GET') {
      const receipt = url.searchParams.get('receipt');
      if (receipt) {
        const normalizedReceipt = receipt.trim();
        await fulfillJson(route, {
          published: true,
          phase: 'COMPLETED',
          totalVotes: 3,
          receiptStatus: {
            searchedCode: normalizedReceipt,
            found: normalizedReceipt.toLowerCase() === SYNTHETIC_PUBLISHED_RECEIPT.toLowerCase(),
          },
          results: [
            { id: 'cand-a', full_name: 'Candidate One', votes: 2, percentage: 66.7 },
            { id: 'cand-b', full_name: 'Candidate Two', votes: 1, percentage: 33.3 },
          ],
        });
        return;
      }

      if (options.published) {
        await fulfillJson(route, {
          published: true,
          phase: 'COMPLETED',
          totalVotes: 3,
          receiptStatus: null,
          results: [
            { id: 'cand-a', full_name: 'Candidate One', votes: 2, percentage: 66.7 },
            { id: 'cand-b', full_name: 'Candidate Two', votes: 1, percentage: 33.3 },
          ],
        });
        return;
      }

      await fulfillJson(route, {
        published: false,
        phase: 'VOTING',
      });
      return;
    }

    if (path === '/api/verify' && method === 'GET') {
      const ballotId = url.searchParams.get('ballot_id') ?? '';
      const receiptCode = url.searchParams.get('receipt_code') ?? '';

      if (ballotId === SYNTHETIC_PAPER_BALLOT_ID) {
        await fulfillJson(route, {
          found: true,
          channel: 'PAPER',
          cast_date: '2026-01-01',
        });
        return;
      }

      if (receiptCode === SYNTHETIC_VERIFY_RECEIPT) {
        await fulfillJson(route, {
          found: true,
          channel: 'DIGITAL',
          cast_date: '2026-01-01',
        });
        return;
      }

      if (receiptCode || ballotId) {
        await fulfillJson(route, { found: false });
        return;
      }
    }

    unexpectedApiCalls.push(`${method} ${path}`);
    await route.abort();
  });

  return { unexpectedApiCalls };
}

test.describe('F4 public route cutover smoke', () => {
  test('results route shows unpublished waiting state only', async ({ page }) => {
    const { unexpectedApiCalls } = await installPublicApiMock(page, { published: false });

    await page.goto(`${BASE_URL}/results`);

    await expect(page.getByRole('heading', { name: 'Election Results' })).toBeVisible();
    await expect(page.getByText('Voting is still open (VOTING). Final results will be published after voting closes.')).toBeVisible();
    await expect(page.getByText('Total votes:')).toHaveCount(0);
    await expect(page.getByText(/Receipt .*found/i)).toHaveCount(0);
    await expect(unexpectedApiCalls).toEqual([]);
  });

  test('results route shows published totals and receipt lookup', async ({ page }) => {
    const { unexpectedApiCalls } = await installPublicApiMock(page, { published: true });

    await page.goto(`${BASE_URL}/results`);

    await expect(page.getByText('Total votes:')).toBeVisible();
    await expect(page.getByText('3', { exact: true })).toBeVisible();
    await expect(page.getByText('Candidate One')).toBeVisible();
    await expect(page.getByText('Candidate Two')).toBeVisible();

    await page.getByPlaceholder('Receipt code (e.g. VC-a1b2c3d4)').fill(SYNTHETIC_PUBLISHED_RECEIPT);
    await page.getByRole('button', { name: 'Check' }).click();
    await expect(page.getByText('found ✓')).toBeVisible();

    await expect(unexpectedApiCalls).toEqual([]);
  });

  test('verify route supports receipt lookup and paper ballot query autofill', async ({ page }) => {
    const { unexpectedApiCalls } = await installPublicApiMock(page, { published: true });

    await page.goto(`${BASE_URL}/verify`);

    await page.getByPlaceholder('e.g. VC-a1b2c3d4e5').fill(SYNTHETIC_VERIFY_RECEIPT);
    await page.getByRole('button', { name: 'Confirm My Vote' }).click();
    await expect(page.getByText('✓ Your vote was recorded')).toBeVisible();
    await expect(page.getByText('Digital', { exact: true })).toBeVisible();

    await page.goto(`${BASE_URL}/verify?ballot_id=${encodeURIComponent(SYNTHETIC_PAPER_BALLOT_ID)}`);
    const ballotInput = page.getByPlaceholder('e.g. PAPER:abc123...');
    await expect(ballotInput).toHaveValue(SYNTHETIC_PAPER_BALLOT_ID);

    const receiptInput = page.getByPlaceholder('e.g. VC-a1b2c3d4e5');
    await receiptInput.fill('');
    await page.getByRole('button', { name: 'Confirm My Vote' }).click();
    await expect(page.getByText('✓ Your vote was recorded')).toBeVisible();
    await expect(page.getByText('Paper', { exact: true })).toBeVisible();

    await expect(unexpectedApiCalls).toEqual([]);
  });
});
