-- =========================================================
-- PrimePass Database Schema (PostgreSQL)
-- Covers: core PrimePass site, Hearts in Transit, Safari Nami
-- =========================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto; -- for gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS citext;   -- for case-insensitive email

-- ---------- ENUM TYPES ----------
DO $$ BEGIN
  CREATE TYPE brand_type AS ENUM ('primepass', 'hearts_in_transit', 'safari_nami');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE user_role AS ENUM ('member', 'admin', 'concierge');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE booking_status AS ENUM ('pending', 'confirmed', 'cancelled', 'completed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE payment_provider AS ENUM ('stripe', 'paypal', 'binance_pay', 'okx_pay', 'bank_transfer');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE payment_status AS ENUM ('pending', 'paid', 'failed', 'refunded');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE traveler_type AS ENUM ('solo', 'couple', 'group');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE privacy_mode AS ENUM ('private', 'open', 'hosted');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE match_status AS ENUM ('pending', 'accepted', 'declined');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE story_status AS ENUM ('pending', 'approved', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE equipment_mode AS ENUM ('rent', 'buy');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------- MEMBERSHIP TIERS ----------
-- tiers.html: Voyager, Odyssey, Sovereign
CREATE TABLE IF NOT EXISTS membership_tiers (
  id              SERIAL PRIMARY KEY,
  slug            TEXT UNIQUE NOT NULL,
  name            TEXT NOT NULL,
  description     TEXT,
  benefits        JSONB NOT NULL DEFAULT '[]', -- list of benefit strings
  sort_order      INT NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- USERS / AUTH ----------
-- login.html, primepassCreateAccount.html
-- POST /api/auth/register, POST /api/auth/login
CREATE TABLE IF NOT EXISTS users (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  first_name      TEXT NOT NULL,
  last_name       TEXT NOT NULL,
  email           CITEXT UNIQUE NOT NULL,
  password_hash   TEXT NOT NULL, -- argon2id
  role            user_role NOT NULL DEFAULT 'member',
  tier_id         INT REFERENCES membership_tiers(id) ON DELETE SET NULL,
  failed_login_attempts INT NOT NULL DEFAULT 0,
  locked_until    TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sessions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash      TEXT NOT NULL,
  user_agent      TEXT,
  ip_address      INET,
  expires_at      TIMESTAMPTZ NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON sessions(user_id);

-- ---------- DESTINATIONS ----------
-- index.html world map + trending, destinations.html filterable grid
CREATE TABLE IF NOT EXISTS destinations (
  id              SERIAL PRIMARY KEY,
  slug            TEXT UNIQUE NOT NULL,
  name            TEXT NOT NULL,
  region          TEXT,
  brand           brand_type NOT NULL DEFAULT 'primepass',
  tags            TEXT[] NOT NULL DEFAULT '{}', -- Beach, Mountain, City, Culture, Wellness...
  summary         TEXT,
  hero_image_url  TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_destinations_tags ON destinations USING GIN (tags);

-- ---------- TRIP PACKAGES ----------
-- Covers Hearts in Transit tiers (Solo Star, Twin Flames, Forever After, Sweet Escape)
-- and Safari Nami itineraries / migration packages
CREATE TABLE IF NOT EXISTS trip_packages (
  id              SERIAL PRIMARY KEY,
  slug            TEXT UNIQUE NOT NULL,
  brand           brand_type NOT NULL,
  name            TEXT NOT NULL,
  capacity_label  TEXT,          -- e.g. "1 traveler", "Up to 4 couples / 8 people"
  description     TEXT,
  highlights      JSONB NOT NULL DEFAULT '[]',
  price_from      NUMERIC(12,2),
  currency        CHAR(3) NOT NULL DEFAULT 'USD',
  is_featured     BOOLEAN NOT NULL DEFAULT false,
  metadata        JSONB NOT NULL DEFAULT '{}', -- flexible extra fields per package
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- BOOKINGS ----------
-- index.html trip search / pricing widget / flight search all feed into a booking intent
CREATE TABLE IF NOT EXISTS bookings (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
  brand           brand_type NOT NULL DEFAULT 'primepass',
  package_id      INT REFERENCES trip_packages(id) ON DELETE SET NULL,
  destination_id  INT REFERENCES destinations(id) ON DELETE SET NULL,
  origin          TEXT,
  destination_text TEXT,
  depart_date     DATE,
  return_date     DATE,
  travelers       INT NOT NULL DEFAULT 1 CHECK (travelers > 0),
  cabin_class     TEXT,           -- Economy, Business, First Class, Private Jet
  status          booking_status NOT NULL DEFAULT 'pending',
  total_amount    NUMERIC(12,2),
  currency        CHAR(3) NOT NULL DEFAULT 'USD',
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_bookings_user_id ON bookings(user_id);
CREATE INDEX IF NOT EXISTS idx_bookings_status ON bookings(status);

-- ---------- PAYMENTS ----------
-- POST /api/payments/create-session, webhook-verified before marking paid
CREATE TABLE IF NOT EXISTS payments (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id          UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  provider            payment_provider NOT NULL,
  provider_session_id TEXT,
  status              payment_status NOT NULL DEFAULT 'pending',
  amount              NUMERIC(12,2) NOT NULL,
  currency            CHAR(3) NOT NULL DEFAULT 'USD',
  webhook_verified    BOOLEAN NOT NULL DEFAULT false,
  raw_provider_payload JSONB, -- store verified webhook payload for audit
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_payments_booking_id ON payments(booking_id);

-- ---------- FLIGHT SEARCH LOGS ----------
-- POST /api/flights/search (analytics / concierge follow-up, not live inventory)
CREATE TABLE IF NOT EXISTS flight_search_logs (
  id              BIGSERIAL PRIMARY KEY,
  user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
  origin          TEXT NOT NULL,
  destination     TEXT NOT NULL,
  depart_date     DATE,
  return_date     DATE,
  cabin_class     TEXT,
  airline_alliance TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- SAFARI NAMI: MIGRATION REQUESTS ----------
-- POST /api/safari/migration-plan
CREATE TABLE IF NOT EXISTS safari_migration_requests (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
  arrival_date    DATE NOT NULL,
  departure_date  DATE NOT NULL CHECK (departure_date >= arrival_date),
  migration_zone  TEXT NOT NULL,
  status          booking_status NOT NULL DEFAULT 'pending',
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- SAFARI NAMI: EQUIPMENT ----------
CREATE TABLE IF NOT EXISTS equipment_items (
  id              SERIAL PRIMARY KEY,
  name            TEXT NOT NULL UNIQUE,
  category        TEXT, -- safari essentials, hikes & water days, etc.
  rental_price    NUMERIC(10,2),
  purchase_price  NUMERIC(10,2),
  available       BOOLEAN NOT NULL DEFAULT true,
  metadata        JSONB NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS booking_equipment (
  id              BIGSERIAL PRIMARY KEY,
  booking_id      UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  equipment_id    INT NOT NULL REFERENCES equipment_items(id) ON DELETE RESTRICT,
  mode            equipment_mode NOT NULL,
  quantity        INT NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit_price      NUMERIC(10,2) NOT NULL
);

-- ---------- HEARTS IN TRANSIT: MATCH PROFILES ----------
-- Solo Star / Twin Flames matching, filters: dates, interests, age range, pace, privacy
CREATE TABLE IF NOT EXISTS match_profiles (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  traveler_type   traveler_type NOT NULL,
  destination_id  INT REFERENCES destinations(id) ON DELETE SET NULL,
  date_start      DATE,
  date_end        DATE,
  age_range_min   INT,
  age_range_max   INT,
  pace            TEXT,          -- relaxed, balanced, packed
  social_comfort  TEXT,          -- low, medium, high
  privacy_mode    privacy_mode NOT NULL DEFAULT 'private',
  verified        BOOLEAN NOT NULL DEFAULT false,
  bio             TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_match_profiles_destination ON match_profiles(destination_id);
CREATE INDEX IF NOT EXISTS idx_match_profiles_dates ON match_profiles(date_start, date_end);

CREATE TABLE IF NOT EXISTS match_connections (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id_a    UUID NOT NULL REFERENCES match_profiles(id) ON DELETE CASCADE,
  profile_id_b    UUID NOT NULL REFERENCES match_profiles(id) ON DELETE CASCADE,
  status          match_status NOT NULL DEFAULT 'pending',
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT distinct_profiles CHECK (profile_id_a <> profile_id_b),
  CONSTRAINT unique_pair UNIQUE (profile_id_a, profile_id_b)
);

-- ---------- CLIENT STORIES (moderation queue) ----------
-- POST /api/stories/moderation-queue -- media is scanned/stored server-side, only trusted URL kept
CREATE TABLE IF NOT EXISTS stories (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
  brand           brand_type NOT NULL DEFAULT 'hearts_in_transit',
  title           TEXT NOT NULL,
  body            TEXT NOT NULL,
  photo_url       TEXT, -- populated only after server-side trusted-storage scan
  status          story_status NOT NULL DEFAULT 'pending',
  moderated_by    UUID REFERENCES users(id) ON DELETE SET NULL,
  moderated_at    TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_stories_status ON stories(status);

-- ---------- updated_at trigger helper ----------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_users_updated_at ON users;
CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_bookings_updated_at ON bookings;
CREATE TRIGGER trg_bookings_updated_at BEFORE UPDATE ON bookings
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_payments_updated_at ON payments;
CREATE TRIGGER trg_payments_updated_at BEFORE UPDATE ON payments
  FOR EACH ROW EXECUTE FUNCTION set_updated_at(); but prioritize 

-- ---------- PASSWORD RESETS (3-step auth) ----------
CREATE TABLE IF NOT EXISTS password_resets (
  id                      SERIAL PRIMARY KEY,
  email                   CITEXT UNIQUE NOT NULL,
  reset_token_hash        TEXT NOT NULL,
  auth_hash_1             TEXT NOT NULL,
  auth_hash_2             TEXT NOT NULL,
  auth_hash_3             TEXT NOT NULL,
  step                    INT NOT NULL DEFAULT 0,
  auth_step_1_verified    BOOLEAN NOT NULL DEFAULT false,
  auth_step_2_verified    BOOLEAN NOT NULL DEFAULT false,
  auth_step_3_verified    BOOLEAN NOT NULL DEFAULT false,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- ADMIN INVITATIONS ----------
CREATE TABLE IF NOT EXISTS admin_invitations (
  id                SERIAL PRIMARY KEY,
  email             CITEXT UNIQUE NOT NULL,
  first_name        TEXT NOT NULL,
  last_name         TEXT NOT NULL,
  invited_by        UUID REFERENCES users(id) ON DELETE SET NULL,
  invite_token_hash TEXT NOT NULL,
  status            TEXT NOT NULL DEFAULT 'pending', -- pending, approved, expired, revoked
  approved_at       TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =========================================================
-- NEW TABLES for v2.0 — Social, Admin, Insurance, Automation
-- =========================================================

-- ---------- SOCIAL PROFILES ----------
CREATE TABLE IF NOT EXISTS social_profiles (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  display_name        TEXT,
  privacy             TEXT NOT NULL DEFAULT 'buddies_only' CHECK (privacy IN ('private', 'buddies_only', 'public')),
  theme_color         TEXT DEFAULT '#c7a96b',
  font_style          TEXT DEFAULT 'Inter',
  profile_image_url   TEXT,
  background_media_url TEXT,
  bio                 TEXT,
  pace                TEXT CHECK (pace IN ('relaxed', 'balanced', 'packed')),
  social_comfort      TEXT CHECK (social_comfort IN ('low', 'medium', 'high')),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- SOCIAL POSTS ----------
CREATE TABLE IF NOT EXISTS social_posts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  caption         TEXT,
  media_url       TEXT,
  media_type      TEXT CHECK (media_type IN ('image', 'video', 'audio')),
  status          TEXT NOT NULL DEFAULT 'published' CHECK (status IN ('published', 'hidden', 'flagged')),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_social_posts_user ON social_posts(user_id);
CREATE INDEX IF NOT EXISTS idx_social_posts_created ON social_posts(created_at DESC);

-- ---------- POST LIKES ----------
CREATE TABLE IF NOT EXISTS post_likes (
  id          BIGSERIAL PRIMARY KEY,
  post_id     UUID NOT NULL REFERENCES social_posts(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (post_id, user_id)
);

-- ---------- POST SHARES ----------
CREATE TABLE IF NOT EXISTS post_shares (
  id          BIGSERIAL PRIMARY KEY,
  post_id     UUID NOT NULL REFERENCES social_posts(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (post_id, user_id)
);

-- ---------- SOCIAL MESSAGES ----------
CREATE TABLE IF NOT EXISTS social_messages (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  recipient_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  content       TEXT NOT NULL,
  read_at       TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_social_messages_conversation ON social_messages(sender_id, recipient_id);
CREATE INDEX IF NOT EXISTS idx_social_messages_unread ON social_messages(recipient_id) WHERE read_at IS NULL;

-- ---------- BUDDY CONNECTIONS ----------
CREATE TABLE IF NOT EXISTS buddy_connections (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id_a    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  profile_id_b    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status          TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined')),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT distinct_buddies CHECK (profile_id_a <> profile_id_b),
  CONSTRAINT unique_buddy_pair UNIQUE (profile_id_a, profile_id_b)
);
CREATE INDEX IF NOT EXISTS idx_buddy_pending ON buddy_connections(profile_id_b, status);

-- ---------- BLOCKED USERS ----------
CREATE TABLE IF NOT EXISTS blocked_users (
  id              BIGSERIAL PRIMARY KEY,
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  blocked_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, blocked_user_id)
);

-- ---------- BOOKING SERVICES ----------
CREATE TABLE IF NOT EXISTS booking_services (
  id            BIGSERIAL PRIMARY KEY,
  booking_id    UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  service_type  TEXT NOT NULL CHECK (service_type IN ('flight', 'hotel', 'restaurant', 'park', 'resort', 'spa', 'activity')),
  service_name  TEXT NOT NULL,
  quantity      INT NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit_price    NUMERIC(12,2) NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- INSURANCE PLANS (admin-editable) ----------
CREATE TABLE IF NOT EXISTS insurance_plans (
  id                SERIAL PRIMARY KEY,
  name              TEXT NOT NULL UNIQUE,
  description       TEXT,
  coverage_limit    NUMERIC(12,2) NOT NULL DEFAULT 0,
  deductible        NUMERIC(12,2) NOT NULL DEFAULT 0,
  medical_evac      NUMERIC(12,2) NOT NULL DEFAULT 0,
  cancellation_cover NUMERIC(12,2) NOT NULL DEFAULT 0,
  is_active         BOOLEAN NOT NULL DEFAULT true,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- DISCOUNTS ----------
CREATE TABLE IF NOT EXISTS discounts (
  id                SERIAL PRIMARY KEY,
  code              TEXT NOT NULL UNIQUE,
  discount_percent  NUMERIC(5,2) NOT NULL CHECK (discount_percent > 0 AND discount_percent <= 100),
  package_slug      TEXT,
  max_uses          INT,
  remaining_uses    INT,
  expires_at        TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_discounts_code ON discounts(code);

-- ---------- AUTOMATIONS ----------
CREATE TABLE IF NOT EXISTS automations (
  id              SERIAL PRIMARY KEY,
  task            TEXT NOT NULL,
  trigger_event   TEXT NOT NULL CHECK (trigger_event IN ('payment_received', 'date_reached', 'seats_below_limit', 'discount_expires')),
  target_date     DATE,
  params          JSONB NOT NULL DEFAULT '{}',
  is_active       BOOLEAN NOT NULL DEFAULT true,
  last_run_at     TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- ADMIN AUDIT LOG ----------
CREATE TABLE IF NOT EXISTS admin_audit_log (
  id            BIGSERIAL PRIMARY KEY,
  admin_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  action        TEXT NOT NULL,
  details       JSONB NOT NULL DEFAULT '{}',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_admin_audit_admin ON admin_audit_log(admin_id);
CREATE INDEX IF NOT EXISTS idx_admin_audit_created ON admin_audit_log(created_at DESC);

-- ---------- MFA SETTINGS ----------
CREATE TABLE IF NOT EXISTS mfa_settings (
  id            SERIAL PRIMARY KEY,
  user_id       UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  secret_hash   TEXT NOT NULL,
  method        TEXT NOT NULL DEFAULT 'totp' CHECK (method IN ('totp', 'sms', 'email')),
  enabled       BOOLEAN NOT NULL DEFAULT false,
  verified_at   TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- TRIGGERS for new tables ----------
DROP TRIGGER IF EXISTS trg_social_profiles_updated_at ON social_profiles;
CREATE TRIGGER trg_social_profiles_updated_at BEFORE UPDATE ON social_profiles
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_social_posts_updated_at ON social_posts;
CREATE TRIGGER trg_social_posts_updated_at BEFORE UPDATE ON social_posts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_insurance_plans_updated_at ON insurance_plans;
CREATE TRIGGER trg_insurance_plans_updated_at BEFORE UPDATE ON insurance_plans
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_automations_updated_at ON automations;
CREATE TRIGGER trg_automations_updated_at BEFORE UPDATE ON automations
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_mfa_settings_updated_at ON mfa_settings;
CREATE TRIGGER trg_mfa_settings_updated_at BEFORE UPDATE ON mfa_settings
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
