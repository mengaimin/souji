-- 通知文面テンプレート機能の削除（Supabase SQL Editor で Run）

DROP FUNCTION IF EXISTS cleaning_get_settings();
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

  RETURN '【本日掃除当番】' || v_lines || E'\n\n'
    || '本日のゴミ捨て担当は' || v_trash_today || 'さんです。' || E'\n'
    || '明日朝のゴミ箱回収担当は' || v_trash_tomorrow || 'さんです。' || E'\n'
    || 'よろしくおねがいいたします。';
END;
$$;

DROP FUNCTION IF EXISTS cleaning_save_slack_template(text, text, text, text, text, text);
DROP FUNCTION IF EXISTS cleaning_tpl_apply(text, text, text, text);
