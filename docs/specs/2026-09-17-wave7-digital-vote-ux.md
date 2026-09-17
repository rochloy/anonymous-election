# Spec — Wave 7: Two-Phase Digital Vote UX (redeem → cast)

Status: DRAFT (design gate — no source edited by this spec; DB/API layer authored in parallel)
Date: 2026-09-17
Scope: `app/vote/[token]/page.tsx` (voter-facing), `app/admin/dashboard/page.tsx` (member-status
indicator only). No API/route/DB changes are specified here — this document assumes the
`POST /api/vote/redeem`, `POST /api/vote/cast`, `POST /api/vote/release` contract described in
the prompt and designs the client UI/copy around it.

Inputs read for continuity:
- `app/vote/[token]/page.tsx` — current single-call vote flow, status machine, receipt actions
  (copy/download/print), `bg-blue-600` primary button convention.
- `app/admin/dashboard/page.tsx:2504-2556` — member status pill (`ELIGIBLE` green /
  `DIGITAL_VOTED` blue / `PAPER_ISSUED` yellow / `PAPER_VOTED` purple), token `ACTIVE`/`USED`
  sub-badges, `dark:` variants throughout.
- `app/verify/page.tsx` — light-panel (`bg-white`/`bg-gray-800`), receipt confirmation
  card styling (`bg-green-50` success, `bg-red-50` error), plain-language reassurance copy
  pattern ("This confirms your vote was recorded — not who you voted for").

---

## 1. Goal

Make the digital vote flow's **two-call** redeem→cast sequence invisible to the voter on the
happy path, while giving honest, non-alarming, non-leaking copy for every failure mode the new
sequence introduces — especially the rare **post-redeem-cast-fails** window, which is
unrecoverable client-side and requires an admin re-issue.

Also design the admin-facing **RESERVED / uncast** third status so admins can see in-flight
digital votes without mistaking a normal, self-resolving TTL window for a problem.

## 2. Non-goals / fixed contract (do not redesign)

- The protocol is fixed: `redeem` then `cast`, sequential, client-orchestrated, credential held
  only in React state (never persisted to storage/URL). This spec designs the UI/copy around
  that contract, not an alternative protocol.
- No change to candidate list loading, token verification on page load, or the receipt code
  format (`VC-…`).
- No change to `/api/auth/verify-token` step 1 (page-load validation stays as-is).

## 3. Client state machine

Current states: `loading | invalid | ready | voted`.

New states (superset, `ready` gains sub-states):

```
loading → invalid
loading → ready
ready            (candidate list, nothing selected or selected, no server call yet)
  → confirming   (redeem in flight)
    → casting    (redeem succeeded, cast in flight)
      → voted           (cast succeeded — receipt screen)
      → cast_failed      (redeem OK, cast failed — unrecoverable, distinct terminal screen)
    → redeem_failed      (redeem rejected — back to `ready`-like screen with inline reason)
  → (voter may click Cancel while in `casting`-pending-confirmation window only if
     UX choice B below is adopted — see §6)
```

Key invariant: **`cast_failed` is a distinct terminal render, not an inline error banner on the
candidate list.** Once cast fails after a successful redeem, the voter's in-memory credential is
assumed gone/unusable — there is nothing left to retry from this tab. The UI must not offer a
"try again" button that silently re-runs redeem (that would mint a second credential against a
token that may now be in an ambiguous state — that's an API-layer decision, not this spec's, but
the UI must not imply a client-side retry is safe). Instead it hands off to a single clear
instruction: contact an election administrator.

## 4. Screen-by-screen spec

### 4.1 `ready` — candidate list (mostly unchanged)

No visual change from today's layout. One addition: the primary button becomes stateful across
three sub-phases while keeping the **same physical button** in place (no layout shift):

