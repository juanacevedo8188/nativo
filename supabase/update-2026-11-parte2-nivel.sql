create or replace function public.set_student_level(p_student uuid, p_sport text, p_level text) returns void
language plpgsql security definer set search_path = public as '
begin
  if not is_staff() then raise exception ''Solo los profes pueden marcar el nivel''; end if;
  if p_sport not in (''sup'', ''kayak'') then raise exception ''Deporte invalido''; end if;
  if p_level is not null and p_level not in (''iniciacion'', ''intermedio'', ''avanzado'') then raise exception ''Nivel invalido''; end if;
  perform set_config(''nativo.levels'', ''on'', true);
  update students set levels = case when p_level is null then levels - p_sport else levels || jsonb_build_object(p_sport, p_level) end
  where id = p_student;
  perform set_config(''nativo.levels'', ''off'', true);
end';
revoke all on function public.set_student_level(uuid, text, text) from public;
grant execute on function public.set_student_level(uuid, text, text) to authenticated;

create or replace function public.students_guard() returns trigger
language plpgsql security definer set search_path = public as '
begin
  if auth.uid() is not null and not is_admin() then
    if old.training = ''approved'' or new.training not in (''none'', ''requested'') then
      new.training := old.training;
    end if;
    new.email := old.email;
    if coalesce(current_setting(''nativo.levels'', true), '''') <> ''on'' then
      new.levels := old.levels;
    end if;
  end if;
  return new;
end';
