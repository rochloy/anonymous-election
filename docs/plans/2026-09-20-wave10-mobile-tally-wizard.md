# Wave 10 — Mobile Tally Wizard Implementation Plan

> **For implementers:** Use the `executing-plans` skill (inline, this session) or have the orchestrator dispatch one `@fixer` per task with review between tasks. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a phone-first admin wizard for the physical count and check-in with three modes (Record / Spoil / Check-in) at `/admin/tally`.

**Architecture:** Single page with login gate, session countdown, and segmented mode switcher. Each mode has its own state machine (IDLE → action → CONFIRMING → SUCCESS/ERROR → auto-clear → IDLE). All existing API routes are reused — no new backend work.

**Tech Stack:** Next.js 16 App Router, TypeScript, Tailwind CSS v4, html5-qrcode (already installed), existing Supabase RPCs.

**Branch:** `agent/wave10-mobile-tally`

**Wireframe:** `docs/plans/2026-09-20-wave10-mobile-tally-wizard-wireframe.md` (approved)

---

## Existing Infrastructure (no changes needed)

| What | Where | Status |
|---|---|---|
| Login with `scope: 'mobile'` | `app/api/admin/login/route.ts:21,38-40` | ✅ Already works |
| Mobile session TTL (12min absolute) | `app/api/admin/login/route.ts:10,40` | ✅ Already works |
| Auth validation (mobile = no idle bump) | `app/api/admin/auth.ts:76-82` | ✅ Already works |
| CSRF double-submit pattern | `app/api/admin/auth.ts:104-118` | ✅ Already works |
| Logout (this device) | `app/api/admin/logout/route.ts` | ✅ Already works |
| Revoke all sessions | `app/api/admin/sessions/revoke-all/route.ts` | ✅ Already works |
| Candidates list | `app/api/candidates/route.ts` | ✅ Public, no auth |
| Member search | `app/api/admin/members/route.ts` | ✅ `?q=<query>`, rate-limited |
| Record vote | `app/api/admin/paper-vote/route.ts` | ✅ `{ ballotId, candidateId }` |
| Spoil ballot | `app/api/admin/paper-invalid/route.ts` | ✅ `{ ballotId, reason }` |
| Check-in member | `app/api/admin/paper-ballot/route.ts` | ✅ `{ memberId }` |
| QR scanner | `html5-qrcode` package | ✅ Already installed |
| `extractBallotId()` | `app/admin/dashboard/page.tsx:88-97` | ✅ Reuse pattern |

---

## File Structure

| File | Responsibility |
|---|---|
| `app/admin/tally/page.tsx` | Main page: login gate, session management, mode switcher, renders active mode |
| `components/tally/QrScanner.tsx` | Reusable html5-qrcode wrapper (camera viewfinder + auto-capture) |
| `components/tally/RecordMode.tsx` | Record mode: scan → candidate picker → confirm → receipt |
| `components/tally/SpoilMode.tsx` | Spoil mode: scan → reason input → confirm → voided |
| `components/tally/CheckinMode.tsx` | Check-in mode: search → select → confirm → slip code |

---

## Task 1: Create branch + page scaffold

**Files:**
- Create: `app/admin/tally/page.tsx`

- [ ] **Step 1: Create branch**

```bash
cd ~/Programs/opencode-projects/anonymous-election
git checkout -b agent/wave10-mobile-tally
```

- [ ] **Step 2: Create `app/admin/tally/page.tsx` scaffold**

