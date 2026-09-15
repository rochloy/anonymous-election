import { test, expect } from '@playwright/test';

const BASE_URL = 'http://localhost:3000';
const ADMIN_SECRET = process.env.ADMIN_SECRET || 'test-secret';

test.describe('Wave 6 token dispatch select-all with email only', () => {
  test.describe.configure({ mode: 'serial' });

  test('Select All includes only members with email and dispatch payload excludes email-less members', async ({ page }) => {
    const membersFixture = [
      {
        id: 'm-with-1',
        member_code: 'MC001',
        full_name: 'Member With Email One',
        email: 'one@example.com',
        phone: null,
        is_active: true,
        votingStatus: 'ELIGIBLE',
      },
      {
        id: 'm-with-2',
        member_code: 'MC002',
        full_name: 'Member With Email Two',
        email: 'two@example.com',
        phone: null,
        is_active: true,
        votingStatus: 'ELIGIBLE',
      },
      {
        id: 'm-with-3',
        member_code: 'MC003',
        full_name: 'Member With Email Three',
        email: 'three@example.com',
        phone: null,
        is_active: true,
        votingStatus: 'ELIGIBLE',
      },
      {
        id: 'm-no-1',
        member_code: 'MC004',
        full_name: 'Member No Email Empty',
        email: '',
        phone: null,
        is_active: true,
        votingStatus: 'ELIGIBLE',
      },
      {
        id: 'm-no-2',
        member_code: 'MC005',
        full_name: 'Member No Email Null',
        email: null,
        phone: null,
        is_active: true,
        votingStatus: 'ELIGIBLE',
      },
    ];

    let capturedDispatchBody: { memberIds: string[]; type: 'VOTING' | 'NOMINATION' } | null = null;

    await page.route('**/api/**', async route => {
      const request = route.request();
      const url = new URL(request.url());
      const { pathname, searchParams } = url;
      const method = request.method();

      if (pathname === '/api/admin/me' && method === 'GET') {
        await route.fulfill({ status: 401, contentType: 'application/json', body: JSON.stringify({ error: 'Unauthorized', reason: 'unauthorized' }) });
        return;
      }

      if (pathname === '/api/admin/login' && method === 'POST') {
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ success: true, csrfToken: 'csrf-test-token', expiresAt: new Date(Date.now() + 10 * 60 * 1000).toISOString() }),
          headers: {
            'set-cookie': 'admin_session=test-session; Path=/; HttpOnly; SameSite=Lax',
          },
        });
        return;
      }

      if (pathname === '/api/admin/stats' && method === 'GET') {
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ totalMembers: membersFixture.length, currentPhase: 'NOMINATION_CLOSED' }),
        });
        return;
      }

      if (pathname === '/api/admin/phase' && method === 'GET') {
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            current_phase: 'NOMINATION_CLOSED',
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
          body: JSON.stringify({ votingTokenTtlHours: 72, allowWriteIns: true, maxNomineesPerMember: 1 }),
        });
        return;
      }

      if (pathname === '/api/admin/members-manage' && method === 'GET' && searchParams.get('limit') === '500') {
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ members: membersFixture }),
        });
        return;
      }

      if (pathname === '/api/candidates' && method === 'GET') {
        await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([]) });
        return;
      }

      if (pathname === '/api/admin/tokens-dispatch' && method === 'POST') {
        capturedDispatchBody = JSON.parse(request.postData() || '{}') as { memberIds: string[]; type: 'VOTING' | 'NOMINATION' };
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ total: capturedDispatchBody.memberIds.length, sent: capturedDispatchBody.memberIds.length, failed: 0, errors: [] }),
        });
        return;
      }

      await route.fulfill({ status: 500, contentType: 'application/json', body: JSON.stringify({ error: `Unexpected mocked route: ${method} ${pathname}` }) });
    });

    await page.goto(`${BASE_URL}/admin/dashboard`);
    await page.locator('input[name="secret"]').fill(ADMIN_SECRET);
    await page.getByRole('button', { name: 'Access Dashboard' }).click();
    await expect(page.getByRole('heading', { name: 'Election Admin Dashboard' })).toBeVisible();

    await page.getByRole('button', { name: 'Token Dispatch' }).click();
    await expect(page.getByText('Select members and token type, then click Dispatch. Tokens are sent via email as magic links.')).toBeVisible();

    // 1) live count label
    await expect(page.getByText('3 selectable / 2 without email')).toBeVisible();

    // 2) email-less rows are disabled + tagged
    const noEmailEmptyRow = page.locator('li', { hasText: 'Member No Email Empty' });
    const noEmailNullRow = page.locator('li', { hasText: 'Member No Email Null' });
    await expect(noEmailEmptyRow.getByRole('checkbox')).toBeDisabled();
    await expect(noEmailNullRow.getByRole('checkbox')).toBeDisabled();
    await expect(noEmailEmptyRow.locator('span', { hasText: /^NO EMAIL$/ })).toBeVisible();
    await expect(noEmailNullRow.locator('span', { hasText: /^NO EMAIL$/ })).toBeVisible();

    // 3) Select All only checks members with email
    await page.getByRole('button', { name: 'Select All' }).click();
    await expect(page.locator('li', { hasText: 'Member With Email One' }).getByRole('checkbox')).toBeChecked();
    await expect(page.locator('li', { hasText: 'Member With Email Two' }).getByRole('checkbox')).toBeChecked();
    await expect(page.locator('li', { hasText: 'Member With Email Three' }).getByRole('checkbox')).toBeChecked();
    await expect(noEmailEmptyRow.getByRole('checkbox')).not.toBeChecked();
    await expect(noEmailNullRow.getByRole('checkbox')).not.toBeChecked();

    // 4) dispatch payload includes exactly selectable IDs
    await page.getByRole('button', { name: 'Dispatch Tokens' }).click();
    await expect.poll(() => capturedDispatchBody).not.toBeNull();
    const dispatchBody = capturedDispatchBody as { memberIds: string[]; type: 'VOTING' | 'NOMINATION' } | null;
    if (!dispatchBody) {
      throw new Error('Dispatch body was not captured');
    }
    expect(dispatchBody.type).toBe('VOTING');
    expect(dispatchBody.memberIds).toEqual(['m-with-1', 'm-with-2', 'm-with-3']);
    expect(dispatchBody.memberIds).not.toContain('m-no-1');
    expect(dispatchBody.memberIds).not.toContain('m-no-2');
  });
});
