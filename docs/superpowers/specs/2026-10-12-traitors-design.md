# Traitors (async) — Design

Date: 2026-10-12

## Goal

An asynchronous Traitors-style social deduction game for the org, played over weeks in people's own time. Godot 4 web export on GitHub Pages, Supabase as the only backend. Alpha with a small group; wider team only once missions are in.

## Scope

**v1 (alpha):** Google login, lobby, role dealing, scheduled banishment votes, scheduled murders, in-game traitors chat, end screen, game-master controls, avatars from headshots.

**Before full release (not v1):** missions (group quiz with traitor sabotage, shield reward). The schema has a nullable `mission` slot so this plugs in without a rewrite.

**Out of scope:** in-game public chat (Slack is used for public discussion), photo/real-world tasks, realtime sockets, animated characters (later swap of the `Avatar` scene).

## Decisions

| Topic | Decision |
|---|---|
| Engine | Godot 4, single-threaded web export (works on plain static hosting) |
| Backend | Supabase: Postgres + RLS, Auth, `pg_cron`. No other services |
| Login | Google SSO via Supabase Auth, restricted to the org domain |
| Updates | Client polls ~every 10s |
| Game master | Admin allowlist of Google emails. Not a player. Creates/starts games, extends or force-resolves stuck events |
| Players | 6 or more, with no upper limit, chosen by the GM from the registered people (new people can register at any time) |
| Traitors | Chosen by the GM in the lobby, any number as long as there are fewer traitors than faithful. Stored where players cannot read it, and turned into roles when the game starts. If the GM ticks nobody: 2 or 3 at random (a sixth of the players, between 2 and 3) |
| Public chat | Dropped from v1; Slack instead |
| Traitors chat | In game, readable/writable by traitors only |
| Avatars | Team headshots bundled as static assets (`avatars/team-NN.webp`). Each person chooses theirs from a gallery after registering; one photo per person, changeable later. The GM can also give anyone a photo or remove it. Initial letter shown until chosen. If every photo is taken, a new person carries on with their initial until a photo is added |
| Vote tie | Broken at random among tied players |
| Role reveal | Banished and murdered players' roles are shown to everyone |
| Dead players | Can't act or post |

## Architecture

- **Client (Godot):** renders state and sends requests. No game logic.
- **Server:** all state changes go through server-side functions (`cast_vote`, `pick_victim`, `post_message`, GM functions). Each checks caller identity, alive status, role and that the event is open. The client never writes tables directly.
- **Scheduler:** a `pg_cron` job runs every minute and calls `advance_games()`, which opens, closes and reveals any event whose time has come.

## Data model (all tables have RLS on)

- `games` — status, config (schedule, timezone), `mission` (nullable, unused in v1).
- `players` — user, game, alive flag, `avatar_key`, (later) shield flag.
- `roles` — player and role. Readable by the owner, and by fellow traitors for traitor rows.
- `events` — one row per scheduled event: type (`banishment` | `murder`), `opens_at`, `closes_at`, `reveals_at`, status, result.
- `actions` — votes and victim picks, tied to an event. Write-only to the client until the event is revealed.
- `messages` — traitors channel only in v1; author, body, timestamp. Channel column kept so a public channel can be added later.

## Schedule (Europe/London)

| Event | Opens | Closes | Result shown |
|---|---|---|---|
| Banishment 1 | Mon 09:00 | Tue 09:00 | Tue 09:00 |
| Murder 1 | Tue 09:00 | Wed 09:00 | Wed 09:00 |
| Banishment 2 | Wed 09:00 | Thu 09:00 | Thu 09:00 |
| Murder 2 | Thu 09:00 | Mon 09:00 | Mon 09:00 |

Repeats weekly: two rounds a week, so a 10-player game runs roughly 2–3 weeks. Times live in game config, not code, so the schedule can change (or compress to minutes for dry runs) without code changes.

Banishment and murder are two interleaved tracks, not a single day/night sequence. Windows overlap (Wed: banishment 2 and murder 1; Mon: banishment 1 and murder 2).

## Rules

