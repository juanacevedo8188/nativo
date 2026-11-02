// Mails programados: Vercel lo llama 1 vez por día a las 8:00 (hora Argentina). Ver "crons" en vercel.json.
//  - A cada profe con "Mail para avisos": sus clases de HOY con los anotados (los lunes, en cambio, el resumen de la semana).
//  - A cada alumno con clase MAÑANA: recordatorio.
// Todo pasa por el tope de lib/mail.js (son mails "de rutina": se cortan antes que los importantes).
const { keyProblem, send } = require('../lib/common');
const M = require('../lib/mail');

const SEL = 'id,starts_at,duration_min,title,location,capacity,status,members_only,profe_id,profe:profe_id(name),bookings(code,customer_name,customer_email,people,status,paid,student:student_id(email))';
const act = s => (s.bookings || []).filter(b => b.status !== 'cancelled');
const count = s => act(s).reduce((a, b) => a + (b.people || 1), 0);
const slotsBetween = (from, to) => M.rest(`slots?select=${encodeURIComponent(SEL)}&status=eq.open&starts_at=gte.${from.toISOString()}&starts_at=lt.${to.toISOString()}&order=starts_at`);

function profeMail(p, slots, weekly) {
  slots = [...slots].sort((a, b) => a.starts_at.localeCompare(b.starts_at));
  const first = p.name.split(' ')[0];
  const rows = slots.map(s => `<div style="border-top:1px solid #d9ebe2;padding:10px 0">
      <div><b>${weekly ? `${M.esc(M.cap(M.fDay(s.starts_at)))} · ` : ''}${M.fTime(s.starts_at)}</b> · ${M.esc(s.title)} <span style="background:${count(s) ? '#dcf4f1' : '#fbf0dc'};color:${count(s) ? '#0e8488' : '#a86a12'};border-radius:999px;padding:2px 9px;font-size:13px;font-weight:700">${count(s)}/${s.capacity}</span></div>
      <div style="font-size:14px;color:#4a5a56;margin-top:3px">${act(s).length ? act(s).map(b => `${M.esc(b.customer_name)}${b.people > 1 ? ` ×${b.people}` : ''}${b.paid ? ' ✓' : ''}`).join(' · ') : 'Todavía sin anotados'}</div></div>`).join('');
  const total = slots.reduce((a, s) => a + count(s), 0);
  return {
    subject: weekly ? `📅 Tu semana en Nativo: ${slots.length} ${slots.length === 1 ? 'clase' : 'clases'}` : `🏄 Hoy tenés ${slots.length} ${slots.length === 1 ? 'clase' : 'clases'}`,
    html: M.layout(weekly ? `Tu semana, ${M.esc(first)}` : `Hoy, ${M.esc(first)}`, `<p style="margin:0 0 6px">${slots.length} ${slots.length === 1 ? 'clase' : 'clases'} · ${total} ${total === 1 ? 'alumno anotado' : 'alumnos anotados'} (✓ = ya pagó).</p>
      ${rows}<div style="margin-top:14px">${M.btn(`${M.SITE}/#staff/agenda`, 'Abrir la agenda')}</div>`),
  };
}
function remindMail(s, b) {
  const first = (b.customer_name || '').split(' ')[0];
  return { subject: `🌊 Mañana remás: ${M.fTime(s.starts_at)} hs en Nativo`, html: M.layout(`¡Mañana remás, ${M.esc(first)}! 🌊`, `${M.classBox(s)}${M.BRING}
    <p style="font-size:14px;color:#4a5a56;margin:0 0 16px">Llegá unos 15 minutos antes. Si no podés venir, cancelala desde tu reserva (hasta 12 h antes) así el lugar le queda a otro.</p>
    ${M.btn(`${M.SITE}/#r-${b.code}`, 'Ver mi reserva')}${M.btn(M.MAPS, '📍 Cómo llegar', true)}`) };
}

module.exports = async (req, res) => {
  const secret = process.env.CRON_SECRET;
  if (!secret || req.headers.authorization !== `Bearer ${secret}`) return send(res, 401, { error: 'No autorizado' });
  if (!M.KEY) return send(res, 200, { skipped: 'mails apagados (falta RESEND_API_KEY)' });
  const bad = keyProblem(); if (bad) return send(res, 500, { error: bad });
  const log = { profes: [], remind: [] };
  try {
    const today = M.arDay(), start = new Date(`${today}T03:00:00Z`), day = 864e5;     // 00:00 hora Argentina = 03:00 UTC
    const monday = new Date(`${today}T12:00:00Z`).getUTCDay() === 1;
    // 1) Profes: hoy (o la semana, los lunes)
    const profes = (await M.rest('profiles?select=id,name,notify_email&approved=eq.true&notify_email=not.is.null')).filter(p => M.validEmail(p.notify_email.trim()));
    if (profes.length) {
      const span = await slotsBetween(start, new Date(start.getTime() + (monday ? 7 : 1) * day));
      for (const p of profes) {
        const mine = span.filter(s => s.profe_id === p.id); if (!mine.length) continue;
        const m = profeMail(p, mine, monday);
        log.profes.push([p.name, await M.sendMail({ kind: monday ? 'profe-week' : 'profe-day', ref: today, to: p.notify_email, low: true, ...m })]);
      }
    }
    // 2) Alumnos con clase mañana
    const tomorrow = await slotsBetween(new Date(start.getTime() + day), new Date(start.getTime() + 2 * day));
    for (const s of tomorrow) for (const b of act(s).filter(b => b.status === 'confirmed')) {
      const to = (b.customer_email || b.student?.email || '').trim(); if (!to) continue;
      const r = await M.sendMail({ kind: 'remind', ref: b.code, to, low: true, ...remindMail(s, b) });
      log.remind.push([b.code, r]);
      if (/tope/.test(r.skipped || '')) break;
    }
    return send(res, 200, { ok: true, day: today, monday, ...log, usage: await M.usage() });
  } catch (e) { console.error('cron-mail', e); return send(res, 500, { error: e.message, ...log }); }
};
