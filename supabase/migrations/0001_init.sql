-- Online Game Board — initial schema
-- Design notes:
--   * owner_token / player_token live in separate "*_secrets" tables with NO
--     anon-facing policies. rooms/players never carry secrets, so it is safe
--     to expose them to public SELECT and to Supabase Realtime broadcast.
--   * All writes go through SECURITY DEFINER RPC functions that verify the
--     caller's token against the secrets tables. No direct table INSERT/
--     UPDATE/DELETE is granted to anon.
--   * Piece position (x, y) is stored as percentage (0..100) of the map
--     image's natural size, so it is resolution-independent across clients.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  background_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.room_secrets (
  room_id uuid primary key references public.rooms (id) on delete cascade,
  owner_token uuid not null default gen_random_uuid()
);

create table public.players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  name text not null,
  avatar_url text,
  x numeric not null default 50 check (x >= 0 and x <= 100),
  y numeric not null default 50 check (y >= 0 and y <= 100),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.player_secrets (
  player_id uuid primary key references public.players (id) on delete cascade,
  player_token uuid not null default gen_random_uuid()
);

create index players_room_id_idx on public.players (room_id);

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table public.rooms enable row level security;
alter table public.players enable row level security;
alter table public.room_secrets enable row level security;
alter table public.player_secrets enable row level security;

-- rooms/players hold no secrets: safe to read publicly (and thus over Realtime).
create policy "rooms are publicly readable" on public.rooms
  for select to anon, authenticated using (true);

create policy "players are publicly readable" on public.players
  for select to anon, authenticated using (true);

-- room_secrets / player_secrets: intentionally NO policies for anon/authenticated.
-- RLS is enabled with zero matching policies => default deny for those roles.
-- Only SECURITY DEFINER functions below (running as table owner) can read/write them.

-- No direct INSERT/UPDATE/DELETE policies on rooms/players either: all writes
-- happen through the RPC functions below.

-- ---------------------------------------------------------------------------
-- RPC functions
-- ---------------------------------------------------------------------------

create or replace function public.create_room()
returns table (room_id uuid, owner_token uuid)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room_id uuid;
  v_owner_token uuid;
begin
  insert into public.rooms default values returning id into v_room_id;
  insert into public.room_secrets (room_id, owner_token)
    values (v_room_id, gen_random_uuid())
    returning room_secrets.owner_token into v_owner_token;

  return query select v_room_id, v_owner_token;
end;
$$;

create or replace function public.verify_owner(p_room_id uuid, p_owner_token uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.room_secrets
    where room_id = p_room_id and owner_token = p_owner_token
  );
$$;

create or replace function public.update_room_map(
  p_room_id uuid,
  p_owner_token uuid,
  p_background_url text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.verify_owner(p_room_id, p_owner_token) then
    raise exception 'forbidden';
  end if;

  update public.rooms
    set background_url = p_background_url, updated_at = now()
    where id = p_room_id;
end;
$$;

create or replace function public.create_player(
  p_room_id uuid,
  p_owner_token uuid,
  p_name text,
  p_avatar_url text default null
)
returns table (player_id uuid, player_token uuid)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_player_id uuid;
  v_player_token uuid;
begin
  if not public.verify_owner(p_room_id, p_owner_token) then
    raise exception 'forbidden';
  end if;

  insert into public.players (room_id, name, avatar_url, x, y)
    values (p_room_id, p_name, p_avatar_url, 50, 50)
    returning id into v_player_id;

  insert into public.player_secrets (player_id, player_token)
    values (v_player_id, gen_random_uuid())
    returning player_secrets.player_token into v_player_token;

  return query select v_player_id, v_player_token;
end;
$$;

create or replace function public.edit_player(
  p_player_id uuid,
  p_owner_token uuid,
  p_name text default null,
  p_avatar_url text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room_id uuid;
begin
  select room_id into v_room_id from public.players where id = p_player_id;
  if v_room_id is null then
    raise exception 'not_found';
  end if;
  if not public.verify_owner(v_room_id, p_owner_token) then
    raise exception 'forbidden';
  end if;

  update public.players
    set name = coalesce(p_name, name),
        avatar_url = coalesce(p_avatar_url, avatar_url),
        updated_at = now()
    where id = p_player_id;
end;
$$;

create or replace function public.delete_player(
  p_player_id uuid,
  p_owner_token uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room_id uuid;
begin
  select room_id into v_room_id from public.players where id = p_player_id;
  if v_room_id is null then
    raise exception 'not_found';
  end if;
  if not public.verify_owner(v_room_id, p_owner_token) then
    raise exception 'forbidden';
  end if;

  delete from public.players where id = p_player_id;
end;
$$;

create or replace function public.get_player_id_for_token(
  p_room_id uuid,
  p_player_token uuid
)
returns uuid
language sql
security definer
set search_path = public, pg_temp
as $$
  select p.id
  from public.players p
  join public.player_secrets s on s.player_id = p.id
  where p.room_id = p_room_id and s.player_token = p_player_token;
$$;

create or replace function public.move_token(
  p_player_id uuid,
  p_x numeric,
  p_y numeric,
  p_owner_token uuid default null,
  p_player_token uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room_id uuid;
  v_authorized boolean := false;
begin
  select room_id into v_room_id from public.players where id = p_player_id;
  if v_room_id is null then
    raise exception 'not_found';
  end if;

  if p_owner_token is not null and public.verify_owner(v_room_id, p_owner_token) then
    v_authorized := true;
  elsif p_player_token is not null and exists (
    select 1 from public.player_secrets
    where player_id = p_player_id and player_token = p_player_token
  ) then
    v_authorized := true;
  end if;

  if not v_authorized then
    raise exception 'forbidden';
  end if;

  update public.players
    set x = greatest(0, least(100, p_x)),
        y = greatest(0, least(100, p_y)),
        updated_at = now()
    where id = p_player_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

revoke all on public.rooms, public.players, public.room_secrets, public.player_secrets
  from anon, authenticated;
grant select on public.rooms, public.players to anon, authenticated;

grant execute on function
  public.create_room(),
  public.verify_owner(uuid, uuid),
  public.update_room_map(uuid, uuid, text),
  public.create_player(uuid, uuid, text, text),
  public.edit_player(uuid, uuid, text, text),
  public.delete_player(uuid, uuid),
  public.get_player_id_for_token(uuid, uuid),
  public.move_token(uuid, numeric, numeric, uuid, uuid)
to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------

alter publication supabase_realtime add table public.rooms;
alter publication supabase_realtime add table public.players;

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('maps', 'maps', true, 8388608, array['image/png','image/jpeg','image/webp','image/gif']),
  ('avatars', 'avatars', true, 2097152, array['image/png','image/jpeg','image/webp','image/gif'])
on conflict (id) do nothing;

create policy "anon can upload maps" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'maps');

create policy "anon can upload avatars" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'avatars');
