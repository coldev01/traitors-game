const SUPABASE_URL = 'https://YOUR-PROJECT.supabase.co';
// Public by design: security is RLS + server-side functions, not secrecy of this key.
const SUPABASE_ANON_KEY = 'YOUR-ANON-KEY';

const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const app = document.getElementById('app');
const S = { user: null, admin: false, game: null, me: null, players: [], roles: {}, events: [], results: {},
            messages: [], mine: {}, picks: {}, overview: null, tab: 'game', error: '' };

// Display names come from Google profiles, so every interpolated value goes through esc().
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const name = id => S.players.find(p => p.id === id)?.display_name ?? '?';
const isOpen = e => e.status === 'open' && new Date(e.closes_at) > new Date();
const countdown = iso => `<span data-t="${esc(iso)}"></span>`;

async function refresh() {
  const { data: { session } } = await sb.auth.getSession();
  S.user = session?.user ?? null;
  if (S.user) {
    S.admin = (await sb.rpc('am_admin')).data === true;
    const { data } = await sb.from('games').select('*').order('created_at', { ascending: false }).limit(1);
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
  S.players = pl.data ?? [];
  S.roles = Object.fromEntries((ro.data ?? []).map(r => [r.player_id, r.role]));
  S.events = ev.data ?? [];
  S.results = Object.fromEntries((re.data ?? []).map(r => [r.event_id, r.target_id]));
  S.me = S.players.find(p => p.user_id === S.user.id) ?? null;
  S.mine = {}; S.picks = {}; S.messages = [];
  if (S.me && S.roles[S.me.id] === 'traitor') {
    const { data } = await sb.from('messages').select('*').eq('game_id', g).order('created_at').limit(200);
    S.messages = data ?? [];
  }
  for (const e of S.events.filter(isOpen)) {
    if (!S.me) break;
    const { data } = await sb.rpc('my_action', { p_event: e.id });
    if (data?.length) S.mine[e.id] = data[0].target_id;
    if (e.kind === 'murder' && S.roles[S.me.id] === 'traitor') S.picks[e.id] = (await sb.rpc('traitor_picks', { p_event: e.id })).data ?? [];
  }
  if (S.admin) S.overview = (await sb.rpc('gm_overview', { p_game: g })).data;
}

async function call(fn, args) {
  const { error } = await sb.rpc(fn, args);
  S.error = error?.message ?? '';
  await refresh();
}

const avatar = p => `<span class="av"><b>${esc((p.display_name || '?')[0].toUpperCase())}</b><img src="avatars/${esc(p.avatar_key)}.jpg" alt="" onerror="this.remove()"></span>`;

function playerGrid() {
  const mineTraitor = S.me && S.roles[S.me.id] === 'traitor';
  return `<div class="grid">${S.players.map(p => {
    const role = S.roles[p.id];
    // Alive players' roles are only visible to us when they are a fellow traitor.
    const tag = role && (!p.alive || p.id === S.me?.id || mineTraitor || S.game.status === 'finished')
      ? `<span class="tag ${role}">${role}</span>` : '';
    return `<div class="player ${p.alive ? '' : 'dead'}">${avatar(p)}${esc(p.display_name)}<br>${p.alive ? '' : '<span class="muted">out</span> '}${tag}</div>`;
  }).join('')}</div>`;
}

function options(list, blank) {
  return `<option value="">${blank}</option>` + list.map(p => `<option value="${esc(p.id)}">${esc(p.display_name)}</option>`).join('');
}

function eventPanel(e) {
  const me = S.me, alive = me?.alive;
  const head = `<h3>${e.kind === 'banishment' ? 'Banishment vote' : 'Murder'}</h3><p class="muted">Closes in ${countdown(e.closes_at)}</p>`;
  const chosen = e.id in S.mine ? (S.mine[e.id] ? name(S.mine[e.id]) : (e.kind === 'murder' ? 'nobody' : 'abstain')) : 'nothing yet';
  if (e.kind === 'banishment' && alive) {
    const targets = S.players.filter(p => p.alive && p.id !== me.id);
    return `<div class="card">${head}<div class="row"><select id="sel-${esc(e.id)}">${options(targets, 'Abstain')}</select>
      <button data-act="vote" data-ev="${esc(e.id)}">Lock in vote</button></div><p class="muted">Your vote: ${esc(chosen)}</p></div>`;
  }
  if (e.kind === 'murder' && alive && S.roles[me.id] === 'traitor') {
    const targets = S.players.filter(p => p.alive && S.roles[p.id] !== 'traitor');
    const picks = (S.picks[e.id] ?? []).map(k => `${esc(name(k.player_id))} → ${esc(k.target_id ? name(k.target_id) : 'nobody')}`).join(', ');
    return `<div class="card">${head}<div class="row"><select id="sel-${esc(e.id)}">${options(targets, 'No murder')}</select>
      <button data-act="murder" data-ev="${esc(e.id)}">Lock in</button></div>
      <p class="muted">Your pick: ${esc(chosen)}${picks ? `<br>Traitor picks: ${picks}` : ''}</p></div>`;
  }
  return '';
}

function history() {
  const done = S.events.filter(e => e.status === 'revealed').reverse().slice(0, 6);
  return done.map(e => {
    const t = S.results[e.id], verb = e.kind === 'banishment' ? 'banished' : 'murdered';
    return `<p>${t ? `<b>${esc(name(t))}</b> was ${verb} — they were ${esc(S.roles[t] ?? '?')}.` : `Nobody was ${verb}.`}</p>`;
  }).join('') || '<p class="muted">Nothing has happened yet.</p>';
}

function chat() {
  return `<div class="chat" id="log">${S.messages.map(m => `<p><b>${esc(name(m.player_id))}</b>: ${esc(m.body)}</p>`).join('')}</div>
    <div class="row" style="margin-top:8px"><input id="chat" maxlength="500" placeholder="Message fellow traitors"><button data-act="send">Send</button></div>`;
}

function gmPanel() {
  const o = S.overview;
  if (!o) return '';
  const evs = o.events.map(e => `<p>${esc(e.kind)} — ${esc(e.status)}, closes ${countdown(e.closes_at)}
    <button class="ghost" data-act="close" data-ev="${esc(e.id)}">Close now</button>
    <button class="ghost" data-act="extend" data-ev="${esc(e.id)}">+1 day</button></p>`).join('');
  return `<div class="card"><h3>Game master</h3><p class="muted">${o.players} players joined</p>${S.game.status === 'active' ? evs : ''}
    <button class="ghost" data-act="delete">Delete game</button></div>`;
}

function view() {
  if (!S.user) return `<h1>Traitors</h1><button data-act="login">Sign in with Google</button>`;
  const g = S.game;
  if (!g) return S.admin ? `<button data-act="create">Create game</button>` : `<p>No game yet — check back soon.</p>`;
  if (g.status === 'lobby') {
    if (S.admin) return `<h2>Lobby</h2>${gmPanel()}<button data-act="start">Start game</button>`;
    return S.me ? `<h2>Lobby</h2><p class="muted">Waiting for the game master to start.</p>${playerGrid()}`
                : `<h2>A game is open</h2><button data-act="join">Join game</button>`;
  }
  if (g.status === 'finished') {
    return `<h1>${g.winner === 'faithful' ? 'The Faithful win' : 'The Traitors win'}</h1>${playerGrid()}<h2>What happened</h2>${history()}${S.admin ? gmPanel() : ''}${S.admin ? '<button data-act="create">New game</button>' : ''}`;
  }
  if (S.admin) return `<h2>Game in progress</h2>${gmPanel()}`;
  if (!S.me) return `<p>A game is in progress. You're not in it.</p>`;
  const role = S.roles[S.me.id], isTraitor = role === 'traitor';
  const tabs = isTraitor ? `<div class="row"><button class="ghost ${S.tab === 'game' ? 'active' : ''}" data-act="tab" data-tab="game">Game</button>
    <button class="ghost ${S.tab === 'chat' ? 'active' : ''}" data-act="tab" data-tab="chat">Traitors chat</button></div>` : '';
  if (isTraitor && S.tab === 'chat') return `${tabs}<h2>Traitors chat</h2>${chat()}`;
  return `${tabs}<div class="card">You are a <span class="tag ${role}">${esc(role)}</span>${S.me.alive ? '' : ' — you are out'}</div>
    ${S.events.filter(isOpen).map(eventPanel).join('')}<h2>Players</h2>${playerGrid()}<h2>What happened</h2>${history()}`;
}

function render() {
  const keep = {};
  app.querySelectorAll('select,input').forEach(e => { keep[e.id] = e.value; });
  const focus = document.activeElement?.id;
  const header = S.user ? `<div class="row top"><span class="muted">${esc(S.user.email)}</span><button class="ghost" data-act="logout">Sign out</button></div>` : '';
  app.innerHTML = header + (S.error ? `<div class="error">${esc(S.error)}</div>` : '') + view();
  for (const [id, v] of Object.entries(keep)) { const e = document.getElementById(id); if (e && id) e.value = v; }
  if (focus) document.getElementById(focus)?.focus();
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

const sel = id => document.getElementById('sel-' + id).value || null;
const actions = {
  login: () => sb.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: location.origin + location.pathname } }),
  logout: () => sb.auth.signOut().then(refresh),
  create: () => call('create_game'),
  join: () => call('join_game', { p_game: S.game.id }),
  start: () => call('start_game', { p_game: S.game.id }),
  vote: el => call('cast_vote', { p_event: el.dataset.ev, p_target: sel(el.dataset.ev) }),
  murder: el => call('pick_victim', { p_event: el.dataset.ev, p_target: sel(el.dataset.ev) }),
  close: el => call('gm_force_close', { p_event: el.dataset.ev }),
  extend: el => call('gm_extend_event', { p_event: el.dataset.ev, p_by: '1 day' }),
  delete: () => confirm('Delete this game and all its data?') && call('gm_delete_game', { p_game: S.game.id }),
  tab: el => { S.tab = el.dataset.tab; render(); },
  send: () => {
    const box = document.getElementById('chat'), body = box.value.trim();
    if (!body) return;
    box.value = '';
    return call('post_message', { p_game: S.game.id, p_body: body });
  },
};

document.addEventListener('click', e => {
  const el = e.target.closest('[data-act]');
  if (el) actions[el.dataset.act](el);
});
document.addEventListener('keydown', e => { if (e.key === 'Enter' && e.target.id === 'chat') actions.send(); });

sb.auth.onAuthStateChange(() => setTimeout(refresh, 0));
// An open <select> is closed by a re-render, so don't poll over someone mid-choice.
setInterval(() => { if (document.activeElement?.tagName !== 'SELECT') refresh(); }, 10000);
setInterval(tick, 1000);
