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
    'photos', coalesce((select jsonb_agg(p.url order by p.created_at) from public.photos p where p.laptop_id = l.id), '[]'),
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
  from public.laptops l where l.id = p_id
$$;

create or replace function private.line_json(p_line uuid, p_role text) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', ln.id, 'line_no', ln.line_no, 'is_mixed', ln.is_mixed, 'brand', ln.brand,
    'brand_other', ln.brand_other, 'model', ln.model, 'processor', ln.processor, 'processor_other', ln.processor_other,
    'gen', ln.gen, 'ram_gb', ln.ram_gb, 'storage_type', ln.storage_type, 'storage_gb', ln.storage_gb, 'qty', ln.qty,
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
    'qty', (select count(*) from public.laptops where lot_id = lo.id),
    'sold', (select count(*) from public.laptops x where x.lot_id = lo.id and private.is_sold(x.id)),
    'lines', coalesce((select jsonb_agg(private.line_json(ln.id, p_role) order by ln.line_no)
                       from public.lot_lines ln where ln.lot_id = lo.id), '[]'),
    'expenses', case when p_role = 'staff' then '[]'::jsonb else
                coalesce((select jsonb_agg(private.lot_expense_json(e.id) order by e.spent_on, e.created_at)
                          from public.lot_expenses e where e.lot_id = lo.id and e.deleted_at is null), '[]') end)
  || case when p_role = 'admin' then jsonb_build_object(
       'cost', (select sum(c.cost) from public.laptop_costs c join public.laptops l on l.id = c.laptop_id where l.lot_id = lo.id),
       'cost_missing', (select count(*) from public.laptops l where l.lot_id = lo.id
                        and not exists (select 1 from public.laptop_costs c where c.laptop_id = l.id)))
     else '{}'::jsonb end
  from public.lots lo join public.suppliers s on s.id = lo.supplier_id
  where lo.id = p_lot
$$;

create or replace function private.supplier_json(p_sup uuid, p_role text) returns jsonb
language sql stable set search_path = '' as $$
  with ls as (
    select l.id, (select count(*) from public.repairs r where r.laptop_id = l.id and r.deleted_at is null) > 0 repaired,
           private.repairs_of(l.id) rep,
           (select private.profit(sa.id) from public.sales sa where sa.laptop_id = l.id and sa.status = 'active') profit
    from public.laptops l join public.lots lo on lo.id = l.lot_id where lo.supplier_id = p_sup
  )
  select jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name, 'phone', s.phone,
    'lots', (select count(*) from public.lots where supplier_id = s.id),
    'quality', (select case when count(*) = 0 then null else jsonb_build_object(
                  'n', count(*),
                  'pct_rep', round(100.0 * count(*) filter (where repaired) / count(*)),
                  'avg_rep', round(sum(rep) / count(*), 2),
                  'avg_profit', case when p_role = 'admin' then round(avg(profit), 2) end) end from ls))
  || case when p_role = 'admin' then jsonb_build_object(
       'bought', coalesce((select sum(c.cost) from public.laptop_costs c join public.laptops l on l.id = c.laptop_id
                           join public.lots lo on lo.id = l.lot_id where lo.supplier_id = s.id), 0),
       'paid', case when s.code = '00' then null else
               coalesce((select sum(amount) from public.supplier_payments where supplier_id = s.id), 0) end,
       'due', private.supplier_due(s.id),
       'payments', coalesce((select jsonb_agg(jsonb_build_object('id', sp.id, 'paid_on', sp.paid_on, 'amount', sp.amount, 'method', sp.method,
                                                 'ref', sp.ref, 'note', sp.note) order by sp.paid_on desc, sp.created_at desc)
                             from (select * from public.supplier_payments where supplier_id = s.id order by paid_on desc, created_at desc limit 30) sp), '[]'),
       'cost_missing', (select count(*) from public.laptops l join public.lots lo on lo.id = l.lot_id
                        where lo.supplier_id = s.id and not exists (select 1 from public.laptop_costs c where c.laptop_id = l.id)))
     else '{}'::jsonb end
  from public.suppliers s where s.id = p_sup
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
                 coalesce((select jsonb_agg(private.supplier_json(s.id, r) order by s.code) from public.suppliers s), '[]') end,
    'lots', coalesce((select jsonb_agg(private.lot_json(lo.id, r) order by lo.bought_on, lo.created_at) from public.lots lo), '[]'),
    'laptops', coalesce((select jsonb_agg(private.laptop_json(l.id, r) order by l.created_at, l.code)
                         from public.laptops l where not private.is_old_sold(l.id)), '[]'),
    'hidden_sold', (select count(*) from public.laptops l where private.is_old_sold(l.id)),
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
                               from public.bookings b join public.laptops l on l.id = b.laptop_id
                               join public.customers c on c.id = b.customer_id
                               where b.advance_status = 'held'), '[]') end,
    'partners', coalesce((select jsonb_agg(private.partner_json(p.id, r) order by p.active desc, private.partner_label(p.id))
                          from public.service_partners p), '[]'),
    'service_owed', case when r <> 'admin' then null else
                    (select coalesce(sum(greatest(private.partner_owed(p.id), 0)), 0) from public.service_partners p) end,
    'stock_value', case when r <> 'admin' then null else
                   (select jsonb_build_object('value', round(coalesce(sum(private.full_cost(l.id)), 0), 2),
                                              'cost_missing', count(*) filter (where private.cost_of(l.id) is null))
                    from public.laptops l where not private.is_sold(l.id)) end,
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
  return (select private.laptop_json(l.id, r) from public.laptops l where l.code = c);
