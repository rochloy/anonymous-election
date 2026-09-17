'use client';
import { useState, useEffect, useRef } from 'react';
import { useParams } from 'next/navigation';

type Candidate = { id: string; full_name: string; statement: string | null; photo_url: string | null };

type PageStatus = 'loading' | 'invalid' | 'ready' | 'confirming' | 'casting' | 'voted' | 'cast_failed';

interface RedeemResponse {
  success?: boolean;
  message?: string;
  credential?: string;
  ttlSeconds?: number;
}

interface CastResponse {
  success?: boolean;
  message?: string;
  receiptCode?: string;
  ballotId?: string;
}

interface LegacyVoteResponse {
  success?: boolean;
  receiptCode?: string;
  error?: string;
  code?: string;
}

const DEFAULT_CREDENTIAL_TTL_MS = 15 * 60 * 1000; // fallback if server omits ttlSeconds
const SLOW_CAST_NOTICE_MS = 4000; // Wave 7 spec §7 Rough Edge #1: progressive "still working" hint

// Wave 7 spec §4.2 — the redeem RPC returns a plain-language `message` string,
// not a machine-readable reason code. These patterns classify the small set of
// known DB messages (see supabase/migration_wave7_digital_severance.sql) into
// "dead end, contact admin" vs "safe to retry" without needing a code field.
// Anything unrecognized defaults to retryable — safer than trapping a voter
// behind a dead end for a message we don't understand.
const NON_RETRYABLE_REDEEM_PATTERNS: RegExp[] = [
  /expired/i,
  /invalid or non-existent/i,
  /voided and reissued/i,
  /already been used/i,
  /not eligible to vote/i,
  /paper ballot has already been issued/i,
  /voting phase is closed/i,
];

function isRedeemRetryable(message: string): boolean {
  return !NON_RETRYABLE_REDEEM_PATTERNS.some((pattern) => pattern.test(message));
}

function Spinner() {
  return (
    <svg className="animate-spin h-4 w-4 text-white" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
      <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
    </svg>
  );
}

