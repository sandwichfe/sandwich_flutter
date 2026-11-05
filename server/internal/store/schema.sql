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
    screenshot_tags TEXT NOT NULL DEFAULT '[]',
    -- fingerprint 是 "size:mtime" 的组合，重复扫描时和库里比对，相同就跳过 ffprobe
    fingerprint     TEXT NOT NULL DEFAULT '',
    -- nfo_mtime 单独记录 NFO 的修改时间：视频没动但 NFO 改了，也要重新入库
    nfo_mtime       INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_items_library ON items(library_id);
CREATE INDEX IF NOT EXISTS idx_items_parent ON items(parent_id);
CREATE INDEX IF NOT EXISTS idx_items_type ON items(type);
CREATE INDEX IF NOT EXISTS idx_items_name ON items(name);
CREATE INDEX IF NOT EXISTS idx_items_sort_name ON items(sort_name);
CREATE INDEX IF NOT EXISTS idx_items_premiere ON items(premiere_date);
-- 「库内最新加入」走 (library_id, date_created) 复合索引，避免每次临时 B 树排序
CREATE INDEX IF NOT EXISTS idx_items_library_created ON items(library_id, date_created);

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
-- 「继续观看」的播放位置过滤复用不到上面那条索引，单独补一条
CREATE INDEX IF NOT EXISTS idx_user_data_resume ON user_data(user_id, played, last_played_date);

CREATE TABLE IF NOT EXISTS play_sessions (
    id             TEXT PRIMARY KEY,
    user_id        TEXT NOT NULL,
    item_id        TEXT NOT NULL,
    position_ticks INTEGER NOT NULL DEFAULT 0,
    updated_at     TEXT NOT NULL
);

-- 人物关联表：把 items.people 的 JSON 拆成可索引的行，供人物筛选与作品聚合。
-- items.people 仍是展示用的权威数据，这里只是查询副本，入库时同步写入。
CREATE TABLE IF NOT EXISTS item_people (
    item_id    TEXT NOT NULL,
    person_id  TEXT NOT NULL,
    role       TEXT NOT NULL DEFAULT '',
    type       TEXT NOT NULL DEFAULT '',
    sort_order INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_item_people_item ON item_people(item_id);
CREATE INDEX IF NOT EXISTS idx_item_people_person ON item_people(person_id);

-- 人物汇总表：/Persons 直接分页查它，不再读全表 people JSON 再在内存里排序。
CREATE TABLE IF NOT EXISTS person_view (
    person_id  TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    image_tag  TEXT NOT NULL DEFAULT '',
    item_count INTEGER NOT NULL DEFAULT 0
);
