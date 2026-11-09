# First Choice Laptops, Stock Manager: Phase 1 plan

Source of truth: `first-choice-laptops.html` (approved prototype). Same screens, wording, colours, icons and flows. Only the data layer moves to Supabase.

---

## 1. What the prototype does today (summary of the read)

- One HTML file. All data lives in one localStorage object `D` = `{suppliers, batches, laptops, supPay, debts, prices, log, refunds, settings}`.
- A laptop holds everything about itself, nested: `expenses[]` (repairs), `tests{}`, `photos[]`, `sale{…payments[]}`, `reserve{…payments[]}` (booking), `returns[]` (earlier sales that came back).
- Sticker code = `SS-LL-MM-YY-PPP` (supplier, lot no., month, year, piece). Lot prefix = first four parts.
- The cost of a laptop is not stored. It is worked out each time as lot cost ÷ qty. Exchange laptops are the exception: they store their own cost.
- Exchange laptops go to a hidden supplier `00` "Customer exchange", lot `00-01-MM-YY`. A matching supplier payment with method `Exchange` keeps that supplier's balance at zero.
- The PINs are hard-coded (`1111` and `2222`). Roles are only checked in the UI.

## 2. Architecture

```
FirstChoiceLaptops/
  index.html              same markup and CSS as the prototype; loads app.js as a module
  css/app.css             the prototype's <style>, moved out unchanged
  app.js                  starts the app: session, router, dock
  config.example.js       SUPABASE_URL, SUPABASE_ANON_KEY (copy to config.js)
  manifest.webmanifest, sw.js
  assets/                 logo.jpg (taken out of the prototype), icon-192.png, icon-512.png, fonts/Archivo*.woff2
  lib/                    supabase.js (UMD), qrcode.min.js, jsQR.js, html5-qrcode.min.js (all local, no CDN)
  api/                    client.js, auth.js, snapshot.js (load + cache), actions.js (one function per RPC), realtime.js, photos.js
  ui/                     icons.js, dom.js (esc, rs, fmtD, tag…), toast.js, dialog.js, sheet.js, charts.js (the hand-built SVG charts), print.js
  views/                  home, stock, lots, scan, laptop (pop-up with its tabs), customers, suppliers, debts, money, share, prices, activity, settings, backup, reports
  supabase/migrations/    0001_schema.sql, 0002_rls.sql, 0003_rpc.sql, 0004_triggers.sql, 0005_seed.sql
  tests/                  sql tests for the 9 required checks
  README.md
```

**How data flows**
- **Read:** one RPC, `get_snapshot()`, returns all the data the current role may see, as JSON in the same shape the prototype's `D` uses. The view code can then be ported almost line for line, which keeps the risk of behaviour changes low. For admin it includes costs; for co-admin the cost fields are simply not there. A busy shop has a few thousand laptops a year, which is well within a single fetch.
- **What the snapshot skips (agreed 2026-11-07):** sold laptops sold more than 12 months ago **and** fully paid. Anything with money still due always loads. Things that depend on the full history come from the server instead:
  - totals per lot and supplier (counts, money bought and paid, balances, quality score)
  - Reports for the chosen year and the year before: `report_year(year)`
  - Today's money: `money_day(date)`
  - Customers "All" tab: per-customer totals
  - Search: Home and Stock search also ask the server (`search_laptops(q)`)
  - A scanned or typed sticker that isn't loaded is fetched by code (`get_laptop(code)`), so warranty claims on old laptops still open
  - The Stock "Sold" chip counts the last 12 months and has a "Show older" button
  - The activity log loads the latest 300 rows, and older ones load when you scroll
- **Write:** every money or status change goes through one security-definer RPC (one transaction, row lock on the laptop). Simple field edits (model, serial, specs, grade, test note, tests, photos) are plain table writes, allowed by RLS and column grants.
- **Sync:** both phones subscribe to Realtime inserts on `activity_log`. Every write creates a log row through triggers, so that one channel is enough. On a new row the app re-fetches the snapshot (debounced about 0.5 s) and redraws the current screen.
- **Offline:** the last snapshot is cached on the phone, so you can still look at it. Saving is blocked with a clear message and a banner is shown. Every write RPC also takes a `client_ref` uuid, so a double tap or a retry can never create two sales.
- **Dates:** all "today" logic uses Asia/Kolkata, in the database as well as on the phone.

## 2a. Login and users (changed 2026-11-07, replaces "Login as Admin / Co-admin")

**Login screen**
- Logo, then **Mobile number** (+91 shown in front, 10 digits, numeric keypad), then **6-digit PIN** (one masked field, numeric keypad, exactly 6 digits), then **Login**.
- No role dropdown. The role comes from the user's profile after login.
- Same card, colours and styles as the prototype login box.
- The last mobile number is remembered on the phone. Next time it shows as "+91 98xxx xxx50" with a **Not you?** link, and only the PIN needs typing.

