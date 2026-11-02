create or replace function public.check_coupon(p_coupon text, p_sport text)
returns table (coupon text, pct int)
language plpgsql stable security definer set search_path = public as '
declare c coupons; v_used int;
begin
  select * into c from coupons where coupons.code = upper(btrim(coalesce(p_coupon, '''')));
  if not found or not c.active then raise exception ''%'', U&''Ese cup\00f3n no existe''; end if;
  if c.valid_until is not null and c.valid_until < (now() at time zone ''America/Argentina/Buenos_Aires'')::date then
    raise exception ''%'', U&''Ese cup\00f3n ya venci\00f3'';
  end if;
  if c.sport is not null and c.sport <> coalesce(p_sport, ''sup'') then
    raise exception ''%'', U&''Ese cup\00f3n es para clases de '' || case c.sport when ''kayak'' then ''kayak'' else ''SUP'' end;
  end if;
  if c.max_uses is not null then
    select count(*) into v_used from bookings b where b.coupon_code = c.code and b.status <> ''cancelled'';
    if v_used >= c.max_uses then raise exception ''%'', U&''Ese cup\00f3n ya se us\00f3 todas las veces''; end if;
  end if;
  return query select c.code, c.percent;
end';
revoke all on function public.check_coupon(text, text) from public;
grant execute on function public.check_coupon(text, text) to anon, authenticated;

create or replace function public.apply_coupon(p_booking text, p_coupon text)
returns numeric
language plpgsql security definer set search_path = public as '
declare b bookings; s slots; v_sport text; r record; v_digits text; v_new numeric;
begin
  select * into b from bookings where code = upper(btrim(coalesce(p_booking, ''''))) for update;
  if not found or b.status <> ''confirmed'' then raise exception ''No encontramos esa reserva''; end if;
  if b.paid then raise exception ''%'', U&''La reserva ya est\00e1 paga''; end if;
  if b.coupon_code is not null then raise exception ''%'', U&''Esta reserva ya tiene un cup\00f3n''; end if;
  select * into s from slots where id = b.slot_id;
  if s.starts_at <= now() then raise exception ''%'', U&''La clase ya pas\00f3''; end if;
  select coalesce((select ct.sport from class_types ct where ct.id = s.class_type_id), ''sup'') into v_sport;
  select * into r from check_coupon(p_coupon, v_sport);
  v_digits := right(regexp_replace(coalesce(b.customer_phone, ''''), ''\D'', '''', ''g''), 10);
  if exists (select 1 from bookings x where x.coupon_code = r.coupon and x.status <> ''cancelled''
             and right(regexp_replace(coalesce(x.customer_phone, ''''), ''\D'', '''', ''g''), 10) = v_digits) then
    raise exception ''%'', U&''Ya usaste este cup\00f3n'';
  end if;
  v_new := round(b.amount * (100 - r.pct) / 100.0);
  update bookings set amount = v_new, coupon_code = r.coupon,
    notes = concat_ws('' - '', nullif(btrim(notes), ''''), U&''Cup\00f3n '' || r.coupon || '' -'' || r.pct || ''%'')
  where id = b.id;
  return v_new;
end';
revoke all on function public.apply_coupon(text, text) from public;
grant execute on function public.apply_coupon(text, text) to anon, authenticated;
