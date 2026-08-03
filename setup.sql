-- Run this once in Supabase: SQL Editor -> New query -> paste -> Run

create table if not exists kv_store (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

alter table kv_store enable row level security;

create policy "Allow anon read" on kv_store
  for select using (true);

create policy "Allow anon insert" on kv_store
  for insert with check (true);

create policy "Allow anon update" on kv_store
  for update using (true);

insert into kv_store (key, value) values
  ('contracts', '[]'::jsonb),
  ('admin_pin', '"Gvm@1234"'::jsonb)
on conflict (key) do nothing;
