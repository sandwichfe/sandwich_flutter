-- embyx 初始 schema。复杂字段以 JSON 文本存储，先跑通链路，后续可拆表。

CREATE TABLE IF NOT EXISTS users (
    id                TEXT PRIMARY KEY,
    name              TEXT NOT NULL UNIQUE COLLATE NOCASE,
    password_hash     TEXT NOT NULL,
    is_admin          INTEGER NOT NULL DEFAULT 0,
    primary_image_tag TEXT NOT NULL DEFAULT '',
    created_at        TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tokens (
    token      TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS libraries (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    collection_type TEXT NOT NULL DEFAULT 'movies',
    -- path 保留作为单目录兼容字段，paths 是权威数据（JSON 数组，支持一个库多个目录）
    path            TEXT NOT NULL DEFAULT '',
    paths           TEXT NOT NULL DEFAULT '[]',
    sort_order      INTEGER NOT NULL DEFAULT 0,
    -- 1 = 优先使用媒体目录里的海报/封面，0 = 优先使用服务端从视频画面生成的图片
    prefer_local_artwork INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS items (
    id              TEXT PRIMARY KEY,
    library_id      TEXT NOT NULL DEFAULT '',
    parent_id       TEXT NOT NULL DEFAULT '',
    type            TEXT NOT NULL DEFAULT '',
    name            TEXT NOT NULL DEFAULT '',
    sort_name       TEXT NOT NULL DEFAULT '',
    overview        TEXT NOT NULL DEFAULT '',
    production_year INTEGER,
    premiere_date   TEXT NOT NULL DEFAULT '',
    date_created    TEXT NOT NULL DEFAULT '',
    community_rating REAL,
    official_rating TEXT NOT NULL DEFAULT '',
    run_time_ticks  INTEGER NOT NULL DEFAULT 0,
    width           INTEGER NOT NULL DEFAULT 0,
    height          INTEGER NOT NULL DEFAULT 0,
    path            TEXT NOT NULL DEFAULT '',
    container       TEXT NOT NULL DEFAULT '',
    size            INTEGER NOT NULL DEFAULT 0,
    bitrate         INTEGER NOT NULL DEFAULT 0,
    media_streams   TEXT NOT NULL DEFAULT '[]',
    genres          TEXT NOT NULL DEFAULT '[]',
    tags            TEXT NOT NULL DEFAULT '[]',
    studios         TEXT NOT NULL DEFAULT '[]',
    people          TEXT NOT NULL DEFAULT '[]',
    chapters        TEXT NOT NULL DEFAULT '[]',
    provider_ids    TEXT NOT NULL DEFAULT '{}',
    external_urls   TEXT NOT NULL DEFAULT '[]',
    image_tags      TEXT NOT NULL DEFAULT '{}',
    backdrop_tags   TEXT NOT NULL DEFAULT '[]',
    screenshot_tags TEXT NOT NULL DEFAULT '[]'
);

CREATE INDEX IF NOT EXISTS idx_items_library ON items(library_id);
CREATE INDEX IF NOT EXISTS idx_items_parent ON items(parent_id);
CREATE INDEX IF NOT EXISTS idx_items_type ON items(type);
CREATE INDEX IF NOT EXISTS idx_items_name ON items(name);
CREATE INDEX IF NOT EXISTS idx_items_sort_name ON items(sort_name);
CREATE INDEX IF NOT EXISTS idx_items_premiere ON items(premiere_date);

CREATE TABLE IF NOT EXISTS user_data (
    user_id                 TEXT NOT NULL,
    item_id                 TEXT NOT NULL,
    is_favorite             INTEGER NOT NULL DEFAULT 0,
    played                  INTEGER NOT NULL DEFAULT 0,
    playback_position_ticks INTEGER NOT NULL DEFAULT 0,
    play_count              INTEGER NOT NULL DEFAULT 0,
    last_played_date        TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (user_id, item_id)
);

CREATE INDEX IF NOT EXISTS idx_user_data_played ON user_data(user_id, last_played_date);

CREATE TABLE IF NOT EXISTS play_sessions (
    id             TEXT PRIMARY KEY,
    user_id        TEXT NOT NULL,
    item_id        TEXT NOT NULL,
    position_ticks INTEGER NOT NULL DEFAULT 0,
    updated_at     TEXT NOT NULL
);
