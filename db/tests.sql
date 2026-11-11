-- Run in the Supabase SQL editor AFTER schema.sql and seed (run it on a scratch project, not live data).
-- Everything rolls back at the end. Any failed assertion raises an error and stops the run.
-- Last line returns 'all tests passed'.
begin;

create schema tests;
grant usage on schema tests to authenticated, anon;

create function tests.ok(p_cond boolean, p_label text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_label; end if;
end $$;

create function tests.eq(p_a anyelement, p_b anyelement, p_label text) returns void language plpgsql as $$
begin
  if p_a is distinct from p_b then raise exception 'FAIL: % (got %, expected %)', p_label, p_a, p_b; end if;
end $$;

-- p_expect matches either the SQLSTATE or a substring of the message. The call must actually fail:
-- succeeding is a test failure, not a pass.
create function tests.throws(p_sql text, p_expect text, p_label text) returns void language plpgsql as $$
declare v_raised boolean := false;
begin
  begin
    execute p_sql;
  exception when others then
    v_raised := true;
    if not (sqlstate = p_expect or sqlerrm like '%' || p_expect || '%') then
      raise exception 'FAIL: % (wrong error: % %)', p_label, sqlstate, sqlerrm;
    end if;
  end;
  if not v_raised then raise exception 'FAIL: % (no error was raised)', p_label; end if;
end $$;

create function tests.lives(p_sql text, p_label text) returns void language plpgsql as $$
begin
  execute p_sql;
exception when others then
  raise exception 'FAIL: % (%)', p_label, sqlerrm;
end $$;

create function tests.make_user(p_name text) returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, raw_user_meta_data)
  values (v, p_name || case when position('@' in p_name) > 0 then '' else '@org.test' end,
          'authenticated', 'authenticated', jsonb_build_object('full_name', p_name));
  return v;
end $$;

-- Claims lookup is security definer (authenticated can't read auth.users); set_config('role') can't be done
-- from a definer function, so act_as itself stays invoker.
create function tests.claims(p_name text) returns text language sql security definer as $$
  select json_build_object('sub', u.id, 'email', u.email, 'role', 'authenticated',
                           'user_metadata', u.raw_user_meta_data)::text
  from auth.users u
  where u.email = p_name || case when position('@' in p_name) > 0 then '' else '@org.test' end
$$;

create function tests.act_as(p_name text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', tests.claims(p_name), true);
  perform set_config('role', 'authenticated', true);
end $$;

create function tests.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'anon', true);
end $$;

create function tests.reset() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  execute 'reset role';
end $$;

create function tests.g() returns uuid language sql stable as $$
  select current_setting('t.g')::uuid
$$;

create function tests.pid(p_game uuid, p_name text) returns uuid language sql stable security definer as $$
  select id from public.players where game_id = p_game and display_name = p_name
$$;

create function tests.add_players(p_game uuid, n int) returns void language plpgsql as $$
declare u uuid; i int;
begin
  for i in 1..n loop
    u := tests.make_user('p' || i);
    insert into public.players (game_id, user_id, email, display_name, avatar_key)
    values (p_game, u, 'p' || i || '@org.test', 'p' || i, 'p' || i);
  end loop;
end $$;

-- players a..n (letters), plus gm and an outsider; game already started with no events
create function tests.uid(p_name text) returns uuid language sql stable security definer as $$
  select id from auth.users where email = p_name || '@org.test'
$$;

create function tests.add_people(n int) returns void language plpgsql as $$
declare u uuid; i int;
begin
  for i in 1..n loop
    u := tests.make_user('p' || i);
    insert into public.people (user_id, email, display_name, avatar_key) values (u, 'p' || i || '@org.test', 'p' || i, 'p' || i);
  end loop;
end $$;

create function tests.make_game(n int) returns uuid language plpgsql as $$
declare g uuid; u uuid; i int;
begin
  insert into public.app_config values ('org_domain', 'org.test')
    on conflict (key) do update set value = excluded.value;
  insert into public.admins values ('gm@org.test') on conflict do nothing;
  perform tests.make_user('gm');
  perform tests.make_user('outsider');
  insert into public.games default values returning id into g;
  for i in 1..n loop
    u := tests.make_user(chr(96 + i));
    insert into public.players (game_id, user_id, email, display_name, avatar_key)
    values (g, u, chr(96 + i) || '@org.test', chr(96 + i), chr(96 + i));
  end loop;
  perform public.internal_start_game(g, '2026-10-19'::timestamp, '[]'::jsonb, 1, 10080);
  return g;
end $$;

create function tests.set_traitors(p_game uuid, p_names text[]) returns void language sql as $$
  update public.roles r
  set role = case when p.display_name = any (p_names) then 'traitor' else 'faithful' end
  from public.players p
  where p.id = r.player_id and r.game_id = p_game
$$;

grant execute on all functions in schema tests to authenticated, anon;

-- Each section runs between a savepoint and a rollback so users/games don't leak between them.
-- The seed's admins/app_config rows are replaced inside the first section only for the test run.
delete from admins;
delete from app_config;

-------------------------------------------------------------------- 1. RLS
savepoint s1;
insert into app_config values ('org_domain', 'org.test');
select tests.make_user('c'), tests.make_user('a'), tests.make_user('d'), tests.make_user('outsider');

insert into games (id) values ('00000000-0000-0000-0000-0000000000aa');
insert into players (id, game_id, user_id, email, display_name, avatar_key)
select gen_random_uuid(), '00000000-0000-0000-0000-0000000000aa', u.id, u.email, split_part(u.email, '@', 1), split_part(u.email, '@', 1)
from auth.users u where u.email in ('a@org.test', 'c@org.test', 'd@org.test');
insert into roles (player_id, game_id, role)
select p.id, p.game_id, case p.display_name when 'a' then 'traitor' else 'faithful' end from players p;
update roles set role = 'traitor' where player_id = (select id from players where display_name = 'd');

select tests.act_as('c');
select tests.eq((select count(*) from roles), 1::bigint, 'faithful sees only own role');
select tests.act_as('a');
select tests.eq((select count(*) from roles), 2::bigint, 'traitor sees self and fellow traitor');
select tests.act_as('outsider');
select tests.eq((select count(*) from roles), 0::bigint, 'non-member sees no roles');
select tests.eq((select count(*) from players), 0::bigint, 'non-member sees no players');

select tests.reset();
update players set alive = false where display_name = 'd';
select tests.act_as('c');
select tests.eq((select count(*) from roles), 2::bigint, 'dead player role is revealed to game members');

select tests.reset();
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at, status)
values ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000aa', 'murder', now(), now(), now(), 'closed');
insert into event_results values ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000aa', (select id from players where display_name = 'c'));
insert into actions (event_id, player_id, target_id)
values ('00000000-0000-0000-0000-0000000000e1', (select id from players where display_name = 'a'), (select id from players where display_name = 'c'));
select tests.act_as('c');
select tests.eq((select count(*) from event_results), 0::bigint, 'murder result hidden until revealed');
select tests.eq((select count(*) from actions), 0::bigint, 'clients can never read actions');

select tests.reset();
update events set status = 'revealed';
select tests.act_as('c');
select tests.eq((select count(*) from event_results), 1::bigint, 'result visible once revealed');

select tests.reset();
insert into messages (game_id, player_id, body)
values ('00000000-0000-0000-0000-0000000000aa', (select id from players where display_name = 'a'), 'psst');
select tests.act_as('c');
select tests.eq((select count(*) from messages), 0::bigint, 'faithful cannot read traitors chat');
select tests.act_as('a');
select tests.eq((select count(*) from messages), 1::bigint, 'traitor reads traitors chat');
select tests.reset();
rollback to savepoint s1;

-------------------------------------------------------------------- 2. GM selects players / start
savepoint s2;
insert into admins values ('gm@org.test');
select tests.make_user('gm'), tests.make_user('a');
-- people p1..p6 registered; 'a' is a plain registered account
select tests.add_people(6);

select tests.act_as('a');
select tests.throws($$select create_game()$$, 'admin only', 'non-admin cannot create a game');

select tests.act_as('gm');
select set_config('t.g', create_game()::text, false);
select tests.ok(tests.g() is not null, 'GM creates a game');
select tests.eq((gm_overview(tests.g()) -> 'people' -> 0 ->> 'in_game')::boolean, false, 'people start unselected');

select tests.act_as('a');
select tests.throws(format($$select gm_set_player(%L, %L, true)$$, tests.g(), tests.uid('p1')), 'admin only', 'non-admin cannot select players');

select tests.act_as('gm');
select tests.lives(format($$select gm_set_player(%L, %L, true)$$, tests.g(), tests.uid('p1')), 'GM selects a player');
select tests.lives(format($$select gm_set_player(%L, %L, true)$$, tests.g(), tests.uid('p1')), 'selecting twice is harmless');
select tests.eq((gm_overview(tests.g()) ->> 'players')::int, 1, 'one player selected');
select tests.lives(format($$select gm_set_player(%L, %L, false)$$, tests.g(), tests.uid('p1')), 'GM deselects a player');
select tests.eq((gm_overview(tests.g()) ->> 'players')::int, 0, 'player removed');

