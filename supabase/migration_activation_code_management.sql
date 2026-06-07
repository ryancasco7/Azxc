-- Activation Code Management Enhancement
-- Run in Supabase SQL Editor after migration_admin_features.sql

-- Create a custom activation code with configurable uses, expiry, and status
CREATE OR REPLACE FUNCTION admin_create_code(
  p_code_id TEXT,
  p_code_type TEXT DEFAULT 'free',
  p_expires_at TIMESTAMPTZ DEFAULT NULL,
  p_max_uses INT DEFAULT 1,
  p_is_active BOOLEAN DEFAULT TRUE
) RETURNS JSON AS $$
DECLARE
  v_code TEXT;
  v_status TEXT;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  IF p_code_type NOT IN ('standard', 'free') THEN RAISE EXCEPTION 'Invalid code type'; END IF;

  v_code := upper(trim(p_code_id));
  IF v_code IS NULL OR v_code = '' THEN RAISE EXCEPTION 'Activation code is required'; END IF;
  IF length(v_code) < 3 OR length(v_code) > 50 THEN RAISE EXCEPTION 'Code must be 3–50 characters'; END IF;

  v_status := CASE WHEN COALESCE(p_is_active, TRUE) THEN 'unused' ELSE 'disabled' END;

  INSERT INTO activation_codes (code_id, code_type, expires_at, max_uses, status)
  VALUES (v_code, p_code_type, p_expires_at, GREATEST(p_max_uses, 1), v_status);

  PERFORM log_admin_action(
    'CODE_CREATED',
    v_code || ' (' || p_code_type || ', max:' || GREATEST(p_max_uses, 1)::TEXT || ')'
  );
  RETURN json_build_object('code_id', v_code);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Edit an existing activation code
CREATE OR REPLACE FUNCTION admin_update_code(
  p_code_id TEXT,
  p_max_uses INT DEFAULT NULL,
  p_expires_at TIMESTAMPTZ DEFAULT NULL,
  p_clear_expiry BOOLEAN DEFAULT FALSE,
  p_is_active BOOLEAN DEFAULT NULL
) RETURNS JSON AS $$
DECLARE
  v_code activation_codes%ROWTYPE;
  v_max_uses INT;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;

  SELECT * INTO v_code FROM activation_codes WHERE code_id = p_code_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Code not found'; END IF;

  IF v_code.status = 'used' OR v_code.use_count >= v_code.max_uses THEN
    RAISE EXCEPTION 'Cannot edit an exhausted code';
  END IF;

  v_max_uses := COALESCE(GREATEST(p_max_uses, v_code.use_count), v_code.max_uses);
  IF p_max_uses IS NOT NULL AND p_max_uses < v_code.use_count THEN
    RAISE EXCEPTION 'Max uses cannot be less than current use count (%)', v_code.use_count;
  END IF;

  UPDATE activation_codes SET
    max_uses = v_max_uses,
    expires_at = CASE
      WHEN p_clear_expiry THEN NULL
      WHEN p_expires_at IS NOT NULL THEN p_expires_at
      ELSE expires_at
    END,
    status = CASE
      WHEN p_is_active IS NOT NULL THEN
        CASE
          WHEN p_is_active = FALSE THEN 'disabled'
          WHEN v_code.use_count >= v_max_uses THEN 'used'
          ELSE 'unused'
        END
      ELSE status
    END
  WHERE code_id = p_code_id
  RETURNING * INTO v_code;

  PERFORM log_admin_action('CODE_UPDATED', p_code_id);
  RETURN row_to_json(v_code);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Deactivate a code (works on partially-used codes)
CREATE OR REPLACE FUNCTION admin_disable_code(p_code_id TEXT)
RETURNS VOID AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  UPDATE activation_codes SET status = 'disabled'
  WHERE code_id = p_code_id
    AND status NOT IN ('used', 'disabled')
    AND use_count < max_uses;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Code cannot be deactivated (not found, already inactive, or exhausted)';
  END IF;
  PERFORM log_admin_action('CODE_DISABLED', p_code_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Reactivate a disabled code that still has remaining uses
CREATE OR REPLACE FUNCTION admin_activate_code(p_code_id TEXT)
RETURNS VOID AS $$
DECLARE
  v_code activation_codes%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;

  SELECT * INTO v_code FROM activation_codes WHERE code_id = p_code_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Code not found'; END IF;
  IF v_code.status = 'used' OR v_code.use_count >= v_code.max_uses THEN
    RAISE EXCEPTION 'Exhausted codes cannot be reactivated';
  END IF;
  IF v_code.expires_at IS NOT NULL AND v_code.expires_at < NOW() THEN
    RAISE EXCEPTION 'Expired codes cannot be reactivated — update the expiration date first';
  END IF;

  UPDATE activation_codes SET status = 'unused' WHERE code_id = p_code_id;
  PERFORM log_admin_action('CODE_ACTIVATED', p_code_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Allow higher max_uses on bulk-generated codes
CREATE OR REPLACE FUNCTION admin_generate_codes(
  p_count INT DEFAULT 1,
  p_code_type TEXT DEFAULT 'standard',
  p_expires_at TIMESTAMPTZ DEFAULT NULL,
  p_max_uses INT DEFAULT 1
) RETURNS JSON AS $$
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
      VALUES (v_code, p_code_type, p_expires_at, GREATEST(LEAST(p_max_uses, 10000), 1));
      v_inserted := v_inserted + 1;
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
  END LOOP;

  PERFORM log_admin_action('CODES_GENERATED', p_code_type || ' x' || v_inserted::TEXT);
  RETURN json_build_object('generated', v_inserted, 'code_type', p_code_type);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION admin_update_code TO authenticated;
GRANT EXECUTE ON FUNCTION admin_activate_code TO authenticated;
