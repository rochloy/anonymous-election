'use client';

import { useEffect, useRef } from 'react';

interface QrScannerProps {
  onScan: (decodedText: string) => void;
  onCancel: () => void;
}

export default function QrScanner({ onScan, onCancel }: QrScannerProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const scannerRef = useRef<any>(null);

  useEffect(() => {
    let cancelled = false;

    import('html5-qrcode').then(({ Html5Qrcode }) => {
      if (cancelled || !containerRef.current) return;

      const scanner = new Html5Qrcode('tally-qr-reader');
      scannerRef.current = scanner;

      scanner.start(
        { facingMode: 'environment' },
        {
          fps: 10,
          qrbox: { width: 250, height: 250 },
          aspectRatio: 1.0,
        },
        (decodedText: string) => {
          if (cancelled) return;
          const ballotId = extractBallotId(decodedText);
          scanner.stop().then(() => scanner.clear()).catch(() => {});
          onScan(ballotId);
        },
        () => {}
      ).catch((err: unknown) => {
        console.error('[QrScanner] start failed:', err);
        onCancel();
      });
    });

    return () => {
      cancelled = true;
      if (scannerRef.current) {
        scannerRef.current.stop().then(() => scannerRef.current.clear()).catch(() => {});
      }
    };
  }, [onScan, onCancel]);

  return (
    <div className="fixed inset-0 z-50 bg-black">
      <div id="tally-qr-reader" ref={containerRef} className="w-full h-full" />
      <button
        onClick={onCancel}
        className="absolute top-4 left-1/2 -translate-x-1/2 bg-white/90 text-gray-900 font-semibold px-6 py-2 rounded-full shadow-lg"
      >
        Cancel
      </button>
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