```tsx
'use client';

import { useState, useEffect, useCallback, useRef } from 'react';

type Mode = 'record' | 'spoil' | 'checkin';

export default function TallyPage() {
  const [secret, setSecret] = useState('');
  const [loggedIn, setLoggedIn] = useState(false);
  const [csrfToken, setCsrfToken] = useState('');
  const [expiresAt, setExpiresAt] = useState<number>(0);
  const [mode, setMode] = useState<Mode>('record');
  const [loginError, setLoginError] = useState('');
  const [loggingIn, setLoggingIn] = useState(false);

  // TODO: session countdown, login handler, mode switcher, mode rendering

  if (!loggedIn) {
    return (
      <div className="min-h-screen bg-gray-50 flex items-center justify-center p-4">
        <div className="w-full max-w-sm bg-white rounded-2xl shadow-lg p-6">
          <h1 className="text-xl font-bold text-center mb-1">Election Tally</h1>
          <p className="text-sm text-gray-500 text-center mb-6">Admin tool — phone optimized</p>
          <form onSubmit={handleLogin}>
            <input
              type="password"
              value={secret}
              onChange={(e) => setSecret(e.target.value)}
              placeholder="Admin secret"
              className="w-full border border-gray-300 rounded-lg px-4 py-3 mb-3 text-base"
              autoFocus
            />
            {loginError && <p className="text-red-600 text-sm mb-3">{loginError}</p>}
            <button
              type="submit"
              disabled={loggingIn || !secret}
              className="w-full bg-blue-600 text-white font-semibold rounded-lg px-4 py-3 text-base disabled:opacity-50"
            >
              {loggingIn ? 'Logging in…' : 'Log in'}
            </button>
          </form>
          <p className="text-xs text-gray-400 text-center mt-4">Session: 12 min, auto-logout</p>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gray-50">
      {/* Top bar */}
      <div className="sticky top-0 z-30 bg-white border-b border-gray-200 px-4 py-3 flex items-center justify-between">
        <span className="font-bold text-lg">Tally</span>
        <div className="flex items-center gap-3">
          <SessionCountdown expiresAt={expiresAt} onExpire={handleLogout} />
          <LogoutMenu onLogout={handleLogout} onLogoutAll={handleLogoutAll} />
        </div>
      </div>

      {/* Mode switcher */}
      <div className="sticky top-[53px] z-20 bg-white border-b border-gray-200 px-4 py-2">
        <div className="flex rounded-lg bg-gray-100 p-1">
          {(['record', 'spoil', 'checkin'] as Mode[]).map((m) => (
            <button
              key={m}
              onClick={() => setMode(m)}
              className={`flex-1 py-2 text-sm font-medium rounded-md transition-colors ${
                mode === m ? 'bg-white shadow text-gray-900' : 'text-gray-500'
              }`}
            >
              {m === 'record' ? 'Record' : m === 'spoil' ? 'Spoil' : 'Check-in'}
            </button>
          ))}
        </div>
      </div>

      {/* Active mode */}
      <div className="p-4">
        {mode === 'record' && <RecordMode csrfToken={csrfToken} />}
        {mode === 'spoil' && <SpoilMode csrfToken={csrfToken} />}
        {mode === 'checkin' && <CheckinMode csrfToken={csrfToken} />}
      </div>
    </div>
  );
}

// Stub components — implemented in later tasks
function SessionCountdown({ expiresAt, onExpire }: { expiresAt: number; onExpire: () => void }) {
  return <span className="text-sm text-gray-500">⏱ --:--</span>;
}

function LogoutMenu({ onLogout, onLogoutAll }: { onLogout: () => void; onLogoutAll: () => void }) {
  return <button onClick={onLogout} className="text-sm text-gray-500">Logout ▾</button>;
}

function RecordMode({ csrfToken }: { csrfToken: string }) {
  return <div>Record mode — TODO</div>;
}

function SpoilMode({ csrfToken }: { csrfToken: string }) {
  return <div>Spoil mode — TODO</div>;
}

function CheckinMode({ csrfToken }: { csrfToken: string }) {
  return <div>Check-in mode — TODO</div>;
}
```

- [ ] **Step 3: Verify build**

Run: `npm run build 2>&1 | tail -5`
Expected: Build succeeds (may have existing TS warnings, no new errors)

- [ ] **Step 4: Commit**

```bash
git add app/admin/tally/page.tsx
git commit -m "feat(wave10): scaffold mobile tally wizard page"
```

---

## Task 2: Login handler + session management

**Files:**
- Modify: `app/admin/tally/page.tsx`

- [ ] **Step 1: Add login handler, session state, and CSRF cookie reader**

Add these to `app/admin/tally/page.tsx`:

```tsx
// Add at top of file, after imports
const SESSION_COOKIE_NAME = 'admin_session';
const CSRF_COOKIE_NAME = 'admin_csrf';

function readCookie(name: string): string {
  const match = document.cookie.match(new RegExp('(^| )' + name + '=([^;]+)'));
  return match ? match[2] : '';
}

// Replace the login form's onSubmit handler
const handleLogin = async (e: React.FormEvent) => {
  e.preventDefault();
  if (!secret) return;
  setLoggingIn(true);
  setLoginError('');
  try {
    const res = await fetch('/api/admin/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ secret, scope: 'mobile' }),
    });
    const data = await res.json();
    if (!res.ok) {
      setLoginError(data.error || 'Login failed');
      setLoggingIn(false);
      return;
    }
    // CSRF token is set as a cookie by the API; read it
    const csrf = data.csrfToken || readCookie(CSRF_COOKIE_NAME);
    setCsrfToken(csrf);
    setExpiresAt(new Date(data.expiresAt).getTime());
    setLoggedIn(true);
  } catch {
    setLoginError('Network error');
  }
  setLoggingIn(false);
};

// Add logout handlers
const handleLogout = async () => {
  try {
    await fetch('/api/admin/logout', {
      method: 'POST',
      headers: { 'x-csrf-token': csrfToken },
    });
  } catch { /* ignore */ }
  setLoggedIn(false);
  setSecret('');
  setCsrfToken('');
  setExpiresAt(0);
};

const handleLogoutAll = async () => {
  if (!confirm('Log out from all devices?')) return;
  try {
    await fetch('/api/admin/sessions/revoke-all', {
      method: 'POST',
      headers: { 'x-csrf-token': csrfToken },
    });
  } catch { /* ignore */ }
  setLoggedIn(false);
  setSecret('');
  setCsrfToken('');
  setExpiresAt(0);
};
```

