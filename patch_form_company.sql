-- Google フォーム連携: 会社マスタ・申請登録・会社自動作成
-- Supabase SQL Editor で Run

-- ============================================================
--  会社マスタ（会社ごとの当番・Slack 設定）
-- ============================================================
CREATE TABLE IF NOT EXISTS cleaning_companies (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                  text NOT NULL,
  name_normalized       text NOT NULL UNIQUE,
  contact_person        text,
  contact_email         text,
  contact_phone         text,
  address               text,
  department            text,
  notes                 text,
  rotation_start_date   date NOT NULL DEFAULT (timezone('Asia/Tokyo', now()))::date,
  slack_enabled         boolean NOT NULL DEFAULT false,
  slack_bot_token       text,
  slack_channel_id      text,
  cron_hour_jst         int NOT NULL DEFAULT 9 CHECK (cron_hour_jst BETWEEN 0 AND 23),
  cron_enabled          boolean NOT NULL DEFAULT true,
  last_cron_run_at      timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE cleaning_companies IS '会社（フォーム回答から自動登録可）';

-- ============================================================
--  申請書（Google フォーム回答の保存）
-- ============================================================
CREATE TABLE IF NOT EXISTS cleaning_applications (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id        uuid NOT NULL REFERENCES cleaning_companies(id) ON DELETE CASCADE,
  staff_id          uuid REFERENCES cleaning_staff(id) ON DELETE SET NULL,
  staff_name        text NOT NULL,
  staff_email       text,
  staff_department  text,
  mention_name      text,
  slack_user_id     text,
  notes             text,
  source            text NOT NULL DEFAULT 'google_form',
  raw_payload       jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS cleaning_applications_company_idx ON cleaning_applications (company_id, created_at DESC);

-- ============================================================
--  既存テーブル拡張
-- ============================================================
ALTER TABLE cleaning_staff
  ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES cleaning_companies(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS email text,
  ADD COLUMN IF NOT EXISTS department text;

ALTER TABLE cleaning_settings
  ADD COLUMN IF NOT EXISTS active_company_id uuid REFERENCES cleaning_companies(id),
  ADD COLUMN IF NOT EXISTS form_secret_hash text;

-- 既存データを既定会社へ移行
DO $$
DECLARE
  v_default_id uuid;
  v_rotation date;
  v_slack_enabled boolean;
  v_slack_bot text;
  v_slack_channel text;
  v_cron_hour int;
  v_cron_enabled boolean;
  v_last_cron timestamptz;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cleaning_companies LIMIT 1) THEN
    SELECT rotation_start_date, slack_enabled, slack_bot_token, slack_channel_id,
           cron_hour_jst, cron_enabled, last_cron_run_at
    INTO v_rotation, v_slack_enabled, v_slack_bot, v_slack_channel,
         v_cron_hour, v_cron_enabled, v_last_cron
    FROM cleaning_settings WHERE id = 1;

    INSERT INTO cleaning_companies (
      name, name_normalized, rotation_start_date,
      slack_enabled, slack_bot_token, slack_channel_id,
      cron_hour_jst, cron_enabled, last_cron_run_at
    ) VALUES (
      '既定の会社', '既定の会社',
      coalesce(v_rotation, (timezone('Asia/Tokyo', now()))::date),
      coalesce(v_slack_enabled, false), v_slack_bot, v_slack_channel,
      coalesce(v_cron_hour, 9), coalesce(v_cron_enabled, true), v_last_cron
    )
    RETURNING id INTO v_default_id;

    UPDATE cleaning_staff SET company_id = v_default_id WHERE company_id IS NULL;
    UPDATE cleaning_settings SET active_company_id = v_default_id WHERE id = 1;
  END IF;
END $$;

-- ============================================================
--  ヘルパー
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_normalize_key(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT regexp_replace(trim(coalesce(p_text, '')), '\s+', '', 'g');
$$;

CREATE OR REPLACE FUNCTION cleaning_active_company_id()
RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    (SELECT active_company_id FROM cleaning_settings WHERE id = 1),
    (SELECT id FROM cleaning_companies ORDER BY created_at LIMIT 1)
  );
$$;

CREATE OR REPLACE FUNCTION cleaning_verify_form_secret(p_secret text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM cleaning_settings
    WHERE id = 1
      AND form_secret_hash IS NOT NULL
      AND form_secret_hash = extensions.crypt(p_secret, form_secret_hash)
  );
$$;

CREATE OR REPLACE FUNCTION cleaning_json_text(p_payload jsonb, p_keys text[])
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_key text;
  v_val text;
BEGIN
  FOREACH v_key IN ARRAY p_keys LOOP
    v_val := nullif(trim(p_payload->>v_key), '');
    IF v_val IS NOT NULL THEN
      RETURN v_val;
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION cleaning_find_or_create_company(p_payload jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_name text;
  v_key text;
  v_id uuid;
  v_created boolean := false;
BEGIN
  v_name := cleaning_json_text(p_payload, ARRAY[
    'company_name', '会社名', 'companyName'
  ]);
  IF v_name IS NULL OR v_name = '' THEN
    RAISE EXCEPTION '会社名が必要です';
  END IF;

  v_key := cleaning_normalize_key(v_name);
  SELECT id INTO v_id FROM cleaning_companies WHERE name_normalized = v_key;

  IF v_id IS NULL THEN
    INSERT INTO cleaning_companies (name, name_normalized)
    VALUES (v_name, v_key)
    RETURNING id INTO v_id;
    v_created := true;
  END IF;

  UPDATE cleaning_companies SET
    contact_person = coalesce(
      nullif(trim(cleaning_json_text(p_payload, ARRAY['company_contact_person', '会社担当者名', 'contact_person'])), ''),
      contact_person
    ),
    contact_email = coalesce(
      nullif(trim(cleaning_json_text(p_payload, ARRAY['company_contact_email', '会社メールアドレス', 'company_email'])), ''),
      contact_email
    ),
    contact_phone = coalesce(
      nullif(trim(cleaning_json_text(p_payload, ARRAY['company_contact_phone', '会社電話番号', 'company_phone'])), ''),
      contact_phone
    ),
    address = coalesce(
      nullif(trim(cleaning_json_text(p_payload, ARRAY['company_address', '会社住所', 'address'])), ''),
      address
    ),
    department = coalesce(
      nullif(trim(cleaning_json_text(p_payload, ARRAY['company_department', '会社部署'])), ''),
      department
    ),
    notes = coalesce(
      nullif(trim(cleaning_json_text(p_payload, ARRAY['company_notes', '会社備考'])), ''),
      notes
    ),
    slack_channel_id = coalesce(
      nullif(trim(cleaning_json_text(p_payload, ARRAY['slack_channel_id', 'SlackチャンネルID'])), ''),
      slack_channel_id
    ),
    updated_at = now()
  WHERE id = v_id;

  RETURN v_id;
END;
$$;

-- ============================================================
--  Google フォーム回答の登録
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_form_submit(
  p_form_secret text,
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id uuid;
  v_company_created boolean := false;
  v_company_name text;
  v_company_key text;
  v_staff_name text;
  v_staff_email text;
  v_staff_dept text;
  v_mention_name text;
  v_slack_user_id text;
  v_notes text;
  v_staff_id uuid;
  v_app_id uuid;
  v_max int;
  v_company_existed boolean;
BEGIN
  IF NOT cleaning_verify_form_secret(p_form_secret) THEN
    RAISE EXCEPTION 'フォーム秘密鍵が正しくありません';
  END IF;

  v_company_name := cleaning_json_text(p_payload, ARRAY['company_name', '会社名', 'companyName']);
  IF v_company_name IS NULL OR trim(v_company_name) = '' THEN
    RAISE EXCEPTION '会社名が必要です';
  END IF;

  v_company_key := cleaning_normalize_key(v_company_name);
  v_company_existed := EXISTS (SELECT 1 FROM cleaning_companies WHERE name_normalized = v_company_key);

  v_company_id := cleaning_find_or_create_company(p_payload);
  v_company_created := NOT v_company_existed;

  v_staff_name := cleaning_json_text(p_payload, ARRAY['staff_name', '申請者氏名', '氏名', 'name']);
  IF v_staff_name IS NULL OR trim(v_staff_name) = '' THEN
    RAISE EXCEPTION '申請者氏名が必要です';
  END IF;

  v_staff_email := cleaning_json_text(p_payload, ARRAY['staff_email', '申請者メール', 'email', 'メールアドレス']);
  v_staff_dept := cleaning_json_text(p_payload, ARRAY['staff_department', '部署', 'department']);
  v_mention_name := cleaning_json_text(p_payload, ARRAY['mention_name', 'Slack表示名', 'slack_mention_name']);
  v_slack_user_id := cleaning_json_text(p_payload, ARRAY['slack_user_id', 'SlackメンバーID']);
  v_notes := cleaning_json_text(p_payload, ARRAY['notes', '備考']);

  -- 同一会社・同一メール or 同一氏名があれば更新、なければ追加
  SELECT id INTO v_staff_id
  FROM cleaning_staff
  WHERE company_id = v_company_id
    AND (
      (v_staff_email IS NOT NULL AND email = v_staff_email)
      OR (email IS NULL AND name = trim(v_staff_name))
    )
  ORDER BY created_at
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    SELECT coalesce(max(sort_order), -1) + 1 INTO v_max
    FROM cleaning_staff WHERE company_id = v_company_id;

    INSERT INTO cleaning_staff (
      company_id, name, mention_name, slack_user_id, email, department, sort_order, is_active
    ) VALUES (
      v_company_id,
      trim(v_staff_name),
      NULLIF(trim(coalesce(v_mention_name, '')), ''),
      NULLIF(trim(coalesce(v_slack_user_id, '')), ''),
      NULLIF(trim(coalesce(v_staff_email, '')), ''),
      NULLIF(trim(coalesce(v_staff_dept, '')), ''),
      v_max,
      true
    )
    RETURNING id INTO v_staff_id;
  ELSE
    UPDATE cleaning_staff SET
      name = trim(v_staff_name),
      mention_name = coalesce(NULLIF(trim(coalesce(v_mention_name, '')), ''), mention_name),
      slack_user_id = coalesce(NULLIF(trim(coalesce(v_slack_user_id, '')), ''), slack_user_id),
      email = coalesce(NULLIF(trim(coalesce(v_staff_email, '')), ''), email),
      department = coalesce(NULLIF(trim(coalesce(v_staff_dept, '')), ''), department),
      is_active = true
    WHERE id = v_staff_id;
  END IF;

  INSERT INTO cleaning_applications (
    company_id, staff_id, staff_name, staff_email, staff_department,
    mention_name, slack_user_id, notes, raw_payload
  ) VALUES (
    v_company_id, v_staff_id, trim(v_staff_name),
    NULLIF(trim(coalesce(v_staff_email, '')), ''),
    NULLIF(trim(coalesce(v_staff_dept, '')), ''),
    NULLIF(trim(coalesce(v_mention_name, '')), ''),
    NULLIF(trim(coalesce(v_slack_user_id, '')), ''),
    NULLIF(trim(coalesce(v_notes, '')), ''),
    coalesce(p_payload, '{}'::jsonb)
  )
  RETURNING id INTO v_app_id;

  RETURN jsonb_build_object(
    'ok', true,
    'company_id', v_company_id,
    'company_name', v_company_name,
    'company_created', v_company_created,
    'staff_id', v_staff_id,
    'application_id', v_app_id
  );
END;
$$;

-- ============================================================
--  会社・申請の参照 RPC
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_list_companies()
RETURNS TABLE(id uuid, name text, staff_count bigint, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT c.id, c.name, count(s.id), c.created_at
  FROM cleaning_companies c
  LEFT JOIN cleaning_staff s ON s.company_id = c.id AND s.is_active = true
  GROUP BY c.id, c.name, c.created_at
  ORDER BY c.name;
$$;

CREATE OR REPLACE FUNCTION cleaning_list_applications(p_password text, p_limit int DEFAULT 50)
RETURNS TABLE(
  id uuid, company_id uuid, company_name text,
  staff_name text, staff_email text, staff_department text,
  mention_name text, slack_user_id text, notes text,
  created_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  RETURN QUERY
  SELECT
    a.id, a.company_id, c.name,
    a.staff_name, a.staff_email, a.staff_department,
    a.mention_name, a.slack_user_id, a.notes,
    a.created_at
  FROM cleaning_applications a
  JOIN cleaning_companies c ON c.id = a.company_id
  ORDER BY a.created_at DESC
  LIMIT greatest(1, least(coalesce(p_limit, 50), 200));
END;
$$;

CREATE OR REPLACE FUNCTION cleaning_set_active_company(p_password text, p_company_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cleaning_companies WHERE id = p_company_id) THEN
    RAISE EXCEPTION '会社が見つかりません';
  END IF;
  UPDATE cleaning_settings SET active_company_id = p_company_id, updated_at = now() WHERE id = 1;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION cleaning_set_form_secret(p_password text, p_form_secret text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  IF p_form_secret IS NULL OR length(trim(p_form_secret)) < 8 THEN
    RAISE EXCEPTION 'フォーム秘密鍵は8文字以上にしてください';
  END IF;
  UPDATE cleaning_settings SET
    form_secret_hash = extensions.crypt(trim(p_form_secret), extensions.gen_salt('bf')),
    updated_at = now()
  WHERE id = 1;
  RETURN true;
END;
$$;

-- ============================================================
--  当番・Slack を会社単位に
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_workdays_since_anchor(
  p_date date DEFAULT cleaning_jst_today(),
  p_company_id uuid DEFAULT cleaning_active_company_id()
)
RETURNS int
LANGUAGE sql STABLE AS $$
  SELECT GREATEST(0, (
    SELECT count(*)::int
    FROM generate_series(
      (SELECT rotation_start_date FROM cleaning_companies WHERE id = p_company_id),
      p_date,
      '1 day'::interval
    ) AS gs(d)
    WHERE cleaning_is_workday(gs.d::date)
  ) - 1);
$$;

DROP FUNCTION IF EXISTS cleaning_list_staff();
CREATE OR REPLACE FUNCTION cleaning_list_staff()
RETURNS TABLE(
  id uuid, name text, mention_name text, slack_user_id text,
  sort_order int, is_active boolean, email text, department text, company_id uuid
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.id, s.name, s.mention_name, s.slack_user_id,
         s.sort_order, s.is_active, s.email, s.department, s.company_id
  FROM cleaning_staff s
  WHERE s.company_id = cleaning_active_company_id()
  ORDER BY s.sort_order, s.created_at;
$$;

CREATE OR REPLACE FUNCTION cleaning_schedule_for_date(
  p_date date DEFAULT cleaning_jst_today(),
  p_company_id uuid DEFAULT cleaning_active_company_id()
)
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
  WHERE s.is_active = true AND s.company_id = p_company_id;

  v_count := jsonb_array_length(v_staff);

  IF v_count = 0 THEN
    RETURN jsonb_build_object(
      'date', p_date, 'is_off_day', false, 'company_id', p_company_id,
      'day_offset', 0, 'staff_count', 0,
      'assignments', '[]'::jsonb, 'trash_today', null, 'trash_tomorrow', null
    );
  END IF;

  IF NOT cleaning_is_workday(p_date) THEN
    v_off_reason := CASE
      WHEN extract(isodow FROM p_date) IN (6, 7) THEN 'weekend'
      ELSE 'holiday'
    END;
    RETURN jsonb_build_object(
      'date', p_date, 'is_off_day', true, 'off_reason', v_off_reason,
      'company_id', p_company_id, 'day_offset', null, 'staff_count', v_count,
      'assignments', '[]'::jsonb, 'trash_today', null, 'trash_tomorrow', null
    );
  END IF;

  v_day := cleaning_workdays_since_anchor(p_date, p_company_id);

  FOR v_i IN 0..4 LOOP
    v_idx := cleaning_assignee_index(v_day, v_i, v_count);
    v_name := v_staff->v_idx->>'name';
    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'task_index', v_i, 'task', v_tasks[v_i + 1], 'emoji', v_emojis[v_i + 1],
      'staff_id', v_staff->v_idx->>'id', 'staff_name', v_name,
      'staff_mention', coalesce(v_staff->v_idx->>'mention_name', v_name),
      'staff_slack_user_id', v_staff->v_idx->>'slack_user_id', 'sort_order', v_idx
    ));
  END LOOP;

  v_idx := cleaning_assignee_index(v_day, 0, v_count);
  v_next_workday := cleaning_next_workday(p_date);
  v_day_next := cleaning_workdays_since_anchor(v_next_workday, p_company_id);
  v_idx_tomorrow := cleaning_assignee_index(v_day_next, 0, v_count);

  RETURN jsonb_build_object(
    'date', p_date, 'is_off_day', false, 'company_id', p_company_id,
    'day_offset', v_day, 'staff_count', v_count, 'assignments', v_result,
    'trash_today', jsonb_build_object(
      'staff_id', v_staff->v_idx->>'id', 'staff_name', v_staff->v_idx->>'name',
      'staff_mention', coalesce(v_staff->v_idx->>'mention_name', v_staff->v_idx->>'name'),
      'staff_slack_user_id', v_staff->v_idx->>'slack_user_id', 'sort_order', v_idx
    ),
    'trash_tomorrow', jsonb_build_object(
      'staff_id', v_staff->v_idx_tomorrow->>'id', 'staff_name', v_staff->v_idx_tomorrow->>'name',
      'staff_mention', coalesce(v_staff->v_idx_tomorrow->>'mention_name', v_staff->v_idx_tomorrow->>'name'),
      'staff_slack_user_id', v_staff->v_idx_tomorrow->>'slack_user_id', 'sort_order', v_idx_tomorrow
    )
  );
END;
$$;

DROP FUNCTION IF EXISTS cleaning_get_settings();
CREATE OR REPLACE FUNCTION cleaning_get_settings()
RETURNS TABLE(
  rotation_start_date date,
  slack_enabled boolean,
  slack_bot_token_masked text,
  slack_channel_id text,
  cron_hour_jst int,
  cron_enabled boolean,
  last_cron_run_at timestamptz,
  updated_at timestamptz,
  active_company_id uuid,
  active_company_name text,
  form_secret_set boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    c.rotation_start_date,
    c.slack_enabled,
    CASE WHEN c.slack_bot_token IS NULL OR length(c.slack_bot_token) < 8 THEN NULL
         ELSE '****' || right(c.slack_bot_token, 4) END,
    c.slack_channel_id,
    c.cron_hour_jst,
    c.cron_enabled,
    c.last_cron_run_at,
    c.updated_at,
    c.id,
    c.name,
    (s.form_secret_hash IS NOT NULL AND length(s.form_secret_hash) > 0)
  FROM cleaning_settings s
  LEFT JOIN cleaning_companies c ON c.id = cleaning_active_company_id()
  WHERE s.id = 1;
$$;

DROP FUNCTION IF EXISTS cleaning_save_settings(text, date, boolean, text, text, int, boolean);
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
DECLARE
  v_company_id uuid;
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  v_company_id := cleaning_active_company_id();
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION '会社が選択されていません';
  END IF;
  UPDATE cleaning_companies SET
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
  WHERE id = v_company_id;
  UPDATE cleaning_settings SET updated_at = now() WHERE id = 1;
  RETURN true;
END;
$$;

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
  v_company_id uuid;
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  IF trim(p_name) = '' THEN
    RAISE EXCEPTION '名前を入力してください';
  END IF;
  v_company_id := cleaning_active_company_id();
  SELECT coalesce(max(sort_order), -1) + 1 INTO v_max
  FROM cleaning_staff WHERE company_id = v_company_id;
  INSERT INTO cleaning_staff (company_id, name, mention_name, slack_user_id, sort_order)
  VALUES (
    v_company_id, trim(p_name),
    NULLIF(trim(coalesce(p_mention_name, '')), ''),
    NULLIF(trim(coalesce(p_slack_user_id, '')), ''),
    v_max
  )
  RETURNING cleaning_staff.id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION cleaning_send_slack(
  p_date date DEFAULT cleaning_jst_today(),
  p_company_id uuid DEFAULT cleaning_active_company_id()
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
  FROM cleaning_companies WHERE id = p_company_id;

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

  v_msg := cleaning_build_slack_message(p_date, p_company_id);

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
    UPDATE cleaning_companies SET last_cron_run_at = now() WHERE id = p_company_id;
    RETURN jsonb_build_object('ok', true, 'message', v_msg, 'company_id', p_company_id);
  END IF;
  RETURN jsonb_build_object(
    'ok', false,
    'error', coalesce(v_body->>'error', 'Slack HTTP ' || v_resp.status::text),
    'needed', v_body->>'needed',
    'body', v_resp.content
  );
END;
$$;

CREATE OR REPLACE FUNCTION cleaning_build_slack_message(
  p_date date DEFAULT cleaning_jst_today(),
  p_company_id uuid DEFAULT cleaning_active_company_id()
)
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
  v_sched := cleaning_schedule_for_date(p_date, p_company_id);

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

CREATE OR REPLACE FUNCTION cleaning_cron_send_slack()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_rec record;
  v_jst_hour int;
  v_result jsonb;
BEGIN
  v_jst_hour := extract(hour FROM timezone('Asia/Tokyo', now()))::int;
  FOR v_rec IN
    SELECT id, cron_hour_jst, cron_enabled
    FROM cleaning_companies
    WHERE coalesce(cron_enabled, true)
  LOOP
    IF v_jst_hour <> coalesce(v_rec.cron_hour_jst, 9) THEN
      CONTINUE;
    END IF;
    v_result := cleaning_send_slack(cleaning_jst_today(), v_rec.id);
    IF coalesce(v_result->>'ok', 'false') <> 'true'
       AND coalesce(v_result->>'skipped', 'false') <> 'true' THEN
      RAISE WARNING 'cleaning Slack failed (company %): %', v_rec.id, v_result;
    END IF;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION cleaning_form_submit(text, jsonb) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_list_companies() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_list_applications(text, int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_set_active_company(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_set_form_secret(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_save_settings(text, date, boolean, text, text, int, boolean) TO anon, authenticated;
