'use client';
import { useState, useEffect } from 'react';
import Link from 'next/link';

interface ElectionStatus {
  phase: string;
  nomination_start: string | null;
  nomination_end: string | null;
  voting_start: string | null;
  voting_end: string | null;
}

export default function HomePage() {
  const [status, setStatus] = useState<ElectionStatus | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch('/api/election/status')
      .then(r => r.json())
      .then(d => { setStatus(d); setLoading(false); })
      .catch(() => setLoading(false));
  }, []);

  const phaseLabels: Record<string, string> = {
    SETUP: 'Setup',
    NOMINATION: 'Nomination Open',
    NOMINATION_CLOSED: 'Nomination Closed',
    VOTING: 'Voting Open',
    VOTING_CLOSED: 'Voting Closed',
    COMPLETED: 'Completed',
  };

  const phaseColors: Record<string, string> = {
    SETUP: 'bg-gray-100 text-gray-700',
    NOMINATION: 'bg-green-100 text-green-700',
    NOMINATION_CLOSED: 'bg-yellow-100 text-yellow-700',
    VOTING: 'bg-blue-100 text-blue-700',
    VOTING_CLOSED: 'bg-orange-100 text-orange-700',
    COMPLETED: 'bg-purple-100 text-purple-700',
  };

  if (loading) return <div className="min-h-screen flex items-center justify-center">Loading election status...</div>;

  const phase = status?.phase || 'UNKNOWN';
  const label = phaseLabels[phase] || phase;
  const colorClass = phaseColors[phase] || 'bg-gray-100 text-gray-700';

  return (
    <div className="min-h-screen bg-gray-50 dark:bg-gray-900">
      <header className="bg-white dark:bg-gray-800 shadow-sm">
        <div className="max-w-4xl mx-auto px-4 py-4 flex justify-between items-center">
          <h1 className="text-xl font-bold text-gray-900 dark:text-white">Committee Head Election</h1>
          <nav className="flex gap-4">
            <Link href="/results" className="text-sm text-blue-600 hover:underline">Results</Link>
            <Link href="/admin" className="text-sm text-gray-600 hover:underline">Admin</Link>
          </nav>
        </div>
      </header>

      <main className="max-w-4xl mx-auto px-4 py-12">
        <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-8">
          <div className="mb-8">
            <span className={`inline-block px-4 py-2 rounded-full text-sm font-medium ${colorClass}`}>
              {label}
            </span>
          </div>

          <div className="grid gap-6 md:grid-cols-2 mb-8">
            {status?.nomination_start && (
              <div className="p-4 bg-gray-50 dark:bg-gray-700 rounded">
                <h3 className="font-medium text-gray-900 dark:text-white">Nomination Period</h3>
                <p className="text-sm text-gray-600 dark:text-gray-400">
                  {new Date(status.nomination_start).toLocaleString()} — {status.nomination_end ? new Date(status.nomination_end).toLocaleString() : 'TBD'}
                </p>
              </div>
            )}
            {status?.voting_start && (
              <div className="p-4 bg-gray-50 dark:bg-gray-700 rounded">
                <h3 className="font-medium text-gray-900 dark:text-white">Voting Period</h3>
                <p className="text-sm text-gray-600 dark:text-gray-400">
                  {new Date(status.voting_start).toLocaleString()} — {status.voting_end ? new Date(status.voting_end).toLocaleString() : 'TBD'}
                </p>
              </div>
            )}
          </div>

          <div className="space-y-4">
            {phase === 'VOTING' && (
              <div className="p-4 border border-blue-200 bg-blue-50 dark:bg-blue-900/20 rounded">
                <h3 className="font-medium text-gray-900 dark:text-white mb-2">Cast Your Vote</h3>
                <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                  Use the magic link sent to your email, or enter your token below:
                </p>
                <form className="flex gap-2 max-w-md">
                  <input
                    type="text"
                    placeholder="Enter your voting token"
                    className="flex-1 p-2 border rounded"
                  />
                  <button type="submit" className="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700">
                    Vote
                  </button>
                </form>
                <p className="mt-2 text-xs text-gray-500">
                  Your token is a long hex string. The magic link format:{' '}
                  <code className="bg-gray-100 dark:bg-gray-700 px-1 rounded">{"{/vote/<token>}"}</code>
                </p>
              </div>
            )}

            <Link
              href="/results"
              className="inline-block px-6 py-3 bg-gray-100 dark:bg-gray-700 text-gray-900 dark:text-white rounded hover:bg-gray-200 dark:hover:bg-gray-600 transition"
            >
              View Election Results
            </Link>

            <Link
              href="/admin"
              className="inline-block px-6 py-3 border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-300 rounded hover:bg-gray-50 dark:hover:bg-gray-700 transition"
            >
              Admin Dashboard
            </Link>
          </div>

          <div className="mt-8 p-4 bg-gray-50 dark:bg-gray-700 rounded text-sm text-gray-600 dark:text-gray-400">
            <h4 className="font-medium mb-2">How it works</h4>
            <ul className="list-disc list-inside space-y-1">
              <li>Each member receives a unique, single-use voting token via email</li>
              <li>Tokens are used once at <code className="bg-gray-100 dark:bg-gray-600 px-1 rounded">{"{/vote/<token>}"}</code></li>
              <li>Votes are anonymous — no link between your identity and your ballot</li>
              <li>After voting, you receive a receipt code to verify your vote was counted</li>
              <li>Results are published after voting closes</li>
            </ul>
          </div>
        </div>
      </main>

      <footer className="border-t border-gray-200 dark:border-gray-700 py-8">
        <div className="max-w-4xl mx-auto px-4 text-center text-sm text-gray-500 dark:text-gray-400">
          <p>Committee Head Election — Anonymous Digital Voting System</p>
        </div>
      </footer>
    </div>
  );
}