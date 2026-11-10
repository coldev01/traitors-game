-- Traitors backend. Paste into the Supabase SQL editor (re-runnable).
-- First run only: enable pg_cron under Database > Extensions, then run the seed at the bottom.

create table if not exists app_config (key text primary key, value text not null);
create table if not exists admins (email text primary key);

create table if not exists games (
  id uuid primary key default gen_random_uuid(),
  status text not null default 'lobby' check (status in ('lobby', 'active', 'finished')),
  winner text check (winner in ('faithful', 'traitors')),
  tz text not null default 'Europe/London',
  mission jsonb,
  created_at timestamptz not null default now()
);

create table if not exists players (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references games on delete cascade,
  user_id uuid not null references auth.users,
  email text not null,
  display_name text not null,
  avatar_key text,
  alive boolean not null default true,
  unique (game_id, user_id)
);

create table if not exists roles (
  player_id uuid primary key references players on delete cascade,
  game_id uuid not null references games on delete cascade,
  role text not null check (role in ('faithful', 'traitor'))
);

create table if not exists events (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references games on delete cascade,
  kind text not null check (kind in ('banishment', 'murder')),
  opens_at timestamptz not null,
  closes_at timestamptz not null,
  reveals_at timestamptz not null,
  status text not null default 'scheduled' check (status in ('scheduled', 'open', 'closed', 'revealed')),
  unique (game_id, kind, opens_at)
);

-- Separate from events so a murder victim stays hidden until the event is revealed.
create table if not exists event_results (
  event_id uuid primary key references events on delete cascade,
  game_id uuid not null references games on delete cascade,
  target_id uuid references players
);

create table if not exists actions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events on delete cascade,
  player_id uuid not null references players on delete cascade,
  target_id uuid references players,
  created_at timestamptz not null default now(),
  unique (event_id, player_id)
);

create table if not exists messages (
  id bigint generated always as identity primary key,
  game_id uuid not null references games on delete cascade,
  channel text not null default 'traitors' check (channel in ('traitors')),
  player_id uuid not null references players,
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default clock_timestamp()
);

-- Registered accounts, independent of any one game; the GM picks who plays each game.
create table if not exists people (
  user_id uuid primary key references auth.users on delete cascade,
  email text not null unique,
  display_name text not null,
  avatar_key text,
  created_at timestamptz not null default now()
);
alter table people enable row level security;

-- Recruitment: a murder window can end in a recruit offer instead of a kill. accepted stays null until
-- the target answers; null at reveal counts as a refusal.
alter table actions add column if not exists kind text not null default 'kill' check (kind in ('kill', 'recruit'));
alter table event_results add column if not exists kind text not null default 'kill' check (kind in ('kill', 'recruit'));
alter table event_results add column if not exists accepted boolean;
alter table events add column if not exists reminded boolean not null default false;

alter table app_config enable row level security;
alter table admins enable row level security;
alter table games enable row level security;
alter table players enable row level security;
alter table roles enable row level security;
alter table events enable row level security;
alter table event_results enable row level security;
alter table actions enable row level security;
alter table messages enable row level security;

create or replace function is_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where email = lower(auth.jwt() ->> 'email'))
$$;

create or replace function my_player(p_game uuid) returns uuid language sql stable security definer set search_path = public as $$
  select id from players where game_id = p_game and user_id = auth.uid()
$$;

create or replace function in_game(p_game uuid) returns boolean language sql stable security definer set search_path = public as $$
  select my_player(p_game) is not null
$$;

create or replace function is_traitor(p_game uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from roles r where r.player_id = my_player(p_game) and r.role = 'traitor')
$$;

-- No insert/update/delete policies anywhere: all writes go through security-definer functions.
-- app_config, admins and actions have no select policy either, so clients can never read them.
drop policy if exists games_select on games;
create policy games_select on games for select to authenticated using (true);
drop policy if exists players_select on players;
create policy players_select on players for select to authenticated using (in_game(game_id));
drop policy if exists events_select on events;
create policy events_select on events for select to authenticated using (in_game(game_id));

