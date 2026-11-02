# Deploy and dry run

## 1. Supabase (once)

1. New project. Database → Extensions → enable `pg_cron`.
2. SQL editor: run `db/schema.sql`, then the seed (org domain, GM email) at its bottom.
3. Authentication → Providers → Google: add a Google OAuth client (Google Cloud Console → Credentials → Web client). Authorised redirect URI is the one Supabase shows on that page.
4. Authentication → URL Configuration: Site URL and Redirect URLs = your Pages URL (`https://<user>.github.io/<repo>/`) plus `http://localhost:8000/` for local testing.
5. On a scratch project only, run `db/tests.sql`. It should end with `all tests passed`.
6. Project Settings → API: copy the URL and anon key into the top of `app.js`. The anon key is meant to be public; never put the service_role key anywhere in the repo.

Org-domain restriction lives in `join_game` (checks the email domain against the seed), so non-org Google accounts can sign in but cannot join.

## 2. Headshots

Put `avatars/<email-prefix>.jpg` (e.g. `ada.lovelace.jpg` for `ada.lovelace@org.com`). Missing photos fall back to the initial.

## 3. GitHub Pages

Repo Settings → Pages → Deploy from branch → `main` / root. No build step.

Local check first: `python3 -m http.server 8000` and open `http://localhost:8000/`.

## 4. Dry run (compressed schedule)

Needs 6 players (the minimum): use 6 test Google accounts on the org domain plus the GM account. `start_game` checks the caller is the GM, so it can't run from the dashboard SQL editor. Instead, once the players have joined, sign in as the GM and run this in the browser console (the GM Start button uses the real weekly schedule):

```js
await sb.rpc('start_game', {
  p_game: S.game.id,
  p_anchor: new Date().toLocaleString('sv', { timeZone: 'Europe/London' }).replace(' ', 'T'),
  p_schedule: [
    { kind: 'banishment', open: 0,  close: 10, reveal: 10 },
    { kind: 'murder',     open: 10, close: 20, reveal: 22 },
    { kind: 'banishment', open: 15, close: 25, reveal: 25 },
    { kind: 'murder',     open: 25, close: 30, reveal: 32 }],
  p_weeks: 2, p_period: 40 })
```

Offsets are minutes from the anchor (now); the cron job resolves events within a minute of their time.

Checklist:
- [ ] Faithful players never see the Traitors tab, other roles, or others' votes
- [ ] Two traitors see each other and the chat
- [ ] Banishment resolves at close; role revealed; tie picks one
- [ ] Murder victim stays alive until its reveal time, then is shown dead
- [ ] No murder pick → nobody dies
- [ ] Win screen appears and shows all roles
- [ ] GM Close now / +1 day work
- [ ] Dead player cannot vote or post

Cleanup: GM panel → Delete game (or `select gm_delete_game('<game-id>')`). Then create the real game and start it with the Start button.