-- 5 selected: too few
select tests.lives(format($$select gm_set_player(%L, %L, true)$$, tests.g(), tests.uid('p' || i)), 'select p' || i) from generate_series(1, 5) i;
select tests.throws(format($$select start_game(%L, '2026-10-19')$$, tests.g()), 'need at least 6 players', 'start needs 6 players');
select tests.act_as('a');
select tests.throws(format($$select start_game(%L, '2026-10-19')$$, tests.g()), 'admin only', 'non-admin cannot start');

select tests.act_as('gm');
select gm_set_player(tests.g(), tests.uid('p6'), true);
select start_game(tests.g(), '2026-10-19');
select tests.reset();
select tests.eq((select count(*) from roles where game_id = tests.g() and role = 'traitor'), 2::bigint, '6 players -> 2 traitors');
select tests.eq((select count(*) from events where game_id = tests.g()), 48::bigint, '12 weeks x 4 events');
select tests.eq((select opens_at from events where game_id = tests.g() and kind = 'banishment' order by opens_at limit 1),
                '2026-10-19 09:00:00+01'::timestamptz, 'first banishment opens Mon 09:00 London');
select tests.eq((select closes_at from events where game_id = tests.g() and kind = 'murder' order by opens_at limit 1),
                '2026-10-21 09:00:00+01'::timestamptz, 'murder 1 closes Wed 09:00');
select tests.eq((select count(*) from events where game_id = tests.g() and extract(isodow from opens_at at time zone 'Europe/London') > 4), 0::bigint, 'nothing opens Fri-Sun');
select tests.act_as('gm');
select tests.throws(format($$select gm_set_player(%L, %L, false)$$, tests.g(), tests.uid('p1')), 'game not in lobby', 'cannot change players once started');
select tests.reset();
rollback to savepoint s2;

-------------------------------------------------------------------- 2b. no upper limit on players
savepoint s2b;
insert into admins values ('gm@org.test');
select tests.make_user('gm');
select tests.add_people(30);
select tests.act_as('gm');
select set_config('t.g', create_game()::text, false);
-- new people may join at any time, so there is no cap: thirty players all go in
select tests.lives(format($$select gm_set_player(%L, %L, true)$$, tests.g(), tests.uid('p' || i)), 'select p' || i) from generate_series(1, 30) i;
select tests.reset();
select internal_start_game(tests.g(), '2026-10-19'::timestamp, '[]'::jsonb, 1, 10080);
select tests.eq((select count(*) from roles where game_id = tests.g() and role = 'traitor'), 3::bigint, '30 players, none chosen -> still 3 random traitors');
select tests.eq((select count(*) from players where game_id = tests.g()), 30::bigint, 'all thirty are in the game');
rollback to savepoint s2b;

-------------------------------------------------------------------- 3. actions
savepoint s3;
select set_config('t.g', tests.make_game(8)::text, false);
select tests.set_traitors(tests.g(), '{a,b}');
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at, status) values
  ('00000000-0000-0000-0000-0000000000b1', tests.g(), 'banishment', now() - interval '1 hour', now() + interval '1 hour', now() + interval '1 hour', 'open'),
  ('00000000-0000-0000-0000-0000000000b2', tests.g(), 'murder', now() - interval '1 hour', now() + interval '1 hour', now() + interval '2 hours', 'open'),
  ('00000000-0000-0000-0000-0000000000b3', tests.g(), 'banishment', now() - interval '2 hours', now() - interval '1 hour', now() - interval '1 hour', 'closed');
update players set alive = false where display_name = 'h';

select tests.act_as('c');
select tests.lives(format($$select cast_vote('00000000-0000-0000-0000-0000000000b1', %L)$$, tests.pid(tests.g(), 'd')), 'alive player votes');
select tests.lives(format($$select cast_vote('00000000-0000-0000-0000-0000000000b1', %L)$$, tests.pid(tests.g(), 'e')), 'vote can be changed');
select tests.eq((select target_id from my_pick('00000000-0000-0000-0000-0000000000b1')), tests.pid(tests.g(), 'e'), 'my_pick returns latest vote');
select tests.throws(format($$select cast_vote('00000000-0000-0000-0000-0000000000b1', %L)$$, tests.pid(tests.g(), 'c')), 'invalid target', 'cannot vote for self');
select tests.throws(format($$select cast_vote('00000000-0000-0000-0000-0000000000b1', %L)$$, tests.pid(tests.g(), 'h')), 'invalid target', 'cannot vote for dead player');
select tests.throws(format($$select cast_vote('00000000-0000-0000-0000-0000000000b3', %L)$$, tests.pid(tests.g(), 'd')), 'event not open', 'cannot vote in closed event');
select tests.throws(format($$select cast_vote('00000000-0000-0000-0000-0000000000b2', %L)$$, tests.pid(tests.g(), 'd')), 'event not open', 'cast_vote rejects murder events');
select tests.act_as('h');
select tests.throws(format($$select cast_vote('00000000-0000-0000-0000-0000000000b1', %L)$$, tests.pid(tests.g(), 'd')), 'not allowed', 'dead player cannot vote');
select tests.act_as('outsider');
select tests.throws(format($$select cast_vote('00000000-0000-0000-0000-0000000000b1', %L)$$, tests.pid(tests.g(), 'd')), 'not allowed', 'non-member cannot vote');

select tests.act_as('c');
select tests.throws(format($$select pick_victim('00000000-0000-0000-0000-0000000000b2', %L)$$, tests.pid(tests.g(), 'd')), 'not allowed', 'faithful cannot pick a victim');
select tests.act_as('a');
select tests.lives(format($$select pick_victim('00000000-0000-0000-0000-0000000000b2', %L)$$, tests.pid(tests.g(), 'd')), 'traitor picks a faithful victim');
select tests.throws(format($$select pick_victim('00000000-0000-0000-0000-0000000000b2', %L)$$, tests.pid(tests.g(), 'b')), 'invalid target', 'traitor cannot target a traitor');
select tests.eq((select count(*) from team_picks('00000000-0000-0000-0000-0000000000b2')), 1::bigint, 'traitor sees traitor picks');

select tests.lives(format($$select post_message(%L, 'hello')$$, tests.g()), 'traitor posts');
select tests.act_as('c');
select tests.throws(format($$select post_message(%L, 'hi')$$, tests.g()), 'not allowed', 'faithful cannot post');
select tests.act_as('b');
select tests.throws(format($$select post_message(%L, '   ')$$, tests.g()), '23514', 'blank message rejected');
select tests.reset();
rollback to savepoint s3;

-------------------------------------------------------------------- 4. resolution
savepoint s4;
select set_config('t.g', tests.make_game(8)::text, false);
select tests.set_traitors(tests.g(), '{a,b}');
create temp table ev (name text primary key, id uuid);

create function pg_temp.mk(p_name text, p_kind text, p_open timestamptz, p_close timestamptz, p_reveal timestamptz) returns void language plpgsql as $$
declare v uuid;
begin
  insert into events (game_id, kind, opens_at, closes_at, reveals_at)
  values (tests.g(), p_kind, p_open, p_close, p_reveal) returning id into v;
  insert into ev values (p_name, v);
end $$;
create function pg_temp.act(p_event text, p_by text, p_target text) returns void language sql as $$
  insert into actions (event_id, player_id, target_id)
  values ((select id from ev where name = p_event), tests.pid(tests.g(), p_by),
          case when p_target is null then null else tests.pid(tests.g(), p_target) end)
$$;
create function pg_temp.alive(p_name text) returns boolean language sql as $$
  select alive from players where id = tests.pid(tests.g(), p_name)
$$;

-- plain majority banishment
select pg_temp.mk('b1', 'banishment', '2026-10-19 09:00+01', '2026-10-20 15:00+01', '2026-10-20 15:00+01');
select pg_temp.act('b1', 'c', 'f'); select pg_temp.act('b1', 'd', 'f'); select pg_temp.act('b1', 'e', 'g');
select advance_games('2026-10-20 15:01+01');
select tests.eq(pg_temp.alive('f'), false, 'majority target is banished');
select tests.eq((select status from events where id = (select id from ev where name = 'b1')), 'revealed', 'banishment closed and revealed together');

-- no votes: nobody dies
select pg_temp.mk('b2', 'banishment', '2026-10-21 09:00+01', '2026-10-22 15:00+01', '2026-10-22 15:00+01');
select advance_games('2026-10-22 15:01+01');
select tests.eq((select count(*) from players where game_id = tests.g() and not alive), 1::bigint, 'no votes -> nobody banished');

-- tie: exactly one of the tied dies
select pg_temp.mk('b3', 'banishment', '2026-10-23 09:00+01', '2026-10-24 15:00+01', '2026-10-24 15:00+01');
select pg_temp.act('b3', 'c', 'g'); select pg_temp.act('b3', 'd', 'h');
select advance_games('2026-10-24 15:01+01');
select tests.eq((select count(*) from players where game_id = tests.g() and not alive and display_name in ('g', 'h')), 1::bigint, 'tie -> exactly one tied player banished');

