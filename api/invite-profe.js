// POST { name, email, phone, pct } con el token del admin en Authorization.
// Crea la cuenta del profe en Supabase Auth y le manda el mail de invitación para que
// elija su contraseña. Su perfil queda aprobado, con su WhatsApp y su %.
// Necesita la service role key: por eso vive en el servidor y nunca en el HTML.
const { send, readBody, siteUrl } = require('../lib/common');
const SB_URL = (process.env.SUPABASE_URL || '').replace(/\/$/, '');
const SB_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || '';

async function call(path, opts = {}) {
  const r = await fetch(`${SB_URL}${path}`, {
    ...opts,
    headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, 'Content-Type': 'application/json', Prefer: 'return=representation', ...(opts.headers || {}) },
  });
  return { ok: r.ok, status: r.status, data: await r.json().catch(() => null) };
}

module.exports = async (req, res) => {
  const json = (status, body) => send(res, status, body);
  if (req.method !== 'POST') return json(405, { error: 'Método no permitido' });
  if (!SB_URL || !SB_KEY) return json(500, { error: 'Falta configurar SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY en Vercel' });

  // 1) ¿Quién llama? Validamos su token con Supabase y que sea admin aprobado.
  const token = String(req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) return json(401, { error: 'Iniciá sesión de nuevo' });
  const who = await call('/auth/v1/user', { headers: { Authorization: `Bearer ${token}` } });
  if (!who.ok || !who.data?.id) return json(401, { error: 'Tu sesión venció. Salí y volvé a entrar.' });
  const me = await call(`/rest/v1/profiles?id=eq.${who.data.id}&select=role,approved`);
  if (!me.data?.[0] || me.data[0].role !== 'admin' || !me.data[0].approved) return json(403, { error: 'Solo un admin puede agregar profes' });

  // 2) Datos del profe nuevo.
  const b = readBody(req);
  const name = String(b.name || '').trim().slice(0, 60);
  const email = String(b.email || '').trim().toLowerCase();
  const phone = b.phone ? String(b.phone).trim().slice(0, 30) : null;
  const pct = Math.min(100, Math.max(0, Number(b.pct ?? 50) || 0));
  if (name.length < 2) return json(400, { error: 'Poné el nombre del profe' });
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json(400, { error: 'El email no es válido' });

  // 3) Invitación (crea el usuario y manda el mail). Si ya tenía cuenta, solo lo aprobamos.
  const site = siteUrl(req);
  const inv = await call(`/auth/v1/invite?redirect_to=${encodeURIComponent(site + '/?staff=1')}`, {
    method: 'POST', body: JSON.stringify({ email, data: { name } }),
  });
  const exists = !inv.ok && (inv.status === 422 || /already/i.test(JSON.stringify(inv.data)));
  if (!inv.ok && !exists) {
    console.error('invite', inv.status, inv.data);
    return json(502, { error: 'No se pudo mandar la invitación. Revisá el email o probá en un rato.' });
  }

  // 4) Perfil aprobado con sus datos (el trigger handle_new_user ya lo creó).
  const filter = inv.ok && inv.data?.id ? `id=eq.${inv.data.id}` : `email=eq.${encodeURIComponent(email)}`;
  const upd = await call(`/rest/v1/profiles?${filter}`, {
    method: 'PATCH', body: JSON.stringify({ name, phone, commission_pct: pct, approved: true }),
  });
  if (!upd.ok || !upd.data?.length) return json(500, { error: 'Se creó la cuenta pero no se pudo aprobar el perfil. Aprobalo desde la lista.' });
  return json(200, { ok: true, invited: inv.ok, alreadyExisted: exists });
};
