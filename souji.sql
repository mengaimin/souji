-- ============================================================
--  会社掃除当番システム  Supabase マイグレーション
--  SQL Editor で Run → index.html の Supabase URL / Key を設定
--  初期管理者パスワード: admin / Admin1234
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ============================================================
--  社員（当番順）
-- ============================================================
CREATE TABLE cleaning_staff (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  sort_order    int NOT NULL DEFAULT 0,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX cleaning_staff_order_idx ON cleaning_staff (sort_order, created_at);

COMMENT ON TABLE cleaning_staff IS '掃除当番社員（sort_order が当番順・1番から）';
COMMENT ON COLUMN cleaning_staff.sort_order IS '当番順（0始まり。0=1番）';

-- ============================================================
--  設定
-- ============================================================
CREATE TABLE cleaning_settings (
  id                    int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  rotation_start_date   date NOT NULL DEFAULT (timezone('Asia/Tokyo', now()))::date,
  slack_enabled         boolean NOT NULL DEFAULT false,
  slack_webhook_url     text,
  cron_hour_jst         int NOT NULL DEFAULT 9 CHECK (cron_hour_jst BETWEEN 0 AND 23),
  cron_enabled          boolean NOT NULL DEFAULT true,
  last_cron_run_at      timestamptz,
  admin_password_hash   text NOT NULL,
  updated_at            timestamptz NOT NULL DEFAULT now()
);

INSERT INTO cleaning_settings (id, admin_password_hash)
VALUES (1, extensions.crypt('Admin1234', extensions.gen_salt('bf')))
ON CONFLICT (id) DO NOTHING;

COMMENT ON TABLE cleaning_settings IS '掃除当番システム設定（1行のみ）';
COMMENT ON COLUMN cleaning_settings.rotation_start_date IS 'ローテーション起点日（この日に1番がゴミ捨て）';

-- ============================================================
--  日付ヘルパー
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_jst_today() RETURNS date
LANGUAGE sql STABLE AS $$
  SELECT (timezone('Asia/Tokyo', now()))::date;
$$;

CREATE OR REPLACE FUNCTION cleaning_days_since_anchor(p_date date DEFAULT cleaning_jst_today())
RETURNS int
LANGUAGE sql STABLE AS $$
  SELECT (p_date - (SELECT rotation_start_date FROM cleaning_settings WHERE id = 1))::int;
$$;

-- タスク t (0=ゴミ,1=トイレ,2=フロア,3=空気清浄機,4=給湯室) の担当者 index
CREATE OR REPLACE FUNCTION cleaning_assignee_index(
  p_day_offset int,
  p_task_index int,
  p_staff_count int
) RETURNS int
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_staff_count <= 0 THEN NULL
    ELSE ((p_day_offset - p_task_index) % p_staff_count + p_staff_count) % p_staff_count
  END;
$$;

-- ============================================================
--  指定日の当番表（JSON）
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_schedule_for_date(p_date date DEFAULT cleaning_jst_today())
RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_staff jsonb;
  v_count int;
  v_day int;
  v_tasks text[] := ARRAY['ゴミ捨て','トイレ','フロア','空気清浄機','給湯室'];
  v_emojis text[] := ARRAY['🗑️','🚽','🧹','💨','☕'];
  v_result jsonb := '[]'::jsonb;
  v_i int;
  v_idx int;
  v_idx_tomorrow int;
  v_name text;
BEGIN
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id, 'name', s.name, 'sort_order', s.sort_order
  ) ORDER BY s.sort_order, s.created_at), '[]'::jsonb)
  INTO v_staff
  FROM cleaning_staff s
  WHERE s.is_active = true;

  v_count := jsonb_array_length(v_staff);
  v_day := cleaning_days_since_anchor(p_date);

  IF v_count = 0 THEN
    RETURN jsonb_build_object(
      'date', p_date,
      'day_offset', v_day,
      'staff_count', 0,
      'assignments', '[]'::jsonb,
      'trash_today', null,
      'trash_tomorrow', null
    );
  END IF;

  FOR v_i IN 0..4 LOOP
    v_idx := cleaning_assignee_index(v_day, v_i, v_count);
    v_name := v_staff->v_idx->>'name';
    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'task_index', v_i,
      'task', v_tasks[v_i + 1],
      'emoji', v_emojis[v_i + 1],
      'staff_id', v_staff->v_idx->>'id',
      'staff_name', v_name,
      'sort_order', v_idx
    ));
  END LOOP;

  v_idx := cleaning_assignee_index(v_day, 0, v_count);
  v_idx_tomorrow := cleaning_assignee_index(v_day + 1, 0, v_count);
  RETURN jsonb_build_object(
    'date', p_date,
    'day_offset', v_day,
    'staff_count', v_count,
    'assignments', v_result,
    'trash_today', jsonb_build_object(
      'staff_id', v_staff->v_idx->>'id',
      'staff_name', v_staff->v_idx->>'name',
      'sort_order', v_idx
    ),
    'trash_tomorrow', jsonb_build_object(
      'staff_id', v_staff->v_idx_tomorrow->>'id',
      'staff_name', v_staff->v_idx_tomorrow->>'name',
      'sort_order', v_idx_tomorrow
    )
  );
