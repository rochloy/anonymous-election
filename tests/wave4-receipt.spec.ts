import { test, expect } from '@playwright/test';

const BASE_URL = 'http://localhost:3000';

function streamToString(stream: NodeJS.ReadableStream): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    stream.on('data', chunk => chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)));
    stream.on('error', reject);
    stream.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
  });
}

test.describe('Wave 4 vote-success receipt actions', () => {
  test.describe.configure({ mode: 'serial' });

  test('success receipt buttons work with fully mocked vote flow', async ({ page }) => {
    const context = page.context();
    await context.grantPermissions(['clipboard-read', 'clipboard-write']);

    await page.addInitScript(() => {
      (window as typeof window & { __printed: boolean }).__printed = false;
      window.print = () => {
        (window as typeof window & { __printed: boolean }).__printed = true;
      };
    });

    await page.route('**/api/auth/verify-token', async route => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ valid: true }),
      });
    });

    await page.route('**/api/candidates', async route => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify([
          { id: 'cand-1', full_name: 'Test Candidate A', statement: 'x', photo_url: null },
          { id: 'cand-2', full_name: 'Test Candidate B', statement: 'y', photo_url: null },
        ]),
      });
    });

    await page.route('**/api/vote', async route => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ success: true, receiptCode: 'VC-abcdef0123' }),
      });
    });

    await page.goto(`${BASE_URL}/vote/test-token-xyz`);
    await page.getByRole('button', { name: 'Test Candidate A' }).click();
    await page.getByRole('button', { name: 'Confirm vote' }).click();

    const successScreen = page.locator('div', {
      has: page.getByRole('heading', { name: 'Vote cast' }),
    });
    await expect(page.getByRole('heading', { name: 'Vote cast' })).toBeVisible();

    // 1) Receipt code visible
    await expect(successScreen.locator('code')).toHaveText('VC-abcdef0123');

    // 2) Copy button + clipboard
    await page.getByRole('button', { name: 'Copy' }).click();
    await expect(page.getByRole('button', { name: 'Copied!' })).toBeVisible();
    await expect
      .poll(async () => page.evaluate(() => navigator.clipboard.readText()))
      .toBe('VC-abcdef0123');

    // 3) Download button + filename + file contents
    const downloadPromise = page.waitForEvent('download');
    await page.getByRole('button', { name: 'Download receipt' }).click();
    const download = await downloadPromise;
    expect(download.suggestedFilename()).toBe('vote-receipt.txt');
    const downloadStream = await download.createReadStream();
    if (!downloadStream) {
      throw new Error('Download stream was not available');
    }
    const downloadText = await streamToString(downloadStream);
    expect(downloadText).toContain('VC-abcdef0123');
    expect(downloadText).toContain('does not reveal who you voted for');

    // 4) Print button invokes window.print stub
    await page.getByRole('button', { name: 'Print receipt' }).click();
    await expect.poll(async () => page.evaluate(() => (window as typeof window & { __printed: boolean }).__printed)).toBe(true);

    // 5) Receipt-freeness copy present
    await expect(successScreen).toContainText('it is not emailed to you');
    await expect(successScreen).toContainText('confirm your vote was recorded');

    // 6) Negative assertions: no candidate identities / ballot payload clues
    await expect(successScreen).not.toContainText('Test Candidate A');
    await expect(successScreen).not.toContainText('Test Candidate B');
    await expect(successScreen).not.toContainText('ballot_id');
    await expect(successScreen).not.toContainText('DIGITAL:');
  });
});
