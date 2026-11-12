const SUPABASE_URL = 'https://konbcshzmxrghgcwikmi.supabase.co';
// Public by design: security is RLS + server-side functions, not secrecy of this key.
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtvbmJjc2h6bXhyZ2hnY3dpa21pIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE4MDU5NzUsImV4cCI6MjEwNzM4MTk3NX0.gIbw92C-Qanh4zKlHpOeq-KNLd29usrdaR9IGFWA8g8';

const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const app = document.getElementById('app');
const S = { user: null, admin: false, game: null, me: null, players: [], roles: {}, events: [], results: {},
            messages: [], mine: {}, picks: {}, overview: null, dash: null, secrets: null, gmchat: [], curtain: false, person: null, gallery: [], picking: false, skipPhoto: false, gmPick: null, lobbyStep: 'players', tab: 'game', error: '', notice: '', authTab: 'signin', peek: false, archived: [], archiveData: {}, openArchive: null, offer: null, recovery: false, recruits: {}, netError: false, voting: null, voteSel: null, voteKind: 'kill' };

// Names are chosen by the players, so every interpolated value goes through esc().
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const name = id => S.players.find(p => p.id === id)?.display_name ?? '?';
const isOpen = e => e.status === 'open' && new Date(e.closes_at) > new Date();
const countdown = iso => `<span data-t="${esc(iso)}"></span>`;

// One refresh at a time: the 10 s timer and a button press can overlap, and an older answer must not overwrite a newer one.
let refreshing = false, refreshAgain = false;
const NET_MSG = 'Could not reach the game just now. Showing what we had; retrying.';
async function refresh() {
  if (refreshing) { refreshAgain = true; return; }
  refreshing = true;
  try {
    do {
      refreshAgain = false;
      try { await doRefresh(); if (S.netError) { S.netError = false; if (S.error === NET_MSG) S.error = ''; render(); } }
      catch (err) { console.error(err); S.netError = true; if (!S.error) S.error = NET_MSG; render(); }
    } while (refreshAgain);
  } finally { refreshing = false; }
}

async function doRefresh() {
  const { data: { session } } = await sb.auth.getSession();
  S.user = session?.user ?? null;
  if (S.user) {
    S.admin = (await sb.rpc('am_admin')).data === true;
    if (S.admin) S.archived = (await sb.from('games').select('*, players(count)').eq('archived', true).order('created_at', { ascending: false })).data ?? [];
    if (!S.admin) {
      S.person = (await sb.rpc('my_person')).data ?? null;
      if (S.person && (!S.person.avatar_key || S.picking)) S.gallery = (await sb.rpc('photo_gallery')).data ?? [];
    }
    const { data, error } = await sb.from('games').select('*').eq('archived', false).order('created_at', { ascending: false }).limit(1);
    if (error) throw error;
    S.game = data?.[0] ?? null;
    if (S.game) await loadGame();
  }
  render();
}

async function loadGame() {
  const g = S.game.id;
  const [pl, ro, ev, re] = await Promise.all([
    sb.from('players').select('*').eq('game_id', g).order('display_name'),
    sb.from('roles').select('*').eq('game_id', g),
    sb.from('events').select('*').eq('game_id', g).order('opens_at'),
    sb.from('event_results').select('*').eq('game_id', g)]);
  // A failed request must not look like an empty game ("Nothing has happened yet"); keep what we had and say so.
  const failed = [pl, ro, ev, re].find(r => r.error);
  if (failed) throw failed.error;
  S.players = pl.data ?? [];
  S.roles = Object.fromEntries((ro.data ?? []).map(r => [r.player_id, r.role]));
  S.events = ev.data ?? [];
  S.results = Object.fromEntries((re.data ?? []).map(r => [r.event_id, { target: r.target_id, kind: r.kind, accepted: r.accepted, votes: r.votes }]));
  S.me = S.players.find(p => p.user_id === S.user.id) ?? null;
  S.mine = {}; S.endChoice = {}; S.picks = {}; S.messages = []; S.offer = null; S.recruits = {}; S.locks = {};
  if (S.me && S.roles[S.me.id] === 'traitor') {
    // Newest 200, then back into reading order (the oldest 200 would freeze the chat once it got long).
    const { data } = await sb.from('messages').select('*').eq('game_id', g).order('created_at', { ascending: false }).limit(200);
    S.messages = (data ?? []).reverse();
    const rc = await sb.from('recruit_offers').select('*').eq('game_id', g);
    S.recruits = Object.fromEntries((rc.data ?? []).map(r => [r.event_id, { target: r.target_id, accepted: r.accepted }]));
    const lk = await sb.from('murder_locks').select('*').eq('game_id', g);
    S.locks = Object.fromEntries((lk.data ?? []).map(l => [l.event_id, { kind: l.kind, target: l.target_id }]));
  }
  for (const e of S.events.filter(isOpen)) {
    if (!S.me) break;
    const { data } = await sb.rpc('my_pick', { p_event: e.id });
    if (data?.length) S.mine[e.id] = { kind: data[0].kind, target: data[0].target_id };
    if (e.kind === 'endgame') S.endChoice[e.id] = (await sb.rpc('my_endgame', { p_event: e.id })).data;
    if (e.kind === 'murder' && S.roles[S.me.id] === 'traitor') S.picks[e.id] = (await sb.rpc('team_picks', { p_event: e.id })).data ?? [];
  }
  if (S.me?.alive) S.offer = (await sb.rpc('my_offer', { p_game: g })).data ?? null;
  if (S.admin) {
    S.overview = (await sb.rpc('gm_overview', { p_game: g })).data;
    S.dash = (await sb.rpc('gm_dashboard', { p_game: g })).data;
    if (S.curtain) {
      S.secrets = (await sb.rpc('gm_secrets', { p_game: g })).data;
      S.gmchat = (await sb.rpc('gm_chat', { p_game: g })).data ?? [];
    }
  }
}

// Raw database and auth messages are written for developers; the ones people can actually hit get plain words.
// Anything not listed is shown as it came.
const FRIENDLY = [
  [/people_display_name_unique|display_name.*already exists/i, 'That name is already taken. Please choose a different one.'],
  [/people_email_key|people.*email.*already exists|already registered/i, 'That email is already registered. Sign in instead.'],
  [/people_name_ok/i, 'Names must be 1 to 40 characters, with no line breaks.'],
  [/event not open/i, 'That choice has closed or already been locked in.'],
  [/recruitment not available/i, 'You can only recruit when two or fewer traitors are left.'],
  [/invalid target/i, 'You cannot choose that player.'],
  [/not allowed/i, 'You are not allowed to do that.'],
  [/no offer/i, 'There is no offer to answer any more.'],
  [/invalid login credentials/i, 'That email and password do not match.'],
  [/jwt expired|invalid jwt/i, 'Your sign-in has expired. Please sign in again.'],
  [/failed to fetch|networkerror|load failed/i, 'Could not reach the server. Check your connection and try again.'],
  [/duplicate key value|violates (unique|foreign key|check) constraint/i, 'That could not be saved. Please check what you entered and try again.'],
];
const friendly = m => FRIENDLY.find(([re]) => re.test(m))?.[1] ?? m;

async function call(fn, args) {
  const { error } = await sb.rpc(fn, args);
  S.error = error?.message ?? '';
  await refresh();
}

