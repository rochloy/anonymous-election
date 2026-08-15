'use client';

import { useEffect, useState, Suspense } from 'react';
import { useSearchParams, useRouter } from 'next/navigation';

function PhaseConfirmContent() {
  const searchParams = useSearchParams();
  const router = useRouter();
  const [status, setStatus] = useState<'loading' | 'success' | 'error'>('loading');
  const [message, setMessage] = useState('');

  useEffect(() => {
    const token = searchParams.get('token');
    const phase = searchParams.get('phase');

    if (!token || !phase) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setStatus('error');
      setMessage('Invalid confirmation link: missing token or phase');
      return;
    }

    const confirmPhase = async () => {
      try {
        const res = await fetch('/api/admin/phase', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ action: 'confirm', token, phase }),
        });
        const data = await res.json();
        if (!res.ok) {
          setStatus('error');
          setMessage(data.error || 'Confirmation failed');
        } else {
          setStatus('success');
          setMessage(data.message || `Phase changed to ${data.newPhase}`);
          // Redirect back to dashboard after 3 seconds
          setTimeout(() => router.push('/admin/dashboard'), 3000);
        }
      } catch {
        setStatus('error');
        setMessage('Network error during confirmation');
      }
    };

    confirmPhase();
  }, [searchParams, router]);

  return (
    <div className="min-h-screen bg-gray-50 dark:bg-gray-900 py-12 px-4 flex items-center justify-center">
      <div className="max-w-md w-full bg-white dark:bg-gray-800 rounded-lg shadow-md p-8 text-center">
        {status === 'loading' && (
          <>
            <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-600 mx-auto mb-4"></div>
            <p className="text-gray-600 dark:text-gray-400">Verifying confirmation link...</p>
          </>
        )}
        {status === 'success' && (
          <>
            <svg className="w-16 h-16 text-green-600 mx-auto mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M5 13l4 4L19 7" />
            </svg>
            <h1 className="text-2xl font-bold text-gray-900 dark:text-white mb-2">Confirmed!</h1>
            <p className="text-gray-600 dark:text-gray-400 mb-4">{message}</p>
            <p className="text-sm text-gray-500">Redirecting to dashboard...</p>
          </>
        )}
        {status === 'error' && (
          <>
            <svg className="w-16 h-16 text-red-600 mx-auto mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M6 18L18 6M6 6l12 12" />
            </svg>
            <h1 className="text-2xl font-bold text-gray-900 dark:text-white mb-2">Confirmation Failed</h1>
            <p className="text-gray-600 dark:text-gray-400 mb-4">{message}</p>
            <a
              href="/admin/dashboard"
              className="inline-block px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded font-medium"
            >
              Return to Dashboard
            </a>
          </>
        )}
      </div>
    </div>
  );
}

export default function PhaseConfirmPage() {
  return (
    <Suspense fallback={<div className="min-h-screen flex items-center justify-center"><div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-600"></div></div>}>
      <PhaseConfirmContent />
    </Suspense>
  );
}