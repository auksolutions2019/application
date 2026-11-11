-- =====================================================================
-- First Choice Laptops, Stock Manager: complete database setup
-- Generated from supabase/migrations by tools/build-setup.mjs. Do not edit by hand.
--
-- Paste the whole file into the Supabase SQL Editor on a new project and click Run.
-- It is safe to run again: every step checks first.
-- The last result shows how many tables were made and how many have access rules on.
-- If the SQL Editor says the query is too big, run setup_part1.sql, setup_part2.sql and setup_part3.sql instead.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0001_schema.sql
-- ---------------------------------------------------------------------
-- First Choice Laptops, Stock Manager
-- 0001: tables, constraints, indexes
-- Money is numeric(12,2) in INR. All "today" logic uses Asia/Kolkata.

create schema if not exists private;

-- ---------- small helpers ----------
create or replace function private.today() returns date
language sql stable set search_path = '' as $$
  select (now() at time zone 'Asia/Kolkata')::date
$$;

create or replace function private.touch() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- Shop shorthand, e.g. "Dell i5 7th 8/256" or "HP i3 4th 8/500 HDD".
create or replace function private.ordinal(n int) returns text
language sql immutable set search_path = '' as $$
  select case when n is null then null
    when n % 100 between 11 and 13 then n || 'th'
    when n % 10 = 1 then n || 'st'
    when n % 10 = 2 then n || 'nd'
    when n % 10 = 3 then n || 'rd'
    else n || 'th' end
$$;

create or replace function private.shorthand(
  p_brand text, p_brand_other text, p_processor text, p_processor_other text,
  p_gen int, p_ram int, p_storage_type text, p_storage_gb int
) returns text
language sql immutable set search_path = '' as $$
  select btrim(concat_ws(' ',
    nullif(case when p_brand = 'Other' then btrim(coalesce(p_brand_other, '')) else coalesce(p_brand, '') end, ''),
    nullif(case when p_processor = 'Other' then btrim(coalesce(p_processor_other, '')) else coalesce(p_processor, '') end, ''),
    private.ordinal(p_gen),
    case when p_ram is null and p_storage_gb is null then null
         else concat(coalesce(p_ram::text, '?'), '/',
                     case when p_storage_gb is null then 'N'
                          when p_storage_gb >= 1000 and p_storage_gb % 1000 = 0 then (p_storage_gb / 1000) || 'TB'
                          else p_storage_gb::text end) end,
    case when p_storage_type = 'HDD' then 'HDD' end
  ))
$$;

-- ---------- users ----------
create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete restrict,
  name          text not null check (length(btrim(name)) between 1 and 80),
  mobile        text not null unique check (mobile ~ '^[6-9][0-9]{9}$'),
  role          text not null check (role in ('admin','coadmin','staff')),
  active        boolean not null default true,
  last_login_at timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- One row per PIN login, written by the auth-login Edge Function.
