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
  mention_name  text,
  slack_user_id text,
  sort_order    int NOT NULL DEFAULT 0,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX cleaning_staff_order_idx ON cleaning_staff (sort_order, created_at);

COMMENT ON TABLE cleaning_staff IS '掃除当番社員（sort_order が当番順・1番から）';
COMMENT ON COLUMN cleaning_staff.sort_order IS '当番順（0始まり。0=1番）';
COMMENT ON COLUMN cleaning_staff.mention_name IS 'Slack @用の表示名（未設定時は name を使用。例: 小笠原 将太）';
COMMENT ON COLUMN cleaning_staff.slack_user_id IS 'Slack メンバーID（U...）。設定すると通知でメンション色付き表示';
COMMENT ON COLUMN cleaning_staff.is_active IS 'true=当番対象、false=休み（掃除当番から除外）';

-- ============================================================
--  設定
-- ============================================================
CREATE TABLE cleaning_settings (
  id                    int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  rotation_start_date   date NOT NULL DEFAULT (timezone('Asia/Tokyo', now()))::date,
  slack_enabled         boolean NOT NULL DEFAULT false,
  slack_bot_token       text,
  slack_channel_id      text,
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

-- 祝日マスタ（日本の国民の祝日）
CREATE TABLE cleaning_holidays (
  holiday_date date PRIMARY KEY,
  name text NOT NULL
);

COMMENT ON TABLE cleaning_holidays IS '掃除当番の休日（国民の祝日）';

-- 2025〜2028 年（必要に応じて追加）
INSERT INTO cleaning_holidays (holiday_date, name) VALUES
  ('2025-01-01', '元日'), ('2025-01-13', '成人の日'), ('2025-02-11', '建国記念の日'),
  ('2025-02-23', '天皇誕生日'), ('2025-02-24', '振替休日'), ('2025-03-20', '春分の日'),
  ('2025-04-29', '昭和の日'), ('2025-05-03', '憲法記念日'), ('2025-05-04', 'みどりの日'),
  ('2025-05-05', 'こどもの日'), ('2025-05-06', '振替休日'), ('2025-07-21', '海の日'),
  ('2025-08-11', '山の日'), ('2025-09-15', '敬老の日'), ('2025-09-23', '秋分の日'),
  ('2025-10-13', 'スポーツの日'), ('2025-11-03', '文化の日'), ('2025-11-23', '勤労感謝の日'),
  ('2025-11-24', '振替休日'),
  ('2026-01-01', '元日'), ('2026-01-12', '成人の日'), ('2026-02-11', '建国記念の日'),
  ('2026-02-23', '天皇誕生日'), ('2026-03-20', '春分の日'), ('2026-04-29', '昭和の日'),
  ('2026-05-03', '憲法記念日'), ('2026-05-04', 'みどりの日'), ('2026-05-05', 'こどもの日'),
  ('2026-05-06', '振替休日'), ('2026-07-20', '海の日'), ('2026-08-11', '山の日'),
  ('2026-09-21', '敬老の日'), ('2026-09-22', '国民の休日'), ('2026-09-23', '秋分の日'),
  ('2026-10-12', 'スポーツの日'), ('2026-11-03', '文化の日'), ('2026-11-23', '勤労感謝の日'),
  ('2027-01-01', '元日'), ('2027-01-11', '成人の日'), ('2027-02-11', '建国記念の日'),
  ('2027-02-23', '天皇誕生日'), ('2027-03-21', '春分の日'), ('2027-04-29', '昭和の日'),
  ('2027-05-03', '憲法記念日'), ('2027-05-04', 'みどりの日'), ('2027-05-05', 'こどもの日'),
  ('2027-07-19', '海の日'), ('2027-08-11', '山の日'), ('2027-09-20', '敬老の日'),
  ('2027-09-23', '秋分の日'), ('2027-10-11', 'スポーツの日'), ('2027-11-03', '文化の日'),
  ('2027-11-23', '勤労感謝の日'),
  ('2028-01-01', '元日'), ('2028-01-10', '成人の日'), ('2028-02-11', '建国記念の日'),
  ('2028-02-23', '天皇誕生日'), ('2028-03-20', '春分の日'), ('2028-04-29', '昭和の日'),
  ('2028-05-03', '憲法記念日'), ('2028-05-04', 'みどりの日'), ('2028-05-05', 'こどもの日'),
  ('2028-07-17', '海の日'), ('2028-08-11', '山の日'), ('2028-09-18', '敬老の日'),
  ('2028-09-22', '秋分の日'), ('2028-10-09', 'スポーツの日'), ('2028-11-03', '文化の日'),
  ('2028-11-23', '勤労感謝の日')
ON CONFLICT (holiday_date) DO NOTHING;

CREATE OR REPLACE FUNCTION cleaning_is_workday(p_date date)
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT extract(isodow FROM p_date) NOT IN (6, 7)
    AND NOT EXISTS (SELECT 1 FROM cleaning_holidays h WHERE h.holiday_date = p_date);
$$;

CREATE OR REPLACE FUNCTION cleaning_next_workday(p_date date)
RETURNS date
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_d date := p_date + 1;
BEGIN
  WHILE NOT cleaning_is_workday(v_d) LOOP
    v_d := v_d + 1;
  END LOOP;
  RETURN v_d;
END;
$$;

CREATE OR REPLACE FUNCTION cleaning_workdays_since_anchor(p_date date DEFAULT cleaning_jst_today())
RETURNS int
LANGUAGE sql STABLE AS $$
  SELECT GREATEST(0, (
    SELECT count(*)::int
    FROM generate_series(
      (SELECT rotation_start_date FROM cleaning_settings WHERE id = 1),
      p_date,
      '1 day'::interval
    ) AS gs(d)
    WHERE cleaning_is_workday(gs.d::date)
  ) - 1);
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

-- Slack メンバーID（U...）を正規化（<@U...> や @U... も可）
CREATE OR REPLACE FUNCTION cleaning_normalize_slack_user_id(p_slack_user_id text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v text;
BEGIN
  IF p_slack_user_id IS NULL THEN RETURN NULL; END IF;
  v := trim(p_slack_user_id);
  IF v = '' THEN RETURN NULL; END IF;
  IF v ~ '^<@[^>]+>$' THEN
    v := regexp_replace(v, '^<@([^>]+)>$', '\1');
  END IF;
  IF left(v, 1) = '@' THEN
    v := substring(v from 2);
  END IF;
  v := trim(v);
  IF v ~* '^[UW][A-Z0-9]{8,}$' THEN RETURN v; END IF;
  RETURN NULL;
END;
$$;

-- 送信直前: @表示名 を DB の Slack ID で <@U...> に差し替え（青いメンション）
CREATE OR REPLACE FUNCTION cleaning_enrich_slack_mentions(p_message text)
RETURNS text
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  r record;
  v_id text;
  v_msg text;
BEGIN
  v_msg := coalesce(p_message, '');
  FOR r IN
    SELECT s.name, s.mention_name, s.slack_user_id
    FROM cleaning_staff s
    WHERE s.slack_user_id IS NOT NULL AND trim(s.slack_user_id) <> ''
  LOOP
    v_id := cleaning_normalize_slack_user_id(r.slack_user_id);
    IF v_id IS NULL THEN CONTINUE; END IF;
    IF r.name IS NOT NULL AND r.name <> '' THEN
      v_msg := replace(v_msg, '@' || r.name, '<@' || v_id || '>');
    END IF;
    IF r.mention_name IS NOT NULL AND r.mention_name <> '' AND r.mention_name <> r.name THEN
      v_msg := replace(v_msg, '@' || r.mention_name, '<@' || v_id || '>');
    END IF;
  END LOOP;
  RETURN v_msg;
END;
$$;

-- ゴミ担当行のみ @ メンション（🗑️ 今日・明日のゴミ捨て行）
CREATE OR REPLACE FUNCTION cleaning_slack_trash_mention(p_name text, p_slack_user_id text DEFAULT NULL)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN cleaning_normalize_slack_user_id(p_slack_user_id) IS NOT NULL THEN
      '<@' || cleaning_normalize_slack_user_id(p_slack_user_id) || '>'
    ELSE '@' || coalesce(nullif(trim(p_name), ''), '—')
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
  v_day_next int;
  v_next_workday date;
  v_tasks text[] := ARRAY['ゴミ捨て','トイレ','フロア','空気清浄機','給湯室'];
  v_emojis text[] := ARRAY['🗑️','🚽','🧹','💨','☕'];
  v_result jsonb := '[]'::jsonb;
  v_i int;
  v_idx int;
  v_idx_tomorrow int;
  v_name text;
  v_off_reason text;
BEGIN
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id, 'name', s.name,
    'mention_name', coalesce(s.mention_name, s.name),
    'slack_user_id', s.slack_user_id,
    'sort_order', s.sort_order
  ) ORDER BY s.sort_order, s.created_at), '[]'::jsonb)
  INTO v_staff
  FROM cleaning_staff s
  WHERE s.is_active = true;

  v_count := jsonb_array_length(v_staff);

  IF v_count = 0 THEN
    RETURN jsonb_build_object(
      'date', p_date,
      'is_off_day', false,
      'day_offset', 0,
      'staff_count', 0,
      'assignments', '[]'::jsonb,
      'trash_today', null,
      'trash_tomorrow', null
    );
  END IF;

  IF NOT cleaning_is_workday(p_date) THEN
    v_off_reason := CASE
      WHEN extract(isodow FROM p_date) IN (6, 7) THEN 'weekend'
      ELSE 'holiday'
    END;
    RETURN jsonb_build_object(
      'date', p_date,
      'is_off_day', true,
      'off_reason', v_off_reason,
      'day_offset', null,
      'staff_count', v_count,
      'assignments', '[]'::jsonb,
      'trash_today', null,
      'trash_tomorrow', null
    );
  END IF;

  v_day := cleaning_workdays_since_anchor(p_date);

  FOR v_i IN 0..4 LOOP
    v_idx := cleaning_assignee_index(v_day, v_i, v_count);
    v_name := v_staff->v_idx->>'name';
    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'task_index', v_i,
      'task', v_tasks[v_i + 1],
      'emoji', v_emojis[v_i + 1],
      'staff_id', v_staff->v_idx->>'id',
      'staff_name', v_name,
      'staff_mention', coalesce(v_staff->v_idx->>'mention_name', v_name),
      'staff_slack_user_id', v_staff->v_idx->>'slack_user_id',
      'sort_order', v_idx
    ));
  END LOOP;

  v_idx := cleaning_assignee_index(v_day, 0, v_count);
  v_next_workday := cleaning_next_workday(p_date);
  v_day_next := cleaning_workdays_since_anchor(v_next_workday);
  v_idx_tomorrow := cleaning_assignee_index(v_day_next, 0, v_count);
  RETURN jsonb_build_object(
    'date', p_date,
    'is_off_day', false,
    'day_offset', v_day,
    'staff_count', v_count,
    'assignments', v_result,
    'trash_today', jsonb_build_object(
      'staff_id', v_staff->v_idx->>'id',
      'staff_name', v_staff->v_idx->>'name',
      'staff_mention', coalesce(v_staff->v_idx->>'mention_name', v_staff->v_idx->>'name'),
      'staff_slack_user_id', v_staff->v_idx->>'slack_user_id',
      'sort_order', v_idx
    ),
    'trash_tomorrow', jsonb_build_object(
      'staff_id', v_staff->v_idx_tomorrow->>'id',
      'staff_name', v_staff->v_idx_tomorrow->>'name',
      'staff_mention', coalesce(v_staff->v_idx_tomorrow->>'mention_name', v_staff->v_idx_tomorrow->>'name'),
      'staff_slack_user_id', v_staff->v_idx_tomorrow->>'slack_user_id',
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
--  RPC: 祝日一覧
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_list_holidays()
RETURNS TABLE(holiday_date date, name text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT h.holiday_date, h.name FROM cleaning_holidays h ORDER BY h.holiday_date;
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
DROP FUNCTION IF EXISTS cleaning_list_staff();
CREATE OR REPLACE FUNCTION cleaning_list_staff()
RETURNS TABLE(id uuid, name text, mention_name text, slack_user_id text, sort_order int, is_active boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.id, s.name, s.mention_name, s.slack_user_id, s.sort_order, s.is_active
  FROM cleaning_staff s
  ORDER BY s.sort_order, s.created_at;
$$;

-- ============================================================
--  RPC: 社員追加
-- ============================================================
DROP FUNCTION IF EXISTS cleaning_add_staff(text, text, text);
DROP FUNCTION IF EXISTS cleaning_add_staff(text, text, text, text);
CREATE OR REPLACE FUNCTION cleaning_add_staff(
  p_password text,
  p_name text,
  p_mention_name text DEFAULT NULL,
  p_slack_user_id text DEFAULT NULL
)
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
  INSERT INTO cleaning_staff (name, mention_name, slack_user_id, sort_order)
  VALUES (
    trim(p_name),
    NULLIF(trim(coalesce(p_mention_name, '')), ''),
    cleaning_normalize_slack_user_id(p_slack_user_id),
    v_max
  )
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
--  RPC: 社員編集
-- ============================================================
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
    slack_user_id = cleaning_normalize_slack_user_id(p_slack_user_id),
    is_active = coalesce(p_is_active, is_active)
  WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '社員が見つかりません';
  END IF;
  RETURN true;
END;
$$;

-- ============================================================
--  RPC: 休み／復帰トグル
-- ============================================================
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
  slack_bot_token_masked text,
  slack_channel_id text,
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
    CASE WHEN s.slack_bot_token IS NULL OR length(s.slack_bot_token) < 8 THEN NULL
         ELSE '****' || right(s.slack_bot_token, 4) END,
    s.slack_channel_id,
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
  p_slack_bot_token text,
  p_slack_channel_id text,
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
    slack_bot_token = CASE
      WHEN p_slack_bot_token IS NULL OR trim(p_slack_bot_token) = '' THEN slack_bot_token
      WHEN p_slack_bot_token LIKE '****%' THEN slack_bot_token
      ELSE trim(p_slack_bot_token)
    END,
    slack_channel_id = CASE
      WHEN p_slack_channel_id IS NULL OR trim(p_slack_channel_id) = '' THEN slack_channel_id
      ELSE trim(p_slack_channel_id)
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
  v_trash_tomorrow_label text;
BEGIN
  v_sched := cleaning_schedule_for_date(p_date);

  IF coalesce(v_sched->>'is_off_day', 'false') = 'true' THEN
    RETURN '【本日掃除当番】本日は土日祝のため掃除当番はありません。';
  END IF;

  IF (v_sched->>'staff_count')::int = 0 THEN
    RETURN '【本日掃除当番】社員が登録されていません。';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_sched->'assignments')
  LOOP
    v_lines := v_lines || E'\n'
      || (v_item->>'staff_name') || 'さん  → 「' || (v_item->>'task') || '」';
  END LOOP;

  v_trash_today := cleaning_slack_trash_mention(
    v_sched->'trash_today'->>'staff_name',
    v_sched->'trash_today'->>'staff_slack_user_id'
  );
  v_trash_tomorrow := cleaning_slack_trash_mention(
    v_sched->'trash_tomorrow'->>'staff_name',
    v_sched->'trash_tomorrow'->>'staff_slack_user_id'
  );

  IF cleaning_is_workday(p_date + 1) THEN
    v_trash_tomorrow_label := '明日のゴミ捨て';
  ELSE
    v_trash_tomorrow_label := '次回営業日のゴミ捨て';
  END IF;

  RETURN '【本日掃除当番】' || v_lines || E'\n\n'
    || '🗑️ 今日のゴミ捨て: ' || v_trash_today || E'\n'
    || '🗑️ ' || v_trash_tomorrow_label || ': ' || v_trash_tomorrow || E'\n'
    || 'よろしくおねがいいたします。';
END;
$$;

-- ============================================================
--  Slack 送信（Bot Token + チャンネルID）
-- ============================================================
DROP FUNCTION IF EXISTS cleaning_send_slack(date);
CREATE OR REPLACE FUNCTION cleaning_send_slack(
  p_date date DEFAULT cleaning_jst_today(),
  p_message text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_token text;
  v_channel text;
  v_enabled boolean;
  v_msg text;
  v_resp extensions.http_response;
  v_body jsonb;
BEGIN
  SELECT slack_bot_token, slack_channel_id, slack_enabled
  INTO v_token, v_channel, v_enabled
  FROM cleaning_settings WHERE id = 1;

  IF NOT coalesce(v_enabled, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Slack通知が無効です');
  END IF;
  IF v_token IS NULL OR trim(v_token) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Bot Token が未設定です');
  END IF;
  IF trim(v_token) NOT LIKE 'xoxb-%' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Bot Token は xoxb- で始まる Bot User OAuth Token を設定してください');
  END IF;
  IF v_channel IS NULL OR trim(v_channel) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'チャンネルID が未設定です');
  END IF;

  IF NOT cleaning_is_workday(p_date) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'off_day');
  END IF;

  v_msg := cleaning_enrich_slack_mentions(
    coalesce(nullif(trim(p_message), ''), cleaning_build_slack_message(p_date))
  );

  SELECT * INTO v_resp FROM extensions.http((
    'POST', 'https://slack.com/api/chat.postMessage',
    ARRAY[
      extensions.http_header('Content-Type', 'application/json; charset=utf-8'),
      extensions.http_header('Authorization', 'Bearer ' || trim(v_token))
    ],
    'application/json',
    jsonb_build_object(
      'channel', trim(v_channel),
      'blocks', jsonb_build_array(jsonb_build_object(
        'type', 'section',
        'text', jsonb_build_object('type', 'mrkdwn', 'text', v_msg)
      )),
      'text', v_msg
    )::text
  )::extensions.http_request);

  v_body := coalesce(v_resp.content::jsonb, '{}'::jsonb);
  IF v_resp.status = 200 AND coalesce(v_body->>'ok', 'false') = 'true' THEN
    RETURN jsonb_build_object('ok', true, 'message', v_msg);
  END IF;
  RETURN jsonb_build_object(
    'ok', false,
    'error', coalesce(v_body->>'error', 'Slack HTTP ' || v_resp.status::text),
    'needed', v_body->>'needed',
    'body', v_resp.content
  );
END;
$$;

-- ============================================================
--  RPC: テスト送信（管理者）
-- ============================================================
DROP FUNCTION IF EXISTS cleaning_test_slack(text);
CREATE OR REPLACE FUNCTION cleaning_test_slack(
  p_password text,
  p_message text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  RETURN cleaning_send_slack(cleaning_jst_today(), p_message);
END;
$$;

-- ============================================================
--  権限
-- ============================================================
ALTER TABLE cleaning_staff DISABLE ROW LEVEL SECURITY;
ALTER TABLE cleaning_settings DISABLE ROW LEVEL SECURITY;

GRANT SELECT ON cleaning_staff TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_jst_today() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_is_workday(date) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_workdays_since_anchor(date) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_list_holidays() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_days_since_anchor(date) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_assignee_index(int, int, int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_schedule_for_date(date) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_build_slack_message(date) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_check_password(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_list_staff() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_enrich_slack_mentions(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_normalize_slack_user_id(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_slack_trash_mention(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_add_staff(text, text, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_update_staff(text, uuid, text, text, text, boolean) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_toggle_staff_leave(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_delete_staff(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_reorder_staff(text, uuid[]) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_get_settings() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_save_settings(text, date, boolean, text, text, int, boolean) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_change_password(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_test_slack(text) TO anon, authenticated;
