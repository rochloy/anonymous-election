'use client';

import { useEffect, useRef, useState } from 'react';

interface QrScannerProps {
  onScan: (decodedText: string) => void;
  onCancel: () => void;
}

/**
 * Full-viewport QR scanner (html5-qrcode) for the mobile wizard.
 * Camera config matches the working desktop Ballot Lookup path
 * (no aspectRatio — a fixed 1.0 overconstrains some phone cameras).
 * start() failures render an on-screen error + Retry instead of
 * silently unmounting via onCancel.
 */
export default function QrScanner({ onScan, onCancel }: QrScannerProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const scannerRef = useRef<any>(null);
  // Refs hold the latest callbacks so the camera effect deps stay stable
  // (parents used to pass inline arrows → effect thrash → camera restart).
  const onScanRef = useRef(onScan);
  const onCancelRef = useRef(onCancel);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [startAttempt, setStartAttempt] = useState(0);

  useEffect(() => {
    onScanRef.current = onScan;
    onCancelRef.current = onCancel;
  }, [onScan, onCancel]);

  useEffect(() => {
    let cancelled = false;

    import('html5-qrcode').then(({ Html5Qrcode }) => {
      if (cancelled || !containerRef.current) return;

      let scanner: InstanceType<typeof Html5Qrcode>;
      try {
        scanner = new Html5Qrcode('tally-qr-reader');
      } catch (err) {
        if (!cancelled) setErrorMessage(formatCameraError(err));
        return;
      }
      scannerRef.current = scanner;

      scanner.start(
        { facingMode: 'environment' },
        {
          fps: 10,
          qrbox: { width: 250, height: 250 },
        },
        (decodedText: string) => {
          if (cancelled) return;
          const ballotId = extractBallotId(decodedText);
          scanner.stop().then(() => scanner.clear()).catch(() => {});
          onScanRef.current(ballotId);
        },
        () => {}
      ).catch((err: unknown) => {
        if (cancelled) return;
        console.error('[QrScanner] start failed:', err);
        setErrorMessage(formatCameraError(err));
      });
    }).catch((err: unknown) => {
      if (cancelled) return;
      console.error('[QrScanner] html5-qrcode load failed:', err);
      setErrorMessage('Could not load the QR scanner. Check your connection and retry.');
    });

    return () => {
      cancelled = true;
      const active = scannerRef.current;
      scannerRef.current = null;
      if (active) {
        // stop() rejects if start() never succeeded — clear anyway
        active.stop().catch(() => {}).then(() => active.clear()).catch(() => {});
      }
    };
    // Re-run only on explicit Retry — callbacks live in refs.
  }, [startAttempt]);

  return (
    <div className="fixed inset-0 z-50 bg-black">
      <div id="tally-qr-reader" ref={containerRef} className="w-full h-full" />
      <button
        onClick={() => onCancelRef.current()}
        className="absolute top-4 left-1/2 -translate-x-1/2 bg-white/90 text-gray-900 font-semibold px-6 py-2 rounded-full shadow-lg"
      >
        Cancel
      </button>
      {errorMessage && (
        <div className="absolute inset-0 flex items-center justify-center p-6 bg-black/80">
          <div className="w-full max-w-sm bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl p-5 space-y-4 text-center">
            <p className="text-sm text-red-600 dark:text-red-400">{errorMessage}</p>
            <div className="flex gap-3 justify-center">
              <button
                onClick={() => {
                  setErrorMessage(null);
                  setStartAttempt((n) => n + 1);
                }}
                className="bg-blue-600 text-white font-semibold rounded-lg px-5 py-2.5 text-sm"
              >
                Retry
              </button>
              <button
                onClick={() => onCancelRef.current()}
                className="border border-gray-300 dark:border-gray-600 text-gray-600 dark:text-gray-300 font-medium rounded-lg px-5 py-2.5 text-sm"
              >
                Cancel
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

/** Map html5-qrcode / getUserMedia failures to actionable on-screen text. */
function formatCameraError(err: unknown): string {
  const name = err instanceof Error ? err.name : '';
  const message =
    typeof err === 'string'
      ? err
      : err instanceof Error
        ? err.message
        : String(err ?? '');

  if (
    name === 'NotAllowedError' ||
    name === 'PermissionDeniedError' ||
    /permission|denied/i.test(message)
  ) {
    return 'Camera permission was denied. Allow camera access for this site, then retry.';
  }
  if (
    name === 'NotFoundError' ||
    name === 'DevicesNotFoundError' ||
    /no camera|no video|requested device/i.test(message)
  ) {
    return 'No camera was found on this device.';
  }
  if (
    name === 'NotReadableError' ||
    name === 'TrackStartError' ||
    /in use|could not start|hardware/i.test(message)
  ) {
    return 'Camera is unavailable (it may be in use by another app). Close other camera apps and retry.';
  }
  if (typeof window !== 'undefined' && !window.isSecureContext) {
    return 'Camera requires HTTPS. Open this page over HTTPS and retry.';
  }
  return message ? `Camera failed to start: ${message}` : 'Camera failed to start.';
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