-- private.my_role() only accepts sessions younger than 7 days.
create table if not exists public.app_sessions (
  session_id uuid primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists app_sessions_user_id_idx on public.app_sessions (user_id);

-- Wrong-PIN counter, written only by Edge Functions (service role).
create table if not exists public.login_attempts (
  mobile       text primary key,
  failed_count int not null default 0,
  locked_until timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ---------- settings (single row) ----------
create table if not exists public.settings (
  id                      int primary key default 1 check (id = 1),
  shop_name               text not null default 'First Choice Laptops',
  phone                   text not null default '+91 99168 76350',
  addr                    text not null default 'No 2, 4th Cross, R.T Nagar, Bangalore 560032',
  default_warranty_months int  not null default 6  check (default_warranty_months between 0 and 60),
  old_days                int  not null default 60 check (old_days between 1 and 3650),
  cloud_name              text not null default '',
  upload_preset           text not null default '',
  -- invoice (bill) details
  bill_name               text not null default '',
  bill_email              text not null default '',
  logo_url                text not null default '',
  bank_name               text not null default '',
  bank_holder             text not null default '',
  bank_account            text not null default '',
  bank_ifsc               text not null default '',
  invoice_next            int  not null default 58 check (invoice_next >= 1),
  accessory_warranty_months int not null default 12 check (accessory_warranty_months between 0 and 60),
  bill_print_bw           boolean not null default true,   -- printed bills in black and white; WhatsApp / download PDF in colour
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  updated_by              uuid references public.profiles(id)
);

-- ---------- suppliers, lots, lines, laptops ----------
create table if not exists public.suppliers (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique check (code ~ '^[0-9]{2}$'),   -- '00' = customer exchange
  name       text not null check (length(btrim(name)) between 1 and 80),
  phone      text not null default '',
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.lots (
  id          uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references public.suppliers(id),
  lot_no      int  not null check (lot_no between 1 and 99),
  month       int  not null check (month between 1 and 12),
  year        int  not null check (year between 2000 and 2099),
  prefix      text not null unique check (prefix ~ '^[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}$'),
  kind        text not null default 'purchase' check (kind in ('purchase','opening','exchange')),
  bought_on   date not null default private.today(),
  note        text not null default '',
  created_by  uuid references public.profiles(id) default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists lots_supplier_id_idx on public.lots (supplier_id);

-- Spec value lists (kept in one place so app and database agree)
create or replace function private.brands() returns text[] language sql immutable as
  $$ select array['Dell','HP','Lenovo','Acer','Asus','Apple','Other'] $$;
create or replace function private.processors() returns text[] language sql immutable as
  $$ select array['i3','i5','i7','i9','Pentium','Celeron','Ryzen 3','Ryzen 5','Ryzen 7','Other'] $$;

-- One lot has one or more lines (model, specs, qty, cost). A "Mixed" line has unknown models.
create table if not exists public.lot_lines (
  id              uuid primary key default gen_random_uuid(),
  lot_id          uuid not null references public.lots(id) on delete cascade,
  line_no         int  not null check (line_no between 1 and 99),
  is_mixed        boolean not null default false,
  brand           text check (brand = any (private.brands())),
  brand_other     text not null default '',
  model           text not null default '',
  processor       text check (processor = any (private.processors())),
  processor_other text not null default '',
  gen             int  check (gen between 1 and 30),
  ram_gb          int  check (ram_gb in (2,4,6,8,12,16,24,32,64)),
  storage_type    text check (storage_type in ('SSD','HDD')),
  storage_gb      int  check (storage_gb between 16 and 8000),
  qty             int  not null check (qty between 1 and 500),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (lot_id, line_no)
);

-- Admin only. What was paid for a line. No row = cost missing.
create table if not exists public.lot_line_costs (
  line_id    uuid primary key references public.lot_lines(id) on delete cascade,
  line_cost  numeric(12,2) not null check (line_cost >= 0),
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.laptops (
  id              uuid primary key default gen_random_uuid(),
  lot_id          uuid not null references public.lots(id),
  line_id         uuid not null references public.lot_lines(id),
  piece_no        int  not null check (piece_no between 1 and 999),
  code            text not null unique check (code ~ '^[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{3}$'),
  brand           text check (brand = any (private.brands())),
  brand_other     text not null default '',
  model           text not null default '',
  processor       text check (processor = any (private.processors())),
  processor_other text not null default '',
  gen             int  check (gen between 1 and 30),
  ram_gb          int  check (ram_gb in (2,4,6,8,12,16,24,32,64)),
  storage_type    text check (storage_type in ('SSD','HDD')),
  storage_gb      int  check (storage_gb between 16 and 8000),
  shorthand       text generated always as
                  (private.shorthand(brand, brand_other, processor, processor_other, gen, ram_gb, storage_type, storage_gb)) stored,
  serial          text not null default '',
  grade           text not null default '' check (grade in ('','A','B','C')),
  status          text not null default 'in_stock' check (status in ('in_stock','booked','sold','at_service')),
  notes           text not null default '' check (length(notes) <= 300),
  test_note       text not null default '',
  tested_on       date,
  added_on        date not null default private.today(),
  created_by      uuid references public.profiles(id) default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (lot_id, piece_no)
);
create unique index if not exists laptops_serial_uniq on public.laptops (upper(btrim(serial))) where btrim(serial) <> '';
create index if not exists laptops_status_idx on public.laptops (status);
create index if not exists laptops_line_id_idx on public.laptops (line_id);
create index if not exists laptops_shorthand_idx on public.laptops (lower(shorthand));
create index if not exists laptops_processor_gen_ram_gb_storage_gb_idx on public.laptops (processor, gen, ram_gb, storage_gb);

-- Admin only. Purchase cost of each laptop, written from its line. No row = cost missing.
create table if not exists public.laptop_costs (
  laptop_id  uuid primary key references public.laptops(id) on delete cascade,
  cost       numeric(12,2) not null check (cost >= 0),
  source     text not null check (source in ('lot','exchange','import')),
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.laptop_tests (
  laptop_id  uuid not null references public.laptops(id) on delete cascade,
  test       text not null check (test in ('Display','Keyboard','Touchpad','Battery','Charging','USB ports','Wi-Fi','Audio','Camera','Storage')),
  result     text not null check (result in ('pass','fail')),
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (laptop_id, test)
);

-- Parts bought for a lot (not for one laptop). Shared across the line, or the whole lot when line_id is null.
create table if not exists public.lot_expenses (
  id         uuid primary key default gen_random_uuid(),
  lot_id     uuid not null references public.lots(id),
  line_id    uuid references public.lot_lines(id),
  spent_on   date not null default private.today(),
  type       text not null check (type in ('SSD','RAM','Battery','Charger','HDD','Keyboard','Screen','Transport','Repair labour','Other')),
  count      int  not null default 1 check (count between 1 and 1000),
  amount     numeric(12,2) not null check (amount > 0),
  method     text not null default 'Cash' check (method in ('Cash','UPI','Bank')),
  ref        text not null default '',
  note       text not null default '',
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id),
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists lot_expenses_lot_id_idx on public.lot_expenses (lot_id);
create index if not exists lot_expenses_spent_on_idx on public.lot_expenses (spent_on);

-- Work on one laptop. lot_expense_id set = one unit fitted from that lot expense
-- (its amount then leaves the shared pool, so it is never counted twice).
create table if not exists public.repairs (
  id             uuid primary key default gen_random_uuid(),
  laptop_id      uuid not null references public.laptops(id),
  lot_expense_id uuid references public.lot_expenses(id),
  work           text not null check (length(btrim(work)) between 1 and 120),
  amount         numeric(12,2) not null check (amount > 0),
  done_on        date not null default private.today(),
  deleted_at     timestamptz,
  deleted_by     uuid references public.profiles(id),
  created_by     uuid references public.profiles(id) default auth.uid(),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists repairs_laptop_id_idx on public.repairs (laptop_id);
create index if not exists repairs_lot_expense_id_idx on public.repairs (lot_expense_id);
create index if not exists repairs_done_on_idx on public.repairs (done_on);

create table if not exists public.photos (
  id         uuid primary key default gen_random_uuid(),
  laptop_id  uuid not null references public.laptops(id),
  url        text not null check (url ~ '^https://res\.cloudinary\.com/[^\s"''<>]+$'),
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists photos_laptop_id_idx on public.photos (laptop_id);

-- ---------- customers, sales, bookings ----------
create or replace function private.lead_sources() returns text[] language sql immutable as
  $$ select array['OLX','Instagram','Lead Matrix','Circle app','Octo','Walk-in','Old customer','Dealer','Other'] $$;

create table if not exists public.customers (
  id            uuid primary key default gen_random_uuid(),
  mobile        text not null unique check (mobile ~ '^[0-9]{6,15}$'),
  name          text not null default '',
  address       text not null default '',
  customer_type text not null default 'Retail' check (customer_type in ('Retail','Dealer')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists customers_name_idx on public.customers (lower(name));

create table if not exists public.bookings (
  id               uuid primary key default gen_random_uuid(),
  laptop_id        uuid not null references public.laptops(id),
  customer_id      uuid not null references public.customers(id),   -- a booking always needs a mobile
  customer_name    text not null default '',
  customer_address text not null default '',
  lead_source      text not null check (lead_source = any (private.lead_sources())),
  customer_type    text not null default 'Retail' check (customer_type in ('Retail','Dealer')),
  booked_on        date not null,
  agreed_price     numeric(12,2) check (agreed_price > 0),
  status           text not null default 'open' check (status in ('open','completed','cancelled')),
  cancelled_on     date,
  -- after a cancel with an advance: refunded, kept, or held (staff cancelled; admin/co-admin decides later)
  advance_status   text check (advance_status in ('held','refunded','kept')),
  advance_decided_by uuid references public.profiles(id),
  created_by       uuid references public.profiles(id) default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create unique index if not exists bookings_one_open on public.bookings (laptop_id) where status = 'open';
create index if not exists bookings_customer_id_idx on public.bookings (customer_id);

create table if not exists public.booking_payments (
  id         uuid primary key default gen_random_uuid(),
  note        text not null default '' check (length(note) <= 300),
  booking_id uuid not null references public.bookings(id),
  paid_on    date not null,
  amount     numeric(12,2) not null check (amount > 0),
  method     text not null check (method in ('Cash','UPI','Bank')),
  ref        text not null default '',
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists booking_payments_booking_id_idx on public.booking_payments (booking_id);
create index if not exists booking_payments_paid_on_idx on public.booking_payments (paid_on);

-- One invoice number per bill (a single sale, or a bulk sale). The primary key means a number can never repeat.
create table if not exists public.invoices (
  no         int primary key check (no > 0),
  issued_on  date not null,
  bulk_group uuid,
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.sales (
  id               uuid primary key default gen_random_uuid(),
  laptop_id        uuid not null references public.laptops(id),
  customer_id      uuid references public.customers(id),            -- null = no mobile given
  customer_name    text not null default '',                        -- as printed on the bill
  customer_address text not null default '',
  lead_source      text not null check (lead_source = any (private.lead_sources())),
  customer_type    text not null default 'Retail' check (customer_type in ('Retail','Dealer')),
  sold_on          date not null,
  price            numeric(12,2) not null check (price > 0),
  warranty_months  int not null default 0 check (warranty_months between 0 and 60),
  bulk_group       uuid,
  booking_id       uuid references public.bookings(id),
  invoice_no       int references public.invoices(no),
  accessory_warranty_months int not null default 0 check (accessory_warranty_months between 0 and 60),
  warranty_token   text unique,                    -- long random token behind the warranty QR on the bill
  status           text not null default 'active' check (status in ('active','returned','voided')),
  voided_at        timestamptz,
  voided_by        uuid references public.profiles(id),
  void_reason      text,
  created_by       uuid references public.profiles(id) default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check ((warranty_months = 0 and accessory_warranty_months = 0) or customer_id is not null)   -- warranty needs a mobile
);
-- A laptop can never have two live sales.
create unique index if not exists sales_one_active on public.sales (laptop_id) where status = 'active';
create index if not exists sales_customer_id_idx on public.sales (customer_id);
create index if not exists sales_sold_on_idx on public.sales (sold_on);
create index if not exists sales_lead_source_idx on public.sales (lead_source);

create table if not exists public.sale_payments (
  id                 uuid primary key default gen_random_uuid(),
  note        text not null default '' check (length(note) <= 300),
  sale_id            uuid not null references public.sales(id),
  paid_on            date not null,
  amount             numeric(12,2) not null check (amount <> 0),
  method             text not null check (method in ('Cash','UPI','Bank','Exchange')),
  ref                text not null default '',
  reversal_of        uuid unique references public.sale_payments(id),
  booking_payment_id uuid unique references public.booking_payments(id),  -- advance carried into the sale
  created_by         uuid references public.profiles(id) default auth.uid(),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check ((reversal_of is null) = (amount > 0))
);
create index if not exists sale_payments_sale_id_idx on public.sale_payments (sale_id);
create index if not exists sale_payments_paid_on_idx on public.sale_payments (paid_on);

create table if not exists public.returns (
  id          uuid primary key default gen_random_uuid(),
  sale_id     uuid not null unique references public.sales(id),
  laptop_id   uuid not null references public.laptops(id),
  returned_on date not null,
  note        text not null default '',
  created_by  uuid references public.profiles(id) default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists returns_laptop_id_idx on public.returns (laptop_id);

create table if not exists public.refunds (
  id          uuid primary key default gen_random_uuid(),
  label       text not null default '',           -- what the refund was for (written by the app)
  return_id   uuid references public.returns(id),
  booking_id  uuid references public.bookings(id),
  refunded_on date not null,
  amount      numeric(12,2) not null check (amount > 0),
  method      text not null check (method in ('Cash','UPI','Bank')),
  ref         text not null default '',
  note        text not null default '',
  created_by  uuid references public.profiles(id) default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (num_nonnulls(return_id, booking_id) <= 1)
);
create index if not exists refunds_refunded_on_idx on public.refunds (refunded_on);

-- ---------- what the shop owes and spends ----------
create table if not exists public.supplier_payments (
  id          uuid primary key default gen_random_uuid(),
  note        text not null default '' check (length(note) <= 300),
  supplier_id uuid not null references public.suppliers(id),
  paid_on     date not null,
  amount      numeric(12,2) not null check (amount <> 0),
  method      text not null check (method in ('Cash','UPI','Bank')),
  ref         text not null default '',
  reversal_of uuid unique references public.supplier_payments(id),
  created_by  uuid references public.profiles(id) default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check ((reversal_of is null) = (amount > 0))
);
create index if not exists supplier_payments_supplier_id_idx on public.supplier_payments (supplier_id);
create index if not exists supplier_payments_paid_on_idx on public.supplier_payments (paid_on);

create table if not exists public.debts (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(btrim(name)) between 1 and 120),
  type       text not null check (type in ('Shop rent','Loan','Borrowed','Bill','Other')),
  amount     numeric(12,2) not null check (amount > 0),
  due_on     date,
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id),
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.debt_payments (
  id          uuid primary key default gen_random_uuid(),
  note        text not null default '' check (length(note) <= 300),
  debt_id     uuid not null references public.debts(id),
  paid_on     date not null,
  amount      numeric(12,2) not null check (amount <> 0),
  method      text not null check (method in ('Cash','UPI','Bank')),
  ref         text not null default '',
  reversal_of uuid unique references public.debt_payments(id),
  created_by  uuid references public.profiles(id) default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check ((reversal_of is null) = (amount > 0))
);
create index if not exists debt_payments_debt_id_idx on public.debt_payments (debt_id);
create index if not exists debt_payments_paid_on_idx on public.debt_payments (paid_on);

-- Running costs not tied to a lot. Payments of Shop rent / Bill debts are added to these
-- automatically in reports ("from Liabilities"), so they are never entered here twice.
create table if not exists public.shop_expenses (
  id         uuid primary key default gen_random_uuid(),
  spent_on   date not null default private.today(),
  type       text not null check (type in ('Rent','Electricity','Salary','Internet','Transport','Other')),
  amount     numeric(12,2) not null check (amount > 0),
  method     text not null default 'Cash' check (method in ('Cash','UPI','Bank')),
  ref        text not null default '',
  note       text not null default '',
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id),
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists shop_expenses_spent_on_idx on public.shop_expenses (spent_on);

-- ---------- prices and log ----------
-- Usual selling price per shorthand ("Dell i5 7th 8/256").
create table if not exists public.model_prices (
  shorthand  text primary key check (length(btrim(shorthand)) between 1 and 120),
  price      numeric(12,2) not null check (price > 0),
  updated_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.activity_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  actor_id   uuid references public.profiles(id),
  actor_name text not null default 'System',
  actor_role text,
  action     text not null,
  entity     text,
  entity_id  text,
  message    text not null,
  admin_only boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists activity_log_at_desc_idx on public.activity_log (at desc);

-- ---------- service partners (outside technicians and repair shops) ----------
create or replace function private.service_skills() returns text[] language sql immutable as
  $$ select array['Chip-level','Screen','Keyboard','Battery','Hinge/body','Software','Other'] $$;

create table if not exists public.service_partners (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(btrim(name)) between 1 and 80),
  mobile     text not null default '' check (mobile = '' or mobile ~ '^[0-9]{6,15}$'),
  shop_name  text not null default '',
  address    text not null default '',
  skills     text[] not null default '{}' check (skills <@ private.service_skills()),
  active     boolean not null default true,
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One trip of one laptop to a partner. kind: stock laptop, or a customer's laptop back under warranty.
create table if not exists public.service_jobs (
  id          uuid primary key default gen_random_uuid(),
  laptop_id   uuid not null references public.laptops(id),
  partner_id  uuid not null references public.service_partners(id),
  kind        text not null check (kind in ('stock','warranty')),
  sale_id     uuid references public.sales(id),
  issues      text[] not null default '{}' check (issues <@ private.service_skills()),
  note        text not null default '',
  given_on    date not null,
  expected_on date,
  status      text not null default 'out' check (status in ('out','returned')),
  received_on date,
  work_done   text not null default '',
  outcome     text check (outcome in ('fixed','not_fixed','no_work')),
  given_by    uuid references public.profiles(id) default auth.uid(),
  received_by uuid references public.profiles(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check ((status = 'out') = (received_on is null)),
  check (kind = 'stock' or sale_id is not null)
);
create unique index if not exists service_one_open on public.service_jobs (laptop_id) where status = 'out';
create index if not exists service_jobs_partner_id_idx on public.service_jobs (partner_id);
create index if not exists service_jobs_received_on_idx on public.service_jobs (received_on);

-- Admin only. No row = "charge missing" (staff never enter or see charges).
create table if not exists public.service_charges (
  job_id     uuid primary key references public.service_jobs(id),
  charge     numeric(12,2) not null check (charge >= 0),
  entered_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.service_payments (
  id          uuid primary key default gen_random_uuid(),
  note        text not null default '' check (length(note) <= 300),
  partner_id  uuid not null references public.service_partners(id),
  job_id      uuid references public.service_jobs(id),
  paid_on     date not null,
  amount      numeric(12,2) not null check (amount <> 0),
  method      text not null check (method in ('Cash','UPI','Bank')),
  ref         text not null default '',
  reversal_of uuid unique references public.service_payments(id),
  created_by  uuid references public.profiles(id) default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check ((reversal_of is null) = (amount > 0))
);
create index if not exists service_payments_partner_id_idx on public.service_payments (partner_id);
create index if not exists service_payments_paid_on_idx on public.service_payments (paid_on);

-- Live sync: one tiny row per change. Every role may read it (it carries no data), so every phone
-- refreshes, including staff who cannot read the activity log itself.
create table if not exists public.sync_ticks (
  id bigint generated always as identity primary key,
  at timestamptz not null default now()
);

-- Rate limit for the public warranty check page (written only by public.warranty_lookup).
create table if not exists public.rate_limits (
  key          text primary key,
  hits         int not null default 0,
  window_start timestamptz not null default now()
);

-- Idempotency: a retried or double-tapped save returns the first result.
create table if not exists private.rpc_requests (
  client_ref uuid primary key,
  result     jsonb,
  created_at timestamptz not null default now()
);

-- ---------- updated_at triggers ----------
do $$
declare t text;
begin
  foreach t in array array['profiles','app_sessions','login_attempts','settings','suppliers','lots','lot_lines','lot_line_costs','laptops',
    'laptop_costs','laptop_tests','lot_expenses','repairs','photos','customers','bookings','booking_payments','sales',
    'sale_payments','returns','refunds','supplier_payments','debts','debt_payments','shop_expenses','model_prices',
    'service_partners','service_jobs','service_charges','service_payments','invoices']
  loop
    execute format('drop trigger if exists touch on public.%I', t);
    execute format('create trigger touch before update on public.%I for each row execute function private.touch()', t);
  end loop;
end $$;

-- ---------- columns added after the first version (no-ops on a new project) ----------
alter table public.sale_payments     add column if not exists note text not null default '';
alter table public.booking_payments  add column if not exists note text not null default '';
alter table public.supplier_payments add column if not exists note text not null default '';
alter table public.debt_payments     add column if not exists note text not null default '';
alter table public.service_payments  add column if not exists note text not null default '';
alter table public.refunds           add column if not exists label text not null default '';
alter table public.settings add column if not exists bill_name text not null default '';
alter table public.settings add column if not exists bill_email text not null default '';
alter table public.settings add column if not exists logo_url text not null default '';
alter table public.settings add column if not exists bank_name text not null default '';
alter table public.settings add column if not exists bank_holder text not null default '';
alter table public.settings add column if not exists bank_account text not null default '';
alter table public.settings add column if not exists bank_ifsc text not null default '';
alter table public.settings add column if not exists invoice_next int not null default 58;
alter table public.settings add column if not exists accessory_warranty_months int not null default 12;
alter table public.settings add column if not exists bill_print_bw boolean not null default true;
alter table public.sales add column if not exists invoice_no int references public.invoices(no);
alter table public.sales add column if not exists accessory_warranty_months int not null default 0;
alter table public.sales add column if not exists warranty_token text unique;

-- ---------------------------------------------------------------------
-- 0002_security.sql
-- ---------------------------------------------------------------------
-- 0002: role helpers, integrity triggers, Row Level Security, grants

-- ---------- role helpers ----------
-- Role of the caller, or null when: not logged in, user turned off,
-- or the PIN login (session) is older than 7 days.
create or replace function private.my_role() returns text
language sql stable security definer set search_path = '' as $$
  select p.role
  from public.profiles p
  join public.app_sessions s
    on s.user_id = p.id
   and s.session_id = nullif(auth.jwt() ->> 'session_id', '')::uuid
  where p.id = auth.uid()
    and p.active
    and s.created_at > now() - interval '7 days'
$$;

create or replace function private.is_admin() returns boolean
language sql stable set search_path = '' as $$ select coalesce(private.my_role() = 'admin', false) $$;

create or replace function private.is_user() returns boolean
language sql stable set search_path = '' as $$ select private.my_role() is not null $$;

-- admin or co-admin
create or replace function private.is_manager() returns boolean
language sql stable set search_path = '' as $$ select coalesce(private.my_role() in ('admin','coadmin'), false) $$;

create or replace function private.require_user() returns text
language plpgsql stable set search_path = '' as $$
declare r text := private.my_role();
begin
  if r is null then
    raise exception 'Please log in again.' using errcode = '28000';
  end if;
  return r;
end $$;

create or replace function private.require_admin() returns void
language plpgsql stable set search_path = '' as $$
begin
  if private.require_user() <> 'admin' then
    raise exception 'Only the admin can do this.' using errcode = '42501';
  end if;
end $$;

create or replace function private.require_manager() returns text
language plpgsql stable set search_path = '' as $$
declare r text := private.require_user();
begin
  if r = 'staff' then
    raise exception 'Ask the admin or co-admin to do this.' using errcode = '42501';
  end if;
  return r;
end $$;

-- ---------- integrity: payments are never edited or deleted ----------
create or replace function private.no_edit() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_setting('app.wipe', true) = 'on' then   -- only restore_backup sets this
    return coalesce(old, new);
  end if;
  -- the admin may change the note on a payment, never anything else (edit_payment_note logs the old text)
  if tg_op = 'UPDATE' and (to_jsonb(new) - 'note' - 'updated_at') = (to_jsonb(old) - 'note' - 'updated_at') then
    return new;
  end if;
  raise exception 'Payments cannot be changed or deleted. Add a reversal instead.';
end $$;

do $$
declare t text;
begin
  foreach t in array array['sale_payments','booking_payments','supplier_payments','debt_payments','refunds','service_payments']
  loop
    execute format('drop trigger if exists no_edit on public.%I', t);
    execute format('create trigger no_edit before update or delete on public.%I for each row execute function private.no_edit()', t);
  end loop;
end $$;

-- Total paid on a sale can never be above its price, or below zero.
create or replace function private.check_sale_total() returns trigger
language plpgsql set search_path = '' as $$
declare v_price numeric; v_paid numeric;
begin
  select s.price into v_price from public.sales s where s.id = new.sale_id;
  select coalesce(sum(p.amount), 0) into v_paid from public.sale_payments p where p.sale_id = new.sale_id;
  if v_paid > v_price then
    raise exception 'Payments (%) would be more than the price (%).', v_paid, v_price;
  end if;
  if v_paid < 0 then
    raise exception 'Payments on a sale cannot go below zero.';
  end if;
  return null;
end $$;

drop trigger if exists sale_total on public.sale_payments;
create constraint trigger sale_total after insert on public.sale_payments
  for each row execute function private.check_sale_total();

-- A sale price can't be lowered below what is already paid.
create or replace function private.check_sale_price() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.price < (select coalesce(sum(amount), 0) from public.sale_payments where sale_id = new.id) then
    raise exception 'The price cannot be less than what is already paid.';
  end if;
  return new;
end $$;

drop trigger if exists sale_price on public.sales;
create trigger sale_price before update of price on public.sales
  for each row execute function private.check_sale_price();

-- ---------- Row Level Security ----------
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public'
  loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
alter table private.rpc_requests enable row level security;

-- Nothing is reachable by default; then grant reading table by table.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on schema private from public;
grant usage on schema private to authenticated;

-- Readable by every active user (admin, co-admin, staff)
do $$
declare t text;
begin
  foreach t in array array['settings','lots','lot_lines','laptops','laptop_tests','repairs','photos',
    'customers','bookings','booking_payments','sales','sale_payments','returns','refunds','model_prices',
    'service_partners','service_jobs','sync_ticks','invoices']
  loop
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists user_read on public.%I', t);
    execute format('create policy user_read on public.%I for select to authenticated using (private.is_user())', t);
  end loop;
end $$;

-- Admin and co-admin: suppliers, parts bought for lots
do $$
declare t text;
begin
  foreach t in array array['suppliers','lot_expenses']
  loop
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists manager_read on public.%I', t);
    execute format('create policy manager_read on public.%I for select to authenticated using (private.is_manager())', t);
  end loop;
end $$;

-- Admin only: purchase costs, what the shop owes and spends
do $$
declare t text;
begin
  foreach t in array array['laptop_costs','lot_line_costs','supplier_payments','debts','debt_payments','shop_expenses',
    'service_charges','service_payments']
  loop
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists admin_read on public.%I', t);
    execute format('create policy admin_read on public.%I for select to authenticated using (private.is_admin())', t);
  end loop;
end $$;

-- Profiles: own row, or all rows for admin
grant select on public.profiles to authenticated;
drop policy if exists own_or_admin on public.profiles;
create policy own_or_admin on public.profiles for select to authenticated
  using (id = auth.uid() or private.is_admin());

-- Activity: co-admin never sees admin-only lines (costs, supplier and debt money); staff sees none
grant select on public.activity_log to authenticated;
drop policy if exists read_log on public.activity_log;
create policy read_log on public.activity_log for select to authenticated
  using (private.is_admin() or (private.is_manager() and not admin_only));

-- Laptop details every user may edit directly (everything else goes through RPCs)
grant update (brand, brand_other, model, processor, processor_other, gen, ram_gb, storage_type, storage_gb,
              serial, grade, notes, test_note) on public.laptops to authenticated;
drop policy if exists staff_edit on public.laptops;
create policy staff_edit on public.laptops for update to authenticated
  using (private.is_user()) with check (private.is_user());

-- app_sessions, login_attempts: no policies = no access except the service role (Edge Functions).

-- Helpers called inside policies must be executable by the caller.
revoke all on all functions in schema private from public;
grant execute on function private.my_role(), private.is_admin(), private.is_manager(), private.is_user() to authenticated;
-- Pure helpers used by column defaults, checks and the generated shorthand when a user edits a laptop.
grant execute on function private.today(), private.ordinal(int), private.brands(), private.processors(), private.lead_sources(),
  private.shorthand(text, text, text, text, int, int, text, int), private.service_skills() to authenticated;
alter default privileges in schema private revoke execute on functions from public;

-- ---------------------------------------------------------------------
-- 0003_activity.sql
-- ---------------------------------------------------------------------
-- 0003: activity log, filled by triggers (who, what, when)
-- Messages read like the prototype's log. Lines with costs or what the shop owes are admin_only.

-- Indian money format: ₹1,23,456
create or replace function private.rs(n numeric) returns text
language plpgsql immutable set search_path = '' as $$
declare s text := round(abs(coalesce(n, 0)))::bigint::text; h text;
begin
  if length(s) > 3 then
    h := regexp_replace(left(s, length(s) - 3), '(\d)(?=(\d\d)+$)', '\1,', 'g');
    s := h || ',' || right(s, 3);
  end if;
  return case when n < 0 then '-₹' else '₹' end || s;
end $$;

create or replace function private.log(p_action text, p_entity text, p_entity_id text, p_message text, p_admin_only boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare v_id uuid := auth.uid(); v_name text; v_role text;
begin
  if current_setting('app.no_log', true) = 'on' then return; end if;   -- set during backup import
  select p.name, p.role into v_name, v_role from public.profiles p where p.id = v_id;
  insert into public.activity_log (actor_id, actor_name, actor_role, action, entity, entity_id, message, admin_only)
  values (case when v_name is null then null else v_id end, coalesce(v_name, 'System'), v_role,
          p_action, p_entity, p_entity_id, p_message, p_admin_only);
end $$;

-- Name to show for a customer; sales without a name show the lead source ("OLX customer").
create or replace function private.cust_label(p_name text, p_lead text) returns text
language sql immutable set search_path = '' as $$
  select coalesce(nullif(btrim(p_name), ''), coalesce(p_lead, 'Walk-in') || ' customer')
$$;

-- ' – note' after a log line when the payment has a note
create or replace function private.note_suffix(p text) returns text
language sql immutable set search_path = '' as $$ select case when btrim(coalesce(p, '')) <> '' then ' – ' || btrim(p) else '' end $$;

create or replace function private.lap_code(p_id uuid) returns text
language sql stable set search_path = '' as $$ select code from public.laptops where id = p_id $$;

-- ---------- laptops ----------
create or replace function private.log_laptops_ins() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in
    select n.lot_id, count(*) c, min(n.code) first_code,
           max(coalesce(nullif(n.model, ''), nullif(n.shorthand, ''))) model, max(n.notes) note,
           lo.prefix, s.code sup_code
    from new_rows n join public.lots lo on lo.id = n.lot_id join public.suppliers s on s.id = lo.supplier_id
    group by n.lot_id, lo.prefix, s.code
  loop
    if r.sup_code = '00' then
      perform private.log('exchange_in', 'laptop', r.first_code,
        format('Took %s in exchange (%s), new code %s', coalesce(nullif(r.model, ''), 'a laptop'), r.note, r.first_code));
    else
      perform private.log('lot_created', 'lot', r.prefix,
        format('Created lot %s with %s laptop%s', r.prefix, r.c, case when r.c = 1 then '' else 's' end));
    end if;
  end loop;
  return null;
end $$;
drop trigger if exists log_ins on public.laptops;
create trigger log_ins after insert on public.laptops referencing new table as new_rows
  for each statement execute function private.log_laptops_ins();

create or replace function private.log_laptops_upd() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.shorthand is distinct from old.shorthand then perform private.log('edit', 'laptop', new.code, format('Changed specs of %s to "%s"', new.code, new.shorthand)); end if;
  if new.model     is distinct from old.model     then perform private.log('edit', 'laptop', new.code, format('Changed model of %s to "%s"', new.code, new.model)); end if;
  if new.serial    is distinct from old.serial    then perform private.log('edit', 'laptop', new.code, format('Changed serial of %s to "%s"', new.code, new.serial)); end if;
  if new.grade     is distinct from old.grade     then perform private.log('edit', 'laptop', new.code, format('Changed grade of %s to "%s"', new.code, new.grade)); end if;
  if new.notes     is distinct from old.notes     then perform private.log('edit', 'laptop', new.code, format('Changed notes of %s to "%s"', new.code, new.notes)); end if;
  if new.test_note is distinct from old.test_note then perform private.log('edit', 'laptop', new.code, format('Changed test notes of %s to "%s"', new.code, new.test_note)); end if;
  return null;
end $$;
drop trigger if exists log_upd on public.laptops;
create trigger log_upd after update on public.laptops for each row execute function private.log_laptops_upd();

-- ---------- costs (admin only) ----------
create or replace function private.log_costs_ins() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in
    select lo.prefix, sum(n.cost) total
    from new_rows n join public.laptops l on l.id = n.laptop_id join public.lots lo on lo.id = l.lot_id
    where n.source = 'lot'
    group by lo.prefix
  loop
    perform private.log('lot_cost', 'lot', r.prefix, format('Lot cost %s for %s', private.rs(r.total), r.prefix), true);
  end loop;
  return null;
end $$;
drop trigger if exists log_ins on public.laptop_costs;
create trigger log_ins after insert on public.laptop_costs referencing new table as new_rows
  for each statement execute function private.log_costs_ins();

-- ---------- tests ----------
create or replace function private.log_tests_ins() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in select n.laptop_id, n.test from new_rows n where n.result = 'fail' loop
    perform private.log('test_fail', 'laptop', private.lap_code(r.laptop_id),
      format('%s: %s test failed', private.lap_code(r.laptop_id), r.test));
  end loop;
  for r in
    select distinct n.laptop_id from new_rows n
    where n.result = 'pass'
      and (select count(*) from public.laptop_tests t where t.laptop_id = n.laptop_id and t.result = 'pass') = 10
  loop
    perform private.log('tests_passed', 'laptop', private.lap_code(r.laptop_id),
      format('%s passed all tests', private.lap_code(r.laptop_id)));
  end loop;
  return null;
end $$;
drop trigger if exists log_ins on public.laptop_tests;
create trigger log_ins after insert on public.laptop_tests referencing new table as new_rows
  for each statement execute function private.log_tests_ins();

-- ---------- repairs, photos ----------
create or replace function private.log_repairs() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c text := private.lap_code(new.laptop_id);
begin
  if tg_op = 'INSERT' and new.lot_expense_id is not null then
    perform private.log('repair', 'laptop', c, format('Fitted %s from lot stock to %s', new.work, c));
  elsif tg_op = 'INSERT' then
    perform private.log('repair', 'laptop', c, format('Repair on %s: %s, %s', c, new.work, private.rs(new.amount)));
  elsif new.deleted_at is not null and old.deleted_at is null then
    perform private.log('repair_deleted', 'laptop', c, format('Deleted repair on %s: %s, %s', c, new.work, private.rs(new.amount)));
  end if;
  return null;
end $$;
drop trigger if exists log_chg on public.repairs;
create trigger log_chg after insert or update on public.repairs for each row execute function private.log_repairs();

create or replace function private.log_photos() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c text := private.lap_code(new.laptop_id);
begin
  perform private.log('photo', 'laptop', c, format('Added a photo to %s', c));
  return null;
end $$;
drop trigger if exists log_ins on public.photos;
create trigger log_ins after insert on public.photos for each row execute function private.log_photos();

-- ---------- sales and payments ----------
create or replace function private.log_sales() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c text := private.lap_code(new.laptop_id);
begin
  if tg_op = 'INSERT' then
    perform private.log('sale', 'laptop', c, format('Sold %s to %s for %s', c, private.cust_label(new.customer_name, new.lead_source), private.rs(new.price)));
  elsif new.status = 'returned' and old.status = 'active' then
    perform private.log('return', 'laptop', c, format('%s returned by %s', c, private.cust_label(new.customer_name, new.lead_source)));
  elsif new.status = 'voided' and old.status = 'active' then
    perform private.log('undo_sale', 'laptop', c,
      format('Undid sale of %s to %s, payments reversed%s', c, private.cust_label(new.customer_name, new.lead_source),
             case when coalesce(new.void_reason, '') <> '' then ' (' || new.void_reason || ')' else '' end));
  end if;
  return null;
end $$;
drop trigger if exists log_chg on public.sales;
create trigger log_chg after insert or update on public.sales for each row execute function private.log_sales();

create or replace function private.log_sale_payments() returns trigger
language plpgsql security definer set search_path = '' as $$
declare s record;
begin
  -- advances carried into a sale, exchanges and reversals are already described by other lines
  if new.booking_payment_id is not null or new.reversal_of is not null or new.method = 'Exchange' then
    return null;
  end if;
  select private.cust_label(sa.customer_name, sa.lead_source) customer_name, l.code into s from public.sales sa join public.laptops l on l.id = sa.laptop_id where sa.id = new.sale_id;
  perform private.log('payment', 'laptop', s.code,
    format('Received %s (%s) from %s for %s%s', private.rs(new.amount), new.method, s.customer_name, s.code, private.note_suffix(new.note)));
  return null;
end $$;
drop trigger if exists log_ins on public.sale_payments;
create trigger log_ins after insert on public.sale_payments for each row execute function private.log_sale_payments();

-- ---------- bookings ----------
create or replace function private.log_bookings() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c text := private.lap_code(new.laptop_id);
begin
  if tg_op = 'INSERT' then
    perform private.log('booking', 'laptop', c, format('Booked %s for %s', c, private.cust_label(new.customer_name, new.lead_source)));
  elsif new.status = 'cancelled' and old.status = 'open' then
    perform private.log('booking_cancelled', 'laptop', c, format('Cancelled booking of %s by %s%s', c,
      private.cust_label(new.customer_name, new.lead_source),
      case new.advance_status when 'held' then ', advance held for admin or co-admin'
                              when 'kept' then ', advance kept' when 'refunded' then ', advance refunded' else '' end));
  elsif old.advance_status = 'held' and new.advance_status in ('refunded','kept') then
    perform private.log('advance_settled', 'laptop', c, format('Held advance from %s for %s: %s',
      private.cust_label(new.customer_name, new.lead_source), c, new.advance_status));
  end if;
  return null;
end $$;
drop trigger if exists log_chg on public.bookings;
create trigger log_chg after insert or update on public.bookings for each row execute function private.log_bookings();

create or replace function private.log_booking_payments() returns trigger
language plpgsql security definer set search_path = '' as $$
declare b record;
begin
  select private.cust_label(bo.customer_name, bo.lead_source) customer_name, l.code into b from public.bookings bo join public.laptops l on l.id = bo.laptop_id where bo.id = new.booking_id;
  perform private.log('advance', 'laptop', b.code,
    format('Advance %s (%s) from %s for %s%s', private.rs(new.amount), new.method, b.customer_name, b.code, private.note_suffix(new.note)));
  return null;
end $$;
drop trigger if exists log_ins on public.booking_payments;
create trigger log_ins after insert on public.booking_payments for each row execute function private.log_booking_payments();

create or replace function private.log_refunds() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.log('refund', 'refund', new.id::text, format('Refund %s (%s): %s%s', private.rs(new.amount), new.method, new.label, private.note_suffix(new.note)));
  return null;
end $$;
drop trigger if exists log_ins on public.refunds;
create trigger log_ins after insert on public.refunds for each row execute function private.log_refunds();

-- ---------- suppliers, debts (money lines are admin only) ----------
create or replace function private.log_suppliers() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.code <> '00' then
    perform private.log('supplier', 'supplier', new.code, format('Added supplier %s, %s', new.code, new.name));
  end if;
  return null;
end $$;
drop trigger if exists log_ins on public.suppliers;
create trigger log_ins after insert on public.suppliers for each row execute function private.log_suppliers();

create or replace function private.log_supplier_payments() returns trigger
language plpgsql security definer set search_path = '' as $$
declare n text;
begin
  select name into n from public.suppliers where id = new.supplier_id;
  perform private.log('supplier_payment', 'supplier', new.supplier_id::text,
    format('%s %s (%s) to supplier %s%s', case when new.amount < 0 then 'Reversed payment of' else 'Paid' end,
           private.rs(abs(new.amount)), new.method, n, private.note_suffix(new.note)), true);
  return null;
end $$;
drop trigger if exists log_ins on public.supplier_payments;
create trigger log_ins after insert on public.supplier_payments for each row execute function private.log_supplier_payments();

create or replace function private.log_debts() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.log('debt', 'debt', new.id::text, format('Added debt: %s, %s', new.name, private.rs(new.amount)), true);
  elsif new.deleted_at is not null and old.deleted_at is null then
    perform private.log('debt_deleted', 'debt', new.id::text, format('Deleted debt: %s', new.name), true);
  end if;
  return null;
end $$;
drop trigger if exists log_chg on public.debts;
create trigger log_chg after insert or update on public.debts for each row execute function private.log_debts();

create or replace function private.log_debt_payments() returns trigger
language plpgsql security definer set search_path = '' as $$
declare n text;
begin
  select name into n from public.debts where id = new.debt_id;
  perform private.log('debt_payment', 'debt', new.debt_id::text,
    format('%s %s (%s) for %s%s', case when new.amount < 0 then 'Reversed payment of' else 'Paid' end,
           private.rs(abs(new.amount)), new.method, n, private.note_suffix(new.note)), true);
  return null;
end $$;
drop trigger if exists log_ins on public.debt_payments;
create trigger log_ins after insert on public.debt_payments for each row execute function private.log_debt_payments();

-- ---------- lot expenses, shop expenses ----------
create or replace function private.log_lot_expenses() returns trigger
language plpgsql security definer set search_path = '' as $$
declare p text;
begin
  select prefix into p from public.lots where id = new.lot_id;
  if tg_op = 'INSERT' then
    perform private.log('lot_expense', 'lot', p, format('Parts for lot %s: %s x %s, %s%s', p, new.count, new.type, private.rs(new.amount), private.note_suffix(new.note)));
  elsif new.deleted_at is not null and old.deleted_at is null then
    perform private.log('lot_expense_deleted', 'lot', p, format('Deleted parts for lot %s: %s x %s, %s', p, new.count, new.type, private.rs(new.amount)));
  end if;
  return null;
end $$;
drop trigger if exists log_chg on public.lot_expenses;
create trigger log_chg after insert or update on public.lot_expenses for each row execute function private.log_lot_expenses();

create or replace function private.log_shop_expenses() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.log('shop_expense', 'shop_expense', new.id::text,
      format('Shop expense: %s %s (%s)%s', new.type, private.rs(new.amount), new.method,
             case when new.note <> '' then ', ' || new.note else '' end), true);
  elsif new.deleted_at is not null and old.deleted_at is null then
    perform private.log('shop_expense_deleted', 'shop_expense', new.id::text,
      format('Deleted shop expense: %s %s', new.type, private.rs(new.amount)), true);
  end if;
  return null;
end $$;
drop trigger if exists log_chg on public.shop_expenses;
create trigger log_chg after insert or update on public.shop_expenses for each row execute function private.log_shop_expenses();

-- ---------- prices, settings ----------
create or replace function private.log_prices() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    perform private.log('price', 'model', old.shorthand, format('Set usual price of %s to none', old.shorthand));
  else
    perform private.log('price', 'model', new.shorthand, format('Set usual price of %s to %s', new.shorthand, private.rs(new.price)));
  end if;
  return null;
end $$;
drop trigger if exists log_chg on public.model_prices;
create trigger log_chg after insert or update or delete on public.model_prices for each row execute function private.log_prices();

create or replace function private.log_settings() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.log('settings', 'settings', '1', 'Changed settings');
  return null;
end $$;
drop trigger if exists log_upd on public.settings;
create trigger log_upd after update on public.settings for each row execute function private.log_settings();

-- ---------- service partners ----------
create or replace function private.partner_label(p_id uuid) returns text
language sql stable set search_path = '' as $$
  select coalesce(nullif(btrim(shop_name), ''), name) from public.service_partners where id = p_id
$$;

create or replace function private.actor_name() returns text
language sql stable security definer set search_path = '' as $$
  select coalesce((select name from public.profiles where id = auth.uid()), 'Someone')
$$;

create or replace function private.log_partners() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.log('partner', 'partner', new.id::text, format('Added service partner %s', private.partner_label(new.id)));
  elsif new.active is distinct from old.active then
    perform private.log('partner', 'partner', new.id::text,
      format('%s service partner %s', case when new.active then 'Turned on' else 'Turned off' end, private.partner_label(new.id)));
  end if;
  return null;
end $$;
drop trigger if exists log_chg on public.service_partners;
create trigger log_chg after insert or update on public.service_partners for each row execute function private.log_partners();

-- "Imran gave 01-04-11-26-003 to Ravi Chip Repair for screen"
create or replace function private.log_service_jobs() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c text := private.lap_code(new.laptop_id); p text := private.partner_label(new.partner_id);
begin
  if tg_op = 'INSERT' then
    perform private.log('service_out', 'laptop', c, format('%s gave %s to %s for %s%s', private.actor_name(), c, p,
      coalesce(nullif(lower(array_to_string(new.issues, ', ')), ''), 'service'),
      case when new.kind = 'warranty' then ' (warranty)' else '' end));
  elsif new.status = 'returned' and old.status = 'out' then
    perform private.log('service_back', 'laptop', c, format('%s received %s back from %s: %s', private.actor_name(), c, p,
      case new.outcome when 'fixed' then 'fixed' when 'not_fixed' then 'not fixed' else 'returned without work' end));
  end if;
  return null;
end $$;
drop trigger if exists log_chg on public.service_jobs;
create trigger log_chg after insert or update on public.service_jobs for each row execute function private.log_service_jobs();

create or replace function private.log_service_charges() returns trigger
language plpgsql security definer set search_path = '' as $$
declare j record;
begin
  select laptop_id, partner_id into j from public.service_jobs where id = new.job_id;
  perform private.log('service_charge', 'laptop', private.lap_code(j.laptop_id),
    format('Service charge %s for %s (%s)', private.rs(new.charge), private.lap_code(j.laptop_id), private.partner_label(j.partner_id)), true);
  return null;
end $$;
drop trigger if exists log_chg on public.service_charges;
create trigger log_chg after insert or update on public.service_charges for each row execute function private.log_service_charges();

create or replace function private.log_service_payments() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.log('service_payment', 'partner', new.partner_id::text,
    format('Paid %s (%s) to service partner %s%s', private.rs(new.amount), new.method, private.partner_label(new.partner_id), private.note_suffix(new.note)), true);
  return null;
end $$;
drop trigger if exists log_ins on public.service_payments;
create trigger log_ins after insert on public.service_payments for each row execute function private.log_service_payments();

-- ---------- live sync ----------
-- Every activity line also drops a data-free tick that all roles can receive through Realtime.
create or replace function private.tick() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.sync_ticks default values;
  delete from public.sync_ticks where at < now() - interval '1 hour';
  return null;
end $$;
drop trigger if exists tick on public.activity_log;
create trigger tick after insert on public.activity_log for each statement execute function private.tick();

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                     and schemaname = 'public' and tablename = 'sync_ticks') then
    alter publication supabase_realtime add table public.sync_ticks;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 0004_rpc.sql
-- ---------------------------------------------------------------------
-- 0004: write functions (RPCs). One transaction each, rows locked, role checked first.
-- Errors are plain English; the app shows them as a toast.
-- hint = 'confirm_tests' means: ask the admin "Sell anyway?" and call again with p_override_tests = true.

-- =====================================================================
-- private helpers
-- =====================================================================
create or replace function private.norm_mobile(p text) returns text
language plpgsql immutable set search_path = '' as $$
declare d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
begin
  if d = '' then return null; end if;                     -- no mobile given
  if length(d) = 12 and left(d, 2) = '91' then d := right(d, 10);
  elsif length(d) = 11 and left(d, 1) = '0' then d := right(d, 10);
  end if;
  if length(d) not between 6 and 15 then
    raise exception 'Enter a valid mobile number';
  end if;
  return d;
end $$;

create or replace function private.check_method(p text) returns void
language plpgsql immutable set search_path = '' as $$
begin
  if p is null or p not in ('Cash','UPI','Bank') then raise exception 'Choose Cash, UPI or Bank'; end if;
end $$;

create or replace function private.check_amount(p numeric, p_what text default 'an amount') returns void
language plpgsql immutable set search_path = '' as $$
begin
  if p is null or p <= 0 then raise exception 'Enter %', p_what; end if;
  if p <> round(p, 2) then raise exception 'Use at most 2 decimal places'; end if;
end $$;

create or replace function private.check_lead(p_lead text, p_type text) returns void
language plpgsql immutable set search_path = '' as $$
begin
  if p_lead is null or not (p_lead = any (private.lead_sources())) then
    raise exception 'Choose where the customer came from';
  end if;
  if p_type is null or p_type not in ('Retail','Dealer') then raise exception 'Choose Retail or Dealer'; end if;
end $$;

-- Idempotency. Returns the earlier result if this client_ref was already used.
create or replace function private.idem_get(p_ref uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare n int; v jsonb;
begin
  if p_ref is null then return null; end if;
  insert into private.rpc_requests (client_ref) values (p_ref) on conflict do nothing;
  get diagnostics n = row_count;
  if n = 1 then return null; end if;
  select result into v from private.rpc_requests where client_ref = p_ref;
  return coalesce(v, '{}'::jsonb) || '{"repeat": true}'::jsonb;
end $$;

create or replace function private.idem_put(p_ref uuid, p_result jsonb) returns jsonb
language plpgsql set search_path = '' as $$
begin
  if p_ref is not null then
    update private.rpc_requests set result = p_result where client_ref = p_ref;
  end if;
  return p_result;
end $$;

create or replace function private.tests_passed(p_laptop uuid) returns boolean
language sql stable set search_path = '' as $$
  select count(*) = 10 from public.laptop_tests where laptop_id = p_laptop and result = 'pass'
$$;

create or replace function private.cost_of(p_laptop uuid) returns numeric
language sql stable set search_path = '' as $$
  select cost from public.laptop_costs where laptop_id = p_laptop
$$;

-- All repairs on the laptop, including parts fitted from lot stock.
create or replace function private.repairs_of(p_laptop uuid) returns numeric
language sql stable set search_path = '' as $$
  select coalesce(sum(amount), 0) from public.repairs where laptop_id = p_laptop and deleted_at is null
$$;

-- Units of a lot expense already fitted to single laptops, and their value.
create or replace function private.fitted(p_expense uuid, out units int, out value numeric)
language sql stable set search_path = '' as $$
  select count(*)::int, coalesce(sum(amount), 0) from public.repairs
  where lot_expense_id = p_expense and deleted_at is null
$$;

-- This laptop's equal share of its lot's parts/expenses (whole lot, or its own line),
-- leaving out units fitted to single laptops (those are in repairs_of instead).
create or replace function private.lot_share(p_laptop uuid) returns numeric
language sql stable set search_path = '' as $$
  select coalesce(sum(
           (e.amount - (select f.value from private.fitted(e.id) f))
           / (select count(*) from public.laptops x
              where x.lot_id = e.lot_id and (e.line_id is null or x.line_id = e.line_id))
         ), 0)
  from public.laptops l
  join public.lot_expenses e on e.lot_id = l.lot_id and e.deleted_at is null
                            and (e.line_id is null or e.line_id = l.line_id)
  where l.id = p_laptop
$$;

-- Service charges on this laptop while it was shop stock (warranty jobs are counted separately).
create or replace function private.service_cost(p_laptop uuid) returns numeric
language sql stable set search_path = '' as $$
  select coalesce(sum(c.charge), 0) from public.service_jobs j join public.service_charges c on c.job_id = j.id
  where j.laptop_id = p_laptop and j.kind = 'stock'
$$;

-- Everything this laptop cost the shop. Null when the purchase cost is missing.
create or replace function private.full_cost(p_laptop uuid) returns numeric
language sql stable set search_path = '' as $$
  select private.cost_of(p_laptop) + private.repairs_of(p_laptop) + private.lot_share(p_laptop)
       + private.service_cost(p_laptop)
$$;

create or replace function private.sale_paid(p_sale uuid) returns numeric
language sql stable set search_path = '' as $$
  select coalesce(sum(amount), 0) from public.sale_payments where sale_id = p_sale
$$;

-- Gross profit of a sale; null when the laptop's cost is missing.
create or replace function private.profit(p_sale uuid) returns numeric
language sql stable set search_path = '' as $$
  select round(s.price - private.full_cost(s.laptop_id), 2) from public.sales s where s.id = p_sale
$$;

-- Returns null when there is no mobile.
create or replace function private.upsert_customer(p_mobile text, p_name text, p_address text, p_type text) returns uuid
language plpgsql set search_path = '' as $$
declare v uuid; m text := private.norm_mobile(p_mobile);
begin
  if m is null then return null; end if;
  insert into public.customers (mobile, name, address, customer_type)
  values (m, btrim(coalesce(p_name, '')), btrim(coalesce(p_address, '')), coalesce(p_type, 'Retail'))
  on conflict (mobile) do update
    set name = case when excluded.name <> '' then excluded.name else public.customers.name end,
        address = case when excluded.address <> '' then excluded.address else public.customers.address end,
        customer_type = excluded.customer_type
  returning id into v;
  return v;
end $$;

create or replace function private.supplier_due(p_supplier uuid) returns numeric
language sql stable set search_path = '' as $$
  select case when s.code = '00' then 0 else
    coalesce((select sum(c.cost) from public.laptop_costs c join public.laptops l on l.id = c.laptop_id
              join public.lots lo on lo.id = l.lot_id where lo.supplier_id = s.id), 0)
  - coalesce((select sum(p.amount) from public.supplier_payments p where p.supplier_id = s.id), 0) end
  from public.suppliers s where s.id = p_supplier
$$;

-- Write each laptop's purchase cost from its line: equal split, leftover paisa on the last piece.
create or replace function private.write_line_costs(p_line uuid) returns void
language plpgsql set search_path = '' as $$
declare v_cost numeric; v_n int; v_per numeric; v_last int;
begin
  select line_cost into v_cost from public.lot_line_costs where line_id = p_line;
  delete from public.laptop_costs c using public.laptops l where l.id = c.laptop_id and l.line_id = p_line;
  if v_cost is null then return; end if;
  select count(*), max(piece_no) into v_n, v_last from public.laptops where line_id = p_line;
  v_per := trunc(v_cost / v_n, 2);
  insert into public.laptop_costs (laptop_id, cost, source)
  select l.id, case when l.piece_no = v_last then v_cost - v_per * (v_n - 1) else v_per end, 'lot'
  from public.laptops l where l.line_id = p_line;
end $$;

-- Exchange laptop goes into lot 00-01-MM-YY (this month), cost = exchange value.
create or replace function private.new_exchange_laptop(p_model text, p_value numeric, p_from text) returns jsonb
language plpgsql set search_path = '' as $$
declare v_sup uuid; v_lot uuid; v_line uuid; v_d date := private.today(); v_prefix text; v_no int; v_code text; v_id uuid;
begin
  select id into v_sup from public.suppliers where code = '00';
  if v_sup is null then
    insert into public.suppliers (code, name) values ('00', 'Customer exchange') returning id into v_sup;
  end if;
  v_prefix := '00-01-' || to_char(v_d, 'MM') || '-' || to_char(v_d, 'YY');
  insert into public.lots (supplier_id, lot_no, month, year, prefix, kind, bought_on)
  values (v_sup, 1, extract(month from v_d)::int, extract(year from v_d)::int, v_prefix, 'exchange', v_d)
  on conflict (prefix) do nothing;
  select id into v_lot from public.lots where prefix = v_prefix for update;
  select id into v_line from public.lot_lines where lot_id = v_lot and line_no = 1;
  select coalesce(max(piece_no), 0) + 1 into v_no from public.laptops where lot_id = v_lot;
  if v_line is null then
    insert into public.lot_lines (lot_id, line_no, is_mixed, qty) values (v_lot, 1, true, 1) returning id into v_line;
  else
    update public.lot_lines set qty = v_no where id = v_line;
  end if;
  v_code := v_prefix || '-' || lpad(v_no::text, 3, '0');
  insert into public.laptops (lot_id, line_id, piece_no, code, model, notes, added_on)
  values (v_lot, v_line, v_no, v_code, btrim(p_model), 'exchanged by ' || p_from, v_d)
  returning id into v_id;
  insert into public.laptop_costs (laptop_id, cost, source) values (v_id, p_value, 'exchange');
  return jsonb_build_object('id', v_id, 'code', v_code);
end $$;

-- Functions whose arguments changed are dropped first, so re-running this file never leaves an old version behind.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where (n.nspname = 'private' and p.proname in ('do_sell', 'refund_advance'))
              or (n.nspname = 'public' and p.proname in ('sell_laptop', 'complete_booking', 'sell_laptops_bulk', 'add_sale_payment',
                  'receive_customer_payment', 'book_laptop', 'cancel_booking', 'settle_held_advance', 'return_sale',
                  'pay_supplier', 'pay_debt', 'save_settings'))
  loop
    execute 'drop function ' || r.sig;
  end loop;
end $$;

-- Long random token behind the warranty QR on a bill (64 hex characters, from the database's secure random source).
create or replace function private.new_token() returns text
language sql volatile set search_path = '' as $$
  select replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
$$;

-- Next invoice number. The settings row is locked while it counts up, so two phones can never get the same number,
-- and invoices.no is a primary key on top of that.
create or replace function private.next_invoice(p_date date, p_group uuid) returns int
language plpgsql set search_path = '' as $$
declare v_no int;
begin
  update public.settings set invoice_next = invoice_next + 1 where id = 1 returning invoice_next - 1 into v_no;
  if exists (select 1 from public.invoices where no = v_no) then
    raise exception 'Invoice number INV-% is already used. Ask the admin to set the next invoice number in Settings.', v_no;
  end if;
  insert into public.invoices (no, issued_on, bulk_group) values (v_no, p_date, p_group);
  return v_no;
end $$;

-- Pay a booking's whole advance back, by the method it was paid in.
create or replace function private.refund_advance(b public.bookings, p_note text default '') returns numeric
language plpgsql set search_path = '' as $$
declare v_adv numeric; v_method text; v_code text;
begin
  select coalesce(sum(amount), 0) into v_adv from public.booking_payments where booking_id = b.id;
  if v_adv = 0 then return 0; end if;
  select method into v_method from public.booking_payments where booking_id = b.id order by paid_on, created_at limit 1;
  select code into v_code from public.laptops where id = b.laptop_id;
  insert into public.refunds (booking_id, refunded_on, amount, method, label, note)
  values (b.id, private.today(), v_adv, v_method,
          format('Advance back to %s for %s', private.cust_label(b.customer_name, b.lead_source), v_code), btrim(coalesce(p_note, '')));
  return v_adv;
end $$;

-- A laptop at service cannot be sold, booked, handed over, returned or undone.
create or replace function private.service_guard(p_laptop uuid) returns void
language plpgsql stable set search_path = '' as $$
declare j record;
begin
  select private.partner_label(partner_id) p, given_on into j from public.service_jobs where laptop_id = p_laptop and status = 'out';
  if found then
    raise exception 'This laptop is with % since %', j.p, to_char(j.given_on, 'DD/MM/YYYY');
  end if;
end $$;

-- Warranty months: the given value, or the shop default when there is a mobile to attach it to.
create or replace function private.pick_warranty(p_given int, p_default int, p_mobile text, p_what text) returns int
language plpgsql immutable set search_path = '' as $$
declare v int := coalesce(p_given, case when p_mobile is null then 0 else p_default end, 0);
begin
  if v not between 0 and 60 then raise exception '% warranty must be between 0 and 60 months', p_what; end if;
  if v > 0 and p_mobile is null then raise exception 'Enter the mobile number to give a warranty'; end if;
  return v;
end $$;

-- Core of a single sale (also used to complete a booking).
create or replace function private.do_sell(
  p_laptop_id uuid, p_name text, p_mobile text, p_address text, p_lead text, p_type text,
  p_price numeric, p_paid numeric, p_method text, p_ref text, p_sold_on date, p_warranty int,
  p_ex_model text, p_ex_value numeric, p_override boolean, p_acc_warranty int default null, p_note text default ''
) returns jsonb
language plpgsql set search_path = '' as $$
declare
  v_role text := private.require_user();
  l public.laptops; bk public.bookings; st public.settings;
  v_adv numeric := 0; v_paid numeric := coalesce(p_paid, 0); v_exv numeric := nullif(coalesce(p_ex_value, 0), 0);
  v_date date := coalesce(p_sold_on, private.today()); v_warr int; v_acc int; v_cust uuid; v_sale uuid; v_ex jsonb; v_total numeric;
  v_mobile text := private.norm_mobile(p_mobile); v_name text := btrim(coalesce(p_name, ''));
  v_lead text := p_lead; v_type text := coalesce(p_type, 'Retail'); v_addr text := btrim(coalesce(p_address, ''));
  v_inv int; v_token text := private.new_token();
begin
  select * into l from public.laptops where id = p_laptop_id for update;
  if not found then raise exception 'Laptop not found.'; end if;
  perform private.service_guard(l.id);
  if l.status = 'sold' then raise exception '% is already sold.', l.code; end if;

  select * into bk from public.bookings where laptop_id = l.id and status = 'open' for update;
  if bk.id is not null then
    -- completing a booking: anything not typed again comes from the booking
    select coalesce(sum(amount), 0) into v_adv from public.booking_payments where booking_id = bk.id;
    if v_mobile is null then select mobile into v_mobile from public.customers where id = bk.customer_id; end if;
    if v_name = '' then v_name := bk.customer_name; end if;
    if v_addr = '' then v_addr := bk.customer_address; end if;
    v_lead := coalesce(v_lead, bk.lead_source);
    v_type := coalesce(p_type, bk.customer_type);
  end if;

  perform private.check_lead(v_lead, v_type);
  if coalesce(p_price, 0) <= 0 then raise exception 'Enter the selling price'; end if;
  perform private.check_amount(p_price, 'the selling price');
  if v_paid < 0 then raise exception 'Paid amount cannot be below zero'; end if;
  if v_paid > 0 then perform private.check_amount(v_paid); perform private.check_method(p_method); end if;
  if v_date > private.today() then raise exception 'The sale date cannot be in the future'; end if;

  select * into st from public.settings where id = 1;
  v_warr := private.pick_warranty(p_warranty, st.default_warranty_months, v_mobile, 'Laptop');
  v_acc := private.pick_warranty(p_acc_warranty, st.accessory_warranty_months, v_mobile, 'Charger and battery');

  -- staff never sees the floor, so a price below it is refused instead of confirmed
  if v_role = 'staff' and p_price < coalesce(round(private.full_cost(l.id), 0), 0) then
    raise exception 'This price is too low. Ask the admin.';
  end if;

  if not private.tests_passed(l.id) then
    if v_role <> 'admin' then
      raise exception 'All tests must pass before selling. Ask the admin.';
    end if;
    if not coalesce(p_override, false) then
      raise exception 'Not every test has passed on %. Sell anyway?', l.code using hint = 'confirm_tests';
    end if;
  end if;

  if v_exv is not null then
    if v_exv < 0 or btrim(coalesce(p_ex_model, '')) = '' then
      raise exception 'Enter the old laptop model and its value, or close the exchange section';
    end if;
    perform private.check_amount(v_exv, 'the exchange value');
  end if;

  v_total := v_adv + v_paid + coalesce(v_exv, 0);
  if v_total > p_price then
    raise exception 'Advance, exchange and paid now add up to more than the price';
  end if;
  if v_total < p_price and v_mobile is null then
    raise exception 'Enter the mobile number when money is still due';
  end if;

  v_cust := private.upsert_customer(v_mobile, v_name, v_addr, v_type);
  if current_setting('app.no_invoice', true) is distinct from 'on' then v_inv := private.next_invoice(v_date, null); end if;
  insert into public.sales (laptop_id, customer_id, customer_name, customer_address, lead_source, customer_type,
                            sold_on, price, warranty_months, accessory_warranty_months, booking_id, invoice_no, warranty_token)
  values (l.id, v_cust, v_name, v_addr, v_lead, v_type, v_date, p_price, v_warr, v_acc, bk.id, v_inv, v_token)
  returning id into v_sale;

  if bk.id is not null then
    insert into public.sale_payments (sale_id, paid_on, amount, method, ref, note, booking_payment_id)
    select v_sale, bp.paid_on, bp.amount, bp.method, bp.ref, bp.note, bp.id
    from public.booking_payments bp where bp.booking_id = bk.id order by bp.paid_on, bp.created_at;
    update public.bookings set status = 'completed' where id = bk.id;
  end if;

  if v_exv is not null then
    v_ex := private.new_exchange_laptop(p_ex_model, v_exv, private.cust_label(v_name, v_lead));
    insert into public.sale_payments (sale_id, paid_on, amount, method, ref)
    values (v_sale, v_date, v_exv, 'Exchange', v_ex ->> 'code');
  end if;

  if v_paid > 0 then
    insert into public.sale_payments (sale_id, paid_on, amount, method, ref, note)
    values (v_sale, v_date, v_paid, p_method, btrim(coalesce(p_ref, '')), btrim(coalesce(p_note, '')));
  end if;

  update public.laptops set status = 'sold' where id = l.id;

  return jsonb_build_object('sale_id', v_sale, 'code', l.code, 'price', p_price,
    'paid', v_total, 'balance', p_price - v_total, 'exchange_code', v_ex ->> 'code',
    'invoice_no', v_inv, 'warranty_token', v_token);
end $$;

-- =====================================================================
-- public RPCs
-- =====================================================================

-- ---------- suppliers and lots ----------
create or replace function public.add_supplier(p_name text, p_phone text default '')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_code text; v_id uuid;
begin
  perform private.require_admin();
  if btrim(coalesce(p_name, '')) = '' then raise exception 'Enter the supplier name'; end if;
  lock table public.suppliers in share row exclusive mode;
  select lpad((coalesce(max(code::int), 0) + 1)::text, 2, '0') into v_code from public.suppliers where code <> '00';
  if v_code::int > 99 then raise exception 'All supplier numbers 01 to 99 are used'; end if;
  insert into public.suppliers (code, name, phone) values (v_code, btrim(p_name), btrim(coalesce(p_phone, '')))
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'code', v_code);
end $$;

-- p_lines: [{"is_mixed":false,"brand":"HP","model":"4440s","processor":"i5","gen":3,"ram_gb":4,
--            "storage_type":"HDD","storage_gb":320,"qty":3,"cost":10500}, ...]   cost null/absent = missing
create or replace function public.create_lot(
  p_supplier_id uuid, p_lot_no int, p_bought_on date, p_lines jsonb,
  p_kind text default 'purchase', p_note text default '', p_client_ref uuid default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.suppliers; v_prefix text; v_lot uuid; v_line uuid; v jsonb; ln jsonb; i int := 0;
        v_piece int := 0; v_qty int; v_total int := 0; v_cost numeric; v_mixed boolean;
begin
  perform private.require_manager();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;

  select * into s from public.suppliers where id = p_supplier_id;
  if not found or s.code = '00' then raise exception 'Choose a supplier'; end if;
  if p_lot_no is null or p_lot_no not between 1 and 99 then raise exception 'Lot no. must be 1 to 99'; end if;
  if p_bought_on is null then raise exception 'Enter the purchase date'; end if;
  if p_bought_on > private.today() then raise exception 'The purchase date cannot be in the future'; end if;
  if p_kind not in ('purchase','opening') then raise exception 'Lot type must be purchase or opening stock'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Add at least one laptop';
  end if;
  if jsonb_array_length(p_lines) > 99 then raise exception 'A lot can have up to 99 kinds of laptops'; end if;
  select coalesce(sum((x ->> 'qty')::int), 0) into v_total from jsonb_array_elements(p_lines) x;
  if v_total > 500 then raise exception 'A lot can have up to 500 laptops'; end if;

  v_prefix := s.code || '-' || lpad(p_lot_no::text, 2, '0') || '-' || to_char(p_bought_on, 'MM') || '-' || to_char(p_bought_on, 'YY');
  if exists (select 1 from public.lots where prefix = v_prefix and deleted_at is not null) then
    raise exception 'Lot % was deleted, so its sticker numbers cannot be used again. Use the next lot number.', v_prefix;
  end if;
  if exists (select 1 from public.lots where prefix = v_prefix) then
    raise exception 'Lot % already exists. Change the lot number.', v_prefix;
  end if;

  insert into public.lots (supplier_id, lot_no, month, year, prefix, kind, bought_on, note)
  values (s.id, p_lot_no, extract(month from p_bought_on)::int, extract(year from p_bought_on)::int,
          v_prefix, p_kind, p_bought_on, btrim(coalesce(p_note, '')))
  returning id into v_lot;

  for ln in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    v_qty := (ln ->> 'qty')::int;
    if v_qty is null or v_qty < 1 then raise exception 'Laptops %: enter how many', i; end if;
    v_cost := (ln ->> 'cost')::numeric;
    if v_cost is not null and (v_cost < 0 or v_cost <> round(v_cost, 2)) then raise exception 'Laptops %: check the cost', i; end if;
    v_mixed := coalesce((ln ->> 'is_mixed')::boolean, false);

    insert into public.lot_lines (lot_id, line_no, is_mixed, brand, brand_other, model, processor, processor_other,
                                  gen, ram_gb, storage_type, storage_gb, qty)
    values (v_lot, i, v_mixed,
            case when v_mixed then null else nullif(ln ->> 'brand', '') end,
            case when v_mixed then '' else btrim(coalesce(ln ->> 'brand_other', '')) end,
            case when v_mixed then '' else btrim(coalesce(ln ->> 'model', '')) end,
            case when v_mixed then null else nullif(ln ->> 'processor', '') end,
            case when v_mixed then '' else btrim(coalesce(ln ->> 'processor_other', '')) end,
            case when v_mixed then null else (ln ->> 'gen')::int end,
            case when v_mixed then null else (ln ->> 'ram_gb')::int end,
            case when v_mixed then null else nullif(ln ->> 'storage_type', '') end,
            case when v_mixed then null else (ln ->> 'storage_gb')::int end,
            v_qty)
    returning id into v_line;
    if v_cost is not null then
      insert into public.lot_line_costs (line_id, line_cost) values (v_line, v_cost);
    end if;

    -- piece numbers run across the whole lot
    insert into public.laptops (lot_id, line_id, piece_no, code, brand, brand_other, model, processor, processor_other,
                                gen, ram_gb, storage_type, storage_gb, added_on)
    select v_lot, v_line, v_piece + g, v_prefix || '-' || lpad((v_piece + g)::text, 3, '0'),
           ll.brand, ll.brand_other, ll.model, ll.processor, ll.processor_other, ll.gen, ll.ram_gb, ll.storage_type, ll.storage_gb,
           p_bought_on
    from generate_series(1, v_qty) g, public.lot_lines ll where ll.id = v_line;
    v_piece := v_piece + v_qty;

    perform private.write_line_costs(v_line);
  end loop;

  v := jsonb_build_object('lot_id', v_lot, 'prefix', v_prefix, 'qty', v_piece,
         'codes', (select jsonb_agg(code order by piece_no) from public.laptops where lot_id = v_lot));
  return private.idem_put(p_client_ref, v);
end $$;

create or replace function public.set_line_cost(p_line_id uuid, p_cost numeric)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ln public.lot_lines; lo public.lots;
begin
  perform private.require_admin();
  select * into ln from public.lot_lines where id = p_line_id for update;
  if not found then raise exception 'These laptops are not in the lot'; end if;
  select * into lo from public.lots where id = ln.lot_id;
  if lo.kind = 'exchange' then raise exception 'Exchange laptops get their cost from the exchange value'; end if;
  if p_cost is not null and (p_cost < 0 or p_cost <> round(p_cost, 2)) then raise exception 'Check the cost'; end if;
  if p_cost is null then
    delete from public.lot_line_costs where line_id = ln.id;
  else
    insert into public.lot_line_costs (line_id, line_cost) values (ln.id, p_cost)
    on conflict (line_id) do update set line_cost = excluded.line_cost;
  end if;
  perform private.write_line_costs(ln.id);
  return jsonb_build_object('prefix', lo.prefix, 'line_no', ln.line_no, 'per_laptop', round(p_cost / ln.qty, 2));
end $$;

-- ---------- lot expenses ----------
create or replace function public.add_lot_expense(
  p_lot_id uuid, p_type text, p_count int, p_amount numeric, p_method text default 'Cash',
  p_line_id uuid default null, p_ref text default '', p_note text default '', p_spent_on date default null,
  p_client_ref uuid default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_id uuid;
begin
  perform private.require_manager();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  perform 1 from public.lots where id = p_lot_id;
  if not found then raise exception 'Lot not found'; end if;
  if p_line_id is not null and not exists (select 1 from public.lot_lines where id = p_line_id and lot_id = p_lot_id) then
    raise exception 'Those laptops are not in this lot';
  end if;
  if p_type is null or p_type not in ('SSD','RAM','Battery','Charger','HDD','Keyboard','Screen','Transport','Repair labour','Other') then
    raise exception 'Choose the expense type';
  end if;
  if p_count is null or p_count < 1 then raise exception 'Enter how many'; end if;
  perform private.check_amount(p_amount);
  perform private.check_method(p_method);
  if coalesce(p_spent_on, private.today()) > private.today() then raise exception 'The date cannot be in the future'; end if;
  insert into public.lot_expenses (lot_id, line_id, spent_on, type, count, amount, method, ref, note)
  values (p_lot_id, p_line_id, coalesce(p_spent_on, private.today()), p_type, p_count, p_amount, p_method,
          btrim(coalesce(p_ref, '')), btrim(coalesce(p_note, '')))
  returning id into v_id;
  return private.idem_put(p_client_ref, jsonb_build_object('lot_expense_id', v_id));
end $$;

create or replace function public.delete_lot_expense(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  if (select units from private.fitted(p_id)) > 0 then
    raise exception 'Some of these parts are fitted to laptops. Delete those repairs first.';
  end if;
  update public.lot_expenses set deleted_at = now(), deleted_by = auth.uid() where id = p_id and deleted_at is null;
  if not found then raise exception 'Expense not found'; end if;
end $$;

-- ---------- tests, repairs, photos ----------
create or replace function public.set_test(p_laptop_id uuid, p_test text, p_result text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_res text := case when p_result = 'ok' then 'pass' else p_result end; v_old text; v_pass int;
begin
  perform private.require_user();
  perform 1 from public.laptops where id = p_laptop_id for update;
  if not found then raise exception 'Laptop not found.'; end if;
  if v_res not in ('pass','fail') then raise exception 'Result must be pass or fail'; end if;
  select result into v_old from public.laptop_tests where laptop_id = p_laptop_id and test = p_test;
  delete from public.laptop_tests where laptop_id = p_laptop_id and test = p_test;
  if v_old is distinct from v_res then          -- tapping the same button again clears it
    insert into public.laptop_tests (laptop_id, test, result) values (p_laptop_id, p_test, v_res);
  end if;
  select count(*) into v_pass from public.laptop_tests where laptop_id = p_laptop_id and result = 'pass';
  if v_pass = 10 then update public.laptops set tested_on = private.today() where id = p_laptop_id; end if;
  return jsonb_build_object('passed', v_pass, 'all_passed', v_pass = 10);
end $$;

create or replace function public.set_all_tests(p_laptop_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_user();
  perform 1 from public.laptops where id = p_laptop_id for update;
  if not found then raise exception 'Laptop not found.'; end if;
  if not private.tests_passed(p_laptop_id) then
    delete from public.laptop_tests where laptop_id = p_laptop_id;
    insert into public.laptop_tests (laptop_id, test, result)
    select p_laptop_id, t, 'pass'
    from unnest(array['Display','Keyboard','Touchpad','Battery','Charging','USB ports','Wi-Fi','Audio','Camera','Storage']) t;
    update public.laptops set tested_on = private.today() where id = p_laptop_id;
  end if;
  return jsonb_build_object('passed', 10, 'all_passed', true);
end $$;

-- p_lot_expense_id set = fit one unit from that lot expense; its amount is worked out here.
create or replace function public.add_repair(
  p_laptop_id uuid, p_work text, p_amount numeric default null, p_lot_expense_id uuid default null, p_client_ref uuid default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_id uuid; l public.laptops; e public.lot_expenses; f record; v_amt numeric := p_amount; v_work text := btrim(coalesce(p_work, ''));
begin
  perform private.require_user();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  select * into l from public.laptops where id = p_laptop_id;
  if not found then raise exception 'Laptop not found.'; end if;

  if p_lot_expense_id is not null then
    select * into e from public.lot_expenses where id = p_lot_expense_id and deleted_at is null for update;
    if not found or e.lot_id <> l.lot_id or (e.line_id is not null and e.line_id <> l.line_id) then
      raise exception 'Those parts were bought for other laptops';
    end if;
    select * into f from private.fitted(e.id);
    if f.units >= e.count then raise exception 'No % left from that purchase', e.type; end if;
    -- one unit; the last unit takes any leftover paisa so the units add up exactly
    v_amt := case when f.units = e.count - 1 then e.amount - f.value else trunc(e.amount / e.count, 2) end;
    if v_work = '' then v_work := e.type || ' (from lot stock)'; end if;
  else
    if v_work = '' then raise exception 'Enter the work done and its cost'; end if;
    perform private.check_amount(v_amt, 'the work done and its cost');
  end if;

  insert into public.repairs (laptop_id, lot_expense_id, work, amount)
  values (p_laptop_id, p_lot_expense_id, v_work, v_amt) returning id into v_id;
  return private.idem_put(p_client_ref, jsonb_build_object('repair_id', v_id, 'amount', v_amt));
end $$;

create or replace function public.delete_repair(p_repair_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  update public.repairs set deleted_at = now(), deleted_by = auth.uid()
  where id = p_repair_id and deleted_at is null;
  if not found then raise exception 'Repair not found'; end if;
end $$;

create or replace function public.add_photo(p_laptop_id uuid, p_url text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_user();
  if coalesce(p_url, '') !~ '^https://res\.cloudinary\.com/[^\s"''<>]+$' then
    raise exception 'Photo link must be a Cloudinary https link';
  end if;
  perform 1 from public.laptops where id = p_laptop_id;
  if not found then raise exception 'Laptop not found.'; end if;
  insert into public.photos (laptop_id, url) values (p_laptop_id, p_url);
end $$;

-- Only the floor price, never the cost itself. Null when the cost is missing ("not set yet").
create or replace function public.safe_price(p_laptop_id uuid)
returns numeric language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_manager();
  return round(private.full_cost(p_laptop_id), 0);
end $$;

-- ---------- sales ----------
create or replace function public.sell_laptop(
  p_laptop_id uuid, p_price numeric, p_lead_source text default null, p_customer_type text default 'Retail',
  p_name text default '', p_mobile text default '', p_address text default '',
  p_paid numeric default 0, p_method text default 'Cash', p_ref text default '',
  p_sold_on date default null, p_warranty_months int default null,
  p_exchange_model text default null, p_exchange_value numeric default null,
  p_override_tests boolean default false, p_client_ref uuid default null,
  p_accessory_warranty_months int default null, p_note text default ''
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  perform private.require_user();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  v := private.do_sell(p_laptop_id, p_name, p_mobile, p_address, p_lead_source, p_customer_type,
                       p_price, p_paid, p_method, p_ref, p_sold_on, p_warranty_months,
                       p_exchange_model, p_exchange_value, p_override_tests, p_accessory_warranty_months, p_note);
  return private.idem_put(p_client_ref, v);
end $$;

-- Name, mobile, lead source and type default to what was entered on the booking.
create or replace function public.complete_booking(
  p_booking_id uuid, p_price numeric, p_lead_source text default null, p_customer_type text default null,
  p_name text default '', p_mobile text default '', p_address text default '',
  p_paid numeric default 0, p_method text default 'Cash', p_ref text default '',
  p_sold_on date default null, p_warranty_months int default null,
  p_exchange_model text default null, p_exchange_value numeric default null,
  p_override_tests boolean default false, p_client_ref uuid default null,
  p_accessory_warranty_months int default null, p_note text default ''
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_laptop uuid;
begin
  perform private.require_user();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  select laptop_id into v_laptop from public.bookings where id = p_booking_id and status = 'open';
  if v_laptop is null then raise exception 'This booking is no longer open.'; end if;
  v := private.do_sell(v_laptop, p_name, p_mobile, p_address, p_lead_source, p_customer_type,
                       p_price, p_paid, p_method, p_ref, p_sold_on, p_warranty_months,
                       p_exchange_model, p_exchange_value, p_override_tests, p_accessory_warranty_months, p_note);
  return private.idem_put(p_client_ref, v);
end $$;

create or replace function public.sell_laptops_bulk(
  p_laptop_ids uuid[], p_price_each numeric, p_lead_source text default 'Dealer', p_customer_type text default 'Dealer',
  p_name text default '', p_mobile text default '', p_address text default '',
  p_total_paid numeric default 0, p_method text default 'Cash', p_ref text default '',
  p_warranty_months int default null, p_override_tests boolean default false, p_client_ref uuid default null,
  p_accessory_warranty_months int default null, p_note text default ''
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_role text := private.require_user(); v jsonb; v_n int; v_found int; v_list text; v_acc int; v_inv int; st public.settings;
  v_paid numeric := coalesce(p_total_paid, 0); v_left numeric; v_total numeric;
  v_cust uuid; v_grp uuid := gen_random_uuid(); v_warr int; v_today date := private.today();
  v_id uuid; v_sale uuid; v_p numeric; v_mobile text := private.norm_mobile(p_mobile);
begin
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  v_n := coalesce(array_length(p_laptop_ids, 1), 0);
  if v_n = 0 then raise exception 'Tick at least one laptop'; end if;
  if (select count(distinct x) from unnest(p_laptop_ids) x) <> v_n then raise exception 'A laptop is ticked twice'; end if;
  perform private.check_lead(p_lead_source, p_customer_type);
  if coalesce(p_price_each, 0) <= 0 then raise exception 'Enter the price per laptop'; end if;
  perform private.check_amount(p_price_each, 'the price per laptop');
  if v_paid < 0 then raise exception 'Paid amount cannot be below zero'; end if;
  if v_paid > 0 then perform private.check_amount(v_paid); perform private.check_method(p_method); end if;

  -- lock in a fixed order so two phones can never deadlock
  perform 1 from public.laptops where id = any(p_laptop_ids) order by id for update;
  get diagnostics v_found = row_count;
  if v_found <> v_n then raise exception 'Some ticked laptops were not found. Refresh and try again.'; end if;

  select string_agg(code, ', ' order by code) into v_list from public.laptops where id = any(p_laptop_ids) and status = 'at_service';
  if v_list is not null then raise exception 'At service, cannot be sold: %', v_list; end if;
  select string_agg(code, ', ' order by code) into v_list from public.laptops where id = any(p_laptop_ids) and status = 'sold';
  if v_list is not null then raise exception 'Already sold: %', v_list; end if;
  select string_agg(code, ', ' order by code) into v_list from public.laptops where id = any(p_laptop_ids) and status = 'booked';
  if v_list is not null then raise exception 'Booked for another customer: %. Complete or cancel the booking first.', v_list; end if;
  select string_agg(code, ', ' order by code) into v_list from public.laptops
  where id = any(p_laptop_ids) and not private.tests_passed(id);
  if v_list is not null then
    if v_role <> 'admin' then
      raise exception 'All tests must pass before selling. Not passed yet: %', v_list;
    end if;
    if not coalesce(p_override_tests, false) then
      raise exception 'Not every test has passed on: %. Sell anyway?', v_list using hint = 'confirm_tests';
    end if;
  end if;

  if v_role = 'staff' and exists (select 1 from public.laptops where id = any(p_laptop_ids)
                                  and p_price_each < coalesce(round(private.full_cost(id), 0), 0)) then
    raise exception 'This price is too low for some laptops. Ask the admin.';
  end if;

  v_total := p_price_each * v_n;
  if v_paid > v_total then raise exception 'Paid is more than total %', private.rs(v_total); end if;
  if v_paid < v_total and v_mobile is null then raise exception 'Enter the mobile number when money is still due'; end if;

  select * into st from public.settings where id = 1;
  v_warr := private.pick_warranty(p_warranty_months, st.default_warranty_months, v_mobile, 'Laptop');
  v_acc := private.pick_warranty(p_accessory_warranty_months, st.accessory_warranty_months, v_mobile, 'Charger and battery');

  v_cust := private.upsert_customer(v_mobile, p_name, p_address, p_customer_type);
  v_inv := private.next_invoice(v_today, v_grp);          -- one bill for the whole bulk sale
  v_left := v_paid;
  foreach v_id in array p_laptop_ids loop            -- the payment is shared in the order ticked
    insert into public.sales (laptop_id, customer_id, customer_name, customer_address, lead_source, customer_type,
                              sold_on, price, warranty_months, accessory_warranty_months, bulk_group, invoice_no, warranty_token)
    values (v_id, v_cust, btrim(coalesce(p_name, '')), btrim(coalesce(p_address, '')), p_lead_source, p_customer_type,
            v_today, p_price_each, v_warr, v_acc, v_grp, v_inv, private.new_token())
    returning id into v_sale;
    v_p := least(v_left, p_price_each);
    if v_p > 0 then
      insert into public.sale_payments (sale_id, paid_on, amount, method, ref, note)
      values (v_sale, v_today, v_p, p_method, btrim(coalesce(p_ref, '')), btrim(coalesce(p_note, '')));
      v_left := v_left - v_p;
    end if;
    update public.laptops set status = 'sold' where id = v_id;
  end loop;

  v := jsonb_build_object('count', v_n, 'total', v_total, 'paid', v_paid, 'balance', v_total - v_paid, 'bulk_group', v_grp, 'invoice_no', v_inv);
  return private.idem_put(p_client_ref, v);
end $$;

create or replace function public.add_sale_payment(
  p_sale_id uuid, p_amount numeric, p_method text default 'Cash', p_ref text default '', p_client_ref uuid default null,
  p_note text default ''
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.sales; v jsonb; v_bal numeric;
begin
  perform private.require_manager();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  select * into s from public.sales where id = p_sale_id for update;
  if not found or s.status <> 'active' then raise exception 'This sale is no longer active. Refresh and try again.'; end if;
  perform private.check_amount(p_amount, 'the amount received');
  perform private.check_method(p_method);
  v_bal := s.price - private.sale_paid(s.id);
  if p_amount > v_bal then raise exception 'That is more than the balance of %', private.rs(v_bal); end if;
  insert into public.sale_payments (sale_id, paid_on, amount, method, ref, note)
  values (s.id, private.today(), p_amount, p_method, btrim(coalesce(p_ref, '')), btrim(coalesce(p_note, '')));
  v := jsonb_build_object('paid', s.price - v_bal + p_amount, 'balance', v_bal - p_amount);
  return private.idem_put(p_client_ref, v);
end $$;

-- One payment from a customer, oldest balance cleared first.
create or replace function public.receive_customer_payment(
  p_mobile text, p_amount numeric, p_method text default 'Cash', p_ref text default '', p_client_ref uuid default null,
  p_note text default ''
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_cust uuid; v_due numeric := 0; v_left numeric; v_p numeric; r record; v_applied jsonb := '[]';
begin
  perform private.require_manager();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  perform private.check_amount(p_amount, 'the amount received');
  perform private.check_method(p_method);
  select id into v_cust from public.customers where mobile = private.norm_mobile(p_mobile);
  if v_cust is null then raise exception 'Customer not found'; end if;

  perform 1 from public.sales where customer_id = v_cust and status = 'active' order by id for update;
  select coalesce(sum(s.price - private.sale_paid(s.id)), 0) into v_due
  from public.sales s where s.customer_id = v_cust and s.status = 'active';
  if p_amount > v_due then raise exception 'That is more than the balance of %', private.rs(v_due); end if;

  v_left := p_amount;
  for r in
    select s.id, l.code, s.price - private.sale_paid(s.id) due
    from public.sales s join public.laptops l on l.id = s.laptop_id
    where s.customer_id = v_cust and s.status = 'active' and s.price > private.sale_paid(s.id)
    order by s.sold_on, s.created_at
  loop
    exit when v_left <= 0;
    v_p := least(v_left, r.due);
    insert into public.sale_payments (sale_id, paid_on, amount, method, ref, note)
    values (r.id, private.today(), v_p, p_method, btrim(coalesce(p_ref, '')), btrim(coalesce(p_note, '')));
    v_applied := v_applied || jsonb_build_object('code', r.code, 'amount', v_p);
    v_left := v_left - v_p;
  end loop;

  v := jsonb_build_object('applied', v_applied, 'balance', v_due - p_amount);
  return private.idem_put(p_client_ref, v);
end $$;

-- ---------- bookings ----------
create or replace function public.book_laptop(
  p_laptop_id uuid, p_mobile text, p_lead_source text, p_customer_type text default 'Retail',
  p_name text default '', p_address text default '', p_agreed_price numeric default null,
  p_advance numeric default 0, p_method text default 'Cash', p_ref text default '',
  p_booked_on date default null, p_client_ref uuid default null, p_note text default ''
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare l public.laptops; v jsonb; v_cust uuid; v_id uuid; v_adv numeric := coalesce(p_advance, 0);
        v_date date := coalesce(p_booked_on, private.today());
begin
  perform private.require_user();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  select * into l from public.laptops where id = p_laptop_id for update;
  if not found then raise exception 'Laptop not found.'; end if;
  perform private.service_guard(l.id);
  if l.status = 'sold' then raise exception '% is already sold.', l.code; end if;
  if l.status = 'booked' then raise exception '% is already booked.', l.code; end if;
  if private.norm_mobile(p_mobile) is null then raise exception 'Enter the customer mobile to book'; end if;
  perform private.check_lead(p_lead_source, p_customer_type);
  if p_agreed_price is not null and p_agreed_price <= 0 then raise exception 'Check the agreed price'; end if;
  if v_adv < 0 then raise exception 'Advance cannot be below zero'; end if;
  if v_adv > 0 then perform private.check_amount(v_adv, 'the advance'); perform private.check_method(p_method); end if;
  if p_agreed_price is not null and v_adv > p_agreed_price then raise exception 'Advance is more than the agreed price'; end if;
  if v_date > private.today() then raise exception 'The booking date cannot be in the future'; end if;

  v_cust := private.upsert_customer(p_mobile, p_name, p_address, p_customer_type);
  insert into public.bookings (laptop_id, customer_id, customer_name, customer_address, lead_source, customer_type, booked_on, agreed_price)
  values (l.id, v_cust, btrim(coalesce(p_name, '')), btrim(coalesce(p_address, '')), p_lead_source, p_customer_type, v_date, p_agreed_price)
  returning id into v_id;
  if v_adv > 0 then
    insert into public.booking_payments (booking_id, paid_on, amount, method, ref, note)
    values (v_id, v_date, v_adv, p_method, btrim(coalesce(p_ref, '')), btrim(coalesce(p_note, '')));
  end if;
  update public.laptops set status = 'booked' where id = l.id;
  return private.idem_put(p_client_ref, jsonb_build_object('booking_id', v_id, 'advance', v_adv));
end $$;

-- Staff may cancel but never refund: the advance is then "held" until admin/co-admin decides (settle_held_advance).
create or replace function public.cancel_booking(p_booking_id uuid, p_refund boolean default false, p_client_ref uuid default null,
                                                 p_note text default '')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_role text := private.require_user(); b public.bookings; v jsonb; v_adv numeric; v_status text;
begin
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  select * into b from public.bookings where id = p_booking_id for update;
  if not found or b.status <> 'open' then raise exception 'This booking is no longer open.'; end if;
  perform 1 from public.laptops where id = b.laptop_id for update;
  if v_role = 'staff' and coalesce(p_refund, false) then
    raise exception 'Only the admin or co-admin can refund. Cancel without refund; the advance is held for them.';
  end if;
  select coalesce(sum(amount), 0) into v_adv from public.booking_payments where booking_id = b.id;
  v_status := case when v_adv = 0 then null
                   when v_role = 'staff' then 'held'
                   when coalesce(p_refund, false) then 'refunded'
                   else 'kept' end;
  if v_status = 'refunded' then perform private.refund_advance(b, p_note); end if;
  update public.bookings set status = 'cancelled', cancelled_on = private.today(), advance_status = v_status,
         advance_decided_by = case when v_status in ('refunded','kept') then auth.uid() end
  where id = b.id;
  update public.laptops set status = 'in_stock' where id = b.laptop_id;
  return private.idem_put(p_client_ref, jsonb_build_object('advance', v_adv, 'advance_status', v_status));
end $$;

-- Admin / co-admin decides on an advance that staff left "held": refund it or keep it.
create or replace function public.settle_held_advance(p_booking_id uuid, p_refund boolean, p_client_ref uuid default null,
                                                      p_note text default '')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare b public.bookings; v jsonb; v_status text := case when p_refund then 'refunded' else 'kept' end;
begin
  perform private.require_manager();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  if p_refund is null then raise exception 'Choose refund or keep'; end if;
  select * into b from public.bookings where id = p_booking_id for update;
  if not found or b.advance_status is distinct from 'held' then raise exception 'This advance is not waiting for a decision.'; end if;
  if p_refund then perform private.refund_advance(b, p_note); end if;
  update public.bookings set advance_status = v_status, advance_decided_by = auth.uid() where id = b.id;
  return private.idem_put(p_client_ref, jsonb_build_object('advance_status', v_status));
end $$;

-- ---------- returns and undo (admin) ----------
create or replace function public.return_sale(
  p_sale_id uuid, p_refund numeric default 0, p_method text default 'Cash', p_note text default '',
  p_ref text default '', p_client_ref uuid default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.sales; v jsonb; v_cash numeric; v_ret uuid; v_code text; v_refund numeric := coalesce(p_refund, 0);
begin
  perform private.require_admin();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  select * into s from public.sales where id = p_sale_id for update;
  if not found or s.status <> 'active' then raise exception 'This sale is no longer active. Refresh and try again.'; end if;
  select code into v_code from public.laptops where id = s.laptop_id for update;
  perform private.service_guard(s.laptop_id);
  select coalesce(sum(amount), 0) into v_cash from public.sale_payments where sale_id = s.id and method <> 'Exchange';
  if v_refund < 0 or v_refund > v_cash then raise exception 'Refund can be from 0 up to %', private.rs(v_cash); end if;
  if v_refund > 0 then perform private.check_amount(v_refund, 'the refund'); perform private.check_method(p_method); end if;

  insert into public.returns (sale_id, laptop_id, returned_on, note)
  values (s.id, s.laptop_id, private.today(), btrim(coalesce(p_note, '')))
  returning id into v_ret;
  if v_refund > 0 then
    insert into public.refunds (return_id, refunded_on, amount, method, ref, label, note)
    values (v_ret, private.today(), v_refund, p_method, btrim(coalesce(p_ref, '')),
            format('Refund to %s for %s', private.cust_label(s.customer_name, s.lead_source), v_code), btrim(coalesce(p_note, '')));
  end if;
  update public.sales set status = 'returned' where id = s.id;
  update public.laptops set status = 'in_stock' where id = s.laptop_id;
  return private.idem_put(p_client_ref, jsonb_build_object('code', v_code, 'refund', v_refund));
end $$;

-- For entry mistakes. Nothing is deleted: the sale is voided and every payment gets a reversal.
create or replace function public.undo_sale(p_sale_id uuid, p_reason text default '', p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.sales; v jsonb;
begin
  perform private.require_admin();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  select * into s from public.sales where id = p_sale_id for update;
  if not found or s.status <> 'active' then raise exception 'This sale is no longer active. Refresh and try again.'; end if;
  perform 1 from public.laptops where id = s.laptop_id for update;
  perform private.service_guard(s.laptop_id);

  insert into public.sale_payments (sale_id, paid_on, amount, method, ref, reversal_of)
  select p.sale_id, private.today(), -p.amount, p.method, p.ref, p.id
  from public.sale_payments p
  where p.sale_id = s.id and p.amount > 0
    and not exists (select 1 from public.sale_payments x where x.reversal_of = p.id);

  update public.sales set status = 'voided', voided_at = now(), voided_by = auth.uid(),
         void_reason = nullif(btrim(coalesce(p_reason, '')), '')
  where id = s.id;

  if s.booking_id is not null then
    -- the sale came from a booking: put the booking back as it was
    update public.bookings set status = 'open' where id = s.booking_id;
    update public.laptops set status = 'booked' where id = s.laptop_id;
  else
    update public.laptops set status = 'in_stock' where id = s.laptop_id;
  end if;
  return private.idem_put(p_client_ref, jsonb_build_object('voided', s.id));
end $$;

-- ---------- what the shop owes and spends (admin) ----------
create or replace function public.pay_supplier(
  p_supplier_id uuid, p_amount numeric, p_method text default 'Cash', p_ref text default '', p_client_ref uuid default null,
  p_note text default ''
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.suppliers; v jsonb; v_due numeric;
begin
  perform private.require_admin();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  select * into s from public.suppliers where id = p_supplier_id for update;
  if not found or s.code = '00' then raise exception 'Supplier not found'; end if;
  perform private.check_amount(p_amount);
  perform private.check_method(p_method);
  v_due := private.supplier_due(s.id);
  if v_due > 0 and p_amount > v_due then raise exception 'That is more than the balance of %', private.rs(v_due); end if;
  insert into public.supplier_payments (supplier_id, paid_on, amount, method, ref, note)
  values (s.id, private.today(), p_amount, p_method, btrim(coalesce(p_ref, '')), btrim(coalesce(p_note, '')));
  return private.idem_put(p_client_ref, jsonb_build_object('due', v_due - p_amount));
end $$;

create or replace function public.add_debt(p_name text, p_type text, p_amount numeric, p_due_on date default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  perform private.require_admin();
  if btrim(coalesce(p_name, '')) = '' then raise exception 'Enter what it is and the amount'; end if;
  perform private.check_amount(p_amount, 'what it is and the amount');
  if p_type not in ('Shop rent','Loan','Borrowed','Bill','Other') then raise exception 'Choose a type'; end if;
  insert into public.debts (name, type, amount, due_on) values (btrim(p_name), p_type, p_amount, p_due_on)
  returning id into v_id;
  return jsonb_build_object('debt_id', v_id);
end $$;

create or replace function public.pay_debt(
  p_debt_id uuid, p_amount numeric, p_method text default 'Cash', p_ref text default '', p_client_ref uuid default null,
  p_note text default ''
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare d public.debts; v jsonb; v_bal numeric;
begin
  perform private.require_admin();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  select * into d from public.debts where id = p_debt_id and deleted_at is null for update;
  if not found then raise exception 'Debt not found'; end if;
  perform private.check_amount(p_amount);
  perform private.check_method(p_method);
  select d.amount - coalesce(sum(amount), 0) into v_bal from public.debt_payments where debt_id = d.id;
  if p_amount > v_bal then raise exception 'That is more than the balance of %', private.rs(v_bal); end if;
  insert into public.debt_payments (debt_id, paid_on, amount, method, ref, note)
  values (d.id, private.today(), p_amount, p_method, btrim(coalesce(p_ref, '')), btrim(coalesce(p_note, '')));
  return private.idem_put(p_client_ref, jsonb_build_object('balance', v_bal - p_amount));
end $$;

create or replace function public.delete_debt(p_debt_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  update public.debts set deleted_at = now(), deleted_by = auth.uid() where id = p_debt_id and deleted_at is null;
  if not found then raise exception 'Debt not found'; end if;
end $$;

create or replace function public.add_shop_expense(
  p_type text, p_amount numeric, p_method text default 'Cash', p_ref text default '', p_note text default '',
  p_spent_on date default null, p_client_ref uuid default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_id uuid;
begin
  perform private.require_admin();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  if p_type is null or p_type not in ('Rent','Electricity','Salary','Internet','Transport','Other') then
    raise exception 'Choose the expense type';
  end if;
  -- the same money must not be entered here and in Liabilities
  if p_type = 'Rent' and exists (select 1 from public.debts d where d.type = 'Shop rent' and d.deleted_at is null
       and d.amount > coalesce((select sum(amount) from public.debt_payments where debt_id = d.id), 0)) then
    raise exception 'Shop rent is open in Liabilities. Pay it there; it shows here by itself.';
  end if;
  if p_type = 'Electricity' and exists (select 1 from public.debts d where d.type = 'Bill' and d.deleted_at is null
       and d.amount > coalesce((select sum(amount) from public.debt_payments where debt_id = d.id), 0)) then
    raise exception 'A bill is open in Liabilities. Pay it there; it shows here by itself.';
  end if;
  perform private.check_amount(p_amount);
  perform private.check_method(p_method);
  if coalesce(p_spent_on, private.today()) > private.today() then raise exception 'The date cannot be in the future'; end if;
  insert into public.shop_expenses (spent_on, type, amount, method, ref, note)
  values (coalesce(p_spent_on, private.today()), p_type, p_amount, p_method, btrim(coalesce(p_ref, '')), btrim(coalesce(p_note, '')))
  returning id into v_id;
  return private.idem_put(p_client_ref, jsonb_build_object('shop_expense_id', v_id));
end $$;

create or replace function public.delete_shop_expense(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  update public.shop_expenses set deleted_at = now(), deleted_by = auth.uid() where id = p_id and deleted_at is null;
  if not found then raise exception 'Expense not found'; end if;
end $$;

-- ---------- prices and settings (admin) ----------
create or replace function public.set_model_price(p_shorthand text, p_price numeric)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  if btrim(coalesce(p_shorthand, '')) = '' then raise exception 'Model is missing'; end if;
  if p_price is null or p_price <= 0 then
    delete from public.model_prices where shorthand = btrim(p_shorthand);
  else
    perform private.check_amount(p_price, 'a price');
    insert into public.model_prices (shorthand, price, updated_by) values (btrim(p_shorthand), p_price, auth.uid())
    on conflict (shorthand) do update set price = excluded.price, updated_by = excluded.updated_by;
  end if;
end $$;

-- Anything left null keeps its current value.
create or replace function public.save_settings(
  p_shop_name text, p_phone text, p_addr text, p_default_warranty_months int, p_old_days int,
  p_cloud_name text, p_upload_preset text,
  p_bill_name text default null, p_bill_email text default null, p_logo_url text default null,
  p_bank_name text default null, p_bank_holder text default null, p_bank_account text default null, p_bank_ifsc text default null,
  p_invoice_next int default null, p_accessory_warranty_months int default null, p_bill_print_bw boolean default null
) returns void language plpgsql security definer set search_path = '' as $$
declare v_max int;
begin
  perform private.require_admin();
  if btrim(coalesce(p_shop_name, '')) = '' then raise exception 'Enter the shop name'; end if;
  if p_logo_url is not null and p_logo_url <> '' and p_logo_url !~ '^https://res\.cloudinary\.com/[^\s"''<>]+$' then
    raise exception 'The logo must be a Cloudinary https link';
  end if;
  if p_invoice_next is not null then
    select max(no) into v_max from public.invoices;
    if p_invoice_next < 1 then raise exception 'The next invoice number must be 1 or more'; end if;
    if v_max is not null and p_invoice_next <= v_max then
      raise exception 'INV-% is already used. The next invoice number must be above it.', v_max;
    end if;
  end if;
  if coalesce(p_accessory_warranty_months, 0) not between 0 and 60 then raise exception 'Charger and battery warranty must be 0 to 60 months'; end if;
  update public.settings set
    shop_name = btrim(p_shop_name), phone = btrim(coalesce(p_phone, '')), addr = btrim(coalesce(p_addr, '')),
    default_warranty_months = coalesce(p_default_warranty_months, 0),
    old_days = coalesce(nullif(p_old_days, 0), 60),
    cloud_name = btrim(coalesce(p_cloud_name, '')), upload_preset = btrim(coalesce(p_upload_preset, '')),
    bill_name = coalesce(btrim(p_bill_name), bill_name), bill_email = coalesce(btrim(p_bill_email), bill_email),
    logo_url = coalesce(btrim(p_logo_url), logo_url), bank_name = coalesce(btrim(p_bank_name), bank_name),
    bank_holder = coalesce(btrim(p_bank_holder), bank_holder), bank_account = coalesce(btrim(p_bank_account), bank_account),
    bank_ifsc = coalesce(upper(btrim(p_bank_ifsc)), bank_ifsc), invoice_next = coalesce(p_invoice_next, invoice_next),
    accessory_warranty_months = coalesce(p_accessory_warranty_months, accessory_warranty_months),
    bill_print_bw = coalesce(p_bill_print_bw, bill_print_bw),
    updated_by = auth.uid()
  where id = 1;
end $$;

-- ---------- bills, notes, warranty check ----------
-- Gives a sale (or its whole bulk sale) an invoice number and warranty token if it has none yet (sales from before bills).
create or replace function public.issue_invoice(p_sale_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.sales; v_no int;
begin
  perform private.require_user();
  select * into s from public.sales where id = p_sale_id for update;
  if not found then raise exception 'Sale not found'; end if;
  if s.invoice_no is null then
    v_no := private.next_invoice(s.sold_on, s.bulk_group);
    update public.sales set invoice_no = v_no
    where (id = s.id or (s.bulk_group is not null and bulk_group = s.bulk_group)) and invoice_no is null;
  end if;
  update public.sales set warranty_token = private.new_token()
  where (id = s.id or (s.bulk_group is not null and bulk_group = s.bulk_group)) and warranty_token is null;
  select * into s from public.sales where id = p_sale_id;
  return jsonb_build_object('invoice_no', s.invoice_no, 'issued_on', (select issued_on from public.invoices where no = s.invoice_no),
                            'warranty_token', s.warranty_token);
end $$;

-- The admin may change the note on any payment or expense later, never the amount. The old text is kept in Activity.
create or replace function public.edit_payment_note(p_kind text, p_id uuid, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_tab text; v_old text; v_amt numeric; v_label text; v_admin_only boolean;
begin
  perform private.require_admin();
  select t.tab, t.label, t.admin_only into v_tab, v_label, v_admin_only
  from (values ('sale_payment', 'sale_payments', 'customer payment', false), ('booking_payment', 'booking_payments', 'advance', false),
               ('refund', 'refunds', 'refund', false), ('supplier_payment', 'supplier_payments', 'supplier payment', true),
               ('debt_payment', 'debt_payments', 'debt payment', true), ('service_payment', 'service_payments', 'service partner payment', true),
               ('shop_expense', 'shop_expenses', 'shop expense', true), ('lot_expense', 'lot_expenses', 'lot expense', false)) t(kind, tab, label, admin_only)
  where t.kind = p_kind;
  if v_tab is null then raise exception 'Unknown payment type'; end if;
  if length(coalesce(p_note, '')) > 300 then raise exception 'Keep the note under 300 characters'; end if;
  execute format('select note, amount from public.%I where id = $1 for update', v_tab) into v_old, v_amt using p_id;
  if v_amt is null then raise exception 'Payment not found'; end if;
  if v_old is not distinct from btrim(coalesce(p_note, '')) then return; end if;
  execute format('update public.%I set note = $2 where id = $1', v_tab) using p_id, btrim(coalesce(p_note, ''));
  perform private.log('note_edit', p_kind, p_id::text,
    format('Changed the note on a %s of %s from "%s" to "%s"', v_label, private.rs(abs(v_amt)), coalesce(v_old, ''), btrim(coalesce(p_note, ''))), v_admin_only);
end $$;

-- Scanning the warranty QR on a bill inside the app opens that laptop.
create or replace function public.find_by_warranty_token(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r text := private.require_user();
begin
  if coalesce(p_token, '') !~ '^[0-9a-f]{64}$' then return null; end if;
  return (select private.laptop_json(s.laptop_id, r) from public.sales s where s.warranty_token = p_token);
end $$;

-- Public warranty check (called only by the warranty-check Edge Function with the service key).
-- Returns only safe fields: never the customer, mobile, price or payments. Rate limited per caller and overall.
create or replace function public.warranty_lookup(p_token text, p_client text default 'unknown')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.sales; st public.settings; l public.laptops; v_hits int; v_all int; v_bill date; v_lend date; v_aend date;
        v_today date := private.today();
begin
  -- 20 checks per 10 minutes from one caller, 1000 per 10 minutes in total
  insert into public.rate_limits (key, hits, window_start) values ('w:' || left(coalesce(p_client, 'unknown'), 80), 1, now())
  on conflict (key) do update set hits = case when public.rate_limits.window_start < now() - interval '10 minutes' then 1 else public.rate_limits.hits + 1 end,
                                  window_start = case when public.rate_limits.window_start < now() - interval '10 minutes' then now() else public.rate_limits.window_start end
  returning hits into v_hits;
  insert into public.rate_limits (key, hits, window_start) values ('w:all', 1, now())
  on conflict (key) do update set hits = case when public.rate_limits.window_start < now() - interval '10 minutes' then 1 else public.rate_limits.hits + 1 end,
                                  window_start = case when public.rate_limits.window_start < now() - interval '10 minutes' then now() else public.rate_limits.window_start end
  returning hits into v_all;
  if v_hits > 20 or v_all > 1000 then return jsonb_build_object('error', 'rate_limited'); end if;
  delete from public.rate_limits where window_start < now() - interval '1 day';

  if coalesce(p_token, '') !~ '^[0-9a-f]{64}$' then return jsonb_build_object('error', 'not_found'); end if;
  select * into s from public.sales where warranty_token = p_token and status = 'active';
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  select * into l from public.laptops where id = s.laptop_id;
  select * into st from public.settings where id = 1;
  v_bill := coalesce((select issued_on from public.invoices where no = s.invoice_no), s.sold_on);
  v_lend := case when s.warranty_months > 0 then (v_bill + make_interval(months => s.warranty_months))::date end;
  v_aend := case when s.accessory_warranty_months > 0 then (v_bill + make_interval(months => s.accessory_warranty_months))::date end;
  return jsonb_build_object(
    'business', coalesce(nullif(st.bill_name, ''), st.shop_name),
    'invoice_no', case when s.invoice_no is not null then 'INV-' || s.invoice_no end,
    'laptop', coalesce(nullif(concat_ws(' ', nullif(l.shorthand, ''), nullif(l.model, '')), ''), 'Laptop'),
    'code', l.code,
    'bill_date', v_bill,
    'laptop_warranty_end', v_lend,
    'accessory_warranty_end', v_aend,
    'laptop_status', case when v_lend is null then 'No warranty' when v_lend >= v_today then 'Valid'
                          else 'Expired on ' || to_char(v_lend, 'DD-MM-YYYY') end,
    'accessory_status', case when v_aend is null then 'No warranty' when v_aend >= v_today then 'Valid'
                             else 'Expired on ' || to_char(v_aend, 'DD-MM-YYYY') end,
    'status', case when coalesce(v_lend, v_aend) is null then 'No warranty'
                   when greatest(coalesce(v_lend, '-infinity'::date), coalesce(v_aend, '-infinity'::date)) >= v_today then 'Valid'
                   else 'Expired on ' || to_char(greatest(coalesce(v_lend, '-infinity'::date), coalesce(v_aend, '-infinity'::date)), 'DD-MM-YYYY') end);
end $$;

-- ---------- first admin (run once from the SQL editor) ----------
create or replace function public.bootstrap_first_admin(p_user_id uuid, p_name text, p_mobile text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.profiles where role = 'admin') then
    raise exception 'An admin already exists. Add users from More, Users.';
  end if;
  insert into public.profiles (id, name, mobile, role) values (p_user_id, btrim(p_name), p_mobile, 'admin');
  return 'Admin ' || btrim(p_name) || ' created. Log in with mobile ' || p_mobile || ' and the PIN.';
end $$;

-- ---------------------------------------------------------------------
-- 0005_service.sql
-- ---------------------------------------------------------------------
-- 0005: service partners (outside technicians and repair shops)
-- Staff: give and receive, never see or enter charges. Co-admin: may enter a charge, no totals, no paying.
-- Admin: everything. A stock laptop's charge adds to its cost; a warranty job's charge is a warranty cost.

-- Functions whose arguments changed are dropped first, so re-running never leaves an old version behind.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('receive_from_service', 'pay_service_partner')
  loop execute 'drop function ' || r.sig; end loop;
end $$;

create or replace function private.check_skills(p text[], p_what text) returns void
language plpgsql immutable set search_path = '' as $$
begin
  if p is not null and not (p <@ private.service_skills()) then raise exception 'Unknown % in the list', p_what; end if;
end $$;

create or replace function public.save_service_partner(
  p_name text, p_mobile text default '', p_shop_name text default '', p_address text default '',
  p_skills text[] default '{}', p_active boolean default true, p_id uuid default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid := p_id; v_mob text := coalesce(private.norm_mobile(p_mobile), '');
begin
  perform private.require_manager();
  if btrim(coalesce(p_name, '')) = '' then raise exception 'Enter the partner name'; end if;
  perform private.check_skills(p_skills, 'repair type');
  if v_id is null then
    insert into public.service_partners (name, mobile, shop_name, address, skills, active)
    values (btrim(p_name), v_mob, btrim(coalesce(p_shop_name, '')), btrim(coalesce(p_address, '')),
            coalesce(p_skills, '{}'), coalesce(p_active, true))
    returning id into v_id;
  else
    update public.service_partners set name = btrim(p_name), mobile = v_mob, shop_name = btrim(coalesce(p_shop_name, '')),
      address = btrim(coalesce(p_address, '')), skills = coalesce(p_skills, '{}'), active = coalesce(p_active, true)
    where id = v_id;
    if not found then raise exception 'Partner not found'; end if;
  end if;
  return jsonb_build_object('partner_id', v_id);
end $$;

-- Kind follows the laptop: in stock = stock laptop, sold = customer's laptop back under warranty.
create or replace function public.give_for_service(
  p_laptop_id uuid, p_partner_id uuid, p_issues text[] default '{}', p_note text default '',
  p_given_on date default null, p_expected_on date default null, p_kind text default null, p_client_ref uuid default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; l public.laptops; pr public.service_partners; v_kind text; v_sale uuid; v_id uuid;
        v_given date := coalesce(p_given_on, private.today());
begin
  perform private.require_user();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  select * into l from public.laptops where id = p_laptop_id for update;
  if not found then raise exception 'Laptop not found.'; end if;
  perform private.service_guard(l.id);
  if l.status = 'booked' then raise exception '% is booked. Complete or cancel the booking first.', l.code; end if;
  select id into v_sale from public.sales where laptop_id = l.id and status = 'active';
  v_kind := case when v_sale is null then 'stock' else 'warranty' end;
  if p_kind is not null and p_kind <> v_kind then
    raise exception '%', case when v_kind = 'stock' then 'This laptop is in stock, so it goes as a stock laptop.'
                              else 'This laptop is sold, so it goes as a customer warranty laptop.' end;
  end if;
  select * into pr from public.service_partners where id = p_partner_id;
  if not found or not pr.active then raise exception 'Choose a service partner'; end if;
  perform private.check_skills(p_issues, 'problem');
  if coalesce(array_length(p_issues, 1), 0) = 0 and btrim(coalesce(p_note, '')) = '' then
    raise exception 'Choose what to fix, or write a note';
  end if;
  if v_given > private.today() then raise exception 'The date given cannot be in the future'; end if;
  if p_expected_on is not null and p_expected_on < v_given then raise exception 'Expected return is before the date given'; end if;

  insert into public.service_jobs (laptop_id, partner_id, kind, sale_id, issues, note, given_on, expected_on)
  values (l.id, pr.id, v_kind, v_sale, coalesce(p_issues, '{}'), btrim(coalesce(p_note, '')), v_given, p_expected_on)
  returning id into v_id;
  update public.laptops set status = 'at_service' where id = l.id;
  return private.idem_put(p_client_ref, jsonb_build_object('job_id', v_id, 'kind', v_kind));
end $$;

create or replace function public.receive_from_service(
  p_job_id uuid, p_outcome text, p_work_done text default '', p_received_on date default null,
  p_charge numeric default null, p_paid_now boolean default false, p_method text default 'Cash', p_ref text default '',
  p_client_ref uuid default null, p_note text default ''
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_role text := private.require_user(); v jsonb; j public.service_jobs;
        v_rec date := coalesce(p_received_on, private.today());
begin
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  select * into j from public.service_jobs where id = p_job_id for update;
  if not found or j.status <> 'out' then raise exception 'This laptop is not out for service.'; end if;
  perform 1 from public.laptops where id = j.laptop_id for update;
  if p_outcome is null or p_outcome not in ('fixed','not_fixed','no_work') then
    raise exception 'Choose fixed, not fixed or returned without work';
  end if;
  if v_rec > private.today() then raise exception 'The date received cannot be in the future'; end if;
  if v_rec < j.given_on then raise exception 'The date received is before the date given'; end if;
  if p_charge is not null then
    if v_role = 'staff' then raise exception 'Staff cannot enter service charges. Leave it for the admin or co-admin.'; end if;
    if p_charge < 0 or p_charge <> round(p_charge, 2) then raise exception 'Check the service charge'; end if;
  end if;
  if coalesce(p_paid_now, false) then
    if v_role <> 'admin' then raise exception 'Only the admin can pay service partners. Mark it as paid later.'; end if;
    if coalesce(p_charge, 0) <= 0 then raise exception 'Enter the service charge to pay it now'; end if;
    perform private.check_method(p_method);
  end if;

  update public.service_jobs set status = 'returned', received_on = v_rec, work_done = btrim(coalesce(p_work_done, '')),
         outcome = p_outcome, received_by = auth.uid()
  where id = j.id;
  if p_charge is not null then
    insert into public.service_charges (job_id, charge) values (j.id, p_charge);
  end if;
  if coalesce(p_paid_now, false) then
    insert into public.service_payments (partner_id, job_id, paid_on, amount, method, ref, note)
    values (j.partner_id, j.id, v_rec, p_charge, p_method, btrim(coalesce(p_ref, '')), btrim(coalesce(p_note, '')));
  end if;
  -- back to where it was: a warranty laptop is the customer's again, a stock laptop is back on the shelf
  update public.laptops set status = case when j.kind = 'warranty' then 'sold' else 'in_stock' end where id = j.laptop_id;
  return private.idem_put(p_client_ref, jsonb_build_object('job_id', j.id, 'charge_missing', p_charge is null));
end $$;

-- Fill in a missing charge later. Co-admin may only fill a missing one; admin may also correct it.
create or replace function public.set_service_charge(p_job_id uuid, p_charge numeric)
returns void language plpgsql security definer set search_path = '' as $$
declare v_role text := private.require_manager(); j public.service_jobs;
begin
  select * into j from public.service_jobs where id = p_job_id for update;
  if not found then raise exception 'Service job not found'; end if;
  if p_charge is null or p_charge < 0 or p_charge <> round(p_charge, 2) then raise exception 'Check the service charge'; end if;
  if exists (select 1 from public.service_charges where job_id = j.id) then
    if v_role <> 'admin' then raise exception 'The charge is already entered. Ask the admin to change it.'; end if;
    update public.service_charges set charge = p_charge, entered_by = auth.uid() where job_id = j.id;
  else
    insert into public.service_charges (job_id, charge) values (j.id, p_charge);
  end if;
end $$;

create or replace function private.partner_owed(p_partner uuid) returns numeric
language sql stable set search_path = '' as $$
  select coalesce((select sum(c.charge) from public.service_charges c join public.service_jobs j on j.id = c.job_id
                   where j.partner_id = p_partner), 0)
       - coalesce((select sum(amount) from public.service_payments where partner_id = p_partner), 0)
$$;

create or replace function public.pay_service_partner(
  p_partner_id uuid, p_amount numeric, p_method text default 'Cash', p_ref text default '', p_client_ref uuid default null,
  p_note text default ''
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_owed numeric;
begin
  perform private.require_admin();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  perform 1 from public.service_partners where id = p_partner_id for update;
  if not found then raise exception 'Partner not found'; end if;
  perform private.check_amount(p_amount);
  perform private.check_method(p_method);
  v_owed := private.partner_owed(p_partner_id);
  if p_amount > v_owed then raise exception 'That is more than the % owed', private.rs(v_owed); end if;
  insert into public.service_payments (partner_id, paid_on, amount, method, ref, note)
  values (p_partner_id, private.today(), p_amount, p_method, btrim(coalesce(p_ref, '')), btrim(coalesce(p_note, '')));
  return private.idem_put(p_client_ref, jsonb_build_object('owed', v_owed - p_amount));
end $$;

-- ---------- reads ----------
create or replace function private.job_json(p_job uuid, p_role text) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', j.id, 'laptop_id', j.laptop_id, 'code', l.code, 'shorthand', l.shorthand, 'model', l.model,
    'partner_id', j.partner_id, 'partner', private.partner_label(j.partner_id), 'kind', j.kind,
    'issues', to_jsonb(j.issues), 'note', j.note, 'given_on', j.given_on, 'expected_on', j.expected_on,
    'status', j.status, 'received_on', j.received_on, 'work_done', j.work_done, 'outcome', j.outcome,
    'days_out', coalesce(j.received_on, private.today()) - j.given_on,
    'overdue', j.status = 'out' and j.expected_on is not null and j.expected_on < private.today())
  || case when p_role = 'admin' then jsonb_build_object('charge', (select charge from public.service_charges where job_id = j.id))
          when p_role = 'coadmin' then jsonb_build_object('charge_entered', exists (select 1 from public.service_charges where job_id = j.id))
          else '{}'::jsonb end
  from public.service_jobs j join public.laptops l on l.id = j.laptop_id
  where j.id = p_job
$$;

create or replace function private.partner_json(p_partner uuid, p_role text) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', p.id, 'name', p.name, 'mobile', p.mobile, 'shop_name', p.shop_name,
    'label', private.partner_label(p.id), 'address', p.address, 'skills', to_jsonb(p.skills), 'active', p.active,
    'out_count', (select count(*) from public.service_jobs where partner_id = p.id and status = 'out'))
  || case when p_role = 'admin' then jsonb_build_object('owed', private.partner_owed(p.id),
       'charge_missing', (select count(*) from public.service_jobs j where j.partner_id = p.id and j.status = 'returned'
                          and not exists (select 1 from public.service_charges c where c.job_id = j.id)))
     else '{}'::jsonb end
  from public.service_partners p where p.id = p_partner
$$;

-- Partner page: with them now, history, money (admin only).
create or replace function public.partner_detail(p_partner_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r text := private.require_user();
begin
  if not exists (select 1 from public.service_partners where id = p_partner_id) then raise exception 'Partner not found'; end if;
  return private.partner_json(p_partner_id, r) || jsonb_build_object(
    'with_them', coalesce((select jsonb_agg(private.job_json(j.id, r) order by j.given_on, j.created_at)
                           from public.service_jobs j where j.partner_id = p_partner_id and j.status = 'out'), '[]'),
    'history', (select jsonb_build_object('sent', count(*), 'returned', count(*) filter (where status = 'returned'),
                         'fixed', count(*) filter (where outcome = 'fixed'), 'not_fixed', count(*) filter (where outcome = 'not_fixed'),
                         'no_work', count(*) filter (where outcome = 'no_work'))
                from public.service_jobs where partner_id = p_partner_id),
    'recent', coalesce((select jsonb_agg(private.job_json(x.id, r) order by x.received_on desc)
                        from (select id, received_on from public.service_jobs where partner_id = p_partner_id and status = 'returned'
                              order by received_on desc, created_at desc limit 30) x), '[]'))
  || case when r = 'admin' then jsonb_build_object('money', jsonb_build_object(
       'charges', coalesce((select sum(c.charge) from public.service_charges c join public.service_jobs j on j.id = c.job_id
                            where j.partner_id = p_partner_id), 0),
       'paid', coalesce((select sum(amount) from public.service_payments where partner_id = p_partner_id), 0),
       'owed', private.partner_owed(p_partner_id),
       'payments', coalesce((select jsonb_agg(jsonb_build_object('id', vp.id, 'paid_on', vp.paid_on, 'amount', vp.amount, 'method', vp.method,
                                                   'ref', vp.ref, 'note', vp.note) order by vp.paid_on desc, vp.created_at desc)
                             from public.service_payments vp where vp.partner_id = p_partner_id), '[]'))) else '{}'::jsonb end;
end $$;

-- Jobs still waiting for a charge (admin and co-admin fill them in).
create or replace function public.service_jobs_missing_charge()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r text := private.require_manager();
begin
  return coalesce((select jsonb_agg(private.job_json(j.id, r) order by j.received_on)
                   from public.service_jobs j where j.status = 'returned'
                   and not exists (select 1 from public.service_charges c where c.job_id = j.id)), '[]');
end $$;

-- Keep-alive for the free plan: one daily call from GitHub Actions (returns no business data).
create or replace function public.ping() returns text
language sql stable security definer set search_path = '' as $$
  select 'ok ' || (select count(*) from public.settings)::text
$$;

-- ---------------------------------------------------------------------
-- 0005a_soft_delete.sql
-- ---------------------------------------------------------------------
-- 0005a: soft delete for laptops, lots, suppliers, service partners and photos.
-- A deleted row stays in its table with deleted_at / deleted_by, so its sticker code is never reused,
-- and it can be restored for 30 days (More → Recently deleted). Every screen reads through the
-- private.live_* views below, so deleted rows disappear from lists, counts, reports and stock value.
-- Safe to run twice.

do $$
declare t text;
begin
  foreach t in array array['laptops','lots','suppliers','service_partners','photos'] loop
    execute format('alter table public.%I add column if not exists deleted_at timestamptz', t);
    execute format('alter table public.%I add column if not exists deleted_by uuid references public.profiles(id)', t);
  end loop;
end $$;

-- Rows that are not deleted. Used by every read in 0006 and by the delete rules in 0010.
create or replace view private.live_laptops  as select * from public.laptops  where deleted_at is null;
create or replace view private.live_lots     as select * from public.lots     where deleted_at is null;
create or replace view private.live_suppliers as select * from public.suppliers where deleted_at is null;
create or replace view private.live_partners as select * from public.service_partners where deleted_at is null;
create or replace view private.live_photos   as select * from public.photos   where deleted_at is null;

-- One row per delete, for Recently deleted, Restore and the 30-day cleanup.
-- details: what else went with it (a lot's laptops and expenses) and any cost moved, so Restore can undo it exactly.
create table if not exists private.deletions (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('laptop','lot','supplier','partner','photo')),
  item_id      uuid not null,
  label        text not null default '',
  details      jsonb not null default '{}',
  deleted_at   timestamptz not null default now(),
  deleted_by   uuid references public.profiles(id),
  cloud_status text check (cloud_status in ('pending','deleted','failed','skipped')),   -- photos: the Cloudinary copy
  restored_at  timestamptz,
  restored_by  uuid references public.profiles(id),
  purged_at    timestamptz
);
create index if not exists deletions_open_idx on private.deletions (deleted_at) where restored_at is null and purged_at is null;

-- ---------- guards: a deleted row cannot be used or changed (only restored) ----------
-- Changing a deleted row is refused, except restoring it (deleted_at back to null) and the 30-day cleanup.
create or replace function private.guard_deleted_row() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.deleted_at is not null and new.deleted_at is not null and coalesce(current_setting('app.purging', true), '') <> 'on' then
    raise exception 'This was deleted. Restore it first from More → Recently deleted.';
  end if;
  return new;
end $$;

-- New sales, bookings, service trips, repairs, photos and tests cannot point at a deleted laptop.
create or replace function private.guard_live_laptop() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_setting('app.no_log', true) = 'on' then return new; end if;   -- loading a backup
  if exists (select 1 from public.laptops where id = new.laptop_id and deleted_at is not null) then
    raise exception 'This laptop was deleted. Restore it first from More → Recently deleted.';
  end if;
  return new;
end $$;

create or replace function private.guard_live_partner() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_setting('app.no_log', true) = 'on' then return new; end if;   -- loading a backup
  if exists (select 1 from public.service_partners where id = new.partner_id and deleted_at is not null) then
    raise exception 'This service partner was deleted.';
  end if;
  return new;
end $$;

-- A new lot cannot use a deleted supplier, or the lot number of a deleted lot (its stickers are never reused).
create or replace function private.guard_new_lot() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_setting('app.no_log', true) = 'on' then return new; end if;   -- loading a backup
  if exists (select 1 from public.suppliers where id = new.supplier_id and deleted_at is not null) then
    raise exception 'This supplier was deleted.';
  end if;
  if exists (select 1 from public.lots where prefix = new.prefix and deleted_at is not null) then
    raise exception 'Lot % was deleted, so its sticker numbers cannot be used again. Use the next lot number.', new.prefix;
  end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['laptops','lots','suppliers','service_partners','photos'] loop
    execute format('drop trigger if exists guard_deleted on public.%I', t);
    execute format('create trigger guard_deleted before update on public.%I for each row execute function private.guard_deleted_row()', t);
  end loop;
  foreach t in array array['sales','bookings','service_jobs','repairs','photos','laptop_tests','returns'] loop
    execute format('drop trigger if exists guard_live_laptop on public.%I', t);
    execute format('create trigger guard_live_laptop before insert on public.%I for each row execute function private.guard_live_laptop()', t);
  end loop;
end $$;
drop trigger if exists guard_live_partner on public.service_jobs;
create trigger guard_live_partner before insert on public.service_jobs for each row execute function private.guard_live_partner();
drop trigger if exists guard_live_partner on public.service_payments;
create trigger guard_live_partner before insert on public.service_payments for each row execute function private.guard_live_partner();
drop trigger if exists guard_new_lot on public.lots;
create trigger guard_new_lot before insert on public.lots for each row execute function private.guard_new_lot();

-- ---------- row level security: deleted rows are not readable or editable directly ----------
do $$
declare t text;
begin
  foreach t in array array['laptops','lots','photos','service_partners'] loop
    execute format('drop policy if exists user_read on public.%I', t);
    execute format('create policy user_read on public.%I for select to authenticated using (private.is_user() and deleted_at is null)', t);
  end loop;
end $$;
drop policy if exists manager_read on public.suppliers;
create policy manager_read on public.suppliers for select to authenticated using (private.is_manager() and deleted_at is null);
drop policy if exists staff_edit on public.laptops;
create policy staff_edit on public.laptops for update to authenticated
  using (private.is_user() and deleted_at is null) with check (private.is_user() and deleted_at is null);

-- ---------------------------------------------------------------------
-- 0005b_accessories.sql
-- ---------------------------------------------------------------------
-- 0005b: accessories (chargers, mice, keyboards, bags…) and notifications. Safe to run twice.
-- The count of an accessory is always the sum of its stock movements (in / out / adjust); it never goes below 0.
-- Costs are admin only (separate table), like laptop costs.

create table if not exists public.accessories (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(btrim(name)) between 1 and 80),
  alert_at    int  not null default 2 check (alert_at between 0 and 9999),
  price       numeric(12,2) check (price is null or price >= 0),          -- usual selling price (everyone sees it)
  low_alerted boolean not null default false,                              -- a low-stock notification was made for this dip
  deleted_at  timestamptz,
  deleted_by  uuid references public.profiles(id),
  created_by  uuid references public.profiles(id) default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index if not exists accessories_name_uniq on public.accessories (lower(btrim(name))) where deleted_at is null;

-- Every change in stock. delta > 0 for in, < 0 for out, either for adjust. Never edited or deleted.
create table if not exists public.accessory_moves (
  id           uuid primary key default gen_random_uuid(),
  accessory_id uuid not null references public.accessories(id),
  kind         text not null check (kind in ('in','out','adjust')),
  delta        int  not null check (delta <> 0),
  amount       numeric(12,2) not null default 0 check (amount >= 0),       -- out: money received (0 = free)
  free         boolean not null default false,
  method       text check (method in ('Cash','UPI','Bank')),                -- how the money moved (sale or purchase)
  supplier_id  uuid references public.suppliers(id),
  sale_id      uuid references public.sales(id),                            -- given with this laptop sale
  customer     text not null default '',
  mobile       text not null default '',
  reason       text not null default '',                                    -- adjust: Damaged, Lost, Found, Count correction…
  note         text not null default '' check (length(note) <= 300),
  moved_on     date not null default private.today(),
  created_by   uuid references public.profiles(id) default auth.uid(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check ((kind = 'in' and delta > 0) or (kind = 'out' and delta < 0) or kind = 'adjust'),
  check (kind = 'out' or amount = 0)
);
create index if not exists accessory_moves_acc_idx on public.accessory_moves (accessory_id);
create index if not exists accessory_moves_on_idx on public.accessory_moves (moved_on);
create index if not exists accessory_moves_sale_idx on public.accessory_moves (sale_id);

-- Admin only: what each unit cost on a purchase (an "in" movement). No row = cost not entered.
create table if not exists public.accessory_move_costs (
  move_id    uuid primary key references public.accessory_moves(id),
  unit_cost  numeric(12,2) not null check (unit_cost >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Notifications: one row per event; read state per user. audience: who may see it.
create table if not exists public.notifications (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null check (kind in ('low_stock','service_overdue','balance_pending','held_advance')),
  key        text not null unique,                        -- stops the same event being notified twice
  title      text not null,
  body       text not null default '',
  link_kind  text,                                        -- accessory, laptop, held
  link_id    text,
  audience   text not null default 'all' check (audience in ('all','mgr','admin')),
  created_at timestamptz not null default now()
);
create index if not exists notifications_created_idx on public.notifications (created_at desc);

create table if not exists public.notification_reads (
  notification_id uuid not null references public.notifications(id) on delete cascade,
  user_id         uuid not null references public.profiles(id),
  read_at         timestamptz not null default now(),
  created_at      timestamptz not null default now(),   -- backups sort every table by created_at
  primary key (notification_id, user_id)
);
alter table public.notification_reads add column if not exists created_at timestamptz not null default now();

-- Recently deleted can hold accessories too
alter table private.deletions drop constraint if exists deletions_kind_check;
alter table private.deletions add constraint deletions_kind_check check (kind in ('laptop','lot','supplier','partner','photo','accessory'));

create or replace view private.live_accessories as select * from public.accessories where deleted_at is null;

-- ---------- triggers ----------
do $$
declare t text;
begin
  foreach t in array array['accessories','accessory_moves','accessory_move_costs'] loop
    execute format('drop trigger if exists touch on public.%I', t);
    execute format('create trigger touch before update on public.%I for each row execute function private.touch()', t);
  end loop;
end $$;
-- Movements are history: never changed or deleted (like payments)
drop trigger if exists no_edit on public.accessory_moves;
create trigger no_edit before update or delete on public.accessory_moves for each row execute function private.no_edit();
drop trigger if exists guard_deleted on public.accessories;
create trigger guard_deleted before update on public.accessories for each row execute function private.guard_deleted_row();

-- Current count
create or replace function private.acc_qty(p_acc uuid) returns int
language sql stable set search_path = '' as $$
  select coalesce(sum(delta), 0)::int from public.accessory_moves where accessory_id = p_acc
$$;

-- Never below 0 (checked after every movement, so it also holds if two phones sell at once)
create or replace function private.acc_not_negative() returns trigger
language plpgsql set search_path = '' as $$
declare q int; n text;
begin
  q := private.acc_qty(new.accessory_id);
  if q < 0 then
    select name into n from public.accessories where id = new.accessory_id;
    raise exception 'Only % % left. Stock cannot go below 0.', q - new.delta, n;
  end if;
  return null;
end $$;
drop trigger if exists not_negative on public.accessory_moves;
create constraint trigger not_negative after insert on public.accessory_moves deferrable initially immediate
  for each row execute function private.acc_not_negative();

-- Low stock: one notification each time the count drops to the alert number or below (not on every sale).
-- It re-arms when stock goes back above the alert number.
create or replace function private.acc_check_low(p_acc uuid, p_after text default '') returns void
language plpgsql security definer set search_path = '' as $$
declare a public.accessories; q int;
begin
  select * into a from public.accessories where id = p_acc;
  if not found or a.deleted_at is not null then return; end if;
  q := private.acc_qty(p_acc);
  if q <= a.alert_at and not a.low_alerted then
    insert into public.notifications (kind, key, title, body, link_kind, link_id, audience)
    values ('low_stock', 'low:' || p_acc || ':' || extract(epoch from clock_timestamp())::text,
            format('%s: only %s left', a.name, q),
            concat_ws(', ', nullif(p_after, ''), to_char(now() at time zone 'Asia/Kolkata', 'DD/MM/YYYY, FMHH12:MI am')),
            'accessory', p_acc::text, 'all');
    update public.accessories set low_alerted = true where id = p_acc;
  elsif q > a.alert_at and a.low_alerted then
    update public.accessories set low_alerted = false where id = p_acc;
  end if;
end $$;

create or replace function private.acc_moves_after() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.acc_check_low(new.accessory_id,
    case when new.kind = 'out' and new.customer <> '' then 'After the sale to ' || new.customer
         when new.kind = 'out' then 'After a sale' when new.kind = 'adjust' then 'After an adjustment' else '' end);
  return null;
end $$;
drop trigger if exists check_low on public.accessory_moves;
create trigger check_low after insert on public.accessory_moves for each row execute function private.acc_moves_after();

create or replace function private.acc_alert_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.acc_check_low(new.id, 'Alert number changed');
  return null;
end $$;
drop trigger if exists alert_changed on public.accessories;
create trigger alert_changed after update of alert_at on public.accessories for each row
  when (new.alert_at is distinct from old.alert_at) execute function private.acc_alert_changed();

-- Every phone refreshes when a notification is made
drop trigger if exists tick on public.notifications;
create trigger tick after insert on public.notifications for each row execute function private.tick();

-- ---------- activity log ----------
create or replace function private.log_accessory_moves() returns trigger
language plpgsql security definer set search_path = '' as $$
declare n text;
begin
  select name into n from public.accessories where id = new.accessory_id;
  perform private.log('accessory', 'accessory', new.accessory_id::text,
    case new.kind
      when 'in' then format('Added %s × %s to stock%s', new.delta, n, private.note_suffix(new.note))
      when 'out' then format('%s %s × %s%s%s%s', case when new.free then 'Gave' else 'Sold' end, -new.delta, n,
                             case when new.customer <> '' then ' to ' || new.customer else '' end,
                             case when new.free then ' free' when new.amount > 0 then ' for ' || private.rs(new.amount) else '' end,
                             private.note_suffix(new.note))
      else format('Adjusted %s by %s%s (%s)', n, case when new.delta > 0 then '+' else '' end || new.delta, '', coalesce(nullif(new.reason, ''), 'no reason'))
    end);
  return null;
end $$;
drop trigger if exists log_ins on public.accessory_moves;
create trigger log_ins after insert on public.accessory_moves for each row execute function private.log_accessory_moves();

-- ---------- row level security (the app reads through RPCs; these are a second lock) ----------
do $$
declare t text;
begin
  foreach t in array array['accessories','accessory_moves','accessory_move_costs','notifications','notification_reads'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
grant select on public.accessories, public.accessory_moves to authenticated;
drop policy if exists user_read on public.accessories;
create policy user_read on public.accessories for select to authenticated using (private.is_user() and deleted_at is null);
drop policy if exists user_read on public.accessory_moves;
create policy user_read on public.accessory_moves for select to authenticated using (private.is_user());
grant select on public.accessory_move_costs to authenticated;
drop policy if exists admin_read on public.accessory_move_costs;
create policy admin_read on public.accessory_move_costs for select to authenticated using (private.is_admin());
-- notifications and their read state: only through the RPCs (no policy = no direct access)

-- ---------------------------------------------------------------------
-- 0006_reads.sql
-- ---------------------------------------------------------------------
-- 0006: read functions. Each returns only what the caller's role may see.
-- admin: everything. coadmin: no costs, profit, supplier balances, debts, shop expenses. staff: also no suppliers,
-- lot expenses, customers list, money, reports or activity.

-- Sold = has a live sale (a sold laptop away at service under warranty is still sold).
create or replace function private.is_sold(p_laptop uuid) returns boolean
language sql stable set search_path = '' as $$
  select exists (select 1 from public.sales where laptop_id = p_laptop and status = 'active')
$$;

-- ---------- JSON builders ----------
create or replace function private.payments_json(p_sale uuid) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'paid_on', p.paid_on, 'amount', p.amount, 'method', p.method,
                                               'ref', p.ref, 'note', p.note, 'from_booking', p.booking_payment_id is not null)
                            order by p.paid_on, p.created_at), '[]')
  from public.sale_payments p where p.sale_id = p_sale and p.reversal_of is null
$$;

create or replace function private.sale_json(p_sale uuid, p_role text) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', s.id, 'sold_on', s.sold_on, 'name', s.customer_name,
    'label', private.cust_label(s.customer_name, s.lead_source),
    'mobile', c.mobile, 'address', s.customer_address, 'lead_source', s.lead_source, 'customer_type', s.customer_type,
    'price', s.price, 'warranty_months', s.warranty_months, 'accessory_warranty_months', s.accessory_warranty_months,
    'bulk_group', s.bulk_group, 'status', s.status, 'invoice_no', s.invoice_no, 'warranty_token', s.warranty_token,
    'bill_date', coalesce((select i.issued_on from public.invoices i where i.no = s.invoice_no), s.sold_on),
    'payments', private.payments_json(s.id),
    'paid', private.sale_paid(s.id), 'due', s.price - private.sale_paid(s.id),
    'accessories', coalesce((select jsonb_agg(jsonb_build_object('name', a.name, 'qty', -m.delta, 'amount', m.amount, 'free', m.free, 'method', m.method)
                                              order by m.created_at)
                             from public.accessory_moves m join public.accessories a on a.id = m.accessory_id
                             where m.sale_id = s.id and m.kind = 'out'), '[]'))
  || case when p_role = 'admin' then jsonb_build_object('profit', private.profit(s.id)) else '{}'::jsonb end
  from public.sales s left join public.customers c on c.id = s.customer_id
  where s.id = p_sale
$$;

create or replace function private.booking_json(p_booking uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', b.id, 'booked_on', b.booked_on, 'name', b.customer_name,
    'label', private.cust_label(b.customer_name, b.lead_source),
    'mobile', c.mobile, 'address', b.customer_address, 'lead_source', b.lead_source, 'customer_type', b.customer_type,
    'agreed_price', b.agreed_price,
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'paid_on', p.paid_on, 'amount', p.amount, 'method', p.method, 'ref', p.ref, 'note', p.note)
                                           order by p.paid_on, p.created_at)
                          from public.booking_payments p where p.booking_id = b.id), '[]'),
    'advance', coalesce((select sum(amount) from public.booking_payments where booking_id = b.id), 0))
  from public.bookings b join public.customers c on c.id = b.customer_id
  where b.id = p_booking
$$;

create or replace function private.laptop_json(p_id uuid, p_role text) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', l.id, 'code', l.code, 'lot_id', l.lot_id, 'line_id', l.line_id, 'piece_no', l.piece_no,
    'brand', l.brand, 'brand_other', l.brand_other, 'model', l.model,
    'processor', l.processor, 'processor_other', l.processor_other, 'gen', l.gen,
    'ram_gb', l.ram_gb, 'storage_type', l.storage_type, 'storage_gb', l.storage_gb, 'shorthand', l.shorthand,
    'serial', l.serial, 'grade', l.grade, 'status', l.status, 'notes', l.notes,
    'test_note', l.test_note, 'tested_on', l.tested_on, 'added_on', l.added_on,
    'tests', coalesce((select jsonb_object_agg(t.test, case when t.result = 'pass' then 'ok' else 'fail' end)
                       from public.laptop_tests t where t.laptop_id = l.id), '{}'),
    'repairs', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'work', r.work, 'amount', r.amount, 'done_on', r.done_on,
                                                             'from_lot_stock', r.lot_expense_id is not null)
                                          order by r.done_on, r.created_at)
                         from public.repairs r where r.laptop_id = l.id and r.deleted_at is null), '[]'),
    'photos', coalesce((select jsonb_agg(p.url order by p.created_at) from private.live_photos p where p.laptop_id = l.id), '[]'),
    'photo_ids', coalesce((select jsonb_agg(p.id order by p.created_at) from private.live_photos p where p.laptop_id = l.id), '[]'),
    'sale', (select private.sale_json(s.id, p_role) from public.sales s where s.laptop_id = l.id and s.status = 'active'),
    'booking', (select private.booking_json(b.id) from public.bookings b where b.laptop_id = l.id and b.status = 'open'),
    'returns', coalesce((select jsonb_agg(jsonb_build_object(
                           'name', private.cust_label(s.customer_name, s.lead_source), 'sold_on', s.sold_on,
                           'returned_on', rt.returned_on,
                           'refund', coalesce((select sum(f.amount) from public.refunds f where f.return_id = rt.id), 0))
                         order by rt.returned_on)
                         from public.returns rt join public.sales s on s.id = rt.sale_id where rt.laptop_id = l.id), '[]'),
    'service', (select private.job_json(j.id, p_role) from public.service_jobs j where j.laptop_id = l.id and j.status = 'out'),
    'service_history', coalesce((select jsonb_agg(private.job_json(j.id, p_role) order by j.given_on)
                                 from public.service_jobs j where j.laptop_id = l.id and j.status = 'returned'), '[]'))
  || case when p_role = 'admin' then jsonb_build_object(
       'cost', private.cost_of(l.id), 'lot_share', round(private.lot_share(l.id), 2),
       'service_cost', private.service_cost(l.id),
       'service_charge_missing', exists (select 1 from public.service_jobs j where j.laptop_id = l.id and j.kind = 'stock'
                                         and j.status = 'returned' and not exists (select 1 from public.service_charges c where c.job_id = j.id)),
       'full_cost', round(private.full_cost(l.id), 2))
     else '{}'::jsonb end
  from private.live_laptops l where l.id = p_id
$$;

create or replace function private.line_json(p_line uuid, p_role text) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', ln.id, 'line_no', ln.line_no, 'is_mixed', ln.is_mixed, 'brand', ln.brand,
    'brand_other', ln.brand_other, 'model', ln.model, 'processor', ln.processor, 'processor_other', ln.processor_other,
    'gen', ln.gen, 'ram_gb', ln.ram_gb, 'storage_type', ln.storage_type, 'storage_gb', ln.storage_gb,
    'qty', (select count(*) from private.live_laptops x where x.line_id = ln.id),   -- deleted laptops are not counted
    'label', case when ln.is_mixed then 'Mixed'
                  else coalesce(nullif(concat_ws(' ', nullif(private.shorthand(ln.brand, ln.brand_other, ln.processor, ln.processor_other,
                                ln.gen, ln.ram_gb, ln.storage_type, ln.storage_gb), ''), nullif(ln.model, '')), ''), 'Line ' || ln.line_no) end)
  || case when p_role = 'admin' then jsonb_build_object(
       'line_cost', (select c.line_cost from public.lot_line_costs c where c.line_id = ln.id)) else '{}'::jsonb end
  from public.lot_lines ln where ln.id = p_line
$$;

create or replace function private.lot_expense_json(p_exp uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', e.id, 'lot_id', e.lot_id, 'line_id', e.line_id, 'spent_on', e.spent_on, 'type', e.type,
    'count', e.count, 'amount', e.amount, 'method', e.method, 'ref', e.ref, 'note', e.note,
    'units_left', e.count - (select f.units from private.fitted(e.id) f))
  from public.lot_expenses e where e.id = p_exp
$$;

create or replace function private.lot_json(p_lot uuid, p_role text) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', lo.id, 'supplier_id', case when p_role = 'staff' then null else lo.supplier_id end,
    'supplier_name', case when p_role = 'staff' then null else s.name end,
    'lot_no', lo.lot_no, 'month', lo.month, 'year', lo.year, 'prefix', lo.prefix, 'kind', lo.kind,
    'bought_on', lo.bought_on, 'note', lo.note,
    'qty', (select count(*) from private.live_laptops where lot_id = lo.id),
    'sold', (select count(*) from private.live_laptops x where x.lot_id = lo.id and private.is_sold(x.id)),
    'lines', coalesce((select jsonb_agg(private.line_json(ln.id, p_role) order by ln.line_no)
                       from public.lot_lines ln where ln.lot_id = lo.id
                         and exists (select 1 from private.live_laptops x where x.line_id = ln.id)), '[]'),
    'expenses', case when p_role = 'staff' then '[]'::jsonb else
                coalesce((select jsonb_agg(private.lot_expense_json(e.id) order by e.spent_on, e.created_at)
                          from public.lot_expenses e where e.lot_id = lo.id and e.deleted_at is null), '[]') end)
  || case when p_role = 'admin' then jsonb_build_object(
       'cost', (select sum(c.cost) from public.laptop_costs c join private.live_laptops l on l.id = c.laptop_id where l.lot_id = lo.id),
       'cost_missing', (select count(*) from private.live_laptops l where l.lot_id = lo.id
                        and not exists (select 1 from public.laptop_costs c where c.laptop_id = l.id)))
     else '{}'::jsonb end
  from private.live_lots lo join private.live_suppliers s on s.id = lo.supplier_id
  where lo.id = p_lot
$$;

create or replace function private.supplier_json(p_sup uuid, p_role text) returns jsonb
language sql stable set search_path = '' as $$
  with ls as (
    select l.id, (select count(*) from public.repairs r where r.laptop_id = l.id and r.deleted_at is null) > 0 repaired,
           private.repairs_of(l.id) rep,
           (select private.profit(sa.id) from public.sales sa where sa.laptop_id = l.id and sa.status = 'active') profit
    from private.live_laptops l join private.live_lots lo on lo.id = l.lot_id where lo.supplier_id = p_sup
  )
  select jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name, 'phone', s.phone,
    'lots', (select count(*) from private.live_lots where supplier_id = s.id),
    -- highest lot number ever used, deleted lots included (their sticker numbers are never reused)
    'max_lot_no', (select coalesce(max(lot_no), 0) from public.lots where supplier_id = s.id),
    'quality', (select case when count(*) = 0 then null else jsonb_build_object(
                  'n', count(*),
                  'pct_rep', round(100.0 * count(*) filter (where repaired) / count(*)),
                  'avg_rep', round(sum(rep) / count(*), 2),
                  'avg_profit', case when p_role = 'admin' then round(avg(profit), 2) end) end from ls))
  || case when p_role = 'admin' then jsonb_build_object(
       'bought', coalesce((select sum(c.cost) from public.laptop_costs c join private.live_laptops l on l.id = c.laptop_id
                           join private.live_lots lo on lo.id = l.lot_id where lo.supplier_id = s.id), 0),
       'paid', case when s.code = '00' then null else
               coalesce((select sum(amount) from public.supplier_payments where supplier_id = s.id), 0) end,
       'due', private.supplier_due(s.id),
       'payments', coalesce((select jsonb_agg(jsonb_build_object('id', sp.id, 'paid_on', sp.paid_on, 'amount', sp.amount, 'method', sp.method,
                                                 'ref', sp.ref, 'note', sp.note) order by sp.paid_on desc, sp.created_at desc)
                             from (select * from public.supplier_payments where supplier_id = s.id order by paid_on desc, created_at desc limit 30) sp), '[]'),
       'cost_missing', (select count(*) from private.live_laptops l join private.live_lots lo on lo.id = l.lot_id
                        where lo.supplier_id = s.id and not exists (select 1 from public.laptop_costs c where c.laptop_id = l.id)))
     else '{}'::jsonb end
  from private.live_suppliers s where s.id = p_sup
$$;

-- Sold more than 12 months ago and fully paid: left out of the snapshot (fetched on demand).
create or replace function private.is_old_sold(p_laptop uuid) returns boolean
language sql stable set search_path = '' as $$
  select exists (select 1 from public.sales s where s.laptop_id = p_laptop and s.status = 'active'
                 and s.sold_on < private.today() - interval '12 months' and private.sale_paid(s.id) >= s.price)
$$;

-- ---------- snapshot ----------
create or replace function public.get_snapshot()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r text := private.require_user();
begin
  return jsonb_build_object(
    'me', (select jsonb_build_object('id', p.id, 'name', p.name, 'role', p.role, 'mobile', p.mobile)
           from public.profiles p where p.id = auth.uid()),
    'today', private.today(),
    'settings', (select to_jsonb(s) - 'id' - 'created_at' - 'updated_at' - 'updated_by' from public.settings s),
    'suppliers', case when r = 'staff' then '[]'::jsonb else
                 coalesce((select jsonb_agg(private.supplier_json(s.id, r) order by s.code) from private.live_suppliers s), '[]') end,
    'lots', coalesce((select jsonb_agg(private.lot_json(lo.id, r) order by lo.bought_on, lo.created_at) from private.live_lots lo), '[]'),
    'laptops', coalesce((select jsonb_agg(private.laptop_json(l.id, r) order by l.created_at, l.code)
                         from private.live_laptops l where not private.is_old_sold(l.id)), '[]'),
    'hidden_sold', (select count(*) from private.live_laptops l where private.is_old_sold(l.id)),
    'prices', coalesce((select jsonb_object_agg(shorthand, price) from public.model_prices), '{}'),
    'accessories', coalesce((select jsonb_agg(private.accessory_json(a.id, r) order by lower(a.name)) from private.live_accessories a), '[]'),
    'debts', case when r <> 'admin' then '[]'::jsonb else
             coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name, 'type', d.type, 'amount', d.amount,
                         'due_on', d.due_on,
                         'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'paid_on', p.paid_on, 'amount', p.amount,
                                                 'method', p.method, 'ref', p.ref, 'note', p.note) order by p.paid_on, p.created_at)
                                               from public.debt_payments p where p.debt_id = d.id), '[]'),
                         'balance', d.amount - coalesce((select sum(amount) from public.debt_payments where debt_id = d.id), 0))
                       order by d.created_at)
                       from public.debts d where d.deleted_at is null), '[]') end,
    'held_advances', case when r = 'staff' then '[]'::jsonb else
                     coalesce((select jsonb_agg(jsonb_build_object('booking_id', b.id, 'code', l.code,
                                 'name', private.cust_label(b.customer_name, b.lead_source), 'mobile', c.mobile,
                                 'cancelled_on', b.cancelled_on,
                                 'advance', (select sum(amount) from public.booking_payments where booking_id = b.id))
                               order by b.cancelled_on)
                               from public.bookings b join private.live_laptops l on l.id = b.laptop_id
                               join public.customers c on c.id = b.customer_id
                               where b.advance_status = 'held'), '[]') end,
    'partners', coalesce((select jsonb_agg(private.partner_json(p.id, r) order by p.active desc, private.partner_label(p.id))
                          from private.live_partners p), '[]'),
    'service_owed', case when r <> 'admin' then null else
                    (select coalesce(sum(greatest(private.partner_owed(p.id), 0)), 0) from private.live_partners p) end,
    'stock_value', case when r <> 'admin' then null else
                   (select jsonb_build_object('value', round(coalesce(sum(private.full_cost(l.id)), 0), 2),
                                              'cost_missing', count(*) filter (where private.cost_of(l.id) is null))
                    from private.live_laptops l where not private.is_sold(l.id)) end,
    'activity', case when r = 'staff' then '[]'::jsonb else
                coalesce((select jsonb_agg(to_jsonb(a) order by a.id desc)
                          from (select id, at, actor_name, actor_role, message from public.activity_log
                                where r = 'admin' or not admin_only order by id desc limit 300) a), '[]') end
  );
end $$;

-- ---------- on-demand reads ----------
create or replace function public.get_laptop(p_code text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r text := private.require_user(); c text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g')); d text;
begin
  d := regexp_replace(c, '\D', '', 'g');
  if c !~ '-' and length(d) = 11 then
    c := substr(d, 1, 2) || '-' || substr(d, 3, 2) || '-' || substr(d, 5, 2) || '-' || substr(d, 7, 2) || '-' || substr(d, 9, 3);
  end if;
  return (select private.laptop_json(l.id, r) from private.live_laptops l where l.code = c);
end $$;

create or replace function public.search_laptops(p_q text, p_limit int default 60)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r text := private.require_user(); q text := lower(btrim(coalesce(p_q, ''))); d text;
begin
  if q = '' then return '[]'::jsonb; end if;
  d := regexp_replace(q, '\D', '', 'g');
  return coalesce((
    select jsonb_agg(private.laptop_json(x.id, r))
    from (select l.id from private.live_laptops l
          left join public.sales s on s.laptop_id = l.id and s.status = 'active'
          left join public.customers c on c.id = s.customer_id
          where position(q in lower(l.code)) > 0
             or (length(d) >= 3 and position(d in replace(l.code, '-', '')) > 0)
             or position(q in lower(l.serial)) > 0
             or position(q in lower(l.shorthand)) > 0
             or position(q in lower(l.model)) > 0
             or position(q in lower(coalesce(s.customer_name, ''))) > 0
             or (length(d) >= 3 and position(d in coalesce(c.mobile, '')) > 0)
          order by l.created_at desc
          limit least(greatest(coalesce(p_limit, 60), 1), 300)) x), '[]');
end $$;

create or replace function public.lot_laptops(p_lot_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r text := private.require_user();
begin
  return coalesce((select jsonb_agg(private.laptop_json(l.id, r) order by l.piece_no)
                   from private.live_laptops l where l.lot_id = p_lot_id), '[]');
end $$;

create or replace function public.old_sold_laptops(p_offset int default 0, p_limit int default 100)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r text := private.require_user();
begin
  return coalesce((select jsonb_agg(private.laptop_json(x.laptop_id, r))
                   from (select s.laptop_id from public.sales s
                         where s.status = 'active' and private.is_old_sold(s.laptop_id)
                         order by s.sold_on desc offset greatest(coalesce(p_offset, 0), 0)
                         limit least(greatest(coalesce(p_limit, 100), 1), 300)) x), '[]');
end $$;

create or replace function public.activity_page(p_before bigint default null, p_role text default null, p_limit int default 300)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r text := private.require_manager();
begin
  return coalesce((select jsonb_agg(to_jsonb(a) order by a.id desc)
                   from (select id, at, actor_name, actor_role, message from public.activity_log
                         where (r = 'admin' or not admin_only)
                           and (p_before is null or id < p_before)
                           and (p_role is null or actor_role = p_role)
                         order by id desc limit least(greatest(coalesce(p_limit, 300), 1), 1000)) a), '[]');
end $$;

-- Customers screen, both tabs (all history, not only the snapshot).
create or replace function public.customer_summary()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_manager();
  return coalesce((
    select jsonb_agg(x order by x.due > 0 desc, x.oldest_due, x.last desc)
    from (
      select c.mobile, coalesce(nullif(c.name, ''), (array_agg(private.cust_label(s.customer_name, s.lead_source) order by s.sold_on desc))[1]) name,
             c.address, c.customer_type, count(*) n,
             sum(s.price) total, sum(private.sale_paid(s.id)) paid, sum(s.price - private.sale_paid(s.id)) due,
             max(s.sold_on) last,
             min(s.sold_on) filter (where s.price > private.sale_paid(s.id)) oldest_due,
             (array_agg(l.code order by s.sold_on desc))[1:4] codes
      from public.customers c
      join public.sales s on s.customer_id = c.id and s.status = 'active'
      join private.live_laptops l on l.id = s.laptop_id
      group by c.id) x), '[]');
end $$;

-- Today's money for any date, built from what was already entered.
create or replace function public.money_day(p_date date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r text := private.require_manager(); adm boolean := r = 'admin';
begin
  return jsonb_build_object('date', p_date,
    'ins', coalesce((select jsonb_agg(x) from (
        select p.amount amt, p.method m, private.cust_label(s.customer_name, s.lead_source) || ', ' || l.code t, p.note n, p.id id, 'sale_payment' k
        from public.sale_payments p join public.sales s on s.id = p.sale_id join private.live_laptops l on l.id = s.laptop_id
        where p.paid_on = p_date and p.reversal_of is null and p.booking_payment_id is null and s.status <> 'voided'
        union all
        select bp.amount, bp.method, private.cust_label(b.customer_name, b.lead_source) || ' (advance), ' || l.code, bp.note, bp.id, 'booking_payment'
        from public.booking_payments bp join public.bookings b on b.id = bp.booking_id join private.live_laptops l on l.id = b.laptop_id
        where bp.paid_on = p_date
        union all
        select m.amount, m.method, 'Accessory: ' || (-m.delta) || ' × ' || a.name || case when m.customer <> '' then ', ' || m.customer else '' end,
               m.note, null::uuid, null
        from public.accessory_moves m join public.accessories a on a.id = m.accessory_id
        where m.moved_on = p_date and m.kind = 'out' and m.amount > 0) x), '[]'),
    'outs', coalesce((select jsonb_agg(x) from (
        select r.amount amt, 'Cash' m, 'Repair on ' || l.code || ': ' || r.work t, '' n, null::uuid id, null k
        from public.repairs r join private.live_laptops l on l.id = r.laptop_id
        where r.done_on = p_date and r.deleted_at is null and r.lot_expense_id is null
        union all
        select e.amount, e.method, 'Parts for lot ' || lo.prefix || ': ' || e.count || ' x ' || e.type, e.note, e.id, 'lot_expense'
        from public.lot_expenses e join private.live_lots lo on lo.id = e.lot_id
        where e.spent_on = p_date and e.deleted_at is null
        union all
        -- supplier, Liabilities, shop and service payments: in full for admin; one combined line per method for co-admin
        select sum(b.amt), b.m, case when adm then b.t else 'Business payments (by admin)' end,
               case when adm then max(b.n) else '' end, case when adm then b.k end, case when adm then max(b.kind) end
        from (
          select sp.amount amt, sp.method m, 'Supplier ' || s.name t, sp.note n, sp.id k, 'supplier_payment' kind
          from public.supplier_payments sp join private.live_suppliers s on s.id = sp.supplier_id where sp.paid_on = p_date
          union all
          select dp.amount, dp.method, d.name, dp.note, dp.id, 'debt_payment'
          from public.debt_payments dp join public.debts d on d.id = dp.debt_id where dp.paid_on = p_date
          union all
          select se.amount, se.method, 'Shop: ' || se.type, se.note, se.id, 'shop_expense'
          from public.shop_expenses se where se.spent_on = p_date and se.deleted_at is null
          union all
          select vp.amount, vp.method, 'Service: ' || private.partner_label(vp.partner_id), vp.note, vp.id, 'service_payment'
          from public.service_payments vp where vp.paid_on = p_date
          union all
          select round(c.unit_cost * m.delta, 2), m.method, 'Accessory stock: ' || m.delta || ' × ' || a.name, m.note, m.id, null
          from public.accessory_moves m join public.accessory_move_costs c on c.move_id = m.id join public.accessories a on a.id = m.accessory_id
          where m.moved_on = p_date and m.kind = 'in' and m.method is not null and c.unit_cost > 0) b
        group by b.m, case when adm then b.t else 'Business payments (by admin)' end, case when adm then b.k end
        union all
        select f.amount, f.method, coalesce(nullif(f.label, ''), 'Refund'), f.note, f.id, 'refund' from public.refunds f where f.refunded_on = p_date) x), '[]'));
end $$;

-- Shop expenses: entered ones plus payments of Shop rent / Bill debts ("from Liabilities", read-only).
create or replace function private.shop_expense_rows(p_from date, p_to date)
returns table (id uuid, spent_on date, type text, amount numeric, method text, ref text, note text, from_liabilities boolean)
language sql stable set search_path = '' as $$
  select se.id, se.spent_on, se.type, se.amount, se.method, se.ref, se.note, false
  from public.shop_expenses se where se.deleted_at is null and se.spent_on between p_from and p_to
  union all
  select dp.id, dp.paid_on, case when d.type = 'Shop rent' then 'Rent' else 'Bill' end, dp.amount, dp.method, dp.ref, d.name, true
  from public.debt_payments dp join public.debts d on d.id = dp.debt_id
  where d.type in ('Shop rent','Bill') and dp.paid_on between p_from and p_to
$$;

create or replace function public.shop_expense_list(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_admin();
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.spent_on desc) from private.shop_expense_rows(p_from, p_to) x), '[]');
end $$;

-- ---------- reports ----------
create or replace function public.report_year(p_year int)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r text := private.require_manager(); adm boolean := r = 'admin';
        d0 date := make_date(p_year, 1, 1); d1 date := make_date(p_year, 12, 31);
begin
  return (
    with sold as (
      select s.id, s.laptop_id, s.sold_on, s.price, extract(month from s.sold_on)::int m,
             private.profit(s.id) profit, private.sale_paid(s.id) paid
      from public.sales s where s.status = 'active' and s.sold_on between d0 and d1
    ), prev as (
      select s.price, private.profit(s.id) profit
      from public.sales s where s.status = 'active' and extract(year from s.sold_on) = p_year - 1
    ), shop as (
      select extract(month from x.spent_on)::int m, sum(x.amount) amt from private.shop_expense_rows(d0, d1) x group by 1
    ), svc as (   -- service charges by the month the laptop came back
      select extract(month from j.received_on)::int m,
             sum(c.charge) filter (where j.kind = 'stock') stock_amt,
             sum(c.charge) filter (where j.kind = 'warranty') warranty_amt
      from public.service_jobs j join public.service_charges c on c.job_id = j.id
      where j.received_on between d0 and d1 group by 1
    ), acc as (   -- accessories sold or given: money in, and cost at the average purchase cost
      select extract(month from m.moved_on)::int m, sum(m.amount) sales,
             sum(m.amount - (-m.delta) * private.acc_avg_cost(m.accessory_id)) profit,
             count(*) filter (where private.acc_avg_cost(m.accessory_id) is null) cost_missing
      from public.accessory_moves m where m.kind = 'out' and m.moved_on between d0 and d1 group by 1
    ), months as (
      select g m,
             coalesce((select sales from acc where acc.m = g), 0) acc_sales,
             coalesce((select profit from acc where acc.m = g), 0) acc_profit,
             (select count(*) from sold where sold.m = g) n,
             (select coalesce(sum(price), 0) from sold where sold.m = g) sales,
             (select coalesce(sum(profit), 0) from sold where sold.m = g) gross,
             (select count(*) from sold where sold.m = g and profit is null) cost_missing,
             coalesce((select amt from shop where shop.m = g), 0) shop,
             coalesce((select stock_amt from svc where svc.m = g), 0) service_stock,
             coalesce((select warranty_amt from svc where svc.m = g), 0) warranty
      from generate_series(1, 12) g
    )
    select jsonb_build_object(
      'year', p_year,
      'years', (select jsonb_agg(y order by y desc) from (
                  select extract(year from private.today())::int y
                  union select distinct year from private.live_lots
                  union select distinct extract(year from sold_on)::int from public.sales where status = 'active') ys),
      'months', (select jsonb_agg(jsonb_build_object('m', m, 'n', n, 'sales', sales, 'acc_sales', acc_sales)
                   -- stock service charges are already inside gross (laptop cost); warranty repairs come off net
                   || case when adm then jsonb_build_object('gross', round(gross, 2), 'cost_missing', cost_missing,
                                                            'shop', shop, 'service_stock', service_stock, 'warranty', warranty,
                                                            'acc_profit', round(acc_profit, 2),
                                                            'net', round(gross + acc_profit - shop - warranty, 2)) else '{}'::jsonb end
                   order by m) from months),
      'prev', jsonb_build_object('n', (select count(*) from prev), 'sales', (select coalesce(sum(price), 0) from prev))
              || case when adm then jsonb_build_object('gross', (select round(coalesce(sum(profit), 0), 2) from prev)) else '{}'::jsonb end,
      'collected', (select coalesce(sum(paid), 0) from sold),
      'pending', (select coalesce(sum(price - paid), 0) from sold),
      'batches', coalesce((select jsonb_agg(jsonb_build_object('prefix', lo.prefix,
                    'qty', (select count(*) from private.live_laptops where lot_id = lo.id),
                    'sold', (select count(*) from private.live_laptops x where x.lot_id = lo.id and private.is_sold(x.id)),
                    'sales', (select coalesce(sum(s.price), 0) from public.sales s join private.live_laptops l on l.id = s.laptop_id
                              where l.lot_id = lo.id and s.status = 'active'))
                  order by lo.bought_on) from private.live_lots lo where lo.year = p_year), '[]')
    ) || case when adm then jsonb_build_object(
           'repairs_sold', (select round(coalesce(sum(private.repairs_of(laptop_id)), 0), 2) from sold)) else '{}'::jsonb end
  );
end $$;

-- Sales, laptops and gross profit by lead source, per month.
create or replace function public.lead_report(p_year int)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r text := private.require_manager();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('m', m, 'lead_source', lead_source, 'n', n, 'sales', sales)
                     || case when r = 'admin' then jsonb_build_object('gross', gross, 'cost_missing', cost_missing) else '{}'::jsonb end
                     order by m, sales desc)
    from (select extract(month from s.sold_on)::int m, s.lead_source, count(*) n, sum(s.price) sales,
                 round(coalesce(sum(private.profit(s.id)), 0), 2) gross,
                 count(*) filter (where private.profit(s.id) is null) cost_missing
          from public.sales s where s.status = 'active' and extract(year from s.sold_on) = p_year
          group by 1, 2) x), '[]');
end $$;

-- Lot P&L (admin): status, sold and left, total cost, sales, gross profit, margin.
create or replace function public.lot_pnl()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'prefix', x.prefix, 'kind', x.kind, 'supplier', x.supplier, 'bought_on', x.bought_on, 'note', x.note,
             'qty', x.qty, 'sold', x.sold, 'left', x.qty - x.sold,
             'status', case when x.sold = 0 then 'Unsold' when x.sold = x.qty then 'Sold out' else 'Part sold' end,
             'purchase', x.purchase, 'cost_missing', x.cost_missing, 'lot_expenses', x.lot_exp, 'repairs', x.repairs,
             'total_cost', x.purchase + x.lot_exp + x.repairs, 'sales', x.sales, 'gross', x.gross,
             'margin_pct', case when x.sales > 0 then round(100 * x.gross / x.sales, 1) end)
           order by x.bought_on desc)
    from (
      select lo.prefix, lo.kind, s.name supplier, lo.bought_on, lo.note,
             (select count(*) from private.live_laptops where lot_id = lo.id) qty,
             (select count(*) from private.live_laptops x where x.lot_id = lo.id and private.is_sold(x.id)) sold,
             coalesce((select sum(c.cost) from public.laptop_costs c join private.live_laptops l on l.id = c.laptop_id where l.lot_id = lo.id), 0) purchase,
             (select count(*) from private.live_laptops l where l.lot_id = lo.id
              and not exists (select 1 from public.laptop_costs c where c.laptop_id = l.id)) cost_missing,
             -- parts fitted to single laptops are already inside an expense, so only manual repairs are added
             coalesce((select sum(amount) from public.lot_expenses where lot_id = lo.id and deleted_at is null), 0) lot_exp,
             coalesce((select sum(r.amount) from public.repairs r join private.live_laptops l on l.id = r.laptop_id
                       where l.lot_id = lo.id and r.deleted_at is null and r.lot_expense_id is null), 0) repairs,
             coalesce((select sum(sa.price) from public.sales sa join private.live_laptops l on l.id = sa.laptop_id
                       where l.lot_id = lo.id and sa.status = 'active'), 0) sales,
             coalesce((select round(sum(private.profit(sa.id)), 2) from public.sales sa join private.live_laptops l on l.id = sa.laptop_id
                       where l.lot_id = lo.id and sa.status = 'active'), 0) gross
      from private.live_lots lo join private.live_suppliers s on s.id = lo.supplier_id) x), '[]');
end $$;

-- ---------------------------------------------------------------------
-- 0007_backup_import.sql
-- ---------------------------------------------------------------------
-- 0007: backup, restore and one-time imports (admin only)
--   export_backup()                 full copy of the business data as JSON ("fcl-v2")
--   restore_backup(json, 'RESTORE') wipes the business data and loads a backup (fcl-v2 or an old prototype backup)
--   import_backup(json)             one-time load of a prototype backup into an empty database
--   import_excel(plan)              one-time load of the dealer's Excel, after the preview is approved
-- Users (profiles, logins) are never touched.

-- Tables in load order (parents first).
create or replace function private.backup_tables() returns text[] language sql immutable as $$
  select array['settings','suppliers','lots','lot_lines','lot_line_costs','laptops','laptop_costs','laptop_tests',
    'lot_expenses','repairs','photos','customers','bookings','booking_payments','invoices','sales','sale_payments','returns',
    'refunds','supplier_payments','debts','debt_payments','shop_expenses','model_prices','service_partners',
    'service_jobs','service_charges','service_payments','activity_log',
    'accessories','accessory_moves','accessory_move_costs','notifications','notification_reads']
$$;

create or replace function public.export_backup()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare t text; v jsonb; tabs jsonb := '{}';
begin
  perform private.require_admin();
  foreach t in array private.backup_tables() loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x) order by %s), ''[]'') from public.%I x',
                   case when t = 'activity_log' then 'x.id' else 'x.created_at' end, t) into v;
    tabs := tabs || jsonb_build_object(t, v);
  end loop;
  -- Recently deleted (30 days), so a restored backup can still restore those items
  tabs := tabs || jsonb_build_object('deletions', coalesce((select jsonb_agg(to_jsonb(d) order by d.deleted_at) from private.deletions d), '[]'));
  return jsonb_build_object('format', 'fcl-v2', 'exported_at', now(), 'tables', tabs);
end $$;

create or replace function private.wipe_business_data() returns void
language plpgsql set search_path = '' as $$
declare t text; list text := '';
begin
  foreach t in array private.backup_tables() loop list := list || ', public.' || quote_ident(t); end loop;
  execute 'truncate ' || substr(list, 3) || ', public.sync_ticks, private.rpc_requests, private.deletions restart identity cascade';
end $$;

-- Generic loader for an fcl-v2 backup: every table, every column (except generated ones).
-- Links to users that do not exist in this project are cleared rather than failing.
create or replace function private.load_v2(d jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare t text; cols text; exprs text; n int; counts jsonb := '{}';
begin
  foreach t in array private.backup_tables() loop
    if jsonb_typeof(d -> 'tables' -> t) is distinct from 'array' then continue; end if;
    select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position),
           string_agg(case when c.column_name in ('created_by','updated_by','deleted_by','voided_by','entered_by',
                                                   'given_by','received_by','advance_decided_by','actor_id')
                           then format('(select p.id from public.profiles p where p.id = x.%I)', c.column_name)
                           else 'x.' || quote_ident(c.column_name) end, ', ' order by c.ordinal_position)
      into cols, exprs
    from information_schema.columns c
    where c.table_schema = 'public' and c.table_name = t and c.is_generated = 'NEVER'
      and not (t = 'activity_log' and c.column_name = 'id');
    execute format('insert into public.%I (%s) select %s from jsonb_populate_recordset(null::public.%I, $1) x order by %s',
                   t, cols, exprs, t, case when t = 'activity_log' then 'x.at' else 'x.created_at' end)
      using d -> 'tables' -> t;
    get diagnostics n = row_count;
    counts := counts || jsonb_build_object(t, n);
  end loop;
  return counts;
end $$;

-- ---------- old prototype backups ----------
create or replace function private.guess_brand(t text) returns text language sql immutable set search_path = '' as $$
  select case when t ~* '\mdell\M|latitude|inspiron|vostro' then 'Dell'
              when t ~* '\mhp\M|elitebook|probook|pavilion' then 'HP'
              when t ~* 'lenovo|thinkpad|ideapad|\m[etxl]4[0-9]{2}\M' then 'Lenovo'
              when t ~* '\macer\M|\mascer\M|aspire' then 'Acer'
              when t ~* '\masus\M|vivobook|zenbook' then 'Asus'
              when t ~* 'apple|macbook' then 'Apple' end
$$;
create or replace function private.guess_processor(t text) returns text language sql immutable set search_path = '' as $$
  select case when t ~* '\mi3\M' then 'i3' when t ~* '\mi5\M' then 'i5' when t ~* '\mi7\M' then 'i7' when t ~* '\mi9\M' then 'i9'
              when t ~* 'ryzen ?3' then 'Ryzen 3' when t ~* 'ryzen ?5' then 'Ryzen 5' when t ~* 'ryzen ?7' then 'Ryzen 7'
              when t ~* 'pentium|pentinum' then 'Pentium' when t ~* 'celeron' then 'Celeron' end
$$;
create or replace function private.guess_gen(t text) returns int language sql immutable set search_path = '' as $$
  select nullif(substring(lower(coalesce(t, '')) from '\m([0-9]{1,2}) ?(?:st|nd|rd|th|ed|gen)\M'), '')::int
$$;

create or replace function private.proto_method(p text, p_allow_exchange boolean) returns text
language sql immutable set search_path = '' as $$
  select case when p in ('Cash','UPI','Bank') then p when p = 'Exchange' and p_allow_exchange then 'Exchange' else 'Cash' end
$$;

create or replace function private.load_proto_sale(p_laptop uuid, s jsonb, p_status text) returns uuid
language plpgsql set search_path = '' as $$
declare v_cust uuid; v_sale uuid; p jsonb;
begin
  begin
    v_cust := private.upsert_customer(s ->> 'mobile', s ->> 'name', s ->> 'address', 'Retail');
  exception when others then v_cust := null;    -- unusable mobile in the old data
  end;
  insert into public.sales (laptop_id, customer_id, customer_name, customer_address, lead_source, customer_type,
                            sold_on, price, warranty_months, status)
  values (p_laptop, v_cust, btrim(coalesce(s ->> 'name', '')), btrim(coalesce(s ->> 'address', '')), 'Other', 'Retail',
          (s ->> 'date')::date, (s ->> 'price')::numeric,
          case when v_cust is null then 0 else least(60, greatest(0, coalesce((s ->> 'warranty')::int, 0))) end, p_status)
  returning id into v_sale;
  for p in select * from jsonb_array_elements(coalesce(s -> 'payments', '[]')) loop
    if coalesce((p ->> 'amt')::numeric, 0) > 0 then
      insert into public.sale_payments (sale_id, paid_on, amount, method, ref)
      values (v_sale, coalesce((p ->> 'date')::date, (s ->> 'date')::date), round((p ->> 'amt')::numeric, 2),
              private.proto_method(p ->> 'method', true), coalesce(p ->> 'ref', ''));
    end if;
  end loop;
  return v_sale;
end $$;

create or replace function private.load_prototype(d jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare s jsonb; b jsonb; l jsonb; r jsonb; p jsonb; x record;
        v_sup uuid; v_lot uuid; v_line uuid; v_lap uuid; v_sale uuid; v_bk uuid; v_cust uuid; v_debt uuid;
        v_status text; v_prefix text; v_serial text; v_note text; v_per numeric; v_rest numeric; v_free int;
        n_lap int := 0; n_sale int := 0;
begin
  create temp table if not exists _map (kind text, old text, new uuid, primary key (kind, old)) on commit drop;
  delete from _map;

  s := d -> 'settings';
  if jsonb_typeof(s) = 'object' then
    update public.settings set shop_name = coalesce(nullif(btrim(s ->> 'shopName'), ''), shop_name),
      phone = coalesce(s ->> 'phone', phone), addr = coalesce(s ->> 'addr', addr),
      default_warranty_months = coalesce(least(60, (s ->> 'warranty')::int), default_warranty_months),
      old_days = coalesce(nullif((s ->> 'oldDays')::int, 0), old_days),
      cloud_name = coalesce(s ->> 'cloud', cloud_name), upload_preset = coalesce(s ->> 'preset', upload_preset)
    where id = 1;
  end if;

  for s in select * from jsonb_array_elements(coalesce(d -> 'suppliers', '[]')) loop
    insert into public.suppliers (code, name, phone)
    values (s ->> 'code', coalesce(nullif(btrim(s ->> 'name'), ''), 'Supplier ' || (s ->> 'code')), coalesce(s ->> 'phone', ''))
    on conflict (code) do update set name = excluded.name, phone = excluded.phone
    returning id into v_sup;
    insert into _map values ('sup', s ->> 'id', v_sup);
  end loop;

  for b in select * from jsonb_array_elements(coalesce(d -> 'batches', '[]')) loop
    select new into v_sup from _map where kind = 'sup' and old = b ->> 'supId';
    v_prefix := b ->> 'prefix';
    insert into public.lots (supplier_id, lot_no, month, year, prefix, kind, bought_on, note)
    values (v_sup, (b ->> 'batchNo')::int, (b ->> 'month')::int, (b ->> 'year')::int, v_prefix,
            case when left(v_prefix, 2) = '00' then 'exchange' else 'purchase' end,
            coalesce((b ->> 'date')::date, make_date((b ->> 'year')::int, (b ->> 'month')::int, 1)), 'From the old app')
    returning id into v_lot;
    insert into public.lot_lines (lot_id, line_no, is_mixed, model, qty)
    values (v_lot, 1, left(v_prefix, 2) = '00' or btrim(coalesce(b ->> 'model', '')) = '',
            case when left(v_prefix, 2) = '00' then '' else btrim(coalesce(b ->> 'model', '')) end,
            greatest(1, (select count(*) from jsonb_array_elements(coalesce(d -> 'laptops', '[]')) y where y ->> 'batchId' = b ->> 'id')))
    returning id into v_line;
    insert into _map values ('lot', b ->> 'id', v_lot), ('line', b ->> 'id', v_line);
  end loop;

  for l in select * from jsonb_array_elements(coalesce(d -> 'laptops', '[]')) loop
    select new into v_lot from _map where kind = 'lot' and old = l ->> 'batchId';
    select new into v_line from _map where kind = 'line' and old = l ->> 'batchId';
    v_status := case when jsonb_typeof(l -> 'sale') = 'object' then 'sold'
                     when jsonb_typeof(l -> 'reserve') = 'object' then 'booked' else 'in_stock' end;
    v_serial := btrim(coalesce(l ->> 'serial', ''));
    v_note := btrim(concat_ws('. ', nullif(btrim(coalesce(l ->> 'note', '')), ''),
                              case when coalesce(l ->> 'specs', '') <> '' then 'Specs: ' || (l ->> 'specs') end));
    if v_serial <> '' and exists (select 1 from public.laptops where upper(btrim(serial)) = upper(v_serial)) then
      v_note := btrim(concat_ws('. ', nullif(v_note, ''), 'Same serial as another laptop: ' || v_serial));
      v_serial := '';
    end if;
    insert into public.laptops (lot_id, line_id, piece_no, code, brand, processor, gen, model, serial, grade, status,
                                notes, test_note, tested_on, added_on)
    values (v_lot, v_line, right(l ->> 'code', 3)::int, l ->> 'code',
            private.guess_brand(l ->> 'model'), private.guess_processor(l ->> 'model'), private.guess_gen(l ->> 'model'),
            btrim(coalesce(l ->> 'model', '')), v_serial,
            case when l ->> 'grade' in ('A','B','C') then l ->> 'grade' else '' end, v_status,
            left(v_note, 300), coalesce(l ->> 'testNote', ''), (l ->> 'testedOn')::date,
            coalesce((l ->> 'added')::date, (select bought_on from public.lots where id = v_lot)))
    returning id into v_lap;
    n_lap := n_lap + 1;

    insert into public.laptop_tests (laptop_id, test, result)
    select v_lap, t.k, case when t.v = 'ok' then 'pass' else 'fail' end
    from jsonb_each_text(case when jsonb_typeof(l -> 'tests') = 'object' then l -> 'tests' else '{}' end) as t(k, v)
    where t.v in ('ok','fail')
      and t.k = any (array['Display','Keyboard','Touchpad','Battery','Charging','USB ports','Wi-Fi','Audio','Camera','Storage']);

    insert into public.repairs (laptop_id, work, amount, done_on)
    select v_lap, left(coalesce(nullif(btrim(e ->> 'desc'), ''), 'Repair'), 120), round((e ->> 'amt')::numeric, 2),
           coalesce((e ->> 'date')::date, private.today())
    from jsonb_array_elements(coalesce(l -> 'expenses', '[]')) e where coalesce((e ->> 'amt')::numeric, 0) > 0;

    insert into public.photos (laptop_id, url)
    select v_lap, u from jsonb_array_elements_text(coalesce(l -> 'photos', '[]')) u
    where u ~ '^https://res\.cloudinary\.com/[^\s"''<>]+$';

    if l ->> 'cost' is not null then
      insert into public.laptop_costs (laptop_id, cost, source)
      values (v_lap, round((l ->> 'cost')::numeric, 2), case when left(l ->> 'code', 2) = '00' then 'exchange' else 'import' end);
    end if;

    if v_status = 'sold' then perform private.load_proto_sale(v_lap, l -> 'sale', 'active'); n_sale := n_sale + 1; end if;
    for r in select * from jsonb_array_elements(coalesce(l -> 'returns', '[]')) loop
      v_sale := private.load_proto_sale(v_lap, r, 'returned');
      insert into public.returns (sale_id, laptop_id, returned_on, note)
      values (v_sale, v_lap, coalesce((r ->> 'retDate')::date, (r ->> 'date')::date), 'From the old app');
    end loop;
    if v_status = 'booked' then
      r := l -> 'reserve';
      v_cust := private.upsert_customer(r ->> 'mobile', r ->> 'name', r ->> 'address', 'Retail');
      insert into public.bookings (laptop_id, customer_id, customer_name, customer_address, lead_source, booked_on, agreed_price)
      values (v_lap, v_cust, btrim(coalesce(r ->> 'name', '')), btrim(coalesce(r ->> 'address', '')), 'Other',
              (r ->> 'date')::date, nullif((r ->> 'price')::numeric, 0))
      returning id into v_bk;
      insert into public.booking_payments (booking_id, paid_on, amount, method, ref)
      select v_bk, coalesce((p2 ->> 'date')::date, (r ->> 'date')::date), round((p2 ->> 'amt')::numeric, 2),
             private.proto_method(p2 ->> 'method', false), coalesce(p2 ->> 'ref', '')
      from jsonb_array_elements(coalesce(r -> 'payments', '[]')) p2 where coalesce((p2 ->> 'amt')::numeric, 0) > 0;
    end if;
  end loop;

  -- lot cost: what is left after laptops with their own cost, split over the others (same as the old app)
  for b in select * from jsonb_array_elements(coalesce(d -> 'batches', '[]')) loop
    if left(b ->> 'prefix', 2) = '00' or coalesce((b ->> 'cost')::numeric, 0) <= 0 then continue; end if;
    select new into v_line from _map where kind = 'line' and old = b ->> 'id';
    insert into public.lot_line_costs (line_id, line_cost) values (v_line, round((b ->> 'cost')::numeric, 2));
    select round((b ->> 'cost')::numeric, 2) - coalesce(sum(c.cost), 0) into v_rest
    from public.laptop_costs c join public.laptops x2 on x2.id = c.laptop_id where x2.line_id = v_line;
    select count(*) into v_free from public.laptops x2 where x2.line_id = v_line
      and not exists (select 1 from public.laptop_costs c where c.laptop_id = x2.id);
    if v_free > 0 and v_rest >= 0 then
      v_per := trunc(v_rest / v_free, 2);
      insert into public.laptop_costs (laptop_id, cost, source)
      select q.id, case when q.rn = v_free then v_rest - v_per * (v_free - 1) else v_per end, 'lot'
      from (select x2.id, row_number() over (order by x2.piece_no) rn from public.laptops x2
            where x2.line_id = v_line and not exists (select 1 from public.laptop_costs c where c.laptop_id = x2.id)) q;
    end if;
  end loop;

  for p in select * from jsonb_array_elements(coalesce(d -> 'supPay', '[]')) loop
    if p ->> 'method' = 'Exchange' or coalesce((p ->> 'amt')::numeric, 0) <= 0 then continue; end if;
    select new into v_sup from _map where kind = 'sup' and old = p ->> 'supId';
    if v_sup is null then continue; end if;
    insert into public.supplier_payments (supplier_id, paid_on, amount, method, ref)
    values (v_sup, (p ->> 'date')::date, round((p ->> 'amt')::numeric, 2), private.proto_method(p ->> 'method', false), coalesce(p ->> 'ref', ''));
  end loop;

  for p in select * from jsonb_array_elements(coalesce(d -> 'debts', '[]')) loop
    insert into public.debts (name, type, amount, due_on)
    values (coalesce(nullif(btrim(p ->> 'name'), ''), 'Debt'),
            case when p ->> 'type' in ('Shop rent','Loan','Borrowed','Bill','Other') then p ->> 'type' else 'Other' end,
            round((p ->> 'amount')::numeric, 2), nullif(p ->> 'due', '')::date)
    returning id into v_debt;
    insert into public.debt_payments (debt_id, paid_on, amount, method, ref)
    select v_debt, (q ->> 'date')::date, round((q ->> 'amt')::numeric, 2), private.proto_method(q ->> 'method', false), ''
    from jsonb_array_elements(coalesce(p -> 'payments', '[]')) q where coalesce((q ->> 'amt')::numeric, 0) > 0;
  end loop;

  insert into public.model_prices (shorthand, price)
  select left(btrim(k), 120), round(v::numeric, 2)
  from jsonb_each_text(case when jsonb_typeof(d -> 'prices') = 'object' then d -> 'prices' else '{}' end) as t(k, v)
  where btrim(k) <> '' and v::numeric > 0
  on conflict (shorthand) do nothing;

  insert into public.refunds (refunded_on, amount, method, label)
  select (f ->> 'date')::date, round((f ->> 'amt')::numeric, 2), private.proto_method(f ->> 'method', false), coalesce(f ->> 'note', '')
  from jsonb_array_elements(coalesce(d -> 'refunds', '[]')) f where coalesce((f ->> 'amt')::numeric, 0) > 0;

  insert into public.activity_log (at, actor_name, actor_role, action, message)
  select coalesce((g ->> 't')::timestamptz, now()), case when g ->> 'who' = 'coadmin' then 'Co-admin (old app)' else 'Admin (old app)' end,
         case when g ->> 'who' = 'coadmin' then 'coadmin' else 'admin' end, 'old_app', coalesce(g ->> 'what', '')
  from jsonb_array_elements(coalesce(d -> 'log', '[]')) g;

  return jsonb_build_object('suppliers', (select count(*) from _map where kind = 'sup'),
                            'lots', (select count(*) from _map where kind = 'lot'), 'laptops', n_lap, 'sales', n_sale);
end $$;

create or replace function private.load_any(d jsonb) returns jsonb
language plpgsql set search_path = '' as $$
begin
  if d ->> 'format' = 'fcl-v2' then return private.load_v2(d); end if;
  if jsonb_typeof(d -> 'laptops') = 'array' and jsonb_typeof(d -> 'suppliers') = 'array' then return private.load_prototype(d); end if;
  raise exception 'This is not a backup file from this app or the old app';
end $$;

create or replace function public.restore_backup(p_data jsonb, p_confirm text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  perform private.require_admin();
  if p_confirm is distinct from 'RESTORE' then raise exception 'Type RESTORE to confirm'; end if;
  if not (p_data ->> 'format' = 'fcl-v2' or jsonb_typeof(p_data -> 'laptops') = 'array') then
    raise exception 'This is not a backup file from this app or the old app';
  end if;
  perform set_config('app.no_log', 'on', true);
  perform private.wipe_business_data();
  if p_data ->> 'format' is distinct from 'fcl-v2' then
    insert into public.settings (id) values (1);
    insert into public.suppliers (code, name) values ('00', 'Customer exchange');
  end if;
  v := private.load_any(p_data);
  insert into public.settings (id) values (1) on conflict (id) do nothing;
  insert into public.suppliers (code, name) values ('00', 'Customer exchange') on conflict (code) do nothing;
  if jsonb_typeof(p_data -> 'tables' -> 'deletions') = 'array' then
    insert into private.deletions (id, kind, item_id, label, details, deleted_at, deleted_by, cloud_status, restored_at, restored_by, purged_at)
    select x.id, x.kind, x.item_id, x.label, x.details, x.deleted_at,
           (select p.id from public.profiles p where p.id = x.deleted_by), x.cloud_status, x.restored_at,
           (select p.id from public.profiles p where p.id = x.restored_by), x.purged_at
    from jsonb_populate_recordset(null::private.deletions, p_data -> 'tables' -> 'deletions') x;
  end if;
  perform set_config('app.no_log', 'off', true);
  perform private.log('restore', 'backup', null, 'Restored a backup');
  return v;
end $$;

-- One-time: load an old prototype backup into a database that has no lots yet.
create or replace function public.import_backup(p_data jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  perform private.require_admin();
  if exists (select 1 from public.lots where kind <> 'exchange') or exists (select 1 from public.sales) then
    raise exception 'This database already has data. Use Restore in Backup to replace everything.';
  end if;
  if jsonb_typeof(p_data -> 'laptops') is distinct from 'array' then raise exception 'This is not a backup file from the old app'; end if;
  perform set_config('app.no_log', 'on', true);
  v := private.load_prototype(p_data);
  perform set_config('app.no_log', 'off', true);
  perform private.log('import', 'backup', null, format('Imported the old app backup: %s laptops', v ->> 'laptops'));
  return v;
end $$;

-- ---------- one-time Excel import ----------
-- p: {"lots":[{"key","supplier","lot_no","bought_on","kind","note","lines":[...]}],
--     "expenses":[{"lot_key","spent_on","type","count","amount","method","line_no","note"}],
--     "sales":[{"lot_key","sold_on","price","lead_source","customer_type","name","method","specs":{...}}]}  one sale per laptop
create or replace function public.import_excel(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare lo jsonb; e jsonb; s jsonb; sp jsonb; v_sup uuid; v_no int; v_lot uuid; v_line uuid; v_lap uuid; r jsonb;
        n_sales int := 0; t_sales numeric := 0; n_exp int := 0; t_exp numeric := 0;
begin
  perform private.require_admin();
  if exists (select 1 from public.lots where kind <> 'exchange') or exists (select 1 from public.sales) then
    raise exception 'This database already has lots or sales. The Excel import runs only once, on an empty database.';
  end if;
  perform set_config('app.no_log', 'on', true);
  perform set_config('app.no_invoice', 'on', true);     -- old sales from the Excel get no invoice number
  create temp table if not exists _xl (key text primary key, lot uuid) on commit drop;
  delete from _xl;

  for lo in select * from jsonb_array_elements(coalesce(p -> 'lots', '[]')) loop
    select id into v_sup from public.suppliers where lower(name) = lower(btrim(lo ->> 'supplier')) and code <> '00';
    if v_sup is null then v_sup := (public.add_supplier(btrim(lo ->> 'supplier'), '') ->> 'id')::uuid; end if;
    v_no := (lo ->> 'lot_no')::int;
    if v_no is null or v_no not between 1 and 99 or exists (select 1 from public.lots where supplier_id = v_sup and lot_no = v_no
         and month = extract(month from (lo ->> 'bought_on')::date) and year = extract(year from (lo ->> 'bought_on')::date)) then
      select coalesce(max(lot_no), 0) + 1 into v_no from public.lots where supplier_id = v_sup;
    end if;
    r := public.create_lot(v_sup, v_no, (lo ->> 'bought_on')::date, lo -> 'lines',
                           coalesce(lo ->> 'kind', 'purchase'), coalesce(lo ->> 'note', ''));
    insert into _xl values (lo ->> 'key', (r ->> 'lot_id')::uuid);
  end loop;

  for e in select * from jsonb_array_elements(coalesce(p -> 'expenses', '[]')) loop
    select lot into v_lot from _xl where key = e ->> 'lot_key';
    if v_lot is null then raise exception 'Expense for unknown lot %', e ->> 'lot_key'; end if;
    v_line := null;
    if e ->> 'line_no' is not null then
      select id into v_line from public.lot_lines where lot_id = v_lot and line_no = (e ->> 'line_no')::int;
    end if;
    perform public.add_lot_expense(v_lot, e ->> 'type', (e ->> 'count')::int, (e ->> 'amount')::numeric,
                                   coalesce(e ->> 'method', 'Cash'), v_line, '', coalesce(e ->> 'note', ''), (e ->> 'spent_on')::date);
    n_exp := n_exp + 1; t_exp := t_exp + (e ->> 'amount')::numeric;
  end loop;

  for s in select * from jsonb_array_elements(coalesce(p -> 'sales', '[]')) order by value ->> 'sold_on' loop
    select lot into v_lot from _xl where key = s ->> 'lot_key';
    if v_lot is null then raise exception 'Sale for unknown lot %', s ->> 'lot_key'; end if;
    sp := coalesce(s -> 'specs', '{}');
    -- best unsold laptop in that lot: same model, then same brand/processor/gen, then a Mixed one, then any
    select l.id into v_lap
    from public.laptops l join public.lot_lines ln on ln.id = l.line_id
    where l.lot_id = v_lot and l.status = 'in_stock'
    order by case when not ln.is_mixed and coalesce(sp ->> 'model', '') <> '' and lower(ln.model) = lower(sp ->> 'model') then 0
                  when not ln.is_mixed and ln.brand is not distinct from sp ->> 'brand' and ln.processor is not distinct from sp ->> 'processor'
                       and ln.gen is not distinct from (sp ->> 'gen')::int then 1
                  when ln.is_mixed then 2 else 3 end, l.piece_no
    limit 1;
    if v_lap is null then raise exception 'Lot % has more sales than laptops', s ->> 'lot_key'; end if;
    update public.laptops set
      brand = coalesce(brand, sp ->> 'brand'), brand_other = case when brand_other = '' then coalesce(sp ->> 'brand_other', '') else brand_other end,
      model = case when model = '' then coalesce(sp ->> 'model', '') else model end,
      processor = coalesce(processor, sp ->> 'processor'), gen = coalesce(gen, (sp ->> 'gen')::int),
      ram_gb = coalesce(ram_gb, (sp ->> 'ram_gb')::int), storage_type = coalesce(storage_type, sp ->> 'storage_type'),
      storage_gb = coalesce(storage_gb, (sp ->> 'storage_gb')::int)
    where id = v_lap;
    perform private.do_sell(v_lap, coalesce(s ->> 'name', ''), '', '', s ->> 'lead_source', coalesce(s ->> 'customer_type', 'Retail'),
                            (s ->> 'price')::numeric, (s ->> 'price')::numeric, coalesce(s ->> 'method', 'UPI'), '',
                            (s ->> 'sold_on')::date, 0, null, null, true);
    n_sales := n_sales + 1; t_sales := t_sales + (s ->> 'price')::numeric;
  end loop;

  perform set_config('app.no_log', 'off', true);
  perform set_config('app.no_invoice', 'off', true);
  r := jsonb_build_object('lots', (select count(*) from _xl),
         'lines', (select count(*) from public.lot_lines ln join _xl on _xl.lot = ln.lot_id),
         'laptops', (select count(*) from public.laptops l join _xl on _xl.lot = l.lot_id),
         'cost', (select coalesce(sum(c.line_cost), 0) from public.lot_line_costs c join public.lot_lines ln on ln.id = c.line_id
                  join _xl on _xl.lot = ln.lot_id),
         'sales', n_sales, 'sales_total', t_sales, 'expenses', n_exp, 'expenses_total', t_exp);
  perform private.log('import', 'excel', null, format('Imported the Excel: %s lots, %s laptops, %s sales (%s), %s expenses (%s)',
          r ->> 'lots', r ->> 'laptops', n_sales, private.rs(t_sales), n_exp, private.rs(t_exp)));
  return r;
end $$;

-- ---------------------------------------------------------------------
-- 0008_admin_sql.sql
-- ---------------------------------------------------------------------
-- 0008: add a login from the SQL Editor only (for extra admins).
-- private.admin_add_user_sql(name, mobile, pin, role) creates the Supabase Auth user with a hidden email
-- (91<mobile>.<random>@fcl.local) and the PIN stored only as a bcrypt hash, plus the profile row.
-- It lives in the private schema and nobody but the database owner may run it, so the app can never call it.
-- The mobile and PIN are typed only in the SQL Editor; they are never stored in this repo.
-- Usage:  select private.admin_add_user_sql('Name', '9XXXXXXXXX', '0XXXXX', 'admin');   -- PIN in quotes keeps a leading 0

create extension if not exists pgcrypto with schema extensions;

create or replace function private.admin_add_user_sql(
  p_name text, p_mobile text, p_pin text, p_role text default 'admin', p_domain text default 'fcl.local'
) returns text
language plpgsql security definer set search_path = '' as $$
declare m text := regexp_replace(coalesce(p_mobile, ''), '\D', '', 'g'); v_id uuid := gen_random_uuid(); v_email text;
begin
  if length(m) = 12 and left(m, 2) = '91' then m := right(m, 10); end if;
  if m !~ '^[6-9][0-9]{9}$' then raise exception 'The mobile must be 10 digits, starting with 6 to 9'; end if;
  if coalesce(p_pin, '') !~ '^[0-9]{6}$' then raise exception 'The PIN must be exactly 6 digits, written in quotes, e.g. ''0XXXXX'''; end if;
  if p_role not in ('admin', 'coadmin', 'staff') then raise exception 'The role must be admin, coadmin or staff'; end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'Enter a name'; end if;

  -- safe to run twice: nothing happens if this mobile already has a login
  if exists (select 1 from public.profiles where mobile = m)
     or exists (select 1 from auth.users where email like '91' || m || '.%') then
    return 'Nothing done: mobile ' || m || ' already has a login.';
  end if;

  v_email := '91' || m || '.' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8) || '@' || p_domain;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, recovery_token, email_change, email_change_token_new)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', v_email,
          extensions.crypt(p_pin, extensions.gen_salt('bf', 10)), now(),
          '{"provider": "email", "providers": ["email"]}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', '');
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (v_id::text, v_id, jsonb_build_object('sub', v_id::text, 'email', v_email, 'email_verified', true), 'email', now(), now(), now());
  insert into public.profiles (id, name, mobile, role, active) values (v_id, btrim(p_name), m, p_role, true);
  insert into public.activity_log (actor_name, action, entity, entity_id, message)
  values ('System', 'user', 'user', v_id::text, format('Added user %s (%s) from the SQL Editor', btrim(p_name),
          case p_role when 'admin' then 'Admin' when 'coadmin' then 'Co-admin' else 'Staff' end));
  return format('Added %s as %s. Log in with mobile %s and the PIN, then change the PIN in More, Change my PIN.',
                btrim(p_name), p_role, m);
end $$;

revoke all on function private.admin_add_user_sql(text, text, text, text, text) from public;

-- ---------------------------------------------------------------------
-- 0008b_deletes.sql
-- ---------------------------------------------------------------------
-- 0008b: delete and restore (Recently deleted, 30 days), with the rules enforced here, not only in the app.
-- Laptops, lots, suppliers and service partners: admin only. Photos: admin and co-admin.
-- Payments are never deleted, users are turned off (not deleted), customers stay (they come from sales).
-- Safe to run twice.

-- ---------- cost helpers that must ignore deleted laptops ----------
-- This laptop's equal share of its lot's parts/expenses, shared only among laptops that are not deleted.
create or replace function private.lot_share(p_laptop uuid) returns numeric
language sql stable set search_path = '' as $$
  select coalesce(sum(
           (e.amount - (select f.value from private.fitted(e.id) f))
           / nullif((select count(*) from private.live_laptops x
                     where x.lot_id = e.lot_id and (e.line_id is null or x.line_id = e.line_id)), 0)
         ), 0)
  from public.laptops l
  join public.lot_expenses e on e.lot_id = l.lot_id and e.deleted_at is null
                            and (e.line_id is null or e.line_id = l.line_id)
  where l.id = p_laptop
$$;

-- Each laptop's purchase cost from its line, split over the laptops that are not deleted.
create or replace function private.write_line_costs(p_line uuid) returns void
language plpgsql set search_path = '' as $$
declare v_cost numeric; v_n int; v_per numeric; v_last int;
begin
  select line_cost into v_cost from public.lot_line_costs where line_id = p_line;
  delete from public.laptop_costs c using private.live_laptops l where l.id = c.laptop_id and l.line_id = p_line;
  if v_cost is null then return; end if;
  select count(*), max(piece_no) into v_n, v_last from private.live_laptops where line_id = p_line;
  if v_n = 0 then return; end if;
  v_per := trunc(v_cost / v_n, 2);
  insert into public.laptop_costs (laptop_id, cost, source)
  select l.id, case when l.piece_no = v_last then v_cost - v_per * (v_n - 1) else v_per end, 'lot'
  from private.live_laptops l where l.line_id = p_line;
end $$;

create or replace function private.supplier_due(p_supplier uuid) returns numeric
language sql stable set search_path = '' as $$
  select case when s.code = '00' then 0 else
    coalesce((select sum(c.cost) from public.laptop_costs c join private.live_laptops l on l.id = c.laptop_id
              join private.live_lots lo on lo.id = l.lot_id where lo.supplier_id = s.id), 0)
  - coalesce((select sum(p.amount) from public.supplier_payments p where p.supplier_id = s.id), 0) end
  from public.suppliers s where s.id = p_supplier
$$;

-- ---------- rules ----------
-- Why a laptop must stay (null = it may be deleted). Anything with a customer or money in its history stays.
create or replace function private.laptop_block_reason(p_laptop uuid) returns text
language sql stable set search_path = '' as $$
  select case
    when exists (select 1 from public.sales where laptop_id = p_laptop and status = 'active')
      then 'This laptop has a sale. Use Undo sale or Return instead.'
    when exists (select 1 from public.returns where laptop_id = p_laptop)
      then 'This laptop was returned by a customer, so it stays in the history.'
    when exists (select 1 from public.sales where laptop_id = p_laptop)
      then 'This laptop was sold before (the sale was undone), so it stays in the history.'
    when exists (select 1 from public.bookings where laptop_id = p_laptop)
      then 'This laptop was booked by a customer, so it stays in the history.'
    when exists (select 1 from public.service_jobs where laptop_id = p_laptop)
      then 'This laptop went for service, so it stays in the history.'
    when exists (select 1 from public.laptops l join public.lots lo on lo.id = l.lot_id where l.id = p_laptop and lo.kind = 'exchange')
      then 'This laptop came in exchange on a sale. Its value is part of that sale''s payment.'
  end
$$;

-- Unsold laptops (with a cost) that would carry a deleted laptop's cost: same group first, else the same lot.
create or replace function private.cost_carriers(p_laptop uuid) returns uuid[]
language plpgsql stable set search_path = '' as $$
declare l public.laptops; v uuid[];
begin
  select * into l from public.laptops where id = p_laptop;
  select array_agg(x.id order by x.piece_no) into v from private.live_laptops x
  where x.line_id = l.line_id and x.id <> l.id and not private.is_sold(x.id)
    and exists (select 1 from public.laptop_costs c where c.laptop_id = x.id);
  if v is null then
    select array_agg(x.id order by x.piece_no) into v from private.live_laptops x
    where x.lot_id = l.lot_id and x.id <> l.id and not private.is_sold(x.id)
      and exists (select 1 from public.laptop_costs c where c.laptop_id = x.id);
  end if;
  return coalesce(v, '{}');
end $$;

-- ---------- laptop ----------
-- What the app shows before asking: may it be deleted, and the cost choice.
create or replace function public.delete_laptop_check(p_laptop_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare l public.laptops; v_cost numeric; v_carry uuid[];
begin
  perform private.require_admin();
  select * into l from private.live_laptops where id = p_laptop_id;
  if not found then raise exception 'Laptop not found'; end if;
  v_cost := private.cost_of(l.id);
  v_carry := private.cost_carriers(l.id);
  return jsonb_build_object('code', l.code, 'reason', private.laptop_block_reason(l.id),
    'cost', v_cost, 'can_keep', v_cost is not null and v_cost > 0 and cardinality(v_carry) > 0, 'keep_count', cardinality(v_carry));
end $$;

-- p_lot_cost: 'reduce' = the lot cost goes down by this laptop's cost;
--             'keep'   = the lot cost stays; this laptop's cost is shared over the other unsold laptops.
create or replace function public.delete_laptop(p_laptop_id uuid, p_lot_cost text default 'reduce', p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; l public.laptops; v_why text; v_cost numeric; v_carry uuid[]; v_n int; v_per numeric; v_deltas jsonb := '[]';
        v_mode text := coalesce(p_lot_cost, 'reduce'); v_del uuid; i int; d numeric;
begin
  perform private.require_admin();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  if v_mode not in ('reduce', 'keep') then raise exception 'Choose reduce or keep for the lot cost'; end if;
  select * into l from public.laptops where id = p_laptop_id for update;
  if not found or l.deleted_at is not null then raise exception 'Laptop not found, or already deleted'; end if;
  v_why := private.laptop_block_reason(l.id);
  if v_why is not null then raise exception '%', v_why; end if;
  v_cost := private.cost_of(l.id);
  if v_cost is null or v_cost = 0 then v_mode := 'none';
  elsif v_mode = 'keep' then
    v_carry := private.cost_carriers(l.id); v_n := cardinality(v_carry);
    if v_n = 0 then raise exception 'There is no other unsold laptop in this lot to carry the cost. Choose to reduce the lot cost.'; end if;
    v_per := trunc(v_cost / v_n, 2);
    for i in 1 .. v_n loop
      d := case when i = v_n then v_cost - v_per * (v_n - 1) else v_per end;
      update public.laptop_costs set cost = cost + d where laptop_id = v_carry[i];
      v_deltas := v_deltas || jsonb_build_array(jsonb_build_object('id', v_carry[i], 'delta', d));
    end loop;
  else
    update public.lot_line_costs set line_cost = greatest(line_cost - v_cost, 0) where line_id = l.line_id;
  end if;
  update public.laptops set deleted_at = now(), deleted_by = auth.uid() where id = l.id;
  insert into private.deletions (kind, item_id, label, details, deleted_by)
  values ('laptop', l.id, l.code || coalesce(' · ' || nullif(concat_ws(' ', nullif(l.shorthand, ''), nullif(l.model, '')), ''), ''),
          jsonb_build_object('mode', v_mode, 'cost', v_cost, 'line_id', l.line_id, 'deltas', v_deltas), auth.uid())
  returning id into v_del;
  perform private.log('delete', 'laptop', l.code, format('Deleted laptop %s', l.code));
  if v_mode = 'reduce' then
    perform private.log('delete', 'laptop', l.code, format('Lot cost reduced by %s for deleted laptop %s', private.rs(v_cost), l.code), true);
  elsif v_mode = 'keep' then
    perform private.log('delete', 'laptop', l.code, format('Lot cost kept: %s of deleted laptop %s shared over %s other laptops', private.rs(v_cost), l.code, v_n), true);
  end if;
  v := jsonb_build_object('deletion_id', v_del, 'code', l.code, 'mode', v_mode);
  return private.idem_put(p_client_ref, v);
end $$;

-- ---------- lot ----------
create or replace function public.delete_lot_check(p_lot_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare lo public.lots;
begin
  perform private.require_admin();
  select * into lo from private.live_lots where id = p_lot_id;
  if not found then raise exception 'Lot not found'; end if;
  return jsonb_build_object('prefix', lo.prefix, 'kind', lo.kind,
    'laptops', (select count(*) from private.live_laptops where lot_id = lo.id),
    'expenses', (select count(*) from public.lot_expenses where lot_id = lo.id and deleted_at is null),
    'blockers', coalesce((select jsonb_agg(jsonb_build_object('code', x.code, 'reason', private.laptop_block_reason(x.id)) order by x.piece_no)
                          from private.live_laptops x where x.lot_id = lo.id and private.laptop_block_reason(x.id) is not null), '[]'));
end $$;

-- p_confirm must be the lot code (e.g. 01-01-11-26), typed by the admin.
create or replace function public.delete_lot(p_lot_id uuid, p_confirm text, p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; lo public.lots; v_block text; v_laps uuid[]; v_exps uuid[]; v_del uuid;
begin
  perform private.require_admin();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  select * into lo from public.lots where id = p_lot_id for update;
  if not found or lo.deleted_at is not null then raise exception 'Lot not found, or already deleted'; end if;
  if lo.kind = 'exchange' then raise exception 'The exchange lot holds laptops taken in on sales. It cannot be deleted.'; end if;
  if btrim(coalesce(p_confirm, '')) <> lo.prefix then raise exception 'Type the lot code % to confirm', lo.prefix; end if;
  select string_agg(x.code || ': ' || private.laptop_block_reason(x.id), E'\n' order by x.piece_no) into v_block
  from public.laptops x where x.lot_id = lo.id and x.deleted_at is null and private.laptop_block_reason(x.id) is not null;
  if v_block is not null then raise exception E'These laptops must stay, so the lot cannot be deleted:\n%', v_block; end if;
  with u as (update public.laptops set deleted_at = now(), deleted_by = auth.uid()
             where lot_id = lo.id and deleted_at is null returning id)
  select coalesce(array_agg(id), '{}') into v_laps from u;
  with u as (update public.lot_expenses set deleted_at = now(), deleted_by = auth.uid()
             where lot_id = lo.id and deleted_at is null returning id)
  select coalesce(array_agg(id), '{}') into v_exps from u;
  update public.lots set deleted_at = now(), deleted_by = auth.uid() where id = lo.id;
  insert into private.deletions (kind, item_id, label, details, deleted_by)
  values ('lot', lo.id, format('Lot %s, %s laptop%s', lo.prefix, cardinality(v_laps), case when cardinality(v_laps) = 1 then '' else 's' end),
          jsonb_build_object('laptops', to_jsonb(v_laps), 'expenses', to_jsonb(v_exps)), auth.uid())
  returning id into v_del;
  perform private.log('delete', 'lot', lo.prefix, format('Deleted lot %s with %s laptop%s', lo.prefix, cardinality(v_laps), case when cardinality(v_laps) = 1 then '' else 's' end));
  v := jsonb_build_object('deletion_id', v_del, 'prefix', lo.prefix, 'laptops', cardinality(v_laps));
  return private.idem_put(p_client_ref, v);
end $$;

-- ---------- supplier, service partner ----------
create or replace function public.delete_supplier(p_supplier_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.suppliers; v_del uuid; n int;
begin
  perform private.require_admin();
  select * into s from public.suppliers where id = p_supplier_id for update;
  if not found or s.deleted_at is not null then raise exception 'Supplier not found, or already deleted'; end if;
  if s.code = '00' then raise exception 'The customer exchange supplier is part of the app. It cannot be deleted.'; end if;
  select count(*) into n from public.lots where supplier_id = s.id and deleted_at is null;
  if n > 0 then raise exception 'This supplier has % lot%. Delete the lots first, or keep the supplier.', n, case when n = 1 then '' else 's' end; end if;
  if exists (select 1 from public.lots where supplier_id = s.id) then
    raise exception 'This supplier had lots before (now deleted). It stays so their sticker numbers stay unique.';
  end if;
  if exists (select 1 from public.supplier_payments where supplier_id = s.id) then
    raise exception 'This supplier has payments in the history, so it stays.';
  end if;
  update public.suppliers set deleted_at = now(), deleted_by = auth.uid() where id = s.id;
  insert into private.deletions (kind, item_id, label, deleted_by)
  values ('supplier', s.id, format('Supplier %s, %s', s.code, s.name), auth.uid()) returning id into v_del;
  perform private.log('delete', 'supplier', s.code, format('Deleted supplier %s, %s', s.code, s.name));
  return jsonb_build_object('deletion_id', v_del);
end $$;

create or replace function public.delete_service_partner(p_partner_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.service_partners; v_del uuid; v_name text;
begin
  perform private.require_admin();
  select * into p from public.service_partners where id = p_partner_id for update;
  if not found or p.deleted_at is not null then raise exception 'Service partner not found, or already deleted'; end if;
  if exists (select 1 from public.service_jobs where partner_id = p.id) then
    raise exception 'This partner has service jobs in the history. Turn them off instead.';
  end if;
  if exists (select 1 from public.service_payments where partner_id = p.id) then
    raise exception 'This partner has payments in the history. Turn them off instead.';
  end if;
  v_name := coalesce(nullif(btrim(p.shop_name), ''), p.name);
  update public.service_partners set deleted_at = now(), deleted_by = auth.uid() where id = p.id;
  insert into private.deletions (kind, item_id, label, deleted_by)
  values ('partner', p.id, 'Service partner ' || v_name, auth.uid()) returning id into v_del;
  perform private.log('delete', 'partner', p.id::text, format('Deleted service partner %s', v_name));
  return jsonb_build_object('deletion_id', v_del);
end $$;

-- ---------- photo (admin and co-admin) ----------
-- Removes the photo from the app at once. The photo-delete Edge Function then removes the Cloudinary copy
-- and reports back with photo_cloud_result. If that fails, the photo stays out of the app and the failure is logged.
create or replace function public.delete_photo(p_photo_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ph public.photos; v_code text; v_del uuid;
begin
  perform private.require_manager();
  select * into ph from public.photos where id = p_photo_id for update;
  if not found or ph.deleted_at is not null then raise exception 'Photo not found, or already deleted'; end if;
  select code into v_code from public.laptops where id = ph.laptop_id;
  update public.photos set deleted_at = now(), deleted_by = auth.uid() where id = ph.id;
  insert into private.deletions (kind, item_id, label, details, deleted_by, cloud_status)
  values ('photo', ph.id, 'Photo of ' || v_code, jsonb_build_object('url', ph.url, 'laptop_id', ph.laptop_id), auth.uid(), 'pending')
  returning id into v_del;
  perform private.log('delete', 'photo', v_code, format('Deleted a photo of %s', v_code));
  return jsonb_build_object('deletion_id', v_del, 'url', ph.url, 'code', v_code);
end $$;

-- Called only by the photo-delete Edge Function (service key) after it tried Cloudinary.
create or replace function public.photo_cloud_result(p_deletion_id uuid, p_status text, p_detail text default '')
returns void language plpgsql security definer set search_path = '' as $$
declare d private.deletions;
begin
  if p_status not in ('deleted', 'failed', 'skipped') then raise exception 'Bad status'; end if;
  update private.deletions set cloud_status = p_status,
         details = details || jsonb_build_object('cloud_detail', left(coalesce(p_detail, ''), 300))
  where id = p_deletion_id and kind = 'photo' returning * into d;
  if not found then raise exception 'Not found'; end if;
  if p_status = 'failed' then
    perform private.log('delete', 'photo', d.label, format('%s: the Cloudinary copy could not be deleted (%s). It is gone from the app.', d.label, left(coalesce(p_detail, ''), 120)));
  end if;
end $$;

-- ---------- recently deleted, restore, 30-day cleanup ----------
-- After 30 days a delete is final: photos, suppliers and partners are removed; deleted laptops and lots keep a
-- hidden row (code only) so their sticker numbers are never used again, and lose their photos and tests.
create or replace function private.purge_deleted() returns int
language plpgsql security definer set search_path = '' as $$
declare d private.deletions; n int := 0; v_laps uuid[];
begin
  perform set_config('app.purging', 'on', true);
  for d in select * from private.deletions where restored_at is null and purged_at is null
             and deleted_at < now() - interval '30 days' for update skip locked loop
    if d.kind = 'accessory' then
      null;   -- the accessory stays hidden (its stock history is kept)
    elsif d.kind = 'photo' then
      delete from public.photos where id = d.item_id and deleted_at is not null;
    elsif d.kind = 'supplier' then
      delete from public.suppliers s where s.id = d.item_id and s.deleted_at is not null
        and not exists (select 1 from public.lots where supplier_id = s.id)
        and not exists (select 1 from public.supplier_payments where supplier_id = s.id);
    elsif d.kind = 'partner' then
      delete from public.service_partners p where p.id = d.item_id and p.deleted_at is not null
        and not exists (select 1 from public.service_jobs where partner_id = p.id)
        and not exists (select 1 from public.service_payments where partner_id = p.id);
    else
      v_laps := case when d.kind = 'laptop' then array[d.item_id]
                     else array(select jsonb_array_elements_text(d.details -> 'laptops')::uuid) end;
      delete from public.photos where laptop_id = any (v_laps);
      delete from public.laptop_tests where laptop_id = any (v_laps);
    end if;
    update private.deletions set purged_at = now() where id = d.id;
    n := n + 1;
  end loop;
  perform set_config('app.purging', 'off', true);
  return n;
end $$;

create or replace function public.recently_deleted()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  perform private.purge_deleted();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', d.id, 'kind', d.kind, 'label', d.label, 'deleted_at', d.deleted_at,
      'by', coalesce((select name from public.profiles where id = d.deleted_by), 'Someone'),
      'days_left', greatest(0, 30 - floor(extract(epoch from now() - d.deleted_at) / 86400)::int),
      'mode', d.details ->> 'mode', 'cost', (d.details ->> 'cost')::numeric,
      'url', d.details ->> 'url', 'cloud', d.cloud_status,
      'can_restore', not (d.kind = 'photo' and d.cloud_status = 'deleted'))
    order by d.deleted_at desc)
    from private.deletions d where d.restored_at is null and d.purged_at is null), '[]');
end $$;

create or replace function public.restore_deleted(p_deletion_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d private.deletions; x jsonb; v_code text; v_lot text;
begin
  perform private.require_admin();
  select * into d from private.deletions where id = p_deletion_id for update;
  if not found or d.restored_at is not null then raise exception 'Nothing to restore'; end if;
  if d.purged_at is not null or d.deleted_at < now() - interval '30 days' then
    raise exception 'This was deleted more than 30 days ago and is gone for good.';
  end if;
  if d.kind = 'laptop' then
    select l.code, lo.prefix into v_code, v_lot from public.laptops l join public.lots lo on lo.id = l.lot_id
    where l.id = d.item_id and lo.deleted_at is not null;
    if v_lot is not null then raise exception 'Lot % is deleted. Restore the lot first.', v_lot; end if;
    for x in select * from jsonb_array_elements(d.details -> 'deltas') loop
      update public.laptop_costs set cost = greatest(cost - (x ->> 'delta')::numeric, 0) where laptop_id = (x ->> 'id')::uuid;
    end loop;
    if d.details ->> 'mode' = 'reduce' then
      update public.lot_line_costs set line_cost = line_cost + (d.details ->> 'cost')::numeric where line_id = (d.details ->> 'line_id')::uuid;
    end if;
    update public.laptops set deleted_at = null, deleted_by = null where id = d.item_id returning code into v_code;
    perform private.log('restore', 'laptop', v_code, format('Restored laptop %s', v_code));
  elsif d.kind = 'lot' then
    if exists (select 1 from public.lots lo join public.suppliers s on s.id = lo.supplier_id where lo.id = d.item_id and s.deleted_at is not null) then
      raise exception 'The supplier of this lot is deleted. Restore the supplier first.';
    end if;
    update public.lots set deleted_at = null, deleted_by = null where id = d.item_id returning prefix into v_lot;
    update public.laptops set deleted_at = null, deleted_by = null
    where id in (select jsonb_array_elements_text(d.details -> 'laptops')::uuid);
    update public.lot_expenses set deleted_at = null, deleted_by = null
    where id in (select jsonb_array_elements_text(d.details -> 'expenses')::uuid);
    perform private.log('restore', 'lot', v_lot, format('Restored lot %s', v_lot));
  elsif d.kind = 'supplier' then
    update public.suppliers set deleted_at = null, deleted_by = null where id = d.item_id returning code || ', ' || name into v_code;
    perform private.log('restore', 'supplier', d.item_id::text, format('Restored supplier %s', v_code));
  elsif d.kind = 'accessory' then
    if exists (select 1 from public.accessories x join public.accessories y on lower(btrim(y.name)) = lower(btrim(x.name))
               where x.id = d.item_id and y.id <> x.id and y.deleted_at is null) then
      raise exception 'Another accessory with this name exists now. Rename or delete it first.';
    end if;
    update public.accessories set deleted_at = null, deleted_by = null where id = d.item_id returning name into v_code;
    perform private.log('restore', 'accessory', d.item_id::text, format('Restored accessory %s', v_code));
  elsif d.kind = 'partner' then
    update public.service_partners set deleted_at = null, deleted_by = null where id = d.item_id;
    perform private.log('restore', 'partner', d.item_id::text, format('Restored service partner %s', private.partner_label(d.item_id)));
  else
    if d.cloud_status = 'deleted' then raise exception 'This photo was also removed from Cloudinary, so it cannot come back.'; end if;
    if exists (select 1 from public.photos p join public.laptops l on l.id = p.laptop_id where p.id = d.item_id and l.deleted_at is not null) then
      raise exception 'The laptop of this photo is deleted. Restore the laptop first.';
    end if;
    update public.photos set deleted_at = null, deleted_by = null where id = d.item_id;
    perform private.log('restore', 'photo', d.label, format('Restored %s', lower(left(d.label, 1)) || substr(d.label, 2)));
  end if;
  update private.deletions set restored_at = now(), restored_by = auth.uid() where id = d.id;
  return jsonb_build_object('kind', d.kind, 'label', d.label);
end $$;

-- The daily keep-alive call (GitHub Actions, 09:00 India time) also runs the 30-day cleanup.
create or replace function public.ping() returns text
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform private.purge_deleted();
  return 'ok ' || (select count(*) from public.settings)::text;
end $$;

-- ---------------------------------------------------------------------
-- 0008c_accessories_rpc.sql
-- ---------------------------------------------------------------------
-- 0008c: accessories (add, stock in, sell or give, adjust, delete) and notifications. Safe to run twice.
-- Who may do what: staff sell or give and see quantities; co-admin also adds stock, adjusts and edits (never sees cost);
-- admin everything, including costs, profit and delete.

-- Average cost of one unit (purchases with a cost entered). Admin only, used for profit.
create or replace function private.acc_avg_cost(p_acc uuid) returns numeric
language sql stable set search_path = '' as $$
  select round(sum(c.unit_cost * m.delta) / nullif(sum(m.delta), 0), 2)
  from public.accessory_moves m join public.accessory_move_costs c on c.move_id = m.id
  where m.accessory_id = p_acc and m.kind = 'in'
$$;
create or replace function private.acc_last_cost(p_acc uuid) returns numeric
language sql stable set search_path = '' as $$
  select c.unit_cost from public.accessory_moves m join public.accessory_move_costs c on c.move_id = m.id
  where m.accessory_id = p_acc and m.kind = 'in' order by m.created_at desc limit 1
$$;

create or replace function private.accessory_json(p_acc uuid, p_role text) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', a.id, 'name', a.name, 'qty', private.acc_qty(a.id), 'alert_at', a.alert_at, 'price', a.price,
                            'low', private.acc_qty(a.id) <= a.alert_at)
  || case when p_role = 'admin' then jsonb_build_object('cost', private.acc_last_cost(a.id), 'avg_cost', private.acc_avg_cost(a.id)) else '{}'::jsonb end
  from public.accessories a where a.id = p_acc
$$;

create or replace function private.acc_lock(p_acc uuid) returns public.accessories
language plpgsql set search_path = '' as $$
declare a public.accessories;
begin
  select * into a from public.accessories where id = p_acc for update;
  if not found or a.deleted_at is not null then raise exception 'Accessory not found'; end if;
  return a;
end $$;

-- ---------- add / edit ----------
create or replace function public.add_accessory(p_name text, p_opening int default 0, p_alert int default 2,
  p_cost numeric default null, p_price numeric default null, p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_id uuid; v_move uuid; r text := private.require_manager();
begin
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'Enter the name'; end if;
  if coalesce(p_opening, 0) < 0 then raise exception 'Opening stock cannot be below 0'; end if;
  if exists (select 1 from public.accessories where lower(btrim(name)) = lower(btrim(p_name)) and deleted_at is null) then
    raise exception '% is already in the list. Tap it to add stock.', btrim(p_name);
  end if;
  insert into public.accessories (name, alert_at, price) values (btrim(p_name), greatest(coalesce(p_alert, 2), 0), p_price)
  returning id into v_id;
  if coalesce(p_opening, 0) > 0 then
    insert into public.accessory_moves (accessory_id, kind, delta, note) values (v_id, 'in', p_opening, 'Opening stock') returning id into v_move;
    if p_cost is not null then insert into public.accessory_move_costs (move_id, unit_cost) values (v_move, p_cost); end if;
  else
    perform private.acc_check_low(v_id, 'Added with no stock');
  end if;
  v := jsonb_build_object('id', v_id);
  return private.idem_put(p_client_ref, v);
end $$;

create or replace function public.save_accessory(p_id uuid, p_name text, p_alert int, p_price numeric default null)
returns void language plpgsql security definer set search_path = '' as $$
declare a public.accessories;
begin
  perform private.require_manager();
  a := private.acc_lock(p_id);
  if btrim(coalesce(p_name, '')) = '' then raise exception 'Enter the name'; end if;
  if exists (select 1 from public.accessories where lower(btrim(name)) = lower(btrim(p_name)) and deleted_at is null and id <> p_id) then
    raise exception '% is already in the list.', btrim(p_name);
  end if;
  update public.accessories set name = btrim(p_name), alert_at = greatest(coalesce(p_alert, a.alert_at), 0), price = p_price where id = p_id;
end $$;

-- ---------- movements ----------
-- New stock bought (admin, co-admin). Cost is optional; only the admin ever sees it.
create or replace function public.accessory_in(p_id uuid, p_qty int, p_cost_each numeric default null, p_supplier_id uuid default null,
  p_on date default null, p_method text default 'Cash', p_note text default '', p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_move uuid;
begin
  perform private.require_manager();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  perform private.acc_lock(p_id);
  if coalesce(p_qty, 0) < 1 then raise exception 'Enter how many'; end if;
  if p_cost_each is not null and p_cost_each < 0 then raise exception 'Check the cost'; end if;
  if coalesce(p_on, private.today()) > private.today() then raise exception 'The date cannot be in the future'; end if;
  insert into public.accessory_moves (accessory_id, kind, delta, method, supplier_id, note, moved_on)
  values (p_id, 'in', p_qty, case when p_cost_each is null then null else coalesce(p_method, 'Cash') end, p_supplier_id,
          left(btrim(coalesce(p_note, '')), 300), coalesce(p_on, private.today()))
  returning id into v_move;
  if p_cost_each is not null then insert into public.accessory_move_costs (move_id, unit_cost) values (v_move, p_cost_each); end if;
  v := jsonb_build_object('qty', private.acc_qty(p_id));
  return private.idem_put(p_client_ref, v);
end $$;

create or replace function private.acc_out(p_id uuid, p_qty int, p_price_each numeric, p_free boolean, p_method text,
  p_customer text, p_mobile text, p_note text, p_sale uuid) returns void
language plpgsql set search_path = '' as $$
declare a public.accessories; q int; v_amt numeric;
begin
  a := private.acc_lock(p_id);
  if coalesce(p_qty, 0) < 1 then raise exception 'Enter how many'; end if;
  q := private.acc_qty(p_id);
  if p_qty > q then raise exception 'Only % % left.', q, a.name; end if;
  v_amt := case when coalesce(p_free, false) then 0 else round(coalesce(p_price_each, a.price, 0) * p_qty, 2) end;
  if v_amt < 0 then raise exception 'Check the price'; end if;
  insert into public.accessory_moves (accessory_id, kind, delta, amount, free, method, sale_id, customer, mobile, note)
  values (p_id, 'out', -p_qty, v_amt, coalesce(p_free, false) or v_amt = 0, case when v_amt > 0 then coalesce(p_method, 'Cash') end,
          p_sale, btrim(coalesce(p_customer, '')), regexp_replace(coalesce(p_mobile, ''), '\D', '', 'g'), left(btrim(coalesce(p_note, '')), 300));
end $$;

-- Sell or give (everyone, staff included)
create or replace function public.accessory_out(p_id uuid, p_qty int, p_price_each numeric default null, p_free boolean default false,
  p_method text default 'Cash', p_customer text default '', p_mobile text default '', p_note text default '', p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  perform private.require_user();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  perform private.acc_out(p_id, p_qty, p_price_each, p_free, p_method, p_customer, p_mobile, p_note, null);
  v := jsonb_build_object('qty', private.acc_qty(p_id));
  return private.idem_put(p_client_ref, v);
end $$;

-- Accessories given with a laptop sale (single sale, or the bulk sale it belongs to).
-- p_items: [{"id": "...", "qty": 2, "price_each": 400}]. Free: no charge; otherwise the money is received now.
create or replace function public.give_accessories(p_sale_id uuid default null, p_bulk_group uuid default null, p_items jsonb default '[]',
  p_free boolean default true, p_method text default 'Cash', p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; s public.sales; x jsonb; v_inv text;
begin
  perform private.require_user();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  select * into s from public.sales where status = 'active'
    and (id = p_sale_id or (p_bulk_group is not null and bulk_group = p_bulk_group)) order by created_at limit 1;
  if not found then raise exception 'Sale not found'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Pick the accessories'; end if;
  v_inv := case when s.invoice_no is not null then 'INV-' || s.invoice_no else '' end;
  -- lock in a fixed order, so two phones never wait on each other
  for x in select * from jsonb_array_elements(p_items) e order by e ->> 'id' loop
    perform private.acc_out((x ->> 'id')::uuid, (x ->> 'qty')::int, (x ->> 'price_each')::numeric, p_free, p_method,
                            private.cust_label(s.customer_name, s.lead_source), coalesce((select mobile from public.customers where id = s.customer_id), ''),
                            case when v_inv <> '' then 'With laptop sale ' || v_inv else 'With laptop sale' end, s.id);
  end loop;
  v := jsonb_build_object('sale_id', s.id);
  return private.idem_put(p_client_ref, v);
end $$;

-- Damaged, lost, found, count correction (admin, co-admin). Needs a reason.
create or replace function public.accessory_adjust(p_id uuid, p_delta int, p_reason text, p_note text default '', p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; a public.accessories;
begin
  perform private.require_manager();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  a := private.acc_lock(p_id);
  if coalesce(p_delta, 0) = 0 then raise exception 'Enter how many to add or take off'; end if;
  if btrim(coalesce(p_reason, '')) = '' then raise exception 'Choose a reason'; end if;
  if private.acc_qty(p_id) + p_delta < 0 then raise exception 'Only % % left. Stock cannot go below 0.', private.acc_qty(p_id), a.name; end if;
  insert into public.accessory_moves (accessory_id, kind, delta, reason, note)
  values (p_id, 'adjust', p_delta, left(btrim(p_reason), 60), left(btrim(coalesce(p_note, '')), 300));
  v := jsonb_build_object('qty', private.acc_qty(p_id));
  return private.idem_put(p_client_ref, v);
end $$;

-- Last movements of one accessory (who, when, note). Money only for admin and co-admin, cost only for admin.
create or replace function public.accessory_moves_list(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r text := private.require_user();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'delta', m.delta, 'on', m.moved_on, 'at', m.created_at,
      'by', coalesce((select name from public.profiles where id = m.created_by), 'Someone'),
      'customer', m.customer, 'free', m.free, 'reason', m.reason, 'note', m.note,
      'supplier', (select name from public.suppliers where id = m.supplier_id))
    || case when r <> 'staff' then jsonb_build_object('amount', m.amount, 'method', m.method) else '{}'::jsonb end
    || case when r = 'admin' then jsonb_build_object('unit_cost', (select unit_cost from public.accessory_move_costs where move_id = m.id)) else '{}'::jsonb end
    order by m.created_at desc)
    from (select * from public.accessory_moves where accessory_id = p_id order by created_at desc limit 60) m), '[]');
end $$;

-- Delete (admin): soft delete, in Recently deleted for 30 days. The movements stay in the history.
create or replace function public.delete_accessory(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a public.accessories; v_del uuid;
begin
  perform private.require_admin();
  a := private.acc_lock(p_id);
  update public.accessories set deleted_at = now(), deleted_by = auth.uid() where id = p_id;
  insert into private.deletions (kind, item_id, label, deleted_by)
  values ('accessory', p_id, format('Accessory %s (%s left)', a.name, private.acc_qty(p_id)), auth.uid()) returning id into v_del;
  perform private.log('delete', 'accessory', p_id::text, format('Deleted accessory %s', a.name));
  return jsonb_build_object('deletion_id', v_del);
end $$;

-- ---------- notifications ----------
-- Events that come from the calendar (not from one action): made when the app loads and by the daily ping.
create or replace function private.refresh_notifications() returns void
language plpgsql security definer set search_path = '' as $$
declare v_today date := private.today();
begin
  -- laptops with a service partner past the expected date
  insert into public.notifications (kind, key, title, body, link_kind, link_id, audience)
  select 'service_overdue', 'svc:' || j.id,
         format('%s at %s: %s day%s past the expected date', l.code, private.partner_label(j.partner_id),
                v_today - j.expected_on, case when v_today - j.expected_on = 1 then '' else 's' end),
         format('Given on %s, expected back %s', to_char(j.given_on, 'DD/MM/YYYY'), to_char(j.expected_on, 'DD/MM/YYYY')),
         'laptop', l.code, 'all'
  from public.service_jobs j join public.laptops l on l.id = j.laptop_id
  where j.status = 'out' and j.expected_on < v_today
  on conflict (key) do nothing;
  -- customer balances pending over 30 days
  insert into public.notifications (kind, key, title, body, link_kind, link_id, audience)
  select 'balance_pending', 'due:' || s.id,
         format('%s: %s pending %s days', private.cust_label(s.customer_name, s.lead_source), private.rs(s.price - private.sale_paid(s.id)), v_today - s.sold_on),
         format('Sold %s on %s', l.code, to_char(s.sold_on, 'DD/MM/YYYY')), 'laptop', l.code, 'mgr'
  from public.sales s join public.laptops l on l.id = s.laptop_id
  where s.status = 'active' and s.sold_on <= v_today - 30 and s.price - private.sale_paid(s.id) > 0
  on conflict (key) do nothing;
  -- advances held after a cancelled booking, waiting for the admin or co-admin
  insert into public.notifications (kind, key, title, body, link_kind, link_id, audience)
  select 'held_advance', 'held:' || b.id,
         format('Advance of %s held for %s', private.rs((select sum(amount) from public.booking_payments where booking_id = b.id)),
                private.cust_label(b.customer_name, b.lead_source)),
         format('Booking of %s was cancelled. Keep or refund the advance.', l.code), 'held', l.code, 'mgr'
  from public.bookings b join public.laptops l on l.id = b.laptop_id
  where b.advance_status = 'held'
  on conflict (key) do nothing;
end $$;

create or replace function private.notif_visible(p_audience text, p_role text) returns boolean
language sql immutable set search_path = '' as $$
  select p_audience = 'all' or (p_audience = 'mgr' and p_role in ('admin','coadmin')) or (p_audience = 'admin' and p_role = 'admin')
$$;

-- Makes the calendar notifications, then returns how many are unread for this user.
create or replace function public.notifications_check()
returns int language plpgsql security definer set search_path = '' as $$
declare r text := private.require_user();
begin
  perform private.refresh_notifications();
  return (select count(*) from public.notifications n
          where private.notif_visible(n.audience, r) and n.created_at > now() - interval '60 days'
            and not exists (select 1 from public.notification_reads x where x.notification_id = n.id and x.user_id = auth.uid()))::int;
end $$;

create or replace function public.my_notifications()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r text := private.require_user();
begin
  perform private.refresh_notifications();
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body,
      'link_kind', n.link_kind, 'link_id', n.link_id, 'at', n.created_at,
      'read', exists (select 1 from public.notification_reads x where x.notification_id = n.id and x.user_id = auth.uid()))
    order by n.created_at desc)
    from (select * from public.notifications where private.notif_visible(audience, r) and created_at > now() - interval '60 days'
          order by created_at desc limit 100) n), '[]');
end $$;

-- p_ids null = all of this user's notifications
create or replace function public.mark_notifications_read(p_ids uuid[] default null)
returns int language plpgsql security definer set search_path = '' as $$
declare r text := private.require_user(); n int;
begin
  insert into public.notification_reads (notification_id, user_id)
  select id, auth.uid() from public.notifications
  where private.notif_visible(audience, r) and (p_ids is null or id = any (p_ids))
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- The daily keep-alive also makes the calendar notifications and runs the 30-day cleanup
create or replace function public.ping() returns text
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform private.purge_deleted();
  perform private.refresh_notifications();
  return 'ok ' || (select count(*) from public.settings)::text;
end $$;

-- ---------------------------------------------------------------------
-- 0009_seed_grants.sql
-- ---------------------------------------------------------------------
-- 0009: seed rows and function permissions (run last)

insert into public.settings (id) values (1) on conflict (id) do nothing;
insert into public.suppliers (code, name) values ('00', 'Customer exchange') on conflict (code) do nothing;

-- RPCs: logged-in users only. Each function checks the role itself.
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
-- The first admin is created once from the SQL editor, never from the app.
revoke execute on function public.bootstrap_first_admin(uuid, text, text) from authenticated;
-- The public warranty check is run only by the warranty-check Edge Function (service key), never by the app.
revoke execute on function public.warranty_lookup(text, text) from authenticated;
grant execute on function public.warranty_lookup(text, text) to service_role;
-- The photo-delete Edge Function reports what Cloudinary said (service key only).
revoke execute on function public.photo_cloud_result(uuid, text, text) from authenticated;
grant execute on function public.photo_cloud_result(uuid, text, text) to service_role;
-- The daily keep-alive call is the only thing the public key may run.
grant execute on function public.ping() to anon;
alter default privileges in schema public revoke execute on functions from public, anon;

-- ---------------------------------------------------------------------
-- Check: both numbers must be the same (every table has its access rules on)
-- ---------------------------------------------------------------------
select count(*) as tables, count(*) filter (where c.relrowsecurity) as tables_with_rls_on
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r';
