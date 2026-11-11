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
