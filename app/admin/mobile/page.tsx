'use client';

import { useState, useEffect, useCallback } from 'react';
import RecordMode from '@/components/tally/RecordMode';
import SpoilMode from '@/components/tally/SpoilMode';
import CheckinMode from '@/components/tally/CheckinMode';

type Mode = 'record' | 'spoil' | 'checkin';

const CSRF_COOKIE_NAME = 'admin_csrf';

function readCookie(name: string): string {
  if (typeof document === 'undefined') return '';
  const match = document.cookie.match(new RegExp('(^| )' + name + '=([^;]+)'));
  return match ? match[2] : '';
}

/** Phase-dependent tab order: Check-in first during VOTING, Record first otherwise. */
function modeOrder(phase: string): Mode[] {
  if (phase === 'VOTING') return ['checkin', 'record', 'spoil'];
  return ['record', 'spoil', 'checkin'];
}

function modeLabel(m: Mode): string {
  return m === 'record' ? 'Record' : m === 'spoil' ? 'Spoil' : 'Check-in';
}

export default function TallyPage() {
  const [secret, setSecret] = useState('');
  const [loggedIn, setLoggedIn] = useState(false);
  const [csrfToken, setCsrfToken] = useState('');
  const [expiresAt, setExpiresAt] = useState<number>(0);
  const [mode, setMode] = useState<Mode>('checkin');
  const [phase, setPhase] = useState<string>('LOADING');
  const [loginError, setLoginError] = useState('');
  const [loggingIn, setLoggingIn] = useState(false);

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
      const csrf = data.csrfToken || readCookie(CSRF_COOKIE_NAME);
      setCsrfToken(csrf);
      setExpiresAt(new Date(data.expiresAt).getTime());
      setLoggedIn(true);
      setSecret('');
    } catch {
      setLoginError('Network error');
    }
    setLoggingIn(false);
  };

  useEffect(() => {
    if (!loggedIn) return;
    fetch('/api/admin/phase')
      .then((r) => r.json())
      .then((data) => {
        const p = data.current_phase || 'UNKNOWN';
        setPhase(p);
        // Set default mode based on phase
        setMode(p === 'VOTING' ? 'checkin' : 'record');
      })
      .catch(() => setPhase('UNKNOWN'));
  }, [loggedIn]);

  const handleLogout = useCallback(async () => {
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
  }, [csrfToken]);

  const handleLogoutAll = useCallback(async () => {
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
  }, [csrfToken]);

  if (!loggedIn) {
    return (
      <div className="min-h-screen bg-gray-50 dark:bg-gray-900 flex items-center justify-center p-4">
        <div className="w-full max-w-sm bg-white dark:bg-gray-800 rounded-2xl shadow-lg p-6">
          <h1 className="text-xl font-bold text-gray-900 dark:text-white text-center mb-1">Election Tally</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400 text-center mb-6">Admin tool — phone optimized</p>
          <form onSubmit={handleLogin}>
            <input
              type="password"
              value={secret}
              onChange={(e) => setSecret(e.target.value)}
              placeholder="Admin secret"
              className="w-full border border-gray-300 dark:border-gray-600 dark:bg-gray-700 dark:text-white rounded-lg px-4 py-3 mb-3 text-base"
              autoFocus
            />
            {loginError && <p className="text-red-600 dark:text-red-400 text-sm mb-3">{loginError}</p>}
            <button
              type="submit"
              disabled={loggingIn || !secret}
              className="w-full bg-blue-600 text-white font-semibold rounded-lg px-4 py-3 text-base disabled:opacity-50"
            >
              {loggingIn ? 'Logging in…' : 'Log in'}
            </button>
          </form>
          <p className="text-xs text-gray-400 dark:text-gray-500 text-center mt-4">Session: 12 min, auto-logout</p>
          <p className="text-xs text-center mt-2">
            <a href="/admin/dashboard" className="text-blue-500 hover:text-blue-600 dark:text-blue-400 dark:hover:text-blue-300">Admin Dashboard →</a>
          </p>
        </div>
      </div>
    );
  }

  const orderedModes = modeOrder(phase);

  return (
    <div className="min-h-screen bg-gray-50 dark:bg-gray-900">
      {/* Top bar */}
      <div className="sticky top-0 z-30 bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700 px-4 py-3 flex items-center justify-between">
        <span className="font-bold text-lg text-gray-900 dark:text-white">Tally</span>
        <div className="flex items-center gap-3">
          <SessionCountdown expiresAt={expiresAt} onExpire={handleLogout} />
          <LogoutMenu onLogout={handleLogout} onLogoutAll={handleLogoutAll} />
        </div>
      </div>

      {/* Mode switcher */}
      <div className="sticky top-[53px] z-20 bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700 px-4 py-2">
        <div className="flex rounded-lg bg-gray-100 dark:bg-gray-700 p-1">
          {orderedModes.map((m) => (
            <button
              key={m}
              onClick={() => setMode(m)}
              className={`flex-1 py-2 text-sm font-medium rounded-md transition-colors ${
                mode === m
                  ? 'bg-white shadow text-gray-900 dark:bg-gray-600 dark:text-white'
                  : 'text-gray-500 dark:text-gray-400'
              }`}
            >
              {modeLabel(m)}
            </button>
          ))}
        </div>
      </div>

      {/* Active mode */}
      <div className="p-4">
        {(mode === 'record' || mode === 'spoil') && phase !== 'VOTING' && (
          <div className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl p-6 text-center">
            <p className="text-gray-500 dark:text-gray-400 font-medium">Available only while voting is open.</p>
            <p className="text-sm text-gray-400 dark:text-gray-500 mt-1">Current phase: {phase}</p>
          </div>
        )}
        {mode === 'record' && phase === 'VOTING' && <RecordMode csrfToken={csrfToken} />}
        {mode === 'spoil' && phase === 'VOTING' && <SpoilMode csrfToken={csrfToken} />}
        {mode === 'checkin' && <CheckinMode csrfToken={csrfToken} />}
      </div>
    </div>
  );
}

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
  const low = totalSec < 180;

  return (
    <span className={`text-sm font-mono tabular-nums ${low ? 'text-amber-600 dark:text-amber-400 animate-pulse' : 'text-gray-500 dark:text-gray-400'}`}>
      ⏱ {min}:{sec.toString().padStart(2, '0')}
    </span>
  );
}

function LogoutMenu({ onLogout, onLogoutAll }: { onLogout: () => void; onLogoutAll: () => void }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="relative">
      <button onClick={() => setOpen(!open)} className="text-sm text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200">
        Logout ▾
      </button>
      {open && (
        <>
          <div className="fixed inset-0 z-40" onClick={() => setOpen(false)} />
          <div className="absolute right-0 top-full mt-1 bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg shadow-lg py-1 z-50 min-w-[160px]">
            <button
              onClick={() => { setOpen(false); onLogout(); }}
              className="block w-full text-left px-4 py-2 text-sm hover:bg-gray-50 dark:hover:bg-gray-700 dark:text-gray-200"
            >
              Log out
            </button>
            <button
              onClick={() => { setOpen(false); onLogoutAll(); }}
              className="block w-full text-left px-4 py-2 text-sm text-red-600 dark:text-red-400 hover:bg-gray-50 dark:hover:bg-gray-700"
            >
              Log out everywhere
            </button>
          </div>
        </>
      )}
    </div>
  );
}
