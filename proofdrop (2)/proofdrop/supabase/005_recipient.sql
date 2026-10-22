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
