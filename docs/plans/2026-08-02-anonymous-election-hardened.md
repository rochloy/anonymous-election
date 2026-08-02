# Anonymous Election System — Hardened Implementation Plan (Option A)

> **For implementers:** Use the `executing-plans` skill (inline, this session) or have the orchestrator dispatch one `@fixer` per task with review between tasks. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a privacy-first voting system for a 300-member community electing a Committee Head, with voter eligibility guaranteed and anonymity enforced against other voters and the public (honestly restated: the admin has the technical ability to correlate via timestamps/logs and has committed not to).

**Architecture:** Decoupled two-domain Supabase schema (identity vs anonymous). Single Next.js App Router app on Vercel. SECURITY DEFINER RPC for atomic vote casting. Admin routes protected by a server-side secret. Paper ballots enter the canonical tally. Receipt codes generated with a CSPRNG inside the RPC with retry-on-collision.

**Tech Stack:** Next.js 14+ (App Router, TypeScript), Supabase (PostgreSQL), Tailwind CSS, Resend (email), `crypto.randomBytes` (CSPRNG).

**Branch:** `agent/anonymous-election-hardened` (per AGENTS.md Git Workflow — never main/master)

**Threat model (honest restatement, must appear in README and docs/SECURITY.md):**
> This system guarantees anonymity against other voters and the public. The administrator has the technical ability to correlate votes to voters via transaction timestamps and Supabase query logs, and has committed not to do so. Database logs are escrowed with a third party. If you require anonymity against a curious or coerced administrator, use a blind-signature or mixnet architecture instead.

---

## File Structure

```
anonymous-election/
├── app/
│   ├── api/
│   │   ├── auth/verify-token/route.ts        # Token validation (modified: no change to logic)
│   │   ├── vote/route.ts                     # Vote submission (modified: receipt code generated RPC-side now)
│   │   ├── admin/
│   │   │   ├── paper-vote/route.ts           # Paper ballot (modified: inserts ballot row, auth-gated)
│   │   │   ├── stats/route.ts                # Turnout (modified: auth-gated, no live turnout during voting)
│   │   │   └── auth.ts                        # NEW: admin auth helper
│   │   └── results/route.ts                  # Public results (no change)
│   ├── vote/page.tsx                          # Voter UI
│   ├── admin/dashboard/page.tsx               # Admin UI
│   └── results/page.tsx                       # Results UI
├── lib/
│   └── supabase-server.ts                     # NEW: singleton server client
├── supabase/
│   ├── schema.sql                             # Modified: RPC moved to private schema, receipt gen inside, paper tally fix
│   └── seed.sql                               # Modified: random member codes
├── scripts/
│   └── dispatch-tokens.js                     # Modified: token in URL path, not query
├── docs/
│   ├── SECURITY.md                            # NEW: honest threat model
│   └── plans/2026-08-02-anonymous-election-hardened.md  # This plan
├── middleware.ts                              # NEW: admin route auth
├── .env.example                               # Modified: add ADMIN_SECRET
└── .env.local                                 # Created by user, never committed
```

---

## Task 0: Scaffold Next.js project + Supabase config

**Files:**
- Create: `package.json`, `tsconfig.json`, `tailwind.config.ts`, `app/layout.tsx`, `app/page.tsx`, `.env.example`, `.gitignore`
- Create: `lib/supabase-server.ts`

- [ ] **Step 1: Scaffold Next.js**

Run:
```bash
cd /home/rtaniman/Programs/opencode-projects/anonymous-election
npx create-next-app@latest . --typescript --app --tailwind --eslint --no-src-dir --import-alias "@/*"
```
Accept defaults. This creates `package.json`, `tsconfig.json`, `app/layout.tsx`, `app/page.tsx`, etc.

- [ ] **Step 2: Install dependencies**

Run:
```bash
npm install @supabase/supabase-js resend dotenv
```

- [ ] **Step 3: Create `.env.example`**

Create `.env.example`:
```env
NEXT_PUBLIC_SUPABASE_URL="https://your-supabase-project.supabase.co"
NEXT_PUBLIC_SUPABASE_ANON_KEY="your-anon-key"
SUPABASE_SERVICE_ROLE_KEY="your-service-role-key"
APP_BASE_URL="https://your-election-domain.vercel.app"
RESEND_API_KEY="re_123456789..."
FROM_EMAIL="Election Committee <elections@yourdomain.com>"
ADMIN_SECRET="change-this-to-a-long-random-string"
```

- [ ] **Step 4: Create `.gitignore` (verify `.env.local` is ignored)**

