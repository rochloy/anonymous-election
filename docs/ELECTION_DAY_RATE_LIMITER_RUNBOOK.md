# Election-Day Rate-Limiter Fault Runbook

## Purpose

Provide polling staff with a safe, concrete procedure when rate-limiter behavior changes during election operations.

This runbook distinguishes:

- **Confirmed denials** (HTTP **429**) vs
- **Limiter unavailability/faults** (HTTP **503** on fail-closed surfaces)

and explains when normal operations can continue versus when to pause check-in.

> Scope boundary: this runbook does **not** add offline ballot import/replay, does **not** assume any configured WAF rule, and does **not** assume any automatic alerting destination.

## Named Operational Role

- **Role responsible for triage/escalation:** `election authority/polling lead`
- **Fill-in contact (must be completed before election day):** `[NAME / PHONE / BACKUP CONTACT]`

## Session Timeout Facts (for triage)

- **Desktop admin session:** 10-minute idle timeout, 4-hour absolute cap.
- **Mobile Wizard session:** 12-minute absolute timeout (no idle extension).

These values matter because limiter faults are often first seen at re-login after expiry.

## Surface Policy Matrix

| Surface | Confirmed denial | Limiter fault (RPC error/throw/malformed result) | Policy |
|---|---|---|---|
| Admin login (`/api/admin/login`) | 429 | 503 (`Login temporarily unavailable. Please try again shortly.`) | **Fail-closed** |
| General admin proxy (`/api/admin/*` in `proxy.ts`) | 429 | Continue to handler | **Fail-open** |
| Legacy vote submit (`/api/vote`) | 429 | Continue to normal vote guards | **Fail-open** |
| Admin member search (`/api/admin/members`) | 429 | Continue, still requires valid admin session | **Fail-open** |
| Nomination submit (`/api/nominate`) | 429 | 503 (`Rate limit unavailable`) | **Fail-closed** |
| Nomination search (`/api/nominate/search`, IP + token checks) | 429 | 503 (`Rate limit unavailable`) | **Fail-closed** |

Non-negotiable rule: **a confirmed denial remains 429 on all surfaces**.

## 429 vs 503 Meaning

- **429 Too Many Requests**: limiter is healthy and explicitly denied the request for the current window. This is not, by itself, proof of attack.
- **503 Service Unavailable (limiter unavailable)**: limiter decision could not be obtained (error, throw, malformed/absent decision). On fail-closed surfaces, request is blocked to avoid unsafe bypass.

## Triage Procedure for Polling Lead

1. **Capture symptom without voter data**
   - Record: timestamp, endpoint, HTTP status (429 or 503), and whether staff were logged in or re-authenticating.
   - Do **not** capture submitted secrets, voter tokens, member names, or full request bodies.

2. **Classify quickly**
   - **Mostly 429** on a route: treat as threshold pressure first.
   - **503 from login or nomination routes** is a **symptom**, not proof of root cause.
   - Do not diagnose limiter fault from status code alone; correlate with sanitized structured logs (`event: 'limiter_unavailable'`) and check for concurrent DB/session errors.

3. **Check Vercel logs (sanitized signals only)**
   - Open project logs around the incident window.
   - Look for route-tagged limiter events/errors (e.g., login/member-search/vote/nominate paths), specifically `event: 'limiter_unavailable'`.
   - Confirm whether failures are isolated to limiter checks or broader DB/API/session errors.

4. **Check Supabase RPC health (no secrets exposed)**
   - Use platform health dashboards/logs to confirm RPC/database availability status.
   - Validate whether `check_rate_limit` calls are succeeding/failing in the same time window.
   - Do not print or paste credentials; do not run probes against real voter/member records.

5. **Differentiate outage type**
   - **Limiter-only fault:** login may return 503 for new/expired sessions, while already-authenticated admin work can continue on fail-open surfaces.
   - **Broad Supabase outage:** session creation/validation, entitlement checks, and voting writes fail broadly. Limiter policy cannot rescue this.

6. **Operational decision point (paper check-in safety)**
   - If online entitlement/session commits are unavailable (broad DB outage or equivalent write-path failure), **pause final paper check-in/commit actions** until recovery.
   - Do not improvise offline entitlement tracking for later import.

7. **Escalate**
   - Escalate to `election authority/polling lead` at: **[NAME / PHONE / BACKUP CONTACT]**.
   - Include: status pattern (429 vs 503), affected routes, start time, and whether authenticated sessions remained usable.

## Data-Safety Constraints During Incident Handling

- Do not test against real voter/member records while diagnosing limiter health.
- Do not copy admin secrets, voting tokens, or nomination tokens into tickets/chat.
- Keep evidence minimal: status codes, route names, and timestamps.

## Recovery and Resume Criteria

Resume paused final check-in/commit operations only after:

1. limiter/API health is stable in logs,
2. session creation/validation works again,
3. entitlement and vote writes succeed in normal operator flow,
4. polling lead approves restart.
