-- NATIVO · Escuela de SUP — base de datos de reservas.
-- Correr una sola vez en un proyecto NUEVO de Supabase:
--   Dashboard → SQL Editor → New query → pegar todo → Run.
-- Es idempotente: si lo volvés a correr no rompe nada ni borra datos.
--
-- Modelo:
--   profiles     → profes y admins (1 por usuario de Supabase Auth)
--   class_types  → catálogo: iniciación, privada, travesía… con precio sugerido
--   slots        → cada horario que publica un profe (fecha, cupo, precio)
--   bookings     → cada reserva de un alumno sobre un horario
--
-- Los alumnos NO necesitan cuenta: reservan con nombre + WhatsApp a través de
-- la función book_slot(), que valida el cupo dentro de la base (no en el
-- navegador), así dos personas no pueden quedarse con el último lugar.

-- ───────────────────────────── 1) Tablas ─────────────────────────────

create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  name           text not null default '',
  email          text,
  phone          text,
  bio            text,
  role           text not null default 'profe' check (role in ('admin', 'profe')),
  approved       boolean not null default false,
  -- % de lo cobrado que le corresponde al profe. Se copia a cada horario al
  -- crearlo (slots.profe_pct), así cambiarlo no altera clases ya cargadas.
  commission_pct numeric(5,2) not null default 50 check (commission_pct between 0 and 100),
  created_at     timestamptz not null default now()
);

-- Un admin puede ser solo admin (no da clases) o admin y profe a la vez.
-- teaches = da clases: aparece en la página de reservas y en la lista de profes.
alter table public.profiles add column if not exists teaches boolean not null default true;
-- Alias (o CBU/CVU) del profe para que el alumno le transfiera la clase, y el titular para confirmar.
alter table public.profiles add column if not exists pay_alias  text;
alter table public.profiles add column if not exists pay_holder text;
-- Disciplinas: qué da cada profe (sports) y de cuáles configura tipos de clase, precios y cupos (manages).
-- Ej.: Mati → sports {kayak}, manages {kayak}. Los admins manejan todo.
alter table public.profiles add column if not exists sports  text[] not null default '{sup}';
alter table public.profiles add column if not exists manages text[] not null default '{}';
-- Dado de baja: ya no entra ni aparece, pero sus clases y números quedan en el historial.
alter table public.profiles add column if not exists archived boolean not null default false;
-- Foto del profe (link público al archivo en Storage → bucket "avatars").
alter table public.profiles add column if not exists avatar_url text;
-- Cada profe elige si su WhatsApp se muestra a los alumnos (botón "Escribile").
alter table public.profiles add column if not exists public_whatsapp boolean not null default true;

create table if not exists public.class_types (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  description  text,
  duration_min int not null default 60 check (duration_min > 0),
  price        numeric(12,2) not null default 0 check (price >= 0),
  capacity     int not null default 1 check (capacity > 0),
  active       boolean not null default true,
  sort         int not null default 0,
  created_at   timestamptz not null default now()
);

create table if not exists public.slots (
  id            uuid primary key default gen_random_uuid(),
  profe_id      uuid not null references public.profiles(id) on delete restrict,
  class_type_id uuid references public.class_types(id) on delete set null,
  title         text not null,
  starts_at     timestamptz not null,
  duration_min  int not null default 60 check (duration_min > 0),
  capacity      int not null default 1 check (capacity > 0),
  price         numeric(12,2) not null default 0 check (price >= 0), -- por persona
  profe_pct     numeric(5,2) not null default 0,                      -- lo setea el trigger
  location      text,
  notes         text,
  status        text not null default 'open' check (status in ('open', 'cancelled')),
  created_at    timestamptz not null default now()
);
create index if not exists slots_starts_at_idx on public.slots (starts_at);
create index if not exists slots_profe_idx on public.slots (profe_id, starts_at);

create table if not exists public.bookings (
  id             uuid primary key default gen_random_uuid(),
  code           text not null unique default upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)),
  -- restrict: un horario con reservas no se puede borrar, solo cancelar → queda el registro.
  slot_id        uuid not null references public.slots(id) on delete restrict,
  customer_name  text not null,
  customer_phone text not null,
  customer_email text,
  people         int not null default 1 check (people between 1 and 20),
  amount         numeric(12,2) not null default 0 check (amount >= 0), -- total (precio × personas)
  status         text not null default 'confirmed'
                 check (status in ('confirmed', 'attended', 'no_show', 'cancelled')),
  paid           boolean not null default false,
  payment_method text,  -- efectivo / transferencia / mercadopago
  notes          text,
  created_at     timestamptz not null default now()
);
create index if not exists bookings_slot_idx on public.bookings (slot_id);

-- Alumnos con cuenta (entran con Google). Los invitados siguen reservando sin cuenta.
create table if not exists public.students (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text,
  name       text not null default '',
  phone      text,
  avatar_url text,
  bio        text,
  instagram  text,
  level      text check (level in ('nunca', 'pocas', 'seguido')),
  created_at timestamptz not null default now()
);
alter table public.bookings add column if not exists student_id uuid references public.students(id) on delete set null;
-- Cómo dijo el alumno que va a pagar al reservar (transferencia al alias del profe o efectivo en la clase).
alter table public.bookings add column if not exists pay_pref text;
alter table public.bookings drop constraint if exists bookings_pay_pref_check;
alter table public.bookings add constraint bookings_pay_pref_check check (pay_pref is null or pay_pref in ('transferencia', 'efectivo'));

-- Entrenamiento: clases solo para alumnos aprobados por un admin.
--   class_types.members_only / slots.members_only → la clase es "Solo entrenamiento".
--   students.training: none (nada) → requested (lo pidió) → approved (lo aprobó un admin).
alter table public.class_types add column if not exists members_only boolean not null default false;
-- Disciplina (SUP o kayak) y tipo: iniciación, travesía (se resalta en la página) u otra.
alter table public.class_types add column if not exists sport text not null default 'sup';
alter table public.class_types add column if not exists kind  text not null default 'iniciacion';
alter table public.class_types drop constraint if exists class_types_sport_check;
alter table public.class_types add constraint class_types_sport_check check (sport in ('sup', 'kayak'));
alter table public.class_types drop constraint if exists class_types_kind_check;
alter table public.class_types add constraint class_types_kind_check check (kind in ('iniciacion', 'travesia', 'otra'));
alter table public.slots       add column if not exists members_only boolean not null default false;
alter table public.students    add column if not exists training text not null default 'none';
alter table public.students    add column if not exists training_note text;
alter table public.students    drop constraint if exists students_training_check;
alter table public.students    add constraint students_training_check check (training in ('none', 'requested', 'approved'));

-- Abonos: el alumno paga un plan (ej. $90.000 = 4 clases en 30 días) y reserva con esas clases.
create table if not exists public.plans (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  description text,
  price       numeric(12,2) not null default 0 check (price >= 0),
  classes     int not null default 4 check (classes > 0),
  days_valid  int not null default 30 check (days_valid > 0),
  active      boolean not null default true,
  sort        int not null default 0,
  created_at  timestamptz not null default now()
);
-- El abono sirve para clases de su disciplina (el actual es de SUP).
alter table public.plans add column if not exists sport text not null default 'sup';
create table if not exists public.passes (
  id             uuid primary key default gen_random_uuid(),
  student_id     uuid not null references public.students(id) on delete cascade,
  plan_id        uuid references public.plans(id) on delete set null,
  name           text not null,                      -- copia del plan al momento de comprarlo
  price          numeric(12,2) not null,
  classes_total  int not null check (classes_total > 0),
  days_valid     int not null default 30,
  status         text not null default 'pending' check (status in ('pending', 'active', 'cancelled')),
  starts_on      date,
  expires_on     date,
  payment_method text,
  paid_at        timestamptz,
  created_at     timestamptz not null default now()
);
create index if not exists passes_student_idx on public.passes (student_id);
-- La reserva hecha con abono queda vinculada (cancelarla devuelve la clase al abono).
alter table public.bookings add column if not exists pass_id uuid references public.passes(id) on delete set null;
create index if not exists bookings_student_idx on public.bookings (student_id);
-- Pago online: id del pago de Mercado Pago (lo completa el webhook, nunca el navegador).
alter table public.bookings add column if not exists mp_payment_id text;
-- Canal por el que llegó la reserva: la web, o cargada a mano por el profe.
alter table public.bookings add column if not exists source text not null default 'web';
alter table public.bookings drop constraint if exists bookings_source_check;
alter table public.bookings add constraint bookings_source_check
  check (source in ('web', 'whatsapp', 'instagram', 'presencial', 'otro'));