end $$;

create or replace function public.search_laptops(p_q text, p_limit int default 60)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r text := private.require_user(); q text := lower(btrim(coalesce(p_q, ''))); d text;
begin
  if q = '' then return '[]'::jsonb; end if;
  d := regexp_replace(q, '\D', '', 'g');
  return coalesce((
    select jsonb_agg(private.laptop_json(x.id, r))
    from (select l.id from public.laptops l
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
                   from public.laptops l where l.lot_id = p_lot_id), '[]');
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
      join public.laptops l on l.id = s.laptop_id
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
        from public.sale_payments p join public.sales s on s.id = p.sale_id join public.laptops l on l.id = s.laptop_id
        where p.paid_on = p_date and p.reversal_of is null and p.booking_payment_id is null and s.status <> 'voided'
        union all
        select bp.amount, bp.method, private.cust_label(b.customer_name, b.lead_source) || ' (advance), ' || l.code, bp.note, bp.id, 'booking_payment'
        from public.booking_payments bp join public.bookings b on b.id = bp.booking_id join public.laptops l on l.id = b.laptop_id
        where bp.paid_on = p_date) x), '[]'),
    'outs', coalesce((select jsonb_agg(x) from (
        select r.amount amt, 'Cash' m, 'Repair on ' || l.code || ': ' || r.work t, '' n, null::uuid id, null k
        from public.repairs r join public.laptops l on l.id = r.laptop_id
        where r.done_on = p_date and r.deleted_at is null and r.lot_expense_id is null
        union all
        select e.amount, e.method, 'Parts for lot ' || lo.prefix || ': ' || e.count || ' x ' || e.type, e.note, e.id, 'lot_expense'
        from public.lot_expenses e join public.lots lo on lo.id = e.lot_id
        where e.spent_on = p_date and e.deleted_at is null
        union all
        -- supplier, Liabilities, shop and service payments: in full for admin; one combined line per method for co-admin
        select sum(b.amt), b.m, case when adm then b.t else 'Business payments (by admin)' end,
               case when adm then max(b.n) else '' end, case when adm then b.k end, case when adm then max(b.kind) end
        from (
          select sp.amount amt, sp.method m, 'Supplier ' || s.name t, sp.note n, sp.id k, 'supplier_payment' kind
          from public.supplier_payments sp join public.suppliers s on s.id = sp.supplier_id where sp.paid_on = p_date
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
                  union select distinct year from public.lots
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
                    'qty', (select count(*) from public.laptops where lot_id = lo.id),
                    'sold', (select count(*) from public.laptops x where x.lot_id = lo.id and private.is_sold(x.id)),
                    'sales', (select coalesce(sum(s.price), 0) from public.sales s join public.laptops l on l.id = s.laptop_id
                              where l.lot_id = lo.id and s.status = 'active'))
                  order by lo.bought_on) from public.lots lo where lo.year = p_year), '[]')
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
             (select count(*) from public.laptops where lot_id = lo.id) qty,
             (select count(*) from public.laptops x where x.lot_id = lo.id and private.is_sold(x.id)) sold,
             coalesce((select sum(c.cost) from public.laptop_costs c join public.laptops l on l.id = c.laptop_id where l.lot_id = lo.id), 0) purchase,
             (select count(*) from public.laptops l where l.lot_id = lo.id
              and not exists (select 1 from public.laptop_costs c where c.laptop_id = l.id)) cost_missing,
             -- parts fitted to single laptops are already inside an expense, so only manual repairs are added
             coalesce((select sum(amount) from public.lot_expenses where lot_id = lo.id and deleted_at is null), 0) lot_exp,
             coalesce((select sum(r.amount) from public.repairs r join public.laptops l on l.id = r.laptop_id
                       where l.lot_id = lo.id and r.deleted_at is null and r.lot_expense_id is null), 0) repairs,
             coalesce((select sum(sa.price) from public.sales sa join public.laptops l on l.id = sa.laptop_id
                       where l.lot_id = lo.id and sa.status = 'active'), 0) sales,
             coalesce((select round(sum(private.profit(sa.id)), 2) from public.sales sa join public.laptops l on l.id = sa.laptop_id
                       where l.lot_id = lo.id and sa.status = 'active'), 0) gross
      from public.lots lo join public.suppliers s on s.id = lo.supplier_id) x), '[]');
end $$;