drop policy if exists roles_select on roles;
create policy roles_select on roles for select to authenticated using (
  in_game(game_id) and (
    player_id = my_player(game_id)
    or (is_traitor(game_id) and role = 'traitor')
    or exists (select 1 from players p where p.id = roles.player_id and not p.alive)
    or exists (select 1 from games g where g.id = roles.game_id and g.status = 'finished')
  )
);

drop policy if exists results_select on event_results;
create policy results_select on event_results for select to authenticated using (
  in_game(game_id)
  and exists (select 1 from events e where e.id = event_id and e.status = 'revealed')
  and (kind = 'kill' or is_traitor(game_id))
);

drop policy if exists messages_select on messages;
create policy messages_select on messages for select to authenticated using (is_traitor(game_id));

create or replace function am_admin() returns boolean language sql stable as $$ select is_admin() $$;

-- Offsets are minutes from Monday 00:00 local time. Murder 1 closes Wed 24:00 (= Thu 00:00);
-- murder 2 spans the weekend and closes Mon 24:00 (= Tue 00:00 next week).
create or replace function default_schedule() returns jsonb language sql immutable as $$
  select jsonb_build_array(
    jsonb_build_object('kind', 'banishment', 'open', 0 * 1440 + 9 * 60, 'close', 1 * 1440 + 15 * 60, 'reveal', 1 * 1440 + 15 * 60),
    jsonb_build_object('kind', 'murder',     'open', 1 * 1440 + 15 * 60, 'close', 3 * 1440,           'reveal', 3 * 1440 + 9 * 60),
    jsonb_build_object('kind', 'banishment', 'open', 2 * 1440 + 9 * 60,  'close', 3 * 1440 + 15 * 60, 'reveal', 3 * 1440 + 15 * 60),
    jsonb_build_object('kind', 'murder',     'open', 3 * 1440 + 15 * 60, 'close', 8 * 1440,           'reveal', 8 * 1440 + 9 * 60))
$$;

create or replace function create_game() returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  insert into games default values returning id into v;
  return v;
end $$;

create or replace function internal_start_game(
  p_game uuid, p_anchor timestamp default null, p_schedule jsonb default null,
  p_weeks int default 12, p_period int default 10080
) returns void language plpgsql security definer set search_path = public as $$
declare g games; n int; k int; v_anchor timestamp;
begin
  select * into g from games where id = p_game for update;
  if g.id is null or g.status <> 'lobby' then raise exception 'game not startable'; end if;
  select count(*) into n from players where game_id = p_game;
  if n < 6 then raise exception 'need at least 6 players'; end if;

  k := greatest(2, round(n / 4.0));
  insert into roles (player_id, game_id, role)
  select id, p_game, case when rn <= k then 'traitor' else 'faithful' end
  from (select id, row_number() over (order by random()) rn from players where game_id = p_game) s;

  v_anchor := coalesce(p_anchor, date_trunc('week', now() at time zone g.tz) + interval '7 days');
  -- ponytail: events are pre-generated for p_weeks (12); a game longer than that needs a top-up function.
  insert into events (game_id, kind, opens_at, closes_at, reveals_at)
  select p_game, s ->> 'kind',
    (v_anchor + make_interval(mins => w * p_period + (s ->> 'open')::int)) at time zone g.tz,
    (v_anchor + make_interval(mins => w * p_period + (s ->> 'close')::int)) at time zone g.tz,
    (v_anchor + make_interval(mins => w * p_period + (s ->> 'reveal')::int)) at time zone g.tz
  from generate_series(0, p_weeks - 1) w, jsonb_array_elements(coalesce(p_schedule, default_schedule())) s;

  update games set status = 'active' where id = p_game;
end $$;

