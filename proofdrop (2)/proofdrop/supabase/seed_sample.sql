-- Optional: fills the admin dashboard with test deliveries.
-- Needs at least one merchant and one APPROVED rider (sign up on the landing page, approve in Admin).
-- Remove later with:  delete from public.deliveries where is_sample;
do $$
declare m uuid[]; r uuid[]; i int; x float; c numeric; st delivery_status; rk int; fl jsonb; t timestamptz;
begin
  select array_agg(id) into m from public.profiles where role = 'merchant';
  select array_agg(id) into r from public.profiles where role = 'rider' and status = 'active';
  if m is null or r is null then raise exception 'Create a merchant and an approved rider first'; end if;
  for i in 1..120 loop
    t := now() - random() * interval '30 days'; x := random();
    c := (array[0,0,25,60,120,185])[1 + floor(random()*6)::int];
    st := 'delivered'; rk := 0; fl := '[]';
    if x < .06 then st := 'failed'; rk := 5; fl := '[{"w":5,"t":"Recipient unavailable"}]';
    elsif x < .14 then rk := 35; fl := '[{"w":35,"t":"Completed 310 m from the drop-off pin"}]';
    elsif x < .18 then rk := 55; fl := '[{"w":40,"t":"This photo was already used on another delivery"},{"w":15,"t":"Completed less than 20 seconds after arrival"}]'; end if;
    insert into public.deliveries (merchant_id, rider_id, address, recipient_name, cod_amount, cod_collected,
      status, risk_score, flags, created_at, arrived_at, completed_at, is_sample)
    values (m[1 + floor(random()*array_length(m,1))::int], r[1 + floor(random()*array_length(r,1))::int],
      (1 + floor(random()*90))::int || ' ' || (array['Palm Ave','Mill Rd','Harbor St','Cedar Way'])[1 + floor(random()*4)::int],
      'Sample recipient', c, case when st = 'delivered' then c end, st, rk, fl, t, t + interval '30 minutes', t + interval '40 minutes', true);
  end loop;
end $$;
