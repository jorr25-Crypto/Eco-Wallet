-- Eco-Wallet backend for Supabase.
-- Run once: Supabase dashboard -> SQL Editor -> New query -> paste all -> Run.
-- Money rule: 1 cent = 1 point (100 points = $1). Day boundaries use Calgary time.

-- ---------- tables ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '',
  email text not null default '',
  balance_cents int not null default 0 check (balance_cents >= 0),
  points int not null default 0 check (points >= 0),
  xp int not null default 0,
  items int not null default 0,
  co2 numeric(10,1) not null default 0,
  last_deposit_cents int not null default 0,
  streak int not null default 0,
  last_day date,
  mission_day date,
  mission_bottles int not null default 0,
  mission_done boolean not null default false,
  trees int not null default 0,
  receipts int not null default 0,
  created_at timestamptz not null default now()
);

-- Receipts are issued by the depot (you, or its system). Apps can never read or write this table directly.
create table public.receipts (
  code text primary key check (code ~ '^GW[0-9]{6}-[0-9]{5}$'),
  lines jsonb not null default '[]',
  total_cents int not null check (total_cents > 0),
  bottles int not null default 0,
  items int not null default 0,
  co2 numeric(10,1) not null default 0,
  redeemed_by uuid references auth.users(id),
  redeemed_at timestamptz
);

create table public.rewards (
  id text primary key,
  name text not null,
  cost int not null check (cost > 0),
  active boolean not null default true
);

create table public.transactions (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  description text not null,
  cash_cents int,
  points int not null default 0,
  created_at timestamptz not null default now()
);

create table public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  message text not null,
  read boolean not null default false,
  created_at timestamptz not null default now()
);

create index on public.transactions (user_id, created_at desc);
create index on public.notifications (user_id, created_at desc);

-- ---------- security: row-level security ----------
alter table public.profiles      enable row level security;
alter table public.receipts      enable row level security;
alter table public.rewards       enable row level security;
alter table public.transactions  enable row level security;
alter table public.notifications enable row level security;

create policy "read own profile"       on public.profiles      for select to authenticated using (id = auth.uid());
create policy "read own transactions" on public.transactions  for select to authenticated using (user_id = auth.uid());
create policy "read own notifications" on public.notifications for select to authenticated using (user_id = auth.uid());
create policy "anyone can read rewards" on public.rewards      for select to anon, authenticated using (true);
-- No policies on receipts, and no insert/update/delete policies anywhere:
-- all changes go through the functions below.

revoke all on public.profiles, public.receipts, public.transactions, public.notifications from anon, authenticated;
revoke all on public.rewards from anon, authenticated;
grant select on public.profiles, public.transactions, public.notifications to authenticated;
grant select on public.rewards to anon, authenticated;

-- ---------- helpers ----------
create function public.eco_today() returns date language sql stable as $$
  select (now() at time zone 'America/Edmonton')::date
$$;

-- Create a profile automatically when someone signs up.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, email)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', ''), coalesce(new.email, ''));
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

