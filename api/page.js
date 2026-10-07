// Páginas con vista previa propia para WhatsApp / Instagram (los bots no ejecutan JS ni leen el #):
//   /kayak       → la web abierta en la pestaña Kayak, con tarjeta de kayak.
//   /c/<id>      → link directo a una clase o travesía: tarjeta con título, día, hora y profe,
//                  y la web abre esa clase para reservar.
// Sirve el mismo index.html cambiando solo las etiquetas de la vista previa (vercel.json hace el ruteo).
const { SB_URL, SB_KEY, keyHeaders, siteUrl } = require('../lib/common');

const TZ = 'America/Argentina/Buenos_Aires';
const esc = s => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const money = n => '$ ' + Math.round(+n || 0).toLocaleString('es-AR');
let cache = { html: null, at: 0 };

async function indexHtml(site) {
  if (cache.html && Date.now() - cache.at < 60000) return cache.html;
  const r = await fetch(`${site}/index.html`);
  if (!r.ok) throw new Error('index ' + r.status);
  cache = { html: await r.text(), at: Date.now() };
  return cache.html;
}

async function slotInfo(id) {
  if (!/^[0-9a-f-]{36}$/i.test(id) || !SB_URL || !SB_KEY) return null;
  const sel = 'title,starts_at,duration_min,price,status,members_only,profe:profe_id(name),type:class_type_id(sport,kind)';
  const r = await fetch(`${SB_URL}/rest/v1/slots?id=eq.${id}&select=${encodeURIComponent(sel)}`, { headers: keyHeaders() });
  const rows = r.ok ? await r.json().catch(() => []) : [];
  const s = rows[0];
  return s && s.status === 'open' && !s.members_only ? s : null;   // suspendidas / entrenamiento: tarjeta general
}

function setMeta(html, m) {
  const put = (prop, val) => {
    const re = new RegExp(`(<meta (?:property|name)="${prop}" content=")[^"]*(")`);
    html = html.replace(re, `$1${esc(val)}$2`);
  };
  put('og:title', m.title); put('og:description', m.desc); put('og:url', m.url);
  put('og:image', m.image); put('og:image:secure_url', m.image); put('og:image:alt', m.title);
  put('description', m.desc);
  html = html.replace(/<title>[^<]*<\/title>/, `<title>${esc(m.title)}</title>`);
  // las rutas de la web son relativas (img/…): desde /c/<id> tienen que salir de la raíz
  return html.replace('<head>', '<head>\n<base href="/">');
}

module.exports = async (req, res) => {
  const site = siteUrl(req);
  const sport = String(req.query.sport || '').toLowerCase();
  const slotId = String(req.query.slot || '');
  let html;
  try { html = await indexHtml(site); }
  catch { res.statusCode = 302; res.setHeader('Location', '/'); return res.end(); }

  let m = null;
  if (slotId) {
    const s = await slotInfo(slotId).catch(() => null);
    if (s) {
      const sp = s.type?.sport || 'sup', trav = s.type?.kind === 'travesia';
      const d = new Date(s.starts_at);
      const day = d.toLocaleDateString('es-AR', { timeZone: TZ, weekday: 'long', day: 'numeric', month: 'long' }).replace(',', '');
      const hour = d.toLocaleTimeString('es-AR', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hour12: false });
      const dur = s.duration_min >= 120 ? `${String(Math.round(s.duration_min / 6) / 10).replace('.', ',')} h` : `${s.duration_min} min`;
      m = {
        title: `${trav ? '🧭 ' : sp === 'kayak' ? '🛶 ' : '🏄 '}${s.title} · ${day.charAt(0).toUpperCase() + day.slice(1)} ${hour}`,
        desc: `Con ${s.profe?.name || 'Nativo'} · ${dur} · ${money(s.price)} por persona. Reservá tu lugar en Nativo 👉`,
        url: `${site}/c/${slotId}`,
        image: `${site}/img/${sp === 'kayak' ? 'og-kayak.jpg' : 'og.jpg'}`,
      };
    }
  } else if (sport === 'kayak') {
    m = {
      title: 'Nativo · Kayak en Rosario',
      desc: 'Clases de kayak y travesías por el río. Elegí día y horario y reservá online. 📍 Guardería Barlovento.',
      url: `${site}/kayak`,
      image: `${site}/img/og-kayak.jpg`,
    };
  }
  if (m) html = setMeta(html, m);
  else html = html.replace('<head>', '<head>\n<base href="/">');

  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', 'public, s-maxage=300, stale-while-revalidate=600');
  res.statusCode = 200;
  res.end(html);
};
