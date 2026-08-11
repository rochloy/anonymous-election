'use client';

import { useState, useEffect } from 'react';

interface Member {
  id: string;
  member_code: string;
  full_name: string;
  email: string | null;
  phone: string | null;
  votingStatus: 'ELIGIBLE' | 'DIGITAL_VOTED' | 'PAPER_ISSUED' | 'PAPER_VOTED';
  paperBallot?: {
    ballotId: string;
    shortCode: string;
    qrDataUrl?: string;
    qrSvg?: string;
    issuedAt: string;
    votedAt?: string;
  } | null;
}

interface Candidate {
  id: string;
  full_name: string;
  statement?: string;
}

interface IssuedBallotModal {
  memberName: string;
  ballotId: string;
  shortCode: string;
  qrDataUrl?: string;
  qrSvg?: string;
}

/**
 * Extract the ballot_id from a scanned QR payload.
 * Accepts both the new URL format (`https://.../verify?ballot_id=PAPER:...`)
 * and the legacy raw format (`PAPER:...`) for already-printed ballots.
 */
function extractBallotId(decodedText: string): string {
  try {
    const url = new URL(decodedText);
    const id = url.searchParams.get('ballot_id');
    if (id) return decodeURIComponent(id);
  } catch {
    // not a URL — fall through to raw text
  }
  return decodedText;
}

