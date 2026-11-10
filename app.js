const SUPABASE_URL = 'https://konbcshzmxrghgcwikmi.supabase.co';
// Public by design: security is RLS + server-side functions, not secrecy of this key.
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtvbmJjc2h6bXhyZ2hnY3dpa21pIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE4MDU5NzUsImV4cCI6MjEwNzM4MTk3NX0.gIbw92C-Qanh4zKlHpOeq-KNLd29usrdaR9IGFWA8g8';

const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const app = document.getElementById('app');
const S = { user: null, admin: false, game: null, me: null, players: [], roles: {}, events: [], results: {},
            messages: [], mine: {}, picks: {}, overview: null, tab: 'game', error: '', notice: '', authTab: 'signin', peek: false };

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
  const murdered = new Set(S.events.filter(e => e.kind === 'murder' && e.status === 'revealed').map(e => S.results[e.id]));
  return `<div class="grid">${S.players.map(p => {
    const role = S.roles[p.id];
    // Alive players' roles are only visible to us when they are a fellow traitor.
    const tag = role && (!p.alive || p.id === S.me?.id || mineTraitor || S.game.status === 'finished')
      ? `<span class="tag ${role}">${role}</span>` : '';
    return `<div class="player ${p.alive ? '' : 'dead'}"><span class="avwrap">${avatar(p)}${murdered.has(p.id) ? '<img class="slain" src="assets/murdered.svg" alt="Murdered">' : ''}</span><span class="pname">${esc(p.display_name)}</span><br>${tag}</div>`;
  }).join('')}</div>`;
}

function options(list, blank) {
  return `<option value="">${blank}</option>` + list.map(p => `<option value="${esc(p.id)}">${esc(p.display_name)}</option>`).join('');
}

function eventPanel(e) {
  const me = S.me, murder = e.kind === 'murder';
  const head = `<h3>${murder ? 'Choose a victim' : 'Vote to banish'}</h3><p class="clock">${countdown(e.closes_at)}<small>left to decide</small></p>`;
  const chosen = e.id in S.mine ? (S.mine[e.id] ? name(S.mine[e.id]) : (murder ? 'nobody' : 'abstain')) : 'nothing yet';
  if (!me?.alive) return '';
  if (!murder) {
    const targets = S.players.filter(p => p.alive && p.id !== me.id);
    return `<div class="slip">${head}<div class="row"><select id="sel-${esc(e.id)}">${options(targets, 'Abstain')}</select>
      <button data-act="vote" data-ev="${esc(e.id)}">Cast vote</button></div><p class="muted choice">Your vote: ${esc(chosen)}</p></div>`;
  }
  if (S.roles[me.id] !== 'traitor') return '';
  const targets = S.players.filter(p => p.alive && S.roles[p.id] !== 'traitor');
  const picks = (S.picks[e.id] ?? []).map(k => `${esc(name(k.player_id))} → ${esc(k.target_id ? name(k.target_id) : 'nobody')}`).join(', ');
  return `<div class="slip murder">${head}<div class="row"><select id="sel-${esc(e.id)}">${options(targets, 'No murder')}</select>
    <button data-act="murder" data-ev="${esc(e.id)}">Choose victim</button></div>
    <p class="muted choice">Your pick: ${esc(chosen)}${picks ? `<br>Traitor picks: ${picks}` : ''}</p></div>`;
}

function timeline() {
  const done = S.events.filter(e => e.status === 'revealed').reverse().slice(0, 6);
  const items = done.map(e => {
    const t = S.results[e.id], verb = e.kind === 'banishment' ? 'banished' : 'murdered';
    return `<li class="${esc(e.kind)}">${t ? `<b>${esc(name(t))}</b> was ${verb}. They were ${esc(S.roles[t] ?? '?')}.` : `Nobody was ${verb}.`}</li>`;
  }).join('');
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
  return `<div class="role open ${esc(role)}"><span class="seal ${traitor ? '' : 'faithful'}">${traitor ? 'T' : 'F'}</span>
    <span><span class="roleName">${traitor ? 'Traitor' : 'Faithful'}</span><br><span class="muted">${line}</span></span></div>`;
}

function chat() {
  return `<div class="chat" id="log">${S.messages.map(m => `<p><b>${esc(name(m.player_id))}</b>: ${esc(m.body)}</p>`).join('')}</div>
    <div class="row" style="margin-top:12px"><input id="chat" maxlength="500" placeholder="Message fellow traitors"><button data-act="send">Send</button></div>`;
}

function gmPanel() {
  const o = S.overview;
  if (!o) return '';
  const lobby = S.game.status === 'lobby';
  const evs = o.events.map(e => `<p>${esc(e.kind)}, ${esc(e.status)}. Closes in ${countdown(e.closes_at)}</p>
    <div class="row"><button class="ghost" data-act="close" data-ev="${esc(e.id)}">Close now</button>
    <button class="ghost" data-act="extend" data-ev="${esc(e.id)}">Add a day</button></div>`).join('');
  const people = o.people.map(p => `<label class="pick"><input type="checkbox" data-act="toggle" data-user="${esc(p.user_id)}"
    ${p.in_game ? 'checked' : ''} ${lobby ? '' : 'disabled'}> ${esc(p.name)} <span class="muted">${esc(p.email)}</span></label>`).join('');
  return `<div class="card"><h3>Game master</h3>
    <p class="muted">To register, people open this address and enter the signup code.</p>
    <div class="share"><b>${esc(location.origin + location.pathname)}</b><br>Signup code: <b>${esc(o.signup_code ?? '(not set)')}</b></div>
    <p class="muted">${o.players} selected for this game${lobby ? '. Tick the people who are playing.' : '.'}</p>
    ${people || '<p class="muted">Nobody has registered yet.</p>'}
    ${S.game.status === 'active' ? `<h3 style="margin-top:20px">Open events</h3>${evs}` : ''}
    <div class="gm-actions"><button class="ghost" data-act="delete">Delete game</button></div></div>`;
}