create or replace function start_game(
  p_game uuid, p_anchor timestamp default null, p_schedule jsonb default null,
  p_weeks int default 12, p_period int default 10080
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  perform internal_start_game(p_game, p_anchor, p_schedule, p_weeks, p_period);
end $$;

create or replace function cast_vote(p_event uuid, p_target uuid) returns void language plpgsql security definer set search_path = public as $$
declare ev events; me uuid;
begin
  select * into ev from events where id = p_event;
  if ev.id is null or ev.kind <> 'banishment' or ev.status <> 'open' or now() >= ev.closes_at then
    raise exception 'event not open';
  end if;
  me := my_player(ev.game_id);
  if me is null or not (select alive from players where id = me) then raise exception 'not allowed'; end if;
  if p_target is not null and (p_target = me or not exists (
    select 1 from players where id = p_target and game_id = ev.game_id and alive)) then
    raise exception 'invalid target';
  end if;
  insert into actions (event_id, player_id, target_id) values (p_event, me, p_target)
  on conflict (event_id, player_id) do update set target_id = excluded.target_id, created_at = now();
end $$;

create or replace function pick_victim(p_event uuid, p_target uuid) returns void language plpgsql security definer set search_path = public as $$
declare ev events; me uuid;
begin
  select * into ev from events where id = p_event;
  if ev.id is null or ev.kind <> 'murder' or ev.status <> 'open' or now() >= ev.closes_at then
    raise exception 'event not open';
  end if;
  me := my_player(ev.game_id);
  if me is null or not is_traitor(ev.game_id) or not (select alive from players where id = me) then
    raise exception 'not allowed';
  end if;
  if p_target is not null and not exists (
    select 1 from players p join roles r on r.player_id = p.id
    where p.id = p_target and p.game_id = ev.game_id and p.alive and r.role = 'faithful') then
    raise exception 'invalid target';
  end if;
  insert into actions (event_id, player_id, target_id, kind) values (p_event, me, p_target, 'kill')
  on conflict (event_id, player_id) do update set target_id = excluded.target_id, kind = 'kill', created_at = now();
end $$;

create or replace function pick_recruit(p_event uuid, p_target uuid) returns void language plpgsql security definer set search_path = public as $$
declare ev events; me uuid;
begin
  select * into ev from events where id = p_event;
  if ev.id is null or ev.kind <> 'murder' or ev.status <> 'open' or now() >= ev.closes_at then
    raise exception 'event not open';
  end if;
  me := my_player(ev.game_id);
  if me is null or not is_traitor(ev.game_id) or not (select alive from players where id = me) then
    raise exception 'not allowed';
  end if;
  if (select count(*) from players p join roles r on r.player_id = p.id
      where p.game_id = ev.game_id and p.alive and r.role = 'traitor') > 2 then
    raise exception 'recruitment not available';
  end if;
  if not exists (
    select 1 from players p join roles r on r.player_id = p.id
    where p.id = p_target and p.game_id = ev.game_id and p.alive and r.role = 'faithful') then
    raise exception 'invalid target';
  end if;
  insert into actions (event_id, player_id, target_id, kind) values (p_event, me, p_target, 'recruit')
  on conflict (event_id, player_id) do update set target_id = excluded.target_id, kind = 'recruit', created_at = now();
end $$;

create or replace function post_message(p_game uuid, p_body text) returns void language plpgsql security definer set search_path = public as $$
declare me uuid := my_player(p_game);
begin
  if me is null or not is_traitor(p_game) or not (select alive from players where id = me)
     or (select status from games where id = p_game) <> 'active' then
    raise exception 'not allowed';
  end if;
  if exists (select 1 from messages where player_id = me and created_at > clock_timestamp() - interval '2 seconds') then
    raise exception 'slow down';
  end if;
  insert into messages (game_id, player_id, body) values (p_game, me, left(trim(p_body), 500));
end $$;

create or replace function my_pick(p_event uuid) returns table (kind text, target_id uuid) language sql stable security definer set search_path = public as $$
  select a.kind, a.target_id from actions a join players p on p.id = a.player_id
  where a.event_id = p_event and p.user_id = auth.uid()
$$;

create or replace function team_picks(p_event uuid) returns table (player_id uuid, kind text, target_id uuid) language sql stable security definer set search_path = public as $$
  select a.player_id, a.kind, a.target_id from actions a join events e on e.id = a.event_id
  where a.event_id = p_event and e.kind = 'murder' and is_traitor(e.game_id)
$$;

-- The recruit offer is private to its target and open from the window closing until the reveal.
create or replace function my_offer(p_game uuid) returns uuid language sql stable security definer set search_path = public as $$
  select r.event_id from event_results r
  join events e on e.id = r.event_id
  join players p on p.id = r.target_id
  where r.game_id = p_game and r.kind = 'recruit' and r.accepted is null
    and e.status = 'closed' and p.alive and p.user_id = auth.uid()
  limit 1
$$;

create or replace function respond_recruit(p_event uuid, p_accept boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  update event_results r set accepted = p_accept
  from events e, players p
  where r.event_id = p_event and e.id = r.event_id and p.id = r.target_id
    and r.kind = 'recruit' and r.accepted is null and e.status = 'closed' and p.alive and p.user_id = auth.uid();
  if not found then raise exception 'no offer'; end if;
end $$;

create or replace function check_win(p_game uuid) returns void language plpgsql security definer set search_path = public as $$
declare t int; f int;
begin
  select count(*) filter (where r.role = 'traitor'), count(*) filter (where r.role = 'faithful')
  into t, f from players p join roles r on r.player_id = p.id
  where p.game_id = p_game and p.alive;
  if t = 0 then
    update games set status = 'finished', winner = 'faithful' where id = p_game;
  elsif t >= f then
    update games set status = 'finished', winner = 'traitors' where id = p_game;
  end if;
end $$;

-- Dead voters and dead targets are filtered here, not at cast time, because a murder is only
-- applied at its reveal: a vote cast before then must be discarded once the voter is dead.
create or replace function close_event(p_event uuid) returns void language plpgsql security definer set search_path = public as $$
declare ev events; v_target uuid; v_kind text;
begin
  select * into ev from events where id = p_event for update;
  select a.target_id, a.kind into v_target, v_kind
  from actions a
  join players voter on voter.id = a.player_id and voter.alive
  join players t on t.id = a.target_id and t.alive
  where a.event_id = p_event and a.target_id is not null
  group by a.kind, a.target_id
  order by count(*) desc, random()
  limit 1;
  -- Traitors may have grown back past the limit since they picked (a recruit already landed), so re-check.
  if v_kind = 'recruit' and (select count(*) from players p join roles r on r.player_id = p.id
                             where p.game_id = ev.game_id and p.alive and r.role = 'traitor') > 2 then
    v_target := null;
  end if;
  insert into event_results (event_id, game_id, target_id, kind)
  values (p_event, ev.game_id, v_target, case when v_target is null then 'kill' else coalesce(v_kind, 'kill') end);
  update events set status = 'closed' where id = p_event;
end $$;

create extension if not exists pg_net;

-- Posts to the Slack webhook the GM saved. Does nothing until one is set. Only hooks.slack.com URLs are
-- ever called (the database makes the request, so an arbitrary URL would be a server-side request hole).
create or replace function slack_post(p_text text) returns void language plpgsql security definer set search_path = public as $$
declare v_url text := (select value from app_config where key = 'slack_webhook');
begin
  if v_url is null or v_url not like 'https://hooks.slack.com/%' then return; end if;
  -- A failed or unreachable Slack must never stop a round from resolving.
  begin
    perform net.http_post(url := v_url,
                          -- Names are player-chosen, so neutralise Slack markup like <!channel>.
                          body := jsonb_build_object('text', replace(replace(replace(p_text, '&', '&amp;'), '<', '&lt;'), '>', '&gt;')),
                          headers := '{"Content-Type": "application/json"}'::jsonb);
  exception when others then null;
  end;
end $$;

create or replace function reveal_event(p_event uuid) returns void language plpgsql security definer set search_path = public as $$
declare ev events; v_target uuid; v_kind text; v_accepted boolean; v_name text; v_role text; g games;
begin
  select * into ev from events where id = p_event for update;
  select target_id, kind, accepted into v_target, v_kind, v_accepted from event_results where event_id = p_event;
  if v_target is not null then
    if v_kind = 'kill' then
      update players set alive = false where id = v_target;
    elsif v_accepted is true then
      -- A target banished between the offer and the reveal can't be recruited.
      update roles set role = 'traitor' where player_id = v_target and exists (select 1 from players where id = v_target and alive);
    end if;
  end if;
  update events set status = 'revealed' where id = p_event;

  -- A recruit round is announced as a quiet one so the faithful can't tell it apart.
  if v_target is not null and v_kind = 'kill' then
    select p.display_name, r.role into v_name, v_role from players p join roles r on r.player_id = p.id where p.id = v_target;
    perform slack_post(format('%s was %s. They were %s.', v_name,
      case ev.kind when 'banishment' then 'banished' else 'murdered' end,
      case v_role when 'traitor' then 'a traitor' else 'faithful' end));
  else
    perform slack_post(format('Nobody was %s.', case ev.kind when 'banishment' then 'banished' else 'murdered' end));
  end if;

  perform check_win(ev.game_id);
  select * into g from games where id = ev.game_id;
  if g.status = 'finished' then
    perform slack_post(case g.winner when 'faithful' then 'The game is over. The Faithful win!' else 'The game is over. The Traitors win!' end);
  end if;
end $$;

create or replace function advance_games(p_now timestamptz default now()) returns void language plpgsql security definer set search_path = public as $$
declare e events; tz text;
begin
  for e in select ev.* from events ev join games g on g.id = ev.game_id
           where g.status = 'active' and ev.status = 'scheduled' and ev.opens_at <= p_now
           order by ev.opens_at loop
    update events set status = 'open' where id = e.id;
    -- Murder windows are the traitors' business, so only banishment votes are announced.
    if e.kind = 'banishment' then
      select g.tz into tz from games g where g.id = e.game_id;
      perform slack_post(format('The banishment vote is open. It closes %s. Not voting counts as abstaining.',
                                to_char(e.closes_at at time zone tz, 'FMDay "at" HH24:MI')));
    end if;
  end loop;

  for e in select ev.* from events ev join games g on g.id = ev.game_id
           where g.status = 'active' and ev.status = 'open' and ev.kind = 'banishment' and not ev.reminded
             and ev.closes_at - interval '3 hours' <= p_now and ev.closes_at > p_now
           order by ev.closes_at loop
    update events set reminded = true where id = e.id;
    select g.tz into tz from games g where g.id = e.game_id;
    perform slack_post(format('Reminder: the banishment vote closes %s. If you have not voted yet, now is the time.',
                              to_char(e.closes_at at time zone tz, 'FMDay "at" HH24:MI')));
  end loop;

  for e in select ev.* from events ev join games g on g.id = ev.game_id
           where g.status = 'active' and ev.status = 'open' and ev.closes_at <= p_now
           order by ev.closes_at loop
    perform close_event(e.id);
  end loop;

  -- Re-checks game status per event: a win mid-catch-up must stop later reveals.
  for e in select ev.* from events ev join games g on g.id = ev.game_id
           where g.status = 'active' and ev.status = 'closed' and ev.reveals_at <= p_now
           order by ev.reveals_at loop
    if (select status from games where id = e.game_id) = 'active' then
      perform reveal_event(e.id);
    end if;
  end loop;
end $$;

create extension if not exists pg_cron;
select cron.schedule('advance-games', '* * * * *', $$select public.advance_games()$$);

create or replace function gm_force_close(p_event uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  update events
  set closes_at = least(closes_at, now()),
      reveals_at = case when kind = 'banishment' then least(reveals_at, now()) else reveals_at end
  where id = p_event;
  perform advance_games();
end $$;

create or replace function gm_extend_event(p_event uuid, p_by interval) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  update events set closes_at = closes_at + p_by, reveals_at = reveals_at + p_by
  where id = p_event and status in ('scheduled', 'open');
end $$;

-- Retention: spec says player data is deleted after a game ends.
create or replace function gm_delete_game(p_game uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  delete from games where id = p_game;
end $$;

revoke execute on function
  advance_games(timestamptz), close_event(uuid), reveal_event(uuid), check_win(uuid),
  internal_start_game(uuid, timestamp, jsonb, int, int)
  from public, anon, authenticated;

revoke execute on function
  am_admin(), default_schedule(), create_game(),
  start_game(uuid, timestamp, jsonb, int, int), cast_vote(uuid, uuid), pick_victim(uuid, uuid),
  post_message(uuid, text), pick_recruit(uuid, uuid), my_pick(uuid), team_picks(uuid), my_offer(uuid), respond_recruit(uuid, boolean),
  gm_force_close(uuid), gm_extend_event(uuid, interval), gm_delete_game(uuid),
  is_admin(), my_player(uuid), in_game(uuid), is_traitor(uuid)
  from public, anon;

-- Explicit grant: don't rely on Supabase default privileges once PUBLIC is revoked.
grant execute on function
  am_admin(), default_schedule(), create_game(),
  start_game(uuid, timestamp, jsonb, int, int), cast_vote(uuid, uuid), pick_victim(uuid, uuid),
  post_message(uuid, text), pick_recruit(uuid, uuid), my_pick(uuid), team_picks(uuid), my_offer(uuid), respond_recruit(uuid, boolean),
  gm_force_close(uuid), gm_extend_event(uuid, interval), gm_delete_game(uuid),
  is_admin(), my_player(uuid), in_game(uuid), is_traitor(uuid)
  to authenticated;

-- The GM isn't a player, so RLS hides players/events from them; this is their only window in.
create or replace function gm_overview(p_game uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return jsonb_build_object(
    'players', (select count(*) from players where game_id = p_game),
    'signup_code', (select value from app_config where key = 'signup_code'),
    'slack_on', exists (select 1 from app_config where key = 'slack_webhook'),
    'people', coalesce((select jsonb_agg(jsonb_build_object(
                'user_id', p.user_id, 'name', p.display_name, 'email', p.email,
                'in_game', exists (select 1 from players g where g.game_id = p_game and g.user_id = p.user_id))
                order by p.display_name) from people p), '[]'),
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.opens_at)
                        from (select * from events where game_id = p_game and status <> 'revealed'
                              order by opens_at limit 8) e), '[]'));
end $$;

create or replace function gm_set_player(p_game uuid, p_user uuid, p_in boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if (select status from games where id = p_game) is distinct from 'lobby' then raise exception 'game not in lobby'; end if;
  if p_in then
    if (select count(*) from players where game_id = p_game) >= 15 then raise exception 'game full'; end if;
    insert into players (game_id, user_id, email, display_name, avatar_key)
    select p_game, user_id, email, display_name, avatar_key from people where user_id = p_user
    on conflict (game_id, user_id) do nothing;
  else
    delete from players where game_id = p_game and user_id = p_user;
  end if;
end $$;

create or replace function gm_set_slack(p_url text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if coalesce(p_url, '') = '' then
    delete from app_config where key = 'slack_webhook';
  elsif p_url not like 'https://hooks.slack.com/%' then
    raise exception 'That is not a Slack webhook URL';
  else
    insert into app_config (key, value) values ('slack_webhook', p_url)
    on conflict (key) do update set value = excluded.value;
  end if;
end $$;

create or replace function gm_slack_test() returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if not exists (select 1 from app_config where key = 'slack_webhook') then raise exception 'No Slack webhook is set'; end if;
  perform slack_post('Test message from Traitors. If you can read this, announcements are working.');
end $$;

revoke execute on function slack_post(text) from public, anon, authenticated;
revoke execute on function gm_set_slack(text), gm_slack_test() from public, anon;
grant execute on function gm_set_slack(text), gm_slack_test() to authenticated;

revoke execute on function gm_overview(uuid), gm_set_player(uuid, uuid, boolean) from public, anon;
grant execute on function gm_overview(uuid), gm_set_player(uuid, uuid, boolean) to authenticated;

-- join_game is gone: the GM selects players, nobody self-joins.
drop function if exists join_game(uuid);
drop function if exists my_action(uuid);
drop function if exists traitor_picks(uuid);

-- Seed (edit, run once):
-- insert into app_config values ('org_domain', 'yourorg.com'), ('signup_code', 'pick-a-long-random-code');
-- insert into admins values ('gm@yourorg.com');
