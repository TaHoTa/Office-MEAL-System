# Office Meal Tracker

A phone-first web app for the daily office meal count, in Bangla and English.

| Feature | How it works |
|---|---|
| Daily poll | Opens 8:00 am, locks 11:30 am (Dhaka time), every day. The lock is enforced by the database. |
| Answering | Tap + for a meal, + again for guests (up to 10). "Not eating today" records a No. Answers can be changed or cleared until 11:30. |
| No answer | Counts as no meal. Days where nobody eats stay blank. |
| Calendar | Each person's meals per day, the office total per day, and who ate on any past day. |
| Monthly report | Meals x the month's rate = taka. Admin sees everyone and can download Excel or print/save a PDF. Members see only their own amount and payment status. |
| Corrections | Admin can fix any person's meals for today or a past day. Corrected entries are marked "edited by admin". |
| People | Anyone can join with any email. Admin can remove (and restore) people. New joiners carry a "new" tag for 7 days. |
| Roles | The first person to sign up is the permanent owner. The owner can hand the admin role to one other person and move it later. |
| Reminders | WhatsApp share button with a dated message, plus an optional 8:30 am phone notification to people who have not answered. |

Open `index.html` before any setup and the app runs in **demo mode** with sample data, so you can try every screen first.

## What is in this folder

| File | Purpose |
|---|---|
| `index.html` | The whole app |
| `config.js` | Your Supabase address and key (the only file you must edit) |
| `sw.js`, `manifest.webmanifest`, `icons/` | Lets phones install the app and receive the reminder |
| `vendor/` | Bundled libraries (Supabase client, Excel export) |
| `supabase/1_schema.sql` | Database tables and security rules |
| `supabase/2_reminder.sql` | The 8:30 schedule (Part B) |
| `supabase/functions/meal-reminder/index.ts` | Sends the 8:30 notification (Part B) |
| `setup-keys.html` | One-time key generator for notifications (Part B) |

Supabase and GitHub rename menu items from time to time. If a label below is slightly different on your screen, look for the closest match.

## Part A: get the app live (about 20 minutes)

| Step | Where | What to do |
|---|---|---|
| 1 | supabase.com | Create a free account and a new project. Pick the region closest to Bangladesh (Singapore or Mumbai). Save the database password somewhere safe. |
| 2 | Supabase > SQL Editor | New query, paste everything from `supabase/1_schema.sql`, press Run. It should say "Success". |
| 3 | Supabase > Authentication > Sign In / Providers > Email | Turn **off** "Confirm email". With it on, every new person must click an emailed link, and the free email sender only allows a few emails per hour, so 20 to 30 people joining on day one would get stuck. |
| 4 | Supabase > Project Settings > API Keys (and Data API for the URL) | Copy the **Project URL** and the **Publishable key** (starts with `sb_publishable_`). Paste both into `config.js`. Never use a "secret" key here. |
| 5 | github.com | Create a new **public** repository (for example `office-meal`). Upload every file and folder from this package, keeping the folder structure. |
| 6 | GitHub repo > Settings > Pages | Source: "Deploy from a branch". Branch: `main`, folder `/ (root)`. Save. After a minute or two your app is at `https://YOUR-USERNAME.github.io/office-meal/`. |
| 7 | Supabase > Authentication > URL Configuration | Set **Site URL** to your app address from step 6. This makes "Forgot password" links come back to the app. |
| 8 | Your app | Open the app address and **create your own account first**. The first account becomes the owner. |
| 9 | Your app | Ask your colleague to create an account, then go to People > "Make admin" next to their name. |
| 10 | WhatsApp | Share the app address with the office. People sign up with name, email and password, and stay signed in on their phone. |

The two values in `config.js` are designed to be public. The data is protected by the rules in `1_schema.sql`, not by hiding the key.

### Installing on a phone

| Phone | Steps |
|---|---|
| Android (Chrome) | Open the app > menu (three dots) > "Add to Home screen" or "Install app". |
| iPhone (Safari) | Open the app > Share button > "Add to Home Screen". Required on iPhone for notifications. |

## Part B: the 8:30 am notification (optional, about 20 minutes)

Do this after Part A works. The WhatsApp share button works without it.

| Step | Where | What to do |
|---|---|---|
| 1 | `https://YOUR-USERNAME.github.io/office-meal/setup-keys.html` | Press "Create keys" once. Keep the page open; you need all three values. |
| 2 | GitHub > `config.js` | Paste the VAPID_PUBLIC_KEY value into `VAPID_PUBLIC_KEY` and commit. |
| 3 | Supabase > Edge Functions | Create a new function in the dashboard editor named exactly `meal-reminder`. Replace its code with the contents of `supabase/functions/meal-reminder/index.ts` and deploy. |
| 4 | Same function > Settings/Details | Turn **off** "Verify JWT". The function is protected by its own secret instead. |
| 5 | Supabase > Edge Functions > Secrets | Add four secrets: `CRON_SECRET`, `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` (all from step 1) and `VAPID_SUBJECT` = `mailto:` followed by your email. |
| 6 | `supabase/2_reminder.sql` | Replace `<<<FUNCTION_URL>>>` with `https://YOUR-PROJECT-REF.supabase.co/functions/v1/meal-reminder` and `<<<CRON_SECRET>>>` with the same CRON_SECRET. Paste into the SQL Editor and Run. |
| 7 | Each person's phone | Profile > "Turn on reminder" > Allow. |
| 8 | Supabase > SQL Editor | Test: run `select private.send_meal_reminder();`. Everyone who turned reminders on and has not answered today should get a notification within a few seconds. |

Reminder rules: sent at 8:30 am to people who have not answered. On Friday and Saturday it is sent only if somebody has already answered Yes, so normal weekends stay quiet. Public holidays on weekdays still get one notification.

## Day-to-day admin

| Task | Where |
|---|---|
| Set the month's meal rate | Report > rate box > Save rate. One rate per month; change it whenever needed. |
| Mark someone paid | Report > tap their Unpaid/Paid label. |
| Fix a missed or wrong vote | Today or Calendar > pick the day > pencil button next to the person. |
| Month-end files | Report > pick the month > "Download Excel" or "Print or save PDF" (choose "Save as PDF" in the print window). |
| Remove someone | People > Remove. Their past meals stay in the reports. |
| Move the admin role (owner only) | People > "Make admin" next to the new person. |

## Good to know

| Topic | Note |
|---|---|
| Free plan | Supabase free projects can be paused after a period with no activity. Daily use keeps it awake; if it is ever paused, press "Restore" in the Supabase dashboard. |
| Changing poll times | The times are in two places: `poll_open()` in `1_schema.sql` (the real lock) and `OPEN_MIN` / `LOCK_MIN` near the top of the script in `index.html` (what the screen shows). Change both. |
| Updating the app | Edit files in GitHub; the live app updates in a minute or two. |
| Demo mode | Add `?demo` to the address to see sample data without touching real records. |
