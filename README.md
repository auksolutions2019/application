# First Choice Laptops – Stock Manager

Stock, sales and money app for First Choice Laptops (Auk Solutions), R.T Nagar, Bengaluru. It covers:

- lots with several model lines and QR stickers
- tests, parts and repairs
- sales with exchange, booking and part payment
- service partners
- suppliers, liabilities and shop expenses
- reports

Admin, co-admin and staff each log in with their own mobile number and 6-digit PIN, and all phones share live data.

- **Front end:** plain HTML, CSS and JavaScript (ES modules, no build step), hosted on Cloudflare Pages from the private GitHub repo.
- **Back end:** Supabase (Postgres with Row Level Security, database functions, Realtime, Auth, three Edge Functions).
- **Photos:** Cloudinary (unsigned upload preset).

Setup takes about 30 minutes. Do the steps in this order.

---

## 1. Create the Supabase project

1. Sign in at **supabase.com** with the dealer's account.
2. Click **New project**:
   - Name: `first-choice-laptops`
   - Region: **South Asia (Mumbai)**
   - Plan: Free
   - Database password: make a strong one and keep it in a password manager (the app never uses it).
3. Wait about 2 minutes until the project is ready.

## 2. Create the database (one file)

1. Open **SQL Editor**, then **New query**.
2. Open `supabase/setup_all.sql` from this repo, copy **all** of it, paste it in, and click **Run**.
3. The last result shows two numbers: `tables` and `tables_with_rls_on`. They must be the same (39 and 39). That means every table has its access rules on.

**If the SQL Editor says the query is too big:** use the three parts instead. Paste `supabase/setup_part1.sql` into a new query and click **Run**. Do the same with `setup_part2.sql`, then `setup_part3.sql`, each in a new query, in that order. Part 3 ends with the same check (39 and 39). Together they are exactly the same SQL as `setup_all.sql`.

**After an app update that changes the database** (for example the accessories and notifications update): run the setup again (all of it, or the three parts). It upgrades the existing database and keeps all data.

The file is safe to run again; every step checks first. Do not edit it by hand: it is built from `supabase/migrations/` with `node tools/build-setup.mjs`.

## 3. Auth settings

1. Under **Authentication → Sign In / Providers**:
   - **Email** must be on (the PIN is the password of a hidden email login).
   - Turn **off** "Allow new users to sign up", so nobody can create their own login.
   - Turn **off** "Confirm email".
2. Under **Database → Publications → supabase_realtime**, check that the table **sync_ticks** is ticked (setup_all.sql adds it). This is what makes a sale on one phone show on the other.

## 4. Deploy the five Edge Functions

These handle the PIN login with its 5-try lock, PIN changes, user management, the public warranty check behind the QR on bills, and deleting photos from Cloudinary. They are the only place the service key is used, and it stays inside Supabase.

**Option A – Supabase CLI** (Windows PowerShell, inside this project folder; needs Node.js):

```
npx supabase login
npx supabase link --project-ref YOUR-PROJECT-REF
npx supabase functions deploy auth-login --no-verify-jwt --use-api
npx supabase functions deploy change-pin --no-verify-jwt --use-api
npx supabase functions deploy admin-users --no-verify-jwt --use-api
npx supabase functions deploy warranty-check --no-verify-jwt --use-api
npx supabase functions deploy photo-delete --no-verify-jwt --use-api
```

- `supabase login` opens the browser: sign in with the dealer's Supabase account.
- The project ref is the part of the Project URL before `.supabase.co`. It is also under **Project Settings → General**.
- `--no-verify-jwt` is needed because each function checks the caller itself, and the login function is called before anyone is logged in.

**Option B – Dashboard:** **Edge Functions → Deploy a new function → Via Editor**. Do this once for each of `auth-login`, `change-pin`, `admin-users`, `warranty-check` and `photo-delete`:
1. Use the folder name as the function name.
2. Paste the file `supabase/functions/<name>/index.ts`.
3. Click **Deploy**.
4. In the function's **Settings**, turn **off** "Verify JWT".

## 5. Set the secrets

Supabase already gives the functions `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY`; nothing to add for those. One optional secret limits which website may call the functions:

```
npx supabase secrets set APP_ORIGIN=https://first-choice-laptops.pages.dev
```

You can also add it in the dashboard: **Edge Functions → Secrets**, name `APP_ORIGIN`. Use the site address from step 8. If you skip this, any site may call the functions; the PIN lock and role checks still apply.

**Cloudinary secrets (for deleting photos).** `photo-delete` needs three secrets. They go only into Supabase, never into the app or this repo:

1. Sign in at **cloudinary.com**. On the **Dashboard** (Home), or under **Settings (gear) → API Keys**, you see the **Cloud name**, the **API Key** and the **API Secret** (click the eye or *Reveal* to see the secret).
2. In Supabase: **Edge Functions → Secrets → Add new secret**, three times:
   - `CLOUDINARY_CLOUD_NAME` = the cloud name (the same one entered in the app's Settings → Photos)
   - `CLOUDINARY_API_KEY` = the API key (digits)
   - `CLOUDINARY_API_SECRET` = the API secret
3. Click **Save**. Nothing needs redeploying.

Without them, deleting a photo still removes it from the app; the Cloudinary copy stays and Activity says so.

Another optional secret is `LOGIN_EMAIL_DOMAIN` (default `fcl.local`). It is the domain of the hidden login emails. Change it only if Supabase refuses `fcl.local`, and use the same domain in step 6.

## 6. Create Ayan as the first admin (once)

1. Under **Authentication → Users → Add user → Create new user**, enter:
   - **Email:** `91` + Ayan's 10-digit mobile + `.` + any 8 letters or digits + `@fcl.local`. For example, `919916876350.k3x9p2qa@fcl.local`. The random part keeps the login private; nobody ever types this email.
   - **Password:** Ayan's 6-digit PIN.
   - Tick **Auto Confirm User**, then create the user.
2. Copy the new user's **UID**.
3. In the **SQL Editor**, run this with the UID, the name and the 10-digit mobile:
   ```sql
   select public.bootstrap_first_admin('PASTE-UID-HERE', 'Ayan', '9916876350');
   ```
   It answers "Admin Ayan created". It refuses to run once an admin exists.
4. Everyone else (Raheem, workers) is added later from the app: **More → Users → Add a user**. There you pick the role: Co-admin or Staff.

### 6b. Add an extra admin from the SQL Editor (private)

Some admin logins are added straight from the SQL Editor, so their mobile number and PIN never appear in the app or in this repo.

- **The file:** `supabase/private/add_admin.sql` is on the developer's computer only. The folder is in `.gitignore`, so it never goes to GitHub.
- **Run it:**
  1. Open it, copy all of it, paste it into the **SQL Editor** and click **Run**. This must be after step 2.
  2. The answer reads "Added Admin as admin …".
  3. If the mobile already has a login, it answers "Nothing done …" and changes nothing. That makes it safe to run twice.
- **Then:**
  1. **Delete the file** from the computer, so the PIN is not left lying around.
  2. Log in on the phone with that mobile and PIN, and **change the PIN at once**: More → Change my PIN.

For any later admin, type this in the SQL Editor (never save it in a file in this repo):

```sql
select private.admin_add_user_sql('Name', '9XXXXXXXXX', '0XXXXX', 'admin');
```

- **Values:** the 10-digit mobile and the 6-digit PIN.
- **Quotes:** keep the PIN in quotes, so a leading 0 is not lost.
- **Role:** `'admin'`, `'coadmin'` or `'staff'`.

The function creates the Supabase Auth user. The hidden email has a random part, and the PIN is stored only as a bcrypt hash. It also creates the profile, and refuses a mobile that already has a login. Only the SQL Editor can run it; the app cannot. If Supabase ever refuses writing to its auth tables from SQL, add the person from the app instead: **More → Users**.

## 7. Put the Project URL and key into `config.js`

Under **Project Settings → API**, copy the **Project URL** and the **anon public** key (or the **publishable** key), and put them into `config.js`:

```js
window.FCL_CONFIG = {
  SUPABASE_URL: 'https://YOUR-PROJECT-REF.supabase.co',
  SUPABASE_ANON_KEY: 'eyJ... or sb_publishable_...'
};
```

These two values are public by design: Row Level Security protects the data. **Never** put the `service_role` or secret key in `config.js`, in this repo, or anywhere in the app. Commit and push the change.

## 8. Publish on Cloudflare Pages (free, the GitHub repo stays private)

Cloudflare Pages publishes the app straight from the private GitHub repo, on every push to `main`. It publishes only the app's own files: `docs/`, `tests/`, `supabase/`, `prototype/` and `tools/` stay private. The copy step is in `tools/pages-build.sh`.

1. Go to **dash.cloudflare.com** and sign up or sign in with the dealer's email. The Free plan is enough.
2. In the left menu, open **Workers & Pages**, then click **Create**. Choose the **Pages** tab, then **Connect to Git**.
3. Click **Connect GitHub**. A GitHub window opens: sign in as **auksolutions2019**, choose **Only select repositories**, pick **auksolutions2019/application**, then click **Install & Authorize**.
4. Back in Cloudflare, select the **application** repository and click **Begin setup**.
5. Fill in the build settings exactly:
   - **Project name:** `first-choice-laptops` (this becomes the address `https://first-choice-laptops.pages.dev`; if the name is taken, Cloudflare adds a few letters, so use the address it shows)
   - **Production branch:** `main`
   - **Framework preset:** None
   - **Build command:** `bash tools/pages-build.sh`
   - **Build output directory:** `dist`
   - **Environment variables:** none
6. Click **Save and Deploy**. After about a minute it shows **Success** and the site address.
7. Open the address on each phone, log in, and use **Add to Home screen** (Android: Chrome menu ⋮ → Add to Home screen / Install app).
8. Go back to step 5 of this README and set `APP_ORIGIN` to this exact address, with no slash at the end, for example `https://first-choice-laptops.pages.dev`.

From now on, every `git push` to `main` updates the site by itself in about a minute. Cloudflare's **Deployments** list shows each one and can roll back to an earlier one.

**Optional:**
- **Own domain:** in the Pages project, **Custom domains → Set up a custom domain**, for example `stock.firstchoicelaptops.in`. If you add one, set `APP_ORIGIN` to it.
- **Preview sites:** pushes to other branches get their own preview address. They use the same Supabase project, so test there with care, or turn them off under **Settings → Builds → Branch control**.

The live camera scanner needs https, which Cloudflare Pages gives.

## 9. Daily keep-alive ping

Free Supabase projects pause after 7 days without use. The GitHub Actions workflow `.github/workflows/keepalive.yml` calls the database once a day (09:00 India time).

- It reads the URL and key from `config.js`, so there is nothing to set up after step 7.
- Check it once: on GitHub go to **Actions → Keep Supabase awake → Run workflow**. It should finish green and print `"ok 1"`.
- If GitHub ever shows "This scheduled workflow is disabled", click **Enable workflow**.

## 10. Bills (invoice) and the warranty QR

In the app, under **More → Settings → Bill (invoice)**, set these (they are saved in Supabase):

- **Logo:** leave it empty to use the First Choice logo, or upload another one (it goes to Cloudinary, so do step 11 first).
- **Print in black and white:** on by default.
- **Business name on bills and email.** The address and phone come from Shop details.
- **Next invoice number:** `58` (the dealer's last paper bill was INV-57). Numbers come from a counter in the database, so two phones never get the same one.
- **Default warranties:** laptop, and charger and battery (12 months).
- **Payment instructions:** bank name, account holder, account number, IFSC.

**Every bill:**
- It gets the next INV number and a warranty QR next to each laptop's warranty text.
- The QR opens `https://<your site>/w/?t=<code>`. That page shows only the business, invoice number, laptop, sticker code, bill date and warranty status. It never shows the customer, mobile, price or payments.
- Warranty end dates count from the bill date.
- Scanning that QR in the app's Scan screen opens the laptop.
- The WhatsApp bill carries the same check link.

Sales imported from the Excel get no invoice number; they get one the first time their bill is printed.

**The bill design** is the dealer's own invoice. Bills are A4 only; there is no thermal receipt. In the laptop pop-up, after a sale:
- **Print bill:** black and white, for the A4 printer (when "Print in black and white" is on).
- **Bill PDF (colour):** the colour version. In the print screen choose **Save as PDF**, then share that PDF on WhatsApp or keep it.
- **Send bill on WhatsApp:** sends the bill as a text message with the warranty check link.

Without an uploaded logo, the bill uses the First Choice logo, which already carries the name. An uploaded logo gets the business name printed beside it. The signature line reads "For," followed by the business name in capitals, e.g. "For, FIRST CHOICE LAPTOPS".

**Notes:**
- Every payment and expense has an optional **Note**, next to Ref / UTR, saved in Supabase.
- The admin can change a note later by tapping ✎. The amount can never change, and the old note is kept in Activity.

## 11. Photos (Cloudinary)

1. Create a free account at cloudinary.com with the dealer's email. The **cloud name** is on the dashboard.
2. Go to **Settings → Upload → Upload presets → Add upload preset**. Set **Signing mode: Unsigned** and save.
3. In the app: **More → Settings → Photos**. Enter the cloud name and the preset name.

Photos are shrunk to 1600 px (JPEG quality 0.8) on the phone before upload. Only the photo links are stored in Supabase.

## 12. Bring in the old data (one time, before anything else)

Log in as Ayan, then **More → Backup and import → Bring in old data**:

- **Dealer's Excel** (`.xlsx` with Lot Entry, Expenses and Sales). The app shows a full preview before saving:
  - totals compared with the Excel Dashboard
  - flagged dates, with a choice for each
  - the 3 "wc" tab sales, with a choice of lot 12 or 13
  - possible double entries, with "remove one"
  - every customer name, set as dealer, walk-in or old customer
  - a numbered list of every assumption

  Nothing is saved until **Import**. The import runs only once, on an empty database.
- **Old one-page app backup** (`.json` from the prototype's Backup screen). It keeps the codes, dates, payments, bookings, returns and the activity log.

After that, use **Download backup** every week. **Restore** replaces all business data with a backup file; you type RESTORE to confirm. Users and PINs are never touched.

---

## 13. Export (More → Backup and import → Export)

- **Who:** the admin gets every format; the co-admin gets Excel and CSV only, without costs, profit, supplier money or debts; staff get no export.
- **Excel (.xlsx):** one sheet per table, with a bold, frozen header, amounts in ₹ as numbers, real dates (DD-MM-YYYY) and a totals row.
- **CSV (.zip):** one file per table, for other software.
- **SQL (.sql):** a full backup that loads into a new Supabase project. Run `setup_all.sql` (or parts 1 to 3) first, then this file, then create the admin again (step 6). It has no logins, PINs or secrets.
- **JSON:** the backup that this app's Restore reads.
- **Options:** a date range (applies to sales, payments, expenses, service jobs and stock movements) and "include deleted items". SQL and JSON are always complete.
- Every export is recorded in Activity. The files contain customer names, mobiles and money: keep them private.

## Roles

| | Admin | Co-admin | Staff |
|---|---|---|---|
| Scan, stock, tests, repairs, photos, service (give / receive) | ✓ | ✓ | ✓ |
| Book with advance, sell (all tests must pass) | ✓ (can override tests) | ✓ | ✓ (cannot go below the safe price) |
| Lots, lot expenses, later customer payments, customers, Today's money, reports (no profit), activity, suppliers (no money) | ✓ | ✓ | ✗ |
| Service charges | enter, see, pay | enter only | ✗ |
| Costs, profit, supplier balances, liabilities, shop expenses, Lot P&L, return / undo sale, backup, settings, users | ✓ | ✗ | ✗ |

Everything is enforced in the database (RLS and security-definer functions), not only by hiding buttons. A user who is turned off, or whose PIN login is older than 7 days, can read and change nothing.

## Project layout

```
index.html, app.js, config.js, config.example.js, manifest.webmanifest, sw.js
css/          app.css (the approved prototype's styles + additions), fonts.css
assets/       logo, icons, self-hosted Archivo font
lib/          supabase.js, qrcode, jsQR, html5-qrcode, xlsx (bundled, no CDN), excel-plan.js (Excel import rules)
api/          client.js (calls, errors, offline), auth.js (PIN login), store.js (data + live sync)
ui/           shared pieces: dialogs, charts, printing, spec chips
views/        screens: home, stock, scan, laptop pop-up, people, service, more, reports, backup
w/            public warranty check page (opened by the QR on bills)
supabase/     setup_all.sql (run this), migrations/ (its sources), functions/ (Edge Functions), config.toml
tests/local/  database tests on a local Postgres (PGlite): run.mjs, excel.mjs
tests/ui/     devserver.mjs (local stand-in for Supabase), smoke.mjs (browser test)
prototype/    the approved one-page prototype (the design reference)
tools/        build-setup.mjs (makes setup_all.sql), pages-build.sh (Cloudflare Pages copy step)
docs/PLAN.md  all decisions
```

## Testing on this computer (no Supabase needed)

```
cd tests/local
npm install
node run.mjs           # every database rule, the 9 required tests and more (213 checks)
node unit.mjs          # amount in words (lakh, crore) and warranty dates
node run.mjs --setup   # the same, loading supabase/setup_all.sql twice from empty
node excel.mjs         # the Excel import against the dealer's file and Dashboard totals
```

To try the app in a browser:
1. Run `node tests/ui/devserver.mjs` from the project folder.
2. Open http://localhost:8787 and log in with `9900000001` (admin), `9900000002` (co-admin) or `9900000003` (staff). The PIN is `246810` for all three.

The browser test (`tests/ui/smoke.mjs`) needs `puppeteer-core` and Edge or Chrome; see the top of the file.

After changing anything in `supabase/migrations/`, run `node tools/build-setup.mjs` to rebuild `setup_all.sql`.

When app files change, raise `VERSION` in `sw.js`, so installed phones pick up the new version.
