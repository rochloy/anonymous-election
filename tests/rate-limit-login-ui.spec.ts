import { test, expect } from '@playwright/test';

const BASE_URL = 'http://localhost:3000';
const RATE_LIMIT_COPY = 'Login temporarily unavailable. Please try again shortly.';

test.describe('Rate-limit fault policy login UX', () => {
  test('desktop initial login shows non-sensitive 503 copy', async ({ page }) => {
    const submittedSecret = 'desktop-initial-secret-123';

    await page.route('**/api/admin/me', async route => {
      await route.fulfill({
        status: 401,
        contentType: 'application/json',
        body: JSON.stringify({ error: 'Unauthorized', reason: 'unauthorized' }),
      });
    });

    await page.route('**/api/admin/login', async route => {
      await route.fulfill({
        status: 503,
        contentType: 'application/json',
        body: JSON.stringify({ error: RATE_LIMIT_COPY }),
      });
    });

    await page.goto(`${BASE_URL}/admin/dashboard`);
    await page.locator('input[name="secret"]').fill(submittedSecret);
    await page.getByRole('button', { name: 'Access Dashboard' }).click();

    await expect(page.getByText(RATE_LIMIT_COPY)).toBeVisible();
    await expect(page.getByText(submittedSecret)).toHaveCount(0);
    await expect(page.getByText(/rate limit exceeded/i)).toHaveCount(0);
  });

  test('desktop reauth modal shows non-sensitive 503 copy', async ({ page }) => {
    const initialSecret = 'desktop-initial-login-secret';
    const reauthSecret = 'desktop-reauth-secret-xyz';
    let loginCallCount = 0;

    await page.route('**/api/**', async route => {
      const request = route.request();
      const url = new URL(request.url());
      const { pathname } = url;
      const method = request.method();

      if (pathname === '/api/admin/me' && method === 'GET') {
        await route.fulfill({
          status: 401,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'Unauthorized', reason: 'unauthorized' }),
        });
        return;
      }

      if (pathname === '/api/admin/login' && method === 'POST') {
        loginCallCount += 1;
        if (loginCallCount === 1) {
          await route.fulfill({
            status: 200,
            contentType: 'application/json',
            body: JSON.stringify({
              success: true,
              csrfToken: 'csrf-test-token',
              expiresAt: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
            }),
            headers: {
              'set-cookie': 'admin_session=test-session; Path=/; HttpOnly; SameSite=Lax',
            },
          });
          return;
        }
        await route.fulfill({
          status: 503,
          contentType: 'application/json',
          body: JSON.stringify({ error: RATE_LIMIT_COPY }),
        });
        return;
      }

      if (pathname === '/api/candidates' && method === 'GET') {
        await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([]) });
        return;
      }

      if (pathname === '/api/admin/stats' && method === 'GET') {
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ totalMembers: 0, currentPhase: 'SETUP' }),
        });
        return;
      }

      if (pathname === '/api/admin/phase' && method === 'GET') {
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            current_phase: 'SETUP',
            allowedNextPhases: [],
            isTerminal: false,
            nomination_start: null,
            nomination_end: null,
            voting_start: null,
            voting_end: null,
            pendingConfirmation: null,
            pendingResetConfirmation: null,
          }),
        });
        return;
      }

      if (pathname === '/api/admin/settings' && method === 'GET') {
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            votingTokenTtlHours: 72,
            allowWriteIns: true,
            maxNomineesPerMember: 1,
            ageRequirementEnabled: false,
            minimumVotingAge: null,
            allowAddingMemberDuringVoting: false,
          }),
        });
        return;
      }

      if (pathname === '/api/admin/members-manage' && method === 'GET') {
        await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ members: [], stats: { total: 0, withEmail: 0, withPhone: 0, withBoth: 0 } }) });
        return;
      }

      if (pathname === '/api/admin/paper-void-unused' && method === 'POST') {
        await route.fulfill({
          status: 401,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'Unauthorized', reason: 'absolute_expired' }),
        });
        return;
      }

      await route.fulfill({ status: 500, contentType: 'application/json', body: JSON.stringify({ error: `Unexpected mocked route: ${method} ${pathname}` }) });
    });

    page.once('dialog', dialog => dialog.accept());

    await page.goto(`${BASE_URL}/admin/dashboard`);
    await page.locator('input[name="secret"]').fill(initialSecret);
    await page.getByRole('button', { name: 'Access Dashboard' }).click();
    await expect(page.getByRole('heading', { name: 'Election Admin Dashboard' })).toBeVisible();

    await page.getByRole('button', { name: 'Preprinted Ballots' }).click();
    await page.getByPlaceholder('e.g. End of election').fill('unsaved reason to trigger reauth');
    await page.getByRole('button', { name: 'Void Unused Ballots' }).click();

    await expect(page.getByRole('heading', { name: 'Sign in again to continue' })).toBeVisible();
    await page.locator('#reauth-secret').fill(reauthSecret);
    await page.getByRole('button', { name: 'Sign in' }).click();

    await expect(page.getByText(RATE_LIMIT_COPY)).toBeVisible();
    await expect(page.getByText(reauthSecret)).toHaveCount(0);
    await expect(page.getByText(/rate limit exceeded/i)).toHaveCount(0);
  });

  test('mobile wizard login shows non-sensitive 503 copy', async ({ page }) => {
    const submittedSecret = 'mobile-login-secret-456';

    await page.route('**/api/admin/login', async route => {
      await route.fulfill({
        status: 503,
        contentType: 'application/json',
        body: JSON.stringify({ error: RATE_LIMIT_COPY }),
      });
    });

    await page.goto(`${BASE_URL}/admin/mobile`);
    await page.getByPlaceholder('Admin secret').fill(submittedSecret);
    await page.getByRole('button', { name: 'Log in' }).click();

    await expect(page.getByText(RATE_LIMIT_COPY)).toBeVisible();
    await expect(page.getByText(submittedSecret)).toHaveCount(0);
    await expect(page.getByText(/rate limit exceeded/i)).toHaveCount(0);
  });
});
