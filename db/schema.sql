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

-- Team photos people can choose from (files live in avatars/<key>.webp). Add a row and a file to add a photo.
-- Each photo can belong to only one person.
-- Who the GM has chosen to be traitors, before the game starts. Kept apart from players (which every member can
-- read) and with no policies at all, so nobody but the GM's functions can see it.
create table if not exists designated_traitors (
  game_id uuid not null references games on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  primary key (game_id, user_id)
);
alter table designated_traitors enable row level security;

create table if not exists photos (key text primary key);
alter table photos enable row level security;
insert into photos (key) select 'team-' || lpad(n::text, 2, '0') from generate_series(1, 21) n on conflict do nothing;
create unique index if not exists people_avatar_key_key on people (avatar_key) where avatar_key is not null;

-- Recruitment: a murder window can end in a recruit offer instead of a kill. accepted stays null until
-- the target answers; null at reveal counts as a refusal.
alter table actions add column if not exists kind text not null default 'kill' check (kind in ('kill', 'recruit'));
alter table event_results add column if not exists kind text not null default 'kill' check (kind in ('kill', 'recruit'));
alter table event_results add column if not exists accepted boolean;
alter table events add column if not exists reminded boolean not null default false;
-- The public who-voted-for-whom text, saved at the reveal so the app and Slack show exactly the same thing.
-- It is only readable once the event is revealed, through the same policy as the result itself.
alter table event_results add column if not exists votes text;
-- The GM can speak in the traitors chat. Their messages have no player, so player_id must be nullable;
-- only post_message (player) and gm_post_message (GM) write here, so the pairing is enforced in those.
alter table messages alter column player_id drop not null;
alter table messages add column if not exists from_gm boolean not null default false;

-- End game. phase: 'normal', then 'final' (the last banishment, and any later one) and 'endgame' (the vote to stop).
-- Final-phase events have no clock (untimed): they close when everyone alive has answered, so closes_at/reveals_at
-- are parked far in the future. role_public is false for players banished with 6 or fewer alive, so their role
-- stays secret until the game ends.
alter table games add column if not exists phase text not null default 'normal' check (phase in ('normal', 'final', 'endgame'));
alter table events add column if not exists untimed boolean not null default false;
alter table players add column if not exists role_public boolean not null default true;
alter table actions add column if not exists end_vote boolean;
alter table events drop constraint if exists events_kind_check;
alter table events add constraint events_kind_check check (kind in ('banishment', 'murder', 'endgame'));

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
    or exists (select 1 from players p where p.id = roles.player_id and not p.alive and p.role_public)
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
  -- Everything opens/closes Mon-Thu 09:00, never Fri-Sun (the team is off alternate Fridays). Murder 2 spans the weekend.
  select jsonb_build_array(
    jsonb_build_object('kind', 'banishment', 'open', 540,  'close', 1980, 'reveal', 1980),
    jsonb_build_object('kind', 'murder',     'open', 1980, 'close', 3420, 'reveal', 3420),
    jsonb_build_object('kind', 'banishment', 'open', 3420, 'close', 4860, 'reveal', 4860),
    jsonb_build_object('kind', 'murder',     'open', 4860, 'close', 10620, 'reveal', 10620))
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

  -- The GM's chosen traitors win if there are any (only people actually in this game count); otherwise
  -- 2 or 3 are picked at random. Either way there must be fewer traitors than faithful, or the game is over at once.
  select count(*) into k from designated_traitors d join players p on p.user_id = d.user_id and p.game_id = d.game_id
  where d.game_id = p_game;
  if k > 0 then
    if k >= n - k then raise exception 'There must be fewer traitors than faithful'; end if;
    insert into roles (player_id, game_id, role)
    select p.id, p_game, case when exists (select 1 from designated_traitors d where d.game_id = p_game and d.user_id = p.user_id)
                              then 'traitor' else 'faithful' end
    from players p where p.game_id = p_game;
  else
    k := least(3, greatest(2, round(n / 6.0)));
    insert into roles (player_id, game_id, role)
    select id, p_game, case when rn <= k then 'traitor' else 'faithful' end
    from (select id, row_number() over (order by random()) rn from players where game_id = p_game) s;
  end if;

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

