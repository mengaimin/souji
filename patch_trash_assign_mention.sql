-- 🗑️ 今日・明日のゴミ捨て行を @ メンション付きで送信（既存 DB 用）
-- Supabase SQL Editor で Run

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

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname = 'cleaning_build_slack_message'
      AND pg_get_function_identity_arguments(oid) LIKE '%uuid%'
  ) THEN
    EXECUTE $fn$
CREATE OR REPLACE FUNCTION cleaning_build_slack_message(
  p_date date DEFAULT cleaning_jst_today(),
  p_company_id uuid DEFAULT cleaning_active_company_id()
)
RETURNS text
LANGUAGE plpgsql STABLE
AS $body$
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
$body$;
    $fn$;
  END IF;
END $$;

SELECT cleaning_build_slack_message(cleaning_jst_today()) AS message_preview;
