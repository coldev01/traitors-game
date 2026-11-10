# Deploy and dry run

## 1. Supabase (once)

1. New project. Database → Extensions → enable `pg_cron`.
2. SQL editor: run `db/schema.sql`. Then the seed at its bottom: allowed email domain, a long random **signup code**, and your GM email.
3. Authentication → Users → Add user for the GM (email + password, tick Auto Confirm). The email must match the `admins` seed.
4. Deploy the `register` function (it holds the service-role key server-side, never in the repo): `supabase functions deploy register --no-verify-jwt`, or paste `supabase/functions/register/index.ts` into Edge Functions → New function and turn "Verify JWT" **off** (it is a public sign-up endpoint; the signup code and email domain are its only gate).
5. On a scratch project only, run `db/tests.sql`. It should end with `all tests passed`.
6. Project Settings → API: copy the URL and anon key into the top of `app.js`. The anon key is meant to be public; never put the service_role key anywhere in the repo.

## 2. How people get in

- **Once:** the GM posts the app URL and the signup code (both shown in the GM panel). Each person opens the URL, picks **Register**, and enters their name, dev email, a password and the code. That creates their account permanently.
- **Every game:** the GM ticks who is playing in the lobby panel, then starts the game. Nobody has to be re-added.
- Later games re-use the same people. Only registered people appear in the list.
- Forgotten password: Supabase dashboard → Authentication → Users → the user → Send password recovery, or delete the user and have them register again.
- Rotate the code any time: `update app_config set value = '<new code>' where key = 'signup_code';`

## 3. Headshots

Put `avatars/<email-prefix>.jpg` (e.g. `ada.lovelace.jpg` for `ada.lovelace@org.com`). Missing photos fall back to the initial.

## 4. GitHub Pages

Repo Settings → Pages → Deploy from branch → `main` / root. No build step.

Local check first: `python3 -m http.server 8000` and open `http://localhost:8000/`.

## 5. Dry run (compressed schedule)

Needs 6 registered people ticked into the game plus the GM account. `start_game` checks the caller is the GM, so it can't run from the dashboard SQL editor. Instead, sign in as the GM and run this in the browser console (the GM Start button uses the real weekly schedule):

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

Cleanup: GM panel → Delete game (or `select gm_delete_game('<game-id>')`). People stay registered for the next game.
