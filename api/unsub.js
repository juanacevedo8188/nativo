// Baja de los mails de promoción ("Te extrañamos"). El link lleva una firma (t) para que nadie dé de baja a otro.
const crypto = require('crypto');
const { keyProblem } = require('../lib/common');
const M = require('../lib/mail');

const page = (title, text) => `<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Nativo</title></head>
<body style="margin:0;background:#f3faf6;font-family:Arial,Helvetica,sans-serif;color:#1f1d1e"><div style="max-width:460px;margin:60px auto;padding:0 18px;text-align:center">
<div style="font-size:26px;font-weight:800;color:#0e8488">Nativo</div><h1 style="font-size:22px">${title}</h1><p style="color:#4a5a56">${text}</p>
<a href="/" style="display:inline-block;margin-top:10px;background:#fbef46;color:#1f1d1e;font-weight:800;padding:12px 20px;border-radius:999px;border:2px solid #1f1d1e;text-decoration:none">Ir a la web</a></div></body></html>`;

module.exports = async (req, res) => {
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  const email = String(req.query.e || '').trim().toLowerCase(), t = String(req.query.t || '');
  const ok = email && process.env.CRON_SECRET && t === crypto.createHmac('sha256', process.env.CRON_SECRET).update(email).digest('hex').slice(0, 24);
  if (!ok || keyProblem()) { res.statusCode = 400; return res.end(page('Link inválido', 'Este link de baja no es válido.')); }
  try {
    await M.rest('mail_optout?on_conflict=email', { method: 'POST', headers: { Prefer: 'resolution=ignore-duplicates,return=minimal' }, body: JSON.stringify({ email }) });
    res.end(page('Listo, te dimos de baja', 'No te vamos a mandar más mails de promociones. Los de tus reservas (confirmación y recordatorio) te siguen llegando.'));
  } catch (e) { res.statusCode = 500; res.end(page('Ups', 'No pudimos darte de baja. Probá de nuevo en un rato.')); }
};
