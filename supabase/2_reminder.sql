-- =====================================================================
-- Office Meal Tracker: 8:30 am reminder (OPTIONAL, set up after the app works)
-- Before running: replace the two placeholders marked <<< >>> below.
-- Run in Supabase: SQL Editor > New query > paste > Run.
-- =====================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Private settings (this schema is not reachable from the app or the internet API).
create schema if not exists private;
create table if not exists private.reminder_config (
  id           int primary key default 1 check (id = 1),
  function_url text not null,
  cron_secret  text not null
);

insert into private.reminder_config (id, function_url, cron_secret)
values (
  1,
  '<<<FUNCTION_URL>>>',   -- e.g. https://abcdefghijkl.supabase.co/functions/v1/meal-reminder
  '<<<CRON_SECRET>>>'     -- the same long random text you saved as the CRON_SECRET function secret
)
on conflict (id) do update
  set function_url = excluded.function_url, cron_secret = excluded.cron_secret;

-- Collects the phones of active people who have not answered today and
-- asks the edge function to notify them.
-- Friday and Saturday: only sends if somebody has already said Yes
-- (so ordinary weekends stay quiet, but weekend office days still get a reminder).
create or replace function private.send_meal_reminder() returns text
language plpgsql security definer set search_path = public, private as $$
declare
  cfg       private.reminder_config%rowtype;
  v_today   date := (now() at time zone 'Asia/Dhaka')::date;
  v_dow     int  := extract(dow from v_today);   -- 5 = Friday, 6 = Saturday
  v_targets jsonb;
begin
  select * into cfg from private.reminder_config where id = 1;
  if cfg.function_url is null then return 'no config'; end if;

  -- forget phones that have not opened the app for 90 days
  delete from push_subscriptions where updated_at < now() - interval '90 days';

  if v_dow in (5, 6) and not exists
     (select 1 from votes where day = v_today and meals > 0) then
    return 'weekend, nobody voted yes: skipped';
  end if;

  select coalesce(jsonb_agg(s.endpoint), '[]'::jsonb) into v_targets
  from push_subscriptions s
  join profiles p on p.id = s.user_id and p.active
  where not exists (select 1 from votes v where v.user_id = s.user_id and v.day = v_today);

  if jsonb_array_length(v_targets) = 0 then return 'nobody to remind'; end if;

  perform net.http_post(
    url     := cfg.function_url,
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-cron-secret', cfg.cron_secret),
    body    := jsonb_build_object('endpoints', v_targets),
    timeout_milliseconds := 20000
  );
  return 'sent to ' || jsonb_array_length(v_targets) || ' phone(s)';
end $$;

-- Every day at 08:30 Dhaka time (= 02:30 UTC; cron runs on UTC).
select cron.unschedule('meal-reminder-0830')
 where exists (select 1 from cron.job where jobname = 'meal-reminder-0830');
select cron.schedule('meal-reminder-0830', '30 2 * * *',
                     $$ select private.send_meal_reminder(); $$);

-- To test right now (sends to everyone who has not answered today):
--   select private.send_meal_reminder();
