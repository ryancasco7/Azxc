/* MathBOT Supabase Database Layer */
window.MathBOTDB = (function () {
  'use strict';

  let supabase = null;
  let currentProfile = null;
  const realtimeChannels = [];

  function authEmail(username) {
    return `${username.toLowerCase().trim()}@mathbot.app`;
  }

  function mapProfile(row) {
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

  function withTimeout(promise, ms, message) {
    return Promise.race([
      promise,
      new Promise((_, reject) => setTimeout(() => reject(new Error(message)), ms))
    ]);
  }

  async function fetchConfig() {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 8000);
    try {
      const res = await fetch('/api/config', { signal: controller.signal });
      if (!res.ok) throw new Error('config endpoint failed');
      return await res.json();
    } finally {
      clearTimeout(timer);
    }
  }

  async function init() {
    let url, anonKey;
    try {
      ({ url, anonKey } = await fetchConfig());
    } catch {
      if (window.__MATHBOT_CONFIG__) {
        ({ url, anonKey } = window.__MATHBOT_CONFIG__);
      } else {
        throw new Error('Failed to load Supabase config. Run "npm run dev" locally or set env vars on Vercel.');
      }
    }
    if (!url || !anonKey) throw new Error('Supabase URL and anon key are required.');

    if (!window.supabase?.createClient) {
      throw new Error('Supabase library failed to load. Check your internet connection.');
    }

    supabase = window.supabase.createClient(url, anonKey, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
    });
    supabase.auth.onAuthStateChange(async (event) => {
      if (event === 'SIGNED_IN') await loadProfile().catch(() => { currentProfile = null; });
      if (event === 'SIGNED_OUT') currentProfile = null;
    });

    // Restore session in background — never block page load on auth
    withTimeout(supabase.auth.getSession(), 5000, 'session check')
      .then(async ({ data: { session } }) => {
        if (session) await withTimeout(loadProfile(), 5000, 'profile load').catch(() => { currentProfile = null; });
      })
      .catch(() => { currentProfile = null; });

    return supabase;
  }

  function getClient() { return supabase; }

  async function loadProfile() {
    const { data: { user } } = await withTimeout(supabase.auth.getUser(), 5000, 'getUser timed out');
    if (!user) { currentProfile = null; return null; }
    const { data, error } = await withTimeout(
      supabase.from('profiles').select('*').eq('id', user.id).single(),
      5000,
      'profile query timed out'
    );
    if (error) throw error;
    currentProfile = mapProfile(data);
    return currentProfile;
  }

  function getProfile() { return currentProfile; }

  async function login(username, password) {
    const { data, error } = await supabase.auth.signInWithPassword({
      email: authEmail(username),
      password
    });
    if (error) throw error;
    await loadProfile();
    if (currentProfile?.status === 'banned') {
      await supabase.auth.signOut();
      throw new Error('Account has been banned');
    }
    return currentProfile;
  }

  async function logout() {
    await supabase.auth.signOut();
    currentProfile = null;
  }

  async function register(payload) {
    const res = await fetch('/api/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'Registration failed');
    return data;
  }

  async function getSession() {
    const { data: { session } } = await withTimeout(supabase.auth.getSession(), 5000, 'getSession timed out');
    return session;
  }

  async function ensureProfile() {
    if (currentProfile) return currentProfile;
    return loadProfile().catch(() => null);
  }

  async function requireAuth(role = null) {
    const session = await getSession();
    if (!session) return null;
    if (!currentProfile) await ensureProfile();
    if (!currentProfile) return null;
    if (currentProfile.status === 'banned') {
      await logout();
      return null;
    }
    if (role && currentProfile.role !== role) return { forbidden: true, profile: currentProfile };
    return { session, user: currentProfile };
  }

  async function fetchProfileById(id) {
    const { data } = await supabase.from('profiles').select('*').eq('id', id).single();
    return mapProfile(data);
  }

  async function refreshProfile() {
    return loadProfile();
  }

  /* Question history */
  async function getUserQuestionKeys(userId) {
    const { data } = await supabase
      .from('question_history')
      .select('question_key')
      .eq('user_id', userId);
    return (data || []).map(r => r.question_key);
  }

  async function saveQuestionKey(userId, key) {
    await supabase.from('question_history').upsert(
      { user_id: userId, question_key: key },
      { onConflict: 'user_id,question_key' }
    );
  }

  /* Game */
  async function submitAnswer(questionKey, userAnswer, correctAnswer) {
    const { data, error } = await supabase.rpc('submit_game_answer', {
      p_question_key: questionKey,
      p_user_answer: userAnswer,
      p_correct_answer: correctAnswer
    });
    if (error) throw error;
    if (data?.profile) currentProfile = mapProfile(data.profile);
    return data;
  }

  /* Earnings & activity */
  async function getRecentEarnings(limit = 10) {
    const { data } = await supabase.from('earnings')
      .select('*').order('created_at', { ascending: false }).limit(limit);
    return data || [];
  }

  async function getDailyLeaderboard() {
    const today = new Date().toISOString().slice(0, 10);
    const { data } = await supabase.from('earnings')
      .select('username, amount, created_at')
      .gte('created_at', today + 'T00:00:00');
    const map = {};
    (data || []).forEach(e => { map[e.username] = (map[e.username] || 0) + parseFloat(e.amount); });
    return Object.entries(map).sort((a, b) => b[1] - a[1]).slice(0, 10);
  }

  async function getTopEarners() {
    const { data } = await supabase.from('profiles')
      .select('username, earnings, referral_earnings')
      .eq('role', 'user').eq('status', 'active')
      .order('earnings', { ascending: false }).limit(50);
    return (data || [])
      .map(u => ({ username: u.username, total: parseFloat(u.earnings) + parseFloat(u.referral_earnings) }))
      .sort((a, b) => b.total - a.total).slice(0, 10);
  }

  /* Notifications */
  async function getNotifications(userId) {
    const { data } = await supabase.from('notifications')
      .select('*').eq('user_id', userId)
      .order('created_at', { ascending: false }).limit(50);
    return (data || []).map(n => ({
      id: n.id, message: n.message, type: n.type,
      date: n.created_at, read: n.read
    }));
  }

  async function markNotificationsRead() {
    await supabase.rpc('mark_notifications_read');
  }

  /* Withdrawals */
  async function getPendingAmount(userId) {
    const { data } = await supabase.from('withdrawals')
      .select('amount').eq('user_id', userId).eq('status', 'pending');
    return (data || []).reduce((s, w) => s + parseFloat(w.amount), 0);
  }

  async function getUserWithdrawals(userId) {
    const { data } = await supabase.from('withdrawals')
      .select('*').eq('user_id', userId)
      .order('requested_at', { ascending: false });
    return data || [];
  }

  async function requestWithdrawal(amount, gcashName, gcashNumber) {
    const { data, error } = await supabase.rpc('request_withdrawal', {
      p_amount: amount,
      p_gcash_name: gcashName,
      p_gcash_number: gcashNumber
    });
    if (error) throw error;
    await loadProfile();
    return data;
  }

  async function getAllWithdrawals() {
    const { data } = await supabase.from('withdrawals')
      .select('*').order('requested_at', { ascending: false });
    return data || [];
  }

  /* Admin */
  async function getAdminStats() {
    const [users, earnings, referrals, withdrawals, codes] = await Promise.all([
      supabase.from('profiles').select('*').eq('role', 'user'),
      supabase.from('earnings').select('amount, created_at'),
      supabase.from('referrals').select('reward'),
      supabase.from('withdrawals').select('status'),
      supabase.from('activation_codes').select('code_id')
    ]);
    const u = users.data || [];
    const today = new Date().toISOString().slice(0, 10);
    return {
      totalUsers: u.length,
      activated: u.filter(x => x.activation_code).length,
      totalPaid: (earnings.data || []).reduce((s, e) => s + parseFloat(e.amount), 0),
      refRewards: (referrals.data || []).reduce((s, r) => s + parseFloat(r.reward), 0),
      pendingWd: (withdrawals.data || []).filter(w => w.status === 'pending').length,
      approvedWd: (withdrawals.data || []).filter(w => w.status === 'approved').length,
      rejectedWd: (withdrawals.data || []).filter(w => w.status === 'rejected').length,
      totalCodes: (codes.data || []).length,
      dailyUsers: u.filter(x => x.created_at?.slice(0, 10) === today).length,
      dailyEarnings: (earnings.data || []).filter(e => e.created_at?.slice(0, 10) === today)
        .reduce((s, e) => s + parseFloat(e.amount), 0)
    };
  }

  async function getLast7DaysUsers() {
    const { data } = await supabase.from('profiles').select('created_at').eq('role', 'user');
    const days = [];
    for (let i = 6; i >= 0; i--) {
      const d = new Date(); d.setDate(d.getDate() - i);
      const key = d.toISOString().slice(0, 10);
      days.push({
        label: d.toLocaleDateString('en-PH', { weekday: 'short' }),
        value: (data || []).filter(u => u.created_at?.slice(0, 10) === key).length
      });
    }
    return days;
  }

  async function getLast7DaysEarnings() {
    const { data } = await supabase.from('earnings').select('amount, created_at');
    const days = [];
    for (let i = 6; i >= 0; i--) {
      const d = new Date(); d.setDate(d.getDate() - i);
      const key = d.toISOString().slice(0, 10);
      days.push({
        label: d.toLocaleDateString('en-PH', { weekday: 'short' }),
        value: (data || []).filter(e => e.created_at?.slice(0, 10) === key)
          .reduce((s, e) => s + parseFloat(e.amount), 0)
      });
    }
    return days;
  }

  async function getActivationCodes(filter = 'all', typeFilter = 'all') {
    let q = supabase.from('activation_codes').select('*').order('generated_at', { ascending: false });
    if (filter === 'used') q = q.eq('status', 'used');
    if (filter === 'unused') q = q.eq('status', 'unused');
    if (filter === 'expired') q = q.eq('status', 'expired');
    if (typeFilter === 'standard') q = q.eq('code_type', 'standard');
    if (typeFilter === 'free') q = q.eq('code_type', 'free');
    const { data } = await q;
    return (data || []).map(c => ({
      ...c,
      code_type: c.code_type || 'standard',
      max_uses: c.max_uses ?? 1,
      use_count: c.use_count ?? 0
    }));
  }

  async function getActivePromotions() {
    const { data, error } = await supabase.rpc('get_active_promotions');
    if (error) throw error;
    return data || [];
  }

  async function adminGetPromotions() {
    const { data, error } = await supabase.rpc('admin_get_promotions');
    if (error) throw error;
    return data || [];
  }

  async function adminSavePromotion(promo) {
    const { data, error } = await supabase.rpc('admin_save_promotion', {
      p_id: promo.id || null,
      p_title: promo.title,
      p_description: promo.description,
      p_start_at: promo.start_at,
      p_end_at: promo.end_at,
      p_bonus_type: promo.bonus_type,
      p_bonus_amount: promo.bonus_type === 'fixed' ? promo.bonus_amount : null,
      p_bonus_percent: promo.bonus_type === 'percentage' ? promo.bonus_percent : null,
      p_eligibility: promo.eligibility || '',
      p_is_active: promo.is_active !== false
    });
    if (error) throw error;
    return data;
  }

  async function adminTogglePromotion(id, active) {
    const { error } = await supabase.rpc('admin_toggle_promotion', { p_id: id, p_active: active });
    if (error) throw error;
  }

  async function adminDeletePromotion(id) {
    const { error } = await supabase.rpc('admin_delete_promotion', { p_id: id });
    if (error) throw error;
  }

  async function adminAdjustBalance(userId, amount, type, reason, allowNegative = false) {
    const { data, error } = await supabase.rpc('admin_adjust_balance', {
      p_user_id: userId,
      p_amount: amount,
      p_adjustment_type: type,
      p_reason: reason,
      p_allow_negative: allowNegative
    });
    if (error) throw error;
    return data;
  }

  async function adminGetBalanceAdjustments(userId = null) {
    const { data, error } = await supabase.rpc('admin_get_balance_adjustments', { p_user_id: userId });
    if (error) throw error;
    return data || [];
  }

  async function adminGetAuditLogs() {
    const { data, error } = await supabase.rpc('admin_get_audit_logs');
    if (error) throw error;
    return data || [];
  }

  async function adminGetAllNotifications() {
    const { data, error } = await supabase.rpc('admin_get_all_notifications');
    if (error) throw error;
    return data || [];
  }

  async function getAllUsers(search = '') {
    let q = supabase.from('profiles').select('*').eq('role', 'user').order('created_at', { ascending: false });
    const { data } = await q;
    let users = (data || []).map(mapProfile);
    if (search) {
      const s = search.toLowerCase();
      users = users.filter(u =>
        u.name.toLowerCase().includes(s) ||
        u.username.includes(s) ||
        u.phone.includes(s)
      );
    }
    return users;
  }

  async function adminGenerateCodes(count, codeType = 'standard', expiresAt = null, maxUses = 1) {
    const { data, error } = await supabase.rpc('admin_generate_codes', {
      p_count: count,
      p_code_type: codeType,
      p_expires_at: expiresAt,
      p_max_uses: maxUses
    });
    if (error) throw error;
    return data;
  }

  async function adminCreateCode(codeId, codeType = 'standard', expiresAt = null, maxUses = 1) {
    const { data, error } = await supabase.rpc('admin_create_code', {
      p_code_id: codeId,
      p_code_type: codeType,
      p_expires_at: expiresAt,
      p_max_uses: maxUses
    });
    if (error) throw error;
    return data;
  }

  async function adminDisableCode(codeId) {
    const { error } = await supabase.rpc('admin_disable_code', { p_code_id: codeId });
    if (error) throw error;
  }

  async function adminDeleteCode(codeId) {
    const { error } = await supabase.rpc('admin_delete_code', { p_code_id: codeId });
    if (error) throw error;
  }

  async function adminUpdateUser(userId, name, phone, earnings) {
    const { error } = await supabase.rpc('admin_update_user', {
      p_user_id: userId, p_name: name, p_phone: phone, p_earnings: earnings
    });
    if (error) throw error;
  }

  async function adminToggleBan(userId) {
    const { data, error } = await supabase.rpc('admin_toggle_ban', { p_user_id: userId });
    if (error) throw error;
    return data;
  }

  async function adminDeleteUser(userId) {
    const session = await getSession();
    const res = await fetch('/api/delete-user', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${session.access_token}`
      },
      body: JSON.stringify({ userId })
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error);
    return data;
  }

  async function adminProcessWithdrawal(withdrawalId, status) {
    const { data, error } = await supabase.rpc('admin_process_withdrawal', {
      p_withdrawal_id: withdrawalId,
      p_status: status
    });
    if (error) throw error;
    return data;
  }

  /* Realtime */
  function subscribe(tables, callback) {
    const channel = supabase.channel('mathbot-realtime-' + Date.now());
    tables.forEach(table => {
      channel.on('postgres_changes', { event: '*', schema: 'public', table }, callback);
    });
    channel.subscribe();
    realtimeChannels.push(channel);
    return channel;
  }

  function unsubscribeAll() {
    realtimeChannels.forEach(ch => supabase.removeChannel(ch));
    realtimeChannels.length = 0;
  }

  return {
    init, getClient, login, logout, register, getSession, ensureProfile, requireAuth,
    getProfile, loadProfile, refreshProfile, fetchProfileById,
    getUserQuestionKeys, saveQuestionKey,
    submitAnswer, getRecentEarnings, getDailyLeaderboard, getTopEarners,
    getNotifications, markNotificationsRead,
    getPendingAmount, getUserWithdrawals, requestWithdrawal, getAllWithdrawals,
    getAdminStats, getLast7DaysUsers, getLast7DaysEarnings,
    getActivationCodes, getAllUsers, getActivePromotions,
    adminGetPromotions, adminSavePromotion, adminTogglePromotion, adminDeletePromotion,
    adminAdjustBalance, adminGetBalanceAdjustments, adminGetAuditLogs, adminGetAllNotifications,
    adminGenerateCodes, adminCreateCode, adminDisableCode, adminDeleteCode,
    adminUpdateUser, adminToggleBan, adminDeleteUser, adminProcessWithdrawal,
    subscribe, unsubscribeAll, mapProfile
  };
})();
