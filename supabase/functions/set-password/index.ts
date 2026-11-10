// Lets the GM set someone's password. Changing another user's password needs the service-role key, so it can't
// happen in the browser. verify_jwt is on, and the caller must also be in the admins table.
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const jwt = (req.headers.get('Authorization') ?? '').replace('Bearer ', '');
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user?.email) return json({ error: 'Not signed in' }, 401);
  const { data: isAdmin } = await admin.from('admins').select('email').eq('email', user.email.toLowerCase()).maybeSingle();
  if (!isAdmin) return json({ error: 'Admin only' }, 403);

  const { user_id, password } = await req.json();
  if (!user_id || String(password ?? '').length < 8) return json({ error: 'Password must be at least 8 characters' }, 400);
  const { error } = await admin.auth.admin.updateUserById(user_id, { password });
  return error ? json({ error: error.message }, 400) : json({ ok: true });
});
