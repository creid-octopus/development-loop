-- R: repeatable view. Flyway runs it again whenever this file changes.
--
-- Added for the layer 3 rollback tests. No app version reads it.
-- Change the summary_version value to make Flyway apply it again.

CREATE OR REPLACE VIEW items_summary AS
SELECT
    2               AS summary_version,
    count(*)        AS item_count,
    max(created_at) AS last_created_at
FROM items;
