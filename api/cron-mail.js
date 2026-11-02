// Mails programados: Vercel lo llama 1 vez por día a las 8:00 (hora Argentina). Ver "crons" en vercel.json.
//  - A cada profe con "Mail para avisos": sus clases de HOY con los anotados (los lunes, en cambio, el resumen de la semana).
//  - A cada alumno con clase MAÑANA: recordatorio.
//  - "Traé a un amigo": si el amigo ya fue a su clase, se genera el premio (cupón personal de 1 uso) para quien lo invitó.
//  - "Te extrañamos": a quien no viene hace X días (si está activado en Cupones), con un cupón. Máx. 15 por día.
// Todo pasa por el tope de lib/mail.js (son mails "de rutina": se cortan antes que los importantes).
const crypto = require('crypto');
const { keyProblem, send } = require('../lib/common');
const M = require('../lib/mail');
const WINBACK_PER_DAY = 15;
const unsubLink = email => `${M.SITE}/api/unsub?e=${encodeURIComponent(email)}&t=${crypto.createHmac('sha256', process.env.CRON_SECRET || '').update(email).digest('hex').slice(0, 24)}`;
const setting = async key => (await M.rest(`app_settings?key=eq.${key}&select=value`))[0]?.value || {};

function rewardMail(name, friend, code, pct, until) {
  return { subject: `🎁 ${friend} vino a remar: tenés ${pct}% en tu próxima clase`, html: M.layout(`¡Gracias por traer a ${M.esc(friend)}! 🤝`, `<p style="margin:0 0 14px">Hola ${M.esc(name)}, tu invitado ya fue a su primera clase. Tu premio:</p>
    <div style="background:#fbef46;border:2px solid #1f1d1e;border-radius:14px;padding:16px;text-align:center;margin:0 0 16px"><div style="font-size:14px">Código de ${pct}% de descuento</div>
      <div style="font-size:28px;font-weight:800;letter-spacing:2px;margin-top:4px">${M.esc(code)}</div><div style="font-size:13px;margin-top:4px">Un solo uso · vence el ${M.esc(until)}</div></div>
    <p style="font-size:14px;color:#4a5a56;margin:0 0 16px">Ponelo al reservar, en "¿Tenés un cupón de descuento?". Seguí invitando: cada amigo que viene te da otro premio.</p>${M.btn(M.SITE, 'Reservar mi clase')}`) };
}
function winbackMail(name, email, cp) {
  return { subject: `🌊 Hace rato que no te vemos en el río, ${name}`, html: M.layout(`¡Te extrañamos, ${M.esc(name)}! 🌊`, `<p style="margin:0 0 14px">Hace unas semanas que no venís a remar. El río está lindo y tenemos lugar para vos.</p>
    ${cp ? `<div style="background:#fbef46;border:2px solid #1f1d1e;border-radius:14px;padding:16px;text-align:center;margin:0 0 16px"><div style="font-size:14px">Para tu vuelta, ${cp.percent}% de descuento</div>
      <div style="font-size:28px;font-weight:800;letter-spacing:2px;margin-top:4px">${M.esc(cp.code)}</div>${cp.valid_until ? `<div style="font-size:13px;margin-top:4px">Vence el ${M.esc(new Date(cp.valid_until + 'T12:00:00Z').toLocaleDateString('es-AR'))}</div>` : ''}</div>` : ''}
    ${M.btn(M.SITE, 'Elegir mi clase')}
    <p style="font-size:12px;color:#8a9a95;margin:22px 0 0">¿No querés recibir estos mails? <a href="${unsubLink(email)}" style="color:#8a9a95">Darme de baja</a></p>`) };
}

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
    // 3) Traé a un amigo: premio para quien invitó, cuando el amigo ya fue a su clase
    log.referrals = [];
    try {
    const ref = await setting('referral');
    const pend = await M.rest('referrals?status=eq.pending&select=id,friend_name,referrer:referrer_id(name,email),booking:booking_id(status,slot:slot_id(starts_at,status))');
    for (const r of pend) {
      const s = r.booking?.slot; if (!s || new Date(s.starts_at) > new Date()) continue;
      if (!['confirmed', 'attended'].includes(r.booking.status) || s.status !== 'open') { await M.rest(`referrals?id=eq.${r.id}`, { method: 'PATCH', body: JSON.stringify({ status: 'void' }) }); continue; }
      const pct = Math.min(100, Math.max(1, +ref.reward_pct || 15)), until = new Date(Date.now() + 90 * day).toISOString().slice(0, 10);
      const code = 'AMIGO' + crypto.randomBytes(4).toString('hex').toUpperCase().slice(0, 5);
      await M.rest('coupons', { method: 'POST', body: JSON.stringify({ code, percent: pct, max_uses: 1, valid_until: until, note: `Premio de ${r.referrer?.name || ''} por invitar a ${r.friend_name || ''}` }) });
      await M.rest(`referrals?id=eq.${r.id}`, { method: 'PATCH', body: JSON.stringify({ status: 'rewarded', reward_coupon: code, reward_pct: pct, rewarded_at: new Date().toISOString() }) });
      const name = (r.referrer?.name || '').split(' ')[0];
      const mail = r.referrer?.email ? await M.sendMail({ kind: 'ref-reward', ref: r.id, to: r.referrer.email, ...rewardMail(name, r.friend_name || 'tu amigo', code, pct, new Date(until + 'T12:00:00Z').toLocaleDateString('es-AR')) }) : { skipped: 'sin mail' };
      log.referrals.push([code, mail]);
    }
    } catch (e) { console.error('cron-mail referrals', e); log.referrals.push(['error', e.message]); }
    // 4) Te extrañamos: quien no viene hace X días y no tiene nada reservado (una vez por "última clase")
    log.winback = [];
    try {
    const wb = await setting('winback');
    if (wb.on) {
      const days = Math.max(14, +wb.days || 30), since = new Date(Date.now() - 120 * day).toISOString();
      const rows = await M.rest(`bookings?select=code,customer_name,customer_email,status,student:student_id(email),slot:slot_id!inner(starts_at,status)&status=neq.cancelled&slot.starts_at=gte.${since}`);
      const by = {};
      for (const b of rows) {
        const e = (b.customer_email || b.student?.email || '').trim().toLowerCase(); if (!M.validEmail(e) || b.slot?.status !== 'open') continue;
        const t = new Date(b.slot.starts_at).getTime(), x = (by[e] ||= { last: 0, code: '', name: b.customer_name, future: false });
        if (t > Date.now()) x.future = true; else if (t > x.last) Object.assign(x, { last: t, code: b.code, name: b.customer_name });
      }
      const out = new Set((await M.rest('mail_optout?select=email')).map(o => o.email));
      const cp = wb.coupon ? (await M.rest(`coupons?code=eq.${encodeURIComponent(wb.coupon)}&active=eq.true&select=code,percent,valid_until`))[0] : null;
      let n = 0;
      for (const [email, x] of Object.entries(by)) {
        if (n >= WINBACK_PER_DAY) break;
        if (x.future || !x.last || Date.now() - x.last < days * day || out.has(email)) continue;
        const r = await M.sendMail({ kind: 'winback', ref: x.code, to: email, low: true, ...winbackMail((x.name || '').split(' ')[0], email, cp) });
        if (r.sent) n++;
        log.winback.push([email.replace(/^(.).*@/, '$1…@'), r]);
        if (/tope/.test(r.skipped || '')) break;
      }
    }
    } catch (e) { console.error('cron-mail winback', e); log.winback.push(['error', e.message]); }
    return send(res, 200, { ok: true, day: today, monday, ...log, usage: await M.usage() });
  } catch (e) { console.error('cron-mail', e); return send(res, 500, { error: e.message, ...log }); }
};
