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
