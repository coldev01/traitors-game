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
| Players | 6–15 per game |
| Traitors | `max(2, round(players / 4))` |
| Public chat | Dropped from v1; Slack instead |
| Traitors chat | In game, readable/writable by traitors only |
| Avatars | Org headshots (already public on the website) bundled as static assets, matched to players by email; placeholder if missing |
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
| Banishment 1 | Mon 09:00 | Tue 15:00 | Tue 15:00 |
| Murder 1 | Tue 15:00 | Wed 24:00 | Thu 09:00 |
| Banishment 2 | Wed 09:00 | Thu 15:00 | Thu 15:00 |
| Murder 2 | Thu 15:00 | Mon 24:00 | Tue 09:00 |

Repeats weekly: two rounds a week, so a 10-player game runs roughly 2–3 weeks. Times live in game config, not code, so the schedule can change (or compress to minutes for dry runs) without code changes.

Banishment and murder are two interleaved tracks, not a single day/night sequence. Windows overlap (Wed: banishment 2 and murder 1; Mon: banishment 1 and murder 2).

## Rules

- **Fixed times only.** Events resolve at their scheduled time. There is no early finish, so Slack discussion can run until the deadline and nobody is pressured.
- **Banishment:** most votes is banished. Ties are broken at random among the tied players. Abstaining is allowed. The banished player is marked dead and their role is revealed at `reveals_at`.
- **Murder:** optional. Traitors who lock in a victim vote among themselves; majority wins, ties random. If no traitor locks in a victim, nobody dies.
- **Murder timing:** the victim is chosen at close but only applied (marked dead, role revealed) at `reveals_at`, so the reveal always lands before that day's banishment. A victim who voted before being applied has that vote discarded.
- **Recruitment:** once 2 or fewer traitors are alive, a traitor's murder pick can instead be a recruit pick (majority across traitors, ties random, same as a murder). At the close the chosen faithful gets a private offer, open until the reveal. Accept: they become a traitor at the reveal (role card, traitors chat and traitor view update). Refuse, or no answer: nothing happens and nobody dies that round. Recruit results are visible to traitors only; everyone else sees an ordinary "nobody was murdered" round.
- **Win check** after each applied result: faithful win when all traitors are out; traitors win when they equal or outnumber the faithful.

## Screens (Godot)

- **Login** — "Sign in with Google".
- **Lobby** — player photo grid; Start button for the game master.
- **Game** — player grid (alive/dead, avatars), current events with countdowns, traitors chat tab (traitors only), action panel (vote / pick victim), own role card.
- **End** — winner and full role reveal.
- **GM panel** — create/start game, extend or force-resolve an event. Control panel only, not a roles view.

`Avatar` is a single scene taking an `avatar_key`; today it shows a still photo, later it can show an animated character.

## Security

- The anon key ships in the web build by design, so security rests entirely on RLS and server-side functions. Roles and actions are never readable by the wrong player; chat posting is validated server-side.
- Sign-up is restricted to the org Google domain.
- The Supabase owner can read all data (fairness, not a technical risk). Chat has a length cap and a rate limit, and message text is escaped (no BBCode) in Godot.
- Messages and player data are deleted after a game ends.
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

- Voting opens 09:00 Mon and Wed; reveals are at 09:00.
- Murder 2's window (Thu 15:00 to Mon 24:00) deliberately spans the weekend.
- The org supplies headshots and an `email → photo` mapping.