const avatar = (p, size = '') => `<span class="av ${size}"><b>${esc((p.display_name || '?')[0].toUpperCase())}</b>${p.avatar_key ? `<img src="avatars/${esc(p.avatar_key)}.webp" alt="" onerror="this.remove()">` : ''}</span>`;

// Shown until a person has chosen a photo, and again whenever they press "Change photo".
function pickerView() {
  const changing = S.person.avatar_key && S.picking;
  const tiles = S.gallery.map(g => `<button class="pick-photo ${g.mine ? 'mine' : ''}" data-act="photo" data-key="${esc(g.key)}"
    ${g.taken ? 'disabled' : ''} aria-label="Photo ${esc(g.key)}${g.taken ? ', already taken' : ''}"><img src="avatars/${esc(g.key)}.webp" alt=""></button>`).join('');
  const fields = changing ? `<div class="edit-fields"><label>Name<input id="ename" maxlength="40" value="${esc(S.person.name)}" autocomplete="off"></label>
      <label>New password<input id="epw" type="password" placeholder="Leave blank to keep yours" autocomplete="new-password"></label></div>
    <div class="gm-actions"><button data-act="savemine">Save</button></div>` : '';
  return `<h2 style="margin-top:0">${changing ? 'Edit your details' : 'Choose your photo'}</h2>
    ${fields}${changing ? '<h3 style="margin-top:24px">Photo</h3>' : ''}
    <p class="muted">${changing ? 'Pick a new one. Yours is outlined.' : 'Which one is you? This is how everyone in the game will see you.'} Greyed-out photos have been taken.</p>
    <div class="gallery">${tiles}</div>
    ${!changing && !S.gallery.some(g => !g.taken) ? '<p class="warn">Every photo has been taken. Ask the game master to add yours. You can carry on with your initial for now.</p>' : ''}
    ${changing ? '<div class="gm-actions"><button class="ghost" data-act="keepphoto">Back</button></div>'
      : !S.gallery.some(g => !g.taken) ? '<div class="gm-actions"><button data-act="skipphoto">Continue with my initial</button></div>' : ''}`;
}

const murderedIds = () => new Set(S.events.filter(e => e.kind === 'murder' && e.status === 'revealed' && S.results[e.id]?.kind === 'kill').map(e => S.results[e.id].target));

// The finished game: the winning side in full, with a burst of confetti the first time it is shown.
function winnerHero() {
  const g = S.game, traitors = g.winner === 'traitors';
  const team = S.players.filter(p => (S.roles[p.id] === 'traitor') === traitors && S.roles[p.id]);
  const names = team.map(p => esc(p.display_name));
  const who = names.length > 1 ? `${names.slice(0, -1).join(', ')} and ${names.slice(-1)}` : names[0] ?? '';
  const line = traitors ? `The traitors were ${who}. They fooled everyone.` : `${who} found every traitor.`;
  return `<div class="winner ${esc(g.winner)}"><p class="muted">The game is over</p><h1>${traitors ? 'The Traitors win' : 'The Faithful win'}</h1>
    <div class="winners">${team.map(p => `<span class="winface">${avatar(p)}<span class="pname">${esc(p.display_name)}</span></span>`).join('')}</div>
    <p>${line}</p></div>`;
}

