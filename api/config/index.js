import { cors, json } from '../../lib/api-utils.js';

export default function handler(req, res) {
  cors(res);
  if (req.method === 'OPTIONS') { res.statusCode = 200; return res.end(); }

  const url = (process.env.SUPABASE_URL || '').trim();
  const anonKey = (process.env.SUPABASE_ANON_KEY || '').trim();

  if (!url || !anonKey) {
    return json(res, 500, { error: 'Supabase not configured' });
  }

  return json(res, 200, { url, anonKey });
}
