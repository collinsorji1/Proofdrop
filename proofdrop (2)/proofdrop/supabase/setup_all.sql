-- ProofDrop: complete database setup. Paste this whole file into the Supabase SQL editor and run it once.
-- It is schema.sql + 002 to 007 in order. If the editor complains about the 'alter type' line, run that one line alone first, then the rest.

-- ============================================================
-- schema.sql
-- ============================================================
-- ProofDrop: accounts foundation. Run once in the Supabase SQL editor.
create type user_role as enum ('admin','merchant','rider');
create type account_status as enum ('active','pending','suspended');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role user_role not null default 'merchant',
  status account_status not null default 'active',
  full_name text not null,
  phone text,
  business_name text,
  vehicle text,
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;

create function public.is_admin() returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.profiles
    where id = auth.uid() and role = 'admin' and status = 'active')
$$;

create policy "read own profile" on public.profiles for select using (auth.uid() = id);
create policy "admins read all" on public.profiles for select using (public.is_admin());
create policy "admins update all" on public.profiles for update
  using (public.is_admin()) with check (public.is_admin());

-- Roles come from sign-up metadata, but only merchant or rider are ever accepted.
-- Admins are made by hand (see README). Riders start as pending until approved.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare r user_role := case when new.raw_user_meta_data->>'role' = 'rider'
                            then 'rider'::user_role else 'merchant'::user_role end;
begin
  insert into public.profiles (id, role, status, full_name, phone, business_name, vehicle)
  values (
    new.id, r,
    case when r = 'rider' then 'pending'::account_status else 'active'::account_status end,
    coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'), ''), 'New user'),
    left(new.raw_user_meta_data->>'phone', 30),
    left(new.raw_user_meta_data->>'business', 120),
    left(new.raw_user_meta_data->>'vehicle', 60)
  );
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

-- ============================================================
-- 002_core.sql
-- ============================================================
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

-- ============================================================
-- 003_merchant.sql
-- ============================================================
-- 003_merchant.sql: run after 002_core.sql. Lets merchants create and manage deliveries safely.
alter table public.deliveries add column done_lat double precision, add column done_lng double precision;

-- The handoff code and the recipient's private link token live here. No policies on purpose:
-- riders and merchants can never read this table directly, only the functions below can.
create table public.delivery_secrets (
  delivery_id uuid primary key references public.deliveries(id) on delete cascade,
  otp text not null,
  recipient_token text unique not null
);
alter table public.delivery_secrets enable row level security;

create function public.create_delivery(p_address text, p_recipient_name text, p_recipient_phone text,
  p_cod numeric, p_rider uuid, p_lat double precision, p_lng double precision)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d public.deliveries; tok text := replace(gen_random_uuid()::text, '-', '');
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'merchant' and status = 'active') then
    raise exception 'Only active merchant accounts can create deliveries'; end if;
  if length(trim(coalesce(p_address, ''))) < 5 then raise exception 'Enter the full drop-off address'; end if;
  if p_rider is not null and not exists (select 1 from public.profiles where id = p_rider and role = 'rider' and status = 'active') then
    raise exception 'Choose an approved rider'; end if;
  insert into public.deliveries (merchant_id, rider_id, address, recipient_name, recipient_phone, cod_amount, pin_lat, pin_lng, status)
  values (auth.uid(), p_rider, trim(p_address), nullif(trim(p_recipient_name), ''), nullif(trim(p_recipient_phone), ''),
          greatest(coalesce(p_cod, 0), 0), p_lat, p_lng,
          case when p_rider is null then 'created' else 'assigned' end::delivery_status)
  returning * into d;
  insert into public.delivery_secrets values (d.id, lpad(floor(random() * 10000)::int::text, 4, '0'), tok);
  return jsonb_build_object('id', d.id, 'tracking_code', d.tracking_code, 'token', tok);
end $$;

create function public.assign_rider(p_delivery uuid, p_rider uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.deliveries where id = p_delivery and merchant_id = auth.uid()
                 and status in ('created', 'assigned')) then raise exception 'This delivery cannot be reassigned'; end if;
  if not exists (select 1 from public.profiles where id = p_rider and role = 'rider' and status = 'active') then
    raise exception 'Choose an approved rider'; end if;
  update public.deliveries set rider_id = p_rider, status = 'assigned' where id = p_delivery;
end $$;

