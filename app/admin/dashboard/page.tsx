'use client';

import Image from 'next/image';
import { useState, useEffect, useRef, useCallback, useSyncExternalStore } from 'react';

interface MemberToken {
  id: string;
  type: 'VOTING' | 'NOMINATION';
  is_used: boolean;
  expires_at: string;
}

interface Member {
  id: string;
  member_code: string;
  full_name: string;
  email: string | null;
  phone: string | null;
  is_active: boolean;
  // Wave 8 — voting entitlement taxonomy. Server precedence (highest wins):
  // INELIGIBLE > PAPER_VOTED > DIGITAL_VOTED > PAPER_ISSUED > DIGITAL_RESERVED
  // > DIGITAL_ISSUED > ENTITLED > NO_ENTITLEMENT. See STATUS_BADGE below for
  // the per-state visual treatment.
  votingStatus:
    | 'INELIGIBLE'
    | 'PAPER_VOTED'
    | 'DIGITAL_VOTED'
    | 'PAPER_ISSUED'
    | 'DIGITAL_RESERVED'
    | 'DIGITAL_ISSUED'
    | 'ENTITLED'
    | 'NO_ENTITLEMENT';
  paperCheckIn?: {
    shortCode: string;
    status: string;
    checkedInAt: string | null;
    checkedInDate: string | null;
  } | null;
  tokens?: MemberToken[];
  // Wave 5 — GDPR/eligibility fields (present on /api/admin/members results)
  voting_eligible?: boolean;
  eligibility_reason?: string;
  eligibility_source?: string;
}

interface ReissueDialogState {
  tokenId: string;
  memberName: string;
  tokenType: 'VOTING' | 'NOMINATION';
}

interface Candidate {
  id: string;
  full_name: string;
  statement?: string;
  is_active?: boolean;
}

// Identity slip returned by the member-issue flow. Deliberately has NO
// ballot_id / QR field — the anonymous ballot QR is only ever printed on the
// anonymous pool sheet (Tab 2), never re-rendered next to a member (Option A,
// locked design decision — no UI may co-locate member_id with ballot_id).
interface IssuedBallotModal {
  memberName: string;
  memberCode: string;
  shortCode: string;
  participationDate: string | null;
  status: string;
}

/**
 * Split an array into fixed-size chunks. Used to lay out printed ballots
 * 4-up per A4 sheet (one chunk = one physical sheet).
 */
function chunkArray<T>(items: T[], size: number): T[][] {
  const chunks: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    chunks.push(items.slice(i, i + size));
  }
  return chunks;
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

/**
 * Wave 8 — per-member voting-status badge treatment (all `votingStatus`
 * values except `DIGITAL_RESERVED`, which keeps its own bespoke
 * pulsing-amber "in progress" render inline — see the member-row JSX).
 * Colors are chosen so no two "in limbo" states are confusable:
 *   - INELIGIBLE: muted/barred — must not vote.
 *   - PAPER_VOTED / DIGITAL_VOTED: terminal "done" states (purple / blue).
 *   - PAPER_ISSUED / DIGITAL_ISSUED: sibling "issued, awaiting action"
 *     states — same pill shape, yellow (paper) vs sky (digital) so they
 *     read as a pair without being mistaken for one another.
 *   - ENTITLED: calm "ready to vote" green.
 *   - NO_ENTITLEMENT: neutral grey "needs provisioning" — distinct from
 *     DIGITAL_RESERVED's live amber and PAPER_ISSUED/DIGITAL_ISSUED's
 *     issued-hues so it doesn't read as urgent or already in-flight.
 */
const STATUS_BADGE: Record<
  Exclude<Member['votingStatus'], 'DIGITAL_RESERVED'>,
  { label: string; className: string; title?: string }
> = {
  INELIGIBLE: {
    label: 'INELIGIBLE',
    className: 'bg-gray-200 text-gray-500 line-through decoration-2 dark:bg-gray-700/50 dark:text-gray-400',
    title: 'This member is not eligible to vote.',
  },
  NO_ENTITLEMENT: {
    label: 'NO_ENTITLEMENT',
    className: 'bg-gray-100 text-gray-600 dark:bg-gray-700/40 dark:text-gray-300',
    title: 'Eligible but no voting credential yet — needs provisioning (issue a paper check-in or dispatch a digital token).',
  },
  ENTITLED: {
    label: 'ENTITLED',
    className: 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400',
    title: 'Eligible and holds a voting credential — ready to vote.',
  },
  DIGITAL_ISSUED: {
    label: 'DIGITAL_ISSUED',
    className: 'bg-sky-100 text-sky-800 dark:bg-sky-900/30 dark:text-sky-400',
    title: 'Digital voting email sent, not yet used — paper check-in still allowed.',
  },
  PAPER_ISSUED: {
    label: 'PAPER_ISSUED',
    className: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-400',
    title: 'Paper check-in issued, ballot not yet cast.',
  },
  DIGITAL_VOTED: {
    label: 'DIGITAL_VOTED',
    className: 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-400',
    title: 'Vote cast digitally. Terminal state.',
  },
  PAPER_VOTED: {
    label: 'PAPER_VOTED',
    className: 'bg-purple-100 text-purple-800 dark:bg-purple-900/30 dark:text-purple-400',
    title: 'Vote cast on paper. Terminal state.',
  },
};

/**
 * Wave 5 — manual eligibility reasons an admin may pick when marking a
 * member INELIGIBLE. Deliberately excludes system-assigned reasons
 * (AGE_UNDER_MIN / UNDETERMINED / PURGED) — those are never admin-editable.
 */
const MANUAL_INELIGIBLE_REASONS = ['MANUAL_ADMIN_HOLD', 'NOT_A_MEMBER', 'INACTIVE_MEMBER'] as const;
type ManualIneligibleReason = (typeof MANUAL_INELIGIBLE_REASONS)[number];

type EligibilityDraft = {
  votingEligible: boolean;
  reason: ManualIneligibleReason;
  note: string;
};

/** Seed a per-row eligibility draft from the member's current server state. */
function draftFromMember(m: Member): EligibilityDraft {
  const eligible = m.voting_eligible ?? true;
  const currentReason = m.eligibility_reason as ManualIneligibleReason | undefined;
  const reason: ManualIneligibleReason =
    !eligible && currentReason && MANUAL_INELIGIBLE_REASONS.includes(currentReason)
      ? currentReason
      : 'MANUAL_ADMIN_HOLD';
  return { votingEligible: eligible, reason, note: '' };
}

/**
 * Wave 2 — Admin Session Security types.
 * Mirrors the reason codes returned by requireAdmin() in app/api/admin/auth.ts.
 */
type SessionExpiryReason = 'idle_expired' | 'absolute_expired' | 'unauthorized' | 'revoked';

/** How a session-expiry was detected: a failed mutation (user was mid-action)
 * vs. an ambient check (the ME poll or the local countdown reaching zero). */
type SessionExpirySource = 'mutation' | 'ambient';

const SESSION_WARNING_THRESHOLD_MS = 2 * 60 * 1000; // show the countdown banner in the last 2 minutes
const SESSION_POLL_INTERVAL_MS = 60 * 1000; // passive /api/admin/me poll cadence

const SESSION_EXPIRY_COPY: Record<SessionExpiryReason, string> = {
  idle_expired: 'You were signed out for inactivity.',
  absolute_expired: "You've reached the 4-hour session limit.",
  unauthorized: 'Your session is no longer valid.',
  revoked: 'This session was signed out (e.g. from another login).',
};

function formatSessionCountdown(ms: number): string {
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  const mm = Math.floor(totalSeconds / 60);
  const ss = totalSeconds % 60;
  return `${mm}:${ss.toString().padStart(2, '0')}`;
}

/**
 * Get CSRF token from cookie for double-submit pattern
 */
function getCsrfToken(): string {
  if (typeof document === 'undefined') return '';
  const cookies = document.cookie.split('; ');
  const csrfCookie = cookies.find(c => c.startsWith('admin_csrf='));
  return csrfCookie ? csrfCookie.split('=')[1] : '';
}

/**
 * Fetch wrapper that includes CSRF token for state-changing requests
 */
async function apiFetch(url: string, options: RequestInit = {}): Promise<Response> {
  const method = (options.method || 'GET').toUpperCase();
  const needsCsrf = ['POST', 'PATCH', 'DELETE', 'PUT'].includes(method);
  
  const headers = new Headers(options.headers);
  if (needsCsrf) {
    const csrfToken = getCsrfToken();
    if (csrfToken) {
      headers.set('x-csrf-token', csrfToken);
    }
  }
  
  return fetch(url, { ...options, headers });
}

/**
 * Tracks whether the component has hydrated on the client, without calling
 * setState inside an effect (which react-hooks/set-state-in-effect flags).
 * The subscribe callback is a no-op because this value never changes after
 * the initial client render.
 */
function useHasMounted(): boolean {
  return useSyncExternalStore(
    () => () => {},
    () => true,
    () => false
  );
}