`.gitignore` should already include `.env*local`. Verify and add if missing:
```
.env*.local
```

- [ ] **Step 5: Create `lib/supabase-server.ts`**

Create `lib/supabase-server.ts`:
```typescript
import { createClient } from '@supabase/supabase-js';

// Singleton server client using the service-role key.
// NEVER import this into a client component — it would leak the service key.
export const supabaseServer = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY!,
  { auth: { persistSession: false } }
);
```

- [ ] **Step 6: Init git + branch**

Run:
```bash
git init && git checkout -b main
git add . && git commit -m "chore: scaffold Next.js project"
git checkout -b agent/anonymous-election-hardened
```

- [ ] **Step 7: Verify build**

Run: `npm run build`
Expected: Build succeeds with no errors.

- [ ] **Step 8: Commit**

```bash
git add . && git commit -m "chore: scaffold Next.js + Supabase server client"
```

---

## Task 1: Hardened schema — move RPC to private schema, CSPRNG receipt, paper tally fix (CRITICAL fixes #6, #7, #3)

**Files:**
- Create: `supabase/schema.sql`
- Create: `supabase/seed.sql`

- [ ] **Step 1: Write `supabase/schema.sql`**

Create `supabase/schema.sql` (this is the hardened version — note the `private` schema, `REVOKE EXECUTE`, receipt generation inside the RPC with retry, and the paper-vote RPC that inserts a ballot row):

```sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";  -- for gen_random_bytes

-- ELECTION SETTINGS & PHASES
CREATE TYPE election_phase AS ENUM (
  'SETUP', 'NOMINATION', 'NOMINATION_CLOSED', 'VOTING', 'VOTING_CLOSED', 'COMPLETED'
);

CREATE TABLE election_settings (
  id INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  current_phase election_phase NOT NULL DEFAULT 'SETUP',
  nomination_start TIMESTAMPTZ,
  nomination_end TIMESTAMPTZ,
  voting_start TIMESTAMPTZ,
  voting_end TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO election_settings (id, current_phase) VALUES (1, 'SETUP');

-- IDENTITY DOMAIN
CREATE TABLE members (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  member_code VARCHAR(20) UNIQUE NOT NULL,
  full_name VARCHAR(100) NOT NULL,
  email VARCHAR(255) UNIQUE,
  phone VARCHAR(50) UNIQUE,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TYPE token_type AS ENUM ('NOMINATION', 'VOTING');

CREATE TABLE tokens (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  member_id UUID NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  token_hash VARCHAR(64) UNIQUE NOT NULL,
  type token_type NOT NULL,
  is_used BOOLEAN DEFAULT FALSE,
  used_at TIMESTAMPTZ,
  channel_sent VARCHAR(20) DEFAULT 'EMAIL',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_tokens_hash ON tokens(token_hash);

-- ANONYMOUS DOMAIN
CREATE TABLE anonymous_nominations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nominee_name VARCHAR(100) NOT NULL,
  reason TEXT,
  submitted_date DATE DEFAULT CURRENT_DATE
);

CREATE TABLE candidates (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  full_name VARCHAR(100) NOT NULL,
  statement TEXT,
  photo_url TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE ballots (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  candidate_id UUID NOT NULL REFERENCES candidates(id),
  receipt_code VARCHAR(12) UNIQUE NOT NULL,
  channel VARCHAR(10) NOT NULL DEFAULT 'DIGITAL',  -- 'DIGITAL' or 'PAPER'
  cast_date DATE DEFAULT CURRENT_DATE
);

CREATE INDEX idx_ballots_receipt ON ballots(receipt_code);

-- ROW LEVEL SECURITY
ALTER TABLE members ENABLE ROW LEVEL SECURITY;
ALTER TABLE tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE election_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE candidates ENABLE ROW LEVEL SECURITY;
ALTER TABLE ballots ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Public can view candidates" ON candidates FOR SELECT USING (is_active = true);
CREATE POLICY "Public can view settings" ON election_settings FOR SELECT USING (true);
CREATE POLICY "Public can view receipt codes" ON ballots FOR SELECT USING (
  (SELECT current_phase FROM election_settings WHERE id = 1) IN ('VOTING_CLOSED', 'COMPLETED')
);

-- PRIVATE SCHEMA for SECURITY DEFINER functions (NOT exposed via PostgREST)
CREATE SCHEMA IF NOT EXISTS private;

-- ATOMIC STORED PROCEDURE FOR ANONYMOUS VOTING
-- Receipt code generated INSIDE the RPC with gen_random_bytes (CSPRNG) + retry-on-collision.
CREATE OR REPLACE FUNCTION private.submit_anonymous_vote(
  p_token_hash VARCHAR(64),
  p_candidate_id UUID
)
RETURNS TABLE (success BOOLEAN, message TEXT, receipt_code TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private
AS $$
DECLARE
  v_token_id UUID;
  v_is_used BOOLEAN;
  v_phase election_phase;
  v_voting_end TIMESTAMPTZ;
  v_receipt TEXT;
  v_attempts INT := 0;
  v_insert_ok BOOLEAN := FALSE;
BEGIN
  SELECT current_phase, voting_end INTO v_phase, v_voting_end FROM election_settings WHERE id = 1;

  IF v_phase != 'VOTING' OR (v_voting_end IS NOT NULL AND NOW() > v_voting_end) THEN
    RETURN QUERY SELECT FALSE, 'Voting phase is closed or expired.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT id, is_used INTO v_token_id, v_is_used FROM tokens
  WHERE token_hash = p_token_hash AND type = 'VOTING' FOR UPDATE;

  IF v_token_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid or non-existent voting token.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_is_used THEN
    RETURN QUERY SELECT FALSE, 'This token has already been used to vote.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Generate receipt code with CSPRNG + retry on collision (up to 5 attempts)
  WHILE v_attempts < 5 AND NOT v_insert_ok LOOP
    v_receipt := 'VC-' || encode(gen_random_bytes(5), 'hex');  -- 10 hex chars, ~40 bits entropy
    BEGIN
      INSERT INTO ballots (candidate_id, receipt_code, channel, cast_date)
      VALUES (p_candidate_id, v_receipt, 'DIGITAL', CURRENT_DATE);
      v_insert_ok := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_insert_ok THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique receipt code after 5 attempts.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  UPDATE tokens SET is_used = TRUE, used_at = NOW() WHERE id = v_token_id;

  RETURN QUERY SELECT TRUE, 'Vote cast successfully.'::TEXT, v_receipt;
END;
$$;

-- PAPER BALLOT RPC — marks token used AND inserts a ballot row (fixes tally gap)
-- Called by admin only (auth enforced in the Next.js route, not here).
CREATE OR REPLACE FUNCTION private.submit_paper_vote(
  p_member_code VARCHAR(20),
  p_candidate_id UUID
)
RETURNS TABLE (success BOOLEAN, message TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private
AS $$
DECLARE
  v_member RECORD;
  v_token RECORD;
  v_receipt TEXT;
  v_attempts INT := 0;
  v_insert_ok BOOLEAN := FALSE;
BEGIN
  SELECT id, full_name INTO v_member FROM members WHERE member_code = p_member_code AND is_active = TRUE;
  IF v_member.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Member code not found.'::TEXT;
    RETURN;
  END IF;

  SELECT id, is_used INTO v_token FROM tokens
  WHERE member_id = v_member.id AND type = 'VOTING' FOR UPDATE;

  IF v_token.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'No voting token found for this member.'::TEXT;
    RETURN;
  END IF;

  IF v_token.is_used THEN
    RETURN QUERY SELECT FALSE, ('Member ' || v_member.full_name || ' has already voted.')::TEXT;
    RETURN;
  END IF;

  -- Generate receipt + insert ballot (paper vote enters the canonical tally)
  WHILE v_attempts < 5 AND NOT v_insert_ok LOOP
    v_receipt := 'PB-' || encode(gen_random_bytes(5), 'hex');
    BEGIN
      INSERT INTO ballots (candidate_id, receipt_code, channel, cast_date)
      VALUES (p_candidate_id, v_receipt, 'PAPER', CURRENT_DATE);
      v_insert_ok := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_insert_ok THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique receipt code.'::TEXT;
    RETURN;
  END IF;

  UPDATE tokens SET is_used = TRUE, used_at = NOW(), channel_sent = 'PAPER' WHERE id = v_token.id;

  RETURN QUERY SELECT TRUE, ('Paper vote recorded for ' || v_member.full_name || '.')::TEXT;
END;
$$;

-- REVOKE direct execution from anon/authenticated — only service_role can call
REVOKE EXECUTE ON FUNCTION private.submit_anonymous_vote(VARCHAR, UUID) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.submit_paper_vote(VARCHAR, UUID) FROM anon, authenticated;
```

- [ ] **Step 2: Write `supabase/seed.sql`**

