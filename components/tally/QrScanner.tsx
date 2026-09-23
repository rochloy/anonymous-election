'use client';

import { useEffect, useRef, useState } from 'react';

interface QrScannerProps {
  onScan: (decodedText: string) => void;
  onCancel: () => void;
}

/**
 * Full-viewport QR scanner for the mobile wizard.
 *
 * Uses Html5QrcodeScanner + render() — the same integration as the working
 * desktop Ballot Lookup path — rather than raw Html5Qrcode + start().
 * Raw Html5Qrcode.stop() throws synchronously when the scanner is not
 * scanning, so the previous stop-in-success-callback + stop-in-cleanup
 * pattern crashed the page on every successful scan (double-stop race →
 * Next.js client-side exception → "This page couldn't load").
 * Html5QrcodeScanner.clear() checks isScanning before stopping, which makes
 * the lifecycle safe. Its built-in chrome also provides a file-scan fallback
 * (scan a QR from a photo) when the live camera feed struggles.
 */
export default function QrScanner({ onScan, onCancel }: QrScannerProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const scannerRef = useRef<any>(null);
  // Refs hold the latest callbacks so the scanner effect deps stay stable.
  const onScanRef = useRef(onScan);
  const onCancelRef = useRef(onCancel);
  const [loadError, setLoadError] = useState<string | null>(null);

  useEffect(() => {
    onScanRef.current = onScan;
    onCancelRef.current = onCancel;
  }, [onScan, onCancel]);

  useEffect(() => {
    let cancelled = false;

    import('html5-qrcode').then(({ Html5QrcodeScanner }) => {
      if (cancelled || !containerRef.current) return;

      const scanner = new Html5QrcodeScanner(
        'tally-qr-reader',
        // Same config as the working desktop Ballot Lookup scanner.
        { fps: 10, qrbox: { width: 250, height: 250 } },
        /* verbose= */ false
      );
      scannerRef.current = scanner;

      scanner.render(
        (decodedText: string) => {
          if (cancelled) return;
          const ballotId = extractBallotId(decodedText);
          // Mirrors the desktop path: hand the ID to the parent (schedules
          // unmount), then clear() — which checks isScanning before stop().
          onScanRef.current(ballotId);
          if (scannerRef.current) {
            scannerRef.current.clear().catch(() => {});
          }
        },
        () => {}
      );
    }).catch((err: unknown) => {
      if (cancelled) return;
      console.error('[QrScanner] html5-qrcode load failed:', err);
      setLoadError('Could not load the QR scanner. Check your connection and retry.');
    });

    return () => {
      cancelled = true;
      const active = scannerRef.current;
      scannerRef.current = null;
      if (active) {
        // clear() checks isScanning before stop() — never double-stops.
        active.clear().catch(() => {});
      }
    };
  }, []);

  return (
    <div className="fixed inset-0 z-50 bg-black overflow-auto">
      <div id="tally-qr-reader" ref={containerRef} className="w-full min-h-full" />
      <button
        onClick={() => onCancelRef.current()}
        className="sticky top-4 left-1/2 -translate-x-1/2 bg-white/90 text-gray-900 font-semibold px-6 py-2 rounded-full shadow-lg"
      >
        Cancel
      </button>
      {loadError && (
        <div className="fixed inset-0 flex items-center justify-center p-6 bg-black/80">
          <div className="w-full max-w-sm bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl p-5 space-y-4 text-center">
            <p className="text-sm text-red-600 dark:text-red-400">{loadError}</p>
            <button
              onClick={() => onCancelRef.current()}
              className="border border-gray-300 dark:border-gray-600 text-gray-600 dark:text-gray-300 font-medium rounded-lg px-5 py-2.5 text-sm"
            >
              Close
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

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
