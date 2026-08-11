'use client';
import { useState, useEffect, Suspense } from 'react';
import { useSearchParams } from 'next/navigation';

function VerifyForm() {
  const searchParams = useSearchParams();
  const [ballotId, setBallotId] = useState('');
  const [receiptCode, setReceiptCode] = useState('');
  const [data, setData] = useState<any>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Auto-fill ballot_id from URL query param (e.g. when arriving via QR scan).
  useEffect(() => {
    const id = searchParams.get('ballot_id');
    if (id) setBallotId(decodeURIComponent(id));
  }, [searchParams]);

  const verify = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError(null);
    setData(null);

    try {
      const params = new URLSearchParams({ ballot_id: ballotId });
      if (receiptCode) params.append('receipt_code', receiptCode);

      const r = await fetch(`/api/verify?${params}`);
      const d = await r.json();

      if (!r.ok) {
        setError(d.error || 'Verification failed');
      } else {
        setData(d);
      }
    } catch {
      setError('Server error');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-gray-50 dark:bg-gray-900 py-12 px-4">
      <div className="max-w-2xl mx-auto">
        <h1 className="text-2xl font-bold text-gray-900 dark:text-white mb-2">Verify Your Vote</h1>
        <p className="text-sm text-gray-600 dark:text-gray-400 mb-6">
          Enter your ballot ID (and receipt code for digital votes) to confirm your vote was recorded.
        </p>

        <form onSubmit={verify} className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 space-y-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Ballot ID <span className="text-red-500">*</span>
            </label>
            <input
              type="text"
              value={ballotId}
              onChange={e => setBallotId(e.target.value)}
              placeholder="e.g. abc123.def456..."
              className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
              required
            />
            <p className="mt-1 text-xs text-gray-500">
              The long code from your voting confirmation or printed on your paper ballot.
            </p>
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Receipt Code <span className="text-gray-400">(digital votes only)</span>
            </label>
            <input
              type="text"
              value={receiptCode}
              onChange={e => setReceiptCode(e.target.value)}
              placeholder="e.g. VC-a1b2c3d4e5"
              className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            />
            <p className="mt-1 text-xs text-gray-500">
              The short code shown after you cast your digital vote. Paper votes don't need this.
            </p>
          </div>

          <button
            type="submit"
            disabled={loading}
            className="w-full px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700 disabled:opacity-50"
          >
            {loading ? 'Verifying...' : 'Verify Vote'}
          </button>
        </form>

        {error && (
          <div className="mt-4 p-4 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded">
            <p className="text-red-700 dark:text-red-400">{error}</p>
          </div>
        )}

        {data && (
          <div className="mt-4 p-6 bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-lg">
            <h3 className="font-semibold text-green-800 dark:text-green-400 mb-3">
              {data.found ? '✓ Vote Verified' : '✗ Vote Not Found'}
            </h3>
            {data.found ? (
              <dl className="space-y-2 text-sm">
                <div className="flex justify-between">
                  <dt className="text-gray-600 dark:text-gray-400">Channel:</dt>
                  <dd className="font-medium text-gray-900 dark:text-white">{data.channel}</dd>
                </div>
                <div className="flex justify-between">
                  <dt className="text-gray-600 dark:text-gray-400">Candidate:</dt>
                  <dd className="font-medium text-gray-900 dark:text-white">{data.candidate_name}</dd>
                </div>
                <div className="flex justify-between">
                  <dt className="text-gray-600 dark:text-gray-400">Cast Date:</dt>
                  <dd className="font-medium text-gray-900 dark:text-white">{data.cast_date}</dd>
                </div>
                {data.receipt_match !== undefined && (
                  <div className="flex justify-between">
                    <dt className="text-gray-600 dark:text-gray-400">Receipt:</dt>
                    <dd className="font-medium text-gray-900 dark:text-white">
                      {data.receipt_match ? '✓ Matched' : '✗ Does not match'}
                    </dd>
                  </div>
                )}
              </dl>
            ) : (
              <p className="text-sm text-gray-600 dark:text-gray-400">
                No ballot found with this ID. Check that you entered the full ballot ID correctly.
              </p>
            )}
          </div>
        )}

        <div className="mt-6 text-center">
          <a href="/" className="text-sm text-blue-600 hover:underline">← Back to Home</a>
        </div>
      </div>
    </div>
  );
}

export default function VerifyPage() {
  return (
    <Suspense fallback={
      <div className="min-h-screen bg-gray-50 dark:bg-gray-900 py-12 px-4">
        <div className="max-w-2xl mx-auto">
          <p className="text-gray-600 dark:text-gray-400">Loading verification form…</p>
        </div>
      </div>
    }>
      <VerifyForm />
    </Suspense>
  );
}