create function public.resolve_dispute(p_delivery uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.deliveries set dispute_resolved = true
  where id = p_delivery and merchant_id = auth.uid() and dispute_reason is not null;
  if not found then raise exception 'No open dispute on this delivery'; end if;
end $$;

create function public.recipient_link_token(p_delivery uuid) returns text
language sql security definer set search_path = public stable as $$
  select s.recipient_token from public.delivery_secrets s
  join public.deliveries d on d.id = s.delivery_id
  where s.delivery_id = p_delivery and d.merchant_id = auth.uid()
$$;

-- Riders a merchant may pick from, plus riders already on that merchant's deliveries (so names still show).
create function public.merchant_riders() returns table (id uuid, full_name text, vehicle text, status account_status)
language sql security definer set search_path = public stable as $$
  select p.id, p.full_name, p.vehicle, p.status from public.profiles p
  where p.role = 'rider'
    and exists (select 1 from public.profiles m where m.id = auth.uid() and m.role = 'merchant' and m.status = 'active')
    and (p.status = 'active' or p.id in (select rider_id from public.deliveries where merchant_id = auth.uid()))
  order by p.full_name
$$;

revoke execute on function public.create_delivery, public.assign_rider, public.resolve_dispute,
  public.recipient_link_token, public.merchant_riders from public, anon;
grant execute on function public.create_delivery, public.assign_rider, public.resolve_dispute,
  public.recipient_link_token, public.merchant_riders to authenticated;

-- ============================================================
-- 004_rider.sql
-- ============================================================
-- 004_rider.sql: run after 003_merchant.sql. The rider app and ALL fraud checks.
-- Riders have no direct table access. Every action goes through the functions below,
-- which run in the database, so a rider's phone can never decide its own risk score.
alter table public.deliveries
  add column arrive_lat double precision, add column arrive_lng double precision, add column arrive_dist double precision,
  add column otp_attempts int not null default 0, add column photo_path text;
create index on public.deliveries (photo_hash);

create function public.dist_m(a1 double precision, o1 double precision, a2 double precision, o2 double precision)
returns double precision language sql immutable as $$
  select 12742000 * asin(sqrt(sin(radians(a2 - a1) / 2) ^ 2 + cos(radians(a1)) * cos(radians(a2)) * sin(radians(o2 - o1) / 2) ^ 2))
$$;

-- What a rider may see: their own deliveries, without the drop-off pin or the handoff code.
create function public.rider_tasks() returns jsonb language sql security definer set search_path = public stable as $$
  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb) from (
    select d.id, d.tracking_code, d.address, d.recipient_name, d.recipient_phone, d.cod_amount, d.cod_collected,
           d.status, d.risk_score, d.flags, d.cleared, d.created_at, d.arrived_at, d.completed_at
    from public.deliveries d
    where d.rider_id = auth.uid() and d.created_at > now() - interval '30 days'
      and exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'rider' and p.status = 'active')
  ) t
$$;

create function public.rider_arrive(p_delivery uuid, p_lat double precision, p_lng double precision) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.deliveries; r int; m double precision; fl jsonb;
begin
  select * into d from public.deliveries
   where id = p_delivery and rider_id = auth.uid() and status = 'assigned'
     and exists (select 1 from public.profiles where id = auth.uid() and role = 'rider' and status = 'active') for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'This delivery is not ready for check-in.'); end if;
  select geofence_m into r from public.settings;
  fl := d.flags;
  if p_lat is null or p_lng is null then
    fl := fl || jsonb_build_array(jsonb_build_object('w', 25, 't', 'Location unavailable at check-in'));
  elsif d.pin_lat is not null then
    m := public.dist_m(p_lat, p_lng, d.pin_lat, d.pin_lng);
    if m > r then return jsonb_build_object('ok', false, 'distance', round(m), 'radius', r); end if;
  end if;
  update public.deliveries set status = 'arrived', arrived_at = now(), arrive_lat = p_lat, arrive_lng = p_lng,
         arrive_dist = m, flags = fl where id = p_delivery;
  return jsonb_build_object('ok', true);
end $$;

