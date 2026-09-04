'use client';
import { useState, useEffect, useRef, useCallback } from 'react';
import { useParams } from 'next/navigation';

type Match = { memberId: string; fullName: string };
type Nominee = { nominee_member_id: string | null; nominee_name: string; reason: string };

const REASON_MAX = 2000;

export default function NominatePage() {
  const params = useParams();
  const token = params.token as string;

  const [phase, setPhase] = useState<'loading' | 'ready' | 'submitted'>('loading');
  const [allowWriteIns, setAllowWriteIns] = useState(true);
  const [maxNominees, setMaxNominees] = useState(1);

  const [query, setQuery] = useState('');
  const [matches, setMatches] = useState<Match[]>([]);
  const [searching, setSearching] = useState(false);
  const [writeInDraft, setWriteInDraft] = useState('');

  const [nominees, setNominees] = useState<Nominee[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const [insertedCount, setInsertedCount] = useState(0);
  const [error, setError] = useState<string | null>(null);

  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Fetch election settings (public, non-admin) to learn the write-in toggle and nominee cap.
  useEffect(() => {
    fetch('/api/election/status')
      .then((r) => r.json())
      .then((d) => {
        setAllowWriteIns(d.allow_write_ins ?? true);
        setMaxNominees(d.max_nominees_per_member ?? 1);
        setPhase('ready');
      })
      .catch(() => setPhase('ready'));
  }, []);

  const runSearch = useCallback(
    async (q: string) => {
      if (q.trim().length < 2) {
        setMatches([]);
        return;
      }
      setSearching(true);
      try {
        const res = await fetch('/api/nominate/search', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ rawToken: token, query: q }),
        });
        const json = await res.json();
        setMatches(json.results ?? []);
      } catch {
        setMatches([]);
      } finally {
        setSearching(false);
      }
    },
    [token]
  );

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

  const atCap = nominees.length >= maxNominees;
  const alreadyPicked = (memberId: string) => nominees.some((n) => n.nominee_member_id === memberId);

  const addMatched = (m: Match) => {
    if (atCap || alreadyPicked(m.memberId)) return;
    setNominees((n) => [...n, { nominee_member_id: m.memberId, nominee_name: m.fullName, reason: '' }]);
    setQuery('');
    setMatches([]);
  };

  const addWriteIn = () => {
    const name = writeInDraft.trim();
    if (!name || atCap) return;
    setNominees((n) => [...n, { nominee_member_id: null, nominee_name: name, reason: '' }]);
    setWriteInDraft('');
  };

  const removeNominee = (index: number) => {
    setNominees((n) => n.filter((_, i) => i !== index));
  };

  const updateReason = (index: number, reason: string) => {
    setNominees((n) => n.map((nom, i) => (i === index ? { ...nom, reason: reason.slice(0, REASON_MAX) } : nom)));
  };

  const submit = async () => {
    if (nominees.length === 0) {
      setError('Add at least one nominee before submitting.');
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const res = await fetch('/api/nominate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: token, nominees }),
      });
      const json = await res.json();
      if (res.ok && json.success) {
        setInsertedCount(json.insertedCount ?? nominees.length);
        setPhase('submitted');
      } else {
        setError(json.error || 'Nomination failed.');
      }
    } catch {
      setError('Network error. Please try again.');
    } finally {
      setSubmitting(false);
    }
  };

  if (phase === 'loading') {
    return <div className="p-8 text-gray-600 dark:text-gray-400">Loading nomination form...</div>;
  }

  if (phase === 'submitted') {
    return (
      <div className="min-h-screen bg-gray-50 dark:bg-gray-900 py-12 px-4">
        <div className="max-w-lg mx-auto bg-white dark:bg-gray-800 rounded-lg shadow p-8">
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white mb-2">Nomination submitted</h1>
          <p className="text-gray-600 dark:text-gray-400">
            {insertedCount} nomination{insertedCount === 1 ? '' : 's'} recorded. Your nomination link has now been used and can&apos;t be reused.
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gray-50 dark:bg-gray-900 py-12 px-4">
      <div className="max-w-lg mx-auto">
        <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 sm:p-8">
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white mb-1">Nominate a candidate</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400 mb-6">
            Search the member roster to nominate someone{allowWriteIns ? ', or add a name that isn\'t listed' : ''}. You can nominate up to {maxNominees} member{maxNominees === 1 ? '' : 's'}.
          </p>

          {/* Roster search */}
          {!atCap && (
            <div className="mb-6">
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                Search members
              </label>
              <input
                type="text"
                value={query}
                onChange={(e) => onQueryChange(e.target.value)}
                placeholder="Type at least 2 characters..."
                className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
              />
              {searching && <p className="text-xs text-gray-400 mt-1">Searching...</p>}
              {matches.length > 0 && (
                <div className="mt-2 border rounded divide-y dark:divide-gray-700 dark:border-gray-600">
                  {matches.map((m) => (
                    <button
                      key={m.memberId}
                      type="button"
                      onClick={() => addMatched(m)}
                      disabled={alreadyPicked(m.memberId)}
                      className="w-full text-left px-3 py-2 text-sm hover:bg-gray-50 dark:hover:bg-gray-700 dark:text-white disabled:opacity-40"
                    >
                      {m.fullName}
                    </button>
                  ))}
                </div>
              )}

              {allowWriteIns && (
                <div className="mt-4 flex gap-2">
                  <input
                    type="text"
                    value={writeInDraft}
                    onChange={(e) => setWriteInDraft(e.target.value.slice(0, 100))}
                    placeholder="Or type a name not on the roster..."
                    className="flex-1 p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  />
                  <button
                    type="button"
                    onClick={addWriteIn}
                    disabled={!writeInDraft.trim()}
                    className="px-4 py-2 bg-gray-700 hover:bg-gray-800 text-white rounded font-medium disabled:opacity-50"
                  >
                    Add
                  </button>
                </div>
              )}
            </div>
          )}

          {atCap && (
            <p className="mb-6 text-sm text-amber-700 dark:text-amber-400 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded p-3">
              You&apos;ve reached the limit of {maxNominees} nominee{maxNominees === 1 ? '' : 's'}. Remove one below to change your selection.
            </p>
          )}

          {/* Selected nominees */}
          {nominees.length > 0 && (
            <div className="space-y-3 mb-6">
              {nominees.map((nom, i) => (
                <div key={i} className="border rounded p-3 dark:border-gray-600">
                  <div className="flex items-center justify-between mb-2">
                    <span className="font-medium text-gray-900 dark:text-white">{nom.nominee_name}</span>
                    <button
                      type="button"
                      onClick={() => removeNominee(i)}
                      className="text-xs text-red-600 hover:text-red-700"
                    >
                      Remove
                    </button>
                  </div>
                  <textarea
                    value={nom.reason}
                    onChange={(e) => updateReason(i, e.target.value)}
                    placeholder="Reason for nominating (optional)"
                    rows={2}
                    maxLength={REASON_MAX}
                    className="w-full p-2 border rounded text-sm dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  />
                  <p className="text-right text-xs text-gray-400 mt-1">{nom.reason.length}/{REASON_MAX}</p>
                </div>
              ))}
            </div>
          )}

          {error && (
            <div className="mb-4 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded text-red-800 dark:text-red-300 text-sm">
              {error}
            </div>
          )}

          <button
            type="button"
            onClick={submit}
            disabled={submitting || nominees.length === 0}
            className="w-full py-2 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium disabled:opacity-50"
          >
            {submitting ? 'Submitting...' : 'Submit nomination'}
          </button>
        </div>
      </div>
    </div>
  );
}
