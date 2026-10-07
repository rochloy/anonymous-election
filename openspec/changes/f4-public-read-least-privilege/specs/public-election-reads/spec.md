# Spec Delta

## Purpose

Allow anyone to check vote recording and published election information without granting a public request access to the complete ballot, voter, or election-settings tables.

## ADDED Requirements

### Requirement: Public reads have a least-privilege database boundary
The system MUST serve anonymous election status, active candidates, vote verification, and published results through narrowly scoped, read-only database operations. The public database role MUST NOT have direct SELECT access to ballots, candidates, or election settings, nor an operation that returns individual ballot choices or an individual receipt-to-candidate mapping. Token-authenticated voting and administrator functions are outside this capability.

#### Scenario: Direct table access is attempted
- **WHEN** a caller uses the public database role to read any ballot, candidate, or election-settings table directly
- **THEN** no rows, tally, receipt-to-candidate mapping, or settings columns are disclosed

#### Scenario: A caller bypasses the application route
- **WHEN** a caller invokes any public read operation directly through the database API
- **THEN** the same input restrictions, phase gates, and output limits apply as through the application route

#### Scenario: Public read privileges are inspected
- **WHEN** the database roles and callable operation signatures are checked
- **THEN** only the intended F4 read operations are public among the operations introduced by this change, and their owner has no login, write, table-ownership, or RLS-bypass privilege; unrelated previously approved public operations remain governed by their own contracts

#### Scenario: Restricted reader verifies before publication
- **WHEN** a recorded ballot is verified while voting is still open
- **THEN** the restricted read operation can confirm its existence without granting `anon` or `authenticated` direct ballot-table SELECT, and the same reader cannot return the selected candidate

The dedicated read owner MUST have only the needed column-level SELECT privileges, no inherited table-wide SELECT, and a targeted ballot read policy that allows pre-publication existence checks. Publication limits MUST be enforced within the result operation regardless of its ability to inspect ballot rows.

### Requirement: Vote verification does not disclose choices
The system MUST allow verification of an opaque ballot ID and of an accepted digital `VC-` receipt, including while voting is open, without disclosing the candidate selected, a stored receipt, or a raw ballot row. When both inputs are supplied, the system MUST report whether the receipt matches the ballot found by the ID. A paper voter uses the ballot ID printed on the paper ballot; accepting `PB-` receipt codes on this endpoint is NOT part of this change, and no requirement assumes a paper voter receives a `PB-` receipt.

#### Scenario: Ballot ID is recorded
- **WHEN** a caller verifies a recorded ballot ID
- **THEN** the response indicates it was found and returns only the existing channel and cast-date metadata, not the selected candidate or stored receipt

#### Scenario: Accepted receipt is recorded
- **WHEN** a caller verifies a valid recorded `VC-` receipt without a ballot ID
- **THEN** the response indicates the recorded vote and returns the same limited metadata without identifying the selected candidate

#### Scenario: Paired inputs do not match
- **WHEN** a caller supplies a recorded ballot ID and a valid but different `VC-` receipt
- **THEN** the response indicates the ballot ID was found with `receipt_match: false` and does not disclose either vote choice

#### Scenario: Paired inputs include an unknown ballot ID
- **WHEN** a caller supplies an unknown ballot ID together with a valid receipt for another ballot
- **THEN** verification reports `found: false` for the requested ID without falling back to the other ballot or asserting a match

#### Scenario: A lookup is absent or malformed
- **WHEN** a caller supplies a nonexistent ballot ID, malformed or overlong receipt, or a receipt format that is not accepted here
- **THEN** the response returns a bounded negative result without returning a ballot row or candidate choice

### Requirement: Results and receipt existence obey the publication boundary
The system MUST return no candidate tally, total-vote count, or receipt-existence result before the election reaches VOTING_CLOSED or COMPLETED. After publication it SHALL return the established candidate aggregates and, when a receipt is supplied, a found/not-found flag plus a bounded, normalized echo of the caller-provided code for the existing UI; looking up a receipt MUST NOT reveal its candidate or a stored receipt value.

#### Scenario: Voting is still open
- **WHEN** a caller requests results or supplies a receipt while the phase is SETUP, NOMINATION, NOMINATION_CLOSED, or VOTING
- **THEN** the response is unpublished with the phase but no tally, total-vote count, or receipt-existence answer

#### Scenario: Results are published
- **WHEN** a caller requests results in VOTING_CLOSED or COMPLETED
- **THEN** the response includes the current candidate aggregates, total votes, and percentages without exposing individual ballot rows

#### Scenario: Published receipt is checked
- **WHEN** a caller who already holds a recorded digital or paper receipt checks it after publication
- **THEN** the response includes only a receipt-found flag and the bounded normalized code the caller already supplied alongside the published aggregates, without revealing a stored receipt or linking that code to any candidate

#### Scenario: Oversized receipt input is supplied
- **WHEN** a caller supplies a receipt value beyond the public input bound
- **THEN** the request is rejected without looking up ballots or reflecting the oversized value in a response

### Requirement: Public election status and candidates expose fixed projections
The system MUST expose only the currently required phase/dates/nomination options from the election settings and only the currently displayed fields of active candidates. An unrecognized database column MUST NOT become public merely because it was added to a table.

#### Scenario: Election status is requested
- **WHEN** anyone requests public election status
- **THEN** the response contains the existing whitelisted phase, nomination and voting dates, write-in setting, and nominee limit and no other settings columns

#### Scenario: Candidate list is requested
- **WHEN** anyone requests public candidates
- **THEN** only active candidates with the established display fields are returned ordered by their creation time ascending; the ordering timestamp itself need not appear in the public result

### Requirement: Faults cannot masquerade as election facts
The system MUST respond to a database permission failure, missing required settings, malformed database response, or other read error with a generic non-success error. It MUST NOT convert such a fault into a genuine-looking SETUP phase, missing vote, empty candidate list, or published zero-vote tally. Error responses and diagnostics MUST NOT disclose raw database messages or election data.

#### Scenario: Verification storage fails
- **WHEN** the verification database read fails rather than returning a valid negative lookup
- **THEN** the public response is a generic error rather than `found: false`

#### Scenario: Results or status storage fails
- **WHEN** the results, candidate, or election-status database read fails or required settings are missing
- **THEN** the public response is a generic error rather than a plausible unpublished SETUP state or zero-vote result
