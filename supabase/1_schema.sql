-- =====================================================================
-- Office Meal Tracker: database setup
-- Run this ONCE in Supabase: SQL Editor > New query > paste > Run.
-- The FIRST person who signs up in the app becomes the permanent owner.
-- =====================================================================

-- ---------- Tables ----------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text not null default '',
  role       text not null default 'member' check (role in ('owner','admin','member')),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.votes (
  user_id      uuid not null references public.profiles(id) on delete cascade,
  day          date not null,
  meals        int  not null check (meals between 0 and 50),  -- 0 = "not eating"
  admin_edited boolean not null default false,
  edited_by    uuid references public.profiles(id) on delete set null,
  updated_at   timestamptz not null default now(),
  primary key (user_id, day)
);
create index if not exists votes_day_idx on public.votes(day);

create table if not exists public.month_rates (
  month      date primary key check (extract(day from month) = 1),
  rate       numeric(10,2) not null check (rate >= 0),
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table if not exists public.payments (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  month      date not null check (extract(day from month) = 1),
  paid       boolean not null default false,
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (user_id, month)
);

create table if not exists public.push_subscriptions (
  endpoint   text primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  p256dh     text not null default '',
  auth       text not null default '',
  updated_at timestamptz not null default now()
);

-- ---------- Time helpers (everything runs on Dhaka time) ----------
create or replace function public.dhaka_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Dhaka')::date $$;

-- Voting window: 08:00 up to (not including) 11:30, Dhaka time.
create or replace function public.poll_open() returns boolean
language sql stable as $$
  select (now() at time zone 'Asia/Dhaka')::time >= time '08:00'
     and (now() at time zone 'Asia/Dhaka')::time <  time '11:30'
$$;

-- ---------- Role helpers ----------
create or replace function public.is_active() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active)
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles
                 where id = auth.uid() and active and role in ('owner','admin'))
$$;

create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles
                 where id = auth.uid() and active and role = 'owner')
$$;

-- ---------- New sign-up -> profile (first user becomes owner) ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, role)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
             split_part(new.email, '@', 1)),
    case when not exists (select 1 from public.profiles) then 'owner' else 'member' end
  );
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Row level security ----------
alter table public.profiles           enable row level security;
alter table public.votes              enable row level security;
alter table public.month_rates        enable row level security;
alter table public.payments           enable row level security;
alter table public.push_subscriptions enable row level security;  -- no policies: RPC only

drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_active());

drop policy if exists votes_read on public.votes;
create policy votes_read on public.votes for select to authenticated
  using (public.is_active());

drop policy if exists rates_read on public.month_rates;
create policy rates_read on public.month_rates for select to authenticated
  using (public.is_active());
drop policy if exists rates_write on public.month_rates;
create policy rates_write on public.month_rates for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Payment status: each person sees only their own; admins see everyone.
drop policy if exists payments_read on public.payments;
create policy payments_read on public.payments for select to authenticated
  using ((user_id = auth.uid() and public.is_active()) or public.is_admin());
drop policy if exists payments_write on public.payments;
create policy payments_write on public.payments for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Profiles and votes are changed only through the functions below,
-- so the 08:00-11:30 lock cannot be bypassed from a phone or browser.

-- ---------- Voting ----------
create or replace function public.cast_vote(p_meals int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_active() then raise exception 'NOT_ACTIVE'; end if;
  if not poll_open() then raise exception 'POLL_CLOSED'; end if;
  if p_meals is null or p_meals < 0 or p_meals > 10 then raise exception 'BAD_COUNT'; end if;
  insert into votes (user_id, day, meals, admin_edited, edited_by, updated_at)
  values (auth.uid(), dhaka_today(), p_meals, false, null, now())
  on conflict (user_id, day) do update
    set meals = excluded.meals, admin_edited = false, edited_by = null, updated_at = now();
end $$;

create or replace function public.remove_vote() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_active() then raise exception 'NOT_ACTIVE'; end if;
  if not poll_open() then raise exception 'POLL_CLOSED'; end if;
  delete from votes where user_id = auth.uid() and day = dhaka_today();
end $$;

-- Admin correction for any member, today or any past day.
-- p_meals = null clears the entry. Corrections are flagged "edited by admin".
create or replace function public.admin_set_vote(p_user uuid, p_day date, p_meals int)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  if p_day > dhaka_today() then raise exception 'FUTURE_DAY'; end if;
  if p_meals is null then
    delete from votes where user_id = p_user and day = p_day;
    return;
  end if;
  if p_meals < 0 or p_meals > 50 then raise exception 'BAD_COUNT'; end if;
  insert into votes (user_id, day, meals, admin_edited, edited_by, updated_at)
  values (p_user, p_day, p_meals, true, auth.uid(), now())
  on conflict (user_id, day) do update
    set meals = excluded.meals, admin_edited = true, edited_by = auth.uid(), updated_at = now();
end $$;

-- ---------- Profile and people ----------
create or replace function public.update_my_name(p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if length(trim(coalesce(p_name, ''))) < 1 then raise exception 'BAD_NAME'; end if;
  update profiles set full_name = left(trim(p_name), 60) where id = auth.uid();
end $$;

-- Admin view of members, including email (emails are hidden from ordinary members).
create or replace function public.admin_members()
returns table (id uuid, full_name text, email text, role text, active boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  return query
    select p.id, p.full_name, u.email::text, p.role, p.active, p.created_at
    from profiles p join auth.users u on u.id = p.id
    order by p.created_at desc;
end $$;

-- Remove (or restore) a member. Their past meals stay in the records.
create or replace function public.admin_set_active(p_user uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_role text;
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  select role into v_role from profiles where id = p_user;
  if v_role is null then raise exception 'NOT_FOUND'; end if;
  if v_role = 'owner' then raise exception 'OWNER_PROTECTED'; end if;
  if v_role = 'admin' and not is_owner() then raise exception 'OWNER_ONLY'; end if;
  update profiles
     set active = p_active,
         role   = case when p_active then role else 'member' end
   where id = p_user;
  if not p_active then
    delete from push_subscriptions where user_id = p_user;
  end if;
end $$;

-- Owner hands the admin role to someone (p_user = null: nobody is admin).
create or replace function public.owner_set_admin(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_owner() then raise exception 'OWNER_ONLY'; end if;
  update profiles set role = 'member' where role = 'admin';
  if p_user is not null then
    update profiles set role = 'admin'
     where id = p_user and role = 'member' and active;
    if not found then raise exception 'NOT_FOUND'; end if;
  end if;
end $$;

-- ---------- Phone notifications ----------
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_active() then raise exception 'NOT_ACTIVE'; end if;
  if p_endpoint is null or p_endpoint not like 'https://%' then raise exception 'BAD_ENDPOINT'; end if;
  insert into push_subscriptions (endpoint, user_id, p256dh, auth, updated_at)
  values (p_endpoint, auth.uid(), coalesce(p_p256dh, ''), coalesce(p_auth, ''), now())
  on conflict (endpoint) do update
    set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth, updated_at = now();
end $$;

create or replace function public.delete_push_subscription(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;

-- ---------- Permissions ----------
revoke execute on all functions in schema public from public, anon;
grant  execute on all functions in schema public to authenticated;
