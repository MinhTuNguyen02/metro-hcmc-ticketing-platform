-- =============================================================================
-- METRO HCMC TICKETING PLATFORM - COMPLETE DATABASE INITIALIZATION SCRIPT
-- =============================================================================

-- 1. EXTENSIONS & SCHEMAS
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA public;

-- Wrapper functions in extensions schema for backwards compatibility
CREATE OR REPLACE FUNCTION extensions.uuid_generate_v4() RETURNS uuid AS $$
  SELECT public.gen_random_uuid();
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION extensions.crypt(text, text) RETURNS text AS $$
  SELECT public.crypt($1, $2);
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION extensions.gen_salt(text) RETURNS text AS $$
  SELECT public.gen_salt($1);
$$ LANGUAGE sql;

CREATE SCHEMA IF NOT EXISTS api;
CREATE SCHEMA IF NOT EXISTS internal;
CREATE SCHEMA IF NOT EXISTS batch;

-- Set default search path
SET search_path = public, api, internal, batch, extensions;

-- =============================================================================
-- 2. ENUM TYPES
-- =============================================================================
DO $$ BEGIN
  CREATE TYPE user_role AS ENUM ('CUSTOMER', 'ADMIN', 'INSPECTOR');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
  CREATE TYPE auth_provider AS ENUM ('LOCAL', 'GOOGLE', 'FACEBOOK');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
  CREATE TYPE ticket_status AS ENUM ('NEW', 'ACTIVE', 'USED', 'EXPIRED', 'CANCELLED');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
  CREATE TYPE ticket_product_type AS ENUM ('single_ride', 'day_pass', 'multi_day_pass', 'monthly_pass');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
  CREATE TYPE pay_status AS ENUM ('PENDING', 'SUCCESS', 'FAILED');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
  CREATE TYPE promotion_type AS ENUM ('percent', 'amount');
EXCEPTION WHEN duplicate_object THEN null; END $$;

-- =============================================================================
-- 3. TABLES
-- =============================================================================

