'use client';

import { useState, useEffect, useRef, useCallback } from 'react';
import { validateScannedBallotId } from '@/lib/ballot';

type VotingStatus = 'ELIGIBLE' | 'DIGITAL_VOTED' | 'PAPER_ISSUED' | 'PAPER_VOTED';

/** Minimal member-search shape (mode=assign) — no email/phone/paperBallot. */
interface Member {
  id: string;
  member_code: string;
  full_name: string;
  votingStatus: VotingStatus;
}

type Step = 'scan' | 'search' | 'confirm' | 'result';

const CSRF_COOKIE_NAME = 'admin_csrf';
const CSRF_HEADER_NAME = 'x-csrf-token';

/** Read the (non-HttpOnly) CSRF cookie as a fallback when component state
 * hasn't captured it yet (e.g. an existing session restored via /api/admin/me
 * on page load, where the token isn't re-sent in the response body). */
function readCsrfCookie(): string {
  if (typeof document === 'undefined') return '';
  const match = document.cookie.split('; ').find(c => c.startsWith(`${CSRF_COOKIE_NAME}=`));
  return match ? match.split('=')[1] : '';
}

function formatCountdown(ms: number): string {
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  const mm = Math.floor(totalSeconds / 60);
  const ss = totalSeconds % 60;
  return `${mm}:${ss.toString().padStart(2, '0')}`;
}

function votingStatusBadgeClass(status: VotingStatus): string {
  if (status === 'ELIGIBLE') {
    return 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400';
  }
  if (status === 'DIGITAL_VOTED') {
    return 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-400';
  }
  // PAPER_ISSUED, PAPER_VOTED
  return 'bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-400';
}

function votingStatusLabel(status: VotingStatus): string {
  switch (status) {
    case 'ELIGIBLE':
      return 'Eligible';
    case 'DIGITAL_VOTED':
      return 'Already voted (digital)';
    case 'PAPER_ISSUED':
      return 'Paper ballot already issued';
    case 'PAPER_VOTED':
      return 'Already voted (paper)';
  }
}

