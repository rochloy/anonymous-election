'use client';
import { useState } from 'react';

export default function AdminDashboard() {
  const [secret, setSecret] = useState('');
  const [memberCode, setMemberCode] = useState('');
  const [candidateId, setCandidateId] = useState('');
  const [msg, setMsg] = useState<string | null>(null);

  const submitPaper = async (e: React.FormEvent) => {
    e.preventDefault();
    const r = await fetch('/api/admin/paper-vote', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-admin-secret': secret },
      body: JSON.stringify({ memberCode, candidateId }),
    });
    const d = await r.json();
    setMsg(d.success ? d.message : d.error);
  };

  return (
    <div className="p-8 max-w-2xl mx-auto">
      <h1 className="text-2xl font-bold mb-6">Admin Dashboard</h1>
      <form onSubmit={submitPaper} className="space-y-4">
        <input
          type="password"
          placeholder="Admin secret"
          value={secret}
          onChange={e => setSecret(e.target.value)}
          className="w-full p-2 border rounded"
          required
        />
        <input
          placeholder="Member code (e.g. M-a1b2c3d4)"
          value={memberCode}
          onChange={e => setMemberCode(e.target.value)}
          className="w-full p-2 border rounded"
          required
        />
        <input
          placeholder="Candidate UUID"
          value={candidateId}
          onChange={e => setCandidateId(e.target.value)}
          className="w-full p-2 border rounded"
          required
        />
        <button type="submit" className="px-6 py-2 bg-blue-600 text-white rounded">
          Record paper vote
        </button>
      </form>
      {msg && <p className="mt-4">{msg}</p>}
    </div>
  );
}
