# Manual UAT Testing Guide — Anonymous Election System

**Version:** 1.0  
**Date:** 2026-08-19  
**Branch:** `agent/security-hardening-2026`  
**Environment:** Production (https://anonymous-election.vercel.app) or Local (http://localhost:3000)

---

## Overview

This guide covers manual User Acceptance Testing for both **voters (users)** and **election administrators**. It validates the complete election workflow from nomination through voting to results, plus all admin dashboard functionality.

---

## Prerequisites

### Environment Setup
- [ ] Application deployed and accessible
- [ ] Supabase database with all 5 migrations applied
- [ ] Resend email service configured (for admin notifications)
- [ ] Admin secret configured in environment (`ADMIN_SECRET`)
- [ ] Test admin email configured (`ADMIN_EMAIL` or `FROM_EMAIL`)

### Test Data
- [ ] Election in `SETUP` phase initially
- [ ] At least 3 candidates created
- [ ] At least 5 test members (mix of with/without email)
- [ ] Paper ballot members without email for paper voting tests

---

## Part 1: Voter (User) Testing

### 1.1 Home Page
| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | Navigate to `/` | Page loads with election info, phase status, navigation links |
| 2 | Verify phase indicator | Shows current phase (SETUP/NOMINATION/VOTING/etc.) |
| 3 | Click "Verify Vote" link | Navigates to `/verify` |
| 4 | Click "Results" link | Navigates to `/results` |

### 1.2 Vote Verification Page (`/verify`)
| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | Visit `/verify` without params | Shows ballot ID input field |
| 2 | Enter invalid ballot ID | Shows "Ballot not found" error |
| 3 | Enter valid ballot ID (from test vote) | Shows vote details: candidate, timestamp, receipt code |
| 4 | Test URL param auto-fill: `/verify?ballot_id=<id>` | Auto-fills and shows verification |

### 1.3 Digital Voting Flow (`/vote/[token]`)
| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | Click voting token link (from email) | Opens voting page with candidate list |
| 2 | Verify token validation | Shows "Valid token" status, candidate list |
| 3 | Select a candidate | Radio button selects, vote button enables |
| 4 | Submit vote | Shows success message with receipt code |
| 5 | Try to vote again with same token | Shows "Already voted" error |
| 6 | Try expired token | Shows "Token expired" error |
| 7 | Try invalid token | Shows "Invalid token" error |

### 1.4 Paper Ballot Voting
| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | Admin issues paper ballot to member | Member receives ballot with QR code |
| 2 | Scan QR code with phone camera | Opens `/verify?ballot_id=...` |
| 3 | Verify page shows ballot details | Shows ballot ID, status (ISSUED/VOTED) |
| 4 | Admin records paper vote | Vote recorded, status changes to VOTED |
| 5 | Re-scan QR code | Shows voted status with candidate |

### 1.5 Results Page (`/results`)
| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | Visit `/results` during voting | Shows "Results not yet available" or partial counts |
| 2 | Visit after phase = COMPLETED | Shows full results table with vote counts |
| 3 | Verify totals match cast votes | Counts match database |

---

## Part 2: Admin Dashboard Testing

### Access & Authentication
| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | Navigate to `/admin/dashboard` | Shows login form |
| 2 | Enter wrong secret | Shows "Invalid admin secret" error, stays on login |
| 3 | Enter correct secret | Logs in, shows dashboard with 8 tabs |
| 4 | Refresh page | Stays logged in (cookie session) |
| 5 | Wait 15 minutes inactive | Auto-logs out, redirects to login |
| 6 | Click "Logout" button | Logs out, redirects to login |
| 6 | Try accessing `/admin/dashboard` directly after logout | Redirects to login |

### 2.1 Tab: Search & Issue Paper Ballot
| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | Click "Search & Issue Paper Ballot" tab | Shows search input, member list |
| 2 | Search by name (min 2 chars) | Shows matching active members |
| 3 | Search non-existent name | Shows empty state |
| 4 | Click "Issue Paper Ballot" for member | Creates ballot, shows QR code modal |
| 5 | Download/print QR code | QR code downloads as PNG |
| 6 | Verify ballot in "Preprinted Ballots" tab | New ballot appears in list |
| 7 | Try issuing second ballot to same member | Shows error "Already has ballot" |

### 2.2 Tab: Preprinted Ballots
| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | Click "Preprinted Ballots" tab | Lists all issued paper ballots |
| 2 | Verify columns: Ballot ID, Member, Status, Issued At, Voted At | All data visible |
| 3 | Filter by status (ISSUED/VOTED/SPOILED) | Filters correctly |
| 4 | Click "Spoil" on issued ballot | Status changes to SPOILED, audit log entry |
| 5 | Try to spoil already voted ballot | Shows error |

### 2.3 Tab: Record / Spoil Vote
| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | Click "Record / Spoil Vote" tab | Shows member search + vote recording form |
| 2 | Search member, select candidate, click "Record Vote" | Vote recorded, audit log entry |
| 3 | Try recording duplicate vote for same member | Shows error "Already voted" |
| 4 | Click "Spoil Vote" on recorded vote | Vote spoiled, status updated |
| 5 | Verify audit log entries | Both record and spoil logged |

### 2.4 Tab: Election Settings (Phase Control + Dates)

#### Phase Control
| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | Click "Election Settings" tab | Shows current phase, advance buttons |
| 2 | Click "Advance to NOMINATION" | Shows "Confirmation email sent" toast |
| 3 | Check admin email | Receives email with confirmation link |
| 4 | Click email link (or call verify_token API) | UI shows "CONFIRM" input field |
| 5 | Type "CONFIRM" in input | "Confirm Phase Change" button enables |
| 6 | Click "Confirm Phase Change" | Shows final confirmation dialog |
| 7 | Click "Execute Phase Change" in dialog | Phase advances, toast shows success |
| 8 | Verify new phase in dashboard | Phase updated, next advance button shown |
| 9 | Try to advance from COMPLETED | No advance button (terminal state) |

#### Three-Fold Confirmation Negative Tests
| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | Request phase change, type "CONFIRM" WITHOUT clicking email link | Shows "Email confirmation required" error |
| 2 | Request phase change, type "WRONG" in confirm field | Shows "Must type CONFIRM to proceed" |
| 3 | Call execute API directly without email confirmation | Returns 400 "Email confirmation required" |
| 4 | Use invalid/expired token in email link | Shows "Invalid or expired confirmation link" |

#### Election Dates
| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | Set nomination_start, nomination_end, voting_start, voting_end | Dates save successfully |
| 2 | Set voting_end in past | Accepts but votes after this time rejected by RPC |
| 3 | Set dates out of order (voting before nomination) | Accepts (no auto-advance, manual only) |
| 4 | Clear all dates | Saves as null |

### 2.5 Tab: Candidates
| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | Click "Candidates" tab | Lists all candidates with status |
| 2 | Click "Add Candidate" | Opens modal with name, statement, photo URL |
| 3 | Submit with valid data | Candidate added, appears in list |
| 4 | Submit without name | Shows "Candidate name required" error |
| 5 | Submit with invalid photo URL (http://, javascript:) | Shows "Only HTTPS URLs allowed" error |
| 6 | Submit with statement > 5000 chars | Shows length error |
| 7 | Edit candidate | Updates successfully |
| 8 | Deactivate candidate | Candidate hidden from voting |
| 9 | Try to delete candidate with votes | Shows "Cannot delete candidate with existing votes" |
| 10 | Delete candidate without votes | Deletes successfully |

### 2.6 Tab: Members Management
| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | Click "Members Management" tab | Lists all members with pagination |
| 2 | Search by name | Filters correctly |
| 3 | Click "Deactivate" on active member | Member status changes, audit log |
| 4 | Click "Activate" on inactive member | Member status changes, audit log |
| 5 | Verify deactivated members don't appear in voting | Cannot vote, no tokens dispatched |

### 2.7 Tab: Token Dispatch
| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | Click "Token Dispatch" tab | Shows member selection, token type dropdown |
| 2 | Select "VOTING" tokens, choose members | "Dispatch Tokens" button enables |
| 3 | Click "Dispatch Tokens" | Emails sent, toast shows count sent/failed |
| 4 | Check member email | Receives voting link with 7-day expiry |
| 5 | Select "NOMINATION" tokens | Emails sent with 24-hour expiry |
| 6 | Dispatch with no members selected | Button disabled |
| 7 | Verify tokens in database | Tokens created with expires_at, is_used=false |

### 2.8 Tab: Audit Log Viewer
| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | Click "Audit Log Viewer" tab | Shows paginated audit entries |
| 2 | Filter by action (PHASE_CHANGE, VOTE_CAST, etc.) | Filters correctly |
| 3 | Filter by member ID | Shows only that member's entries |
| 4 | Filter by date range | Shows entries within range |
| 5 | Verify admin_id populated | Shows admin session ID for each entry |
| 6. | Verify hash chain (if migration run) | record_hash links to previous_hash |

---

## Part 3: Security Feature Testing

### 3.1 Authentication Security
| Test | Action | Expected Result |
|------|--------|-----------------|
| Brute force admin secret | 125 rapid login attempts with wrong secret | Rate limited (429 after 120/min) |
| Session hijack attempt | Steal cookie, use in different browser | Works (SameSite=Strict prevents CSRF, but cookie works) |
| Session expiry | Wait 30 min, refresh | Auto-logs out, requires re-login |
| localStorage secret theft | Check localStorage after login | No admin_secret in localStorage |

### 3.2 CSRF Protection
| Test | Action | Expected Result |
|------|--------|-----------------|
| Cross-site form submit | Create malicious page that POSTs to admin API | Blocked (403 CSRF token required) |
| Missing CSRF header | Call admin API with session cookie but no x-csrf-token | Blocked (403) |
| Valid CSRF | Normal dashboard usage | All actions work |

### 3.3 Rate Limiting
| Endpoint | Limit | Test |
|----------|-------|------|
| `/api/admin/*` | 120 req/min (prod) | 121st request returns 429 |
| `/api/vote` | 5 req/min | 6th request returns 429 |
| `/api/admin/members` (search) | 30 req/min | 31st request returns 429 |

### 3.4 Input Validation
| Field | Invalid Input | Expected Result |
|-------|---------------|-----------------|
| Candidate name | 300 chars | Accepted (max 255) |
| Candidate name | 300 chars | Rejected (max 255) |
| Candidate statement | 6000 chars | Rejected (max 5000) |
| Photo URL | `http://example.com` | Rejected (HTTPS only) |
| Photo URL | `javascript:alert(1)` | Rejected |
| Member email | `invalid-email` | Rejected |
| Member phone | `abc` | Rejected |
| CSV import | `=cmd|'/C calc'!A0` | Sanitized to `'=cmd|'/C calc'!A0` |

### 3.5 Token Security
| Test | Action | Expected Result |
|------|--------|-----------------|
| Voting token expiry | Use token after 7 days | "Token expired" error |
| Nomination token expiry | Use token after 24 hours | "Token expired" error |
| Token reuse | Vote twice with same token | Second attempt rejected |
| Token enumeration | Brute force token space | Rate limited, tokens are 256-bit |

---

## Part 4: Election Workflow End-to-End

### 4.1 Complete Election Cycle
| Phase | Admin Action | Voter Action | Verification |
|-------|--------------|--------------|--------------|
| SETUP | Create candidates, import members | — | Candidates visible, members imported |
| SETUP → NOMINATION | Three-fold phase advance | — | Phase changes to NOMINATION |
| NOMINATION | Dispatch nomination tokens | Submit nominations | Nominations recorded |
| NOMINATION → NOMINATION_CLOSED | Three-fold phase advance | — | Phase changes |
| NOMINATION_CLOSED → VOTING | Three-fold phase advance | — | Phase changes to VOTING |
| VOTING | Dispatch voting tokens | Vote digitally or paper | Votes recorded, receipts issued |
| VOTING → VOTING_CLOSED | Three-fold phase advance | — | Phase changes |
| VOTING_CLOSED → COMPLETED | Three-fold phase advance | — | Phase changes, results published |
| COMPLETED | View results | Verify votes | Results match cast votes |

### 4.2 Reset Election (Testing)
| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | In COMPLETED phase, click "Request Reset" | Email sent |
| 2 | Click email link | UI shows "RESET" input |
| 3 | Type "RESET", click "Verify & Continue" | Final dialog shown |
| 4 | Click "Execute Reset" | Phase returns to SETUP, all votes cleared |
| 5 | Verify audit log | PHASE_CHANGE entries for each step |

---

## Part 5: Regression Checklist

After any deployment, verify these critical paths still work:

- [ ] Admin login with correct secret
- [ ] Admin login rejects wrong secret
- [ ] All 8 tabs accessible and functional
- [ ] Phase change three-fold confirmation works
- [ ] Reset election three-fold confirmation works
- [ ] Token dispatch sends emails
- [ ] Digital voting works end-to-end
- [ ] Paper ballot issue/record/spoil works
- [ ] Candidate CRUD works
- [ ] Member activate/deactivate works
- [ ] CSV import works (with/without email)
- [ ] Audit log shows entries with admin_id
- [ ] Rate limiting active on all endpoints
- [ ] Security headers present (CSP, HSTS, etc.)
- [ ] Error messages generic in production
- [ ] Config validation runs on startup

---

## Test Data Cleanup

After testing:
- [ ] Reset election to SETUP phase
- [ ] Clear test votes/ballots
- [ ] Deactivate test candidates
- [ ] Deactivate test members
- [ ] Clear test tokens

---

## Sign-Off

| Role | Name | Date | Signature |
|------|------|------|-----------|
| QA Lead | | | |
| Admin User | | | |
| Developer | | | |

---

## Appendix: Useful Commands

```bash
# Run automated UAT suite
npx playwright test tests/uat.spec.ts --reporter=line

# Check audit log hash chain (if migration run)
psql -c "SELECT action, record_hash, previous_hash FROM vote_audit_log ORDER BY created_at DESC LIMIT 5;"

# Verify rate limit tables
psql -c "SELECT * FROM rate_limit_hits ORDER BY created_at DESC LIMIT 10;"

# Check admin sessions
psql -c "SELECT * FROM admin_sessions ORDER BY created_at DESC LIMIT 10;"

# Check token expiry
psql -c "SELECT type, expires_at, is_used FROM tokens ORDER BY created_at DESC LIMIT 10;"
```