create function public.rider_complete(p_delivery uuid, p_otp text, p_lat double precision, p_lng double precision,
  p_photo_path text, p_photo_hash text, p_cod numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.deliveries; s public.delivery_secrets; r int; m double precision; fl jsonb; k int;
        prev record; dd double precision; risk int;
begin
  select * into d from public.deliveries
   where id = p_delivery and rider_id = auth.uid() and status = 'arrived'
     and exists (select 1 from public.profiles where id = auth.uid() and role = 'rider' and status = 'active') for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'This delivery is not ready to complete.'); end if;
  if p_photo_path is null or p_photo_hash is null or p_photo_path not like auth.uid()::text || '/%' then
    return jsonb_build_object('ok', false, 'message', 'A photo of the parcel is required.'); end if;
  select * into s from public.delivery_secrets where delivery_id = p_delivery;
  fl := d.flags;

  -- 1. Handoff code: three tries, then the delivery is locked and flagged.
  if p_otp is distinct from s.otp then
    k := d.otp_attempts + 1;
    if k >= 3 then
      fl := fl || jsonb_build_array(jsonb_build_object('w', 30, 't', 'Handoff code entered wrong 3 times'));
      update public.deliveries set otp_attempts = k, status = 'failed', completed_at = now(), flags = fl,
        risk_score = least(100, (select coalesce(sum((f->>'w')::int), 0) from jsonb_array_elements(fl) f)) where id = p_delivery;
      return jsonb_build_object('ok', false, 'locked', true);
    end if;
    update public.deliveries set otp_attempts = k where id = p_delivery;
    return jsonb_build_object('ok', false, 'attempts_left', 3 - k);
  end if;

  select geofence_m into r from public.settings;
  -- 2. Place: was the phone at the drop-off pin, and could the rider have got here from the last drop?
  if p_lat is null or p_lng is null then
    fl := fl || jsonb_build_array(jsonb_build_object('w', 25, 't', 'Location unavailable at completion'));
  else
    if d.pin_lat is not null then
      m := public.dist_m(p_lat, p_lng, d.pin_lat, d.pin_lng);
      if m > r then fl := fl || jsonb_build_array(jsonb_build_object('w', 35, 't', format('Completed %s m from the drop-off pin', round(m)))); end if;
    end if;
    select done_lat, done_lng, completed_at into prev from public.deliveries
     where rider_id = auth.uid() and status = 'delivered' and done_lat is not null and id <> p_delivery
     order by completed_at desc limit 1;
    if found then
      dd := public.dist_m(prev.done_lat, prev.done_lng, p_lat, p_lng);
      if dd > 1000 and dd / greatest(extract(epoch from (now() - prev.completed_at)), 1) > 33 then
        fl := fl || jsonb_build_array(jsonb_build_object('w', 30, 't', 'Impossible travel speed since the previous delivery')); end if;
    end if;
  end if;
  -- 3. Speed on site, photo reuse, cash, wrong attempts.
  if now() - d.arrived_at < interval '20 seconds' then
    fl := fl || jsonb_build_array(jsonb_build_object('w', 15, 't', 'Completed less than 20 seconds after arrival')); end if;
  if exists (select 1 from public.deliveries x where x.photo_hash = p_photo_hash and x.id <> p_delivery) then
    fl := fl || jsonb_build_array(jsonb_build_object('w', 40, 't', 'This photo was already used on another delivery')); end if;
  if coalesce(p_cod, 0) <> d.cod_amount then
    fl := fl || jsonb_build_array(jsonb_build_object('w', 30, 't', format('Cash mismatch: expected %s, collected %s', d.cod_amount, coalesce(p_cod, 0)))); end if;
  if d.otp_attempts > 0 then
    fl := fl || jsonb_build_array(jsonb_build_object('w', d.otp_attempts * 5, 't', format('%s wrong code attempt(s)', d.otp_attempts))); end if;

  risk := least(100, (select coalesce(sum((f->>'w')::int), 0) from jsonb_array_elements(fl) f));
  update public.deliveries set status = 'delivered', completed_at = now(), done_lat = p_lat, done_lng = p_lng,
         cod_collected = coalesce(p_cod, 0), photo_hash = p_photo_hash, photo_path = p_photo_path,
         flags = fl, risk_score = risk where id = p_delivery;
  return jsonb_build_object('ok', true, 'risk', risk);
end $$;

