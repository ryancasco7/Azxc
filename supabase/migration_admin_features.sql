-- MathBOT Admin Features Migration
-- Run in Supabase SQL Editor after schema.sql

-- ============================================================
-- EXTEND ACTIVATION CODES
-- ============================================================

ALTER TABLE activation_codes ADD COLUMN IF NOT EXISTS code_type TEXT NOT NULL DEFAULT 'standard';
ALTER TABLE activation_codes ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;
ALTER TABLE activation_codes ADD COLUMN IF NOT EXISTS max_uses INT NOT NULL DEFAULT 1;
ALTER TABLE activation_codes ADD COLUMN IF NOT EXISTS use_count INT NOT NULL DEFAULT 0;
ALTER TABLE activation_codes ADD COLUMN IF NOT EXISTS redeemed_at TIMESTAMPTZ;
ALTER TABLE activation_codes ADD COLUMN IF NOT EXISTS redeemed_by TEXT;

ALTER TABLE activation_codes DROP CONSTRAINT IF EXISTS activation_codes_status_check;
ALTER TABLE activation_codes ADD CONSTRAINT activation_codes_status_check
  CHECK (status IN ('unused', 'used', 'disabled', 'expired'));

ALTER TABLE activation_codes DROP CONSTRAINT IF EXISTS activation_codes_code_type_check;
ALTER TABLE activation_codes ADD CONSTRAINT activation_codes_code_type_check
  CHECK (code_type IN ('standard', 'free'));

-- ============================================================
-- NEW TABLES
-- ============================================================

CREATE TABLE IF NOT EXISTS promotions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  start_at TIMESTAMPTZ NOT NULL,
  end_at TIMESTAMPTZ NOT NULL,
  bonus_type TEXT NOT NULL CHECK (bonus_type IN ('fixed', 'percentage')),
  bonus_amount DECIMAL(12, 4),
  bonus_percent DECIMAL(5, 2),
  eligibility TEXT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_by TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (end_at > start_at),
  CHECK (
    (bonus_type = 'fixed' AND bonus_amount IS NOT NULL AND bonus_amount > 0) OR
    (bonus_type = 'percentage' AND bonus_percent IS NOT NULL AND bonus_percent > 0)
  )
);

