-- V1: the first table. The app reads and writes it through /api/items.
--
-- Flyway runs this file once and records it in flyway_schema_history.
-- Never edit a migration after it has run anywhere. Add a new version instead.

CREATE TABLE items (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