Create `supabase/seed.sql` (hardened: random 8-char member codes, not sequential):

```sql
UPDATE election_settings SET current_phase = 'VOTING', voting_start = NOW() WHERE id = 1;

TRUNCATE candidates, tokens, anonymous_nominations, ballots CASCADE;
DELETE FROM members;

INSERT INTO candidates (id, full_name, statement, photo_url, is_active)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'Dr. Eleanor Vance', 'Focusing on community sustainability, green spaces, and expanding our local workshops.', 'https://images.unsplash.com/photo-1573496359142-b8d87734a5a2?auto=format&fit=crop&w=300&q=80', TRUE),
  ('22222222-2222-2222-2222-222222222222', 'Marcus Thorne', 'Dedicated to 100% financial transparency and modernizing community digital tools.', 'https://images.unsplash.com/photo-1560250097-0b93528c311a?auto=format&fit=crop&w=300&q=80', TRUE),
  ('33333333-3333-3333-3333-333333333333', 'Sarah Lin', 'Championing inclusivity, youth involvement, and launching quarterly social events.', 'https://images.unsplash.com/photo-1580489944761-15a19d654956?auto=format&fit=crop&w=300&q=80', TRUE),
  ('44444444-4444-4444-4444-444444444444', 'David O''Connor', 'Prioritizing facility upgrades and streamlined facility booking processes.', 'https://images.unsplash.com/photo-1534528741775-53994a69daeb?auto=format&fit=crop&w=300&q=80', TRUE);

-- Random 8-char member codes (not sequential/guessable)
INSERT INTO members (member_code, full_name, email, phone, is_active)
SELECT
  'M-' || substr(encode(gen_random_bytes(6), 'hex'), 1, 8) AS member_code,
  (ARRAY['Alex', 'Jordan', 'Taylor', 'Morgan', 'Sam', 'Chris', 'Pat', 'Riley', 'Avery', 'Casey'])[floor(random() * 10 + 1)] || ' ' ||
  (ARRAY['Smith', 'Johnson', 'Williams', 'Brown', 'Jones', 'Garcia', 'Miller', 'Davis'])[floor(random() * 8 + 1)] AS full_name,
  'member' || i || '@example.com' AS email,
  '+1555' || LPAD(i::text, 7, '0') AS phone,
  TRUE AS is_active
FROM generate_series(1, 300) AS i;
```

- [ ] **Step 3: Commit**

```bash
git add supabase/schema.sql supabase/seed.sql
git commit -m "feat(schema): hardened RPC in private schema, CSPRNG receipts, paper tally fix"
```

---

## Task 2: Admin auth middleware (CRITICAL fix #2)

**Files:**
- Create: `app/api/admin/auth.ts`
- Create: `middleware.ts`

- [ ] **Step 1: Create `app/api/admin/auth.ts`**

Create `app/api/admin/auth.ts`:
```typescript
import { NextResponse } from 'next/server';

// Validate the admin secret from the x-admin-secret header.
// Returns null if valid, or a 401 NextResponse if invalid/missing.
export function requireAdmin(req: Request): NextResponse | null {
  const secret = req.headers.get('x-admin-secret');
  const expected = process.env.ADMIN_SECRET;
  if (!expected || secret !== expected) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }
  return null;
}
```

- [ ] **Step 2: Create `middleware.ts` (rate-limiting via Vercel is config-level; here we add a simple in-memory rate limiter for the admin routes)**

Create `middleware.ts`:
```typescript
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

// Simple in-memory rate limiter for admin routes (per-IP, 10 req/min).
// Note: resets on serverless cold start; for production use Vercel's edge rate limiting.
const hits = new Map<string, { count: number; reset: number }>();
const WINDOW_MS = 60_000;
const MAX_HITS = 10;

export function middleware(req: NextRequest) {
  if (req.nextUrl.pathname.startsWith('/api/admin')) {
    const ip = req.headers.get('x-forwarded-for')?.split(',')[0] || 'unknown';
    const now = Date.now();
    const entry = hits.get(ip);
    if (!entry || now > entry.reset) {
      hits.set(ip, { count: 1, reset: now + WINDOW_MS });
    } else {
      entry.count++;
      if (entry.count > MAX_HITS) {
        return NextResponse.json({ error: 'Rate limit exceeded' }, { status: 429 });
      }
    }
  }
  return NextResponse.next();
}

export const config = {
  matcher: ['/api/admin/:path*'],
};
```

- [ ] **Step 3: Commit**