CREATE TABLE IF NOT EXISTS balance_adjustments (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  username TEXT NOT NULL,
  admin_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
  admin_username TEXT NOT NULL,
  amount DECIMAL(12, 4) NOT NULL,
  adjustment_type TEXT NOT NULL CHECK (adjustment_type IN ('add', 'deduct')),
  previous_balance DECIMAL(12, 4) NOT NULL,
  new_balance DECIMAL(12, 4) NOT NULL,
  reason TEXT NOT NULL,
  allow_negative BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS code_redemptions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  code_id TEXT NOT NULL REFERENCES activation_codes(code_id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  username TEXT NOT NULL,
  redemption_type TEXT NOT NULL CHECK (redemption_type IN ('standard', 'free_activation')),
  referred_by TEXT,
  referral_rewarded BOOLEAN NOT NULL DEFAULT FALSE,
  redeemed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Extend earnings types
ALTER TABLE earnings DROP CONSTRAINT IF EXISTS earnings_type_check;
ALTER TABLE earnings ADD CONSTRAINT earnings_type_check
  CHECK (type IN ('game', 'referral', 'adjustment', 'promotion'));

CREATE INDEX IF NOT EXISTS idx_promotions_dates ON promotions(start_at, end_at);
CREATE INDEX IF NOT EXISTS idx_balance_adj_user ON balance_adjustments(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_code_redemptions_code ON code_redemptions(code_id);
CREATE INDEX IF NOT EXISTS idx_activation_codes_type ON activation_codes(code_type);

-- ============================================================
-- PROMOTION STATUS HELPER
-- ============================================================

CREATE OR REPLACE FUNCTION promotion_status(p promotions)
RETURNS TEXT AS $$
BEGIN
  IF NOT p.is_active THEN RETURN 'deactivated'; END IF;
  IF NOW() < p.start_at THEN RETURN 'scheduled'; END IF;
  IF NOW() > p.end_at THEN RETURN 'expired'; END IF;
  RETURN 'active';
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================
-- PROMOTIONS RPCs
-- ============================================================

CREATE OR REPLACE FUNCTION get_active_promotions()
RETURNS SETOF promotions AS $$
  SELECT * FROM promotions
  WHERE is_active = TRUE
    AND start_at <= NOW()
    AND end_at >= NOW()
  ORDER BY start_at DESC;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION admin_get_promotions()
RETURNS JSON AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  RETURN (
    SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.created_at DESC), '[]'::json)
    FROM (
      SELECT p.*, promotion_status(p) AS computed_status
      FROM promotions p
    ) t
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_save_promotion(
  p_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_start_at TIMESTAMPTZ,
  p_end_at TIMESTAMPTZ,
  p_bonus_type TEXT,
  p_bonus_amount DECIMAL,
  p_bonus_percent DECIMAL,
  p_eligibility TEXT,
  p_is_active BOOLEAN DEFAULT TRUE
) RETURNS JSON AS $$
DECLARE v_admin TEXT;
  v_row promotions%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  IF p_end_at <= p_start_at THEN RAISE EXCEPTION 'End date must be after start date'; END IF;

  SELECT username INTO v_admin FROM profiles WHERE id = auth.uid();

  IF p_id IS NULL THEN
    INSERT INTO promotions (title, description, start_at, end_at, bonus_type, bonus_amount, bonus_percent, eligibility, is_active, created_by)
    VALUES (p_title, p_description, p_start_at, p_end_at, p_bonus_type, p_bonus_amount, p_bonus_percent, p_eligibility, COALESCE(p_is_active, TRUE), v_admin)
    RETURNING * INTO v_row;
    PERFORM log_admin_action('PROMOTION_CREATED', v_row.title);
  ELSE
    UPDATE promotions SET
      title = p_title, description = p_description,
      start_at = p_start_at, end_at = p_end_at,
      bonus_type = p_bonus_type, bonus_amount = p_bonus_amount,
      bonus_percent = p_bonus_percent, eligibility = p_eligibility,
      is_active = COALESCE(p_is_active, TRUE), updated_at = NOW()
    WHERE id = p_id RETURNING * INTO v_row;
    PERFORM log_admin_action('PROMOTION_UPDATED', v_row.title);
  END IF;

  RETURN json_build_object('promotion', row_to_json(v_row), 'status', promotion_status(v_row));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_toggle_promotion(p_id UUID, p_active BOOLEAN)
RETURNS VOID AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  UPDATE promotions SET is_active = p_active, updated_at = NOW() WHERE id = p_id;
  PERFORM log_admin_action(CASE WHEN p_active THEN 'PROMOTION_ACTIVATED' ELSE 'PROMOTION_DEACTIVATED' END, p_id::TEXT);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_delete_promotion(p_id UUID)
RETURNS VOID AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  DELETE FROM promotions WHERE id = p_id;
  PERFORM log_admin_action('PROMOTION_DELETED', p_id::TEXT);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- BALANCE ADJUSTMENT RPC
-- ============================================================

CREATE OR REPLACE FUNCTION admin_adjust_balance(
  p_user_id UUID,
  p_amount DECIMAL,
  p_adjustment_type TEXT,
  p_reason TEXT,
  p_allow_negative BOOLEAN DEFAULT FALSE
) RETURNS JSON AS $$
DECLARE
  v_user profiles%ROWTYPE;
  v_admin TEXT;
  v_admin_id UUID;
  v_prev DECIMAL(12,4);
  v_new DECIMAL(12,4);
  v_delta DECIMAL(12,4);
  v_adj balance_adjustments%ROWTYPE;
  v_msg TEXT;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  IF p_reason IS NULL OR trim(p_reason) = '' THEN RAISE EXCEPTION 'Reason is required'; END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
  IF p_adjustment_type NOT IN ('add', 'deduct') THEN RAISE EXCEPTION 'Invalid adjustment type'; END IF;

  SELECT * INTO v_user FROM profiles WHERE id = p_user_id AND role = 'user';
  IF NOT FOUND THEN RAISE EXCEPTION 'User not found'; END IF;

  v_admin_id := auth.uid();
  SELECT username INTO v_admin FROM profiles WHERE id = v_admin_id;
  v_prev := v_user.earnings + v_user.referral_earnings;
  v_delta := CASE WHEN p_adjustment_type = 'add' THEN p_amount ELSE -p_amount END;
  v_new := v_prev + v_delta;

  IF v_new < 0 AND NOT p_allow_negative THEN
    RAISE EXCEPTION 'Adjustment would result in negative balance';
  END IF;

  IF p_adjustment_type = 'add' THEN
    UPDATE profiles SET earnings = earnings + p_amount, updated_at = NOW() WHERE id = p_user_id RETURNING * INTO v_user;
  ELSE
    UPDATE profiles SET
      earnings = GREATEST(0, earnings - LEAST(earnings, p_amount)),
      referral_earnings = GREATEST(0, referral_earnings - GREATEST(0, p_amount - earnings)),
      updated_at = NOW()
    WHERE id = p_user_id RETURNING * INTO v_user;
    v_new := v_user.earnings + v_user.referral_earnings;
  END IF;

  INSERT INTO balance_adjustments (user_id, username, admin_id, admin_username, amount, adjustment_type, previous_balance, new_balance, reason, allow_negative)
  VALUES (p_user_id, v_user.username, v_admin_id, v_admin, p_amount, p_adjustment_type, v_prev, v_new, trim(p_reason), p_allow_negative)
  RETURNING * INTO v_adj;

  INSERT INTO earnings (user_id, username, amount, type, description)
  VALUES (p_user_id, v_user.username, v_delta, 'adjustment',
    CASE WHEN p_adjustment_type = 'add' THEN 'Balance added: ' ELSE 'Balance deducted: ' END || trim(p_reason));

  v_msg := 'Balance adjusted by admin. '
    || CASE WHEN p_adjustment_type = 'add' THEN '+' ELSE '-' END
    || '₱' || p_amount::TEXT
    || '. Previous: ₱' || v_prev::TEXT
    || ', New: ₱' || v_new::TEXT
    || '. Reason: ' || trim(p_reason);

  PERFORM add_notification(p_user_id, v_msg, CASE WHEN p_adjustment_type = 'add' THEN 'success' ELSE 'warning' END);
  PERFORM log_admin_action('BALANCE_ADJUSTED', v_user.username || ' ' || p_adjustment_type || ' ₱' || p_amount::TEXT || ' — ' || trim(p_reason));

  RETURN row_to_json(v_adj);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- FREE ACTIVATION CODES RPCs
-- ============================================================

CREATE OR REPLACE FUNCTION admin_generate_codes(p_count INT DEFAULT 1, p_code_type TEXT DEFAULT 'standard', p_expires_at TIMESTAMPTZ DEFAULT NULL, p_max_uses INT DEFAULT 1)
RETURNS JSON AS $$
DECLARE
  v_chars TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code TEXT;
  v_i INT; v_j INT; v_k INT; v_seg TEXT;
  v_inserted INT := 0;
  v_prefix TEXT;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  p_count := LEAST(GREATEST(p_count, 1), 50);
  IF p_code_type NOT IN ('standard', 'free') THEN RAISE EXCEPTION 'Invalid code type'; END IF;
  v_prefix := CASE WHEN p_code_type = 'free' THEN 'MBF' ELSE 'MB' END;

  FOR v_i IN 1..p_count LOOP
    v_code := v_prefix;
    FOR v_k IN 1..3 LOOP
      v_seg := '';
      FOR v_j IN 1..4 LOOP
        v_seg := v_seg || substr(v_chars, (floor(random() * length(v_chars)) + 1)::INT, 1);
      END LOOP;
      v_code := v_code || '-' || v_seg;
    END LOOP;

    BEGIN
      INSERT INTO activation_codes (code_id, code_type, expires_at, max_uses)
      VALUES (v_code, p_code_type, p_expires_at, GREATEST(p_max_uses, 1));
      v_inserted := v_inserted + 1;
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
  END LOOP;

  PERFORM log_admin_action('CODES_GENERATED', p_code_type || ' x' || v_inserted::TEXT);
  RETURN json_build_object('generated', v_inserted, 'code_type', p_code_type);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_create_code(
  p_code_id TEXT,
  p_code_type TEXT DEFAULT 'standard',
  p_expires_at TIMESTAMPTZ DEFAULT NULL,
  p_max_uses INT DEFAULT 1
) RETURNS JSON AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  IF p_code_type NOT IN ('standard', 'free') THEN RAISE EXCEPTION 'Invalid code type'; END IF;

  INSERT INTO activation_codes (code_id, code_type, expires_at, max_uses)
  VALUES (upper(trim(p_code_id)), p_code_type, p_expires_at, GREATEST(p_max_uses, 1));

  PERFORM log_admin_action('CODE_CREATED', upper(trim(p_code_id)) || ' (' || p_code_type || ')');
  RETURN json_build_object('code_id', upper(trim(p_code_id)));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- ADMIN QUERY RPCs
-- ============================================================

CREATE OR REPLACE FUNCTION admin_get_balance_adjustments(p_user_id UUID DEFAULT NULL)
RETURNS JSON AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  RETURN (
    SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.created_at DESC), '[]'::json)
    FROM (
      SELECT * FROM balance_adjustments
      WHERE p_user_id IS NULL OR user_id = p_user_id
      ORDER BY created_at DESC LIMIT 200
    ) t
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_get_audit_logs()
RETURNS JSON AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  RETURN (
    SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.created_at DESC), '[]'::json)
    FROM (SELECT * FROM admin_logs ORDER BY created_at DESC LIMIT 300) t
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_get_all_notifications()
RETURNS JSON AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  RETURN (
    SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.created_at DESC), '[]'::json)
    FROM (
      SELECT n.*, p.username
      FROM notifications n
      JOIN profiles p ON p.id = n.user_id
      ORDER BY n.created_at DESC LIMIT 200
    ) t
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RLS
-- ============================================================

