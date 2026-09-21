'use client';

import { useState } from 'react';

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
          <form onSubmit={(e) => e.preventDefault()}>
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
          <SessionCountdown expiresAt={expiresAt} onExpire={() => setLoggedIn(false)} />
          <LogoutMenu onLogout={() => setLoggedIn(false)} onLogoutAll={() => setLoggedIn(false)} />
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