END;
$$;

-- ============================================================
--  認証ヘルパー
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_verify_admin(p_password text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM cleaning_settings
    WHERE id = 1
      AND admin_password_hash = extensions.crypt(p_password, admin_password_hash)
  );
$$;

-- ============================================================
--  RPC: ログイン確認
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_check_password(p_password text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  RETURN cleaning_verify_admin(p_password);
END;
$$;

-- ============================================================
--  RPC: 社員一覧
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_list_staff()
RETURNS TABLE(id uuid, name text, sort_order int, is_active boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.id, s.name, s.sort_order, s.is_active
  FROM cleaning_staff s
  ORDER BY s.sort_order, s.created_at;
$$;

-- ============================================================
--  RPC: 社員追加
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_add_staff(p_password text, p_name text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_max int;
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  IF trim(p_name) = '' THEN
    RAISE EXCEPTION '名前を入力してください';
  END IF;
  SELECT coalesce(max(sort_order), -1) + 1 INTO v_max FROM cleaning_staff;
  INSERT INTO cleaning_staff (name, sort_order)
  VALUES (trim(p_name), v_max)
  RETURNING cleaning_staff.id INTO v_id;
  RETURN v_id;
END;
$$;

-- ============================================================
--  RPC: 社員削除
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_delete_staff(p_password text, p_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  DELETE FROM cleaning_staff WHERE id = p_id;
  -- sort_order を詰め直す
  WITH ranked AS (
    SELECT id, row_number() OVER (ORDER BY sort_order, created_at) - 1 AS new_order
    FROM cleaning_staff
  )
  UPDATE cleaning_staff s SET sort_order = r.new_order
  FROM ranked r WHERE s.id = r.id;
  RETURN FOUND;
END;
$$;

-- ============================================================
--  RPC: 順番入れ替え（id の配列順が新しい当番順）
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_reorder_staff(p_password text, p_ids uuid[])
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_i int;
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  FOR v_i IN 1..coalesce(array_length(p_ids, 1), 0) LOOP
    UPDATE cleaning_staff SET sort_order = v_i - 1 WHERE id = p_ids[v_i];
  END LOOP;
  RETURN true;
END;
$$;

-- ============================================================
--  RPC: 設定取得
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_get_settings()
RETURNS TABLE(
  rotation_start_date date,
  slack_enabled boolean,
  slack_webhook_masked text,
  cron_hour_jst int,
  cron_enabled boolean,
  last_cron_run_at timestamptz,
  updated_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    s.rotation_start_date,
    s.slack_enabled,
    CASE WHEN s.slack_webhook_url IS NULL OR length(s.slack_webhook_url) < 8 THEN NULL
         ELSE '****' || right(s.slack_webhook_url, 4) END,
    s.cron_hour_jst,
    s.cron_enabled,
    s.last_cron_run_at,
    s.updated_at
  FROM cleaning_settings s WHERE s.id = 1;
$$;

-- ============================================================
--  RPC: 設定保存
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_save_settings(
  p_password text,
  p_rotation_start_date date,
  p_slack_enabled boolean,
  p_slack_webhook_url text,
  p_cron_hour_jst int,
  p_cron_enabled boolean DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  UPDATE cleaning_settings SET
    rotation_start_date = coalesce(p_rotation_start_date, rotation_start_date),
    slack_enabled = coalesce(p_slack_enabled, slack_enabled),
    slack_webhook_url = CASE
      WHEN p_slack_webhook_url IS NULL OR trim(p_slack_webhook_url) = '' THEN slack_webhook_url
      WHEN p_slack_webhook_url LIKE '****%' THEN slack_webhook_url
      ELSE trim(p_slack_webhook_url)
    END,
    cron_hour_jst = coalesce(p_cron_hour_jst, cron_hour_jst),
    cron_enabled = coalesce(p_cron_enabled, cron_enabled),
    updated_at = now()
  WHERE id = 1;
  RETURN true;
END;
$$;

-- ============================================================
--  RPC: パスワード変更
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_change_password(
  p_current_password text,
  p_new_password text
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT cleaning_verify_admin(p_current_password) THEN
    RAISE EXCEPTION '現在のパスワードが正しくありません';
  END IF;
  IF length(p_new_password) < 8 THEN
    RAISE EXCEPTION '新しいパスワードは8文字以上にしてください';
  END IF;
  UPDATE cleaning_settings SET
    admin_password_hash = extensions.crypt(p_new_password, extensions.gen_salt('bf')),
    updated_at = now()
  WHERE id = 1;
  RETURN true;
END;
$$;

-- ============================================================
--  Slack メッセージ生成
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_build_slack_message(p_date date DEFAULT cleaning_jst_today())
RETURNS text
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_sched jsonb;
  v_lines text := '';
  v_item jsonb;
  v_trash_today text;
  v_trash_tomorrow text;
BEGIN
  v_sched := cleaning_schedule_for_date(p_date);
  IF (v_sched->>'staff_count')::int = 0 THEN
    RETURN '【掃除当番】社員が登録されていません。';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_sched->'assignments')
  LOOP
    v_lines := v_lines || E'\n' || (v_item->>'emoji') || ' ' || (v_item->>'task')
      || ': ' || (v_item->>'staff_name');
  END LOOP;

  v_trash_today := v_sched->'trash_today'->>'staff_name';
  v_trash_tomorrow := v_sched->'trash_tomorrow'->>'staff_name';

  RETURN '【掃除当番】' || to_char(p_date, 'YYYY/MM/DD') || E'\n\n'
    || '■ 今日の五つの掃除担当' || v_lines || E'\n\n'
    || '■ 今日のゴミ捨て担当: ' || v_trash_today || E'\n'
    || '■ 明日のゴミ回収: ' || v_trash_tomorrow || E'\n\n'
    || 'よろしくお願いいたします。';
END;
$$;

-- ============================================================
--  Slack 送信（Webhook）
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_send_slack(p_date date DEFAULT cleaning_jst_today())
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_url text;
  v_enabled boolean;
  v_msg text;
  v_resp extensions.http_response;
BEGIN
  SELECT slack_webhook_url, slack_enabled INTO v_url, v_enabled
  FROM cleaning_settings WHERE id = 1;

  IF NOT coalesce(v_enabled, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Slack通知が無効です');
  END IF;
  IF v_url IS NULL OR trim(v_url) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Webhook URL が未設定です');
  END IF;

  v_msg := cleaning_build_slack_message(p_date);

  SELECT * INTO v_resp FROM extensions.http((
    'POST', v_url,
    ARRAY[extensions.http_header('Content-Type', 'application/json')],
    'application/json',
    jsonb_build_object('text', v_msg)::text
  )::extensions.http_request);

  IF v_resp.status BETWEEN 200 AND 299 THEN
    RETURN jsonb_build_object('ok', true, 'message', v_msg);
  END IF;
  RETURN jsonb_build_object('ok', false, 'error', 'Slack HTTP ' || v_resp.status::text, 'body', v_resp.content);
END;
$$;

-- ============================================================
--  RPC: テスト送信（管理者）
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_test_slack(p_password text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  RETURN cleaning_send_slack(cleaning_jst_today());
END;
$$;

-- ============================================================
--  権限
-- ============================================================
ALTER TABLE cleaning_staff DISABLE ROW LEVEL SECURITY;
ALTER TABLE cleaning_settings DISABLE ROW LEVEL SECURITY;

GRANT SELECT ON cleaning_staff TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_jst_today() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_days_since_anchor(date) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_assignee_index(int, int, int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_schedule_for_date(date) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_build_slack_message(date) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_check_password(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_list_staff() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_add_staff(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_delete_staff(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_reorder_staff(text, uuid[]) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_get_settings() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_save_settings(text, date, boolean, text, int, boolean) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_change_password(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_test_slack(text) TO anon, authenticated;
