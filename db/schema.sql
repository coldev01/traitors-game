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
  target_id uuid references players on delete set null
);

-- A recruit round is stored in event_results as an ordinary "nobody was murdered" row, so non-traitors can't tell it
-- apart. The real offer lives here, readable only by traitors (and its target, through my_offer).
create table if not exists recruit_offers (
  event_id uuid primary key references events on delete cascade,
  game_id uuid not null references games on delete cascade,
  target_id uuid references players on delete set null,
  accepted boolean
);
alter table recruit_offers enable row level security;

-- What the traitors locked in for a murder window: a murder, a recruit, or nothing (target null). Kept out of events,
-- which every player can read, so the faithful can't see whether a recruit is under way.
create table if not exists murder_locks (
  event_id uuid primary key references events on delete cascade,
  game_id uuid not null references games on delete cascade,
  kind text not null check (kind in ('kill', 'recruit')),
  target_id uuid references players on delete set null
);
alter table murder_locks enable row level security;

create table if not exists actions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events on delete cascade,
  player_id uuid not null references players on delete cascade,
  target_id uuid references players on delete set null,
  created_at timestamptz not null default now(),
  unique (event_id, player_id)
);

create table if not exists messages (
  id bigint generated always as identity primary key,
  game_id uuid not null references games on delete cascade,
  channel text not null default 'traitors' check (channel in ('traitors')),
  player_id uuid not null references players on delete cascade,
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

-- Recruitment: when the traitors lock in a recruit the target becomes a traitor at once, and has until the window
-- closes to refuse. accepted stays null until they answer; refusing turns them faithful again and they are murdered.
-- The traitors choose by majority until picks_close_at; after that a random one of their picks goes ahead.
alter table events add column if not exists picks_close_at timestamptz;
alter table actions add column if not exists kind text not null default 'kill' check (kind in ('kill', 'recruit'));
alter table event_results add column if not exists kind text not null default 'kill' check (kind in ('kill', 'recruit'));
alter table event_results add column if not exists accepted boolean;
-- Rounds saved before recruit offers moved here: move them over so they stop showing as public results.
insert into recruit_offers (event_id, game_id, target_id, accepted)
  select event_id, game_id, target_id, accepted from event_results where kind = 'recruit' on conflict do nothing;
update event_results set kind = 'kill', target_id = null where kind = 'recruit';
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
alter table games add column if not exists revealing boolean not null default false;
alter table games add column if not exists archived boolean not null default false;
-- Names end up in Slack posts and the vote breakdown (which is split on line breaks), so no control characters, and no
-- two people can share a name (ignoring case).
alter table people drop constraint if exists people_name_ok;
alter table people add constraint people_name_ok check (
  char_length(display_name) between 1 and 40 and display_name !~ '[\u0001-\u001f\u007f-\u009f\u2028\u2029]') not valid; -- checks new and changed rows, so an old name can't stop a re-run
create unique index if not exists people_display_name_unique on people (lower(display_name));
alter table players add column if not exists revealed boolean not null default false;
alter table players add column if not exists revealed_at timestamptz;
alter table players add column if not exists role_public boolean not null default true;
alter table actions add column if not exists end_vote boolean;
-- Without these, deleting a game that has votes or chat fails: the cascade removes players but these rows still point at them.
alter table actions drop constraint if exists actions_target_id_fkey, add constraint actions_target_id_fkey foreign key (target_id) references players on delete set null;
alter table event_results drop constraint if exists event_results_target_id_fkey, add constraint event_results_target_id_fkey foreign key (target_id) references players on delete set null;
alter table messages drop constraint if exists messages_player_id_fkey, add constraint messages_player_id_fkey foreign key (player_id) references players on delete cascade;
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
-- The GM is not a player, but runs the game and has to see who is in it and what has happened (never roles, below).
create policy players_select on players for select to authenticated using (in_game(game_id) or is_admin());
drop policy if exists events_select on events;
create policy events_select on events for select to authenticated using (in_game(game_id) or is_admin());

drop policy if exists roles_select on roles;
create policy roles_select on roles for select to authenticated using (
  (is_admin() and exists (select 1 from games g where g.id = roles.game_id and g.status = 'finished')) or
  in_game(game_id) and (
    player_id = my_player(game_id)
    or (is_traitor(game_id) and role = 'traitor')
    or exists (select 1 from players p where p.id = roles.player_id and not p.alive and p.role_public)
    or exists (select 1 from players p where p.id = roles.player_id and p.revealed)
    or exists (select 1 from games g where g.id = roles.game_id and g.status = 'finished')
  )
);

drop policy if exists results_select on event_results;
create policy results_select on event_results for select to authenticated using (
  (in_game(game_id) or is_admin())
  and exists (select 1 from events e where e.id = event_id and e.status = 'revealed')
);

drop policy if exists murder_locks_select on murder_locks;
create policy murder_locks_select on murder_locks for select to authenticated using (is_traitor(game_id));
drop policy if exists recruit_offers_select on recruit_offers;
create policy recruit_offers_select on recruit_offers for select to authenticated using (is_traitor(game_id));

drop policy if exists messages_select on messages;
create policy messages_select on messages for select to authenticated using (is_traitor(game_id));

create or replace function am_admin() returns boolean language sql stable as $$ select is_admin() $$;

-- Offsets are minutes from Monday 00:00 local time. In a murder window the traitors must decide by 'lock' (14:00 on the
-- day it opens); a recruit then has until the window closes to refuse. Murder 1 closes Wed 00:00 and murder 2 closes
-- Mon 00:00 (the next week); nothing opens or closes on a Friday, Saturday or Sunday.
create or replace function default_schedule() returns jsonb language sql immutable as $$
  -- Votes open and close Mon-Thu 09:00; murders close at midnight and are revealed at 09:00. Never Fri-Sun (the team is off
  -- alternate Fridays). Murder 2 spans the weekend.
  select jsonb_build_array(
    jsonb_build_object('kind', 'banishment', 'open', 540,  'close', 1980, 'reveal', 1980),
    jsonb_build_object('kind', 'murder',     'open', 1980, 'close', 2880, 'reveal', 3420, 'lock', 2280),
    jsonb_build_object('kind', 'banishment', 'open', 3420, 'close', 4860, 'reveal', 4860),
    jsonb_build_object('kind', 'murder',     'open', 4860, 'close', 10080, 'reveal', 10620, 'lock', 5160))
$$;

create or replace function create_game() returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if exists (select 1 from games where status in ('lobby', 'active') and not archived) then
    raise exception 'A game is already waiting or running. Finish or delete it first.';
  end if;
  -- A finished game is put away automatically, so it never vanishes from every screen.
  update games set archived = true where status = 'finished' and not archived;
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
  insert into events (game_id, kind, opens_at, closes_at, reveals_at, picks_close_at)
  select p_game, s ->> 'kind',
    (v_anchor + make_interval(mins => w * p_period + (s ->> 'open')::int)) at time zone g.tz,
    (v_anchor + make_interval(mins => w * p_period + (s ->> 'close')::int)) at time zone g.tz,
    (v_anchor + make_interval(mins => w * p_period + (s ->> 'reveal')::int)) at time zone g.tz,
    (v_anchor + make_interval(mins => w * p_period + (s ->> 'lock')::int)) at time zone g.tz
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
  if ev.id is null or not ev.untimed then return; end if;
  -- Same lock as advance_games: if the last two answers land together, the second one to get here sees both.
  perform pg_advisory_xact_lock(727001);
  select * into ev from events where id = p_event;
  if ev.status <> 'open' then return; end if;
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
  -- Lock first, before touching any event row: taking it after a row lock can deadlock with advance_games.
  perform pg_advisory_xact_lock(727001);
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
  -- Lock first, before touching any event row: taking it after a row lock can deadlock with advance_games.
  perform pg_advisory_xact_lock(727001);
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
  perform pg_advisory_xact_lock(727001); -- the pick that makes a majority locks the round, so picks can't interleave
  select * into ev from events where id = p_event;
  if ev.id is null or ev.kind <> 'murder' or ev.status <> 'open' or now() >= least(ev.closes_at, coalesce(ev.picks_close_at, ev.closes_at))
     or exists (select 1 from murder_locks where event_id = p_event) then
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
  perform lock_murder(p_event, false);
end $$;

create or replace function pick_recruit(p_event uuid, p_target uuid) returns void language plpgsql security definer set search_path = public as $$
declare ev events; me uuid;
begin
  perform pg_advisory_xact_lock(727001);
  select * into ev from events where id = p_event;
  if ev.id is null or ev.kind <> 'murder' or ev.status <> 'open' or now() >= least(ev.closes_at, coalesce(ev.picks_close_at, ev.closes_at))
     or exists (select 1 from murder_locks where event_id = p_event) then
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
  perform lock_murder(p_event, false);
end $$;

-- Settles what the traitors chose for a murder window. Called after every pick and at the deadline (p_force).
-- A choice with more than half the living traitors behind it locks at once; at the deadline the most-picked choice
-- wins, a tie is settled at random, and no picks at all locks "nobody". A recruit makes the target a traitor now,
-- and they have until the window closes to refuse (respond_recruit).
create or replace function lock_murder(p_event uuid, p_force boolean) returns void language plpgsql security definer set search_path = public as $$
declare ev events; v_n int; v_kind text; v_target uuid; v_votes int;
begin
  select * into ev from events where id = p_event for no key update;
  if ev.id is null or ev.kind <> 'murder' or ev.status <> 'open'
     or exists (select 1 from murder_locks where event_id = p_event) then return; end if;
  select count(*) into v_n from players p join roles r on r.player_id = p.id
  where p.game_id = ev.game_id and p.alive and r.role = 'traitor';
  select a.kind, a.target_id, count(*) into v_kind, v_target, v_votes
  from actions a
  join players voter on voter.id = a.player_id and voter.alive
  join roles vr on vr.player_id = voter.id and vr.role = 'traitor'
  join players t on t.id = a.target_id and t.alive
  where a.event_id = p_event and a.target_id is not null
  group by a.kind, a.target_id
  order by count(*) desc, random()
  limit 1;
  if v_target is null then
    if not p_force then return; end if;
    v_kind := 'kill'; -- the deadline passed with no picks
  elsif v_votes * 2 <= v_n and not p_force then
    return;
  end if;
  -- Traitors may have grown back past the limit since they picked, so re-check.
  if v_kind = 'recruit' and v_n > 2 then v_kind := 'kill'; v_target := null; end if;
  insert into murder_locks (event_id, game_id, kind, target_id) values (p_event, ev.game_id, v_kind, v_target);
  if v_kind = 'recruit' then
    update roles set role = 'traitor' where player_id = v_target;
    insert into recruit_offers (event_id, game_id, target_id) values (p_event, ev.game_id, v_target);
  end if;
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

-- The recruit is already a traitor. They can refuse until the murder window closes, and refusing gets them murdered.
create or replace function my_offer(p_game uuid) returns uuid language sql stable security definer set search_path = public as $$
  select r.event_id from recruit_offers r
  join events e on e.id = r.event_id
  join players p on p.id = r.target_id
  where r.game_id = p_game and r.accepted is null
    and e.status = 'open' and p.alive and p.user_id = auth.uid()
  limit 1
$$;

create or replace function respond_recruit(p_event uuid, p_accept boolean) returns void language plpgsql security definer set search_path = public as $$
declare v_target uuid;
begin
  perform pg_advisory_xact_lock(727001);
  update recruit_offers r set accepted = p_accept
  from events e, players p
  where r.event_id = p_event and e.id = r.event_id and p.id = r.target_id
    and r.accepted is null and e.status = 'open' and now() < e.closes_at and p.alive and p.user_id = auth.uid()
  returning r.target_id into v_target;
  if v_target is null then raise exception 'no offer'; end if;
  -- Refusing undoes the recruitment, so the murder that follows shows them as faithful and the faithful learn nothing.
  if not p_accept then update roles set role = 'faithful' where player_id = v_target; end if;
end $$;

-- The game ends only at 2 players left (the end game vote handles the rest). Parity or an empty traitor side does
-- not end it: players can't tell whether the last traitor has gone, so the game can't announce it by stopping.
-- Either way of finishing goes through the reveal stage first, where the last players show their roles.
create or replace function check_win(p_game uuid) returns void language plpgsql security definer set search_path = public as $$
declare n int;
begin
  select count(*) into n from players where game_id = p_game and alive;
  if n <= 2 and not (select revealing from games where id = p_game) then perform begin_reveal(p_game); end if;
end $$;

-- Nothing is scheduled or open any more; the players still alive show their roles one at a time.
create or replace function begin_reveal(p_game uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  update games set revealing = true where id = p_game;
  delete from events where game_id = p_game and status in ('scheduled', 'open');
  perform slack_post('The game is nearly over. The players still standing now reveal who they are.');
  perform finish_if_revealed(p_game);
end $$;

create or replace function finish_if_revealed(p_game uuid) returns void language plpgsql security definer set search_path = public as $$
declare w text;
begin
  if not (select revealing from games where id = p_game) then return; end if;
  if exists (select 1 from players where game_id = p_game and alive and not revealed) then return; end if;
  select case when exists (select 1 from players p join roles r on r.player_id = p.id
                           where p.game_id = p_game and p.alive and r.role = 'traitor') then 'traitors' else 'faithful' end into w;
  update games set status = 'finished', winner = w where id = p_game;
  perform slack_post(case w when 'faithful' then 'The game is over. The Faithful win!' else 'The game is over. The Traitors win!' end);
end $$;

create or replace function do_reveal(p_player uuid) returns void language plpgsql security definer set search_path = public as $$
declare pl players; v_role text;
begin
  select * into pl from players where id = p_player for update;
  if pl.id is null or not pl.alive or pl.revealed or not (select revealing from games where id = pl.game_id) then return; end if;
  update players set revealed = true, revealed_at = clock_timestamp() where id = p_player;
  select role into v_role from roles where player_id = p_player;
  perform slack_post(format('%s reveals their role: %s.', pl.display_name, case v_role when 'traitor' then 'a traitor' else 'faithful' end));
  perform finish_if_revealed(pl.game_id);
end $$;

create or replace function reveal_my_role(p_game uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if my_player(p_game) is null then raise exception 'not in this game'; end if;
  perform do_reveal(my_player(p_game));
end $$;

create or replace function gm_reveal_role(p_player uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  perform do_reveal(p_player);
end $$;

create or replace function gm_reveal_all(p_game uuid) returns void language plpgsql security definer set search_path = public as $$
declare r uuid;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  for r in select id from players where game_id = p_game and alive and not revealed loop perform do_reveal(r); end loop;
end $$;

-- Dead voters and dead targets are filtered here, not at cast time, because a murder is only
-- applied at its reveal: a vote cast before then must be discarded once the voter is dead.
create or replace function close_event(p_event uuid) returns void language plpgsql security definer set search_path = public as $$
declare ev events; v_target uuid; v_kind text;
begin
  select * into ev from events where id = p_event for no key update; -- not 'for update': that would block on a voter's insert
  if ev.status <> 'open' then return; end if; -- another run already closed it
  if ev.kind = 'endgame' then
    -- accepted means "everyone alive chose to end it"; no answer counts as keep playing.
    insert into event_results (event_id, game_id, target_id, kind, accepted)
    values (p_event, ev.game_id, null, 'kill', not exists (
      select 1 from players p where p.game_id = ev.game_id and p.alive
        and not exists (select 1 from actions a where a.event_id = p_event and a.player_id = p.id and a.end_vote is true)));
    update events set status = 'closed' where id = p_event;
    return;
  end if;
  if ev.kind = 'murder' then
    perform lock_murder(p_event, true); -- a window forced shut before the traitors' deadline still gets its choice settled
    select l.kind, l.target_id into v_kind, v_target from murder_locks l where l.event_id = p_event;
    -- A recruit round is public as a quiet one, unless the recruit refused: then they are murdered.
    if v_kind = 'recruit' then
      select case when o.accepted is false then o.target_id end into v_target from recruit_offers o where o.event_id = p_event;
    end if;
    if not exists (select 1 from players where id = v_target and alive) then v_target := null; end if;
  else
    select a.target_id into v_target
    from actions a
    join players voter on voter.id = a.player_id and voter.alive
    join players t on t.id = a.target_id and t.alive
    where a.event_id = p_event and a.target_id is not null
    group by a.target_id
    order by count(*) desc, random()
    limit 1;
  end if;
  insert into event_results (event_id, game_id, target_id, kind) values (p_event, ev.game_id, v_target, 'kill');
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
  select * into ev from events where id = p_event for no key update; -- not 'for update': that would block on a voter's insert
  if ev.status <> 'closed' then return; end if; -- another run already revealed it

  if ev.kind = 'endgame' then
    select accepted into v_accepted from event_results where event_id = p_event;
    update events set status = 'revealed' where id = p_event;
    if v_accepted then
      perform slack_post('Everyone chose to end the game.');
      perform begin_reveal(ev.game_id);
    else
      perform slack_post('Not everyone chose to end the game, so it goes on.');
      perform open_final_banishment(ev.game_id);
    end if;
    return;
  end if;

  if ev.kind = 'banishment' then v_votes := vote_breakdown(p_event); end if;
  select target_id, kind into v_target, v_kind from event_results where event_id = p_event;
  select count(*) into v_alive from players where game_id = ev.game_id and alive;
  -- Murder victims are always faithful, so only banishments can hide anything: from 6 alive down, no role is shown.
  v_show_role := ev.kind = 'murder' or v_alive >= 7;
  if v_target is not null then
    update players set alive = false, role_public = v_show_role where id = v_target;
  end if;
  update events set status = 'revealed' where id = p_event;
  if v_votes is not null then update event_results set votes = v_votes where event_id = p_event; end if;

  -- A recruit round has no public target, so it is announced as a quiet one and the faithful can't tell it apart.
  if v_target is not null then
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
  if g.revealing or g.status = 'finished' then
    null; -- the reveal stage posts its own announcements
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
  -- One run at a time: the cron job, a GM button and the last vote can all arrive together.
  perform pg_advisory_xact_lock(727001);
  loop
    changed := false; i := i + 1;

    -- The traitors' deadline: settle what they chose so a recruit can start refusing.
    for e in select ev.* from events ev join games g on g.id = ev.game_id
             where g.status = 'active' and ev.status = 'open' and ev.kind = 'murder' and ev.picks_close_at <= p_now
               and not exists (select 1 from murder_locks l where l.event_id = ev.id)
             order by ev.picks_close_at loop
      perform lock_murder(e.id, true);
      changed := true;
    end loop;

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
  -- Lock first, before touching any event row: taking it after a row lock can deadlock with advance_games.
  perform pg_advisory_xact_lock(727001);
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
-- A finished game can be put away so the app moves on to a fresh one; it stays in the database and in the GM's archive list.
create or replace function gm_archive_game(p_game uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if (select status from games where id = p_game) is distinct from 'finished' then raise exception 'Only a finished game can be archived'; end if;
  update games set archived = true where id = p_game;
end $$;
revoke execute on function gm_archive_game(uuid) from public, anon;
grant execute on function gm_archive_game(uuid) to authenticated;

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
  -- Lock first, before touching any event row: taking it after a row lock can deadlock with advance_games.
  perform pg_advisory_xact_lock(727001);
  if (select status from games where id = p_game) is distinct from 'active' then raise exception 'The game is not running'; end if;
  if (select phase from games where id = p_game) <> 'normal' or (select revealing from games where id = p_game) then raise exception 'The end game has already started'; end if;
  delete from events where game_id = p_game and status = 'scheduled';
  update actions set target_id = null where event_id in (select id from events where game_id = p_game and status = 'open');
  update events set closes_at = least(closes_at, now()), reveals_at = least(reveals_at, now())
  where game_id = p_game and status in ('open', 'closed');
  perform advance_games();
  if (select status from games where id = p_game) = 'active' then perform open_final_banishment(p_game); end if;
end $$;

revoke execute on function
  advance_games(timestamptz), close_event(uuid), reveal_event(uuid), check_win(uuid),
  settle_untimed(uuid), lock_murder(uuid, boolean), open_final_banishment(uuid), begin_reveal(uuid), finish_if_revealed(uuid), do_reveal(uuid),
  internal_start_game(uuid, timestamp, jsonb, int, int)
  from public, anon, authenticated;

revoke execute on function gm_start_endgame(uuid), cast_endgame(uuid, boolean), my_endgame(uuid), reveal_my_role(uuid), gm_reveal_role(uuid), gm_reveal_all(uuid) from public, anon;
grant execute on function gm_start_endgame(uuid), cast_endgame(uuid, boolean), my_endgame(uuid), reveal_my_role(uuid), gm_reveal_role(uuid), gm_reveal_all(uuid) to authenticated;

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
  if n is null or length(n) not between 1 and 40 or n ~ '[\u0001-\u001f\u007f-\u009f\u2028\u2029]' then
    raise exception 'Name must be 1 to 40 characters, with no line breaks';
  end if;
  -- Locked while playing, so nobody can take another player's name mid-game. The GM can still fix a mistake.
  if not is_admin() and exists (select 1 from players p join games g on g.id = p.game_id
                                where p.user_id = p_user and g.status = 'active') then
    raise exception 'Names are locked while a game is running. Ask the game master.';
  end if;
  begin
    update people set display_name = n where user_id = p_user;
  exception when unique_violation then
    raise exception 'That name is already taken';
  end;
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
  -- Lock first, before touching any event row: taking it after a row lock can deadlock with advance_games.
  perform pg_advisory_xact_lock(727001);
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
                                                            'kind', a.kind, 'target', t.display_name, 'end_vote', a.end_vote)
                                        order by e.opens_at, voter.display_name)
                       from actions a join events e on e.id = a.event_id
                       join players voter on voter.id = a.player_id
                       left join players t on t.id = a.target_id
                       where e.game_id = p_game and e.status in ('open', 'closed')), '[]'),
    'offers', coalesce((select jsonb_agg(jsonb_build_object('event_id', r.event_id, 'target', t.display_name, 'accepted', r.accepted))
                        from recruit_offers r join events e on e.id = r.event_id join players t on t.id = r.target_id
                        where r.game_id = p_game and e.status in ('open', 'closed')), '[]'));
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
