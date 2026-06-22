# 会社掃除当番システム

社員の当番順に基づき、5つの掃除（ゴミ捨て・トイレ・フロア・空気清浄機・給湯室）を自動ローテーションし、**平日の朝**に Slack へ通知する Web アプリです。

- フロント: `index.html`（単一 HTML）
- バックエンド: Supabase（PostgreSQL + RPC）

---

## ローテーションのルール

1. **社員を登録**し、当番順（1番・2番・3番…）を決める
2. **営業日のみ**当番が回る（**土日・祝日は掃除なし**）
3. **ゴミ捨て**は営業日ごとに順番交代（1番→2番→…→1番）
4. **個人のタスク進行**: 今日ゴミ捨ての人は、次の営業日トイレ → その次フロア → 空気清浄機 → 給湯室 と進む
5. **平日の朝**、Slack に今日の5担当・ゴミ捨て・次回ゴミ回収を通知

### 例（3人・平日のみ）

| 営業日 | ゴミ捨て | トイレ | フロア | 空気清浄機 | 給湯室 |
|--------|---------|--------|--------|-----------|--------|
| 1日目 | 1番 | 3番 | 2番 | 1番 | 3番 |
| 2日目 | 2番 | 1番 | 3番 | 2番 | 1番 |
| 3日目 | 3番 | 2番 | 1番 | 3番 | 2番 |

金曜の通知では「**次回営業日朝**のゴミ箱回収担当」として月曜の人が表示されます。

---

## 初回セットアップ

### 1. Supabase プロジェクト

