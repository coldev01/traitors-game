const SUPABASE_URL = 'https://konbcshzmxrghgcwikmi.supabase.co';
// Public by design: security is RLS + server-side functions, not secrecy of this key.
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtvbmJjc2h6bXhyZ2hnY3dpa21pIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE4MDU5NzUsImV4cCI6MjEwNzM4MTk3NX0.gIbw92C-Qanh4zKlHpOeq-KNLd29usrdaR9IGFWA8g8';

const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const app = document.getElementById('app');
const S = { user: null, admin: false, game: null, me: null, players: [], roles: {}, events: [], results: {},
            messages: [], mine: {}, picks: {}, overview: null, tab: 'game', error: '', notice: '', authTab: 'signin', peek: false, offer: null };

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
  S.results = Object.fromEntries((re.data ?? []).map(r => [r.event_id, { target: r.target_id, kind: r.kind, accepted: r.accepted }]));
  S.me = S.players.find(p => p.user_id === S.user.id) ?? null;
  S.mine = {}; S.picks = {}; S.messages = []; S.offer = null;
  if (S.me && S.roles[S.me.id] === 'traitor') {
    const { data } = await sb.from('messages').select('*').eq('game_id', g).order('created_at').limit(200);
    S.messages = data ?? [];
  }
  for (const e of S.events.filter(isOpen)) {
    if (!S.me) break;
    const { data } = await sb.rpc('my_pick', { p_event: e.id });
    if (data?.length) S.mine[e.id] = { kind: data[0].kind, target: data[0].target_id };
    if (e.kind === 'murder' && S.roles[S.me.id] === 'traitor') S.picks[e.id] = (await sb.rpc('team_picks', { p_event: e.id })).data ?? [];
  }
  if (S.me?.alive) S.offer = (await sb.rpc('my_offer', { p_game: g })).data ?? null;
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
  const murdered = new Set(S.events.filter(e => e.kind === 'murder' && e.status === 'revealed' && S.results[e.id]?.kind === 'kill').map(e => S.results[e.id].target));
  return `<div class="grid">${S.players.map(p => {
    const role = S.roles[p.id];
    // Alive players' roles are only visible to us when they are a fellow traitor.
    const tag = role && (!p.alive || p.id === S.me?.id || mineTraitor || S.game.status === 'finished')
      ? `<span class="tag ${role}">${role}</span>` : '';
    return `<div class="player ${p.alive ? '' : 'dead'}"><span class="avwrap">${avatar(p)}${murdered.has(p.id) ? '<img class="slain" src="assets/murdered.svg" alt="Murdered">' : ''}</span><span class="pname">${esc(p.display_name)}</span><br>${tag}</div>`;
  }).join('')}</div>`;
}

function options(list, blank, required) {
  return `<option value=""${required ? ' disabled selected' : ''}>${blank}</option>` + list.map(p => `<option value="${esc(p.id)}">${esc(p.display_name)}</option>`).join('');
}