-- murder: victim alive after close, dead after reveal
update players set alive = true where game_id = tests.g();
select pg_temp.mk('m1', 'murder', '2026-10-27 15:00+01', '2026-10-29 00:00+01', '2026-10-29 09:00+01');
select pg_temp.act('m1', 'a', 'c'); select pg_temp.act('m1', 'b', 'c');
select advance_games('2026-10-29 00:01+01');
select tests.eq(pg_temp.alive('c'), true, 'murder victim still alive between close and reveal');
select tests.eq((select count(*) from event_results where event_id = (select id from ev where name = 'm1') and target_id is not null), 1::bigint, 'victim chosen at close');
select advance_games('2026-10-29 09:01+01');
select tests.eq(pg_temp.alive('c'), false, 'murder victim dead at reveal');

-- no traitor picks: nobody dies
select pg_temp.mk('m2', 'murder', '2026-11-03 15:00+00', '2026-11-05 00:00+00', '2026-11-05 09:00+00');
select advance_games('2026-11-05 09:01+00');
select tests.eq((select count(*) from players where game_id = tests.g() and not alive), 1::bigint, 'no murder pick -> nobody dies');

-- dead voters are discarded (d, e dead with 2 votes for f; alive h votes g -> g, not f)
update players set alive = true where game_id = tests.g();
select pg_temp.mk('b4', 'banishment', '2026-11-06 09:00+00', '2026-11-07 15:00+00', '2026-11-07 15:00+00');
select pg_temp.act('b4', 'd', 'f'); select pg_temp.act('b4', 'e', 'f'); select pg_temp.act('b4', 'h', 'g');
update players set alive = false where display_name in ('d', 'e') and game_id = tests.g();
-- Only 6 are alive, which would make this the final banishment; this test is about the normal path.
update games set phase = 'final' where id = tests.g();
select advance_games('2026-11-07 15:01+00');
update games set phase = 'normal' where id = tests.g();
select tests.eq(pg_temp.alive('g'), false, 'votes from dead players are discarded');

-- both traitors out -> faithful win
update players set alive = true where game_id = tests.g();
select pg_temp.mk('b5', 'banishment', '2026-11-10 09:00+00', '2026-11-11 15:00+00', '2026-11-11 15:00+00');
update players set alive = false where display_name = 'a' and game_id = tests.g();
select pg_temp.act('b5', 'c', 'b'); select pg_temp.act('b5', 'd', 'b');
select advance_games('2026-11-11 15:01+00');
select tests.eq((select status from games where id = tests.g()), 'active', 'all traitors out does not end the game by itself');
-- ...but it ends at 2 left, and with no traitor among them the faithful win.
update players set alive = false where id in (select id from players where game_id = tests.g() and alive order by display_name offset 2);
select check_win(tests.g());
select tests.eq((select revealing from games where id = tests.g()), true, '2 left starts the reveal stage');
select tests.eq((select winner from games where id = tests.g()), null, 'nobody has won until the roles are shown');
select do_reveal(id) from players where game_id = tests.g() and alive;
select tests.eq((select winner from games where id = tests.g()), 'faithful', '2 left and no traitor -> faithful win');

-- traitors equal faithful -> traitors win
update games set status = 'active', winner = null, revealing = false where id = tests.g();
update players set alive = true, revealed = false where game_id = tests.g();
update players set alive = false where display_name in ('c', 'd', 'e', 'f', 'h') and game_id = tests.g();
select pg_temp.mk('b6', 'banishment', '2026-11-12 09:00+00', '2026-11-13 15:00+00', '2026-11-13 15:00+00');
select pg_temp.act('b6', 'a', 'g');
-- Few alive would make this the final banishment; this test is about the normal path.
update games set phase = 'final' where id = tests.g();
select advance_games('2026-11-13 15:01+00');
select do_reveal(id) from players where game_id = tests.g() and alive;
select tests.eq((select winner from games where id = tests.g()), 'traitors', '2 left with a traitor among them -> traitors win');
rollback to savepoint s4;

-------------------------------------------------------------------- 4b. votes for a player who was murdered meanwhile
savepoint s4b;
select set_config('t.g', tests.make_game(8)::text, false);
select tests.set_traitors(tests.g(), '{a,b}');
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at) values
  ('00000000-0000-0000-0000-0000000000f9', tests.g(), 'banishment', now() - interval '3 hours', now() + interval '1 hour', now() + interval '1 hour');
insert into actions (event_id, player_id, target_id) values
  ('00000000-0000-0000-0000-0000000000f9', tests.pid(tests.g(), 'c'), tests.pid(tests.g(), 'f')),
  ('00000000-0000-0000-0000-0000000000f9', tests.pid(tests.g(), 'd'), tests.pid(tests.g(), 'f')),
  ('00000000-0000-0000-0000-0000000000f9', tests.pid(tests.g(), 'e'), tests.pid(tests.g(), 'g'));
-- f (the front-runner) is murdered before the vote closes. Current rule: their votes are dropped and
-- the next-most-voted player is banished. Change this test deliberately if that rule changes.
update players set alive = false where id = tests.pid(tests.g(), 'f');
select advance_games(now() + interval '2 hours');
select tests.eq((select alive from players where id = tests.pid(tests.g(), 'g')), false, 'runner-up is banished when the front-runner was murdered');
select tests.eq((select count(*) from players where game_id = tests.g() and not alive), 2::bigint, 'only the victim and the runner-up are out');
rollback to savepoint s4b;

-------------------------------------------------------------------- 6. recruitment
savepoint s6;
select set_config('t.g', tests.make_game(8)::text, false);
select tests.set_traitors(tests.g(), '{a,b}');
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at, status) values
  ('00000000-0000-0000-0000-0000000000d1', tests.g(), 'murder', now() - interval '1 hour', now() + interval '1 hour', now() + interval '5 hours', 'open');

select tests.act_as('c');
select tests.throws(format($$select pick_recruit('00000000-0000-0000-0000-0000000000d1', %L)$$, tests.pid(tests.g(), 'd')), 'not allowed', 'faithful cannot recruit');
select tests.act_as('a');
select tests.throws(format($$select pick_recruit('00000000-0000-0000-0000-0000000000d1', %L)$$, tests.pid(tests.g(), 'b')), 'invalid target', 'cannot recruit a traitor');
select tests.lives(format($$select pick_recruit('00000000-0000-0000-0000-0000000000d1', %L)$$, tests.pid(tests.g(), 'c')), 'traitor picks a recruit');
select tests.eq((select kind from my_pick('00000000-0000-0000-0000-0000000000d1')), 'recruit', 'pick is recorded as a recruit');
select tests.act_as('b');
select tests.lives(format($$select pick_recruit('00000000-0000-0000-0000-0000000000d1', %L)$$, tests.pid(tests.g(), 'c')), 'second traitor agrees');
select tests.reset();

-- window closes: offer exists for c only, nobody has died, no reveal yet
select advance_games(now() + interval '2 hours');
select tests.eq((select kind from event_results where event_id = '00000000-0000-0000-0000-0000000000d1'), 'recruit', 'closed as a recruit offer');
select tests.eq((select count(*) from players where game_id = tests.g() and not alive), 0::bigint, 'recruit round kills nobody');
select tests.act_as('c');
select tests.ok(my_offer(tests.g()) is not null, 'target sees the offer');
select tests.act_as('d');
select tests.ok(my_offer(tests.g()) is null, 'others see no offer');
select tests.throws($$select respond_recruit('00000000-0000-0000-0000-0000000000d1', true)$$, 'no offer', 'non-target cannot answer');
select tests.act_as('c');
select tests.lives($$select respond_recruit('00000000-0000-0000-0000-0000000000d1', true)$$, 'target accepts');
select tests.throws($$select respond_recruit('00000000-0000-0000-0000-0000000000d1', false)$$, 'no offer', 'answer cannot be changed');
select tests.reset();

-- reveal: c is now a traitor, nobody died, and non-traitors cannot see the result
select advance_games(now() + interval '6 hours');
select tests.eq((select role from roles where player_id = tests.pid(tests.g(), 'c')), 'traitor', 'accepted recruit becomes a traitor');
select tests.eq((select count(*) from players where game_id = tests.g() and not alive), 0::bigint, 'still nobody dead');
select tests.act_as('d');
select tests.eq((select count(*) from event_results), 0::bigint, 'faithful cannot see a recruit result');
select tests.act_as('a');
select tests.eq((select count(*) from event_results), 1::bigint, 'traitors can see it');
select tests.act_as('c');
select tests.eq((select count(*) from roles), 3::bigint, 'recruit now sees both fellow traitors and self');
select tests.reset();
rollback to savepoint s6;

-------------------------------------------------------------------- 6b. refusal, silence, limit
savepoint s6b;
select set_config('t.g', tests.make_game(8)::text, false);
select tests.set_traitors(tests.g(), '{a,b}');
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at, status) values
  ('00000000-0000-0000-0000-0000000000d2', tests.g(), 'murder', now() - interval '1 hour', now() + interval '1 hour', now() + interval '5 hours', 'open');
select tests.act_as('a');
select pick_recruit('00000000-0000-0000-0000-0000000000d2', tests.pid(tests.g(), 'c'));
select tests.reset();
select advance_games(now() + interval '2 hours');
select tests.act_as('c');
select respond_recruit('00000000-0000-0000-0000-0000000000d2', false);
select tests.reset();
select advance_games(now() + interval '6 hours');
select tests.eq((select role from roles where player_id = tests.pid(tests.g(), 'c')), 'faithful', 'refusal leaves them faithful');
select tests.eq((select count(*) from players where game_id = tests.g() and not alive), 0::bigint, 'refusal kills nobody');
rollback to savepoint s6b;

