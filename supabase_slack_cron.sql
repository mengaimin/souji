-- ============================================================
--  掃除当番 Slack 毎日自動通知（pg_cron）
--  前提: souji.sql 実行済み、http 拡張有効
--  Dashboard → Database → Extensions で pg_cron を有効化
-- ============================================================

CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron;

ALTER TABLE cleaning_settings
  ADD COLUMN IF NOT EXISTS last_cron_run_at timestamptz,
  ADD COLUMN IF NOT EXISTS cron_enabled boolean NOT NULL DEFAULT true;

SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname = 'cleaning-daily-slack';

-- JST 9:00 = UTC 0:00（設定の cron_hour_jst と照合）
SELECT cron.schedule(
  'cleaning-daily-slack',
  '0 * * * *',
  $$SELECT cleaning_cron_send_slack();$$
);

CREATE OR REPLACE FUNCTION cleaning_cron_send_slack()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_hour int;
  v_enabled boolean;
  v_jst_hour int;
  v_result jsonb;
BEGIN
  SELECT cron_hour_jst, cron_enabled INTO v_hour, v_enabled
  FROM cleaning_settings WHERE id = 1;

  IF NOT coalesce(v_enabled, true) THEN
    RETURN;
  END IF;

  v_jst_hour := extract(hour FROM timezone('Asia/Tokyo', now()))::int;
  IF v_jst_hour <> coalesce(v_hour, 9) THEN
    RETURN;
  END IF;

  v_result := cleaning_send_slack(cleaning_jst_today());
  UPDATE cleaning_settings SET last_cron_run_at = now() WHERE id = 1;

  IF coalesce(v_result->>'ok', 'false') <> 'true' THEN
    RAISE WARNING 'cleaning Slack failed: %', v_result;
  END IF;
END;
$$;