function confetti() {
  if (S.celebrated || matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  S.celebrated = true;
  const colours = ['#ff8200', '#ff6685', '#f1dfae', '#730032'];
  for (let i = 0; i < 70; i++) {
    const c = document.createElement('i');
    c.className = 'confetti';
    c.style.cssText = `left:${Math.random() * 100}vw;background:${colours[i % 4]};animation-delay:${Math.random() * 1.5}s;animation-duration:${2.5 + Math.random() * 2}s`;
    document.body.append(c);
    setTimeout(() => c.remove(), 6500);
  }
}

// An archived game is shown with the same screens as a live finished one, by pointing the globals at its data for the render.
async function fetchGame(id) {
  const [pl, ro, ev, re] = await Promise.all([
    sb.from('players').select('*').eq('game_id', id).order('display_name'),
    sb.from('roles').select('*').eq('game_id', id),
    sb.from('events').select('*').eq('game_id', id).order('opens_at'),
    sb.from('event_results').select('*').eq('game_id', id)]);
  return {
    players: pl.data ?? [],
    roles: Object.fromEntries((ro.data ?? []).map(r => [r.player_id, r.role])),
    events: ev.data ?? [],
    results: Object.fromEntries((re.data ?? []).map(r => [r.event_id, { target: r.target_id, kind: r.kind, accepted: r.accepted, votes: r.votes }]))
  };
}

function archivedGameView(g) {
  const d = S.archiveData[g.id];
  if (!d) return '<p class="muted">Loading…</p>';
  const keep = { game: S.game, players: S.players, roles: S.roles, events: S.events, results: S.results, me: S.me };
  Object.assign(S, { game: g, ...d, me: null });
  try { return `${winnerHero()}${playerGrid()}<h3>What happened</h3>${timeline(Infinity)}`; } finally { Object.assign(S, keep); }
}

function archivedList() {
  if (!S.archived.length) return '';
  const items = S.archived.map(g => {
    const open = S.openArchive === g.id;
    return `<li><button class="archrow" data-act="archiveopen" data-id="${esc(g.id)}" aria-expanded="${open}">
      <span><b>${g.winner === 'traitors' ? 'The Traitors won' : g.winner === 'faithful' ? 'The Faithful won' : 'Not finished'}</b>
      <span class="muted">${new Date(g.created_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })}, ${g.players?.[0]?.count ?? 0} players</span></span>
      <span class="caret">${open ? 'Hide' : 'Show'}</span></button>${open ? `<div class="archbody">${archivedGameView(g)}</div>` : ''}</li>`;
  }).join('');
  return `<h2>Archived games</h2><ul class="archive">${items}</ul>`;
}

// The quiet screens: no game yet, in the lobby, or not added. One wax seal, a line that sets the mood, and how the game works.
function waitingView(title, extra = '', start = ['Now you are registered, the game master can add you to the next game.', 'They then choose the traitors and the game begins.']) {
  return `<div class="waiting"><span class="seal big">?</span><h1>${title}</h1>${extra}
    <div class="rules"><h3>How the game starts</h3><ul>${start.map(t => `<li>${t}</li>`).join('')}</ul>
    <h3 class="next">How it works</h3><ul>
      <li>Twice a week the group will choose to banish one player.</li>
      <li>Twice a week the traitors choose a victim, or recruit someone to join them.</li>
      <li>The faithful hunt the traitors. The traitors blend in and wait.</li>
      <li>Near the end, we enter the end game, where roles are no longer revealed.</li>
      <li>It finishes when only two remain, or all players agree to end the game. Who will win, the traitors or the faithful?</li>
    </ul></div></div>`;
}

function playerGrid() {
  const mineTraitor = S.me && S.roles[S.me.id] === 'traitor';
  const murdered = murderedIds();
  return `<div class="grid">${S.players.map(p => {
    const role = S.roles[p.id];
    // Our own role and fellow traitors only show while the sealed role card is open, so a glance at the grid gives nothing away.
    const tag = role && (!p.alive || p.revealed || S.game.status === 'finished' || ((p.id === S.me?.id || mineTraitor) && (S.peek || !S.me?.alive)))
      ? `<span class="tag ${role}">${role}</span>` : '';
    return `<div class="player ${p.alive ? '' : 'dead'}"><span class="avwrap">${avatar(p)}${murdered.has(p.id) ? '<img class="slain" src="assets/murdered.svg" alt="Murdered">' : ''}</span><span class="pname">${esc(p.display_name)}</span><br>${tag}</div>`;
  }).join('')}</div>`;
}

// The traitors have until picks_close_at to agree; windows saved before that was added just use the close.
const traitorClock = e => `<p class="clock">${countdown(e.picks_close_at ?? e.closes_at)}<small>to agree</small></p>`;

function eventPanel(e) {
  const me = S.me, murder = e.kind === 'murder';
  if (!me?.alive) return '';
  const mine = S.mine[e.id];
  const clock = e.untimed ? '<p class="clock"><small>No deadline: it closes when everyone has answered</small></p>'
                          : `<p class="clock">${countdown(e.closes_at)}<small>left to decide</small></p>`;
  if (e.kind === 'endgame') {
    const c = S.endChoice[e.id];
    const pick = (end, label) => `<button class="${c === end ? '' : 'ghost'}" data-act="endgame" data-ev="${esc(e.id)}" data-end="${end}">${label}</button>`;
    return `<div class="slip"><h3>The end game</h3>${clock}
      <p>If everyone chooses to end the game, it ends. If no traitor is left, the Faithful win. If any traitor is still here, the Traitors win. One vote to keep playing and it goes on.</p>
      <div class="row">${pick(true, 'End the game')}${pick(false, 'Keep playing')}</div>
      <p class="muted choice">Your choice: ${c === true ? 'end the game' : c === false ? 'keep playing' : 'nothing yet'}. You can change it until everyone has answered.</p></div>`;
  }
  if (!murder) {
    const voted = mine?.target && S.players.find(p => p.id === mine.target);
    // A murder can land while a banishment is still open; votes for the victim are dropped at the close.
    const stale = voted && !voted.alive;
    const body = !voted ? `<p>You haven't voted yet.</p><div class="row"><button data-act="votescreen" data-ev="${esc(e.id)}">Cast your vote</button></div>`
      : stale ? `<p class="warn">Your vote was for ${esc(voted.display_name)}, who is out of the game. It won't count. Choose again before the vote closes.</p>
          <div class="row"><button data-act="votescreen" data-ev="${esc(e.id)}">Choose again</button></div>`
      : `<div class="voted"><span class="muted">You voted for</span><span class="voteface">${avatar(voted)}<b class="bigname">${esc(voted.display_name)}</b></span></div>
          <div class="row"><button class="ghost" data-act="votescreen" data-ev="${esc(e.id)}">Change vote</button></div>
          <p class="muted choice">${e.untimed ? 'You can change it until everyone has voted.' : 'You can change it until the vote closes.'}</p>`;
    return `<div class="slip"><h3>Banishment vote</h3>${clock}${body}</div>`;
  }
  if (S.roles[me.id] !== 'traitor') return '';
  const traitorsLeft = S.players.filter(p => p.alive && S.roles[p.id] === 'traitor').length;
  const canRecruit = traitorsLeft <= 2;
  const picked = mine?.target && S.players.find(p => p.id === mine.target);
  const team = (S.picks[e.id] ?? []).map(k => `${esc(name(k.player_id))} → ${esc(k.target_id ? `${k.kind === 'recruit' ? 'recruit ' : ''}${name(k.target_id)}` : 'nobody')}`).join(', ');
  const lock = S.locks[e.id];
  if (lock) {
    const t = lock.target && S.players.find(p => p.id === lock.target);
    const what = !t ? '<div class="voted"><b class="bigname">Nobody</b></div>'
      : `<div class="voted"><span class="muted">${lock.kind === 'recruit' ? 'Recruited' : 'Murder'}</span><span class="voteface">${avatar(t)}<b class="bigname">${esc(t.display_name)}</b></span></div>`;
    return `<div class="slip murder"><h3>The traitors have decided</h3>${what}
      <p class="muted choice">${lock.kind === 'recruit' && t ? 'They are a traitor now and can refuse until the window closes. If they do, they are murdered.' : t ? 'The murder is revealed with the next results.' : 'Nobody was chosen, so nobody will be murdered.'}</p></div>`;
  }
  const body = !mine ? '<p>You haven\'t chosen yet.</p>'
    : picked ? `<div class="voted"><span class="muted">${mine.kind === 'recruit' ? 'You suggest recruiting' : 'You suggest murdering'}</span><span class="voteface">${avatar(picked)}<b class="bigname">${esc(picked.display_name)}</b></span></div>`
    : '<div class="voted"><span class="muted">Your pick</span><b class="bigname">Nobody</b></div>';
  return `<div class="slip murder"><h3>${canRecruit ? 'Murder or recruit' : 'Choose a victim'}</h3>${traitorClock(e)}
    <p class="muted">${canRecruit ? `Only ${traitorsLeft} traitor${traitorsLeft === 1 ? '' : 's'} left, so you can recruit a faithful instead of murdering. A recruit becomes a traitor at once, but can refuse, and then they are murdered. ` : ''}Each traitor suggests someone. When more than half of you name the same person, it is locked in. At the deadline, one of the suggestions is chosen at random.</p>
    ${body}<div class="row"><button ${mine ? 'class="ghost"' : ''} data-act="votescreen" data-ev="${esc(e.id)}">${mine ? 'Change suggestion' : 'Suggest'}</button></div>
    ${team ? `<p class="muted choice">Suggestions: ${team}</p>` : ''}</div>`;
}

// Full-screen vote: clock and Cast vote stay at the top, the choice is a ring round a photo, and nothing is sent until Cast vote.
function voteView(e) {
  const me = S.me, sel = S.voteSel;
  const targets = S.players.filter(p => p.alive && p.id !== me.id);
  const picked = targets.find(p => p.id === sel);
  const clock = e.untimed ? '<p class="clock"><small>No deadline: it closes when everyone has voted</small></p>'
                          : `<p class="clock">${countdown(e.closes_at)}<small>left to decide</small></p>`;
  const tiles = targets.map(p => `<label class="tile"><input type="radio" name="vote" value="${esc(p.id)}" ${p.id === sel ? 'checked' : ''}>
    <span class="face">${avatar(p)}</span><span class="pname">${esc(p.display_name)}</span></label>`).join('');
  return `<div class="votebar"><h2>Vote to banish</h2>${clock}
    <div class="row"><button data-act="cast" data-ev="${esc(e.id)}" ${picked ? '' : 'disabled'}>${picked ? `Cast vote for ${esc(picked.display_name)}` : 'Cast vote'}</button>
    <button class="ghost" data-act="voteback">Back</button></div>
    <p class="muted choice">${picked ? `Selected: ${esc(picked.display_name)}` : 'Choose who to banish.'}</p></div>
    <div class="tiles">${tiles}</div>`;
}

function murderView(e) {
  const me = S.me, sel = S.voteSel, kind = S.voteKind;
  const targets = S.players.filter(p => p.alive && S.roles[p.id] !== 'traitor');
  const canRecruit = S.players.filter(p => p.alive && S.roles[p.id] === 'traitor').length <= 2;
  const picked = targets.find(p => p.id === sel);
  const verb = kind === 'recruit' ? 'Recruit' : 'Murder';
  const clock = traitorClock(e);
  const tiles = targets.map(p => `<label class="tile"><input type="radio" name="vote" value="${esc(p.id)}" ${p.id === sel ? 'checked' : ''}>
    <span class="face">${avatar(p)}</span><span class="pname">${esc(p.display_name)}</span></label>`).join('');
  const mode = (k, label) => `<button class="ghost ${kind === k ? 'active' : ''}" data-act="votekind" data-kind="${k}">${label}</button>`;
  return `<div class="votebar"><h2>${canRecruit ? 'Murder or recruit' : 'Choose a victim'}</h2>${clock}
    ${canRecruit ? `<div class="seg" style="margin:0 0 12px">${mode('kill', 'Murder')}${mode('recruit', 'Recruit')}</div>` : ''}
    <div class="row"><button data-act="cast" data-ev="${esc(e.id)}" ${picked ? '' : 'disabled'}>${picked ? `${canRecruit ? verb + ' ' : 'Murder '}${esc(picked.display_name)}` : 'Suggest'}</button>
    <button class="ghost" data-act="voteback">Back</button></div>
    ${kind === 'recruit' && canRecruit ? '<p class="muted choice">They become a traitor at once, but can refuse, and then they are murdered.</p>' : ''}</div>
    <div class="tiles">${tiles}</div>`;
}

// The last players show their roles one at a time; the winner is announced after the last one.
function revealPanel() {
  const left = S.players.filter(p => p.alive && !p.revealed);
  const names = left.map(p => esc(p.display_name)).join(', ');
  if (S.admin) {
    const rows = left.map(p => `<div class="pick-row"><span class="pick">${avatar(p, 'sm')} ${esc(p.display_name)}</span>
      <button class="ghost small" data-act="gmreveal" data-player="${esc(p.id)}">Reveal</button></div>`).join('');
    return `<div class="slip"><h3>Roles to reveal</h3><p class="muted">The players still standing show who they are. The winner is announced after the last one. You can reveal anyone yourself.</p>
      ${rows || '<p class="muted">Everyone has revealed.</p>'}${left.length ? '<div class="row" style="margin-top:12px"><button data-act="gmrevealall">Reveal all</button></div>' : ''}</div>`;
  }
  const mine = S.me?.alive && !S.me.revealed;
  return `<div class="slip"><h3>Time to reveal</h3>
    <p>The game is nearly over. The players still standing now show who they are, and then the winner is announced.</p>
    ${mine ? '<div class="row"><button data-act="revealme">Reveal my role</button></div>'
      : S.me?.alive ? '<p class="muted">You have revealed your role.</p>' : ''}
    ${left.length ? `<p class="muted choice">Still to reveal: ${names}.</p>` : ''}</div>`;
}

function offerCard() {
  const e = S.events.find(x => x.id === S.offer);
  return `<div class="slip murder"><h3>The traitors have chosen you</h3>
    <p>You are a traitor now. Refuse and you will be murdered. If you do nothing you stay a traitor, and nobody else will know either way.</p>
    <p class="clock">${e ? countdown(e.closes_at) : ''}<small>left to refuse</small></p>
    <div class="row"><button class="ghost" data-act="refuse" data-ev="${esc(S.offer)}">Refuse and be murdered</button></div></div>`;
}

function resultItem(e) {
  const r = S.results[e.id], verb = e.kind === 'banishment' ? 'banished' : 'murdered';
  if (e.kind === 'endgame') return `<li class="banishment">${r?.accepted ? 'Everyone chose to end the game.' : 'Not everyone chose to end the game, so it goes on.'}</li>`;
  // Only traitors can read the recruit offer; everyone else just sees an ordinary quiet round.
  const rc = S.recruits[e.id];
  if (rc) {
    return `<li class="${esc(e.kind)}"><b>${esc(name(rc.target))}</b> ${rc.accepted === false ? 'refused to join and was murdered.' : 'was recruited and joined the traitors.'}</li>`;
  }
  const t = r?.target;
  // The saved text is the same breakdown Slack gets: a "Votes:" line, then one line per target, then notes.
  const votes = r?.votes ? `<div class="votes"><b>Votes</b><br>${r.votes.split('\n').slice(1).map(esc).join('<br>')}</div>` : '';
  return `<li class="${esc(e.kind)}">${t ? `<b>${esc(name(t))}</b> was ${verb}.${S.roles[t] ? ` They were ${esc(S.roles[t])}.` : ''}` : `Nobody was ${verb}.`}${votes}</li>`;
}

// Results the viewer hasn't dismissed yet, so a vote that closes while they are looking at the game can't go unnoticed.
const seenKey = () => `tt-seen-${S.game.id}`;
function newsBanner() {
  const done = S.events.filter(e => e.status === 'revealed');
  let seen = null;
  try { seen = localStorage.getItem(seenKey()); } catch {}
  const i = done.findIndex(e => e.id === seen);
  const fresh = (i < 0 ? done : done.slice(i + 1)).slice(-3).reverse();
  if (!fresh.length) return '';
  return `<div class="news"><h3>What just happened</h3><ol class="timeline">${fresh.map(resultItem).join('')}</ol>
    <div class="row"><button data-act="seennews">Got it</button></div></div>`;
}

function timeline(limit = 6) {
  // Every final reveal is kept, however many results there are; only the older event results are capped.
  const events = S.events.filter(e => e.status === 'revealed').slice(-limit).map(e => ({ t: new Date(e.reveals_at), html: resultItem(e) }));
  const reveals = S.players.filter(p => p.revealed && S.roles[p.id]).map(p => ({
    t: new Date(p.revealed_at ?? Date.now()),
    html: `<li class="banishment"><b>${esc(p.display_name)}</b> revealed they were ${S.roles[p.id] === 'traitor' ? 'a traitor' : 'faithful'}.</li>` }));
  const items = [...events, ...reveals].sort((a, b) => b.t - a.t).map(x => x.html).join('');
  return items ? `<ol class="timeline">${items}</ol>` : '<p class="muted">Nothing has happened yet.</p>';
}

function roleCard(role) {
  const me = S.me, traitor = role === 'traitor';
  if (me.alive && !S.peek) {
    return `<button class="role sealed" data-act="peek"><span class="seal">?</span>
      <span><b>Your role is sealed</b><br><span class="muted">Tap to look. It hides again after a few seconds.</span></span></button>`;
  }
  const mates = traitor ? S.players.filter(p => S.roles[p.id] === 'traitor' && p.id !== me.id).map(p => esc(p.display_name)) : [];
  const line = !me.alive ? 'You are out of the game.'
    : traitor ? (mates.length ? `With ${mates.join(', ')}. Pick a victim when a murder opens.` : 'You are the last traitor.')
    : 'Find the traitors and banish them.';
  return `<div class="role open ${S.peekNew ? 'anim ' : ''}${esc(role)}"><span class="seal ${traitor ? '' : 'faithful'}">${traitor ? 'T' : 'F'}</span>
    <span><span class="roleName">${traitor ? 'Traitor' : 'Faithful'}</span><br><span class="muted">${line}</span></span></div>`;
}

function chat() {
  return `<div class="chat" id="log">${S.messages.map(m => `<p><b>${m.from_gm ? 'Game master' : esc(name(m.player_id))}</b>: ${esc(m.body)}</p>`).join('')}</div>
    <div class="row" style="margin-top:12px"><input id="chat" maxlength="500" placeholder="Message fellow traitors"><button data-act="send">Send</button></div>`;
}

// The GM choosing a photo for someone else. Same gallery, but each tile acts on the chosen person.
function gmPickerView() {
  const g = S.gmPick;
  const tiles = g.gallery.map(t => `<button class="pick-photo ${t.mine ? 'mine' : ''}" data-act="gmphoto" data-key="${esc(t.key)}"
    ${t.taken ? 'disabled' : ''} aria-label="Photo ${esc(t.key)}${t.taken ? ', already taken' : ''}"><img src="avatars/${esc(t.key)}.webp" alt=""></button>`).join('');
  const has = g.gallery.some(t => t.mine);
  return `<h2 style="margin-top:0">Edit ${esc(g.name)}</h2>
    <div class="edit-fields"><label>Name<input id="ename" maxlength="40" value="${esc(g.name)}" autocomplete="off"></label>
      <label>New password<input id="epw" type="text" placeholder="Leave blank to keep theirs" autocomplete="off"></label></div>
    <div class="gm-actions"><button data-act="gmsave">Save</button></div>
    <h3 style="margin-top:24px">Photo</h3>
    <p class="muted">Pick one for them. Theirs is outlined, and greyed-out photos belong to someone else.</p>
    <div class="gallery">${tiles}</div>
    <div class="gm-actions"><button class="ghost" data-act="gmphotocancel">Back</button>
    ${has ? '<button class="ghost" data-act="gmphotoremove">Remove their photo</button>' : ''}</div>`;
}

// Lobby, step 1 and 2. Each person is a photo tile: the checkbox is hidden and the photo ring shows the choice.
function personTile(p, act, on, photoLink) {
  return `<label class="tile"><input type="checkbox" data-act="${act}" data-user="${esc(p.user_id)}" ${on ? 'checked' : ''}>
    <span class="face">${avatar({ display_name: p.name, avatar_key: p.avatar_key })}</span>
    <span class="pname">${esc(p.name)}</span><span class="muted email">${esc(p.email)}</span>
    ${photoLink ? `<a href="#" data-act="choosephoto" data-user="${esc(p.user_id)}" data-name="${esc(p.name)}">Edit</a>` : ''}</label>`;
}

function playersStep() {
  const o = S.overview;
  const people = o?.people ?? [];
  const short = (o?.players ?? 0) < 6;
  return `<h2 style="margin-top:0">Who is playing?</h2>
    <p class="muted">Tick everyone who is in this game. ${o?.players ?? 0} selected${short ? ', and you need at least 6' : ''}.</p>
    ${people.length ? `<div class="tiles">${people.map(p => personTile(p, 'toggle', p.in_game, true)).join('')}</div>` : '<p class="muted">Nobody has registered yet.</p>'}
    <div class="gm-actions"><button data-act="lobbynext" ${short ? 'disabled' : ''}>Next: choose the traitors</button></div>
    <div class="gm-panel">${gmPanel()}</div>`;
}

// The GM decides who the traitors are, from the people ticked into the game. Nothing ticked means random.
function traitorsStep() {
  const players = (S.overview?.people ?? []).filter(p => p.in_game);
  const n = players.length, chosen = players.filter(p => p.traitor).length;
  const tooMany = chosen > 0 && chosen >= n - chosen;
  const note = tooMany ? `${chosen} of ${n} is too many: there must be fewer traitors than faithful.`
    : chosen ? `${chosen} traitor${chosen === 1 ? '' : 's'} chosen, ${n - chosen} faithful.`
    : `Nobody chosen, so ${Math.min(3, Math.max(2, Math.round(n / 6)))} will be picked at random when you start.`;
  return `<h2 style="margin-top:0">Choose the traitors</h2>
    <p class="muted">Tick who the traitors are. Players only learn their role when you press Start.</p>
    <div class="tiles">${players.map(p => personTile(p, 'traitor', p.traitor, false)).join('')}</div>
    <p class="${tooMany ? 'warn' : 'muted'}">${note}</p>
    <div class="gm-actions"><button class="ghost" data-act="lobbyback">Back</button><button data-act="start" ${tooMany ? 'disabled' : ''}>Start game</button></div>`;
}

function dashboard() {
  const d = S.dash;
  if (!d || S.game.status !== 'active') return '';
  const label = e => e.kind === 'endgame' ? 'End game vote' : e.kind === 'banishment' ? 'Banishment vote' : 'Murder window';
  const controls = e => `<div class="row"><button class="ghost" data-act="close" data-ev="${esc(e.id)}">Close now</button>
    ${e.untimed ? '' : `<button class="ghost" data-act="extend" data-ev="${esc(e.id)}" data-by="6 hours">Add 6 hours</button>
    <button class="ghost" data-act="extend" data-ev="${esc(e.id)}" data-by="1 day">Add a day</button>`}
    ${e.kind === 'banishment' ? `<button class="ghost" data-act="remind" data-ev="${esc(e.id)}">Nudge on Slack</button>` : ''}
    ${e.kind === 'endgame' ? '' : `<button class="ghost" data-act="skip" data-ev="${esc(e.id)}">Skip, no result</button>`}</div>`;
  let nextShown = false;
  const items = d.events.map(e => {
    if (e.status === 'scheduled') {
      if (nextShown) return '';
      nextShown = true;
      return `<div class="dash-item"><b>Up next: ${label(e).toLowerCase()}</b><p class="muted">Opens in ${countdown(e.opens_at)}</p></div>`;
    }
    if (e.status === 'closed') {
      return `<div class="dash-item"><b>${label(e)} closed</b><p class="muted">Result announced in ${countdown(e.reveals_at)}</p></div>`;
    }
    // Participation only: for murders the GM sees how many traitors have chosen, never who or what.
    const vote = e.kind !== 'murder';
    const done = vote ? e.voted : e.picked, total = vote ? e.voters : e.traitors;
    const pct = total ? Math.round(100 * done / total) : 0;
    const who = vote
      ? (e.not_voted.length ? `<p class="muted">Still to vote: ${e.not_voted.map(esc).join(', ')}</p>` : '<p class="muted">Everyone has voted.</p>')
      : '';
    return `<div class="dash-item"><b>${label(e)}</b>
      <p class="muted">${done} of ${total} ${vote ? 'have voted' : 'traitors have chosen'}. ${e.untimed ? 'No deadline: it closes when everyone has answered.' : `Closes in ${countdown(e.closes_at)}`}</p>
      <div class="meter"><i style="width:${pct}%"></i></div>${who}${controls(e)}</div>`;
  }).join('');
  const turnout = d.history.length ? `<p class="muted">Recent votes, newest first: ${d.history.map(h => `${h.voted} voted`).join(', ')}</p>` : '';
  const endCard = d.phase === 'normal' && !S.game.revealing ? `<div class="dash-item"><b>Start the end game early</b><p class="muted">Voids anything open, cancels everything scheduled and starts the final banishment. The end game vote follows it.</p>
      <div class="row"><button class="ghost" data-act="startend">Start the end game now</button></div></div>`
      : `<div class="dash-item"><b>${d.phase === 'final' ? 'Final banishment' : 'End game'}</b><p class="muted">No murders and no deadlines now. Each vote closes when everyone alive has answered.</p></div>`;
  return `<div class="card wide"><h3>Right now</h3><div class="dash-cols">
    <div><div class="stats"><div><b>${d.alive}</b><span>alive</span></div><div><b>${d.out}</b><span>out</span></div></div>${endCard}</div>
    <div>${items || '<p class="muted">Nothing is scheduled.</p>'}${turnout}</div>
    <div><div class="dash-item"><b>Delay the whole game</b><p class="muted">Moves every event still to come, for a holiday or an outage.</p>
      <div class="row"><button class="ghost" data-act="shift" data-by="1 day">Delay a day</button>
      <button class="ghost" data-act="shift" data-by="2 days">Delay 2 days</button></div></div></div></div></div>`;
}

// Everything, including roles and picks. Hidden until asked for so the GM never spoils themself by accident.
function curtain() {
  if (!S.curtain) return `<div class="card"><h3>Behind the curtain</h3><p class="muted">Roles, every vote and pick, recruit offers and the traitors chat.</p>
    <button class="ghost" data-act="curtain">Show</button></div>`;
  const sec = S.secrets;
  if (!sec) return `<div class="card"><h3>Behind the curtain</h3><p class="muted">Loading…</p></div>`;
  const roleTag = p => p.role ? `<span class="tag ${esc(p.role)}">${esc(p.role)}</span>` : '';
  const murdered = murderedIds();
  const players = sec.players.map(p => `<p class="${p.alive ? '' : 'muted'}">${p.alive ? '' : '<s>'}${esc(p.name)}${p.alive ? '' : '</s>'} ${murdered.has(p.id) ? '<img class="mini-cross" src="assets/murdered.svg" alt="Murdered" title="Murdered">' : ''}${roleTag(p)}</p>`).join('');
  const picks = sec.picks.map(k => k.event_kind === 'endgame'
    ? `<p>End game: <b>${esc(k.who)}</b> → ${k.end_vote === true ? 'end the game' : k.end_vote === false ? 'keep playing' : 'answered'}</p>`
    : `<p>${k.event_kind === 'banishment' ? 'Vote' : 'Traitor pick'}: <b>${esc(k.who)}</b> → ${esc(k.target ? `${k.kind === 'recruit' ? 'recruit ' : ''}${k.target}` : 'nobody')}</p>`).join('');
  const offers = sec.offers.map(o => `<p>Recruit offer to <b>${esc(o.target)}</b>: ${o.accepted === false ? 'refused and is murdered' : 'recruited, can refuse until the window closes'}</p>`).join('');
  const chat = S.gmchat.map(m => `<p><b>${esc(m.who)}</b>: ${esc(m.body)}</p>`).join('') || '<p class="muted">No messages yet.</p>';
  return `<div class="card"><h3>Behind the curtain</h3>
    <div class="dash-item"><b>Players and roles</b>${players}</div>
    <div class="dash-item"><b>Open picks</b>${picks || '<p class="muted">Nothing chosen yet.</p>'}${offers}</div>
    <div class="dash-item"><b>Traitors chat</b><div class="chat" id="log">${chat}</div>
      <div class="row" style="margin-top:12px"><input id="gmchat" maxlength="500" placeholder="Speak to the traitors as the Game master" autocomplete="off">
      <button data-act="gmsend">Send</button></div></div>
    <div class="gm-actions"><button class="ghost" data-act="curtain">Hide</button></div></div>`;
}

function gmPanel() {
  const o = S.overview;
  if (!o) return '';
  const lobby = S.game.status === 'lobby';
  const people = lobby ? '' : o.people.map(p => `<div class="pick-row"><label class="pick"><input type="checkbox" disabled ${p.in_game ? 'checked' : ''}>
    ${avatar({ display_name: p.name, avatar_key: p.avatar_key }, 'sm')} ${esc(p.name)} <span class="muted">${esc(p.email)}</span></label>
    <a href="#" data-act="choosephoto" data-user="${esc(p.user_id)}" data-name="${esc(p.name)}">Edit</a></div>`).join('');
  return `<div class="card"><h3>Game master</h3>
    <p class="muted">To register, people open this address and enter the signup code.</p>
    <div class="share"><b>${esc(location.origin + location.pathname)}</b><br>Signup code: <b>${esc(o.signup_code ?? '(not set)')}</b></div>
    ${lobby ? '' : `<p class="muted">${o.players} selected for this game.</p>${people || '<p class="muted">Nobody has registered yet.</p>'}`}
    <h3 style="margin-top:20px">Slack announcements</h3>
    <p class="muted">${o.slack_on ? 'Connected. Votes opening, reminders, results and the final outcome are posted.' : 'Not connected. Paste a Slack webhook URL to post public updates to a channel.'}</p>
    <div class="row"><input id="slackurl" placeholder="https://hooks.slack.com/..." autocomplete="off">
      <button data-act="slacksave">Save</button>
      ${o.slack_on ? '<button class="ghost" data-act="slacktest">Send test</button><button class="ghost" data-act="slackoff">Disconnect</button>' : ''}</div>
    <div class="gm-actions split"><button class="ghost" data-act="delete">Delete game</button>${S.game.status === 'finished' ? '<button class="ghost" data-act="archive">Archive this game</button>' : ''}</div></div>`;
}

function view() {
  if (!S.user) {
    const tab = (id, label) => `<button class="ghost ${S.authTab === id ? 'active' : ''}" data-act="authtab" data-tab="${id}">${label}</button>`;
    const form = S.authTab === 'signin'
      ? `<div class="form"><input id="email" type="email" placeholder="Email" autocomplete="username">
         <input id="pw" type="password" placeholder="Password" autocomplete="current-password"><button data-act="login">Sign in</button>
         <a href="#" data-act="forgot">Forgot your password?</a></div>`
      : `<div class="form"><input id="rname" placeholder="Your name" maxlength="40"><input id="remail" type="email" placeholder="Work email" autocomplete="username">
         <input id="rpw" type="password" placeholder="Choose a password (8+ characters)" autocomplete="new-password">
         <input id="rpw2" type="password" placeholder="Confirm password" autocomplete="new-password">
         <input id="rcode" placeholder="Signup code"><button data-act="register">Register</button></div>`;
    return `<div class="auth"><div class="hero"><h1>Traitors</h1><p>Banishments, murders and bluffing, played in spare minutes over a few weeks.</p></div>
      <div class="seg">${tab('signin', 'Sign in')}${tab('register', 'Register')}</div>${form}</div>`;
  }
  if (S.recovery) return `<h2 style="margin-top:0">Choose a new password</h2><div class="form"><input id="np1" type="password" placeholder="New password (8+ characters)" autocomplete="new-password">
    <input id="np2" type="password" placeholder="Confirm new password" autocomplete="new-password"><button data-act="newpw">Save password</button></div>`;
  const ve = S.voting && S.me?.alive && S.events.find(x => x.id === S.voting && isOpen(x));
  if (ve) return ve.kind === 'murder' ? murderView(ve) : voteView(ve);
  S.voting = null;
  if (S.admin && S.gmPick) return gmPickerView();
  if (!S.admin && S.person && ((!S.person.avatar_key && !S.skipPhoto) || S.picking)) return pickerView();
  const g = S.game;
  if (!g) return S.admin ? `<p>No game yet.</p><button data-act="create">Create game</button>${archivedList()}` : waitingView('The doors are closed.');
  if (g.status === 'lobby') {
    if (S.admin) return S.lobbyStep === 'traitors' ? traitorsStep() : playersStep();
    const n = S.players.length;
    return S.me ? waitingView('You are at the table.',
                  `<h2>${n} ${n === 1 ? 'player' : 'players'} so far</h2>${playerGrid()}`,
                  ['You are registered and the game master has added you to this game.', 'They now choose the traitors and the game begins.'])
                : waitingView('Not at the table yet.', '<p class="muted">The game master has not added you to this game. Ask them to tick your name.</p>');
  }
  if (g.status === 'finished') {
    return `${winnerHero()}${playerGrid()}<h2>What happened</h2>${timeline()}${S.admin ? gmPanel() : ''}${S.admin ? '<div class="gm-actions"><button data-act="create">New game</button></div>' + archivedList() : ''}`;
  }
  if (S.admin) return `${newsBanner()}${g.revealing ? revealPanel() : ''}<h2>Game in progress</h2><div class="gm-grid">${dashboard()}${curtain()}${gmPanel()}</div>`;
  if (!S.me) return `<p>A game is in progress and you're not in it.</p>`;
  const role = S.roles[S.me.id], isTraitor = role === 'traitor';
  const tabs = isTraitor ? `<div class="seg" style="margin:0 0 20px"><button class="ghost ${S.tab === 'game' ? 'active' : ''}" data-act="tab" data-tab="game">Game</button>
    <button class="ghost ${S.tab === 'chat' ? 'active' : ''}" data-act="tab" data-tab="chat">Traitors chat</button></div>` : '';
  if (isTraitor && S.tab === 'chat') return `${tabs}<h2 style="margin-top:0">Traitors chat</h2>${chat()}`;
  const finalNote = S.game.revealing ? '' : S.game.phase !== 'normal' ? '<p class="muted">The final stages. There are no more murders and roles are no longer revealed. Each vote closes when everyone alive has answered.</p>' : '';
  return `${tabs}${finalNote}${S.offer ? offerCard() : ''}${roleCard(role)}
    ${newsBanner()}${S.game.revealing ? revealPanel() : ''}${S.events.filter(isOpen).map(eventPanel).join('')}<h2>Players</h2>${playerGrid()}<h2>What happened</h2>${timeline()}`;
}

function render() {
  const keep = {};
  app.querySelectorAll('select,input').forEach(e => { keep[e.id] = e.value; });
  const focus = document.activeElement?.id;
  const header = S.user ? `<div class="bar"><span class="who"><span class="muted">${S.person ? `<b class="uname">${esc(S.person.name)}</b> ` : ''}${esc(S.user.email)}</span>${S.person && !S.admin && (S.person.avatar_key || S.skipPhoto) && !S.picking ? `<a href="#" data-act="changephoto">Edit</a>` : ''}<button class="ghost" data-act="logout">Sign out</button></span></div>` : '';
  app.innerHTML = header + (S.error ? `<div class="error">${esc(friendly(S.error))}</div>` : '')
    + (S.notice ? `<div class="notice">${esc(S.notice)}</div>` : '') + view()
    + (S.user ? `<footer class="site-foot"><img src="assets/dev-x-traitors.svg" alt="DEV x Traitors" width="233" height="60"></footer>` : '');
  for (const [id, v] of Object.entries(keep)) { const e = document.getElementById(id); if (e && id) e.value = v; }
  if (focus) document.getElementById(focus)?.focus();
  if (S.game?.status === 'finished' && S.user) confetti();
  const log = document.getElementById('log');
  if (log) log.scrollTop = log.scrollHeight;
  tick();
}

function tick() {
  document.querySelectorAll('[data-t]').forEach(el => {
    const s = Math.max(0, Math.round((new Date(el.dataset.t) - Date.now()) / 1000));
    el.textContent = s >= 86400 ? `${Math.floor(s / 86400)}d ${Math.floor(s % 86400 / 3600)}h` : `${Math.floor(s / 3600)}h ${Math.floor(s % 3600 / 60)}m ${s % 60}s`;
  });
}

const actions = {
  login: () => actions.loginWith(document.getElementById('email').value.trim(), document.getElementById('pw').value),
  loginWith: async (email, password) => {
    const { error } = await sb.auth.signInWithPassword({ email, password });
    S.error = error?.message ?? '';
    await refresh();
  },
  peek: () => {
    S.peek = true;
    S.peekNew = true; // only the render caused by the tap animates; the 10 s refresh re-renders without replaying it
    render();
    S.peekNew = false;
    clearTimeout(S.peekTimer);
    S.peekTimer = setTimeout(() => { S.peek = false; render(); }, 6000);
  },
  forgot: async () => {
    const email = document.getElementById('email').value.trim();
    if (!email) { S.error = 'Enter your email above first.'; return render(); }
    const { error } = await sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname });
    S.error = error?.message ?? '';
    if (!error) S.notice = 'If that email is registered, a reset link is on its way.';
    render();
  },
  newpw: async () => {
    const a = document.getElementById('np1').value, b = document.getElementById('np2').value;
    if (a.length < 8) { S.error = 'Password must be at least 8 characters'; return render(); }
    if (a !== b) { S.error = 'The two passwords do not match'; return render(); }
    const { error } = await sb.auth.updateUser({ password: a });
    S.error = error?.message ?? '';
    if (!error) { S.recovery = false; S.notice = 'Password changed.'; }
    await refresh();
  },
  authtab: el => { S.authTab = el.dataset.tab; S.error = ''; render(); },
  register: async () => {
    const v = id => document.getElementById(id).value;
    if (v('rpw') !== v('rpw2')) { S.error = "Passwords don't match"; return render(); }
    const { data, error } = await sb.functions.invoke('register', { body: { name: v('rname'), email: v('remail'), password: v('rpw'), code: v('rcode') } });
    if (error || !data?.ok) {
      S.error = (await error?.context?.json?.().catch(() => null))?.error ?? error?.message ?? 'Registration failed';
      return render();
    }
    await actions.loginWith(v('remail'), v('rpw'));
  },
  slacksave: async () => {
    const box = document.getElementById('slackurl'), url = box.value.trim();
    if (!url) { S.error = 'Paste a Slack webhook URL first.'; return render(); }
    box.value = '';
    await call('gm_set_slack', { p_url: url });
    if (!S.error) { S.notice = 'Slack connected. Use Send test to check it.'; render(); }
  },
  slackoff: async () => {
    await call('gm_set_slack', { p_url: '' });
    if (!S.error) { S.notice = 'Slack disconnected.'; render(); }
  },
  slacktest: async () => {
    await call('gm_slack_test');
    if (!S.error) { S.notice = 'Test message sent. Check the channel.'; render(); }
  },
  shift: el => confirm(`Delay every remaining event by ${el.dataset.by}?`) && call('gm_shift_game', { p_game: S.game.id, p_by: el.dataset.by }),
  skip: el => confirm('Skip this event? All picks are discarded and nobody is banished or murdered.') && call('gm_skip_event', { p_event: el.dataset.ev }),
  remind: async el => {
    await call('gm_remind', { p_event: el.dataset.ev });
    if (!S.error) { S.notice = 'Posted the list of players still to vote to Slack.'; render(); }
  },
  curtain: async () => { S.curtain = !S.curtain; await refresh(); },
  gmsend: async () => {
    const box = document.getElementById('gmchat'), body = box.value.trim();
    if (!body) return;
    box.value = '';
    await call('gm_post_message', { p_game: S.game.id, p_body: body });
  },
  photo: async el => {
    await call('set_my_photo', { p_key: el.dataset.key });
    if (!S.error) { S.picking = false; await refresh(); }
  },
  skipphoto: () => { S.skipPhoto = true; render(); },
  savemine: async () => {
    const n = document.getElementById('ename').value.trim(), pw = document.getElementById('epw').value;
    if (pw && pw.length < 8) { S.error = 'Password must be at least 8 characters'; return render(); }
    if (n !== S.person.name) {
      const { error } = await sb.rpc('set_name', { p_user: S.user.id, p_name: n });
      if (error) { S.error = error.message; return render(); }
    }
    if (pw) {
      const { error } = await sb.auth.updateUser({ password: pw });
      if (error) { S.error = error.message; return render(); }
    }
    S.picking = false; S.error = ''; S.notice = 'Saved.';
    await refresh();
  },
  keepphoto: () => { S.picking = false; render(); },
  changephoto: async () => { S.picking = true; await refresh(); },
  choosephoto: async el => {
    const { data, error } = await sb.rpc('gm_gallery', { p_user: el.dataset.user });
    if (error) { S.error = error.message; return render(); }
    S.gmPick = { user_id: el.dataset.user, name: el.dataset.name, gallery: data ?? [] };
    S.error = '';
    render();
  },
  gmphoto: async el => {
    await call('gm_set_photo', { p_user: S.gmPick.user_id, p_key: el.dataset.key });
    if (!S.error) { S.gmPick = null; await refresh(); }
  },
  gmphotoremove: async () => {
    if (!confirm(`Remove ${S.gmPick.name}'s photo? They will be asked to choose again.`)) return;
    await call('gm_reset_photo', { p_user: S.gmPick.user_id });
    if (!S.error) { S.gmPick = null; await refresh(); }
  },
  gmsave: async () => {
    const g = S.gmPick, n = document.getElementById('ename').value.trim(), pw = document.getElementById('epw').value;
    if (n !== g.name) {
      const { error } = await sb.rpc('set_name', { p_user: g.user_id, p_name: n });
      if (error) { S.error = error.message; return render(); }
      g.name = n;
    }
    if (pw) {
      const { data, error } = await sb.functions.invoke('set-password', { body: { user_id: g.user_id, password: pw } });
      if (error || data?.error) { S.error = data?.error ?? error.message; return render(); }
    }
    S.gmPick = null; S.notice = 'Saved.';
    await refresh();
  },
  gmphotocancel: () => { S.gmPick = null; render(); },
  lobbynext: () => { S.lobbyStep = 'traitors'; render(); },
  lobbyback: () => { S.lobbyStep = 'players'; render(); },
  traitor: el => call('gm_set_traitor', { p_game: S.game.id, p_user: el.dataset.user, p_on: el.checked }),
  toggle: el => call('gm_set_player', { p_game: S.game.id, p_user: el.dataset.user, p_in: el.checked }),
  logout: () => sb.auth.signOut().then(refresh),
  create: () => { S.lobbyStep = 'players'; return call('create_game'); },
  start: () => call('start_game', { p_game: S.game.id }),
  votescreen: el => {
    const m = S.mine[el.dataset.ev];
    S.voting = el.dataset.ev; S.error = '';
    S.voteSel = m?.target ?? null;
    S.voteKind = m?.kind === 'recruit' ? 'recruit' : 'kill';
    render();
  },
  seennews: () => {
    const last = S.events.filter(e => e.status === 'revealed').pop();
    try { if (last) localStorage.setItem(seenKey(), last.id); } catch {}
    render();
  },
  votekind: el => { S.voteKind = el.dataset.kind; render(); },
  voteback: () => { S.voting = null; render(); },
  cast: async el => {
    if (!S.voteSel) return;
    const murder = S.events.find(x => x.id === el.dataset.ev)?.kind === 'murder';
    const target = S.voteSel;
    await call(murder ? (S.voteKind === 'recruit' && target ? 'pick_recruit' : 'pick_victim') : 'cast_vote', { p_event: el.dataset.ev, p_target: target });
    if (!S.error) { S.voting = null; render(); }
  },
  refuse: async el => {
    if (!confirm('Refuse to join the traitors? You will be murdered when the results are revealed.')) return;
    await call('respond_recruit', { p_event: el.dataset.ev, p_accept: false });
    if (!S.error) { S.notice = 'You refused. You will be murdered when the results are revealed.'; render(); }
  },
  endgame: el => call('cast_endgame', { p_event: el.dataset.ev, p_end: el.dataset.end === 'true' }),
  revealme: () => call('reveal_my_role', { p_game: S.game.id }),
  gmreveal: el => call('gm_reveal_role', { p_player: el.dataset.player }),
  gmrevealall: () => confirm('Reveal every remaining role now?') && call('gm_reveal_all', { p_game: S.game.id }),
  startend: () => confirm('Start the end game now? Anything open is voided and the final banishment begins.') && call('gm_start_endgame', { p_game: S.game.id }),
  close: el => call('gm_force_close', { p_event: el.dataset.ev }),
  extend: el => call('gm_extend_event', { p_event: el.dataset.ev, p_by: el.dataset.by || '1 day' }),
  archiveopen: async el => {
    const id = el.dataset.id;
    if (S.openArchive === id) { S.openArchive = null; return render(); }
    if (!S.archiveData[id]) S.archiveData[id] = await fetchGame(id);
    S.openArchive = id;
    render();
  },
  archive: () => confirm('Archive this game? It moves to the archived list and a new game can start.') && call('gm_archive_game', { p_game: S.game.id }),
  delete: () => confirm('Delete this game and all its data?') && call('gm_delete_game', { p_game: S.game.id }),
  tab: el => { S.tab = el.dataset.tab; render(); },
  send: () => {
    const box = document.getElementById('chat'), body = box.value.trim();
    if (!body) return;
    box.value = '';
    return call('post_message', { p_game: S.game.id, p_body: body });
  },
};

// Errors thrown inside an async click handler would otherwise vanish, leaving the screen looking dead.
let busy = false;
document.addEventListener('click', async e => {
  const el = e.target.closest('[data-act]');
  if (!el || busy) return;
  if (el.tagName === 'A') e.preventDefault();
  busy = true;
  el.disabled = true;
  S.notice = '';
  try {
    await actions[el.dataset.act](el);
  } catch (err) {
    console.error(err);
    S.error = err.message;
    render();
  } finally {
    busy = false;
    // A cancelled confirm() re-renders nothing, so the button would otherwise stay disabled.
    el.disabled = false;
  }
});
document.addEventListener('change', e => {
  if (e.target.name === 'vote') { S.voteSel = e.target.value; render(); }
});
document.addEventListener('keydown', e => {
  if (e.key === 'Enter') ({ chat: actions.send, pw: actions.login, gmchat: actions.gmsend })[e.target.id]?.();
});

sb.auth.onAuthStateChange(event => { if (event === 'PASSWORD_RECOVERY') S.recovery = true; setTimeout(refresh, 0); });

setInterval(refresh, 10000);
setInterval(tick, 1000);
