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

## 2a. Slack announcements (optional)

Public updates only: a banishment vote opening, a reminder 3 hours before it closes, who was banished or murdered (and their role), and the final result. A banishment result also lists who voted for whom, who did not vote, and notes a random tie-break. The votes are public once the result is out. A recruit round is announced as "Nobody was murdered", exactly as in the app. Nothing secret is ever posted.

1. Go to https://api.slack.com/apps, **Create New App → From scratch**, pick your workspace.
2. **Incoming Webhooks** → turn on → **Add New Webhook to Workspace** → choose the channel → copy the URL (it starts `https://hooks.slack.com/`).
3. In the game's GM panel, paste it under **Slack announcements**, press **Save**, then **Send test**.
4. If your workspace needs an owner to approve new apps, you'll be told when you add the webhook. A fallback that needs no app: Slack **Workflow Builder → From a webhook**, with a text variable named `text`, and a step that posts it to the channel. Use that trigger URL instead.

Use a throwaway channel for the dry run, because Slack messages can't be unsent from here. Press **Disconnect** to stop posting at any time.

## 2b. One-off cleanup after upgrading an existing project

Recruitment replaced two read functions (`my_action`, `traitor_picks`) with `my_pick` and `team_picks`. After re-running `db/schema.sql`, remove the old ones in the SQL editor (the tool that applies migrations won't run `drop`):

```sql
drop function if exists my_action(uuid);
drop function if exists traitor_picks(uuid);
```

## 3. Team photos

The 17 team photos are in `avatars/team-01.webp` to `team-17.webp` (320px, about 11KB each). Nobody's photo is assigned in advance: after registering, each person is shown the gallery and picks theirs ("Which one is you?"). A photo can belong to only one person, taken ones are greyed out, and people can change theirs later with **Change photo** in the top bar. In the GM panel each person's thumbnail shows next to their name, with a **Reset photo** button if someone picked the wrong face.

- **Add a photo:** put `team-18.webp` in `avatars/` and run `insert into photos (key) values ('team-18');`.
- **Pre-assign photos instead:** the choice is stored in `people.avatar_key`, so a one-off `update people set avatar_key = 'team-07' where email = '...';` binds a photo without the person choosing.
- Photos are only fetched for the people in a game plus the gallery, so the images add little to page load.
- If the site is published publicly (GitHub Pages), these photos are public too. Check the team is happy with that first.

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
