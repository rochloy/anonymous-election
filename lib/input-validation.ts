/**
 * Input validation utilities for length limits and sanitization
 * SEC-16: Input length limits on text fields
 */

export const INPUT_LIMITS = {
  // Candidate fields
  candidate: {
    full_name: { min: 1, max: 255 },
    statement: { min: 0, max: 5000 },
    photo_url: { min: 0, max: 2048 },
  },
  // Member fields
  member: {
    full_name: { min: 1, max: 255 },
    email: { min: 0, max: 255 },
    phone: { min: 0, max: 50 },
    member_code: { min: 1, max: 50 },
  },
  // CSV import fields
  csv: {
    full_name: { min: 1, max: 255 },
    email: { min: 0, max: 255 },
    phone: { min: 0, max: 50 },
    member_code: { min: 1, max: 50 },
  },
  // Phase change
  phase: {
    confirmText: { min: 5, max: 7 }, // "CONFIRM" (7) or "RESET" (5)
  },
  // Token dispatch
  token: {
    type: { min: 1, max: 20 },
  },
  // Election dates
  election: {
    date: { min: 0, max: 50 }, // ISO date string
  },
} as const;

/**
 * Validate string length against limits
 */
export function validateLength(
  value: string | null | undefined,
  fieldName: string,
  limits: { min: number; max: number }
): { valid: boolean; error?: string } {
  if (value === null || value === undefined) {
    if (limits.min > 0) {
      return { valid: false, error: `${fieldName} is required` };
    }
    return { valid: true };
  }

  const trimmed = value.trim();
  const len = trimmed.length;

  if (len < limits.min) {
    return { valid: false, error: `${fieldName} must be at least ${limits.min} characters` };
  }
  if (len > limits.max) {
    return { valid: false, error: `${fieldName} must not exceed ${limits.max} characters` };
  }
  return { valid: true };
}

/**
 * Validate multiple fields at once
 */
export function validateFields(
  data: Record<string, unknown>,
  schema: Record<string, { min: number; max: number }>
): { valid: boolean; errors: string[] } {
  const errors: string[] = [];
  
  for (const [field, limits] of Object.entries(schema)) {
    const result = validateLength(data[field] as string | null | undefined, field, limits);
    if (!result.valid && result.error) {
      errors.push(result.error);
    }
  }
  
  return { valid: errors.length === 0, errors };
}

/**
 * Sanitize string input - trim and remove null bytes
 */
export function sanitizeString(value: string | null | undefined): string {
  if (!value) return '';
  return value.replace(/\0/g, '').trim();
}

/**
 * Validate email format
 */
export function validateEmail(email: string | null | undefined): { valid: boolean; error?: string } {
  if (!email || !email.trim()) return { valid: true }; // Optional field
  const trimmed = email.trim();
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  if (!emailRegex.test(trimmed)) {
    return { valid: false, error: 'Invalid email format' };
  }
  if (trimmed.length > 255) {
    return { valid: false, error: 'Email must not exceed 255 characters' };
  }
  return { valid: true };
}

/**
 * Validate phone format (basic)
 */
export function validatePhone(phone: string | null | undefined): { valid: boolean; error?: string } {
  if (!phone || !phone.trim()) return { valid: true }; // Optional field
  const trimmed = phone.trim();
  if (trimmed.length > 50) {
    return { valid: false, error: 'Phone must not exceed 50 characters' };
  }
  // Basic phone validation - allow digits, spaces, dashes, parentheses, plus
  const phoneRegex = /^[\d\s\-\(\)\+]+$/;
  if (!phoneRegex.test(trimmed)) {
    return { valid: false, error: 'Invalid phone format' };
  }
  return { valid: true };
}