ALTER TABLE promotions ENABLE ROW LEVEL SECURITY;
ALTER TABLE balance_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE code_redemptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone read active promotions" ON promotions FOR SELECT
  USING (is_active = TRUE AND start_at <= NOW() AND end_at >= NOW() OR is_admin());

CREATE POLICY "Admin manage promotions" ON promotions FOR ALL USING (is_admin());

CREATE POLICY "Users read own adjustments" ON balance_adjustments FOR SELECT
  USING (user_id = auth.uid() OR is_admin());

CREATE POLICY "Admin manage adjustments" ON balance_adjustments FOR ALL USING (is_admin());

CREATE POLICY "Admin read redemptions" ON code_redemptions FOR SELECT USING (is_admin());
CREATE POLICY "Users read own redemptions" ON code_redemptions FOR SELECT USING (user_id = auth.uid());

-- Realtime
ALTER PUBLICATION supabase_realtime ADD TABLE promotions;
ALTER PUBLICATION supabase_realtime ADD TABLE balance_adjustments;

-- Grants
GRANT EXECUTE ON FUNCTION get_active_promotions TO authenticated;
GRANT EXECUTE ON FUNCTION admin_get_promotions TO authenticated;
GRANT EXECUTE ON FUNCTION admin_save_promotion TO authenticated;
GRANT EXECUTE ON FUNCTION admin_toggle_promotion TO authenticated;
GRANT EXECUTE ON FUNCTION admin_delete_promotion TO authenticated;
GRANT EXECUTE ON FUNCTION admin_adjust_balance TO authenticated;
GRANT EXECUTE ON FUNCTION admin_create_code TO authenticated;
GRANT EXECUTE ON FUNCTION admin_get_balance_adjustments TO authenticated;
GRANT EXECUTE ON FUNCTION admin_get_audit_logs TO authenticated;
GRANT EXECUTE ON FUNCTION admin_get_all_notifications TO authenticated;