function eventPanel(e) {
  const me = S.me, murder = e.kind === 'murder';
  if (!me?.alive) return '';
  const mine = S.mine[e.id];
  const clock = `<p class="clock">${countdown(e.closes_at)}<small>left to decide</small></p>`;
  if (!murder) {
    const targets = S.players.filter(p => p.alive && p.id !== me.id);
    const chosen = mine?.target ? name(mine.target) : 'nothing yet';
    // A murder can land while a banishment is still open; votes for the victim are dropped at the close.
    const stale = mine?.target && !S.players.find(p => p.id === mine.target)?.alive;
    return `<div class="slip"><h3>Vote to banish</h3>${clock}<div class="row"><select id="sel-${esc(e.id)}">${options(targets, 'Choose a player to banish', true)}</select>
      <button data-act="vote" data-ev="${esc(e.id)}">Cast vote</button></div>
      ${stale ? `<p class="warn">Your vote was for ${esc(chosen)}, who is out of the game. It won't count. Choose again before the vote closes.</p>`
              : `<p class="muted choice">Your vote: ${esc(chosen)}. No vote counts as abstaining.</p>`}</div>`;
  }
  if (S.roles[me.id] !== 'traitor') return '';
  const targets = S.players.filter(p => p.alive && S.roles[p.id] !== 'traitor');
  const traitorsLeft = S.players.filter(p => p.alive && S.roles[p.id] === 'traitor').length;
  const canRecruit = traitorsLeft <= 2;
  const opt = (kind, p) => `<option value="${kind}:${esc(p.id)}">${esc(p.display_name)}</option>`;
  const select = `<select id="sel-${esc(e.id)}"><option value="">No murder</option>
    <optgroup label="Murder">${targets.map(p => opt('kill', p)).join('')}</optgroup>
    ${canRecruit ? `<optgroup label="Recruit">${targets.map(p => opt('recruit', p)).join('')}</optgroup>` : ''}</select>`;
  const chosen = mine ? (mine.target ? `${mine.kind === 'recruit' ? 'recruit' : 'murder'} ${name(mine.target)}` : 'no murder') : 'nothing yet';
  const team = (S.picks[e.id] ?? []).map(k => `${esc(name(k.player_id))} → ${esc(k.target_id ? `${k.kind === 'recruit' ? 'recruit ' : ''}${name(k.target_id)}` : 'nobody')}`).join(', ');
  return `<div class="slip murder"><h3>${canRecruit ? 'Murder or recruit' : 'Choose a victim'}</h3>${clock}
    ${canRecruit ? `<p class="muted">Only ${traitorsLeft} traitor${traitorsLeft === 1 ? '' : 's'} left. You can recruit a faithful instead of murdering. They can refuse, and then nothing happens.</p>` : ''}
    <div class="row">${select}<button data-act="murder" data-ev="${esc(e.id)}">${canRecruit ? 'Confirm' : 'Choose victim'}</button></div>
    <p class="muted choice">Your pick: ${esc(chosen)}${team ? `<br>Traitor picks: ${team}` : ''}</p></div>`;
}

function offerCard() {
  const e = S.events.find(x => x.id === S.offer);
  return `<div class="slip murder"><h3>The traitors have chosen you</h3>
    <p>Join them and you become a traitor. Refuse and nothing happens. No one else will know either way.</p>
    <p class="clock">${e ? countdown(e.reveals_at) : ''}<small>to answer</small></p>
    <div class="row"><button data-act="accept" data-ev="${esc(S.offer)}">Join the traitors</button>
    <button class="ghost" data-act="refuse" data-ev="${esc(S.offer)}">Refuse</button></div></div>`;
}

function timeline() {
  const done = S.events.filter(e => e.status === 'revealed').reverse().slice(0, 6);
  const items = done.map(e => {
    const r = S.results[e.id], verb = e.kind === 'banishment' ? 'banished' : 'murdered';
    // Only traitors can read a recruit result; everyone else sees an ordinary quiet round.
    if (r?.kind === 'recruit') {
      return `<li class="${esc(e.kind)}"><b>${esc(name(r.target))}</b> ${r.accepted ? 'accepted and joined the traitors.' : 'refused. Nobody was murdered.'}</li>`;
    }
    const t = r?.target;
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
    <h3 style="margin-top:20px">Slack announcements</h3>
    <p class="muted">${o.slack_on ? 'Connected. Votes opening, reminders, results and the final outcome are posted.' : 'Not connected. Paste a Slack webhook URL to post public updates to a channel.'}</p>
    <div class="row"><input id="slackurl" placeholder="https://hooks.slack.com/..." autocomplete="off">
      <button data-act="slacksave">Save</button>
      ${o.slack_on ? '<button class="ghost" data-act="slacktest">Send test</button><button class="ghost" data-act="slackoff">Disconnect</button>' : ''}</div>
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
  return `${tabs}${S.offer ? offerCard() : ''}${roleCard(role)}
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
  toggle: el => call('gm_set_player', { p_game: S.game.id, p_user: el.dataset.user, p_in: el.checked }),
  logout: () => sb.auth.signOut().then(refresh),
  create: () => call('create_game'),
  start: () => call('start_game', { p_game: S.game.id }),
  vote: el => {
    const target = sel(el.dataset.ev);
    if (!target) { S.error = 'Choose a player to banish.'; return render(); }
    return call('cast_vote', { p_event: el.dataset.ev, p_target: target });
  },
  murder: el => {
    const [kind, id] = (document.getElementById('sel-' + el.dataset.ev).value || '').split(':');
    return call(kind === 'recruit' ? 'pick_recruit' : 'pick_victim', { p_event: el.dataset.ev, p_target: id || null });
  },
  accept: async el => {
    await call('respond_recruit', { p_event: el.dataset.ev, p_accept: true });
    if (!S.error) { S.notice = 'You will become a traitor when the round is revealed.'; render(); }
  },
  refuse: async el => {
    await call('respond_recruit', { p_event: el.dataset.ev, p_accept: false });
    if (!S.error) { S.notice = 'You refused. Nothing happens.'; render(); }
  },
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
