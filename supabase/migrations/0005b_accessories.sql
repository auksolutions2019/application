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
