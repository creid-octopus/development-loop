-- V3: sample rows so a fresh database has something to show.
-- Safe to re-run against an empty table only. Flyway runs it once.

INSERT INTO items (name, description) VALUES
    ('first item',  'Created by migration V3'),
    ('second item', 'Created by migration V3'),
    ('third item',  NULL);
