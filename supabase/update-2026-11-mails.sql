alter table public.profiles add column if not exists notify_email text;

create table if not exists public.mail_log (
  id         bigserial primary key,
  kind       text not null,
  ref        text not null,
  to_email   text not null,
  day        date not null default (now() at time zone 'America/Argentina/Buenos_Aires')::date,
  ok         boolean,
  created_at timestamptz not null default now()
);
create unique index if not exists mail_log_once on public.mail_log (kind, ref, to_email);
create index if not exists mail_log_day on public.mail_log (day);
alter table public.mail_log enable row level security;
revoke all on public.mail_log from anon, authenticated;

create or replace function public.mail_stats() returns table (today int, month int)
language plpgsql stable security definer set search_path = public as '
declare d date := (now() at time zone ''America/Argentina/Buenos_Aires'')::date;
begin
  if not is_admin() then raise exception ''Solo admins''; end if;
  return query select count(*) filter (where m.day = d)::int, count(*)::int
    from mail_log m where m.day >= date_trunc(''month'', d)::date and m.ok is not false;
end';
revoke all on function public.mail_stats() from public;
grant execute on function public.mail_stats() to authenticated;
