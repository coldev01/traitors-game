# Traitors v1 (alpha) — Plain Web + Supabase Plan

Replaces `2026-10-12-traitors-v1.md`. Rules, schedule, data model and security in `specs/2026-10-12-traitors-design.md` are unchanged. Only the client and tooling change.

## What changes

| Dropped | Replaced by |
|---|---|
| Godot 4 + web export | One static `index.html` + `app.js` (no build step, no framework) |
| Docker, Supabase CLI, local stack | Supabase hosted project; SQL applied via dashboard SQL editor or the Supabase connector |
| pgTAP in CI, GitHub Action export | One `tests.sql` run manually in the SQL editor (rolls back at the end) |
| 10-task subagent build | 3 tasks below |

Kept: Supabase Auth (Google, org domain only), RLS, server-side functions, `pg_cron` calling `advance_games(now)`, 10s polling, headshots in `avatars/` matched by email, GitHub Pages hosting.

## Task 1: Database (one file, `db/schema.sql`)

Port from old plan Tasks 2–6, merged into a single idempotent script:

- Tables: `games`, `players`, `roles`, `events`, `actions`, `messages` with RLS on (per spec).
- Functions (all `security definer`, check caller, alive, role, event open): `create_game`, `join_game`, `start_game` (deals roles), `cast_vote`, `pick_victim`, `post_message`, `gm_extend_event`, `gm_force_resolve`.
- `advance_games(now timestamptz default now())`: opens/closes/reveals events, ties random, applies murder at `reveals_at`, discards a victim's late vote, win check.
- `pg_cron` job every minute calling `advance_games()`.
- GM = email in an `admins` table; sign-up restricted to org domain via auth hook or `check` on first login.
- `db/tests.sql`: begin; fake two-faithful/two-traitor game; assert a faithful can't select others' roles/actions/traitor messages, dead can't act, tie/abstain/no-murder/win cases via injected `now`; rollback.

Done when: `tests.sql` passes in the SQL editor on a fresh project.

## Task 2: Web client (`index.html`, `app.js`, `style.css`)

Supabase JS via CDN, anon key in `app.js` (public by design).

- Login: `signInWithOAuth({provider:'google'})`.
- Lobby: avatar grid; Start button if GM.
- Game: player grid (alive/dead, role shown if revealed), events with countdowns, vote / pick-victim panel, traitors chat tab (traitors only, `textContent` only — never `innerHTML`), own role card.
- End: winner + full role reveal.
- GM panel: create/start, extend, force-resolve.
- Poll `select` on the views every 10s; all writes via `supabase.rpc(...)`.
- `Avatar` = one `avatar(key)` function returning an `<img>`, placeholder on 404 (swap for animated later).

Done when: two browser profiles can log in, join, start and play a compressed-schedule round.

## Task 3: Deploy + dry run

- Supabase: add Pages URL to Auth redirect allowlist; enable Google provider, restrict domain.
- GitHub Pages from `main` root (no Action needed).
- Dry run: set game config to minute-scale schedule, play with 4+ test accounts, tick the manual checklist (secrecy, ties, murder reveal order, GM controls).
- Delete the compressed game; alpha with a small group.

## Checklist before alpha

- [ ] `tests.sql` green
- [ ] Anon key only in client; service key nowhere in repo
- [ ] Chat length cap + rate limit enforced server-side
- [ ] Headshot email→file mapping provided
- [ ] Data deleted after a game ends (`delete_game` GM function)