-- Lines (Tuyến metro)
CREATE TABLE IF NOT EXISTS lines (
  code TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  color_hex TEXT DEFAULT '#0080FF',
  status TEXT DEFAULT 'active',
  state BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Stations (Nhà ga)
CREATE TABLE IF NOT EXISTS stations (
  code TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  line_code TEXT NOT NULL REFERENCES lines(code) ON DELETE CASCADE,
  order_index INTEGER NOT NULL,
  lat DOUBLE PRECISION,
  lon DOUBLE PRECISION,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT uq_station_line_order UNIQUE (line_code, order_index)
);

-- Segments (Đoạn tuyến giữa 2 ga)
CREATE TABLE IF NOT EXISTS segments (
  line_code TEXT NOT NULL REFERENCES lines(code) ON DELETE CASCADE,
  from_station TEXT NOT NULL REFERENCES stations(code) ON DELETE CASCADE,
  to_station TEXT NOT NULL REFERENCES stations(code) ON DELETE CASCADE,
  travel_min INTEGER NOT NULL DEFAULT 2,
  PRIMARY KEY (line_code, from_station, to_station)
);

-- Fare Rules (Biểu phí giá vé lượt)
CREATE TABLE IF NOT EXISTS fare_rules (
  id SERIAL PRIMARY KEY,
  line_code TEXT NOT NULL REFERENCES lines(code) ON DELETE CASCADE,
  base_price NUMERIC NOT NULL DEFAULT 7000,
  base_stops INTEGER NOT NULL DEFAULT 5,
  step_stops INTEGER NOT NULL DEFAULT 2,
  step_price NUMERIC NOT NULL DEFAULT 2000,
  state BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Ticket Products (Các loại sản phẩm vé)
CREATE TABLE IF NOT EXISTS ticket_products (
  code TEXT PRIMARY KEY,
  name_vi TEXT NOT NULL,
  type ticket_product_type NOT NULL,
  price NUMERIC NOT NULL,
  duration_hours INTEGER DEFAULT 0,
  auto_activate_after_days INTEGER DEFAULT 30,
  state BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Users (Người dùng: Khách hàng, Admin, Nhân viên soát vé)
CREATE TABLE IF NOT EXISTS users (
  user_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name TEXT NOT NULL,
  primary_email TEXT UNIQUE NOT NULL,
  phone_number TEXT,
  address TEXT,
  cccd TEXT,
  birth_date DATE,
  role user_role DEFAULT 'CUSTOMER',
  avatar_url TEXT,
  email_verified BOOLEAN DEFAULT FALSE,
  is_active BOOLEAN DEFAULT TRUE,
  face_descriptor TEXT,
  biometric_token TEXT,
  is_biometric_enabled BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Auth Identities (Tài khoản đăng nhập local / OAuth)
CREATE TABLE IF NOT EXISTS auth_identities (
  identity_id SERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  provider auth_provider DEFAULT 'LOCAL',
  email TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  is_primary BOOLEAN DEFAULT TRUE,
  provider_user_id TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT uq_identity_provider_email UNIQUE (provider, email)
);

-- Auth Tokens (Quản lý phiên đăng nhập và Reset Password)
CREATE TABLE IF NOT EXISTS auth_tokens (
  token UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  token_type TEXT DEFAULT 'ACCESS',
  issued_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  client_ip TEXT,
  user_agent TEXT
);

-- Promotions (Chương trình khuyến mãi & Giftcode)
CREATE TABLE IF NOT EXISTS promotions (
  promo_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  description TEXT,
  promo_type promotion_type NOT NULL DEFAULT 'amount',
  discount_percent NUMERIC,
  discount_amount NUMERIC,
  starts_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ends_at TIMESTAMPTZ,
  min_order_amount NUMERIC DEFAULT 0,
  max_usage INTEGER DEFAULT 1,
  used_count INTEGER DEFAULT 0,
  ticket_product_code TEXT REFERENCES ticket_products(code),
  state BOOLEAN DEFAULT TRUE,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Tickets (Vé đã mua/đổi)
CREATE TABLE IF NOT EXISTS tickets (
  ticket_id SERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  product_code TEXT NOT NULL REFERENCES ticket_products(code),
  from_station TEXT REFERENCES stations(code),
  to_station TEXT REFERENCES stations(code),
  stops INTEGER,
  final_price NUMERIC NOT NULL DEFAULT 0,
  qr_code TEXT UNIQUE NOT NULL DEFAULT ('TK-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 12))),
  status ticket_status DEFAULT 'NEW',
  valid_from TIMESTAMPTZ,
  valid_to TIMESTAMPTZ,
  used_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Payments (Giao dịch thanh toán PayOS / Tiền mặt / Giftcode)
CREATE TABLE IF NOT EXISTS payments (
  payment_id SERIAL PRIMARY KEY,
  ticket_id INTEGER NOT NULL REFERENCES tickets(ticket_id) ON DELETE CASCADE,
  method TEXT NOT NULL DEFAULT 'PAYOS',
  amount NUMERIC NOT NULL,
  status pay_status DEFAULT 'PENDING',
  transaction_id TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Validations (Lịch sử soát vé / quét QR tại ga)
CREATE TABLE IF NOT EXISTS validations (
  validation_id SERIAL PRIMARY KEY,
  ticket_id INTEGER NOT NULL REFERENCES tickets(ticket_id) ON DELETE CASCADE,
  station_code TEXT NOT NULL REFERENCES stations(code) ON DELETE CASCADE,
  direction TEXT DEFAULT 'IN',
  validated_by UUID REFERENCES users(user_id) ON DELETE SET NULL,
  validated_at TIMESTAMPTZ DEFAULT NOW(),
  note TEXT
);

-- Audit Log (Nhật ký kiểm toán hệ thống)
CREATE TABLE IF NOT EXISTS audit_log (
  log_id SERIAL PRIMARY KEY,
  actor_user UUID REFERENCES users(user_id) ON DELETE SET NULL,
  action TEXT NOT NULL,
  object_type TEXT,
  object_id TEXT,
  payload_json JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Announcements (Thông báo hệ thống)
CREATE TABLE IF NOT EXISTS announcements (
  ann_id SERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  content_md TEXT NOT NULL,
  visible_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  visible_to TIMESTAMPTZ,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Feedbacks (Góp ý của hành khách)
CREATE TABLE IF NOT EXISTS feedbacks (
  id SERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  title TEXT,
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Notifications (Thông báo cá nhân / Quà tặng gửi riêng)
CREATE TABLE IF NOT EXISTS notifications (
  id SERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  content TEXT NOT NULL,
  type TEXT DEFAULT 'PERSONAL',
  is_read BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- 4. INTERNAL HELPER FUNCTIONS & TRIGGERS
-- =============================================================================

-- Trigger: Tự động cập nhật used_at khi vé chuyển sang trạng thái USED
CREATE OR REPLACE FUNCTION internal.tickets_set_used_at()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'USED' AND (OLD.status IS NULL OR OLD.status != 'USED') THEN
    IF NEW.used_at IS NULL THEN
      NEW.used_at := NOW();
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_tickets_set_used_at ON tickets;
CREATE TRIGGER trg_tickets_set_used_at
BEFORE UPDATE ON tickets
FOR EACH ROW
EXECUTE FUNCTION internal.tickets_set_used_at();

-- Helper: Kiểm tra vé pass có còn hiệu lực không
CREATE OR REPLACE FUNCTION internal.fn_is_ticket_in_effect(p_ticket_id integer, p_scan_time timestamptz)
RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_in_effect boolean;
BEGIN
  SELECT (valid_to IS NULL OR valid_to >= p_scan_time)
     AND (valid_from IS NULL OR valid_from <= p_scan_time)
  INTO v_in_effect
  FROM tickets
  WHERE ticket_id = p_ticket_id;

  RETURN COALESCE(v_in_effect, FALSE);
END;
$$;

-- Helper: Tính số ga đi qua giữa 2 trạm
CREATE OR REPLACE FUNCTION internal.fn_calc_stops(p_line_code text, p_from_station text, p_to_station text)
RETURNS integer
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_from_idx integer;
  v_to_idx integer;
BEGIN
  SELECT order_index INTO v_from_idx FROM stations WHERE line_code = p_line_code AND code = p_from_station;
  SELECT order_index INTO v_to_idx FROM stations WHERE line_code = p_line_code AND code = p_to_station;

  IF v_from_idx IS NULL OR v_to_idx IS NULL THEN
    RETURN 1;
  END IF;

  RETURN ABS(v_from_idx - v_to_idx);
END;
$$;

-- Helper: Tính giá vé lượt dựa vào biểu phí
CREATE OR REPLACE FUNCTION internal.calc_single_ride_fare_simple(p_line_code text, p_stops integer)
RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_rule fare_rules%ROWTYPE;
BEGIN
  SELECT * INTO v_rule
  FROM fare_rules
  WHERE line_code = p_line_code AND state = TRUE
  ORDER BY id DESC LIMIT 1;

  IF NOT FOUND THEN
    RETURN 15000;
  END IF;

  IF p_stops <= v_rule.base_stops THEN
    RETURN v_rule.base_price;
  ELSE
    RETURN v_rule.base_price + CEIL((p_stops - v_rule.base_stops)::numeric / v_rule.step_stops) * v_rule.step_price;
  END IF;
END;
$$;

-- Helper: Áp dụng mã khuyến mãi tính số tiền giảm
CREATE OR REPLACE FUNCTION internal.fn_apply_promotion(p_base_price numeric, p_promo_code text, p_now timestamptz)
RETURNS TABLE (base numeric, discount numeric, final numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_promo promotions%ROWTYPE;
  v_discount numeric := 0;
BEGIN
  IF p_promo_code IS NULL OR trim(p_promo_code) = '' THEN
    RETURN QUERY SELECT p_base_price, 0::numeric, p_base_price;
    RETURN;
  END IF;

  SELECT * INTO v_promo
  FROM promotions
  WHERE UPPER(code) = UPPER(trim(p_promo_code))
    AND state = TRUE AND is_active = TRUE
    AND starts_at <= p_now
    AND (ends_at IS NULL OR ends_at >= p_now)
    AND (used_count < max_usage)
    AND p_base_price >= COALESCE(min_order_amount, 0)
  LIMIT 1;

  IF FOUND THEN
    IF v_promo.promo_type = 'percent' THEN
      v_discount := ROUND(p_base_price * COALESCE(v_promo.discount_percent, 0) / 100);
    ELSE
      v_discount := LEAST(p_base_price, COALESCE(v_promo.discount_amount, 0));
    END IF;
    RETURN QUERY SELECT p_base_price, v_discount, GREATEST(0::numeric, p_base_price - v_discount);
  ELSE
    RETURN QUERY SELECT p_base_price, 0::numeric, p_base_price;
  END IF;
END;
$$;

-- =============================================================================
-- 5. BATCH BACKGROUND JOBS FUNCTIONS
-- =============================================================================

-- Batch: Tự động kích hoạt các vé gói đã quá hạn chờ kích hoạt
CREATE OR REPLACE FUNCTION batch.fn_auto_activate_due_json() RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_count integer := 0;
  v_ticket RECORD;
BEGIN
  FOR v_ticket IN
    SELECT t.ticket_id, tp.duration_hours
    FROM tickets t
    JOIN ticket_products tp ON t.product_code = tp.code
    JOIN payments p ON t.ticket_id = p.ticket_id AND p.status = 'SUCCESS'
    WHERE t.status = 'NEW'
      AND tp.type != 'single_ride'
      AND NOW() >= (t.created_at + (COALESCE(tp.auto_activate_after_days, 30) || ' days')::interval)
  LOOP
    UPDATE tickets
    SET status = 'ACTIVE',
        valid_from = NOW(),
        valid_to = NOW() + (COALESCE(v_ticket.duration_hours, 24) || ' hours')::interval
    WHERE ticket_id = v_ticket.ticket_id;

    INSERT INTO audit_log (action, object_type, object_id, payload_json)
    VALUES ('AUTO_ACTIVATE_PASS', 'ticket', v_ticket.ticket_id::text, jsonb_build_object('is_auto', true));

    v_count := v_count + 1;
  END LOOP;

  RETURN json_build_object('success', TRUE, 'activated_count', v_count);
END;
$$;

-- Batch: Tự động đánh dấu hết hạn cho vé pass
CREATE OR REPLACE FUNCTION batch.fn_expire_passes_due() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  v_count integer := 0;
BEGIN
  WITH expired AS (
    UPDATE tickets
    SET status = 'EXPIRED'
    WHERE status = 'ACTIVE'
      AND valid_to IS NOT NULL
      AND valid_to < NOW()
    RETURNING ticket_id
  )
  SELECT COUNT(*) INTO v_count FROM expired;

  RETURN v_count;
END;
$$;

-- Batch: Dọn dẹp các vé chưa thanh toán quá 30 phút
CREATE OR REPLACE FUNCTION batch.fn_cleanup_unpaid_tickets() RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_count integer := 0;
BEGIN
  WITH cancelled AS (
    UPDATE tickets
    SET status = 'CANCELLED'
    WHERE status = 'NEW'
      AND created_at < NOW() - INTERVAL '30 minutes'
      AND NOT EXISTS (
        SELECT 1 FROM payments WHERE payments.ticket_id = tickets.ticket_id AND payments.status = 'SUCCESS'
      )
    RETURNING ticket_id
  )
  SELECT COUNT(*) INTO v_count FROM cancelled;

  UPDATE payments
  SET status = 'FAILED'
  WHERE status = 'PENDING'
    AND created_at < NOW() - INTERVAL '30 minutes';

  RETURN json_build_object('cleaned_count', v_count);
END;
$$;

-- =============================================================================
-- 6. API FUNCTIONS: AUTH & USER PROFILE
-- =============================================================================

-- Đăng ký tài khoản (Hỗ trợ cả 7 tham số đầy đủ)
CREATE OR REPLACE FUNCTION api.fn_auth_register_json(
  p_email text,
  p_password text,
  p_display_name text,
  p_phone_number text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_cccd text DEFAULT NULL,
  p_birth_date date DEFAULT NULL
) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_user_id uuid;
  v_password_hash text;
  v_token uuid;
  v_expires_at timestamp;
  v_email_exists boolean;
BEGIN
  IF p_email IS NULL OR trim(p_email) = '' THEN
    RETURN json_build_object('success', FALSE, 'message', 'Email là bắt buộc');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM auth_identities WHERE provider = 'LOCAL' AND LOWER(email) = LOWER(trim(p_email))
  ) INTO v_email_exists;

  IF v_email_exists THEN
    RETURN json_build_object('success', FALSE, 'message', 'Email đã được đăng ký');
  END IF;

  INSERT INTO users (display_name, primary_email, phone_number, address, cccd, birth_date, role, is_active)
  VALUES (p_display_name, trim(p_email), p_phone_number, p_address, p_cccd, p_birth_date, 'CUSTOMER', TRUE)
  RETURNING user_id INTO v_user_id;

  v_password_hash := extensions.crypt(p_password, extensions.gen_salt('bf'));

  INSERT INTO auth_identities (user_id, provider, email, password_hash, is_primary, provider_user_id)
  VALUES (v_user_id, 'LOCAL', trim(p_email), v_password_hash, TRUE, trim(p_email));

  v_token := extensions.uuid_generate_v4();
  v_expires_at := NOW() + INTERVAL '10 minutes';

  INSERT INTO auth_tokens (token, user_id, issued_at, expires_at)
  VALUES (v_token, v_user_id, NOW(), v_expires_at);

  RETURN json_build_object(
    'success', TRUE,
    'user', json_build_object(
      'user_id', v_user_id,
      'email', trim(p_email),
      'display_name', p_display_name,
      'role', 'CUSTOMER'
    ),
    'token', v_token,
    'token_expires_at', v_expires_at
  );
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', FALSE, 'message', SQLERRM);
END;
$$;

-- Đăng ký overload 3 tham số
CREATE OR REPLACE FUNCTION api.fn_auth_register_json(p_email text, p_password text, p_display_name text) RETURNS json
LANGUAGE plpgsql AS $$
BEGIN
  RETURN api.fn_auth_register_json(p_email, p_password, p_display_name, NULL, NULL, NULL, NULL);
END;
$$;

-- Đăng nhập tài khoản
CREATE OR REPLACE FUNCTION api.fn_auth_login_json(
  p_provider auth_provider,
  p_email text,
  p_password text,
  p_provider_user_id text DEFAULT NULL
) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_user_id uuid;
  v_display_name text;
  v_primary_email text;
  v_role user_role;
  v_is_active boolean;
  v_password_hash text;
  v_token uuid;
  v_issued_at timestamp;
  v_expires_at timestamp;
BEGIN
  IF p_provider = 'LOCAL' THEN
    IF p_email IS NULL OR trim(p_email) = '' OR p_password IS NULL THEN
      RETURN json_build_object('success', FALSE, 'message', 'Email và mật khẩu không được để trống');
    END IF;

    SELECT u.user_id, u.display_name, u.primary_email, u.role, u.is_active, ai.password_hash
    INTO v_user_id, v_display_name, v_primary_email, v_role, v_is_active, v_password_hash
    FROM auth_identities ai
    JOIN users u ON u.user_id = ai.user_id
    WHERE ai.provider = 'LOCAL' AND LOWER(ai.email) = LOWER(trim(p_email))
    LIMIT 1;

    IF NOT FOUND OR extensions.crypt(p_password, v_password_hash) <> v_password_hash THEN
      RETURN json_build_object('success', FALSE, 'message', 'Tài khoản hoặc mật khẩu không chính xác');
    END IF;

    IF NOT v_is_active THEN
       RETURN json_build_object('success', FALSE, 'message', 'Tài khoản đã bị tạm khóa');
    END IF;
  ELSE
    RETURN json_build_object('success', FALSE, 'message', 'Phương thức đăng nhập không hỗ trợ');
  END IF;

  v_token := extensions.uuid_generate_v4();
  v_issued_at := NOW();
  v_expires_at := NOW() + INTERVAL '10 minutes';

  INSERT INTO auth_tokens (token, user_id, issued_at, expires_at, client_ip, user_agent)
  VALUES (v_token, v_user_id, v_issued_at, v_expires_at, NULL, NULL);

  RETURN json_build_object(
    'success', TRUE,
    'user', json_build_object(
      'user_id', v_user_id,
      'email', v_primary_email,
      'display_name', v_display_name,
      'role', v_role
    ),
    'token', v_token,
    'token_expires_at', v_expires_at
  );
END;
$$;

-- Lấy thông tin tài khoản qua Token (Auth middleware)
CREATE OR REPLACE FUNCTION api.fn_auth_get_me_json(p_token uuid) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_user_id uuid;
  v_expires_at timestamp;
  v_user users%ROWTYPE;
BEGIN
  SELECT user_id, expires_at INTO v_user_id, v_expires_at
  FROM auth_tokens
  WHERE token = p_token
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN json_build_object('success', FALSE, 'error_code', 'INVALID_TOKEN', 'message', 'Token không tồn tại');
  END IF;

  IF v_expires_at <= NOW() THEN
    RETURN json_build_object('success', FALSE, 'error_code', 'TOKEN_EXPIRED', 'message', 'Phiên đăng nhập đã hết hạn');
  END IF;

  SELECT * INTO v_user FROM users WHERE user_id = v_user_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', FALSE, 'error_code', 'USER_NOT_FOUND', 'message', 'Không tìm thấy người dùng');
  END IF;

  IF NOT v_user.is_active THEN
    RETURN json_build_object('success', FALSE, 'error_code', 'USER_INACTIVE', 'message', 'Tài khoản đã bị tạm khóa');
  END IF;

  RETURN json_build_object(
    'success', TRUE,
    'user', json_build_object(
      'user_id', v_user.user_id,
      'display_name', v_user.display_name,
      'primary_email', v_user.primary_email,
      'phone_number', v_user.phone_number,
      'address', v_user.address,
      'cccd', v_user.cccd,
      'birth_date', v_user.birth_date,
      'role', v_user.role,
      'avatar_url', v_user.avatar_url,
      'email_verified', v_user.email_verified,
      'created_at', v_user.created_at,
      'updated_at', v_user.updated_at
    )
  );
END;
$$;

-- Quên mật khẩu tạo token reset
CREATE OR REPLACE FUNCTION api.fn_auth_forgot_password_json(p_email text) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_user_id uuid;
  v_reset_token uuid;
  v_expires_at timestamp;
BEGIN
  IF p_email IS NULL OR trim(p_email) = '' THEN
    RETURN json_build_object('success', FALSE, 'message', 'Email không hợp lệ');
  END IF;

  SELECT user_id INTO v_user_id
  FROM auth_identities
  WHERE provider = 'LOCAL' AND LOWER(email) = LOWER(trim(p_email))
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN json_build_object('success', FALSE, 'message', 'Email không tồn tại trong hệ thống');
  END IF;

  v_reset_token := extensions.uuid_generate_v4();
  v_expires_at := NOW() + INTERVAL '10 minutes';

  INSERT INTO auth_tokens(token, user_id, issued_at, expires_at, token_type)
  VALUES (v_reset_token, v_user_id, NOW(), v_expires_at, 'RESET_PASSWORD');

  RETURN json_build_object(
    'success', TRUE,
    'reset_token', v_reset_token,
    'expires_at', v_expires_at
  );
END;
$$;

-- Đổi mật khẩu qua reset token
CREATE OR REPLACE FUNCTION api.fn_auth_reset_password_json(p_reset_token uuid, p_new_password text) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_user_id uuid;
  v_hash text;
BEGIN
  IF p_reset_token IS NULL THEN
    RETURN json_build_object('success', FALSE, 'message', 'Token không được để trống');
  END IF;

  IF p_new_password IS NULL OR trim(p_new_password) = '' THEN
    RETURN json_build_object('success', FALSE, 'message', 'Mật khẩu mới không được để trống');
  END IF;

  SELECT user_id INTO v_user_id
  FROM auth_tokens
  WHERE token = p_reset_token
    AND token_type = 'RESET_PASSWORD'
    AND expires_at > NOW()
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN json_build_object('success', FALSE, 'message', 'Token không hợp lệ hoặc đã hết hạn');
  END IF;

  v_hash := extensions.crypt(p_new_password, extensions.gen_salt('bf'));

  UPDATE auth_identities
  SET password_hash = v_hash
  WHERE user_id = v_user_id AND provider = 'LOCAL';

  DELETE FROM auth_tokens WHERE token = p_reset_token;

  RETURN json_build_object('success', TRUE, 'message', 'Đặt lại mật khẩu thành công');
END;
$$;

-- Đổi mật khẩu khi đang đăng nhập (có mật khẩu cũ)
CREATE OR REPLACE FUNCTION api.change_password_with_token(p_token uuid, p_old_password text, p_new_password text) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_user_id uuid;
  v_expires_at timestamptz;
  v_hash text;
  v_new_hash text;
BEGIN
  SELECT user_id, expires_at INTO v_user_id, v_expires_at
  FROM auth_tokens WHERE token = p_token;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Token không hợp lệ';
  END IF;

  IF v_expires_at <= NOW() THEN
    RAISE EXCEPTION 'Token đã hết hạn';
  END IF;

  SELECT password_hash INTO v_hash
  FROM auth_identities WHERE user_id = v_user_id AND provider = 'LOCAL';

  IF NOT FOUND OR extensions.crypt(p_old_password, v_hash) <> v_hash THEN
    RAISE EXCEPTION 'Mật khẩu cũ không chính xác';
  END IF;

  v_new_hash := extensions.crypt(p_new_password, extensions.gen_salt('bf'));

  UPDATE auth_identities
  SET password_hash = v_new_hash
  WHERE user_id = v_user_id AND provider = 'LOCAL';

  RETURN json_build_object('success', TRUE, 'message', 'Đổi mật khẩu thành công');
END;
$$;

-- Cập nhật thông tin người dùng
CREATE OR REPLACE FUNCTION api.update_user_profile(
  p_user_id uuid,
  p_display_name text,
  p_phone_number text,
  p_address text,
  p_cccd text,
  p_birth_date date
) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_user users%ROWTYPE;
BEGIN
  UPDATE users
  SET display_name = COALESCE(NULLIF(p_display_name, ''), display_name),
      phone_number = COALESCE(p_phone_number, phone_number),
      address      = COALESCE(p_address, address),
      cccd         = COALESCE(p_cccd, cccd),
      birth_date   = COALESCE(p_birth_date, birth_date),
      updated_at   = NOW()
  WHERE user_id = p_user_id
  RETURNING * INTO v_user;

  IF NOT FOUND THEN
    RETURN json_build_object('success', FALSE, 'message', 'Không tìm thấy người dùng');
  END IF;

  RETURN json_build_object(
    'success', TRUE,
    'user', json_build_object(
      'user_id', v_user.user_id,
      'display_name', v_user.display_name,
      'primary_email', v_user.primary_email,
      'phone_number', v_user.phone_number,
      'address', v_user.address,
      'cccd', v_user.cccd,
      'birth_date', v_user.birth_date,
      'role', v_user.role,
      'avatar_url', v_user.avatar_url
    )
  );
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', FALSE, 'message', SQLERRM);
END;
$$;

-- Đăng nhập bằng sinh trắc học
CREATE OR REPLACE FUNCTION api.fn_auth_login_biometric_json(p_biometric_token text) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_user users%ROWTYPE;
  v_token uuid;
  v_expires_at timestamptz;
BEGIN
  SELECT * INTO v_user
  FROM users
  WHERE biometric_token = p_biometric_token
    AND is_biometric_enabled = TRUE
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN json_build_object('success', FALSE, 'message', 'Xác thực sinh trắc học không thành công hoặc tài khoản bị khóa');
  END IF;

  v_token := extensions.uuid_generate_v4();
  v_expires_at := NOW() + INTERVAL '10 minutes';

  INSERT INTO auth_tokens (token, user_id, issued_at, expires_at)
  VALUES (v_token, v_user.user_id, NOW(), v_expires_at);

  RETURN json_build_object(
    'success', TRUE,
    'token', v_token,
    'token_expires_at', v_expires_at,
    'user', json_build_object(
      'user_id', v_user.user_id,
      'email', v_user.primary_email,
      'display_name', v_user.display_name,
      'role', v_user.role
    )
  );
END;
$$;

-- Lấy danh sách thông báo cho mobile (cá nhân + thông báo chung)
CREATE OR REPLACE FUNCTION api.fn_get_user_notifications_json(p_user_id uuid) RETURNS json
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (
    SELECT COALESCE(json_agg(
      json_build_object(
        'id', n.id,
        'title', n.title,
        'content', n.content,
        'type', n.type,
        'is_read', n.is_read,
        'created_at', n.created_at
      ) ORDER BY n.created_at DESC
    ), '[]'::json)
    FROM (
      SELECT id::text, title, content, type, is_read, created_at
      FROM notifications
      WHERE user_id = p_user_id
      UNION ALL
      SELECT ('ann_' || ann_id)::text AS id, title, content_md AS content, 'PUBLIC' AS type, FALSE AS is_read, created_at
      FROM announcements
      WHERE is_active = TRUE AND visible_from <= NOW() AND (visible_to IS NULL OR visible_to >= NOW())
    ) n
  );
END;
$$;

-- =============================================================================
-- 7. API FUNCTIONS: TICKETING & VALIDATION
-- =============================================================================

-- Quét vé / Kích hoạt vé (Hỗ trợ 5 tham số: qr_code, station_code, direction, actor_user, is_auto)
CREATE OR REPLACE FUNCTION api.fn_activate_or_use_ticket_json(
  p_qr_code text,
  p_station_code text,
  p_direction text DEFAULT 'IN',
  p_actor_user uuid DEFAULT NULL::uuid,
  p_is_auto boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_ticket tickets%ROWTYPE;
  v_product ticket_products%ROWTYPE;
  v_payment_status pay_status;
  v_scan_time TIMESTAMPTZ := NOW();
  v_action_type TEXT;
  v_validation_note TEXT;
  v_response JSONB;
BEGIN
  -- 1. Lấy thông tin vé và sản phẩm
  SELECT * INTO v_ticket FROM tickets t WHERE t.qr_code = p_qr_code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'message', 'QR Code không hợp lệ hoặc không tìm thấy vé.');
  END IF;

  SELECT * INTO v_product FROM ticket_products p WHERE p.code = v_ticket.product_code;
  IF NOT FOUND THEN
     RETURN jsonb_build_object('success', FALSE, 'message', 'Không tìm thấy thông tin sản phẩm của vé.');
  END IF;

  -- 2. Kiểm tra thanh toán
  IF NOT p_is_auto THEN
    SELECT status INTO v_payment_status
    FROM payments
    WHERE ticket_id = v_ticket.ticket_id AND status = 'SUCCESS'
    LIMIT 1;

    IF v_payment_status IS NULL THEN
      RETURN jsonb_build_object('success', FALSE, 'status', 'UNPAID', 'message', 'Vé chưa được thanh toán.');
    END IF;
  END IF;

  -- 3. Xử lý State Machine
  CASE v_ticket.status
    WHEN 'NEW' THEN
      IF v_product.type = 'single_ride' THEN
        UPDATE tickets
        SET status = 'USED', valid_from = v_scan_time
        WHERE ticket_id = v_ticket.ticket_id;

        v_action_type := 'USE_SINGLE_RIDE';
        v_validation_note := 'Sử dụng vé lượt thành công (' || COALESCE(p_direction, 'IN') || ')';
        v_response := jsonb_build_object('success', TRUE, 'status', 'USED', 'message', 'Vé lượt đã được sử dụng.');
      ELSE
        UPDATE tickets
        SET status = 'ACTIVE',
            valid_from = v_scan_time,
            valid_to = v_scan_time + (v_product.duration_hours || ' hours')::interval
        WHERE ticket_id = v_ticket.ticket_id;

        IF p_is_auto THEN
          v_action_type := 'AUTO_ACTIVATE_PASS';
          v_validation_note := 'Tự động kích hoạt vé pass';
          v_response := jsonb_build_object('success', TRUE, 'status', 'ACTIVE', 'message', 'Vé pass đã được tự động kích hoạt.');
        ELSE
          v_action_type := 'ACTIVATE_PASS';
          v_validation_note := 'Kích hoạt vé pass';
          v_response := jsonb_build_object('success', TRUE, 'status', 'ACTIVE', 'message', 'Vé pass đã được kích hoạt.');
        END IF;
      END IF;

    WHEN 'ACTIVE' THEN
      IF internal.fn_is_ticket_in_effect(v_ticket.ticket_id, v_scan_time) THEN
        v_action_type := 'VALIDATE_PASS';
        v_validation_note := 'Quét vé pass hợp lệ (' || COALESCE(p_direction, 'IN') || ')';
        v_response := jsonb_build_object('success', TRUE, 'status', 'ACTIVE', 'message', 'Vé pass hợp lệ.');
      ELSE
        UPDATE tickets SET status = 'EXPIRED' WHERE ticket_id = v_ticket.ticket_id;
        v_action_type := 'VALIDATE_EXPIRED_PASS';
        v_validation_note := 'Quét vé pass đã hết hạn';
        v_response := jsonb_build_object('success', FALSE, 'status', 'EXPIRED', 'message', 'Vé pass đã hết hạn.');
      END IF;

    WHEN 'USED' THEN
      v_response := jsonb_build_object('success', FALSE, 'status', 'USED', 'message', 'Vé này đã được sử dụng.');
    WHEN 'EXPIRED' THEN
      v_response := jsonb_build_object('success', FALSE, 'status', 'EXPIRED', 'message', 'Vé này đã hết hạn.');
    WHEN 'CANCELLED' THEN
      v_response := jsonb_build_object('success', FALSE, 'status', 'CANCELLED', 'message', 'Vé này đã bị huỷ.');
  END CASE;

  -- 4. Ghi log validation
  IF v_action_type IS NOT NULL AND NOT p_is_auto THEN
    INSERT INTO validations (ticket_id, station_code, direction, validated_by, validated_at, note)
    VALUES (v_ticket.ticket_id, p_station_code, COALESCE(p_direction, 'IN'), p_actor_user, v_scan_time, v_validation_note);
  END IF;

  IF v_action_type IS NOT NULL THEN
    INSERT INTO audit_log (actor_user, action, object_type, object_id, payload_json)
    VALUES (p_actor_user, v_action_type, 'ticket', v_ticket.ticket_id::text, jsonb_build_object('station', p_station_code, 'direction', p_direction, 'is_auto', p_is_auto));
  END IF;

  RETURN v_response;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', FALSE, 'message', SQLERRM);
END;
$$;

-- Overload 4 tham số cho fn_activate_or_use_ticket_json
CREATE OR REPLACE FUNCTION api.fn_activate_or_use_ticket_json(
  p_qr_code text,
  p_station_code text,
  p_actor_user uuid,
  p_is_auto boolean
) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  RETURN api.fn_activate_or_use_ticket_json(p_qr_code, p_station_code, 'IN', p_actor_user, p_is_auto);
END;
$$;

-- Báo giá vé lượt
CREATE OR REPLACE FUNCTION api.fn_quote_single_json(line_code text, from_station text, to_station text, promo_code text DEFAULT NULL::text) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_stops INT;
  v_base_price NUMERIC(12,2);
  v_promotion_result RECORD;
BEGIN
  v_stops := internal.fn_calc_stops(line_code, from_station, to_station);
  v_base_price := internal.calc_single_ride_fare_simple(line_code, v_stops);

  SELECT base, discount, final
  INTO v_promotion_result
  FROM internal.fn_apply_promotion(v_base_price, promo_code, NOW());

  RETURN json_build_object(
    'data', json_build_object(
      'line_code', line_code,
      'from_station', from_station,
      'to_station', to_station,
      'stops', v_stops,
      'base_price', v_base_price,
      'promo_code', promo_code,
      'discount', v_promotion_result.discount,
      'final_price', v_promotion_result.final,
      'currency', 'VND'
    )
  );
END;
$$;

-- Tạo vé lượt
CREATE OR REPLACE FUNCTION api.fn_create_ticket_single_json(
  user_id uuid,
  line_code text,
  from_station text,
  to_station text,
  stops integer,
  final_price numeric,
  promo_code text DEFAULT NULL::text
) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  new_ticket_id INT;
  v_product_code TEXT := 'L1_SINGLE';
BEGIN
  INSERT INTO tickets (
    user_id, product_code, from_station, to_station, stops, final_price, status
  ) VALUES (
    user_id, v_product_code, from_station, to_station, stops, final_price, 'NEW'
  ) RETURNING ticket_id INTO new_ticket_id;

  INSERT INTO audit_log (actor_user, action, object_type, object_id, payload_json)
  VALUES (user_id, 'TICKET_CREATED_SINGLE', 'TICKET', new_ticket_id::TEXT,
    json_build_object('final_price', final_price, 'promo_code', promo_code, 'from', from_station, 'to', to_station));

  RETURN json_build_object(
    'data', json_build_object(
      'ticket', (SELECT row_to_json(t) FROM tickets t WHERE t.ticket_id = new_ticket_id),
      'message', 'Single ride ticket created successfully. Awaiting payment.'
    )
  );
END;
$$;

-- Tạo vé pass (4 tham số: user_id, product_code, final_price, promo_code)
CREATE OR REPLACE FUNCTION api.fn_create_ticket_pass_json(
  user_id uuid,
  product_code text,
  final_price numeric,
  promo_code text DEFAULT NULL::text
) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  new_ticket_id INT;
  v_product RECORD;
  v_calc_price NUMERIC;
BEGIN
  SELECT price, type, duration_hours INTO v_product
  FROM ticket_products
  WHERE code = product_code AND state = TRUE AND type != 'single_ride';

  IF v_product.price IS NULL THEN
    RAISE EXCEPTION 'Invalid or single_ride product code: %', product_code;
  END IF;

  v_calc_price := COALESCE(final_price, v_product.price);

  INSERT INTO tickets (
    user_id, product_code, final_price, status
  ) VALUES (
    user_id, product_code, v_calc_price, 'NEW'
  ) RETURNING ticket_id INTO new_ticket_id;

  RETURN json_build_object(
    'data', json_build_object(
      'ticket', (SELECT row_to_json(t) FROM tickets t WHERE t.ticket_id = new_ticket_id),
      'message', 'Pass ticket created successfully. Awaiting payment.'
    )
  );
END;
$$;

-- Overload 3 tham số cho fn_create_ticket_pass_json
CREATE OR REPLACE FUNCTION api.fn_create_ticket_pass_json(user_id uuid, product_code text, promo_code text DEFAULT NULL::text) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_prod ticket_products%ROWTYPE;
  v_final numeric;
BEGIN
  SELECT * INTO v_prod FROM ticket_products WHERE code = product_code;
  SELECT final INTO v_final FROM internal.fn_apply_promotion(v_prod.price, promo_code, NOW());
  RETURN api.fn_create_ticket_pass_json(user_id, product_code, v_final, promo_code);
END;
$$;

-- Lấy chi tiết vé (kèm mã QR)
CREATE OR REPLACE FUNCTION api.fn_get_ticket_json(ticket_id integer) RETURNS json
LANGUAGE plpgsql STABLE AS $_$
DECLARE
  v_ticket_data JSON;
BEGIN
  SELECT json_build_object(
    'ticket_id', t.ticket_id,
    'user_id', t.user_id,
    'product_code', t.product_code,
    'type', tp.type,
    'product_name', tp.name_vi,
    'from_station', t.from_station,
    'to_station', t.to_station,
    'stops', t.stops,
    'final_price', t.final_price,
    'qr_code', t.qr_code,
    'status', t.status,
    'valid_from', t.valid_from,
    'valid_to', t.valid_to,
    'created_at', t.created_at,
    'used_at', t.used_at
  ) INTO v_ticket_data
  FROM tickets t
  JOIN ticket_products tp ON t.product_code = tp.code
  WHERE t.ticket_id = $1;

  IF v_ticket_data IS NULL THEN
    RETURN json_build_object('error', 'Ticket not found.');
  END IF;

  RETURN json_build_object('data', v_ticket_data);
END;
$_$;

-- Lấy danh sách vé của người dùng
CREATE OR REPLACE FUNCTION api.fn_get_user_tickets_json(user_id uuid, status_filter ticket_status DEFAULT NULL::ticket_status) RETURNS json
LANGUAGE plpgsql STABLE AS $_$
BEGIN
  RETURN json_build_object(
    'data', json_build_object(
      'tickets', (
        SELECT COALESCE(json_agg(
          json_build_object(
            'ticket_id', t.ticket_id,
            'product_name', tp.name_vi,
            'type', tp.type,
            'final_price', t.final_price,
            'status', t.status,
            'valid_from', t.valid_from,
            'valid_to', t.valid_to,
            'qr_code', t.qr_code,
            'created_at', t.created_at
          ) ORDER BY t.created_at DESC
        ), '[]'::JSON)
        FROM tickets t
        JOIN ticket_products tp ON t.product_code = tp.code
        WHERE t.user_id = $1 AND (status_filter IS NULL OR t.status = status_filter)
      )
    )
  );
END;
$_$;

-- Lấy danh sách gói vé đang mở bán
CREATE OR REPLACE FUNCTION api.fn_get_active_ticket_products_json() RETURNS json
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN json_build_object(
    'data', json_build_object(
      'products', (
        SELECT COALESCE(json_agg(
          json_build_object(
            'code', code,
            'name_vi', name_vi,
            'type', type,
            'price', price,
            'duration_hours', duration_hours,
            'auto_activate_after_days', auto_activate_after_days,
            'state', state
          ) ORDER BY price ASC
        ), '[]'::json)
        FROM ticket_products
        WHERE state = TRUE AND type != 'single_ride'
      )
    )
  );
END;
$$;

-- =============================================================================
-- 8. API FUNCTIONS: PAYMENTS
-- =============================================================================

-- Tạo bản ghi thanh toán PENDING
CREATE OR REPLACE FUNCTION api.fn_create_payment_json(p_ticket_id integer, p_method text, p_amount numeric) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  new_payment RECORD;
BEGIN
  INSERT INTO payments (ticket_id, method, amount, status)
  VALUES (p_ticket_id, p_method, p_amount, 'PENDING')
  RETURNING * INTO new_payment;

  RETURN jsonb_build_object(
    'success', TRUE,
    'payment', jsonb_strip_nulls(row_to_json(new_payment)::jsonb)
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', FALSE, 'message', SQLERRM);
END;
$$;

-- Xác nhận thanh toán thành công
CREATE OR REPLACE FUNCTION api.fn_confirm_payment_json(p_payment_id integer) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  updated_payment RECORD;
BEGIN
  UPDATE payments
  SET status = 'SUCCESS', updated_at = NOW()
  WHERE payment_id = p_payment_id AND status = 'PENDING'
  RETURNING * INTO updated_payment;

  IF NOT FOUND THEN
    SELECT * INTO updated_payment FROM payments WHERE payment_id = p_payment_id;
    IF updated_payment IS NULL THEN
        RETURN jsonb_build_object('success', FALSE, 'message', 'Payment ID không tồn tại.');
    END IF;

    IF updated_payment.status = 'SUCCESS' THEN
        RETURN jsonb_build_object(
            'success', TRUE,
            'message', 'Thanh toán này đã được xác nhận trước đó.',
            'payment', jsonb_strip_nulls(row_to_json(updated_payment)::jsonb)
        );
    END IF;

    RETURN jsonb_build_object('success', FALSE, 'message', 'Không thể xác nhận thanh toán (có thể đã FAILED hoặc không ở trạng thái PENDING).');
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'payment', jsonb_strip_nulls(row_to_json(updated_payment)::jsonb)
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', FALSE, 'message', SQLERRM);
END;
$$;

-- Đánh dấu thanh toán thất bại / hủy
CREATE OR REPLACE FUNCTION api.fn_fail_payment_json(p_payment_id integer) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_ticket_id integer;
BEGIN
  UPDATE payments
  SET status = 'FAILED', updated_at = NOW()
  WHERE payment_id = p_payment_id
  RETURNING ticket_id INTO v_ticket_id;

  IF v_ticket_id IS NOT NULL THEN
    UPDATE tickets
    SET status = 'CANCELLED'
    WHERE ticket_id = v_ticket_id AND status = 'NEW';
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'message', 'Thanh toán đã được đánh dấu thất bại');
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', FALSE, 'message', SQLERRM);
END;
$$;

-- =============================================================================
-- 9. API FUNCTIONS: PROMOTIONS & GIFTCODES
-- =============================================================================

-- Kiểm tra mã khuyến mãi
CREATE OR REPLACE FUNCTION api.fn_check_promotion_json(p_code text, p_original_price numeric, p_user_id uuid) RETURNS json
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_promo promotions%ROWTYPE;
  v_discount numeric := 0;
  v_final numeric := 0;
BEGIN
  IF p_code IS NULL OR trim(p_code) = '' THEN
    RETURN json_build_object('success', FALSE, 'message', 'Vui lòng nhập mã khuyến mãi');
  END IF;

  SELECT * INTO v_promo
  FROM promotions
  WHERE UPPER(code) = UPPER(trim(p_code))
    AND state = TRUE AND is_active = TRUE
    AND starts_at <= NOW()
    AND (ends_at IS NULL OR ends_at >= NOW())
    AND used_count < max_usage
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN json_build_object('success', FALSE, 'message', 'Mã khuyến mãi không tồn tại hoặc đã hết hạn');
  END IF;

  IF p_original_price < COALESCE(v_promo.min_order_amount, 0) THEN
    RETURN json_build_object('success', FALSE, 'message', 'Đơn hàng chưa đạt giá trị tối thiểu ' || v_promo.min_order_amount || 'đ');
  END IF;

  IF v_promo.promo_type = 'percent' THEN
    v_discount := ROUND(p_original_price * COALESCE(v_promo.discount_percent, 0) / 100);
  ELSE
    v_discount := LEAST(p_original_price, COALESCE(v_promo.discount_amount, 0));
  END IF;

  v_final := GREATEST(0::numeric, p_original_price - v_discount);

  RETURN json_build_object(
    'success', TRUE,
    'data', json_build_object(
      'discount', v_discount,
      'final_price', v_final,
      'description', v_promo.name
    )
  );
END;
$$;

-- Đổi Giftcode lấy vé (Redeem)
CREATE OR REPLACE FUNCTION api.fn_redeem_giftcode_json(p_user_id uuid, p_code text) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_promo promotions%ROWTYPE;
  v_prod ticket_products%ROWTYPE;
  v_new_ticket_id integer;
  v_qr_code text;
BEGIN
  IF p_code IS NULL OR trim(p_code) = '' THEN
    RETURN json_build_object('ok', FALSE, 'message', 'Vui lòng nhập mã vé');
  END IF;

  SELECT * INTO v_promo
  FROM promotions
  WHERE UPPER(code) = UPPER(trim(p_code))
    AND is_active = TRUE AND state = TRUE;

  IF NOT FOUND THEN
    RETURN json_build_object('ok', FALSE, 'message', 'Mã vé không tồn tại hoặc đã bị khóa');
  END IF;

  IF v_promo.starts_at > NOW() THEN
    RETURN json_build_object('ok', FALSE, 'message', 'Mã chưa đến thời gian áp dụng');
  END IF;

  IF v_promo.ends_at IS NOT NULL AND v_promo.ends_at < NOW() THEN
    RETURN json_build_object('ok', FALSE, 'message', 'Mã vé đã hết hạn');
  END IF;

  IF v_promo.used_count >= v_promo.max_usage THEN
    RETURN json_build_object('ok', FALSE, 'message', 'Mã vé đã hết lượt sử dụng');
  END IF;

  SELECT * INTO v_prod FROM ticket_products WHERE code = v_promo.ticket_product_code;
  IF NOT FOUND THEN
    SELECT * INTO v_prod FROM ticket_products WHERE type != 'single_ride' ORDER BY price ASC LIMIT 1;
  END IF;

  UPDATE promotions SET used_count = used_count + 1 WHERE promo_id = v_promo.promo_id;

  INSERT INTO tickets (
    user_id, product_code, final_price, status, valid_from, valid_to
  ) VALUES (
    p_user_id,
    v_prod.code,
    0,
    'ACTIVE',
    NOW(),
    NOW() + (COALESCE(v_prod.duration_hours, 24) || ' hours')::interval
  ) RETURNING ticket_id, qr_code INTO v_new_ticket_id, v_qr_code;

  INSERT INTO payments (ticket_id, method, amount, status)
  VALUES (v_new_ticket_id, 'GIFTCODE', 0, 'SUCCESS');

  INSERT INTO audit_log (actor_user, action, object_type, object_id, payload_json)
  VALUES (p_user_id, 'REDEEM_GIFTCODE', 'TICKET', v_new_ticket_id::text, jsonb_build_object('code', p_code));

  RETURN json_build_object(
    'ok', TRUE,
    'success', TRUE,
    'message', 'Đổi mã thành công! Vé đã được thêm vào ví.',
    'data', json_build_object('ticket_id', v_new_ticket_id, 'qr_code', v_qr_code)
  );
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('ok', FALSE, 'message', SQLERRM);
END;
$$;

-- Lấy danh sách giftcodes khả dụng để tặng khách hàng
CREATE OR REPLACE FUNCTION api.fn_get_available_giftcodes() RETURNS json
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (
    SELECT COALESCE(json_agg(
      json_build_object(
        'promo_id', p.promo_id,
        'code', p.code,
        'name', p.name,
        'description', p.description,
        'reward_value', p.ticket_product_code,
        'product_name', tp.name_vi,
        'max_usage', p.max_usage,
        'used_count', p.used_count,
        'expires_at', p.ends_at
      ) ORDER BY p.created_at DESC
    ), '[]'::json)
    FROM promotions p
    LEFT JOIN ticket_products tp ON p.ticket_product_code = tp.code
    WHERE p.is_active = TRUE AND p.state = TRUE
      AND (p.ends_at IS NULL OR p.ends_at > NOW())
      AND p.used_count < p.max_usage
  );
END;
$$;

-- Admin gửi mã quà tặng / thông báo riêng cho khách hàng
CREATE OR REPLACE FUNCTION api.fn_admin_send_gift_json(
  p_user_id uuid,
  p_promo_code text,
  p_title text,
  p_content text
) RETURNS json
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO notifications (user_id, title, content, type, is_read)
  VALUES (
    p_user_id,
    COALESCE(p_title, 'Quà tặng từ Metro HCMC'),
    p_content || E'\n\n👉 Mã quà tặng của bạn: ' || p_promo_code,
    'PERSONAL',
    FALSE
  );

  INSERT INTO audit_log (actor_user, action, object_type, object_id, payload_json)
  VALUES (p_user_id, 'ADMIN_SEND_GIFT', 'USER', p_user_id::text, jsonb_build_object('promo_code', p_promo_code));

  RETURN json_build_object('success', TRUE, 'message', 'Đã gửi quà tặng thành công');
END;
$$;

-- Admin tạo/cập nhật giftcode
CREATE OR REPLACE FUNCTION api.fn_admin_upsert_giftcode_json(
  p_promo_id uuid,
  p_prefix text,
  p_quantity integer,
  p_ticket_product_code text,
  p_max_usage integer,
  p_starts_at timestamp,
  p_expires_at timestamp,
  p_is_active boolean
) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_count integer := 0;
  v_code text;
  v_prod ticket_products%ROWTYPE;
BEGIN
  SELECT * INTO v_prod FROM ticket_products WHERE code = p_ticket_product_code;

  IF p_promo_id IS NOT NULL THEN
    UPDATE promotions
    SET code = COALESCE(p_prefix, code),
        ticket_product_code = p_ticket_product_code,
        max_usage = COALESCE(p_max_usage, max_usage),
        starts_at = COALESCE(p_starts_at, starts_at),
        ends_at = p_expires_at,
        is_active = COALESCE(p_is_active, is_active),
        state = COALESCE(p_is_active, state)
    WHERE promo_id = p_promo_id;

    RETURN json_build_object('ok', TRUE, 'promo_id', p_promo_id);
  ELSE
    IF p_quantity IS NULL OR p_quantity <= 1 THEN
      INSERT INTO promotions (
        code, name, description, promo_type, discount_amount,
        starts_at, ends_at, max_usage, ticket_product_code, is_active, state
      ) VALUES (
        p_prefix,
        'Giftcode: ' || p_prefix,
        'Đổi vé ' || COALESCE(v_prod.name_vi, p_ticket_product_code),
        'amount',
        COALESCE(v_prod.price, 0),
        COALESCE(p_starts_at, NOW()),
        p_expires_at,
        COALESCE(p_max_usage, 1),
        p_ticket_product_code,
        COALESCE(p_is_active, TRUE),
        COALESCE(p_is_active, TRUE)
      );
      v_count := 1;
    ELSE
      FOR i IN 1..p_quantity LOOP
        v_code := p_prefix || '_' || UPPER(SUBSTR(MD5(RANDOM()::text || CLOCK_TIMESTAMP()::text), 1, 6));
        INSERT INTO promotions (
          code, name, description, promo_type, discount_amount,
          starts_at, ends_at, max_usage, ticket_product_code, is_active, state
        ) VALUES (
          v_code,
          'Giftcode: ' || v_code,
          'Đổi vé ' || COALESCE(v_prod.name_vi, p_ticket_product_code),
          'amount',
          COALESCE(v_prod.price, 0),
          COALESCE(p_starts_at, NOW()),
          p_expires_at,
          COALESCE(p_max_usage, 1),
          p_ticket_product_code,
          COALESCE(p_is_active, TRUE),
          COALESCE(p_is_active, TRUE)
        );
        v_count := v_count + 1;
      END LOOP;
    END IF;

    RETURN json_build_object('ok', TRUE, 'count', v_count);
  END IF;
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('ok', FALSE, 'message', SQLERRM);
END;
$$;

-- Admin lấy danh sách giftcode
CREATE OR REPLACE FUNCTION api.fn_admin_get_giftcodes_json(p_limit integer DEFAULT 100, p_offset integer DEFAULT 0) RETURNS json
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN json_build_object(
    'ok', TRUE,
    'data', (
      SELECT COALESCE(json_agg(
        json_build_object(
          'promo_id', p.promo_id,
          'code', p.code,
          'product_name', COALESCE(tp.name_vi, 'Vé Metro'),
          'reward_value', p.ticket_product_code,
          'ticket_product_code', p.ticket_product_code,
          'used_count', p.used_count,
          'max_usage', p.max_usage,
          'starts_at', p.starts_at,
          'expires_at', p.ends_at,
          'is_active', p.is_active
        ) ORDER BY p.created_at DESC
      ), '[]'::json)
      FROM (
        SELECT * FROM promotions
        WHERE ticket_product_code IS NOT NULL
        ORDER BY created_at DESC
        LIMIT p_limit OFFSET p_offset
      ) p
      LEFT JOIN ticket_products tp ON p.ticket_product_code = tp.code
    )
  );
END;
$$;

-- =============================================================================
-- 10. API FUNCTIONS: SUPPORT & FEEDBACKS
-- =============================================================================

-- Người dùng gửi phản hồi/góp ý
CREATE OR REPLACE FUNCTION api.fn_create_feedback_json(p_user_id uuid, p_title text, p_content text) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_id integer;
BEGIN
  INSERT INTO feedbacks (user_id, title, content)
  VALUES (p_user_id, COALESCE(p_title, 'Góp ý chung'), p_content)
  RETURNING id INTO v_id;

  RETURN json_build_object('success', TRUE, 'message', 'Cảm ơn bạn đã gửi phản hồi!', 'id', v_id);
END;
$$;

-- Admin xem danh sách phản hồi
CREATE OR REPLACE FUNCTION api.fn_admin_get_feedbacks_json(p_limit integer DEFAULT 50) RETURNS json
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN json_build_object(
    'success', TRUE,
    'data', (
      SELECT COALESCE(json_agg(
        json_build_object(
          'id', f.id,
          'title', f.title,
          'content', f.content,
          'user_id', f.user_id,
          'user_name', u.display_name,
          'email', u.primary_email,
          'phone', u.phone_number,
          'created_at', f.created_at
        ) ORDER BY f.created_at DESC
      ), '[]'::json)
      FROM (
        SELECT * FROM feedbacks ORDER BY created_at DESC LIMIT p_limit
      ) f
      JOIN users u ON f.user_id = u.user_id
    )
  );
END;
$$;

-- =============================================================================
-- 11. API FUNCTIONS: LINES, STATIONS, SEGMENTS & FARE RULES
-- =============================================================================

-- Lấy danh sách tuyến công khai
CREATE OR REPLACE FUNCTION api.fn_get_lines_json() RETURNS json
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN json_build_object(
    'data', json_build_object(
      'lines', (
        SELECT COALESCE(json_agg(
          json_build_object(
            'code', code,
            'name', name,
            'color_hex', color_hex,
            'status', status
          )
        ), '[]'::JSON)
        FROM lines
        WHERE status = 'active'
      )
    )
  );
END;
$$;

-- Lấy danh sách ga của tuyến công khai
CREATE OR REPLACE FUNCTION api.fn_get_stations_json(p_line_code text) RETURNS json
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN json_build_object(
    'data', json_build_object(
      'line_code', p_line_code,
      'stations', (
        SELECT COALESCE(json_agg(
          json_build_object(
            'code', code,
            'name', name,
            'order_index', order_index,
            'lat', lat,
            'lon', lon
          )
        ORDER BY order_index ASC), '[]'::JSON)
        FROM stations
        WHERE line_code = p_line_code
      )
    )
  );
END;
$$;

-- Admin lấy danh sách toàn bộ ga
CREATE OR REPLACE FUNCTION api.fn_admin_get_stations_json() RETURNS json
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN json_build_object(
    'ok', TRUE,
    'data', (
      SELECT COALESCE(json_agg(
        json_build_object(
          'code', s.code,
          'name', s.name,
          'line_code', s.line_code,
          'line_name', l.name,
          'order_index', s.order_index,
          'lat', s.lat,
          'lon', s.lon,
          'created_at', s.created_at
        ) ORDER BY s.line_code, s.order_index ASC
      ), '[]'::json)
      FROM stations s
      LEFT JOIN lines l ON s.line_code = l.code
    )
  );
END;
$$;

-- Admin xóa nhà ga
CREATE OR REPLACE FUNCTION api.fn_admin_delete_station_json(p_actor_user_id uuid, p_code text) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_station stations%ROWTYPE;
BEGIN
  SELECT * INTO v_station FROM stations WHERE code = p_code;
  IF NOT FOUND THEN
    RETURN json_build_object('ok', FALSE, 'message', 'Không tìm thấy nhà ga');
  END IF;

  DELETE FROM stations WHERE code = p_code;

  INSERT INTO audit_log (actor_user, action, object_type, object_id, payload_json)
  VALUES (p_actor_user_id, 'ADMIN_DELETE_STATION', 'STATION', p_code, to_jsonb(v_station));

  RETURN json_build_object('ok', TRUE, 'message', 'Đã xóa ga thành công');
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('ok', FALSE, 'message', SQLERRM);
END;
$$;

-- Admin Upsert Tuyến
CREATE OR REPLACE FUNCTION api.fn_admin_upsert_line_json(p_actor_user_id uuid, p_code text, p_name text, p_color_hex text, p_state boolean) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_line lines%ROWTYPE;
BEGIN
  IF p_code IS NULL OR trim(p_code) = '' THEN
    RETURN json_build_object('ok',FALSE,
      'error', json_build_object('code','INVALID_CODE','message','code is required'));
  END IF;

  IF p_name IS NULL OR trim(p_name) = '' THEN
    RETURN json_build_object('ok',FALSE,
      'error', json_build_object('code','INVALID_NAME','message','name is required'));
  END IF;

  INSERT INTO lines(code, name, color_hex, state, status)
  VALUES (p_code, p_name, p_color_hex, COALESCE(p_state,TRUE), CASE WHEN COALESCE(p_state,TRUE) THEN 'active' ELSE 'inactive' END)
  ON CONFLICT (code) DO UPDATE
    SET name      = EXCLUDED.name,
        color_hex = EXCLUDED.color_hex,
        state     = EXCLUDED.state,
        status    = EXCLUDED.status
  RETURNING * INTO v_line;

  INSERT INTO audit_log(actor_user, action, object_type, object_id, payload_json)
  VALUES (p_actor_user_id, 'ADMIN_UPSERT_LINE', 'LINE', v_line.code, to_jsonb(v_line));

  RETURN json_build_object('ok',TRUE, 'data', json_build_object('line', row_to_json(v_line)));
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('ok',FALSE,
    'error', json_build_object('code','SERVER_ERROR','message',SQLERRM));
END;
$$;

-- Admin Upsert Ga
CREATE OR REPLACE FUNCTION api.fn_admin_upsert_station_json(p_actor_user_id uuid, p_code text, p_name text, p_line_code text, p_order_index integer, p_lat double precision, p_lon double precision) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_station stations%ROWTYPE;
BEGIN
  IF p_code IS NULL OR trim(p_code) = '' THEN
    RETURN json_build_object('ok',FALSE, 'error', json_build_object('code','INVALID_CODE','message','code is required'));
  END IF;

  IF p_name IS NULL OR trim(p_name) = '' THEN
    RETURN json_build_object('ok',FALSE, 'error', json_build_object('code','INVALID_NAME','message','name is required'));
  END IF;

  IF p_line_code IS NULL OR trim(p_line_code) = '' THEN
    RETURN json_build_object('ok',FALSE, 'error', json_build_object('code','INVALID_LINE','message','line_code is required'));
  END IF;

  PERFORM 1 FROM lines WHERE code = p_line_code;
  IF NOT FOUND THEN
    RETURN json_build_object('ok',FALSE, 'error', json_build_object('code','LINE_NOT_FOUND','message','line_code does not exist'));
  END IF;

  INSERT INTO stations(code, name, line_code, order_index, lat, lon)
  VALUES (p_code, p_name, p_line_code, p_order_index, p_lat, p_lon)
  ON CONFLICT (code) DO UPDATE
    SET name        = EXCLUDED.name,
        line_code   = EXCLUDED.line_code,
        order_index = EXCLUDED.order_index,
        lat         = EXCLUDED.lat,
        lon         = EXCLUDED.lon
  RETURNING * INTO v_station;

  INSERT INTO audit_log(actor_user, action, object_type, object_id, payload_json)
  VALUES (p_actor_user_id, 'ADMIN_UPSERT_STATION', 'STATION', v_station.code, to_jsonb(v_station));

  RETURN json_build_object('ok',TRUE, 'data', json_build_object('station', row_to_json(v_station)));
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('ok',FALSE, 'error', json_build_object('code','SERVER_ERROR','message',SQLERRM));
END;
$$;

-- Admin Upsert Đoạn tuyến
CREATE OR REPLACE FUNCTION api.fn_admin_upsert_segment_json(p_actor_user_id uuid, p_line_code text, p_from_station text, p_to_station text, p_travel_min integer) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_segment segments%ROWTYPE;
BEGIN
  IF p_line_code IS NULL OR trim(p_line_code) = '' THEN
    RETURN json_build_object('ok',FALSE, 'error', json_build_object('code','INVALID_LINE','message','line_code is required'));
  END IF;

  IF p_from_station IS NULL OR p_to_station IS NULL OR trim(p_from_station) = '' OR trim(p_to_station) = '' THEN
    RETURN json_build_object('ok',FALSE, 'error', json_build_object('code','INVALID_STATION','message','from/to required'));
  END IF;

  IF p_from_station = p_to_station THEN
    RETURN json_build_object('ok',FALSE, 'error', json_build_object('code','SAME_STATION','message','from and to cannot be same'));
  END IF;

  INSERT INTO segments(line_code, from_station, to_station, travel_min)
  VALUES (p_line_code, p_from_station, p_to_station, p_travel_min)
  ON CONFLICT (line_code, from_station, to_station) DO UPDATE
    SET travel_min = EXCLUDED.travel_min
  RETURNING * INTO v_segment;

  INSERT INTO audit_log(actor_user, action, object_type, object_id, payload_json)
  VALUES (p_actor_user_id, 'ADMIN_UPSERT_SEGMENT', 'SEGMENT', v_segment.line_code || ':' || v_segment.from_station || '->' || v_segment.to_station, to_jsonb(v_segment));

  RETURN json_build_object('ok', TRUE, 'data', json_build_object('segment', row_to_json(v_segment)));
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('ok',FALSE, 'error', json_build_object('code','SERVER_ERROR','message',SQLERRM));
END;
$$;

-- Admin cấu hình Fare Rule
CREATE OR REPLACE FUNCTION api.fn_admin_set_active_fare_rule_json(p_actor_user_id uuid, p_line_code text, p_base_price numeric, p_base_stops integer, p_step_stops integer, p_step_price numeric) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_rule fare_rules%ROWTYPE;
BEGIN
  UPDATE fare_rules SET state = FALSE WHERE line_code = p_line_code AND state = TRUE;

  INSERT INTO fare_rules(line_code, base_price, base_stops, step_stops, step_price, state)
  VALUES(p_line_code, p_base_price, p_base_stops, p_step_stops, p_step_price, TRUE)
  RETURNING * INTO v_rule;

  INSERT INTO audit_log(actor_user, action, object_type, object_id, payload_json)
  VALUES (p_actor_user_id, 'ADMIN_UPSERT_FARE_RULE', 'FARE_RULE', v_rule.line_code, to_jsonb(v_rule));

  RETURN json_build_object('ok',TRUE, 'data', json_build_object('fare_rule', row_to_json(v_rule)));
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('ok',FALSE, 'error', json_build_object('code','SERVER_ERROR','message',SQLERRM));
END;
$$;

-- Admin xem danh sách fare rules
CREATE OR REPLACE FUNCTION api.fn_admin_get_fare_rules_json() RETURNS json
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN json_build_object(
    'ok', TRUE,
    'data', (
      SELECT COALESCE(json_agg(row_to_json(fr) ORDER BY line_code, id DESC), '[]'::json)
      FROM fare_rules fr
    )
  );
END;
$$;

-- Admin Upsert Ticket Product
CREATE OR REPLACE FUNCTION api.fn_admin_upsert_ticket_product_json(
  p_actor_user_id uuid,
  p_code text,
  p_name_vi text,
  p_type ticket_product_type,
  p_price numeric,
  p_duration_hours integer,
  p_auto_activate_after_days integer,
  p_state boolean
) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_product ticket_products%ROWTYPE;
BEGIN
  IF p_code IS NULL THEN
    RETURN json_build_object('ok',FALSE, 'error', json_build_object('code','INVALID_CODE','message','code required'));
  END IF;

  INSERT INTO ticket_products(code, name_vi, type, price, duration_hours, auto_activate_after_days, state)
  VALUES(p_code, p_name_vi, p_type, p_price, p_duration_hours, p_auto_activate_after_days, COALESCE(p_state,TRUE))
  ON CONFLICT (code) DO UPDATE
    SET name_vi = EXCLUDED.name_vi,
        type = EXCLUDED.type,
        price = EXCLUDED.price,
        duration_hours = EXCLUDED.duration_hours,
        auto_activate_after_days = EXCLUDED.auto_activate_after_days,
        state = EXCLUDED.state
  RETURNING * INTO v_product;

  INSERT INTO audit_log(actor_user, action, object_type, object_id, payload_json)
  VALUES (p_actor_user_id, 'ADMIN_UPSERT_TICKET_PRODUCT', 'TICKET_PRODUCT', v_product.code, to_jsonb(v_product));

  RETURN json_build_object('ok',TRUE, 'data', json_build_object('ticket_product', row_to_json(v_product)));
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('ok',FALSE, 'error', json_build_object('code','SERVER_ERROR','message',SQLERRM));
END;
$$;

-- Admin lấy danh sách Ticket Products
CREATE OR REPLACE FUNCTION api.fn_admin_get_ticket_products_json() RETURNS json
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN json_build_object(
    'ok', TRUE,
    'data', (
      SELECT COALESCE(json_agg(row_to_json(tp) ORDER BY price ASC), '[]'::json)
      FROM ticket_products tp
    )
  );
END;
$$;

-- Admin Upsert Khuyến mãi chung
CREATE OR REPLACE FUNCTION api.fn_admin_upsert_promotion_json(
  p_actor_user_id uuid,
  p_code text,
  p_name text,
  p_description text,
  p_promo_type promotion_type,
  p_discount_percent numeric,
  p_discount_amount numeric,
  p_starts_at timestamp with time zone,
  p_ends_at timestamp with time zone,
  p_min_order_amount numeric,
  p_state boolean
) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_promo promotions%ROWTYPE;
BEGIN
  INSERT INTO promotions(
    code, name, description, promo_type,
    discount_percent, discount_amount,
    starts_at, ends_at, min_order_amount, state, is_active
  )
  VALUES(
    p_code, p_name, p_description, p_promo_type,
    p_discount_percent, p_discount_amount,
    p_starts_at, p_ends_at, p_min_order_amount, COALESCE(p_state,TRUE), COALESCE(p_state,TRUE)
  )
  ON CONFLICT (code) DO UPDATE
    SET name             = EXCLUDED.name,
        description      = EXCLUDED.description,
        promo_type       = EXCLUDED.promo_type,
        discount_percent = EXCLUDED.discount_percent,
        discount_amount  = EXCLUDED.discount_amount,
        starts_at        = EXCLUDED.starts_at,
        ends_at          = EXCLUDED.ends_at,
        min_order_amount = EXCLUDED.min_order_amount,
        state            = EXCLUDED.state,
        is_active        = EXCLUDED.is_active
  RETURNING * INTO v_promo;

  INSERT INTO audit_log(actor_user, action, object_type, object_id, payload_json)
  VALUES (p_actor_user_id, 'ADMIN_UPSERT_PROMOTION', 'PROMOTION', v_promo.code, to_jsonb(v_promo));

  RETURN json_build_object('ok',TRUE, 'data', json_build_object('promotion', row_to_json(v_promo)));
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('ok',FALSE, 'error', json_build_object('code','SERVER_ERROR','message',SQLERRM));
END;
$$;

-- Admin lấy danh sách khuyến mãi
CREATE OR REPLACE FUNCTION api.fn_admin_get_promotions_json() RETURNS json
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN json_build_object(
    'ok', TRUE,
    'data', (
      SELECT COALESCE(json_agg(row_to_json(p) ORDER BY starts_at DESC), '[]'::json)
      FROM promotions p
    )
  );
END;
$$;

-- Admin Upsert Thông báo
CREATE OR REPLACE FUNCTION api.fn_admin_upsert_announcement_json(
  p_actor_user_id uuid,
  p_title text,
  p_content_md text,
  p_visible_from timestamp with time zone,
  p_visible_to timestamp with time zone,
  p_is_active boolean,
  p_ann_id integer DEFAULT NULL::integer
) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_ann announcements%ROWTYPE;
BEGIN
  IF p_ann_id IS NOT NULL THEN
    UPDATE announcements
    SET title = p_title,
        content_md = p_content_md,
        visible_from = COALESCE(p_visible_from, visible_from),
        visible_to = p_visible_to,
        is_active = COALESCE(p_is_active, is_active)
    WHERE ann_id = p_ann_id
    RETURNING * INTO v_ann;
  ELSE
    INSERT INTO announcements(title, content_md, visible_from, visible_to, is_active)
    VALUES (p_title, p_content_md, COALESCE(p_visible_from, NOW()), p_visible_to, COALESCE(p_is_active, TRUE))
    RETURNING * INTO v_ann;
  END IF;

  INSERT INTO audit_log(actor_user, action, object_type, object_id, payload_json)
  VALUES (p_actor_user_id, 'ADMIN_UPSERT_ANNOUNCEMENT', 'ANNOUNCEMENT', v_ann.ann_id::text, to_jsonb(v_ann));

  RETURN json_build_object('ok',TRUE, 'data', json_build_object('announcement', row_to_json(v_ann)));
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('ok',FALSE, 'error', json_build_object('code','SERVER_ERROR','message',SQLERRM));
END;
$$;

-- Admin xem danh sách thông báo
CREATE OR REPLACE FUNCTION api.fn_admin_get_announcements_json() RETURNS json
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN json_build_object(
    'ok', TRUE,
    'data', (
      SELECT COALESCE(json_agg(row_to_json(a) ORDER BY visible_from DESC), '[]'::json)
      FROM announcements a
    )
  );
END;
$$;

-- Lấy thông báo công khai (Public)
CREATE OR REPLACE FUNCTION api.fn_get_announcements_json() RETURNS json
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_items JSON;
BEGIN
  SELECT COALESCE(
    json_agg(
      json_build_object(
        'ann_id',       ann_id,
        'title',        title,
        'content_md',   content_md,
        'visible_from', visible_from,
        'visible_to',   visible_to,
        'is_active',    is_active,
        'created_at',   created_at
      )
      ORDER BY visible_from DESC
    ),
    '[]'::JSON
  )
  INTO v_items
  FROM announcements
  WHERE is_active = TRUE
    AND visible_from <= NOW()
    AND (visible_to IS NULL OR visible_to >= NOW());

  RETURN json_build_object('success', TRUE, 'announcements', v_items);
END;
$$;

-- =============================================================================
-- 12. API FUNCTIONS: CUSTOMER MANAGEMENT, REPORTING & AUDIT
-- =============================================================================

-- Lấy danh sách khách hàng cho Admin
CREATE OR REPLACE FUNCTION api.fn_get_customers_json() RETURNS json
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (
    SELECT COALESCE(json_agg(
      json_build_object(
        'user_id', u.user_id,
        'full_name', u.display_name,
        'display_name', u.display_name,
        'email', u.primary_email,
        'phone', u.phone_number,
        'avatar_url', u.avatar_url,
        'state', u.is_active,
        'is_active', u.is_active,
        'role', u.role,
        'total_tickets', (SELECT COUNT(*) FROM tickets t WHERE t.user_id = u.user_id),
        'created_at', u.created_at
      ) ORDER BY u.created_at DESC
    ), '[]'::json)
    FROM users u
    WHERE u.role = 'CUSTOMER'
  );
END;
$$;

-- Lấy lịch sử đi tàu của khách hàng
CREATE OR REPLACE FUNCTION api.fn_get_user_ride_history(p_user_id uuid) RETURNS json
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (
    SELECT COALESCE(json_agg(
      json_build_object(
        'validation_id', v.validation_id,
        'ticket_id', t.ticket_id,
        'product_code', t.product_code,
        'product_name', tp.name_vi,
        'station_code', v.station_code,
        'direction', v.direction,
        'validated_at', v.validated_at,
        'note', v.note
      ) ORDER BY v.validated_at DESC
    ), '[]'::json)
    FROM validations v
    JOIN tickets t ON v.ticket_id = t.ticket_id
    JOIN ticket_products tp ON t.product_code = tp.code
    WHERE t.user_id = p_user_id
  );
END;
$$;

-- Báo cáo doanh thu theo ngày
CREATE OR REPLACE FUNCTION api.fn_report_sales_json(p_from_date date, p_to_date date) RETURNS json
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_rows JSON;
BEGIN
  SELECT COALESCE(json_agg(
    json_build_object(
      'date', report_date,
      'amount', total_amount,
      'count', total_count
    ) ORDER BY report_date ASC
  ), '[]'::JSON)
  INTO v_rows
  FROM (
    SELECT
      created_at::DATE AS report_date,
      SUM(amount) AS total_amount,
      COUNT(*) AS total_count
    FROM payments
    WHERE status = 'SUCCESS'
      AND created_at >= p_from_date
      AND created_at < (p_to_date + 1)
    GROUP BY created_at::DATE
  ) AS daily_sales;

  RETURN json_build_object('ok', TRUE, 'data', json_build_object('rows', v_rows));
END;
$$;

-- Báo cáo tỷ lệ loại vé
CREATE OR REPLACE FUNCTION api.fn_report_ticket_types_json(p_from_date date, p_to_date date) RETURNS json
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_rows JSON;
BEGIN
  SELECT COALESCE(json_agg(
    json_build_object(
      'name', type_name,
      'value', ticket_count
    )
  ), '[]'::JSON)
  INTO v_rows
  FROM (
    SELECT
      CASE
        WHEN tp.type = 'single_ride' THEN 'Vé lượt'
        WHEN tp.type = 'day_pass' THEN 'Vé ngày'
        WHEN tp.type = 'multi_day_pass' THEN 'Vé nhiều ngày'
        WHEN tp.type = 'monthly_pass' THEN 'Vé tháng'
        ELSE 'Khác'
      END AS type_name,
      COUNT(t.ticket_id) AS ticket_count
    FROM tickets t
    JOIN ticket_products tp ON t.product_code = tp.code
    JOIN payments p ON t.ticket_id = p.ticket_id
    WHERE t.created_at::DATE BETWEEN p_from_date AND p_to_date
      AND p.status = 'SUCCESS'
    GROUP BY tp.type
  ) AS t;

  RETURN json_build_object('ok', TRUE, 'data', v_rows);
END;
$$;

-- Báo cáo lưu lượng soát vé theo khoảng ngày
CREATE OR REPLACE FUNCTION api.fn_report_traffic_json(p_from_date date, p_to_date date) RETURNS json
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_rows JSON;
BEGIN
  IF p_from_date IS NULL THEN p_from_date := CURRENT_DATE; END IF;
  IF p_to_date IS NULL THEN p_to_date := p_from_date; END IF;

  SELECT COALESCE(json_agg(
    json_build_object(
      'station_code', station_code,
      'validations_count', validations_count
    ) ORDER BY validations_count DESC
  ), '[]'::JSON)
  INTO v_rows
  FROM (
    SELECT station_code, COUNT(*) AS validations_count
    FROM validations
    WHERE validated_at::DATE BETWEEN p_from_date AND p_to_date
    GROUP BY station_code
  ) AS t;

  RETURN json_build_object('ok', TRUE, 'data', json_build_object('rows', COALESCE(v_rows, '[]'::JSON)));
END;
$$;

-- Báo cáo lưu lượng soát vé theo 1 ngày (overload)
CREATE OR REPLACE FUNCTION api.fn_report_traffic_json(p_on_date date) RETURNS json
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN api.fn_report_traffic_json(p_on_date, p_on_date);
END;
$$;

-- Admin Audit Log
CREATE OR REPLACE FUNCTION api.fn_admin_get_audit_json(
  p_from_ts timestamp with time zone,
  p_to_ts timestamp with time zone,
  p_action_filter text DEFAULT NULL::text
) RETURNS json
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_logs JSON;
BEGIN
  SELECT COALESCE(json_agg(
    json_build_object(
      'log_id', log_id,
      'actor_user', actor_user,
      'action', action,
      'object_type', object_type,
      'object_id', object_id,
      'payload_json', payload_json,
      'created_at', created_at
    ) ORDER BY created_at DESC
  ), '[]'::JSON)
  INTO v_logs
  FROM audit_log
  WHERE created_at >= COALESCE(p_from_ts, NOW() - INTERVAL '30 days')
    AND created_at <= COALESCE(p_to_ts, NOW())
    AND (p_action_filter IS NULL OR action = p_action_filter);

  RETURN json_build_object('ok', TRUE, 'result', json_build_object('logs', v_logs));
END;
$$;

-- Admin xem Payments
CREATE OR REPLACE FUNCTION api.fn_admin_get_payments_json(
  p_from_ts timestamp with time zone,
  p_to_ts timestamp with time zone,
  p_status_filter pay_status DEFAULT NULL::pay_status
) RETURNS json
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_payments JSON;
BEGIN
  SELECT COALESCE(json_agg(
    json_build_object(
      'payment_id', p.payment_id,
      'ticket_id', p.ticket_id,
      'method', p.method,
      'amount', p.amount,
      'status', p.status,
      'created_at', p.created_at,
      'user_email', u.primary_email,
      'product_name', tp.name_vi
    ) ORDER BY p.created_at DESC
  ), '[]'::JSON)
  INTO v_payments
  FROM payments p
  JOIN tickets t ON p.ticket_id = t.ticket_id
  JOIN users u ON t.user_id = u.user_id
  JOIN ticket_products tp ON t.product_code = tp.code
  WHERE p.created_at >= COALESCE(p_from_ts, NOW() - INTERVAL '30 days')
    AND p.created_at <= COALESCE(p_to_ts, NOW())
    AND (p_status_filter IS NULL OR p.status = p_status_filter);

  RETURN json_build_object('ok', TRUE, 'data', v_payments);
END;
$$;

-- =============================================================================
-- 13. SEED INITIAL FOUNDATIONAL DATA
-- =============================================================================

-- Line 1: Bến Thành - Suối Tiên
INSERT INTO lines (code, name, color_hex, status, state)
VALUES ('L1', 'Tuyến 1: Bến Thành - Bến xe Suối Tiên', '#0080FF', 'active', TRUE)
ON CONFLICT (code) DO NOTHING;

-- 14 Stations on Line 1
INSERT INTO stations (code, name, line_code, order_index, lat, lon) VALUES
  ('BT',   'Bến Thành',          'L1', 1,  10.7721, 106.6983),
  ('NHTP', 'Nhà hát Thành phố',   'L1', 2,  10.7766, 106.7032),
  ('BS',   'Ba Son',              'L1', 3,  10.7842, 106.7073),
  ('VT',   'Công viên Văn Thánh', 'L1', 4,  10.7978, 106.7163),
  ('TC',   'Tân Cảng',            'L1', 5,  10.7995, 106.7235),
  ('TD',   'Thảo Điền',           'L1', 6,  10.8016, 106.7344),
  ('AP',   'An Phú',              'L1', 7,  10.8037, 106.7441),
  ('RC',   'Rạch Chiếc',          'L1', 8,  10.8122, 106.7584),
  ('PL',   'Phước Long',          'L1', 9,  10.8228, 106.7667),
  ('BTH',  'Bình Thái',           'L1', 10, 10.8329, 106.7728),
  ('TDU',  'Thủ Đức',             'L1', 11, 10.8465, 106.7766),
  ('CNC',  'Khu Công nghệ cao',   'L1', 12, 10.8576, 106.7885),
  ('DHQG', 'Đại học Quốc gia',    'L1', 13, 10.8711, 106.8012),
  ('BXST', 'Bến xe Suối Tiên',    'L1', 14, 10.8827, 106.8124)
ON CONFLICT (code) DO NOTHING;

-- Segments connecting consecutive stations
INSERT INTO segments (line_code, from_station, to_station, travel_min) VALUES
  ('L1', 'BT',   'NHTP', 2), ('L1', 'NHTP', 'BT',   2),
  ('L1', 'NHTP', 'BS',   2), ('L1', 'BS',   'NHTP', 2),
  ('L1', 'BS',   'VT',   3), ('L1', 'VT',   'BS',   3),
  ('L1', 'VT',   'TC',   2), ('L1', 'TC',   'VT',   2),
  ('L1', 'TC',   'TD',   3), ('L1', 'TD',   'TC',   3),
  ('L1', 'TD',   'AP',   2), ('L1', 'AP',   'TD',   2),
  ('L1', 'AP',   'RC',   3), ('L1', 'RC',   'AP',   3),
  ('L1', 'RC',   'PL',   3), ('L1', 'PL',   'RC',   3),
  ('L1', 'PL',   'BTH',  2), ('L1', 'BTH',  'PL',   2),
  ('L1', 'BTH',  'TDU',  3), ('L1', 'TDU',  'BTH',  3),
  ('L1', 'TDU',  'CNC',  3), ('L1', 'CNC',  'TDU',  3),
  ('L1', 'CNC',  'DHQG', 3), ('L1', 'DHQG', 'CNC',  3),
  ('L1', 'DHQG', 'BXST', 3), ('L1', 'BXST', 'DHQG', 3)
ON CONFLICT (line_code, from_station, to_station) DO NOTHING;

-- Fare rule for Line 1
INSERT INTO fare_rules (line_code, base_price, base_stops, step_stops, step_price, state)
VALUES ('L1', 7000, 5, 2, 2000, TRUE)
ON CONFLICT DO NOTHING;

-- Ticket Products
INSERT INTO ticket_products (code, name_vi, type, price, duration_hours, auto_activate_after_days, state) VALUES
  ('L1_SINGLE',  'Vé lượt Tuyến 1',          'single_ride',     15000,  2,   1,  TRUE),
  ('PASS_1D',     'Vé 1 Ngày (Không giới hạn)', 'day_pass',        40000,  24,  30, TRUE),
  ('PASS_3D',     'Vé 3 Ngày (Không giới hạn)', 'multi_day_pass',  90000,  72,  30, TRUE),
  ('PASS_MONTH',  'Vé 30 Ngày (Vé Tháng)',     'monthly_pass',    260000, 720, 30, TRUE)
ON CONFLICT (code) DO UPDATE
  SET name_vi = EXCLUDED.name_vi,
      type = EXCLUDED.type,
      price = EXCLUDED.price,
      duration_hours = EXCLUDED.duration_hours,
      auto_activate_after_days = EXCLUDED.auto_activate_after_days,
      state = EXCLUDED.state;

-- Initial Users:
-- Admin: admin@metro.com / Admin@123456
-- Inspector: inspector@metro.com / Inspector@123456
-- Customer: customer@metro.com / Customer@123456
DO $$
DECLARE
  v_admin_id uuid := 'a0000000-0000-0000-0000-000000000001'::uuid;
  v_insp_id  uuid := 'a0000000-0000-0000-0000-000000000002'::uuid;
  v_cust_id  uuid := 'a0000000-0000-0000-0000-000000000003'::uuid;
  v_hash text;
BEGIN
  -- 1. Admin
  IF NOT EXISTS (SELECT 1 FROM users WHERE primary_email = 'admin@metro.com') THEN
    INSERT INTO users (user_id, display_name, primary_email, phone_number, role, is_active)
    VALUES (v_admin_id, 'Quản Trị Viên Metro', 'admin@metro.com', '0901000001', 'ADMIN', TRUE);

    v_hash := extensions.crypt('Admin@123456', extensions.gen_salt('bf'));
    INSERT INTO auth_identities (user_id, provider, email, password_hash, is_primary, provider_user_id)
    VALUES (v_admin_id, 'LOCAL', 'admin@metro.com', v_hash, TRUE, 'admin@metro.com');
  END IF;

  -- 2. Inspector
  IF NOT EXISTS (SELECT 1 FROM users WHERE primary_email = 'inspector@metro.com') THEN
    INSERT INTO users (user_id, display_name, primary_email, phone_number, role, is_active)
    VALUES (v_insp_id, 'Nhân Viên Soát Vé 01', 'inspector@metro.com', '0901000002', 'INSPECTOR', TRUE);

    v_hash := extensions.crypt('Inspector@123456', extensions.gen_salt('bf'));
    INSERT INTO auth_identities (user_id, provider, email, password_hash, is_primary, provider_user_id)
    VALUES (v_insp_id, 'LOCAL', 'inspector@metro.com', v_hash, TRUE, 'inspector@metro.com');
  END IF;

  -- 3. Customer
  IF NOT EXISTS (SELECT 1 FROM users WHERE primary_email = 'customer@metro.com') THEN
    INSERT INTO users (user_id, display_name, primary_email, phone_number, address, cccd, role, is_active)
    VALUES (v_cust_id, 'Nguyễn Văn A', 'customer@metro.com', '0901234567', 'Quận 1, TP. Hồ Chí Minh', '079123456789', 'CUSTOMER', TRUE);

    v_hash := extensions.crypt('Customer@123456', extensions.gen_salt('bf'));
    INSERT INTO auth_identities (user_id, provider, email, password_hash, is_primary, provider_user_id)
    VALUES (v_cust_id, 'LOCAL', 'customer@metro.com', v_hash, TRUE, 'customer@metro.com');
  END IF;
END $$;

-- Sample Promotions & Giftcodes
INSERT INTO promotions (
  code, name, description, promo_type, discount_percent, discount_amount,
  starts_at, ends_at, min_order_amount, max_usage, used_count, ticket_product_code, state, is_active
) VALUES
  ('METRO2026', 'Khuyến mãi chào xuân 2026', 'Giảm 20% cho mọi đơn hàng từ 15.000đ', 'percent', 20, NULL, NOW() - INTERVAL '1 day', NOW() + INTERVAL '365 days', 15000, 1000, 0, NULL, TRUE, TRUE),
  ('CHAOHCMC',  'Chào mừng khai trương', 'Giảm ngay 10.000đ cho chuyến đi', 'amount', NULL, 10000, NOW() - INTERVAL '1 day', NOW() + INTERVAL '365 days', 15000, 500, 0, NULL, TRUE, TRUE),
  ('FREEPASS1', 'Tặng 1 vé ngày miễn phí', 'Mã đổi 1 vé 1 ngày trải nghiệm Metro', 'amount', NULL, 40000, NOW() - INTERVAL '1 day', NOW() + INTERVAL '365 days', 0, 100, 0, 'PASS_1D', TRUE, TRUE)
ON CONFLICT (code) DO NOTHING;

-- Sample Announcement
INSERT INTO announcements (title, content_md, visible_from, visible_to, is_active)
VALUES (
  'Chào mừng bạn đến với Metro TP. Hồ Chí Minh!',
  'Tuyến Metro số 1 (Bến Thành - Suối Tiên) đã chính thức đưa vào khai thác thương mại. Quý hành khách có thể mua vé trực tiếp trên ứng dụng di động hoặc sử dụng mã QR tại các cổng soát vé.',
  NOW() - INTERVAL '1 hour',
  NOW() + INTERVAL '365 days',
  TRUE
)
ON CONFLICT DO NOTHING;
