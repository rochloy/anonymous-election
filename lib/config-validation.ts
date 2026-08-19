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

  for (const envVar of requiredEnvVars) {
    const value = process.env[envVar];
    if (!value) {
      missing.push(envVar);
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

  if (missing.length > 0) {
    throw new Error(`Missing required environment variables: ${missing.join(', ')}`);
  }

  if (invalid.length > 0) {
    throw new Error(`Invalid configuration: ${invalid.join('; ')}`);
  }
}

// Run validation at module load (skip in test environment)
if (process.env.NODE_ENV !== 'test' && process.env.NODE_ENV !== 'development') {
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