- [ ] **Step 2: Implement `SessionCountdown` component**

Replace the stub:

```tsx
function SessionCountdown({ expiresAt, onExpire }: { expiresAt: number; onExpire: () => void }) {
  const [remaining, setRemaining] = useState(0);

  useEffect(() => {
    if (!expiresAt) return;
    const tick = () => {
      const ms = expiresAt - Date.now();
      if (ms <= 0) {
        onExpire();
        return;
      }
      setRemaining(ms);
    };
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, [expiresAt, onExpire]);

  const totalSec = Math.ceil(remaining / 1000);
  const min = Math.floor(totalSec / 60);
  const sec = totalSec % 60;
  const low = totalSec < 180; // under 3 minutes

  return (
    <span className={`text-sm font-mono tabular-nums ${low ? 'text-amber-600 animate-pulse' : 'text-gray-500'}`}>
      ⏱ {min}:{sec.toString().padStart(2, '0')}
    </span>
  );
}
```

- [ ] **Step 3: Implement `LogoutMenu` component**

Replace the stub:

```tsx
function LogoutMenu({ onLogout, onLogoutAll }: { onLogout: () => void; onLogoutAll: () => void }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="relative">
      <button onClick={() => setOpen(!open)} className="text-sm text-gray-500 hover:text-gray-700">
        Logout ▾
      </button>
      {open && (
        <div className="absolute right-0 top-full mt-1 bg-white border border-gray-200 rounded-lg shadow-lg py-1 z-50 min-w-[160px]">
          <button
            onClick={() => { setOpen(false); onLogout(); }}
            className="block w-full text-left px-4 py-2 text-sm hover:bg-gray-50"
          >
            Log out
          </button>
          <button
            onClick={() => { setOpen(false); onLogoutAll(); }}
            className="block w-full text-left px-4 py-2 text-sm text-red-600 hover:bg-gray-50"
          >
            Log out everywhere
          </button>
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 4: Verify build**

Run: `npm run build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add app/admin/tally/page.tsx
git commit -m "feat(wave10): login handler, session countdown, logout menu"
```

---

## Task 3: QrScanner component

**Files:**
- Create: `components/tally/QrScanner.tsx`

- [ ] **Step 1: Create `components/tally/QrScanner.tsx`**

```tsx
'use client';

import { useEffect, useRef } from 'react';

interface QrScannerProps {
  onScan: (decodedText: string) => void;
  onCancel: () => void;
}

/**
 * Full-viewport QR scanner using html5-qrcode.
 * Auto-captures on detect — no tap needed.
 * Renders into a container that fills the viewport.
 */
export default function QrScanner({ onScan, onCancel }: QrScannerProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const scannerRef = useRef<any>(null);

  useEffect(() => {
    let cancelled = false;

    import('html5-qrcode').then(({ Html5Qrcode }) => {
      if (cancelled || !containerRef.current) return;

      const scanner = new Html5Qrcode('tally-qr-reader');
      scannerRef.current = scanner;

      scanner.start(
        { facingMode: 'environment' },
        {
          fps: 10,
          qrbox: { width: 250, height: 250 },
          aspectRatio: 1.0,
        },
        (decodedText: string) => {
          if (cancelled) return;
          // Extract ballot ID from URL or raw text
          const ballotId = extractBallotId(decodedText);
          scanner.stop().then(() => scanner.clear()).catch(() => {});
          onScan(ballotId);
        },
        () => {} // ignore scan failures (continuous scanning)
      ).catch((err: any) => {
        console.error('[QrScanner] start failed:', err);
        onCancel();
      });
    });

    return () => {
      cancelled = true;
      if (scannerRef.current) {
        scannerRef.current.stop().then(() => scannerRef.current.clear()).catch(() => {});
      }
    };
  }, [onScan, onCancel]);

  return (
    <div className="fixed inset-0 z-50 bg-black">
      <div id="tally-qr-reader" ref={containerRef} className="w-full h-full" />
      <button
        onClick={onCancel}
        className="absolute top-4 left-1/2 -translate-x-1/2 bg-white/90 text-gray-900 font-semibold px-6 py-2 rounded-full shadow-lg"
      >
        Cancel
      </button>
    </div>
  );
}

/**
 * Extract ballot ID from QR decode result.
 * Handles both URL format (https://.../verify?ballot_id=PAPER:...)
 * and legacy raw format (PAPER:...).
 */
function extractBallotId(decodedText: string): string {
  try {
    const url = new URL(decodedText);
    const id = url.searchParams.get('ballot_id');
    if (id) return decodeURIComponent(id);
  } catch {
    // not a URL — fall through to raw text
  }
  return decodedText;
}
```

- [ ] **Step 2: Verify build**

Run: `npm run build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add components/tally/QrScanner.tsx
git commit -m "feat(wave10): reusable QR scanner component"
```

---

## Task 4: RecordMode component

**Files:**
- Modify: `app/admin/tally/page.tsx` (replace `RecordMode` stub with import)
- Create: `components/tally/RecordMode.tsx`

- [ ] **Step 1: Create `components/tally/RecordMode.tsx`**

```tsx
'use client';

