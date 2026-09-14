import { test, expect, type Page } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import crypto from 'crypto';

const BASE_URL = 'http://localhost:3000';
const ADMIN_SECRET = process.env.ADMIN_SECRET || 'test-secret';
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

const supabase =
  SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY
    ? createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
        auth: { persistSession: false, autoRefreshToken: false },
      })
    : null;

function requireSupabaseClient() {
  if (!supabase) {
    throw new Error(
      'Missing NEXT_PUBLIC_SUPABASE_URL and/or SUPABASE_SERVICE_ROLE_KEY for Wave 2 session tests'
    );
  }
  return supabase;
}

function tokenHashFromSessionToken(sessionToken: string): string {
  return crypto.createHash('sha256').update(sessionToken).digest('hex');
}

async function login(page: Page) {
  await page.goto(`${BASE_URL}/admin/dashboard`);
  await page.locator('input[name="secret"]').fill(ADMIN_SECRET);
  await page.getByRole('button', { name: 'Access Dashboard' }).click();
  await expect(page.getByRole('heading', { name: 'Election Admin Dashboard' })).toBeVisible({ timeout: 30_000 });
}

async function getAdminSessionToken(page: Page): Promise<string> {
  const cookies = await page.context().cookies();
  const sessionCookie = cookies.find(cookie => cookie.name === 'admin_session');
  if (!sessionCookie?.value) {
    throw new Error('admin_session cookie not found');
  }
  return sessionCookie.value;
}

async function backdateAbsoluteExpiryByTokenHash(tokenHash: string) {
  const db = requireSupabaseClient();
  const now = Date.now();
  const createdAt = new Date(now - 5 * 60 * 60 * 1000).toISOString(); // >4h ago
  const expiresAt = new Date(now + 5 * 60 * 1000).toISOString();
  const { error } = await db
    .from('admin_sessions')
    .update({ created_at: createdAt, expires_at: expiresAt })
    .eq('token_hash', tokenHash);
  if (error) {
    throw new Error(`Failed to backdate absolute expiry: ${error.message}`);
  }
}

async function backdateIdleExpiryByTokenHash(tokenHash: string) {
  const db = requireSupabaseClient();
  const now = Date.now();
  const createdAt = new Date(now - 10 * 60 * 1000).toISOString();
  const expiresAt = new Date(now - 60 * 1000).toISOString(); // already idle-expired
  const { error } = await db
    .from('admin_sessions')
    .update({ created_at: createdAt, expires_at: expiresAt })
    .eq('token_hash', tokenHash);
  if (error) {
    throw new Error(`Failed to backdate idle expiry: ${error.message}`);
  }
}

test.describe.serial('Wave 2 admin session security', () => {
  test('Scenario 1: mutation 401 opens re-auth modal and preserves unsaved state', async ({ page }) => {
    await login(page);

    await page.getByRole('button', { name: 'Preprinted Ballots' }).click();

    const reasonInput = page.getByPlaceholder('e.g. End of election');
    await reasonInput.fill('keep this unsaved reason');

    const sessionToken = await getAdminSessionToken(page);
    await backdateAbsoluteExpiryByTokenHash(tokenHashFromSessionToken(sessionToken));

    page.once('dialog', dialog => dialog.accept());
    await page.getByRole('button', { name: 'Void Unused Ballots' }).click();

    await expect(page.getByRole('heading', { name: 'Sign in again to continue' })).toBeVisible();
    await expect(page.getByText("You've reached the 4-hour session limit.")).toBeVisible();
    await expect(reasonInput).toHaveValue('keep this unsaved reason');

    await page.locator('#reauth-secret').fill(ADMIN_SECRET);
    await page.getByRole('button', { name: 'Sign in' }).click();

    await expect(page.getByRole('heading', { name: 'Sign in again to continue' })).toBeHidden();
    await expect(reasonInput).toHaveValue('keep this unsaved reason');
  });

  test('Scenario 2: ambient idle 401 with clean state drops to full login', async ({ page }) => {
    test.setTimeout(150_000);

    await login(page);

    const sessionToken = await getAdminSessionToken(page);
    await backdateIdleExpiryByTokenHash(tokenHashFromSessionToken(sessionToken));

    await expect(page.getByRole('heading', { name: 'Admin Dashboard' })).toBeVisible({ timeout: 90_000 });
    await expect(page.getByRole('button', { name: 'Access Dashboard' })).toBeVisible({ timeout: 90_000 });
    await expect(page.getByRole('heading', { name: 'Sign in again to continue' })).toBeHidden();
    await expect(page.getByText('You were signed out for inactivity. Log in again.')).toBeVisible();
  });
});