savepoint s6c;
select set_config('t.g', tests.make_game(8)::text, false);
select tests.set_traitors(tests.g(), '{a,b}');
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at, status) values
  ('00000000-0000-0000-0000-0000000000d3', tests.g(), 'murder', now() - interval '1 hour', now() + interval '1 hour', now() + interval '5 hours', 'open');
select tests.act_as('a');
select pick_recruit('00000000-0000-0000-0000-0000000000d3', tests.pid(tests.g(), 'c'));
select tests.reset();
select advance_games(now() + interval '2 hours');
select advance_games(now() + interval '6 hours');
select tests.eq((select role from roles where player_id = tests.pid(tests.g(), 'c')), 'faithful', 'no answer counts as a refusal');
rollback to savepoint s6c;

savepoint s6d;
select set_config('t.g', tests.make_game(8)::text, false);
select tests.set_traitors(tests.g(), '{a,b,c}');
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at, status) values
  ('00000000-0000-0000-0000-0000000000d4', tests.g(), 'murder', now() - interval '1 hour', now() + interval '1 hour', now() + interval '5 hours', 'open');
select tests.act_as('a');
select tests.throws(format($$select pick_recruit('00000000-0000-0000-0000-0000000000d4', %L)$$, tests.pid(tests.g(), 'd')), 'recruitment not available', 'no recruiting with 3 traitors');
select tests.reset();
rollback to savepoint s6d;

-------------------------------------------------------------------- 7. slack announcements
savepoint s7;
select set_config('t.g', tests.make_game(8)::text, false);
select tests.act_as('a');
select tests.throws($$select gm_set_slack('https://hooks.slack.com/services/T0/B0/X')$$, 'admin only', 'non-GM cannot set the webhook');
select tests.throws($$select gm_slack_test()$$, 'admin only', 'non-GM cannot send a test');
select tests.throws($$select slack_post('hi')$$, '42501', 'clients cannot call slack_post directly');
select tests.act_as('gm');
select tests.throws($$select gm_set_slack('https://evil.example.com/hook')$$, 'not a Slack webhook', 'rejects non-Slack URLs');
select tests.throws($$select gm_slack_test()$$, 'No Slack webhook', 'test needs a webhook first');
select tests.lives($$select gm_set_slack('https://hooks.slack.com/services/T0/B0/X')$$, 'accepts a Slack URL');
select tests.eq((gm_overview(tests.g()) ->> 'slack_on')::boolean, true, 'overview reports Slack connected');
select tests.reset();
-- Slack being unreachable (here pg_net may not even exist) must not stop a round from resolving.
insert into events (game_id, kind, opens_at, closes_at, reveals_at) values (tests.g(), 'banishment', now() - interval '3 hours', now() - interval '1 hour', now() - interval '1 hour');
select advance_games(now());
select tests.eq((select status from events where game_id = tests.g()), 'revealed', 'round resolves even if Slack fails');
select tests.act_as('gm');
select tests.lives($$select gm_set_slack('')$$, 'GM can disconnect');
select tests.eq((gm_overview(tests.g()) ->> 'slack_on')::boolean, false, 'overview reports disconnected');
select tests.reset();
rollback to savepoint s7;

-------------------------------------------------------------------- 8. GM dashboard
savepoint s8;
select set_config('t.g', tests.make_game(8)::text, false);
select tests.set_traitors(tests.g(), '{a,b}');
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at, status) values
  ('00000000-0000-0000-0000-0000000000e8', tests.g(), 'banishment', now() - interval '1 hour', now() + interval '5 hours', now() + interval '5 hours', 'open'),
  ('00000000-0000-0000-0000-0000000000e9', tests.g(), 'murder', now() - interval '1 hour', now() + interval '5 hours', now() + interval '9 hours', 'open');
insert into actions (event_id, player_id, target_id) values
  ('00000000-0000-0000-0000-0000000000e8', tests.pid(tests.g(), 'c'), tests.pid(tests.g(), 'd')),
  ('00000000-0000-0000-0000-0000000000e8', tests.pid(tests.g(), 'd'), tests.pid(tests.g(), 'c'));
insert into actions (event_id, player_id, target_id, kind) values
  ('00000000-0000-0000-0000-0000000000e9', tests.pid(tests.g(), 'a'), tests.pid(tests.g(), 'c'), 'recruit');

select tests.act_as('a');
select tests.throws(format($$select gm_dashboard(%L)$$, tests.g()), 'admin only', 'non-GM cannot read the dashboard');
select tests.act_as('gm');
select set_config('t.d', gm_dashboard(tests.g())::text, false);
select tests.reset();
select tests.eq((current_setting('t.d')::jsonb -> 'events' -> 0 ->> 'voters')::int, 8, 'eight players can vote');
select tests.eq((current_setting('t.d')::jsonb -> 'events' -> 0 ->> 'voted')::int, 2, 'two have voted');
select tests.eq(jsonb_array_length(current_setting('t.d')::jsonb -> 'events' -> 0 -> 'not_voted'), 6, 'six still to vote');
select tests.ok(not (current_setting('t.d')::jsonb -> 'events' -> 0 -> 'not_voted') ? 'c', 'a player who voted is not listed as outstanding');
select tests.eq((current_setting('t.d')::jsonb -> 'events' -> 1 ->> 'traitors')::int, 2, 'two traitors alive');
select tests.eq((current_setting('t.d')::jsonb -> 'events' -> 1 ->> 'picked')::int, 1, 'one traitor has chosen');
-- Secrecy: the dashboard must not reveal what was chosen, who the traitors are, or that a pick is a recruit.
select tests.ok(current_setting('t.d') !~ 'recruit', 'dashboard never says recruit');
select tests.ok(current_setting('t.d') !~ 'target', 'dashboard never includes targets');
select tests.ok(current_setting('t.d') !~ 'role', 'dashboard carries no role information');
select tests.ok((current_setting('t.d')::jsonb -> 'events' -> 0 -> 'not_voted') ? 'a' and (current_setting('t.d')::jsonb -> 'events' -> 0 -> 'not_voted') ? 'e', 'non-voters are listed whatever their role');
rollback to savepoint s8;

-------------------------------------------------------------------- 9. GM controls: shift, skip, remind, extend
savepoint s9;
select set_config('t.g', tests.make_game(8)::text, false);
select tests.set_traitors(tests.g(), '{a,b}');
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at, status) values
  ('00000000-0000-0000-0000-0000000000a1', tests.g(), 'banishment', now() - interval '1 hour', now() + interval '5 hours', now() + interval '5 hours', 'open'),
  ('00000000-0000-0000-0000-0000000000a2', tests.g(), 'murder', now() + interval '5 hours', now() + interval '20 hours', now() + interval '30 hours', 'scheduled'),
  ('00000000-0000-0000-0000-0000000000a3', tests.g(), 'murder', now() - interval '20 hours', now() - interval '10 hours', now() + interval '2 hours', 'closed'),
  ('00000000-0000-0000-0000-0000000000a4', tests.g(), 'banishment', now() - interval '90 hours', now() - interval '80 hours', now() - interval '80 hours', 'revealed');
create temp table before_times as select id, opens_at, closes_at, reveals_at from events where game_id = tests.g();

select tests.act_as('a');
select tests.throws(format($$select gm_shift_game(%L, '1 day')$$, tests.g()), 'admin only', 'non-GM cannot delay the game');
select tests.throws($$select gm_skip_event('00000000-0000-0000-0000-0000000000a1')$$, 'admin only', 'non-GM cannot skip');
select tests.throws($$select gm_remind('00000000-0000-0000-0000-0000000000a1')$$, 'admin only', 'non-GM cannot remind');
select tests.act_as('gm');
select tests.throws(format($$select gm_shift_game(%L, '30 days')$$, tests.g()), 'between 0 and 14', 'delay is capped');
select tests.throws(format($$select gm_shift_game(%L, '-1 day')$$, tests.g()), 'between 0 and 14', 'delay cannot go backwards');
select tests.lives(format($$select gm_shift_game(%L, '1 day')$$, tests.g()), 'GM delays the game a day');
select tests.reset();
select tests.eq((select e.closes_at - b.closes_at from events e join before_times b using (id) where e.id = '00000000-0000-0000-0000-0000000000a1'), interval '1 day', 'open window closes a day later');
select tests.eq((select e.opens_at = b.opens_at from events e join before_times b using (id) where e.id = '00000000-0000-0000-0000-0000000000a1'), true, 'open window keeps its start');
select tests.eq((select e.opens_at - b.opens_at from events e join before_times b using (id) where e.id = '00000000-0000-0000-0000-0000000000a2'), interval '1 day', 'scheduled window starts a day later');
select tests.eq((select e.reveals_at - b.reveals_at from events e join before_times b using (id) where e.id = '00000000-0000-0000-0000-0000000000a3'), interval '1 day', 'closed window reveals a day later');
select tests.eq((select e.closes_at = b.closes_at and e.reveals_at = b.reveals_at from events e join before_times b using (id) where e.id = '00000000-0000-0000-0000-0000000000a4'), true, 'finished events are untouched');

