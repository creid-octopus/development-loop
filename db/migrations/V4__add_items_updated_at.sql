-- V4: expand step. Adds a nullable column.
--
-- Added for the layer 3 rollback tests. No app version reads or writes
-- `updated_at` yet, so every app version keeps working against this schema.
-- Never edit this file. It has run in Development.

ALTER TABLE items ADD COLUMN updated_at TIMESTAMPTZ;
