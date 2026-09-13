-- ADR 0027: commit the enum addition before later migrations use its value.
-- This alone enables no upload, claim, publication or reader path.
alter type wali.artifact_role add value if not exists 'image_default';