| Sub-state | Button label | Button style | Disabled? |
|---|---|---|---|
| idle, nothing selected | `Confirm vote` | `bg-blue-600 text-white` (existing) | disabled |
| idle, candidate selected | `Confirm vote` | `bg-blue-600 hover:bg-blue-700 text-white` (existing) | enabled |
| `confirming` (redeem in flight) | `Confirming…` | same blue, `opacity-75 cursor-wait`, inline spinner | disabled |
| `casting` (cast in flight) | `Casting your vote…` | same blue, spinner | disabled |

Candidate cards become **non-interactive** (no `onClick`, visually dimmed to ~60% opacity via
`opacity-60 pointer-events-none`) the moment the button is clicked, for the entire
`confirming`→`casting` window. This prevents a voter from changing their selection mid-flight
(which the fixed 2-call contract cannot support once `redeem` has already fired) and visually
communicates "this is happening now, hold on."

**Motion note:** on click, transition the button label with a simple cross-fade
(`transition-opacity duration-150`) between `Confirm vote` → `Confirming…` → `Casting your
vote…`. Do not use a multi-step progress bar or numbered "step 1 of 2" UI — the fixed contract
is explicitly designed to feel like one action, and exposing "step 2" language would undercut
that by implying a resumable multi-step process it is not (see §7, Rough Edge #1).

Add a small spinner (inline SVG or a simple CSS-animated dot, matching the existing icon style
used elsewhere in the dashboard, e.g. `animate-spin`) to the left of the button label whenever
disabled-and-pending, so voters get non-text feedback the click registered even on slow network.

No separate "loading card" or modal — everything happens in-place on the existing candidate
screen. This preserves the "single action" feel most directly.

### 4.2 `redeem_failed` — redeem rejected

Rendered as an **inline error panel above the candidate list**, not a full-screen replacement —
the voter stays on the same screen they were on, selection is preserved, and they may retry
(hit Confirm again) once told what's wrong, where retrying makes sense.

Panel style (matches `verify/page.tsx` error convention):
```
<div className="p-4 mb-4 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded">
```

Copy is mapped **per reason**, plain language, no internals leaked, no mention of "credential",
"reserve", or DB-speak to the voter:

| Server reason (redeem rejected) | Voter-facing copy | Retry affordance |
|---|---|---|
| Token invalid / not found | "This voting link isn't valid. Double-check the link in your email or text, or contact an election administrator for a new one." | No retry button — dead end, contact admin |
| Token expired | "This voting link has expired. Contact an election administrator to request a new one." | No retry — dead end, contact admin |
| Token already used | "This link has already been used to vote. If you believe this is a mistake, contact an election administrator." | No retry — dead end, contact admin |
| Token already reserved (another in-flight redeem holds it — e.g. voter double-clicked in two tabs) | "Your vote is already being processed in another tab or window. Please check there, or wait a moment and try again here." | Retry button shown (`Try again`) |
| Member ineligible | "Our records show this membership isn't eligible to vote in this election. Contact an election administrator if you believe this is incorrect." | No retry — dead end, contact admin |
| Cross-channel conflict (paper ballot already issued/cast for this member) | "It looks like a paper ballot has already been issued or cast for this membership, so this digital link can no longer be used. Contact an election administrator if you believe this is a mistake." | No retry — dead end, contact admin |
| Generic/unknown server error, network failure on redeem call | "Something went wrong starting your vote. Please try again." | Retry button shown (`Try again`) |

For every "No retry" row, render a secondary line: *"Need help? Contact your election
administrator."* — if the app has a known admin contact surface (email/help link) elsewhere in
the site, link it here; otherwise keep it as plain text (flagged in §7, Rough Edge #2 — this spec
does not know the canonical support contact channel).

After a redeem failure, the button and candidate cards return to fully interactive (nothing was
reserved server-side that the client needs to hold), selection state is preserved so the voter
doesn't have to reselect their candidate before retrying.

### 4.3 `casting` → `cast_failed` — the unrecoverable window

This is the state that most needs careful, honest, calm copy. Triggers: cast API call fails
after a successful redeem (network drop, in-memory credential lost to refresh/crash — though a
refresh/crash also destroys all React state, so in practice this state is only reachable when
the tab survives but the cast network call itself fails or times out server-side, e.g. TTL
expired in the few-hundred-ms gap between redeem and cast).

**Full-screen replacement**, not an inline banner — this is a terminal state distinct from "try
again", and treating it as a dismissible inline error risks voters clicking past it and assuming
they're fine. Style consistent with the current `voted` screen's card-in-page layout, but amber
(caution), not red (error/danger) and not green (success) — this is neither a clean failure nor
a success, and red risks reading as "you did something wrong."

```
<div className="p-8 max-w-2xl mx-auto">
  <div className="p-6 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg">
    <h1 className="text-xl font-bold text-amber-900 dark:text-amber-300 mb-3">
      We couldn't finish casting your vote
    </h1>
    <p className="text-sm text-gray-700 dark:text-gray-300 mb-3">
      Your voting credential is no longer valid, so we weren't able to complete this vote.
      <strong> Your vote has not been recorded</strong> — nothing was counted.
    </p>
    <p className="text-sm text-gray-700 dark:text-gray-300 mb-3">
      This can happen if the connection dropped at the wrong moment. It is not something you did
      wrong, and this link cannot be reused to try again.
    </p>
    <p className="text-sm font-medium text-gray-900 dark:text-white">
      Please contact an election administrator — they can issue you a new voting link.
    </p>
  </div>
</div>
```

Exact copy requirements (non-negotiable per the prompt's contract):
- MUST explicitly state the vote was **not recorded** (never let the voter believe they might
  have voted and it just didn't confirm — ambiguity here undermines trust more than a clean
  failure would).
- MUST NOT say or imply "you already voted."
- MUST NOT expose internals: no mention of "TTL", "credential expired", "redeem", "cast",
  "token", error codes, or stack traces. "Your voting credential is no longer valid" is the
  most technical phrase used, and it's necessary to explain *why* contacting an admin is the
  next step — it does not reveal mechanism.
- MUST give a single, unambiguous next action: contact an election administrator for a new link.
  No retry button on this screen — a client-side retry would attempt a fresh redeem against a
  token whose state is now the API layer's problem to define; the UI does not decide that, it
  just stops here.

No receipt-style actions (copy/download/print) on this screen — there is no receipt, and
offering those affordances would visually imply this is a success-adjacent state.

### 4.4 `voted` — success / receipt (unchanged)

No changes to the existing receipt screen (copy/download/print buttons, receipt code display,
"save this privately" copy). It already reads correctly for the two-call flow since the voter
never sees the intermediate mechanics. One addition only: on arrival at this screen, if a
`Cancel` affordance was visible during `casting` (see §6, if adopted), it must be fully removed
— no residual disabled button flash.

### 4.5 Loading state before `ready` (unchanged)

`Verifying your token...` stays as-is. No redeem call happens here — reconfirm this explicitly
in the implementation: the effect that fires on mount must call **only**
`/api/auth/verify-token` and `/api/candidates`, never `/api/vote/redeem`. Redeem must be
strictly gated behind the Confirm-vote click. (This is a contract requirement from the prompt,
restated here as an implementation guardrail since it's easy to accidentally trigger redeem
eagerly for a "smoother" UX — that would be wrong: it reserves the token before the voter has
committed to voting, e.g. a voter who opens the link, sees the candidates, and closes the tab
without voting.)

## 5. Copy reference table (all voter-facing strings, consolidated)

| Context | String |
|---|---|
| Button, no selection | `Confirm vote` |
| Button, selected, idle | `Confirm vote` |
| Button, redeeming | `Confirming…` |
| Button, casting | `Casting your vote…` |
| Redeem fail — invalid token | This voting link isn't valid. Double-check the link in your email or text, or contact an election administrator for a new one. |
| Redeem fail — expired token | This voting link has expired. Contact an election administrator to request a new one. |
| Redeem fail — already used | This link has already been used to vote. If you believe this is a mistake, contact an election administrator. |
| Redeem fail — already reserved | Your vote is already being processed in another tab or window. Please check there, or wait a moment and try again here. |
| Redeem fail — ineligible | Our records show this membership isn't eligible to vote in this election. Contact an election administrator if you believe this is incorrect. |
| Redeem fail — cross-channel conflict | It looks like a paper ballot has already been issued or cast for this membership, so this digital link can no longer be used. Contact an election administrator if you believe this is a mistake. |
| Redeem fail — generic/network | Something went wrong starting your vote. Please try again. |
| Redeem fail — help line (dead-end rows) | Need help? Contact your election administrator. |
| Cast fail (post-redeem, terminal) — heading | We couldn't finish casting your vote |
| Cast fail — body 1 | Your voting credential is no longer valid, so we weren't able to complete this vote. **Your vote has not been recorded** — nothing was counted. |
| Cast fail — body 2 | This can happen if the connection dropped at the wrong moment. It is not something you did wrong, and this link cannot be reused to try again. |
| Cast fail — action | Please contact an election administrator — they can issue you a new voting link. |
| Cancel affordance (if adopted, see §6) | Cancel |
| Cancel confirmation toast/inline (if adopted) | Cancelled. You can pick a candidate and vote whenever you're ready. |

No copy in this table mentions "redeem", "reserve", "credential TTL", "cast", or any other
implementation term to the voter — those words only appear in this spec and in code, not in UI.
The one exception is "voting credential" in the cast-fail screen, which is unavoidable plain
English for "the thing that let you vote" and is judged acceptable per the contract (§4.3).

## 6. Cancel-after-redeem affordance — design decision

**Recommendation: do not surface a visible Cancel button in v1.** Reasoning:

- The redeem→cast gap is designed to be milliseconds (two sequential `fetch` calls fired
  back-to-back with no voter interaction in between — the prompt's contract does not describe
  a pause for voter confirmation between redeem and cast). There is no UI moment where a voter
  is sitting at a screen with a live reservation deciding whether to back out — by the time
  render happens, `cast` has typically already been requested.
- Surfacing a Cancel button implies a pause that doesn't exist in the happy path, which
  contradicts the "one action" goal and invites a race: a voter clicks Cancel at the exact
  moment `cast` resolves server-side, producing a confusing "cancelled, but did I vote?" state
  the UI cannot cleanly resolve.
- If a real pause is later needed (e.g. deliberately inserting a "review your choice" confirm
  step between redeem and cast for other reasons), the release endpoint becomes useful and this
  section should be revisited.

**If the API layer's real-world latency between redeem and cast turns out to be non-trivial**
(e.g. cast does extra work, or there's a deliberate confirm step this spec doesn't know about),
the fallback design is:
- Show a `Cancel` text-button (not a filled button — de-emphasized, `text-sm text-gray-500
  hover:underline`) next to the disabled `Casting your vote…` primary button, enabled only
  during the `casting` sub-state.
- Clicking it calls `POST /api/vote/release`, then returns the voter to the fully-interactive
  `ready` screen with their selection preserved and copy: *"Cancelled. You can pick a candidate
  and vote whenever you're ready."*
- If `cast` and `release`/`cancel` race (voter clicks Cancel just as cast succeeds
  server-side), the client must trust whichever response actually lands and never show a state
  that contradicts it — if cast's success response arrives after a cancel was requested, show
  the `voted` receipt screen, not the cancelled state. This is a client-side response-ordering
  rule to hand to whoever implements the fetch logic, not a new API behavior.

This is flagged as an open decision for you (see §7) since it depends on real cast-path latency
that this spec doesn't have visibility into.

## 7. Rough edges in the fixed contract — flagging for your decision

1. **"One click, two calls" hides real latency variance from the voter.** If a voter is on a
   slow connection, `redeem` then `cast` sequentially could take a few seconds combined, and
   because there's no numbered "step 1/2" UI (deliberately, per §4.1), a voter watching
   `Confirming…` → `Casting your vote…` change might wonder if the button is stuck vs.
   progressing. Mitigated with the spinner + button label change, but there's a real design
   tension between "make it feel like one action" (masks progress) and "communicate it's still
   working" (implies multiple steps). Current spec sides with the "one action" framing since
   that's explicitly the fixed goal; flagging in case slow-network cast latency in practice
   turns out to be long enough that voters need a stronger sense of "still working" (e.g. adding
   elapsed-time text after ~3s: "Still working…").

2. **No canonical "contact an election administrator" channel is currently designed.** Every
   dead-end failure copy in this spec ends with "contact an election administrator," but I
   don't know if this app has an admin email, a help page, or a phone number surfaced anywhere
   voter-facing today. Recommend adding one canonical contact line (email or a `/help` page
   link) somewhere central (e.g. election communications, or a small footer link on `/vote/…`
   itself) so this copy can become a real `mailto:` or link rather than inert text. Until that
   exists, ship the inert text — better than nothing, but worth closing the loop.

3. **Cross-channel conflict copy assumes the API tells the client "why" at redeem time.**
   The per-reason mapping in §4.2 assumes the redeem endpoint returns a distinguishable reason
   code per row (invalid / expired / used / reserved / ineligible / cross-channel /
   generic). If the API instead collapses several of these into one generic "redeem failed"
   response for security reasons (e.g. to avoid leaking which specific state a token is in to
   an attacker probing tokens), several of the differentiated copy rows in §4.2/§5 collapse into
   the generic-error row and lose their more helpful specificity. Flagging because this is a
   security/UX tradeoff that belongs to the API design, not this spec — if the API team decides
   to collapse reasons for anti-enumeration reasons, tell me and I'll consolidate the copy table
   accordingly (the *voter-facing* language for each individual case in §4.2 remains valid
   material to reuse even if fewer of them are distinguishable at runtime).

4. **`cast_failed` offers no path back into the same tab.** By design (§4.3), there's no retry
   button — but this means a voter who hits this state, then fixes their network and refreshes
   the page, will land back on `/vote/<token>` at `loading` → likely `invalid` (token already
   reserved/consumed depending on what state the API left it in) rather than a fresh `ready`
   state. That's expected/correct per the contract (the token's fate here is the API layer's
   call), but means the "contact an administrator" instruction is truly the only path — worth
   the API team confirming that a re-issued token (new token, not a retry of the same one) is
   indeed the intended recovery, so this spec's copy ("they can issue you a new voting link")
   matches what actually happens operationally.

## 8. Admin dashboard — third status: "RESERVED / uncast"

### 8.1 Where it slots in

Same status pill location as today (`app/admin/dashboard/page.tsx` member row, next to the
existing `ELIGIBLE`/`DIGITAL_VOTED`/`PAPER_ISSUED`/`PAPER_VOTED` pill). Insert the new value
into the type as `'DIGITAL_RESERVED'` (server-side naming is the API layer's call; this spec
just needs *a* stable string value to key off of) so the existing ternary/pill pattern extends
naturally:

```
member.votingStatus === 'ELIGIBLE'        → green  (existing)
member.votingStatus === 'DIGITAL_RESERVED' → NEW — amber, see below
member.votingStatus === 'DIGITAL_VOTED'    → blue   (existing)
member.votingStatus === 'PAPER_ISSUED'     → yellow (existing)
member.votingStatus === 'PAPER_VOTED'      → purple (existing)
```

### 8.2 Visual treatment

**Do not reuse yellow** — `PAPER_ISSUED` already owns yellow, and visually confusing "someone
has a live paper ballot outstanding" with "someone has a live digital credential reservation"
would be a real admin-facing regression (these require different admin actions: paper issuance
is stable/expected to sit there until voted; digital reservation is expected to self-resolve in
minutes).

Use **amber with a pulsing dot** to communicate "transient, will resolve on its own":

```tsx
<span className="inline-flex items-center gap-1.5 px-2.5 py-1 text-xs font-semibold rounded-full bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-400">
  <span className="w-1.5 h-1.5 rounded-full bg-amber-500 animate-pulse" aria-hidden="true" />
  RESERVED
</span>
```

- Label text: **`RESERVED`** (matches the existing all-caps pill convention: `ELIGIBLE`,
  `DIGITAL_VOTED`, `PAPER_ISSUED`, `PAPER_VOTED`).
- The small pulsing dot (`animate-pulse`, Tailwind's built-in keyframe) is the one deliberate
  motion moment in the admin UI addition — it should read as "something is actively in progress
  here," distinct from the static pills for stable states. Keep it subtle (1.5×1.5, not a big
  attention-grabber) — this is a "the system is handling something," not a "come fix this now"
  alert.
- Do not use red/danger styling anywhere for this state — it is not an error condition.

### 8.3 Tooltip / help copy

Add a `title` attribute (native tooltip, matching the lightweight-affordance level already used
elsewhere in this dashboard, e.g. no custom tooltip component exists here today) on the pill:

```
title="This member redeemed a digital voting credential but hasn't finished casting yet. This is normal and temporary — it resolves on its own when the credential expires or the vote completes. No admin action is needed unless it persists for an unusually long time."
```

If a member row has extra vertical space available (it does, alongside the existing
`ELIGIBLE`/`PAPER_ISSUED` action buttons), also render a one-line explanatory caption directly
under the pill instead of relying solely on hover discovery (admins scanning a long list won't
hover every pill):

```tsx
<p className="mt-1 text-[11px] text-amber-700 dark:text-amber-500 max-w-[220px]">
  In progress — resolves automatically
</p>
```

### 8.4 No admin action button for this state

Unlike `ELIGIBLE` (which shows "Issue Paper Ballot" / "Select for scanned ballot") and
`PAPER_ISSUED` (which shows "View QR / Print"), `RESERVED` should show **no action button** by
default. This reinforces "nothing to do here, wait it out" and avoids admins reaching for a
"cancel their vote" button that doesn't exist in this spec's contract (the only release path is
voter-initiated `/api/vote/release` or TTL auto-expiry — both outside admin control per the
fixed contract). If the API layer later needs an admin-triggered force-release for stuck rows
(e.g. TTL sweep is delayed), that would be a new capability outside this spec's scope — flag it
to me separately rather than silently adding a button here.

### 8.5 Why this matters for trust

Admins seeing an unfamiliar pill mid-election with no explanation are the most likely people to
escalate unnecessarily (call the voter, call the developer, assume something broke). The
combination of (a) a visually distinct-but-calm color, (b) the word "RESERVED" itself (implies
temporary hold, not a terminal state), (c) the pulsing dot as a "still working" signal, and (d)
explicit "resolves on its own" copy in both the tooltip and inline caption is intended to
preempt that escalation reflex.

## 9. Summary of visual/motion tokens used (net-new only)

| Token | Use |
|---|---|
| `bg-amber-50` / `border-amber-200` / `dark:bg-amber-900/20` / `dark:border-amber-800` | `cast_failed` full-screen panel background |
| `text-amber-900` / `dark:text-amber-300` | `cast_failed` heading |
| `bg-amber-100` / `text-amber-800` / `dark:bg-amber-900/30` / `dark:text-amber-400` | Admin `RESERVED` pill |
| `bg-amber-500` + `animate-pulse` | Admin `RESERVED` pill's live-indicator dot |
| `opacity-60 pointer-events-none` | Candidate cards, disabled during confirm/cast |
| `opacity-75 cursor-wait` | Primary button, disabled during confirm/cast |
| `transition-opacity duration-150` | Button label cross-fade between phases |
| `animate-spin` | Inline spinner icon on primary button while pending |

No new fonts, no new color families beyond amber (chosen specifically because it's unused by
the existing four-state pill system and reads as "caution/in-progress," not "error" or
"success"). Everything else reuses the app's existing red/green/blue/gray Tailwind v4 palette
and `dark:` variant conventions already established across `vote/[token]`, `verify`, and the
admin dashboard.
