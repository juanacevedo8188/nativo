alter table public.students add column if not exists levels jsonb not null default '{}'::jsonb;

create table if not exists public.student_notes (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid not null references public.students(id) on delete cascade,
  author_id   uuid references public.profiles(id) on delete set null,
  author_name text,
  sport       text not null default 'sup',
  body        text not null check (length(body) between 1 and 1000),
  private     boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists student_notes_student_idx on public.student_notes (student_id, created_at desc);
alter table public.student_notes enable row level security;
grant select, insert, delete on public.student_notes to authenticated;
drop policy if exists "student_notes select" on public.student_notes;
create policy "student_notes select" on public.student_notes for select to authenticated
  using (public.is_staff() or (student_id = auth.uid() and not private));
drop policy if exists "student_notes insert" on public.student_notes;
create policy "student_notes insert" on public.student_notes for insert to authenticated
  with check (public.is_staff() and author_id = auth.uid());
drop policy if exists "student_notes delete" on public.student_notes;
create policy "student_notes delete" on public.student_notes for delete to authenticated
  using (public.is_admin() or author_id = auth.uid());

create table if not exists public.slot_photos (
  id         uuid primary key default gen_random_uuid(),
  slot_id    uuid not null references public.slots(id) on delete cascade,
  path       text not null,
  url        text not null,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists slot_photos_slot_idx on public.slot_photos (slot_id, created_at);
alter table public.slot_photos enable row level security;
grant select, insert, delete on public.slot_photos to authenticated;
drop policy if exists "slot_photos select" on public.slot_photos;
create policy "slot_photos select" on public.slot_photos for select to authenticated
  using (public.is_staff() or exists (select 1 from public.bookings b where b.slot_id = slot_photos.slot_id and b.student_id = auth.uid() and b.status <> 'cancelled'));
drop policy if exists "slot_photos insert" on public.slot_photos;
create policy "slot_photos insert" on public.slot_photos for insert to authenticated
  with check (public.is_admin() or public.owns_slot(slot_id));
drop policy if exists "slot_photos delete" on public.slot_photos;
create policy "slot_photos delete" on public.slot_photos for delete to authenticated
  using (public.is_admin() or public.owns_slot(slot_id));

insert into storage.buckets (id, name, public) values ('class-photos', 'class-photos', true) on conflict (id) do update set public = true;
drop policy if exists "class-photos select" on storage.objects;
create policy "class-photos select" on storage.objects for select to authenticated
  using (bucket_id = 'class-photos' and public.is_staff());
drop policy if exists "class-photos insert" on storage.objects;
create policy "class-photos insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'class-photos' and public.is_staff());
drop policy if exists "class-photos delete" on storage.objects;
create policy "class-photos delete" on storage.objects for delete to authenticated
  using (bucket_id = 'class-photos' and public.is_staff());
