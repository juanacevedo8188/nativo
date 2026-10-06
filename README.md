# Nativo · Escuela de SUP — reservas

Página única (`index.html`) para que los alumnos reserven clases y los profes/admins gestionen horarios, cobros y números.

## Probarla ya (modo demo)
Abrí `index.html` en el navegador. Sin configurar Supabase arranca en **modo demo**, con datos de prueba guardados en ese navegador.
En **Profes** podés entrar como admin, como profe o como profe pendiente de aprobación.

## Ponerla en producción (unos 15 minutos)
1. Creá un proyecto **nuevo** en [supabase.com](https://supabase.com) (exclusivo para Nativo).
2. En **SQL Editor**, pegá y ejecutá `supabase/setup.sql`.
3. En **Project Settings → API**, copiá la *Project URL* y la *anon/publishable key* en `CONFIG` al principio del `<script>` de `index.html`. Completá también el `WHATSAPP` de la escuela y el `LOCATION`.
4. En **Authentication → URL Configuration**, poné como *Site URL* la dirección donde vas a publicar la página. En *Redirect URLs* agregá `https://tu-sitio/?staff=1`, que es a donde vuelven los mails de invitación y de recuperar contraseña.
5. Publicá en [Vercel](https://vercel.com): *Add New → Project →* importá este repo. *Framework Preset*: **Other**. No hace falta build command ni output directory: la página se sirve tal cual y los archivos de `api/` quedan como funciones del servidor.
   En *Settings → Environment Variables* cargá (y después *Redeploy*):
   | Variable | Valor |
   |---|---|
   | `SUPABASE_URL` | la Project URL |
   | `SUPABASE_SERVICE_ROLE_KEY` | Supabase → Project Settings → API Keys → *Legacy API keys* → **service_role** (`eyJ…`). **Secreta**: va solo acá, nunca en el HTML ni en el chat |
   | `SITE_URL` | la dirección de producción, ej. `https://nativo.vercel.app` (sin barra al final) |
6. Entrá a la página → **Profes → pedí acceso acá**, confirmá el email y después corré en el SQL Editor:
   ```sql
   update public.profiles set role = 'admin', approved = true, teaches = false where email = 'tu-email@ejemplo.com';
   ```
7. Para sumar profes: **Equipo → Agregar profe** (nombre, **usuario**, WhatsApp, %). El usuario (ej. `tomi`) no necesita mail: por dentro la cuenta es `tomi@usuarios.nativoescuela.com.ar` (`CONFIG.USER_DOMAIN`). Si ya es alumno con Google, poné su email de Google. Se le crea la cuenta con una **contraseña provisoria** y aparece el mensaje listo para mandárselo **por WhatsApp**: no se usan mails, así que no hay límite de envíos. El profe la cambia en *Perfil → Cambiar mi contraseña*.
   Si alguien se olvida la contraseña: *Equipo →* tocarlo *→ "Se olvidó la contraseña: generar una nueva"*.
   Para sacar a alguien: *Equipo →* tocarlo *→ "Sacar del equipo"*. Si nunca dio clases se borra la cuenta; si tiene historial queda **de baja** (no entra ni aparece, pero sus números siguen en el Resumen) y se puede reactivar. No borres profes a mano desde las tablas de Supabase.
   Necesita `SUPABASE_URL` y `SUPABASE_SERVICE_ROLE_KEY` en Vercel (paso 5). La función `api/invite-profe` verifica que quien lo pide sea admin.
   Recomendado: en Supabase → *Authentication → Sign In / Providers* desactivá **"Allow new users to sign up"**, así solo el admin crea cuentas.
8. Roles (Equipo → Rol): **Profe** da clases; **Admin** maneja la escuela y no aparece como profe; **Admin y profe** hace las dos cosas (crea clases a su nombre, ve "Mis clases" en la agenda y "Tu parte como profe" en el Resumen).

## Cuenta de alumno con Google (opcional para el alumno)
Los alumnos pueden reservar como invitados o **entrar con Google**: reservan en un toque (nombre y WhatsApp ya cargados) y tienen perfil con foto, Instagram, nivel, sus clases (próximas e historial), estadísticas y logros. Las reservas que hicieron como invitados con el mismo email de Google se suman solas.
Las cuentas de profes las crea el admin (el servidor las marca con `app_metadata.staff`); cualquier otro registro es alumno, así que entrar con Google nunca da acceso a la parte de profes.

Configuración (una vez):
1. [Google Cloud Console](https://console.cloud.google.com/) → crear proyecto → *APIs y servicios → Pantalla de consentimiento de OAuth* (Externo, nombre "Nativo", tu email) → *Publicar app*.
2. *Credenciales → Crear credenciales → ID de cliente de OAuth* → tipo **Aplicación web** → en *URIs de redireccionamiento autorizados* poné `https://<tu-proyecto>.supabase.co/auth/v1/callback`. Copiá el *ID de cliente* y el *Secreto*.
3. Supabase → *Authentication → Sign In / Providers → Google* → activalo y pegá ID y Secreto → *Save*.
4. Supabase → *Authentication → Sign In / Providers* → **"Allow new users to sign up" activado** (si no, los alumnos no pueden crear su cuenta).
5. Supabase → *Authentication → URL Configuration → Redirect URLs* → agregá `https://tu-sitio.vercel.app/**`.

## Abonos (paquete de clases)
- *Más → 💳 Abonos → Planes*: nombre, precio, clases y días de vigencia (arranca con "Abono mensual · $90.000 · 4 clases · 30 días"). La oferta se muestra en la página con lo que se ahorra frente a clases sueltas.
- El alumno (con cuenta de Google) lo pide desde la página o su perfil y coordina el pago por WhatsApp; el admin lo confirma en *Abonos → Pedidos → Cobrado* (se activa desde ese día) o lo da directo a un alumno.
- Al reservar, el alumno con abono ve "Usar mi abono (te quedan N)" y paga $0. Cada clase del abono vale precio ÷ clases (ej. $22.500) y con eso se calcula la parte del profe y el "Cobrado". Cancelar la reserva devuelve la clase al abono. El Resumen muestra aparte "Abonos vendidos".
- Todo lo controla la base: `request_pass`, `activate_pass`, `grant_pass`, `cancel_pass`, `my_passes`, `admin_passes` y `book_slot(..., p_use_pass)`.

## Entrenamiento
- En *Más → Precio y cupo* marcá el tipo de clase como **Solo entren.** y usá la descripción para días y horarios. Esas clases **no se publican en la web** (`public_slots` las excluye): se ven solo en la agenda de los profes, que anotan a los chicos con "+ Anotar alumno".
- En la página aparece una tarjeta de promoción con el WhatsApp de contacto (`CONFIG.TRAINING_CONTACT`, hoy Torita) para pedir info y sumarse.
- Los chicos del grupo con cuenta de Google piden su insignia desde el perfil; el admin la aprueba en *Equipo → Entrenamiento*. Los aprobados muestran 🏅 en el perfil (y suman un logro) y en la agenda.

## Comprobante para el alumno
Al reservar, el alumno pasa a **"Tu reserva"** (`/#r-CÓDIGO`): la reserva actualizada (pagada, suspendida…), botón para **guardar el comprobante como imagen** en el celu, agregarla al calendario, cómo llegar, compartir el link y escribir por WhatsApp. Ese celular además recuerda sus reservas y las muestra arriba en "Tus próximas clases". La función `booking_by_code` solo devuelve datos de la clase y el primer nombre.

## Pago online con Mercado Pago (opcional)
El alumno reserva y en la misma pantalla puede tocar **Pagar ahora con Mercado Pago**. También puede pagar después desde **Pagar mi reserva**, con su código.
Cuando Mercado Pago aprueba el pago, avisa al servidor (`api/mp-webhook`) y la reserva queda marcada como **pagó · mercadopago** sin que nadie toque nada.

1. En [Mercado Pago Developers](https://www.mercadopago.com.ar/developers/panel/app) creá una aplicación de tipo *Checkout Pro*. Copiá el **Access Token**: primero el de prueba (`TEST-…`), y el de producción cuando esté todo probado.
2. En Vercel → *Settings → Environment Variables*, sumá (además de las del paso 5) y hacé *Redeploy*:
   | Variable | Valor |
   |---|---|
   | `MP_ACCESS_TOKEN` | Access Token de Mercado Pago |
   | `MP_WEBHOOK_SECRET` | opcional pero recomendado: la "clave secreta" de *Webhooks* en tu app de MP |
3. En la app de Mercado Pago → *Webhooks*, poné como URL `https://tu-sitio/api/mp-webhook` y marcá el evento **Pagos**.
4. En `index.html`, poné `MERCADOPAGO: true` en `CONFIG`.

Seguridad: el navegador solo manda el código de reserva. El monto se lee de la base, y el webhook vuelve a consultar el pago a la API de Mercado Pago antes de marcar nada. Si el monto pagado es menor al de la reserva, no la marca como paga. Si hay devolución o contracargo, la desmarca.
Comisión: Mercado Pago cobra su comisión sobre cada cobro con Checkout Pro. Los números del panel muestran el monto bruto.

## Cómo funciona
| Quién | Qué hace |
|---|---|
| Alumno (sin cuenta) | Filtra por clase, profe y día. Reserva con nombre y WhatsApp, recibe un código y puede agregar la clase a su calendario. |
| Profe | Carga horarios uno por uno o en lote (días de la semana × horas × rango de fechas). Ve quién viene, marca asistencia y pago, y ve **Mis números**. |
| Admin | Hace todo lo anterior para todos los profes. Ve el **Resumen** del mes, aprueba profes, define el %, edita los tipos de clase y exporta el CSV. |

**Números del mes** (se cuentan las reservas no canceladas, en clases que no se suspendieron):
- Cobrado = Σ monto de las reservas marcadas como pagadas
- A pagar al profe = Σ cobrado × % del profe. Se usa el % que tenía el profe cuando se cargó cada horario.
- Neto escuela = Cobrado − A pagar a profes
- Por cobrar = Σ monto de las reservas sin pagar (confirmadas o con asistencia)
- **No cobrados** (al final del resumen): clases ya dadas en los últimos 4 meses con alumnos sin pago marcado. No suman en la parte del profe hasta que alguien toca **Cobrado**. Así a los profes les conviene mantener la agenda al día.
- Ocupación = Σ personas que vinieron o están confirmadas ÷ Σ cupo

El cupo se valida dentro de la base (`book_slot`, con el horario bloqueado), así que dos personas no pueden quedarse con el último lugar.
Los horarios con reservas no se pueden borrar, solo suspender. Así siempre queda registro.
