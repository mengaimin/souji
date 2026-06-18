-- 社員編集機能パッチ（Supabase SQL Editor で Run）

CREATE OR REPLACE FUNCTION cleaning_update_staff(
  p_password text,
  p_id uuid,
  p_name text,
  p_mention_name text DEFAULT NULL
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
    mention_name = NULLIF(trim(coalesce(p_mention_name, '')), '')
  WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '社員が見つかりません';
  END IF;
  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION cleaning_update_staff(text, uuid, text, text) TO anon, authenticated;
