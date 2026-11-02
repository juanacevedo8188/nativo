// Mails que salen en el momento:
//  - { event: 'booking', codes: ['A1B2C3', …] }  → confirmación al alumno (si reservó varias semanas, un solo mail con todas).
//    Cualquiera la puede pedir, pero solo le llega al mail de esa misma reserva, y una sola vez.
//  - { event: 'suspended', slot, codes }          → aviso de clase suspendida. Solo el profe de la clase o un admin.
const { SB_URL, keyHeaders, keyProblem, send, readBody } = require('../lib/common');
const M = require('../lib/mail');

const SEL = 'code,customer_name,customer_email,people,amount,paid,payment_method,pay_pref,status,slot_id,student:student_id(email),slot:slot_id(id,starts_at,duration_min,title,location,status,profe_id,profe:profe_id(name,pay_alias,pay_holder))';
const emailOf = b => (b.customer_email || b.student?.email || '').trim().toLowerCase();

async function staffId(req) {
  const token = String(req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) return null;
  const r = await fetch(`${SB_URL}/auth/v1/user`, { headers: { ...keyHeaders(), Authorization: `Bearer ${token}` } });
  const u = r.ok ? await r.json() : null; if (!u?.id) return null;
  const [p] = await M.rest(`profiles?id=eq.${u.id}&select=id,role,approved`);
  return p?.approved ? p : null;
}

function confirmMail(list) {
  const b0 = list[0], first = (b0.customer_name || '').split(' ')[0];
  const many = list.length > 1, pr = b0.slot.profe || {};
  const pay = b => b.paid ? (b.payment_method === 'abono' ? 'con tu abono ✓' : 'pagada ✓') : +b.amount > 0 ? `${M.money(b.amount)} · ${b.pay_pref === 'transferencia' && pr.pay_alias ? `transferencia al alias <b>${M.esc(pr.pay_alias)}</b>` : 'se paga en la clase'}` : '';
  const body = `<p style="margin:0 0 16px">¡Hola ${M.esc(first)}! ${many ? `Reservaste <b>${list.length} clases</b>. Te esperamos:` : 'Tu lugar está reservado. Te esperamos:'}</p>
    ${list.map(b => M.classBox(b.slot, `<div style="font-size:14px;margin-top:6px">${b.people > 1 ? `${b.people} personas · ` : ''}${pay(b)}</div>
      <div style="font-size:12px;color:#8a9a95;margin-top:4px">Código ${M.esc(b.code)}</div>`)).join('')}
    ${M.BRING}
    <p style="font-size:14px;color:#4a5a56;margin:0 0 16px">Si no podés ir, cancelala desde tu comprobante hasta 12 horas antes así el lugar le queda a otro. Si hay viento o lluvia, te avisamos para reprogramar.</p>
    ${M.btn(`${M.SITE}/#r-${b0.code}`, 'Ver mi reserva')}${M.btn(M.MAPS, '📍 Cómo llegar', true)}`;
  return { subject: many ? `✅ Reservaste ${list.length} clases en Nativo` : `✅ Reserva confirmada: ${M.cap(M.fDay(b0.slot.starts_at))} ${M.fTime(b0.slot.starts_at)}`, html: M.layout(many ? '¡Clases reservadas! 🏄' : '¡Reserva confirmada! 🏄', body) };
}
function suspendedMail(b) {
  const first = (b.customer_name || '').split(' ')[0];
  return { subject: `⚠️ Se suspendió tu clase del ${M.fDay(b.slot.starts_at)}`, html: M.layout('Se suspendió tu clase', `<p style="margin:0 0 16px">Hola ${M.esc(first)}, tuvimos que suspender esta clase (por el clima o un imprevisto):</p>
    ${M.classBox(b.slot)}<p style="margin:0 0 16px">No te cobramos nada${b.payment_method === 'abono' ? ' y la clase volvió a tu abono' : ''}. Elegí otro día cuando quieras, o escribile a tu profe para reprogramar.</p>
    ${M.btn(M.SITE, 'Elegir otro día')}`) };
}

module.exports = async (req, res) => {
  if (req.method !== 'POST') return send(res, 405, { error: 'Método no permitido' });
  if (!M.KEY) return send(res, 200, { skipped: 'mails apagados' });
  const bad = keyProblem(); if (bad) return send(res, 500, { error: bad });
  const body = readBody(req);
  const codes = [...new Set([].concat(body.codes || body.code || []).map(c => String(c).trim().toUpperCase()).filter(c => /^[0-9A-F]{6}$/.test(c)))].slice(0, 12);
  if (!codes.length) return send(res, 400, { error: 'Faltan los códigos' });
  try {
    const list = await M.rest(`bookings?code=in.(${codes.join(',')})&select=${encodeURIComponent(SEL)}`);
    if (body.event === 'booking') {
      const live = list.filter(b => b.status === 'confirmed' && b.slot?.status === 'open').sort((a, b) => a.slot.starts_at.localeCompare(b.slot.starts_at));
      const to = live.length ? emailOf(live[0]) : '';
      const mine = live.filter(b => emailOf(b) === to);
      if (!to || !mine.length) return send(res, 200, { skipped: 'sin mail' });
      const m = confirmMail(mine);
      return send(res, 200, await M.sendMail({ kind: 'confirm', ref: mine.map(b => b.code).sort().join('-'), to, ...m }));
    }
    if (body.event === 'suspended') {
      const me = await staffId(req); if (!me) return send(res, 401, { error: 'Iniciá sesión de nuevo' });
      const slotId = String(body.slot || '');
      const mine = list.filter(b => b.slot_id === slotId && b.slot?.status === 'cancelled' && (me.role === 'admin' || b.slot.profe_id === me.id));
      const out = [];
      for (const b of mine) { const to = emailOf(b); if (to) out.push(await M.sendMail({ kind: 'suspended', ref: b.code, to, ...suspendedMail(b) })); }
      return send(res, 200, { results: out });
    }
    return send(res, 400, { error: 'Evento desconocido' });
  } catch (e) { console.error('mail', e); return send(res, 500, { error: e.message }); }
};
