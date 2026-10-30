-- V5: expand step. Adds a nullable column.
--
-- Added to test pull request environments (layer 6). No app version reads or
-- writes `category` yet, so every app version keeps working against this schema.
-- Never edit this file once it has run in Development.

ALTER TABLE items ADD COLUMN category TEXT;
