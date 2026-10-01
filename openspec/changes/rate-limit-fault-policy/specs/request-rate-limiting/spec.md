# Spec Delta

## Purpose

Keep legitimate election-day operations available where the agreed fault policy permits, while distinguishing an unavailable request limiter from a confirmed rate-limit denial and retaining authentication and voting safeguards.

## ADDED Requirements

### Requirement: Distinguish limiter outcomes
The system MUST treat an explicit allow, an explicit denial, and an unavailable limiter as distinct outcomes. An error, exception, malformed or absent result, or an explicitly configured deadline being exceeded MUST be treated as unavailability, not as a confirmed denial or a healthy allow.

#### Scenario: A request is within its limit
- **WHEN** the limiter explicitly permits a request
- **THEN** the request proceeds through its normal authentication, authorization, eligibility, and operation checks

#### Scenario: A request exceeds its limit
- **WHEN** the limiter explicitly denies a request
- **THEN** the request receives HTTP 429 with retry guidance and cannot proceed under any fault policy

#### Scenario: The limiter returns an unusable result
- **WHEN** the limiter returns no valid allow-or-deny decision
- **THEN** the system applies that request surface's unavailable-limiter policy instead of interpreting the result as permission or as a confirmed denial

### Requirement: Login fails closed with an identifiable outage response
The admin login-specific limiter MUST fail closed when unavailable. Login MUST return HTTP 503 with a non-sensitive, actionable explanation; it MUST NOT compare the submitted secret or create an admin session for that request. A confirmed rate-limit denial MUST remain HTTP 429. The general admin proxy MUST NOT prevent a login request from reaching this login-specific check solely because the proxy's own limiter is unavailable.

#### Scenario: Login limiter is unavailable
- **WHEN** the admin login-specific limiter reports an error, throws, returns an unusable result, or exceeds an explicitly configured deadline
- **THEN** login responds HTTP 503, explains that login is temporarily unavailable, and creates no session

#### Scenario: Login limit is actually exceeded
- **WHEN** the login-specific limiter explicitly denies the request
- **THEN** login responds HTTP 429 and creates no session

### Requirement: Existing fail-open surfaces continue through normal safeguards
The general admin proxy, the legacy digital-vote endpoint, and authenticated admin member search MUST continue through their normal handlers if their own limiter is unavailable. This exception MUST NOT disable admin session validation, CSRF checks, voting token and phase checks, or paper entitlement guards. Confirmed limiter denials MUST still block with HTTP 429.

#### Scenario: General proxy limiter is unavailable
- **WHEN** the general admin proxy's limiter cannot return a valid decision
- **THEN** the request reaches its normal handler, which still enforces its own security and business checks

#### Scenario: Vote limiter is unavailable
- **WHEN** the legacy digital-vote endpoint's limiter cannot return a valid decision
- **THEN** the request still undergoes its normal voting-mode, token, eligibility, phase, and atomic cast checks

#### Scenario: Search limiter is unavailable
- **WHEN** the member-search limiter cannot return a valid decision
- **THEN** the request still requires a valid admin session before any member information is returned

### Requirement: Preserve existing nomination fault posture
Nomination submission and nomination member search MUST continue to fail closed with HTTP 503 when their limiter is unavailable. A confirmed denial MUST remain HTTP 429. This change MUST NOT introduce rate limiting into the separate two-phase digital endpoints.

#### Scenario: Nomination limiter is unavailable
- **WHEN** a nomination endpoint's limiter errors or returns no valid decision
- **THEN** it returns HTTP 503 instead of treating that fault as a rate-limit denial or permission

### Requirement: Make limiter faults diagnosable without leaking election data
An endpoint MUST distinguish a confirmed denial from limiter unavailability in its server-side diagnostic events. A blocked login MUST show a non-sensitive unavailable-limiter message to staff. Diagnostic events MUST NOT include submitted admin secrets, voting or nomination tokens, member names, search terms, or full request bodies. Documentation MUST identify who monitors faults and what action to take during a persistent limiter-only fault versus a broader database outage; it MUST NOT claim proactive notifications exist unless they are configured and tested.

#### Scenario: Repeated login-limiter errors
- **WHEN** login limiter checks repeatedly fail
- **THEN** staff see the distinguishable 503 response, server diagnostics identify limiter unavailability separately from confirmed denials, and the documented escalation procedure directs staff to a named operational role

#### Scenario: Confirmed denial
- **WHEN** the limiter explicitly rejects a burst of requests
- **THEN** the response and sanitized diagnostic classification identify a denial, without labeling it proof of an attack
