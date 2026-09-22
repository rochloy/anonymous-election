# User Guide

## Overview

Anonymous Election System is a secure, anonymous digital voting platform with paper ballot support. It provides:

- **Digital voting** via magic-link tokens emailed to members
- **Paper voting** via identity slips (check-in) + an anonymous preprinted ballot pool with QR codes — the system never links a member to a specific ballot
- **Admin dashboard** for election management
- **Public verification** of votes via receipt codes

---

## Quick Start

### For Administrators

1. **Access Dashboard**: Navigate to `/admin/dashboard`
2. **Enter Admin Secret**: Use the `ADMIN_SECRET` from your environment
3. **Configure Election**:
   - Set election dates (Election Settings tab)
   - Add candidates (Candidates tab)
   - Import members (Members Management tab)
4. **Start Election**: Advance phase from SETUP → NOMINATION → VOTING
5. **Dispatch Tokens**: Send voting tokens via email (Token Dispatch tab)
6. **Monitor**: Use Audit Log tab to track all actions

### For Voters

1. **Receive Token**: Check email for magic link
2. **Vote**: Click link → select candidate → submit
3. **Verify**: Use receipt code at `/verify` to confirm vote was counted

---

## Admin Dashboard Reference

### Tab 1: Search & Issue Paper Ballot
- Search members by name
- **Check-in** (button) for eligible members: creates the identity slip (short code + member name/code — no QR) and consumes the member's voting entitlement for paper voting. Members without a prior entitlement get one created automatically (lazy provisioning).
- View issued slip details

### Tab 2: Preprinted Ballots
- **Generate**: Create the anonymous blank-ballot pool (1-1000) with QR codes — no member identity on these
- **Print**: Print ballot QR grid for physical distribution
- **Void**: Mark unused ballots as void

### Tab 3: Record / Spoil Vote
- **Record**: Scan ballot QR or enter ballot ID + candidate to record paper vote
- **Spoil**: Mark ballot as spoiled/invalid with reason

### Tab 4: Election Settings
- **Current Phase**: View phase badge + election dates
- **Advance Phase**: Three-fold confirmation:
  1. Click "Advance to X" → confirmation email sent to admin
  2. Click email link → auto-confirms (or call verify_token API)
  3. Return to dashboard, type "CONFIRM" → final confirmation dialog → execute
- **Election Dates**: Set nomination/voting periods (Save Dates button)
- **Voting Link Validity**: Set how long emailed voting links stay valid, in hours (1–2160; default 168 = 7 days). Applies to voting links dispatched *after* you save; does not change links already sent.
- **Voter Age Requirement**: When enabled, members must meet the minimum age (as of the voting start date, or the current date if unset) to be eligible. Age is derived at import time; DOB is never stored.
- **Member Roster**: **Allow adding members during voting** (default off, ⚠ not recommended). Only enable to accommodate members physically present during paper voting whose roster entry was incomplete. The setting itself can only be changed during SETUP / NOMINATION / NOMINATION_CLOSED / VOTING; it locks once voting closes.
- **Reset Election**: Return to SETUP phase (three-fold confirmation, for testing). **This only changes the phase — it does NOT erase votes, tokens, members, or nominations.** Clearing data requires a destructive database reseed (see Technical Guide → "Election Lifecycle & Reuse"), which is run from the database, not this dashboard.

### Tab 5: Candidates
- **Add**: Name, statement, photo URL (HTTPS only), active status
- **Edit**: Click Edit on any candidate
- **Toggle Active**: Show/hide from voters
- **Delete**: Remove candidate (only if no votes cast)