-- Untimed events close the moment everyone alive has answered. An answer is a chosen target (banishment) or an
-- end/keep-playing choice (end game).
create or replace function settle_untimed(p_event uuid) returns void language plpgsql security definer set search_path = public as $$
declare ev events;
begin
  select * into ev from events where id = p_event;
  if ev.id is null or not ev.untimed or ev.status <> 'open' then return; end if;
  if not exists (select 1 from players p where p.game_id = ev.game_id and p.alive and not exists (
        select 1 from actions a where a.event_id = p_event and a.player_id = p.id
          and (a.target_id is not null or a.end_vote is not null))) then
    update events set closes_at = now(), reveals_at = now() where id = p_event;
    perform advance_games();
  end if;
end $$;

-- The last banishment and any repeat: no clock, no murder, roles stay hidden. Anything still scheduled is dropped.
create or replace function open_final_banishment(p_game uuid) returns void language plpgsql security definer set search_path = public as $$
declare t timestamptz := clock_timestamp();
begin
  update games set phase = 'final' where id = p_game;
  delete from events where game_id = p_game and status = 'scheduled';
  insert into events (game_id, kind, opens_at, closes_at, reveals_at, status, untimed)
  values (p_game, 'banishment', t, t + interval '10 years', t + interval '10 years', 'open', true);
  perform slack_post('The final banishment vote is open. There is no deadline: it closes when everyone has voted. Roles are no longer revealed.');
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
  perform settle_untimed(p_event);
end $$;

create or replace function cast_endgame(p_event uuid, p_end boolean) returns void language plpgsql security definer set search_path = public as $$
declare ev events; me uuid;
begin
  select * into ev from events where id = p_event;
  if ev.id is null or ev.kind <> 'endgame' or ev.status <> 'open' then raise exception 'event not open'; end if;
  me := my_player(ev.game_id);
  if me is null or not (select alive from players where id = me) then raise exception 'not allowed'; end if;
  if p_end is null then raise exception 'choose end or keep playing'; end if;
  insert into actions (event_id, player_id, end_vote) values (p_event, me, p_end)
  on conflict (event_id, player_id) do update set end_vote = excluded.end_vote, created_at = now();
  perform settle_untimed(p_event);
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
  if ev.kind = 'endgame' then
    -- accepted means "everyone alive chose to end it"; no answer counts as keep playing.
    insert into event_results (event_id, game_id, target_id, kind, accepted)
    values (p_event, ev.game_id, null, 'kill', not exists (
      select 1 from players p where p.game_id = ev.game_id and p.alive
        and not exists (select 1 from actions a where a.event_id = p_event and a.player_id = p.id and a.end_vote is true)));
    update events set status = 'closed' where id = p_event;
    return;
  end if;
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

