// Calendario del profe (.ics) para suscribirse desde Google Calendar o el iPhone:
// sus clases de las últimas 2 semanas y las próximas 10, con cuántos anotados hay y quiénes.
// /api/cal?t=TOKEN  (el token es secreto y personal: lo genera cada profe en Más → Mi calendario).
// Admin: &all=1 incluye las clases de todos los profes.
const { SB_URL, keyHeaders, keyProblem, siteUrl } = require('../lib/common');

const get = async (path) => {
  const r = await fetch(`${SB_URL}/rest/v1/${path}`, { headers: keyHeaders() });
  if (!r.ok) throw new Error(`Supabase ${r.status}`);
  return r.json();
};
// Texto de iCalendar: escapar y cortar líneas largas (máx. 75 bytes, la siguiente empieza con espacio).
const txt = s => String(s ?? '').replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\r?\n/g, '\\n');
function fold(line) {
  const out = []; let cur = '', bytes = 0;
  for (const ch of line) {
    const b = Buffer.byteLength(ch);
    if (bytes + b > (out.length ? 74 : 75)) { out.push(cur); cur = ''; bytes = 0; }
    cur += ch; bytes += b;
  }
  out.push(cur);
  return out.join('\r\n ');
}
const stamp = d => new Date(d).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
const EMOJI = { sup: '🏄', kayak: '🛶' };

module.exports = async (req, res) => {
  const t = String(req.query.t || '');
  if (!/^[0-9a-f]{32,64}$/.test(t)) { res.statusCode = 404; return res.end('Link de calendario inválido'); }
  const problem = keyProblem();
  if (problem) { res.statusCode = 500; return res.end(problem); }
  try {
    const [tok] = await get(`cal_tokens?token=eq.${t}&select=profile_id`);
    const [me] = tok ? await get(`profiles?id=eq.${tok.profile_id}&select=id,name,role,approved,archived`) : [];
    if (!me || !me.approved || me.archived) { res.statusCode = 404; return res.end('Este link ya no es válido. Generá uno nuevo desde la web.'); }
    const all = req.query.all === '1' && me.role === 'admin';
    const from = new Date(Date.now() - 14 * 864e5).toISOString(), to = new Date(Date.now() + 70 * 864e5).toISOString();
    const sel = 'id,title,starts_at,duration_min,capacity,location,status,members_only,profe:profe_id(name),type:class_type_id(sport,kind),bookings(customer_name,people,status,paid,payment_method)';
    const slots = await get(`slots?select=${encodeURIComponent(sel)}&starts_at=gte.${encodeURIComponent(from)}&starts_at=lt.${encodeURIComponent(to)}${all ? '' : `&profe_id=eq.${me.id}`}&order=starts_at`);
    const site = siteUrl(req), now = stamp(new Date());
    const first = me.name.split(' ')[0];
    const L = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Nativo//Clases//ES', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
      `X-WR-CALNAME:${txt(all ? 'Nativo · Todas las clases' : `Nativo · Clases de ${first}`)}`, 'X-WR-TIMEZONE:America/Argentina/Buenos_Aires',
      'REFRESH-INTERVAL;VALUE=DURATION:PT1H', 'X-PUBLISHED-TTL:PT1H'];
    for (const s of slots) {
      const act = (s.bookings || []).filter(b => b.status !== 'cancelled');
      const n = act.reduce((a, b) => a + (b.people || 1), 0), off = s.status === 'cancelled';
      const em = s.members_only ? '🏅' : EMOJI[s.type?.sport] || '🏄';
      const who = all && s.profe?.name ? ` · ${s.profe.name.split(' ')[0]}` : '';
      const summary = off ? `❌ Suspendida · ${s.title}${who}` : `${em} ${s.title} · ${n}/${s.capacity}${who}`;
      const lines = act.length
        ? [`Anotados (${n}/${s.capacity}):`, ...act.map(b => `• ${b.customer_name}${b.people > 1 ? ` ×${b.people}` : ''}${b.status === 'no_show' ? ' (no vino)' : ''} — ${b.paid ? `pagó${b.payment_method ? ` (${b.payment_method})` : ''}` : 'a cobrar'}`)]
        : ['Todavía sin anotados.'];
      if (off) lines.unshift('Esta clase está suspendida.');
      lines.push('', `Agenda: ${site}/#staff/agenda`);
      L.push('BEGIN:VEVENT', `UID:${s.id}@nativoescuela.com.ar`, `DTSTAMP:${now}`, `DTSTART:${stamp(s.starts_at)}`,
        `DTEND:${stamp(new Date(new Date(s.starts_at).getTime() + (s.duration_min || 60) * 60000))}`,
        `SUMMARY:${txt(summary)}`, `DESCRIPTION:${txt(lines.join('\n'))}`, `STATUS:${off ? 'CANCELLED' : 'CONFIRMED'}`);
      if (s.location) L.push(`LOCATION:${txt(s.location)}`);
      if (!off) L.push('BEGIN:VALARM', 'ACTION:DISPLAY', 'TRIGGER:-PT60M', `DESCRIPTION:${txt(`En 1 hora: ${s.title} (${n}/${s.capacity})`)}`, 'END:VALARM');
      L.push('END:VEVENT');
    }
    L.push('END:VCALENDAR');
    res.setHeader('Content-Type', 'text/calendar; charset=utf-8');
    res.setHeader('Content-Disposition', 'inline; filename="nativo.ics"');
    res.setHeader('Cache-Control', 'public, max-age=0, s-maxage=300');
    res.end(L.map(fold).join('\r\n') + '\r\n');
  } catch (e) {
    res.statusCode = 500; res.end('No se pudo armar el calendario: ' + e.message);
  }
};
