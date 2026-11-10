-- =====================================================================
-- First Choice Laptops, Stock Manager: database setup, PART 1 OF 2
-- Generated from supabase/migrations by tools/build-setup.mjs. Do not edit by hand.
-- The same SQL as setup_all.sql, split in two because the SQL Editor may refuse one big query.
-- Run part 1 first, then part 2 in a new query. Both are safe to run again.
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
    raise exception 'Add at least one line';
  end if;
  if jsonb_array_length(p_lines) > 99 then raise exception 'A lot can have up to 99 lines'; end if;
  select coalesce(sum((x ->> 'qty')::int), 0) into v_total from jsonb_array_elements(p_lines) x;
  if v_total > 500 then raise exception 'A lot can have up to 500 laptops'; end if;

  v_prefix := s.code || '-' || lpad(p_lot_no::text, 2, '0') || '-' || to_char(p_bought_on, 'MM') || '-' || to_char(p_bought_on, 'YY');
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
    if v_qty is null or v_qty < 1 then raise exception 'Line %: enter the number of laptops', i; end if;
    v_cost := (ln ->> 'cost')::numeric;
    if v_cost is not null and (v_cost < 0 or v_cost <> round(v_cost, 2)) then raise exception 'Line %: check the cost', i; end if;
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
  if not found then raise exception 'Lot line not found'; end if;
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
    raise exception 'That line is not in this lot';
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
      raise exception 'Those parts were bought for another lot or line';
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


-- End of part 1. Now run setup_part2.sql in a new query.
