-- PARTE 1 de 2: tablas nuevas (lista de espera, fichas, reseñas, gift cards, pedidos grupales).

create table if not exists public.waitlist (
  id         uuid primary key default gen_random_uuid(),
  slot_id    uuid not null references public.slots(id) on delete cascade,
  name       text not null,
  phone      text not null,
  student_id uuid references public.students(id) on delete set null,
  created_at timestamptz not null default now(),
  notified_at timestamptz
);

create table if not exists public.waivers (
  id              uuid primary key default gen_random_uuid(),
  phone_key       text not null,
  student_id      uuid references public.students(id) on delete set null,
  name            text not null,
  birth_date      date,
  swims           text check (swims in ('si', 'poco', 'no')),
  health          text,
  emergency_name  text,
  emergency_phone text,
  accepted_at     timestamptz not null default now()
);

create table if not exists public.reviews (
  id         uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references public.bookings(id) on delete cascade,
  slot_id    uuid references public.slots(id) on delete cascade,
  profe_id   uuid references public.profiles(id) on delete set null,
  stars      int not null check (stars between 1 and 5),
  comment    text,
  hidden     boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.gift_cards (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,
  kind             text not null check (kind in ('clase', 'abono')),
  sport            text not null default 'sup',
  plan_id          uuid references public.plans(id) on delete set null,
  value            numeric(12,2) not null default 0,
  buyer_name       text not null,
  buyer_phone      text not null,
  recipient_name   text not null,
  message          text,
  status           text not null default 'pending' check (status in ('pending', 'active', 'redeemed', 'cancelled')),
  created_at       timestamptz not null default now(),
  paid_at          timestamptz,
  redeemed_at      timestamptz,
  redeemed_booking uuid references public.bookings(id) on delete set null,
  redeemed_pass    uuid references public.passes(id) on delete set null
);

create table if not exists public.group_requests (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  phone      text not null,
  kind       text not null default 'grupo' check (kind in ('privada', 'grupo', 'cumple', 'empresa', 'otro')),
  sport      text not null default 'sup',
  people     int,
  preferred  text,
  message    text,
  status     text not null default 'nuevo' check (status in ('nuevo', 'contactado', 'cerrado')),
  created_at timestamptz not null default now()
);

create index if not exists waitlist_slot_idx on public.waitlist (slot_id, created_at);
create index if not exists waivers_phone_idx on public.waivers (phone_key, accepted_at desc);

grant select, update, delete on public.waitlist to authenticated;
grant select on public.waivers to authenticated;
grant select, update on public.reviews to authenticated;
grant select, update on public.gift_cards to authenticated;
grant select, update, delete on public.group_requests to authenticated;

alter table public.waitlist enable row level security;
drop policy if exists "waitlist staff" on public.waitlist;
create policy "waitlist staff" on public.waitlist for all to authenticated
  using (is_admin() or owns_slot(slot_id)) with check (is_admin() or owns_slot(slot_id));
alter table public.waivers enable row level security;
drop policy if exists "waivers staff" on public.waivers;
create policy "waivers staff" on public.waivers for select to authenticated using (is_staff());
alter table public.reviews enable row level security;
drop policy if exists "reviews select" on public.reviews;
create policy "reviews select" on public.reviews for select to authenticated using (is_admin() or profe_id = auth.uid());
drop policy if exists "reviews hide" on public.reviews;
create policy "reviews hide" on public.reviews for update to authenticated using (is_admin()) with check (is_admin());
alter table public.gift_cards enable row level security;
drop policy if exists "gift_cards admin" on public.gift_cards;
create policy "gift_cards admin" on public.gift_cards for all to authenticated using (is_admin()) with check (is_admin());
alter table public.group_requests enable row level security;
drop policy if exists "group_requests admin" on public.group_requests;
create policy "group_requests admin" on public.group_requests for all to authenticated using (is_admin()) with check (is_admin());

do $fn$
declare t text;
begin
  foreach t in array array['waitlist', 'gift_cards', 'group_requests'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $fn$;
