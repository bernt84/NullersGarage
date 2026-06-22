-- ============================================================================
--  GuitarØre — Supabase schema
--  Org-baseret multi-tenancy · RLS via my_org() security-definer
--  Kør hele filen i Supabase SQL Editor på dit NYE projekt.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) ORGS + MEDLEMSKAB
-- ---------------------------------------------------------------------------
create table if not exists public.orgs (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  created_at  timestamptz not null default now()
);

-- Knytter en auth-bruger til præcis én org + rolle.
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  org_id      uuid references public.orgs(id) on delete set null,
  role        text not null default 'member' check (role in ('admin','member')),
  display_name text,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 2) my_org() — security-definer helper
--    Returnerer den indloggede brugers org_id. Bruges i alle RLS-policies.
--    SECURITY DEFINER så den kan læse profiles uden at udløse RLS-rekursion.
-- ---------------------------------------------------------------------------
create or replace function public.my_org()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select org_id from public.profiles where id = auth.uid();
$$;

create or replace function public.my_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- ---------------------------------------------------------------------------
-- 3) DATATABELLER  (alt der synkes)
-- ---------------------------------------------------------------------------

-- 3a) Importerede sange (delt i org)
create table if not exists public.songs (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null default public.my_org() references public.orgs(id) on delete cascade,
  owner_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title       text not null,
  meta        text,
  body        text not null,            -- becifring i [G]-format
  cat         text default 'mine',
  diff        text default 'let',
  updated_at  timestamptz not null default now(),
  created_at  timestamptz not null default now()
);

-- 3b) App-indstillinger (pr. bruger — BPM, sprog, sidste sang, capo osv.)
create table if not exists public.settings (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  org_id      uuid not null default public.my_org() references public.orgs(id) on delete cascade,
  data        jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

-- 3c) Quiz-score / fremgang (pr. bruger, akkumuleret)
create table if not exists public.progress (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  org_id      uuid not null default public.my_org() references public.orgs(id) on delete cascade,
  kind        text not null,            -- 'fretboard_quiz' | 'staff_quiz' | 'groove' | 'play'
  score       int  not null default 0,
  total       int  not null default 0,
  best_streak int  not null default 0,
  updated_at  timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  unique (user_id, kind)
);

-- 3d) Optagelser — metadata i tabel, selve lyden i Storage-bucket 'recordings'
create table if not exists public.recordings (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null default public.my_org() references public.orgs(id) on delete cascade,
  owner_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title       text,
  storage_path text not null,           -- f.eks. '<org_id>/<owner_id>/<uuid>.webm'
  duration_s  int,
  created_at  timestamptz not null default now()
);

-- updated_at auto-touch
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;

drop trigger if exists t_songs_touch    on public.songs;
drop trigger if exists t_settings_touch on public.settings;
drop trigger if exists t_progress_touch on public.progress;
create trigger t_songs_touch    before update on public.songs    for each row execute function public.touch_updated_at();
create trigger t_settings_touch before update on public.settings for each row execute function public.touch_updated_at();
create trigger t_progress_touch before update on public.progress for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- 4) AUTO-PROFIL ved ny bruger
--    Første bruger i en helt tom database bliver admin og får sin egen org.
--    Ellers oprettes profil uden org (admin tildeler senere) — se note nederst.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_count int;
begin
  select count(*) into v_count from public.profiles;
  if v_count = 0 then
    -- Allerførste bruger: opret org + gør til admin
    insert into public.orgs(name) values ('Min org') returning id into v_org;
    insert into public.profiles(id, org_id, role, display_name)
      values (new.id, v_org, 'admin', coalesce(new.raw_user_meta_data->>'display_name', new.email));
  else
    insert into public.profiles(id, org_id, role, display_name)
      values (new.id, null, 'member', coalesce(new.raw_user_meta_data->>'display_name', new.email));
  end if;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- 5) RLS — slå til + policies
-- ---------------------------------------------------------------------------
alter table public.orgs       enable row level security;
alter table public.profiles   enable row level security;
alter table public.songs      enable row level security;
alter table public.settings   enable row level security;
alter table public.progress   enable row level security;
alter table public.recordings enable row level security;

