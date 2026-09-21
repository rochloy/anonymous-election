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
        setPhase('success');
      } else {
        setResult({ success: false, message: data.error || 'Void failed' });
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
      <div className="text-sm text-gray-500">
        Voided this session: <span className="font-semibold text-gray-900">{tally}</span>
      </div>

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

      {phase === 'success' && result && (
        <div className="bg-green-50 border border-green-200 rounded-xl p-6 text-center space-y-2">
          <p className="text-green-700 font-semibold text-lg">✓ Voided</p>
          <p className="text-sm text-green-600">Next ballot in 3…</p>
        </div>
      )}

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
