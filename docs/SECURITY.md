# Security & Privacy Model

## Anonymity Guarantee (Honest Statement)

This system guarantees **anonymity against other voters and the public**. It does **not** guarantee anonymity against the administrator.

### What is protected
- One voter cannot see another voter's choice.
- The public cannot see who voted for whom until results are published, and even then only sees aggregated counts + receipt codes (not voter identities).
- The receipt-code lookup lets a voter verify their own vote was counted, without revealing their identity.

### What is NOT protected
The administrator (or anyone holding the `SUPABASE_SERVICE_ROLE_KEY`, or Supabase support staff) has the technical ability to correlate votes to voters via:
1. **Transaction timestamps**: the `submit_anonymous_vote` RPC updates `tokens.used_at` and inserts a `ballots` row in the same transaction. The millisecond-precision `used_at` can be joined to the ballot insertion time.
2. **Query logs**: Supabase's Postgres logs capture RPC parameters (`p_token_hash`, `p_candidate_id`) in plaintext. The `p_token_hash` directly identifies the voter.

### Mitigation commitments
- The administrator has committed, in writing, not to run correlation queries.
- Database query logs are escrowed with a third party and not directly accessible to the admin.
- The `private` schema and `REVOKE EXECUTE FROM anon` prevent direct RPC invocation by non-admin clients.

### If you need stronger anonymity
If the threat model includes a curious or coerced administrator, this architecture is insufficient. Use a blind-signature or mixnet architecture instead, where no single component can link identity to vote.

## Security Controls Implemented
- **Admin route auth**: all `/api/admin/*` routes require `x-admin-secret` header matching `ADMIN_SECRET` env var.
- **Rate limiting**: admin routes limited to 10 req/min per IP.
- **RPC in private schema**: `submit_anonymous_vote` and `submit_paper_vote` are in the `private` schema, not exposed via PostgREST. `REVOKE EXECUTE FROM anon, authenticated`.
- **CSPRNG receipts**: receipt codes generated with `gen_random_bytes` (Postgres CSPRNG) inside the RPC, with 5-attempt retry on collision.
- **Paper tally fix**: paper votes insert a `ballots` row with `channel='PAPER'`, so they enter the canonical tally.
- **No live turnout during voting**: `/api/admin/stats` hides turnout counts while phase is `VOTING` (anti-coercion).
- **Token in URL path**: magic links use `/vote/<token>` not `/vote?token=<token>`, avoiding access-log and Referer leakage.
- **Random member codes**: seed uses random 8-char codes, not sequential `MEM-001`..`MEM-300`.
- **HMAC-signed ballot IDs**: paper ballot IDs include an HMAC signature (`PAPER:<uuid>:<timestamp>:<hmac>`) to prevent forgery.
- **URL-based QR payload**: QR codes encode `${APP_BASE_URL}/verify?ballot_id=<id>` so native phone cameras recognize them as actionable links. The ballot ID is already printed as plain text on the physical ballot, so encoding it in a URL introduces no new exposure. The `/verify` endpoint only queries the anonymous `ballots` table — voter identity is never revealed.
