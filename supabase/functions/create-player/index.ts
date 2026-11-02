// Creating auth users needs the service-role key, which must never reach the browser,
// so the GM's "add player" button calls this function instead.
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  const url = Deno.env.get('SUPABASE_URL')!;
  const caller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
  });
  if ((await caller.rpc('am_admin')).data !== true) return json({ error: 'admin only' }, 403);

  const { game_id, email, name } = await req.json();
  if (!game_id || !email || !name) return json({ error: 'game_id, email and name are required' }, 400);

  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: game } = await admin.from('games').select('status').eq('id', game_id).single();
  if (game?.status !== 'lobby') return json({ error: 'game is not in the lobby' }, 400);

  const cleanEmail = String(email).trim().toLowerCase();
  const password = Array.from(crypto.getRandomValues(new Uint8Array(10)), (b) => 'abcdefghjkmnpqrstuvwxyz23456789'[b % 31]).join('');
  const { data: created, error } = await admin.auth.admin.createUser({
    email: cleanEmail, password, email_confirm: true, user_metadata: { full_name: String(name).trim() },
  });
  if (error) return json({ error: error.message }, 400);

  const { error: perr } = await admin.from('players').insert({
    game_id, user_id: created.user.id, email: cleanEmail,
    display_name: String(name).trim(), avatar_key: cleanEmail.split('@')[0],
  });
  if (perr) {
    await admin.auth.admin.deleteUser(created.user.id);
    return json({ error: perr.message }, 400);
  }
  return json({ email: cleanEmail, password });
});