-- ───────────────────────────── 2) Helpers ─────────────────────────────
-- security definer: leen profiles/slots sin pasar por RLS (evita recursión).

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin' and approved);
$fn$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from profiles where id = auth.uid() and approved);
$fn$;

-- ¿Puede configurar tipos de clase / precios de esta disciplina? (admin, o profe con esa disciplina en manages)
create or replace function public.can_manage_sport(p_sport text) returns boolean
language sql stable security definer set search_path = public as $fn$
  select is_admin() or exists (select 1 from profiles where id = auth.uid() and approved and p_sport = any(manages));
$fn$;

create or replace function public.owns_slot(p_slot uuid) returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from slots where id = p_slot and profe_id = auth.uid());
$fn$;

-- ───────────────────────────── 3) Triggers ─────────────────────────────

-- Cada usuario nuevo de Auth (un profe que se registra) → perfil pendiente de aprobación.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  -- Profes/admins: los crea el admin desde Equipo y el servidor les marca app_metadata.staff
  -- (app_metadata solo lo puede escribir el servidor, no el usuario). También el primer usuario.
  if coalesce(new.raw_app_meta_data ->> 'staff', '') = 'true' or not exists (select 1 from profiles) then
    insert into profiles (id, email, name)
    values (new.id, new.email,
            coalesce(nullif(btrim(new.raw_user_meta_data ->> 'name'), ''), split_part(new.email, '@', 1)))
    on conflict (id) do nothing;
  else
    -- Cualquier otro registro (Google) es un alumno: nombre y foto vienen de su cuenta de Google.
    insert into students (id, email, name, avatar_url)
    values (new.id, new.email,
            coalesce(nullif(btrim(coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name')), ''), split_part(new.email, '@', 1)),
            coalesce(new.raw_user_meta_data ->> 'avatar_url', new.raw_user_meta_data ->> 'picture'))
    on conflict (id) do nothing;
  end if;
  return new;
end $fn$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Un profe puede editar su nombre/teléfono/bio, pero no su rol, aprobación ni %.
-- (auth.uid() es null cuando corrés SQL desde el dashboard → ahí no se restringe.)
create or replace function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  if auth.uid() is not null and not is_admin() then
    new.role := old.role;
    new.approved := old.approved;
    new.commission_pct := old.commission_pct;
    new.teaches := old.teaches;
    new.email := old.email;
    new.archived := old.archived;
    new.sports := old.sports;
    new.manages := old.manages;
  end if;
  return new;
end $fn$;

drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard
  before update on public.profiles
  for each row execute function public.profiles_guard();

-- Horarios: un profe solo carga a su nombre; el % del profe se toma del perfil
-- al crear el horario y solo un admin lo puede cambiar después.
create or replace function public.slots_guard() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null and not is_admin() then
      new.profe_id := auth.uid();
      -- un profe solo crea clases de las disciplinas que da (ej. Mati: kayak)
      if not coalesce((select ct.sport from class_types ct where ct.id = new.class_type_id), 'sup')
             = any(coalesce((select sports from profiles where id = new.profe_id), '{}'::text[])) then
        raise exception 'No das clases de esa disciplina. Pedile a un admin que te la habilite.';
      end if;
    end if;
    new.profe_pct := coalesce((select commission_pct from profiles where id = new.profe_id), 0);
  elsif auth.uid() is not null and not is_admin() then
    new.profe_id := old.profe_id;
    new.profe_pct := old.profe_pct;
  end if;
  return new;
end $fn$;

drop trigger if exists slots_guard on public.slots;
create trigger slots_guard
  before insert or update on public.slots
  for each row execute function public.slots_guard();

-- ─────────────────────── 4) Funciones públicas (sin login) ───────────────────────

-- Horarios disponibles a futuro, con cupo ocupado. No expone datos de alumnos.
drop function if exists public.public_slots(timestamptz, timestamptz);   -- cambió lo que devuelve (members_only)
create or replace function public.public_slots(p_from timestamptz, p_to timestamptz)
returns table (
  id uuid, title text, class_type_id uuid, starts_at timestamptz, duration_min int,
  capacity int, price numeric, location text, notes text,
  profe_id uuid, profe_name text, booked int, members_only boolean
)
language sql stable security definer set search_path = public as $fn$
  select s.id, s.title, s.class_type_id, s.starts_at, s.duration_min,
         s.capacity, s.price, s.location, s.notes,
         s.profe_id, p.name,
         coalesce((select sum(b.people) from bookings b
                   where b.slot_id = s.id and b.status <> 'cancelled'), 0)::int,
         s.members_only
  from slots s
  join profiles p on p.id = s.profe_id
  where s.status = 'open'
    and not s.members_only          -- las de entrenamiento se manejan por WhatsApp: no se publican
    and p.approved
    and s.starts_at >= greatest(p_from, now())
    and s.starts_at < p_to
    and p_to - p_from <= interval '93 days'
  order by s.starts_at;
$fn$;

-- Profes para mostrar en la página pública.
drop function if exists public.public_profes();   -- cambió lo que devuelve (alias para transferir)
create or replace function public.public_profes()
returns table (id uuid, name text, bio text, avatar_url text, whatsapp text, sports text[], pay_alias text, pay_holder text)
language sql stable security definer set search_path = public as $fn$
  select p.id, p.name, p.bio, p.avatar_url, case when p.public_whatsapp then nullif(btrim(p.phone), '') end, p.sports,
         nullif(btrim(p.pay_alias), ''), nullif(btrim(p.pay_holder), '')
  from profiles p
  where p.approved
    and (p.teaches
         or exists (select 1 from slots s where s.profe_id = p.id and s.starts_at > now() and s.status = 'open'))
  order by p.name;
$fn$;

-- Reserva: valida datos y cupo con el horario bloqueado (FOR UPDATE).
-- p_use_pass: el alumno con cuenta paga con su abono (descuenta clases, queda pagada).
drop function if exists public.book_slot(uuid, text, text, text, int);
drop function if exists public.book_slot(uuid, text, text, text, int, boolean);   -- ahora también recibe cómo va a pagar
create or replace function public.book_slot(
  p_slot uuid, p_name text, p_phone text, p_email text default null, p_people int default 1, p_use_pass boolean default false,
  p_pay text default null
)
returns table (code text, starts_at timestamptz, title text, profe_name text, people int, amount numeric)
language plpgsql security definer set search_path = public as $fn$
#variable_conflict use_column
declare
  s        slots;
  v_booked int;
  v_code   text;
  v_digits text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_pass   passes;
  v_left   int;
  v_amount numeric;
  v_day    date;
begin
  p_name  := btrim(coalesce(p_name, ''));
  p_phone := btrim(coalesce(p_phone, ''));
  p_email := nullif(btrim(coalesce(p_email, '')), '');

  if length(p_name) < 2 or length(p_name) > 80 then
    raise exception 'Ingresá tu nombre y apellido';
  end if;
  if length(v_digits) < 8 or length(p_phone) > 30 then
    raise exception 'Ingresá un WhatsApp válido (con característica)';
  end if;
  if p_email is not null and (length(p_email) > 120 or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then
    raise exception 'El email no es válido';
  end if;
  if p_people is null or p_people < 1 or p_people > 20 then
    raise exception 'Cantidad de personas inválida';
  end if;

  select * into s from slots where slots.id = p_slot for update;
  if not found or s.status <> 'open' then
    raise exception 'Ese horario ya no está disponible';
  end if;
  if s.starts_at <= now() then
    raise exception 'Ese horario ya pasó';
  end if;
  if s.members_only and not exists (select 1 from students st where st.id = auth.uid() and st.training = 'approved') then
    raise exception 'Esta clase es solo para alumnos de entrenamiento';
  end if;

  select coalesce(sum(b.people), 0) into v_booked
  from bookings b where b.slot_id = p_slot and b.status <> 'cancelled';
  if v_booked + p_people > s.capacity then
    raise exception 'Quedan % lugares en ese horario', greatest(s.capacity - v_booked, 0);
  end if;

  if exists (select 1 from bookings b
             where b.slot_id = p_slot and b.status <> 'cancelled'
               -- últimos 10 dígitos: "+54 9 341 555-1234" y "3415551234" son el mismo número
               and right(regexp_replace(b.customer_phone, '\D', '', 'g'), 10) = right(v_digits, 10)) then
    raise exception 'Ya hay una reserva con ese WhatsApp en este horario';
  end if;

  v_amount := s.price * p_people;
  if p_use_pass then
    v_day := (s.starts_at at time zone 'America/Argentina/Buenos_Aires')::date;
    select ps.* into v_pass from passes ps left join plans pl on pl.id = ps.plan_id
    where ps.student_id = auth.uid() and ps.status = 'active' and v_day between ps.starts_on and ps.expires_on
      and coalesce(pl.sport, 'sup') = coalesce((select ct.sport from class_types ct where ct.id = s.class_type_id), 'sup')
    order by ps.expires_on limit 1 for update of ps;
    if not found then raise exception 'No tenés un abono activo para esa fecha y esa disciplina'; end if;
    v_left := v_pass.classes_total - coalesce((select sum(b.people) from bookings b where b.pass_id = v_pass.id and b.status <> 'cancelled'), 0);
    if v_left < p_people then raise exception 'Te quedan % clases en tu abono', v_left; end if;
    v_amount := round(v_pass.price / v_pass.classes_total) * p_people;   -- valor de cada clase del abono
  end if;

  insert into bookings (slot_id, customer_name, customer_phone, customer_email, people, amount, student_id, pass_id, paid, payment_method, pay_pref)
  values (p_slot, p_name, p_phone, p_email, p_people, v_amount,
          (select st.id from students st where st.id = auth.uid()),   -- si reservó con su cuenta
          v_pass.id, p_use_pass, case when p_use_pass then 'abono' end,
          case when not p_use_pass and p_pay in ('transferencia', 'efectivo') then p_pay end)
  returning bookings.code into v_code;

  return query
    select v_code, s.starts_at, s.title,
           (select pr.name from profiles pr where pr.id = s.profe_id),
           p_people, v_amount;
end $fn$;

-- "Mi reserva": el alumno ve su reserva con el código (link nativo…/#r-CÓDIGO).
-- Devuelve solo datos de la clase y el primer nombre; nada de teléfono ni email.
drop function if exists public.booking_by_code(text);   -- cambió lo que devuelve (alias y forma de pago)
create or replace function public.booking_by_code(p_code text)
returns table (
  code text, first_name text, title text, starts_at timestamptz, duration_min int,
  location text, profe_name text, people int, amount numeric, paid boolean,
  status text, slot_status text, profe_whatsapp text, payment_method text, sport text,
  pay_pref text, profe_alias text, profe_holder text
)
language sql stable security definer set search_path = public as $fn$
  select b.code, split_part(btrim(b.customer_name), ' ', 1), s.title, s.starts_at, s.duration_min,
         s.location, p.name, b.people, b.amount, b.paid, b.status, s.status,
         case when p.public_whatsapp then nullif(btrim(p.phone), '') end, b.payment_method, coalesce(ct.sport, 'sup'),
         b.pay_pref, nullif(btrim(p.pay_alias), ''), nullif(btrim(p.pay_holder), '')
  from bookings b
  join slots s on s.id = b.slot_id
  join profiles p on p.id = s.profe_id
  left join class_types ct on ct.id = s.class_type_id
  where p_code ~* '^[0-9a-f]{6}$' and b.code = upper(btrim(p_code));
$fn$;
-- Clases del alumno con cuenta (perfil). Suma las que reservó como invitado con el mismo email de Google.
drop function if exists public.my_bookings();   -- cambió lo que devuelve (disciplina y tipo)
create or replace function public.my_bookings()
returns table (
  code text, status text, paid boolean, people int, amount numeric, title text,
  starts_at timestamptz, duration_min int, location text, slot_status text,
  profe_name text, profe_avatar text, members_only boolean, sport text, kind text
)
language plpgsql security definer set search_path = public as $fn$
#variable_conflict use_column
begin
  if auth.uid() is null or not exists (select 1 from students where id = auth.uid()) then return; end if;
  update bookings b set student_id = auth.uid()
  where b.student_id is null and auth.email() is not null and lower(b.customer_email) = lower(auth.email());
  return query
    select b.code, b.status, b.paid, b.people, b.amount, s.title, s.starts_at, s.duration_min,
           s.location, s.status, p.name, p.avatar_url, s.members_only, coalesce(ct.sport, 'sup'), coalesce(ct.kind, 'iniciacion')
    from bookings b join slots s on s.id = b.slot_id join profiles p on p.id = s.profe_id
    left join class_types ct on ct.id = s.class_type_id
    where b.student_id = auth.uid()
    order by s.starts_at desc;
end $fn$;
revoke all on function public.my_bookings() from public;
grant execute on function public.my_bookings() to authenticated;

revoke all on function public.booking_by_code(text) from public;
grant execute on function public.booking_by_code(text) to anon, authenticated;

-- El alumno cancela su propia reserva desde el comprobante (si se confundió o no puede ir).
-- Prueba de que es suya: tener cuenta y ser el dueño, o poner el mismo WhatsApp con el que reservó.
-- Hasta 12 h antes de la clase (cambiar también CONFIG.CANCEL_HOURS en index.html). Si ya pagó,
-- no se cancela sola: hay que escribirle a la escuela (para la devolución). Si era con abono,
-- la clase vuelve al abono (pass_used no cuenta las canceladas).
create or replace function public.cancel_my_booking(p_code text, p_phone text default null)
returns text
language plpgsql security definer set search_path = public as $fn$
declare b bookings; s slots;
  digits text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 8);
begin
  select * into b from bookings where code = upper(btrim(p_code)) and p_code ~* '^\s*[0-9a-f]{6}\s*$' for update;
  if not found then raise exception 'No encontramos esa reserva'; end if;
  if not ((auth.uid() is not null and b.student_id = auth.uid())
          or (length(digits) >= 6 and right(regexp_replace(b.customer_phone, '\D', '', 'g'), 8) = digits)) then
    raise exception 'El WhatsApp no coincide con el de la reserva';
  end if;
  select * into s from slots where id = b.slot_id;
  if b.status = 'cancelled' then return 'ok'; end if;
  if b.status <> 'confirmed' or s.status <> 'open' then raise exception 'Esta reserva ya no se puede cancelar'; end if;
  if s.starts_at < now() + interval '12 hours' then
    raise exception 'Faltan menos de 12 horas: para cancelar escribinos por WhatsApp';
  end if;
  if b.paid and coalesce(b.payment_method, '') <> 'abono' then
    raise exception 'La reserva ya está paga: para cancelarla escribinos por WhatsApp';
  end if;
  update bookings set status = 'cancelled',
    notes = concat_ws(' · ', nullif(btrim(notes), ''), 'Cancelada por el alumno ' || to_char(now() at time zone 'America/Argentina/Buenos_Aires', 'DD/MM HH24:MI'))
  where id = b.id;
  return 'ok';
end $fn$;
revoke all on function public.cancel_my_booking(text, text) from public;
grant execute on function public.cancel_my_booking(text, text) to anon, authenticated;

-- Borrar una clase SUSPENDIDA junto con sus reservas canceladas (para que no ocupe lugar).
-- Solo el admin o el profe de esa clase. No deja borrar si alguna reserva quedó cobrada.
create or replace function public.delete_suspended_slot(p_slot uuid)
returns void
language plpgsql security definer set search_path = public as $fn$
declare s slots;
begin
  select * into s from slots where id = p_slot for update;
  if not found then raise exception 'Esa clase ya no existe'; end if;
  if not (is_admin() or (is_staff() and s.profe_id = auth.uid())) then raise exception 'No podés borrar esta clase'; end if;
  if s.status <> 'cancelled' then raise exception 'Solo se pueden borrar clases suspendidas'; end if;
  if exists (select 1 from bookings b where b.slot_id = p_slot and b.paid) then
    raise exception 'Esta clase tiene una reserva cobrada: marcala como no pagada (o devolvé la plata) antes de borrarla';
  end if;
  delete from bookings where slot_id = p_slot;
  delete from slots where id = p_slot;
end $fn$;
-- Borrar cualquier clase con sus reservas (pruebas o errores de carga). Admin o el profe de la clase.
-- Si alguna reserva estaba cobrada, hay que confirmarlo explícitamente (p_force = true).
create or replace function public.delete_slot(p_slot uuid, p_force boolean default false)
returns void
language plpgsql security definer set search_path = public as $fn$
declare s slots;
begin
  select * into s from slots where id = p_slot for update;
  if not found then raise exception 'Esa clase ya no existe'; end if;
  if not (is_admin() or (is_staff() and s.profe_id = auth.uid())) then raise exception 'No podés borrar esta clase'; end if;
  if not p_force and exists (select 1 from bookings b where b.slot_id = p_slot and b.paid) then
    raise exception 'Esta clase tiene reservas cobradas';
  end if;
  delete from bookings where slot_id = p_slot;
  delete from slots where id = p_slot;
end $fn$;
revoke all on function public.delete_slot(uuid, boolean) from public;
grant execute on function public.delete_slot(uuid, boolean) to authenticated;

-- ── Abonos ──
drop function if exists public.cancel_pass(uuid);   -- ahora devuelve cuántas reservas cambió
-- Clases usadas de un abono = personas de sus reservas no canceladas.
create or replace function public.pass_used(p_pass uuid) returns int
language sql stable security definer set search_path = public as $fn$
  select coalesce(sum(b.people), 0)::int from bookings b where b.pass_id = p_pass and b.status <> 'cancelled';
$fn$;

-- El alumno pide un abono (queda pendiente hasta que un admin confirme el pago).
create or replace function public.request_pass(p_plan uuid) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare pl plans; v_id uuid;
begin
  if not exists (select 1 from students where id = auth.uid()) then raise exception 'Entrá con tu cuenta para pedir un abono'; end if;
  select * into pl from plans where id = p_plan and active;
  if not found then raise exception 'Ese abono ya no está disponible'; end if;
  if exists (select 1 from passes where student_id = auth.uid() and status = 'pending') then
    raise exception 'Ya tenés un pedido de abono pendiente';
  end if;
  insert into passes (student_id, plan_id, name, price, classes_total, days_valid)
  values (auth.uid(), pl.id, pl.name, pl.price, pl.classes, pl.days_valid) returning id into v_id;
  return v_id;
end $fn$;

-- Abonos del alumno logueado (perfil y reserva).
drop function if exists public.my_passes();   -- cambió lo que devuelve (disciplina)
create or replace function public.my_passes()
returns table (id uuid, name text, price numeric, classes_total int, used int, status text, starts_on date, expires_on date, sport text)
language sql stable security definer set search_path = public as $fn$
  select ps.id, ps.name, ps.price, ps.classes_total, pass_used(ps.id), ps.status, ps.starts_on, ps.expires_on, coalesce(pl.sport, 'sup')
  from passes ps left join plans pl on pl.id = ps.plan_id where ps.student_id = auth.uid() and ps.status <> 'cancelled'
  order by ps.created_at desc;
$fn$;

-- Admin: todos los abonos con alumno y clases usadas.
drop function if exists public.admin_passes();   -- cambió lo que devuelve (disciplina)
create or replace function public.admin_passes()
returns table (id uuid, student_id uuid, student_name text, student_avatar text, student_phone text, name text, price numeric,
               classes_total int, used int, status text, starts_on date, expires_on date, payment_method text, paid_at timestamptz, created_at timestamptz,
               sport text)
language plpgsql stable security definer set search_path = public as $fn$
begin
  if not is_admin() then raise exception 'Solo un admin puede ver los abonos'; end if;
  return query
    select ps.id, ps.student_id, st.name, st.avatar_url, st.phone, ps.name, ps.price, ps.classes_total, pass_used(ps.id),
           ps.status, ps.starts_on, ps.expires_on, ps.payment_method, ps.paid_at, ps.created_at, coalesce(pl.sport, 'sup')
    from passes ps join students st on st.id = ps.student_id left join plans pl on pl.id = ps.plan_id
    order by ps.created_at desc;
end $fn$;

-- Admin: confirmar el pago (activa el abono desde hoy) o dar uno directo a un alumno.
create or replace function public.activate_pass(p_pass uuid, p_method text) returns void
language plpgsql security definer set search_path = public as $fn$
declare v_today date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
begin
  if not is_admin() then raise exception 'Solo un admin puede confirmar abonos'; end if;
  update passes set status = 'active', payment_method = p_method, paid_at = now(),
                    starts_on = v_today, expires_on = v_today + days_valid - 1
  where id = p_pass and status = 'pending';
  if not found then raise exception 'Ese pedido ya no está pendiente'; end if;
end $fn$;

create or replace function public.grant_pass(p_student uuid, p_plan uuid, p_method text) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare pl plans; v_id uuid; v_today date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
begin
  if not is_admin() then raise exception 'Solo un admin puede dar abonos'; end if;
  select * into pl from plans where id = p_plan;
  if not found then raise exception 'Ese plan no existe'; end if;
  insert into passes (student_id, plan_id, name, price, classes_total, days_valid, status, starts_on, expires_on, payment_method, paid_at)
  values (p_student, pl.id, pl.name, pl.price, pl.classes, pl.days_valid, 'active', v_today, v_today + pl.days_valid - 1, p_method, now())
  returning id into v_id;
  return v_id;
end $fn$;

-- Anular: las reservas FUTURAS hechas con ese abono pasan a "a cobrar" con el precio normal de la clase
-- (las que ya pasaron quedan como estaban). Devuelve cuántas reservas cambió.
create or replace function public.cancel_pass(p_pass uuid) returns int
language plpgsql security definer set search_path = public as $fn$
declare n int;
begin
  if not is_admin() then raise exception 'Solo un admin puede anular abonos'; end if;
  update passes set status = 'cancelled' where id = p_pass;
  update bookings b set pass_id = null, paid = false, payment_method = null, amount = s.price * b.people
  from slots s
  where b.slot_id = s.id and b.pass_id = p_pass and b.status <> 'cancelled' and s.starts_at > now();
  get diagnostics n = row_count;
  return n;
end $fn$;

-- Deshacer una anulación (si fue por error): vuelve a quedar activo con sus fechas originales.
create or replace function public.reactivate_pass(p_pass uuid) returns void
language plpgsql security definer set search_path = public as $fn$
begin
  if not is_admin() then raise exception 'Solo un admin puede reactivar abonos'; end if;
  update passes set status = case when paid_at is null then 'pending' else 'active' end
  where id = p_pass and status = 'cancelled';
  if not found then raise exception 'Ese abono no está anulado'; end if;
end $fn$;

revoke all on function public.pass_used(uuid), public.request_pass(uuid), public.my_passes(), public.admin_passes(),
                       public.activate_pass(uuid, text), public.grant_pass(uuid, uuid, text), public.cancel_pass(uuid), public.reactivate_pass(uuid) from public;
grant execute on function public.request_pass(uuid), public.my_passes(), public.admin_passes(),
                          public.activate_pass(uuid, text), public.grant_pass(uuid, uuid, text), public.cancel_pass(uuid), public.reactivate_pass(uuid) to authenticated;

revoke all on function public.delete_suspended_slot(uuid) from public;
grant execute on function public.delete_suspended_slot(uuid) to authenticated;

revoke all on function public.public_slots(timestamptz, timestamptz) from public;
revoke all on function public.public_profes() from public;
revoke all on function public.book_slot(uuid, text, text, text, int, boolean, text) from public;
grant execute on function public.public_slots(timestamptz, timestamptz) to anon, authenticated;
grant execute on function public.public_profes() to anon, authenticated;
grant execute on function public.book_slot(uuid, text, text, text, int, boolean, text) to anon, authenticated;

-- Alta de profe desde el servidor (/api/invite-profe, con la clave secreta): deja el perfil
-- aprobado aunque la cuenta ya existiera (ej. un profe que se borró de la tabla y se vuelve a sumar).
drop function if exists public.staff_account(text, text, text, numeric);
create or replace function public.staff_account(p_email text, p_name text, p_phone text, p_pct numeric)
returns table (profile_id uuid, is_student boolean)
language plpgsql security definer set search_path = public as $fn$
declare v uuid; e text := lower(btrim(p_email));
begin
  select u.id into v from auth.users u where lower(u.email) = e limit 1;
  if v is null then return; end if;
  insert into profiles as pr (id, email, name, phone, commission_pct, approved, teaches, archived)
  values (v, e, p_name, p_phone, p_pct, true, true, false)
  on conflict (id) do update set name = excluded.name, phone = coalesce(excluded.phone, pr.phone),
    commission_pct = excluded.commission_pct, approved = true, archived = false,
    teaches = case when pr.archived then true else pr.teaches end;
  update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"staff": true}'::jsonb where auth.users.id = v;
  return query select v, exists (select 1 from students s where s.id = v);
end $fn$;
revoke all on function public.staff_account(text, text, text, numeric) from public, anon, authenticated;
grant execute on function public.staff_account(text, text, text, numeric) to service_role;

-- Tablón del team: avisos de los profes para el grupo de entrenamiento (solo lo ven ellos y el staff).
create table if not exists public.team_posts (
  id          uuid primary key default gen_random_uuid(),
  author_id   uuid references public.profiles(id) on delete set null,
  author_name text,
  body        text not null check (length(btrim(body)) between 1 and 600),
  pinned      boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists team_posts_created_idx on public.team_posts (created_at desc);
-- El autor lo pone la base (no se puede publicar a nombre de otro).
create or replace function public.team_posts_guard() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then new.author_id := auth.uid(); end if;
    new.author_name := (select name from profiles where id = new.author_id);
    new.created_at := now();
  else
    new.author_id := old.author_id; new.author_name := old.author_name; new.created_at := old.created_at;
  end if;
  return new;
end $fn$;
drop trigger if exists team_posts_guard on public.team_posts;
create trigger team_posts_guard before insert or update on public.team_posts
  for each row execute function public.team_posts_guard();
grant select, insert, update, delete on public.team_posts to authenticated;

-- "Hoy entrené": cada alumno del grupo suma su entrenamiento con un botón (uno por día).
create table if not exists public.training_logs (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  day        date not null,
  created_at timestamptz not null default now(),
  unique (student_id, day)
);
grant select on public.training_logs to authenticated;

-- Días entrenados de un alumno: sus "Hoy entrené" + los entrenamientos donde el profe lo anotó con su cuenta.
create or replace function public.training_days(p_id uuid) returns date[]
language sql stable security definer set search_path = public as $fn$
  select coalesce(array_agg(distinct d order by d), '{}') from (
    select day as d from training_logs where student_id = p_id
    union
    select (s.starts_at at time zone 'America/Argentina/Buenos_Aires')::date
    from bookings b join slots s on s.id = b.slot_id
    where b.student_id = p_id and s.members_only and s.starts_at < now()
      and b.status not in ('cancelled', 'no_show') and s.status <> 'cancelled'
  ) x;
$fn$;

create or replace function public.log_training(p_undo boolean default false) returns date[]
language plpgsql security definer set search_path = public as $fn$
declare d date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
begin
  if not exists (select 1 from students where id = auth.uid() and training = 'approved') then
    raise exception 'Es para el grupo de entrenamiento';
  end if;
  if p_undo then delete from training_logs where student_id = auth.uid() and day = d;
  else insert into training_logs (student_id, day) values (auth.uid(), d) on conflict do nothing;
  end if;
  return training_days(auth.uid());
end $fn$;

-- ¿Puedo ver el perfil de este alumno? El propio, el staff a todos, y el team entre sí.
create or replace function public.can_view_student(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $fn$
  select auth.uid() = p_id or is_staff()
      or (exists (select 1 from students where id = auth.uid() and training = 'approved')
          and exists (select 1 from students where id = p_id and training = 'approved'));
$fn$;

-- Perfil de un alumno para verlo (logros, clases, racha). Sin datos de contacto salvo para el staff.
create or replace function public.student_profile(p_id uuid) returns json
language plpgsql stable security definer set search_path = public as $fn$
declare r json;
begin
  if not can_view_student(p_id) then raise exception 'No tenés acceso a este perfil'; end if;
  select json_build_object(
    'student', json_build_object('id', st.id, 'name', st.name, 'avatar_url', st.avatar_url, 'bio', st.bio,
                                 'instagram', st.instagram, 'level', st.level, 'training', st.training,
                                 'phone', case when is_staff() then st.phone end, 'created_at', st.created_at),
    'bookings', coalesce((select json_agg(json_build_object('starts_at', s.starts_at, 'duration_min', s.duration_min, 'people', b.people,
                  'profe_name', p.name, 'members_only', s.members_only, 'status', b.status, 'slot_status', s.status,
                  'sport', coalesce(ct.sport, 'sup'), 'kind', coalesce(ct.kind, 'iniciacion')) order by s.starts_at desc)
                from bookings b join slots s on s.id = b.slot_id join profiles p on p.id = s.profe_id
                left join class_types ct on ct.id = s.class_type_id where b.student_id = p_id), '[]'::json),
    'train_days', to_json(training_days(p_id)))
  into r from students st where st.id = p_id;
  if r is null then raise exception 'No encontramos ese perfil'; end if;
  return r;
end $fn$;

-- Integrantes del grupo de entrenamiento (para el portal del team). Solo lo ven el team y el staff.
create or replace function public.team_members()
returns table (id uuid, name text, avatar_url text, instagram text, level text, train_days date[])
language plpgsql stable security definer set search_path = public as $fn$
#variable_conflict use_column
begin
  if not (is_staff() or exists (select 1 from students where id = auth.uid() and training = 'approved')) then
    raise exception 'Es para el grupo de entrenamiento';
  end if;
  return query select st.id, st.name, st.avatar_url, st.instagram, st.level, training_days(st.id)
    from students st where st.training = 'approved' order by st.name;
end $fn$;

revoke all on function public.training_days(uuid), public.log_training(boolean), public.can_view_student(uuid),
                       public.student_profile(uuid), public.team_members() from public;
grant execute on function public.log_training(boolean), public.student_profile(uuid), public.team_members() to authenticated;

-- ═════════ Lista de espera, ficha y deslinde, reseñas, gift cards y pedidos grupales ═════════
-- Clave de un teléfono: los últimos 10 dígitos ("+54 9 341 555-1234" = "3415551234").
create or replace function public.phone_key(p text) returns text
language sql immutable as $fn$ select right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10) $fn$;

-- ── Lista de espera: si una clase está completa, el alumno se anota y le avisamos si se libera un lugar.
create table if not exists public.waitlist (
  id         uuid primary key default gen_random_uuid(),
  slot_id    uuid not null references public.slots(id) on delete cascade,
  name       text not null,
  phone      text not null,
  student_id uuid references public.students(id) on delete set null,
  created_at timestamptz not null default now(),
  notified_at timestamptz
);
create index if not exists waitlist_slot_idx on public.waitlist (slot_id, created_at);
grant select, update, delete on public.waitlist to authenticated;

create or replace function public.join_waitlist(p_slot uuid, p_name text, p_phone text) returns int
language plpgsql security definer set search_path = public as $fn$
declare s slots; v_booked int; k text := phone_key(p_phone);
begin
  p_name := btrim(coalesce(p_name, ''));
  if length(p_name) < 2 or length(p_name) > 80 then raise exception 'Ingresá tu nombre y apellido'; end if;
  if length(k) < 8 then raise exception 'Ingresá un WhatsApp válido (con característica)'; end if;
  select * into s from slots where id = p_slot;
  if not found or s.status <> 'open' or s.starts_at <= now() or s.members_only then raise exception 'Esa clase ya no está disponible'; end if;
  select coalesce(sum(people), 0) into v_booked from bookings where slot_id = p_slot and status <> 'cancelled';
  if v_booked < s.capacity then raise exception 'Hay lugar: reservá directamente'; end if;
  if exists (select 1 from bookings where slot_id = p_slot and status <> 'cancelled' and phone_key(customer_phone) = k) then
    raise exception 'Ya tenés una reserva en esta clase';
  end if;
  if not exists (select 1 from waitlist where slot_id = p_slot and phone_key(phone) = k) then
    if (select count(*) from waitlist where slot_id = p_slot) >= 30 then raise exception 'La lista de espera está llena'; end if;
    insert into waitlist (slot_id, name, phone, student_id)
    values (p_slot, p_name, btrim(p_phone), (select st.id from students st where st.id = auth.uid()));
  end if;
  return (select count(*) from waitlist w where w.slot_id = p_slot
          and w.created_at <= (select created_at from waitlist where slot_id = p_slot and phone_key(phone) = k limit 1));
end $fn$;

-- Del alumno con cuenta: sus esperas y si ya se liberó lugar.
create or replace function public.my_waitlist()
returns table (slot_id uuid, title text, starts_at timestamptz, free int)
language sql stable security definer set search_path = public as $fn$
  select s.id, s.title, s.starts_at,
         greatest(s.capacity - coalesce((select sum(b.people) from bookings b where b.slot_id = s.id and b.status <> 'cancelled'), 0), 0)::int
  from waitlist w join slots s on s.id = w.slot_id
  where w.student_id = auth.uid() and s.status = 'open' and s.starts_at > now()
    and not exists (select 1 from bookings b where b.slot_id = s.id and b.status <> 'cancelled'
                    and (phone_key(b.customer_phone) = phone_key(w.phone) or b.student_id = auth.uid()))
  order by s.starts_at;
$fn$;

-- Quien ya reservó esa clase no se cuenta más en la lista de espera (se filtra al leerla).
drop trigger if exists waitlist_cleanup on public.bookings;

-- ── Ficha y deslinde: una vez por persona (vale 1 año). Se completa desde el comprobante.
create table if not exists public.waivers (
  id              uuid primary key default gen_random_uuid(),
  phone_key       text not null,
  student_id      uuid references public.students(id) on delete set null,
  name            text not null,
  birth_date      date,
  swims           text check (swims in ('si', 'poco', 'no')),
  health          text,
  emergency_name  text,
  emergency_phone text,
  accepted_at     timestamptz not null default now()
);
create index if not exists waivers_phone_idx on public.waivers (phone_key, accepted_at desc);
grant select on public.waivers to authenticated;

create or replace function public.waiver_status(p_code text) returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from bookings b join waivers w
                   on w.phone_key = phone_key(b.customer_phone) or (b.student_id is not null and w.student_id = b.student_id)
                 where b.code = upper(btrim(p_code)) and w.accepted_at > now() - interval '365 days');
$fn$;

-- Alumno con cuenta: la completa en su perfil (una vez; vale 1 año).
create or replace function public.my_waiver()
returns table (name text, birth_date date, swims text, health text, emergency_name text, emergency_phone text, accepted_at timestamptz)
language sql stable security definer set search_path = public as $fn$
  select w.name, w.birth_date, w.swims, w.health, w.emergency_name, w.emergency_phone, w.accepted_at
  from waivers w where w.student_id = auth.uid() and w.accepted_at > now() - interval '365 days'
  order by w.accepted_at desc limit 1;
$fn$;
create or replace function public.submit_my_waiver(p_name text, p_phone text, p_birth date, p_swims text, p_health text,
                                                   p_em_name text, p_em_phone text) returns void
language plpgsql security definer set search_path = public as $fn$
begin
  if not exists (select 1 from students where id = auth.uid()) then raise exception 'Entrá con tu cuenta'; end if;
  if length(btrim(coalesce(p_name, ''))) < 2 then raise exception 'Poné tu nombre y apellido'; end if;
  if length(phone_key(p_phone)) < 8 then raise exception 'Poné tu WhatsApp'; end if;
  if p_swims not in ('si', 'poco', 'no') then raise exception 'Contanos si sabés nadar'; end if;
  if length(phone_key(p_em_phone)) < 8 or length(btrim(coalesce(p_em_name, ''))) < 2 then raise exception 'Poné un contacto de emergencia con teléfono'; end if;
  insert into waivers (phone_key, student_id, name, birth_date, swims, health, emergency_name, emergency_phone)
  values (phone_key(p_phone), auth.uid(), btrim(p_name), p_birth, p_swims, left(nullif(btrim(p_health), ''), 500), btrim(p_em_name), btrim(p_em_phone));
  update students set phone = btrim(p_phone) where id = auth.uid() and (phone is null or btrim(phone) = '');
end $fn$;

create or replace function public.submit_waiver(p_code text, p_name text, p_birth date, p_swims text, p_health text,
                                                p_em_name text, p_em_phone text) returns void
language plpgsql security definer set search_path = public as $fn$
declare b bookings;
begin
  select * into b from bookings where code = upper(btrim(p_code));
  if not found then raise exception 'No encontramos esa reserva'; end if;
  if length(btrim(coalesce(p_name, ''))) < 2 then raise exception 'Poné tu nombre y apellido'; end if;
  if p_swims not in ('si', 'poco', 'no') then raise exception 'Contanos si sabés nadar'; end if;
  if length(phone_key(p_em_phone)) < 8 or length(btrim(coalesce(p_em_name, ''))) < 2 then raise exception 'Poné un contacto de emergencia con teléfono'; end if;
  insert into waivers (phone_key, student_id, name, birth_date, swims, health, emergency_name, emergency_phone)
  values (phone_key(b.customer_phone), b.student_id, btrim(p_name), p_birth, p_swims, left(nullif(btrim(p_health), ''), 500),
          btrim(p_em_name), btrim(p_em_phone));
end $fn$;

-- ── Reseñas: el alumno califica su clase (con el código de la reserva) cuando ya terminó.
create table if not exists public.reviews (
  id         uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references public.bookings(id) on delete cascade,
  slot_id    uuid references public.slots(id) on delete cascade,
  profe_id   uuid references public.profiles(id) on delete set null,
  stars      int not null check (stars between 1 and 5),
  comment    text,
  hidden     boolean not null default false,
  created_at timestamptz not null default now()
);
grant select, update on public.reviews to authenticated;

create or replace function public.leave_review(p_code text, p_stars int, p_comment text) returns void
language plpgsql security definer set search_path = public as $fn$
declare b bookings; s slots;
begin
  select * into b from bookings where code = upper(btrim(p_code));
  if not found then raise exception 'No encontramos esa reserva'; end if;
  select * into s from slots where id = b.slot_id;
  if s.starts_at + make_interval(mins => s.duration_min) > now() then raise exception 'Podés calificar cuando termine la clase'; end if;
  if b.status in ('cancelled', 'no_show') or s.status = 'cancelled' then raise exception 'Esa clase no se dio'; end if;
  if p_stars not between 1 and 5 then raise exception 'Elegí de 1 a 5 estrellas'; end if;
  update reviews set stars = p_stars, comment = left(nullif(btrim(p_comment), ''), 400), created_at = now() where booking_id = b.id;
  if not found then
    insert into reviews (booking_id, slot_id, profe_id, stars, comment)
    values (b.id, s.id, s.profe_id, p_stars, left(nullif(btrim(p_comment), ''), 400));
  end if;
end $fn$;

create or replace function public.review_by_code(p_code text) returns table (stars int, comment text)
language sql stable security definer set search_path = public as $fn$
  select r.stars, r.comment from reviews r join bookings b on b.id = r.booking_id where b.code = upper(btrim(p_code));
$fn$;

-- Para la página: las buenas reseñas con comentario (las que un admin no ocultó).
create or replace function public.public_reviews()
returns table (first_name text, profe_name text, stars int, comment text, sport text, created_at timestamptz)
language sql stable security definer set search_path = public as $fn$
  select split_part(btrim(b.customer_name), ' ', 1), p.name, r.stars, r.comment, coalesce(ct.sport, 'sup'), r.created_at
  from reviews r join bookings b on b.id = r.booking_id join slots s on s.id = r.slot_id
  left join profiles p on p.id = r.profe_id left join class_types ct on ct.id = s.class_type_id
  where r.stars >= 4 and r.comment is not null and not r.hidden
  order by r.created_at desc limit 12;
$fn$;

-- ── Gift cards: alguien regala una clase o un abono. Se pide desde la página, el admin la activa
--    cuando cobra, y quien la recibe la canjea con el código.
create table if not exists public.gift_cards (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,
  kind             text not null check (kind in ('clase', 'abono')),
  sport            text not null default 'sup',
  plan_id          uuid references public.plans(id) on delete set null,
  value            numeric(12,2) not null default 0,
  buyer_name       text not null,
  buyer_phone      text not null,
  recipient_name   text not null,
  message          text,
  status           text not null default 'pending' check (status in ('pending', 'active', 'redeemed', 'cancelled')),
  created_at       timestamptz not null default now(),
  paid_at          timestamptz,
  redeemed_at      timestamptz,
  redeemed_booking uuid references public.bookings(id) on delete set null,
  redeemed_pass    uuid references public.passes(id) on delete set null
);
grant select, update on public.gift_cards to authenticated;

create or replace function public.request_gift(p_kind text, p_sport text, p_plan uuid, p_buyer text, p_buyer_phone text,
                                               p_recipient text, p_message text) returns text
language plpgsql security definer set search_path = public as $fn$
declare v_code text; v_value numeric; pl plans;
begin
  if p_kind not in ('clase', 'abono') then raise exception 'Elegí qué regalar'; end if;
  if length(btrim(coalesce(p_buyer, ''))) < 2 or length(btrim(coalesce(p_recipient, ''))) < 2 then raise exception 'Poné tu nombre y el de quien lo recibe'; end if;
  if length(phone_key(p_buyer_phone)) < 8 then raise exception 'Ingresá tu WhatsApp para coordinar el pago'; end if;
  if (select count(*) from gift_cards where phone_key(buyer_phone) = phone_key(p_buyer_phone) and status = 'pending') >= 5 then
    raise exception 'Ya tenés regalos pendientes de pago: escribinos por WhatsApp';
  end if;
  if p_kind = 'abono' then
    select * into pl from plans where id = p_plan and active;
    if not found then raise exception 'Ese abono no está disponible'; end if;
    v_value := pl.price; p_sport := pl.sport;
  else
    p_sport := coalesce(nullif(p_sport, ''), 'sup');
    select ct.price into v_value from class_types ct where ct.active and not ct.members_only and ct.sport = p_sport
    order by (ct.kind = 'iniciacion') desc, ct.price limit 1;
    if coalesce(v_value, 0) <= 0 then raise exception 'Todavía no hay clases de esa disciplina para regalar'; end if;
  end if;
  loop
    v_code := 'NAT-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from gift_cards where code = v_code);
  end loop;
  insert into gift_cards (code, kind, sport, plan_id, value, buyer_name, buyer_phone, recipient_name, message)
  values (v_code, p_kind, p_sport, case when p_kind = 'abono' then p_plan end, v_value, btrim(p_buyer), btrim(p_buyer_phone),
          btrim(p_recipient), left(nullif(btrim(p_message), ''), 200));
  return v_code;
end $fn$;

create or replace function public.gift_by_code(p_code text)
returns table (code text, kind text, sport text, plan_name text, classes int, value numeric, from_name text, recipient_name text, message text, status text)
language sql stable security definer set search_path = public as $fn$
  select g.code, g.kind, g.sport, pl.name, coalesce(pl.classes, 1), g.value, split_part(g.buyer_name, ' ', 1), g.recipient_name, g.message, g.status
  from gift_cards g left join plans pl on pl.id = g.plan_id where g.code = upper(btrim(p_code));
$fn$;

-- Canjear una gift card de CLASE en una reserva (se marca pagada; la parte del profe sale del valor de la clase).
create or replace function public.redeem_gift_booking(p_gift text, p_booking text) returns void
language plpgsql security definer set search_path = public as $fn$
declare g gift_cards; b bookings; v_sport text;
begin
  select * into g from gift_cards where code = upper(btrim(p_gift)) for update;
  if not found then raise exception 'Ese código de regalo no existe'; end if;
  if g.status = 'pending' then raise exception 'Ese regalo todavía no está pago: avisale a quien te lo regaló'; end if;
  if g.status <> 'active' then raise exception 'Ese regalo ya se usó'; end if;
  if g.kind <> 'clase' then raise exception 'Ese regalo es un abono: canjealo desde tu perfil'; end if;
  select * into b from bookings where code = upper(btrim(p_booking)) for update;
  if not found or b.status <> 'confirmed' then raise exception 'No encontramos esa reserva'; end if;
  if b.paid then raise exception 'Esa reserva ya está paga'; end if;
  if b.people > 1 then raise exception 'El regalo cubre 1 persona: reservá para 1 y canjealo'; end if;
  select coalesce(ct.sport, 'sup') into v_sport from slots s left join class_types ct on ct.id = s.class_type_id where s.id = b.slot_id;
  if v_sport <> g.sport then raise exception 'Ese regalo es para clases de %', case g.sport when 'kayak' then 'kayak' else 'SUP' end; end if;
  update bookings set paid = true, payment_method = 'regalo', pay_pref = null,
    notes = concat_ws(' · ', nullif(btrim(notes), ''), 'Gift card ' || g.code) where id = b.id;
  update gift_cards set status = 'redeemed', redeemed_at = now(), redeemed_booking = b.id where id = g.id;
end $fn$;

-- Canjear una gift card de ABONO: se activa en la cuenta del alumno (tiene que entrar con Google).
create or replace function public.redeem_gift_pass(p_gift text) returns void
language plpgsql security definer set search_path = public as $fn$
declare g gift_cards; pl plans; v_id uuid; v_today date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
begin
  if not exists (select 1 from students where id = auth.uid()) then raise exception 'Entrá con Google para canjear el abono'; end if;
  select * into g from gift_cards where code = upper(btrim(p_gift)) for update;
  if not found then raise exception 'Ese código de regalo no existe'; end if;
  if g.status = 'pending' then raise exception 'Ese regalo todavía no está pago: avisale a quien te lo regaló'; end if;
  if g.status <> 'active' then raise exception 'Ese regalo ya se usó'; end if;
  if g.kind <> 'abono' then raise exception 'Ese regalo es una clase: canjealo al reservar'; end if;
  select * into pl from plans where id = g.plan_id;
  if not found then raise exception 'Ese abono ya no existe: escribinos'; end if;
  insert into passes (student_id, plan_id, name, price, classes_total, days_valid, status, starts_on, expires_on, payment_method, paid_at)
  values (auth.uid(), pl.id, pl.name, g.value, pl.classes, pl.days_valid, 'active', v_today, v_today + pl.days_valid - 1, 'regalo', now())
  returning id into v_id;
  update gift_cards set status = 'redeemed', redeemed_at = now(), redeemed_pass = v_id where id = g.id;
end $fn$;

-- ── Clases privadas y grupales (cumpleaños, empresas, grupos): pedido desde la página para el admin.
create table if not exists public.group_requests (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  phone      text not null,
  kind       text not null default 'grupo' check (kind in ('privada', 'grupo', 'cumple', 'empresa', 'otro')),
  sport      text not null default 'sup',
  people     int,
  preferred  text,
  message    text,
  status     text not null default 'nuevo' check (status in ('nuevo', 'contactado', 'cerrado')),
  created_at timestamptz not null default now()
);
grant select, update, delete on public.group_requests to authenticated;

create or replace function public.request_group(p_name text, p_phone text, p_kind text, p_sport text, p_people int, p_preferred text, p_message text)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  if length(btrim(coalesce(p_name, ''))) < 2 then raise exception 'Poné tu nombre'; end if;
  if length(phone_key(p_phone)) < 8 then raise exception 'Ingresá un WhatsApp válido (con característica)'; end if;
  if (select count(*) from group_requests where phone_key(phone) = phone_key(p_phone) and created_at > now() - interval '1 day') >= 3 then
    raise exception 'Ya recibimos tu pedido: te escribimos pronto';
  end if;
  insert into group_requests (name, phone, kind, sport, people, preferred, message)
  values (btrim(p_name), btrim(p_phone), case when p_kind in ('privada', 'grupo', 'cumple', 'empresa', 'otro') then p_kind else 'otro' end,
          case when p_sport = 'kayak' then 'kayak' else 'sup' end, least(greatest(coalesce(p_people, 1), 1), 200),
          left(nullif(btrim(p_preferred), ''), 120), left(nullif(btrim(p_message), ''), 500));
end $fn$;

revoke all on function public.join_waitlist(uuid, text, text), public.my_waitlist(), public.waiver_status(text),
  public.submit_waiver(text, text, date, text, text, text, text), public.leave_review(text, int, text), public.review_by_code(text),
  public.public_reviews(), public.request_gift(text, text, uuid, text, text, text, text), public.gift_by_code(text),
  public.redeem_gift_booking(text, text), public.redeem_gift_pass(text), public.request_group(text, text, text, text, int, text, text) from public;
grant execute on function public.join_waitlist(uuid, text, text), public.waiver_status(text),
  public.submit_waiver(text, text, date, text, text, text, text), public.leave_review(text, int, text), public.review_by_code(text),
  public.public_reviews(), public.request_gift(text, text, uuid, text, text, text, text), public.gift_by_code(text),
  public.redeem_gift_booking(text, text), public.request_group(text, text, text, text, int, text, text) to anon, authenticated;
grant execute on function public.my_waitlist(), public.redeem_gift_pass(text) to authenticated;
revoke all on function public.my_waiver(), public.submit_my_waiver(text, text, date, text, text, text, text) from public;
grant execute on function public.my_waiver(), public.submit_my_waiver(text, text, date, text, text, text, text) to authenticated;

-- ───────────────────────────── 5) Permisos (RLS) ─────────────────────────────

alter table public.profiles    enable row level security;
alter table public.class_types enable row level security;
alter table public.slots       enable row level security;
alter table public.bookings    enable row level security;

-- profiles: cada uno ve/edita el suyo; el admin ve/edita todos.
drop policy if exists "profiles select" on public.profiles;
create policy "profiles select" on public.profiles for select to authenticated
  using (id = auth.uid() or is_admin());
drop policy if exists "profiles update" on public.profiles;
create policy "profiles update" on public.profiles for update to authenticated
  using (id = auth.uid() or is_admin()) with check (id = auth.uid() or is_admin());
drop policy if exists "profiles delete" on public.profiles;
create policy "profiles delete" on public.profiles for delete to authenticated
  using (is_admin());

-- students: cada alumno ve/edita su perfil; profes y admins pueden verlo (nombre y foto en la agenda).
alter table public.students enable row level security;
drop policy if exists "students select" on public.students;
create policy "students select" on public.students for select to authenticated
  using (id = auth.uid() or is_staff());
drop policy if exists "students update" on public.students;
create policy "students update" on public.students for update to authenticated
  using (id = auth.uid() or is_admin()) with check (id = auth.uid() or is_admin());

-- El alumno puede pedir (o cancelar el pedido de) entrenamiento, pero solo un admin lo aprueba.
create or replace function public.students_guard() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  if auth.uid() is not null and not is_admin() then
    if old.training = 'approved' or new.training not in ('none', 'requested') then
      new.training := old.training;
    end if;
    new.email := old.email;
  end if;
  return new;
end $fn$;
drop trigger if exists students_guard on public.students;
create trigger students_guard before update on public.students
  for each row execute function public.students_guard();

-- plans: lectura pública de los activos (la oferta en la página); solo admin edita.
alter table public.plans  enable row level security;
alter table public.passes enable row level security;
drop policy if exists "plans select" on public.plans;
create policy "plans select" on public.plans for select to anon, authenticated using (active or is_admin());
drop policy if exists "plans admin" on public.plans;
create policy "plans admin" on public.plans for all to authenticated using (is_admin()) with check (is_admin());
-- passes: el alumno ve los suyos; todo lo demás pasa por las funciones de arriba.
drop policy if exists "passes select" on public.passes;
create policy "passes select" on public.passes for select to authenticated using (student_id = auth.uid() or is_admin());

-- class_types: lectura pública de las activas; solo admin edita.
drop policy if exists "class_types select" on public.class_types;
create policy "class_types select" on public.class_types for select to anon, authenticated
  using (active or can_manage_sport(sport));
-- edita el admin, o el profe que maneja esa disciplina (ej. Mati los de kayak)
drop policy if exists "class_types admin" on public.class_types;
create policy "class_types admin" on public.class_types for all to authenticated
  using (can_manage_sport(sport)) with check (can_manage_sport(sport));

-- slots: el profe maneja los suyos; el admin, todos.
drop policy if exists "slots select" on public.slots;
create policy "slots select" on public.slots for select to authenticated
  using (is_admin() or profe_id = auth.uid());
drop policy if exists "slots insert" on public.slots;
create policy "slots insert" on public.slots for insert to authenticated
  with check (is_admin() or (is_staff() and profe_id = auth.uid()));
drop policy if exists "slots update" on public.slots;
create policy "slots update" on public.slots for update to authenticated
  using (is_admin() or (is_staff() and profe_id = auth.uid()))
  with check (is_admin() or (is_staff() and profe_id = auth.uid()));
drop policy if exists "slots delete" on public.slots;
create policy "slots delete" on public.slots for delete to authenticated
  using (is_admin() or (is_staff() and profe_id = auth.uid()));

-- bookings: el profe ve/gestiona las de sus horarios; borrar solo el admin.
-- Los alumnos reservan vía book_slot(), nunca escriben la tabla directo.
drop policy if exists "bookings select" on public.bookings;
create policy "bookings select" on public.bookings for select to authenticated
  using (is_admin() or owns_slot(slot_id));
drop policy if exists "bookings insert" on public.bookings;
create policy "bookings insert" on public.bookings for insert to authenticated
  with check (is_admin() or (is_staff() and owns_slot(slot_id)));
drop policy if exists "bookings update" on public.bookings;
create policy "bookings update" on public.bookings for update to authenticated
  using (is_admin() or (is_staff() and owns_slot(slot_id)))
  with check (is_admin() or (is_staff() and owns_slot(slot_id)));
drop policy if exists "bookings delete" on public.bookings;
create policy "bookings delete" on public.bookings for delete to authenticated
  using (is_admin());

-- ───────────────────────────── 5b) Fotos de perfil (Storage) ─────────────────────────────
-- Bucket público "avatars": cualquiera puede VER las fotos (las muestra la página de reservas).
-- Subir/cambiar/borrar: cada uno en su carpeta (avatars/<su id>/…) y el admin en cualquiera.
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do update set public = true;

