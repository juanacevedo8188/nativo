create table if not exists public.site_notices (
  sport      text primary key check (sport in ('all', 'sup', 'kayak')),
  body       text not null check (length(body) between 1 and 280),
  tone       text not null default 'warn' check (tone in ('warn', 'info')),
  until      timestamptz,
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);
alter table public.site_notices enable row level security;
grant select on public.site_notices to anon, authenticated;
grant insert, update, delete on public.site_notices to authenticated;
drop policy if exists "site_notices select" on public.site_notices;
create policy "site_notices select" on public.site_notices for select to anon, authenticated using (true);
drop policy if exists "site_notices write" on public.site_notices;
create policy "site_notices write" on public.site_notices for all to authenticated
  using (public.is_admin() or (sport <> 'all' and public.can_manage_sport(sport)))
  with check (public.is_admin() or (sport <> 'all' and public.can_manage_sport(sport)));

create table if not exists public.coupons (
  code        text primary key check (code ~ '^[A-Z0-9]{3,20}$'),
  percent     int not null check (percent between 1 and 100),
  sport       text check (sport in ('sup', 'kayak')),
  valid_until date,
  max_uses    int check (max_uses > 0),
  active      boolean not null default true,
  note        text,
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);
alter table public.coupons enable row level security;
grant select, insert, update, delete on public.coupons to authenticated;
drop policy if exists "coupons staff" on public.coupons;
create policy "coupons staff" on public.coupons for all to authenticated
  using (public.is_admin() or (sport is not null and public.can_manage_sport(sport)))
  with check (public.is_admin() or (sport is not null and public.can_manage_sport(sport)));

alter table public.bookings add column if not exists coupon_code text;
create index if not exists bookings_coupon_idx on public.bookings (coupon_code) where coupon_code is not null;
