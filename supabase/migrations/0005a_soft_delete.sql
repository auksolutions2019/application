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