-- (select: lo pide Storage para reemplazar/borrar archivos; las fotos ya son públicas igual)
drop policy if exists "avatars select" on storage.objects;
create policy "avatars select" on storage.objects for select to authenticated
  using (bucket_id = 'avatars');
drop policy if exists "avatars insert" on storage.objects;
create policy "avatars insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
drop policy if exists "avatars update" on storage.objects;
create policy "avatars update" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
drop policy if exists "avatars delete" on storage.objects;
create policy "avatars delete" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

alter table public.waitlist enable row level security;
drop policy if exists "waitlist staff" on public.waitlist;
create policy "waitlist staff" on public.waitlist for all to authenticated
  using (is_admin() or owns_slot(slot_id)) with check (is_admin() or owns_slot(slot_id));
alter table public.waivers enable row level security;
drop policy if exists "waivers staff" on public.waivers;
create policy "waivers staff" on public.waivers for select to authenticated using (is_staff());
alter table public.reviews enable row level security;
drop policy if exists "reviews select" on public.reviews;
create policy "reviews select" on public.reviews for select to authenticated using (is_admin() or profe_id = auth.uid());
drop policy if exists "reviews hide" on public.reviews;
create policy "reviews hide" on public.reviews for update to authenticated using (is_admin()) with check (is_admin());
alter table public.gift_cards enable row level security;
drop policy if exists "gift_cards admin" on public.gift_cards;
create policy "gift_cards admin" on public.gift_cards for all to authenticated using (is_admin()) with check (is_admin());
alter table public.group_requests enable row level security;
drop policy if exists "group_requests admin" on public.group_requests;
create policy "group_requests admin" on public.group_requests for all to authenticated using (is_admin()) with check (is_admin());

