import { getServiceClient } from '../../lib/supabase.js';
import { cors, json, readBody } from '../../lib/api-utils.js';

export default async function handler(req, res) {
  cors(res);
  if (req.method === 'OPTIONS') { res.statusCode = 200; return res.end(); }
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });

  try {
    const authHeader = req.headers.authorization;
    if (!authHeader?.startsWith('Bearer ')) {
      return json(res, 401, { error: 'Not authenticated' });
    }

    const token = authHeader.slice(7);
    const supabase = getServiceClient();

    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) return json(res, 401, { error: 'Invalid session' });

    const { data: admin } = await supabase.from('profiles').select('role').eq('id', user.id).single();
    if (!admin || admin.role !== 'admin') return json(res, 403, { error: 'Admin only' });

    const body = await readBody(req);
    const { userId } = body;
    if (!userId) return json(res, 400, { error: 'userId required' });

    const { data: target } = await supabase.from('profiles').select('username, role').eq('id', userId).single();
    if (!target || target.role === 'admin') return json(res, 400, { error: 'Cannot delete this user' });

    const { error: delError } = await supabase.auth.admin.deleteUser(userId);
    if (delError) return json(res, 400, { error: delError.message });

    await supabase.from('admin_logs').insert({
      action: 'USER_DELETED',
      details: target.username,
      admin_username: user.user_metadata?.username || 'admin'
    });

    return json(res, 200, { success: true });
  } catch (err) {
    return json(res, 500, { error: err.message });
  }
}