create function public.rider_unavailable(p_delivery uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update public.deliveries set status = 'failed', completed_at = now(), risk_score = least(100, risk_score + 5),
         flags = flags || jsonb_build_array(jsonb_build_object('w', 5, 't', 'Recipient unavailable'))
   where id = p_delivery and rider_id = auth.uid() and status = 'arrived';
  return jsonb_build_object('ok', found);
end $$;

revoke execute on function public.rider_tasks, public.rider_arrive, public.rider_complete, public.rider_unavailable from public, anon;
grant execute on function public.rider_tasks, public.rider_arrive, public.rider_complete, public.rider_unavailable to authenticated;

-- Private photo storage: riders write only into their own folder; admins, the rider and the merchant can read.
insert into storage.buckets (id, name, public) values ('delivery-photos', 'delivery-photos', false) on conflict do nothing;
create policy "riders upload own photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'delivery-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photo readers" on storage.objects for select to authenticated
  using (bucket_id = 'delivery-photos' and (public.is_admin() or (storage.foldername(name))[1] = auth.uid()::text
    or exists (select 1 from public.deliveries d where d.photo_path = name and d.merchant_id = auth.uid())));

-- ============================================================
-- 005_recipient.sql
-- ============================================================
-- 005_recipient.sql: run after 004_rider.sql. The public tracking page for recipients (no login).
-- The page never touches tables: it only calls these two functions with the private token from the link.
alter table public.deliveries add column recipient_confirmed boolean not null default false;

create function public.recipient_view(p_token text) returns jsonb
language sql security definer set search_path = public stable as $$
  select jsonb_build_object(
    'merchant', coalesce(m.business_name, m.full_name),
    'address', d.address,
    'status', d.status,
    'otp', case when d.status in ('created', 'assigned', 'arrived') then s.otp end,   -- hidden once the drop is over
    'cod', d.cod_amount,
    'rider', split_part(r.full_name, ' ', 1),
    'vehicle', r.vehicle,
    'created_at', d.created_at, 'arrived_at', d.arrived_at, 'completed_at', d.completed_at,
    'confirmed', d.recipient_confirmed,
    'dispute', d.dispute_reason, 'resolved', d.dispute_resolved)
  from public.delivery_secrets s
  join public.deliveries d on d.id = s.delivery_id
  join public.profiles m on m.id = d.merchant_id
  left join public.profiles r on r.id = d.rider_id
  where s.recipient_token = p_token
$$;

create function public.recipient_respond(p_token text, p_action text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.deliveries;
begin
  select d2.* into d from public.deliveries d2
    join public.delivery_secrets s on s.delivery_id = d2.id
   where s.recipient_token = p_token for update of d2;
  if not found then return jsonb_build_object('ok', false, 'message', 'Delivery not found.'); end if;
  if d.status <> 'delivered' then return jsonb_build_object('ok', false, 'message', 'This delivery is not complete yet.'); end if;
  if p_action = 'confirm' then
    if d.dispute_reason is not null then return jsonb_build_object('ok', false, 'message', 'You already sent a report.'); end if;
    update public.deliveries set recipient_confirmed = true where id = d.id;
  elsif p_action = 'report' and p_reason in ('Not received', 'Damaged', 'Wrong item') then
    if d.recipient_confirmed then return jsonb_build_object('ok', false, 'message', 'You already confirmed this delivery.'); end if;
    if d.dispute_reason is not null then return jsonb_build_object('ok', false, 'message', 'You already sent a report.'); end if;
    update public.deliveries set dispute_reason = p_reason, dispute_resolved = false where id = d.id;
  else
    return jsonb_build_object('ok', false, 'message', 'Unknown action.');
  end if;
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function public.recipient_view, public.recipient_respond from public;
grant execute on function public.recipient_view, public.recipient_respond to anon, authenticated;

-- ============================================================
-- 006_customer.sql
-- ============================================================
-- 006_customer.sql: run after 005_recipient.sql. Customer accounts, store catalog and orders.
-- If your SQL editor complains about the next line, run it on its own first, then run the rest.
alter type user_role add value if not exists 'customer';

alter table public.profiles add column category text, add column blurb text;
alter table public.settings add column delivery_fee numeric(8,2) not null default 1.50;

-- Sign-up metadata may now pick customer as well. Admin is still never accepted.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare r text := case new.raw_user_meta_data->>'role' when 'rider' then 'rider' when 'customer' then 'customer' else 'merchant' end;
begin
  insert into public.profiles (id, role, status, full_name, phone, business_name, vehicle)
  values (
    new.id, r::user_role,
    (case when r = 'rider' then 'pending' else 'active' end)::account_status,
    coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'), ''), 'New user'),
    left(new.raw_user_meta_data->>'phone', 30),
    left(new.raw_user_meta_data->>'business', 120),
    left(new.raw_user_meta_data->>'vehicle', 60)
  );
  return new;
end $$;

create table public.products (
  id uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  description text,
  price numeric(10,2) not null check (price >= 0),
  category text,
  available boolean not null default true,
  created_at timestamptz not null default now()
);
create index on public.products (merchant_id);
alter table public.products enable row level security;
create policy "merchants manage own products" on public.products for all to authenticated
  using (merchant_id = auth.uid())
  with check (merchant_id = auth.uid() and exists (select 1 from public.profiles where id = auth.uid() and role = 'merchant'));
create policy "admins read products" on public.products for select using (public.is_admin());

-- Orders become deliveries. The customer pays cash to the rider, so the order total is the delivery's COD amount.
create table public.orders (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.profiles(id),
  merchant_id uuid not null references public.profiles(id),
  delivery_id uuid references public.deliveries(id),
  address text not null, pin_lat double precision, pin_lng double precision,
  phone text, note text,
  subtotal numeric(10,2) not null, delivery_fee numeric(10,2) not null, total numeric(10,2) not null,
  created_at timestamptz not null default now()
);
create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  name text not null, price numeric(10,2) not null, qty int not null check (qty > 0)
);
create index on public.orders (customer_id);
create index on public.orders (merchant_id);
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
create policy "merchants read own orders" on public.orders for select using (merchant_id = auth.uid());
create policy "admins read orders" on public.orders for select using (public.is_admin());
create policy "merchants read own order items" on public.order_items for select
  using (exists (select 1 from public.orders o where o.id = order_id and o.merchant_id = auth.uid()));

create function public.list_stores() returns table (id uuid, name text, category text, blurb text, fee numeric)
language sql security definer set search_path = public stable as $$
  select p.id, coalesce(p.business_name, p.full_name), p.category, p.blurb, (select s.delivery_fee from public.settings s)
  from public.profiles p
  where p.role = 'merchant' and p.status = 'active'
    and exists (select 1 from public.products x where x.merchant_id = p.id and x.available)
  order by 2
$$;

create function public.store_menu(p_store uuid) returns jsonb
language sql security definer set search_path = public stable as $$
  select jsonb_build_object(
    'store', jsonb_build_object('id', p.id, 'name', coalesce(p.business_name, p.full_name), 'category', p.category, 'blurb', p.blurb),
    'fee', (select s.delivery_fee from public.settings s),
    'products', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'description', x.description,
                  'price', x.price, 'category', x.category) order by x.category, x.name), '[]'::jsonb)
                 from public.products x where x.merchant_id = p.id and x.available))
  from public.profiles p where p.id = p_store and p.role = 'merchant' and p.status = 'active'