alter table public.training_logs enable row level security;
drop policy if exists "training_logs select" on public.training_logs;
create policy "training_logs select" on public.training_logs for select to authenticated
  using (student_id = auth.uid() or is_staff());

alter table public.team_posts enable row level security;
drop policy if exists "team_posts select" on public.team_posts;
create policy "team_posts select" on public.team_posts for select to authenticated
  using (is_staff() or exists (select 1 from students where id = auth.uid() and training = 'approved'));
drop policy if exists "team_posts insert" on public.team_posts;
create policy "team_posts insert" on public.team_posts for insert to authenticated with check (is_staff());
drop policy if exists "team_posts update" on public.team_posts;
create policy "team_posts update" on public.team_posts for update to authenticated
  using (is_admin() or author_id = auth.uid()) with check (is_admin() or author_id = auth.uid());
drop policy if exists "team_posts delete" on public.team_posts;
create policy "team_posts delete" on public.team_posts for delete to authenticated
  using (is_admin() or author_id = auth.uid());

-- Tiempo real: la app de profes se actualiza sola cuando otro carga, cobra o borra algo.
-- Cada uno recibe solo los cambios que sus permisos (RLS) ya le dejan ver.
do $fn$
declare t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['slots', 'bookings', 'passes', 'students', 'profiles', 'team_posts', 'waitlist', 'gift_cards', 'group_requests'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $fn$;

-- ───────────────────────────── 6) Datos iniciales ─────────────────────────────
-- Arrancamos solo con clases de iniciación. Precio, cupo y duración se editan desde
-- el panel admin → Clases; ahí también se pueden sumar otros tipos más adelante
-- (con un solo tipo activo, la página no muestra filtros ni selectores de clase).
insert into public.class_types (name, description, duration_min, price, capacity, sort)
select * from (values
  ('Clase de iniciación', 'Primera vez arriba de la tabla. Incluye tabla, remo y chaleco.', 60, 30000, 4, 1)
) v(name, description, duration_min, price, capacity, sort)
where not exists (select 1 from public.class_types);

