-- PARTE 2 de 2: funciones (correla después de la PARTE 1). Se puede correr más de una vez.

-- ═════════ Lista de espera, ficha y deslinde, reseñas, gift cards y pedidos grupales ═════════
-- Clave de un teléfono: los últimos 10 dígitos ("+54 9 341 555-1234" = "3415551234").
create or replace function public.phone_key(p text) returns text
language sql immutable as $fn$ select right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10) $fn$;

-- ── Lista de espera: si una clase está completa, el alumno se anota y le avisamos si se libera un lugar.

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