function view() {
  if (!S.user) {
    const tab = (id, label) => `<button class="ghost ${S.authTab === id ? 'active' : ''}" data-act="authtab" data-tab="${id}">${label}</button>`;
    const form = S.authTab === 'signin'
      ? `<div class="form"><input id="email" type="email" placeholder="Email" autocomplete="username">
         <input id="pw" type="password" placeholder="Password" autocomplete="current-password"><button data-act="login">Sign in</button></div>`
      : `<div class="form"><input id="rname" placeholder="Your name"><input id="remail" type="email" placeholder="Work email" autocomplete="username">
         <input id="rpw" type="password" placeholder="Choose a password (8+ characters)" autocomplete="new-password">
         <input id="rpw2" type="password" placeholder="Confirm password" autocomplete="new-password">
         <input id="rcode" placeholder="Signup code"><button data-act="register">Register</button></div>`;
    return `<div class="auth"><div class="hero"><h1>Traitors</h1><p>Banishments, murders and bluffing, played in spare minutes over a few weeks.</p></div>
      <div class="seg">${tab('signin', 'Sign in')}${tab('register', 'Register')}</div>${form}
      <div class="foot"><img src="assets/dev-logo.svg" alt="DEV" width="124" height="56"></div></div>`;
  }
  const g = S.game;
  if (!g) return S.admin ? `<p>No game yet.</p><button data-act="create">Create game</button>` : `<p>No game yet. Check back soon.</p>`;
  if (g.status === 'lobby') {
    if (S.admin) return `<h2>Lobby</h2>${gmPanel()}<button data-act="start">Start game</button>`;
    return S.me ? `<h2>Lobby</h2><p class="muted">Waiting for the game master to start.</p>${playerGrid()}`
                : `<p>You haven't been added to this game yet. Ask the game master.</p>`;
  }
  if (g.status === 'finished') {
    return `<div class="winner ${esc(g.winner)}"><h1>${g.winner === 'faithful' ? 'The Faithful win' : 'The Traitors win'}</h1></div>${playerGrid()}<h2>What happened</h2>${timeline()}${S.admin ? gmPanel() : ''}${S.admin ? '<button data-act="create">New game</button>' : ''}`;
  }
  if (S.admin) return `<h2>Game in progress</h2>${gmPanel()}`;
  if (!S.me) return `<p>A game is in progress and you're not in it.</p>`;
  const role = S.roles[S.me.id], isTraitor = role === 'traitor';
  const tabs = isTraitor ? `<div class="seg" style="margin:0 0 20px"><button class="ghost ${S.tab === 'game' ? 'active' : ''}" data-act="tab" data-tab="game">Game</button>
    <button class="ghost ${S.tab === 'chat' ? 'active' : ''}" data-act="tab" data-tab="chat">Traitors chat</button></div>` : '';
  if (isTraitor && S.tab === 'chat') return `${tabs}<h2 style="margin-top:0">Traitors chat</h2>${chat()}`;
  return `${tabs}${roleCard(role)}
    ${S.events.filter(isOpen).map(eventPanel).join('')}<h2>Players</h2>${playerGrid()}<h2>What happened</h2>${timeline()}`;
}

function render() {
  const keep = {};
  app.querySelectorAll('select,input').forEach(e => { keep[e.id] = e.value; });
  const focus = document.activeElement?.id;
  const header = S.user ? `<div class="bar"><span class="who"><span class="muted">${esc(S.user.email)}</span><button class="ghost" data-act="logout">Sign out</button></span></div>` : '';
  app.innerHTML = header + (S.error ? `<div class="error">${esc(S.error)}</div>` : '')
    + (S.notice ? `<div class="notice">${esc(S.notice)}</div>` : '') + view()
    + (S.user ? `<footer class="site-foot"><img src="assets/dev-x-traitors.svg" alt="DEV x Traitors" width="233" height="60"></footer>` : '');
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
  login: () => actions.loginWith(document.getElementById('email').value.trim(), document.getElementById('pw').value),
  loginWith: async (email, password) => {
    const { error } = await sb.auth.signInWithPassword({ email, password });
    S.error = error?.message ?? '';
    await refresh();
  },
  peek: () => {
    S.peek = true;
    render();
    clearTimeout(S.peekTimer);
    S.peekTimer = setTimeout(() => { S.peek = false; render(); }, 6000);
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
  toggle: el => call('gm_set_player', { p_game: S.game.id, p_user: el.dataset.user, p_in: el.checked }),
  logout: () => sb.auth.signOut().then(refresh),
  create: () => call('create_game'),
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

// Errors thrown inside an async click handler would otherwise vanish, leaving the screen looking dead.
let busy = false;
document.addEventListener('click', async e => {
  const el = e.target.closest('[data-act]');
  if (!el || busy) return;
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
  }
});
document.addEventListener('keydown', e => {
  if (e.key === 'Enter') ({ chat: actions.send, pw: actions.login })[e.target.id]?.();
});

sb.auth.onAuthStateChange(() => setTimeout(refresh, 0));

// An open <select> is closed by a re-render, so don't poll over someone mid-choice.
setInterval(() => { if (document.activeElement?.tagName !== 'SELECT') refresh(); }, 10000);
setInterval(tick, 1000);
