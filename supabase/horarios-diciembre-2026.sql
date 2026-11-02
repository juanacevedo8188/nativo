do '
declare
  tz text := ''America/Argentina/Buenos_Aires'';
  plan text[] := array[
    ''1|12:00|EUGE|INI'', ''2|12:00|EUGE|INI'', ''3|12:00|EUGE|INI'', ''4|12:00|EUGE|INI'', ''5|12:00|EUGE|INI'',
    ''2|16:00|TORA|INI'', ''2|17:00|TORA|ENT'', ''2|18:00|TORA|INI'',
    ''4|16:00|TORA|INI'', ''4|17:00|TORA|ENT'', ''4|18:00|TORA|INI'',
    ''5|13:00|TORA|INI'', ''5|15:00|TORA|INI'', ''5|16:30|TORA|INI'',
    ''6|10:00|MACHA|INI'', ''6|11:00|TORA|INI'', ''6|12:45|FRIJO|INI'', ''6|14:30|TORA|ENT'', ''6|16:00|MACHA|INI'', ''6|17:00|EUGE|INI'', ''6|18:00|TORA|INI'',
    ''7|10:00|FRIJO|INI'', ''7|11:00|FRIJO|INI'', ''7|12:45|FRIJO|INI''];
  sin_clases date[] := array[date ''2026-12-25''];
  item text; f text[]; d date; t timestamptz; pid uuid; tid uuid; c int; n int := 0; dup int := 0;
  p_euge uuid; p_tora uuid; p_macha uuid; p_frijo uuid; t_ini uuid; t_ent uuid;
begin
  select count(*), min(id::text)::uuid into c, p_euge from profiles where approved and not archived and name ilike ''%euge%'';
  if c <> 1 then raise exception ''No encuentro un unico profe EUGE (hay %)'', c; end if;
  select count(*), min(id::text)::uuid into c, p_tora from profiles where approved and not archived and (name ilike ''%torit%'' or name ilike ''%tora%'');
  if c <> 1 then raise exception ''No encuentro un unico profe TORA (hay %)'', c; end if;
  select count(*), min(id::text)::uuid into c, p_macha from profiles where approved and not archived and name ilike ''%macha%'';
  if c <> 1 then raise exception ''No encuentro un unico profe MACHA (hay %)'', c; end if;
  select count(*), min(id::text)::uuid into c, p_frijo from profiles where approved and not archived and name ilike ''%frijo%'';
  if c <> 1 then raise exception ''No encuentro un unico profe FRIJO (hay %)'', c; end if;
  select id into t_ini from class_types where active and coalesce(sport, ''sup'') = ''sup'' and not coalesce(members_only, false)
    order by (kind = ''iniciacion'') desc nulls last, sort, created_at limit 1;
  if t_ini is null then raise exception ''No hay tipo de clase de SUP para iniciacion''; end if;
  select id into t_ent from class_types where active and coalesce(sport, ''sup'') = ''sup'' and (name ilike ''%entren%'' or coalesce(members_only, false))
    order by (name ilike ''%entren%'') desc, sort, created_at limit 1;
  if t_ent is null then raise exception ''No hay tipo de clase Entrenamiento de SUP''; end if;
  for d in select g::date from generate_series(date ''2026-12-01'', date ''2026-12-31'', interval ''1 day'') g loop
    continue when d = any(sin_clases);
    foreach item in array plan loop
      f := string_to_array(item, ''|'');
      continue when f[1]::int <> extract(isodow from d)::int;
      t := (d + f[2]::time) at time zone tz;
      continue when t <= now();
      pid := case f[3] when ''EUGE'' then p_euge when ''TORA'' then p_tora when ''MACHA'' then p_macha else p_frijo end;
      tid := case f[4] when ''ENT'' then t_ent else t_ini end;
      if exists (select 1 from slots where profe_id = pid and starts_at = t and status = ''open'') then dup := dup + 1; continue; end if;
      insert into slots (profe_id, class_type_id, title, starts_at, duration_min, capacity, price, location, members_only)
        select pid, ct.id, ct.name, t, ct.duration_min, ct.capacity, ct.price, U&''Guarder\00eda Barlovento, Rosario'', coalesce(ct.members_only, false)
        from class_types ct where ct.id = tid;
      n := n + 1;
    end loop;
  end loop;
  raise notice ''Clases creadas: %, ya existian: %'', n, dup;
end
';

select p.name as profe, s.title as clase, count(*) as clases, min(to_char(s.starts_at at time zone 'America/Argentina/Buenos_Aires', 'DD/MM')) as desde, max(to_char(s.starts_at at time zone 'America/Argentina/Buenos_Aires', 'DD/MM')) as hasta
from slots s join profiles p on p.id = s.profe_id
where s.starts_at >= date '2026-12-01' and s.starts_at < date '2027-01-01' and s.status = 'open'
group by p.name, s.title order by p.name, s.title;
