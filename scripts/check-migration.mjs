import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';
import path from 'path';
import { fileURLToPath } from 'url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
config({ path: path.join(root, '.env') });

const url = process.env.SUPABASE_URL;
const anon = process.env.SUPABASE_ANON_KEY;
const sb = createClient(url, anon);

await sb.auth.signInWithPassword({ email: 'admin@mathbot.app', password: 'admin123' });

const checks = [
  ['promotions table', () => sb.from('promotions').select('id').limit(1)],
  ['balance_adjustments table', () => sb.from('balance_adjustments').select('id').limit(1)],
  ['code_redemptions table', () => sb.from('code_redemptions').select('id').limit(1)],
  ['admin_adjust_balance RPC', () => sb.rpc('admin_adjust_balance', {
    p_user_id: '00000000-0000-0000-0000-000000000001',
    p_amount: 1, p_adjustment_type: 'add', p_reason: 'check', p_allow_negative: false
  })],
  ['admin_get_promotions RPC', () => sb.rpc('admin_get_promotions')],
];

let ok = 0;
for (const [name, fn] of checks) {
  const { error } = await fn();
  const pass = !error || (name.includes('admin_adjust_balance') && error.message.includes('User not found'));
  console.log(pass ? '✓' : '✗', name, pass ? '' : '— ' + error.message);
  if (pass) ok++;
}

console.log(`\n${ok}/${checks.length} checks passed`);
if (ok < checks.length) {
  console.log('\nRun the migration in Supabase SQL Editor:');
  console.log('  File: supabase/migration_admin_features.sql');
  console.log('  URL:  https://supabase.com/dashboard/project/eiszdzotcatandzyityu/sql/new');
  process.exit(1);
}
