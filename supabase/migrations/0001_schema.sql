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
create table public.profiles (
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
create table public.app_sessions (
  session_id uuid primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.app_sessions (user_id);

-- Wrong-PIN counter, written only by Edge Functions (service role).
create table public.login_attempts (
  mobile       text primary key,
  failed_count int not null default 0,
  locked_until timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ---------- settings (single row) ----------
create table public.settings (
  id                      int primary key default 1 check (id = 1),
  shop_name               text not null default 'First Choice Laptops',
  phone                   text not null default '+91 99168 76350',
  addr                    text not null default 'No 2, 4th Cross, R.T Nagar, Bangalore 560032',
  default_warranty_months int  not null default 6  check (default_warranty_months between 0 and 60),
  old_days                int  not null default 60 check (old_days between 1 and 3650),
  cloud_name              text not null default '',
  upload_preset           text not null default '',
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  updated_by              uuid references public.profiles(id)
);

-- ---------- suppliers, lots, lines, laptops ----------
create table public.suppliers (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique check (code ~ '^[0-9]{2}$'),   -- '00' = customer exchange
  name       text not null check (length(btrim(name)) between 1 and 80),
  phone      text not null default '',
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.lots (
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
create index on public.lots (supplier_id);

-- Spec value lists (kept in one place so app and database agree)
create or replace function private.brands() returns text[] language sql immutable as
  $$ select array['Dell','HP','Lenovo','Acer','Asus','Apple','Other'] $$;
create or replace function private.processors() returns text[] language sql immutable as
  $$ select array['i3','i5','i7','i9','Pentium','Celeron','Ryzen 3','Ryzen 5','Ryzen 7','Other'] $$;

-- One lot has one or more lines (model, specs, qty, cost). A "Mixed" line has unknown models.
create table public.lot_lines (
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
create table public.lot_line_costs (
  line_id    uuid primary key references public.lot_lines(id) on delete cascade,
  line_cost  numeric(12,2) not null check (line_cost >= 0),
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.laptops (
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
  status          text not null default 'in_stock' check (status in ('in_stock','booked','sold')),
  notes           text not null default '' check (length(notes) <= 300),
  test_note       text not null default '',
  tested_on       date,
  added_on        date not null default private.today(),
  created_by      uuid references public.profiles(id) default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (lot_id, piece_no)
);
create unique index laptops_serial_uniq on public.laptops (upper(btrim(serial))) where btrim(serial) <> '';
create index on public.laptops (status);
create index on public.laptops (line_id);
create index on public.laptops (lower(shorthand));
create index on public.laptops (processor, gen, ram_gb, storage_gb);

-- Admin only. Purchase cost of each laptop, written from its line. No row = cost missing.
create table public.laptop_costs (
  laptop_id  uuid primary key references public.laptops(id) on delete cascade,
  cost       numeric(12,2) not null check (cost >= 0),
  source     text not null check (source in ('lot','exchange','import')),
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.laptop_tests (
  laptop_id  uuid not null references public.laptops(id) on delete cascade,
  test       text not null check (test in ('Display','Keyboard','Touchpad','Battery','Charging','USB ports','Wi-Fi','Audio','Camera','Storage')),
  result     text not null check (result in ('pass','fail')),
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (laptop_id, test)
);

-- Parts bought for a lot (not for one laptop). Shared across the line, or the whole lot when line_id is null.
create table public.lot_expenses (
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
create index on public.lot_expenses (lot_id);
create index on public.lot_expenses (spent_on);

-- Work on one laptop. lot_expense_id set = one unit fitted from that lot expense
-- (its amount then leaves the shared pool, so it is never counted twice).
create table public.repairs (
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
create index on public.repairs (laptop_id);
create index on public.repairs (lot_expense_id);
create index on public.repairs (done_on);

create table public.photos (
  id         uuid primary key default gen_random_uuid(),
  laptop_id  uuid not null references public.laptops(id),
  url        text not null check (url ~ '^https://res\.cloudinary\.com/[^\s"''<>]+$'),
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.photos (laptop_id);

-- ---------- customers, sales, bookings ----------
create or replace function private.lead_sources() returns text[] language sql immutable as
  $$ select array['OLX','Instagram','Lead Matrix','Circle app','Octo','Walk-in','Old customer','Dealer','Other'] $$;

create table public.customers (
  id            uuid primary key default gen_random_uuid(),
  mobile        text not null unique check (mobile ~ '^[0-9]{6,15}$'),
  name          text not null default '',
  address       text not null default '',
  customer_type text not null default 'Retail' check (customer_type in ('Retail','Dealer')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index on public.customers (lower(name));

create table public.bookings (
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
create unique index bookings_one_open on public.bookings (laptop_id) where status = 'open';
create index on public.bookings (customer_id);

create table public.booking_payments (
  id         uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id),
  paid_on    date not null,
  amount     numeric(12,2) not null check (amount > 0),
  method     text not null check (method in ('Cash','UPI','Bank')),
  ref        text not null default '',
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.booking_payments (booking_id);
create index on public.booking_payments (paid_on);

create table public.sales (
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
  status           text not null default 'active' check (status in ('active','returned','voided')),
  voided_at        timestamptz,
  voided_by        uuid references public.profiles(id),
  void_reason      text,
  created_by       uuid references public.profiles(id) default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (warranty_months = 0 or customer_id is not null)          -- warranty needs a mobile
);
-- A laptop can never have two live sales.
create unique index sales_one_active on public.sales (laptop_id) where status = 'active';
create index on public.sales (customer_id);
create index on public.sales (sold_on);
create index on public.sales (lead_source);

create table public.sale_payments (
  id                 uuid primary key default gen_random_uuid(),
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
create index on public.sale_payments (sale_id);
create index on public.sale_payments (paid_on);

create table public.returns (
  id          uuid primary key default gen_random_uuid(),
  sale_id     uuid not null unique references public.sales(id),
  laptop_id   uuid not null references public.laptops(id),
  returned_on date not null,
  note        text not null default '',
  created_by  uuid references public.profiles(id) default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on public.returns (laptop_id);

create table public.refunds (
  id          uuid primary key default gen_random_uuid(),
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
create index on public.refunds (refunded_on);

-- ---------- what the shop owes and spends ----------
create table public.supplier_payments (
  id          uuid primary key default gen_random_uuid(),
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
create index on public.supplier_payments (supplier_id);
create index on public.supplier_payments (paid_on);

create table public.debts (
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

create table public.debt_payments (
  id          uuid primary key default gen_random_uuid(),
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
create index on public.debt_payments (debt_id);
create index on public.debt_payments (paid_on);

-- Running costs not tied to a lot. Payments of Shop rent / Bill debts are added to these
-- automatically in reports ("from Liabilities"), so they are never entered here twice.
create table public.shop_expenses (
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
create index on public.shop_expenses (spent_on);

-- ---------- prices and log ----------
-- Usual selling price per shorthand ("Dell i5 7th 8/256").
create table public.model_prices (
  shorthand  text primary key check (length(btrim(shorthand)) between 1 and 120),
  price      numeric(12,2) not null check (price > 0),
  updated_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.activity_log (
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
create index on public.activity_log (at desc);

-- Idempotency: a retried or double-tapped save returns the first result.
create table private.rpc_requests (
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
    'sale_payments','returns','refunds','supplier_payments','debts','debt_payments','shop_expenses','model_prices']
  loop
    execute format('create trigger touch before update on public.%I for each row execute function private.touch()', t);
  end loop;
end $$;
