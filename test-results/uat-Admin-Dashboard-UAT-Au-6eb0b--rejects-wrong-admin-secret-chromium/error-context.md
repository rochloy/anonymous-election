# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: uat.spec.ts >> Admin Dashboard UAT >> Authentication >> rejects wrong admin secret
- Location: tests/uat.spec.ts:39:5

# Error details

```
Error: expect(locator).toBeVisible() failed

Locator: locator('h1:has-text("Election Admin Dashboard")')
Expected: visible
Timeout: 15000ms
Error: element(s) not found

Call log:
  - Expect "toBeVisible" with timeout 15000ms
  - waiting for locator('h1:has-text("Election Admin Dashboard")')

```

```yaml
- heading "Admin Dashboard" [level=1]
- paragraph: Enter Admin Secret to access management functions.
- text: Failed to create session Admin Secret
- textbox "Enter admin secret...": b4fca292a5232aa323bddbf2603dee6bf2775b98d7cbd6d81d40aa6eaeaf13cb
- button "Access Dashboard"
- alert
```

# Test source

```ts
  1   | import { test, expect } from '@playwright/test';
  2   | 
  3   | const BASE_URL = 'http://localhost:3000';
  4   | const ADMIN_SECRET = process.env.ADMIN_SECRET || 'test-secret';
  5   | 
  6   | // Helper to wait for dashboard to load after login
  7   | async function waitForDashboard(page: any) {
  8   |   await expect(page.locator('h1:has-text("Election Admin Dashboard")')).toBeVisible({ timeout: 15000 });
  9   | }
  10  | 
  11  | // Helper to login and return authenticated page
  12  | async function loginAndGetPage(page: any) {
  13  |   await page.goto(`${BASE_URL}/admin/dashboard`);
  14  |   await page.fill('input[type="password"]', ADMIN_SECRET);
  15  |   await page.click('button:has-text("Access Dashboard")');
> 16  |   await expect(page.locator('h1:has-text("Election Admin Dashboard")')).toBeVisible({ timeout: 15000 });
      |                                                                         ^ Error: expect(locator).toBeVisible() failed
  17  |   // Small delay to ensure auth is fully established
  18  |   await page.waitForTimeout(500);
  19  | }
  20  | 
  21  | test.describe('Admin Dashboard UAT', () => {
  22  |   let authenticatedPage: any;
  23  | 
  24  |   test.beforeAll(async ({ browser }) => {
  25  |     // Create a single authenticated page for all tests
  26  |     const context = await browser.newContext();
  27  |     const page = await context.newPage();
  28  |     await loginAndGetPage(page);
  29  |     authenticatedPage = page;
  30  |   });
  31  | 
  32  |   test.afterAll(async () => {
  33  |     if (authenticatedPage) {
  34  |       await authenticatedPage.close();
  35  |     }
  36  |   });
  37  | 
  38  |   test.describe('Authentication', () => {
  39  |     test('rejects wrong admin secret', async ({ page }) => {
  40  |       await page.goto(`${BASE_URL}/admin/dashboard`);
  41  |       await page.fill('input[type="password"]', 'wrong-secret');
  42  |       await page.click('button:has-text("Access Dashboard")');
  43  |       // Check for error message - could be toast or inline
  44  |       await expect(page.locator('text=Invalid admin secret').or(page.locator('text=Unauthorized'))).toBeVisible({ timeout: 5000 });
  45  |       await expect(page.locator('input[type="password"]')).toBeVisible();
  46  |     });
  47  | 
  48  |     test('accepts correct admin secret', async ({ page }) => {
  49  |       await page.goto(`${BASE_URL}/admin/dashboard`);
  50  |       await page.fill('input[type="password"]', ADMIN_SECRET);
  51  |       await page.click('button:has-text("Access Dashboard")');
  52  |       // Wait for login to complete and dashboard to load
  53  |       await expect(page.locator('h1:has-text("Election Admin Dashboard")')).toBeVisible({ timeout: 15000 });
  54  |     });
  55  | 
  56  |     test('clears invalid stored secret on mount', async ({ page }) => {
  57  |       await page.goto(`${BASE_URL}/admin/dashboard`);
  58  |       await page.evaluate(() => localStorage.setItem('admin_secret', 'invalid-secret'));
  59  |       await page.reload();
  60  |       await expect(page.locator('input[type="password"]')).toBeVisible({ timeout: 5000 });
  61  |     });
  62  |   });
  63  | 
  64  |   test.describe('Tab Navigation', () => {
  65  |     test.beforeEach(async () => {
  66  |       // Use the shared authenticated page
  67  |       await authenticatedPage.click('button:has-text("Search & Issue Paper Ballot")');
  68  |       await expect(authenticatedPage.locator('button:has-text("Search & Issue Paper Ballot")')).toHaveClass(/border-blue-600/);
  69  |     });
  70  | 
  71  |     const tabs = [
  72  |       { name: 'Search & Issue Paper Ballot', tabId: 'members' },
  73  |       { name: 'Preprinted Ballots', tabId: 'inventory' },
  74  |       { name: 'Record / Spoil Vote', tabId: 'record' },
  75  |       { name: 'Election Settings', tabId: 'phase' },
  76  |       { name: 'Candidates', tabId: 'candidates' },
  77  |       { name: 'Members Management', tabId: 'members-manage' },
  78  |       { name: 'Token Dispatch', tabId: 'tokens-dispatch' },
  79  |     ];
  80  | 
  81  |     for (const tab of tabs) {
  82  |       test(`navigates to ${tab.name} tab`, async () => {
  83  |         await authenticatedPage.click(`button:has-text("${tab.name}")`);
  84  |         // Verify tab is active by checking the active tab button style
  85  |         await expect(authenticatedPage.locator(`button:has-text("${tab.name}")`)).toHaveClass(/border-blue-600/);
  86  |         // Small delay to avoid rate limiting
  87  |         await authenticatedPage.waitForTimeout(200);
  88  |       });
  89  |     }
  90  |   });
  91  | 
  92  |   test.describe('Phase Change - Three-Fold Confirmation', () => {
  93  |     test.beforeEach(async () => {
  94  |       await authenticatedPage.reload();
  95  |       await waitForDashboard(authenticatedPage);
  96  |       await authenticatedPage.click('button:has-text("Election Settings")');
  97  |       await authenticatedPage.waitForTimeout(500);
  98  |     });
  99  | 
  100 |     test('shows advance phase buttons when not in terminal state', async () => {
  101 |       await expect(authenticatedPage.locator('button:has-text("Advance to NOMINATION")')).toBeVisible({ timeout: 5000 });
  102 |     });
  103 | 
  104 |     test('requests phase change and shows email sent message', async () => {
  105 |       await authenticatedPage.click('button:has-text("Advance to NOMINATION")');
  106 |       // Wait for the toast to appear
  107 |       await expect(authenticatedPage.locator('text=/Confirmation email sent/i')).toBeVisible({ timeout: 15000 });
  108 |     });
  109 | 
  110 |     test('requires email confirmation before proceeding', async () => {
  111 |       await authenticatedPage.click('button:has-text("Advance to NOMINATION")');
  112 |       await expect(authenticatedPage.locator('text=/Confirmation email sent/i')).toBeVisible({ timeout: 15000 });
  113 |       // Typing CONFIRM without clicking email link first should fail
  114 |       await authenticatedPage.fill('input[placeholder="CONFIRM"]', 'CONFIRM');
  115 |       await authenticatedPage.click('button:has-text("Confirm Phase Change")');
  116 |       await expect(authenticatedPage.locator('text=/Email confirmation required/i')).toBeVisible({ timeout: 10000 });
```