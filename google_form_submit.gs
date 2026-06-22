/**
 * Google フォーム → 掃除当番システム 連携スクリプト
 *
 * セットアップ:
 * 1. Supabase で patch_form_company.sql を実行
 * 2. 管理画面「設定」→ フォーム秘密鍵を保存（8文字以上）
 * 3. 下記 CONFIG を編集
 * 4. Google フォーム → 回答先スプレッドシート → 拡張機能 → Apps Script に貼り付け
 * 5. トリガー: 「フォーム送信時」→ onFormSubmit
 *
 * フォーム項目（質問タイトルをこの名前に合わせる）:
 * - 会社名（必須）
 * - 会社担当者名
 * - 会社メールアドレス
 * - 会社電話番号
 * - 会社住所
 * - 申請者氏名（必須）
 * - 申請者メール
 * - 部署
 * - Slack表示名
 * - SlackメンバーID
 * - 備考
 */

const CONFIG = {
  SUPABASE_URL: 'https://YOUR_PROJECT.supabase.co',
  SUPABASE_ANON_KEY: 'YOUR_ANON_KEY',
  FORM_SECRET: 'your-form-secret-here',
};

function onFormSubmit(e) {
  try {
    const payload = buildPayload_(e);
    const result = submitToSupabase_(payload);
    Logger.log('OK: ' + JSON.stringify(result));
  } catch (err) {
    Logger.log('ERROR: ' + err.message);
    throw err;
  }
}

function buildPayload_(e) {
  const nv = e.namedValues || {};
  const get = (keys) => {
    for (let i = 0; i < keys.length; i++) {
      const v = nv[keys[i]];
      if (v && v[0] && String(v[0]).trim()) return String(v[0]).trim();
    }
    return '';
  };

  return {
    company_name: get(['会社名', 'company_name']),
    company_contact_person: get(['会社担当者名', 'company_contact_person']),
    company_contact_email: get(['会社メールアドレス', 'company_contact_email']),
    company_contact_phone: get(['会社電話番号', 'company_contact_phone']),
    company_address: get(['会社住所', 'company_address']),
    staff_name: get(['申請者氏名', '氏名', 'staff_name']),
    staff_email: get(['申請者メール', 'メールアドレス', 'staff_email']),
    staff_department: get(['部署', 'staff_department']),
    mention_name: get(['Slack表示名', 'mention_name']),
    slack_user_id: get(['SlackメンバーID', 'slack_user_id']),
    slack_channel_id: get(['SlackチャンネルID', 'slack_channel_id']),
    notes: get(['備考', 'notes']),
  };
}

function submitToSupabase_(payload) {
  if (!payload.company_name) throw new Error('会社名がありません');
  if (!payload.staff_name) throw new Error('申請者氏名がありません');

  const url = CONFIG.SUPABASE_URL.replace(/\/$/, '')
    + '/rest/v1/rpc/cleaning_form_submit';

  const res = UrlFetchApp.fetch(url, {
    method: 'post',
    contentType: 'application/json',
    headers: {
      apikey: CONFIG.SUPABASE_ANON_KEY,
      Authorization: 'Bearer ' + CONFIG.SUPABASE_ANON_KEY,
    },
    payload: JSON.stringify({
      p_form_secret: CONFIG.FORM_SECRET,
      p_payload: payload,
    }),
    muteHttpExceptions: true,
  });

  const code = res.getResponseCode();
  const body = res.getContentText();
  if (code >= 400) {
    throw new Error('Supabase HTTP ' + code + ': ' + body);
  }
  const data = JSON.parse(body);
  if (data.message && String(data.message).includes('正しくありません')) {
    throw new Error(data.message);
  }
  return data;
}

/** 手動テスト用 */
function testSubmit() {
  const payload = {
    company_name: 'テスト株式会社',
    company_contact_email: 'test@example.com',
    staff_name: 'テスト太郎',
    staff_email: 'taro@example.com',
    staff_department: '総務',
    mention_name: 'テスト 太郎',
    notes: 'Apps Script テスト',
  };
  Logger.log(submitToSupabase_(payload));
}
