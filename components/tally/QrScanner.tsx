'use client';

import { useEffect, useRef, useState } from 'react';

interface QrScannerProps {
  onScan: (decodedText: string) => void;
  onCancel: () => void;
}

/**
 * Full-viewport QR scanner for the mobile wizard.
 *
 * Camera scanning uses Html5QrcodeScanner + render() — the same integration
 * as the working desktop Ballot Lookup path.
 *
 * File scanning ("Photo") is custom rather than the library's built-in
 * file-scan: the library surfaces failures as raw values (a blocked or failed
 * image load rejects with the Event object → "[object Event]" in its header),
 * and 12MP+ phone photos decode slowly at full size. Our path downscales via
 * canvas before decoding and maps failures to readable text.
 * Note: file-scan requires `blob:` in the CSP img-src (proxy.ts) — the photo
 * is loaded via URL.createObjectURL().
 */
export default function QrScanner({ onScan, onCancel }: QrScannerProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const fileScanRef = useRef<HTMLDivElement>(null);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const scannerRef = useRef<any>(null);
  // Refs hold the latest callbacks so the scanner effect deps stay stable.
  const onScanRef = useRef(onScan);
  const onCancelRef = useRef(onCancel);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [errorKind, setErrorKind] = useState<'camera' | 'file'>('camera');
  const [startAttempt, setStartAttempt] = useState(0);
  const [scanningFile, setScanningFile] = useState(false);

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

      // Hide the library's file-scan UI: it surfaces failures as raw values
      // ("[object Event]") instead of readable text. Our own "Photo" control
      // (in the sticky bar) downscales before decoding and maps errors to
      // readable text. All Scanner chrome is created synchronously inside
      // render(), so the elements exist here.
      const anchor = document.getElementById('html5-qrcode-anchor-scan-type-change');
      if (anchor) anchor.style.display = 'none';
      const fileButton = document.getElementById('html5-qrcode-button-file-selection');
      // button > label(for=…) > file-based scan region div
      const fileRegion = fileButton?.parentElement?.parentElement;
      if (fileRegion) fileRegion.style.display = 'none';
    }).catch((err: unknown) => {
      if (cancelled) return;
      console.error('[QrScanner] html5-qrcode load failed:', err);
      setErrorMessage('Could not load the QR scanner. Check your connection and retry.');
      setErrorKind('camera');
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
  }, [startAttempt]);

  const handleFile = async (file: File | null) => {
    if (!file) return;
    setScanningFile(true);
    try {
      const { Html5Qrcode } = await import('html5-qrcode');
      const scaled = await downscaleImage(file, 1200);
      if (!fileScanRef.current) return;
      // Separate instance: the camera instance is mid-scan and scanFile
      // would throw "Cannot start file scan - ongoing camera scan".
      const fileScanner = new Html5Qrcode('tally-qr-file-scan');
      try {
        const decoded = await fileScanner.scanFile(scaled, false);
        onScanRef.current(extractBallotId(decoded));
      } finally {
        fileScanner.clear();
      }
    } catch (err) {
      console.error('[QrScanner] file scan failed:', err);
      setErrorMessage(formatFileScanError(err));
      setErrorKind('file');
    } finally {
      setScanningFile(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 bg-black overflow-auto">
      {/* Sticky control bar — always visible and survives scrolling. */}
      <div className="sticky top-0 z-10 flex items-center justify-center gap-3 py-3 bg-black">
        <button
          onClick={() => onCancelRef.current()}
          className="bg-white/90 text-gray-900 font-semibold px-6 py-2 rounded-full shadow-lg"
        >
          Cancel
        </button>
        <label className="bg-white/90 text-gray-900 font-semibold px-6 py-2 rounded-full shadow-lg cursor-pointer">
          {scanningFile ? 'Scanning…' : '📷 Photo'}
          <input
            type="file"
            accept="image/*"
            className="sr-only"
            disabled={scanningFile}
            onChange={(e) => {
              const file = e.target.files?.[0] ?? null;
              e.target.value = '';
              void handleFile(file);
            }}
          />
        </label>
      </div>
      <div id="tally-qr-reader" ref={containerRef} className="w-full" />
      {/* Hidden element hosting the file-scan decode canvas */}
      <div id="tally-qr-file-scan" ref={fileScanRef} className="hidden" />
      {errorMessage && (
        <div className="fixed inset-0 flex items-center justify-center p-6 bg-black/80">
          <div className="w-full max-w-sm bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl p-5 space-y-4 text-center">
            <p className="text-sm text-red-600 dark:text-red-400">{errorMessage}</p>
            <div className="flex gap-3 justify-center">
              {errorKind === 'camera' && (
                <button
                  onClick={() => {
                    setErrorMessage(null);
                    setStartAttempt((n) => n + 1);
                  }}
                  className="bg-blue-600 text-white font-semibold rounded-lg px-5 py-2.5 text-sm"
                >
                  Retry
                </button>
              )}
              <button
                onClick={() => setErrorMessage(null)}
                className="border border-gray-300 dark:border-gray-600 text-gray-600 dark:text-gray-300 font-medium rounded-lg px-5 py-2.5 text-sm"
              >
                Close
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

/**
 * Downscale large photos before decoding — 12MP+ phone photos decode slowly
 * at full size; a ≤1200px canvas is fast and reliable.
 */
async function downscaleImage(file: File, maxDim: number): Promise<File> {
  try {
    const bitmap = await createImageBitmap(file);
    const scale = Math.min(1, maxDim / Math.max(bitmap.width, bitmap.height));
    if (scale >= 1) {
      bitmap.close();
      return file;
    }
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(bitmap.width * scale);
    canvas.height = Math.round(bitmap.height * scale);
    const ctx = canvas.getContext('2d');
    if (!ctx) {
      bitmap.close();
      return file;
    }
    ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    bitmap.close();
    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, 'image/png'));
    if (!blob) return file;
    return new File([blob], file.name, { type: 'image/png' });
  } catch {
    return file; // fall back to the original file
  }
}

/** Map file-scan failures to actionable on-screen text. */
function formatFileScanError(err: unknown): string {
  const message =
    err instanceof Error
      ? err.message
      : typeof err === 'string'
        ? err
        : '';
  if (/ongoing camera scan/i.test(message)) {
    return 'Stop the camera scan before scanning from a photo.';
  }
  return 'Could not read a QR code from that photo. Try a sharper, closer photo.';
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
