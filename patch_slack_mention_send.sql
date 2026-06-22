-- Slack @ メンションを実際に通知する（Supabase SQL Editor で Run）
-- 1. Slack ID 正規化  2. プレビューと同じ文面をテスト送信可能に

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
  IF v ~* '^U[A-Z0-9]+$' THEN RETURN v; END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION cleaning_slack_trash_mention(p_name text, p_slack_user_id text DEFAULT NULL)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN cleaning_normalize_slack_user_id(p_slack_user_id) IS NOT NULL THEN
      '<@' || cleaning_normalize_slack_user_id(p_slack_user_id) || '>'
    ELSE '@' || coalesce(nullif(trim(p_name), ''), '—')
  END;
$$;

-- 既存データの Slack ID を正規化（@U... や <@U...> で登録されていた場合）
UPDATE cleaning_staff
SET slack_user_id = cleaning_normalize_slack_user_id(slack_user_id)
WHERE slack_user_id IS NOT NULL;

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

  v_msg := coalesce(nullif(trim(p_message), ''), cleaning_build_slack_message(p_date));

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

GRANT EXECUTE ON FUNCTION cleaning_normalize_slack_user_id(text) TO anon, authenticated;