### Tab 6: Members Management
- **Add Member**: Fill in Name (**required**); Email, Phone, and Member Code are optional. If you leave Member Code blank the system generates one automatically. A duplicate Member Code, Email, or Phone is rejected with a "member already exists" message. New members are added as active.
- **CSV Import**: Paste CSV with columns: `full_name` (or `name`) **required**; `email`, `phone`, `member_code` optional. Members without email can vote via paper ballots.
  - **First load (empty roster):** rows without a `member_code` are accepted and codes are generated.
  - **Re-import onto an existing roster:** rows are matched on **`member_code`** — any row **without** a `member_code` is **refused** (so you don't create accidental duplicates). Members **dropped** from the new CSV are **not** auto-deactivated — deactivate them by hand. For a full roster replacement, wipe-and-reseed instead (Technical Guide → "Election Lifecycle & Reuse").
- **Activate/Deactivate**: Toggle member eligibility. Deactivating is the correct way to "remove" someone — members are never hard-deleted.
- **Roster lock**: From **VOTING** onward, Activate/Deactivate is locked ("Roster locked — voting has started"). The **Add form** is also locked during VOTING **unless** you enable **Allow adding members during voting** (Election Settings → Member Roster — default off, with a warning; create-only: newly added members are active + voting-eligible immediately). Make all other roster changes during SETUP / NOMINATION / NOMINATION_CLOSED.
- **Refresh**: Reload member list

### Tab 7: Token Dispatch
- Select members (checkboxes, Select All button)
- Choose token type: VOTING (configurable expiry, default 7 days — set in Election Settings → Voting Link Validity) or NOMINATION (24-hour expiry)
- Click "Dispatch Tokens" → emails sent via Resend
- Results show sent/failed counts
- **Void & Reissue** (for "I lost / never got my link"): on an existing **unused** token, click **Void & Reissue**, type a **reason** (required — an empty reason is rejected), and confirm. The old link is permanently **voided** (dead — it can no longer be used to vote, even if someone still has it) and a **fresh link is emailed** to the same member. Each member keeps only **one active token per type**, so the replacement automatically supersedes the old one. If the email send fails you'll see a warning even though the reissue succeeded — just dispatch again. Void & Reissue is only available while the election is in a token-dispatchable phase; outside it the action is refused.

### Tab 8: Audit Log
- Filter by: action type, member ID, date range
- Paginated (100 per page)
- Shows: timestamp, action, member, admin (session ID), details
- **Tamper-evident**: SHA-256 hash chain links each entry to previous

### Tab 9: Voter Eligibility
- Search members and review current eligibility state in one grid
- Per member, view:
  - Eligibility status (eligible / ineligible)
  - Eligibility reason code (for example `ELIGIBLE`, `AGE_UNDER_MIN`, `MANUAL_ADMIN_HOLD`, `UNDETERMINED`)
  - Eligibility source (`SYSTEM_DEFAULT`, `CSV_IMPORT`, `ADMIN_ADJUDICATION`, etc.)
- **SETUP phase only:** Toggle **Eligible** / **Ineligible**, select a reason code, add an adjudication note, then **Save** to apply
- **Non-SETUP phases (NOMINATION, VOTING, etc.):** Read-only mode — toggle buttons and save are disabled, yellow notice banner explains eligibility is locked
- The adjudication write is audited; use notes for traceability of manual decisions

### Tab 10: Reporting (VOTING+ phases only)
- Visible once voting starts; used to monitor election progress
- **Generate/Refresh Report**: on-demand snapshot (nothing auto-loads)
- Summary cards: members checked in (paper), paper ballots recorded, digital votes, total votes — all anonymous aggregates, no member identity
- Per-candidate tally with vote counts and percentages
- **Export Progress CSV**: turnout metrics only (`election-progress-YYYY-MM-DD.csv`)
- **Export Results CSV**: official tally only (`election-results-YYYY-MM-DD.csv`) — **locked until voting has closed** (VOTING_CLOSED/COMPLETED), matching the public results-publishing gate; a report generated during VOTING must be Refreshed after close before this unlocks

### Purge Roster PII (Danger Zone)
- Located in the admin dashboard danger area; both actions require typing **`PURGE`** before execution
- **Stage 1 — Contact PII purge**: after voting closes, clears contact fields (email/phone) from roster records
- **Stage 2 — Identity anonymization**: after the 30-day dispute window, anonymizes identity fields for long-term retention
- Both stages are intentionally gated and irreversible in practice; export any required aggregate reports first

> **Data minimization note:** age eligibility is derived at import time and stored as a boolean (`is_age_eligible`). Date of birth is used transiently for derivation and is **never stored** in the database.

---

## Security Features (v0.2.0+)

### Admin Authentication
- **HttpOnly cookie sessions** (10-minute idle TTL; 4-hour absolute cap for desktop, 12-minute for mobile scope)
  - No admin secret stored in localStorage (prevents XSS theft)
  - Session stored server-side in `admin_sessions` table
  - Auto-logout after 10 minutes of inactivity
  - Re-login in the same browser revokes that browser's previous session; sessions on other devices are unaffected (multiple admins can work concurrently, each with their own session)
- **CSRF Protection** (double-submit cookie)
  - All state-changing actions require CSRF token
  - Automatic in dashboard, manual for API calls

### Rate Limiting
- **Admin APIs**: 120 requests/minute per IP (production)
- **Vote API**: 5 requests/minute per IP
- **Member Search**: 30 requests/minute per IP
- Distributed via Supabase RPC (works in serverless)

### Token Security
- **Voting tokens**: configurable expiry, default 7 days (set in Election Settings → Voting Link Validity, 1–2160h)
- **Nomination tokens**: 24-hour expiry
- **Void & reissue**: a voided token is permanently dead — the database rejects any vote attempted with it, and each member holds only one active token per type. Reissued tokens link back to the token they replaced (audit history is preserved, never deleted).
- **Phase/Reset tokens**: 1-hour expiry, bound to admin session
- **Three-fold confirmation** for phase changes and reset:
  1. Request → email sent
  2. Click email link → token verified
  3. Type CONFIRM/RESET → final dialog → execute

### Audit Logging
- **Admin identity** tracked via session ID
- **Tamper-evident hash chain**: each entry cryptographically linked to previous
- **Filterable** by action, member, date range

### Input Validation
- **Length limits**: candidate name 255, statement 5000, photo URL 2048
- **CSV formula injection protection**: `=`, `+`, `-`, `@` prefixed with `'`
- **Photo URLs**: HTTPS only
- **Email/phone format validation**

### Error Handling
- **Generic errors in production** (no internal details leaked)
- Detailed errors only in development

### Config Validation
- Fails fast in production on missing/invalid env vars
- ADMIN_SECRET must be ≥32 chars, no weak secrets
- APP_BASE_URL must be HTTPS in production

---

## Phase Reference

| Phase | Description | Voting Allowed? | Results Visible? |
|-------|-------------|-----------------|------------------|
| SETUP | Initial config | No | No |
| NOMINATION | Accepting nominations | No | No |
| NOMINATION_CLOSED | Nominations closed | No | No |
| VOTING | **Active voting** | Yes | No (anti-coercion) |
| VOTING_CLOSED | Voting ended | No | Yes |
| COMPLETED | Finalized | No | Yes |

**Transitions**: Sequential only (SETUP → NOMINATION → NOMINATION_CLOSED → VOTING → VOTING_CLOSED → COMPLETED)

**Admin Reset**: COMPLETED → SETUP available for testing (three-fold confirmation)

---

## Election Dates

Configure in Election Settings tab:

| Date | Purpose |
|------|---------|
| Nomination Start | When nominations open |
| Nomination End | When nominations close |
| Voting Start | When voting opens |
| Voting End | When voting closes (vote RPC rejects after this) |

**Note**: Dates are display/informational. They do **not** auto-advance phases. Admin must manually advance phases.

---

## Paper Voting Workflow

1. **Check in**: Admin checks the member in (Tab 1) — identity slip issued, voting entitlement consumed for paper
2. **Hand out**: Give the member their identity slip; the member picks a physical ballot from the anonymous pool (QR code, no member identity)
3. **Verify**: Member can scan the ballot QR with their phone to confirm the ballot is valid
4. **Vote**: Member marks their choice and deposits the ballot
5. **Record**: Admin scans/enters the ballot ID + candidate (Tab 3) — the anonymous vote is recorded; the member's identity is never linked to it
6. **Verify**: Voter uses the receipt code at `/verify`

## Mobile Wizard

A mobile-optimized interface for admins to perform voting operations on a phone or tablet.

### Access
- **From dashboard:** Click "📱 Mobile Wizard" button in the header (opens `/admin/mobile`)
- **From QR code:** Click "📱 Mobile QR" button to display a QR code; scan with phone to open directly
- **Direct URL:** Navigate to `/admin/mobile` on any device

### Features
- **Login:** Same admin secret as dashboard; mobile sessions have a 12-minute absolute timeout (no idle extension)
- **Session countdown:** Shows remaining time; amber pulse warning below 3 minutes
- **Logout:** "This device" (current session) or "Everywhere" (all sessions)
- **Three modes:**
  - **Record:** Scan ballot QR → select candidate → confirm → receipt shown
  - **Spoil:** Scan ballot QR → select reason chip → confirm → ballot voided
  - **Check-in:** Debounced member search → select member → confirm → slip code displayed
- **Phase gating:** Record/Spoil buttons disabled outside VOTING phase; Check-in always available
- **Auto-clear:** Success/error messages clear after 3 seconds

### Checked-in Members
Members who have already been checked in or voted appear in search results with a "Checked-in" or "Voted" badge and are greyed out (select button disabled) to prevent duplicate check-ins.

---

## Public Pages

| Page | URL | Purpose |
|------|-----|---------|
| Home | `/` | Election status, phase badge, dates |
| Vote | `/vote/[token]` | Digital voting (magic link) |
| Verify | `/verify` | Vote verification by receipt code |
| Results | `/results` | Public results (after VOTING_CLOSED) |

---

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `NEXT_PUBLIC_SUPABASE_URL` | Yes | — | Supabase project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Yes | — | Supabase anon key |
| `SUPABASE_SERVICE_ROLE_KEY` | Yes | — | Service role key (server only) |
| `APP_BASE_URL` | Yes | — | Base URL for email links (e.g., `https://election.example.com`) |
| `RESEND_API_KEY` | Yes | — | Resend API key for emails |
| `FROM_EMAIL` | Yes | — | Sender email (e.g., `Elections <noreply@domain.com>`) |
| `ADMIN_SECRET` | Yes | — | Admin dashboard password (≥32 chars in prod) |
| `ADMIN_EMAIL` | No | `FROM_EMAIL` | Recipient for phase confirmation emails |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| "Invalid admin secret" | Wrong `ADMIN_SECRET` | Check `.env.local` |
| Email not sent | Missing Resend config | Set `RESEND_API_KEY`, `FROM_EMAIL` |
| Phase won't advance | Invalid transition | Check phase order; use Reset if stuck |
| Vote rejected | Past `voting_end` | Check election dates; advance phase |
| QR scan fails | Camera permission | Allow camera; use manual entry fallback |
| Build fails | Font fetch error | Retry; transient network issue |
| "Rate limit exceeded" | Too many requests | Wait 60 seconds; check rate limits |
| "CSRF token required" | Missing CSRF header | Include `x-csrf-token` header |
| "Token expired" | Token past expiry | Request new token dispatch |

---

## Common Workflows

### Start New Election
1. Reset to SETUP (if needed)
2. Set election dates
3. Add candidates
4. Import members
5. Advance: SETUP → NOMINATION
6. Advance: NOMINATION → NOMINATION_CLOSED
7. Advance: NOMINATION_CLOSED → VOTING
8. Dispatch voting tokens

### End Election
1. Advance: VOTING → VOTING_CLOSED
2. Advance: VOTING_CLOSED → COMPLETED
3. Results visible at `/results`

### Test Cycle
1. Reset to SETUP
2. Repeat "Start New Election" steps

### Procedure C: Resolve digital reservation to paper (blank surrender)

Use this when a voter is stuck in a live digital **RESERVED** state and must complete voting on paper.

1. **Confirm status first**: in the dashboard, verify the member shows `RESERVED` (digital in progress).
2. **Collect the blank paper slip physically**: poll staff must take back the unused blank ballot/slip before any token action.
3. **Spoil for dispute history only**: record the surrendered blank as `SPOILED` with a reason note.
   - This is an audit/dispute record.
   - It **does not auto-release** the digital token reservation (fail-closed by design).
4. **Re-enable entitlement explicitly**: run token re-enable via `reissue_token` (admin action), then confirm a fresh active voting token exists.
5. **Proceed with paper flow**: continue with normal paper check-in/record steps using the re-enabled entitlement.
6. **Do not bypass with manual DB edits**: if reissue fails, escalate; do not clear reservation fields ad hoc.

### Managing the Roster

Roster edits are allowed during **SETUP, NOMINATION, NOMINATION_CLOSED**. From VOTING onward, Activate/Deactivate is locked; the Add form can be unlocked during VOTING via **Allow adding members during voting** (Election Settings → Member Roster, default off).

| Situation | What to do |
|-----------|-----------|
| A. Initial bulk load | CSV Import onto the empty roster (SETUP). Code-less rows get auto-generated codes. |
| B. Add one new member | Tab 6 → Add Member (allowed in SETUP / NOMINATION / NOMINATION_CLOSED; during VOTING only with the setting enabled). |
| C. Remove a member | Deactivate them (never deleted). Reactivate the same way. |
| D. Brand-new election / full roster swap | Wipe-and-reseed the database, then bulk import (Technical Guide → "Election Lifecycle & Reuse"). Back up first. |
| E. Update an existing roster from CSV | Re-import — every row **must** carry a `member_code`; code-less rows are refused. Dropped members are **not** auto-deactivated (do that manually). |
| F. Activate/Deactivate once VOTING has started | Not allowed — locked until VOTING_CLOSED. |
| G. Add a member during VOTING (late physical registration) | Enable **Allow adding members during voting** (Election Settings → Member Roster), then Tab 6 → Add Member. The new member is active + voting-eligible immediately and can be checked in on paper. Disable the setting afterwards. |


> **Reset ≠ wipe.** "Reset to SETUP" above only changes the phase; test votes, tokens, and members
> remain. To start genuinely clean — before going live, or to reuse the system for a new election —
> the database must be **wiped and reseeded** (Technical Guide → "Election Lifecycle & Reuse"). The
> system holds **one election at a time**: a new election overwrites the previous one, so **back up
> prior results first** if you need to keep them.

---

## Security Best Practices for Admins

1. **Use strong ADMIN_SECRET** (≥32 random characters)
2. **Rotate ADMIN_SECRET** periodically
3. **Monitor Audit Log** for suspicious activity
4. **Use HTTPS only** in production (enforced by config validation)
5. **Don't share admin sessions** — each admin should have own session
6. **Log out** when done (auto-logout after 10 min inactivity)
7. **Verify email links** before clicking (check sender, URL)
8. **Test in staging** before production changes
