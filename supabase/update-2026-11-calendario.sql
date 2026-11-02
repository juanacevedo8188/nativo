create table if not exists public.cal_tokens (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  token      text not null unique,
  created_at timestamptz not null default now()
);
alter table public.cal_tokens enable row level security;
revoke all on public.cal_tokens from anon, authenticated;

create or replace function public.my_cal_token(p_reset boolean default false) returns text
language plpgsql security definer set search_path = public as '
declare t text;
begin
  if not is_staff() then raise exception ''Solo para profes''; end if;
  if p_reset then delete from cal_tokens where profile_id = auth.uid(); end if;
  select token into t from cal_tokens where profile_id = auth.uid();
  if t is null then
    t := replace(gen_random_uuid()::text, ''-'', '''') || replace(gen_random_uuid()::text, ''-'', '''');
    insert into cal_tokens (profile_id, token) values (auth.uid(), t);
  end if;
  return t;
end';
revoke all on function public.my_cal_token(boolean) from public;
grant execute on function public.my_cal_token(boolean) to authenticated;
