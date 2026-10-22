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