-- extend: both a day and six hours work
select tests.act_as('gm');
select tests.lives($$select gm_extend_event('00000000-0000-0000-0000-0000000000a1', '6 hours')$$, 'GM extends by six hours');
select tests.reset();

-- remind: needs Slack, needs someone outstanding, only for open banishments
select tests.act_as('gm');
select tests.throws($$select gm_remind('00000000-0000-0000-0000-0000000000a1')$$, 'No Slack webhook', 'reminder needs Slack connected');
select gm_set_slack('https://hooks.slack.com/services/T0/B0/X');
select tests.throws($$select gm_remind('00000000-0000-0000-0000-0000000000a2')$$, 'open banishment', 'cannot remind about a murder window');
select tests.lives($$select gm_remind('00000000-0000-0000-0000-0000000000a1')$$, 'reminder posts (and never fails the game if Slack is down)');
select tests.reset();
insert into actions (event_id, player_id, target_id)
  select '00000000-0000-0000-0000-0000000000a1', p.id, tests.pid(tests.g(), 'a') from players p where p.game_id = tests.g() and p.display_name <> 'a';
insert into actions (event_id, player_id, target_id) values ('00000000-0000-0000-0000-0000000000a1', tests.pid(tests.g(), 'a'), tests.pid(tests.g(), 'b'));
select tests.act_as('gm');
select tests.throws($$select gm_remind('00000000-0000-0000-0000-0000000000a1')$$, 'Everyone has already voted', 'no reminder once everyone has voted');

-- skip: discards all picks, closes now, nobody is banished
select tests.lives($$select gm_skip_event('00000000-0000-0000-0000-0000000000a1')$$, 'GM skips the vote');
select tests.reset();
select tests.eq((select count(*) from actions where event_id = '00000000-0000-0000-0000-0000000000a1' and target_id is not null), 0::bigint, 'skipped event has no live picks left');
select tests.eq((select status from events where id = '00000000-0000-0000-0000-0000000000a1'), 'revealed', 'skipped event is resolved');
select tests.eq((select count(*) from players where game_id = tests.g() and not alive), 0::bigint, 'skipping banishes nobody');
select tests.act_as('gm');
select tests.throws($$select gm_skip_event('00000000-0000-0000-0000-0000000000a1')$$, 'open event', 'cannot skip an event that is already resolved');
select tests.reset();
rollback to savepoint s9;

-------------------------------------------------------------------- 10. GM behind the curtain
savepoint s10;
select set_config('t.g', tests.make_game(8)::text, false);
select tests.set_traitors(tests.g(), '{a,b}');
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at, status) values
  ('00000000-0000-0000-0000-0000000000b8', tests.g(), 'banishment', now() - interval '1 hour', now() + interval '5 hours', now() + interval '5 hours', 'open'),
  ('00000000-0000-0000-0000-0000000000b9', tests.g(), 'murder', now() - interval '1 hour', now() + interval '5 hours', now() + interval '9 hours', 'open');
insert into actions (event_id, player_id, target_id) values
  ('00000000-0000-0000-0000-0000000000b8', tests.pid(tests.g(), 'c'), tests.pid(tests.g(), 'd'));
insert into actions (event_id, player_id, target_id, kind) values
  ('00000000-0000-0000-0000-0000000000b9', tests.pid(tests.g(), 'a'), tests.pid(tests.g(), 'e'), 'recruit');
insert into messages (game_id, player_id, body) values (tests.g(), tests.pid(tests.g(), 'a'), 'a traitor speaking');

select tests.act_as('c');
select tests.throws(format($$select gm_secrets(%L)$$, tests.g()), 'admin only', 'players cannot read the secrets');
select tests.throws(format($$select gm_chat(%L)$$, tests.g()), 'admin only', 'players cannot read the chat through the GM function');
select tests.throws(format($$select gm_post_message(%L, 'hi')$$, tests.g()), 'admin only', 'players cannot post as the GM');
select tests.act_as('gm');
select set_config('t.s', gm_secrets(tests.g())::text, false);
select set_config('t.c', gm_chat(tests.g())::text, false);
select tests.reset();
select tests.eq((select count(*) from jsonb_array_elements(current_setting('t.s')::jsonb -> 'players') x where x ->> 'role' = 'traitor'), 2::bigint, 'GM sees both traitors');
select tests.ok((select bool_or(x ->> 'kind' = 'recruit' and x ->> 'target' = 'e' and x ->> 'who' = 'a') from jsonb_array_elements(current_setting('t.s')::jsonb -> 'picks') x), 'GM sees who picked whom, including a recruit');
select tests.ok((select bool_or(x ->> 'event_kind' = 'banishment' and x ->> 'who' = 'c' and x ->> 'target' = 'd') from jsonb_array_elements(current_setting('t.s')::jsonb -> 'picks') x), 'GM sees how people voted');
select tests.eq(current_setting('t.c')::jsonb -> 0 ->> 'body', 'a traitor speaking', 'GM can read the traitors chat');

-- the GM speaks in the chat: traitors see it, faithful do not, blanks and idle games are refused
select tests.act_as('gm');
select tests.lives(format($$select gm_post_message(%L, '  Welcome, traitors.  ')$$, tests.g()), 'GM posts to the traitors');
select tests.throws(format($$select gm_post_message(%L, '   ')$$, tests.g()), 'empty', 'blank GM message refused');
select tests.reset();
select tests.act_as('a');
select tests.eq((select count(*) from messages where from_gm), 1::bigint, 'a traitor sees the GM message');
select tests.eq((select body from messages where from_gm), 'Welcome, traitors.', 'GM message is trimmed');
select tests.act_as('c');
select tests.eq((select count(*) from messages), 0::bigint, 'faithful still see no chat, GM messages included');
select tests.reset();
update games set status = 'lobby' where id = tests.g();
select tests.act_as('gm');
select tests.throws(format($$select gm_post_message(%L, 'hello')$$, tests.g()), 'not running', 'GM cannot post unless the game is running');
select tests.reset();
rollback to savepoint s10;

-------------------------------------------------------------------- 11. public vote breakdown
savepoint s11;
select set_config('t.g', tests.make_game(8)::text, false);
create temp table ev (name text primary key, id uuid);
create function pg_temp.mkb(p_name text) returns void language plpgsql as $$
declare v uuid;
begin
  insert into events (game_id, kind, opens_at, closes_at, reveals_at, status)
  values (tests.g(), 'banishment', now() - interval '3 hours' - (select count(*) from ev) * interval '1 minute', now() - interval '1 hour', now() - interval '1 hour', 'closed') returning id into v;
  insert into ev values (p_name, v);
end $$;
create function pg_temp.vote(p_event text, p_by text, p_target text) returns void language sql as $$
  insert into actions (event_id, player_id, target_id)
  values ((select id from ev where name = p_event), tests.pid(tests.g(), p_by), case when p_target is null then null else tests.pid(tests.g(), p_target) end)
$$;
create function pg_temp.bd(p_event text) returns text language sql as $$
  select vote_breakdown((select id from ev where name = p_event))
$$;

-- a clear winner: grouped by target, biggest first, with who did not vote
select pg_temp.mkb('x');
select pg_temp.vote('x', 'a', 'f'); select pg_temp.vote('x', 'b', 'f'); select pg_temp.vote('x', 'c', 'f'); select pg_temp.vote('x', 'd', 'g');
select tests.eq(pg_temp.bd('x'), E'Votes:\n• f: 3 (a, b, c)\n• g: 1 (d)\nDid not vote: e, f, g, h.', 'breakdown groups votes by target and lists non-voters');

-- a tie is called out
select pg_temp.mkb('t');
select pg_temp.vote('t', 'a', 'f'); select pg_temp.vote('t', 'b', 'g');
select tests.ok(pg_temp.bd('t') like '%Tie on 1 vote between f and g, decided at random.%', 'a tie is announced as random');
select tests.ok(pg_temp.bd('x') not like '%Tie%', 'no tie line when there is a clear winner');

-- nothing counted means nothing announced
select pg_temp.mkb('n');
select tests.eq(pg_temp.bd('n'), null::text, 'no votes, no breakdown');
select pg_temp.mkb('s');
select pg_temp.vote('s', 'a', null); select pg_temp.vote('s', 'b', null);
select tests.eq(pg_temp.bd('s'), null::text, 'a skipped round (blanked picks) announces no votes');

-- votes that did not count are left out: from a dead voter, for a dead target
select pg_temp.mkb('d');
select pg_temp.vote('d', 'a', 'f'); select pg_temp.vote('d', 'b', 'g'); select pg_temp.vote('d', 'c', 'g');
update players set alive = false where id = tests.pid(tests.g(), 'a');
update players set alive = false where id = tests.pid(tests.g(), 'g');
select tests.eq(pg_temp.bd('d'), null::text, 'votes from the dead and for the dead are not shown');

-- clients can never call it
select set_config('t.evx', (select id::text from ev where name = 'x'), false);
select tests.act_as('c');
select tests.throws(format($$select vote_breakdown(%L)$$, current_setting('t.evx')), '42501', 'players cannot call vote_breakdown');
select tests.reset();

