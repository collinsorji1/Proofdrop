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
