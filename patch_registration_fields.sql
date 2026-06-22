-- 申請書・支給要件確認申立書用の登録項目（Supabase SQL Editor で Run）
-- ※ Google フォーム回答連携は対象外（手動登録用）

-- ============================================================
--  会社マスタ（patch_form_company 未実行でも作成可）
-- ============================================================
CREATE TABLE IF NOT EXISTS cleaning_companies (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                  text NOT NULL,
  name_normalized       text NOT NULL UNIQUE,
  name_kana             text,
  corporate_number      text,
  representative_name   text,
  representative_title  text,
  postal_code           text,
  address               text,
  contact_person        text,
  contact_email         text,
  contact_phone         text,
  contact_department    text,
  fax                   text,
  pension_office_symbol text,
  health_insurance_symbol text,
  employment_insurance_number text,
  labor_insurance_number text,
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

ALTER TABLE cleaning_companies
  ADD COLUMN IF NOT EXISTS name_kana text,
  ADD COLUMN IF NOT EXISTS corporate_number text,
  ADD COLUMN IF NOT EXISTS representative_name text,
  ADD COLUMN IF NOT EXISTS representative_title text,
  ADD COLUMN IF NOT EXISTS postal_code text,
  ADD COLUMN IF NOT EXISTS contact_department text,
  ADD COLUMN IF NOT EXISTS fax text,
  ADD COLUMN IF NOT EXISTS pension_office_symbol text,
  ADD COLUMN IF NOT EXISTS health_insurance_symbol text,
  ADD COLUMN IF NOT EXISTS employment_insurance_number text,
  ADD COLUMN IF NOT EXISTS labor_insurance_number text;

-- ============================================================
--  社員（申請書・被保険者情報）
-- ============================================================
ALTER TABLE cleaning_staff
  ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES cleaning_companies(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS email text,
  ADD COLUMN IF NOT EXISTS department text,
  ADD COLUMN IF NOT EXISTS name_kana text,
  ADD COLUMN IF NOT EXISTS birth_date date,
  ADD COLUMN IF NOT EXISTS gender text,
  ADD COLUMN IF NOT EXISTS postal_code text,
  ADD COLUMN IF NOT EXISTS address text,
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS mobile text,
  ADD COLUMN IF NOT EXISTS emergency_contact_name text,
  ADD COLUMN IF NOT EXISTS emergency_contact_relation text,
  ADD COLUMN IF NOT EXISTS emergency_contact_phone text,
  ADD COLUMN IF NOT EXISTS employee_number text,
  ADD COLUMN IF NOT EXISTS position text,
  ADD COLUMN IF NOT EXISTS employment_type text,
  ADD COLUMN IF NOT EXISTS hire_date date,
  ADD COLUMN IF NOT EXISTS resignation_date date,
  ADD COLUMN IF NOT EXISTS bank_name text,
  ADD COLUMN IF NOT EXISTS bank_branch text,
  ADD COLUMN IF NOT EXISTS bank_account_type text,
  ADD COLUMN IF NOT EXISTS bank_account_number text,
  ADD COLUMN IF NOT EXISTS bank_account_holder text,
  ADD COLUMN IF NOT EXISTS basic_pension_number text,
  ADD COLUMN IF NOT EXISTS insured_number text,
  ADD COLUMN IF NOT EXISTS standard_monthly_remuneration numeric(12, 0),
  ADD COLUMN IF NOT EXISTS profile_notes text;

-- ============================================================
--  被扶養者（支給要件確認申立書）
-- ============================================================
CREATE TABLE IF NOT EXISTS cleaning_staff_dependents (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id                uuid NOT NULL REFERENCES cleaning_staff(id) ON DELETE CASCADE,
  company_id              uuid NOT NULL REFERENCES cleaning_companies(id) ON DELETE CASCADE,
  name                    text NOT NULL,
  name_kana               text,
  relationship            text,
  birth_date              date,
  gender                  text,
  postal_code             text,
  address                 text,
  occupation              text,
  estimated_annual_income numeric(12, 0),
  cohabitation_status     text,
  is_foreign_national     boolean NOT NULL DEFAULT false,
  qualification_date      date,
  notes                   text,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS cleaning_dependents_staff_idx ON cleaning_staff_dependents (staff_id);

ALTER TABLE cleaning_settings
  ADD COLUMN IF NOT EXISTS active_company_id uuid REFERENCES cleaning_companies(id);

-- 既定会社の作成・移行
DO $$
DECLARE
  v_default_id uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cleaning_companies LIMIT 1) THEN
    INSERT INTO cleaning_companies (name, name_normalized)
    VALUES ('既定の会社', '既定の会社')
    RETURNING id INTO v_default_id;
    UPDATE cleaning_staff SET company_id = v_default_id WHERE company_id IS NULL;
    UPDATE cleaning_settings SET active_company_id = v_default_id WHERE id = 1;
  ELSE
    UPDATE cleaning_staff s SET company_id = c.id
    FROM (SELECT id FROM cleaning_companies ORDER BY created_at LIMIT 1) c
    WHERE s.company_id IS NULL;
    UPDATE cleaning_settings SET active_company_id = (
      SELECT id FROM cleaning_companies ORDER BY created_at LIMIT 1
    ) WHERE id = 1 AND active_company_id IS NULL;
  END IF;
END $$;

-- ============================================================
--  ヘルパー（patch_form_company 未実行時）
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_normalize_key(p_text text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT regexp_replace(trim(coalesce(p_text, '')), '\s+', '', 'g');
$$;

CREATE OR REPLACE FUNCTION cleaning_active_company_id()
RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    (SELECT active_company_id FROM cleaning_settings WHERE id = 1),
    (SELECT id FROM cleaning_companies ORDER BY created_at LIMIT 1)
  );
$$;

CREATE OR REPLACE FUNCTION cleaning_null_date(p_text text)
RETURNS date LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_text IS NULL OR trim(p_text) = '' THEN NULL ELSE trim(p_text)::date END;
$$;

CREATE OR REPLACE FUNCTION cleaning_null_numeric(p_text text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_text IS NULL OR trim(p_text) = '' THEN NULL ELSE trim(p_text)::numeric END;
$$;

-- ============================================================
--  会社プロフィール
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_get_company_profile(p_company_id uuid DEFAULT cleaning_active_company_id())
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', c.id,
    'name', c.name,
    'name_kana', c.name_kana,
    'corporate_number', c.corporate_number,
    'representative_name', c.representative_name,
    'representative_title', c.representative_title,
    'postal_code', c.postal_code,
    'address', c.address,
    'contact_person', c.contact_person,
    'contact_email', c.contact_email,
    'contact_phone', c.contact_phone,
    'contact_department', c.contact_department,
    'fax', c.fax,
    'pension_office_symbol', c.pension_office_symbol,
    'health_insurance_symbol', c.health_insurance_symbol,
    'employment_insurance_number', c.employment_insurance_number,
    'labor_insurance_number', c.labor_insurance_number,
    'notes', c.notes
  )
  FROM cleaning_companies c WHERE c.id = p_company_id;
$$;

CREATE OR REPLACE FUNCTION cleaning_create_company(p_password text, p_data jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_name text;
  v_key text;
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  v_name := nullif(trim(p_data->>'name'), '');
  IF v_name IS NULL THEN RAISE EXCEPTION '会社名が必要です'; END IF;
  v_key := cleaning_normalize_key(v_name);
  IF EXISTS (SELECT 1 FROM cleaning_companies WHERE name_normalized = v_key) THEN
    RAISE EXCEPTION '同じ会社名が既に登録されています';
  END IF;
  INSERT INTO cleaning_companies (name, name_normalized) VALUES (v_name, v_key) RETURNING id INTO v_id;
  PERFORM cleaning_save_company_profile(p_password, v_id, p_data);
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION cleaning_save_company_profile(
  p_password text,
  p_company_id uuid,
  p_data jsonb
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cleaning_companies WHERE id = p_company_id) THEN
    RAISE EXCEPTION '会社が見つかりません';
  END IF;
  UPDATE cleaning_companies SET
    name = coalesce(nullif(trim(p_data->>'name'), ''), name),
    name_normalized = cleaning_normalize_key(coalesce(nullif(trim(p_data->>'name'), ''), name)),
    name_kana = nullif(trim(p_data->>'name_kana'), ''),
    corporate_number = nullif(trim(p_data->>'corporate_number'), ''),
    representative_name = nullif(trim(p_data->>'representative_name'), ''),
    representative_title = nullif(trim(p_data->>'representative_title'), ''),
    postal_code = nullif(trim(p_data->>'postal_code'), ''),
    address = nullif(trim(p_data->>'address'), ''),
    contact_person = nullif(trim(p_data->>'contact_person'), ''),
    contact_email = nullif(trim(p_data->>'contact_email'), ''),
    contact_phone = nullif(trim(p_data->>'contact_phone'), ''),
    contact_department = nullif(trim(p_data->>'contact_department'), ''),
    fax = nullif(trim(p_data->>'fax'), ''),
    pension_office_symbol = nullif(trim(p_data->>'pension_office_symbol'), ''),
    health_insurance_symbol = nullif(trim(p_data->>'health_insurance_symbol'), ''),
    employment_insurance_number = nullif(trim(p_data->>'employment_insurance_number'), ''),
    labor_insurance_number = nullif(trim(p_data->>'labor_insurance_number'), ''),
    notes = nullif(trim(p_data->>'notes'), ''),
    updated_at = now()
  WHERE id = p_company_id;
  RETURN true;
END;
$$;

-- ============================================================
--  社員プロフィール
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_get_staff_profile(p_staff_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', s.id,
    'company_id', s.company_id,
    'name', s.name,
    'name_kana', s.name_kana,
    'birth_date', s.birth_date,
    'gender', s.gender,
    'postal_code', s.postal_code,
    'address', s.address,
    'phone', s.phone,
    'mobile', s.mobile,
    'email', s.email,
    'emergency_contact_name', s.emergency_contact_name,
    'emergency_contact_relation', s.emergency_contact_relation,
    'emergency_contact_phone', s.emergency_contact_phone,
    'employee_number', s.employee_number,
    'department', s.department,
    'position', s.position,
    'employment_type', s.employment_type,
    'hire_date', s.hire_date,
    'resignation_date', s.resignation_date,
    'bank_name', s.bank_name,
    'bank_branch', s.bank_branch,
    'bank_account_type', s.bank_account_type,
    'bank_account_number', s.bank_account_number,
    'bank_account_holder', s.bank_account_holder,
    'basic_pension_number', s.basic_pension_number,
    'insured_number', s.insured_number,
    'standard_monthly_remuneration', s.standard_monthly_remuneration,
    'mention_name', s.mention_name,
    'slack_user_id', s.slack_user_id,
    'is_active', s.is_active,
    'sort_order', s.sort_order,
    'profile_notes', s.profile_notes
  )
  FROM cleaning_staff s WHERE s.id = p_staff_id;
$$;

CREATE OR REPLACE FUNCTION cleaning_save_staff_profile(
  p_password text,
  p_staff_id uuid,
  p_data jsonb
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  IF nullif(trim(p_data->>'name'), '') IS NULL THEN
    RAISE EXCEPTION '氏名が必要です';
  END IF;
  UPDATE cleaning_staff SET
    name = trim(p_data->>'name'),
    name_kana = nullif(trim(p_data->>'name_kana'), ''),
    birth_date = cleaning_null_date(p_data->>'birth_date'),
    gender = nullif(trim(p_data->>'gender'), ''),
    postal_code = nullif(trim(p_data->>'postal_code'), ''),
    address = nullif(trim(p_data->>'address'), ''),
    phone = nullif(trim(p_data->>'phone'), ''),
    mobile = nullif(trim(p_data->>'mobile'), ''),
    email = nullif(trim(p_data->>'email'), ''),
    emergency_contact_name = nullif(trim(p_data->>'emergency_contact_name'), ''),
    emergency_contact_relation = nullif(trim(p_data->>'emergency_contact_relation'), ''),
    emergency_contact_phone = nullif(trim(p_data->>'emergency_contact_phone'), ''),
    employee_number = nullif(trim(p_data->>'employee_number'), ''),
    department = nullif(trim(p_data->>'department'), ''),
    position = nullif(trim(p_data->>'position'), ''),
    employment_type = nullif(trim(p_data->>'employment_type'), ''),
    hire_date = cleaning_null_date(p_data->>'hire_date'),
    resignation_date = cleaning_null_date(p_data->>'resignation_date'),
    bank_name = nullif(trim(p_data->>'bank_name'), ''),
    bank_branch = nullif(trim(p_data->>'bank_branch'), ''),
    bank_account_type = nullif(trim(p_data->>'bank_account_type'), ''),
    bank_account_number = nullif(trim(p_data->>'bank_account_number'), ''),
    bank_account_holder = nullif(trim(p_data->>'bank_account_holder'), ''),
    basic_pension_number = nullif(trim(p_data->>'basic_pension_number'), ''),
    insured_number = nullif(trim(p_data->>'insured_number'), ''),
    standard_monthly_remuneration = cleaning_null_numeric(p_data->>'standard_monthly_remuneration'),
    mention_name = nullif(trim(p_data->>'mention_name'), ''),
    slack_user_id = nullif(trim(p_data->>'slack_user_id'), ''),
    is_active = coalesce((p_data->>'is_active')::boolean, is_active),
    profile_notes = nullif(trim(p_data->>'profile_notes'), '')
  WHERE id = p_staff_id;
  IF NOT FOUND THEN RAISE EXCEPTION '社員が見つかりません'; END IF;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION cleaning_create_staff_profile(p_password text, p_data jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_max int;
  v_company_id uuid;
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  IF nullif(trim(p_data->>'name'), '') IS NULL THEN
    RAISE EXCEPTION '氏名が必要です';
  END IF;
  v_company_id := coalesce((p_data->>'company_id')::uuid, cleaning_active_company_id());
  SELECT coalesce(max(sort_order), -1) + 1 INTO v_max
  FROM cleaning_staff WHERE company_id = v_company_id;
  INSERT INTO cleaning_staff (company_id, name, sort_order, is_active)
  VALUES (v_company_id, trim(p_data->>'name'), v_max, true)
  RETURNING id INTO v_id;
  PERFORM cleaning_save_staff_profile(p_password, v_id, p_data);
  RETURN v_id;
END;
$$;

-- ============================================================
--  被扶養者
-- ============================================================
CREATE OR REPLACE FUNCTION cleaning_list_dependents(p_staff_id uuid)
RETURNS TABLE(
  id uuid, staff_id uuid, name text, name_kana text, relationship text,
  birth_date date, gender text, postal_code text, address text,
  occupation text, estimated_annual_income numeric, cohabitation_status text,
  is_foreign_national boolean, qualification_date date, notes text
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT d.id, d.staff_id, d.name, d.name_kana, d.relationship,
         d.birth_date, d.gender, d.postal_code, d.address,
         d.occupation, d.estimated_annual_income, d.cohabitation_status,
         d.is_foreign_national, d.qualification_date, d.notes
  FROM cleaning_staff_dependents d
  WHERE d.staff_id = p_staff_id
  ORDER BY d.created_at;
$$;

CREATE OR REPLACE FUNCTION cleaning_save_dependent(
  p_password text,
  p_staff_id uuid,
  p_data jsonb,
  p_dependent_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_company_id uuid;
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  IF nullif(trim(p_data->>'name'), '') IS NULL THEN
    RAISE EXCEPTION '被扶養者の氏名が必要です';
  END IF;
  SELECT company_id INTO v_company_id FROM cleaning_staff WHERE id = p_staff_id;
  IF v_company_id IS NULL THEN RAISE EXCEPTION '社員が見つかりません'; END IF;

  IF p_dependent_id IS NULL THEN
    INSERT INTO cleaning_staff_dependents (staff_id, company_id, name)
    VALUES (p_staff_id, v_company_id, trim(p_data->>'name'))
    RETURNING id INTO v_id;
  ELSE
    v_id := p_dependent_id;
    UPDATE cleaning_staff_dependents SET staff_id = p_staff_id, company_id = v_company_id
    WHERE id = p_dependent_id;
    IF NOT FOUND THEN RAISE EXCEPTION '被扶養者が見つかりません'; END IF;
  END IF;

  UPDATE cleaning_staff_dependents SET
    name = trim(p_data->>'name'),
    name_kana = nullif(trim(p_data->>'name_kana'), ''),
    relationship = nullif(trim(p_data->>'relationship'), ''),
    birth_date = cleaning_null_date(p_data->>'birth_date'),
    gender = nullif(trim(p_data->>'gender'), ''),
    postal_code = nullif(trim(p_data->>'postal_code'), ''),
    address = nullif(trim(p_data->>'address'), ''),
    occupation = nullif(trim(p_data->>'occupation'), ''),
    estimated_annual_income = cleaning_null_numeric(p_data->>'estimated_annual_income'),
    cohabitation_status = nullif(trim(p_data->>'cohabitation_status'), ''),
    is_foreign_national = coalesce((p_data->>'is_foreign_national')::boolean, false),
    qualification_date = cleaning_null_date(p_data->>'qualification_date'),
    notes = nullif(trim(p_data->>'notes'), ''),
    updated_at = now()
  WHERE id = v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION cleaning_delete_dependent(p_password text, p_dependent_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  DELETE FROM cleaning_staff_dependents WHERE id = p_dependent_id;
  IF NOT FOUND THEN RAISE EXCEPTION '被扶養者が見つかりません'; END IF;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION cleaning_list_companies()
RETURNS TABLE(id uuid, name text, staff_count bigint, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT c.id, c.name, count(s.id), c.created_at
  FROM cleaning_companies c
  LEFT JOIN cleaning_staff s ON s.company_id = c.id AND s.is_active = true
  GROUP BY c.id, c.name, c.created_at
  ORDER BY c.name;
$$;

GRANT EXECUTE ON FUNCTION cleaning_get_company_profile(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_create_company(text, jsonb) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_save_company_profile(text, uuid, jsonb) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_get_staff_profile(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_save_staff_profile(text, uuid, jsonb) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_create_staff_profile(text, jsonb) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_list_dependents(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_save_dependent(text, uuid, jsonb, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_delete_dependent(text, uuid) TO anon, authenticated;

CREATE OR REPLACE FUNCTION cleaning_set_active_company(p_password text, p_company_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
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

GRANT EXECUTE ON FUNCTION cleaning_set_active_company(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_list_companies() TO anon, authenticated;

-- 設定取得（表示中会社名）
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
  active_company_name text
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT
    coalesce(c.rotation_start_date, s.rotation_start_date),
    coalesce(c.slack_enabled, s.slack_enabled, false),
    CASE WHEN coalesce(c.slack_bot_token, s.slack_bot_token) IS NULL
           OR length(coalesce(c.slack_bot_token, s.slack_bot_token)) < 8 THEN NULL
         ELSE '****' || right(coalesce(c.slack_bot_token, s.slack_bot_token), 4) END,
    coalesce(c.slack_channel_id, s.slack_channel_id),
    coalesce(c.cron_hour_jst, s.cron_hour_jst, 9),
    coalesce(c.cron_enabled, s.cron_enabled, true),
    coalesce(c.last_cron_run_at, s.last_cron_run_at),
    coalesce(c.updated_at, s.updated_at),
    c.id,
    c.name
  FROM cleaning_settings s
  LEFT JOIN cleaning_companies c ON c.id = cleaning_active_company_id()
  WHERE s.id = 1;
$$;

GRANT EXECUTE ON FUNCTION cleaning_get_settings() TO anon, authenticated;

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
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_company_id uuid;
BEGIN
  IF NOT cleaning_verify_admin(p_password) THEN
    RAISE EXCEPTION 'パスワードが正しくありません';
  END IF;
  v_company_id := cleaning_active_company_id();
  IF v_company_id IS NOT NULL THEN
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
  ELSE
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
  END IF;
  RETURN true;
END;
$$;

DROP FUNCTION IF EXISTS cleaning_list_staff();
CREATE OR REPLACE FUNCTION cleaning_list_staff()
RETURNS TABLE(
  id uuid, name text, mention_name text, slack_user_id text,
  sort_order int, is_active boolean, email text, department text, company_id uuid
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT s.id, s.name, s.mention_name, s.slack_user_id,
         s.sort_order, s.is_active, s.email, s.department, s.company_id
  FROM cleaning_staff s
  WHERE s.company_id = cleaning_active_company_id()
     OR (cleaning_active_company_id() IS NULL AND s.company_id IS NULL)
  ORDER BY s.sort_order, s.created_at;
$$;

GRANT EXECUTE ON FUNCTION cleaning_save_settings(text, date, boolean, text, text, int, boolean) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cleaning_list_staff() TO anon, authenticated;