-- Who voted for whom, for the public announcement. Uses the same rules as close_event (living voters, living
-- targets) so it shows exactly the votes that counted, and returns null when nothing counted (no votes, or
-- the GM skipped the round) so nothing is announced. Must run before the result is applied: the banished
-- player is marked dead there, and their votes would otherwise drop out.
create or replace function vote_breakdown(p_event uuid) returns text language plpgsql stable security definer set search_path = public as $$
declare v_game uuid; v_lines text; v_top int; v_tied text; v_missing text;
begin
  select game_id into v_game from events where id = p_event;
  select string_agg(format('• %s: %s (%s)', tname, cnt, voters), E'\n' order by cnt desc, tname), max(cnt)
  into v_lines, v_top
  from (select t.display_name as tname, count(*) as cnt, string_agg(voter.display_name, ', ' order by voter.display_name) as voters
        from actions a
        join players voter on voter.id = a.player_id and voter.alive
        join players t on t.id = a.target_id and t.alive
        where a.event_id = p_event and a.target_id is not null
        group by t.id, t.display_name) x;
  if v_lines is null then return null; end if;

  select string_agg(tname, ' and ' order by tname) into v_tied
  from (select t.display_name as tname, count(*) as cnt
        from actions a
        join players voter on voter.id = a.player_id and voter.alive
        join players t on t.id = a.target_id and t.alive
        where a.event_id = p_event and a.target_id is not null
        group by t.id, t.display_name having count(*) = v_top) y;

  select string_agg(p.display_name, ', ' order by p.display_name) into v_missing from players p
  where p.game_id = v_game and p.alive
    and not exists (select 1 from actions a where a.event_id = p_event and a.player_id = p.id and a.target_id is not null);

  return 'Votes:' || E'\n' || v_lines
    || case when v_tied like '% and %' then E'\n' || format('Tie on %s vote%s between %s, decided at random.', v_top, case when v_top = 1 then '' else 's' end, v_tied) else '' end
    || case when v_missing is not null then E'\n' || 'Did not vote: ' || v_missing || '.' else '' end;
end $$;

create or replace function reveal_event(p_event uuid) returns void language plpgsql security definer set search_path = public as $$
declare ev events; v_target uuid; v_kind text; v_accepted boolean; v_name text; v_role text; g games; v_votes text;
        v_alive int; v_show_role boolean;
begin
  select * into ev from events where id = p_event for update;

  if ev.kind = 'endgame' then
    select accepted into v_accepted from event_results where event_id = p_event;
    update events set status = 'revealed' where id = p_event;
    if v_accepted then
      update games set status = 'finished', phase = 'endgame',
        winner = case when exists (select 1 from players p join roles r on r.player_id = p.id
                                   where p.game_id = ev.game_id and p.alive and r.role = 'traitor') then 'traitors' else 'faithful' end
      where id = ev.game_id;
      select * into g from games where id = ev.game_id;
      perform slack_post('Everyone chose to end the game.');
      perform slack_post(case g.winner when 'faithful' then 'The game is over. The Faithful win!' else 'The game is over. The Traitors win!' end);
    else
      perform slack_post('Not everyone chose to end the game, so it goes on.');
      perform open_final_banishment(ev.game_id);
    end if;
    return;
  end if;

  if ev.kind = 'banishment' then v_votes := vote_breakdown(p_event); end if;
  select target_id, kind, accepted into v_target, v_kind, v_accepted from event_results where event_id = p_event;
  select count(*) into v_alive from players where game_id = ev.game_id and alive;
  -- Murder victims are always faithful, so only banishments can hide anything: from 6 alive down, no role is shown.
  v_show_role := ev.kind = 'murder' or v_alive >= 7;
  if v_target is not null then
    if v_kind = 'kill' then
      update players set alive = false, role_public = v_show_role where id = v_target;
    elsif v_accepted is true then
      -- A target banished between the offer and the reveal can't be recruited.
      update roles set role = 'traitor' where player_id = v_target and exists (select 1 from players where id = v_target and alive);
    end if;
  end if;
  update events set status = 'revealed' where id = p_event;
  if v_votes is not null then update event_results set votes = v_votes where event_id = p_event; end if;

  -- A recruit round is announced as a quiet one so the faithful can't tell it apart.
  if v_target is not null and v_kind = 'kill' then
    select p.display_name, r.role into v_name, v_role from players p join roles r on r.player_id = p.id where p.id = v_target;
    perform slack_post(format('%s was %s.', v_name, case ev.kind when 'banishment' then 'banished' else 'murdered' end)
      || case when v_show_role then format(' They were %s.', case v_role when 'traitor' then 'a traitor' else 'faithful' end) else '' end
      || coalesce(E'\n' || v_votes, ''));
  else
    perform slack_post(format('Nobody was %s.', case ev.kind when 'banishment' then 'banished' else 'murdered' end)
      || coalesce(E'\n' || v_votes, ''));
  end if;

  perform check_win(ev.game_id);
  select * into g from games where id = ev.game_id;
  if g.status = 'finished' then
    perform slack_post(case g.winner when 'faithful' then 'The game is over. The Faithful win!' else 'The game is over. The Traitors win!' end);
  elsif ev.untimed then
    -- The last banishment is done and the game is still on: the end game vote follows, with no murder in between.
    declare t timestamptz := clock_timestamp();
    begin
      update games set phase = 'endgame' where id = ev.game_id;
      insert into events (game_id, kind, opens_at, closes_at, reveals_at, status, untimed)
      values (ev.game_id, 'endgame', t, t + interval '10 years', t + interval '10 years', 'open', true);
      perform slack_post('The end game vote is open. Everyone chooses: end the game, or keep playing. There is no deadline.');
    end;
  end if;
