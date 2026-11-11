-- =====================================================================
-- First Choice Laptops, Stock Manager: database setup, PART 2 OF 3
-- Generated from supabase/migrations by tools/build-setup.mjs. Do not edit by hand.
-- The same SQL as setup_all.sql, split because the SQL Editor may refuse one big query.
-- Run the parts in order (1, 2, 3), each in a new query. All are safe to run again.
-- =====================================================================

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
    'paid', private.sale_paid(s.id), 'due', s.price - private.sale_paid(s.id))
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
        where bp.paid_on = p_date) x), '[]'),
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
          from public.service_payments vp where vp.paid_on = p_date) b
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
    ), months as (
      select g m,
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
      'months', (select jsonb_agg(jsonb_build_object('m', m, 'n', n, 'sales', sales)
                   -- stock service charges are already inside gross (laptop cost); warranty repairs come off net
                   || case when adm then jsonb_build_object('gross', round(gross, 2), 'cost_missing', cost_missing,
                                                            'shop', shop, 'service_stock', service_stock, 'warranty', warranty,
                                                            'net', round(gross - shop - warranty, 2)) else '{}'::jsonb end
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


-- End of part 2. Now run setup_part3.sql in a new query.
