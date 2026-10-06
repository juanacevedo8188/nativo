// POST con el token del admin en Authorization. Sin mails (no depende del límite de Supabase):
//  { name, email, phone, pct }  → crea la cuenta del profe con contraseña provisoria y la devuelve,
//                                  para que el admin se la mande por WhatsApp. Perfil aprobado.
//  { action: 'reset', id }      → contraseña provisoria nueva para ese profe.
//  { action: 'remove', id }     → lo saca del equipo (borra la cuenta o lo da de baja si tiene historial).
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

  // B) Sacar a alguien del equipo. Si nunca dio clases se borra la cuenta; si tiene historial
  //    queda "dado de baja": no entra más ni aparece, pero sus clases y números se conservan.
  if (b.action === 'remove') {
    const id = String(b.id || '');
    if (!/^[0-9a-f-]{36}$/i.test(id)) return json(400, { error: 'Profe inválido' });
    if (id === who.data.id) return json(400, { error: 'No te podés sacar a vos mismo' });
    const now = encodeURIComponent(new Date().toISOString());
    const next = await call(`/rest/v1/slots?profe_id=eq.${id}&starts_at=gt.${now}&status=neq.cancelled&select=id`);
    if (!next.ok) return json(500, { error: 'No se pudo revisar sus clases. Probá de nuevo.' });
    if (next.data.length) return json(409, { error: `Tiene ${next.data.length} ${next.data.length === 1 ? 'clase próxima' : 'clases próximas'}. Borralas o suspendelas desde la Agenda y volvé a intentar.` });
    const hist = await call(`/rest/v1/slots?profe_id=eq.${id}&select=id&limit=1`);
    if (hist.data?.length) {
      const r = await call(`/rest/v1/profiles?id=eq.${id}`, { method: 'PATCH', body: JSON.stringify({ approved: false, archived: true, teaches: false }) });
      if (!r.ok) { console.error('archive', r.status, r.data); return json(500, { error: 'No se pudo dar de baja. Probá de nuevo.' }); }
      return json(200, { ok: true, result: 'archived' });
    }
    // Sin historial: si además es alumno (entró con Google) le dejamos la cuenta de alumno.
    const stu = await call(`/rest/v1/students?id=eq.${id}&select=id`);
    const r = stu.data?.length
      ? await call(`/rest/v1/profiles?id=eq.${id}`, { method: 'DELETE' })
      : await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE' });
    if (!r.ok) { console.error('remove', r.status, r.data); return json(500, { error: 'No se pudo borrar. Probá de nuevo.' }); }
    if (stu.data?.length) await call(`/auth/v1/admin/users/${id}`, { method: 'PUT', body: JSON.stringify({ app_metadata: { staff: false } }) });
    return json(200, { ok: true, result: 'deleted' });
  }

  // C) Alta de profe: cuenta lista para entrar, con contraseña provisoria (sin mails).
  const name = String(b.name || '').trim().slice(0, 60);
  const email = String(b.email || '').trim().toLowerCase();
  const phone = b.phone ? String(b.phone).trim().slice(0, 30) : null;
  const pct = Math.min(100, Math.max(0, Number(b.pct ?? 50) || 0));
  if (name.length < 2) return json(400, { error: 'Poné el nombre del profe' });
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json(400, { error: 'El email no es válido' });

  let password = tempPassword();
  const cr = await call('/auth/v1/admin/users', {
    method: 'POST', body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { name }, app_metadata: { staff: true } }),
  });
  const exists = !cr.ok && (cr.status === 422 || /already|exists|registered/i.test(JSON.stringify(cr.data)));
  if (!cr.ok && !exists) {
    console.error('create', cr.status, cr.data);
    return json(502, { error: 'No se pudo crear la cuenta. Revisá el email y probá de nuevo.' });
  }

  // Perfil aprobado con sus datos, exista o no de antes (alumno de Google, profe dado de baja,
  // o un perfil que se borró a mano de la tabla y dejó la cuenta suelta).
  const up = await call('/rest/v1/rpc/staff_account', {
    method: 'POST', body: JSON.stringify({ p_email: email, p_name: name, p_phone: phone, p_pct: pct }),
  });
  const row = Array.isArray(up.data) ? up.data[0] : null;
  if (!up.ok || !row?.profile_id) {
    console.error('staff_account', up.status, up.data);
    return json(500, { error: up.status === 404
      ? 'Falta actualizar la base: corré de nuevo supabase/setup.sql en Supabase → SQL Editor.'
      : 'Se creó la cuenta pero no se pudo aprobar el perfil. Probá agregarlo de nuevo.' });
  }
  // Ya existía: si es solo de staff le damos contraseña nueva; si es alumno (Google) no se la tocamos.
  if (exists) {
    if (row.is_student) password = null;
    else {
      const r = await call(`/auth/v1/admin/users/${row.profile_id}`, { method: 'PUT', body: JSON.stringify({ password }) });
      if (!r.ok) password = null;
    }
  }
  return json(200, { ok: true, created: cr.ok, alreadyExisted: exists, id: row.profile_id, password });
};

// Contraseña provisoria fácil de dictar por WhatsApp, ej. "Tabla-4827-ola".
function tempPassword() {
  const words = ['remo', 'tabla', 'ola', 'kayak', 'viento', 'rio', 'sol', 'vela', 'agua', 'muelle', 'isla', 'playa', 'aleta', 'proa'];
  const w = () => words[crypto.randomInt(words.length)];
  const first = w();
  return `${first[0].toUpperCase()}${first.slice(1)}-${crypto.randomInt(1000, 10000)}-${w()}`;
}
