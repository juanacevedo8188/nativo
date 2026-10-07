-- PARTE 2c: resenas. Se puede correr mas de una vez.

create or replace function public.leave_review(p_code text, p_stars int, p_comment text) returns void
language plpgsql security definer set search_path = public as '
declare b bookings; s slots;
begin
  select * into b from bookings where code = upper(btrim(p_code));
  if not found then raise exception ''No encontramos esa reserva''; end if;
  select * into s from slots where id = b.slot_id;
  if s.starts_at + make_interval(mins => s.duration_min) > now() then raise exception ''%'', U&''Pod\00e9s calificar cuando termine la clase''; end if;
  if b.status in (''cancelled'', ''no_show'') or s.status = ''cancelled'' then raise exception ''Esa clase no se dio''; end if;
  if p_stars not between 1 and 5 then raise exception ''%'', U&''Eleg\00ed de 1 a 5 estrellas''; end if;
  update reviews set stars = p_stars, comment = left(nullif(btrim(p_comment), ''''), 400), created_at = now() where booking_id = b.id;
  if not found then
    insert into reviews (booking_id, slot_id, profe_id, stars, comment)
    values (b.id, s.id, s.profe_id, p_stars, left(nullif(btrim(p_comment), ''''), 400));
  end if;
end ';

create or replace function public.review_by_code(p_code text) returns table (stars int, comment text)
language sql stable security definer set search_path = public as '
  select r.stars, r.comment from reviews r join bookings b on b.id = r.booking_id where b.code = upper(btrim(p_code));
';

create or replace function public.public_reviews()
returns table (first_name text, profe_name text, stars int, comment text, sport text, created_at timestamptz)
language sql stable security definer set search_path = public as '
  select split_part(btrim(b.customer_name), '' '', 1), p.name, r.stars, r.comment, coalesce(ct.sport, ''sup''), r.created_at
  from reviews r join bookings b on b.id = r.booking_id join slots s on s.id = r.slot_id
  left join profiles p on p.id = r.profe_id left join class_types ct on ct.id = s.class_type_id
  where r.stars >= 4 and r.comment is not null and not r.hidden
  order by r.created_at desc limit 12;
';

revoke all on function public.leave_review(text, int, text) from public;

revoke all on function public.review_by_code(text) from public;

revoke all on function public.public_reviews() from public;

grant execute on function public.leave_review(text, int, text) to anon, authenticated;

grant execute on function public.review_by_code(text) to anon, authenticated;

grant execute on function public.public_reviews() to anon, authenticated;
