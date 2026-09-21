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

  useEffect(() => {
    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, []);

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
        setPhase('success');
      } else {
        setResult({ success: false, message: data.error || 'Check-in failed' });
        setPhase('error');
      }
    } catch {
      setResult({ success: false, message: 'Network error' });
      setPhase('error');
    }
    setSubmitting(false);
  };

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
      <div className="text-sm text-gray-500">
        Checked in this session: <span className="font-semibold text-gray-900">{tally}</span>
        {lastCheckin && (
          <div className="text-xs text-gray-400 mt-1">Last: {lastCheckin}</div>
        )}
      </div>

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
              {members.map((m) => {
                const isCheckedIn = m.votingStatus === 'PAPER_ISSUED' || m.votingStatus === 'PAPER_VOTED';
                return (
                  <button
                    key={m.id}
                    onClick={() => !isCheckedIn && handleSelect(m)}
                    disabled={isCheckedIn}
                    className={`w-full text-left px-4 py-3 flex items-center justify-between min-h-[48px] ${
                      isCheckedIn ? 'opacity-50 cursor-not-allowed' : 'hover:bg-gray-50'
                    }`}
                  >
                    <div>
                      <span className="text-base">{m.full_name}</span>
                      <span className="text-sm text-gray-400 ml-2">{m.member_code}</span>
                      {isCheckedIn && (
                        <span className="ml-2 inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-600">
                          {m.votingStatus === 'PAPER_VOTED' ? 'Voted' : 'Checked-in'}
                        </span>
                      )}
                    </div>
                    {!isCheckedIn && <span className="text-xs text-gray-400">→</span>}
                  </button>
                );
              })}
            </div>
          )}
          {phase === 'results' && members.length === 0 && query.length >= 2 && (
            <p className="text-sm text-gray-400 mt-2 text-center">No members found</p>
          )}
        </div>
      )}

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
