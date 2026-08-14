'use client';

import Image from 'next/image';
import { useState, useEffect } from 'react';

interface Member {
  id: string;
  member_code: string;
  full_name: string;
  email: string | null;
  phone: string | null;
  is_active: boolean;
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
  is_active?: boolean;
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
  const [secret, setSecret] = useState(() => {
    if (typeof window === 'undefined') return '';
    return localStorage.getItem('admin_secret') || '';
  });
  const [isAuthenticated, setIsAuthenticated] = useState(() => {
    if (typeof window === 'undefined') return false;
    return Boolean(localStorage.getItem('admin_secret'));
  });
  const [activeTab, setActiveTab] = useState<'members' | 'record' | 'inventory' | 'phase' | 'candidates' | 'members-manage' | 'tokens-dispatch'>('members');

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

  // Option E Inventory State
  const [generateCount, setGenerateCount] = useState<number | ''>(10);
  const [generatedBatch, setGeneratedBatch] = useState<{
    batchId: string;
    generatedCount: number;
    ballots: { ballotId: string; shortCode: string; qrDataUrl?: string; qrSvg?: string }[];
  } | null>(null);

  const [assignBallotId, setAssignBallotId] = useState('');
  const [assignMemberId, setAssignMemberId] = useState('');

  const [voidBatchId, setVoidBatchId] = useState('');
  const [voidReason, setVoidReason] = useState('');

  // Phase Control State
  const [phaseInfo, setPhaseInfo] = useState<{
    currentPhase: string;
    allowedNextPhases: string[];
    isTerminal: boolean;
    nominationStart: string | null;
    nominationEnd: string | null;
    votingStart: string | null;
    votingEnd: string | null;
  } | null>(null);
  const [phaseAction, setPhaseAction] = useState<'idle' | 'requested' | 'confirming' | 'executing'>('idle');
  const [targetPhase, setTargetPhase] = useState('');
  const [confirmText, setConfirmText] = useState('');
  const [phaseLoading, setPhaseLoading] = useState(false);

  // Candidate Management State
  const [candidateName, setCandidateName] = useState('');
  const [candidateStatement, setCandidateStatement] = useState('');
  const [candidatePhotoUrl, setCandidatePhotoUrl] = useState('');
  const [candidateActive, setCandidateActive] = useState(true);
  const [editingCandidateId, setEditingCandidateId] = useState<string | null>(null);

  // Member Management State
  const [allMembers, setAllMembers] = useState<Member[]>([]);
  const [membersLoading, setMembersLoading] = useState(false);
  const [csvContent, setCsvContent] = useState('');
  const [importResult, setImportResult] = useState<{ total: number; imported: number; failed: number; errors: string[] } | null>(null);

  // Token Dispatch State
  const [dispatchMemberIds, setDispatchMemberIds] = useState<string[]>([]);
  const [dispatchType, setDispatchType] = useState<'VOTING' | 'NOMINATION'>('VOTING');
  const [dispatchResult, setDispatchResult] = useState<{ total: number; sent: number; failed: number; errors: string[] } | null>(null);

  // Unified Scanner State
  const [scannerMode, setScannerMode] = useState<'record' | 'assign' | null>(null);

  // Status messages
  const [msg, setMsg] = useState<{ text: string; type: 'success' | 'error' } | null>(null);
  const [loading, setLoading] = useState(false);

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

  const fetchPhaseInfo = async (secKey: string) => {
    try {
      const res = await fetch('/api/admin/phase', {
        headers: { 'x-admin-secret': secKey },
      });
      if (res.ok) {
        const data = await res.json();
        setPhaseInfo({
          currentPhase: data.current_phase,
          allowedNextPhases: data.allowedNextPhases || [],
          isTerminal: data.isTerminal || false,
          nominationStart: data.nomination_start,
          nominationEnd: data.nomination_end,
          votingStart: data.voting_start,
          votingEnd: data.voting_end,
        });
      }
    } catch {
      // Ignore
    }
  };

  useEffect(() => {
    const timer = setTimeout(() => {
      void fetchCandidates();
    }, 0);

    return () => clearTimeout(timer);
  }, []);

  useEffect(() => {
    if (!isAuthenticated || !secret) return;

    const timer = setTimeout(() => {
      void fetchStats(secret);
      void fetchPhaseInfo(secret);
    }, 0);

    return () => clearTimeout(timer);
  }, [isAuthenticated, secret]);