-- orgs: man kan se sin egen org
drop policy if exists orgs_select on public.orgs;
create policy orgs_select on public.orgs
  for select using (id = public.my_org());

-- profiles: man kan se profiler i egen org; man kan opdatere sin egen
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select using (org_id = public.my_org() or id = auth.uid());

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

-- admin kan opdatere medlemmers org/rolle i egen org
drop policy if exists profiles_admin_update on public.profiles;
create policy profiles_admin_update on public.profiles
  for update using (public.my_role() = 'admin' and org_id = public.my_org())
  with check (public.my_role() = 'admin');

-- songs: hele org deler. Alle medlemmer kan læse + skrive; kun ejer/admin sletter.
drop policy if exists songs_rw on public.songs;
create policy songs_select on public.songs for select using (org_id = public.my_org());
create policy songs_insert on public.songs for insert with check (org_id = public.my_org());
create policy songs_update on public.songs for update using (org_id = public.my_org());
create policy songs_delete on public.songs
  for delete using (org_id = public.my_org() and (owner_id = auth.uid() or public.my_role() = 'admin'));

-- settings: kun egen
drop policy if exists settings_rw on public.settings;
create policy settings_select on public.settings for select using (user_id = auth.uid());
create policy settings_upsert on public.settings for insert with check (user_id = auth.uid());
create policy settings_update on public.settings for update using (user_id = auth.uid());

-- progress: kun egen (men org_id sat så man kan lave leaderboard senere)
drop policy if exists progress_rw on public.progress;
create policy progress_select on public.progress for select using (user_id = auth.uid() or org_id = public.my_org());
create policy progress_insert on public.progress for insert with check (user_id = auth.uid());
create policy progress_update on public.progress for update using (user_id = auth.uid());

-- recordings: org deler læsning; ejer/admin sletter
drop policy if exists recordings_rw on public.recordings;
create policy recordings_select on public.recordings for select using (org_id = public.my_org());
create policy recordings_insert on public.recordings for insert with check (org_id = public.my_org());
create policy recordings_delete on public.recordings
  for delete using (org_id = public.my_org() and (owner_id = auth.uid() or public.my_role() = 'admin'));

-- ---------------------------------------------------------------------------
-- 6) STORAGE — bucket til optagelser + path-isolation pr. org
--    Path-konvention:  <org_id>/<owner_id>/<filnavn>.webm
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
  values ('recordings', 'recordings', false)
  on conflict (id) do nothing;

-- Læse/skrive kun filer hvis første path-segment == egen org_id
drop policy if exists rec_read   on storage.objects;
drop policy if exists rec_write  on storage.objects;
drop policy if exists rec_delete on storage.objects;

create policy rec_read on storage.objects
  for select using (
    bucket_id = 'recordings'
    and (storage.foldername(name))[1] = public.my_org()::text
  );

create policy rec_write on storage.objects
  for insert with check (
    bucket_id = 'recordings'
    and (storage.foldername(name))[1] = public.my_org()::text
    and (storage.foldername(name))[2] = auth.uid()::text
  );

create policy rec_delete on storage.objects
  for delete using (
    bucket_id = 'recordings'
    and (storage.foldername(name))[1] = public.my_org()::text
    and ((storage.foldername(name))[2] = auth.uid()::text or public.my_role() = 'admin')
  );

-- ============================================================================
--  NOTER
--  • Første bruger der signer up bliver admin + får org "Min org".
--    Omdøb org bagefter:  update public.orgs set name='Nicon' where id = public.my_org();
--  • Nye medlemmer får ingen org. Som admin tildeler du dem:
--       update public.profiles set org_id = (select org_id from public.profiles where id = auth.uid())
--       where id = '<den_nye_brugers_uuid>';
--    (eller byg en Edge Function til org-admin user creation, som i Makro Mål)
--  • Skift e-mail-bekræftelse fra/til under Auth → Providers efter behov.
-- ============================================================================
