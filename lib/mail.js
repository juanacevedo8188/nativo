// Mails con Resend, con TOPE para no salir nunca del plan gratis (3.000/mes, 100/día).
// - Sin RESEND_API_KEY en Vercel no manda nada (la web anda igual).
// - Tope: 90 por día y 2.500 por mes. Los "importantes" (confirmación, suspensión) pueden usar los 90;
//   los "de rutina" (recordatorios, resúmenes) solo hasta 70, así siempre queda lugar para los importantes.
// - Cada mail se anota en mail_log (kind + ref + destinatario): nunca se manda dos veces lo mismo.
const { SB_URL, keyHeaders } = require('./common');

const KEY = (process.env.RESEND_API_KEY || '').trim();
const FROM = (process.env.MAIL_FROM || 'Nativo <reservas@nativoescuela.com.ar>').trim();
const CAP = { day: 90, lowDay: 70, month: 2500 };
const TZ = 'America/Argentina/Buenos_Aires';
const SITE = (process.env.SITE_URL || 'https://www.nativoescuela.com.ar').replace(/\/$/, '');

const arDay = (d = new Date()) => new Date(d.getTime() - 3 * 3600e3).toISOString().slice(0, 10);   // Argentina: UTC-3 todo el año
async function rest(path, opts = {}) {
  const r = await fetch(`${SB_URL}/rest/v1/${path}`, { ...opts, headers: { ...keyHeaders(), 'Content-Type': 'application/json', Prefer: 'return=representation', ...(opts.headers || {}) } });
  const data = await r.json().catch(() => null);
  if (!r.ok) throw new Error(`Supabase ${r.status}: ${JSON.stringify(data)}`);
  return data;
}
async function usage() {
  const today = arDay(), rows = await rest(`mail_log?select=day&day=gte.${today.slice(0, 8)}01&or=(ok.is.null,ok.eq.true)`);
  return { today: rows.filter(r => r.day === today).length, month: rows.length };
}
const validEmail = e => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e);

async function sendMail({ kind, ref, to, subject, html, low = false }) {
  if (!KEY) return { skipped: 'mails apagados (falta RESEND_API_KEY)' };
  to = String(to || '').trim().toLowerCase();
  if (!validEmail(to)) return { skipped: 'sin mail válido' };
  const u = await usage();
  if (u.month >= CAP.month || u.today >= (low ? CAP.lowDay : CAP.day)) return { skipped: `tope alcanzado (hoy ${u.today}, mes ${u.month})` };
  const ins = await rest('mail_log?on_conflict=kind,ref,to_email', { method: 'POST', headers: { Prefer: 'resolution=ignore-duplicates,return=representation' }, body: JSON.stringify({ kind, ref, to_email: to }) });
  if (!ins?.length) return { skipped: 'ya enviado' };
  const r = await fetch('https://api.resend.com/emails', { method: 'POST', headers: { Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ from: FROM, to: [to], subject, html }) });
  await rest(`mail_log?id=eq.${ins[0].id}`, { method: 'PATCH', body: JSON.stringify({ ok: r.ok }) }).catch(() => {});
  return r.ok ? { sent: true } : { error: await r.text().catch(() => String(r.status)) };
}

/* ── Diseño de los mails (HTML simple con estilos en línea: así se ve bien en Gmail, Outlook y el celu) ── */
const esc = s => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const money = n => '$ ' + Math.round(+n || 0).toLocaleString('es-AR');
const fDay = d => new Date(d).toLocaleDateString('es-AR', { timeZone: TZ, weekday: 'long', day: 'numeric', month: 'long' });
const fTime = d => new Date(d).toLocaleTimeString('es-AR', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hour12: false });
const cap = s => s.charAt(0).toUpperCase() + s.slice(1);
const btn = (href, label, dark) => `<a href="${esc(href)}" style="display:inline-block;background:${dark ? '#1f1d1e' : '#fbef46'};color:${dark ? '#fbef46' : '#1f1d1e'};text-decoration:none;font-weight:800;padding:13px 22px;border-radius:999px;border:2px solid #1f1d1e;margin:6px 6px 0 0">${label}</a>`;
function layout(title, body) {
  return `<!doctype html><html><body style="margin:0;background:#f3faf6;font-family:Arial,Helvetica,sans-serif;color:#1f1d1e">
  <div style="max-width:560px;margin:0 auto;padding:20px 14px">
    <div style="background:#0b3335;border-radius:18px 18px 0 0;padding:18px 22px"><span style="color:#fbef46;font-size:24px;font-weight:800">Nativo</span>
      <span style="color:#7fd3da;font-size:13px;margin-left:8px">SUP &amp; Kayak · Rosario</span></div>
    <div style="background:#fff;border-radius:0 0 18px 18px;padding:24px 22px;border:1px solid #d9ebe2;border-top:0">
      <h1 style="font-size:22px;margin:0 0 14px">${title}</h1>${body}</div>
    <p style="font-size:12px;color:#8a9a95;text-align:center;margin:14px 0">Nativo · Bar Barlovento, Rosario · <a href="${SITE}" style="color:#0e8488">nativoescuela.com.ar</a></p>
  </div></body></html>`;
}
const classBox = (s, extra = '') => `<div style="background:#f3faf6;border-radius:14px;padding:14px 16px;margin:0 0 16px">
  <div style="font-size:17px;font-weight:800">${esc(cap(fDay(s.starts_at)))} · ${fTime(s.starts_at)} hs</div>
  <div style="margin-top:4px">${esc(s.title)}${s.profe?.name ? ` con <b>${esc(s.profe.name)}</b>` : ''}</div>
  ${s.location ? `<div style="color:#4a5a56;font-size:14px;margin-top:2px">📍 ${esc(s.location)}</div>` : ''}${extra}</div>`;
const BRING = '<p style="font-size:14px;color:#4a5a56;margin:0 0 6px"><b>Qué traer:</b> ropa que se pueda mojar, protector solar, agua, toalla y ropa seca.</p>';
const MAPS = `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent('Bar Barlovento Rosario')}`;

module.exports = { sendMail, usage, arDay, CAP, KEY, SITE, TZ, esc, money, fDay, fTime, cap, btn, layout, classBox, BRING, MAPS, rest, validEmail };