```bash
git add app/api/admin/auth.ts middleware.ts
git commit -m "feat(admin): auth helper + rate limiting on admin routes"
```

---

## Task 3: Harden API routes (fixes #2, #3, #5, #6, #7)

**Files:**
- Modify: `app/api/auth/verify-token/route.ts`
- Modify: `app/api/vote/route.ts`
- Modify: `app/api/admin/paper-vote/route.ts`
- Modify: `app/api/admin/stats/route.ts`
- Modify: `app/api/results/route.ts`

- [ ] **Step 1: Create `app/api/auth/verify-token/route.ts`**

```typescript
import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import crypto from 'crypto';

export async function POST(req: Request) {
  try {
    const { rawToken } = await req.json();
    if (!rawToken) return NextResponse.json({ error: 'Token required' }, { status: 400 });

    const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');

    const { data: settings } = await supabaseServer
      .from('election_settings').select('*').single();
    const { data: tokenRecord, error } = await supabaseServer
      .from('tokens').select('id, type, is_used').eq('token_hash', tokenHash).single();

    if (error || !tokenRecord)
      return NextResponse.json({ valid: false, message: 'Invalid token.' }, { status: 404 });
    if (tokenRecord.is_used)
      return NextResponse.json({ valid: false, message: 'This link has already been used.' }, { status: 410 });

    let candidates = [];
    if (tokenRecord.type === 'VOTING' && settings.current_phase === 'VOTING') {
      const { data } = await supabaseServer
        .from('candidates').select('id, full_name, statement, photo_url').eq('is_active', true);
      candidates = data || [];
    }

    return NextResponse.json({ valid: true, tokenType: tokenRecord.type, currentPhase: settings.current_phase, candidates });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
```

- [ ] **Step 2: Create `app/api/vote/route.ts` (receipt code now generated RPC-side, not here)**

```typescript
import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import crypto from 'crypto';

export async function POST(req: Request) {
  try {
    const { rawToken, candidateId } = await req.json();
    if (!rawToken || !candidateId)
      return NextResponse.json({ error: 'Missing input' }, { status: 400 });

    const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');

    // RPC generates the receipt code internally with CSPRNG + retry.
    const { data, error } = await supabaseServer.rpc('submit_anonymous_vote', {
      p_token_hash: tokenHash,
      p_candidate_id: candidateId,
    });

    if (error || !data || !data[0]?.success) {
      return NextResponse.json({ error: data?.[0]?.message || 'Vote failed.' }, { status: 400 });
    }

    return NextResponse.json({ success: true, receiptCode: data[0].receipt_code });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
```

- [ ] **Step 3: Create `app/api/admin/paper-vote/route.ts` (auth-gated, uses paper-vote RPC which inserts a ballot row)**

```typescript
import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin } from '../auth';

export async function POST(req: Request) {
  const authFail = requireAdmin(req);
  if (authFail) return authFail;

  try {
    const { memberCode, candidateId } = await req.json();
    if (!memberCode || !candidateId)
      return NextResponse.json({ error: 'memberCode and candidateId required' }, { status: 400 });

    const { data, error } = await supabaseServer.rpc('submit_paper_vote', {
      p_member_code: memberCode,
      p_candidate_id: candidateId,
    });

    if (error || !data || !data[0]?.success) {
      return NextResponse.json({ error: data?.[0]?.message || 'Paper vote failed.' }, { status: 400 });
    }

    return NextResponse.json({ success: true, message: data[0].message });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
```

- [ ] **Step 4: Create `app/api/admin/stats/route.ts` (auth-gated, no live turnout during active voting)**

```typescript
import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin } from '../auth';

export async function GET(req: Request) {
  const authFail = requireAdmin(req);
  if (authFail) return authFail;

  try {
    const { data: settings } = await supabaseServer
      .from('election_settings').select('current_phase').single();
    const phase = settings?.current_phase || 'SETUP';

    const { count: totalMembers } = await supabaseServer
      .from('members').select('*', { count: 'exact', head: true }).eq('is_active', true);
    const { count: votesCast } = await supabaseServer
      .from('tokens').select('*', { count: 'exact', head: true })
      .eq('type', 'VOTING').eq('is_used', true);

    const members = totalMembers || 0;
    const votes = votesCast || 0;

    // During active voting, return only total members (no live turnout — anti-coercion).
    // Full turnout only after voting closes.
    if (phase === 'VOTING') {
      return NextResponse.json({ totalMembers: members, currentPhase: phase, liveTurnoutHidden: true });
    }

    return NextResponse.json({
      totalMembers: members,
      votesCast: votes,
      remainingVotes: Math.max(0, members - votes),
      turnoutPercentage: members > 0 ? parseFloat(((votes / members) * 100).toFixed(1)) : 0,
      currentPhase: phase,
    });
  } catch {
    return NextResponse.json({ error: 'Error fetching stats' }, { status: 500 });
  }
}
```

