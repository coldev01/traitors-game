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

-- p_expect matches either the SQLSTATE or a substring of the message
create function tests.throws(p_sql text, p_expect text, p_label text) returns void language plpgsql as $$
begin
  execute p_sql;
exception when others then
  if sqlstate = p_expect or sqlerrm like '%' || p_expect || '%' then return; end if;
  raise exception 'FAIL: % (wrong error: % %)', p_label, sqlstate, sqlerrm;
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
                '2026-10-22 00:00:00+01'::timestamptz, 'murder 1 closes Wed midnight (Thu 00:00)');
select tests.act_as('gm');
select tests.throws(format($$select gm_set_player(%L, %L, false)$$, tests.g(), tests.uid('p1')), 'game not in lobby', 'cannot change players once started');
select tests.reset();
rollback to savepoint s2;

-------------------------------------------------------------------- 2b. limits
savepoint s2b;
insert into admins values ('gm@org.test');
select tests.make_user('gm');
select tests.add_people(16);
select tests.act_as('gm');
select set_config('t.g', create_game()::text, false);
select tests.lives(format($$select gm_set_player(%L, %L, true)$$, tests.g(), tests.uid('p' || i)), 'select p' || i) from generate_series(1, 15) i;
select tests.throws(format($$select gm_set_player(%L, %L, true)$$, tests.g(), tests.uid('p16')), 'game full', '16th player rejected');
select tests.reset();
select internal_start_game(tests.g(), '2026-10-19'::timestamp, '[]'::jsonb, 1, 10080);
select tests.eq((select count(*) from roles where game_id = tests.g() and role = 'traitor'), 4::bigint, '15 players -> 4 traitors');
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
select tests.eq((select target_id from my_action('00000000-0000-0000-0000-0000000000b1')), tests.pid(tests.g(), 'e'), 'my_action returns latest vote');
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
select tests.eq((select count(*) from traitor_picks('00000000-0000-0000-0000-0000000000b2')), 1::bigint, 'traitor sees traitor picks');

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
select advance_games('2026-11-07 15:01+00');
select tests.eq(pg_temp.alive('g'), false, 'votes from dead players are discarded');

-- both traitors out -> faithful win
update players set alive = true where game_id = tests.g();
select pg_temp.mk('b5', 'banishment', '2026-11-10 09:00+00', '2026-11-11 15:00+00', '2026-11-11 15:00+00');
update players set alive = false where display_name = 'a' and game_id = tests.g();
select pg_temp.act('b5', 'c', 'b'); select pg_temp.act('b5', 'd', 'b');
select advance_games('2026-11-11 15:01+00');
select tests.eq((select winner from games where id = tests.g()), 'faithful', 'all traitors out -> faithful win');

-- traitors equal faithful -> traitors win
update games set status = 'active', winner = null where id = tests.g();
update players set alive = true where game_id = tests.g();
update players set alive = false where display_name in ('c', 'd', 'e', 'f') and game_id = tests.g();
select pg_temp.mk('b6', 'banishment', '2026-11-12 09:00+00', '2026-11-13 15:00+00', '2026-11-13 15:00+00');
select pg_temp.act('b6', 'a', 'g');
select advance_games('2026-11-13 15:01+00');
select tests.eq((select winner from games where id = tests.g()), 'traitors', 'traitors >= faithful -> traitors win');
rollback to savepoint s4;

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

rollback;
select 'all tests passed' as result;