export default function AdminDashboard() {
  const mounted = useHasMounted();
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const [authChecked, setAuthChecked] = useState(false);
  const [loginSecret, setLoginSecret] = useState('');

  // --- Wave 2: Desktop Session Security ---
  // Source of truth for expiry is the SERVER idle deadline (bumped on each
  // mutation, hard-capped at 4h absolute) — not local mouse/keyboard activity.
  // See app/api/admin/auth.ts requireAdmin().
  const [sessionExpiresAt, setSessionExpiresAt] = useState<string | null>(null);
  const [sessionRemainingMs, setSessionRemainingMs] = useState<number | null>(null);

  // Re-auth modal — renders ON TOP of the still-mounted dashboard so in-progress
  // form state (void reason, add-member fields, CSV selection, etc.) survives.
  const [reauthOpen, setReauthOpen] = useState(false);
  const [reauthReason, setReauthReason] = useState<SessionExpiryReason>('idle_expired');
  const [reauthSecret, setReauthSecret] = useState('');
  const [reauthError, setReauthError] = useState<string | null>(null);
  const [reauthLoading, setReauthLoading] = useState(false);
  const reauthDialogRef = useRef<HTMLDivElement | null>(null);
  const reauthSecretInputRef = useRef<HTMLInputElement | null>(null);

  const csvFileInputRef = useRef<HTMLInputElement | null>(null);

  // Check auth status on mount via cookie-based session
  useEffect(() => {
    const checkAuth = async () => {
      try {
        const res = await fetch('/api/admin/me');
        if (res.ok) {
          const data = await res.json();
          setIsAuthenticated(true);
          setSessionExpiresAt(data.expiresAt ?? null);
        } else {
          setIsAuthenticated(false);
        }
      } catch {
        setIsAuthenticated(false);
      } finally {
        setAuthChecked(true);
      }
    };
    checkAuth();
  }, []);
  const [activeTab, setActiveTab] = useState<'members' | 'record' | 'inventory' | 'phase' | 'candidates' | 'members-manage' | 'tokens-dispatch' | 'nominations' | 'eligibility' | 'reporting'>('members');

  // Stats
  const [stats, setStats] = useState<{ totalMembers: number; currentPhase: string } | null>(null);

  const handleLogout = useCallback(async () => {
    try {
      await apiFetch('/api/admin/logout', { method: 'POST' });
    } catch {
      // Ignore logout errors
    }
    setIsAuthenticated(false);
    setStats(null);
  }, []);


  // Search Members
  const [searchQuery, setSearchQuery] = useState('');
  const [members, setMembers] = useState<Member[]>([]);
  const [searching, setSearching] = useState(false);
  const searchDebounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Modal for Issued Paper Ballot
  const [issuedModal, setIssuedModal] = useState<IssuedBallotModal | null>(null);

  // Void & Reissue Token Dialog
  const [reissueDialog, setReissueDialog] = useState<ReissueDialogState | null>(null);
  const [reissueReason, setReissueReason] = useState('');
  const [reissueLoading, setReissueLoading] = useState(false);
  const [reissueError, setReissueError] = useState<string | null>(null);

  // Record Vote State
  const [candidates, setCandidates] = useState<Candidate[]>([]);
  const [recordBallotId, setRecordBallotId] = useState('');
  const [selectedCandidate, setSelectedCandidate] = useState('');
  const [invalidReason, setInvalidReason] = useState('');

  // Option E Inventory State
  const [generateCount, setGenerateCount] = useState<number | ''>(10);
  // Anonymous ballot pool batch (Option A locked design — pool ballots carry
  // no member identity; the API returns each opaque ballot_id with its own
  // server-generated QR).
  const [generatedBatch, setGeneratedBatch] = useState<{
    generatedCount: number;
    ballots: { ballotId: string; qrDataUrl?: string; qrSvg?: string }[];
  } | null>(null);
  // Print layout: how many A6-scale ballots to tile per A4 sheet (see .ballot-print-root / .layout-6up in globals.css)
  const [ballotsPerSheet, setBallotsPerSheet] = useState<4 | 6>(4);

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
    pendingConfirmation: { phase: string; confirmedAt: string; used: boolean } | null;
    pendingResetConfirmation: { confirmedAt: string; used: boolean } | null;
  } | null>(null);
  const [phaseAction, setPhaseAction] = useState<'idle' | 'requested' | 'confirming' | 'final_confirm' | 'executing'>('idle');
  const [resetAction, setResetAction] = useState<'idle' | 'requested' | 'confirming' | 'final_confirm' | 'executing'>('idle');
  const [resetConfirmText, setResetConfirmText] = useState('');
  const [targetPhase, setTargetPhase] = useState('');
  const [confirmText, setConfirmText] = useState('');
  const [phaseLoading, setPhaseLoading] = useState(false);

  // Election Dates State
  const [nominationStart, setNominationStart] = useState('');
  const [nominationEnd, setNominationEnd] = useState('');
  const [votingStart, setVotingStart] = useState('');
  const [votingEnd, setVotingEnd] = useState('');

  // Voting token TTL setting (hours)
  const [votingTokenTtlHours, setVotingTokenTtlHours] = useState<number | ''>('');
  const [votingTokenTtlError, setVotingTokenTtlError] = useState<string | null>(null);
  const [votingTokenTtlLoading, setVotingTokenTtlLoading] = useState(false);

  // Nomination settings (write-ins + per-member cap)
  const [allowWriteIns, setAllowWriteIns] = useState(true);
  const [maxNomineesPerMember, setMaxNomineesPerMember] = useState(1);
  const [nominationSettingsLoading, setNominationSettingsLoading] = useState(false);

  // Age requirement settings
  const [ageRequirementEnabled, setAgeRequirementEnabled] = useState(false);
  const [minimumVotingAge, setMinimumVotingAge] = useState<number | ''>('');

  // Member roster: allow adding members during VOTING (Election Settings toggle)
  const [allowAddingMemberDuringVoting, setAllowAddingMemberDuringVoting] = useState(false);

  // Member data-completeness counts (from members-manage GET)
  const [memberStats, setMemberStats] = useState<{ total: number; withEmail: number; withPhone: number; withBoth: number } | null>(null);

  // Election-progress report (Reporting tab, on-demand)
  const [reportData, setReportData] = useState<{
    available: boolean;
    phase?: string;
    checkedInCount?: number;
    paperRecordedCount?: number;
    digitalVoteCount?: number;
    totalVoteCount?: number;
    results?: Array<{ id: string; full_name: string; votes: number; percentage: number }>;
  } | null>(null);
  const [reportLoading, setReportLoading] = useState(false);

  // Candidate Management State
  const [candidateName, setCandidateName] = useState('');
  const [candidateStatement, setCandidateStatement] = useState('');
  const [candidatePhotoUrl, setCandidatePhotoUrl] = useState('');
  const [candidateActive, setCandidateActive] = useState(true);
  const [editingCandidateId, setEditingCandidateId] = useState<string | null>(null);

  // Member Management State
  const [allMembers, setAllMembers] = useState<Member[]>([]);
  const [membersLoading, setMembersLoading] = useState(false);
  const [newMemberName, setNewMemberName] = useState('');
  const [newMemberEmail, setNewMemberEmail] = useState('');
  const [newMemberPhone, setNewMemberPhone] = useState('');
  const [newMemberCode, setNewMemberCode] = useState('');
  const [newMemberDob, setNewMemberDob] = useState('');
  const [newMemberAgeEligible, setNewMemberAgeEligible] = useState(false);
  const [addMemberLoading, setAddMemberLoading] = useState(false);
  const [addMemberError, setAddMemberError] = useState<string | null>(null);
  const [csvContent, setCsvContent] = useState('');
  const [importResult, setImportResult] = useState<{ total: number; imported: number; failed: number; errors: string[] } | null>(null);
  const [csvFileName, setCsvFileName] = useState<string | null>(null);
  const [csvFileLineCount, setCsvFileLineCount] = useState<number | null>(null);
  const [csvDragActive, setCsvDragActive] = useState(false);

  // Token Dispatch State
  const [dispatchMemberIds, setDispatchMemberIds] = useState<string[]>([]);
  const [dispatchType, setDispatchType] = useState<'VOTING' | 'NOMINATION'>('VOTING');
  const [dispatchResult, setDispatchResult] = useState<{ total: number; sent: number; failed: number; errors: string[] } | null>(null);

  // Admin Out-of-Band Add Nomination State
  const [nomAddQuery, setNomAddQuery] = useState('');
  const [nomAddMatches, setNomAddMatches] = useState<Member[]>([]);
  const [nomAddSearching, setNomAddSearching] = useState(false);
  const [nomAddSelectedMember, setNomAddSelectedMember] = useState<Member | null>(null);
  const [nomAddWriteInName, setNomAddWriteInName] = useState('');
  const [nomAddReason, setNomAddReason] = useState('');
  const [nomAddLoading, setNomAddLoading] = useState(false);

  // Nomination Adjudication State
  type MatchedNomineeGroup = {
    nomineeMemberId: string;
    fullName: string;
    nominationCount: number;
    affectedNominationIds: string[];
    alreadyPromoted: boolean;
    promotedCandidateId: string | null;
  };
  type UnmatchedNominee = {
    id: string;
    nomineeName: string;
    reason: string | null;
    suggestions: { memberId: string; fullName: string }[];
  };
  const [nominations, setNominations] = useState<{ matched: MatchedNomineeGroup[]; unmatched: UnmatchedNominee[] } | null>(null);
  const [nominationsLoading, setNominationsLoading] = useState(false);
  const [adjudicating, setAdjudicating] = useState<string | null>(null);
  const [mergeCandidateChoice, setMergeCandidateChoice] = useState<Record<string, string>>({});

  // Voter Eligibility State (Wave 5)
  const [eligibilityQuery, setEligibilityQuery] = useState('');
  const [eligibilityResults, setEligibilityResults] = useState<Member[]>([]);
  const [eligibilitySearching, setEligibilitySearching] = useState(false);
  const eligibilityDebounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [eligibilityDrafts, setEligibilityDrafts] = useState<Record<string, EligibilityDraft>>({});
  const [eligibilitySavingId, setEligibilitySavingId] = useState<string | null>(null);

  // Purge Roster PII State (Wave 5) — two-stage GDPR purge, typed-confirmation gated
  const [purgeStage, setPurgeStage] = useState<'CONTACT' | 'IDENTITY' | null>(null);
  const [purgeConfirmText, setPurgeConfirmText] = useState('');
  const [purgeLoading, setPurgeLoading] = useState(false);
  const [purgeResult, setPurgeResult] = useState<{ stage: string; members_touched: number; message: string } | null>(null);

  // Unified Scanner State
  const [scannerMode, setScannerMode] = useState<'record' | null>(null);
  const [showMobileQR, setShowMobileQR] = useState(false);

  // Status messages
  const [msg, setMsg] = useState<{ text: string; type: 'success' | 'error' } | null>(null);
  const [loading, setLoading] = useState(false);

  // --- Wave 2: Desktop Session Security (continued) ---
  // Lightweight "is there anything the admin would lose" signal, derived from
  // existing form state rather than tracked separately. Add a clause here
  // whenever a new form gains meaningful free-text/selection state.
  const hasUnsavedWork =
    voidReason.trim() !== '' ||
    invalidReason.trim() !== '' ||
    recordBallotId.trim() !== '' ||
    selectedCandidate.trim() !== '' ||
    newMemberName.trim() !== '' ||
    newMemberEmail.trim() !== '' ||
    newMemberPhone.trim() !== '' ||
    newMemberCode.trim() !== '' ||
    newMemberDob.trim() !== '' ||
    newMemberAgeEligible ||
    reissueReason.trim() !== '' ||
    csvContent.trim() !== '' ||
    csvFileName !== null ||
    candidateName.trim() !== '' ||
    candidateStatement.trim() !== '' ||
    candidatePhotoUrl.trim() !== '' ||
    editingCandidateId !== null ||
    nomAddQuery.trim() !== '' ||
    nomAddWriteInName.trim() !== '' ||
    nomAddReason.trim() !== '' ||
    nomAddSelectedMember !== null ||
    confirmText.trim() !== '' ||
    resetConfirmText.trim() !== '' ||
    eligibilityQuery.trim() !== '' ||
    purgeConfirmText.trim() !== '';

  // Drop straight to the full login screen — used only when there is nothing
  // unsaved to protect (ambient expiry detection with a clean form state).
  const dropToLoginScreen = useCallback((reason: SessionExpiryReason) => {
    setIsAuthenticated(false);
    setStats(null);
    setSessionExpiresAt(null);
    setSessionRemainingMs(null);
    setMsg({ text: SESSION_EXPIRY_COPY[reason] + ' Log in again.', type: 'error' });
  }, []);

  // Central decision point for any detected session expiry (401, or the local
  // countdown reaching zero). `source` distinguishes a failed mutation (the
  // admin was mid-action — always show the modal, never lose their place)
  // from an ambient check (passive /me poll or local countdown): ambient
  // expiry only opens the modal if there's unsaved work to protect, otherwise
  // it drops straight to the login screen. The reason only changes copy.
  //
  // WIRING HOOK for the mechanical step: call
  //   handleSessionExpiry('mutation', data.reason ?? 'unauthorized')
  // from each mutation call site's `if (res.status === 401) { ... }` branch
  // (paper-vote, paper-invalid, paper-batch, paper-void-unused,
  // phase, settings, candidates, members-manage, members-import,
  // tokens-dispatch, nominations/*, tokens/reissue, etc.) instead of / in
  // addition to whatever ad-hoc 401 handling exists there today.
  const handleSessionExpiry = useCallback(
    (source: SessionExpirySource, reason: SessionExpiryReason) => {
      setSessionExpiresAt(null);
      setSessionRemainingMs(null);
      if (source === 'mutation' || hasUnsavedWork) {
        setReauthReason(reason);
        setReauthError(null);
        setReauthOpen(true);
        return;
      }
      dropToLoginScreen(reason);
    },
    [hasUnsavedWork, dropToLoginScreen]
  );

  // Passive poll: detects server-side expiry/revocation even with no admin
  // action in flight. Does NOT bump the idle deadline server-side (GET /me
  // calls requireAdmin() without bumpIdle). Paused while the reauth modal is
  // already open (no point hammering a session we know is invalid).
  useEffect(() => {
    if (!isAuthenticated || reauthOpen) return;

    const poll = async () => {
      try {
        const res = await fetch('/api/admin/me');
        if (res.status === 401) {
          let reason: SessionExpiryReason = 'unauthorized';
          try {
            const data = await res.json();
            if (data?.reason) reason = data.reason;
          } catch {
            // no/invalid JSON body — keep the generic reason
          }
          handleSessionExpiry('ambient', reason);
          return;
        }
        if (res.ok) {
          const data = await res.json();
          setSessionExpiresAt(data.expiresAt ?? null);
        }
      } catch {
        // network hiccup — try again next interval, don't treat as expiry
      }
    };

    const interval = setInterval(() => {
      void poll();
    }, SESSION_POLL_INTERVAL_MS);
    return () => clearInterval(interval);
  }, [isAuthenticated, reauthOpen, handleSessionExpiry]);

  // Live countdown against the server deadline. A local tick to
  // zero is treated as an ambient expiry too — the exact reason (idle vs.
  // absolute) is unknowable purely client-side, so it defaults to
  // 'idle_expired'; any subsequent server 401 (poll or mutation) supplies the
  // authoritative reason and overwrites this guess.
  useEffect(() => {
    if (!isAuthenticated || !sessionExpiresAt) {
      const timer = setTimeout(() => setSessionRemainingMs(null), 0);
      return () => clearTimeout(timer);
    }
    const deadlineMs = new Date(sessionExpiresAt).getTime();
    const tick = () => {
      const remaining = deadlineMs - Date.now();
      setSessionRemainingMs(remaining);
      if (remaining <= 0) {
        handleSessionExpiry('ambient', 'idle_expired');
      }
    };
    const initial = setTimeout(tick, 0);
    const interval = setInterval(tick, 1000);
    return () => {
      clearTimeout(initial);
      clearInterval(interval);
    };
  }, [isAuthenticated, sessionExpiresAt, handleSessionExpiry]);

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

  const fetchStats = async () => {
    try {
      const res = await fetch('/api/admin/stats');
      if (res.ok) {
        const data = await res.json();
        setStats(data);
      }
    } catch {
      // Ignore
    }
  };

  const fetchPhaseInfo = async () => {
    try {
      const res = await fetch('/api/admin/phase', { cache: 'no-store' });
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
          pendingConfirmation: data.pendingConfirmation || null,
          pendingResetConfirmation: data.pendingResetConfirmation || null,
        });
        // Initialize form fields
        setNominationStart(data.nomination_start ? new Date(data.nomination_start).toISOString().slice(0, 16) : '');
        setNominationEnd(data.nomination_end ? new Date(data.nomination_end).toISOString().slice(0, 16) : '');
        setVotingStart(data.voting_start ? new Date(data.voting_start).toISOString().slice(0, 16) : '');
        setVotingEnd(data.voting_end ? new Date(data.voting_end).toISOString().slice(0, 16) : '');

        // Auto-set phaseAction to 'confirming' if there's a pending confirmation
        // This handles the case where user returns to dashboard after clicking email link
        if (data.pendingConfirmation && phaseAction === 'idle') {
          setTargetPhase(data.pendingConfirmation.phase);
          setPhaseAction('confirming');
        }

        // Auto-set resetAction to 'confirming' if there's a pending reset confirmation
        if (data.pendingResetConfirmation && resetAction === 'idle') {
          setResetAction('confirming');
        }
      }
    } catch {
      // Ignore
    }
  };

  const fetchVotingTokenTtlSettings = async () => {
    try {
      const res = await fetch('/api/admin/settings', { cache: 'no-store' });
      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to load voting token settings', type: 'error' });
        return;
      }
      if (typeof data.votingTokenTtlHours === 'number') {
        setVotingTokenTtlHours(data.votingTokenTtlHours);
      }
      if (typeof data.allowWriteIns === 'boolean') {
        setAllowWriteIns(data.allowWriteIns);
      }
      if (typeof data.maxNomineesPerMember === 'number') {
        setMaxNomineesPerMember(data.maxNomineesPerMember);
      }
      if (typeof data.ageRequirementEnabled === 'boolean') {
        setAgeRequirementEnabled(data.ageRequirementEnabled);
      }
      if (typeof data.minimumVotingAge === 'number') {
        setMinimumVotingAge(data.minimumVotingAge);
      }
      if (typeof data.allowAddingMemberDuringVoting === 'boolean') {
        setAllowAddingMemberDuringVoting(data.allowAddingMemberDuringVoting);
      }
    } catch {
      setMsg({ text: 'Server error loading voting token settings', type: 'error' });
    }
  };

  const handleSaveNominationSettings = async (e: React.FormEvent) => {
    e.preventDefault();
    setNominationSettingsLoading(true);
    setMsg(null);

    try {
      const res = await apiFetch('/api/admin/settings', {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ allowWriteIns, maxNomineesPerMember }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to update nomination settings', type: 'error' });
      } else {
        setAllowWriteIns(data.allowWriteIns);
        setMaxNomineesPerMember(data.maxNomineesPerMember);
        setMsg({ text: 'Nomination settings updated successfully', type: 'success' });
      }
    } catch {
      setMsg({ text: 'Server error updating nomination settings', type: 'error' });
    } finally {
      setNominationSettingsLoading(false);
    }
  };

  const handleSaveAgeRequirementSettings = async (e: React.FormEvent) => {
    e.preventDefault();
    setMsg(null);

    try {
      const res = await apiFetch('/api/admin/settings', {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ageRequirementEnabled, minimumVotingAge: minimumVotingAge || null }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to update age requirement settings', type: 'error' });
      } else {
        setAgeRequirementEnabled(data.ageRequirementEnabled);
        setMinimumVotingAge(data.minimumVotingAge || '');
        setMsg({ text: 'Age requirement settings updated successfully', type: 'success' });
      }
    } catch {
      setMsg({ text: 'Server error updating age requirement settings', type: 'error' });
    }
  };

  const handleSaveRosterSettings = async (e: React.FormEvent) => {
    e.preventDefault();
    setMsg(null);

    try {
      const res = await apiFetch('/api/admin/settings', {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ allowAddingMemberDuringVoting }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to update member roster settings', type: 'error' });
      } else {
        setAllowAddingMemberDuringVoting(data.allowAddingMemberDuringVoting);
        setMsg({ text: 'Member roster settings updated successfully', type: 'success' });
      }
    } catch {
      setMsg({ text: 'Server error updating member roster settings', type: 'error' });
    }
  };

  const handleGenerateReport = async () => {
    setReportLoading(true);
    setMsg(null);

    try {
      const res = await apiFetch('/api/admin/reporting', { cache: 'no-store' });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('ambient', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to generate report', type: 'error' });
      } else {
        setReportData(data);
      }
    } catch {
      setMsg({ text: 'Server error generating report', type: 'error' });
    } finally {
      setReportLoading(false);
    }
  };

  // Client-side CSV export of the currently loaded report snapshot (WYSIWYG).
  // UTF-8 BOM included so Excel opens it correctly.
  const downloadCsv = (filename: string, lines: string[]) => {
    const blob = new Blob(['\uFEFF' + lines.join('\n')], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  const csvEsc = (v: string | number) => {
    const s = String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };

  // Progress CSV: turnout metrics only. Available whenever the report is (VOTING+).
  const handleExportProgressCsv = () => {
    if (!reportData?.available) return;

    const lines: string[] = [];
    lines.push('Election Progress Report');
    lines.push(`Phase,${csvEsc(reportData.phase || '')}`);
    lines.push(`Generated (UTC),${csvEsc(new Date().toISOString())}`);
    lines.push('');
    lines.push('Metric,Count');
    lines.push(`Members checked in (paper),${reportData.checkedInCount ?? 0}`);
    lines.push(`Paper ballots recorded,${reportData.paperRecordedCount ?? 0}`);
    lines.push(`Digital votes,${reportData.digitalVoteCount ?? 0}`);
    lines.push(`Total votes,${reportData.totalVoteCount ?? 0}`);

    downloadCsv(`election-progress-${new Date().toISOString().slice(0, 10)}.csv`, lines);
  };

  // Results CSV: official tally. Gated to VOTING_CLOSED/COMPLETED — partial
  // tallies must not be exportable while voting is open (matches the public
  // /results publishing gate). The gate checks the SNAPSHOT's phase so the
  // button is enabled exactly when the on-screen tally is a post-close tally.
  const handleExportResultsCsv = () => {
    if (!reportData?.available) return;
    if (!['VOTING_CLOSED', 'COMPLETED'].includes(reportData.phase || '')) return;

    const lines: string[] = [];
    lines.push('Election Results Report');
    lines.push(`Phase,${csvEsc(reportData.phase || '')}`);
    lines.push(`Generated (UTC),${csvEsc(new Date().toISOString())}`);
    lines.push('');
    lines.push('Candidate,Votes,Percentage');
    reportData.results?.forEach(c => {
      lines.push(`${csvEsc(c.full_name)},${c.votes},${c.percentage}`);
    });

    downloadCsv(`election-results-${new Date().toISOString().slice(0, 10)}.csv`, lines);
  };

  // Member Management: fetch all members. Declared here (via useCallback for a
  // stable identity) so it's lexically available to the auth-triggered effect
  // below, which must fire fetchAllMembers on successful auth.
  const fetchAllMembers = useCallback(async () => {
    setMembersLoading(true);
    try {
      const res = await fetch('/api/admin/members-manage?limit=500', {
        
      });
      if (res.ok) {
        const data = await res.json();
        setAllMembers(data.members || []);
        if (data.stats) {
          setMemberStats(data.stats);
        }
      }
    } catch {
      // Ignore
    } finally {
      setMembersLoading(false);
    }
  }, []);

  // Nomination Adjudication: fetch nominations. Declared here for the same
  // reason as fetchAllMembers above — needed by the effect further down.
  const fetchNominations = useCallback(async () => {
    setNominationsLoading(true);
    try {
      const res = await apiFetch('/api/admin/nominations');
      const data = await res.json();
      if (res.ok) {
        setNominations({ matched: data.matched || [], unmatched: data.unmatched || [] });
      } else {
        setMsg({ text: data.error || 'Failed to load nominations', type: 'error' });
      }
    } catch {
      setMsg({ text: 'Server error loading nominations', type: 'error' });
    } finally {
      setNominationsLoading(false);
    }
  }, []);

  useEffect(() => {
    const timer = setTimeout(() => {
      void fetchCandidates();
    }, 0);

    return () => clearTimeout(timer);
  }, []);

  useEffect(() => {
    if (!isAuthenticated) return;

    const timer = setTimeout(() => {
      void fetchStats();
      void fetchPhaseInfo();
      void fetchVotingTokenTtlSettings();
      void fetchAllMembers();
    }, 0);

    return () => clearTimeout(timer);
  }, [isAuthenticated, fetchAllMembers]);

  useEffect(() => {
    if (!isAuthenticated) return;
    if (activeTab !== 'nominations') return;
    if (phaseInfo?.currentPhase !== 'NOMINATION_CLOSED') return;

    const timer = setTimeout(() => {
      void fetchNominations();
    }, 0);

    return () => clearTimeout(timer);
  }, [isAuthenticated, activeTab, phaseInfo?.currentPhase, fetchNominations]);

  const handleSaveVotingTokenTtl = async (e: React.FormEvent) => {
    e.preventDefault();
    const ttl = Number(votingTokenTtlHours);
    if (!Number.isInteger(ttl) || ttl < 1 || ttl > 2160) {
      setVotingTokenTtlError('Please enter an integer between 1 and 2160 hours.');
      return;
    }

    setVotingTokenTtlError(null);
    setVotingTokenTtlLoading(true);
    setMsg(null);

    try {
      const res = await apiFetch('/api/admin/settings', {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ votingTokenTtlHours: ttl }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to update voting token validity', type: 'error' });
      } else {
        setVotingTokenTtlHours(data.votingTokenTtlHours);
        setMsg({ text: 'Voting link validity updated successfully', type: 'success' });
      }
    } catch {
      setMsg({ text: 'Server error updating voting token validity', type: 'error' });
    } finally {
      setVotingTokenTtlLoading(false);
    }
  };

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
          { fps: 10, qrbox: { width: 300, height: 300 } },
          /* verbose= */ false
        );
        scanner.render(
          (decodedText: string) => {
            const id = extractBallotId(decodedText);
            if (scannerMode === 'record') {
              setRecordBallotId(id);
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

  const handleLogin = async (e: React.FormEvent) => {
    e.preventDefault();
    const form = e.currentTarget as HTMLFormElement;
    const secret = new FormData(form).get('secret') as string;
    if (!secret) return;

    // Verify secret with server and create cookie session
    let expiresAt: string | null = null;
    try {
      const res = await apiFetch('/api/admin/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ secret, scope: 'desktop' }),
      });
      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || 'Invalid admin secret', type: 'error' });
        return;
      }
      expiresAt = data.expiresAt ?? null;
    } catch {
      setMsg({ text: 'Server error verifying secret', type: 'error' });
      return;
    }

    setLoginSecret('');
    setIsAuthenticated(true);
    setSessionExpiresAt(expiresAt);
    fetchStats();
    setMsg({ text: 'Access granted', type: 'success' });
  };

  // Re-auth modal submit: mints a NEW session + CSRF cookie (server revokes
  // the old row) without touching isAuthenticated or any dashboard form
  // state. apiFetch already reads the CSRF cookie fresh on every call, so no
  // separate "store the token" step is needed beyond letting the browser
  // apply the Set-Cookie response — the same mechanism handleLogin relies on.
  const handleReauthSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!reauthSecret) return;
    setReauthLoading(true);
    setReauthError(null);
    try {
      const res = await apiFetch('/api/admin/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ secret: reauthSecret, scope: 'desktop' }),
      });
      const data = await res.json();
      if (!res.ok) {
        setReauthError(data.error || 'Invalid admin secret');
        return;
      }
      setSessionExpiresAt(data.expiresAt ?? null);
      setReauthSecret('');
      setReauthError(null);
      setReauthOpen(false);
      // Admin re-clicks whatever action failed — we do not auto-replay it.
    } catch {
      setReauthError('Server error verifying secret');
    } finally {
      setReauthLoading(false);
    }
  };

  // Explicit escape hatch out of the modal: abandon in-progress form state
  // and go to the full login screen instead of re-authing in place.
  const handleReauthFullLogin = () => {
    setReauthOpen(false);
    setReauthSecret('');
    setReauthError(null);
    dropToLoginScreen(reauthReason);
  };

  // Focus-trap + Escape-does-not-dismiss for the re-auth modal. Escape must
  // NOT close it (only a successful re-auth or the explicit "Go to full
  // login" escape hatch may); Tab/Shift+Tab cycle within the dialog only.
  useEffect(() => {
    if (!reauthOpen) return;
    const focusTimer = setTimeout(() => reauthSecretInputRef.current?.focus(), 0);

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        e.stopPropagation();
        return;
      }
      if (e.key !== 'Tab') return;
      const container = reauthDialogRef.current;
      if (!container) return;
      const focusable = container.querySelectorAll<HTMLElement>(
        'button, input, [href], select, textarea, [tabindex]:not([tabindex="-1"])'
      );
      if (focusable.length === 0) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (e.shiftKey && document.activeElement === first) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault();
        first.focus();
      }
    };

    document.addEventListener('keydown', handleKeyDown, true);
    return () => {
      clearTimeout(focusTimer);
      document.removeEventListener('keydown', handleKeyDown, true);
    };
  }, [reauthOpen]);

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

  const debouncedSearchMembers = (query: string) => {
    if (searchDebounceRef.current) clearTimeout(searchDebounceRef.current);
    if (query.trim().length < 2) {
      setMembers([]);
      return;
    }
    searchDebounceRef.current = setTimeout(() => {
      searchMembers();
    }, 300);
  };

  const openReissueDialog = (member: Member, token: MemberToken) => {
    setReissueDialog({ tokenId: token.id, memberName: member.full_name, tokenType: token.type });
    setReissueReason('');
    setReissueError(null);
  };

  const closeReissueDialog = () => {
    setReissueDialog(null);
    setReissueReason('');
    setReissueError(null);
  };

  const handleReissueToken = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!reissueDialog) return;
    if (!reissueReason.trim()) {
      setReissueError('Reason for reissue is required');
      return;
    }

    setReissueLoading(true);
    setReissueError(null);

    try {
      const res = await apiFetch('/api/admin/tokens/reissue', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ tokenId: reissueDialog.tokenId, reason: reissueReason.trim() }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setReissueError(data.error || 'Failed to void & reissue token');
        return;
      }
      const successText = data.message || 'Token voided and reissued';
      setReissueDialog(null);
      setReissueReason('');
      await searchMembers();
      setMsg({ text: successText, type: 'success' });
    } catch {
      setReissueError('Server error voiding & reissuing token');
    } finally {
      setReissueLoading(false);
    }
  };

  const issuePaperBallot = async (member: Member) => {
    setLoading(true);
    setMsg(null);

    try {
      const res = await apiFetch('/api/admin/paper-ballot', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          
        },
        body: JSON.stringify({ memberId: member.id }),
      });

      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to issue paper ballot', type: 'error' });
      } else {
        setIssuedModal({
          memberName: member.full_name,
          memberCode: data.memberCode ?? member.member_code,
          shortCode: data.shortCode,
          participationDate: data.participationDate ?? null,
          status: data.status ?? 'PAPER_ISSUED',
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
      const res = await apiFetch('/api/admin/paper-vote', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          
        },
        body: JSON.stringify({ ballotId: recordBallotId.trim(), candidateId: selectedCandidate }),
      });

      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
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
      const res = await apiFetch('/api/admin/paper-invalid', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          
        },
        body: JSON.stringify({ ballotId: recordBallotId.trim(), reason: invalidReason || 'Spoiled by admin' }),
      });

      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
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
      const res = await apiFetch('/api/admin/paper-batch', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ count: generateCount }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || data.message || 'Failed to generate batch', type: 'error' });
      } else {
        setMsg({ text: `Generated ${data.generatedCount} anonymous ballots for the pool.`, type: 'success' });
        setGeneratedBatch({ generatedCount: data.generatedCount, ballots: data.ballots || [] });
        setGenerateCount(10);
      }
    } catch {
      setMsg({ text: 'Server error generating batch', type: 'error' });
    } finally {
      setLoading(false);
    }
  };

  const handleVoidUnused = async (e: React.FormEvent) => {
    e.preventDefault();
    const reason = voidReason.trim() || 'Voided by admin';

    if (!confirm('Void ALL remaining unused anonymous ballots?')) return;

    setLoading(true);
    setMsg(null);

    try {
      const res = await apiFetch('/api/admin/paper-void-unused', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ reason }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || data.message || 'Failed to void ballots', type: 'error' });
      } else {
        setMsg({ text: `Successfully voided ${data.voidedCount} ballot(s).`, type: 'success' });
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
      const res = await apiFetch('/api/admin/phase', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'request', phase }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        setPhaseAction('idle');
        return;
      }
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

    // Step 2 complete - verify email confirmation (Step 1) was completed
    setPhaseLoading(true);
    setMsg(null);
    try {
      const res = await apiFetch('/api/admin/phase', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'verify_token', phase: targetPhase }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Email confirmation required. Please click the link in the email first.', type: 'error' });
        setPhaseLoading(false);
        return;
      }
      // Email confirmed - show final confirmation dialog (Step 3)
      setPhaseAction('final_confirm');
    } catch {
      setMsg({ text: 'Server error verifying confirmation', type: 'error' });
    } finally {
      setPhaseLoading(false);
    }
  };

  const handleFinalConfirmPhaseChange = async () => {
    setPhaseLoading(true);
    setMsg(null);
    setPhaseAction('executing');

    try {
      const res = await apiFetch('/api/admin/phase', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'execute', phase: targetPhase, confirmText }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        setPhaseAction('confirming');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to change phase', type: 'error' });
        setPhaseAction('confirming');
      } else {
        setMsg({ text: data.message || `Phase changed to ${data.newPhase}`, type: 'success' });
        setPhaseAction('idle');
        setTargetPhase('');
        setConfirmText('');
        // Refresh phase info and stats (for top-right Current Phase card)
        void fetchPhaseInfo();
        void fetchStats();
      }
    } catch {
      setMsg({ text: 'Server error executing phase change', type: 'error' });
      setPhaseAction('confirming');
    } finally {
      setPhaseLoading(false);
    }
  };

  const handleCancelPhaseChange = async () => {
    setPhaseLoading(true);
    try {
      const res = await apiFetch('/api/admin/phase', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'cancel', phase: targetPhase }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to cancel', type: 'error' });
      } else {
        setMsg({ text: data.message, type: 'success' });
      }
    } catch {
      setMsg({ text: 'Server error cancelling', type: 'error' });
    } finally {
      setPhaseAction('idle');
      setTargetPhase('');
      setConfirmText('');
      setPhaseLoading(false);
      void fetchPhaseInfo();
      void fetchStats();
    }
  };

  // Reset Election Handlers (three-fold confirmation)
  const handleRequestReset = async () => {
    setLoading(true);
    setMsg(null);
    setResetAction('requested');

    try {
      const res = await apiFetch('/api/admin/phase', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'request_reset' }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        setResetAction('idle');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to request reset', type: 'error' });
        setResetAction('idle');
      } else {
        setMsg({ text: data.message || 'Confirmation email sent. Check your inbox.', type: 'success' });
        setResetAction('confirming');
      }
    } catch {
      setMsg({ text: 'Server error requesting reset', type: 'error' });
      setResetAction('idle');
    } finally {
      setLoading(false);
    }
  };

  const handleVerifyResetToken = async (e: React.FormEvent) => {
    e.preventDefault();
    if (resetConfirmText !== 'RESET') {
      setMsg({ text: 'You must type RESET to proceed', type: 'error' });
      return;
    }

    setLoading(true);
    setMsg(null);
    try {
      const res = await apiFetch('/api/admin/phase', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'verify_reset_token' }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Email confirmation required. Please click the link in the email first.', type: 'error' });
        setLoading(false);
        return;
      }
      setResetAction('final_confirm');
    } catch {
      setMsg({ text: 'Server error verifying confirmation', type: 'error' });
    } finally {
      setLoading(false);
    }
  };

  const handleFinalConfirmReset = async () => {
    setLoading(true);
    setMsg(null);
    setResetAction('executing');

    try {
      const res = await apiFetch('/api/admin/phase', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'execute_reset', confirmText: resetConfirmText }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        setResetAction('confirming');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to reset election', type: 'error' });
        setResetAction('confirming');
      } else {
        setMsg({ text: data.message, type: 'success' });
        setResetAction('idle');
        setResetConfirmText('');
        void fetchPhaseInfo();
        void fetchStats();
      }
    } catch {
      setMsg({ text: 'Server error resetting election', type: 'error' });
      setResetAction('confirming');
    } finally {
      setLoading(false);
    }
  };

  const handleCancelReset = async () => {
    setLoading(true);
    try {
      const res = await apiFetch('/api/admin/phase', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'cancel', phase: 'SETUP' }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to cancel', type: 'error' });
      } else {
        setMsg({ text: data.message, type: 'success' });
      }
    } catch {
      setMsg({ text: 'Server error cancelling', type: 'error' });
    } finally {
      setResetAction('idle');
      setResetConfirmText('');
      setLoading(false);
      void fetchPhaseInfo();
      void fetchStats();
    }
  };

  const handleUpdateDates = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setMsg(null);

    try {
      const res = await apiFetch('/api/admin/phase', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          action: 'update_dates',
          nomination_start: nominationStart || null,
          nomination_end: nominationEnd || null,
          voting_start: votingStart || null,
          voting_end: votingEnd || null,
        }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to update election dates', type: 'error' });
      } else {
        setMsg({ text: 'Election dates updated successfully', type: 'success' });
        void fetchPhaseInfo();
      }
    } catch {
      setMsg({ text: 'Server error updating election dates', type: 'error' });
    } finally {
      setLoading(false);
    }
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

      const res = await apiFetch(url, {
        method,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
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
  // (fetchAllMembers is declared earlier via useCallback, before the effects that need it)

  // Activate/deactivate of EXISTING members stays locked once voting has started.
  const rosterToggleLocked =
    phaseInfo?.currentPhase === 'VOTING' ||
    phaseInfo?.currentPhase === 'VOTING_CLOSED' ||
    phaseInfo?.currentPhase === 'COMPLETED';

  // Adding NEW members is relaxed during VOTING only when the admin enables it
  // (Election Settings → Member Roster). Still locked in VOTING_CLOSED/COMPLETED.
  const rosterAddLocked =
    (phaseInfo?.currentPhase === 'VOTING' && !allowAddingMemberDuringVoting) ||
    phaseInfo?.currentPhase === 'VOTING_CLOSED' ||
    phaseInfo?.currentPhase === 'COMPLETED';

  const handleAddMember = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newMemberName.trim()) {
      setAddMemberError('Name is required');
      return;
    }

    setAddMemberLoading(true);
    setAddMemberError(null);
    setMsg(null);

    try {
      const res = await apiFetch('/api/admin/members-manage', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          full_name: newMemberName.trim(),
          email: newMemberEmail.trim() || null,
          phone: newMemberPhone.trim() || null,
          member_code: newMemberCode.trim() || null,
          dob: newMemberDob.trim() || null,
          age_eligible_asserted: newMemberAgeEligible || null,
        }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (res.status === 409) {
        setAddMemberError(data.error || 'A member with this code, email, or phone already exists.');
      } else if (!res.ok) {
        setAddMemberError(data.error || 'Failed to add member');
      } else {
        setNewMemberName('');
        setNewMemberEmail('');
        setNewMemberPhone('');
        setNewMemberCode('');
        setNewMemberDob('');
        setNewMemberAgeEligible(false);
        setMsg({ text: 'Member added', type: 'success' });
        void fetchAllMembers();
      }
    } catch {
      setAddMemberError('Server error adding member');
    } finally {
      setAddMemberLoading(false);
    }
  };

  const handleToggleMemberActive = async (member: Member) => {
    if (rosterAddLocked) return;
    setLoading(true);
    setMsg(null);

    try {
      const res = await apiFetch('/api/admin/members-manage', {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: member.id, is_active: !member.is_active }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
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

  // Bulk Import: CSV file upload (dropzone + click-to-browse) handlers.
  // Reads the file client-side and populates csvContent so the existing
  // textarea + handleImportMembers submit flow are unchanged.
  const CSV_MAX_BYTES = 1024 * 1024; // 1 MB

  const processCsvFile = (file: File) => {
    const nameLower = file.name.toLowerCase();
    const isCsvName = nameLower.endsWith('.csv');
    const isCsvType = file.type === 'text/csv' || file.type === 'text/plain';
    if (!isCsvName && !isCsvType) {
      setMsg({ text: `"${file.name}" is not a CSV file. Please select a .csv file.`, type: 'error' });
      return;
    }
    if (file.size > CSV_MAX_BYTES) {
      setMsg({ text: `"${file.name}" is too large (${(file.size / 1024).toFixed(0)} KB). Max file size is 1 MB.`, type: 'error' });
      return;
    }

    const reader = new FileReader();
    reader.onload = () => {
      const text = typeof reader.result === 'string' ? reader.result : '';
      setCsvContent(text);
      setCsvFileName(file.name);
      const lineCount = text.split(/\r\n|\r|\n/).filter(line => line.trim().length > 0).length;
      setCsvFileLineCount(lineCount);
      setMsg(null);
    };
    reader.onerror = () => {
      setMsg({ text: `Failed to read "${file.name}"`, type: 'error' });
    };
    reader.readAsText(file);
  };

  const handleCsvFileInputChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) processCsvFile(file);
    e.target.value = '';
  };

  const handleCsvDrop = (e: React.DragEvent<HTMLDivElement>) => {
    e.preventDefault();
    setCsvDragActive(false);
    const file = e.dataTransfer.files?.[0];
    if (file) processCsvFile(file);
  };

  const handleCsvDragOver = (e: React.DragEvent<HTMLDivElement>) => {
    e.preventDefault();
    setCsvDragActive(true);
  };

  const handleCsvDragLeave = (e: React.DragEvent<HTMLDivElement>) => {
    e.preventDefault();
    setCsvDragActive(false);
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
      const res = await apiFetch('/api/admin/members-import', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ csv: csvContent }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to import members', type: 'error' });
      } else {
        setImportResult(data);
        setMsg({ text: `Imported ${data.imported} members, ${data.failed} failed`, type: data.failed > 0 ? 'error' : 'success' });
        setCsvContent('');
        setCsvFileName(null);
        setCsvFileLineCount(null);
        if (csvFileInputRef.current) csvFileInputRef.current.value = '';
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
  const membersWithEmail = allMembers.filter(member => !!member.email?.trim());
  const membersWithoutEmailCount = allMembers.length - membersWithEmail.length;

  const handleDispatchTokens = async (e: React.FormEvent) => {
    e.preventDefault();
    const dispatchableMemberIds = dispatchMemberIds.filter(memberId =>
      membersWithEmail.some(member => member.id === memberId)
    );
    if (dispatchableMemberIds.length === 0) {
      setMsg({ text: 'Select at least one member', type: 'error' });
      return;
    }

    setLoading(true);
    setMsg(null);
    setDispatchResult(null);

    try {
      const res = await apiFetch('/api/admin/tokens-dispatch', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ memberIds: dispatchableMemberIds, type: dispatchType }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
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
    const member = allMembers.find(m => m.id === memberId);
    if (!member?.email?.trim()) return;
    setDispatchMemberIds(prev => prev.includes(memberId) ? prev.filter(id => id !== memberId) : [...prev, memberId]);
  };

  const handleSelectAllMembers = () => {
    const allSelectableSelected =
      membersWithEmail.length > 0 && membersWithEmail.every(member => dispatchMemberIds.includes(member.id));
    if (allSelectableSelected) {
      setDispatchMemberIds([]);
    } else {
      setDispatchMemberIds(membersWithEmail.map(m => m.id));
    }
  };

  const handleDeleteCandidate = async (id: string) => {
    if (!confirm('Are you sure you want to delete this candidate?')) return;

    setLoading(true);
    setMsg(null);

    try {
      const res = await apiFetch(`/api/admin/candidates?id=${id}`, {
        method: 'DELETE',
        
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
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
      const res = await apiFetch('/api/admin/candidates', {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: c.id, is_active: !c.is_active }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
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

  // Admin Out-of-Band Add Nomination Handlers
  const searchNomAddMembers = async (q: string) => {
    if (q.trim().length < 2) {
      setNomAddMatches([]);
      return;
    }
    setNomAddSearching(true);
    try {
      const res = await fetch(`/api/admin/members?q=${encodeURIComponent(q)}`);
      const data = await res.json();
      setNomAddMatches(res.ok ? (data.members || []) : []);
    } catch {
      setNomAddMatches([]);
    } finally {
      setNomAddSearching(false);
    }
  };

  const handleAddNomination = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!nomAddSelectedMember && !nomAddWriteInName.trim()) {
      setMsg({ text: 'Search and pick a member, or enter a write-in name.', type: 'error' });
      return;
    }

    setNomAddLoading(true);
    setMsg(null);

    try {
      const res = await apiFetch('/api/admin/nominations/add', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          nomineeMemberId: nomAddSelectedMember?.id ?? null,
          nomineeName: nomAddSelectedMember ? null : nomAddWriteInName.trim(),
          reason: nomAddReason.trim() || null,
        }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to add nomination', type: 'error' });
      } else {
        setMsg({ text: 'Nomination added', type: 'success' });
        setNomAddQuery('');
        setNomAddMatches([]);
        setNomAddSelectedMember(null);
        setNomAddWriteInName('');
        setNomAddReason('');
      }
    } catch {
      setMsg({ text: 'Server error adding nomination', type: 'error' });
    } finally {
      setNomAddLoading(false);
    }
  };

  // Nomination Adjudication Handlers
  // (fetchNominations is declared earlier via useCallback, before the effect that needs it)

  const handleAdjudicate = async (payload: {
    decision: 'PROMOTE' | 'MERGE' | 'DISCARD';
    nomineeMemberId?: string | null;
    nomineeName?: string;
    affectedNominationIds: string[];
    candidateId?: string;
  }) => {
    const key = payload.affectedNominationIds.join(',') + payload.decision;
    setAdjudicating(key);
    setMsg(null);

    try {
      const res = await apiFetch('/api/admin/nominations/adjudicate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Adjudication failed', type: 'error' });
      } else {
        setMsg({ text: `Decision recorded: ${payload.decision}`, type: 'success' });
        void fetchNominations();
        void fetchCandidates();
      }
    } catch {
      setMsg({ text: 'Server error recording decision', type: 'error' });
    } finally {
      setAdjudicating(null);
    }
  };

  // --- Voter Eligibility (Wave 5) ---
  // Reuses the exact same GET /api/admin/members?q= endpoint + plain fetch
  // (no CSRF needed for GET) as the existing searchMembers() above.
  const searchEligibilityMembers = async (e?: React.FormEvent) => {
    if (e) e.preventDefault();
    if (eligibilityQuery.trim().length < 2) {
      setMsg({ text: 'Search query must be at least 2 characters', type: 'error' });
      return;
    }

    setEligibilitySearching(true);
    setMsg(null);

    try {
      const res = await fetch(`/api/admin/members?q=${encodeURIComponent(eligibilityQuery)}`);
      const data = await res.json();
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to search members', type: 'error' });
      } else {
        const results: Member[] = data.members || [];
        setEligibilityResults(results);
        setEligibilityDrafts(Object.fromEntries(results.map(m => [m.id, draftFromMember(m)])));
      }
    } catch {
      setMsg({ text: 'Server error during search', type: 'error' });
    } finally {
      setEligibilitySearching(false);
    }
  };

  const debouncedSearchEligibility = (query: string) => {
    if (eligibilityDebounceRef.current) clearTimeout(eligibilityDebounceRef.current);
    if (query.trim().length < 2) {
      setEligibilityResults([]);
      return;
    }
    eligibilityDebounceRef.current = setTimeout(() => {
      searchEligibilityMembers();
    }, 300);
  };

  const updateEligibilityDraft = (memberId: string, patch: Partial<EligibilityDraft>) => {
    setEligibilityDrafts(prev => ({
      ...prev,
      [memberId]: { ...(prev[memberId] ?? { votingEligible: true, reason: 'MANUAL_ADMIN_HOLD', note: '' }), ...patch },
    }));
  };

  // Same apiFetch + Content-Type + CSRF pattern as handleAdjudicate above
  // (copied from app/api/admin/nominations/adjudicate's caller): apiFetch
  // auto-attaches the x-csrf-token double-submit header for POST, the
  // server enforces it via requireAdminWithCsrf.
  const handleSaveEligibility = async (member: Member) => {
    const draft = eligibilityDrafts[member.id] ?? draftFromMember(member);
    setEligibilitySavingId(member.id);
    setMsg(null);

    try {
      const res = await apiFetch('/api/admin/eligibility', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          member_id: member.id,
          voting_eligible: draft.votingEligible,
          eligibility_reason: draft.votingEligible ? 'ELIGIBLE' : draft.reason,
          note: draft.note.trim() || null,
        }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Failed to update eligibility', type: 'error' });
      } else {
        const newReason = draft.votingEligible ? 'ELIGIBLE' : draft.reason;
        setMsg({ text: data.message || 'Eligibility updated', type: 'success' });
        // Refresh this member's row in place (no need to re-run the search).
        setEligibilityResults(prev =>
          prev.map(m =>
            m.id === member.id
              ? { ...m, voting_eligible: draft.votingEligible, eligibility_reason: newReason, eligibility_source: 'ADMIN_ADJUDICATION' }
              : m
          )
        );
        updateEligibilityDraft(member.id, { note: '' });
      }
    } catch {
      setMsg({ text: 'Server error updating eligibility', type: 'error' });
    } finally {
      setEligibilitySavingId(null);
    }
  };

  // --- Purge Roster PII (Wave 5) ---
  const openPurgeConfirm = (stage: 'CONTACT' | 'IDENTITY') => {
    setPurgeStage(stage);
    setPurgeConfirmText('');
    setMsg(null);
  };

  const cancelPurgeConfirm = () => {
    setPurgeStage(null);
    setPurgeConfirmText('');
  };

  const handleConfirmPurge = async () => {
    if (!purgeStage || purgeConfirmText !== 'PURGE') return;
    setPurgeLoading(true);
    setMsg(null);

    try {
      const res = await apiFetch('/api/admin/purge', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ stage: purgeStage, confirm: purgeConfirmText }),
      });
      const data = await res.json();
      if (res.status === 401) {
        handleSessionExpiry('mutation', data.reason ?? 'unauthorized');
        return;
      }
      if (!res.ok) {
        setMsg({ text: data.error || 'Purge failed', type: 'error' });
      } else {
        setMsg({ text: data.message || `Purge complete — ${data.members_touched} member(s) affected.`, type: 'success' });
        setPurgeResult({ stage: data.stage, members_touched: data.members_touched, message: data.message });
        setPurgeStage(null);
        setPurgeConfirmText('');
      }
    } catch {
      setMsg({ text: 'Server error running purge', type: 'error' });
    } finally {
      setPurgeLoading(false);
    }
  };