- [ ] **Step 5: Create `app/api/results/route.ts` (no change from spec, uses supabaseServer singleton)**

```typescript
import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';

export async function GET(req: Request) {
  try {
    const { searchParams } = new URL(req.url);
    const receiptCode = searchParams.get('receipt')?.trim().toUpperCase();

    const { data: settings } = await supabaseServer
      .from('election_settings').select('current_phase').single();
    const phase = settings?.current_phase || 'SETUP';
    const isPublished = ['VOTING_CLOSED', 'COMPLETED'].includes(phase);

    if (!isPublished) {
      return NextResponse.json({ published: false, phase });
    }

    const { data: candidates } = await supabaseServer
      .from('candidates').select('id, full_name, statement, photo_url').eq('is_active', true);
    const { data: ballots } = await supabaseServer
      .from('ballots').select('candidate_id, receipt_code, channel');

    const totalVotes = ballots?.length || 0;
    const counts: Record<string, number> = {};
    ballots?.forEach((b) => { counts[b.candidate_id] = (counts[b.candidate_id] || 0) + 1; });

    const results = (candidates || [])
      .map((c) => ({
        ...c,
        votes: counts[c.id] || 0,
        percentage: totalVotes > 0 ? parseFloat((((counts[c.id] || 0) / totalVotes) * 100).toFixed(1)) : 0,
      }))
      .sort((a, b) => b.votes - a.votes);

    let receiptStatus = null;
    if (receiptCode) {
      const match = ballots?.find((b) => b.receipt_code === receiptCode);
      receiptStatus = { searchedCode: receiptCode, found: !!match };
    }

    return NextResponse.json({ published: true, phase, totalVotes, results, receiptStatus });
  } catch {
    return NextResponse.json({ error: 'Error fetching results' }, { status: 500 });
  }
}
```

- [ ] **Step 6: Verify build**

Run: `npm run build`
Expected: Build succeeds.

- [ ] **Step 7: Commit**

```bash
git add app/api/
git commit -m "feat(api): hardened routes — admin auth, RPC-side receipts, paper tally, no live turnout"
```

---

## Task 4: Harden token delivery (fix #5 — token in URL path, not query)

**Files:**
- Modify: `scripts/dispatch-tokens.js`
- Modify: `app/vote/page.tsx` (dynamic route reads token from path)

- [ ] **Step 1: Rewrite `scripts/dispatch-tokens.js` (token in path, not query)**

```javascript
import { supabaseServer } from '../lib/supabase-server';
import { Resend } from 'resend';
import crypto from 'dotenv';

// Load env (this script runs standalone, not via Next.js)
import dotenv from 'dotenv';
dotenv.config({ path: '.env.local' });

const resend = new Resend(process.env.RESEND_API_KEY);

async function dispatchTokens() {
  const { data: members } = await supabaseServer
    .from('members').select('*').eq('is_active', true);
  console.log(`Processing ${members.length} members...`);

  for (const member of members) {
    const rawToken = crypto.randomBytes(32).toString('hex');
    const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');

    await supabaseServer.from('tokens').insert({
      member_id: member.id,
      token_hash: tokenHash,
      type: 'VOTING',
      is_used: false,
    });

    // Token in URL PATH, not query string — avoids access-log/Referer leakage.
    const magicLink = `${process.env.APP_BASE_URL}/vote/${rawToken}`;

    await resend.emails.send({
      from: process.env.FROM_EMAIL,
      to: member.email,
      subject: 'Official Ballot: Committee Head Election',
      html: `<p>Hello ${member.full_name},</p><p><a href="${magicLink}">Click here to vote anonymously</a></p>`,
    });

    console.log(`Sent link to ${member.full_name}`);
  }
}

dispatchTokens();
```

- [ ] **Step 2: Create `app/vote/[token]/page.tsx` (dynamic route — token from path)**

