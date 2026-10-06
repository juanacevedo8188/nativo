// Helpers compartidos por las funciones de /api (Vercel). Sin dependencias: fetch nativo (Node 18+).
const SB_URL = (process.env.SUPABASE_URL || '').replace(/\/$/, '');
const SB_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || '';   // service role: saltea RLS, SOLO en el servidor
const MP_TOKEN = process.env.MP_ACCESS_TOKEN || '';

// Supabase tiene dos formatos de clave secreta:
//  - nueva  "sb_secret_…"  → va solo en el header apikey (no es un JWT).
//  - vieja  service_role "eyJ…" (JWT) → va en apikey y también como Bearer.
const keyHeaders = (key = SB_KEY) => key.startsWith('sb_') ? { apikey: key } : { apikey: key, Authorization: `Bearer ${key}` };
const jwtRole = (k) => { try { return JSON.parse(Buffer.from(k.split('.')[1], 'base64url').toString()).role; } catch { return null; } };
// Explica en castellano si la clave cargada en Vercel no sirve (null = está bien).
function keyProblem() {
  if (!SB_URL) return 'Falta SUPABASE_URL en las variables de Vercel';
  if (!SB_KEY) return 'Falta SUPABASE_SERVICE_ROLE_KEY en las variables de Vercel';
  if (SB_KEY.startsWith('sb_publishable_')) return 'En SUPABASE_SERVICE_ROLE_KEY (Vercel) está la clave pública. Tiene que ir la secreta: "sb_secret_…" o la "service_role" (eyJ…)';
  if (SB_KEY.startsWith('eyJ') && jwtRole(SB_KEY) !== 'service_role') return 'En SUPABASE_SERVICE_ROLE_KEY (Vercel) está la clave "anon". Tiene que ir la "service_role" (o la secreta sb_secret_…)';
  return null;
}

const send = (res, status, body) => res.status(status).json(body);
// Vercel ya parsea el JSON si viene con Content-Type: application/json; si no, llega como texto.
const readBody = (req) => { if (req.body && typeof req.body === 'object') return req.body; try { return JSON.parse(req.body || '{}'); } catch { return {}; } };
const siteUrl = (req) => (process.env.SITE_URL || `https://${req.headers['x-forwarded-host'] || req.headers.host}`).replace(/\/$/, '');

async function sb(path, opts = {}) {
  const r = await fetch(`${SB_URL}/rest/v1/${path}`, {
    ...opts,
    headers: { ...keyHeaders(), 'Content-Type': 'application/json', Prefer: 'return=representation', ...(opts.headers || {}) },
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

module.exports = { SB_URL, SB_KEY, keyHeaders, keyProblem, send, readBody, siteUrl, sb, mp, configured };
