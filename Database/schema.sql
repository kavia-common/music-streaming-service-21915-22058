-- PostgreSQL schema for Music Streaming Service
-- Includes tables, relationships, constraints, default timestamps, and essential indexes

-- Safety: ensure extensions useful for UUIDs and trigram search (optional, guarded)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'uuid-ossp') THEN
        CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
    END IF;
EXCEPTION WHEN insufficient_privilege THEN
    -- ignore if cannot create extension
    NULL;
END$$;

-- Use UTC timestamps default
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- USERS
CREATE TABLE IF NOT EXISTS users (
    id                 UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email              CITEXT UNIQUE NOT NULL,
    password_hash      TEXT NOT NULL,
    display_name       VARCHAR(120),
    is_admin           BOOLEAN NOT NULL DEFAULT FALSE,
    status             VARCHAR(20) NOT NULL DEFAULT 'active', -- active, disabled, deleted
    notification_settings JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes for users
CREATE INDEX IF NOT EXISTS idx_users_email ON users (email);
CREATE INDEX IF NOT EXISTS idx_users_status ON users (status);

-- ARTISTS
CREATE TABLE IF NOT EXISTS artists (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name         VARCHAR(200) NOT NULL,
    bio          TEXT,
    country      VARCHAR(100),
    metadata     JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_artists_name ON artists (name);

-- ALBUMS
CREATE TABLE IF NOT EXISTS albums (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    artist_id      UUID NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
    title          VARCHAR(200) NOT NULL,
    release_date   DATE,
    cover_image_url TEXT,
    metadata       JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_albums_artist_id ON albums (artist_id);
CREATE INDEX IF NOT EXISTS idx_albums_title ON albums (title);

-- TRACKS
CREATE TABLE IF NOT EXISTS tracks (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    album_id        UUID REFERENCES albums(id) ON DELETE SET NULL,
    artist_id       UUID NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
    title           VARCHAR(250) NOT NULL,
    duration_secs   INTEGER NOT NULL CHECK (duration_secs >= 0),
    track_number    INTEGER,
    disc_number     INTEGER,
    genre           VARCHAR(100),
    audio_url       TEXT, -- pointer/URI to object storage/CND
    is_explicit     BOOLEAN NOT NULL DEFAULT FALSE,
    popularity      INTEGER NOT NULL DEFAULT 0, -- for ranking
    metadata        JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_tracks_artist_id ON tracks (artist_id);
CREATE INDEX IF NOT EXISTS idx_tracks_album_id ON tracks (album_id);
CREATE INDEX IF NOT EXISTS idx_tracks_title ON tracks (title);
CREATE INDEX IF NOT EXISTS idx_tracks_genre ON tracks (genre);
CREATE INDEX IF NOT EXISTS idx_tracks_popularity ON tracks (popularity DESC);

-- PLAYLISTS
CREATE TABLE IF NOT EXISTS playlists (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_user_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name            VARCHAR(200) NOT NULL,
    description     TEXT,
    is_public       BOOLEAN NOT NULL DEFAULT FALSE,
    cover_image_url TEXT,
    total_duration_secs INTEGER NOT NULL DEFAULT 0,
    total_tracks    INTEGER NOT NULL DEFAULT 0,
    metadata        JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_playlists_owner ON playlists (owner_user_id);
CREATE INDEX IF NOT EXISTS idx_playlists_public ON playlists (is_public);

-- PLAYLIST_TRACKS (junction with ordering)
CREATE TABLE IF NOT EXISTS playlist_tracks (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    playlist_id     UUID NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    track_id        UUID NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    added_by_user_id UUID NOT NULL REFERENCES users(id) ON DELETE SET NULL,
    position        INTEGER NOT NULL, -- 1-based order within playlist
    added_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (playlist_id, track_id),
    UNIQUE (playlist_id, position)
);
CREATE INDEX IF NOT EXISTS idx_playlist_tracks_playlist ON playlist_tracks (playlist_id);
CREATE INDEX IF NOT EXISTS idx_playlist_tracks_track ON playlist_tracks (track_id);

-- Trigger to keep playlist counts/duration updated
CREATE OR REPLACE FUNCTION update_playlist_aggregates()
RETURNS TRIGGER AS $$
BEGIN
  -- Recalculate aggregates for the affected playlist
  UPDATE playlists p SET
    total_tracks = (SELECT COUNT(*) FROM playlist_tracks pt WHERE pt.playlist_id = p.id),
    total_duration_secs = COALESCE((SELECT SUM(t.duration_secs)
                                    FROM playlist_tracks pt
                                    JOIN tracks t ON t.id = pt.track_id
                                    WHERE pt.playlist_id = p.id), 0),
    updated_at = NOW()
  WHERE p.id = COALESCE(NEW.playlist_id, OLD.playlist_id);
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_playlist_tracks_agg_ins
AFTER INSERT ON playlist_tracks
FOR EACH ROW EXECUTE FUNCTION update_playlist_aggregates();

CREATE TRIGGER trg_playlist_tracks_agg_del
AFTER DELETE ON playlist_tracks
FOR EACH ROW EXECUTE FUNCTION update_playlist_aggregates();

CREATE TRIGGER trg_playlist_tracks_agg_upd
AFTER UPDATE OF playlist_id, track_id ON playlist_tracks
FOR EACH ROW EXECUTE FUNCTION update_playlist_aggregates();

-- PLAYBACK_HISTORY
CREATE TABLE IF NOT EXISTS playback_history (
    id              BIGSERIAL PRIMARY KEY,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    track_id        UUID NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    played_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    device_info     JSONB NOT NULL DEFAULT '{}'::jsonb,
    session_id      UUID,
    play_duration_secs INTEGER CHECK (play_duration_secs IS NULL OR play_duration_secs >= 0)
);
CREATE INDEX IF NOT EXISTS idx_playback_user_time ON playback_history (user_id, played_at DESC);
CREATE INDEX IF NOT EXISTS idx_playback_track_time ON playback_history (track_id, played_at DESC);

-- USER_ACTIVITY (generic audit/activity log)
CREATE TABLE IF NOT EXISTS user_activity (
    id              BIGSERIAL PRIMARY KEY,
    user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
    activity_type   VARCHAR(100) NOT NULL, -- e.g., login, logout, like, follow, search
    activity_data   JSONB NOT NULL DEFAULT '{}'::jsonb,
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_user_activity_user_time ON user_activity (user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_user_activity_type_time ON user_activity (activity_type, occurred_at DESC);

-- ADMIN_AUDIT_LOGS
CREATE TABLE IF NOT EXISTS admin_audit_logs (
    id              BIGSERIAL PRIMARY KEY,
    admin_user_id   UUID REFERENCES users(id) ON DELETE SET NULL,
    action          VARCHAR(150) NOT NULL, -- e.g., create_track, delete_user
    target_type     VARCHAR(100) NOT NULL, -- e.g., user, track, playlist
    target_id       UUID,
    details         JSONB NOT NULL DEFAULT '{}'::jsonb,
    ip_address      INET,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_admin_audit_time ON admin_audit_logs (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_audit_action ON admin_audit_logs (action);

-- RECOMMENDATIONS_CACHE
CREATE TABLE IF NOT EXISTS recommendations_cache (
    user_id         UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    recommendations JSONB NOT NULL, -- array of track IDs with scores: [{track_id, score}]
    generated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at      TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_reco_expires ON recommendations_cache (expires_at);

-- Optional: likes/favorites for tracks (commonly used)
CREATE TABLE IF NOT EXISTS user_liked_tracks (
    user_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    track_id  UUID NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    liked_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, track_id)
);
CREATE INDEX IF NOT EXISTS idx_liked_tracks_track ON user_liked_tracks (track_id);

-- Triggers to auto-update updated_at
CREATE TRIGGER trg_users_updated_at
BEFORE UPDATE ON users
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_artists_updated_at
BEFORE UPDATE ON artists
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_albums_updated_at
BEFORE UPDATE ON albums
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_tracks_updated_at
BEFORE UPDATE ON tracks
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_playlists_updated_at
BEFORE UPDATE ON playlists
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Useful views
CREATE OR REPLACE VIEW v_track_full AS
SELECT
  t.id AS track_id,
  t.title AS track_title,
  t.duration_secs,
  t.genre,
  t.popularity,
  a.id AS album_id,
  a.title AS album_title,
  ar.id AS artist_id,
  ar.name AS artist_name
FROM tracks t
LEFT JOIN albums a ON a.id = t.album_id
JOIN artists ar ON ar.id = t.artist_id;

-- Permissions note:
-- Ensure app user has privileges, granted by startup.sh; nothing to do in schema.

-- End of schema
