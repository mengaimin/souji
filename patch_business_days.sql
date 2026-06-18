-- 土日祝を掃除当番・Slack 通知から除外（Supabase SQL Editor で Run）

CREATE TABLE IF NOT EXISTS cleaning_holidays (
  holiday_date date PRIMARY KEY,
  name text NOT NULL
);

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

CREATE OR REPLACE FUNCTION cleaning_list_holidays()
RETURNS TABLE(holiday_date date, name text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT h.holiday_date, h.name FROM cleaning_holidays h ORDER BY h.holiday_date;
$$;

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
    v_trash_tomorrow_label := '明日朝のゴミ箱回収担当は';
  ELSE
    v_trash_tomorrow_label := '次回営業日朝のゴミ箱回収担当は';
  END IF;

  RETURN '【本日掃除当番】' || v_lines || E'\n\n'
    || '本日のゴミ捨て担当は' || v_trash_today || 'さんです。' || E'\n'
    || v_trash_tomorrow_label || v_trash_tomorrow || 'さんです。' || E'\n'
    || 'よろしくおねがいいたします。';
END;
$$;

CREATE OR REPLACE FUNCTION cleaning_send_slack(p_date date DEFAULT cleaning_jst_today())
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

  v_msg := cleaning_build_slack_message(p_date);

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

GRANT EXECUTE ON FUNCTION cleaning_is_workday(date) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_workdays_since_anchor(date) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_list_holidays() TO anon, authenticated;