- **Fixed times only.** Events resolve at their scheduled time. There is no early finish, so Slack discussion can run until the deadline and nobody is pressured.
- **Banishment:** most votes is banished. Ties are broken at random among the tied players. Not voting counts as abstaining. Once the result is announced, who voted for whom is published too, in Slack and in the app's "What happened" timeline (the same saved text, so they always match) (only the votes that counted, plus who did not vote, and a note when a tie was broken at random). Skipped rounds publish nothing. The banished player is marked dead and their role is revealed at `reveals_at`.
- **Murder:** the traitors must choose a victim (or recruit); there is no "no murder" option in the app. Each living traitor suggests a target. As soon as more than half of them name the same person (and the same choice of murder or recruit) it is locked in. The traitors have until 14:00 on the day the window opens; at that deadline the most-suggested choice goes ahead, a tie is settled at random, and no suggestions at all means nobody dies. Nothing the traitors choose is stored where the faithful can read it (`murder_locks` is traitor-only).
- **Murder timing:** the victim is chosen at close but only applied (marked dead, role revealed) at `reveals_at`, so the reveal always lands before that day's banishment. A victim who voted before being applied has that vote discarded.
- **Recruitment:** once 2 or fewer traitors are alive, a suggestion can be a recruit instead of a murder (same majority and deadline rules). When a recruit is locked in the target becomes a traitor at once (role card, traitors chat and traitor view update) and sees a private offer. They can refuse until the murder window closes; refusing turns them faithful again and they are murdered when the window is revealed, shown as faithful. No answer: they stay a traitor and nobody dies. Everyone else sees an ordinary "nobody was murdered" round, unless the recruit refused, which looks like any murder.
- **Win check** after each applied result: faithful win when all traitors are out; traitors win when they equal or outnumber the faithful.

## End game
- Banished players' roles are shown while 7 or more are alive; from 6 or fewer alive they stay hidden until the game ends. Murder victims are always faithful, so nothing is hidden there.
- The first banishment to open with 6 or fewer alive is the final one (games.phase 'final'). Everything still scheduled is dropped: no more murders, no recruiting.
- The final banishment and the end game vote have no clock. Each closes the moment everyone alive has answered; the GM can close one early (anyone who has not answered counts as keep playing).
- After the final banishment, if the game is still on, everyone alive votes End the game or Keep playing (traitors too). All End: faithful win if no traitor is alive, otherwise the traitors win. Any Keep playing: one more banishment, then the vote again.
- The game ends only when everyone alive picks End, or when 2 players are left (traitors win if either is a traitor, otherwise the Faithful). Banishing the last traitor, or parity, does not stop it: players can't tell whether the last traitor has gone, so the game plays on to the end game vote.
- The GM can start the end game early: anything open is voided and the final banishment begins.

## Screens (Godot)

- **Login** — "Sign in with Google".
- **Lobby** — player photo grid; Start button for the game master.
- **Game** — player grid (alive/dead, avatars), current events with countdowns, traitors chat tab (traitors only), action panel (vote / pick victim), own role card.
- **End** — winner and full role reveal.
- **GM panel** — the GM is the game runner, not a player, and (as database owner) can see everything anyway, so the panel gives full control:
  - **Right now:** alive/out counts, who still has to vote, how many traitors have chosen, countdowns and recent turnout. Participation only, with no roles or targets, so it is safe to glance at.
  - **Controls:** pick who plays, close an event now, add 6 hours or a day, skip an event with no result, delay the whole game by 1-14 days, and nudge the players who have not voted on Slack.
  - **Behind the curtain** (hidden until opened): every role, every vote and pick, recruit offers, and the traitors chat, with the ability to post in it as the Game master.

`Avatar` is a single scene taking an `avatar_key`; today it shows a still photo, later it can show an animated character.

## Security

- The anon key ships in the web build by design, so security rests entirely on RLS and server-side functions. Roles and actions are never readable by the wrong player; chat posting is validated server-side.
- Sign-up is restricted to the org Google domain.
- The Supabase owner can read all data (fairness, not a technical risk). Chat has a length cap and a rate limit, and message text is escaped (no BBCode) in Godot.
- Nothing is deleted automatically. A finished game is archived and kept (votes, results, chat and roles) until the GM deletes it with Delete game, which removes everything in it. Decide on a retention period before the first real game.
- Supabase free-tier projects pause after a week of inactivity, which could affect a game left idle.

## Testing

- **Database tests (SQL/pgTAP) in CI:** a faithful can't read roles, others' actions or traitors messages; dead players and non-players can't act or post; only the GM can create/start games; resolution handles ties, abstentions, no-murder, discarded victim votes and win conditions.
- **Time is injected:** `advance_games()` takes `now` as a parameter so tests step through a whole week instantly.
- **Godot:** manual playtest checklist; logic lives on the server.

## Rollout

- Supabase migrations in the repo. A GitHub Action runs the tests, exports Godot and deploys to Pages.
- Dry run with test accounts on a compressed schedule (minutes, not days).
- Alpha with a small group, then full release once missions are in.

## Assumptions to confirm

- Nothing opens, closes or posts on Fri to Sun (the team is off alternate Fridays). Every event starts at 09:00 Mon to Thu.
- Murder 2's window (Thu 09:00 to Mon 09:00) deliberately spans the weekend.
- The org supplies headshots and an `email → photo` mapping.
- **Reveal stage:** when everyone picks End, or 2 players are left, nothing is announced yet. The game enters a reveal stage: nothing is open or scheduled, and each player still standing presses "Reveal my role" (the GM can reveal anyone, or everyone). Each reveal is shown to everyone and posted to Slack. After the last reveal the winner is announced: the Traitors if any revealed role is a traitor, otherwise the Faithful.
