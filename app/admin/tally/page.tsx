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

export default function TallyPage() {
  const [secret, setSecret] = useState('');
  const [loggedIn, setLoggedIn] = useState(false);
  const [csrfToken, setCsrfToken] = useState('');
  const [expiresAt, setExpiresAt] = useState<number>(0);
  const [mode, setMode] = useState<Mode>('record');
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
    <span className={`text-sm font-mono tabular-nums ${low ? 'text-amber-600 animate-pulse' : 'text-gray-500'}`}>
      ⏱ {min}:{sec.toString().padStart(2, '0')}
    </span>
  );
}

function LogoutMenu({ onLogout, onLogoutAll }: { onLogout: () => void; onLogoutAll: () => void }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="relative">
      <button onClick={() => setOpen(!open)} className="text-sm text-gray-500 hover:text-gray-700">
        Logout ▾
      </button>
      {open && (
        <>
          <div className="fixed inset-0 z-40" onClick={() => setOpen(false)} />
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
        </>
      )}
    </div>
  );
}


