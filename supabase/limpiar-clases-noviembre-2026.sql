delete from slots s
where s.starts_at > now() and s.starts_at < date '2026-12-01'
  and not exists (select 1 from bookings b where b.slot_id = s.id);

update slots s set status = 'cancelled'
where s.status = 'open' and s.starts_at > now() and s.starts_at < date '2026-12-01'
  and not exists (select 1 from bookings b where b.slot_id = s.id and b.status <> 'cancelled');

select to_char(s.starts_at at time zone 'America/Argentina/Buenos_Aires', 'Dy DD/MM HH24:MI') as quedan_con_alumnos,
       p.name as profe, s.title as clase,
       (select sum(b.people) from bookings b where b.slot_id = s.id and b.status <> 'cancelled') as anotados
from slots s join profiles p on p.id = s.profe_id
where s.status = 'open' and s.starts_at > now() and s.starts_at < date '2026-12-01'
order by s.starts_at;