rollback to savepoint s11;

-- a real reveal saves the breakdown with the result, readable by members only once revealed
savepoint s11b;
select set_config('t.g', tests.make_game(8)::text, false);
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at, status) values
  ('00000000-0000-0000-0000-0000000000d7', tests.g(), 'banishment', now() - interval '5 hours', now() + interval '1 hour', now() + interval '1 hour', 'open');
insert into actions (event_id, player_id, target_id) values
  ('00000000-0000-0000-0000-0000000000d7', tests.pid(tests.g(), 'c'), tests.pid(tests.g(), 'f')),
  ('00000000-0000-0000-0000-0000000000d7', tests.pid(tests.g(), 'd'), tests.pid(tests.g(), 'f')),
  ('00000000-0000-0000-0000-0000000000d7', tests.pid(tests.g(), 'f'), tests.pid(tests.g(), 'g'));
select tests.act_as('c');
select tests.eq((select count(*) from event_results), 0::bigint, 'nothing readable before the reveal');
select tests.reset();
select advance_games(now() + interval '2 hours');
select tests.act_as('c');
select tests.eq((select votes from event_results where event_id = '00000000-0000-0000-0000-0000000000d7'),
                E'Votes:\n• f: 2 (c, d)\n• g: 1 (f)\nDid not vote: a, b, e, g, h.', 'members can read the saved breakdown, including the banished player''s own vote');
select tests.act_as('outsider');
select tests.eq((select count(*) from event_results), 0::bigint, 'non-members cannot read it');
select tests.reset();
rollback to savepoint s11b;

-------------------------------------------------------------------- 12. choosing a photo
savepoint s12;
select tests.make_user('gm'), tests.make_user('outsider');
insert into admins values ('gm@org.test');
select tests.add_people(3);

select tests.act_as('p1');
select tests.eq(jsonb_array_length(photo_gallery()), 21, 'the gallery lists all 21 photos');
select tests.eq((select count(*) from jsonb_array_elements(photo_gallery()) x where (x ->> 'taken')::boolean), 0::bigint, 'nothing is taken yet');
select tests.lives($$select set_my_photo('team-01')$$, 'a person chooses a photo');
select tests.eq(my_person() ->> 'avatar_key', 'team-01', 'their choice is saved');
select tests.ok((select (x ->> 'mine')::boolean from jsonb_array_elements(photo_gallery()) x where x ->> 'key' = 'team-01'), 'the gallery marks their own photo');

select tests.act_as('p2');
select tests.ok((select (x ->> 'taken')::boolean from jsonb_array_elements(photo_gallery()) x where x ->> 'key' = 'team-01'), 'a taken photo shows as taken to others');
select tests.throws($$select set_my_photo('team-01')$$, 'already been taken', 'two people cannot share a photo');
select tests.throws($$select set_my_photo('team-99')$$, 'does not exist', 'unknown photos are refused');
select tests.throws($$select set_my_photo('../../etc/passwd')$$, 'does not exist', 'a path is not a photo key');
select tests.lives($$select set_my_photo('team-02')$$, 'a second person chooses another photo');
select tests.lives($$select set_my_photo('team-03')$$, 'they can change their mind');
select tests.act_as('p3');
select tests.lives($$select set_my_photo('team-02')$$, 'a freed photo can be chosen by someone else');

-- people who have not registered cannot use it
select tests.act_as('outsider');
select tests.eq(photo_gallery(), '[]'::jsonb, 'non-registered users see an empty gallery');
select tests.throws($$select set_my_photo('team-05')$$, 'not allowed', 'non-registered users cannot choose');
select tests.as_anon();
select tests.throws($$select photo_gallery()$$, '42501', 'signed-out visitors cannot call it');

-- changing a photo updates games they are already in
select tests.act_as('gm');
select set_config('t.g', create_game()::text, false);
select gm_set_player(tests.g(), tests.uid('p1'), true);
select tests.reset();
select tests.eq((select avatar_key from players where game_id = tests.g()), 'team-01', 'a player starts with their chosen photo');
select tests.act_as('p1');
select set_my_photo('team-09');
select tests.reset();
select tests.eq((select avatar_key from players where game_id = tests.g()), 'team-09', 'changing it updates their games too');

-- the GM can reset a wrong choice
select tests.act_as('p2');
select tests.throws(format($$select gm_reset_photo(%L)$$, tests.uid('p1')), 'admin only', 'players cannot reset anyone''s photo');
select tests.act_as('gm');
select tests.lives(format($$select gm_reset_photo(%L)$$, tests.uid('p1')), 'the GM resets a photo');
select tests.reset();
select tests.eq((select avatar_key from people where user_id = tests.uid('p1')), null::text, 'the person has no photo again');
select tests.eq((select avatar_key from players where game_id = tests.g()), null::text, 'and neither does their player row');
select tests.act_as('p2');
select tests.lives($$select set_my_photo('team-09')$$, 'the reset photo is free again');
select tests.reset();

-- the GM can give any account a photo
select tests.act_as('p2');
select tests.throws(format($$select gm_set_photo(%L, 'team-12')$$, tests.uid('p3')), 'admin only', 'players cannot assign photos');
select tests.throws(format($$select gm_gallery(%L)$$, tests.uid('p3')), 'admin only', 'players cannot read another person''s gallery');
select tests.act_as('gm');
select tests.lives(format($$select gm_set_photo(%L, 'team-12')$$, tests.uid('p3')), 'the GM gives someone a photo');
select tests.reset();
select tests.eq((select avatar_key from people where user_id = tests.uid('p3')), 'team-12', 'it is saved on the person');
select tests.eq((select avatar_key from players where game_id = tests.g() and user_id = tests.uid('p3')), null::text, 'players not in a game are unaffected');
select tests.act_as('gm');
select gm_set_player(tests.g(), tests.uid('p3'), true);
select tests.lives(format($$select gm_set_photo(%L, 'team-13')$$, tests.uid('p3')), 'the GM can change it');
select tests.reset();
select tests.eq((select avatar_key from players where game_id = tests.g() and user_id = tests.uid('p3')), 'team-13', 'and it updates their games');
select tests.act_as('gm');
-- p2 holds team-09 at this point, so giving it to p3 must be refused
select tests.throws(format($$select gm_set_photo(%L, 'team-09')$$, tests.uid('p3')), 'already been taken', 'a photo someone else holds is refused');
select tests.throws(format($$select gm_set_photo(%L, 'team-99')$$, tests.uid('p3')), 'does not exist', 'unknown photos are refused');
select tests.throws($$select gm_set_photo('00000000-0000-0000-0000-00000000dead', 'team-05')$$, 'No such person', 'unknown people are refused');
select tests.ok((select (x ->> 'taken')::boolean from jsonb_array_elements(gm_gallery(tests.uid('p3'))) x where x ->> 'key' = 'team-09'), 'the GM gallery shows photos others hold as taken');
select tests.ok((select (x ->> 'mine')::boolean from jsonb_array_elements(gm_gallery(tests.uid('p3'))) x where x ->> 'key' = 'team-13'), 'and the person''s own as theirs');
select tests.reset();
rollback to savepoint s12;

-------------------------------------------------------------------- 13. the GM chooses the traitors
savepoint s13;
insert into admins values ('gm@org.test');
select tests.make_user('gm');
select tests.add_people(18);
select tests.act_as('gm');
select set_config('t.g', create_game()::text, false);
select gm_set_player(tests.g(), tests.uid('p' || i), true) from generate_series(1, 18) i;

-- only the GM, only in the lobby, only people in this game
select tests.act_as('p1');
select tests.throws(format($$select gm_set_traitor(%L, %L, true)$$, tests.g(), tests.uid('p2')), 'admin only', 'players cannot choose traitors');
select tests.act_as('gm');
select tests.throws(format($$select gm_set_traitor(%L, %L, true)$$, tests.g(), tests.uid('gm')), 'not in this game', 'cannot choose someone who is not playing');
select tests.lives(format($$select gm_set_traitor(%L, %L, true)$$, tests.g(), tests.uid('p4')), 'the GM chooses a traitor');
select tests.lives(format($$select gm_set_traitor(%L, %L, true)$$, tests.g(), tests.uid('p9')), 'and another');
select tests.lives(format($$select gm_set_traitor(%L, %L, true)$$, tests.g(), tests.uid('p17')), 'and a third');
select tests.lives(format($$select gm_set_traitor(%L, %L, true)$$, tests.g(), tests.uid('p9')), 'choosing twice is harmless');
select tests.lives(format($$select gm_set_traitor(%L, %L, false)$$, tests.g(), tests.uid('p17')), 'a choice can be undone');
select tests.lives(format($$select gm_set_traitor(%L, %L, true)$$, tests.g(), tests.uid('p17')), 'and made again');
select set_config('t.o', gm_overview(tests.g())::text, false);
select tests.reset();
select tests.eq((select count(*) from jsonb_array_elements(current_setting('t.o')::jsonb -> 'people') x where (x ->> 'traitor')::boolean), 3::bigint, 'the GM overview shows the three chosen');

