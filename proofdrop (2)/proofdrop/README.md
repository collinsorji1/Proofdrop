# ProofDrop

A last-mile delivery verification platform. Every delivery is checked for the right place, the right person, the right parcel and the right amount of cash. Six small apps share one database.

```
proofdrop/
  config.js            <- your Supabase URL and key, set ONCE
  index.html           Landing page, sign-up and sign-in for merchants and riders
  app/                 Customer app: browse stores, order, track, see the rider
  merchant/            Merchant dashboard: deliveries, menu editor, disputes, cash on delivery
  rider/               Rider app (installable): check-in, code, photo, cash
  admin/               Admin dashboard: revenue, rider approvals, fraud queue, settings
  track/               Public tracking page for anyone who only has a link
  supabase/
    setup_all.sql      The whole database, in one file
    seed_catalog.sql   Optional: sample menus so the customer app has stores
    seed_sample.sql    Optional: sample deliveries so the admin dashboard has data
```

## Go live (about 20 minutes)
1. **Create a free project** at supabase.com.
2. **Run the database.** SQL Editor, paste all of `supabase/setup_all.sql`, run it once. (If the editor complains about the `alter type` line near the end, run that one line on its own first, then the rest.)
3. **Add your keys.** Open `config.js` and paste the Project URL and the `anon public` key (Project Settings > API). Every app reads this one file.
4. **Set the redirect.** Authentication > URL Configuration: set Site URL to wherever you will host the folder.
5. **Host the whole folder** over HTTPS on any static host (Netlify Drop, Cloudflare Pages, Vercel). HTTPS is required for location, camera and "Add to Home Screen".
6. **Make yourself the admin.** Sign up on the landing page as a merchant, then in the SQL editor run:
   `update public.profiles set role='admin' where id=(select id from auth.users where email='you@example.com');`
   Then sign in again. The landing page sends you to `/admin/`.
While testing, turn email confirmation off (Authentication > Providers > Email) so sign-ups work instantly.
With `config.js` left empty, every app runs in preview mode with sample data and saves nothing.

## Try the whole journey
1. Sign up as a **rider** (landing page) and as a **merchant** (use two browsers or a private window).
2. In `/admin/`, open **Riders** and approve the rider.
3. In `/merchant/`, open **Menu**, choose a category and add a few items (or run `supabase/seed_catalog.sql` for sample menus). Then open `/app/`, create a **customer** account and place an order.
4. In `/merchant/`, open the new delivery (it shows the items ordered) and assign the rider.
5. On a phone, open `/rider/`, check in at the address, enter the customer's code, take a photo, and complete it.
6. Back in `/app/`, watch the order move live, then confirm it or report a problem.
7. In `/admin/`, see the revenue and any flags the checks raised.
The merchant can also create a delivery by hand and send the customer the `/track/` link on WhatsApp.

## How the pieces connect
Customer orders and merchant-created deliveries both become rows in one `deliveries` table. Merchants create and assign them, riders complete them, customers and recipients watch them, and the admin sees everything. Handoff codes live in a table nobody can read directly.

## What is enforced in the database
All of this was tested on a real Postgres:
- Sign-ups can only become merchant, rider or customer. Nobody can make themselves admin. Riders start pending until approved.
- The distance check, code (3 tries), photo reuse, cash match, time on site and travel speed all run in the database, so a phone cannot report its own risk score.
- Riders never see the drop-off pin or the handoff code. Merchants never see another merchant's data. Customers only see their own orders. Order prices come from the database, not the phone.
- Only admins can change settings, approve riders or clear flags.

## Before real users
- Add a **privacy policy and terms** page. You collect phone numbers, locations and photos of doors.
- Set up a **custom email sender** in Supabase so confirmation emails come from your domain.
- Decide how you **verify riders**. Right now an admin approval is the only gate.
- Handoff codes are shared by link. To send them automatically you need an **SMS or WhatsApp provider**.

## Known limits
- A web app cannot detect fake-GPS apps (a native app can). Photo reuse only catches the identical file, not a re-shot scene.
- Payment is cash on delivery only. Card payments need a provider such as Paystack, Flutterwave or Stripe.
- Riders are assigned by hand, not automatically.
- The rider app opens offline but needs a connection to check in and complete, because the checks run on the server.
