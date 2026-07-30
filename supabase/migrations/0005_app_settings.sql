-- Global, manually-edited settings (via Table Editor / SQL Editor, not the
-- app UI). Singleton table: the check constraint pins it to a single row
-- with id = 1, so there's never ambiguity about "which settings row".
create table public.app_settings (
  id smallint primary key default 1,
  disable_room_creation boolean not null default false,
  updated_at timestamptz not null default now(),
  constraint app_settings_singleton check (id = 1)
);

insert into public.app_settings (id) values (1);

-- Not a secret, and the frontend needs to read it (to grey out "Create
-- room" and explain why) — public read is fine. No write policies: this
-- table is only ever edited by hand with elevated (dashboard) access,
-- never through the anon-facing API.
alter table public.app_settings enable row level security;

create policy "app_settings are publicly readable" on public.app_settings
  for select to anon, authenticated using (true);

-- Enforce the flag server-side (not just a client-side UI hint) — anyone
-- calling create_room() directly, bypassing the UI, must still be blocked.
create or replace function public.create_room()
returns table (room_id uuid, owner_token uuid)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room_id uuid;
  v_owner_token uuid;
  v_disabled boolean;
begin
  select disable_room_creation into v_disabled from public.app_settings where id = 1;
  if coalesce(v_disabled, false) then
    raise exception 'room_creation_disabled';
  end if;

  insert into public.rooms default values returning id into v_room_id;
  insert into public.room_secrets (room_id, owner_token)
    values (v_room_id, gen_random_uuid())
    returning room_secrets.owner_token into v_owner_token;

  return query select v_room_id, v_owner_token;
end;
$$;