$$;

-- Prices always come from the database, never from the phone.
create function public.place_order(p_merchant uuid, p_items jsonb, p_address text, p_lat double precision,
  p_lng double precision, p_phone text, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.profiles; d public.deliveries; prd public.products; it jsonb; qty int; sub numeric := 0; fee numeric; tot numeric;
        oid uuid; tok text := replace(gen_random_uuid()::text, '-', '');
begin
  select * into c from public.profiles where id = auth.uid() and role::text = 'customer' and status = 'active';
  if not found then raise exception 'Sign in with a customer account to order'; end if;
  if not exists (select 1 from public.profiles where id = p_merchant and role = 'merchant' and status = 'active') then
    raise exception 'This store is not available'; end if;
  if length(trim(coalesce(p_address, ''))) < 5 then raise exception 'Enter your delivery address'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Your basket is empty'; end if;
  select delivery_fee into fee from public.settings;
  for it in select value from jsonb_array_elements(p_items) loop
    qty := least(greatest(coalesce((it->>'qty')::int, 1), 1), 20);
    select * into prd from public.products where id = (it->>'product_id')::uuid and merchant_id = p_merchant and available;
    if not found then raise exception 'An item in your basket is no longer available'; end if;
    sub := sub + prd.price * qty;
  end loop;
  tot := sub + fee;
  insert into public.deliveries (merchant_id, address, recipient_name, recipient_phone, cod_amount, pin_lat, pin_lng, status)
  values (p_merchant, trim(p_address), c.full_name, coalesce(nullif(trim(p_phone), ''), c.phone), tot, p_lat, p_lng, 'created')
  returning * into d;
  insert into public.delivery_secrets values (d.id, lpad(floor(random() * 10000)::int::text, 4, '0'), tok);
  insert into public.orders (customer_id, merchant_id, delivery_id, address, pin_lat, pin_lng, phone, note, subtotal, delivery_fee, total)
  values (c.id, p_merchant, d.id, trim(p_address), p_lat, p_lng, nullif(trim(p_phone), ''), left(p_note, 300), sub, fee, tot)
  returning id into oid;
  for it in select value from jsonb_array_elements(p_items) loop
    qty := least(greatest(coalesce((it->>'qty')::int, 1), 1), 20);
    insert into public.order_items (order_id, product_id, name, price, qty)
      select oid, x.id, x.name, x.price, qty from public.products x where x.id = (it->>'product_id')::uuid;
  end loop;
  return jsonb_build_object('order_id', oid, 'total', tot);
end $$;

create function public.my_orders() returns jsonb language sql security definer set search_path = public stable as $$
  select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc), '[]'::jsonb) from (
    select r.id, coalesce(m.business_name, m.full_name) as merchant, d.status as dstatus,
           r.total, r.subtotal, r.delivery_fee as fee, r.address, r.created_at,
           (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'qty', i.qty, 'price', i.price)), '[]'::jsonb)
              from public.order_items i where i.order_id = r.id) as items,
           case when d.status in ('created', 'assigned', 'arrived') then s.otp end as otp,
           split_part(rd.full_name, ' ', 1) as rider, rd.vehicle,
           case when d.status in ('assigned', 'arrived') then rd.phone end as rphone,
           d.recipient_confirmed as confirmed, d.dispute_reason as dispute, d.dispute_resolved as resolved, d.completed_at
    from public.orders r
    join public.profiles m on m.id = r.merchant_id
    left join public.deliveries d on d.id = r.delivery_id
    left join public.delivery_secrets s on s.delivery_id = d.id
    left join public.profiles rd on rd.id = d.rider_id
    where r.customer_id = auth.uid()
    order by r.created_at desc limit 50
  ) o
