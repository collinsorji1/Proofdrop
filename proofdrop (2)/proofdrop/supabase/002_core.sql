-- 002_core.sql: run after schema.sql. Adds plans, settings and deliveries.
alter table public.profiles add column plan text not null default 'starter';

create table public.settings (
  id int primary key default 1 check (id = 1),
  geofence_m int not null default 100,
  fee_per_delivery numeric(8,2) not null default 0.10,
  plan_prices jsonb not null default '{"starter":49,"growth":199}'
);
insert into public.settings default values;
alter table public.settings enable row level security;
create policy "signed-in read settings" on public.settings for select to authenticated using (true);
create policy "admins write settings" on public.settings for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create type delivery_status as enum ('created','assigned','arrived','delivered','failed');
create table public.deliveries (
  id uuid primary key default gen_random_uuid(),
  tracking_code text unique not null default upper(substr(md5(random()::text), 1, 8)),
  merchant_id uuid not null references public.profiles(id),
  rider_id uuid references public.profiles(id),
  address text not null,
  recipient_name text,
  recipient_phone text,
  cod_amount numeric(10,2) not null default 0,
  cod_collected numeric(10,2),
  pin_lat double precision,
  pin_lng double precision,
  status delivery_status not null default 'created',
  risk_score int not null default 0,
  flags jsonb not null default '[]',          -- [{"w":35,"t":"Completed 310 m from the drop-off pin"}]
  cleared boolean not null default false,
  dispute_reason text,
  dispute_resolved boolean not null default false,
  photo_hash text,
  is_sample boolean not null default false,
  created_at timestamptz not null default now(),
  arrived_at timestamptz,
  completed_at timestamptz
);
create index on public.deliveries (merchant_id);
create index on public.deliveries (rider_id);
create index on public.deliveries (created_at);
alter table public.deliveries enable row level security;
create policy "admins read deliveries" on public.deliveries for select using (public.is_admin());
create policy "admins update deliveries" on public.deliveries for update
  using (public.is_admin()) with check (public.is_admin());
create policy "merchants read own deliveries" on public.deliveries for select using (merchant_id = auth.uid());
