-- PARTE 2d: gift cards. Se puede correr mas de una vez.

create or replace function public.request_gift(p_kind text, p_sport text, p_plan uuid, p_buyer text, p_buyer_phone text,
                                               p_recipient text, p_message text) returns text
language plpgsql security definer set search_path = public as '
declare v_code text; v_value numeric; pl plans;
begin
  if p_kind not in (''clase'', ''abono'') then raise exception ''%'', U&''Eleg\00ed qu\00e9 regalar''; end if;
  if length(btrim(coalesce(p_buyer, ''''))) < 2 or length(btrim(coalesce(p_recipient, ''''))) < 2 then raise exception ''%'', U&''Pon\00e9 tu nombre y el de quien lo recibe''; end if;
  if length(right(regexp_replace(coalesce(p_buyer_phone, ''''), ''\D'', '''', ''g''), 10)) < 8 then raise exception ''%'', U&''Ingres\00e1 tu WhatsApp para coordinar el pago''; end if;
  if (select count(*) from gift_cards where right(regexp_replace(coalesce(buyer_phone, ''''), ''\D'', '''', ''g''), 10) = right(regexp_replace(coalesce(p_buyer_phone, ''''), ''\D'', '''', ''g''), 10) and status = ''pending'') >= 5 then
    raise exception ''%'', U&''Ya ten\00e9s regalos pendientes de pago: escribinos por WhatsApp'';
  end if;
  if p_kind = ''abono'' then
    select * into pl from plans where id = p_plan and active;
    if not found then raise exception ''%'', U&''Ese abono no est\00e1 disponible''; end if;
    v_value := pl.price; p_sport := pl.sport;
  else
    p_sport := coalesce(nullif(p_sport, ''''), ''sup'');
    select ct.price into v_value from class_types ct where ct.active and not ct.members_only and ct.sport = p_sport
    order by (ct.kind = ''iniciacion'') desc, ct.price limit 1;
    if coalesce(v_value, 0) <= 0 then raise exception ''%'', U&''Todav\00eda no hay clases de esa disciplina para regalar''; end if;
  end if;
  loop
    v_code := ''NAT-'' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from gift_cards where code = v_code);
  end loop;
  insert into gift_cards (code, kind, sport, plan_id, value, buyer_name, buyer_phone, recipient_name, message)
  values (v_code, p_kind, p_sport, case when p_kind = ''abono'' then p_plan end, v_value, btrim(p_buyer), btrim(p_buyer_phone),
          btrim(p_recipient), left(nullif(btrim(p_message), ''''), 200));
  return v_code;
end ';

create or replace function public.gift_by_code(p_code text)
returns table (code text, kind text, sport text, plan_name text, classes int, value numeric, from_name text, recipient_name text, message text, status text)
language sql stable security definer set search_path = public as '
  select g.code, g.kind, g.sport, pl.name, coalesce(pl.classes, 1), g.value, split_part(g.buyer_name, '' '', 1), g.recipient_name, g.message, g.status
  from gift_cards g left join plans pl on pl.id = g.plan_id where g.code = upper(btrim(p_code));
';

create or replace function public.redeem_gift_booking(p_gift text, p_booking text) returns void
language plpgsql security definer set search_path = public as '
declare g gift_cards; b bookings; v_sport text;
begin
  select * into g from gift_cards where code = upper(btrim(p_gift)) for update;
  if not found then raise exception ''%'', U&''Ese c\00f3digo de regalo no existe''; end if;
  if g.status = ''pending'' then raise exception ''%'', U&''Ese regalo todav\00eda no est\00e1 pago: avisale a quien te lo regal\00f3''; end if;
  if g.status <> ''active'' then raise exception ''%'', U&''Ese regalo ya se us\00f3''; end if;
  if g.kind <> ''clase'' then raise exception ''Ese regalo es un abono: canjealo desde tu perfil''; end if;
  select * into b from bookings where code = upper(btrim(p_booking)) for update;
  if not found or b.status <> ''confirmed'' then raise exception ''No encontramos esa reserva''; end if;
  if b.paid then raise exception ''%'', U&''Esa reserva ya est\00e1 paga''; end if;
  if b.people > 1 then raise exception ''%'', U&''El regalo cubre 1 persona: reserv\00e1 para 1 y canjealo''; end if;
  select coalesce(ct.sport, ''sup'') into v_sport from slots s left join class_types ct on ct.id = s.class_type_id where s.id = b.slot_id;
  if v_sport <> g.sport then raise exception ''Ese regalo es para clases de %'', case g.sport when ''kayak'' then ''kayak'' else ''SUP'' end; end if;
  update bookings set paid = true, payment_method = ''regalo'', pay_pref = null,
    notes = concat_ws(U&'' \00b7 '', nullif(btrim(notes), ''''), ''Gift card '' || g.code) where id = b.id;
  update gift_cards set status = ''redeemed'', redeemed_at = now(), redeemed_booking = b.id where id = g.id;
end ';

create or replace function public.redeem_gift_pass(p_gift text) returns void
language plpgsql security definer set search_path = public as '
declare g gift_cards; pl plans; v_id uuid; v_today date := (now() at time zone ''America/Argentina/Buenos_Aires'')::date;
begin
  if not exists (select 1 from students where id = auth.uid()) then raise exception ''%'', U&''Entr\00e1 con Google para canjear el abono''; end if;
  select * into g from gift_cards where code = upper(btrim(p_gift)) for update;
  if not found then raise exception ''%'', U&''Ese c\00f3digo de regalo no existe''; end if;
  if g.status = ''pending'' then raise exception ''%'', U&''Ese regalo todav\00eda no est\00e1 pago: avisale a quien te lo regal\00f3''; end if;
  if g.status <> ''active'' then raise exception ''%'', U&''Ese regalo ya se us\00f3''; end if;
  if g.kind <> ''abono'' then raise exception ''Ese regalo es una clase: canjealo al reservar''; end if;
  select * into pl from plans where id = g.plan_id;
  if not found then raise exception ''Ese abono ya no existe: escribinos''; end if;
  insert into passes (student_id, plan_id, name, price, classes_total, days_valid, status, starts_on, expires_on, payment_method, paid_at)
  values (auth.uid(), pl.id, pl.name, g.value, pl.classes, pl.days_valid, ''active'', v_today, v_today + pl.days_valid - 1, ''regalo'', now())
  returning id into v_id;
  update gift_cards set status = ''redeemed'', redeemed_at = now(), redeemed_pass = v_id where id = g.id;
end ';

revoke all on function public.request_gift(text, text, uuid, text, text, text, text) from public;

revoke all on function public.gift_by_code(text) from public;

revoke all on function public.redeem_gift_booking(text, text) from public;

revoke all on function public.redeem_gift_pass(text) from public;

grant execute on function public.request_gift(text, text, uuid, text, text, text, text) to anon, authenticated;

grant execute on function public.gift_by_code(text) to anon, authenticated;

grant execute on function public.redeem_gift_booking(text, text) to anon, authenticated;

grant execute on function public.redeem_gift_pass(text) to authenticated;
