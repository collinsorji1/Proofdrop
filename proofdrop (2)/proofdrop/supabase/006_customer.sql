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