if (!mounted) {
    return (
      <div suppressHydrationWarning className="min-h-screen bg-gray-50 dark:bg-gray-900 py-12 px-4 flex items-center justify-center">
        <div className="max-w-md w-full bg-white dark:bg-gray-800 rounded-lg shadow-md p-8">
          <div className="animate-pulse space-y-4">
            <div className="h-8 bg-gray-200 dark:bg-gray-700 rounded w-3/4"></div>
            <div className="h-4 bg-gray-200 dark:bg-gray-700 rounded w-1/2"></div>
            <div className="h-10 bg-gray-200 dark:bg-gray-700 rounded"></div>
          </div>
      </div>
    </div>
  );
}

  if (!isAuthenticated) {
    return (
      <div suppressHydrationWarning className="min-h-screen bg-gray-50 dark:bg-gray-900 py-12 px-4 flex items-center justify-center">
        <div className="max-w-md w-full bg-white dark:bg-gray-800 rounded-lg shadow-md p-8">
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white mb-2">Admin Dashboard</h1>
          <p className="text-sm text-gray-600 dark:text-gray-400 mb-6">Enter Admin Secret to access management functions.</p>
          {msg && msg.type === 'error' && (
            <div className="mb-4 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg text-red-800 dark:text-red-300 text-sm">
              {msg.text}
            </div>
          )}
          <form onSubmit={handleLogin} className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                Admin Secret
              </label>
              <input
                type="password"
                name="secret"
                value={loginSecret}
                onChange={e => setLoginSecret(e.target.value)}
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
    <div suppressHydrationWarning className="min-h-screen bg-gray-50 dark:bg-gray-900 py-8 px-4 sm:px-6 lg:px-8">
      <div className="max-w-5xl mx-auto">
        {/* Header */}
        <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center mb-8 gap-4 print:hidden">
          <div>
            <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Election Admin Dashboard</h1>
            <p className="text-sm text-gray-500 dark:text-gray-400">
              Manage member voting eligibility, paper ballot issuance, and paper vote recording.
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <a
              href="/admin/mobile"
              className="px-3 py-1.5 text-xs font-medium bg-blue-600 hover:bg-blue-700 text-white rounded"
            >
              📱 Mobile Wizard
            </a>
            <button
              onClick={() => setShowMobileQR(true)}
              className="px-3 py-1.5 text-xs font-medium bg-gray-600 hover:bg-gray-700 text-white rounded"
            >
              📱 Mobile QR
            </button>
            <button
              onClick={handleLogout}
              className="px-3 py-1.5 text-xs font-medium border border-gray-300 dark:border-gray-600 rounded text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700"
            >
              Clear Admin Auth
            </button>
          </div>
        </div>

        {/* Session expiry warning — only surfaces near the end of the idle window; not a blocking element */}
        {sessionRemainingMs !== null && sessionRemainingMs > 0 && sessionRemainingMs <= SESSION_WARNING_THRESHOLD_MS && (
          <div className="mb-6 p-3 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg text-yellow-800 dark:text-yellow-300 text-sm print:hidden">
            Your session expires in {formatSessionCountdown(sessionRemainingMs)} — any action keeps you signed in.
          </div>
        )}

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
            Preprinted Ballots
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
          <button
            onClick={() => setActiveTab('nominations')}
            className={`py-2 px-4 font-medium text-sm border-b-2 ${
              activeTab === 'nominations'
                ? 'border-blue-600 text-blue-600 dark:text-blue-400'
                : 'border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400'
            }`}
          >
            Nominations
          </button>
          <button
            onClick={() => setActiveTab('eligibility')}
            className={`py-2 px-4 font-medium text-sm border-b-2 ${
              activeTab === 'eligibility'
                ? 'border-blue-600 text-blue-600 dark:text-blue-400'
                : 'border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400'
            }`}
          >
            Voter Eligibility
          </button>
          {['VOTING', 'VOTING_CLOSED', 'COMPLETED'].includes(phaseInfo?.currentPhase || '') && (
            <button
              onClick={() => setActiveTab('reporting')}
              className={`py-2 px-4 font-medium text-sm border-b-2 ${
                activeTab === 'reporting'
                  ? 'border-blue-600 text-blue-600 dark:text-blue-400'
                  : 'border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400'
              }`}
            >
              Reporting
            </button>
          )}
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
                  onChange={e => {
                    setSearchQuery(e.target.value);
                    debouncedSearchMembers(e.target.value);
                  }}
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
                        {member.paperCheckIn && (
                          <p className="text-xs text-blue-500 mt-1">
                            Paper check-in code: <span className="font-mono font-bold">{member.paperCheckIn.shortCode}</span>
                          </p>
                        )}
                        {(member.tokens ?? []).length > 0 && (
                          <div className="mt-2 space-y-1">
                            {(member.tokens ?? []).map(token => (
                              <div key={token.id} className="flex items-center gap-2 text-xs">
                                <span className="font-medium text-gray-700 dark:text-gray-300">{token.type} token</span>
                                <span
                                  className={`px-2 py-0.5 rounded font-semibold ${
                                    token.is_used
                                      ? 'bg-gray-200 text-gray-700 dark:bg-gray-700 dark:text-gray-300'
                                      : 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400'
                                  }`}
                                >
                                  {token.is_used ? 'USED' : 'ACTIVE'}
                                </span>
                                {token.is_used ? (
                                  <span className="text-gray-400 dark:text-gray-500 italic">
                                    Used — cannot be reissued
                                  </span>
                                ) : (
                                  <button
                                    type="button"
                                    onClick={() => openReissueDialog(member, token)}
                                    className="px-2 py-1 text-xs bg-red-600 hover:bg-red-700 text-white font-medium rounded"
                                  >
                                    Void & reissue
                                  </button>
                                )}
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                      <div className="flex items-center gap-3">
                        {member.votingStatus === 'DIGITAL_RESERVED' ? (
                          // Wave 7 — transient "redeemed but not yet cast" state. Amber (not
                          // yellow, which PAPER_ISSUED already owns) + a pulsing dot signal
                          // "in progress, resolves on its own" so admins don't over-react to
                          // a normal TTL window. See docs/specs/2026-09-17-wave7-digital-vote-ux.md §8.
                          <div>
                            <span
                              title="This member redeemed a digital voting credential but hasn't finished casting yet. This is normal and temporary — it resolves on its own when the credential expires or the vote completes. No admin action is needed unless it persists for an unusually long time."
                              className="inline-flex items-center gap-1.5 px-2.5 py-1 text-xs font-semibold rounded-full bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-400"
                            >
                              <span className="w-1.5 h-1.5 rounded-full bg-amber-500 animate-pulse" aria-hidden="true" />
                              RESERVED
                            </span>
                            <p className="mt-1 text-[11px] text-amber-700 dark:text-amber-500 max-w-[220px]">
                              In progress — resolves automatically
                            </p>
                          </div>
                        ) : (
                          <span
                            title={STATUS_BADGE[member.votingStatus].title}
                            className={`px-2.5 py-1 text-xs font-semibold rounded-full ${STATUS_BADGE[member.votingStatus].className}`}
                          >
                            {STATUS_BADGE[member.votingStatus].label}
                          </span>
                        )}

                        {(member.votingStatus === 'NO_ENTITLEMENT' ||
                          member.votingStatus === 'ENTITLED' ||
                          member.votingStatus === 'DIGITAL_ISSUED') && (
                          <button
                            onClick={() => issuePaperBallot(member)}
                            disabled={loading}
                            className="px-3 py-1.5 text-xs bg-indigo-600 hover:bg-indigo-700 text-white font-medium rounded disabled:opacity-50"
                          >
                            Check-in
                          </button>
                        )}

                        {member.votingStatus === 'PAPER_ISSUED' && (
                          <div className="text-right">
                            <p className="text-xs font-medium text-gray-700 dark:text-gray-300">Paper checked in</p>
                            <p className="text-[11px] text-gray-400 dark:text-gray-500 max-w-[220px]">
                              Anonymous ballot QR is only on the physical ballot.
                            </p>
                          </div>
                        )}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
        )}

        {/* Tab 2: Anonymous Ballot Pool (Option E) — pool ballots are printed
            here with NO member identity attached; per-member paper check-in
            (identity slip) lives on Tab 1's Issue Paper Ballot flow instead. */}
        {activeTab === 'inventory' && (
          <div className="space-y-6">
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6 print:hidden">
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

            {/* Generated Anonymous Ballot Pool — print view */}
            {generatedBatch && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow mt-6 print:p-0 print:m-0 print:shadow-none print:bg-transparent print:rounded-none">
                <div className="flex justify-between items-center mb-6 print:hidden">
                  <div>
                    <h2 className="text-xl font-bold text-gray-900 dark:text-white">Anonymous Ballot Pool</h2>
                    <p className="text-sm text-gray-500">Count: {generatedBatch.generatedCount}</p>
                    <p className="text-xs font-medium text-blue-600 dark:text-blue-400 mt-1">
                      Anonymous ballots only — no member identity appears anywhere on this sheet.
                    </p>
                    <p className="text-xs text-gray-400 mt-1">
                      Prints as A6 ballots, {ballotsPerSheet}-up on A4. Cut along the dashed guides after printing.
                      {candidates.length === 0 && (
                        <span className="text-amber-600 dark:text-amber-400"> No active candidates loaded — the printed ballot will have an empty mark list.</span>
                      )}
                    </p>
                    <p className="text-xs font-medium text-amber-600 dark:text-amber-400 mt-1">
                      In the print dialog set <span className="font-bold">Margins: None</span> and <span className="font-bold">Scale: 100%</span>.
                    </p>
                    <div className="flex items-center gap-2 mt-3">
                      <span className="text-xs font-medium text-gray-500 dark:text-gray-400">Ballots per sheet:</span>
                      <div className="inline-flex rounded-md border border-gray-300 dark:border-gray-600 overflow-hidden">
                        <button
                          type="button"
                          onClick={() => setBallotsPerSheet(4)}
                          aria-pressed={ballotsPerSheet === 4}
                          className={`px-3 py-1 text-xs font-medium ${
                            ballotsPerSheet === 4
                              ? 'bg-blue-600 text-white'
                              : 'bg-white dark:bg-gray-700 text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-600'
                          }`}
                        >
                          4 (A6)
                        </button>
                        <button
                          type="button"
                          onClick={() => setBallotsPerSheet(6)}
                          aria-pressed={ballotsPerSheet === 6}
                          className={`px-3 py-1 text-xs font-medium border-l border-gray-300 dark:border-gray-600 ${
                            ballotsPerSheet === 6
                              ? 'bg-blue-600 text-white'
                              : 'bg-white dark:bg-gray-700 text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-600'
                          }`}
                        >
                          6
                        </button>
                      </div>
                    </div>
                  </div>
                  <button
                    onClick={() => window.print()}
                    className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium"
                  >
                    Print Ballots
                  </button>
                </div>

                {/* Screen preview: compact card grid, not printed (see .ballot-sheet below for the print layout) */}
                <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-6 print:hidden">
                  {generatedBatch.ballots.map(b => (
                    <div key={b.ballotId} className="flex flex-col items-center p-4 border border-gray-200 dark:border-gray-700 rounded text-center">
                      {b.qrDataUrl && (
                        <Image
                          src={b.qrDataUrl}
                          alt="Anonymous ballot QR"
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

                {/* Print view: A6 ballots, N-up per A4 sheet (see app/globals.css @media print rules) */}
                <div className={`hidden print:block ballot-print-root ${ballotsPerSheet === 6 ? 'layout-6up' : ''}`}>
                  {chunkArray(generatedBatch.ballots, ballotsPerSheet).map((sheetBallots, sheetIdx) => (
                    <div className="ballot-sheet" key={sheetIdx}>
                      {/* Cut guides: vertical column split is the same for both layouts; horizontal
                          row splits differ (one line at 148.5mm for 4-up, two lines at 99mm/198mm
                          for 6-up) so they're driven by ballotsPerSheet rather than hard-coded CSS. */}
                      <div className="ballot-cut-line ballot-cut-line--vertical" aria-hidden="true" />
                      {(ballotsPerSheet === 6 ? ['99mm', '198mm'] : ['148.5mm']).map(top => (
                        <div
                          key={top}
                          className="ballot-cut-line ballot-cut-line--horizontal"
                          style={{ top }}
                          aria-hidden="true"
                        />
                      ))}
                      {sheetBallots.map(b => (
                        <div className="ballot-tile" key={b.ballotId}>
                          <div className="ballot-tile-header">
                            <p className="ballot-title">ANONYMOUS BALLOT</p>
                          </div>

                          {b.qrDataUrl && (
                            <div className="ballot-qr-wrap">
                              <Image
                                src={b.qrDataUrl}
                                alt="Anonymous ballot QR"
                                width={128}
                                height={128}
                                unoptimized
                                className="ballot-qr"
                              />
                            </div>
                          )}

                          <p className="ballot-instruction">Mark ONE box only.</p>

                          <ul className="ballot-candidate-list">
                            {candidates.map(c => (
                              <li key={c.id} className="ballot-candidate-row">
                                <span className="ballot-mark-box" aria-hidden="true" />
                                <span className="ballot-candidate-name">{c.full_name}</span>
                              </li>
                            ))}
                          </ul>

                          <p className="ballot-id-footer">{b.ballotId}</p>
                        </div>
                      ))}
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
        )}


        {/* Tab 3: Record / Spoil Paper Vote */}
        {activeTab === 'record' && (
          <div className="space-y-6 print:hidden">
            {/* Shared Ballot Lookup */}
            <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Ballot Lookup</h2>
              <div className="space-y-4">
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
                  <div className="p-3 bg-gray-100 dark:bg-gray-700 rounded-lg">
                    <div id="qr-reader" className="w-full"></div>
                  </div>
                )}

                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    Ballot ID <span className="text-red-500">*</span>
                  </label>
                  <input
                    type="text"
                    value={recordBallotId}
                    onChange={e => setRecordBallotId(e.target.value)}
                    placeholder="Enter full HMAC Ballot ID or scan QR code above..."
                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  />
                </div>
              </div>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              {/* Record Vote */}
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Record Paper Vote</h2>
                <form onSubmit={handleRecordPaperVote} className="space-y-4">
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
                    disabled={loading || !recordBallotId.trim() || !selectedCandidate}
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
                    disabled={loading || !recordBallotId.trim()}
                    className="w-full py-2 bg-red-600 hover:bg-red-700 text-white rounded font-medium disabled:opacity-50"
                  >
                    Mark Ballot Spoiled / Invalid
                  </button>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* Modal: Issued Paper Check-In (identity slip only). Per the locked
            Option A design decision, no UI may co-locate a member identity
            with a ballot_id/QR — the anonymous ballot QR lives only on the
            pool sheet in Tab 2. This modal shows the member's identity slip:
            a short code they take to redeem an anonymous ballot in person. */}
        {issuedModal && (
          <>
            <div className="fixed inset-0 bg-black/50 flex items-center justify-center p-4 z-50 print:hidden">
              <div className="bg-white dark:bg-gray-800 rounded-lg shadow-xl max-w-md w-full p-6 space-y-4">
                <h3 className="text-lg font-bold text-gray-900 dark:text-white">
                  Paper Check-In Issued
                </h3>
                <p className="text-sm text-gray-600 dark:text-gray-400">
                  Identity slip for: <span className="font-semibold text-gray-900 dark:text-white">{issuedModal.memberName}</span>{' '}
                  <span className="text-xs text-gray-400">({issuedModal.memberCode})</span>
                </p>

                <div className="bg-gray-50 dark:bg-gray-700 p-4 rounded text-center space-y-2">
                  <p className="text-xs text-gray-500 dark:text-gray-400">CHECK-IN CODE</p>
                  <p className="text-xl font-mono font-bold tracking-widest text-blue-600 dark:text-blue-400">
                    {issuedModal.shortCode}
                  </p>
                </div>

                <p className="text-xs text-center text-gray-500 dark:text-gray-400">
                  Give this slip to the member. They exchange it in person for an anonymous ballot from the printed pool sheet — no member identity is ever recorded against a ballot ID.
                </p>

                <div className="flex gap-3">
                  <button
                    onClick={() => window.print()}
                    className="flex-1 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium"
                  >
                    Print Slip
                  </button>
                  <button
                    onClick={() => setIssuedModal(null)}
                    className="flex-1 py-2 bg-gray-900 dark:bg-gray-700 text-white rounded font-medium hover:bg-gray-800"
                  >
                    Close Modal
                  </button>
                </div>
              </div>
            </div>

            {/* Print view: identity slip only. No candidate list, no ballot
                QR/id — the anonymous ballot itself is picked up separately
                from the preprinted pool sheet (Tab 2), never linked to this
                member digitally. */}
            <div className="hidden print:block ballot-print-root">
              <div className="ballot-tile">
                <div className="ballot-tile-header">
                  <p className="ballot-title">PAPER CHECK-IN SLIP</p>
                  <p className="ballot-shortcode">{issuedModal.shortCode}</p>
                </div>

                <p className="ballot-instruction">
                  {issuedModal.memberName} ({issuedModal.memberCode})
                </p>

                <p className="ballot-id-footer">Exchange this slip for an anonymous ballot at the pool table.</p>
              </div>
            </div>
          </>
        )}

        {/* Modal: Void & Reissue Token */}
        {reissueDialog && (
          <div className="fixed inset-0 bg-black/50 flex items-center justify-center p-4 z-50 print:hidden">
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow-xl max-w-md w-full p-6 space-y-4">
              <h3 className="text-lg font-bold text-gray-900 dark:text-white">
                Void & Reissue Token
              </h3>
              <p className="text-sm text-gray-600 dark:text-gray-400">
                Member: <span className="font-semibold text-gray-900 dark:text-white">{reissueDialog.memberName}</span>
                {' '}&mdash; <span className="font-mono">{reissueDialog.tokenType}</span> token
              </p>
              <p className="text-sm text-gray-600 dark:text-gray-400">
                This voids the current token and issues a new one. The member will need the new link.
              </p>

              {reissueError && (
                <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg text-red-800 dark:text-red-300 text-sm">
                  {reissueError}
                </div>
              )}

              <form onSubmit={handleReissueToken} className="space-y-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    Reason for reissue
                  </label>
                  <input
                    type="text"
                    value={reissueReason}
                    onChange={e => setReissueReason(e.target.value)}
                    placeholder="e.g. Member never received the email, link lost..."
                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    required
                  />
                </div>
                <div className="flex gap-3">
                  <button
                    type="submit"
                    disabled={reissueLoading}
                    className="px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded font-medium disabled:opacity-50"
                  >
                    {reissueLoading ? 'Voiding & reissuing...' : 'Void & reissue token'}
                  </button>
                  <button
                    type="button"
                    onClick={closeReissueDialog}
                    disabled={reissueLoading}
                    className="px-4 py-2 bg-gray-600 hover:bg-gray-700 text-white rounded font-medium disabled:opacity-50"
                  >
                    Cancel
                  </button>
                </div>
              </form>
            </div>
          </div>
        )}

        {/* Modal: Re-auth (Wave 2 — Admin Session Security).
            Renders on top of the still-mounted dashboard; never routes through
            the isAuthenticated=false login-tree, so in-progress form state
            (void reason, add-member fields, CSV selection, etc.) survives. */}
        {reauthOpen && (
          <div className="fixed inset-0 bg-black/50 flex items-center justify-center p-4 z-[60] print:hidden">
            <div
              ref={reauthDialogRef}
              role="dialog"
              aria-modal="true"
              aria-labelledby="reauth-modal-title"
              className="bg-white dark:bg-gray-800 rounded-lg shadow-xl max-w-md w-full p-6 space-y-4"
            >
              <h3 id="reauth-modal-title" className="text-lg font-bold text-gray-900 dark:text-white">
                Sign in again to continue
              </h3>
              <p className="text-sm text-gray-600 dark:text-gray-400">
                {SESSION_EXPIRY_COPY[reauthReason]} Your work on this page hasn&apos;t been lost — sign in
                again to continue where you left off.
              </p>

              {reauthError && (
                <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg text-red-800 dark:text-red-300 text-sm">
                  {reauthError}
                </div>
              )}

              <form onSubmit={handleReauthSubmit} className="space-y-4">
                <div>
                  <label htmlFor="reauth-secret" className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    Admin Secret
                  </label>
                  <input
                    ref={reauthSecretInputRef}
                    id="reauth-secret"
                    type="password"
                    value={reauthSecret}
                    onChange={e => setReauthSecret(e.target.value)}
                    placeholder="Enter admin secret..."
                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    required
                  />
                </div>
                <div className="flex gap-3">
                  <button
                    type="submit"
                    disabled={reauthLoading}
                    className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium disabled:opacity-50"
                  >
                    {reauthLoading ? 'Signing in...' : 'Sign in'}
                  </button>
                  <button
                    type="button"
                    onClick={handleReauthFullLogin}
                    disabled={reauthLoading}
                    className="px-4 py-2 bg-gray-600 hover:bg-gray-700 text-white rounded font-medium disabled:opacity-50"
                  >
                    Go to full login
                  </button>
                </div>
              </form>
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
            {phaseInfo && !phaseInfo.isTerminal && phaseAction === 'idle' && !phaseInfo.pendingConfirmation && (
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

            {/* Pending Phase Change (token exists - either email sent or link clicked) */}
            {phaseInfo && !phaseInfo.isTerminal && phaseAction === 'idle' && phaseInfo.pendingConfirmation && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow border border-amber-200 dark:border-amber-900/50">
                <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">
                  {phaseInfo.pendingConfirmation.used ? 'Awaiting Email Confirmation' : 'Pending Phase Change'}
                </h2>
                <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                  {phaseInfo.pendingConfirmation.used
                    ? `A confirmation email has been sent for advancing to <strong>${phaseInfo.pendingConfirmation.phase}</strong>. Click the link in the email, then return here to complete the change.`
                    : `A confirmation email was sent for advancing to <strong>${phaseInfo.pendingConfirmation.phase}</strong>. Click the link in the email to confirm, then return here to complete the change.`}
                </p>
                <div className="flex gap-3">
                  {phaseInfo.pendingConfirmation.used ? (
                    <>
                      <button
                        onClick={() => {
                          setTargetPhase(phaseInfo.pendingConfirmation!.phase);
                          setPhaseAction('confirming');
                        }}
                        disabled={phaseLoading}
                        className="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded font-medium disabled:opacity-50"
                      >
                        Continue Confirmation
                      </button>
                      <button
                        onClick={() => handleCancelPhaseChange()}
                        disabled={phaseLoading}
                        className="px-4 py-2 bg-gray-600 hover:bg-gray-700 text-white rounded font-medium disabled:opacity-50"
                      >
                        Cancel
                      </button>
                    </>
                  ) : (
                    <button
                      onClick={() => handleCancelPhaseChange()}
                      disabled={phaseLoading}
                      className="px-4 py-2 bg-gray-600 hover:bg-gray-700 text-white rounded font-medium disabled:opacity-50"
                    >
                      Cancel
                    </button>
                  )}
                </div>
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

            {/* Final Confirmation Dialog (Step 3) */}
            {phaseInfo && phaseAction === 'final_confirm' && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow border border-red-200 dark:border-red-900/50">
                <div className="flex items-center gap-3 mb-4">
                  <svg className="w-8 h-8 text-red-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
                  </svg>
                  <h2 className="text-lg font-semibold text-gray-900 dark:text-white">Final Confirmation Required</h2>
                </div>
                <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                  You have completed Steps 1 & 2:
                </p>
                <ul className="text-sm text-gray-600 dark:text-gray-400 mb-4 list-disc list-inside space-y-1">
                  <li>✓ Step 1: Clicked confirmation link in email</li>
                  <li>✓ Step 2: Typed CONFIRM</li>
                </ul>
                <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                  <strong>Step 3:</strong> Click the button below to finalize the phase change from <strong>{phaseInfo.currentPhase}</strong> to <strong>{targetPhase}</strong>.
                </p>
                <div className="flex gap-3">
                  <button
                    onClick={handleFinalConfirmPhaseChange}
                    disabled={phaseLoading}
                    className="px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded font-medium disabled:opacity-50"
                  >
                    {phaseLoading ? 'Executing...' : 'Confirm Phase Change (Final)'}
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

            {/* Reset Election (for testing) - Three-fold confirmation */}
            {phaseInfo && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow border border-yellow-200 dark:border-yellow-900/50">
                <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Reset Election (Testing)</h2>
                <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                  Reset the election to SETUP phase. This clears the current phase but preserves members, candidates, and ballots.
                  Use for testing new election cycles.
                </p>

                {/* Pending Reset (token exists - either email sent or link clicked) */}
                {resetAction === 'idle' && phaseInfo.pendingResetConfirmation && (
                  <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border border-amber-200 dark:border-amber-900/50 mb-4">
                    <h3 className="font-medium text-gray-900 dark:text-white mb-2">
                      {phaseInfo.pendingResetConfirmation.used ? 'Awaiting Email Confirmation' : 'Pending Reset Election'}
                    </h3>
                    <p className="text-sm text-gray-600 dark:text-gray-400 mb-3">
                      {phaseInfo.pendingResetConfirmation.used
                        ? 'A confirmation email has been sent for resetting to SETUP. Click the link in the email, then return here to complete the reset.'
                        : 'A confirmation email was sent for resetting to SETUP. Click the link in the email to confirm, then return here to complete the reset.'}
                    </p>
                    <div className="flex gap-3">
                      {phaseInfo.pendingResetConfirmation.used ? (
                        <>
                          <button
                            onClick={() => setResetAction('confirming')}
                            disabled={loading}
                            className="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded font-medium disabled:opacity-50"
                          >
                            Continue Confirmation
                          </button>
                          <button
                            onClick={handleCancelReset}
                            disabled={loading}
                            className="px-4 py-2 bg-gray-600 hover:bg-gray-700 text-white rounded font-medium disabled:opacity-50"
                          >
                            Cancel
                          </button>
                        </>
                      ) : (
                        <button
                          onClick={handleCancelReset}
                          disabled={loading}
                          className="px-4 py-2 bg-gray-600 hover:bg-gray-700 text-white rounded font-medium disabled:opacity-50"
                        >
                          Cancel
                        </button>
                      )}
                    </div>
                  </div>
                )}

                {/* Step 1: Request reset */}
                {resetAction === 'idle' && !phaseInfo.pendingResetConfirmation && (
                  <button
                    onClick={handleRequestReset}
                    disabled={loading}
                    className="px-4 py-2 bg-yellow-600 hover:bg-yellow-700 text-white rounded font-medium disabled:opacity-50"
                  >
                    {loading ? 'Requesting...' : 'Request Reset (Sends Email)'}
                  </button>
                )}

                {/* Step 2: Awaiting email confirmation */}
                {resetAction === 'confirming' && (
                  <div className="space-y-4">
                    <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border border-blue-200 dark:border-blue-900/50">
                      <h3 className="font-medium text-gray-900 dark:text-white mb-2">Awaiting Email Confirmation</h3>
                      <p className="text-sm text-gray-600 dark:text-gray-400">
                        A confirmation email has been sent for resetting to SETUP.
                        Click the link in the email, then return here to complete the reset.
                      </p>
                    </div>
                    <form onSubmit={handleVerifyResetToken} className="space-y-4">
                      <div>
                        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                          Type RESET to proceed <span className="text-red-500">*</span>
                        </label>
                        <input
                          type="text"
                          value={resetConfirmText}
                          onChange={e => setResetConfirmText(e.target.value)}
                          placeholder="RESET"
                          className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white font-mono"
                          required
                        />
                      </div>
                      <div className="flex gap-3">
                        <button
                          type="submit"
                          disabled={loading}
                          className="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded font-medium disabled:opacity-50"
                        >
                          {loading ? 'Verifying...' : 'Verify & Continue'}
                        </button>
                        <button
                          type="button"
                          onClick={handleCancelReset}
                          disabled={loading}
                          className="px-4 py-2 bg-gray-600 hover:bg-gray-700 text-white rounded font-medium disabled:opacity-50"
                        >
                          Cancel
                        </button>
                      </div>
                    </form>
                  </div>
                )}

                {/* Step 3: Final confirmation */}
                {resetAction === 'final_confirm' && (
                  <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow border border-red-200 dark:border-red-900/50">
                    <div className="flex items-center gap-3 mb-4">
                      <svg className="w-8 h-8 text-red-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
                      </svg>
                      <h2 className="text-lg font-semibold text-gray-900 dark:text-white">Final Confirmation Required</h2>
                    </div>
                    <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                      You have completed Steps 1 & 2:
                    </p>
                    <ul className="text-sm text-gray-600 dark:text-gray-400 mb-4 list-disc list-inside space-y-1">
                      <li>✓ Step 1: Clicked confirmation link in email</li>
                      <li>✓ Step 2: Typed RESET</li>
                    </ul>
                    <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                      <strong>Step 3:</strong> Click the button below to finalize the election reset to SETUP.
                    </p>
                    <div className="flex gap-3">
                      <button
                        onClick={handleFinalConfirmReset}
                        disabled={loading}
                        className="px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded font-medium disabled:opacity-50"
                      >
                        {loading ? 'Resetting...' : 'Confirm Reset (Final)'}
                      </button>
                      <button
                        onClick={handleCancelReset}
                        disabled={loading}
                        className="px-4 py-2 bg-gray-600 hover:bg-gray-700 text-white rounded font-medium disabled:opacity-50"
                      >
                        Cancel
                      </button>
                    </div>
                  </div>
                )}

                {/* Executing Reset */}
                {resetAction === 'executing' && (
                  <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                    <div className="flex items-center gap-3">
                      <svg className="animate-spin h-6 w-6 text-blue-600" viewBox="0 0 24 24">
                        <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" fill="none" />
                        <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                      </svg>
                      <span className="text-lg font-medium text-gray-900 dark:text-white">
                        Resetting election to SETUP...
                      </span>
                    </div>
                  </div>
                )}
              </div>
            )}

            {/* Election Dates Configuration */}
            {phaseInfo && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Election Dates</h2>
                <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                  Configure nomination and voting periods. Changes take effect immediately.
                </p>
                <form onSubmit={handleUpdateDates} className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Nomination Start
                    </label>
                    <input
                      type="datetime-local"
                      value={nominationStart}
                      onChange={e => setNominationStart(e.target.value)}
                      className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Nomination End
                    </label>
                    <input
                      type="datetime-local"
                      value={nominationEnd}
                      onChange={e => setNominationEnd(e.target.value)}
                      className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Voting Start
                    </label>
                    <input
                      type="datetime-local"
                      value={votingStart}
                      onChange={e => setVotingStart(e.target.value)}
                      className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Voting End
                    </label>
                    <input
                      type="datetime-local"
                      value={votingEnd}
                      onChange={e => setVotingEnd(e.target.value)}
                      className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    />
                  </div>
                  <div className="sm:col-span-2 flex gap-3">
                    <button
                      type="submit"
                      disabled={loading}
                      className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium disabled:opacity-50"
                    >
                      {loading ? 'Saving...' : 'Save Dates'}
                    </button>
                  </div>
                </form>
              </div>
            )}

            {/* Voting Link Validity Configuration */}
            {phaseInfo && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Voting Link Validity</h2>
                <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                  Applies to newly dispatched voting links only. Allowed range: 1 to 2160 hours (default 168 hours / 7 days).
                </p>
                <form onSubmit={handleSaveVotingTokenTtl} className="space-y-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Voting link validity (hours)
                    </label>
                    <input
                      type="number"
                      min="1"
                      max="2160"
                      step="1"
                      value={votingTokenTtlHours}
                      onChange={e => {
                        setVotingTokenTtlHours(e.target.value ? parseInt(e.target.value, 10) : '');
                        if (votingTokenTtlError) setVotingTokenTtlError(null);
                      }}
                      className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                      required
                    />
                    {votingTokenTtlError && (
                      <p className="mt-2 text-sm text-red-600 dark:text-red-400">{votingTokenTtlError}</p>
                    )}
                  </div>
                  <div className="flex gap-3">
                    <button
                      type="submit"
                      disabled={votingTokenTtlLoading}
                      className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium disabled:opacity-50"
                    >
                      {votingTokenTtlLoading ? 'Saving...' : 'Save'}
                    </button>
                  </div>
                </form>
              </div>
            )}

            {/* Nomination Settings */}
{phaseInfo && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Nomination Settings</h2>
                <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                  Controls the nomination form at /nominate/&lt;token&gt;.
                </p>
                <form onSubmit={handleSaveNominationSettings} className="space-y-4">
                  <div className="flex items-center">
                    <input
                      type="checkbox"
                      id="allowWriteIns"
                      checked={allowWriteIns}
                      onChange={e => setAllowWriteIns(e.target.checked)}
                      className="mr-2"
                    />
                    <label htmlFor="allowWriteIns" className="text-sm font-medium text-gray-700 dark:text-gray-300">
                      Allow write-in nominees (names not on the member roster)
                    </label>
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Max nominees per member
                    </label>
                    <select
                      value={maxNomineesPerMember}
                      onChange={e => setMaxNomineesPerMember(parseInt(e.target.value, 10))}
                      className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    >
                      <option value={1}>1</option>
                      <option value={2}>2</option>
                      <option value={3}>3</option>
                    </select>
                  </div>
                  <div className="flex gap-3">
                    <button
                      type="submit"
                      disabled={nominationSettingsLoading}
                      className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium disabled:opacity-50"
                    >
                      {nominationSettingsLoading ? 'Saving...' : 'Save'}
                    </button>
                  </div>
                </form>
              </div>
            )}

            {/* Age Requirement Settings */}
            {phaseInfo && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Voter Age Requirement</h2>
                <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                  When enabled, members must meet the minimum age as of the voting start date (or current date if not set) to be eligible.
                </p>
                <form onSubmit={handleSaveAgeRequirementSettings} className="space-y-4">
                  <div className="flex items-center">
                    <input
                      type="checkbox"
                      id="ageRequirementEnabled"
                      checked={ageRequirementEnabled}
                      onChange={e => setAgeRequirementEnabled(e.target.checked)}
                      className="mr-2"
                    />
                    <label htmlFor="ageRequirementEnabled" className="text-sm font-medium text-gray-700 dark:text-gray-300">
                      Enable age requirement for voting eligibility
                    </label>
                  </div>
                  {ageRequirementEnabled && (
                    <div>
                      <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                        Minimum voting age
                      </label>
                      <input
                        type="number"
                        min="1"
                        max="130"
                        step="1"
                        value={minimumVotingAge}
                        onChange={e => setMinimumVotingAge(e.target.value ? parseInt(e.target.value, 10) : '')}
                        className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                        required
                      />
                    </div>
                  )}
                  <div className="flex gap-3">
                    <button
                      type="submit"
                      disabled={ageRequirementEnabled && !minimumVotingAge}
                      className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium disabled:opacity-50"
                    >
                      Save
                    </button>
                  </div>
                </form>
              </div>
            )}

            {/* Member Roster Settings */}
            {phaseInfo && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Member Roster</h2>
                <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                  Controls whether new members can be added while voting is open. Newly added members are active and voting-eligible immediately.
                </p>
                <form onSubmit={handleSaveRosterSettings} className="space-y-4">
                  <div className="flex items-center">
                    <input
                      type="checkbox"
                      id="allowAddingMemberDuringVoting"
                      checked={allowAddingMemberDuringVoting}
                      onChange={e => setAllowAddingMemberDuringVoting(e.target.checked)}
                      disabled={!['SETUP', 'NOMINATION', 'NOMINATION_CLOSED', 'VOTING'].includes(phaseInfo.currentPhase)}
                      className="mr-2"
                    />
                    <label htmlFor="allowAddingMemberDuringVoting" className="text-sm font-medium text-gray-700 dark:text-gray-300">
                      Allow adding members during voting
                    </label>
                  </div>
                  <div className="flex items-start gap-2 p-3 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg">
                    <svg className="w-5 h-5 text-amber-600 dark:text-amber-400 shrink-0 mt-0.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
                    </svg>
                    <p className="text-sm text-amber-800 dark:text-amber-300">
                      Not recommended. Only enable this to accommodate members physically present during paper voting whose
                      roster entry was not completed beforehand — it weakens roster integrity during an active election.
                      {['VOTING_CLOSED', 'COMPLETED'].includes(phaseInfo.currentPhase) && ' This setting is locked once voting closes.'}
                    </p>
                  </div>
                  <div className="flex gap-3">
                    <button
                      type="submit"
                      disabled={!['SETUP', 'NOMINATION', 'NOMINATION_CLOSED', 'VOTING'].includes(phaseInfo.currentPhase)}
                      className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium disabled:opacity-50"
                    >
                      Save
                    </button>
                  </div>
                </form>
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
            {/* Member Data Completeness */}
            {memberStats && (
              <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                <h3 className="font-semibold text-gray-900 dark:text-white mb-3">Member Data Completeness</h3>
                <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 text-sm">
                  <div className="p-3 border rounded dark:border-gray-700">
                    <p className="text-gray-500">Total members</p>
                    <p className="text-lg font-bold text-gray-900 dark:text-white">{memberStats.total}</p>
                  </div>
                  <div className="p-3 border rounded dark:border-gray-700">
                    <p className="text-gray-500">With email</p>
                    <p className="text-lg font-bold text-gray-900 dark:text-white">{memberStats.withEmail}</p>
                  </div>
                  <div className="p-3 border rounded dark:border-gray-700">
                    <p className="text-gray-500">With phone</p>
                    <p className="text-lg font-bold text-gray-900 dark:text-white">{memberStats.withPhone}</p>
                  </div>
                  <div className="p-3 border rounded dark:border-gray-700">
                    <p className="text-gray-500">With both</p>
                    <p className="text-lg font-bold text-gray-900 dark:text-white">{memberStats.withBoth}</p>
                  </div>
                </div>
              </div>
            )}

            {/* Add Member */}
            <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Add Member</h2>

              {rosterAddLocked && (
                <div className="mb-4 p-3 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg text-yellow-800 dark:text-yellow-300 text-sm">
                  Roster locked — voting has started.
                </div>
              )}

              {addMemberError && (
                <div className="mb-4 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg text-red-800 dark:text-red-300 text-sm">
                  {addMemberError}
                </div>
              )}

              <form onSubmit={handleAddMember} className="space-y-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    Name <span className="text-red-500">*</span>
                  </label>
                  <input
                    type="text"
                    value={newMemberName}
                    onChange={e => setNewMemberName(e.target.value)}
                    placeholder="e.g. Jane Doe"
                    disabled={rosterAddLocked}
                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:opacity-50"
                    required
                  />
                </div>
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Email (optional)
                    </label>
                    <input
                      type="email"
                      value={newMemberEmail}
                      onChange={e => setNewMemberEmail(e.target.value)}
                      placeholder="jane@example.com"
                      disabled={rosterAddLocked}
                      className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:opacity-50"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Phone (optional)
                    </label>
                    <input
                      type="text"
                      value={newMemberPhone}
                      onChange={e => setNewMemberPhone(e.target.value)}
                      placeholder="+1234567890"
                      disabled={rosterAddLocked}
                      className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:opacity-50"
                    />
                  </div>
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    Member Code (optional)
                  </label>
                  <input
                    type="text"
                    value={newMemberCode}
                    onChange={e => setNewMemberCode(e.target.value)}
                    placeholder="e.g. M-001"
                    disabled={rosterAddLocked}
                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:opacity-50"
                  />
                </div>
                {ageRequirementEnabled && (
                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <div>
                      <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                        Date of Birth (optional)
                      </label>
                      <input
                        type="date"
                        value={newMemberDob}
                        onChange={e => {
                          setNewMemberDob(e.target.value);
                          if (e.target.value) setNewMemberAgeEligible(false);
                        }}
                        disabled={rosterAddLocked || newMemberAgeEligible}
                        className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:opacity-50"
                      />
                      <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
                        Used only to derive age eligibility — never stored.
                      </p>
                    </div>
                    <div>
                      <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                        Age eligible (optional)
                      </label>
                      <label className={`flex items-center gap-2 p-2 border rounded dark:bg-gray-700 dark:border-gray-600 ${rosterAddLocked || newMemberDob.trim() !== '' ? 'opacity-50 cursor-not-allowed' : 'cursor-pointer'}`}>
                        <input
                          type="checkbox"
                          checked={newMemberAgeEligible}
                          onChange={e => {
                            setNewMemberAgeEligible(e.target.checked);
                            if (e.target.checked) setNewMemberDob('');
                          }}
                          disabled={rosterAddLocked || newMemberDob.trim() !== ''}
                          className="w-4 h-4"
                        />
                        <span className="text-sm text-gray-700 dark:text-gray-300">
                          Assert age eligibility without providing a DOB
                        </span>
                      </label>
                      <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
                        Mutually exclusive with Date of Birth.
                      </p>
                    </div>
                  </div>
                )}
                <button
                  type="submit"
                  disabled={addMemberLoading || rosterAddLocked}
                  className="px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white rounded font-medium disabled:opacity-50"
                >
                  {addMemberLoading ? 'Adding...' : 'Add Member'}
                </button>
              </form>
            </div>

            {/* CSV Import */}
            <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
<h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Bulk Import Members (CSV)</h2>
              <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                Upload a .csv file or paste CSV content below. Required columns: <code>full_name</code> (or <code>name</code>).
                Optional: <code>email</code>, <code>phone</code>, <code>member_code</code>, <code>dob</code> (or <code>date_of_birth</code>; ISO 8601 YYYY-MM-DD — used only to derive age eligibility, never stored).
              </p>
              <form onSubmit={handleImportMembers} className="space-y-4">
                <div>
                  <label
                    htmlFor="csv-file-upload"
                    className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
                  >
                    CSV File
                  </label>
                  <div
                    onDrop={handleCsvDrop}
                    onDragOver={handleCsvDragOver}
                    onDragLeave={handleCsvDragLeave}
                    onClick={() => csvFileInputRef.current?.click()}
                    onKeyDown={e => {
                      if (e.key === 'Enter' || e.key === ' ') {
                        e.preventDefault();
                        csvFileInputRef.current?.click();
                      }
                    }}
                    role="button"
                    tabIndex={0}
                    className={`flex flex-col items-center justify-center gap-2 w-full px-6 py-8 border-2 border-dashed rounded-lg cursor-pointer transition-colors ${
                      csvDragActive
                        ? 'border-indigo-500 bg-indigo-50 dark:bg-indigo-950/40'
                        : 'border-gray-300 dark:border-gray-600 hover:border-indigo-400 dark:hover:border-indigo-500 bg-gray-50 dark:bg-gray-700/50'
                    }`}
                  >
                    <svg
                      className={`w-8 h-8 ${csvDragActive ? 'text-indigo-500' : 'text-gray-400 dark:text-gray-500'}`}
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12" />
                    </svg>
                    <p className="text-sm text-gray-600 dark:text-gray-300 text-center">
                      <span className="font-medium text-indigo-600 dark:text-indigo-400">Click to browse</span> or drag and drop a .csv file
                    </p>
                    <p className="text-xs text-gray-400 dark:text-gray-500">Max file size 1 MB</p>
                    <input
                      id="csv-file-upload"
                      ref={csvFileInputRef}
                      type="file"
                      accept=".csv,text/csv,text/plain"
                      onChange={handleCsvFileInputChange}
                      className="sr-only"
                    />
                  </div>
                  {csvFileName && (
                    <p className="mt-2 text-sm text-gray-600 dark:text-gray-400">
                      <span className="font-medium text-gray-900 dark:text-white">{csvFileName}</span>
                      {csvFileLineCount !== null && <> &mdash; {csvFileLineCount} line{csvFileLineCount === 1 ? '' : 's'}</>}
                    </p>
                  )}
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    CSV Content
                 </label>
                  <textarea
                    value={csvContent}
                    onChange={e => setCsvContent(e.target.value)}
                    placeholder="full_name,email,phone,member_code,dob
John Doe,john@example.com,+1234567890,M-001,1990-05-15
Jane Smith,jane@example.com,+0987654321,1985-03-22"
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
                          disabled={loading || rosterToggleLocked}
                          title={rosterToggleLocked ? 'Roster locked — voting has started' : undefined}
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
                      {membersWithEmail.length > 0 && membersWithEmail.every(member => dispatchMemberIds.includes(member.id)) ? 'Deselect All' : 'Select All'}
                    </button>
                    <span className="text-xs text-gray-500 dark:text-gray-400 self-center">
                      {membersWithEmail.length} selectable / {membersWithoutEmailCount} without email
                    </span>
                  </div>
                  <div className="max-h-64 overflow-y-auto border rounded dark:bg-gray-700 dark:border-gray-600 p-2">
                    {allMembers.length === 0 ? (
                      <p className="text-sm text-gray-500 dark:text-gray-400">No members available. Import members first.</p>
                    ) : (
                      <ul className="space-y-1">
                        {allMembers.map(member => (
                          <li
                            key={member.id}
                            className={`flex items-center gap-2 ${!member.email?.trim() ? 'opacity-60' : ''}`}
                          >
                            <input
                              type="checkbox"
                              checked={dispatchMemberIds.includes(member.id)}
                              onChange={() => handleToggleDispatchMember(member.id)}
                              disabled={!member.email?.trim()}
                              className="rounded"
                            />
                            <span className="text-sm text-gray-900 dark:text-white">{member.full_name}</span>
                            <span className="text-xs text-gray-500">({member.member_code})</span>
                            {member.email && <span className="text-xs text-gray-500">{member.email}</span>}
                            {!member.email?.trim() && (
                              <span className="px-1.5 py-0.5 text-xs bg-gray-200 text-gray-700 dark:bg-gray-700 dark:text-gray-300 rounded">
                                NO EMAIL
                              </span>
                            )}
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

        {/* Tab 8: Nominations (out-of-band add + adjudication) */}
        {activeTab === 'nominations' && (
          <div className="space-y-6 print:hidden">
            {phaseInfo?.currentPhase === 'NOMINATION' && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Add Nomination (Out-of-Band)</h2>
                <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                  Use this for a nomination collected outside the digital flow (e.g. by phone or paper). No nominator identity is recorded.
                </p>
                <form onSubmit={handleAddNomination} className="space-y-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Search roster
                    </label>
                    <input
                      type="text"
                      value={nomAddQuery}
                      onChange={e => {
                        setNomAddQuery(e.target.value);
                        setNomAddSelectedMember(null);
                        void searchNomAddMembers(e.target.value);
                      }}
                      placeholder="Type a member name..."
                      className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    />
                    {nomAddSearching && <p className="text-xs text-gray-400 mt-1">Searching...</p>}
                    {nomAddSelectedMember ? (
                      <p className="mt-2 text-sm text-gray-900 dark:text-white">
                        Selected: <span className="font-medium">{nomAddSelectedMember.full_name}</span>{' '}
                        <button type="button" onClick={() => setNomAddSelectedMember(null)} className="text-xs text-red-600 hover:text-red-700 ml-2">
                          Clear
                        </button>
                      </p>
                    ) : (
                      nomAddMatches.length > 0 && (
                        <div className="mt-2 border rounded divide-y dark:divide-gray-700 dark:border-gray-600">
                          {nomAddMatches.map(m => (
                            <button
                              key={m.id}
                              type="button"
                              onClick={() => { setNomAddSelectedMember(m); setNomAddMatches([]); setNomAddQuery(m.full_name); }}
                              className="w-full text-left px-3 py-2 text-sm hover:bg-gray-50 dark:hover:bg-gray-700 dark:text-white"
                            >
                              {m.full_name} <span className="text-xs text-gray-500">({m.member_code})</span>
                            </button>
                          ))}
                        </div>
                      )
                    )}
                  </div>

                  {allowWriteIns && !nomAddSelectedMember && (
                    <div>
                      <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                        Or write-in name (not on roster)
                      </label>
                      <input
                        type="text"
                        value={nomAddWriteInName}
                        onChange={e => setNomAddWriteInName(e.target.value.slice(0, 100))}
                        placeholder="Full name"
                        className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                      />
                    </div>
                  )}

                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Reason (optional)
                    </label>
                    <textarea
                      value={nomAddReason}
                      onChange={e => setNomAddReason(e.target.value.slice(0, 2000))}
                      rows={2}
                      className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    />
                  </div>

                  <button
                    type="submit"
                    disabled={nomAddLoading}
                    className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium disabled:opacity-50"
                  >
                    {nomAddLoading ? 'Adding...' : 'Add Nomination'}
                  </button>
                </form>
              </div>
            )}

            {phaseInfo?.currentPhase === 'NOMINATION_CLOSED' && (
              <div className="space-y-6">
                <div className="flex items-center justify-between">
                  <h2 className="text-lg font-semibold text-gray-900 dark:text-white">Adjudicate Nominations</h2>
                  <button
                    onClick={fetchNominations}
                    disabled={nominationsLoading}
                    className="px-3 py-1.5 text-xs bg-gray-600 hover:bg-gray-700 text-white rounded font-medium disabled:opacity-50"
                  >
                    {nominationsLoading ? 'Refreshing...' : 'Refresh'}
                  </button>
                </div>

                {/* Matched groups */}
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow overflow-hidden">
                  <div className="p-4 border-b border-gray-200 dark:border-gray-700">
                    <h3 className="font-semibold text-gray-900 dark:text-white">
                      Matched nominees ({nominations?.matched.length ?? 0})
                    </h3>
                  </div>
                  {!nominations || nominations.matched.length === 0 ? (
                    <div className="p-6 text-center text-gray-500 text-sm">No matched nominees.</div>
                  ) : (
                    <div className="divide-y divide-gray-200 dark:divide-gray-700">
                      {nominations.matched.map(group => {
                        const key = group.affectedNominationIds.join(',') + 'PROMOTE';
                        return (
                          <div key={group.nomineeMemberId} className="p-4 flex items-center justify-between gap-4">
                            <div>
                              <p className="font-medium text-gray-900 dark:text-white">{group.fullName}</p>
                              <p className="text-xs text-gray-500">{group.nominationCount} nomination{group.nominationCount === 1 ? '' : 's'}</p>
                            </div>
                            {group.alreadyPromoted ? (
                              <span className="px-2.5 py-1 text-xs font-semibold rounded-full bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400">
                                Already promoted
                              </span>
                            ) : (
                              <button
                                onClick={() => handleAdjudicate({
                                  decision: 'PROMOTE',
                                  nomineeMemberId: group.nomineeMemberId,
                                  affectedNominationIds: group.affectedNominationIds,
                                })}
                                disabled={adjudicating === key}
                                className="px-3 py-1.5 text-xs bg-green-600 hover:bg-green-700 text-white font-medium rounded disabled:opacity-50"
                              >
                                {adjudicating === key ? 'Promoting...' : 'Promote to candidate'}
                              </button>
                            )}
                          </div>
                        );
                      })}
                    </div>
                  )}
                </div>

                {/* Unmatched write-ins */}
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow overflow-hidden">
                  <div className="p-4 border-b border-gray-200 dark:border-gray-700">
                    <h3 className="font-semibold text-gray-900 dark:text-white">
                      Unmatched write-ins ({nominations?.unmatched.length ?? 0})
                    </h3>
                  </div>
                  {!nominations || nominations.unmatched.length === 0 ? (
                    <div className="p-6 text-center text-gray-500 text-sm">No unmatched write-ins.</div>
                  ) : (
                    <div className="divide-y divide-gray-200 dark:divide-gray-700">
                      {nominations.unmatched.map(item => {
                        const promoteKey = [item.id].join(',') + 'PROMOTE';
                        const mergeKey = [item.id].join(',') + 'MERGE';
                        const discardKey = [item.id].join(',') + 'DISCARD';
                        return (
                          <div key={item.id} className="p-4 space-y-3">
                            <div>
                              <p className="font-medium text-gray-900 dark:text-white">{item.nomineeName}</p>
                              {item.reason && <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">{item.reason}</p>}
                              {item.suggestions.length > 0 && (
                                <p className="text-xs text-gray-500 mt-1">
                                  Similar roster names: {item.suggestions.map(s => s.fullName).join(', ')}
                                </p>
                              )}
                            </div>
                            <div className="flex flex-wrap items-center gap-2">
                              <button
                                onClick={() => handleAdjudicate({
                                  decision: 'PROMOTE',
                                  nomineeName: item.nomineeName,
                                  affectedNominationIds: [item.id],
                                })}
                                disabled={adjudicating === promoteKey}
                                className="px-3 py-1.5 text-xs bg-green-600 hover:bg-green-700 text-white font-medium rounded disabled:opacity-50"
                              >
                                {adjudicating === promoteKey ? 'Adding...' : 'Add as candidate'}
                              </button>

                              <select
                                value={mergeCandidateChoice[item.id] || ''}
                                onChange={e => setMergeCandidateChoice(prev => ({ ...prev, [item.id]: e.target.value }))}
                                className="p-1.5 text-xs border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                              >
                                <option value="">Merge into existing candidate...</option>
                                {candidates.map(c => (
                                  <option key={c.id} value={c.id}>{c.full_name}</option>
                                ))}
                              </select>
                              <button
                                onClick={() => {
                                  const candidateId = mergeCandidateChoice[item.id];
                                  if (!candidateId) return;
                                  handleAdjudicate({ decision: 'MERGE', candidateId, affectedNominationIds: [item.id] });
                                }}
                                disabled={!mergeCandidateChoice[item.id] || adjudicating === mergeKey}
                                className="px-3 py-1.5 text-xs bg-indigo-600 hover:bg-indigo-700 text-white font-medium rounded disabled:opacity-50"
                              >
                                {adjudicating === mergeKey ? 'Merging...' : 'Merge'}
                              </button>

                              <button
                                onClick={() => handleAdjudicate({ decision: 'DISCARD', affectedNominationIds: [item.id] })}
                                disabled={adjudicating === discardKey}
                                className="px-3 py-1.5 text-xs bg-red-600 hover:bg-red-700 text-white font-medium rounded disabled:opacity-50"
                              >
                                {adjudicating === discardKey ? 'Discarding...' : 'Discard'}
                              </button>
                            </div>
                          </div>
                        );
                      })}
                    </div>
                  )}
                </div>
              </div>
            )}

            {phaseInfo && phaseInfo.currentPhase !== 'NOMINATION' && phaseInfo.currentPhase !== 'NOMINATION_CLOSED' && (
              <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow text-sm text-gray-600 dark:text-gray-400">
                Nomination management is available during the NOMINATION phase (add nominations) and NOMINATION_CLOSED phase (adjudicate).
                Current phase: <strong>{phaseInfo.currentPhase}</strong>.
              </div>
            )}
          </div>
        )}

        {/* Tab: Voter Eligibility (Wave 5) */}
        {activeTab === 'eligibility' && (
          <div className="space-y-6 print:hidden">
            {/* Phase notice */}
            {phaseInfo?.currentPhase && phaseInfo.currentPhase !== 'SETUP' && (
              <div className="p-4 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg">
                <div className="flex items-center gap-2">
                  <svg className="w-5 h-5 text-yellow-600 dark:text-yellow-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L4.082 16.5c-.77.833.192 2.5 1.732 2.5z" />
                  </svg>
                  <div>
                    <p className="text-sm font-medium text-yellow-800 dark:text-yellow-200">
                      Eligibility is read-only during {phaseInfo.currentPhase} phase
                    </p>
                    <p className="text-xs text-yellow-600 dark:text-yellow-400">
                      Eligibility can only be changed during SETUP phase.
                    </p>
                  </div>
                </div>
              </div>
            )}

            <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Search Member</h2>
              <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                {phaseInfo?.currentPhase === 'SETUP'
                  ? 'Search the roster to review or override a member\'s voting eligibility.'
                  : 'Search the roster to view a member\'s voting eligibility (read-only).'}
              </p>
              <form onSubmit={searchEligibilityMembers} className="flex gap-2">
                <input
                  type="text"
                  value={eligibilityQuery}
                  onChange={e => {
                    setEligibilityQuery(e.target.value);
                    debouncedSearchEligibility(e.target.value);
                  }}
                  placeholder="Enter member name (e.g. Voter 001)..."
                  className="flex-1 p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                />
                <button
                  type="submit"
                  disabled={eligibilitySearching}
                  className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium disabled:opacity-50"
                >
                  {eligibilitySearching ? 'Searching...' : 'Search'}
                </button>
              </form>
            </div>

            {eligibilityResults.length > 0 && (
              <div className="bg-white dark:bg-gray-800 rounded-lg shadow overflow-hidden">
                <div className="p-4 border-b border-gray-200 dark:border-gray-700">
                  <h3 className="font-semibold text-gray-900 dark:text-white">Search Results ({eligibilityResults.length})</h3>
                </div>
                <div className="divide-y divide-gray-200 dark:divide-gray-700">
                  {eligibilityResults.map(member => {
                    const eligible = member.voting_eligible ?? true;
                    const draft = eligibilityDrafts[member.id] ?? draftFromMember(member);
                    const saving = eligibilitySavingId === member.id;
                    const unchanged =
                      draft.votingEligible === eligible &&
                      (draft.votingEligible || draft.reason === member.eligibility_reason);
                    return (
                      <div key={member.id} className="p-4 space-y-3">
                        <div className="flex items-start justify-between gap-4 flex-wrap">
                          <div>
                            <p className="font-medium text-gray-900 dark:text-white">{member.full_name}</p>
                            <p className="text-xs text-gray-500">Code: {member.member_code} | Email: {member.email || 'N/A'}</p>
                          </div>
                          <div className="text-right">
                            <span
                              className={`px-2.5 py-1 text-xs font-semibold rounded-full ${
                                eligible
                                  ? 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400'
                                  : 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-400'
                              }`}
                            >
                              {eligible ? 'ELIGIBLE' : 'INELIGIBLE'}
                            </span>
                            <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
                              Reason: <span className="font-medium">{member.eligibility_reason || 'ELIGIBLE'}</span>
                            </p>
                            {member.eligibility_source && (
                              <p className="text-[11px] text-gray-400 dark:text-gray-500">
                                Source: {member.eligibility_source}
                              </p>
                            )}
                          </div>
                        </div>

                        <div className="bg-gray-50 dark:bg-gray-700/50 rounded p-3 space-y-3">
                          <div className="flex items-center gap-2">
                            <span className="text-xs font-medium text-gray-500 dark:text-gray-400">Set to:</span>
                            <div className="inline-flex rounded-md border border-gray-300 dark:border-gray-600 overflow-hidden">
                              <button
                                type="button"
                                onClick={() => updateEligibilityDraft(member.id, { votingEligible: true })}
                                aria-pressed={draft.votingEligible}
                                disabled={phaseInfo?.currentPhase !== 'SETUP'}
                                className={`px-3 py-1 text-xs font-medium ${
                                  draft.votingEligible
                                    ? 'bg-green-600 text-white'
                                    : 'bg-white dark:bg-gray-700 text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-600'
                                } ${phaseInfo?.currentPhase !== 'SETUP' ? 'opacity-50 cursor-not-allowed' : ''}`}
                              >
                                Eligible
                              </button>
                              <button
                                type="button"
                                onClick={() => updateEligibilityDraft(member.id, { votingEligible: false })}
                                aria-pressed={!draft.votingEligible}
                                disabled={phaseInfo?.currentPhase !== 'SETUP'}
                                className={`px-3 py-1 text-xs font-medium border-l border-gray-300 dark:border-gray-600 ${
                                  !draft.votingEligible
                                    ? 'bg-red-600 text-white'
                                    : 'bg-white dark:bg-gray-700 text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-600'
                                } ${phaseInfo?.currentPhase !== 'SETUP' ? 'opacity-50 cursor-not-allowed' : ''}`}
                              >
                                Ineligible
                              </button>
                            </div>
                          </div>

                          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                            <div>
                              <label className="block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1">
                                Reason
                              </label>
                              {draft.votingEligible ? (
                                <input
                                  type="text"
                                  value="ELIGIBLE"
                                  disabled
                                  className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white text-gray-500 dark:text-gray-400"
                                />
                              ) : (
                                <select
                                  value={draft.reason}
                                  onChange={e =>
                                    updateEligibilityDraft(member.id, { reason: e.target.value as ManualIneligibleReason })
                                  }
                                  disabled={phaseInfo?.currentPhase !== 'SETUP'}
                                  className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:opacity-50"
                                >
                                  {MANUAL_INELIGIBLE_REASONS.map(r => (
                                    <option key={r} value={r}>{r}</option>
                                  ))}
                                </select>
                              )}
                            </div>
                            <div>
                              <label className="block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1">
                                Note (optional)
                              </label>
                              <input
                                type="text"
                                value={draft.note}
                                onChange={e => updateEligibilityDraft(member.id, { note: e.target.value })}
                                placeholder="Why this change is being made..."
                                disabled={phaseInfo?.currentPhase !== 'SETUP'}
                                className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:opacity-50"
                              />
                            </div>
                          </div>

                          <button
                            type="button"
                            onClick={() => handleSaveEligibility(member)}
                            disabled={saving || unchanged || phaseInfo?.currentPhase !== 'SETUP'}
                            className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium text-sm disabled:opacity-50"
                          >
                            {saving ? 'Saving...' : 'Save eligibility'}
                          </button>
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>
            )}

            {/* Danger Zone: GDPR roster purge (matches the Reset Election danger-zone styling above) */}
            <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow border border-red-200 dark:border-red-900/50">
              <div className="flex items-center gap-3 mb-4">
                <svg className="w-8 h-8 text-red-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
                </svg>
                <h2 className="text-lg font-semibold text-gray-900 dark:text-white">Purge Roster PII</h2>
              </div>
              <p className="text-sm text-gray-600 dark:text-gray-400 mb-6">
                Two irreversible cleanup stages for GDPR data-minimization. Each requires typing <strong>PURGE</strong> to confirm.
                Current phase: <strong>{phaseInfo?.currentPhase ?? 'Unknown'}</strong>.
              </p>

              {purgeResult && (
                <div className="mb-4 p-3 bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-lg text-green-800 dark:text-green-300 text-sm">
                  Stage {purgeResult.stage} complete — {purgeResult.members_touched} member(s) affected. {purgeResult.message}
                </div>
              )}

              <div className="space-y-4">
                <div className="border border-gray-200 dark:border-gray-700 rounded-lg p-4">
                  <h3 className="font-medium text-gray-900 dark:text-white mb-1">Stage 1 — Purge contact PII</h3>
                  <p className="text-sm text-gray-600 dark:text-gray-400 mb-3">
                    Clears member emails and phone numbers. Only allowed once voting has closed (VOTING_CLOSED or COMPLETED phase).
                  </p>
                  {purgeStage !== 'CONTACT' ? (
                    <button
                      type="button"
                      onClick={() => openPurgeConfirm('CONTACT')}
                      className="px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded font-medium text-sm"
                    >
                      Purge contact PII
                    </button>
                  ) : (
                    <div className="space-y-3">
                      <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
                        Type PURGE to confirm <span className="text-red-500">*</span>
                      </label>
                      <input
                        type="text"
                        value={purgeConfirmText}
                        onChange={e => setPurgeConfirmText(e.target.value)}
                        placeholder="PURGE"
                        className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white font-mono"
                      />
                      <div className="flex gap-3">
                        <button
                          type="button"
                          onClick={handleConfirmPurge}
                          disabled={purgeLoading || purgeConfirmText !== 'PURGE'}
                          className="px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded font-medium disabled:opacity-50"
                        >
                          {purgeLoading ? 'Purging...' : 'Confirm: Purge contact PII'}
                        </button>
                        <button
                          type="button"
                          onClick={cancelPurgeConfirm}
                          disabled={purgeLoading}
                          className="px-4 py-2 bg-gray-600 hover:bg-gray-700 text-white rounded font-medium disabled:opacity-50"
                        >
                          Cancel
                        </button>
                      </div>
                    </div>
                  )}
                </div>

                <div className="border border-gray-200 dark:border-gray-700 rounded-lg p-4">
                  <h3 className="font-medium text-gray-900 dark:text-white mb-1">Stage 2 — Anonymize identity</h3>
                  <p className="text-sm text-gray-600 dark:text-gray-400 mb-3">
                    Redacts member names and member codes. Only allowed 30 days after voting ends (the dispute window).
                    This cannot be reversed.
                  </p>
                  {purgeStage !== 'IDENTITY' ? (
                    <button
                      type="button"
                      onClick={() => openPurgeConfirm('IDENTITY')}
                      className="px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded font-medium text-sm"
                    >
                      Anonymize identity
                    </button>
                  ) : (
                    <div className="space-y-3">
                      <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
                        Type PURGE to confirm <span className="text-red-500">*</span>
                      </label>
                      <input
                        type="text"
                        value={purgeConfirmText}
                        onChange={e => setPurgeConfirmText(e.target.value)}
                        placeholder="PURGE"
                        className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white font-mono"
                      />
                      <div className="flex gap-3">
                        <button
                          type="button"
                          onClick={handleConfirmPurge}
                          disabled={purgeLoading || purgeConfirmText !== 'PURGE'}
                          className="px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded font-medium disabled:opacity-50"
                        >
                          {purgeLoading ? 'Purging...' : 'Confirm: Anonymize identity'}
                        </button>
                        <button
                          type="button"
                          onClick={cancelPurgeConfirm}
                          disabled={purgeLoading}
                          className="px-4 py-2 bg-gray-600 hover:bg-gray-700 text-white rounded font-medium disabled:opacity-50"
                        >
                          Cancel
                        </button>
                      </div>
                    </div>
                  )}
                </div>
              </div>
            </div>
          </div>
        )}
        {/* Tab: Reporting (election progress, on-demand) */}
        {activeTab === 'reporting' && (
          <div className="space-y-6 print:hidden">
            <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Election Progress Report</h2>
              <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                Aggregate turnout and tally snapshot. Available during VOTING, VOTING_CLOSED, and COMPLETED phases.
                All counts are anonymous aggregates — no member identity is exposed.
              </p>
              <div className="flex gap-3 flex-wrap">
                <button
                  onClick={handleGenerateReport}
                  disabled={reportLoading}
                  className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium disabled:opacity-50"
                >
                  {reportLoading ? 'Generating...' : reportData ? 'Refresh Report' : 'Generate Report'}
                </button>
                <button
                  onClick={handleExportProgressCsv}
                  disabled={!reportData?.available}
                  className="px-4 py-2 bg-gray-600 hover:bg-gray-700 text-white rounded font-medium disabled:opacity-50"
                >
                  Export Progress CSV
                </button>
                <button
                  onClick={handleExportResultsCsv}
                  disabled={!reportData?.available || !['VOTING_CLOSED', 'COMPLETED'].includes(reportData?.phase || '')}
                  title={!['VOTING_CLOSED', 'COMPLETED'].includes(reportData?.phase || '') ? 'Results export unlocks once voting has closed' : undefined}
                  className="px-4 py-2 bg-gray-600 hover:bg-gray-700 text-white rounded font-medium disabled:opacity-50"
                >
                  Export Results CSV
                </button>
              </div>
            </div>

            {reportData && !reportData.available && (
              <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6">
                <p className="text-gray-600 dark:text-gray-400">
                  Reporting is not available in the {reportData.phase} phase. It becomes available once voting starts.
                </p>
              </div>
            )}

            {reportData?.available && (
              <>
                <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
                  <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                    <p className="text-sm text-gray-500">Members checked in (paper)</p>
                    <p className="text-2xl font-bold text-gray-900 dark:text-white">{reportData.checkedInCount}</p>
                  </div>
                  <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                    <p className="text-sm text-gray-500">Paper ballots recorded</p>
                    <p className="text-2xl font-bold text-gray-900 dark:text-white">{reportData.paperRecordedCount}</p>
                  </div>
                  <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                    <p className="text-sm text-gray-500">Digital votes</p>
                    <p className="text-2xl font-bold text-gray-900 dark:text-white">{reportData.digitalVoteCount}</p>
                  </div>
                  <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                    <p className="text-sm text-gray-500">Total votes</p>
                    <p className="text-2xl font-bold text-gray-900 dark:text-white">{reportData.totalVoteCount}</p>
                  </div>
                </div>

                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6">
                  <h3 className="font-semibold text-gray-900 dark:text-white mb-4">Tally by candidate</h3>
                  <div className="space-y-3">
                    {reportData.results?.map(c => (
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
              </>
            )}
          </div>
        )}

      </div>

      {/* Mobile QR Code Modal */}
      {showMobileQR && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50" onClick={() => setShowMobileQR(false)}>
          <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl p-6 max-w-sm w-full mx-4" onClick={e => e.stopPropagation()}>
            <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-4 text-center">Mobile Wizard QR Code</h3>
            <div className="flex justify-center mb-4">
              <MobileQRCode />
            </div>
            <p className="text-sm text-gray-500 text-center mb-4">Scan with your phone to open the Mobile Wizard</p>
            <button
              onClick={() => setShowMobileQR(false)}
              className="w-full py-2 px-4 bg-gray-200 dark:bg-gray-700 hover:bg-gray-300 dark:hover:bg-gray-600 text-gray-800 dark:text-white rounded font-medium"
            >
              Close
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

function MobileQRCode() {
  const [qrDataUrl, setQrDataUrl] = useState<string>('');

  useEffect(() => {
    import('qrcode').then((QRCode) => {
      const url = typeof window !== 'undefined'
        ? `${window.location.origin}/admin/mobile`
        : '/admin/mobile';
      QRCode.toDataURL(url, { width: 256, margin: 2 }, (err, dataUrl) => {
        if (!err && dataUrl) setQrDataUrl(dataUrl);
      });
    });
  }, []);

  if (!qrDataUrl) {
    return <div className="w-64 h-64 bg-gray-100 dark:bg-gray-700 rounded-lg animate-pulse" />;
  }

  return <img src={qrDataUrl} alt="Mobile Wizard QR Code" className="w-64 h-64" />;
}
