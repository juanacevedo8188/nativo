// Mercado Pago avisa acá cada cambio de un pago. Consultamos el pago a la API de MP
// (no confiamos en el cuerpo del aviso) y actualizamos la reserva:
//   approved                → paid = true, payment_method = 'mercadopago'
//   refunded / charged_back → paid = false (si era ese mismo pago)
const crypto = require('crypto');
const { send, readBody, sb, mp, configured } = require('../lib/common');

// Firma x-signature: "ts=...,v1=..." = HMAC-SHA256(secret, "id:<data.id>;request-id:<x-request-id>;ts:<ts>;")
function validSignature(req, dataId) {
  const secret = process.env.MP_WEBHOOK_SECRET;
  if (!secret) return true;                                // opcional: si no está configurada, no se valida
  const h = req.headers || {};                             // Node ya los da en minúscula
  const parts = Object.fromEntries(String(h['x-signature'] || '').split(',').map(p => p.trim().split('=')));
  if (!parts.ts || !parts.v1) return false;
  const id = /^[a-z0-9]+$/i.test(dataId) ? String(dataId).toLowerCase() : dataId;
  const manifest = `id:${id};request-id:${h['x-request-id'] || ''};ts:${parts.ts};`;
  const expected = crypto.createHmac('sha256', secret).update(manifest).digest('hex');
  return expected.length === parts.v1.length && crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(parts.v1));
}

module.exports = async (req, res) => {
  const json = (status, body) => send(res, status, body);
  if (!configured()) return json(500, { error: 'not configured' });
  const q = req.query || {};
  const body = readBody(req);
  const type = body.type || q.type || q.topic;
  const id = String(q['data.id'] || body?.data?.id || q.id || '');
  if (type !== 'payment' || !id) return json(200, { ignored: true });
  if (!validSignature(req, id)) return json(401, { error: 'firma inválida' });

  try {
    const pay = await mp(`/v1/payments/${encodeURIComponent(id)}`);
    const ref = pay.external_reference;
    if (!ref || !/^[0-9a-f-]{36}$/i.test(ref)) return json(200, { ignored: 'sin reserva' });
    const [b] = await sb(`bookings?id=eq.${ref}&select=id,amount,paid,mp_payment_id`);
    if (!b) return json(200, { ignored: 'reserva inexistente' });

    if (pay.status === 'approved') {
      if (pay.currency_id !== 'ARS' || Number(pay.transaction_amount) + 0.01 < Number(b.amount)) {
        console.warn('Pago aprobado con monto distinto', { id, amount: pay.transaction_amount, esperado: b.amount });
        return json(200, { ignored: 'monto distinto' });
      }
      if (!b.paid || b.mp_payment_id !== String(pay.id)) {
        await sb(`bookings?id=eq.${b.id}`, { method: 'PATCH', body: JSON.stringify({ paid: true, payment_method: 'mercadopago', mp_payment_id: String(pay.id) }) });
      }
    } else if (['refunded', 'charged_back'].includes(pay.status) && b.mp_payment_id === String(pay.id)) {
      await sb(`bookings?id=eq.${b.id}`, { method: 'PATCH', body: JSON.stringify({ paid: false, notes: `Pago MP ${pay.id} ${pay.status}` }) });
    }
    return json(200, { ok: true, status: pay.status });
  } catch (e) {
    console.error(e);
    return json(500, { error: 'reintentar' });                // 5xx → Mercado Pago reintenta el aviso
  }
};
