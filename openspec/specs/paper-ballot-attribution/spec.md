# paper-ballot-attribution Specification

## Purpose
Guarantees that paper-plane actor/attribution columns reference the admin-session plane, so admin attribution of ballot operations is possible without ever confusing an admin identifier for a voter (member) identifier.

## Requirements

### Requirement: Paper actor columns reference admin sessions
Every actor/attribution column on the paper identity plane and its batch table SHALL be foreign-keyed to the admin-session relation with `ON DELETE RESTRICT`, never to the member relation. This covers `checked_in_by`, `spoiled_by`, and `voided_by` on the paper-ballot table (already satisfied by the Wave 6 severance — restated here as the tracked invariant), and `generated_by` on the paper-ballot-batch table (the delta this change lands).

#### Scenario: Actor column accepts an admin session identifier
- **WHEN** an admin session identifier is written to an actor column
- **THEN** the write succeeds and the attribution is recorded

#### Scenario: Actor column rejects a member identifier
- **WHEN** a member identifier that is not an admin session is written to an actor column
- **THEN** the database rejects the write with a foreign-key violation

### Requirement: Attribution columns stay free of voter identity semantics
The system SHALL NOT treat actor columns as member-plane data: they hold admin-session references only, and the core anonymity invariant (no member ↔ ballot co-location) is unaffected because the paper identity plane never gains ballot handles from this change.

#### Scenario: Roster PII purge is unaffected
- **WHEN** purge_roster_pii redacts or anonymizes member rows (an update, never a delete)
- **THEN** no actor column references a member row and the purge proceeds unaffected

#### Scenario: Deleting a referenced admin session is refused
- **WHEN** a DELETE is attempted on an admin_sessions row that an actor column references
- **THEN** the database rejects it (ON DELETE RESTRICT)

#### Scenario: Session revocation is unaffected
- **WHEN** a referenced admin session is revoked (revoked_at set, row retained per the revoke-not-delete lifecycle)
- **THEN** the revocation succeeds and the attribution is preserved
