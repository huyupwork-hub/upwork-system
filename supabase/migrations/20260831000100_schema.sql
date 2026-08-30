-- FieldProof — core schema.
-- Ownership anchor: inspections.inspector_id. Every access rule in the system resolves
-- to that column; see docs/DATA_MODEL.md §4.

create type public.app_role          as enum ('inspector', 'admin');
create type public.inspection_status as enum ('draft', 'submitted');
create type public.item_severity     as enum ('low', 'medium', 'high', 'critical');
create type public.item_status       as enum ('open', 'resolved');

-- ---------------------------------------------------------------- profiles

create table public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  role       public.app_role not null default 'inspector',
  full_name  text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_full_name_len check (char_length(full_name) between 1 and 120)
);

comment on table public.profiles is
  'One row per auth.users row, created by trigger. role is revoked from authenticated at the column level (D4).';

-- ---------------------------------------------------------------- inspections

create table public.inspections (
  id              uuid primary key default gen_random_uuid(),
  inspector_id    uuid not null references public.profiles (id) on delete cascade,
  site_name       text not null,
  site_address    text,
  client_name     text,
  inspection_date date not null,
  status          public.inspection_status not null default 'draft',
  submitted_at    timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  -- 'simple' rather than 'english': site names, addresses and company names are proper
  -- nouns, where stemming hurts more than it helps. The ::regconfig cast is required —
  -- without it the expression is not immutable and cannot back a generated column.
  search_tsv tsvector generated always as (
    to_tsvector(
      'simple'::regconfig,
      coalesce(site_name, '') || ' ' || coalesce(site_address, '') || ' ' || coalesce(client_name, '')
    )
  ) stored,

  constraint inspections_site_name_len    check (char_length(site_name) between 1 and 200),
  constraint inspections_site_address_len check (site_address is null or char_length(site_address) <= 300),
  constraint inspections_client_name_len  check (client_name  is null or char_length(client_name)  <= 200),

  -- submitted_at exists if and only if the inspection is submitted.
  constraint inspections_submitted_at_consistent check (
    (status = 'submitted' and submitted_at is not null) or
    (status = 'draft'     and submitted_at is null)
  )
);

comment on column public.inspections.id is
  'Device-generated for offline drafts — the idempotency key for first sync (D5). The default covers server-side inserts.';

-- ---------------------------------------------------------------- inspection_items

create table public.inspection_items (
  id            uuid primary key default gen_random_uuid(),
  inspection_id uuid not null references public.inspections (id) on delete cascade,
  sort_order    int  not null default 0,
  title         text not null,
  description   text,
  area          text,
  severity      public.item_severity not null default 'medium',
  status        public.item_status   not null default 'open',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint inspection_items_sort_order_nonneg check (sort_order >= 0),
  constraint inspection_items_title_len         check (char_length(title) between 1 and 200),
  constraint inspection_items_description_len   check (description is null or char_length(description) <= 4000),
  constraint inspection_items_area_len          check (area is null or char_length(area) <= 120),

  -- Not redundant with the primary key: this is the target of the composite foreign key
  -- from item_photos, which is what makes that table's denormalised inspection_id safe (D8).
  constraint inspection_items_id_inspection_uniq unique (id, inspection_id)
);

comment on column public.inspection_items.sort_order is
  'Non-unique; ties break on created_at (D7). Named sort_order rather than position to avoid the POSITION keyword.';

-- ---------------------------------------------------------------- item_photos

create table public.item_photos (
  id            uuid primary key default gen_random_uuid(),
  item_id       uuid not null,
  inspection_id uuid not null,
  storage_path  text not null unique,
  caption       text,
  content_type  text not null,
  byte_size     bigint not null,
  created_at    timestamptz not null default now(),

  constraint item_photos_content_type check (content_type in ('image/jpeg', 'image/png', 'image/webp')),
  constraint item_photos_byte_size    check (byte_size > 0 and byte_size <= 10485760),
  constraint item_photos_caption_len  check (caption is null or char_length(caption) <= 500),

  -- Composite FK: inspection_id cannot disagree with the parent item's (D8).
  constraint item_photos_item_fk foreign key (item_id, inspection_id)
    references public.inspection_items (id, inspection_id) on delete cascade
);

-- ---------------------------------------------------------------- indexes

create index inspections_inspector_created_idx on public.inspections (inspector_id, created_at desc);
create index inspections_draft_idx             on public.inspections (inspector_id) where status = 'draft';
create index inspections_submitted_idx         on public.inspections (submitted_at desc) where status = 'submitted';
create index inspections_search_idx            on public.inspections using gin (search_tsv);

create index inspection_items_inspection_order_idx on public.inspection_items (inspection_id, sort_order);

create index item_photos_item_idx       on public.item_photos (item_id);
create index item_photos_inspection_idx on public.item_photos (inspection_id);
