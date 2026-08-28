-- Run this once in Supabase: SQL Editor -> New query -> paste -> Run
-- Safe to re-run on an existing project: uses IF NOT EXISTS / OR REPLACE /
-- DROP ... IF EXISTS throughout, so re-running this file to pick up a new
-- version of the schema won't error out or duplicate anything.

-- ============================================================
-- kv_store (contracts JSON blob)
-- ============================================================
create table if not exists kv_store (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

alter table kv_store enable row level security;

drop policy if exists "Allow anon read" on kv_store;
drop policy if exists "Allow anon insert" on kv_store;
drop policy if exists "Allow anon update" on kv_store;
drop policy if exists "kv_store select" on kv_store;
drop policy if exists "kv_store insert" on kv_store;
drop policy if exists "kv_store update" on kv_store;

-- Guests (no login) can still view the dashboard read-only.
create policy "kv_store select" on kv_store
  for select using (true);

-- Only a logged-in account (any role) can write. NOTE: this is coarse —
-- it stops an anonymous visitor from writing at all, but it does not
-- itself distinguish "user can set PM dates" from "admin can add/delete
-- contracts" at the database level, because all contracts live in one
-- JSON blob row rather than one row per contract. That finer-grained
-- split is still enforced client-side only (same as the old PIN model —
-- see CLAUDE.md). Tightening it further would mean moving contracts to
-- real per-row storage plus RPC functions; ask before taking that on.
create policy "kv_store insert" on kv_store
  for insert to authenticated with check (true);
create policy "kv_store update" on kv_store
  for update to authenticated using (true);

-- Old shared PINs are replaced by real accounts — drop them.
delete from kv_store where key in ('admin_pin', 'user_pin');
insert into kv_store (key, value) values
  ('contracts', '[]'::jsonb)
on conflict (key) do nothing;

-- ============================================================
-- profiles (one row per account; holds the role)
-- ============================================================
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  role text not null default 'user' check (role in ('user', 'admin', 'super_admin')),
  created_at timestamptz not null default now()
);

alter table profiles enable row level security;

-- True for exactly one email: the permanent super admin. No one — not
-- even another admin — can promote anyone else to this tier, and this
-- account can never be demoted, edited, or removed by the app.
create or replace function public.is_locked_super_admin(target_email text)
returns boolean
language sql
immutable
as $$
  select lower(target_email) = 'zahidrxz@gmail.com';
$$;

-- Looks up the CALLER's own role. Marked SECURITY DEFINER so it reads
-- profiles as its owner (who bypasses RLS as the table owner) instead of
-- as the requesting user — this is what lets policies below check "is the
-- caller an admin?" without recursively re-evaluating the very policy
-- they're part of.
create or replace function public.current_role()
returns text
language sql
security definer
set search_path = public
stable
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- Auto-creates a profiles row whenever someone signs up. Everyone starts
-- as 'user' except the locked super admin email, which always starts (and
-- stays) 'super_admin'.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, role)
  values (
    new.id,
    new.email,
    case when public.is_locked_super_admin(new.email) then 'super_admin' else 'user' end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

drop policy if exists "profiles select" on profiles;
drop policy if exists "profiles update" on profiles;

-- Everyone can see their own row; admins/super_admin can see every row
-- (needed to render the "Manage Users" list).
create policy "profiles select" on profiles
  for select to authenticated
  using (id = auth.uid() or public.current_role() in ('admin', 'super_admin'));

-- Only super_admin can change a role, never on the locked super admin's
-- own row, and only ever *to* user/admin (super_admin is email-locked,
-- not grantable through the app).
create policy "profiles update" on profiles
  for update to authenticated
  using (public.current_role() = 'super_admin' and not public.is_locked_super_admin(email))
  with check (role in ('user', 'admin'));

-- ============================================================
-- activity_log (audit trail — readable only by super_admin)
-- ============================================================
create table if not exists activity_log (
  id bigserial primary key,
  actor_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  actor_email text not null,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table activity_log enable row level security;

drop policy if exists "activity_log insert" on activity_log;
drop policy if exists "activity_log select" on activity_log;

-- Any logged-in account can log its own actions (contract edits, PM
-- check changes, login/logout, role changes)...
create policy "activity_log insert" on activity_log
  for insert to authenticated with check (actor_id = auth.uid());

-- ...but only super_admin can ever read the log back.
create policy "activity_log select" on activity_log
  for select to authenticated using (public.current_role() = 'super_admin');

create index if not exists activity_log_created_at_idx on activity_log (created_at desc);
