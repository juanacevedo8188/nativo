-- PARTE 2b: ficha de salud. Se puede correr mas de una vez.

create or replace function public.waiver_status(p_code text) returns boolean
language sql stable security definer set search_path = public as '
  select exists (select 1 from bookings b join waivers w
                   on w.phone_key = right(regexp_replace(coalesce(b.customer_phone, ''''), ''\D'', '''', ''g''), 10) or (b.student_id is not null and w.student_id = b.student_id)
                 where b.code = upper(btrim(p_code)) and w.accepted_at > now() - interval ''365 days'');
';

create or replace function public.my_waiver()
returns table (name text, birth_date date, swims text, health text, emergency_name text, emergency_phone text, accepted_at timestamptz)
language plpgsql stable security definer set search_path = public as '
begin
  return query select w.name, w.birth_date, w.swims, w.health, w.emergency_name, w.emergency_phone, w.accepted_at from waivers w where w.student_id = auth.uid() and w.accepted_at > now() - interval ''365 days'' order by w.accepted_at desc limit 1;
end
';

create or replace function public.submit_my_waiver(p_name text, p_phone text, p_birth date, p_swims text, p_health text,
                                                   p_em_name text, p_em_phone text) returns void
language plpgsql security definer set search_path = public as '
begin
  if not exists (select 1 from students where id = auth.uid()) then raise exception ''%'', U&''Entr\00e1 con tu cuenta''; end if;
  if length(btrim(coalesce(p_name, ''''))) < 2 then raise exception ''%'', U&''Pon\00e9 tu nombre y apellido''; end if;
  if length(right(regexp_replace(coalesce(p_phone, ''''), ''\D'', '''', ''g''), 10)) < 8 then raise exception ''%'', U&''Pon\00e9 tu WhatsApp''; end if;
  if p_swims not in (''si'', ''poco'', ''no'') then raise exception ''%'', U&''Contanos si sab\00e9s nadar''; end if;
  if length(right(regexp_replace(coalesce(p_em_phone, ''''), ''\D'', '''', ''g''), 10)) < 8 or length(btrim(coalesce(p_em_name, ''''))) < 2 then raise exception ''%'', U&''Pon\00e9 un contacto de emergencia con tel\00e9fono''; end if;
  insert into waivers (phone_key, student_id, name, birth_date, swims, health, emergency_name, emergency_phone)
  values (right(regexp_replace(coalesce(p_phone, ''''), ''\D'', '''', ''g''), 10), auth.uid(), btrim(p_name), p_birth, p_swims, left(nullif(btrim(p_health), ''''), 500), btrim(p_em_name), btrim(p_em_phone));
  update students set phone = btrim(p_phone) where id = auth.uid() and (phone is null or btrim(phone) = '''');
end ';

create or replace function public.submit_waiver(p_code text, p_name text, p_birth date, p_swims text, p_health text,
                                                p_em_name text, p_em_phone text) returns void
language plpgsql security definer set search_path = public as '
declare b bookings;
begin
  select * into b from bookings where code = upper(btrim(p_code));
  if not found then raise exception ''No encontramos esa reserva''; end if;
  if length(btrim(coalesce(p_name, ''''))) < 2 then raise exception ''%'', U&''Pon\00e9 tu nombre y apellido''; end if;
  if p_swims not in (''si'', ''poco'', ''no'') then raise exception ''%'', U&''Contanos si sab\00e9s nadar''; end if;
  if length(right(regexp_replace(coalesce(p_em_phone, ''''), ''\D'', '''', ''g''), 10)) < 8 or length(btrim(coalesce(p_em_name, ''''))) < 2 then raise exception ''%'', U&''Pon\00e9 un contacto de emergencia con tel\00e9fono''; end if;
  insert into waivers (phone_key, student_id, name, birth_date, swims, health, emergency_name, emergency_phone)
  values (right(regexp_replace(coalesce(b.customer_phone, ''''), ''\D'', '''', ''g''), 10), b.student_id, btrim(p_name), p_birth, p_swims, left(nullif(btrim(p_health), ''''), 500),
          btrim(p_em_name), btrim(p_em_phone));
end ';

revoke all on function public.waiver_status(text) from public;

revoke all on function public.submit_waiver(text, text, date, text, text, text, text) from public;

grant execute on function public.waiver_status(text) to anon, authenticated;

grant execute on function public.submit_waiver(text, text, date, text, text, text, text) to anon, authenticated;

revoke all on function public.my_waiver() from public;

revoke all on function public.submit_my_waiver(text, text, date, text, text, text, text) from public;

grant execute on function public.my_waiver() to authenticated;

grant execute on function public.submit_my_waiver(text, text, date, text, text, text, text) to authenticated;