end $$;

-- Runs close, reveal, then open until nothing moves, so a murder revealed at 09:00 has already taken effect when the
-- banishment opening at 09:00 counts who is alive (that count decides whether it is the final banishment).
create or replace function advance_games(p_now timestamptz default now()) returns void language plpgsql security definer set search_path = public as $$
declare e events; tz text; v_alive int; changed boolean; i int := 0;
begin
  loop
    changed := false; i := i + 1;

    for e in select ev.* from events ev join games g on g.id = ev.game_id
             where g.status = 'active' and ev.status = 'open' and ev.closes_at <= p_now
             order by ev.closes_at loop
      perform close_event(e.id);
      changed := true;
    end loop;

    -- Re-checks game status per event: a win mid-catch-up must stop later reveals.
    for e in select ev.* from events ev join games g on g.id = ev.game_id
             where g.status = 'active' and ev.status = 'closed' and ev.reveals_at <= p_now
             order by ev.reveals_at loop
      if (select status from games where id = e.game_id) = 'active' then
        perform reveal_event(e.id);
        changed := true;
      end if;
    end loop;

    for e in select ev.* from events ev join games g on g.id = ev.game_id
             where g.status = 'active' and ev.status = 'scheduled' and ev.opens_at <= p_now
             order by ev.opens_at loop
      -- An earlier event in this pass may have ended the game or dropped this one.
      continue when not exists (select 1 from events x join games g on g.id = x.game_id
                                where x.id = e.id and x.status = 'scheduled' and g.status = 'active');
      select g.tz into tz from games g where g.id = e.game_id;
      select count(*) into v_alive from players where game_id = e.game_id and alive;
      if e.kind = 'banishment' and v_alive <= 6 and (select phase from games where id = e.game_id) = 'normal' then
        -- First banishment with 6 or fewer alive is the last one; open_final_banishment would add a second event, so
        -- convert this one instead.
        update games set phase = 'final' where id = e.game_id;
        delete from events where game_id = e.game_id and status = 'scheduled' and id <> e.id;
        update events set status = 'open', untimed = true,
          closes_at = p_now + interval '10 years', reveals_at = p_now + interval '10 years' where id = e.id;
        perform slack_post('The final banishment vote is open. There is no deadline: it closes when everyone has voted. Roles are no longer revealed.');
      else
        update events set status = 'open' where id = e.id;
        -- Murder windows are the traitors' business, so only banishment votes are announced.
        if e.kind = 'banishment' then
          perform slack_post(format('The banishment vote is open. It closes %s. Not voting counts as abstaining.',
                                    to_char(e.closes_at at time zone tz, 'FMDay "at" HH24:MI')));
        end if;
      end if;
      changed := true;
    end loop;

    exit when not changed or i >= 50;
  end loop;

  for e in select ev.* from events ev join games g on g.id = ev.game_id
           where g.status = 'active' and ev.status = 'open' and ev.kind = 'banishment' and not ev.reminded and not ev.untimed
             and ev.closes_at - interval '3 hours' <= p_now and ev.closes_at > p_now
           order by ev.closes_at loop
    update events set reminded = true where id = e.id;
    select g.tz into tz from games g where g.id = e.game_id;
    perform slack_post(format('Reminder: the banishment vote closes %s. If you have not voted yet, now is the time.',
                              to_char(e.closes_at at time zone tz, 'FMDay "at" HH24:MI')));
  end loop;
