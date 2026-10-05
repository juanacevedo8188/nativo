// POST { code } → crea una preferencia de Checkout Pro para esa reserva y devuelve { url }.
// El monto sale de la base (bookings.amount), nunca del navegador.
const { send, readBody, siteUrl, sb, mp, configured } = require('../lib/common');

module.exports = async (req, res) => {
  const json = (status, body) => send(res, status, body);
  if (req.method !== 'POST') return json(405, { error: 'Método no permitido' });
  if (!configured()) return json(500, { error: 'El pago online no está configurado todavía' });

  const code = String(readBody(req).code || '').trim().toUpperCase();
  if (!/^[0-9A-F]{6}$/.test(code)) return json(400, { error: 'El código tiene 6 caracteres (letras A-F y números)' });

  try {
    const [b] = await sb(`bookings?code=eq.${code}&select=id,code,amount,people,status,paid,customer_name,customer_email,slot:slot_id(title,starts_at,status)`);
    if (!b) return json(404, { error: 'No encontramos una reserva con ese código' });
    if (b.paid) return json(409, { error: 'Esa reserva ya está paga' });
    if (b.status === 'cancelled' || b.slot.status === 'cancelled') return json(409, { error: 'Esa reserva está cancelada' });
    if (new Date(b.slot.starts_at) < new Date()) return json(409, { error: 'La clase ya pasó' });
    if (!(Number(b.amount) > 0)) return json(409, { error: 'Esta reserva no tiene monto a pagar' });

    const site = siteUrl(req);
    const back = (r) => `${site}/?pago=${r}&code=${code}`;
    const fecha = new Date(b.slot.starts_at).toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false });

    const pref = await mp('/checkout/preferences', {
      method: 'POST',
      body: JSON.stringify({
        items: [{ id: b.code, title: `${b.slot.title} · ${fecha} · Nativo SUP`, quantity: 1, currency_id: 'ARS', unit_price: Number(b.amount) }],
        payer: b.customer_email ? { email: b.customer_email, name: b.customer_name } : { name: b.customer_name },
        external_reference: b.id,                         // así el webhook sabe qué reserva marcar
        back_urls: { success: back('ok'), pending: back('pendiente'), failure: back('error') },
        auto_return: 'approved',
        notification_url: `${site}/api/mp-webhook`,
        statement_descriptor: 'NATIVO SUP',
        // La preferencia vence cuando empieza la clase.
        expires: true,
        expiration_date_to: new Date(b.slot.starts_at).toISOString(),
      }),
    });
    return json(200, { url: pref.init_point });
  } catch (e) {
    console.error(e);
    return json(502, { error: 'No pudimos conectar con Mercado Pago. Probá de nuevo en un rato.' });
  }
};
