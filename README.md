# Nativo · Escuela de SUP — reservas

Página única (`index.html`) para que los alumnos reserven clases y los profes/admins gestionen horarios, cobros y números.

## Probarla ya (modo demo)
Abrí `index.html` en el navegador. Sin configurar Supabase arranca en **modo demo**, con datos de prueba guardados en ese navegador.
En **Profes** podés entrar como admin, como profe o como profe pendiente de aprobación.

## Ponerla en producción (unos 15 minutos)
1. Creá un proyecto **nuevo** en [supabase.com](https://supabase.com) (no uses el de Suptrain).
2. En **SQL Editor**, pegá y ejecutá `supabase/setup.sql`.
3. En **Project Settings → API**, copiá la *Project URL* y la *anon/publishable key* en `CONFIG` al principio del `<script>` de `index.html`. Completá también el `WHATSAPP` de la escuela y el `LOCATION`.
4. En **Authentication → URL Configuration**, poné como *Site URL* la dirección donde vas a publicar la página.
5. Publicá la carpeta `nativo/` (Netlify: *Add new site → Deploy manually* y arrastrás la carpeta, o un sitio con *base directory* `nativo`).
6. Entrá a la página → **Profes → Creá tu cuenta**, confirmá el email y después corré en el SQL Editor:
   ```sql
   update public.profiles set role = 'admin', approved = true where email = 'tu-email@ejemplo.com';
   ```
7. Cada profe se crea su cuenta de la misma forma. Vos lo aprobás desde **Profes** y le asignás su %.

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
- Ocupación = Σ personas que vinieron o están confirmadas ÷ Σ cupo

El cupo se valida dentro de la base (`book_slot`, con el horario bloqueado), así que dos personas no pueden quedarse con el último lugar.
Los horarios con reservas no se pueden borrar, solo suspender. Así siempre queda registro.
