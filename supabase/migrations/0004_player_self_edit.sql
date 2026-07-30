-- Owner-controlled flag letting players edit their own name/avatar.
-- allow_player_edit is not a secret (like background_url), so it's covered
-- by the existing public SELECT policy on rooms — no RLS change needed.
alter table public.rooms add column allow_player_edit boolean not null default false;

create or replace function public.set_player_edit_allowed(
  p_room_id uuid,
  p_owner_token uuid,
  p_allowed boolean
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
    set allow_player_edit = p_allowed, updated_at = now()
    where id = p_room_id;
end;
$$;

grant execute on function public.set_player_edit_allowed(uuid, uuid, boolean) to anon, authenticated;

-- edit_player gains a dual-auth path (same pattern as move_token): the
-- owner can always edit any player; a player can now also edit their own
-- row via player_token, but only while the room's allow_player_edit flag
-- is on. Signature changes (new trailing param), so the old 4-arg version
-- is dropped first instead of relying on CREATE OR REPLACE, which would
-- otherwise leave both overloads registered side by side.
drop function if exists public.edit_player(uuid, uuid, text, text);

create or replace function public.edit_player(
  p_player_id uuid,
  p_name text default null,
  p_avatar_url text default null,
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
  elsif p_player_token is not null
    and exists (
      select 1 from public.player_secrets
      where player_id = p_player_id and player_token = p_player_token
    )
    and exists (
      select 1 from public.rooms where id = v_room_id and allow_player_edit
    )
  then
    v_authorized := true;
  end if;

  if not v_authorized then
    raise exception 'forbidden';
  end if;

  update public.players
    set name = coalesce(p_name, name),
        avatar_url = coalesce(p_avatar_url, avatar_url),
        updated_at = now()
    where id = p_player_id;
end;
$$;

grant execute on function public.edit_player(uuid, text, text, uuid, uuid) to anon, authenticated;
