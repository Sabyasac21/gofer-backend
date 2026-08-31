-- A customer may browse anonymously, but a booking is tied to a Firebase
-- verified phone identity.  The server, rather than the mobile client, owns
-- the proof of that identity.
ALTER TABLE gofer_customers
  ADD COLUMN IF NOT EXISTS firebase_uid VARCHAR(128),
  ADD COLUMN IF NOT EXISTS phone_verified_at TIMESTAMPTZ;

CREATE UNIQUE INDEX IF NOT EXISTS gofer_customers_firebase_uid_unique
  ON gofer_customers(firebase_uid)
  WHERE firebase_uid IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS gofer_customers_phone_verified_unique
  ON gofer_customers(phone)
  WHERE phone_verified_at IS NOT NULL;
