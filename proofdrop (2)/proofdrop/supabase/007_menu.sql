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
