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
    if d.kind = 'photo' then
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
