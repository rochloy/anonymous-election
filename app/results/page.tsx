'use client';
import { useState } from 'react';

export default function ResultsPage() {
  const [receipt, setReceipt] = useState('');
  const [data, setData] = useState<any>(null);
  const [loading, setLoading] = useState(false);

  const fetchResults = async () => {
    setLoading(true);
    const url = receipt ? `/api/results?receipt=${encodeURIComponent(receipt)}` : '/api/results';
    const r = await fetch(url);
    const d = await r.json();
    setData(d);
    setLoading(false);
  };

  return (
    <div className="p-8 max-w-3xl mx-auto">
      <h1 className="text-2xl font-bold mb-6">Election Results</h1>
      <div className="flex gap-2 mb-6">
        <input
          placeholder="Receipt code (optional)"
          value={receipt}
          onChange={e => setReceipt(e.target.value)}
          className="flex-1 p-2 border rounded"
        />
        <button onClick={fetchResults} className="px-4 py-2 bg-blue-600 text-white rounded">
          {loading ? 'Loading...' : 'Show results'}
        </button>
      </div>
      {data && !data.published && <p>Voting is still open. Results not yet published.</p>}
      {data?.published && (
        <div>
          <p className="mb-4">Total votes: {data.totalVotes}</p>
          <div className="space-y-3">
            {data.results.map((c: any) => (
              <div key={c.id} className="p-4 border rounded">
                <div className="flex justify-between">
                  <span className="font-semibold">{c.full_name}</span>
                  <span>{c.votes} votes ({c.percentage}%)</span>
                </div>
                <div className="h-2 bg-gray-200 rounded mt-2">
                  <div className="h-2 bg-blue-600 rounded" style={{ width: `${c.percentage}%` }} />
                </div>
              </div>
            ))}
          </div>
          {data.receiptStatus && (
            <p className="mt-6">
              Receipt {data.receiptStatus.searchedCode}: {data.receiptStatus.found ? 'found ✓' : 'not found ✗'}
            </p>
          )}
        </div>
      )}
    </div>
  );
}
