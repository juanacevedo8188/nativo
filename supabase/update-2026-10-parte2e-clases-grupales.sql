-- PARTE 2e: clases grupales. Se puede correr mas de una vez.

create or replace function public.request_group(p_name text, p_phone text, p_kind text, p_sport text, p_people int, p_preferred text, p_message text)
returns void language plpgsql security definer set search_path = public as '
begin
  if length(btrim(coalesce(p_name, ''''))) < 2 then raise exception ''%'', U&''Pon\00e9 tu nombre''; end if;
  if length(right(regexp_replace(coalesce(p_phone, ''''), ''\D'', '''', ''g''), 10)) < 8 then raise exception ''%'', U&''Ingres\00e1 un WhatsApp v\00e1lido (con caracter\00edstica)''; end if;
  if (select count(*) from group_requests where right(regexp_replace(coalesce(phone, ''''), ''\D'', '''', ''g''), 10) = right(regexp_replace(coalesce(p_phone, ''''), ''\D'', '''', ''g''), 10) and created_at > now() - interval ''1 day'') >= 3 then
    raise exception ''Ya recibimos tu pedido: te escribimos pronto'';
  end if;
  insert into group_requests (name, phone, kind, sport, people, preferred, message)
  values (btrim(p_name), btrim(p_phone), case when p_kind in (''privada'', ''grupo'', ''cumple'', ''empresa'', ''otro'') then p_kind else ''otro'' end,
          case when p_sport = ''kayak'' then ''kayak'' else ''sup'' end, least(greatest(coalesce(p_people, 1), 1), 200),
          left(nullif(btrim(p_preferred), ''''), 120), left(nullif(btrim(p_message), ''''), 500));
end ';

revoke all on function public.request_group(text, text, text, text, int, text, text) from public;

grant execute on function public.request_group(text, text, text, text, int, text, text) to anon, authenticated;
