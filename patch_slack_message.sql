-- 既存 Supabase 向け: Slack 通知文面変更パッチ
-- SQL Editor で Run

ALTER TABLE cleaning_staff
  ADD COLUMN IF NOT EXISTS mention_name text;

COMMENT ON COLUMN cleaning_staff.mention_name IS 'Slack @用の表示名（未設定時は name を使用。例: 小笠原 将太）';

-- 戻り値・引数が変わる関数は DROP してから再作成
DROP FUNCTION IF EXISTS cleaning_list_staff();
DROP FUNCTION IF EXISTS cleaning_add_staff(text, text);
DROP FUNCTION IF EXISTS cleaning_add_staff(text, text, text);

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
    'id', s.id, 'name', s.name,
    'mention_name', coalesce(s.mention_name, s.name),
    'sort_order', s.sort_order
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
      'staff_mention', coalesce(v_staff->v_idx->>'mention_name', v_name),
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
      'staff_mention', coalesce(v_staff->v_idx->>'mention_name', v_staff->v_idx->>'name'),
      'sort_order', v_idx
    ),
    'trash_tomorrow', jsonb_build_object(
      'staff_id', v_staff->v_idx_tomorrow->>'id',
      'staff_name', v_staff->v_idx_tomorrow->>'name',
      'staff_mention', coalesce(v_staff->v_idx_tomorrow->>'mention_name', v_staff->v_idx_tomorrow->>'name'),
      'sort_order', v_idx_tomorrow
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION cleaning_list_staff()
RETURNS TABLE(id uuid, name text, mention_name text, sort_order int, is_active boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.id, s.name, s.mention_name, s.sort_order, s.is_active
  FROM cleaning_staff s
  ORDER BY s.sort_order, s.created_at;
$$;

CREATE OR REPLACE FUNCTION cleaning_add_staff(
  p_password text,
  p_name text,
  p_mention_name text DEFAULT NULL
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
  INSERT INTO cleaning_staff (name, mention_name, sort_order)
  VALUES (
    trim(p_name),
    NULLIF(trim(coalesce(p_mention_name, '')), ''),
    v_max
  )
  RETURNING cleaning_staff.id INTO v_id;
  RETURN v_id;
END;
$$;

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
    RETURN '【本日掃除当番】社員が登録されていません。';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_sched->'assignments')
  LOOP
    v_lines := v_lines || E'\n' || '*' || (v_item->>'staff_name') || '*さん  → 「' || (v_item->>'task') || '」';
  END LOOP;

  v_trash_today := coalesce(
    v_sched->'trash_today'->>'staff_mention',
    v_sched->'trash_today'->>'staff_name'
  );
  v_trash_tomorrow := coalesce(
    v_sched->'trash_tomorrow'->>'staff_mention',
    v_sched->'trash_tomorrow'->>'staff_name'
  );

  RETURN '【本日掃除当番】' || v_lines || E'\n\n'
    || '本日のゴミ捨て担当は*@' || v_trash_today || '*さんです。' || E'\n'
    || '明日朝のゴミ箱回収担当は*@' || v_trash_tomorrow || '*さんです。' || E'\n'
    || 'よろしくおねがいいたします。';
END;
$$;

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
    jsonb_build_object(
      'blocks', jsonb_build_array(jsonb_build_object(
        'type', 'section',
        'text', jsonb_build_object('type', 'mrkdwn', 'text', v_msg)
      ))
    )::text
  )::extensions.http_request);

  IF v_resp.status BETWEEN 200 AND 299 THEN
    RETURN jsonb_build_object('ok', true, 'message', v_msg);
  END IF;
  RETURN jsonb_build_object('ok', false, 'error', 'Slack HTTP ' || v_resp.status::text, 'body', v_resp.content);
END;
$$;

GRANT EXECUTE ON FUNCTION cleaning_list_staff() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_add_staff(text, text, text) TO anon, authenticated;
