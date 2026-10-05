# Nativo · Escuela de SUP — reservas

Página única (`index.html`) para que los alumnos reserven clases y los profes/admins gestionen horarios, cobros y números.

## Probarla ya (modo demo)
Abrí `index.html` en el navegador. Sin configurar Supabase arranca en **modo demo**, con datos de prueba guardados en ese navegador.
En **Profes** podés entrar como admin, como profe o como profe pendiente de aprobación.

## Ponerla en producción (unos 15 minutos)
1. Creá un proyecto **nuevo** en [supabase.com](https://supabase.com) (no uses el de Suptrain).
2. En **SQL Editor**, pegá y ejecutá `supabase/setup.sql`.
3. En **Project Settings → API**, copiá la *Project URL* y la *anon/publishable key* en `CONFIG` al principio del `<script>` de `index.html`. Completá también el `WHATSAPP` de la escuela y el `LOCATION`.
4. En **Authentication → URL Configuration**, poné como *Site URL* la dirección donde vas a publicar la página. En *Redirect URLs* agregá `https://tu-sitio/?staff=1`, que es a donde vuelven los mails de invitación y de recuperar contraseña.
5. Publicá en Netlify con un sitio conectado a este repo y *Base directory* `nativo` (así se publican también las funciones de Mercado Pago).
6. Entrá a la página → **Profes → pedí acceso acá**, confirmá el email y después corré en el SQL Editor:
   ```sql
   update public.profiles set role = 'admin', approved = true where email = 'tu-email@ejemplo.com';
   ```
7. Para sumar profes: **Profes → Agregar profe** (nombre, email, WhatsApp, %). Al profe le llega un mail, elige su contraseña y ya entra a su agenda.
   Para esto, en Netlify tienen que estar `SUPABASE_URL` y `SUPABASE_SERVICE_ROLE_KEY` (ver tabla de Mercado Pago). La función `invite-profe` verifica que quien lo pide sea admin.
   Si un profe pide acceso por su cuenta, aparece en "Pidieron acceso" para aprobarlo con un toque.

## Pago online con Mercado Pago (opcional)
El alumno reserva y en la misma pantalla puede tocar **Pagar ahora con Mercado Pago**. También puede pagar después desde **Pagar mi reserva**, con su código.
Cuando Mercado Pago aprueba el pago, avisa al servidor (`mp-webhook`) y la reserva queda marcada como **pagó · mercadopago** sin que nadie toque nada.

1. En [Mercado Pago Developers](https://www.mercadopago.com.ar/developers/panel/app) creá una aplicación de tipo *Checkout Pro*. Copiá el **Access Token**: primero el de prueba (`TEST-…`), y el de producción cuando esté todo probado.
2. En Netlify → *Site configuration → Environment variables*, cargá:
   | Variable | Valor |
   |---|---|
   | `MP_ACCESS_TOKEN` | Access Token de Mercado Pago |
   | `SUPABASE_URL` | la misma URL del proyecto |
   | `SUPABASE_SERVICE_ROLE_KEY` | Supabase → Project Settings → API → *service_role* (**secreta**: va solo acá, nunca en el HTML) |
   | `MP_WEBHOOK_SECRET` | opcional pero recomendado: la "clave secreta" de *Webhooks* en tu app de MP |
   | `SITE_URL` | opcional: `https://tu-sitio.netlify.app` (si no, usa la URL de Netlify) |
3. En la app de Mercado Pago → *Webhooks*, poné como URL `https://tu-sitio/.netlify/functions/mp-webhook` y marcá el evento **Pagos**.
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