import { useState, useEffect, useCallback } from 'react';
import QrScanner from './QrScanner';

type Phase = 'idle' | 'scanning' | 'scanned' | 'success' | 'error';

interface Candidate {
  id: string;
  full_name: string;
}

export default function RecordMode({ csrfToken }: { csrfToken: string }) {
  const [phase, setPhase] = useState<Phase>('idle');
  const [candidates, setCandidates] = useState<Candidate[]>([]);
  const [ballotId, setBallotId] = useState('');
  const [selectedCandidate, setSelectedCandidate] = useState<string | null>(null);
  const [result, setResult] = useState<{ success: boolean; message: string; receiptCode?: string } | null>(null);
  const [tally, setTally] = useState(0);
  const [lastReceipt, setLastReceipt] = useState<{ code: string; name: string } | null>(null);
  const [submitting, setSubmitting] = useState(false);

  // Load candidates on mount
  useEffect(() => {
    fetch('/api/candidates')
      .then((r) => r.json())
      .then((data) => setCandidates(Array.isArray(data) ? data : []))
      .catch(() => {});
  }, []);

  const handleScan = useCallback((id: string) => {
    setBallotId(id);
    setSelectedCandidate(null);
    setPhase('scanned');
  }, []);

  const handleConfirm = async () => {
    if (!ballotId || !selectedCandidate) return;
    setSubmitting(true);
    try {
      const res = await fetch('/api/admin/paper-vote', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-csrf-token': csrfToken,
        },
        body: JSON.stringify({ ballotId, candidateId: selectedCandidate }),
      });
      const data = await res.json();
      if (res.ok && data.success) {
        setResult({ success: true, message: data.message, receiptCode: data.receiptCode });
        setTally((t) => t + 1);
        const cand = candidates.find((c) => c.id === selectedCandidate);
        setLastReceipt({ code: data.receiptCode, name: cand?.full_name || '' });
      } else {
        setResult({ success: false, message: data.error || 'Vote failed' });
      }
    } catch {
      setResult({ success: false, message: 'Network error' });
    }
    setSubmitting(false);
    setPhase(result?.success ? 'success' : 'error');
  };

  // Auto-clear success/error after 3s
  useEffect(() => {
    if (phase !== 'success' && phase !== 'error') return;
    const timer = setTimeout(() => {
      setPhase('idle');
      setResult(null);
      setBallotId('');
      setSelectedCandidate(null);
    }, 3000);
    return () => clearTimeout(timer);
  }, [phase]);

  const truncateId = (id: string) => {
    if (id.length <= 16) return id;
    return `…${id.slice(-12)}`;
  };

  if (phase === 'scanning') {
    return <QrScanner onScan={handleScan} onCancel={() => setPhase('idle')} />;
  }

  return (
    <div className="space-y-4">
      {/* Session tally */}
      <div className="text-sm text-gray-500">
        Recorded this session: <span className="font-semibold text-gray-900">{tally}</span>
        {lastReceipt && (
          <div className="text-xs text-gray-400 mt-1">
            Last: {lastReceipt.code} · {lastReceipt.name}
          </div>
        )}
      </div>

      {/* Phase: idle */}
      {phase === 'idle' && (
        <button
          onClick={() => setPhase('scanning')}
          className="w-full bg-blue-600 text-white font-semibold rounded-xl px-4 py-4 text-base flex items-center justify-center gap-2"
        >
          📷 Scan ballot
        </button>
      )}

      {/* Phase: scanned — candidate picker + confirm */}
      {phase === 'scanned' && (
        <div className="space-y-4">
          <div className="bg-white rounded-xl border border-gray-200 p-4">
            <p className="text-sm text-gray-500 mb-1">Ballot scanned</p>
            <p className="font-mono text-sm text-gray-700">{truncateId(ballotId)}</p>
          </div>

          <div>
            <p className="text-sm font-medium text-gray-700 mb-2">Candidate:</p>
            <div className="space-y-2">
              {candidates.map((c) => (
                <label
                  key={c.id}
                  className={`flex items-center gap-3 p-3 rounded-xl border-2 cursor-pointer transition-colors min-h-[48px] ${
                    selectedCandidate === c.id
                      ? 'border-blue-600 bg-blue-50'
                      : 'border-gray-200 hover:border-gray-300'
                  }`}
                >
                  <input
                    type="radio"
                    name="candidate"
                    value={c.id}
                    checked={selectedCandidate === c.id}
                    onChange={() => setSelectedCandidate(c.id)}
                    className="sr-only"
                  />
                  <span className={`w-5 h-5 rounded-full border-2 flex-shrink-0 flex items-center justify-center ${
                    selectedCandidate === c.id ? 'border-blue-600' : 'border-gray-300'
                  }`}>
                    {selectedCandidate === c.id && <span className="w-2.5 h-2.5 rounded-full bg-blue-600" />}
                  </span>
                  <span className="text-base">{c.full_name}</span>
                </label>
              ))}
            </div>
          </div>

          <div className="flex gap-3">
            <button
              onClick={handleConfirm}
              disabled={!selectedCandidate || submitting}
              className="flex-1 bg-blue-600 text-white font-semibold rounded-xl px-4 py-3 text-base disabled:opacity-50"
            >
              {submitting ? 'Recording…' : 'Confirm'}
            </button>
            <button
              onClick={() => { setBallotId(''); setSelectedCandidate(null); setPhase('idle'); }}
              className="px-4 py-3 text-gray-600 font-medium rounded-xl border border-gray-200"
            >
              Rescan
            </button>
          </div>
        </div>
      )}

      {/* Phase: success */}
      {phase === 'success' && result && (
        <div className="bg-green-50 border border-green-200 rounded-xl p-6 text-center space-y-2">
          <p className="text-green-700 font-semibold text-lg">✓ Recorded</p>
          {result.receiptCode && (
            <p className="font-mono text-xl text-green-800">{result.receiptCode}</p>
          )}
          {lastReceipt && <p className="text-green-700">{lastReceipt.name}</p>}
          <p className="text-sm text-green-600">Next ballot in 3…</p>
        </div>
      )}

      {/* Phase: error */}
      {phase === 'error' && result && (
        <div className="bg-red-50 border border-red-200 rounded-xl p-6 text-center space-y-2">
          <p className="text-red-700 font-semibold text-lg">⚠ Not recorded</p>
          <p className="text-red-600">{result.message}</p>
          <p className="text-sm text-red-500">Discard this ballot.</p>
          <p className="text-sm text-red-400">Next ballot in 3…</p>
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 2: Update `app/admin/tally/page.tsx` to import RecordMode**

Replace the stub in `page.tsx`:
```tsx
// Remove the inline stub:
// function RecordMode({ csrfToken }: { csrfToken: string }) {
//   return <div>Record mode — TODO</div>;
// }

// Add import at top:
import RecordMode from '@/components/tally/RecordMode';
```

- [ ] **Step 3: Verify build**

Run: `npm run build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add components/tally/RecordMode.tsx app/admin/tally/page.tsx
git commit -m "feat(wave10): Record mode — scan, candidate pick, confirm, receipt"
```

---

## Task 5: SpoilMode component

**Files:**
- Modify: `app/admin/tally/page.tsx` (replace `SpoilMode` stub with import)
- Create: `components/tally/SpoilMode.tsx`

- [ ] **Step 1: Create `components/tally/SpoilMode.tsx`**

```tsx
'use client';

import { useState, useEffect, useCallback } from 'react';
import QrScanner from './QrScanner';

type Phase = 'idle' | 'scanning' | 'scanned' | 'success' | 'error';

const REASON_CHIPS = ['Damaged', 'Duplicate', 'Wrong'];

export default function SpoilMode({ csrfToken }: { csrfToken: string }) {
  const [phase, setPhase] = useState<Phase>('idle');
  const [ballotId, setBallotId] = useState('');
  const [reason, setReason] = useState('');
  const [result, setResult] = useState<{ success: boolean; message: string } | null>(null);
  const [tally, setTally] = useState(0);
  const [submitting, setSubmitting] = useState(false);

  const handleScan = useCallback((id: string) => {
    setBallotId(id);
    setReason('');
    setPhase('scanned');
  }, []);

  const handleConfirm = async () => {
    if (!ballotId || !reason.trim()) return;
    setSubmitting(true);
    try {
      const res = await fetch('/api/admin/paper-invalid', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-csrf-token': csrfToken,
        },
        body: JSON.stringify({ ballotId, reason: reason.trim() }),
      });
      const data = await res.json();
      if (res.ok && data.success) {
        setResult({ success: true, message: data.message });
        setTally((t) => t + 1);
      } else {
        setResult({ success: false, message: data.error || 'Void failed' });
      }
    } catch {
      setResult({ success: false, message: 'Network error' });
    }
    setSubmitting(false);
    setPhase(result?.success ? 'success' : 'error');
  };

  // Auto-clear success/error after 3s
  useEffect(() => {
    if (phase !== 'success' && phase !== 'error') return;
    const timer = setTimeout(() => {
      setPhase('idle');
      setResult(null);
      setBallotId('');
      setReason('');
    }, 3000);
    return () => clearTimeout(timer);
  }, [phase]);

  const truncateId = (id: string) => {
    if (id.length <= 16) return id;
    return `…${id.slice(-12)}`;
  };

  if (phase === 'scanning') {
    return <QrScanner onScan={handleScan} onCancel={() => setPhase('idle')} />;
  }

  return (
    <div className="space-y-4">
      {/* Session tally */}
      <div className="text-sm text-gray-500">
        Voided this session: <span className="font-semibold text-gray-900">{tally}</span>
      </div>

      {/* Phase: idle */}
      {phase === 'idle' && (
        <>
          <button
            onClick={() => setPhase('scanning')}
            className="w-full bg-blue-600 text-white font-semibold rounded-xl px-4 py-4 text-base flex items-center justify-center gap-2"
          >
            📷 Scan ballot
          </button>
          <p className="text-xs text-gray-400 text-center">
            Voiding permanently invalidates the anonymous blank.
          </p>
        </>
      )}

      {/* Phase: scanned — reason input + confirm */}
      {phase === 'scanned' && (
        <div className="space-y-4">
          <div className="bg-white rounded-xl border border-gray-200 p-4">
            <p className="text-sm text-gray-500 mb-1">Ballot scanned</p>
            <p className="font-mono text-sm text-gray-700">{truncateId(ballotId)}</p>
          </div>

          <div>
            <p className="text-sm font-medium text-gray-700 mb-2">Reason (required):</p>
            <div className="flex flex-wrap gap-2 mb-3">
              {REASON_CHIPS.map((chip) => (
                <button
                  key={chip}
                  onClick={() => setReason(reason === chip ? '' : chip)}
                  className={`px-4 py-2 rounded-full text-sm font-medium border-2 transition-colors ${
                    reason === chip
                      ? 'border-blue-600 bg-blue-50 text-blue-700'
                      : 'border-gray-200 text-gray-600 hover:border-gray-300'
                  }`}
                >
                  {chip}
                </button>
              ))}
            </div>
            <input
              type="text"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="or type a reason…"
              className="w-full border border-gray-300 rounded-lg px-4 py-3 text-base"
            />
          </div>

          <div className="flex gap-3">
            <button
              onClick={handleConfirm}
              disabled={!reason.trim() || submitting}
              className="flex-1 bg-blue-600 text-white font-semibold rounded-xl px-4 py-3 text-base disabled:opacity-50"
            >
              {submitting ? 'Voiding…' : 'Confirm'}
            </button>
            <button
              onClick={() => { setBallotId(''); setReason(''); setPhase('idle'); }}
              className="px-4 py-3 text-gray-600 font-medium rounded-xl border border-gray-200"
            >
              Rescan
            </button>
          </div>
        </div>
      )}

      {/* Phase: success */}
      {phase === 'success' && result && (
        <div className="bg-green-50 border border-green-200 rounded-xl p-6 text-center space-y-2">
          <p className="text-green-700 font-semibold text-lg">✓ Voided</p>
          <p className="text-sm text-green-600">Next ballot in 3…</p>
        </div>
      )}

      {/* Phase: error */}
      {phase === 'error' && result && (
        <div className="bg-red-50 border border-red-200 rounded-xl p-6 text-center space-y-2">
          <p className="text-red-700 font-semibold text-lg">⚠ Not voided</p>
          <p className="text-red-600">{result.message}</p>
          <p className="text-sm text-red-400">Next ballot in 3…</p>
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 2: Update `app/admin/tally/page.tsx` to import SpoilMode**

Replace the stub:
```tsx
// Remove the inline stub:
// function SpoilMode({ csrfToken }: { csrfToken: string }) {
//   return <div>Spoil mode — TODO</div>;
// }

// Add import at top:
import SpoilMode from '@/components/tally/SpoilMode';
```

- [ ] **Step 3: Verify build**

Run: `npm run build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add components/tally/SpoilMode.tsx app/admin/tally/page.tsx
git commit -m "feat(wave10): Spoil mode — scan, reason chips, confirm, voided"
```

---

## Task 6: CheckinMode component

**Files:**
- Modify: `app/admin/tally/page.tsx` (replace `CheckinMode` stub with import)
- Create: `components/tally/CheckinMode.tsx`

- [ ] **Step 1: Create `components/tally/CheckinMode.tsx`**

```tsx
'use client';

import { useState, useEffect, useRef, useCallback } from 'react';

type Phase = 'idle' | 'results' | 'selected' | 'success' | 'error';

interface Member {
  id: string;
  full_name: string;
  member_code: string;
  votingStatus: string;
}

export default function CheckinMode({ csrfToken }: { csrfToken: string }) {
  const [phase, setPhase] = useState<Phase>('idle');
  const [query, setQuery] = useState('');
  const [members, setMembers] = useState<Member[]>([]);
  const [selected, setSelected] = useState<Member | null>(null);
  const [result, setResult] = useState<{ success: boolean; message: string; shortCode?: string; memberName?: string } | null>(null);
  const [tally, setTally] = useState(0);
  const [lastCheckin, setLastCheckin] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  // Debounced live search
  const runSearch = useCallback(async (q: string) => {
    if (q.length < 2) {
      setMembers([]);
      setPhase('idle');
      return;
    }
    try {
      const res = await fetch(`/api/admin/members?q=${encodeURIComponent(q)}`);
      const data = await res.json();
      setMembers(data.members || []);
      setPhase('results');
    } catch {
      setMembers([]);
    }
  }, []);

  const onQueryChange = (value: string) => {
    setQuery(value);
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => runSearch(value), 300);
  };

  // Cleanup debounce on unmount
  useEffect(() => {
    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, []);

  // Auto-focus search input
  useEffect(() => {
    if (phase === 'idle' && inputRef.current) {
      inputRef.current.focus();
    }
  }, [phase]);

  const handleSelect = (member: Member) => {
    setSelected(member);
    setPhase('selected');
  };

  const handleConfirm = async () => {
    if (!selected) return;
    setSubmitting(true);
    try {
      const res = await fetch('/api/admin/paper-ballot', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-csrf-token': csrfToken,
        },
        body: JSON.stringify({ memberId: selected.id }),
      });
      const data = await res.json();
      if (res.ok && data.success) {
        setResult({ success: true, message: data.message, shortCode: data.shortCode, memberName: data.memberName });
        setTally((t) => t + 1);
        setLastCheckin(data.memberName);
      } else {
        setResult({ success: false, message: data.error || 'Check-in failed' });
      }
    } catch {
      setResult({ success: false, message: 'Network error' });
    }
    setSubmitting(false);
    setPhase(result?.success ? 'success' : 'error');
  };

  // Auto-clear success/error after 3s
  useEffect(() => {
    if (phase !== 'success' && phase !== 'error') return;
    const timer = setTimeout(() => {
      setPhase('idle');
      setResult(null);
      setSelected(null);
      setQuery('');
      setMembers([]);
    }, 3000);
    return () => clearTimeout(timer);
  }, [phase]);

  return (
    <div className="space-y-4">
      {/* Session tally */}
      <div className="text-sm text-gray-500">
        Checked in this session: <span className="font-semibold text-gray-900">{tally}</span>
        {lastCheckin && (
          <div className="text-xs text-gray-400 mt-1">Last: {lastCheckin}</div>
        )}
      </div>

      {/* Phase: idle or results — search input */}
      {(phase === 'idle' || phase === 'results') && (
        <div>
          <input
            ref={inputRef}
            type="text"
            value={query}
            onChange={(e) => onQueryChange(e.target.value)}
            placeholder="🔍 Search member name…"
            className="w-full border border-gray-300 rounded-xl px-4 py-3 text-base"
          />
          {phase === 'results' && members.length > 0 && (
            <div className="mt-2 bg-white rounded-xl border border-gray-200 divide-y divide-gray-100">
              {members.map((m) => (
                <button
                  key={m.id}
                  onClick={() => handleSelect(m)}
                  className="w-full text-left px-4 py-3 flex items-center justify-between hover:bg-gray-50 min-h-[48px]"
                >
                  <div>
                    <span className="text-base">{m.full_name}</span>
                    <span className="text-sm text-gray-400 ml-2">{m.member_code}</span>
                  </div>
                  <span className="text-xs text-gray-400">→</span>
                </button>
              ))}
            </div>
          )}
          {phase === 'results' && members.length === 0 && query.length >= 2 && (
            <p className="text-sm text-gray-400 mt-2 text-center">No members found</p>
          )}
        </div>
      )}

      {/* Phase: selected — confirm */}
      {phase === 'selected' && selected && (
        <div className="space-y-4">
          <div className="bg-white rounded-xl border border-gray-200 p-4">
            <p className="text-sm text-gray-500 mb-1">Check in</p>
            <p className="text-lg font-semibold">{selected.full_name}</p>
            <p className="text-sm text-gray-500 font-mono">{selected.member_code}</p>
          </div>
          <p className="text-xs text-gray-400">
            Creates the identity slip and consumes the voting entitlement for paper voting.
          </p>
          <div className="flex gap-3">
            <button
              onClick={handleConfirm}
              disabled={submitting}
              className="flex-1 bg-blue-600 text-white font-semibold rounded-xl px-4 py-3 text-base disabled:opacity-50"
            >
              {submitting ? 'Checking in…' : 'Confirm'}
            </button>
            <button
              onClick={() => { setSelected(null); setPhase('idle'); setQuery(''); setMembers([]); }}
              className="px-4 py-3 text-gray-600 font-medium rounded-xl border border-gray-200"
            >
              Cancel
            </button>
          </div>
        </div>
      )}

      {/* Phase: success */}
      {phase === 'success' && result && (
        <div className="bg-green-50 border border-green-200 rounded-xl p-6 text-center space-y-2">
          <p className="text-green-700 font-semibold text-lg">✓ Checked in</p>
          {result.memberName && <p className="text-green-700">{result.memberName}</p>}
          {result.shortCode && (
            <p className="font-mono text-xl text-green-800 bg-green-100 rounded-lg px-4 py-2 inline-block">
              {result.shortCode}
            </p>
          )}
          <p className="text-xs text-green-600">
            Slip code: reference only — no need to write down.
          </p>
          <p className="text-sm text-green-600">Hand the member a paper ballot.</p>
          <p className="text-xs text-green-500">Next member in 3…</p>
        </div>
      )}

      {/* Phase: error */}
      {phase === 'error' && result && (
        <div className="bg-red-50 border border-red-200 rounded-xl p-6 text-center space-y-2">
          <p className="text-red-700 font-semibold text-lg">⚠ Not checked in</p>
          <p className="text-red-600">{result.message}</p>
          <p className="text-sm text-red-400">Search again in 3…</p>
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 2: Update `app/admin/tally/page.tsx` to import CheckinMode**

Replace the stub:
```tsx
// Remove the inline stub:
// function CheckinMode({ csrfToken }: { csrfToken: string }) {
//   return <div>Check-in mode — TODO</div>;
// }

// Add import at top:
import CheckinMode from '@/components/tally/CheckinMode';
```

- [ ] **Step 3: Verify build**

Run: `npm run build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add components/tally/CheckinMode.tsx app/admin/tally/page.tsx
git commit -m "feat(wave10): Check-in mode — debounced search, select, confirm, slip code"
```

---

## Task 7: Phase gating + polish

**Files:**
- Modify: `app/admin/tally/page.tsx`

- [ ] **Step 1: Add phase gate for Record/Spoil modes**

The wireframe specifies: "when phase ≠ VOTING, Record and Spoil render a locked card." Check-in is available during VOTING.

Add phase fetching and gating to `page.tsx`:

```tsx
// Add to state declarations
const [phase, setPhase] = useState<string>('LOADING');

// Add useEffect to fetch phase on login
useEffect(() => {
  if (!loggedIn) return;
  fetch('/api/admin/phase')
    .then((r) => r.json())
    .then((data) => setPhase(data.phase || 'UNKNOWN'))
    .catch(() => setPhase('UNKNOWN'));
}, [loggedIn]);
```

Add phase gate UI in the mode rendering section:

```tsx
{/* Active mode */}
<div className="p-4">
  {(mode === 'record' || mode === 'spoil') && phase !== 'VOTING' && (
    <div className="bg-gray-50 border border-gray-200 rounded-xl p-6 text-center">
      <p className="text-gray-500 font-medium">Available only while voting is open.</p>
      <p className="text-sm text-gray-400 mt-1">Current phase: {phase}</p>
    </div>
  )}
  {mode === 'record' && phase === 'VOTING' && <RecordMode csrfToken={csrfToken} />}
  {mode === 'spoil' && phase === 'VOTING' && <SpoilMode csrfToken={csrfToken} />}
  {mode === 'checkin' && <CheckinMode csrfToken={csrfToken} />}
</div>
```

- [ ] **Step 2: Fix the auto-clear race condition in RecordMode and SpoilMode**

The `useEffect` for auto-clear reads `result` from the closure, but `result` is set in the same async flow as `setPhase`. Move the phase transition into the async handler:

In `RecordMode.tsx`, replace the success/error phase setting:

```tsx
// In handleConfirm, after setSubmitting(false):
if (res.ok && data.success) {
  setResult({ success: true, message: data.message, receiptCode: data.receiptCode });
  setTally((t) => t + 1);
  const cand = candidates.find((c) => c.id === selectedCandidate);
  setLastReceipt({ code: data.receiptCode, name: cand?.full_name || '' });
  setPhase('success');
} else {
  setResult({ success: false, message: data.error || 'Vote failed' });
  setPhase('error');
}
```

Apply the same fix to `SpoilMode.tsx` and `CheckinMode.tsx`.

- [ ] **Step 3: Verify build**

Run: `npm run build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add app/admin/tally/page.tsx components/tally/RecordMode.tsx components/tally/SpoilMode.tsx components/tally/CheckinMode.tsx
git commit -m "feat(wave10): phase gating + fix auto-clear race condition"
```

---

## Task 8: Final build + lint check

- [ ] **Step 1: Full build**

Run: `npm run build 2>&1 | tail -20`
Expected: Build succeeds with no new errors

- [ ] **Step 2: Lint**

Run: `npm run lint 2>&1 | tail -10`
Expected: No new warnings beyond baseline (15 existing)

- [ ] **Step 3: Verify all files are committed**

Run: `git status`
Expected: Clean working tree

- [ ] **Step 4: Final commit message review**

Run: `git log --oneline -10`
Expected: Clean commit history on `agent/wave10-mobile-tally`

---

## Spec Coverage

| Wireframe section | Task |
|---|---|
| Login screen (§3) | Task 2 |
| Session countdown (§2) | Task 2 |
| Logout menu (§2) | Task 2 |
| Mode switcher (§2) | Task 1 |
| Phase gate (§2) | Task 7 |
| Record mode (§4) | Task 4 |
| Spoil mode (§5) | Task 5 |
| Check-in mode (§6) | Task 6 |
| QR scanner (§4/5) | Task 3 |
| Debounced search (§6) | Task 6 |
| Auto-clear countdown (§4/5/6) | Tasks 4/5/6 |
| Component inventory (§7) | Tasks 3-6 |