  useEffect(() => {
    type ScannerInstance = {
      render: (onSuccess: (decodedText: string) => void, onError: () => void) => void;
      clear: () => Promise<void>;
    };

    let scanner: ScannerInstance | null = null;
    if (scannerMode) {
      import('html5-qrcode').then(({ Html5QrcodeScanner }) => {
        scanner = new Html5QrcodeScanner(
          'qr-reader',
          { fps: 10, qrbox: { width: 250, height: 250 } },
          /* verbose= */ false
        );
        scanner.render(
          (decodedText: string) => {
            const id = extractBallotId(decodedText);
            if (scannerMode === 'record') {
              setRecordBallotId(id);
            } else if (scannerMode === 'assign') {
              setAssignBallotId(id);
            }
            setScannerMode(null);
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
  }, [scannerMode]);

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

  const handleGenerateBatch = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!generateCount || generateCount < 1 || generateCount > 1000) {
      setMsg({ text: 'Count must be between 1 and 1000', type: 'error' });
      return;
    }

    setLoading(true);
    setMsg(null);
    setGeneratedBatch(null);

    try {
      const res = await fetch('/api/admin/paper-batch', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-admin-secret': secret },
        body: JSON.stringify({ count: generateCount }),
      });
      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || data.message || 'Failed to generate batch', type: 'error' });
      } else {
        setMsg({ text: `Batch ${data.batchId} generated with ${data.generatedCount} ballots`, type: 'success' });
        setGeneratedBatch(data);
        setGenerateCount(10);
      }
    } catch {
      setMsg({ text: 'Server error generating batch', type: 'error' });
    } finally {
      setLoading(false);
    }
  };

  const handleAssignBallot = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!assignBallotId || !assignMemberId) {
      setMsg({ text: 'Both Ballot ID and Member ID are required', type: 'error' });
      return;
    }

    setLoading(true);
    setMsg(null);

    try {
      const res = await fetch('/api/admin/paper-assign', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-admin-secret': secret },
        body: JSON.stringify({ ballotId: assignBallotId.trim(), memberId: assignMemberId.trim() }),
      });
      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || data.message || 'Failed to assign ballot', type: 'error' });
      } else {
        setMsg({ text: 'Ballot successfully assigned to member.', type: 'success' });
        setAssignBallotId('');
        setAssignMemberId('');
        setIssuedModal({
          memberName: 'Assigned Member',
          ballotId: data.ballotId,
          shortCode: data.shortCode,
          qrDataUrl: data.qrDataUrl,
          qrSvg: data.qrSvg,
        });
      }
    } catch {
      setMsg({ text: 'Server error assigning ballot', type: 'error' });
    } finally {
      setLoading(false);
    }
  };

  const handleVoidUnused = async (e: React.FormEvent) => {
    e.preventDefault();
    const reason = voidReason.trim() || 'Voided by admin';

    if (!confirm('Are you sure you want to void remaining unused ballots?')) return;

    setLoading(true);
    setMsg(null);

    try {
      const res = await fetch('/api/admin/paper-void-unused', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-admin-secret': secret },
        body: JSON.stringify({ batchId: voidBatchId.trim() || undefined, reason }),
      });
      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || data.message || 'Failed to void ballots', type: 'error' });
      } else {
        setMsg({ text: `Successfully voided ${data.voidedCount} ballots.`, type: 'success' });
        setVoidBatchId('');
        setVoidReason('');
      }
    } catch {
      setMsg({ text: 'Server error voiding ballots', type: 'error' });
    } finally {
      setLoading(false);
    }
  };

  // Phase Control Handlers
  const handleRequestPhaseChange = async (phase: string) => {
    setPhaseLoading(true);
    setMsg(null);
    setTargetPhase(phase);
    setPhaseAction('requested');

    try {
      const res = await fetch('/api/admin/phase', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-admin-secret': secret },
        body: JSON.stringify({ action: 'request', phase }),
      });
      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to request phase change', type: 'error' });
        setPhaseAction('idle');
      } else {
        setMsg({ text: data.message || 'Confirmation email sent. Check your inbox.', type: 'success' });
        // Wait for email confirmation - UI will show "confirming" state
        setPhaseAction('confirming');
      }
    } catch {
      setMsg({ text: 'Server error requesting phase change', type: 'error' });
      setPhaseAction('idle');
    } finally {
      setPhaseLoading(false);
    }
  };

  const handleConfirmPhaseChange = async (e: React.FormEvent) => {
    e.preventDefault();
    if (confirmText !== 'CONFIRM') {
      setMsg({ text: 'You must type CONFIRM to proceed', type: 'error' });
      return;
    }

    setPhaseLoading(true);
    setMsg(null);
    setPhaseAction('executing');

    try {
      const res = await fetch('/api/admin/phase', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-admin-secret': secret },
        body: JSON.stringify({ action: 'execute', phase: targetPhase, confirmText }),
      });
      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to change phase', type: 'error' });
        setPhaseAction('confirming');
      } else {
        setMsg({ text: data.message || `Phase changed to ${data.newPhase}`, type: 'success' });
        setPhaseAction('idle');
        setTargetPhase('');
        setConfirmText('');
        // Refresh phase info
        void fetchPhaseInfo(secret);
      }
    } catch {
      setMsg({ text: 'Server error executing phase change', type: 'error' });
      setPhaseAction('confirming');
    } finally {
      setPhaseLoading(false);
    }
  };

  const handleCancelPhaseChange = () => {
    setPhaseAction('idle');
    setTargetPhase('');
    setConfirmText('');
    setMsg(null);
  };

  // Candidate Management Handlers
  const handleSaveCandidate = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!candidateName.trim()) {
      setMsg({ text: 'Candidate name is required', type: 'error' });
      return;
    }

    setLoading(true);
    setMsg(null);

    try {
      const url = editingCandidateId ? '/api/admin/candidates' : '/api/admin/candidates';
      const method = editingCandidateId ? 'PATCH' : 'POST';
      const body: Record<string, unknown> = {
        full_name: candidateName.trim(),
        statement: candidateStatement.trim() || null,
        photo_url: candidatePhotoUrl.trim() || null,
        is_active: candidateActive,
      };
      if (editingCandidateId) body.id = editingCandidateId;

      const res = await fetch(url, {
        method,
        headers: { 'Content-Type': 'application/json', 'x-admin-secret': secret },
        body: JSON.stringify(body),
      });
      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to save candidate', type: 'error' });
      } else {
        setMsg({ text: editingCandidateId ? 'Candidate updated' : 'Candidate created', type: 'success' });
        setCandidateName('');
        setCandidateStatement('');
        setCandidatePhotoUrl('');
        setCandidateActive(true);
        setEditingCandidateId(null);
        void fetchCandidates();
      }
    } catch {
      setMsg({ text: 'Server error saving candidate', type: 'error' });
    } finally {
      setLoading(false);
    }
  };

  const handleEditCandidate = (c: Candidate) => {
    setEditingCandidateId(c.id);
    setCandidateName(c.full_name);
    setCandidateStatement(c.statement || '');
    setCandidatePhotoUrl('');
    setCandidateActive(true);
  };

  const handleCancelEditCandidate = () => {
    setEditingCandidateId(null);
    setCandidateName('');
    setCandidateStatement('');
    setCandidatePhotoUrl('');
    setCandidateActive(true);
  };

  // Member Management Handlers
  const fetchAllMembers = async () => {
    setMembersLoading(true);
    try {
      const res = await fetch('/api/admin/members-manage?limit=500', {
        headers: { 'x-admin-secret': secret },
      });
      if (res.ok) {
        const data = await res.json();
        setAllMembers(data.members || []);
      }
    } catch {
      // Ignore
    } finally {
      setMembersLoading(false);
    }
  };

  const handleToggleMemberActive = async (member: Member) => {
    setLoading(true);
    setMsg(null);

    try {
      const res = await fetch('/api/admin/members-manage', {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json', 'x-admin-secret': secret },
        body: JSON.stringify({ id: member.id, is_active: !member.is_active }),
      });
      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to update member', type: 'error' });
      } else {
        setMsg({ text: `Member ${!member.is_active ? 'activated' : 'deactivated'}`, type: 'success' });
        void fetchAllMembers();
      }
    } catch {
      setMsg({ text: 'Server error updating member', type: 'error' });
    } finally {
      setLoading(false);
    }
  };

  const handleImportMembers = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!csvContent.trim()) {
      setMsg({ text: 'CSV content is required', type: 'error' });
      return;
    }

    setLoading(true);
    setMsg(null);
    setImportResult(null);

    try {
      const res = await fetch('/api/admin/members-import', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-admin-secret': secret },
        body: JSON.stringify({ csv: csvContent }),
      });
      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to import members', type: 'error' });
      } else {
        setImportResult(data);
        setMsg({ text: `Imported ${data.imported} members, ${data.failed} failed`, type: data.failed > 0 ? 'error' : 'success' });
        setCsvContent('');
        void fetchAllMembers();
      }
    } catch {
      setMsg({ text: 'Server error importing members', type: 'error' });
    } finally {
      setLoading(false);
    }
  };

  const handleCancelMemberEdit = () => {
    setImportResult(null);
  };

  // Token Dispatch Handlers
  const handleDispatchTokens = async (e: React.FormEvent) => {
    e.preventDefault();
    if (dispatchMemberIds.length === 0) {
      setMsg({ text: 'Select at least one member', type: 'error' });
      return;
    }

    setLoading(true);
    setMsg(null);
    setDispatchResult(null);

    try {
      const res = await fetch('/api/admin/tokens-dispatch', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-admin-secret': secret },
        body: JSON.stringify({ memberIds: dispatchMemberIds, type: dispatchType }),
      });
      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to dispatch tokens', type: 'error' });
      } else {
        setDispatchResult(data);
        setMsg({ text: `Dispatched ${data.sent} tokens, ${data.failed} failed`, type: data.failed > 0 ? 'error' : 'success' });
        setDispatchMemberIds([]);
      }
    } catch {
      setMsg({ text: 'Server error dispatching tokens', type: 'error' });
    } finally {
      setLoading(false);
    }
  };

  const handleCancelDispatch = () => {
    setDispatchResult(null);
    setDispatchMemberIds([]);
  };

  const handleToggleDispatchMember = (memberId: string) => {
    setDispatchMemberIds(prev => prev.includes(memberId) ? prev.filter(id => id !== memberId) : [...prev, memberId]);
  };

  const handleSelectAllMembers = () => {
    if (dispatchMemberIds.length === allMembers.length) {
      setDispatchMemberIds([]);
    } else {
      setDispatchMemberIds(allMembers.map(m => m.id));
    }
  };

  const handleDeleteCandidate = async (id: string) => {
    if (!confirm('Are you sure you want to delete this candidate?')) return;

    setLoading(true);
    setMsg(null);

    try {
      const res = await fetch(`/api/admin/candidates?id=${id}`, {
        method: 'DELETE',
        headers: { 'x-admin-secret': secret },
      });
      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to delete candidate', type: 'error' });
      } else {
        setMsg({ text: 'Candidate deleted', type: 'success' });
        void fetchCandidates();
      }
    } catch {
      setMsg({ text: 'Server error deleting candidate', type: 'error' });
    } finally {
      setLoading(false);
    }
  };

  const handleToggleCandidateActive = async (c: Candidate) => {
    setLoading(true);
    setMsg(null);

    try {
      const res = await fetch('/api/admin/candidates', {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json', 'x-admin-secret': secret },
        body: JSON.stringify({ id: c.id, is_active: !c.is_active }),
      });
      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to update candidate', type: 'error' });
      } else {
        setMsg({ text: `Candidate ${!c.is_active ? 'activated' : 'deactivated'}`, type: 'success' });
        void fetchCandidates();
      }
    } catch {
      setMsg({ text: 'Server error updating candidate', type: 'error' });
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
        <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center mb-8 gap-4 print:hidden">
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
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 mb-6 print:hidden">
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
        <div className="flex border-b border-gray-200 dark:border-gray-700 mb-6 flex-wrap gap-2 print:hidden">
          <button
            onClick={() => setActiveTab('members')}
            className={`py-2 px-4 font-medium text-sm border-b-2 ${
              activeTab === 'members'
                ? 'border-blue-600 text-blue-600 dark:text-blue-400'
                : 'border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400'
            }`}
          >
            Search & Issue Paper Ballot
          </button>
          <button
            onClick={() => setActiveTab('inventory')}
            className={`py-2 px-4 font-medium text-sm border-b-2 ${
              activeTab === 'inventory'
                ? 'border-blue-600 text-blue-600 dark:text-blue-400'
                : 'border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400'
            }`}
          >
            Preprinted Ballots (Option E)
          </button>
          <button
            onClick={() => setActiveTab('record')}
            className={`py-2 px-4 font-medium text-sm border-b-2 ${
              activeTab === 'record'
                ? 'border-blue-600 text-blue-600 dark:text-blue-400'
                : 'border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400'
            }`}
          >
            Record / Spoil Vote
          </button>
          <button
            onClick={() => setActiveTab('phase')}
            className={`py-2 px-4 font-medium text-sm border-b-2 ${
              activeTab === 'phase'
                ? 'border-blue-600 text-blue-600 dark:text-blue-400'
                : 'border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400'
            }`}
          >
            Election Settings
          </button>
          <button
            onClick={() => setActiveTab('candidates')}
            className={`py-2 px-4 font-medium text-sm border-b-2 ${
              activeTab === 'candidates'
                ? 'border-blue-600 text-blue-600 dark:text-blue-400'
                : 'border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400'
            }`}
          >
            Candidates
          </button>
          <button
            onClick={() => setActiveTab('members-manage')}
            className={`py-2 px-4 font-medium text-sm border-b-2 ${
              activeTab === 'members-manage'
                ? 'border-blue-600 text-blue-600 dark:text-blue-400'
                : 'border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400'
            }`}
          >
            Members Management
          </button>
          <button
            onClick={() => setActiveTab('tokens-dispatch')}
            className={`py-2 px-4 font-medium text-sm border-b-2 ${
              activeTab === 'tokens-dispatch'
                ? 'border-blue-600 text-blue-600 dark:text-blue-400'
                : 'border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400'
            }`}
          >
            Token Dispatch
          </button>
        </div>

        {/* Status Message Toast */}
        {msg && (
          <div
            className={`mb-6 p-4 rounded-lg border print:hidden ${
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
          <div className="space-y-6 print:hidden">
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
                          <div className="flex flex-col gap-2">
                            <button
                              onClick={() => issuePaperBallot(member)}
                              disabled={loading}
                              className="px-3 py-1.5 text-xs bg-indigo-600 hover:bg-indigo-700 text-white font-medium rounded disabled:opacity-50"
                            >
                              Issue Paper Ballot
                            </button>
                            <button
                              onClick={() => {
                                setAssignMemberId(member.id);
                                setActiveTab('inventory');
                              }}
                              className="px-3 py-1.5 text-xs bg-emerald-600 hover:bg-emerald-700 text-white font-medium rounded"
                            >
                              Select for scanned ballot
                            </button>
                          </div>
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

        {/* Tab 2: Preprinted Ballots Inventory (Option E) */}
        {activeTab === 'inventory' && (
          <div className="space-y-6">
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6 print:hidden">
              {/* Scan to Assign */}
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Assign Preprinted Ballot</h2>
                <div className="mb-4">
                  <button
                    type="button"
                    onClick={() => setScannerMode(scannerMode === 'assign' ? null : 'assign')}
                    className="w-full py-2 px-3 bg-purple-600 hover:bg-purple-700 text-white rounded font-medium text-sm flex items-center justify-center gap-2"
                  >
                    <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M3 9a2 2 0 012-2h.93a2 2 0 001.664-.89l.812-1.22A2 2 0 0110.07 4h3.86a2 2 0 011.664.89l.812 1.22A2 2 0 0018.07 7H19a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2V9z" />
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M15 13a3 3 0 11-6 0 3 3 0 016 0z" />
                    </svg>
                    {scannerMode === 'assign' ? 'Close QR Scanner' : 'Scan QR Code with Camera'}
                  </button>

                  {scannerMode === 'assign' && (
                    <div className="mt-3 p-3 bg-gray-100 dark:bg-gray-700 rounded-lg">
                      <div id="qr-reader" className="w-full"></div>
                    </div>
                  )}
                </div>

                <form onSubmit={handleAssignBallot} className="space-y-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Member ID <span className="text-red-500">*</span>
                    </label>
                    <input
                      type="text"
                      value={assignMemberId}
                      onChange={e => setAssignMemberId(e.target.value)}
                      placeholder="Use search tab to find ID..."
                      className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                      required
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Ballot ID (Scanned) <span className="text-red-500">*</span>
                    </label>
                    <input
                      type="text"
                      value={assignBallotId}
                      onChange={e => setAssignBallotId(e.target.value)}
                      placeholder="Scan or enter full HMAC Ballot ID..."
                      className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                      required
                    />
                  </div>
                  <button
                    type="submit"
                    disabled={loading}
                    className="w-full py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded font-medium disabled:opacity-50"
                  >
                    {loading ? 'Assigning...' : 'Assign Ballot to Member'}
                  </button>
                </form>
              </div>

              {/* Generate & Void */}
              <div className="space-y-6">
                <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                  <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Generate Blank Ballots</h2>
                  <form onSubmit={handleGenerateBatch} className="space-y-4">
                    <div>
                      <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                        Count (1-1000)
                      </label>
                      <input
                        type="number"
                        min="1"
                        max="1000"
                        value={generateCount}
                        onChange={e => setGenerateCount(e.target.value ? parseInt(e.target.value, 10) : '')}
                        className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                        required
                      />
                    </div>
                    <button
                      type="submit"
                      disabled={loading}
                      className="w-full py-2 bg-indigo-600 hover:bg-indigo-700 text-white rounded font-medium disabled:opacity-50"
                    >
                      {loading ? 'Generating...' : 'Generate New Batch'}
                    </button>
                  </form>
                </div>

                <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow border border-red-200 dark:border-red-900/50">
                  <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4 text-red-700 dark:text-red-400">Void Unused Ballots</h2>
                  <form onSubmit={handleVoidUnused} className="space-y-4">
                    <div>
                      <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                        Batch ID (Optional)
                      </label>
                      <input
                        type="text"
                        value={voidBatchId}
                        onChange={e => setVoidBatchId(e.target.value)}
                        placeholder="Leave blank to void ALL unused"
                        className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                      />
                    </div>
                    <div>
                      <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                        Reason
                      </label>
                      <input
                        type="text"
                        value={voidReason}
                        onChange={e => setVoidReason(e.target.value)}
                        placeholder="e.g. End of election"
                        className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                      />
                    </div>
                    <button
                      type="submit"
                      disabled={loading}
                      className="w-full py-2 bg-red-600 hover:bg-red-700 text-white rounded font-medium disabled:opacity-50"
                    >
                      {loading ? 'Voiding...' : 'Void Unused Ballots'}
                    </button>
                  </form>
                </div>
              </div>
            </div>

            {/* Generated Batch Print View */}
            {generatedBatch && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow mt-6">
                <div className="flex justify-between items-center mb-6 print:hidden">
                  <div>
                    <h2 className="text-xl font-bold text-gray-900 dark:text-white">Generated Batch: {generatedBatch.batchId}</h2>
                    <p className="text-sm text-gray-500">Count: {generatedBatch.generatedCount}</p>
                  </div>
                  <button
                    onClick={() => window.print()}
                    className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium"
                  >
                    Print Ballots
                  </button>
                </div>

                <div className="hidden print:block mb-8">
                  <h1 className="text-2xl font-bold text-center">Official Election Ballots</h1>
                  <p className="text-center text-gray-600">Batch: {generatedBatch.batchId}</p>
                </div>

                <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-6">
                  {generatedBatch.ballots.map(b => (
                    <div key={b.ballotId} className="flex flex-col items-center p-4 border border-gray-200 dark:border-gray-700 rounded text-center break-inside-avoid">
                      <p className="font-mono font-bold text-lg mb-2">{b.shortCode}</p>
                      {b.qrDataUrl && (
                        <Image
                          src={b.qrDataUrl}
                          alt={`QR for ${b.shortCode}`}
                          width={128}
                          height={128}
                          unoptimized
                          className="border p-1"
                        />
                      )}
                      <p className="text-[8px] font-mono mt-2 break-all text-gray-500 w-full overflow-hidden">
                        {b.ballotId}
                      </p>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
        )}

        {/* Tab 3: Record / Spoil Paper Vote */}
        {activeTab === 'record' && (
          <div className="grid grid-cols-1 md:grid-cols-2 gap-6 print:hidden">
            {/* Record Vote */}
            <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Record Paper Vote</h2>
              
              <div className="mb-4">
                <button
                  type="button"
                  onClick={() => setScannerMode(scannerMode === 'record' ? null : 'record')}
                  className="w-full py-2 px-3 bg-purple-600 hover:bg-purple-700 text-white rounded font-medium text-sm flex items-center justify-center gap-2"
                >
                  <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M3 9a2 2 0 012-2h.93a2 2 0 001.664-.89l.812-1.22A2 2 0 0110.07 4h3.86a2 2 0 011.664.89l.812 1.22A2 2 0 0018.07 7H19a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2V9z" />
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M15 13a3 3 0 11-6 0 3 3 0 016 0z" />
                  </svg>
                  {scannerMode === 'record' ? 'Close QR Scanner' : 'Scan QR Code with Camera'}
                </button>

                {scannerMode === 'record' && (
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
          <div className="fixed inset-0 bg-black/50 flex items-center justify-center p-4 z-50 print:hidden">
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow-xl max-w-md w-full p-6 space-y-4">
              <h3 className="text-lg font-bold text-gray-900 dark:text-white">
                Paper Ballot Issued / Assigned
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
                  <Image
                    src={issuedModal.qrDataUrl}
                    alt="Ballot QR code"
                    width={256}
                    height={256}
                    className="rounded"
                    unoptimized
                  />
                </div>
              )}
              <p className="text-xs text-center text-gray-500 dark:text-gray-400">
                Ensure the user takes this ballot or code. Scan it later to record or spoil the vote.
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

        {/* Tab 4: Election Settings / Phase Control */}
        {activeTab === 'phase' && (
          <div className="space-y-6 print:hidden">
            {/* Current Phase Display */}
            {phaseInfo && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Current Election Phase</h2>
                <div className="flex items-center gap-4 mb-4">
                  <span
                    className={`px-4 py-2 text-lg font-bold rounded-full ${
                      phaseInfo.currentPhase === 'VOTING' ? 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400' :
                      phaseInfo.currentPhase === 'VOTING_CLOSED' ? 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-400' :
                      phaseInfo.currentPhase === 'COMPLETED' ? 'bg-purple-100 text-purple-800 dark:bg-purple-900/30 dark:text-purple-400' :
                      phaseInfo.currentPhase === 'SETUP' ? 'bg-gray-100 text-gray-800 dark:bg-gray-900/30 dark:text-gray-400' :
                      phaseInfo.currentPhase === 'NOMINATION' ? 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-400' :
                      'bg-orange-100 text-orange-800 dark:bg-orange-900/30 dark:text-orange-400'
                    }`}
                  >
                    {phaseInfo.currentPhase}
                  </span>
                  {phaseInfo.isTerminal && (
                    <span className="px-3 py-1 text-sm bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-400 rounded-full">
                      Terminal State
                    </span>
                  )}
                </div>

                {/* Election Dates */}
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 text-sm">
                  {phaseInfo.nominationStart && (
                    <div>
                      <span className="text-gray-500">Nomination Start:</span>
                      <p className="font-mono">{new Date(phaseInfo.nominationStart).toLocaleString()}</p>
                    </div>
                  )}
                  {phaseInfo.nominationEnd && (
                    <div>
                      <span className="text-gray-500">Nomination End:</span>
                      <p className="font-mono">{new Date(phaseInfo.nominationEnd).toLocaleString()}</p>
                    </div>
                  )}
                  {phaseInfo.votingStart && (
                    <div>
                      <span className="text-gray-500">Voting Start:</span>
                      <p className="font-mono">{new Date(phaseInfo.votingStart).toLocaleString()}</p>
                    </div>
                  )}
                  {phaseInfo.votingEnd && (
                    <div>
                      <span className="text-gray-500">Voting End:</span>
                      <p className="font-mono">{new Date(phaseInfo.votingEnd).toLocaleString()}</p>
                    </div>
                  )}
                </div>
              </div>
            )}

            {/* Phase Transition Controls */}
            {phaseInfo && !phaseInfo.isTerminal && phaseAction === 'idle' && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Advance Election Phase</h2>
                <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                  Current phase: <strong>{phaseInfo.currentPhase}</strong>. Allowed next phases:
                </p>
                <div className="flex flex-wrap gap-3">
                  {phaseInfo.allowedNextPhases.map((phase) => (
                    <button
                      key={phase}
                      onClick={() => handleRequestPhaseChange(phase)}
                      disabled={phaseLoading}
                      className="px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white rounded font-medium disabled:opacity-50"
                    >
                      Advance to {phase}
                    </button>
                  ))}
                </div>
                <p className="mt-3 text-xs text-gray-500">
                  This will send a confirmation email to the admin email address. You must click the link in the email,
                  then return here and type CONFIRM to complete the phase change.
                </p>
              </div>
            )}

            {/* Email Confirmation Pending */}
            {phaseInfo && phaseAction === 'confirming' && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow border border-blue-200 dark:border-blue-900/50">
                <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Awaiting Email Confirmation</h2>
                <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                  A confirmation email has been sent for advancing to <strong>{targetPhase}</strong>.
                  Click the link in the email, then return here to complete the change.
                </p>
                <div className="space-y-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Type CONFIRM to proceed <span className="text-red-500">*</span>
                    </label>
                    <input
                      type="text"
                      value={confirmText}
                      onChange={e => setConfirmText(e.target.value)}
                      placeholder="CONFIRM"
                      className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white font-mono"
                      required
                    />
                  </div>
                  <div className="flex gap-3">
                    <button
                      onClick={handleConfirmPhaseChange}
                      disabled={phaseLoading}
                      className="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded font-medium disabled:opacity-50"
                    >
                      {phaseLoading ? 'Executing...' : 'Confirm Phase Change'}
                    </button>
                    <button
                      onClick={handleCancelPhaseChange}
                      disabled={phaseLoading}
                      className="px-4 py-2 bg-gray-600 hover:bg-gray-700 text-white rounded font-medium disabled:opacity-50"
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              </div>
            )}

            {/* Executing Phase Change */}
            {phaseInfo && phaseAction === 'executing' && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                <div className="flex items-center gap-3">
                  <svg className="animate-spin h-6 w-6 text-blue-600" viewBox="0 0 24 24">
                    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" fill="none" />
                    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                  </svg>
                  <span className="text-lg font-medium text-gray-900 dark:text-white">
                    Executing phase change to {targetPhase}...
                  </span>
                </div>
              </div>
            )}

            {/* Terminal State */}
            {phaseInfo && phaseInfo.isTerminal && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Election Completed</h2>
                <p className="text-gray-600 dark:text-gray-400">
                  The election has reached its terminal state (<strong>{phaseInfo.currentPhase}</strong>).
                  No further phase transitions are allowed.
                </p>
              </div>
            )}

            {/* Election Dates Configuration */}
            {phaseInfo && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Election Dates</h2>
                <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                  Configure nomination and voting periods. Changes take effect immediately.
                </p>
                <form className="grid grid-cols-1 sm:grid-cols-2 gap-4" onSubmit={(e) => e.preventDefault()}>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Nomination Start
                    </label>
                    <input
                      type="datetime-local"
                      defaultValue={phaseInfo.nominationStart ? new Date(phaseInfo.nominationStart).toISOString().slice(0, 16) : ''}
                      className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Nomination End
                    </label>
                    <input
                      type="datetime-local"
                      defaultValue={phaseInfo.nominationEnd ? new Date(phaseInfo.nominationEnd).toISOString().slice(0, 16) : ''}
                      className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Voting Start
                    </label>
                    <input
                      type="datetime-local"
                      defaultValue={phaseInfo.votingStart ? new Date(phaseInfo.votingStart).toISOString().slice(0, 16) : ''}
                      className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Voting End
                    </label>
                    <input
                      type="datetime-local"
                      defaultValue={phaseInfo.votingEnd ? new Date(phaseInfo.votingEnd).toISOString().slice(0, 16) : ''}
                      className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    />
                  </div>
                </form>
                <p className="mt-3 text-xs text-gray-500">
                  Note: Date changes are not yet persisted via API. Implement date update endpoint if needed.
                </p>
              </div>
            )}
          </div>
        )}

        {/* Tab 5: Candidate Management */}
        {activeTab === 'candidates' && (
          <div className="space-y-6 print:hidden">
            {/* Add/Edit Candidate Form */}
            <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">
                {editingCandidateId ? 'Edit Candidate' : 'Add New Candidate'}
              </h2>
              <form onSubmit={handleSaveCandidate} className="space-y-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    Full Name <span className="text-red-500">*</span>
                  </label>
                  <input
                    type="text"
                    value={candidateName}
                    onChange={e => setCandidateName(e.target.value)}
                    placeholder="e.g. Jane Doe"
                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    required
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    Statement
                  </label>
                  <textarea
                    value={candidateStatement}
                    onChange={e => setCandidateStatement(e.target.value)}
                    placeholder="Candidate's campaign statement or bio..."
                    rows={3}
                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    Photo URL (optional)
                  </label>
                  <input
                    type="text"
                    value={candidatePhotoUrl}
                    onChange={e => setCandidatePhotoUrl(e.target.value)}
                    placeholder="https://example.com/photo.jpg"
                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  />
                </div>
                <div className="flex items-center">
                  <input
                    type="checkbox"
                    id="candidateActive"
                    checked={candidateActive}
                    onChange={e => setCandidateActive(e.target.checked)}
                    className="mr-2"
                  />
                  <label htmlFor="candidateActive" className="text-sm font-medium text-gray-700 dark:text-gray-300">
                    Active (visible to voters)
                  </label>
                </div>
                <div className="flex gap-3">
                  <button
                    type="submit"
                    disabled={loading}
                    className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium disabled:opacity-50"
                  >
                    {loading ? 'Saving...' : editingCandidateId ? 'Update Candidate' : 'Create Candidate'}
                  </button>
                  {editingCandidateId && (
                    <button
                      type="button"
                      onClick={handleCancelEditCandidate}
                      disabled={loading}
                      className="px-4 py-2 bg-gray-600 hover:bg-gray-700 text-white rounded font-medium disabled:opacity-50"
                    >
                      Cancel
                    </button>
                  )}
                </div>
              </form>
            </div>

            {/* Candidates List */}
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow overflow-hidden">
              <div className="p-4 border-b border-gray-200 dark:border-gray-700">
                <h3 className="font-semibold text-gray-900 dark:text-white">
                  All Candidates ({candidates.length})
                </h3>
              </div>
              {candidates.length === 0 ? (
                <div className="p-8 text-center text-gray-500">
                  No candidates yet. Add the first candidate using the form above.
                </div>
              ) : (
                <div className="divide-y divide-gray-200 dark:divide-gray-700">
                  {candidates.map(c => (
                    <div key={c.id} className="p-4 flex items-center justify-between gap-4">
                      <div className="flex-1">
                        <div className="flex items-center gap-2">
                          <p className="font-medium text-gray-900 dark:text-white">{c.full_name}</p>
                          {c.is_active === false && (
                            <span className="px-2 py-0.5 text-xs bg-gray-200 text-gray-700 dark:bg-gray-700 dark:text-gray-300 rounded">
                              INACTIVE
                            </span>
                          )}
                        </div>
                        {c.statement && (
                          <p className="text-sm text-gray-600 dark:text-gray-400 mt-1 line-clamp-2">
                            {c.statement}
                          </p>
                        )}
                      </div>
                      <div className="flex items-center gap-2">
                        <button
                          onClick={() => handleEditCandidate(c)}
                          disabled={loading}
                          className="px-3 py-1.5 text-xs bg-indigo-600 hover:bg-indigo-700 text-white font-medium rounded disabled:opacity-50"
                        >
                          Edit
                        </button>
                        <button
                          onClick={() => handleToggleCandidateActive(c)}
                          disabled={loading}
                          className={`px-3 py-1.5 text-xs font-medium rounded text-white disabled:opacity-50 ${
                            c.is_active !== false
                              ? 'bg-yellow-600 hover:bg-yellow-700'
                              : 'bg-green-600 hover:bg-green-700'
                          }`}
                        >
                          {c.is_active !== false ? 'Deactivate' : 'Activate'}
                        </button>
                        <button
                          onClick={() => handleDeleteCandidate(c.id)}
                          disabled={loading}
                          className="px-3 py-1.5 text-xs bg-red-600 hover:bg-red-700 text-white font-medium rounded disabled:opacity-50"
                        >
                          Delete
                        </button>
                      </div>
                    </div>
                  ))}
               </div>
              )}
           </div>
         </div>
        )}

        {/* Tab 6: Members Management */}
        {activeTab === 'members-manage' && (
          <div className="space-y-6 print:hidden">
            {/* CSV Import */}
            <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Bulk Import Members (CSV</h2>
              <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                Paste CSV content below. Required columns: <code>full_name</code> (or <code>name</code>), <code>email</code>.
                Optional: <code>phone</code>, <code>member_code</code>.
             </p>
              <form onSubmit={handleImportMembers} className="space-y-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    CSV Content
                 </label>
                  <textarea
                    value={csvContent}
                    onChange={e => setCsvContent(e.target.value)}
                    placeholder="full_name,email,phone,member_code
John Doe,john@example.com,+1234567890,M-001
Jane Smith,jane@example.com,+0987654321"
                    rows={6}
                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white font-mono text-sm"
                    required
                  />
               </div>
                <div className="flex gap-3">
                  <button
                    type="submit"
                    disabled={loading || membersLoading}
                    className="px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white rounded font-medium disabled:opacity-50"
                  >
                    {loading ? 'Importing...' : 'Import Members'}
                 </button>
                  {importResult && (
                    <button
                      type="button"
                      onClick={handleCancelMemberEdit}
                      className="px-4 py-2 bg-gray-600 hover:bg-gray-700 text-white rounded font-medium"
                    >
                      Clear Result
                   </button>
                  )}
               </div>
             </form>

              {importResult && (
                <div className="mt-4 p-4 bg-gray-50 dark:bg-gray-700 rounded-lg">
                  <h3 className="font-medium text-gray-900 dark:text-white mb-2">Import Result</h3>
                  <div className="grid grid-cols-3 gap-4 text-sm">
                    <div>
                      <span className="text-gray-500">Total Rows</span>
                      <p className="font-mono">{importResult.total}</p>
                   </div>
                    <div>
                      <span className="text-green-600">Imported</span>
                      <p className="font-mono">{importResult.imported}</p>
                   </div>
                    <div>
                      <span className="text-red-600">Failed</span>
                      <p className="font-mono">{importResult.failed}</p>
                   </div>
                 </div>
                  {importResult.errors.length > 0 && (
                    <div className="mt-3">
                      <span className="text-red-600 font-medium">Errors</span>
                      <ul className="mt-1 text-sm text-red-600 list-disc list-inside max-h-32 overflow-y-auto">
                        {importResult.errors.map((err, i) => (
                          <li key={i}>{err}</li>
                        ))}
                     </ul>
                   </div>
                  )}
               </div>
              )}
           </div>

            {/* Members List */}
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow overflow-hidden">
              <div className="p-4 border-b border-gray-200 dark:border-gray-700 flex items-center justify-between">
                <h3 className="font-semibold text-gray-900 dark:text-white">
                  All Members ({allMembers.length})
               </h3>
                <button
                  onClick={fetchAllMembers}
                  disabled={membersLoading}
                  className="px-3 py-1.5 text-xs bg-gray-600 hover:bg-gray-700 text-white rounded font-medium disabled:opacity-50"
                >
                  {membersLoading ? 'Refreshing...' : 'Refresh'}
               </button>
             </div>
              {allMembers.length === 0 && !membersLoading ? (
                <div className="p-8 text-center text-gray-500">
                  No members found. Import members using the form above.
               </div>
              ) : (
                <div className="divide-y divide-gray-200 dark:divide-gray-700">
                  {allMembers.map(member => (
                    <div key={member.id} className="p-4 flex items-center justify-between gap-4">
                      <div className="flex-1">
                        <div className="flex items-center gap-2">
                          <p className="font-medium text-gray-900 dark:text-white">{member.full_name}</p>
                          <span className="text-xs text-gray-500">({member.member_code})</span>
                          {member.is_active === false && (
                            <span className="px-2 py-0.5 text-xs bg-gray-200 text-gray-700 dark:bg-gray-700 dark:text-gray-300 rounded">
                              INACTIVE
                           </span>
                          )}
                       </div>
                        <p className="text-sm text-gray-600 dark:text-gray-400">
                          {member.email || 'No email'} {member.phone ? ` | ${member.phone}` : ''}
                       </p>
                     </div>
                      <div className="flex items-center gap-2">
                        <button
                          onClick={() => handleToggleMemberActive(member)}
                          disabled={loading}
                          className={`px-3 py-1.5 text-xs font-medium rounded text-white disabled:opacity-50 ${
                            member.is_active !== false
                              ? 'bg-yellow-600 hover:bg-yellow-700'
                              : 'bg-green-600 hover:bg-green-700'
                          }`}
                        >
                          {member.is_active !== false ? 'Deactivate' : 'Activate'}
                       </button>
                     </div>
                   </div>
                  ))}
               </div>
              )}
</div>
          </div>
         )}

        {/* Tab 7: Token Dispatch */}
        {activeTab === 'tokens-dispatch' && (
          <div className="space-y-6 print:hidden">
            <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Dispatch Voting/Nomination Tokens</h2>
              <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                Select members and token type, then click Dispatch. Tokens are sent via email as magic links.
              </p>
              <form onSubmit={handleDispatchTokens} className="space-y-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    Token Type
                  </label>
                  <select
                    value={dispatchType}
                    onChange={e => setDispatchType(e.target.value as 'VOTING' | 'NOMINATION')}
                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  >
                    <option value="VOTING">Voting Token</option>
                    <option value="NOMINATION">Nomination Token</option>
                  </select>
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    Select Members ({dispatchMemberIds.length} selected)
                  </label>
                  <div className="flex gap-2 mb-2">
                    <button
                      type="button"
                      onClick={handleSelectAllMembers}
                      className="px-3 py-1.5 text-xs bg-gray-600 hover:bg-gray-700 text-white rounded font-medium"
                    >
                      {dispatchMemberIds.length === allMembers.length ? 'Deselect All' : 'Select All'}
                    </button>
                  </div>
                  <div className="max-h-64 overflow-y-auto border rounded dark:bg-gray-700 dark:border-gray-600 p-2">
                    {allMembers.length === 0 ? (
                      <p className="text-sm text-gray-500 dark:text-gray-400">No members available. Import members first.</p>
                    ) : (
                      <ul className="space-y-1">
                        {allMembers.map(member => (
                          <li key={member.id} className="flex items-center gap-2">
                            <input
                              type="checkbox"
                              checked={dispatchMemberIds.includes(member.id)}
                              onChange={() => handleToggleDispatchMember(member.id)}
                              className="rounded"
                            />
                            <span className="text-sm text-gray-900 dark:text-white">{member.full_name}</span>
                            <span className="text-xs text-gray-500">({member.member_code})</span>
                            {member.email && <span className="text-xs text-gray-500">{member.email}</span>}
                            {member.is_active === false && (
                              <span className="px-1.5 py-0.5 text-xs bg-gray-200 text-gray-700 dark:bg-gray-700 dark:text-gray-300 rounded">
                                INACTIVE
                              </span>
                            )}
                          </li>
                        ))}
                      </ul>
                    )}
                  </div>
                </div>
                <div className="flex gap-3">
                  <button
                    type="submit"
                    disabled={loading || dispatchMemberIds.length === 0}
                    className="px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white rounded font-medium disabled:opacity-50"
                  >
                    {loading ? 'Dispatching...' : 'Dispatch Tokens'}
                  </button>
                  {dispatchResult && (
                    <button
                      type="button"
                      onClick={handleCancelDispatch}
                      className="px-4 py-2 bg-gray-600 hover:bg-gray-700 text-white rounded font-medium"
                    >
                      Clear Result
                    </button>
                  )}
                </div>
              </form>

              {dispatchResult && (
                <div className="mt-4 p-4 bg-gray-50 dark:bg-gray-700 rounded-lg">
                  <h3 className="font-medium text-gray-900 dark:text-white mb-2">Dispatch Result</h3>
                  <div className="grid grid-cols-3 gap-4 text-sm">
                    <div>
                      <span className="text-gray-500">Total Selected:</span>
                      <p className="font-mono">{dispatchResult.total}</p>
                    </div>
                    <div>
                      <span className="text-green-600">Sent:</span>
                      <p className="font-mono">{dispatchResult.sent}</p>
                    </div>
                    <div>
                      <span className="text-red-600">Failed:</span>
                      <p className="font-mono">{dispatchResult.failed}</p>
                    </div>
                  </div>
                  {dispatchResult.errors.length > 0 && (
                    <div className="mt-3">
                      <span className="text-red-600 font-medium">Errors:</span>
                      <ul className="mt-1 text-sm text-red-600 list-disc list-inside max-h-32 overflow-y-auto">
                        {dispatchResult.errors.map((err, i) => (
                          <li key={i}>{err}</li>
                        ))}
                      </ul>
                    </div>
                  )}
                </div>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
