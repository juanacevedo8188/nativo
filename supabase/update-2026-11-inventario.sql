create table if not exists public.equipment (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null default 'tabla' check (kind in ('tabla', 'remo', 'chaleco', 'kayak', 'pala', 'otro')),
  name       text not null check (length(name) between 1 and 80),
  size       text,
  status     text not null default 'ok' check (status in ('ok', 'revisar', 'reparacion', 'baja')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.equipment_notes (
  id           uuid primary key default gen_random_uuid(),
  equipment_id uuid not null references public.equipment(id) on delete cascade,
  author_id    uuid references public.profiles(id) on delete set null,
  author_name  text,
  body         text not null check (length(body) between 1 and 1000),
  status       text check (status in ('ok', 'revisar', 'reparacion', 'baja')),
  created_at   timestamptz not null default now()
);
create index if not exists equipment_notes_eq_idx on public.equipment_notes (equipment_id, created_at desc);
alter table public.equipment enable row level security;
alter table public.equipment_notes enable row level security;
grant select, insert, update, delete on public.equipment to authenticated;
grant select, insert, delete on public.equipment_notes to authenticated;
drop policy if exists "equipment admin" on public.equipment;
create policy "equipment admin" on public.equipment for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "equipment_notes admin" on public.equipment_notes;
create policy "equipment_notes admin" on public.equipment_notes for all to authenticated using (public.is_admin()) with check (public.is_admin());