-- players can never read who was chosen
select tests.act_as('p1');
select tests.eq((select count(*) from designated_traitors), 0::bigint, 'players cannot read the chosen traitors');
select tests.eq((select count(*) from players where game_id = tests.g()), 18::bigint, 'but they can still see the player list');
select tests.reset();

-- starting uses exactly the GM's choice, whatever the count
select tests.act_as('gm');
select start_game(tests.g(), '2026-10-19');
select tests.reset();
select tests.eq((select count(*) from roles where game_id = tests.g() and role = 'traitor'), 3::bigint, 'exactly three traitors');
select tests.eq((select array_agg(p.display_name order by p.display_name) from roles r join players p on p.id = r.player_id where r.game_id = tests.g() and r.role = 'traitor'),
                array['p17', 'p4', 'p9'], 'and they are the three the GM chose');
select tests.act_as('gm');
select tests.throws(format($$select gm_set_traitor(%L, %L, true)$$, tests.g(), tests.uid('p2')), 'not in lobby', 'no changing traitors once started');
select tests.reset();
rollback to savepoint s13;

-- the GM can choose any number, as long as the faithful outnumber them
savepoint s13b;
insert into admins values ('gm@org.test');
select tests.make_user('gm');
select tests.add_people(8);
select tests.act_as('gm');
select set_config('t.g', create_game()::text, false);
select gm_set_player(tests.g(), tests.uid('p' || i), true) from generate_series(1, 8) i;
select gm_set_traitor(tests.g(), tests.uid('p' || i), true) from generate_series(1, 4) i;
select tests.throws(format($$select start_game(%L, '2026-10-19')$$, tests.g()), 'fewer traitors than faithful', 'four traitors of eight is refused');
select gm_set_traitor(tests.g(), tests.uid('p4'), false);
select start_game(tests.g(), '2026-10-19');
select tests.reset();
select tests.eq((select count(*) from roles where game_id = tests.g() and role = 'traitor'), 3::bigint, 'three of eight is allowed');
rollback to savepoint s13b;

-- one traitor is allowed too, since the GM is in charge
savepoint s13c;
insert into admins values ('gm@org.test');
select tests.make_user('gm');
select tests.add_people(6);
select tests.act_as('gm');
select set_config('t.g', create_game()::text, false);
select gm_set_player(tests.g(), tests.uid('p' || i), true) from generate_series(1, 6) i;
select gm_set_traitor(tests.g(), tests.uid('p2'), true);
select start_game(tests.g(), '2026-10-19');
select tests.reset();
select tests.eq((select count(*) from roles where game_id = tests.g() and role = 'traitor'), 1::bigint, 'a single chosen traitor is respected');
rollback to savepoint s13c;

-- nothing chosen: random, 3 for a big game, 2 for a small one
savepoint s13d;
insert into admins values ('gm@org.test');
select tests.make_user('gm');
select tests.add_people(18);
select tests.act_as('gm');
select set_config('t.g', create_game()::text, false);
select gm_set_player(tests.g(), tests.uid('p' || i), true) from generate_series(1, 18) i;
select start_game(tests.g(), '2026-10-19');
select tests.reset();
select tests.eq((select count(*) from roles where game_id = tests.g() and role = 'traitor'), 3::bigint, '18 players, none chosen -> 3 random traitors');
rollback to savepoint s13d;

-- a stale choice for someone no longer in the game is ignored
savepoint s13e;
insert into admins values ('gm@org.test');
select tests.make_user('gm');
select tests.add_people(7);
select tests.act_as('gm');
select set_config('t.g', create_game()::text, false);
select gm_set_player(tests.g(), tests.uid('p' || i), true) from generate_series(1, 7) i;
select gm_set_traitor(tests.g(), tests.uid('p7'), true);
select gm_set_player(tests.g(), tests.uid('p7'), false);
select gm_set_player(tests.g(), tests.uid('p' || i), true) from generate_series(1, 6) i;
select start_game(tests.g(), '2026-10-19');
select tests.reset();
select tests.eq((select count(*) from roles where game_id = tests.g() and role = 'traitor'), 2::bigint, 'a choice for someone who left is ignored, so it falls back to random');
rollback to savepoint s13e;

-------------------------------------------------------------------- 5. security / GM
savepoint s5;
select set_config('t.g', tests.make_game(8)::text, false);
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at, status)
values ('00000000-0000-0000-0000-0000000000c1', tests.g(), 'banishment', now() - interval '1 hour', now() + interval '1 hour', now() + interval '1 hour', 'open');

select tests.act_as('a');
select tests.throws($$select advance_games()$$, '42501', 'client cannot call advance_games');
select tests.throws($$select close_event('00000000-0000-0000-0000-0000000000c1')$$, '42501', 'client cannot call close_event');
select tests.throws(format($$select internal_start_game(%L)$$, tests.g()), '42501', 'client cannot call internal_start_game');
select tests.throws($$select gm_force_close('00000000-0000-0000-0000-0000000000c1')$$, 'admin only', 'non-GM cannot force close');
select tests.throws($$select gm_extend_event('00000000-0000-0000-0000-0000000000c1', '1 day')$$, 'admin only', 'non-GM cannot extend');
select tests.throws(format($$select gm_delete_game(%L)$$, tests.g()), 'admin only', 'non-GM cannot delete a game');
select tests.throws(format($$select gm_overview(%L)$$, tests.g()), 'admin only', 'non-GM cannot read overview');

select tests.as_anon();
select tests.throws($$select create_game()$$, '42501', 'anon cannot call client functions');

select tests.act_as('gm');
select tests.eq((gm_overview(tests.g()) ->> 'players')::int, 8, 'GM overview counts players');
select tests.lives($$select gm_force_close('00000000-0000-0000-0000-0000000000c1')$$, 'GM can force close');
select tests.reset();
rollback to savepoint s5;

-------------------------------------------------------------------- 14. final banishment and end game
-- Roles are hidden once 6 or fewer are alive; the first banishment to open with 6 or fewer alive is the last one,
-- it and the end game vote have no clock, and they close when everyone alive has answered.
create function tests.vote_all(p_event uuid, p_names text[], p_target text) returns void language plpgsql as $$
declare n text;
begin
  foreach n in array p_names loop
    perform tests.act_as(n);
    perform public.cast_vote(p_event, tests.pid(tests.g(), p_target));
  end loop;
  perform tests.reset();
end $$;
create function tests.endgame_all(p_event uuid, p_names text[], p_end boolean) returns void language plpgsql as $$
declare n text;
begin
  foreach n in array p_names loop
    perform tests.act_as(n);
    perform public.cast_endgame(p_event, p_end);
  end loop;
  perform tests.reset();
end $$;
grant execute on function tests.vote_all(uuid, text[], text), tests.endgame_all(uuid, text[], boolean) to authenticated, anon;

savepoint s14a;
select set_config('t.g', tests.make_game(7)::text, false);
select tests.set_traitors(tests.g(), array['a', 'b', 'g']);
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at) values
  ('00000000-0000-0000-0000-0000000000d1', tests.g(), 'banishment', now() - interval '1 hour', now() + interval '1 day', now() + interval '1 day');
select advance_games();
select tests.eq((select phase from games where id = tests.g()), 'normal', '7 alive: still the normal game');
select tests.eq((select untimed from events where id = '00000000-0000-0000-0000-0000000000d1'), false, '7 alive: normal clock');
select tests.vote_all('00000000-0000-0000-0000-0000000000d1', array['b', 'c', 'd', 'e'], 'a');
update events set closes_at = now(), reveals_at = now() where id = '00000000-0000-0000-0000-0000000000d1';
select advance_games();
select tests.eq((select alive from players where id = tests.pid(tests.g(), 'a')), false, 'a banished at 7 alive');
select tests.act_as('c');
select tests.eq((select count(*) from roles r join players p on p.id = r.player_id where p.display_name = 'a'), 1::bigint, 'role shown when 7 were alive');
select tests.reset();

-- 6 alive (b, g traitors; c, d, e, f faithful): the next banishment to open is the final one
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at) values
  ('00000000-0000-0000-0000-0000000000d3', tests.g(), 'banishment', now() - interval '1 minute', now() + interval '1 day', now() + interval '1 day'),
  ('00000000-0000-0000-0000-0000000000d4', tests.g(), 'murder', now() + interval '1 day', now() + interval '2 days', now() + interval '2 days');
select advance_games();
select tests.eq((select phase from games where id = tests.g()), 'final', 'first banishment at 6 alive is the final one');
select tests.eq((select untimed from events where id = '00000000-0000-0000-0000-0000000000d3'), true, 'final banishment has no clock');
select tests.eq((select count(*) from events where game_id = tests.g() and status = 'scheduled'), 0::bigint, 'no later murder is left scheduled');
select tests.vote_all('00000000-0000-0000-0000-0000000000d3', array['b', 'd', 'e', 'f', 'g'], 'c');
select tests.eq((select status from events where id = '00000000-0000-0000-0000-0000000000d3'), 'open', 'final banishment waits for the last voter');
select tests.vote_all('00000000-0000-0000-0000-0000000000d3', array['c'], 'f');
select tests.eq((select status from events where id = '00000000-0000-0000-0000-0000000000d3'), 'revealed', 'closes and reveals once everyone has voted');
select tests.eq((select alive from players where id = tests.pid(tests.g(), 'c')), false, 'c banished in the final banishment');
select tests.act_as('d');
select tests.eq((select count(*) from roles r join players p on p.id = r.player_id where p.display_name = 'c'), 0::bigint, 'role hidden at 6 alive');
select tests.reset();
select tests.eq((select phase from games where id = tests.g()), 'endgame', 'game moves to the end game');
select tests.eq((select count(*) from events where game_id = tests.g() and kind = 'endgame' and status = 'open' and untimed), 1::bigint, 'end game vote is open and untimed');
select tests.eq((select status from games where id = tests.g()), 'active', 'game carries on');

