# User Guide

## Overview

Anonymous Election System is a secure, anonymous digital voting platform with paper ballot support. It provides:

- **Digital voting** via magic-link tokens emailed to members
- **Paper ballot workflow** (Option E: preprinted ballots with QR codes)
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
- Issue paper ballot with QR code for eligible members
- View issued ballot details

### Tab 2: Preprinted Ballots
- **Generate**: Create blank ballot batches (1-1000) with QR codes
- **Assign**: Scan QR code or enter ballot ID + member ID to assign
- **Print**: Print ballot grid for physical distribution
- **Void**: Mark unused ballots as void

### Tab 3: Record / Spoil Vote
- **Record**: Scan ballot QR or enter ballot ID + candidate to record paper vote
- **Spoil**: Mark ballot as spoiled/invalid with reason

### Tab 4: Election Settings
- **Current Phase**: View phase badge + election dates
- **Advance Phase**: 3-level confirmation:
  1. Click "Advance to X" → confirmation email sent
  2. Click email link → auto-confirms
  3. OR return to dashboard, type "CONFIRM" → confirms
- **Election Dates**: Set nomination/voting periods (Save Dates button)
- **Reset Election**: Return to SETUP phase (for testing)

### Tab 5: Candidates
- **Add**: Name, statement, photo URL, active status
- **Edit**: Click Edit on any candidate
- **Toggle Active**: Show/hide from voters
- **Delete**: Remove candidate

### Tab 6: Members Management
- **CSV Import**: Paste CSV with columns: `full_name` (or `name`), `email`, optional `phone`, `member_code`
- **Activate/Deactivate**: Toggle member eligibility
- **Refresh**: Reload member list

### Tab 7: Token Dispatch
- Select members (checkboxes, Select All button)
- Choose token type: VOTING or NOMINATION
- Click "Dispatch Tokens" → emails sent via Resend
- Results show sent/failed counts

### Tab 8: Audit Log
- Filter by: action type, member ID, date range
- Paginated (100 per page)
- Shows: timestamp, action, member, admin, details

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

**Admin Reset**: COMPLETED → SETUP available for testing

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

## Paper Ballot Workflow (Option E)

1. **Generate**: Admin creates blank ballot batch (Tab 2)
2. **Print**: Print QR code grid
3. **Distribute**: Give physical ballots to voters
4. **Assign**: Voter fills ballot → admin scans QR + enters member ID (Tab 2)
5. **Vote**: Voter marks choice → admin scans QR + selects candidate (Tab 3)
6. **Verify**: Voter uses receipt code at `/verify`

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
| `ADMIN_SECRET` | Yes | — | Admin dashboard password |
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