$$;

create function public.customer_respond(p_order uuid, p_action text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.deliveries;
begin
  select dl.* into d from public.deliveries dl join public.orders r on r.delivery_id = dl.id
   where r.id = p_order and r.customer_id = auth.uid() for update of dl;
  if not found then return jsonb_build_object('ok', false, 'message', 'Order not found.'); end if;
  if d.status <> 'delivered' then return jsonb_build_object('ok', false, 'message', 'This order is not delivered yet.'); end if;
  if p_action = 'confirm' then
    if d.dispute_reason is not null then return jsonb_build_object('ok', false, 'message', 'You already sent a report.'); end if;
    update public.deliveries set recipient_confirmed = true where id = d.id;
  elsif p_action = 'report' and p_reason in ('Not received', 'Damaged', 'Wrong item') then
    if d.recipient_confirmed then return jsonb_build_object('ok', false, 'message', 'You already confirmed this order.'); end if;
    if d.dispute_reason is not null then return jsonb_build_object('ok', false, 'message', 'You already sent a report.'); end if;
    update public.deliveries set dispute_reason = p_reason, dispute_resolved = false where id = d.id;
  else
    return jsonb_build_object('ok', false, 'message', 'Unknown action.');
  end if;
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function public.list_stores, public.store_menu, public.place_order, public.my_orders, public.customer_respond from public;
grant execute on function public.list_stores, public.store_menu to anon, authenticated;
grant execute on function public.place_order, public.my_orders, public.customer_respond to authenticated;

-- ============================================================
-- 007_menu.sql
-- ============================================================
-- 007_menu.sql: run after 006_customer.sql. Lets a merchant choose their store category and tagline.
-- (Menu items themselves are edited directly in the products table, which merchants already own through row level security.)
create function public.update_store_profile(p_category text, p_blurb text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_category is not null and p_category not in ('Food', 'Groceries', 'Pharmacy', 'Electronics', 'Other') then
    raise exception 'Pick a category from the list'; end if;
  update public.profiles set category = p_category, blurb = nullif(left(trim(coalesce(p_blurb, '')), 120), '')
   where id = auth.uid() and role = 'merchant' and status = 'active';
  if not found then raise exception 'Only active merchant accounts can edit a store'; end if;
end $$;

revoke execute on function public.update_store_profile from public, anon;
grant execute on function public.update_store_profile to authenticated;
