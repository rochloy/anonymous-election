# Anonymous Election System

A privacy-first voting system for a 300-member community electing a Committee Head.

## Quick Start

1. **Database**: Run `supabase/schema.sql` then `supabase/seed.sql` in the Supabase SQL Editor.
2. **Env**: Copy `.env.example` to `.env.local` and fill in credentials. Set `ADMIN_SECRET` to a long random string.
3. **Install**: `npm install`
4. **Build**: `npm run build`
5. **Dispatch tokens**: `node scripts/dispatch-tokens.js` (sends magic links to all active members).
6. **Vote**: Members open the link, pick a candidate, get a receipt code.
7. **Close voting**: Update `election_settings.current_phase` to `VOTING_CLOSED`.
8. **Results**: Visit `/results` to see tallies and look up receipts.

## Privacy Model

See `docs/SECURITY.md` for the full honest threat model. **Short version**: anonymous to other voters and the public; the admin has the technical ability to correlate and has committed not to.

## Architecture

Two-domain Supabase schema:
- **Identity domain** (`members`, `tokens`): who is eligible, who has voted.
- **Anonymous domain** (`ballots`, `candidates`): what was voted, receipt codes.

Writes go through `SECURITY DEFINER` RPCs in the `private` schema (not exposed via PostgREST). The service-role key is server-only and never bundled to the client.
