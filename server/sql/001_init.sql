-- ============================================================
-- Initial schema
-- ============================================================

create extension if not exists vector;
create extension if not exists pg_trgm;

create table repos (
  id              uuid primary key default gen_random_uuid(),
  owner           text        not null,
  name            text        not null,
  full_name       text        not null unique,
  default_branch  text        not null default 'main',
  description     text,
  status          text        not null default 'pending',
  stage           text,
  progress        int         not null default 0,
  error           text,
  file_count      int         not null default 0,
  commit_count    int         not null default 0,
  pr_count        int         not null default 0,
  issue_count     int         not null default 0,
  chunk_count     int         not null default 0,

  indexed_at      timestamptz,
  created_at      timestamptz not null default now(),

  constraint repos_status_check
    check (status in ('pending', 'ingesting', 'ready', 'failed'))
);

create index repos_status_idx on repos (status);

-----------------------------------------------------------------------------------------------------------------------------------


-- ------------------------------------------------------------
-- files: all source files at HEAD
-- ------------------------------------------------------------
create table files (
  id          uuid primary key default gen_random_uuid(),
  repo_id     uuid not null references repos(id) on delete cascade,
  path        text not null,
  language    text,
  size_bytes  int  not null default 0,
  blob_sha    text,
  content     text,
  created_at  timestamptz not null default now(),

  unique (repo_id, path)
);

create index files_repo_idx on files (repo_id);
create index files_path_trgm_idx on files using gin (path gin_trgm_ops);

-------------------------------------------------------------------------------------------------------------------------------------


-- ------------------------------------------------------------
-- commits
-- ------------------------------------------------------------
create table commits (
  id             uuid primary key default gen_random_uuid(),
  repo_id        uuid not null references repos(id) on delete cascade,
  sha            text not null,
  message        text not null default '',
  author_name    text,
  author_login   text,
  author_email   text,
  authored_at    timestamptz not null,
  additions      int not null default 0,
  deletions      int not null default 0,
  files_changed  int not null default 0,

  unique (repo_id, sha)
);

create index commits_repo_date_idx on commits (repo_id, authored_at desc);
create index commits_author_idx    on commits (repo_id, author_login);


--------------------------------------------------------------------------------------------------------------------------------------


-- ------------------------------------------------------------
-- commit_files: which paths each commit touched.
-- This is the table that answers ownership questions.
-- ------------------------------------------------------------
create table commit_files (
  id         bigserial primary key,
  repo_id    uuid not null references repos(id) on delete cascade,
  commit_id  uuid not null references commits(id) on delete cascade,
  path       text not null,
  status     text,
  additions  int not null default 0,
  deletions  int not null default 0
);

create index commit_files_repo_path_idx on commit_files (repo_id, path);
create index commit_files_commit_idx    on commit_files (commit_id);

------------------------------------------------------------------------------------------------------------------------------------


-- ------------------------------------------------------------
-- pull requests
-- ------------------------------------------------------------
create table pull_requests (
  id            uuid primary key default gen_random_uuid(),
  repo_id       uuid not null references repos(id) on delete cascade,
  number        int  not null,
  title         text not null default '',
  body          text,
  state         text,
  author_login  text,
  merge_commit_sha text,
  created_at_gh timestamptz,
  merged_at     timestamptz,
  closed_at     timestamptz,

  unique (repo_id, number)
);

create index pull_requests_repo_date_idx on pull_requests (repo_id, created_at_gh desc);


-------------------------------------------------------------------------------------------------------------------------------------


-- ------------------------------------------------------------
-- issues
-- ------------------------------------------------------------
create table issues (
  id            uuid primary key default gen_random_uuid(),
  repo_id       uuid not null references repos(id) on delete cascade,
  number        int  not null,
  title         text not null default '',
  body          text,
  state         text,
  author_login  text,
  labels        text[],
  created_at_gh timestamptz,
  closed_at     timestamptz,

  unique (repo_id, number)
);

create index issues_repo_date_idx on issues (repo_id, created_at_gh desc);


-----------------------------------------------------------------------------------------------------------------------------------


-- ------------------------------------------------------------
-- chunks: the single retrieval surface across all four sources
-- ------------------------------------------------------------
create table chunks (
  id           uuid primary key default gen_random_uuid(),
  repo_id      uuid not null references repos(id) on delete cascade,

  -- which corpus this came from
  source_type  text not null,
  source_id    uuid,

  -- code-specific provenance (null for commit/pr/issue chunks)
  path         text,
  symbol       text,
  kind         text,
  line_start   int,
  line_end     int,

  -- history-specific provenance
  commit_sha   text,
  ref_number   int,

  -- THE temporal filter column: every chunk knows when it happened
  occurred_at  timestamptz,

  content      text not null,
  token_count  int,

  embedding    vector(768),

  tsv tsvector generated always as (
    to_tsvector('english', coalesce(symbol, '') || ' ' ||
                           coalesce(path, '')   || ' ' || content)
  ) stored,

  created_at   timestamptz not null default now(),

  constraint chunks_source_type_check
    check (source_type in ('code', 'commit', 'pr', 'issue'))
);


-------------------------------------------------------------------------------------------------------------------------------------


-- Vector index. HNSW + cosine, same as Pagewise.
create index chunks_embedding_idx
  on chunks using hnsw (embedding vector_cosine_ops)
  with (m = 16, ef_construction = 64);

-- Keyword index. This is the half Pagewise doesn't have.
create index chunks_tsv_idx on chunks using gin (tsv);

-- Metadata filters
create index chunks_repo_type_idx on chunks (repo_id, source_type);
create index chunks_repo_time_idx on chunks (repo_id, occurred_at desc);
create index chunks_repo_path_idx on chunks (repo_id, path);

-- Exact symbol lookup: "where is validateRefreshToken defined"
create index chunks_symbol_trgm_idx on chunks using gin (symbol gin_trgm_ops);


-- ------------------------------------------------------------
-- who_owns: commit-author aggregation for a path prefix,
-- weighted toward recent work.
-- ------------------------------------------------------------
create or replace function who_owns(
  p_repo_id uuid,
  p_path    text,
  p_limit   int default 5
)
returns table (
  author_login  text,
  author_name   text,
  commit_count  bigint,
  lines_changed bigint,
  last_touched  timestamptz,
  recency_score numeric
)
language sql
stable
as $$
  select
    c.author_login,
    max(c.author_name)                            as author_name,
    count(*)                                      as commit_count,
    sum(cf.additions + cf.deletions)              as lines_changed,
    max(c.authored_at)                            as last_touched,
    round(sum(
      exp(-extract(epoch from (now() - c.authored_at)) / (86400 * 180))
    )::numeric, 3)                                as recency_score
  from commit_files cf
  join commits c on c.id = cf.commit_id
  where cf.repo_id = p_repo_id
    and cf.path like p_path || '%'
    and c.author_login is not null
  group by c.author_login
  order by recency_score desc, commit_count desc
  limit p_limit;
$$;