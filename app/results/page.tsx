'use client';
import { useState, useEffect } from 'react';
import Link from 'next/link';

type ResultsData = {
  published: boolean;
  phase?: string;
  totalVotes?: number;
  receiptStatus?: {
    searchedCode: string;
    found: boolean;
  };
  results?: Array<{
    id: string;
    full_name: string;
    votes: number;
    percentage: number;
  }>;
};

export default function ResultsPage() {
  const [receipt, setReceipt] = useState('');
  const [data, setData] = useState<ResultsData | null>(null);
  const [loading, setLoading] = useState(false);

  const fetchResults = async (lookupReceipt: string) => {
    setLoading(true);
    const url = lookupReceipt ? `/api/results?receipt=${encodeURIComponent(lookupReceipt)}` : '/api/results';
    const r = await fetch(url);
    const d: ResultsData = await r.json();
    setData(d);
    setLoading(false);
  };

  // Auto-load on mount
  useEffect(() => {
    const timer = setTimeout(() => {
      void fetchResults('');
    }, 0);

    return () => clearTimeout(timer);
  }, []);

  return (
    <div className="min-h-screen bg-gray-50 dark:bg-gray-900 py-12 px-4">
      <div className="max-w-3xl mx-auto">
        <h1 className="text-2xl font-bold text-gray-900 dark:text-white mb-6">Election Results</h1>

        {/* Receipt verification */}
        <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 mb-6">
          <h2 className="font-medium text-gray-900 dark:text-white mb-3">Verify Your Vote</h2>
          <div className="flex gap-2 mb-2">
            <input
              placeholder="Receipt code (e.g. VC-a1b2c3d4)"
              value={receipt}
              onChange={e => setReceipt(e.target.value)}
              className="flex-1 p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            />
            <button onClick={() => void fetchResults(receipt)} className="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700">
              {loading ? 'Loading...' : 'Check'}
            </button>
          </div>
          <p className="text-xs text-gray-500">
            Or use the <Link href="/verify" className="text-blue-600 hover:underline">full verification page</Link> with ballot ID + receipt code.
          </p>
          {data?.receiptStatus && (
            <p className="mt-3 text-sm">
              Receipt <code className="bg-gray-100 dark:bg-gray-700 px-1 rounded">{data.receiptStatus.searchedCode}</code>:{' '}
              {data.receiptStatus.found
                ? <span className="text-green-600 font-medium">found ✓</span>
                : <span className="text-red-600 font-medium">not found ✗</span>}
            </p>
          )}
        </div>

        {/* Results tally */}
        {data && !data.published && (
          <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6">
            <p className="text-gray-600 dark:text-gray-400">
              Voting is still open ({data.phase}). Final results will be published after voting closes.
            </p>
          </div>
        )}

        {data?.published && (
          <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6">
            <p className="mb-4 text-gray-900 dark:text-white">
              Total votes: <span className="font-bold">{data.totalVotes}</span>
            </p>
            <div className="space-y-3">
              {data.results?.map(c => (
                <div key={c.id} className="p-4 border rounded dark:border-gray-700">
                  <div className="flex justify-between mb-2">
                    <span className="font-semibold text-gray-900 dark:text-white">{c.full_name}</span>
                    <span className="text-gray-700 dark:text-gray-300">{c.votes} votes ({c.percentage}%)</span>
                  </div>
                  <div className="h-2 bg-gray-200 dark:bg-gray-700 rounded">
                    <div className="h-2 bg-blue-600 rounded" style={{ width: `${c.percentage}%` }} />
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        <div className="mt-6 text-center">
          <Link href="/" className="text-sm text-blue-600 hover:underline">← Back to Home</Link>
        </div>
      </div>
    </div>
  );
}