end $$;

create extension if not exists pg_cron;
select cron.schedule('advance-games', '* * * * *', $$select public.advance_games()$$);

create or replace function gm_force_close(p_event uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  update events
  set closes_at = least(closes_at, now()),
      reveals_at = case when kind in ('banishment', 'endgame') then least(reveals_at, now()) else reveals_at end
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

-- Starts the final banishment now. Anything open is voided (picks blanked, nobody banished or murdered) and
-- everything still scheduled is dropped; the end game vote follows the banishment as usual.
-- My own answer in the end game vote (null until I answer), so the buttons can show what I chose.
create or replace function my_endgame(p_event uuid) returns boolean language sql stable security definer set search_path = public as $$
  select a.end_vote from actions a join players p on p.id = a.player_id
  where a.event_id = p_event and p.user_id = auth.uid()
$$;

create or replace function gm_start_endgame(p_game uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if (select status from games where id = p_game) is distinct from 'active' then raise exception 'The game is not running'; end if;
  if (select phase from games where id = p_game) <> 'normal' then raise exception 'The end game has already started'; end if;
  delete from events where game_id = p_game and status = 'scheduled';
  update actions set target_id = null where event_id in (select id from events where game_id = p_game and status = 'open');
  update events set closes_at = least(closes_at, now()), reveals_at = least(reveals_at, now())
  where game_id = p_game and status in ('open', 'closed');
  perform advance_games();
  if (select status from games where id = p_game) = 'active' then perform open_final_banishment(p_game); end if;
end $$;

revoke execute on function
  advance_games(timestamptz), close_event(uuid), reveal_event(uuid), check_win(uuid),
  settle_untimed(uuid), open_final_banishment(uuid),
  internal_start_game(uuid, timestamp, jsonb, int, int)
  from public, anon, authenticated;

revoke execute on function gm_start_endgame(uuid), cast_endgame(uuid, boolean), my_endgame(uuid) from public, anon;
grant execute on function gm_start_endgame(uuid), cast_endgame(uuid, boolean), my_endgame(uuid) to authenticated;

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

create or replace function my_person() returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(x) from (select display_name as name, email, avatar_key from people where user_id = auth.uid()) x
$$;

create or replace function photo_gallery() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'key', f.key,
      'taken', exists (select 1 from people p where p.avatar_key = f.key and p.user_id <> auth.uid()),
      'mine', exists (select 1 from people p where p.avatar_key = f.key and p.user_id = auth.uid())) order by f.key), '[]')
  from photos f where exists (select 1 from people where user_id = auth.uid())
$$;

-- Choosing a photo updates every game they are already in, so the grid never shows a stale picture.
create or replace function set_my_photo(p_key text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from people where user_id = auth.uid()) then raise exception 'not allowed'; end if;
  if not exists (select 1 from photos where key = p_key) then raise exception 'That photo does not exist'; end if;
  begin
    update people set avatar_key = p_key where user_id = auth.uid();
  exception when unique_violation then
    raise exception 'That photo has already been taken';
  end;
  update players set avatar_key = p_key where user_id = auth.uid();
end $$;