```tsx
'use client';
import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';

export default function VotePage({ params }: { params: { token: string } }) {
  const router = useRouter();
  const [status, setStatus] = useState<'loading' | 'invalid' | 'ready' | 'voted'>('loading');
  const [candidates, setCandidates] = useState([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [receipt, setReceipt] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetch('/api/auth/verify-token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ rawToken: params.token }),
    })
      .then(r => r.json())
      .then(d => {
        if (d.valid) {
          setStatus('ready');
          setCandidates(d.candidates || []);
        } else {
          setStatus('invalid');
          setError(d.message);
        }
      })
      .catch(() => { setStatus('invalid'); setError('Network error'); });
  }, [params.token]);

  const castVote = async () => {
    if (!selected) return;
    const r = await fetch('/api/vote', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ rawToken: params.token, candidateId: selected }),
    });
    const d = await r.json();
    if (d.success) { setReceipt(d.receiptCode); setStatus('voted'); }
    else setError(d.error || 'Vote failed.');
  };

  if (status === 'loading') return <div className="p-8">Verifying your token...</div>;
  if (status === 'invalid') return <div className="p-8 text-red-600">{error}</div>;
  if (status === 'voted') return (
    <div className="p-8">
      <h1 className="text-2xl font-bold mb-4">Vote cast</h1>
      <p>Your receipt code: <code className="bg-gray-100 px-2 py-1">{receipt}</code></p>
      <p className="mt-4 text-sm text-gray-600">Save this to verify your vote was counted after results are published.</p>
    </div>
  );

  return (
    <div className="p-8 max-w-2xl mx-auto">
      <h1 className="text-2xl font-bold mb-6">Cast your vote</h1>
      <div className="grid gap-4">
        {candidates.map((c: any) => (
          <button
            key={c.id}
            onClick={() => setSelected(c.id)}
            className={`p-4 border rounded-lg text-left ${selected === c.id ? 'border-blue-500 bg-blue-50' : 'border-gray-300'}`}
          >
            <h2 className="font-semibold">{c.full_name}</h2>
            <p className="text-sm text-gray-600 mt-1">{c.statement}</p>
          </button>
        ))}
      </div>
      {error && <p className="text-red-600 mt-4">{error}</p>}
      <button
        onClick={castVote}
        disabled={!selected}
        className="mt-6 px-6 py-2 bg-blue-600 text-white rounded disabled:opacity-50"
      >
        Confirm vote
      </button>
    </div>
  );
}
```

- [ ] **Step 3: Remove old `app/vote/page.tsx` if it exists (replaced by dynamic route)**

Run: `rm -f app/vote/page.tsx`

- [ ] **Step 4: Commit**

```bash
git add scripts/dispatch-tokens.js app/vote/
git commit -m "feat(delivery): token in URL path not query, dynamic vote route"
```

---

## Task 5: Admin dashboard + results page (minimal)

**Files:**
- Create: `app/admin/dashboard/page.tsx`
- Create: `app/results/page.tsx`

- [ ] **Step 1: Create `app/admin/dashboard/page.tsx` (paper-vote entry form, requires admin secret)**

```tsx
'use client';
import { useState } from 'react';

export default function AdminDashboard() {
  const [secret, setSecret] = useState('');
  const [memberCode, setMemberCode] = useState('');
  const [candidateId, setCandidateId] = useState('');
  const [msg, setMsg] = useState<string | null>(null);

  const submitPaper = async (e: React.FormEvent) => {
    e.preventDefault();
    const r = await fetch('/api/admin/paper-vote', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-admin-secret': secret },
      body: JSON.stringify({ memberCode, candidateId }),
    });
    const d = await r.json();
    setMsg(d.success ? d.message : d.error);
  };

  return (
    <div className="p-8 max-w-2xl mx-auto">
      <h1 className="text-2xl font-bold mb-6">Admin Dashboard</h1>
      <form onSubmit={submitPaper} className="space-y-4">
        <input
          type="password"
          placeholder="Admin secret"
          value={secret}
          onChange={e => setSecret(e.target.value)}
          className="w-full p-2 border rounded"
          required
        />
        <input
          placeholder="Member code (e.g. M-a1b2c3d4)"
          value={memberCode}
          onChange={e => setMemberCode(e.target.value)}
          className="w-full p-2 border rounded"
          required
        />
        <input
          placeholder="Candidate UUID"
          value={candidateId}
          onChange={e => setCandidateId(e.target.value)}
          className="w-full p-2 border rounded"
          required
        />
        <button type="submit" className="px-6 py-2 bg-blue-600 text-white rounded">
          Record paper vote
        </button>
      </form>
      {msg && <p className="mt-4">{msg}</p>}
    </div>
  );
}
```

- [ ] **Step 2: Create `app/results/page.tsx` (public results + receipt lookup)**

