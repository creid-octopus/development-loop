-- V2: expand step. Adds a nullable column.
--
-- This is safe to run before the app changes. The previous app version never
-- reads or writes `description`, so it keeps working against this schema.
-- That property is what lets an app rollback succeed without a database rollback.
--
-- The matching contract step (if the column is ever replaced) belongs in a
-- later release, after no running app version depends on the old shape.

ALTER TABLE items ADD COLUMN description TEXT;
