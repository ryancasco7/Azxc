-- Authorized Code Resellers Migration
-- Run in Supabase SQL Editor after prior migrations

-- ============================================================
-- TABLES
-- ============================================================

CREATE TABLE IF NOT EXISTS resellers (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  full_name TEXT NOT NULL,
  facebook_link TEXT NOT NULL,
  contact_number TEXT NOT NULL,
  location TEXT,
  profile_picture_url TEXT,
  notes TEXT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  codes_assigned INT NOT NULL DEFAULT 0,
  codes_used INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (codes_assigned >= 0),
  CHECK (codes_used >= 0),
  CHECK (codes_used <= codes_assigned)
);

CREATE TABLE IF NOT EXISTS reseller_allocation_history (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  reseller_id UUID NOT NULL REFERENCES resellers(id) ON DELETE CASCADE,
  action_type TEXT NOT NULL CHECK (action_type IN ('assign_add', 'assign_reduce', 'mark_sold')),
  amount INT NOT NULL CHECK (amount > 0),
  assigned_before INT NOT NULL,
  assigned_after INT NOT NULL,
  used_before INT NOT NULL,
  used_after INT NOT NULL,
  admin_username TEXT NOT NULL,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_resellers_active ON resellers(is_active);
CREATE INDEX IF NOT EXISTS idx_reseller_history_reseller ON reseller_allocation_history(reseller_id, created_at DESC);

-- ============================================================
-- PUBLIC: active resellers for users
-- ============================================================

CREATE OR REPLACE FUNCTION get_active_resellers()
RETURNS JSON AS $$
  SELECT COALESCE(json_agg(row_to_json(t) ORDER BY (t.codes_assigned - t.codes_used) DESC, t.full_name ASC), '[]'::json)
  FROM (
    SELECT
      id,
      full_name,
      facebook_link,
      contact_number,
      location,
      profile_picture_url,
      codes_assigned,
      codes_used,
      (codes_assigned - codes_used) AS codes_available,
      CASE
        WHEN (codes_assigned - codes_used) > 0 THEN 'Available'
        ELSE 'Out of Stock'
      END AS stock_status
    FROM resellers
    WHERE is_active = TRUE
  ) t;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- ============================================================
-- ADMIN RPCs
-- ============================================================

CREATE OR REPLACE FUNCTION admin_get_resellers()
RETURNS JSON AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  RETURN (
    SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.created_at DESC), '[]'::json)
    FROM (
      SELECT
        r.*,
        (r.codes_assigned - r.codes_used) AS codes_available,
        CASE
          WHEN NOT r.is_active THEN 'Inactive'
          WHEN (r.codes_assigned - r.codes_used) <= 0 THEN 'Out of Stock'
          ELSE 'Available'
        END AS stock_status
      FROM resellers r
    ) t
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_save_reseller(
  p_id UUID,
  p_full_name TEXT,
  p_facebook_link TEXT,
  p_contact_number TEXT,
  p_location TEXT DEFAULT NULL,
  p_profile_picture_url TEXT DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT TRUE
) RETURNS JSON AS $$
DECLARE
  v_row resellers%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  IF p_full_name IS NULL OR trim(p_full_name) = '' THEN RAISE EXCEPTION 'Full name is required'; END IF;
  IF p_facebook_link IS NULL OR trim(p_facebook_link) = '' THEN RAISE EXCEPTION 'Facebook link is required'; END IF;
  IF p_contact_number IS NULL OR trim(p_contact_number) = '' THEN RAISE EXCEPTION 'Contact number is required'; END IF;

  IF p_id IS NULL THEN
    INSERT INTO resellers (
      full_name, facebook_link, contact_number, location,
      profile_picture_url, notes, is_active
    ) VALUES (
      trim(p_full_name), trim(p_facebook_link), trim(p_contact_number), NULLIF(trim(p_location), ''),
      NULLIF(trim(p_profile_picture_url), ''), NULLIF(trim(p_notes), ''), COALESCE(p_is_active, TRUE)
    ) RETURNING * INTO v_row;
    PERFORM log_admin_action('RESELLER_CREATED', v_row.full_name);
  ELSE
    UPDATE resellers SET
      full_name = trim(p_full_name),
      facebook_link = trim(p_facebook_link),
      contact_number = trim(p_contact_number),
      location = NULLIF(trim(p_location), ''),
      profile_picture_url = NULLIF(trim(p_profile_picture_url), ''),
      notes = NULLIF(trim(p_notes), ''),
      is_active = COALESCE(p_is_active, TRUE),
      updated_at = NOW()
    WHERE id = p_id RETURNING * INTO v_row;
    IF NOT FOUND THEN RAISE EXCEPTION 'Reseller not found'; END IF;
    PERFORM log_admin_action('RESELLER_UPDATED', v_row.full_name);
  END IF;

  RETURN row_to_json(v_row);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_toggle_reseller(p_id UUID, p_active BOOLEAN)
