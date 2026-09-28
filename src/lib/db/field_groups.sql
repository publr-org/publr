INSERT OR IGNORE INTO field_groups (scope, owner, definition)
SELECT 'content_types', id,
    json_object('fields', json_extract(definition, '$.fields'),
        'options', json(COALESCE(json_extract(definition, '$.group'), '{}')))
FROM content_types;

INSERT OR IGNORE INTO field_groups (scope, owner, definition)
SELECT 'taxonomies', id,
    json_object('fields', json_extract(definition, '$.fields'),
        'options', json(COALESCE(json_extract(definition, '$.group'), '{}')))
FROM taxonomies;

INSERT OR IGNORE INTO field_groups (scope, owner, definition)
SELECT 'custom_fields', substr(key, 15),
    json_object('fields', json_extract(value, '$.fields'),
        'options', json(COALESCE(json_extract(value, '$.group'), '{}')))
FROM settings WHERE key IN ('custom_fields.user', 'custom_fields.media');

UPDATE content_types SET definition = json_set(definition, '$.fields', json('[]'), '$.group', json('{}'));
UPDATE taxonomies SET definition = json_set(definition, '$.fields', json('[]'), '$.group', json('{}'));
DELETE FROM settings WHERE key IN ('custom_fields.user', 'custom_fields.media');
INSERT INTO settings (key, value, updated_at) VALUES ('schema.field_groups', '1', 0);
