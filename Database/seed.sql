-- Optional sample seed data for local development
-- Inserts a demo user, a few artists, albums, and tracks
-- Safe to run multiple times due to ON CONFLICT and NOT EXISTS guards

-- Ensure citext extension (if available) for case-insensitive email; ignore errors if not permitted
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'citext') THEN
    CREATE EXTENSION IF NOT EXISTS citext;
  END IF;
EXCEPTION WHEN insufficient_privilege THEN
  NULL;
END$$;

-- Seed demo user (password_hash here is a placeholder; do not use in production)
INSERT INTO users (id, email, password_hash, display_name, is_admin, status)
VALUES (
  uuid_generate_v4(),
  'demo@example.com',
  '$2y$12$abcdefghijklmnopqrstuvabcdefghijklmnopqrstuvabcdefghijklmn', -- bcrypt placeholder
  'Demo User',
  TRUE,
  'active'
)
ON CONFLICT (email) DO NOTHING;

-- Artists
WITH a AS (
  SELECT 'The Sampletones'::text AS name, 'An eclectic sample artist'::text AS bio, 'US'::text AS country
  UNION ALL
  SELECT 'DJ Placeholder', 'Producer and DJ of placeholder beats', 'UK'
  UNION ALL
  SELECT 'Lo-Fi Ensemble', 'Collective focusing on chill lo-fi tracks', 'JP'
)
INSERT INTO artists (id, name, bio, country)
SELECT uuid_generate_v4(), name, bio, country
FROM a
WHERE NOT EXISTS (
  SELECT 1 FROM artists ar WHERE ar.name = a.name
);

-- Albums
WITH artist_ids AS (
  SELECT id, name FROM artists WHERE name IN ('The Sampletones','DJ Placeholder','Lo-Fi Ensemble')
),
alb AS (
  SELECT (SELECT id FROM artist_ids WHERE name='The Sampletones') AS artist_id,
         'Hello World'::text AS title,
         '2021-01-01'::date AS release_date,
         NULL::text AS cover_image_url
  UNION ALL
  SELECT (SELECT id FROM artist_ids WHERE name='DJ Placeholder'),
         'Placeholders Vol. 1', '2022-05-20', NULL
  UNION ALL
  SELECT (SELECT id FROM artist_ids WHERE name='Lo-Fi Ensemble'),
         'Midnight Coding', '2020-10-10', NULL
)
INSERT INTO albums (id, artist_id, title, release_date, cover_image_url)
SELECT uuid_generate_v4(), artist_id, title, release_date, cover_image_url
FROM alb
WHERE NOT EXISTS (
  SELECT 1 FROM albums al
  WHERE al.title = alb.title
    AND al.artist_id = alb.artist_id
);

-- Tracks
WITH artist_ids AS (
  SELECT id, name FROM artists WHERE name IN ('The Sampletones','DJ Placeholder','Lo-Fi Ensemble')
),
album_ids AS (
  SELECT id, title FROM albums WHERE title IN ('Hello World','Placeholders Vol. 1','Midnight Coding')
),
t AS (
  SELECT
    (SELECT id FROM album_ids WHERE title='Hello World') AS album_id,
    (SELECT id FROM artist_ids WHERE name='The Sampletones') AS artist_id,
    'Intro Sequence'::text AS title, 95::int AS duration_secs, 1::int AS track_number, 1::int AS disc_number, 'Indie'::text AS genre, FALSE::boolean AS is_explicit
  UNION ALL
  SELECT
    (SELECT id FROM album_ids WHERE title='Hello World'),
    (SELECT id FROM artist_ids WHERE name='The Sampletones'),
    'Main Theme', 210, 2, 1, 'Indie', FALSE
  UNION ALL
  SELECT
    (SELECT id FROM album_ids WHERE title='Placeholders Vol. 1'),
    (SELECT id FROM artist_ids WHERE name='DJ Placeholder'),
    'Lorem Beats', 180, 1, 1, 'Electronic', FALSE
  UNION ALL
  SELECT
    (SELECT id FROM album_ids WHERE title='Midnight Coding'),
    (SELECT id FROM artist_ids WHERE name='Lo-Fi Ensemble'),
    'Coffee & Code', 240, 1, 1, 'Lo-Fi', FALSE
)
INSERT INTO tracks (
  id, album_id, artist_id, title, duration_secs, track_number, disc_number, genre, is_explicit, popularity
)
SELECT
  uuid_generate_v4(), album_id, artist_id, title, duration_secs, track_number, disc_number, genre, is_explicit, 0
FROM t
WHERE NOT EXISTS (
  SELECT 1 FROM tracks tr
  WHERE tr.title = t.title
    AND tr.artist_id = t.artist_id
);

-- Optional: create a public playlist for the demo user with 2 tracks
WITH demo_user AS (
  SELECT id AS user_id FROM users WHERE email = 'demo@example.com' LIMIT 1
),
pl AS (
  SELECT (SELECT user_id FROM demo_user),
         'Demo Playlist'::text,
         'A small selection of seeded tracks'::text,
         TRUE::boolean
)
INSERT INTO playlists (id, owner_user_id, name, description, is_public)
SELECT uuid_generate_v4(), * FROM pl
WHERE NOT EXISTS (
  SELECT 1 FROM playlists p WHERE p.name = 'Demo Playlist'
);

-- Add two tracks to the playlist
WITH pl_id AS (
  SELECT id FROM playlists WHERE name='Demo Playlist' LIMIT 1
),
sel_tracks AS (
  SELECT id FROM tracks WHERE title IN ('Intro Sequence','Coffee & Code') ORDER BY title
),
ordered AS (
  SELECT id, ROW_NUMBER() OVER (ORDER BY title) AS pos
  FROM tracks WHERE title IN ('Intro Sequence','Coffee & Code')
)
INSERT INTO playlist_tracks (id, playlist_id, track_id, added_by_user_id, position)
SELECT uuid_generate_v4(),
       (SELECT id FROM pl_id),
       o.id,
       (SELECT id FROM users WHERE email='demo@example.com' LIMIT 1),
       o.pos
FROM ordered o
WHERE NOT EXISTS (
  SELECT 1 FROM playlist_tracks pt
  WHERE pt.playlist_id = (SELECT id FROM pl_id)
    AND pt.track_id = o.id
);

-- End of seed
