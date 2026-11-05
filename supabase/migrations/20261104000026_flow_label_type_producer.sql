-- Producer-movement labels get their own label type. Kept in its own migration because a new enum value
-- cannot be used in the same transaction that adds it.
alter type flow.label_type add value if not exists 'producer';
