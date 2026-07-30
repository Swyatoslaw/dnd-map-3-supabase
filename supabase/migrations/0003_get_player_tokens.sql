-- Owner needs player_token values to build/copy invite links, but
-- player_secrets has no anon-facing policies (by design — see 0001). Add a
-- SECURITY DEFINER RPC that returns all player tokens for a room, gated by
-- the same owner_token check used everywhere else.
create or replace function public.get_player_tokens(
  p_room_id uuid,
  p_owner_token uuid
)
returns table (player_id uuid, player_token uuid)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.verify_owner(p_room_id, p_owner_token) then
    raise exception 'forbidden';
  end if;

  return query
  select s.player_id, s.player_token
  from public.player_secrets s
  join public.players p on p.id = s.player_id
  where p.room_id = p_room_id;
end;
$$;

grant execute on function public.get_player_tokens(uuid, uuid) to anon, authenticated;