-- Kayak: dos tipos de ejemplo, inactivos y sin precio. Los completa y activa el profe de kayak
-- (o un admin) desde la página: Crear → "Tipos de clase de Kayak".
insert into public.class_types (name, description, duration_min, price, capacity, sort, sport, kind, active)
select * from (values
  ('Kayak · Iniciación', 'Primera vez en kayak. Incluye kayak, pala y chaleco.', 60, 0, 6, 10, 'kayak', 'iniciacion', false),
  ('Travesía en kayak', 'Salida guiada por el río. Contá el recorrido acá.', 180, 0, 8, 11, 'kayak', 'travesia', false)
) v(name, description, duration_min, price, capacity, sort, sport, kind, active)
where not exists (select 1 from public.class_types where sport = 'kayak');

-- Abono de ejemplo (editable en la página: Más → Abonos).
insert into public.plans (name, description, price, classes, days_valid, sort)
select 'Abono mensual', '1 clase por semana durante un mes', 90000, 4, 30, 1
where not exists (select 1 from public.plans);

-- ───────────────────────────── 7) Primer admin ─────────────────────────────
-- Después de crear tu cuenta desde la página (Profes → pedí acceso acá),
-- corré esto UNA vez con tu email para convertirte en admin:
--
--   update public.profiles set role = 'admin', approved = true, teaches = false
--   where email = 'tu-email@ejemplo.com';
--
-- (teaches = true si además das clases.) A partir de ahí, los demás admins y
-- profes se manejan desde la página: Equipo → Rol.