-- not unanimous: one more banishment, then the vote again
select tests.endgame_all((select id from events where game_id = tests.g() and kind = 'endgame' order by opens_at limit 1), array['b', 'd', 'e', 'f'], true);
select tests.eq((select status from games where id = tests.g()), 'active', 'waiting for the last end game answer');
select tests.endgame_all((select id from events where game_id = tests.g() and kind = 'endgame' order by opens_at limit 1), array['g'], false);
select tests.eq((select status from games where id = tests.g()), 'active', 'one "keep playing" does not end it');
select tests.eq((select count(*) from events where game_id = tests.g() and kind = 'banishment' and status = 'open' and untimed), 1::bigint, 'another untimed banishment opens');
select tests.eq((select phase from games where id = tests.g()), 'final', 'back to a banishment');
-- 5 alive (b, g, d, e, f): g is banished, leaving b as the last traitor
select tests.vote_all((select id from events where game_id = tests.g() and kind = 'banishment' and status = 'open'), array['b', 'd', 'e', 'f'], 'g');
select tests.vote_all((select id from events where game_id = tests.g() and kind = 'banishment' and status = 'open'), array['g'], 'b');
select tests.eq((select alive from players where id = tests.pid(tests.g(), 'g')), false, 'g banished');
select tests.eq((select count(*) from events where game_id = tests.g() and kind = 'endgame' and status = 'open'), 1::bigint, 'a fresh end game vote opens');
select tests.endgame_all((select id from events where game_id = tests.g() and kind = 'endgame' and status = 'open'), array['b', 'd', 'e', 'f'], true);
select tests.eq((select revealing and status = 'active' from games where id = tests.g()), true, 'unanimous end game starts the reveal stage');
select tests.eq((select count(*) from events where game_id = tests.g() and status in ('open', 'scheduled')), 0::bigint, 'nothing is open in the reveal stage');
select do_reveal(tests.pid(tests.g(), 'b'));
select tests.eq((select status from games where id = tests.g()), 'active', 'still waiting for the others to reveal');
select do_reveal(id) from players where game_id = tests.g() and alive;
select tests.eq((select status from games where id = tests.g()), 'finished', 'all revealed ends the game');
select tests.eq((select winner from games where id = tests.g()), 'traitors', 'a traitor still alive: the traitors win');
rollback to savepoint s14a;

-- unanimous with no traitor left: the faithful win
savepoint s14b;
select set_config('t.g', tests.make_game(6)::text, false);
select tests.set_traitors(tests.g(), array['a']);
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at) values
  ('00000000-0000-0000-0000-0000000000d5', tests.g(), 'banishment', now() - interval '1 minute', now() + interval '1 day', now() + interval '1 day');
select advance_games();
select tests.eq((select phase from games where id = tests.g()), 'final', 'a 6-player game starts with its final banishment');
select tests.vote_all('00000000-0000-0000-0000-0000000000d5', array['a', 'c', 'd', 'e', 'f'], 'b');
select tests.vote_all('00000000-0000-0000-0000-0000000000d5', array['b'], 'a');
select tests.eq((select phase from games where id = tests.g()), 'endgame', 'faithful b banished, a traitor remains: end game');
select tests.endgame_all((select id from events where game_id = tests.g() and kind = 'endgame'), array['a', 'c', 'd', 'e', 'f'], true);
insert into admins values ('gm@org.test') on conflict do nothing;
select tests.act_as('gm');
select gm_reveal_all(tests.g());
select tests.reset();
select tests.eq((select winner from games where id = tests.g()), 'traitors', 'GM reveal all: ending it with the traitor alive loses');
rollback to savepoint s14b;

-- the GM can force an end game vote through when someone is missing, and "no answer" counts as keep playing
savepoint s14c;
insert into admins values ('gm@org.test');
select set_config('t.g', tests.make_game(6)::text, false);
select tests.set_traitors(tests.g(), array['a']);
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at) values
  ('00000000-0000-0000-0000-0000000000d6', tests.g(), 'banishment', now() - interval '1 minute', now() + interval '1 day', now() + interval '1 day');
select advance_games();
select tests.vote_all('00000000-0000-0000-0000-0000000000d6', array['a', 'c', 'd', 'e', 'f'], 'b');
select tests.vote_all('00000000-0000-0000-0000-0000000000d6', array['b'], 'a');
select tests.endgame_all((select id from events where game_id = tests.g() and kind = 'endgame'), array['a', 'c', 'd', 'e'], true);
-- Looked up before switching role: the GM is not a player, so RLS would hide the event from them.
select set_config('t.e', (select id::text from events where game_id = tests.g() and kind = 'endgame'), false);
select tests.act_as('gm');
select gm_force_close(current_setting('t.e')::uuid);
select tests.reset();
select tests.eq((select status from games where id = tests.g()), 'active', 'missing answers count as keep playing');
select tests.eq((select count(*) from events where game_id = tests.g() and kind = 'banishment' and status = 'open'), 1::bigint, 'so another banishment opens');
rollback to savepoint s14c;

-- GM starts the end game early
savepoint s14d;
insert into admins values ('gm@org.test');
select set_config('t.g', tests.make_game(9)::text, false);
select tests.set_traitors(tests.g(), array['a', 'b']);
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at, status) values
  ('00000000-0000-0000-0000-0000000000d7', tests.g(), 'banishment', now() - interval '1 hour', now() + interval '1 day', now() + interval '1 day', 'open'),
  ('00000000-0000-0000-0000-0000000000d8', tests.g(), 'murder', now() + interval '1 day', now() + interval '2 days', now() + interval '2 days', 'scheduled');
select tests.act_as('c');
select tests.throws(format($$select gm_start_endgame(%L)$$, tests.g()), 'admin only', 'only the GM can start the end game');
select tests.act_as('gm');
select gm_start_endgame(tests.g());
select tests.reset();
select tests.eq((select phase from games where id = tests.g()), 'final', 'GM start puts the game into the final banishment');
select tests.eq((select count(*) from players where game_id = tests.g() and alive), 9::bigint, 'the voided round banishes nobody');
select tests.eq((select count(*) from events where game_id = tests.g() and status = 'open' and kind = 'banishment' and untimed), 1::bigint, 'one untimed banishment open');
select tests.eq((select count(*) from events where game_id = tests.g() and status = 'scheduled'), 0::bigint, 'nothing left scheduled');
select tests.act_as('gm');
select tests.throws(format($$select gm_start_endgame(%L)$$, tests.g()), 'already', 'cannot start it twice');
select tests.reset();
rollback to savepoint s14d;

-------------------------------------------------------------------- 15. archiving a finished game
savepoint s15;
insert into admins values ('gm@org.test') on conflict do nothing;
select set_config('t.g', tests.make_game(6)::text, false);
select tests.act_as('gm');
select tests.throws(format($$select gm_archive_game(%L)$$, tests.g()), 'finished', 'only a finished game can be archived');
select tests.reset();
update games set status = 'finished', winner = 'faithful' where id = tests.g();
select tests.act_as('a');
select tests.throws(format($$select gm_archive_game(%L)$$, tests.g()), 'admin only', 'a player cannot archive');
select tests.act_as('gm');
select gm_archive_game(tests.g());
select tests.reset();
select tests.eq((select archived from games where id = tests.g()), true, 'the GM archives a finished game');
rollback to savepoint s15;

-------------------------------------------------------------------- 16. deleting a game that has votes and chat
savepoint s16;
insert into admins values ('gm@org.test') on conflict do nothing;
select set_config('t.g', tests.make_game(6)::text, false);
insert into events (id, game_id, kind, opens_at, closes_at, reveals_at, status) values
  ('00000000-0000-0000-0000-0000000000e1', tests.g(), 'banishment', now(), now() + interval '1 day', now() + interval '1 day', 'open');
insert into actions (event_id, player_id, target_id) values
  ('00000000-0000-0000-0000-0000000000e1', tests.pid(tests.g(), 'a'), tests.pid(tests.g(), 'b')),
  ('00000000-0000-0000-0000-0000000000e1', tests.pid(tests.g(), 'b'), tests.pid(tests.g(), 'a'));
insert into messages (game_id, player_id, body) values (tests.g(), tests.pid(tests.g(), 'a'), 'hello');
select tests.act_as('gm');
select gm_delete_game(tests.g());
select tests.reset();
select tests.eq((select count(*) from games where id = tests.g()), 0::bigint, 'a game with votes and chat can be deleted');
rollback to savepoint s16;

rollback;
select 'all tests passed' as result;
