-- Slack 通知: Webhook → Bot Token + チャンネルID（Supabase SQL Editor で Run）

ALTER TABLE cleaning_settings
  ADD COLUMN IF NOT EXISTS slack_bot_token text,
  ADD COLUMN IF NOT EXISTS slack_channel_id text;

ALTER TABLE cleaning_settings DROP COLUMN IF EXISTS slack_webhook_url;

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

DROP FUNCTION IF EXISTS cleaning_save_settings(text, date, boolean, text, int, boolean);
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

GRANT EXECUTE ON FUNCTION cleaning_save_settings(text, date, boolean, text, text, int, boolean) TO anon, authenticated;