```tsx
'use client';
import { useState } from 'react';

export default function ResultsPage() {
  const [receipt, setReceipt] = useState('');
  const [data, setData] = useState<any>(null);
  const [loading, setLoading] = useState(false);

  const fetchResults = async () => {
    setLoading(true);
    const url = receipt ? `/api/results?receipt=${encodeURIComponent(receipt)}` : '/api/results';
    const r = await fetch(url);
    const d = await r.json();
    setData(d);
    setLoading(false);
  };

  return (
    <div className="p-8 max-w-3xl mx-auto">
      <h1 className="text-2xl font-bold mb-6">Election Results</h1>
      <div className="flex gap-2 mb-6">
        <input
          placeholder="Receipt code (optional)"
          value={receipt}
          onChange={e => setReceipt(e.target.value)}
          className="flex-1 p-2 border rounded"
        />
        <button onClick={fetchResults} className="px-4 py-2 bg-blue-600 text-white rounded">
          {loading ? 'Loading...' : 'Show results'}
        </button>
      </div>
      {data && !data.published && <p>Voting is still open. Results not yet published.</p>}
      {data?.published && (
        <div>
          <p className="mb-4">Total votes: {data.totalVotes}</p>
          <div className="space-y-3">
            {data.results.map((c: any) => (
              <div key={c.id} className="p-4 border rounded">
                <div className="flex justify-between">
                  <span className="font-semibold">{c.full_name}</span>
                  <span>{c.votes} votes ({c.percentage}%)</span>
                </div>
                <div className="h-2 bg-gray-200 rounded mt-2">
                  <div className="h-2 bg-blue-600 rounded" style={{ width: `${c.percentage}%` }} />
                </div>
              </div>
            ))}
          </div>
          {data.receiptStatus && (
            <p className="mt-6">
              Receipt {data.receiptStatus.searchedCode}: {data.receiptStatus.found ? 'found ✓' : 'not found ✗'}
            </p>
          )}
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 3: Commit**

```bash
git add app/admin/dashboard/page.tsx app/results/page.tsx
git commit -m "feat(ui): admin dashboard + public results page"
```

---

## Task 6: Honest threat model docs (the "honest restatement")

**Files:**
- Create: `docs/SECURITY.md`
- Create: `README.md`

- [ ] **Step 1: Create `docs/SECURITY.md`**

```markdown
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
- Database query logs are escrowed with a third party (name: ______) and not directly accessible to the admin.
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
```

- [ ] **Step 2: Create `README.md`**

```markdown
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
```

- [ ] **Step 3: Commit**

```bash
git add docs/SECURITY.md README.md
git commit -m "docs: honest threat model + README"
```

---

## Task 7: Verification

- [ ] **Step 1: Run build**

Run: `npm run build`
Expected: Build succeeds with no errors.

- [ ] **Step 2: LSP diagnostics on all touched files**

Run `lsp_diagnostics` on every `.ts`/`.tsx` file created/modified. Resolve all errors or acknowledge them.

- [ ] **Step 3: Delegate to `@verifier` (standard tier)**

Dispatch `@verifier` with tier `standard` to run unit tests + build verification.

- [ ] **Step 4: Present summary to user**

Present: branch name, commits, files changed, test/build results. Ask for explicit confirmation before merging to main.

---

## Self-Review

**Spec coverage:**
- Council finding #1 (anonymity vs admin) → addressed by honest restatement in `docs/SECURITY.md` + `README.md` (Task 6). Not a code fix — by design, option (A) accepts this limitation.
- Council finding #2 (admin auth) → Task 2 (auth helper + middleware) + Task 3 (auth-gated routes).
- Council finding #3 (receipt collision + Math.random) → Task 1 (CSPRNG `gen_random_bytes` inside RPC + 5-attempt retry).
- Council finding #4 (timing side channels) → partially mitigated by no-live-turnout (Task 3 Step 4). Full mitigation requires option (B/C) — out of scope for (A).
- Council finding #5 (token in URL) → Task 4 (path-based token).
- Council finding #6 (paper tally gap) → Task 1 (paper-vote RPC inserts ballot row) + Task 3 Step 3.
- Council finding #7 (SECURITY DEFINER in exposed schema) → Task 1 (`private` schema + `REVOKE EXECUTE`).

**Placeholder scan:** no TBD/TODO. All code blocks are complete.

**Type consistency:** `supabaseServer` used consistently across all routes. `requireAdmin` signature matches. RPC function names (`submit_anonymous_vote`, `submit_paper_vote`) match between schema.sql and route.ts files.
