import { getServiceClient, authEmail, mapProfile } from '../../lib/supabase.js';
import { cors, json, readBody } from '../../lib/api-utils.js';

const REFERRAL_REWARD = 30;

function isCodeExpired(code) {
  if (code.status === 'expired') return true;
  if (!code.expires_at) return false;
  return new Date(code.expires_at) < new Date();
}

function isCodeExhausted(code) {
  const maxUses = code.max_uses || 1;
  const useCount = code.use_count || 0;
  return useCount >= maxUses || code.status === 'used';
}

function isCodeActive(code) {
  return code.status !== 'disabled' && !isCodeExpired(code) && !isCodeExhausted(code);
}

export default async function handler(req, res) {
  cors(res);
  if (req.method === 'OPTIONS') { res.statusCode = 200; return res.end(); }
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });

  try {
    const supabase = getServiceClient();
    const body = await readBody(req);
    const {
      name, username, phone, password,
      activationCode, referralUsername
    } = body;

    const uname = (username || '').toLowerCase().trim();
    const phoneNum = (phone || '').replace(/\s/g, '');
    const code = (activationCode || '').toUpperCase().trim();
    const refUser = (referralUsername || '').toLowerCase().trim();
    const isFreeCode = (actCode) => (actCode.code_type || 'standard') === 'free';

    if (!name || name.length < 2) return json(res, 400, { error: 'Enter your complete name' });
    if (!/^[a-zA-Z0-9_]{3,20}$/.test(uname)) return json(res, 400, { error: 'Invalid username' });
    if (!/^09\d{9}$/.test(phoneNum)) return json(res, 400, { error: 'Invalid phone number' });
    if (!code) return json(res, 400, { error: 'Activation code required' });
    if (!password || password.length < 6) return json(res, 400, { error: 'Password must be at least 6 characters' });

    const { data: existingUser } = await supabase.from('profiles').select('id').eq('username', uname).maybeSingle();
    if (existingUser) return json(res, 400, { error: 'Username already taken' });

    const { data: existingPhone } = await supabase.from('profiles').select('id').eq('phone', phoneNum).maybeSingle();
    if (existingPhone) return json(res, 400, { error: 'Phone number already registered' });

    const { data: actCode } = await supabase.from('activation_codes').select('*').eq('code_id', code).maybeSingle();
    if (!actCode) return json(res, 400, { error: 'Invalid activation code' });
    if (actCode.status === 'disabled') return json(res, 400, { error: 'Activation code is not active' });
    if (isCodeExpired(actCode)) {
      if (actCode.status !== 'expired') {
        await supabase.from('activation_codes').update({ status: 'expired' }).eq('code_id', code);
      }
      return json(res, 400, { error: 'Activation code has expired' });
    }
    if (isCodeExhausted(actCode)) {
      return json(res, 400, { error: 'Activation code has no remaining uses' });
    }
    if (!isCodeActive(actCode)) {
      return json(res, 400, { error: 'Activation code is not available' });
    }

    const freeActivation = isFreeCode(actCode);
    let referrer = null;

    if (refUser && !freeActivation) {
      const { data: ref } = await supabase.from('profiles').select('*').eq('username', refUser).eq('role', 'user').maybeSingle();
      if (!ref) return json(res, 400, { error: 'Referral username not found' });
      if (ref.username === uname) return json(res, 400, { error: 'Cannot refer yourself' });
      referrer = ref;
    }

    const email = authEmail(uname);
    const { data: authData, error: authError } = await supabase.auth.admin.createUser({
      email, password, email_confirm: true,
      user_metadata: { username: uname, name }
    });

    if (authError) return json(res, 400, { error: authError.message });

    const userId = authData.user.id;

    const { data: profile, error: profileError } = await supabase.from('profiles').insert({
      id: userId, name, username: uname, phone: phoneNum,
      role: 'user', status: 'active', activation_code: code,
      referred_by: referrer ? referrer.username : (refUser && freeActivation ? refUser : null)
    }).select().single();

    if (profileError) {
      await supabase.auth.admin.deleteUser(userId);
      return json(res, 400, { error: profileError.message });
    }

    const newUseCount = (actCode.use_count || 0) + 1;
    const maxUses = actCode.max_uses || 1;
    const codeUpdate = {
      use_count: newUseCount,
      user_assigned: uname,
      redeemed_by: uname,
      redeemed_at: new Date().toISOString(),
      status: newUseCount >= maxUses ? 'used' : 'unused'
    };
    await supabase.from('activation_codes').update(codeUpdate).eq('code_id', code);

    await supabase.from('code_redemptions').insert({
      code_id: code,
      user_id: userId,
      username: uname,
      redemption_type: freeActivation ? 'free_activation' : 'standard',
      referred_by: refUser || null,
      referral_rewarded: false
    });

    if (referrer && !freeActivation) {
      const { data: existingRef } = await supabase.from('referrals').select('id').eq('referred_username', uname).maybeSingle();
      if (!existingRef) {
        await supabase.from('profiles').update({
          referral_earnings: parseFloat(referrer.referral_earnings) + REFERRAL_REWARD,
          referral_count: referrer.referral_count + 1,
          earnings: parseFloat(referrer.earnings) + REFERRAL_REWARD,
          updated_at: new Date().toISOString()
        }).eq('id', referrer.id);

        await supabase.from('referrals').insert({
          referrer_id: referrer.id, referred_id: userId,
          referrer_username: referrer.username, referred_username: uname, reward: REFERRAL_REWARD
        });

        await supabase.from('earnings').insert({
          user_id: referrer.id, username: referrer.username,
          amount: REFERRAL_REWARD, type: 'referral', description: `Referral bonus for ${uname}`
        });

        await supabase.from('notifications').insert({
          user_id: referrer.id,
          message: `You earned ₱${REFERRAL_REWARD.toFixed(2)} from referral ${uname}!`,
          type: 'success'
        });

        await supabase.from('code_redemptions').update({ referral_rewarded: true })
          .eq('code_id', code).eq('user_id', userId);
      }
    }

    const welcomeMsg = freeActivation
      ? 'Welcome to MathBOT! Your account was activated with a Free Activation code. Start solving math to earn!'
      : 'Welcome to MathBOT! Start solving math to earn.';

    await supabase.from('notifications').insert({
      user_id: userId, message: welcomeMsg, type: 'success'
    });

    await supabase.from('admin_logs').insert({
      action: freeActivation ? 'FREE_ACTIVATION' : 'USER_REGISTERED',
      details: freeActivation
        ? `Free activation: ${uname} (code: ${code}, referrer: ${refUser || 'none'}, no reward)`
        : `New user: ${uname}`,
      admin_username: 'system'
    });

    return json(res, 201, { success: true, user: mapProfile(profile), freeActivation });
  } catch (err) {
    return json(res, 500, { error: err.message || 'Registration failed' });
  }
}

