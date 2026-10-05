// Helpers compartidos por las funciones de Mercado Pago. Sin dependencias: fetch nativo (Node 18+).
const SB_URL = (process.env.SUPABASE_URL || '').replace(/\/$/, '');
const SB_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || '';   // service role: saltea RLS, SOLO en el servidor
const MP_TOKEN = process.env.MP_ACCESS_TOKEN || '';

const json = (statusCode, body) => ({ statusCode, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

async function sb(path, opts = {}) {
  const r = await fetch(`${SB_URL}/rest/v1/${path}`, {
    ...opts,
    headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, 'Content-Type': 'application/json', Prefer: 'return=representation', ...(opts.headers || {}) },
  });
  const data = await r.json().catch(() => null);
  if (!r.ok) throw new Error(`Supabase ${r.status}: ${JSON.stringify(data)}`);
  return data;
}

async function mp(path, opts = {}) {
  const r = await fetch(`https://api.mercadopago.com${path}`, {
    ...opts,
    headers: { Authorization: `Bearer ${MP_TOKEN}`, 'Content-Type': 'application/json', ...(opts.headers || {}) },
  });
  const data = await r.json().catch(() => null);
  if (!r.ok) throw new Error(`Mercado Pago ${r.status}: ${JSON.stringify(data)}`);
  return data;
}

const configured = () => !!(SB_URL && SB_KEY && MP_TOKEN);

module.exports = { json, sb, mp, configured };
