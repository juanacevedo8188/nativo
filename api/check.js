// Diagnóstico de la configuración del servidor. Abrí  https://tu-sitio/api/check  en el navegador.
// No muestra ninguna clave: solo si están, de qué tipo son y si Supabase las acepta.
const { SB_URL, SB_KEY, jwtRole, keyHeaders, keyProblem } = require('../lib/common');

module.exports = async (req, res) => {
  const keyType = !SB_KEY ? 'falta' : SB_KEY.startsWith('sb_secret_') ? 'secreta nueva (sb_secret) ✓'
    : SB_KEY.startsWith('sb_publishable_') ? 'PÚBLICA ✗ (tiene que ser la secreta)'
    : SB_KEY.startsWith('eyJ') ? (jwtRole(SB_KEY) === 'service_role' ? 'service_role ✓' : `JWT "${jwtRole(SB_KEY)}" ✗ (tiene que ser service_role)`) : 'formato desconocido ✗';
  const out = {
    SUPABASE_URL: SB_URL ? SB_URL.replace(/^https:\/\//, '') : 'falta ✗',
    SUPABASE_SERVICE_ROLE_KEY: keyType,
    SITE_URL: process.env.SITE_URL || '(no está; se usa la dirección del sitio)',
    MP_ACCESS_TOKEN: process.env.MP_ACCESS_TOKEN ? 'cargado' : '(no está; solo hace falta para Mercado Pago)',
  };
  const problem = keyProblem();
  if (!problem) {
    try {
      const r = await fetch(`${SB_URL}/rest/v1/profiles?select=role,approved&limit=50`, { headers: keyHeaders() });
      const d = await r.json().catch(() => null);
      out.lectura_base = r.ok ? `OK ✓ (${d.length} perfiles, ${d.filter(p => p.role === 'admin' && p.approved).length} admin)` : `ERROR ${r.status} ✗ ${d?.message || d?.msg || ''}`;
      const a = await fetch(`${SB_URL}/auth/v1/admin/users?per_page=1`, { headers: keyHeaders() });
      out.permiso_invitar = a.ok ? 'OK ✓' : `ERROR ${a.status} ✗`;
    } catch (e) { out.conexion = `No se pudo conectar a Supabase ✗ (${e.message}) — revisá SUPABASE_URL`; }
  }
  out.resultado = problem ? `✗ ${problem}` : (out.lectura_base || '').startsWith('OK') && out.permiso_invitar === 'OK ✓' ? '✓ Todo bien: "Agregar profe" debería funcionar' : '✗ Hay un problema: mirá las líneas con ✗';
  res.setHeader('Cache-Control', 'no-store');
  res.status(200).json(out);
};
