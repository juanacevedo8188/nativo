create table if not exists public.app_settings (
  key        text primary key,
  value      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.app_settings enable row level security;
grant select, insert, update on public.app_settings to authenticated;
drop policy if exists "app_settings admin" on public.app_settings;
create policy "app_settings admin" on public.app_settings for all to authenticated using (public.is_admin()) with check (public.is_admin());

alter table public.students add column if not exists ref_code text;
create unique index if not exists students_ref_code_idx on public.students (ref_code) where ref_code is not null;

create table if not exists public.referrals (
  id            uuid primary key default gen_random_uuid(),
  referrer_id   uuid not null references public.students(id) on delete cascade,
  booking_id    uuid not null unique references public.bookings(id) on delete cascade,
  friend_name   text,
  friend_pct    int not null,
  status        text not null default 'pending' check (status in ('pending', 'rewarded', 'void')),
  reward_coupon text,
  reward_pct    int,
  created_at    timestamptz not null default now(),
  rewarded_at   timestamptz
);
alter table public.referrals enable row level security;
grant select on public.referrals to authenticated;
drop policy if exists "referrals select" on public.referrals;
create policy "referrals select" on public.referrals for select to authenticated using (referrer_id = auth.uid() or public.is_admin());

create table if not exists public.mail_optout (
  email      text primary key,
  created_at timestamptz not null default now()
);
alter table public.mail_optout enable row level security;
revoke all on public.mail_optout from anon, authenticated;
