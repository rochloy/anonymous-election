'use client';
import { useState, useEffect } from 'react';
import { useParams } from 'next/navigation';

export default function VotePage() {
  const params = useParams();
  const token = params.token as string;

  const [status, setStatus] = useState<'loading' | 'invalid' | 'ready' | 'voted'>('loading');
  const [candidates, setCandidates] = useState<Array<{ id: string; full_name: string; statement: string | null; photo_url: string | null }>>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [receipt, setReceipt] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!token) return;
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
            const candidatesData = (await candidatesRes.json()) as Array<{
              id: string;
              full_name: string;
              statement: string | null;
              photo_url: string | null;
            }>;
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

  const castVote = async () => {
    if (!selected || !token) return;
    const r = await fetch('/api/vote', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ rawToken: token, candidateId: selected }),
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
        {candidates.map((c) => (
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
