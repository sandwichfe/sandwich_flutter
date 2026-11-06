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

-- 演员主表：演员是独立主体，入库时没有就新建、有了就更新信息。
-- 条目被删除时只清关联，这一行永远保留（作品数归零后不再出现在列表里）。
-- items.people 的 JSON 退化为入库快照，展示以这张表为准。
CREATE TABLE IF NOT EXISTS persons (
    person_id  TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    sort_name  TEXT NOT NULL DEFAULT '',
    -- image_tag 是 Primary（头像），backdrop_tags 是写真/背景图（JSON 字符串数组）。
    image_tag     TEXT NOT NULL DEFAULT '',
    backdrop_tags TEXT NOT NULL DEFAULT '[]',
    -- 出生年月日与首映(出道)日期分开存，来源与语义都不一样。
    birth_date    TEXT NOT NULL DEFAULT '',
    premiere_date TEXT NOT NULL DEFAULT '',
    gender        TEXT NOT NULL DEFAULT '',
    cup_size      TEXT NOT NULL DEFAULT '',
    overview      TEXT NOT NULL DEFAULT '',
    -- provider_ids 与 items 同构：{"Tmdb":"123","Imdb":"nm456"}。
    provider_ids  TEXT NOT NULL DEFAULT '{}',
    -- manual_fields 记录手动编辑过的字段名（JSON 数组），刮削不会覆盖这些字段。
    manual_fields TEXT NOT NULL DEFAULT '[]',
    -- scraped_at 是上次 TMDB 刮削时间，match_state: matched/ambiguous/not_found。
    scraped_at    TEXT NOT NULL DEFAULT '',
    match_state   TEXT NOT NULL DEFAULT '',
    -- item_count 是 item_people 的派生值，关联变化时重算，避免列表页做全表聚合。
    item_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_persons_name ON persons(name COLLATE NOCASE);

-- 演员×条目关联表：同一演员在一条内容里可能既是导演又是编剧，
-- 所以 (item_id, person_id, type, role) 才是唯一键。
CREATE TABLE IF NOT EXISTS item_people (
    item_id    TEXT NOT NULL,
    person_id  TEXT NOT NULL,
    role       TEXT NOT NULL DEFAULT '',
    type       TEXT NOT NULL DEFAULT '',
    sort_order INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (item_id, person_id, type, role)
);

CREATE INDEX IF NOT EXISTS idx_item_people_person ON item_people(person_id);

-- 图片锁：锁上的条目/演员/媒体库，扫描导入与自动重拼封面都不会覆盖其图片。
-- 单独一张表而不是 items 加列，因为锁要覆盖三类实体（items / persons / libraries）。
CREATE TABLE IF NOT EXISTS image_locks (
    entity_id  TEXT PRIMARY KEY,
    created_at TEXT NOT NULL
);