-- If someone picked the wrong face, the GM clears it and they choose again.
create or replace function gm_reset_photo(p_user uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  update people set avatar_key = null where user_id = p_user;
  update players set avatar_key = null where user_id = p_user;
end $$;

-- The GM can give any account a photo. Same rule as everyone: one photo per person, so a photo someone
-- else holds is refused (reset theirs first).
create or replace function gm_gallery(p_user uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'key', f.key,
      'taken', exists (select 1 from people p where p.avatar_key = f.key and p.user_id <> p_user),
      'mine', exists (select 1 from people p where p.avatar_key = f.key and p.user_id = p_user)) order by f.key)
    from photos f), '[]');
end $$;

create or replace function gm_set_photo(p_user uuid, p_key text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if not exists (select 1 from people where user_id = p_user) then raise exception 'No such person'; end if;
  if not exists (select 1 from photos where key = p_key) then raise exception 'That photo does not exist'; end if;
  begin
    update people set avatar_key = p_key where user_id = p_user;
  exception when unique_violation then
    raise exception 'That photo has already been taken';
  end;
  update players set avatar_key = p_key where user_id = p_user;
end $$;

revoke execute on function gm_gallery(uuid), gm_set_photo(uuid, text) from public, anon;
grant execute on function gm_gallery(uuid), gm_set_photo(uuid, text) to authenticated;

revoke execute on function my_person(), photo_gallery(), set_my_photo(text), gm_reset_photo(uuid) from public, anon;
grant execute on function my_person(), photo_gallery(), set_my_photo(text), gm_reset_photo(uuid) to authenticated;

-- Names can be corrected by the person or the GM. players holds a copy for each game, so both tables change together.
create or replace function set_name(p_user uuid, p_name text) returns void language plpgsql security definer set search_path = public as $$
declare n text := btrim(p_name);
begin
  if p_user <> auth.uid() and not is_admin() then raise exception 'not allowed'; end if;
  if n is null or length(n) not between 1 and 40 then raise exception 'Name must be 1 to 40 characters'; end if;
  update people set display_name = n where user_id = p_user;
  update players set display_name = n where user_id = p_user;
end $$;
revoke execute on function set_name(uuid, text) from public, anon;
grant execute on function set_name(uuid, text) to authenticated;

-- The GM isn't a player, so RLS hides players/events from them; this is their only window in.
create or replace function gm_overview(p_game uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return jsonb_build_object(
    'players', (select count(*) from players where game_id = p_game),
    'signup_code', (select value from app_config where key = 'signup_code'),
    'slack_on', exists (select 1 from app_config where key = 'slack_webhook'),
    'people', coalesce((select jsonb_agg(jsonb_build_object(
                'user_id', p.user_id, 'name', p.display_name, 'email', p.email, 'avatar_key', p.avatar_key,
                'traitor', exists (select 1 from designated_traitors d where d.game_id = p_game and d.user_id = p.user_id),
                'in_game', exists (select 1 from players g where g.game_id = p_game and g.user_id = p.user_id))
                order by p.display_name) from people p), '[]'),
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.opens_at)
                        from (select * from events where game_id = p_game and status <> 'revealed'
                              order by opens_at limit 8) e), '[]'));
end $$;

