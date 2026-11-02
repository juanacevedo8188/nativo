create or replace function public.public_slots(p_from timestamptz, p_to timestamptz)
returns table (
  id uuid, title text, class_type_id uuid, starts_at timestamptz, duration_min int,
  capacity int, price numeric, location text, notes text,
  profe_id uuid, profe_name text, booked int, members_only boolean
)
language sql stable security definer set search_path = public as '
  select s.id, s.title, s.class_type_id, s.starts_at, s.duration_min,
         s.capacity, s.price, s.location, s.notes,
         s.profe_id, p.name,
         coalesce((select sum(b.people) from bookings b
                   where b.slot_id = s.id and b.status <> ''cancelled''), 0)::int,
         s.members_only
  from slots s
  join profiles p on p.id = s.profe_id
  where s.status = ''open''
    and p.approved
    and s.starts_at >= greatest(p_from, now())
    and s.starts_at < p_to
    and p_to - p_from <= interval ''93 days''
  order by s.starts_at
';