export default function MobileAssignPage() {
  // --- Auth state ---
  const [authStatus, setAuthStatus] = useState<'checking' | 'out' | 'in'>('checking');
  const [csrfToken, setCsrfToken] = useState('');
  const [expiresAt, setExpiresAt] = useState<string | null>(null);
  const [remainingMs, setRemainingMs] = useState<number | null>(null);
  const [loginSecret, setLoginSecret] = useState('');
  const [loginError, setLoginError] = useState<string | null>(null);
  const [loggingIn, setLoggingIn] = useState(false);
  const [revoking, setRevoking] = useState(false);
  const [revokeError, setRevokeError] = useState<string | null>(null);
  const [sessionNotice, setSessionNotice] = useState<string | null>(null);

  // --- Wizard state ---
  const [step, setStep] = useState<Step>('scan');
  const [scannerActive, setScannerActive] = useState(false);
  const [scanError, setScanError] = useState<string | null>(null);
  const [showManualEntry, setShowManualEntry] = useState(false);
  const [manualBallotInput, setManualBallotInput] = useState('');
  const [ballotId, setBallotId] = useState<string | null>(null);

  const [searchQuery, setSearchQuery] = useState('');
  const [members, setMembers] = useState<Member[]>([]);
  const [searching, setSearching] = useState(false);
  const [searchError, setSearchError] = useState<string | null>(null);
  const [selectedMember, setSelectedMember] = useState<Member | null>(null);

  const [assigning, setAssigning] = useState(false);
  const [assignError, setAssignError] = useState<string | null>(null);
  const [assignResult, setAssignResult] = useState<{ memberName: string; shortCode: string } | null>(null);

  const decodeHandledRef = useRef(false);
  const resultTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const getCsrf = useCallback((): string => csrfToken || readCsrfCookie(), [csrfToken]);

  const apiFetch = useCallback(
    (url: string, options: RequestInit = {}): Promise<Response> => {
      const method = (options.method || 'GET').toUpperCase();
      const headers = new Headers(options.headers);
      if (method !== 'GET') {
        const token = getCsrf();
        if (token) headers.set(CSRF_HEADER_NAME, token);
      }
      return fetch(url, { ...options, headers });
    },
    [getCsrf]
  );

  const resetWizard = useCallback(() => {
    if (resultTimerRef.current) {
      clearTimeout(resultTimerRef.current);
      resultTimerRef.current = null;
    }
    setBallotId(null);
    setScanError(null);
    setShowManualEntry(false);
    setManualBallotInput('');
    setSearchQuery('');
    setMembers([]);
    setSearchError(null);
    setSelectedMember(null);
    setAssignError(null);
    setAssignResult(null);
    setStep('scan');
    setScannerActive(true);
  }, []);

  const handleSessionExpired = useCallback((notice: string) => {
    setAuthStatus('out');
    setCsrfToken('');
    setExpiresAt(null);
    setRemainingMs(null);
    setScannerActive(false);
    resetWizard();
    setSessionNotice(notice);
  }, [resetWizard]);

  // --- Bootstrap auth on mount ---
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const res = await fetch('/api/admin/me');
        if (cancelled) return;
        if (res.ok) {
          const data = await res.json();
          if (data.scope !== 'mobile') {
            setAuthStatus('out');
            setSessionNotice('This device needs a mobile session — please log in on this phone.');
            return;
          }
          setExpiresAt(data.expiresAt ?? null);
          const cookieToken = readCsrfCookie();
          if (cookieToken) setCsrfToken(cookieToken);
          setAuthStatus('in');
          setScannerActive(true);
        } else {
          setAuthStatus('out');
        }
      } catch {
        if (!cancelled) setAuthStatus('out');
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  // --- Session countdown ---
  useEffect(() => {
    if (authStatus !== 'in' || !expiresAt) {
      const timer = setTimeout(() => setRemainingMs(null), 0);
      return () => clearTimeout(timer);
    }
    const expiresAtMs = new Date(expiresAt).getTime();
    const tick = () => {
      const remaining = expiresAtMs - Date.now();
      setRemainingMs(remaining);
      if (remaining <= 0) {
        handleSessionExpired('Your session expired. Log in again.');
      }
    };
    const initial = setTimeout(tick, 0);
    const interval = setInterval(tick, 1000);
    return () => {
      clearTimeout(initial);
      clearInterval(interval);
    };
  }, [authStatus, expiresAt, handleSessionExpired]);

  // --- Camera lifecycle (scan step only) ---
  useEffect(() => {
    type ScannerInstance = {
      render: (onSuccess: (decodedText: string) => void, onError: () => void) => void;
      clear: () => Promise<void>;
    };

    let scanner: ScannerInstance | null = null;
    let cancelled = false;

    if (authStatus === 'in' && step === 'scan' && scannerActive) {
      decodeHandledRef.current = false;
      import('html5-qrcode').then(({ Html5QrcodeScanner }) => {
        if (cancelled) return;
        scanner = new Html5QrcodeScanner(
          'mobile-qr-reader',
          { fps: 10, qrbox: { width: 250, height: 250 } },
          /* verbose= */ false
        );
        scanner.render(
          (decodedText: string) => {
            if (decodeHandledRef.current) return;
            const result = validateScannedBallotId(decodedText);
            if (!result.valid) {
              setScanError(result.error || 'That QR code is not a recognized ballot. Try again.');
              return;
            }
            decodeHandledRef.current = true;
            setScanError(null);
            setBallotId(result.ballotId);
            setScannerActive(false);
            setStep('search');
          },
          () => {
            // per-frame decode miss — expected while framing the QR code, ignore
          }
        );
      });
    }

    return () => {
      cancelled = true;
      if (scanner) {
        scanner.clear().catch(() => {
          // camera may already be stopped
        });
      }
    };
  }, [authStatus, step, scannerActive]);

  // --- Member search (debounced) ---
  useEffect(() => {
    if (step !== 'search') return;
    const query = searchQuery.trim();
    if (query.length < 2) {
      const clearTimer = setTimeout(() => {
        setMembers([]);
        setSearchError(null);
      }, 0);
      return () => clearTimeout(clearTimer);
    }
    const timer = setTimeout(async () => {
      setSearching(true);
      try {
        const res = await fetch(`/api/admin/members?q=${encodeURIComponent(query)}&mode=assign`);
        if (res.status === 401) {
          handleSessionExpired('Your session expired. Log in again.');
          return;
        }
        const data = await res.json();
        if (!res.ok) {
          setSearchError(data.error || 'Search failed.');
          setMembers([]);
        } else {
          setSearchError(null);
          setMembers(data.members || []);
        }
      } catch {
        setSearchError('Server error while searching.');
      } finally {
        setSearching(false);
      }
    }, 350);
    return () => clearTimeout(timer);
  }, [searchQuery, step, handleSessionExpired]);

  // --- Cleanup pending result-step timer on unmount ---
  useEffect(() => {
    return () => {
      if (resultTimerRef.current) clearTimeout(resultTimerRef.current);
    };
  }, []);

  const handleLogin = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!loginSecret) return;
    setLoggingIn(true);
    setLoginError(null);
    try {
      const res = await fetch('/api/admin/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ secret: loginSecret, scope: 'mobile' }),
      });
      const data = await res.json();
      if (!res.ok) {
        setLoginError(data.error || 'Invalid admin secret.');
        return;
      }
      setCsrfToken(data.csrfToken || '');
      setExpiresAt(data.expiresAt ?? null);
      setLoginSecret('');
      setSessionNotice(null);
      setAuthStatus('in');
      setScannerActive(true);
      setStep('scan');
    } catch {
      setLoginError('Server error logging in.');
    } finally {
      setLoggingIn(false);
    }
  };

  const handleRevokeAll = async () => {
    if (!confirm('Sign this device out of all admin sessions? You will need the admin secret again.')) return;
    setRevoking(true);
    setRevokeError(null);
    try {
      const res = await apiFetch('/api/admin/sessions/revoke-all', { method: 'POST' });
      if (!res.ok) {
        setRevokeError('Could not sign out other sessions — try again.');
        return;
      }
      handleSessionExpired('Signed out of all sessions.');
    } catch {
      setRevokeError('Could not sign out other sessions — try again.');
    } finally {
      setRevoking(false);
    }
  };

  const handleManualBallotSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    const result = validateScannedBallotId(manualBallotInput.trim());
    if (!result.valid) {
      setScanError(result.error || 'That does not look like a valid ballot ID.');
      return;
    }
    setScanError(null);
    setBallotId(result.ballotId);
    setScannerActive(false);
    setShowManualEntry(false);
    setManualBallotInput('');
    setStep('search');
  };

  const handleRescan = () => {
    setScanError(null);
    setBallotId(null);
    setStep('scan');
    setScannerActive(true);
  };

  const selectMember = (member: Member) => {
    setSelectedMember(member);
    setAssignError(null);
    setStep('confirm');
  };

  const handleBackToSearch = () => {
    setSelectedMember(null);
    setAssignError(null);
    setStep('search');
  };

  const handleAssign = async () => {
    if (!ballotId || !selectedMember || selectedMember.votingStatus !== 'ELIGIBLE') return;
    setAssigning(true);
    setAssignError(null);
    try {
      const res = await apiFetch('/api/admin/paper-assign', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ballotId, memberId: selectedMember.id }),
      });
      if (res.status === 401) {
        handleSessionExpired('Your session expired. Log in again.');
        return;
      }
      const data = await res.json();
      if (!res.ok) {
        setAssignError(data.error || 'Failed to assign ballot.');
        return;
      }
      setAssignResult({ memberName: selectedMember.full_name, shortCode: data.shortCode });
      setStep('result');
      resultTimerRef.current = setTimeout(() => {
        resetWizard();
      }, 5000);
    } catch {
      setAssignError('Server error assigning ballot.');
    } finally {
      setAssigning(false);
    }
  };

  // --- Render helpers ---

  const stepAnnouncement = (() => {
    switch (step) {
      case 'scan':
        return 'Step 1 of 4: Scan ballot QR code';
      case 'search':
        return 'Step 2 of 4: Search for member';
      case 'confirm':
        return 'Step 3 of 4: Confirm assignment';
      case 'result':
        return 'Step 4 of 4: Result';
    }
  })();

  const countdownClass = (() => {
    if (remainingMs === null) return 'text-gray-500 dark:text-gray-400';
    if (remainingMs < 2 * 60 * 1000) return 'text-red-600 dark:text-red-400 font-semibold';
    return 'text-gray-500 dark:text-gray-400';
  })();

  if (authStatus === 'checking') {
    return (
      <div className="min-h-screen bg-gray-50 dark:bg-gray-900 flex items-center justify-center px-4">
        <p className="text-sm text-gray-500 dark:text-gray-400">Checking session…</p>
      </div>
    );
  }

  if (authStatus === 'out') {
    return (
      <div className="min-h-screen bg-gray-50 dark:bg-gray-900 flex items-center justify-center px-4 py-12">
        <div className="w-full max-w-sm">
          <h1 className="text-xl font-bold text-gray-900 dark:text-white mb-1">Mobile Ballot Assign</h1>
          <p className="text-sm text-gray-600 dark:text-gray-400 mb-6">
            Log in on this phone to scan and assign paper ballots. This session is short-lived and separate
            from a desktop login.
          </p>

          {sessionNotice && (
            <div className="mb-4 p-3 rounded-lg text-sm bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 text-amber-800 dark:text-amber-300">
              {sessionNotice}
            </div>
          )}
          {loginError && (
            <div className="mb-4 p-3 rounded-lg text-sm bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 text-red-800 dark:text-red-300">
              {loginError}
            </div>
          )}

          <form onSubmit={handleLogin} className="space-y-4 bg-white dark:bg-gray-800 rounded-lg shadow p-5">
            <div>
              <label htmlFor="mobile-admin-secret" className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                Admin secret
              </label>
              <input
                id="mobile-admin-secret"
                type="password"
                autoComplete="off"
                value={loginSecret}
                onChange={e => setLoginSecret(e.target.value)}
                placeholder="Enter admin secret"
                className="w-full min-h-11 p-3 text-base border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:outline-none focus:ring-2 focus:ring-blue-500"
                required
              />
            </div>
            <button
              type="submit"
              disabled={loggingIn}
              className="w-full min-h-11 py-3 px-4 bg-blue-600 hover:bg-blue-700 active:bg-blue-800 text-white text-base rounded-lg font-medium disabled:opacity-50"
            >
              {loggingIn ? 'Logging in…' : 'Log in on this phone'}
            </button>
          </form>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gray-50 dark:bg-gray-900 pb-8">
      <div aria-live="polite" className="sr-only">
        {stepAnnouncement}
      </div>

      {/* Persistent chrome */}
      <header className="sticky top-0 z-20 bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700 px-4 py-2.5 flex items-center justify-between gap-3">
        <div className="min-w-0">
          <p className="text-sm font-semibold text-gray-900 dark:text-white truncate">Mobile Ballot Assign</p>
          <p className={`text-xs ${countdownClass}`}>
            Session: {remainingMs !== null ? formatCountdown(remainingMs) : '—:—'}
          </p>
        </div>
        <button
          type="button"
          onClick={handleRevokeAll}
          disabled={revoking}
          className="shrink-0 min-h-11 px-3 py-2 text-xs font-medium border border-red-300 dark:border-red-800 rounded-lg text-red-700 dark:text-red-400 active:bg-red-50 dark:active:bg-red-900/20 disabled:opacity-50"
        >
          {revoking ? 'Revoking…' : 'Log out everywhere'}
        </button>
      </header>

      {revokeError && (
        <div className="max-w-md mx-auto px-4 pt-4">
          <div className="p-3 rounded-lg text-sm bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 text-red-800 dark:text-red-300 font-medium">
            {revokeError}
          </div>
        </div>
      )}

      <main className="max-w-md mx-auto px-4 pt-4">
        {step === 'scan' && (
          <section>
            <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-2">Scan the ballot QR code</h2>
            <p className="text-sm text-gray-600 dark:text-gray-400 mb-3">
              Point the camera at the QR code printed on the ballot.
            </p>

            {scanError && (
              <div className="mb-3 p-3 rounded-lg text-sm bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 text-red-800 dark:text-red-300">
                {scanError}
              </div>
            )}

            <div id="mobile-qr-reader" className="w-full rounded-lg overflow-hidden bg-black" />

            <button
              type="button"
              onClick={() => setShowManualEntry(v => !v)}
              className="mt-4 w-full min-h-11 py-3 text-sm font-medium text-blue-700 dark:text-blue-400 border border-blue-200 dark:border-blue-800 rounded-lg active:bg-blue-50 dark:active:bg-blue-900/20"
            >
              {showManualEntry ? 'Hide manual entry' : 'Camera not working? Enter ballot ID manually'}
            </button>

            {showManualEntry && (
              <form onSubmit={handleManualBallotSubmit} className="mt-3 space-y-2">
                <label htmlFor="manual-ballot-id" className="block text-sm font-medium text-gray-700 dark:text-gray-300">
                  Ballot ID
                </label>
                <input
                  id="manual-ballot-id"
                  type="text"
                  value={manualBallotInput}
                  onChange={e => setManualBallotInput(e.target.value)}
                  placeholder="PAPER:... or the printed code"
                  className="w-full min-h-11 p-3 text-base border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:outline-none focus:ring-2 focus:ring-blue-500"
                  required
                />
                <button
                  type="submit"
                  className="w-full min-h-11 py-3 bg-blue-600 hover:bg-blue-700 active:bg-blue-800 text-white text-base rounded-lg font-medium"
                >
                  Use this ballot ID
                </button>
              </form>
            )}
          </section>
        )}

        {step === 'search' && (
          <section>
            <div className="flex items-center justify-between mb-2">
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white">Find the member</h2>
              <button
                type="button"
                onClick={handleRescan}
                className="text-xs font-medium text-blue-700 dark:text-blue-400 min-h-11 px-2"
              >
                Rescan
              </button>
            </div>
            <p className="text-xs text-gray-500 dark:text-gray-400 mb-3">
              Ballot scanned. Search by name to pick who this ballot goes to.
            </p>

            <label htmlFor="member-search" className="sr-only">
              Search members by name
            </label>
            <input
              id="member-search"
              type="text"
              value={searchQuery}
              onChange={e => setSearchQuery(e.target.value)}
              placeholder="Type a member's name…"
              autoFocus
              className="w-full min-h-11 p-3 text-base border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:outline-none focus:ring-2 focus:ring-blue-500"
            />

            {searchError && (
              <div className="mt-3 p-3 rounded-lg text-sm bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 text-red-800 dark:text-red-300">
                {searchError}
              </div>
            )}

            {searching && <p className="mt-3 text-sm text-gray-500 dark:text-gray-400">Searching…</p>}

            {!searching && searchQuery.trim().length >= 2 && members.length === 0 && !searchError && (
              <p className="mt-3 text-sm text-gray-500 dark:text-gray-400">No members found.</p>
            )}

            <ul className="mt-3 space-y-2">
              {members.map(member => (
                <li key={member.id}>
                  <button
                    type="button"
                    onClick={() => selectMember(member)}
                    className="w-full text-left min-h-11 p-3 bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg active:bg-gray-50 dark:active:bg-gray-700 flex items-center justify-between gap-3"
                  >
                    <span className="min-w-0">
                      <span className="block font-medium text-gray-900 dark:text-white truncate">{member.full_name}</span>
                      <span className="block text-xs text-gray-500 dark:text-gray-400">{member.member_code}</span>
                    </span>
                    <span
                      className={`shrink-0 px-2 py-1 text-xs font-semibold rounded-full ${votingStatusBadgeClass(member.votingStatus)}`}
                    >
                      {votingStatusLabel(member.votingStatus)}
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          </section>
        )}

        {step === 'confirm' && selectedMember && (
          <section>
            <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-3">Confirm assignment</h2>

            <div className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg p-4 space-y-3">
              <div>
                <p className="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">Ballot</p>
                <p className="font-mono text-sm text-gray-900 dark:text-white break-all">{ballotId}</p>
              </div>
              <div>
                <p className="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">Member</p>
                <p className="font-medium text-gray-900 dark:text-white">{selectedMember.full_name}</p>
                <p className="text-xs text-gray-500 dark:text-gray-400">{selectedMember.member_code}</p>
              </div>
              <div>
                <p className="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">Voting status</p>
                <span
                  className={`inline-block mt-1 px-2 py-1 text-xs font-semibold rounded-full ${votingStatusBadgeClass(selectedMember.votingStatus)}`}
                >
                  {votingStatusLabel(selectedMember.votingStatus)}
                </span>
              </div>
            </div>

            {selectedMember.votingStatus !== 'ELIGIBLE' && (
              <div className="mt-3 p-3 rounded-lg text-sm bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 text-red-800 dark:text-red-300">
                This member already has a ballot or has already voted. Assigning another ballot may be
                incorrect — double-check before continuing.
              </div>
            )}

            {assignError && (
              <div className="mt-3 p-3 rounded-lg text-sm bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 text-red-800 dark:text-red-300">
                {assignError}
              </div>
            )}

            <div className="mt-4 space-y-2">
              <button
                type="button"
                onClick={handleAssign}
                disabled={assigning || selectedMember.votingStatus !== 'ELIGIBLE'}
                className="w-full min-h-11 py-3 bg-emerald-600 hover:bg-emerald-700 active:bg-emerald-800 text-white text-base rounded-lg font-medium disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {assigning ? 'Assigning…' : 'Assign ballot'}
              </button>
              <button
                type="button"
                onClick={handleBackToSearch}
                disabled={assigning}
                className="w-full min-h-11 py-3 text-gray-700 dark:text-gray-300 border border-gray-300 dark:border-gray-600 rounded-lg font-medium active:bg-gray-100 dark:active:bg-gray-700 disabled:opacity-50"
              >
                Cancel / back
              </button>
            </div>
          </section>
        )}

        {step === 'result' && assignResult && (
          <section>
            <div className="bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-lg p-5 text-center">
              <p className="text-lg font-semibold text-green-800 dark:text-green-400 mb-1">Ballot assigned</p>
              <p className="text-sm text-gray-700 dark:text-gray-300">{assignResult.memberName}</p>
              <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">Short code</p>
              <p className="font-mono text-xl font-bold text-gray-900 dark:text-white">{assignResult.shortCode}</p>
            </div>
            <button
              type="button"
              onClick={resetWizard}
              className="mt-4 w-full min-h-11 py-3 bg-blue-600 hover:bg-blue-700 active:bg-blue-800 text-white text-base rounded-lg font-medium"
            >
              Scan next ballot
            </button>
          </section>
        )}
      </main>
    </div>
  );
}
