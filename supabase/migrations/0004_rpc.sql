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
