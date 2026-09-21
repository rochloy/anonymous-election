# Wave 10 — Mobile Tally Wizard Wireframe (`/admin/tally`)

**Status:** WIREFRAME — for review before implementation
**Date:** 2026-09-20
**Design note:** authored by the orchestrator (designer lane unavailable — monthly quota); copy needs user review.

---

## 1. Purpose

A phone-first admin wizard for the physical count and check-in: the admin walks
around with a phone, scanning ballot QR codes and checking in members. Three
modes in one page (segmented control): **Record / Spoil / Check-in**.

Design goal: minimize interactions per ballot — the tally is a repetitive loop.
Target: **scan (camera auto-capture) → 1 tap (candidate) → 1 tap (Confirm) = 2
taps + scan per ballot.**

---

## 2. Global Layout (all modes)

```
┌─────────────────────────────────────┐
│ Tally          ⏱ 9:41   [Logout ▾] │  ← top bar (sticky)
├─────────────────────────────────────┤
│ ┌─────────┬─────────┬───────────┐   │
│ │ Record  │  Spoil  │ Check-in  │   │  ← mode switcher (segmented, sticky)
│ └─────────┴─────────┴───────────┘   │
│                                     │
│        (active mode's loop)         │  ← content area
│                                     │
└─────────────────────────────────────┘
```

- **Session countdown** (`⏱ 9:41`): prominent, top bar. Mobile scope = hard
  12-minute absolute TTL (no idle extension). Turns amber + pulses under 3:00.
  On expiry: full-screen lock overlay → login screen. Text: "Session ends in
  X:XX — log in again to continue."
- **Logout ▾**: small menu → "Log out" (this device) + "Log out everywhere"
  (revokes all admin sessions; confirm required).
- **Mode switcher**: sticky under the top bar; switching modes is rare but must
  stay reachable one-handed.
- **Phase gate**: when phase ≠ VOTING, Record and Spoil render a locked card:
  "Available only while voting is open. Current phase: X." Check-in is available
  during VOTING.

---

## 3. Login Screen (pre-wizard)

```
┌─────────────────────────────────────┐
│                                     │
│          Election Tally             │
│   Admin tool — phone optimized      │
│                                     │
│   ┌───────────────────────────┐     │
│   │ Admin secret        (pwd) │     │
│   └───────────────────────────┘     │
│   ┌───────────────────────────┐     │
│   │        Log in             │     │  ← ≥48px tall
│   └───────────────────────────┘     │
│                                     │
│   Session: 12 min, auto-logout      │
└─────────────────────────────────────┘
```

- `POST /api/admin/login` with `{ secret, scope: 'mobile' }` → 12-minute session.
- Login rate limit: 5 attempts/min per IP in production (shared per NAT).
- Error: "Invalid admin secret" inline.

---

## 4. Mode 1 — RECORD (tally counting)

### State machine

```
IDLE ──(tap Scan)──▶ SCANNING ──(QR detected)──▶ SCANNED
  ▲                                                   │
  │            ┌───────────────────────────────────────┤
  │            ▼                                       ▼
  ├────(auto-clear)── SUCCESS ◀──(Confirm)── CONFIRMING
  │            │
  │            ▼
  └────(auto-clear)── ERROR (forged / duplicate / invalid)
```

### IDLE

```
┌─────────────────────────────────────┐
│  Recorded this session: 14          │  ← running tally
│  Last: VC-a1b2c3d4e5 · Kimberly S.  │  ← previous receipt (confidence)
│                                     │
│  ┌───────────────────────────┐     │
│  │      📷  Scan ballot      │     │  ← full-width, ≥64px
│  └───────────────────────────┘     │
│                                    │
│  Scan each ballot's QR, pick the   │
│  candidate, confirm.               │
└────────────────────────────────────┘
```

### SCANNING

Full-viewport camera viewfinder (html5-qrcode) with a scan-frame overlay.
Auto-captures on detect — no tap. A "Cancel" affordance returns to IDLE.

### SCANNED (confirm screen)

```
┌─────────────────────────────────────┐
│  Ballot scanned                     │
│  ID …PAPER:…9f2d                    │  ← truncated tail (fresh-scan check)
│                                     │
│  Candidate:                         │
│  ┌───────────────────────────┐     │
│  │ ○ Kimberly Scott          │     │  ← big radio rows, ≥48px
│  ├───────────────────────────┤     │
│  │ ○ Donald Anderson         │     │
│  ├───────────────────────────┤     │
│  │ ○ Donald Moore            │     │
│  └───────────────────────────┘     │
│                                     │
│  ┌───────────┐  ┌───────────┐      │
│  │  Confirm  │  │  Rescan   │      │  ← Confirm disabled until pick
│  └───────────┘  └───────────┘      │
└─────────────────────────────────────┘
```

