'use client';

import { useState, useEffect, useCallback } from 'react';
import QrScanner from './QrScanner';
import { validateBallotScan } from '@/lib/ballot-scan';

type Phase = 'idle' | 'scanning' | 'validating' | 'scanned' | 'success' | 'error';

interface Candidate {
  id: string;
  full_name: string;
}

export default function RecordMode({ csrfToken }: { csrfToken: string }) {
  const [phase, setPhase] = useState<Phase>('idle');
  const [candidates, setCandidates] = useState<Candidate[]>([]);
  const [ballotId, setBallotId] = useState('');
  const [ballotStatus, setBallotStatus] = useState('');
  const [selectedCandidate, setSelectedCandidate] = useState<string | null>(null);
  const [result, setResult] = useState<{ success: boolean; message: string; receiptCode?: string } | null>(null);
  const [tally, setTally] = useState(0);
  const [lastReceipt, setLastReceipt] = useState<{ code: string; name: string } | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    fetch('/api/candidates')
      .then((r) => r.json())
      .then((data) => setCandidates(Array.isArray(data) ? data : []))
      .catch(() => {});
  }, []);

  const handleScan = useCallback((raw: string) => {
    void (async () => {
      setPhase('validating');
      const result = await validateBallotScan(raw);
      if (result.ok) {
        setBallotId(result.ballotId);
        setBallotStatus(result.status);
        setSelectedCandidate(null);
        setPhase('scanned');
      } else {
        setResult({ success: false, message: result.error });
        setPhase('error');
      }
    })();
  }, []);

  const handleCancelScan = useCallback(() => setPhase('idle'), []);

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
        setPhase('success');
      } else {
        setResult({ success: false, message: data.error || 'Vote failed' });
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
      setBallotStatus('');
      setSelectedCandidate(null);
    }, 3000);
    return () => clearTimeout(timer);
  }, [phase]);

  const truncateId = (id: string) => {
    if (id.length <= 16) return id;
    return `…${id.slice(-12)}`;
  };

  if (phase === 'scanning') {
    return <QrScanner onScan={handleScan} onCancel={handleCancelScan} />;
  }

  if (phase === 'validating') {
    return (
      <div className="bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 p-6 text-center">
        <p className="text-gray-500 dark:text-gray-400 font-medium">Validating ballot…</p>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <div className="text-sm text-gray-500 dark:text-gray-400">
        Recorded this session: <span className="font-semibold text-gray-900 dark:text-white">{tally}</span>
        {lastReceipt && (
          <div className="text-xs text-gray-400 dark:text-gray-500 mt-1">
            Last: {lastReceipt.code} · {lastReceipt.name}
          </div>
        )}
      </div>

      {phase === 'idle' && (
        <button
          onClick={() => setPhase('scanning')}
          className="w-full bg-blue-600 text-white font-semibold rounded-xl px-4 py-4 text-base flex items-center justify-center gap-2"
        >
          📷 Scan ballot
        </button>
      )}

      {phase === 'scanned' && (
        <div className="space-y-4">
          <div className="bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 p-4">
            <p className="text-sm text-gray-500 dark:text-gray-400 mb-1">Ballot scanned</p>
            <p className="font-mono text-sm text-gray-700 dark:text-gray-300">{truncateId(ballotId)}</p>
            <p className="text-xs text-gray-400 dark:text-gray-500 mt-1">Status: {ballotStatus}</p>
          </div>

          <div>
            <p className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Candidate:</p>
            <div className="space-y-2">
              {candidates.map((c) => (
                <label
                  key={c.id}
                  className={`flex items-center gap-3 p-3 rounded-xl border-2 cursor-pointer transition-colors min-h-[48px] ${
                    selectedCandidate === c.id
                      ? 'border-blue-600 bg-blue-50 dark:bg-blue-900/30'
                      : 'border-gray-200 dark:border-gray-600 hover:border-gray-300 dark:hover:border-gray-500'
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
                    selectedCandidate === c.id ? 'border-blue-600' : 'border-gray-300 dark:border-gray-500'
                  }`}>
                    {selectedCandidate === c.id && <span className="w-2.5 h-2.5 rounded-full bg-blue-600" />}
                  </span>
                  <span className="text-base text-gray-900 dark:text-white">{c.full_name}</span>
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
              onClick={() => { setBallotId(''); setSelectedCandidate(null); setPhase('scanning'); }}
              className="px-4 py-3 text-gray-600 dark:text-gray-300 font-medium rounded-xl border border-gray-200 dark:border-gray-600"
            >
              Rescan
            </button>
          </div>
        </div>
      )}

      {phase === 'success' && result && (
        <div className="bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-xl p-6 text-center space-y-2">
          <p className="text-green-700 dark:text-green-300 font-semibold text-lg">✓ Recorded</p>
          {result.receiptCode && (
            <p className="font-mono text-xl text-green-800 dark:text-green-300">{result.receiptCode}</p>
          )}
          {lastReceipt && <p className="text-green-700 dark:text-green-300">{lastReceipt.name}</p>}
          <p className="text-sm text-green-600 dark:text-green-400">Next ballot in 3…</p>
        </div>
      )}

      {phase === 'error' && result && (
        <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-xl p-6 text-center space-y-2">
          <p className="text-red-700 dark:text-red-300 font-semibold text-lg">⚠ Not recorded</p>
          <p className="text-red-600 dark:text-red-400">{result.message}</p>
          <p className="text-sm text-red-500 dark:text-red-400">Discard this ballot.</p>
          <p className="text-sm text-red-400 dark:text-red-500">Next ballot in 3…</p>
        </div>
      )}
    </div>
  );
}