export default function AdminDashboard() {
  const [secret, setSecret] = useState('');
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const [activeTab, setActiveTab] = useState<'members' | 'record' | 'stats'>('members');

  // Stats
  const [stats, setStats] = useState<{ totalMembers: number; currentPhase: string } | null>(null);

  // Search Members
  const [searchQuery, setSearchQuery] = useState('');
  const [members, setMembers] = useState<Member[]>([]);
  const [searching, setSearching] = useState(false);

  // Modal for Issued Paper Ballot
  const [issuedModal, setIssuedModal] = useState<IssuedBallotModal | null>(null);

  // Record Vote State
  const [candidates, setCandidates] = useState<Candidate[]>([]);
  const [recordBallotId, setRecordBallotId] = useState('');
  const [selectedCandidate, setSelectedCandidate] = useState('');
  const [invalidReason, setInvalidReason] = useState('');
  const [showScanner, setShowScanner] = useState(false);

  // Status messages
  const [msg, setMsg] = useState<{ text: string; type: 'success' | 'error' } | null>(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const saved = localStorage.getItem('admin_secret');
    if (saved) {
      setSecret(saved);
      setIsAuthenticated(true);
      fetchCandidates();
      fetchStats(saved);
    } else {
      fetchCandidates();
    }
  }, []);

  useEffect(() => {
    let scanner: any = null;
    if (showScanner) {
      import('html5-qrcode').then(({ Html5QrcodeScanner }) => {
        scanner = new Html5QrcodeScanner(
          'qr-reader',
          { fps: 10, qrbox: { width: 250, height: 250 } },
          /* verbose= */ false
        );
        scanner.render(
          (decodedText: string) => {
            setRecordBallotId(extractBallotId(decodedText));
            setShowScanner(false);
            if (scanner) {
              scanner.clear().catch(console.error);
            }
          },
          () => {}
        );
      });
    }
    return () => {
      if (scanner) {
        scanner.clear().catch(console.error);
      }
    };
  }, [showScanner]);

  const handleLogin = (e: React.FormEvent) => {
    e.preventDefault();
    if (!secret) return;
    localStorage.setItem('admin_secret', secret);
    setIsAuthenticated(true);
    fetchStats(secret);
    setMsg({ text: 'Admin secret saved.', type: 'success' });
  };

  const handleLogout = () => {
    localStorage.removeItem('admin_secret');
    setSecret('');
    setIsAuthenticated(false);
    setStats(null);
  };

  const fetchCandidates = async () => {
    try {
      const res = await fetch('/api/candidates');
      if (res.ok) {
        const data = await res.json();
        setCandidates(data);
      }
    } catch {
      // Ignore fallback
    }
  };

  const fetchStats = async (secKey: string) => {
    try {
      const res = await fetch('/api/admin/stats', {
        headers: { 'x-admin-secret': secKey },
      });
      if (res.ok) {
        const data = await res.json();
        setStats(data);
      }
    } catch {
      // Ignore
    }
  };

  const searchMembers = async (e?: React.FormEvent) => {
    if (e) e.preventDefault();
    if (searchQuery.trim().length < 2) {
      setMsg({ text: 'Search query must be at least 2 characters', type: 'error' });
      return;
    }

    setSearching(true);
    setMsg(null);

    try {
      const res = await fetch(`/api/admin/members?q=${encodeURIComponent(searchQuery)}`, {
        headers: { 'x-admin-secret': secret },
      });
      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to search members', type: 'error' });
      } else {
        setMembers(data.members || []);
      }
    } catch {
      setMsg({ text: 'Server error during search', type: 'error' });
    } finally {
      setSearching(false);
    }
  };

  const issuePaperBallot = async (member: Member) => {
    setLoading(true);
    setMsg(null);

    try {
      const res = await fetch('/api/admin/paper-ballot', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-admin-secret': secret,
        },
        body: JSON.stringify({ memberId: member.id }),
      });

      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to issue paper ballot', type: 'error' });
      } else {
        setIssuedModal({
          memberName: member.full_name,
          ballotId: data.ballotId,
          shortCode: data.shortCode,
          qrDataUrl: data.qrDataUrl,
          qrSvg: data.qrSvg,
        });
        // Refresh search results
        searchMembers();
      }
    } catch {
      setMsg({ text: 'Server error issuing paper ballot', type: 'error' });
    } finally {
      setLoading(false);
    }
  };

  const handleRecordPaperVote = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!recordBallotId || !selectedCandidate) {
      setMsg({ text: 'Please enter a Ballot ID and select a candidate.', type: 'error' });
      return;
    }

    setLoading(true);
    setMsg(null);

    try {
      const res = await fetch('/api/admin/paper-vote', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-admin-secret': secret,
        },
        body: JSON.stringify({ ballotId: recordBallotId.trim(), candidateId: selectedCandidate }),
      });

      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to record paper vote', type: 'error' });
      } else {
        setMsg({ text: `Paper vote recorded successfully! Receipt Code: ${data.receiptCode}`, type: 'success' });
        setRecordBallotId('');
        setSelectedCandidate('');
      }
    } catch {
      setMsg({ text: 'Server error recording paper vote', type: 'error' });
    } finally {
      setLoading(false);
    }
  };

  const handleSpoilBallot = async () => {
    if (!recordBallotId) {
      setMsg({ text: 'Please enter a Ballot ID to spoil.', type: 'error' });
      return;
    }

    setLoading(true);
    setMsg(null);

    try {
      const res = await fetch('/api/admin/paper-invalid', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-admin-secret': secret,
        },
        body: JSON.stringify({ ballotId: recordBallotId.trim(), reason: invalidReason || 'Spoiled by admin' }),
      });

      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to spoil ballot', type: 'error' });
      } else {
        setMsg({ text: 'Paper ballot marked as spoiled/invalid.', type: 'success' });
        setRecordBallotId('');
        setInvalidReason('');
      }
    } catch {
      setMsg({ text: 'Server error spoiling ballot', type: 'error' });
    } finally {
      setLoading(false);
    }
  };

  if (!isAuthenticated) {
    return (
      <div className="min-h-screen bg-gray-50 dark:bg-gray-900 py-12 px-4 flex items-center justify-center">
        <div className="max-w-md w-full bg-white dark:bg-gray-800 rounded-lg shadow-md p-8">
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white mb-2">Admin Dashboard</h1>
          <p className="text-sm text-gray-600 dark:text-gray-400 mb-6">Enter Admin Secret to access management functions.</p>
          <form onSubmit={handleLogin} className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                Admin Secret
              </label>
              <input
                type="password"
                value={secret}
                onChange={e => setSecret(e.target.value)}
                placeholder="Enter admin secret..."
                className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                required
              />
            </div>
            <button
              type="submit"
              className="w-full py-2 px-4 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium"
            >
              Access Dashboard
            </button>
          </form>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gray-50 dark:bg-gray-900 py-8 px-4 sm:px-6 lg:px-8">
      <div className="max-w-5xl mx-auto">
        {/* Header */}
        <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center mb-8 gap-4">
          <div>
            <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Election Admin Dashboard</h1>
            <p className="text-sm text-gray-500 dark:text-gray-400">
              Manage member voting eligibility, paper ballot issuance, and paper vote recording.
            </p>
          </div>
          <button
            onClick={handleLogout}
            className="px-3 py-1.5 text-xs font-medium border border-gray-300 dark:border-gray-600 rounded text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700"
          >
            Clear Admin Auth
          </button>
        </div>

        {/* Stats Bar */}
        {stats && (
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 mb-6">
            <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow border border-gray-200 dark:border-gray-700">
              <span className="text-xs text-gray-500 uppercase tracking-wider font-semibold">Total Members</span>
              <p className="text-2xl font-bold text-gray-900 dark:text-white">{stats.totalMembers}</p>
            </div>
            <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow border border-gray-200 dark:border-gray-700">
              <span className="text-xs text-gray-500 uppercase tracking-wider font-semibold">Current Phase</span>
              <p className="text-2xl font-bold text-blue-600 dark:text-blue-400">{stats.currentPhase}</p>
            </div>
          </div>
        )}

        {/* Tabs */}
        <div className="flex border-b border-gray-200 dark:border-gray-700 mb-6">
          <button
            onClick={() => setActiveTab('members')}
            className={`py-2 px-4 font-medium text-sm border-b-2 ${
              activeTab === 'members'
                ? 'border-blue-600 text-blue-600 dark:text-blue-400'
                : 'border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400'
            }`}
          >
            Member Search & Issue Paper Ballot
          </button>
          <button
            onClick={() => setActiveTab('record')}
            className={`py-2 px-4 font-medium text-sm border-b-2 ${
              activeTab === 'record'
                ? 'border-blue-600 text-blue-600 dark:text-blue-400'
                : 'border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400'
            }`}
          >
            Record / Spoil Paper Vote
          </button>
        </div>

        {/* Status Message Toast */}
        {msg && (
          <div
            className={`mb-6 p-4 rounded-lg border ${
              msg.type === 'success'
                ? 'bg-green-50 dark:bg-green-900/20 border-green-200 dark:border-green-800 text-green-800 dark:text-green-300'
                : 'bg-red-50 dark:bg-red-900/20 border-red-200 dark:border-red-800 text-red-800 dark:text-red-300'
            }`}
          >
            <p className="text-sm font-medium">{msg.text}</p>
          </div>
        )}

        {/* Tab 1: Member Search & Issue Paper Ballot */}
        {activeTab === 'members' && (
          <div className="space-y-6">
            <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Search Member</h2>
              <form onSubmit={searchMembers} className="flex gap-2">
                <input
                  type="text"
                  value={searchQuery}
                  onChange={e => setSearchQuery(e.target.value)}
                  placeholder="Enter member name (e.g. Voter 001)..."
                  className="flex-1 p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                />
                <button
                  type="submit"
                  disabled={searching}
                  className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium disabled:opacity-50"
                >
                  {searching ? 'Searching...' : 'Search'}
                </button>
              </form>
            </div>

            {members.length > 0 && (
              <div className="bg-white dark:bg-gray-800 rounded-lg shadow overflow-hidden">
                <div className="p-4 border-b border-gray-200 dark:border-gray-700">
                  <h3 className="font-semibold text-gray-900 dark:text-white">Search Results ({members.length})</h3>
                </div>
                <div className="divide-y divide-gray-200 dark:divide-gray-700">
                  {members.map(member => (
                    <div key={member.id} className="p-4 flex items-center justify-between gap-4">
                      <div>
                        <p className="font-medium text-gray-900 dark:text-white">{member.full_name}</p>
                        <p className="text-xs text-gray-500">Code: {member.member_code} | Email: {member.email || 'N/A'}</p>
                        {member.paperBallot && (
                          <p className="text-xs text-blue-500 mt-1">
                            Paper Ballot Short Code: <span className="font-mono font-bold">{member.paperBallot.shortCode}</span>
                          </p>
                        )}
                      </div>
                      <div className="flex items-center gap-3">
                        <span
                          className={`px-2.5 py-1 text-xs font-semibold rounded-full ${
                            member.votingStatus === 'ELIGIBLE'
                              ? 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400'
                              : member.votingStatus === 'DIGITAL_VOTED'
                              ? 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-400'
                              : member.votingStatus === 'PAPER_ISSUED'
                              ? 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-400'
                              : 'bg-purple-100 text-purple-800 dark:bg-purple-900/30 dark:text-purple-400'
                          }`}
                        >
                          {member.votingStatus}
                        </span>

                        {member.votingStatus === 'ELIGIBLE' && (
                          <button
                            onClick={() => issuePaperBallot(member)}
                            disabled={loading}
                            className="px-3 py-1.5 text-xs bg-indigo-600 hover:bg-indigo-700 text-white font-medium rounded disabled:opacity-50"
                          >
                            Issue Paper Ballot
                          </button>
                        )}

                        {member.votingStatus === 'PAPER_ISSUED' && member.paperBallot && (
                          <button
                            onClick={() =>
                              setIssuedModal({
                                memberName: member.full_name,
                                ballotId: member.paperBallot!.ballotId,
                                shortCode: member.paperBallot!.shortCode,
                                qrDataUrl: member.paperBallot!.qrDataUrl,
                                qrSvg: member.paperBallot!.qrSvg || '',
                              })
                            }
                            className="px-3 py-1.5 text-xs bg-gray-600 hover:bg-gray-700 text-white font-medium rounded"
                          >
                            View QR / Print
                          </button>
                        )}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
        )}

        {/* Tab 2: Record / Spoil Paper Vote */}
        {activeTab === 'record' && (
          <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
            {/* Record Vote */}
            <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Record Paper Vote</h2>
              
              <div className="mb-4">
                <button
                  type="button"
                  onClick={() => setShowScanner(!showScanner)}
                  className="w-full py-2 px-3 bg-purple-600 hover:bg-purple-700 text-white rounded font-medium text-sm flex items-center justify-center gap-2"
                >
                  <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M3 9a2 2 0 012-2h.93a2 2 0 001.664-.89l.812-1.22A2 2 0 0110.07 4h3.86a2 2 0 011.664.89l.812 1.22A2 2 0 0018.07 7H19a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2V9z" />
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M15 13a3 3 0 11-6 0 3 3 0 016 0z" />
                  </svg>
                  {showScanner ? 'Close QR Scanner' : 'Scan QR Code with Camera'}
                </button>

                {showScanner && (
                  <div className="mt-3 p-3 bg-gray-100 dark:bg-gray-700 rounded-lg">
                    <div id="qr-reader" className="w-full"></div>
                  </div>
                )}
              </div>

              <form onSubmit={handleRecordPaperVote} className="space-y-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    Ballot ID <span className="text-red-500">*</span>
                  </label>
                  <input
                    type="text"
                    value={recordBallotId}
                    onChange={e => setRecordBallotId(e.target.value)}
                    placeholder="Enter full HMAC Ballot ID..."
                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    required
                  />
                </div>

                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    Select Candidate <span className="text-red-500">*</span>
                  </label>
                  <select
                    value={selectedCandidate}
                    onChange={e => setSelectedCandidate(e.target.value)}
                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    required
                  >
                    <option value="">-- Choose Candidate --</option>
                    {candidates.map(c => (
                      <option key={c.id} value={c.id}>
                        {c.full_name}
                      </option>
                    ))}
                  </select>
                </div>

                <button
                  type="submit"
                  disabled={loading}
                  className="w-full py-2 bg-green-600 hover:bg-green-700 text-white rounded font-medium disabled:opacity-50"
                >
                  {loading ? 'Submitting...' : 'Record Paper Vote'}
                </button>
              </form>
            </div>

            {/* Spoil Ballot */}
            <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Mark Ballot as Spoiled</h2>
              <div className="space-y-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    Reason for Spoiling
                  </label>
                  <input
                    type="text"
                    value={invalidReason}
                    onChange={e => setInvalidReason(e.target.value)}
                    placeholder="e.g. Physical ballot damaged, voter request..."
                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  />
                </div>

                <button
                  type="button"
                  onClick={handleSpoilBallot}
                  disabled={loading}
                  className="w-full py-2 bg-red-600 hover:bg-red-700 text-white rounded font-medium disabled:opacity-50"
                >
                  Mark Ballot Spoiled / Invalid
                </button>
              </div>
            </div>
          </div>
        )}

        {/* Modal: Issued Paper Ballot */}
        {issuedModal && (
          <div className="fixed inset-0 bg-black/50 flex items-center justify-center p-4 z-50">
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow-xl max-w-md w-full p-6 space-y-4">
              <h3 className="text-lg font-bold text-gray-900 dark:text-white">
                Paper Ballot Issued
              </h3>
              <p className="text-sm text-gray-600 dark:text-gray-400">
                Issued for: <span className="font-semibold text-gray-900 dark:text-white">{issuedModal.memberName}</span>
              </p>

              <div className="bg-gray-50 dark:bg-gray-700 p-4 rounded text-center space-y-2">
                <p className="text-xs text-gray-500 dark:text-gray-400">SHORT CODE</p>
                <p className="text-xl font-mono font-bold tracking-widest text-blue-600 dark:text-blue-400">
                  {issuedModal.shortCode}
                </p>
                <p className="text-xs text-gray-500 dark:text-gray-400 mt-2">FULL BALLOT ID</p>
                <p className="text-[10px] font-mono break-all text-gray-700 dark:text-gray-300">
                  {issuedModal.ballotId}
                </p>
              </div>

              {issuedModal.qrDataUrl && (
                <div className="flex justify-center p-2 bg-white rounded border border-gray-200">
                  <img
                    src={issuedModal.qrDataUrl}
                    alt="Ballot QR code"
                    width={256}
                    height={256}
                    className="rounded"
                  />
                </div>
              )}
              <p className="text-xs text-center text-gray-500 dark:text-gray-400">
                Print this QR on the paper ballot. Scan it later to record or spoil the vote.
              </p>

              <button
                onClick={() => setIssuedModal(null)}
                className="w-full py-2 bg-gray-900 dark:bg-gray-700 text-white rounded font-medium hover:bg-gray-800"
              >
                Close Modal
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