RETURNS VOID AS $$
DECLARE v_name TEXT;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  UPDATE resellers SET is_active = p_active, updated_at = NOW()
  WHERE id = p_id RETURNING full_name INTO v_name;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reseller not found'; END IF;
  PERFORM log_admin_action(
    CASE WHEN p_active THEN 'RESELLER_ACTIVATED' ELSE 'RESELLER_DEACTIVATED' END,
    v_name
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_delete_reseller(p_id UUID)
RETURNS VOID AS $$
DECLARE v_name TEXT;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT full_name INTO v_name FROM resellers WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reseller not found'; END IF;
  DELETE FROM resellers WHERE id = p_id;
  PERFORM log_admin_action('RESELLER_DELETED', v_name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_adjust_reseller_codes(
  p_reseller_id UUID,
  p_action_type TEXT,
  p_amount INT,
  p_notes TEXT DEFAULT NULL
) RETURNS JSON AS $$
DECLARE
  v_reseller resellers%ROWTYPE;
  v_admin TEXT;
  v_assigned_before INT;
  v_used_before INT;
  v_assigned_after INT;
  v_used_after INT;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
  IF p_action_type NOT IN ('assign_add', 'assign_reduce', 'mark_sold') THEN
    RAISE EXCEPTION 'Invalid action type';
  END IF;

  SELECT username INTO v_admin FROM profiles WHERE id = auth.uid();
  SELECT * INTO v_reseller FROM resellers WHERE id = p_reseller_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reseller not found'; END IF;

  v_assigned_before := v_reseller.codes_assigned;
  v_used_before := v_reseller.codes_used;
  v_assigned_after := v_assigned_before;
  v_used_after := v_used_before;

  IF p_action_type = 'assign_add' THEN
    v_assigned_after := v_assigned_before + p_amount;
  ELSIF p_action_type = 'assign_reduce' THEN
    IF (v_assigned_before - p_amount) < v_used_before THEN
      RAISE EXCEPTION 'Cannot reduce below used codes (%)', v_used_before;
    END IF;
    v_assigned_after := v_assigned_before - p_amount;
  ELSIF p_action_type = 'mark_sold' THEN
    IF (v_used_before + p_amount) > v_assigned_before THEN
      RAISE EXCEPTION 'Not enough available codes';
    END IF;
    v_used_after := v_used_before + p_amount;
  END IF;

  UPDATE resellers SET
    codes_assigned = v_assigned_after,
    codes_used = v_used_after,
    updated_at = NOW()
  WHERE id = p_reseller_id
  RETURNING * INTO v_reseller;

  INSERT INTO reseller_allocation_history (
    reseller_id, action_type, amount,
    assigned_before, assigned_after, used_before, used_after,
    admin_username, notes
  ) VALUES (
    p_reseller_id, p_action_type, p_amount,
    v_assigned_before, v_assigned_after, v_used_before, v_used_after,
    v_admin, NULLIF(trim(p_notes), '')
  );

  PERFORM log_admin_action(
    'RESELLER_CODES_' || upper(p_action_type),
    v_reseller.full_name || ' +' || p_amount::TEXT || ' (assigned:' || v_assigned_after::TEXT || ', used:' || v_used_after::TEXT || ')'
  );

  RETURN json_build_object(
    'reseller', row_to_json(v_reseller),
    'codes_available', v_reseller.codes_assigned - v_reseller.codes_used
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_get_reseller_history(p_reseller_id UUID)
RETURNS JSON AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  RETURN (
    SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.created_at DESC), '[]'::json)
    FROM (
      SELECT h.*, r.full_name AS reseller_name
      FROM reseller_allocation_history h
      JOIN resellers r ON r.id = h.reseller_id
      WHERE h.reseller_id = p_reseller_id
      ORDER BY h.created_at DESC
      LIMIT 100
    ) t
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RLS
-- ============================================================

ALTER TABLE resellers ENABLE ROW LEVEL SECURITY;
ALTER TABLE reseller_allocation_history ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated read active resellers" ON resellers FOR SELECT
  USING (is_active = TRUE OR is_admin());

CREATE POLICY "Admin manage resellers" ON resellers FOR ALL USING (is_admin());

CREATE POLICY "Admin read reseller history" ON reseller_allocation_history FOR SELECT
  USING (is_admin());

CREATE POLICY "Admin manage reseller history" ON reseller_allocation_history FOR ALL
  USING (is_admin());

ALTER PUBLICATION supabase_realtime ADD TABLE resellers;

GRANT EXECUTE ON FUNCTION get_active_resellers TO authenticated;
GRANT EXECUTE ON FUNCTION get_active_resellers TO anon;
GRANT EXECUTE ON FUNCTION admin_get_resellers TO authenticated;
GRANT EXECUTE ON FUNCTION admin_save_reseller TO authenticated;
GRANT EXECUTE ON FUNCTION admin_toggle_reseller TO authenticated;
GRANT EXECUTE ON FUNCTION admin_delete_reseller TO authenticated;
GRANT EXECUTE ON FUNCTION admin_adjust_reseller_codes TO authenticated;
GRANT EXECUTE ON FUNCTION admin_get_reseller_history TO authenticated;
