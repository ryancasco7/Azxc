import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';
import path from 'path';
import { fileURLToPath } from 'url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
config({ path: path.join(root, '.env') });

const url = process.env.SUPABASE_URL;
const anon = process.env.SUPABASE_ANON_KEY;
const service = process.env.SUPABASE_SERVICE_ROLE_KEY;

console.log('Testing Supabase connection...');
const supabase = createClient(url, anon);
const admin = createClient(url, service);

const { data: codes, error: codesErr } = await supabase.from('activation_codes').select('code_id').limit(1);
console.log('activation_codes:', codesErr ? codesErr.message : `OK (${codes?.length} rows)`);

const { data: authData, error: authErr } = await supabase.auth.signInWithPassword({
  email: 'admin@mathbot.app',
  password: 'admin123'
});
console.log('admin login:', authErr ? authErr.message : `OK (${authData.user?.id})`);

if (authData?.user) {
  const { data: profile, error: profErr } = await supabase.from('profiles').select('username, role').eq('id', authData.user.id).single();
  console.log('admin profile:', profErr ? profErr.message : profile);
}

const { data: rpc, error: rpcErr } = await supabase.rpc('is_admin');
console.log('is_admin rpc:', rpcErr ? rpcErr.message : rpc);