**How it works behind the scenes**
- **No SMS auth.** Each user is a Supabase email/password user. The PIN is the password, and the user never sees the email.
- **Hidden email:** `91XXXXXXXXXX.<random 8 chars>@fcl.local`. This is a small change from `91XXXXXXXXXX@fcl.local`, and the reason is in the next point.
- **Why the random part:** the anon key is public (it's in the frontend), so anyone could call Supabase's sign-in endpoint directly. If the email could be worked out from the mobile number, that direct call would skip the 5-wrong-PINs lock. With the random part, the email can only be found through our login function, which always applies the lock.
- **Login goes through the Edge Function `auth-login`.** It looks up the mobile, checks the lock, signs in on the server, and returns the session. The app then calls `supabase.auth.setSession(...)`.
- **Lock:** after 5 wrong PINs, that mobile is blocked for 15 minutes. The function returns `locked_until`, and the login screen counts down: "Too many wrong PINs. Try again in 12:40". The count resets after a correct login. Attempts are kept in `login_attempts(mobile, failed_count, locked_until)`, which only the service role can touch.
- **Generic error:** a wrong mobile and a wrong PIN both say "Wrong mobile number or PIN", so nobody can test which mobiles exist.
- **Public sign-ups are turned off** in Supabase Auth settings, so nobody can register themselves with the anon key. This step is in the README.

**Staying logged in**
- The session is kept on the phone until **Logout**.
- After 7 days the app asks for the PIN again, and logging in creates a fresh session.
- **This is also enforced in the database, not only in the app.** The `my_role()` helper used by every RLS rule and RPC returns nothing if the profile is inactive or the session is older than 7 days. It checks `auth.sessions.created_at` for the token's `session_id`. An old token can read and write nothing.

**`profiles` table**
- `id` (= auth.users.id), `name`, `mobile` (unique, 10 digits), `role` ('admin','coadmin'), `active` (bool), `last_login_at`, `created_at`, `updated_at`.
- A user can read their own row. Admin can read all rows.

**More → Users (admin only)**
- List of users: name, mobile, role, active / off.
- Add a user (name, mobile, role, first PIN), change role, reset PIN, turn off or on.
- All of these go through the Edge Function **`admin-users`**. It checks that the caller is an active admin, then uses the service role key, which lives only in the function's secrets and never in the frontend.
- **Turning a user off** sets `active=false` and also bans them in Auth. They can't log in, their open session stops working at once, and all their history stays.
- **Safety check:** the last active admin can't be turned off or changed to co-admin.

**More → Change my PIN (everyone)**
- Old PIN, new PIN, new PIN again.
- Goes through the Edge Function **`change-pin`**, which checks the old PIN. Wrong old PINs count towards the same 5-try lock.

**Names in the activity log**
- `activity_log` stores `actor_id`, `actor_name` and `actor_role` at the time of the action.
- The Activity screen shows the person's name in the pill instead of "Admin" / "Co-admin". The filter stays Everyone / Admin / Co-admin.
- The header shows "First Choice Laptops, *name*".

**First admin (one time, in the README)**
1. Supabase dashboard → Authentication → Add user. Use email `91<mobile>.<any 8 letters>@fcl.local`, the PIN as the password, and tick auto-confirm.
2. In the SQL editor, run `select bootstrap_first_admin('<user id>', 'Dealer name', '<mobile>');`. This works only while there is no admin yet; after that it refuses.
3. From then on, all users are added from More → Users.

## 2b. Changes from the dealer's Excel (`docs/AUK_Laptop_Business_Manager.xlsx`, added 2026-11-07)

**What's in the file**
- 5 lots (10, 11, 12, 13, 786) on 10 Lot Entry lines, 183 laptops.
- Lot purchase cost ₹3,74,000, plus 50 laptops with no cost (lot 786).
- 37 sale rows covering 45 laptops, worth ₹4,97,400.
- 21 expense rows worth ₹60,900, all tied to lots. There are no shop expenses.
- The report tabs (Dashboard, Lot-wise P&L, Stock, Monthly) **have formulas but no saved values**, so their totals can't be read from this file. The dealer will send the Dashboard totals from the live sheet. In Phase 7 the Excel's own formulas will be used to check the import totals.

### 1. Lot lines
- **New table `lot_lines`:** lot, brand, model, processor, gen, RAM, storage type, storage size, `qty`, `line_cost` (blank = cost missing), `is_mixed`.
- **Laptops** get `line_id`. A laptop's starting brand, model and specs are copied from its line.
- **Cost per laptop** = line cost ÷ line qty. Any leftover paisa goes on the line's last laptop, so totals are always exact.
- **Mixed lot:** one line with `is_mixed = true`, shown as "Mixed". Each laptop's specs are filled in later, at testing or at sale.
- **Add lot form:**
  - header: supplier, date, lot no.
  - "Add line" rows: brand, model, processor, gen, RAM, storage, qty, cost, or a "Mixed lot" switch
  - stickers are made for all lines together, and the piece number runs across the whole lot (`-001…-012`)
- **Lot date:** lots get a full `bought_on` date. The sticker code keeps using its month and year.
- **`set_lot_cost`** becomes `set_line_cost(line_id, cost)`.

### 2. Structured specs
- **Fields on laptops and lot lines:**
  - `brand`: Dell, HP, Lenovo, Acer, Asus, Apple, Other
  - `model`: free text
  - `processor`: i3, i5, i7, i9, Pentium, Celeron, Ryzen 3, Ryzen 5, Ryzen 7, Other
  - `gen`: a number
  - `ram_gb`: 4, 6, 8, 12, 16, 32
  - `storage_type`: SSD or HDD
  - `storage_gb`: a number
  - `brand_other` / `processor_other`: free text, only used when "Other" is picked
- **Quick-pick chips** for each field. Model and storage size are typed, with chips for common sizes (128, 256, 512, 1000).
- **Shorthand shown everywhere**, for example "Dell i5 7th 8/256" ("8/500 HDD" for HDD). It's generated in the database, the same in every screen.
- **Replaces the prototype's free-text "Specs" box** on the laptop pop-up. This is a deliberate change to the approved UI.
- **Search and filters:** search matches the shorthand. Stock "All laptops" gets filter chips for processor, gen, RAM and storage.
- **Model prices and the WhatsApp stock list** use the shorthand. That's how the shop prices laptops (an i5 7th 8/256 sells for the same whatever the model).

### 3. Lot expenses (parts bought in bulk)
- **New table `lot_expenses`:**
  - spent_on, lot, `line_id` (null = all lines), type, count, amount, method, ref, note
  - type is one of: SSD, RAM, Battery, Charger, HDD, Keyboard, Screen, Transport, Repair labour, Other
- **Money out:** they appear in Today's money.
- **Sharing:** an expense is shared equally across the laptops of its line, or of the whole lot when "All" is picked. A sold laptop's profit carries its share.
- **"Applies to" picks a line, not a brand.** In a mixed lot, brands aren't known until testing, and a share that changes later would make profit jump around (the same Excel problem you described). So a brand typed for a mixed lot, like "lenovo charger", is kept as a note only.
- **No double counting:**
  - adding a repair on a laptop gets a "Part from lot stock" option that picks a lot expense with units left
  - that repair costs one unit (amount ÷ count) on that laptop
  - the unit leaves the shared pool, so the shared pool = amount − fitted units
  - the units left are shown ("2 of 4 chargers left")
- **Where:** the lot screen gets an "Add parts / expense" button. Both roles can add; only the admin sees the amounts in profit.

### 4. Shop expenses and net profit
- **New table `shop_expenses`:** spent_on, type (Rent, Electricity, Salary, Internet, Transport, Other), amount, method, ref, note. Added from More → Shop expenses. Admin only, and shown in Today's money.
- **Gross profit** (shown per laptop, lot, month, year) = sale price − laptop cost − lot-expense share − repairs. It's counted in the month the laptop sells.
- **Net profit** (month and year) = gross profit − shop expenses of that month.
- **No double counting with Liabilities:** paying a Liabilities debt of type Shop rent or Bill also counts as a shop expense. Loan and Borrowed payments are not expenses.

### 5. Lead source and customer type
- **On every sale and booking:**
  - `lead_source` (required): OLX, Instagram, Lead Matrix, Circle app, Octo, Walk-in, Old customer, Dealer, Other
  - `customer_type`: Retail or Dealer
- **Name and mobile are optional**, with two exceptions:
  - mobile is required when a warranty is given
  - my addition: mobile is also required when a balance is left unpaid, otherwise the money can't be collected or shown under Customers. Bookings still need a mobile.
- **Without a mobile,** the sale has no customer row and shows the lead source as its name, for example "OLX customer".
- **Dealer sales:** picking Dealer shows chips of known dealers (names from earlier dealer sales). The bulk sale form starts with Dealer selected.
- **New report "Lead sources":** per month, laptops sold, sales ₹ and gross profit (admin) for each source.

### 6. Opening stock
- **`lots.kind`:** 'purchase', 'opening' or 'exchange'.
- **Opening lot:** for stock the shop had before the app. It still has a supplier, for example 786 from AYAN.
- **Cost missing:** with no cost entered, its laptops show "Cost missing" until the admin fills in the line costs.

### 7. Small additions
- **Home (admin), "Stock value":** the cost of every laptop still in stock, with "+N cost missing" next to it.
- **New screen "Lot P&L"** (More, admin): each lot with
  - status: Unsold / Part sold / Sold out
  - sold and left
  - total cost (purchase + lot expenses + repairs)
  - sales, gross profit, margin %

### 8. One-time Excel import (Phase 7)
- **Lots:**
  - each Lot Entry row becomes a lot line, with its laptops and stickers
  - text is cleaned: spaces trimmed, "ascer" → Acer, "pentinum" → Pentium, "3ed" → 3rd, "i5 3ed" → i5 / gen 3, "8/N" → 8 GB / no storage, "mix lot" / "ALL UN LISTED" → Mixed
- **Dates:**
  - a lot date is flagged when it's after the lot's first sale or expense
  - it's also flagged when it's more than 30 days before them and the day and month can be swapped
  - every flag needs your confirm or a corrected date
- **Sales:**
  - one sale per unit at the unit price, paid in full by UPI (method typos "up" and "olx" → UPI)
  - each sale goes to an unsold laptop of that lot, matched on the cleaned shorthand, otherwise any unsold laptop; the laptop then takes its specs from the sale text
  - qty > 1 becomes a bulk group
- **Customer column:**
  - lead words become the lead source with no name
  - the rest are shown in the preview, where you set the type (Dealer, Walk-in or Old customer) for each name
- **Expenses:** each becomes a lot expense (type from the text, with the original text kept in the note). The applies-to is a line when the brand matches exactly one brand in the lot's lines, otherwise "All".
- **Preview before saving:** counts and ₹ totals for lots, lines, laptops, sales, expenses and cost, plus every flag. Nothing is saved until you press Import.

### 9. Users
- Raheem and Ayan become the first two users once you tell me who is admin and give their mobiles.
- One admin is created by the one-time bootstrap. The other is added from More → Users.

## 3. Database schema

All tables have `id uuid pk default gen_random_uuid()` (unless noted), `created_at`, `updated_at` (trigger), and `created_by uuid → profiles`. Money is `numeric(12,2)`. RLS is on for every table.

| Table | Key columns | Rules |
|---|---|---|
| `profiles` | `id` = auth.users.id, name, `mobile unique`, `role` ('admin','coadmin'), `active`, last_login_at | user reads own row, admin reads all; written only by Edge Functions / `bootstrap_first_admin`. `my_role()`/`is_admin()` return null when inactive or session > 7 days |
| `login_attempts` | `mobile pk`, failed_count, locked_until | service role only (Edge Functions) |
| `settings` | single row (`id=1`): shop_name, phone, addr, default_warranty_months, old_days, cloud_name, upload_preset | both read, admin writes |
| `suppliers` | `code char(2) unique` (`^\d{2}$`), name, phone | `00` reserved for customer exchange, made only by RPC |
| `lots` | supplier_id, lot_no, month, year, `prefix unique`, model, qty, added_on | prefix check `^\d{2}-\d{2}-\d{2}-\d{2}$` |
| `laptops` | lot_id, piece_no, `code unique`, model, `serial` (unique when not empty), specs, grade ('','A','B','C'), `status` ('in_stock','booked','sold'), note, test_note, tested_on, added_on | indexes on code, serial, lower(model); co-admin may update only model/serial/specs/grade/test_note (column grant). Status is changed only by RPCs |
| `laptop_costs` | `laptop_id pk`, cost, source ('lot','exchange','import') | **admin only**. Lot cost = sum of its laptops' costs (any leftover paisa from rounding goes on the last piece, so the totals are always exact) |
| `laptop_tests` | pk(laptop_id, test), test (one of the 10 names), result ('pass','fail') | no row = not tested yet |
| `repairs` | laptop_id, work, amount, done_on, deleted_at, deleted_by | both add; only admin soft-deletes (kept for audit) |
| `photos` | laptop_id, url (must be `https://res.cloudinary.com/…`), sort | both add |
| `customers` | `mobile unique` (last 10 digits), name, address | upserted by the sale and booking RPCs |
| `sales` | laptop_id, customer_id, customer_name/address (as on the bill), sold_on, price > 0, warranty_months ≥ 0, bulk_group, booking_id, `status` ('active','returned','voided'), voided_by/at/reason, client_ref unique | **partial unique index: one `active` sale per laptop** |
| `sale_payments` | sale_id, paid_on, amount, method ('Cash','UPI','Bank','Exchange'), ref, reversal_of | no UPDATE/DELETE grants; a trigger blocks the total going over the price; reversals are negative rows that point to the original |
| `bookings` | laptop_id, customer_id, customer_name, booked_on, agreed_price, `status` ('open','completed','cancelled'), sale_id | partial unique index: one `open` booking per laptop |
| `booking_payments` | booking_id, paid_on, amount, method, ref | the advance |
| `returns` | `sale_id unique`, laptop_id, returned_on, note | the sale row stays, with status `returned` |
| `refunds` | return_id or booking_id, refunded_on, amount, method, note | money out |
| `supplier_payments` | supplier_id, paid_on, amount, method, ref, reversal_of | admin only (co-admin can't see balances) |
| `debts` | name, type ('Shop rent','Loan','Borrowed','Bill','Other'), amount, due_on, deleted_at | admin only |
| `debt_payments` | debt_id, paid_on, amount, method, ref, reversal_of | admin only |
| `model_prices` | `model pk` (case-insensitive), price | both read, admin writes |
| `activity_log` | bigint id, at, actor_id, actor_name, actor_role, action, entity, entity_id, message, admin_only | written only by triggers; co-admin can't see `admin_only` rows, and the messages co-admin sees never include costs |

**Answers on 2b (2026-11-07):**
- All 8 changes are approved, along with choices 1, 2 and 4.
- Each laptop also keeps a short free-text **Notes** field.
- Liabilities payments on Shop rent and Bill debts show automatically in Shop expenses, marked "from Liabilities", and are read-only there. `add_shop_expense` refuses Rent or Electricity while a matching Liabilities debt is still open, so nothing is counted twice.
- The shop name stays First Choice Laptops.
- Excel questions Q1 to Q6 will be answered before Phase 7.

**Excel answers for now (2026-11-07; the dealer confirms before Phase 7):**
- **Q1, lot 10 cost:** ₹3,500 is the line total, so lot 10 = ₹28,000.
- **Q2, lot 10 date:** 1 Sep 2026 for all lines.
- **Q3, lot 13 date:** 9 Oct 2026, with the note "entered late".
- **Q4, "wc" tab:** use the Sales tab (lot 12) and ignore "wc". The preview shows those 3 sales with a choice of lot 12 or 13.
- **Q5, the two 19 Oct sales:** keep both, flagged as a possible duplicate with a "remove one" option.
- **Q6, users:** **Ayan is admin.** Admin can add any number of users and picks the role for each.
- **Live Dashboard check:** total sales ₹4,97,400 (Sep ₹2,67,500, Oct ₹2,29,900), which matches the count above. Its "Total expenses ₹69" is an Excel bug (it adds up the Count column); the correct figure is ₹60,900.
- **Import preview:** lists every assumption made (the answers above plus every mapping, clean-up and fallback match) so the dealer can confirm or change each one before saving.
- **Excel lot numbers 10–13 and 786** go in the lot note ("Excel lot 786"). Sticker lot numbers stay 2 digits per supplier, so codes keep their 11 digits for the scanner.

### Roles (three, replacing the two-role rules)

| Can… | Admin | Co-admin | Staff |
|---|---|---|---|
| Scan, view stock, run tests, add repairs and photos | ✓ | ✓ | ✓ |
| Book with advance, cancel a booking | ✓ | ✓ | ✓ |
| Sell, single or bulk (tests rule) | ✓ with override | ✓ no override | ✓ no override |
| See the "lowest safe price" hint | ✓ | ✓ | ✗ (a price below it is refused with "Ask the admin") |
| Add lots, add lot expenses | ✓ | ✓ | ✗ |
| Receive customer payments after the sale | ✓ | ✓ | ✗ (payment at the time of sale only) |
| Customers screen, Today's money, Reports (no profit), Activity | ✓ | ✓ | ✗ |
| Suppliers (names and quality) | ✓ | ✓ | ✗ |
| Costs, profit, supplier balances, Liabilities, Shop expenses, Lot P&L | ✓ | ✗ | ✗ |
| Delete, undo sale, return, Backup, Settings, Users | ✓ | ✗ | ✗ |

**Agreed after Phase 2 (2026-11-07):**
- **Co-admin's Today's money:** supplier, Liabilities and shop payments show only as one line per method, "Business payments (by admin) ₹X", with no names or details. The cash drawer totals still match the admin's view.
- **Staff cancelling a booking:** staff can cancel but can't refund. The advance becomes **held**, and admin or co-admin later picks refund or keep (`settle_held_advance`). Held advances are listed for admin and co-admin. When admin or co-admin cancels, they choose refund or keep straight away.

The database enforces all of this:
- `profiles.role` is 'admin', 'coadmin' or 'staff'.
- The RLS helpers are `is_user()` (any active user), `is_manager()` (admin or co-admin) and `is_admin()`.
- Line costs live in an admin-only table, `lot_line_costs`, so no other role can read a purchase cost through the API.

**Added or changed by section 2b:**
- **`lots`** gets `bought_on date` and `kind` ('purchase','opening','exchange'). The lot model moves to its lines.
- **`lot_lines`** (new): lot_id, brand, brand_other, model, processor, processor_other, gen, ram_gb, storage_type, storage_gb, qty, line_cost (null = missing), is_mixed.
- **`laptops`:**
  - gets `line_id` and the structured spec fields, plus a generated `shorthand` column (indexed)
  - `specs` is dropped
  - co-admin can edit the spec fields directly
- **`laptop_costs`:** no change. Each laptop's purchase cost is written from its line.
- **`lot_expenses`** (new): spent_on, lot_id, line_id (null = all), type, count, amount, method, ref, note, deleted_at. Both roles can read and add; the amounts reach profit only for admin.
- **`repairs`** gets `lot_expense_id`. When it's set, the repair is a fitted unit and its amount comes out of the shared pool.
- **`shop_expenses`** (new): spent_on, type, amount, method, ref, note, deleted_at. Admin only.
- **`sales` and `bookings`:**
  - get `lead_source` and `customer_type`
  - `customer_id` becomes nullable (no mobile); check: mobile required when warranty > 0 or a balance is left
- **`model_prices`** is keyed by the shorthand.

**Integrity guarantees**
- A laptop can't be sold twice, because there's one active sale per laptop (unique index) and the row is locked inside the RPC.
- `laptops.status` always matches: `sold` ⇔ an active sale exists; `booked` ⇔ an open booking exists.
- Payments are never changed or deleted. Undoing means a negative reversal row with who, when and why.
- The sum of a sale's payments is never more than its price (a trigger, which also covers payments made together).

## 4. RPC functions (security definer, one transaction each)

Every RPC checks the role first, locks the rows it touches, and raises a plain-English error that the app shows as a toast.

| RPC | Who | What it does |
|---|---|---|
| `get_snapshot()` | both | All data in prototype shape, filtered by role |
| `safe_price(laptop_id)` | both | Returns only the floor (cost + repairs) |
| `add_supplier(name, phone)` | admin | Next free code `01`…`99` |
| `create_lot(supplier_id, lot_no, month, year, qty, total_cost, model)` | both | Makes the lot, all its laptops (`-001`…), and their cost rows |
| `sell_laptop(laptop_id, customer, price, paid, method, ref, sold_on, warranty, exchange{model,value}, override_tests, client_ref)` | both | Checks tests (co-admin blocked; admin needs `override_tests`); sees a booking through if there is one; adds the exchange laptop to lot `00-01-MM-YY` with cost = exchange value, plus a payment with method `Exchange` |
| `sell_laptops_bulk(laptop_ids[], customer, price_each, total_paid, method, override_tests, client_ref)` | both | One payment, split across the laptops in the order they're ticked |
| `add_sale_payment(sale_id, amount, method, ref)` | both | Can't be more than the balance |
| `receive_customer_payment(mobile, amount, method, ref)` | both | Clears the oldest balance first |
| `book_laptop(laptop_id, customer, agreed_price, advance, method, ref)` | both | Status becomes `booked` |
| `complete_booking(booking_id, …sale fields)` | both | Same as sell; each advance becomes a sale payment (date kept) |
| `cancel_booking(booking_id, refund bool)` | both | Refund is optional; status goes back to `in_stock` |
| `return_sale(sale_id, refund_amount, method, note)` | admin | Refund ≤ money paid (not counting the exchange); laptop back in stock; old sale kept |
| `undo_sale(sale_id, reason)` | admin | Sale `voided` and its payments reversed (for entry mistakes) |
| `pay_supplier(supplier_id, amount, method, ref)` | admin | |
| `add_debt(...)`, `pay_debt(debt_id, amount, method, ref)`, `delete_debt(debt_id)` | admin | Delete is a soft delete |
| `add_repair`, `delete_repair` | both / admin | |
| `set_test(laptop_id, test, result or null)`, `set_all_tests(laptop_id)` | both | |
| `set_model_price(model, price)`, `save_settings(...)` | admin | |
| `import_backup(json)` | admin | Loads a prototype backup into an empty database, keeping codes, dates, payments and history |
| `restore_backup(json, confirm text)` | admin | Backup screen restore: wipes everything and imports (you type RESTORE to confirm) |
| `bootstrap_first_admin(user_id, name, mobile)` | SQL editor, once | Refuses if an admin already exists |
| `create_lot(supplier_id, lot_no, bought_on, kind, lines[])` | both | Replaces the one-line version: makes the lot, its lines, laptops numbered across lines, and cost rows |
| `set_line_cost(line_id, cost)` | admin | Fills in a missing cost |
| `add_lot_expense(...)`, `delete_lot_expense(id)` | both / admin | |
| `add_shop_expense(...)`, `delete_shop_expense(id)` | admin | |
| `set_specs(laptop_id, brand, model, processor, gen, ram, storage…)` | both | Fills in the specs (also sent with a sale of a Mixed laptop) |
| `report_year`, `lead_report(year)`, `lot_pnl()` | both (₹ profit only for admin) | Gross and net profit, lead sources, Lot P&L |
| `import_excel(json)` | admin | The parsed and cleaned Excel, after you approve the preview |

**Edge Functions** (Deno, these hold the service role key as a secret)

| Function | Who | What |
|---|---|---|
| `auth-login` | anyone (no JWT) | mobile + PIN → lock check → session, or "Wrong mobile number or PIN" / `locked_until` |
| `change-pin` | logged-in user | old PIN checked (counts towards the lock), sets the new PIN |
| `admin-users` | active admin | list, create, set_role, reset_pin, set_active; won't remove the last active admin |

## 5. Mapping your 9 tests to where they're enforced

| # | Check | Enforced by |
|---|---|---|
| 1 | 20 laptops for ₹3,00,000 → `01-01-MM-YY-001…020`, ₹15,000 each | `create_lot` |
| 2 | Co-admin blocked on a failed test; admin after confirming | `sell_laptop` role check and the `override_tests` flag |
| 3 | ₹29,500 − ₹15,000 = ₹14,500 due; +₹5,000 UPI = ₹9,500, 2 payments | `sell_laptop`, `add_sale_payment` |
| 4 | ₹20,000 − ₹5,000 exchange − ₹10,000 UPI = ₹5,000; `00-01-MM-YY-001` costs ₹5,000 | `sell_laptop` exchange branch |
| 5 | ₹3,000 advance + ₹15,000 → 2 sale payments | `book_laptop`, `complete_booking` |
| 6 | ₹12,000 refund appears as money out today; laptop back in stock | `return_sale`, Today's money |
| 7 | ₹29,500 − ₹20,000 − ₹1,350 = ₹8,150; co-admin API can't read cost or profit | snapshot and RLS on `laptop_costs` |
| 8 | Sale on phone A appears on phone B | Realtime on `activity_log` |
| 9 | Sticker opens laptop; unknown code shows a message; typed and pasted numbers work | scan view (same logic as the prototype) |

Login checks are added by hand as well:
- 5 wrong PINs → locked, with a countdown
- a turned-off user can't log in, and their open session stops working
- co-admin can't open Users or call `admin-users`
- the last mobile is remembered, and "Not you?" clears it

Tests 1 to 7 will be a SQL test script that you run in the Supabase SQL editor. It rolls everything back, so no data is left behind. Tests 8 and 9 are checked by hand on two phones.

---

## 6. Gaps between the prototype and the brief

**Agreed 2026-11-07:** items 1, 3 and 6 as written. Item 4: bulk sale follows the test rule, and admin can override with the same "Sell anyway" confirmation as a single sale. Item 9 is replaced by the new login (exactly 6 digits, see 2a). The login design, including the random part of the hidden email, is approved.

**Final answers (2026-11-07):**
- **Item 2, lot cost.** Lot cost may be left blank when the lot is created. Those laptops then have no cost row. The admin sees a **"Cost missing"** mark on the lot and on Home until it is filled in with `set_lot_cost`, which splits the cost across the lot. Profit for those laptops shows "cost missing", never a wrong number. Supplier "bought" totals leave them out and carry the same mark. Co-admin's lowest safe price says "not set yet".
- **Item 5, Ref / UTR.** Add a small optional "Ref / UTR" box under the method chips for customer, supplier and debt payments.
- **Item 7, model prices.** OK as written: co-admin can view and share them, not edit.
- **Item 8, undo sale.** OK as written: the sale is voided and its payments are reversed, not deleted.
- **Item 10, backup.** OK as written. Restore is admin only, behind a confirmation.

1. **Co-admin and suppliers/liabilities.** In the prototype, co-admin can pay suppliers, add or pay debts, and sees "You owe" on Home. The brief says co-admin can't see supplier balances.
   *My default:* co-admin doesn't see the "You owe" box on Home or the Liabilities screen. On the Suppliers screen they see names, codes and the repair-quality numbers, but not money. Only admin can add suppliers, pay suppliers and manage debts.
2. **Co-admin creating a lot needs a lot cost.**
   *My default:* co-admin can type the cost when creating a lot, but never sees it again. The cost line in lot details is hidden from co-admin.
3. **Lowest safe price for co-admin.** The prototype hint says "Profit ₹X over cost". For co-admin, that together with the price would reveal the cost.
   *My default:* co-admin sees only "Lowest safe price ₹X" and green or red, never a profit figure. The "This price is a loss" confirmation says "below the lowest safe price" instead of showing cost. (The floor still roughly reveals cost; the brief accepts this.)
4. **Bulk sale skips the test check** in the prototype.
   *My default:* the same rule applies. Co-admin can't bulk-sell an untested laptop; admin gets the "Sell anyway" confirmation.
5. **Payment ref.** The brief has an optional ref column, but the prototype has no box for it.
   *My default:* store it (exchange sales put the new sticker code there) and don't add a box, so the screens stay the same. I can add a small optional "Ref / UTR" box under the method chips if you want.
6. **Demo data and "Delete all data".** These would pollute the real shared database.
   *My default:* remove "Load demo data" and the Home "Try it with sample data" card. Keep "Delete all data" for admin only, behind the typed DELETE confirmation.
7. **Model prices editing.** This isn't in the brief's co-admin list.
   *My default:* co-admin can view prices (and share them) but not edit them.
8. **Undo sale vs. "payments never deleted".**
   *My default:* the sale becomes `voided` and each payment gets a reversal row. Voided sales and their reversals are left out of Today's money and reports, as if the entry never happened. That matches what the prototype shows today.
9. **PIN length.** The prototype box allows at most 6 digits.
   *My default:* PIN of 6 or more digits, and the box accepts up to 12.
10. **Backup format.** Export keeps the prototype's JSON shape (plus extra fields), so one importer handles both old prototype backups and new ones.

## 6b. Who owns what (2026-11-07)
- **GitHub:** a private repo on the **dealer's** GitHub account. The developer is added as a collaborator.
- **Supabase:** the project is on the **dealer's** Supabase account. The developer is invited as a Developer member.
- **Commits** use the developer's own Git name and email.
- **The dealer's Excel** (`docs/*.xlsx`) is never committed. It is gitignored and stays on this PC for the Phase 7 import.
- **GitHub Pages** will be served from the dealer's repo (Phase 7/8). Cloudinary will be on the dealer's account too, unless decided otherwise.

## 7. What I'll need from you before Phase 2 runs

- A Supabase project (free tier). I'll walk you through creating it and running the migrations yourself.
- For the Edge Functions: either the Supabase CLI on this PC, or the dashboard's built-in function editor. I'll suggest the easier one in Phase 2.
- Internet on this PC for downloading the local copies of the libraries and the Archivo font (Phase 3).
- Later: a Cloudinary account and a GitHub account (taqwasteps@gmail.com) for Pages.

## 8. Service partners (added 2026-11-09)

- **Tables:**
  - `service_partners`: name, mobile, shop name, address, what they repair
  - `service_jobs`: laptop, partner, stock or warranty, what to fix, given / expected / received dates, work done, outcome
  - `service_charges`: admin only; no row means "charge missing"
  - `service_payments`: never edited, only reversed
- **Laptop status** adds `at_service`. A laptop at service cannot be sold, booked, bulk sold, returned or undone ("This laptop is with … since …").
- **Charges:**
  - a **stock** job's charge is added to that laptop's cost (so profit is right when it sells)
  - a **warranty** job's charge is a warranty cost: it never changes the original sale's profit and comes off net profit in the month it came back
- **Who can do what:**
  - staff gives and receives, never sees or enters charges
  - co-admin may enter a missing charge (not change it), sees no totals, cannot pay
  - admin does everything, including paying now at receive or later from the partner page or Liabilities
- **Screens:**
  - the laptop pop-up gets three big buttons (Replace parts, Delivery / Handover, Give for service), with Tests as a small link; Service is highlighted while at service, Delivery when sold
  - More → Service partners, with a partner page showing laptops with them now (days out, overdue in red), history and money (admin), plus Call, WhatsApp and Pay
  - "At service" on Home and in the Stock filter; "Owed to service partners" on Home and in Liabilities (admin)
  - service payments in Today's money; service and warranty costs per month in Reports
  - Activity line "Imran gave … to Ravi Chip Repair for screen"
- **Live sync** now uses `sync_ticks`, a data-free table every role can receive, so staff phones refresh too.

## 9. Build status (2026-11-09)

- **Database:** `supabase/setup_all.sql` (one file, safe to run twice).
- **Local tests:**
  - 161 checks with the migrations; 163 when loading `setup_all.sql` twice
  - 32 checks for the Excel import, matching the dealer's Dashboard: ₹4,97,400 (Sep ₹2,67,500, Oct ₹2,29,900), expenses ₹60,900
  - 43 browser checks in headless Edge against a local stand-in for Supabase
- **Edge Functions:** type-checked with Deno. Not yet run against a real Supabase project.
- **Still to do on the real project:** setup steps 1–10 in README.md, then check by hand: login lock, Realtime between two phones, camera scanning, Cloudinary upload.
- **Dealer to confirm before the Excel import:** Q1–Q6 answers, plus a second possible double entry found by the import ("HP pentinum 360", OLX, ₹8,500, twice on 27 Sep in lot 786).
