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
