create or replace function public.my_ref_code() returns text
language plpgsql security definer set search_path = public as '
declare c text;
begin
  if not exists (select 1 from students where id = auth.uid()) then raise exception ''Entra con tu cuenta''; end if;
  select ref_code into c from students where id = auth.uid();
  while c is null loop
    c := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    begin
      update students set ref_code = c where id = auth.uid();
    exception when unique_violation then c := null;
    end;
  end loop;
  return c;
end';
revoke all on function public.my_ref_code() from public;
grant execute on function public.my_ref_code() to authenticated;

create or replace function public.referrer_info(p_code text)
returns table (first_name text, friend_pct int)
language sql stable security definer set search_path = public as '
  select split_part(btrim(s.name), '' '', 1), coalesce((a.value ->> ''friend_pct'')::int, 10)
  from students s join app_settings a on a.key = ''referral''
  where s.ref_code = upper(btrim(p_code)) and coalesce((a.value ->> ''on'')::boolean, false)
';
revoke all on function public.referrer_info(text) from public;
grant execute on function public.referrer_info(text) to anon, authenticated;

create or replace function public.apply_referral(p_booking text, p_ref text)
returns numeric
language plpgsql security definer set search_path = public as '
declare b bookings; r students; cfg jsonb; pct int; v_digits text; v_new numeric;
begin
  select value into cfg from app_settings where key = ''referral'';
  if cfg is null or not coalesce((cfg ->> ''on'')::boolean, false) then raise exception ''La promo de invitados no esta activa''; end if;
  pct := least(greatest(coalesce((cfg ->> ''friend_pct'')::int, 10), 1), 100);
  select * into r from students where ref_code = upper(btrim(coalesce(p_ref, '''')));
  if not found then raise exception ''Ese link de invitado no es valido''; end if;
  select * into b from bookings where code = upper(btrim(coalesce(p_booking, ''''))) for update;
  if not found or b.status <> ''confirmed'' then raise exception ''No encontramos esa reserva''; end if;
  if b.paid or b.coupon_code is not null then raise exception ''%'', U&''Esa reserva ya tiene descuento o est\00e1 paga''; end if;
  if b.student_id = r.id then raise exception ''No te podes invitar a vos mismo''; end if;
  v_digits := right(regexp_replace(coalesce(b.customer_phone, ''''), ''\D'', '''', ''g''), 10);
  if v_digits <> '''' and v_digits = right(regexp_replace(coalesce(r.phone, ''''), ''\D'', '''', ''g''), 10) then raise exception ''No te podes invitar a vos mismo''; end if;
  if exists (select 1 from bookings x where x.id <> b.id and x.status <> ''cancelled'' and x.created_at < now() - interval ''15 minutes''
             and ((b.student_id is not null and x.student_id = b.student_id)
                  or right(regexp_replace(coalesce(x.customer_phone, ''''), ''\D'', '''', ''g''), 10) = v_digits)) then
    raise exception ''%'', U&''El descuento de invitado es solo para la primera clase'';
  end if;
  v_new := round(b.amount * (100 - pct) / 100.0);
  update bookings set amount = v_new, coupon_code = ''AMIGO'',
    notes = concat_ws('' - '', nullif(btrim(notes), ''''), ''Invitado por '' || split_part(btrim(r.name), '' '', 1) || '' -'' || pct || ''%'')
  where id = b.id;
  insert into referrals (referrer_id, booking_id, friend_name, friend_pct) values (r.id, b.id, split_part(btrim(b.customer_name), '' '', 1), pct);
  return v_new;
end';
revoke all on function public.apply_referral(text, text) from public;
grant execute on function public.apply_referral(text, text) to anon, authenticated;
