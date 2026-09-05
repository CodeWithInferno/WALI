-- Catalog options belong to deployed configuration, not synthetic local seed data.
-- Preserve existing IDs, disabled options, and operator edits on conflict.
insert into wali.categories (slug, name, description, sort_order) values
  ('nature', 'Nature', 'Landscapes and natural environments.', 10),
  ('space', 'Space', 'Stars, planets, and imagined cosmic scenes.', 20),
  ('abstract', 'Abstract', 'Abstract color, geometry, and motion.', 30),
  ('anime-illustration', 'Anime & Illustration', 'Illustrated and animated artwork.', 40),
  ('games', 'Games', 'Game-inspired scenes with documented rights.', 50),
  ('film-tv', 'Film & TV', 'Film and television material with documented rights.', 60),
  ('cars', 'Cars', 'Automotive scenes and motion.', 70),
  ('cities', 'Cities', 'Cityscapes and urban environments.', 80),
  ('technology', 'Technology', 'Digital systems and technology-inspired scenes.', 90),
  ('minimal', 'Minimal', 'Quiet, low-complexity compositions.', 100),
  ('retro', 'Retro', 'Historical and retro-inspired aesthetics.', 110),
  ('other', 'Other', 'Material not represented by another active category.', 120)
on conflict (slug) do nothing;

insert into wali.tags (slug, label, kind) values
  ('mountains', 'Mountains', 'subject'),
  ('ocean', 'Ocean', 'subject'),
  ('forest', 'Forest', 'subject'),
  ('night', 'Night', 'setting'),
  ('aurora', 'Aurora', 'subject'),
  ('rain', 'Rain', 'setting'),
  ('minimal', 'Minimal', 'style'),
  ('neon', 'Neon', 'style'),
  ('cyber', 'Cyber', 'style'),
  ('calm', 'Calm', 'mood'),
  ('energetic', 'Energetic', 'mood'),
  ('dark', 'Dark', 'mood'),
  ('colorful', 'Colorful', 'color'),
  ('loop', 'Seamless Loop', 'motion')
on conflict (slug) do nothing;

-- These choices do not grant rights in uploaded media. The creator must make
-- an explicit rights declaration, and publication still requires moderation.
insert into wali.licenses (
  code, name, spdx_expression, terms_url, attribution_required,
  commercial_use_allowed, derivatives_allowed, redistribution_allowed, terms_revision
) values
  ('cc0-1.0', 'CC0 1.0 Universal', 'CC0-1.0',
    'https://creativecommons.org/publicdomain/zero/1.0/', false, true, true, true, 1),
  ('cc-by-4.0', 'Creative Commons Attribution 4.0', 'CC-BY-4.0',
    'https://creativecommons.org/licenses/by/4.0/', true, true, true, true, 1)
on conflict (code) do nothing;
