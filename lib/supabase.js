import { createClient } from '@supabase/supabase-js';

export function getServiceClient() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error('Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY');
  return createClient(url, key, { auth: { autoRefreshToken: false, persistSession: false } });
}

export function authEmail(username) {
  return `${username.toLowerCase().trim()}@mathbot.app`;
}

export function mapProfile(row) {
  if (!row) return null;
  return {
    id: row.id,
    name: row.name,
    username: row.username,
    phone: row.phone,
    role: row.role,
    status: row.status,
    earnings: parseFloat(row.earnings),
    referralEarnings: parseFloat(row.referral_earnings),
    totalWithdrawn: parseFloat(row.total_withdrawn),
    referralCount: row.referral_count,
    stats: {
      totalAnswered: row.total_answered,
      correct: row.correct_answers,
      wrong: row.wrong_answers
    },
    registrationDate: row.created_at,
    activationCode: row.activation_code,
    referredBy: row.referred_by
  };
}
