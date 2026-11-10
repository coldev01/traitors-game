// Public sign-up gate: creating auth users needs the service-role key, so the browser can't do it
// directly. Anyone can call this (verify_jwt is off), so the signup code + email domain are the only gate.
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  const { email, name, password, code } = await req.json();
  const cleanEmail = String(email ?? '').trim().toLowerCase();
  const cleanName = String(name ?? '').trim();
  if (!cleanEmail || !cleanName || !password || !code) return json({ error: 'All fields are required' }, 400);
  if (String(password).length < 8) return json({ error: 'Password must be at least 8 characters' }, 400);

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: cfg } = await admin.from('app_config').select('key, value').in('key', ['signup_code', 'org_domain']);
  const conf = Object.fromEntries((cfg ?? []).map((r) => [r.key, r.value]));

  // Same message whether the code is wrong or unset, so a probe learns nothing.
  if (!conf.signup_code || code !== conf.signup_code) return json({ error: 'Wrong signup code' }, 403);
  if (!conf.org_domain || cleanEmail.split('@')[1] !== conf.org_domain) {
    return json({ error: `Use your @${conf.org_domain} email address` }, 400);
  }

  const { data: created, error } = await admin.auth.admin.createUser({
    email: cleanEmail, password, email_confirm: true, user_metadata: { full_name: cleanName },
  });
  if (error) {
    const taken = /already|registered|exists/i.test(error.message);
    return json({ error: taken ? 'That email is already registered. Sign in instead.' : error.message }, 400);
  }

  const { error: perr } = await admin.from('people').insert({
    user_id: created.user.id, email: cleanEmail, display_name: cleanName, avatar_key: cleanEmail.split('@')[0],
  });
  if (perr) {
    await admin.auth.admin.deleteUser(created.user.id);
    return json({ error: perr.message }, 400);
  }
  return json({ ok: true });
});
