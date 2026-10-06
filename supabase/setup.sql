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
create or replace function public.public_slots(p_from timestamptz, p_to timestamptz)
returns table (
  id uuid, title text, class_type_id uuid, starts_at timestamptz, duration_min int,
  capacity int, price numeric, location text, notes text,
  profe_id uuid, profe_name text, booked int
)
language sql stable security definer set search_path = public as $fn$
  select s.id, s.title, s.class_type_id, s.starts_at, s.duration_min,
         s.capacity, s.price, s.location, s.notes,
         s.profe_id, p.name,
         coalesce((select sum(b.people) from bookings b
                   where b.slot_id = s.id and b.status <> 'cancelled'), 0)::int
  from slots s
  join profiles p on p.id = s.profe_id
  where s.status = 'open'
    and p.approved
    and s.starts_at >= greatest(p_from, now())
    and s.starts_at < p_to
    and p_to - p_from <= interval '93 days'
  order by s.starts_at;
$fn$;

-- Profes para mostrar en la página pública.
drop function if exists public.public_profes();   -- cambió lo que devuelve (foto y WhatsApp)
create or replace function public.public_profes()
returns table (id uuid, name text, bio text, avatar_url text, whatsapp text)
language sql stable security definer set search_path = public as $fn$
  select p.id, p.name, p.bio, p.avatar_url, case when p.public_whatsapp then nullif(btrim(p.phone), '') end
  from profiles p
  where p.approved
    and (p.teaches
         or exists (select 1 from slots s where s.profe_id = p.id and s.starts_at > now() and s.status = 'open'))
  order by p.name;
$fn$;

-- Reserva: valida datos y cupo con el horario bloqueado (FOR UPDATE).
create or replace function public.book_slot(
  p_slot uuid, p_name text, p_phone text, p_email text default null, p_people int default 1
)
returns table (code text, starts_at timestamptz, title text, profe_name text, people int, amount numeric)
language plpgsql security definer set search_path = public as $fn$
#variable_conflict use_column
declare
  s        slots;
  v_booked int;
  v_code   text;
  v_digits text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
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

  insert into bookings (slot_id, customer_name, customer_phone, customer_email, people, amount, student_id)
  values (p_slot, p_name, p_phone, p_email, p_people, s.price * p_people,
          (select st.id from students st where st.id = auth.uid()))   -- si reservó con su cuenta
  returning bookings.code into v_code;

  return query
    select v_code, s.starts_at, s.title,
           (select pr.name from profiles pr where pr.id = s.profe_id),
           p_people, s.price * p_people;
end $fn$;

-- "Mi reserva": el alumno ve su reserva con el código (link nativo…/#r-CÓDIGO).
-- Devuelve solo datos de la clase y el primer nombre; nada de teléfono ni email.
drop function if exists public.booking_by_code(text);   -- cambió lo que devuelve (WhatsApp del profe)
create or replace function public.booking_by_code(p_code text)
returns table (
  code text, first_name text, title text, starts_at timestamptz, duration_min int,
  location text, profe_name text, people int, amount numeric, paid boolean,
  status text, slot_status text, profe_whatsapp text
)
language sql stable security definer set search_path = public as $fn$
  select b.code, split_part(btrim(b.customer_name), ' ', 1), s.title, s.starts_at, s.duration_min,
         s.location, p.name, b.people, b.amount, b.paid, b.status, s.status,
         case when p.public_whatsapp then nullif(btrim(p.phone), '') end
  from bookings b
  join slots s on s.id = b.slot_id
  join profiles p on p.id = s.profe_id
  where p_code ~* '^[0-9a-f]{6}$' and b.code = upper(btrim(p_code));
$fn$;
-- Clases del alumno con cuenta (perfil). Suma las que reservó como invitado con el mismo email de Google.
create or replace function public.my_bookings()
returns table (
  code text, status text, paid boolean, people int, amount numeric, title text,
  starts_at timestamptz, duration_min int, location text, slot_status text,
  profe_name text, profe_avatar text
)
language plpgsql security definer set search_path = public as $fn$
#variable_conflict use_column
begin
  if auth.uid() is null or not exists (select 1 from students where id = auth.uid()) then return; end if;
  update bookings b set student_id = auth.uid()
  where b.student_id is null and auth.email() is not null and lower(b.customer_email) = lower(auth.email());
  return query
    select b.code, b.status, b.paid, b.people, b.amount, s.title, s.starts_at, s.duration_min,
           s.location, s.status, p.name, p.avatar_url
    from bookings b join slots s on s.id = b.slot_id join profiles p on p.id = s.profe_id
    where b.student_id = auth.uid()
    order by s.starts_at desc;
end $fn$;
revoke all on function public.my_bookings() from public;
grant execute on function public.my_bookings() to authenticated;

revoke all on function public.booking_by_code(text) from public;
grant execute on function public.booking_by_code(text) to anon, authenticated;

revoke all on function public.public_slots(timestamptz, timestamptz) from public;
revoke all on function public.public_profes() from public;
revoke all on function public.book_slot(uuid, text, text, text, int) from public;
grant execute on function public.public_slots(timestamptz, timestamptz) to anon, authenticated;
grant execute on function public.public_profes() to anon, authenticated;
grant execute on function public.book_slot(uuid, text, text, text, int) to anon, authenticated;

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
  using (id = auth.uid()) with check (id = auth.uid());

-- class_types: lectura pública de las activas; solo admin edita.
drop policy if exists "class_types select" on public.class_types;
create policy "class_types select" on public.class_types for select to anon, authenticated
  using (active or is_admin());
drop policy if exists "class_types admin" on public.class_types;
create policy "class_types admin" on public.class_types for all to authenticated
  using (is_admin()) with check (is_admin());

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

-- ───────────────────────────── 6) Datos iniciales ─────────────────────────────
-- Arrancamos solo con clases de iniciación. Precio, cupo y duración se editan desde
-- el panel admin → Clases; ahí también se pueden sumar otros tipos más adelante
-- (con un solo tipo activo, la página no muestra filtros ni selectores de clase).
insert into public.class_types (name, description, duration_min, price, capacity, sort)
select * from (values
  ('Clase de iniciación', 'Primera vez arriba de la tabla. Incluye tabla, remo y chaleco.', 60, 30000, 4, 1)
) v(name, description, duration_min, price, capacity, sort)
where not exists (select 1 from public.class_types);

-- ───────────────────────────── 7) Primer admin ─────────────────────────────
-- Después de crear tu cuenta desde la página (Profes → pedí acceso acá),
-- corré esto UNA vez con tu email para convertirte en admin:
--
--   update public.profiles set role = 'admin', approved = true, teaches = false
--   where email = 'tu-email@ejemplo.com';
--
-- (teaches = true si además das clases.) A partir de ahí, los demás admins y
-- profes se manejan desde la página: Equipo → Rol.
