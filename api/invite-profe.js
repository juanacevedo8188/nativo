// POST con el token del admin en Authorization. Sin mails (no depende del límite de Supabase):
//  { name, email, phone, pct }  → crea la cuenta del profe con contraseña provisoria y la devuelve,
//                                  para que el admin se la mande por WhatsApp. Perfil aprobado.
//  { action: 'reset', id }      → contraseña provisoria nueva para ese profe.
// Necesita la service role key: por eso vive en el servidor y nunca en el HTML.
const crypto = require('crypto');
const { SB_URL, keyHeaders, keyProblem, send, readBody, siteUrl } = require('../lib/common');

async function call(path, opts = {}) {
  const r = await fetch(`${SB_URL}${path}`, {
    ...opts,
    headers: { ...keyHeaders(), 'Content-Type': 'application/json', Prefer: 'return=representation', ...(opts.headers || {}) },
  });
  return { ok: r.ok, status: r.status, data: await r.json().catch(() => null) };
}

module.exports = async (req, res) => {
  const json = (status, body) => send(res, status, body);
  if (req.method !== 'POST') return json(405, { error: 'Método no permitido' });
  const bad = keyProblem();
  if (bad) return json(500, { error: bad });

  // 1) ¿Quién llama? Validamos su token con Supabase y que sea admin aprobado.
  const token = String(req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) return json(401, { error: 'Iniciá sesión de nuevo' });
  const who = await call('/auth/v1/user', { headers: { Authorization: `Bearer ${token}` } });
  if (!who.ok || !who.data?.id) return json(401, { error: 'Tu sesión venció. Salí y volvé a entrar.' });
  const me = await call(`/rest/v1/profiles?id=eq.${who.data.id}&select=role,approved`);
  if (!me.ok) {
    console.error('profiles', me.status, me.data);
    return json(500, { error: `El servidor no pudo leer la base (error ${me.status}). Revisá que SUPABASE_SERVICE_ROLE_KEY en Vercel sea la clave secreta del mismo proyecto y hacé Redeploy.` });
  }
  if (!me.data?.[0] || me.data[0].role !== 'admin' || !me.data[0].approved) return json(403, { error: 'Solo un admin puede hacer esto' });

  const b = readBody(req);

  // A) Contraseña nueva para un profe que se la olvidó (sin mails).
  if (b.action === 'reset') {
    const id = String(b.id || '');
    if (!/^[0-9a-f-]{36}$/i.test(id)) return json(400, { error: 'Profe inválido' });
    const password = tempPassword();
    const r = await call(`/auth/v1/admin/users/${id}`, { method: 'PUT', body: JSON.stringify({ password }) });
    if (!r.ok) { console.error('reset', r.status, r.data); return json(502, { error: 'No se pudo cambiar la contraseña. Probá de nuevo.' }); }
    return json(200, { ok: true, password });
  }

  // B) Alta de profe: cuenta lista para entrar, con contraseña provisoria (sin mails).
  const name = String(b.name || '').trim().slice(0, 60);
  const email = String(b.email || '').trim().toLowerCase();
  const phone = b.phone ? String(b.phone).trim().slice(0, 30) : null;
  const pct = Math.min(100, Math.max(0, Number(b.pct ?? 50) || 0));
  if (name.length < 2) return json(400, { error: 'Poné el nombre del profe' });
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json(400, { error: 'El email no es válido' });

  const password = tempPassword();
  const cr = await call('/auth/v1/admin/users', {
    method: 'POST', body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { name } }),
  });
  const exists = !cr.ok && (cr.status === 422 || /already|exists|registered/i.test(JSON.stringify(cr.data)));
  if (!cr.ok && !exists) {
    console.error('create', cr.status, cr.data);
    return json(502, { error: 'No se pudo crear la cuenta. Revisá el email y probá de nuevo.' });
  }

  // Perfil aprobado con sus datos (el trigger handle_new_user ya lo creó).
  const filter = cr.ok && cr.data?.id ? `id=eq.${cr.data.id}` : `email=eq.${encodeURIComponent(email)}`;
  const upd = await call(`/rest/v1/profiles?${filter}`, {
    method: 'PATCH', body: JSON.stringify({ name, phone, commission_pct: pct, approved: true }),
  });
  if (!upd.ok || !upd.data?.length) return json(500, { error: 'Se creó la cuenta pero no se pudo aprobar el perfil. Aprobalo desde la lista.' });
  // Si ya tenía cuenta no le tocamos la contraseña: el admin puede generarle una nueva desde Equipo.
  return json(200, { ok: true, created: cr.ok, alreadyExisted: exists, id: upd.data[0].id, password: cr.ok ? password : null });
};

// Contraseña provisoria fácil de dictar por WhatsApp, ej. "Tabla-4827-ola".
function tempPassword() {
  const words = ['remo', 'tabla', 'ola', 'kayak', 'viento', 'rio', 'sol', 'vela', 'agua', 'muelle', 'isla', 'playa', 'aleta', 'proa'];
  const w = () => words[crypto.randomInt(words.length)];
  const first = w();
  return `${first[0].toUpperCase()}${first.slice(1)}-${crypto.randomInt(1000, 10000)}-${w()}`;
}