-- ---------- server-side money logic ----------
create function public.redeem_receipt(p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_code text;
  r public.receipts%rowtype;
  p public.profiles%rowtype;
  v_today date := public.eco_today();
  v_streak int;
  v_bottles int;
  v_done boolean;
  c_goal constant int := 10;   -- bottles needed for the daily mission
  c_bonus constant int := 75;  -- mission reward in points
begin
  if v_uid is null then raise exception 'Please log in first.'; end if;

  v_code := upper(regexp_replace(p_code, '\s', '', 'g'));
  v_code := regexp_replace(v_code, '^(GW[0-9]{6})-?([0-9]{5})$', '\1-\2');

  select * into r from public.receipts where code = v_code for update;
  if not found then raise exception 'Code not recognized. Check the receipt and try again.'; end if;
  if r.redeemed_by is not null then raise exception 'This receipt was already redeemed.'; end if;

  select * into p from public.profiles where id = v_uid for update;

  update public.receipts set redeemed_by = v_uid, redeemed_at = now() where code = v_code;

  v_streak := case when p.last_day = v_today then p.streak
                   when p.last_day = v_today - 1 then p.streak + 1
                   else 1 end;
  v_bottles := (case when p.mission_day = v_today then p.mission_bottles else 0 end) + r.bottles;
  v_done := (p.mission_day = v_today and p.mission_done);

  update public.profiles set
    balance_cents = balance_cents + r.total_cents,
    points = points + r.total_cents,
    xp = xp + r.total_cents,
    items = items + r.items,
    co2 = co2 + r.co2,
    last_deposit_cents = r.total_cents,
    streak = v_streak, last_day = v_today,
    receipts = receipts + 1,
    mission_day = v_today, mission_bottles = v_bottles, mission_done = v_done
  where id = v_uid;

  insert into public.transactions (user_id, kind, description, cash_cents, points)
  values (v_uid, 'deposit', 'Deposit: receipt ' || v_code, r.total_cents, r.total_cents);
  insert into public.notifications (user_id, message)
  values (v_uid, '$' || to_char(r.total_cents / 100.0, 'FM990.00') || ' added to your wallet (+' || r.total_cents || ' pts)');

  if v_bottles >= c_goal and not v_done then
    update public.profiles set points = points + c_bonus, xp = xp + c_bonus, mission_done = true where id = v_uid;
    insert into public.transactions (user_id, kind, description, points)
    values (v_uid, 'mission', 'Mission complete', c_bonus);
    insert into public.notifications (user_id, message)
    values (v_uid, 'Mission complete: +' || c_bonus || ' coins');
  end if;
end $$;

create function public.claim_reward(p_id text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  rw public.rewards%rowtype;
  pr public.profiles%rowtype;
  v_desc text;
begin
  if v_uid is null then raise exception 'Please log in first.'; end if;
  select * into rw from public.rewards where id = p_id and active;
  if not found then raise exception 'This reward is not available.'; end if;
  select * into pr from public.profiles where id = v_uid for update;
  if pr.points < rw.cost then
    raise exception 'You need % more points for this reward.', rw.cost - pr.points;
  end if;

  update public.profiles
     set points = points - rw.cost,
         trees = trees + (case when p_id = 'tree' then 1 else 0 end)
   where id = v_uid;

  v_desc := case when p_id = 'etransfer'
                 then 'E-Transfer of $' || to_char(rw.cost / 100.0, 'FM990.00') || ' to ' || pr.email
                 else rw.name end;
  insert into public.transactions (user_id, kind, description, points)
  values (v_uid, 'redeem', 'Redeemed: ' || v_desc, -rw.cost);
  insert into public.notifications (user_id, message) values (v_uid, 'Redeemed: ' || v_desc);
  -- NOTE: gift cards and e-transfers still need to be fulfilled by you (or a payout provider).
  -- Query the transactions table for kind = 'redeem' to see what is owed.
end $$;

create function public.mark_notifications_read() returns void
language sql security definer set search_path = public as $$
  update public.notifications set read = true where user_id = auth.uid() and not read
$$;

revoke all on function public.redeem_receipt(text), public.claim_reward(text),
  public.mark_notifications_read(), public.handle_new_user() from public, anon, authenticated;
grant execute on function public.redeem_receipt(text), public.claim_reward(text),
  public.mark_notifications_read() to authenticated;

-- ---------- starter data ----------
insert into public.rewards (id, name, cost, active) values
  ('tree', 'Plant a Tree', 1000, true),
  ('coffee', 'Coffee Gift Card', 2500, true),
  ('etransfer', 'E-Transfer', 3000, true),
  ('soon', 'Coming soon', 4000, false);

-- Test receipts to scan or type in. In real use, your depot system inserts one per drop-off.
insert into public.receipts (code, lines, total_cents, bottles, items, co2) values
  ('GW250525-00123', '[{"m":"Aluminum Cans","lb":12.6,"c":756},{"m":"Plastic Bottles (PET)","lb":8.4,"c":294},{"m":"Cardboard","lb":15.2,"c":152},{"m":"Glass Bottles","lb":21.3,"c":320}]', 1522, 238, 649, 11.5),
  ('GW250525-00124', '[]',  842,  6,  40, 2.1),
  ('GW250525-00125', '[]', 1275, 12,  85, 3.4),
  ('GW250525-00126', '[]',  310,  4,  20, 0.8),
  ('GW250525-00127', '[]', 2060, 25, 140, 5.6);
