-- Test fixture for scripts/scan-migrations.sh. Never copy into db/migrations.
-- Each statement below should be reported.

ALTER TABLE items DROP COLUMN description;
ALTER TABLE items RENAME COLUMN name TO title;
ALTER TABLE items ADD COLUMN owner TEXT NOT NULL;
ALTER TABLE items ALTER COLUMN name SET NOT NULL;
DELETE FROM items;
