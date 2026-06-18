-- 休み状態・当番除外（Supabase SQL Editor で Run）

DROP FUNCTION IF EXISTS cleaning_update_staff(text, uuid, text, text);
DROP FUNCTION IF EXISTS cleaning_update_staff(text, uuid, text, text, text);
DROP FUNCTION IF EXISTS cleaning_update_staff(text, uuid, text, text, text, boolean);
CREATE OR REPLACE FUNCTION cleaning_update_staff(
  p_password text,
  p_id uuid,
  p_name text,
  p_mention_name text DEFAULT NULL,
  p_slack_user_id text DEFAULT NULL,
  p_is_active boolean DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  IF trim(p_name) = '' THEN
    RAISE EXCEPTION '名前を入力してください';
  END IF;
  UPDATE cleaning_staff SET
    name = trim(p_name),
    mention_name = NULLIF(trim(coalesce(p_mention_name, '')), ''),
    slack_user_id = NULLIF(trim(coalesce(p_slack_user_id, '')), ''),
    is_active = coalesce(p_is_active, is_active)
  WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '社員が見つかりません';
  END IF;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION cleaning_toggle_staff_leave(p_password text, p_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  UPDATE cleaning_staff SET
    is_active = NOT coalesce(is_active, true)
  WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '社員が見つかりません';
  END IF;
  RETURN true;
END;
$$;

COMMENT ON COLUMN cleaning_staff.is_active IS 'true=当番対象、false=休み（掃除当番から除外）';

GRANT EXECUTE ON FUNCTION cleaning_update_staff(text, uuid, text, text, text, boolean) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_toggle_staff_leave(text, uuid) TO anon, authenticated;