create or replace function gm_set_traitor(p_game uuid, p_user uuid, p_on boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if (select status from games where id = p_game) is distinct from 'lobby' then raise exception 'game not in lobby'; end if;
  if not exists (select 1 from players where game_id = p_game and user_id = p_user) then raise exception 'That person is not in this game'; end if;
  if p_on then
    insert into designated_traitors (game_id, user_id) values (p_game, p_user) on conflict do nothing;
  else
    delete from designated_traitors where game_id = p_game and user_id = p_user;
  end if;
end $$;

revoke execute on function gm_set_traitor(uuid, uuid, boolean) from public, anon;
grant execute on function gm_set_traitor(uuid, uuid, boolean) to authenticated;

create or replace function gm_set_player(p_game uuid, p_user uuid, p_in boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if (select status from games where id = p_game) is distinct from 'lobby' then raise exception 'game not in lobby'; end if;
  if p_in then
    insert into players (game_id, user_id, email, display_name, avatar_key)
    select p_game, user_id, email, display_name, avatar_key from people where user_id = p_user
    on conflict (game_id, user_id) do nothing;
  else
    delete from players where game_id = p_game and user_id = p_user;
  end if;
end $$;

-- Participation only: who hasn't voted and how many traitors have chosen. Never what anyone chose, who the
-- traitors are, or whether a traitor pick is a murder or a recruit, so the GM stays out of the secrets.
create or replace function gm_dashboard(p_game uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare g games;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  select * into g from games where id = p_game;
  return jsonb_build_object(
    'status', g.status, 'phase', g.phase,
    'alive', (select count(*) from players where game_id = p_game and alive),
    'out', (select count(*) from players where game_id = p_game and not alive),
    'events', coalesce((select jsonb_agg(x order by x ->> 'opens_at') from (
      select jsonb_build_object(
        'id', e.id, 'kind', e.kind, 'status', e.status, 'untimed', e.untimed,
        'opens_at', e.opens_at, 'closes_at', e.closes_at, 'reveals_at', e.reveals_at,
        'voters', case when e.kind <> 'murder' then (select count(*) from players p where p.game_id = e.game_id and p.alive) end,
        'voted', case when e.kind <> 'murder' then
          (select count(*) from actions a join players p on p.id = a.player_id where a.event_id = e.id and p.alive) end,
        'not_voted', case when e.kind <> 'murder' and e.status = 'open' then coalesce((
          select jsonb_agg(p.display_name order by p.display_name) from players p
          where p.game_id = e.game_id and p.alive
            and not exists (select 1 from actions a where a.event_id = e.id and a.player_id = p.id)), '[]') end,
        'traitors', case when e.kind = 'murder' then
          (select count(*) from players p join roles r on r.player_id = p.id
           where p.game_id = e.game_id and p.alive and r.role = 'traitor') end,
        'picked', case when e.kind = 'murder' then
          (select count(*) from actions a join players p on p.id = a.player_id join roles r on r.player_id = p.id
           where a.event_id = e.id and p.alive and r.role = 'traitor') end
      ) as x
      from events e where e.game_id = p_game and e.status in ('scheduled', 'open', 'closed')
      order by e.opens_at limit 4) s), '[]'),
    'history', coalesce((select jsonb_agg(h order by h ->> 'at' desc) from (
      select jsonb_build_object('at', e.closes_at,
        'voted', (select count(*) from actions a where a.event_id = e.id)) as h
      from events e where e.game_id = p_game and e.kind = 'banishment' and e.status = 'revealed'
      order by e.closes_at desc limit 4) hs), '[]'));
end $$;

revoke execute on function gm_dashboard(uuid) from public, anon;
grant execute on function gm_dashboard(uuid) to authenticated;

-- Delay everything still to come, e.g. a holiday or an outage. Open windows get longer, scheduled ones start later,
-- closed ones reveal later. Already-sent reminders are re-armed so the new deadline gets its own.
create or replace function gm_shift_game(p_game uuid, p_by interval) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if p_by <= interval '0' or p_by > interval '14 days' then raise exception 'Delay must be between 0 and 14 days'; end if;
  update events set
    opens_at = case when status = 'scheduled' then opens_at + p_by else opens_at end,
    closes_at = case when status in ('scheduled', 'open') then closes_at + p_by else closes_at end,
    reveals_at = reveals_at + p_by,
    reminded = false
  where game_id = p_game and status in ('scheduled', 'open', 'closed');
end $$;

-- Void a window: every pick is blanked (the tally ignores empty picks, and the rows stay as a record of who took
-- part) and it closes now, so nobody is banished or murdered.
create or replace function gm_skip_event(p_event uuid) returns void language plpgsql security definer set search_path = public as $$
declare ev events;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  select * into ev from events where id = p_event;
  if ev.id is null or ev.status <> 'open' then raise exception 'Only an open event can be skipped'; end if;
  update actions set target_id = null where event_id = p_event;
  update events set closes_at = least(closes_at, now()), reveals_at = least(reveals_at, now()) where id = p_event;
  perform advance_games();
end $$;

-- Posts the names of players still to vote. The GM chooses when, so naming people is their call.
create or replace function gm_remind(p_event uuid) returns void language plpgsql security definer set search_path = public as $$
declare ev events; v_names text; v_tz text;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  select * into ev from events where id = p_event;
  if ev.id is null or ev.status <> 'open' or ev.kind <> 'banishment' then
    raise exception 'Only an open banishment vote can be reminded';
  end if;
  if not exists (select 1 from app_config where key = 'slack_webhook') then raise exception 'No Slack webhook is set'; end if;
  select string_agg(p.display_name, ', ' order by p.display_name) into v_names from players p
  where p.game_id = ev.game_id and p.alive
    and not exists (select 1 from actions a where a.event_id = ev.id and a.player_id = p.id);
  if v_names is null then raise exception 'Everyone has already voted'; end if;
  select tz into v_tz from games where id = ev.game_id;
  perform slack_post(format('Still to vote in the banishment: %s. The vote closes %s.', v_names,
                            to_char(ev.closes_at at time zone v_tz, 'FMDay "at" HH24:MI')));
end $$;

revoke execute on function gm_shift_game(uuid, interval), gm_skip_event(uuid), gm_remind(uuid) from public, anon;
grant execute on function gm_shift_game(uuid, interval), gm_skip_event(uuid), gm_remind(uuid) to authenticated;

-- The GM runs the database and can read everything anyway, so this is the full picture: roles, every
-- vote and pick, recruit offers. It is a separate function from gm_dashboard so the safe view stays safe.
create or replace function gm_secrets(p_game uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return jsonb_build_object(
    'players', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.display_name, 'alive', p.alive, 'role', r.role)
                                          order by p.display_name)
                         from players p left join roles r on r.player_id = p.id where p.game_id = p_game), '[]'),
    'picks', coalesce((select jsonb_agg(jsonb_build_object('event_id', a.event_id, 'event_kind', e.kind, 'who', voter.display_name,
                                                            'kind', a.kind, 'target', t.display_name)
                                        order by e.opens_at, voter.display_name)
                       from actions a join events e on e.id = a.event_id
                       join players voter on voter.id = a.player_id
                       left join players t on t.id = a.target_id
                       where e.game_id = p_game and e.status in ('open', 'closed')), '[]'),
    'offers', coalesce((select jsonb_agg(jsonb_build_object('event_id', r.event_id, 'target', t.display_name, 'accepted', r.accepted))
                        from event_results r join events e on e.id = r.event_id join players t on t.id = r.target_id
                        where r.game_id = p_game and r.kind = 'recruit' and e.status = 'closed'), '[]'));
end $$;

create or replace function gm_chat(p_game uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'who', case when m.from_gm then 'Game master' else p.display_name end,
      'body', m.body, 'at', m.created_at, 'from_gm', m.from_gm) order by m.created_at)
    from (select * from messages where game_id = p_game order by created_at desc limit 200) m
    left join players p on p.id = m.player_id), '[]');
end $$;

create or replace function gm_post_message(p_game uuid, p_body text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if (select status from games where id = p_game) is distinct from 'active' then raise exception 'The game is not running'; end if;
  if char_length(trim(coalesce(p_body, ''))) = 0 then raise exception 'The message is empty'; end if;
  insert into messages (game_id, player_id, from_gm, body) values (p_game, null, true, left(trim(p_body), 500));
end $$;

revoke execute on function gm_secrets(uuid), gm_chat(uuid), gm_post_message(uuid, text) from public, anon;
grant execute on function gm_secrets(uuid), gm_chat(uuid), gm_post_message(uuid, text) to authenticated;

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
revoke execute on function vote_breakdown(uuid) from public, anon, authenticated;
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
