-- PARTE 2a: lista de espera. Se puede correr mas de una vez.

create or replace function public.join_waitlist(p_slot uuid, p_name text, p_phone text) returns int
language plpgsql security definer set search_path = public as '
declare s slots; v_booked int; k text := right(regexp_replace(coalesce(p_phone, ''''), ''\D'', '''', ''g''), 10);
begin
  p_name := btrim(coalesce(p_name, ''''));
  if length(p_name) < 2 or length(p_name) > 80 then raise exception ''%'', U&''Ingres\00e1 tu nombre y apellido''; end if;
  if length(k) < 8 then raise exception ''%'', U&''Ingres\00e1 un WhatsApp v\00e1lido (con caracter\00edstica)''; end if;
  select * into s from slots where id = p_slot;
  if not found or s.status <> ''open'' or s.starts_at <= now() or s.members_only then raise exception ''%'', U&''Esa clase ya no est\00e1 disponible''; end if;
  select coalesce(sum(people), 0) into v_booked from bookings where slot_id = p_slot and status <> ''cancelled'';
  if v_booked < s.capacity then raise exception ''%'', U&''Hay lugar: reserv\00e1 directamente''; end if;
  if exists (select 1 from bookings where slot_id = p_slot and status <> ''cancelled'' and right(regexp_replace(coalesce(customer_phone, ''''), ''\D'', '''', ''g''), 10) = k) then
    raise exception ''%'', U&''Ya ten\00e9s una reserva en esta clase'';
  end if;
  if not exists (select 1 from waitlist where slot_id = p_slot and right(regexp_replace(coalesce(phone, ''''), ''\D'', '''', ''g''), 10) = k) then
    if (select count(*) from waitlist where slot_id = p_slot) >= 30 then raise exception ''%'', U&''La lista de espera est\00e1 llena''; end if;
    insert into waitlist (slot_id, name, phone, student_id)
    values (p_slot, p_name, btrim(p_phone), (select st.id from students st where st.id = auth.uid()));
  end if;
  return (select count(*) from waitlist w where w.slot_id = p_slot
          and w.created_at <= (select created_at from waitlist where slot_id = p_slot and right(regexp_replace(coalesce(phone, ''''), ''\D'', '''', ''g''), 10) = k limit 1));
end ';

create or replace function public.my_waitlist()
returns table (slot_id uuid, title text, starts_at timestamptz, free int)
language sql stable security definer set search_path = public as '
  select s.id, s.title, s.starts_at,
         greatest(s.capacity - coalesce((select sum(b.people) from bookings b where b.slot_id = s.id and b.status <> ''cancelled''), 0), 0)::int
  from waitlist w join slots s on s.id = w.slot_id
  where w.student_id = auth.uid() and s.status = ''open'' and s.starts_at > now()
    and not exists (select 1 from bookings b where b.slot_id = s.id and b.status <> ''cancelled''
                    and (right(regexp_replace(coalesce(b.customer_phone, ''''), ''\D'', '''', ''g''), 10) = right(regexp_replace(coalesce(w.phone, ''''), ''\D'', '''', ''g''), 10) or b.student_id = auth.uid()))
  order by s.starts_at;
';

drop trigger if exists waitlist_cleanup on public.bookings;

revoke all on function public.join_waitlist(uuid, text, text) from public;

revoke all on function public.my_waitlist() from public;

grant execute on function public.join_waitlist(uuid, text, text) to anon, authenticated;

grant execute on function public.my_waitlist() to authenticated;