- The full ballot_id travels in the confirm payload; the UI shows only the tail
  (last ~10 chars) — enough for the admin to see it is a fresh, changing scan.
- **Confirm** → `POST /api/admin/paper-vote` `{ ballotId, candidateId }` →
  `{ success, message, receiptCode }`.

### SUCCESS (auto-clear)

```
┌─────────────────────────────────────┐
│  ✓ Recorded                         │
│                                     │
│  Receipt: VC-a1b2c3d4e5             │  ← big, monospace
│  Kimberly Scott                     │
│                                     │
│  Next ballot in 3…                  │  ← countdown, tap to skip
└─────────────────────────────────────┘
```

Auto-returns to IDLE after ~3s; a tap skips the wait. The receipt code is the
member's verification handle (they can check it at `/verify`).

### ERROR (auto-clear)

```
┌─────────────────────────────────────┐
│  ⚠ Not recorded                     │
│  This ballot was already cast or    │  ← specific server message:
│  voided.                            │    forged (HMAC failed) /
│                                     │    duplicate (already cast) /
│  Discard this ballot.               │    invalid
│                                     │
│  Next ballot in 3…                  │
└─────────────────────────────────────┘
```

The three server-side guards surface here with their real messages:
- Forgery: HMAC verification failed → "Invalid ballot ID…"
- Duplication: "Paper ballot has already been cast or voided."
- Invalid: ballot not found / wrong status.
Guidance line: "Discard this ballot." — the physical duplicate/forgery is
removed from the count by hand; the system rejected the record.

---

## 5. Mode 2 — SPOIL (by ballot_id)

### State machine

Same shape as Record: IDLE → SCANNING → SCANNED → CONFIRMING → SUCCESS/ERROR →
auto-clear → IDLE.

### IDLE

```
┌─────────────────────────────────────┐
│  Voided this session: 2             │
│                                     │
│  ┌───────────────────────────┐     │
│  │      📷  Scan ballot      │     │
│  └───────────────────────────┘     │
│                                    │
│  Voiding permanently invalidates   │
│  the anonymous blank.              │
└────────────────────────────────────┘
```

### SCANNED (confirm screen)

```
┌─────────────────────────────────────┐
│  Ballot scanned                     │
│  ID …PAPER:…9f2d                    │
│                                     │
│  Reason (required):                 │
│  ┌───────┐ ┌──────────┐ ┌────────┐ │
│  │Damaged│ │Duplicate │ │Wrong   │ │  ← quick-pick chips
│  └───────┘ └──────────┘ └────────┘ │
│  ┌───────────────────────────┐     │
│  │ or type a reason…         │     │  ← free text
│  └───────────────────────────┘     │
│                                     │
│  ┌───────────┐  ┌───────────┐      │
│  │  Confirm  │  │  Rescan   │      │
│  └───────────┘  └───────────┘      │
└─────────────────────────────────────┘
```

- **Confirm** → `POST /api/admin/paper-invalid` `{ ballotId, reason }` →
  `{ success, message }` (voids the anonymous blank).
- Reason chips + free text: typing on a phone is slow; common reasons as chips.
- SUCCESS: "Voided" card + auto-clear. ERROR: same error-card pattern
  (already cast/voided, not found).

---

## 6. Mode 3 — CHECK-IN

### State machine

```
IDLE ──(type search, ≥2 chars, 300ms debounce)──▶ RESULTS ──(tap member)──▶ SELECTED
  ▲                                                  │
  │            ┌─────────────────────────────────────┤
  │            ▼                                     ▼
  ├────(auto-clear)── SUCCESS ◀──(Confirm)── CONFIRMING
  │            │
  │            ▼
  └────(auto-clear)── ERROR (not found / ineligible /
                                   consumed / digital reserved)
```

*Search is debounced live: fires after 300ms pause, minimum 2 characters. Results update live as the admin types — matching the nominate page's pattern (`app/nominate/[token]/page.tsx:66-69`).*

### IDLE

```
┌─────────────────────────────────────┐
│  Checked in this session: 9         │
│  Last: Sarah Thomas                 │
│                                     │
│  ┌───────────────────────────┐     │
│  │ 🔍 Search member name…    │     │  ← autofocused, live search
│  └───────────────────────────┘     │     (≥2 chars, 300ms debounce)
└─────────────────────────────────────┘
```

*Live search: results update as the admin types (debounced 300ms, min 2 chars).*

### RESULTS