[Supabase](https://supabase.com) でプロジェクトを作成します。

**有効化する Extensions（Dashboard → Database → Extensions）:**

| Extension | 用途 |
|-----------|------|
| `pgcrypto` | 管理者パスワード |
| `http` | Slack API 呼び出し |
| `pg_cron` | 毎日自動通知 |

### 2. SQL 実行

Supabase **SQL Editor** で順に Run:

| 順 | ファイル | 内容 |
|----|---------|------|
| 1 | `souji.sql` | テーブル・ローテーション・Slack 送信・RPC |
| 2 | `supabase_slack_cron.sql` | 毎朝の自動 Slack 通知（pg_cron） |

### 3. index.html の Supabase 接続

`index.html` 内の以下を自分のプロジェクト情報に書き換え:

```javascript
const SUPABASE_URL = 'https://YOUR_PROJECT.supabase.co';
const SUPABASE_ANON_KEY = 'YOUR_ANON_KEY';
```

Dashboard → **Project Settings → API** から取得できます。

### 4. ブラウザで開く

`index.html` をブラウザで開くか、静的ホスティング（GitHub Pages 等）に配置します。

### 5. 初期ログイン

| 項目 | 値 |
|------|-----|
| 初期パスワード | `Admin1234` |

ログイン後、**設定 → パスワード変更** を推奨します。

---

## 日常の使い方

### 画面構成

| タブ | 内容 |
|------|------|
| **ホーム** | 今日の当番・Slack 通知プレビュー |
| **1か月** | 今後30日分の当番表（土日祝は「休」） |
| **社員・順番** | 社員の追加・編集・休み・順番変更 |
| **設定** | 起点日・Slack・自動通知・パスワード |

### 社員の登録

1. 右上 **管理者ログイン**
2. **社員・順番** → **社員を追加**
3. 表示名・Slack @用の名前・Slack メンバーID（任意）を入力
4. **↑↓** ボタンで当番順を調整（上が1番）

**休み:** 編集画面の「休み中」または **休み** ボタン → 当番から除外（削除しない）

### ローテーション起点日

**設定 → 基本設定** で変更します。

- 起点日に **1番の人がゴミ捨て** になるよう設定
- 運用開始日に合わせてください

---

## Slack 通知の設定

Bot Token + チャンネルID 方式で投稿します（Incoming Webhook は使用しません）。

### Slack App の準備

1. [Slack API](https://api.slack.com/apps) → **Create New App**
2. **OAuth & Permissions** → **Bot Token Scopes** に `chat:write` を追加
3. **Install to Workspace**（再インストール）→ **Bot User OAuth Token**（`xoxb-...`）をコピー
4. 通知先チャンネルで `/invite @App名` を実行

### 掃除当番アプリへの登録

**設定 → Slack 通知**

| 項目 | 入力 |
|------|------|
| Slack 通知を有効化 | チェック |
| 毎日の自動送信を有効化 | チェック |
| 通知時刻（JST） | 例: 9:00 |
| チャンネルID | `C...` または `G...`（チャンネル詳細の最下部） |
| Bot Token | `xoxb-...`（初回のみ。以降は空欄でOK） |

**保存** → **テスト送信** で確認。

### Slack 通知文面（固定）

```
【本日掃除当番】
{名前}さん  → 「{タスク}」
（5行）
🗑️ 今日のゴミ捨て: {mention}
🗑️ 明日のゴミ捨て: {mention}（金曜などは「次回営業日のゴミ捨て」）
よろしくおねがいいたします。
```

- 当番一覧（5行）は名前のみ（@ なし）
- 🗑️ 今日・明日のゴミ捨て行は `@` メンション（`slack_user_id` 設定時は Slack で実メンション）

### よくある Slack エラー

| エラー | 原因・対処 |
|--------|-----------|
| `invalid_auth` | Bot Token（`xoxb-...`）を再取得して保存 |
| `missing_scope` | Bot Token Scopes に `chat:write` を追加 → 再インストール → 新トークン保存 |
| `channel_not_found` | チャンネルID の誤り、または Bot Token と別ワークスペース |
| `not_in_channel` | チャンネルで `/invite @App名` |

**注意:** Bot Token のワークスペースと同じチャンネルIDのみ使えます。別チームのチャンネルには、そのチーム側で Webhook / Bot を用意する必要があります。

---

## 土日・祝日

- **土日** と **国民の祝日** は掃除当番なし
- Slack 通知も送信されない
- 祝日データは `cleaning_holidays` テーブル（2025〜2028年を登録済み）

### 会社独自の休日を追加

Supabase SQL Editor:

```sql
INSERT INTO cleaning_holidays (holiday_date, name)
VALUES ('2026-12-29', '年末休暇'), ('2026-12-30', '年末休暇')
ON CONFLICT (holiday_date) DO NOTHING;
```

### 2029年以降の祝日

`cleaning_holidays` に同様に INSERT してください。

---

## 既存 DB へのパッチ

すでに `souji.sql` を実行済みの場合、機能追加時は該当パッチのみ Run:

| ファイル | 内容 |
|---------|------|
| `patch_staff_edit.sql` | 社員編集 |
| `patch_staff_leave.sql` | 休み／復帰 |
| `patch_slack_channel.sql` | Slack: Webhook → Bot Token + チャンネルID |
| `patch_business_days.sql` | 土日祝を除外 |
| `patch_remove_template.sql` | 通知文面テンプレート機能の削除 |

新規構築なら `souji.sql` + `supabase_slack_cron.sql` のみで足ります。

---

## 登録情報（申請書・支給要件確認申立書）

Google フォーム連携の前に、管理画面から必要情報を登録できます。

### Supabase パッチ

```sql
-- patch_registration_fields.sql を Run
-- （会社マスタ拡張・社員詳細・被扶養者テーブル）
```

### 管理画面「登録情報」タブ

| サブタブ | 内容 | 主な用途 |
|---------|------|---------|
| **会社（事業主）** | 会社名、代表者、所在地、社会保険記号など | 申請書の事業所欄 |
| **社員（被保険者）** | 本人情報、雇用、口座、年金番号、Slack当番 | 申請書・被保険者欄 |
| **被扶養者** | 続柄、生年月日、収入見込、同居区分など | 支給要件確認申立書 |

**設定 → 表示中の会社** で編集対象の会社を切り替えます。

社員一覧の **「登録情報」** ボタンから、該当社員の詳細登録画面へ移動できます。

---

## Google フォーム連携（将来用・未使用）

フォーム回答の自動取込は **まだ使わない** 想定です。将来使う場合は `patch_form_company.sql` と `google_form_submit.gs` を参照してください。

---

## ファイル構成

| ファイル | 内容 |
|---------|------|
| `index.html` | Web アプリ本体 |
| `souji.sql` | DB スキーマ・ローテーション・Slack 送信・RPC |
| `supabase_slack_cron.sql` | 毎日自動通知（pg_cron） |
| `patch_registration_fields.sql` | 申請書・支給要件確認用の登録項目 |
| `patch_form_company.sql` | （将来）Google フォーム連携 |
| `google_form_submit.gs` | Google Apps Script テンプレート |
| `patch_*.sql` | その他既存 DB 向け更新パッチ |
| `README.md` | この使い方 |

---

## 運用のヒント

- **ローテーション起点日** を運用開始日に合わせる（その日に1番がゴミ捨て）
- **社員の入退社** は「社員・順番」で追加・休み・削除・順番変更
- **通知時刻** はデフォルト JST 9:00（設定で 0〜23時）
- **自動送信** が動かない場合: `pg_cron` と `supabase_slack_cron.sql` の実行を確認
- **土日にテスト送信** すると「送信しません」と表示される（正常動作）

---

## トラブルシューティング

| 症状 | 確認 |
|------|------|
| 画面が読み込めない | `index.html` の Supabase URL / Key |
| ログインできない | パスワード（初期: `Admin1234`） |
| Slack が届かない | Bot Token・チャンネルID・`/invite`・テスト送信のエラー |
| 当番がずれる | ローテーション起点日、休み中の社員 |
| 祝日なのに当番がある | `patch_business_days.sql` 未実行 |

Supabase で手動テスト:

```sql
SELECT cleaning_send_slack(cleaning_jst_today());
SELECT cleaning_build_slack_message(cleaning_jst_today());
```