export default function VotePage() {
  const params = useParams();
  const token = params.token as string;

  const [status, setStatus] = useState<PageStatus>('loading');
  const [candidates, setCandidates] = useState<Candidate[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [receipt, setReceipt] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null); // page-load errors (invalid token, candidate load failure)
  const [redeemError, setRedeemError] = useState<{ message: string; retryable: boolean } | null>(null);
  const [showSlowNotice, setShowSlowNotice] = useState(false);
  const [copied, setCopied] = useState(false);
  const [copyError, setCopyError] = useState<string | null>(null);

  // Client-side safety net bounding the confirming/casting window to the
  // credential's own TTL, so a hung request can't leave the voter staring at
  // "Casting your vote…" forever. Cleared as soon as cast settles either way.
  const ttlTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const slowNoticeTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const clearInFlightTimers = () => {
    if (ttlTimeoutRef.current) { clearTimeout(ttlTimeoutRef.current); ttlTimeoutRef.current = null; }
    if (slowNoticeTimeoutRef.current) { clearTimeout(slowNoticeTimeoutRef.current); slowNoticeTimeoutRef.current = null; }
    setShowSlowNotice(false);
  };

  useEffect(() => {
    return () => clearInFlightTimers();
  }, []);

  useEffect(() => {
    if (!token) return;
    // Page load only ever verifies the token and loads candidates. No
    // credential work (no /api/vote/redeem call) happens here — redeem is
    // strictly gated behind the voter's Confirm-vote click (Wave 7 spec §4.5).
    fetch('/api/auth/verify-token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ rawToken: token }),
    })
      .then(r => r.json())
      .then(async d => {
        if (d.valid) {
          setStatus('ready');
          try {
            const candidatesRes = await fetch('/api/candidates');
            if (!candidatesRes.ok) {
              setCandidates([]);
              setError('Failed to load candidates');
              return;
            }
            const candidatesData = (await candidatesRes.json()) as Candidate[];
            setCandidates(candidatesData);
          } catch {
            setCandidates([]);
            setError('Failed to load candidates');
          }
        } else {
          setStatus('invalid');
          setError(d.message);
        }
      })
      .catch(() => { setStatus('invalid'); setError('Network error'); });
  }, [token]);

  // Legacy single-call fallback (digital_write_mode = LEGACY, or two-phase
  // unavailable). Mirrors the pre-Wave-7 vote flow.
  const castLegacy = async () => {
    if (!selected || !token) { setStatus('ready'); return; }
    try {
      const r = await fetch('/api/vote', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: token, candidateId: selected }),
      });
      if (r.status === 409) {
        // Contradictory mode signal (redeem said "use legacy", legacy says
        // "use two-phase") — never surface internals, just let the voter retry.
        setRedeemError({ message: 'Something went wrong starting your vote. Please try again.', retryable: true });
        setStatus('ready');
        return;
      }
      const d = (await r.json()) as LegacyVoteResponse;
      if (d.success && d.receiptCode) {
        setReceipt(d.receiptCode);
        setStatus('voted');
      } else {
        setRedeemError({ message: d.error || 'Vote failed.', retryable: true });
        setStatus('ready');
      }
    } catch {
      setRedeemError({ message: 'Something went wrong starting your vote. Please try again.', retryable: true });
      setStatus('ready');
    }
  };

  // Two-phase orchestrator: redeem-at-confirm, then cast, back-to-back, with
  // no voter interaction in between — one click, one perceived action (Wave 7
  // spec §3/§4.1). The minted credential (`DVC-...`) lives only in this
  // function's local scope for the handoff to cast: never assigned to a
  // useState field, never logged, never persisted to storage/URL, and never
  // rendered alongside the token or candidate choice.
  const handleConfirm = async () => {
    if (!selected || !token) return;
    setRedeemError(null);
    setStatus('confirming');

    let redeemRes: Response;
    try {
      redeemRes = await fetch('/api/vote/redeem', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token }),
      });
    } catch {
      setRedeemError({ message: 'Something went wrong starting your vote. Please try again.', retryable: true });
      setStatus('ready');
      return;
    }

    if (redeemRes.status === 409) {
      // Defensive mode fallback: server signals two-phase isn't the active
      // path for this token — fall back to the single-call legacy endpoint
      // rather than hard-failing. (No known server build emits this from
      // /api/vote/redeem today; this exists so mode changes don't break the
      // voter mid-rollout.)
      await castLegacy();
      return;
    }

    let redeemData: RedeemResponse;
    try {
      redeemData = await redeemRes.json();
    } catch {
      setRedeemError({ message: 'Something went wrong starting your vote. Please try again.', retryable: true });
      setStatus('ready');
      return;
    }

    if (!redeemData.success || !redeemData.credential) {
      const message = redeemData.message || 'Something went wrong starting your vote. Please try again.';
      setRedeemError({ message, retryable: isRedeemRetryable(message) });
      setStatus('ready');
      return;
    }

    const credential = redeemData.credential; // local-scope only, see comment above
    const ttlMs = typeof redeemData.ttlSeconds === 'number' && redeemData.ttlSeconds > 0
      ? redeemData.ttlSeconds * 1000
      : DEFAULT_CREDENTIAL_TTL_MS;

    setStatus('casting');
    slowNoticeTimeoutRef.current = setTimeout(() => setShowSlowNotice(true), Math.min(SLOW_CAST_NOTICE_MS, ttlMs));
    ttlTimeoutRef.current = setTimeout(() => {
      // Cast never resolved within the credential's own validity window —
      // treat as the unrecoverable post-redeem failure rather than hanging.
      setStatus('cast_failed');
    }, ttlMs);

    try {
      const castRes = await fetch('/api/vote/cast', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ credential, candidateId: selected }),
      });
      const castData = (await castRes.json()) as CastResponse;
      clearInFlightTimers();
      if (castData.success && castData.receiptCode) {
        setReceipt(castData.receiptCode);
        setStatus('voted');
      } else {
        // Redeem succeeded but cast failed — unrecoverable per spec §4.3.
        // Fixed, calm copy only; never surface the raw server message here
        // (it could imply "already voted" in rare race cases, which is
        // explicitly banned regardless of literal accuracy of the DB text).
        setStatus('cast_failed');
      }
    } catch {
      clearInFlightTimers();
      setStatus('cast_failed');
    }
  };

  // Client-only receipt affordances — no server call, no email, no localStorage.
  // The receipt only ever lives in ephemeral React state and whatever the
  // browser's clipboard/download/print mechanism does with it.
  const handleCopyReceipt = async () => {
    if (!receipt) return;
    setCopyError(null);
    try {
      await navigator.clipboard.writeText(receipt);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      setCopyError('Could not copy automatically — please copy the code manually.');
    }
  };

  const handleDownloadReceipt = () => {
    if (!receipt) return;
    const content = `Vote Receipt\n\nReceipt Code: ${receipt}\n\nKeep this code to confirm your vote was recorded. It does not reveal who you voted for.\n`;
    const blob = new Blob([content], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'vote-receipt.txt';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  if (status === 'loading') return <div className="p-8">Verifying your token...</div>;
  if (status === 'invalid') return <div className="p-8 text-red-600">{error}</div>;

  if (status === 'cast_failed') return (
    <div className="p-8 max-w-2xl mx-auto">
      <div className="p-6 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg">
        <h1 className="text-xl font-bold text-amber-900 dark:text-amber-300 mb-3">
          We couldn&apos;t finish casting your vote
        </h1>
        <p className="text-sm text-gray-700 dark:text-gray-300 mb-3">
          Your voting credential is no longer valid, so we weren&apos;t able to complete this vote.{' '}
          <strong>Your vote has not been recorded</strong> — nothing was counted.
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
  );

  if (status === 'voted') return (
    <div className="p-8 max-w-2xl mx-auto">
      <h1 className="text-2xl font-bold mb-4">Vote cast</h1>
      <p>Your receipt code:</p>
      <p className="mt-2">
        <code className="bg-gray-100 px-3 py-2 rounded text-lg font-mono inline-block">{receipt}</code>
      </p>

      <div className="mt-4 flex flex-wrap gap-3 print:hidden">
        <button
          type="button"
          onClick={handleCopyReceipt}
          className="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700"
        >
          {copied ? 'Copied!' : 'Copy'}
        </button>
        <button
          type="button"
          onClick={handleDownloadReceipt}
          className="px-4 py-2 border border-gray-300 rounded hover:bg-gray-50"
        >
          Download receipt
        </button>
        <button
          type="button"
          onClick={() => window.print()}
          className="px-4 py-2 border border-gray-300 rounded hover:bg-gray-50"
        >
          Print receipt
        </button>
      </div>
      {copyError && <p className="mt-2 text-sm text-red-600 print:hidden">{copyError}</p>}

      <p className="mt-6 text-sm text-gray-600">
        Save this privately — it is not emailed to you. You&apos;ll use it to confirm your vote was recorded.
      </p>
      <p className="mt-1 text-sm text-gray-600">
        Keep it until after results are published.
      </p>
    </div>
  );

  // 'ready' | 'confirming' | 'casting' all render this same candidate-list
  // screen (Wave 7 spec §4.1/§4.2) — only the button label/disabled state and
  // an optional inline error banner change, so a redeem failure returns the
  // voter to exactly where they were instead of a jarring full-screen swap.
  const isBusy = status === 'confirming' || status === 'casting';
  const buttonLabel = status === 'confirming' ? 'Confirming…' : status === 'casting' ? 'Casting your vote…' : 'Confirm vote';

  return (
    <div className="p-8 max-w-2xl mx-auto">
      <h1 className="text-2xl font-bold mb-6">Cast your vote</h1>

      {redeemError && (
        <div className="p-4 mb-4 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded">
          <p className="text-sm text-red-700 dark:text-red-400">{redeemError.message}</p>
          {redeemError.retryable ? (
            <button
              type="button"
              onClick={handleConfirm}
              className="mt-2 text-sm font-medium text-red-700 dark:text-red-400 underline"
            >
              Try again
            </button>
          ) : (
            <p className="mt-2 text-xs text-red-600 dark:text-red-400">
              Need help? Contact your election administrator.
            </p>
          )}
        </div>
      )}

      <div className={`grid gap-4 ${isBusy ? 'opacity-60 pointer-events-none' : ''}`}>
        {candidates.map((c) => (
          <button
            key={c.id}
            onClick={() => setSelected(c.id)}
            disabled={isBusy}
            className={`p-4 border rounded-lg text-left ${selected === c.id ? 'border-blue-500 bg-blue-50' : 'border-gray-300'}`}
          >
            <h2 className="font-semibold">{c.full_name}</h2>
            <p className="text-sm text-gray-600 mt-1">{c.statement}</p>
          </button>
        ))}
      </div>
      {error && <p className="text-red-600 mt-4">{error}</p>}

      <button
        onClick={handleConfirm}
        disabled={!selected || isBusy}
        className={`mt-6 inline-flex items-center gap-2 px-6 py-2 bg-blue-600 text-white rounded transition-opacity duration-150 disabled:opacity-50 ${isBusy ? 'opacity-75 cursor-wait' : 'hover:bg-blue-700'}`}
      >
        {isBusy && <Spinner />}
        <span>{buttonLabel}</span>
      </button>

      {status === 'casting' && showSlowNotice && (
        <p className="mt-2 text-xs text-gray-500">Still working — hang tight.</p>
      )}
    </div>
  );
}
