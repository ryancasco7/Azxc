import { getServiceClient, authEmail } from '../../lib/supabase.js';
import { cors, json } from '../../lib/api-utils.js';

export default async function handler(req, res) {
  cors(res);
  if (req.method === 'OPTIONS') { res.statusCode = 200; return res.end(); }
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });

  const secret = process.env.SETUP_SECRET;
  if (secret && req.headers['x-setup-secret'] !== secret) {
    return json(res, 401, { error: 'Unauthorized' });
  }

  try {
    const supabase = getServiceClient();
    const { data: existing } = await supabase.from('profiles').select('id').eq('username', 'admin').maybeSingle();
    if (existing) {
      return json(res, 200, { message: 'Admin already exists', username: 'admin' });
    }

    const { data: authData, error: authError } = await supabase.auth.admin.createUser({
      email: authEmail('admin'),
      password: 'admin123',
      email_confirm: true,
      user_metadata: { username: 'admin', name: 'System Administrator' }
    });

    if (authError) return json(res, 400, { error: authError.message });

    await supabase.from('profiles').insert({
      id: authData.user.id,
      name: 'System Administrator',
      username: 'admin',
      phone: '09000000000',
      role: 'admin',
      status: 'active',
      activation_code: 'ADMIN'
    });

    return json(res, 201, { message: 'Admin created', username: 'admin', password: 'admin123' });
  } catch (err) {
    return json(res, 500, { error: err.message });
  }
}
