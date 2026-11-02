create or replace function public.slot_photos_by_code(p_code text)
returns table (id uuid, url text, created_at timestamptz)
language sql stable security definer set search_path = public as '
  select ph.id, ph.url, ph.created_at from slot_photos ph join bookings b on b.slot_id = ph.slot_id
  where b.code = upper(btrim(p_code)) and b.status <> ''cancelled'' order by ph.created_at
';
revoke all on function public.slot_photos_by_code(text) from public;
grant execute on function public.slot_photos_by_code(text) to anon, authenticated;

create or replace function public.my_photos()
returns table (id uuid, url text, slot_id uuid, starts_at timestamptz, title text, profe_name text)
language sql stable security definer set search_path = public as '
  select ph.id, ph.url, s.id, s.starts_at, s.title, p.name
  from slot_photos ph join slots s on s.id = ph.slot_id join profiles p on p.id = s.profe_id
  where exists (select 1 from bookings b where b.slot_id = s.id and b.student_id = auth.uid() and b.status <> ''cancelled'')
  order by s.starts_at desc, ph.created_at
  limit 120
';
revoke all on function public.my_photos() from public;
grant execute on function public.my_photos() to authenticated;