```
┌─────────────────────────────────────┐
│  ┌───────────────────────────┐     │
│  │ 🔍 sar                    │     │
│  └───────────────────────────┘     │
│  ┌───────────────────────────┐     │
│  │ Sarah Thomas    M-92765…  │     │  ← tap to select, ≥48px
│  ├───────────────────────────┤     │
│  │ Sarah Connor    M-1a95…   │     │
│  └───────────────────────────┘     │
└─────────────────────────────────────┘
```

*Results update live as the admin types (debounced 300ms, min 2 chars).*

### SELECTED (confirm screen)

```
┌─────────────────────────────────────┐
│  Check in                           │
│  Sarah Thomas                       │
│  M-92765adb                         │
│                                     │
│  Creates the identity slip and      │
│  consumes the voting entitlement    │
│  for paper voting.                  │
│                                     │
│  ┌───────────┐  ┌───────────┐      │
│  │  Confirm  │  │  Cancel   │      │
│  └───────────┘  └───────────┘      │
└─────────────────────────────────────┘
```

- **Confirm** → `POST /api/admin/paper-ballot` `{ memberId }` →
  `issue_paper_ballot(member_id)` → creates the slip, lazy-creates the
  entitlement when absent, consumes the token → member becomes `PAPER_ISSUED`.

### SUCCESS (auto-clear)

```
┌─────────────────────────────────────┐
│  ✓ Checked in                       │
│  Sarah Thomas                       │
│                                     │
│  Slip code: VVB8-A7YN-NUQ0          │  ← READ-ONLY, monospace
│  (reference only — no need to       │
│   write down)                       │
│                                     │
│  Hand the member a paper ballot.    │  ← the physical step
│  Next member in 3…                  │
└─────────────────────────────────────┘
```

- The short code is server-generated and stored as the slip's DB identity —
  displayed read-only for reference/audit; **no printing or writing is needed**
  (design decision — the simple flow needs no physical slip).
- Guidance line: "Hand the member a paper ballot." — the physical handover from
  the pre-printed pool; no system linkage (the severance).

### ERROR

```
┌─────────────────────────────────────┐
│  ⚠ Not checked in                   │
│  <server message>                   │  ← one of:
│                                     │    "Member not found or inactive."
│                                     │    "Member is not eligible to vote."
│                                     │    "Voting entitlement already
│                                     │     consumed."
│                                     │    "Member has an active digital
│                                     │     voting credential; release or
│                                     │     wait for it to expire…"
│                                     │
│  Search again in 3…                 │
└─────────────────────────────────────┘
```

---

## 7. Component Inventory

| Component | Role |
|---|---|
| `SessionGate` | Login screen + countdown + lock overlay |
| `ModeSwitcher` | Segmented control (Record / Spoil / Check-in) |
| `QrScanner` | html5-qrcode viewfinder wrapper, auto-capture |
| `ScanResultCard` | Truncated ballot_id display (fresh-scan check) |
| `CandidatePicker` | Big radio rows from `/api/candidates` |
| `ReasonInput` | Quick-pick chips + free text |
| `ConfirmBar` | Confirm + Cancel/Rescan |
| `ResultCard` | Success/error variants + auto-clear countdown |
| `MemberSearch` | Autofocused input + results list |
| `ShortCodeDisplay` | Read-only monospace short code |
| `SessionTally` | Running per-session count (Record / Spoil / Check-in) |

---

## 8. Design Decisions + Rationale

1. **2 taps + scan per ballot** (candidate → Confirm): the mandatory confirm is
   a deliberate guard against mis-taps (the proven old-wizard pattern); the
   auto-clear keeps the loop fast. A 1-tap "tap candidate = confirm" mode was
   considered and rejected — no confirmation step risks recording mistakes.
2. **Reason chips in Spoil**: typing on a phone is slow; common reasons as
   one-tap chips with a free-text fallback.
3. **Short code read-only in Check-in success**: per the operator's decision —
   the simple flow needs no physical slip; the code is displayed for
   reference/audit only.
4. **Hard 12-minute session countdown, prominent**: mobile scope has no idle
   extension; a prominent countdown prevents a mid-tally lockout surprise.
5. **Running session tally on all three modes**: immediate feedback plus a
   reconciliation aid — the admin can cross-check the physical box count
   against the recorded count.
6. **Truncated ballot_id display**: the full ~135-char ID travels in the
   payload; the tail is enough to confirm a fresh, changing scan.
7. **Phase gating in the wizard**: Record/Spoil locked outside VOTING with the
   real phase shown; Check-in available during VOTING. (Implementation-time
   verification item: confirm the RPC-level phase behavior for check-in.)
