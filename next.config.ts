import type { NextConfig } from "next";

const isProd = process.env.NODE_ENV === 'production';

const securityHeaders = [
  // F14 Tier-2: the Content-Security-Policy header moved to proxy.ts (per-request
  // nonce). Do NOT re-add a static CSP here — two CSP headers intersect in
  // browsers (most restrictive wins) and silently break nonced inline scripts.
  {
    key: 'X-Frame-Options',
    value: 'DENY',
  },
  {
    key: 'X-Frame-Options',
    value: 'DENY',
  },
  {
    key: 'X-Content-Type-Options',
    value: 'nosniff',
  },
  {
    key: 'Referrer-Policy',
    value: 'strict-origin-when-cross-origin',
  },
  {
    key: 'Permissions-Policy',
    // camera=(self): the in-app QR scanner (html5-qrcode) needs camera access;
    // third-party embeds are already prevented by frame-ancestors 'none'.
    value: 'camera=(self), microphone=(), geolocation=(), payment=()',
  },
  ...(isProd ? [{
    key: 'Strict-Transport-Security',
    value: 'max-age=31536000; includeSubDomains; preload',
  }] : []),
];

const nextConfig: NextConfig = {
  async headers() {
    return [
      {
        source: '/:path*',
        headers: securityHeaders,
      },
      {
        source: '/:kind(vote|nominate)/:token',
        headers: [
          { key: 'Referrer-Policy', value: 'no-referrer' },
          { key: 'Cache-Control', value: 'no-store' },
        ],
      },
    ];
  },
};

export default nextConfig;
