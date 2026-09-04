// Configuration validation - runs at module load time
// Fails fast if required environment variables are missing or invalid

const requiredEnvVars = [
  'NEXT_PUBLIC_SUPABASE_URL',
  'NEXT_PUBLIC_SUPABASE_ANON_KEY',
  'SUPABASE_SERVICE_ROLE_KEY',
  'APP_BASE_URL',
  'RESEND_API_KEY',
  'FROM_EMAIL',
  'ADMIN_SECRET',
] as const;

const optionalEnvVars = [
  'ADMIN_EMAIL',
  // Optional dedicated pepper for rate-limit identifiers (de-correlates them from
  // tokens.token_hash). Falls back to ADMIN_SECRET when unset, so not required.
  'RATE_LIMIT_SECRET',
] as const;

function validateUrl(url: string, name: string): void {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
      throw new Error(`${name} must use HTTP or HTTPS protocol`);
    }
    if (process.env.NODE_ENV === 'production' && parsed.protocol !== 'https:') {
      throw new Error(`${name} must use HTTPS in production`);
    }
  } catch (e) {
    throw new Error(`Invalid ${name}: ${e instanceof Error ? e.message : 'malformed URL'}`);
  }
}

function validateConfig(): void {
  const missing: string[] = [];
  const invalid: string[] = [];
  const warnings: string[] = [];

  for (const envVar of requiredEnvVars) {
    const value = process.env[envVar];
    if (!value) {
      missing.push(envVar);
    }
  }

  // Surface unset optional vars as warnings so operators know a fallback is in
  // effect (e.g. RATE_LIMIT_SECRET falls back to ADMIN_SECRET when unset).
  for (const envVar of optionalEnvVars) {
    if (!process.env[envVar]) {
      warnings.push(`${envVar}: not set (using default/fallback behavior)`);
    }
  }

  // Validate APP_BASE_URL format
  if (process.env.APP_BASE_URL) {
    try {
      validateUrl(process.env.APP_BASE_URL, 'APP_BASE_URL');
    } catch (e) {
      invalid.push(`APP_BASE_URL: ${e instanceof Error ? e.message : 'invalid'}`);
    }
  }

  // Validate FROM_EMAIL format
  if (process.env.FROM_EMAIL) {
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(process.env.FROM_EMAIL)) {
      invalid.push('FROM_EMAIL: invalid email format');
    }
  }

  // Production-specific validations
  if (process.env.NODE_ENV === 'production') {
    // ADMIN_SECRET must be strong (at least 32 chars, high entropy)
    if (process.env.ADMIN_SECRET && process.env.ADMIN_SECRET.length < 32) {
      invalid.push('ADMIN_SECRET: must be at least 32 characters in production');
    }

    // RESEND_API_KEY should not be a test key
    if (process.env.RESEND_API_KEY && process.env.RESEND_API_KEY.startsWith('re_')) {
      // This is a valid Resend key format, OK
    } else if (process.env.RESEND_API_KEY) {
      warnings.push('RESEND_API_KEY: unexpected format');
    }

    // APP_BASE_URL should not be localhost
    if (process.env.APP_BASE_URL && process.env.APP_BASE_URL.includes('localhost')) {
      invalid.push('APP_BASE_URL: must not be localhost in production');
    }

    // Check for default/weak secrets
    const weakSecrets = ['test-secret', 'secret', 'admin', 'password', 'changeme'];
    if (process.env.ADMIN_SECRET && weakSecrets.some(w => process.env.ADMIN_SECRET!.toLowerCase().includes(w))) {
      invalid.push('ADMIN_SECRET: appears to be a default/weak secret');
    }
  }

  if (missing.length > 0) {
    throw new Error(`Missing required environment variables: ${missing.join(', ')}`);
  }

  if (invalid.length > 0) {
    throw new Error(`Invalid configuration: ${invalid.join('; ')}`);
  }

  if (warnings.length > 0) {
    console.warn('[config-validation] Warnings:', warnings.join('; '));
  }
}

// Run validation at module load (skip in test, development, and build environments)
if (process.env.NODE_ENV !== 'test' && process.env.NODE_ENV !== 'development' && process.env.NEXT_PHASE !== 'phase-production-build') {
  try {
    validateConfig();
  } catch (e) {
    console.error('[config-validation] Configuration error:', e instanceof Error ? e.message : e);
    // In development, log but don't throw to allow local development
    if (process.env.NODE_ENV === 'production') {
      throw e;
    }
  }
}

export { validateConfig, validateUrl };