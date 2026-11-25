-- Skatepark City: Supabase database
-- Run once in the Supabase dashboard: SQL Editor > New query > paste all of this > Run.
-- Players can only READ their own rows directly. Every change to coins, items,
-- listings, scores and wagers goes through the server functions below, which
-- check the rules, so balances cannot be edited from a browser.

create extension if not exists pgcrypto;

-- ---------- tables ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default 'RIDER' check (name ~ '^[A-Z0-9 ]{1,10}$'),
  look text check (look is null or look ~ '^[0-9A-Z]{6}-[A-Z0-9 ]{1,10}$'),
  coins integer not null default 0 check (coins >= 0),
  progress jsonb not null default '{}'::jsonb,
  wallet_address text,
  earned_day date not null default current_date,
  earned_today integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.items (
  id text primary key,
  name text not null,
  base integer not null check (base > 0),
  step numeric not null default 1.04,
  spread numeric not null default 0.9,
  half_life_h numeric not null default 6
);
-- Item ids carry a namespace. core: items are shared by every game that uses this Supabase project:
-- buy an extra life here, use it in any of the games. Game-only items would use the game's prefix (e.g. spc:).
insert into public.items (id, name, base) values
  ('core:life', 'EXTRA LIFE', 50),
  ('core:skip', 'LEVEL SKIP', 250)
on conflict (id) do nothing;
-- kind: 'market' items trade with the market maker; 'ride' items are numbered editions (player listings only)
alter table public.items add column if not exists kind text not null default 'market';

-- limited rides: a fixed supply per model. Each sale mints the next edition as its own item (spc:ride:<model>#<n>).
create table if not exists public.ride_models (
  id text primary key,
  name text not null,
  price integer not null check (price > 0),
  supply integer not null check (supply > 0),
  minted integer not null default 0 check (minted >= 0)
);
insert into public.ride_models (id, name, price, supply) values
  ('board-c', 'CITY CRUISER', 300, 500), ('board-r', 'NEON NIGHTS', 900, 150), ('board-l', 'GOLDEN GRIP', 2500, 25),
  ('bmx-c', 'STREET RAT', 300, 500), ('bmx-r', 'RED LINE', 900, 150), ('bmx-l', 'CHROME KING', 2500, 25),
  ('blades-c', 'RINK RUNNERS', 300, 500), ('blades-r', 'SLIME TIME', 900, 150), ('blades-l', 'MIDAS WHEELS', 2500, 25),
  ('scooter-c', 'KICK START', 300, 500), ('scooter-r', 'HOT TAMALE', 900, 150), ('scooter-l', 'GHOST RIDER', 2500, 25)
on conflict (id) do nothing;

create table if not exists public.inventory (
  user_id uuid not null references public.profiles(id) on delete cascade,
  item text not null references public.items(id),
  qty integer not null default 0 check (qty >= 0),
  primary key (user_id, item)
);

create table if not exists public.trades (
  id bigserial primary key,
  item text not null references public.items(id),
  side smallint not null check (side in (-1, 1)),
  at timestamptz not null default now()
);
create index if not exists trades_item_at on public.trades (item, at);

create table if not exists public.listings (
  id uuid primary key default gen_random_uuid(),
  item text not null references public.items(id),
  price integer not null check (price between 1 and 99999),
  seller uuid not null references public.profiles(id) on delete cascade,
  seller_name text not null,
  created_at timestamptz not null default now(),
  sold boolean not null default false,
  buyer uuid references public.profiles(id),
  sold_at timestamptz
);
create index if not exists listings_open on public.listings (sold, price);

create table if not exists public.scores (
  id bigserial primary key,
  board text not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  initials text not null check (initials ~ '^[A-Z]{3}$'),
  score integer not null check (score >= 0),
  grade text check (grade is null or grade ~ '^[SABCDW-]$'),
  assisted boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists scores_board on public.scores (board, score desc);

-- usernames (v36): unique, 3 to 12 of A-Z 0-9 _, and they hold the high scores
alter table public.profiles add column if not exists username text;
alter table public.profiles drop constraint if exists profiles_username_check;
alter table public.profiles add constraint profiles_username_check check (username is null or username ~ '^[A-Z0-9_]{3,12}$');
create unique index if not exists profiles_username_unique on public.profiles (username);
alter table public.scores drop constraint if exists scores_initials_check;
alter table public.scores add constraint scores_initials_check check (initials ~ '^[A-Z0-9_]{3,12}$');
-- look codes grew to 13 characters in v31 (layered clothes + ride)
alter table public.profiles drop constraint if exists profiles_look_check;
alter table public.profiles add constraint profiles_look_check check (look is null or look ~ '^([0-9A-Z]{6}|[0-9A-Z]{13})-[A-Z0-9 ]{1,10}$');

create table if not exists public.matches (
  code text primary key check (code ~ '^ride-[a-z0-9]{4}$'),
  mode text not null check (mode in ('fight', 'horse')),
  wager integer not null default 0 check (wager between 0 and 100000),
  host uuid not null references public.profiles(id),
  guest uuid references public.profiles(id),
  host_staked boolean not null default false,
  guest_staked boolean not null default false,
  host_report uuid,
  guest_report uuid,
  first_report_at timestamptz,
  status text not null default 'open' check (status in ('open', 'live', 'settled', 'void')),
  created_at timestamptz not null default now(),
  settled_at timestamptz
);

-- ---------- new player = new profile ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id) values (new.id) on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- row level security: read your own, change nothing directly ----------
alter table public.profiles  enable row level security;
alter table public.items     enable row level security;
alter table public.inventory enable row level security;
alter table public.trades    enable row level security;
alter table public.listings  enable row level security;
alter table public.scores    enable row level security;
alter table public.matches   enable row level security;
alter table public.ride_models enable row level security;

drop policy if exists "own profile" on public.profiles;
create policy "own profile" on public.profiles for select using (auth.uid() = id);
drop policy if exists "items readable" on public.items;
create policy "items readable" on public.items for select using (true);
drop policy if exists "own inventory" on public.inventory;
create policy "own inventory" on public.inventory for select using (auth.uid() = user_id);
drop policy if exists "trades readable" on public.trades;
create policy "trades readable" on public.trades for select using (true);
drop policy if exists "listings readable" on public.listings;
create policy "listings readable" on public.listings for select using (true);
drop policy if exists "scores readable" on public.scores;
create policy "scores readable" on public.scores for select using (true);
drop policy if exists "ride models readable" on public.ride_models;
create policy "ride models readable" on public.ride_models for select using (true);
drop policy if exists "own matches" on public.matches;
create policy "own matches" on public.matches for select using (auth.uid() = host or auth.uid() = guest);

-- ---------- helpers ----------
create or replace function public._me() returns uuid language plpgsql stable as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'not signed in'; end if;
  return u;
end $$;

create or replace function public.market_price(p_item text) returns integer
language sql stable security definer set search_path = public as $$
  select greatest(1, round(i.base * power(i.step, coalesce((
      select sum(t.side * power(0.5, extract(epoch from (now() - t.at)) / 3600.0 / i.half_life_h))
      from public.trades t where t.item = i.id and t.at > now() - interval '48 hours'), 0))))::int
  from public.items i where i.id = p_item;
$$;

create or replace function public.market_prices() returns table (item text, buy integer, sell integer)
language sql stable security definer set search_path = public as $$
  select i.id, public.market_price(i.id), floor(public.market_price(i.id) * i.spread)::int from public.items i;
$$;

-- ---------- profile ----------
create or replace function public.save_profile(p_name text, p_look text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set name = upper(p_name), look = upper(p_look) where id = public._me();
end $$;

create or replace function public.save_progress(p_progress jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if octet_length(p_progress::text) > 20000 then raise exception 'progress too large'; end if;
  update public.profiles set progress = p_progress where id = public._me();
end $$;

-- Only a wallet this account actually signed in with (Supabase Web3 auth) can be linked.
create or replace function public.link_wallet(p_address text) returns void
language plpgsql security definer set search_path = public, auth as $$
declare me uuid := public._me();
begin
  if p_address is null then update public.profiles set wallet_address = null where id = me; return; end if;
  if p_address !~ '^0x[0-9a-fA-F]{40}$' then raise exception 'bad address'; end if;
  if not exists (select 1 from auth.identities i where i.user_id = me and i.provider = 'web3'
                 and (lower(i.identity_data->>'address') = lower(p_address) or lower(i.provider_id) like '%' || lower(p_address))) then
    raise exception 'sign in with that wallet first';
  end if;
  update public.profiles set wallet_address = lower(p_address) where id = me;
end $$;

-- ---------- coins spent in city shops (bodega, bike shop paint jobs) ----------
create or replace function public.spend_coins(p_reason text, p_amount integer) returns integer
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); left_ integer;
begin
  if p_reason <> 'shop' or p_amount < 1 or p_amount > 500 then raise exception 'bad spend'; end if;
  update public.profiles set coins = coins - p_amount where id = me and coins >= p_amount returning coins into left_;
  if not found then raise exception 'not enough coins'; end if;
  return left_;
end $$;

-- ---------- coins earned from play (capped per reason and per day) ----------
create or replace function public.award_coins(p_reason text, p_amount integer) returns integer
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); cap int; daily int := 3000; p public.profiles;
begin
  cap := case p_reason when 'level' then 400 when 'gameover' then 200 when 'mode' then 300
    when 'arcade' then 400 when 'online' then 25 when 'pass-and-play' then 5 else 0 end;
  select * into p from public.profiles where id = me for update;
  if p.earned_day <> current_date then p.earned_today := 0; end if;
  p_amount := least(greatest(p_amount, 0), cap, daily - p.earned_today);
  update public.profiles set coins = coins + p_amount, earned_today = p.earned_today + p_amount, earned_day = current_date where id = me
    returning coins into cap;
  return cap;
end $$;

-- ---------- market maker ----------
create or replace function public.market_buy(p_item text) returns integer
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); price int := public.market_price(p_item); c int;
begin
  if price is null or (select kind from public.items where id = p_item) <> 'market' then raise exception 'unknown item'; end if;
  update public.profiles set coins = coins - price where id = me and coins >= price returning coins into c;
  if c is null then raise exception 'not enough coins'; end if;
  insert into public.inventory (user_id, item, qty) values (me, p_item, 1)
    on conflict (user_id, item) do update set qty = public.inventory.qty + 1;
  insert into public.trades (item, side) values (p_item, 1);
  return c;
end $$;

create or replace function public.market_sell(p_item text) returns integer
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); pay int; c int;
begin
  if (select kind from public.items where id = p_item) is distinct from 'market' then raise exception 'sell this on player listings'; end if;
  update public.inventory set qty = qty - 1 where user_id = me and item = p_item and qty > 0 returning qty into c;
  if c is null then raise exception 'you do not own one'; end if;
  select floor(public.market_price(p_item) * spread)::int into pay from public.items where id = p_item;
  update public.profiles set coins = coins + pay where id = me returning coins into c;
  insert into public.trades (item, side) values (p_item, -1);
  delete from public.trades where at < now() - interval '48 hours';
  return c;
end $$;

create or replace function public.use_item(p_item text) returns integer
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); q int;
begin
  update public.inventory set qty = qty - 1 where user_id = me and item = p_item and qty > 0 returning qty into q;
  if q is null then raise exception 'you do not own one'; end if;
  return q;
end $$;

-- ---------- player listings (seller is paid the moment it sells) ----------
create or replace function public.list_item(p_item text, p_price integer) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); q int; lid uuid; nm text;
begin
  if p_price < 1 or p_price > 99999 then raise exception 'price 1 to 99999'; end if;
  if (select count(*) from public.listings where seller = me and not sold) >= 20 then raise exception 'too many open listings'; end if;
  update public.inventory set qty = qty - 1 where user_id = me and item = p_item and qty > 0 returning qty into q;
  if q is null then raise exception 'you do not own one'; end if;
  select name into nm from public.profiles where id = me;
  insert into public.listings (item, price, seller, seller_name) values (p_item, p_price, me, nm) returning id into lid;
  return lid;
end $$;

create or replace function public.buy_listing(p_id uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); l public.listings; c int;
begin
  select * into l from public.listings where id = p_id for update;
  if not found or l.sold then raise exception 'already sold'; end if;
  if l.seller = me then raise exception 'that is your own listing'; end if;
  update public.profiles set coins = coins - l.price where id = me and coins >= l.price returning coins into c;
  if c is null then raise exception 'not enough coins'; end if;
  update public.profiles set coins = coins + l.price where id = l.seller;
  insert into public.inventory (user_id, item, qty) values (me, l.item, 1)
    on conflict (user_id, item) do update set qty = public.inventory.qty + 1;
  update public.listings set sold = true, buyer = me, sold_at = now() where id = p_id;
  return c;
end $$;

create or replace function public.cancel_listing(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); l public.listings;
begin
  select * into l from public.listings where id = p_id and seller = me for update;
  if not found then raise exception 'not your listing'; end if;
  if l.sold then raise exception 'already sold'; end if;
  delete from public.listings where id = p_id;
  insert into public.inventory (user_id, item, qty) values (me, l.item, 1)
    on conflict (user_id, item) do update set qty = public.inventory.qty + 1;
end $$;

-- ---------- limited rides ----------
create or replace function public.buy_ride(p_model text) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); m public.ride_models; c int; item_id text;
begin
  if me is null then raise exception 'sign in first'; end if;
  select * into m from public.ride_models where id = p_model for update;
  if not found then raise exception 'unknown ride'; end if;
  if m.minted >= m.supply then raise exception 'sold out'; end if;
  update public.profiles set coins = coins - m.price where id = me and coins >= m.price returning coins into c;
  if c is null then raise exception 'not enough coins'; end if;
  update public.ride_models set minted = minted + 1 where id = p_model returning minted into c;
  item_id := 'spc:ride:' || p_model || '#' || c;
  insert into public.items (id, name, base, kind) values (item_id, m.name || ' #' || c, m.price, 'ride');
  insert into public.inventory (user_id, item, qty) values (me, item_id, 1);
  return item_id;
end $$;

-- ---------- usernames ----------
create or replace function public.set_username(p_name text) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); nm text := upper(coalesce(p_name, ''));
begin
  if me is null then raise exception 'sign in first'; end if;
  if nm !~ '^[A-Z0-9_]{3,12}$' then raise exception 'pick 3 to 12 letters, numbers or _'; end if;
  if exists (select 1 from public.profiles where username = nm and id <> me) then raise exception 'that username is taken'; end if;
  update public.profiles set username = nm where id = me;
  update public.scores set initials = nm where user_id = me; -- your old scores follow your name
  return nm;
exception when unique_violation then raise exception 'that username is taken';
end $$;

-- ---------- global high scores ----------
create or replace function public.submit_score(p_board text, p_initials text, p_score integer, p_grade text, p_assisted boolean) returns bigint
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); lim int; sid bigint; nm text;
begin
  lim := case
    when p_board ~ '^[a-z0-9]{2,12}$' and p_board <> 'arcade' then 400000          -- any level id (spc, proj, sewer, site, ...)
    when p_board ~ '^[a-z0-9]{2,12}_(max|meter|strict)$' then 400000
    when p_board = 'arcade' then 200000 else null end;
  if lim is null then raise exception 'unknown board'; end if;
  if p_score < 0 or p_score > lim then raise exception 'score out of range'; end if;
  if (select count(*) from public.scores where user_id = me and created_at > now() - interval '1 minute') >= 5 then raise exception 'slow down'; end if;
  -- the score is held by your username, whatever the client sends
  select username into nm from public.profiles where id = me;
  if nm is null then raise exception 'pick a username first'; end if;
  insert into public.scores (board, user_id, initials, score, grade, assisted) values (p_board, me, nm, p_score, p_grade, coalesce(p_assisted, false)) returning id into sid;
  return sid;
end $$;

create or replace function public.top_scores(p_board text) returns table (initials text, score integer, grade text, assisted boolean)
language sql stable security definer set search_path = public as $$
  select initials, score, grade, assisted from public.scores where board = p_board order by score desc, id asc limit 10;
$$;

-- ---------- online wagers: both players must agree on the winner ----------
create or replace function public.match_open(p_code text, p_mode text, p_wager integer) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.matches (code, mode, wager, host) values (p_code, p_mode, p_wager, public._me());
end $$;

create or replace function public.match_join(p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me();
begin
  update public.matches set guest = me where code = p_code and status in ('open', 'live') and guest is null and host <> me;
  if not found then raise exception 'match not available'; end if;
end $$;

create or replace function public.match_stake(p_code text) returns integer
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); m public.matches; c int;
begin
  select * into m from public.matches where code = p_code for update;
  if not found or m.status not in ('open', 'live') or (me <> m.host and me is distinct from m.guest) then raise exception 'not your match'; end if;
  if (me = m.host and m.host_staked) or (me = m.guest and m.guest_staked) then return (select coins from public.profiles where id = me); end if;
  update public.profiles set coins = coins - m.wager where id = me and coins >= m.wager returning coins into c;
  if c is null then raise exception 'not enough coins'; end if;
  if me = m.host then update public.matches set host_staked = true, status = 'live' where code = p_code;
  else update public.matches set guest_staked = true, status = 'live' where code = p_code; end if;
  return c;
end $$;

create or replace function public._match_settle(p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare m public.matches; pot int;
begin
  select * into m from public.matches where code = p_code for update;
  if m.status in ('settled', 'void') then return; end if;
  pot := (case when m.host_staked then m.wager else 0 end) + (case when m.guest_staked then m.wager else 0 end);
  if m.host_report is not null and m.host_report = m.guest_report then
    update public.profiles set coins = coins + pot where id = m.host_report;
    update public.matches set status = 'settled', settled_at = now() where code = p_code;
  elsif m.host_report is not null and m.guest_report is not null then
    if m.host_staked then update public.profiles set coins = coins + m.wager where id = m.host; end if;
    if m.guest_staked then update public.profiles set coins = coins + m.wager where id = m.guest; end if;
    update public.matches set status = 'void', settled_at = now() where code = p_code;
  end if;
end $$;

create or replace function public.match_report(p_code text, p_winner uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); m public.matches;
begin
  select * into m from public.matches where code = p_code for update;
  if not found or (me <> m.host and me is distinct from m.guest) then raise exception 'not your match'; end if;
  if m.guest is null or (p_winner <> m.host and p_winner <> m.guest) then raise exception 'winner must be a player'; end if;
  if me = m.host then update public.matches set host_report = p_winner, first_report_at = coalesce(first_report_at, now()) where code = p_code;
  else update public.matches set guest_report = p_winner, first_report_at = coalesce(first_report_at, now()) where code = p_code; end if;
  perform public._match_settle(p_code);
  return (select status from public.matches where code = p_code);
end $$;

-- If your opponent never reports (they left), claim after 2 minutes: you are treated as the winner.
create or replace function public.match_claim(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); m public.matches;
begin
  select * into m from public.matches where code = p_code for update;
  if not found or (me <> m.host and me is distinct from m.guest) then raise exception 'not your match'; end if;
  if m.first_report_at is null or m.first_report_at > now() - interval '2 minutes' then raise exception 'too early'; end if;
  if me = m.host and m.guest_report is null and m.host_report = me then update public.matches set guest_report = me where code = p_code;
  elsif me = m.guest and m.host_report is null and m.guest_report = me then update public.matches set host_report = me where code = p_code; end if;
  perform public._match_settle(p_code);
  return (select status from public.matches where code = p_code);
end $$;

-- ---------- who may call what ----------
revoke all on all functions in schema public from public, anon;
grant execute on function public.market_price(text), public.market_prices(), public.top_scores(text) to anon, authenticated;
grant execute on function public.save_profile(text, text), public.save_progress(jsonb), public.link_wallet(text), public.award_coins(text, integer), public.spend_coins(text, integer),
  public.market_buy(text), public.market_sell(text), public.use_item(text), public.list_item(text, integer), public.buy_listing(uuid),
  public.cancel_listing(uuid), public.submit_score(text, text, integer, text, boolean), public.match_open(text, text, integer),
  public.match_join(text), public.match_stake(text), public.match_report(text, uuid), public.match_claim(text), public.buy_ride(text), public.set_username(text) to authenticated;
grant select on public.profiles, public.inventory, public.items, public.trades, public.listings, public.scores, public.matches, public.ride_models to anon, authenticated;

-- ---------- street cred: shared walls and the cred board (v46) ----------
create table if not exists public.spots (
  id text primary key check (id ~ '^[wh][0-9]{1,2}$'),
  uid uuid references public.profiles(id) on delete set null,
  name text not null default 'RIDER',
  type text not null check (type in ('tag', 'throw', 'bomb', 'piece', 'burner')),
  paint text not null check (paint in ('basic', 'chrome', 'gold')),
  at timestamptz not null default now()
);
create table if not exists public.cred_board (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  name text not null,
  cred numeric(10, 1) not null default 0 check (cred >= 0 and cred < 1000000),
  at timestamptz not null default now()
);
alter table public.spots enable row level security;
alter table public.cred_board enable row level security;
drop policy if exists "spots readable" on public.spots;
create policy "spots readable" on public.spots for select using (true);
drop policy if exists "cred readable" on public.cred_board;
create policy "cred readable" on public.cred_board for select using (true);

create or replace function public.paint_spot(p_spot text, p_type text, p_paint text) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); nm text;
begin
  if me is null then raise exception 'sign in first'; end if;
  select coalesce(username, name, 'RIDER') into nm from public.profiles where id = me;
  nm := coalesce(nm, 'RIDER');
  insert into public.spots (id, uid, name, type, paint, at) values (p_spot, me, nm, p_type, p_paint, now())
    on conflict (id) do update set uid = excluded.uid, name = excluded.name, type = excluded.type, paint = excluded.paint, at = now();
end $$;

-- cred is worked out on the device from the walls you held; the board is for bragging, not for buying
create or replace function public.post_cred(p_cred numeric) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); nm text;
begin
  if me is null then raise exception 'sign in first'; end if;
  select coalesce(username, name, 'RIDER') into nm from public.profiles where id = me;
  nm := coalesce(nm, 'RIDER');
  insert into public.cred_board (user_id, name, cred, at) values (me, nm, greatest(0, least(p_cred, 999999)), now())
    on conflict (user_id) do update set name = excluded.name, cred = excluded.cred, at = now();
end $$;
grant execute on function public.paint_spot(text, text, text), public.post_cred(numeric) to authenticated;
grant select on public.spots, public.cred_board to anon, authenticated;

-- ---------- every store item has a market price and a limited supply (v62) ----------
-- Jojo's Cans (designs, paints), the Bike Shop clothing rack, the record store (Walkman, songs). They trade with the
-- market maker like lives and skips, sell back for 90%, list on player listings, and stop selling once the supply is out.
alter table public.items add column if not exists supply integer check (supply is null or supply > 0);
insert into public.items (id, name, base, supply) values
  ('spc:design:throw', 'THROW-UP DESIGN', 150, 1000),
  ('spc:design:bomb', 'BOMB DESIGN', 350, 500),
  ('spc:design:piece', 'PIECE DESIGN', 700, 250),
  ('spc:design:burner', 'BURNER DESIGN', 1500, 100),
  ('spc:paint:chrome', 'CHROME PAINT', 250, 500),
  ('spc:paint:gold', 'GOLD LEAF PAINT', 800, 100),
  ('spc:wear:top:2', 'TANK (TOP)', 60, 300),
  ('spc:wear:top:3', 'JERSEY (TOP)', 90, 300),
  ('spc:wear:top:4', 'JACKET (TOP)', 140, 300),
  ('spc:wear:top:5', 'FLANNEL (TOP)', 110, 300),
  ('spc:wear:bot:2', 'CARGOS (BOTTOMS)', 70, 300),
  ('spc:wear:bot:3', 'JOGGERS (BOTTOMS)', 60, 300),
  ('spc:wear:bot:4', 'TRACKIES (BOTTOMS)', 90, 300),
  ('spc:wear:shoe:2', 'SLIP-ONS (SHOES)', 50, 300),
  ('spc:wear:shoe:3', 'BOOTS (SHOES)', 80, 300),
  ('spc:wear:shoe:4', 'RUNNERS (SHOES)', 70, 300),
  ('spc:wear:hat:2', 'CAP (HEADWEAR)', 40, 300),
  ('spc:wear:hat:3', 'BACK CAP (HEADWEAR)', 40, 300),
  ('spc:wear:hat:4', 'BEANIE (HEADWEAR)', 50, 300),
  ('spc:walkman', 'WALKMAN', 250, 1000),
  ('spc:song:city', 'FINESSE THE BLOCK', 40, 500),
  ('spc:song:tut', 'THE WIZARD''S FIRST SCRATCH', 60, 500),
  ('spc:song:spc', 'MERRY-GO-ROUND ON SEDGWICK', 60, 500),
  ('spc:song:proj', 'BOOGIE DOWN ROCK', 60, 500),
  ('spc:song:sewer', 'CRITICAL LAY-UP', 60, 500),
  ('spc:song:lots', 'DIGGIN'' THE LOTS', 60, 500),
  ('spc:song:xbx', 'FURIOUS FIVE LANES', 60, 500),
  ('spc:song:allA', 'ENJOY THE BEAT', 80, 500),
  ('spc:song:allS', 'SOUL CLAP SUNDAY', 100, 500)
on conflict (id) do update set name = excluded.name, base = excluded.base, supply = excluded.supply;

create or replace function public.market_buy(p_item text) returns integer
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); price int := public.market_price(p_item); c int; sup int; held int;
begin
  if price is null or (select kind from public.items where id = p_item) <> 'market' then raise exception 'unknown item'; end if;
  select supply into sup from public.items where id = p_item;
  if sup is not null then
    perform 1 from public.items where id = p_item for update; -- one buyer at a time per item
    select coalesce(sum(qty), 0) into held from public.inventory where item = p_item;
    held := held + (select count(*) from public.listings where item = p_item and not sold);
    if held >= sup then raise exception 'sold out in the store, check player listings'; end if;
    if p_item like 'spc:design:%' or p_item like 'spc:paint:%' or p_item like 'spc:wear:%' or p_item like 'spc:song:%' or p_item = 'spc:walkman' then
      if exists (select 1 from public.inventory where user_id = me and item = p_item and qty > 0) then raise exception 'you already own it'; end if;
    end if;
  end if;
  update public.profiles set coins = coins - price where id = me and coins >= price returning coins into c;
  if c is null then raise exception 'not enough coins'; end if;
  insert into public.inventory (user_id, item, qty) values (me, p_item, 1)
    on conflict (user_id, item) do update set qty = public.inventory.qty + 1;
  insert into public.trades (item, side) values (p_item, 1);
  return c;
end $$;

-- ---------- v78: rides trade with the shop at market prices; one of each model per rider ----------
-- Each model has a price item (spc:ridem:<model>) that moves with buys and sells like every other market item.
-- Editions sold back to the shop go into stock (back) with their number and are resold before new ones are made.
alter table public.ride_models add column if not exists back integer[] not null default '{}';
insert into public.items (id, name, base, kind) select 'spc:ridem:' || id, name, price, 'ridemkt' from public.ride_models on conflict (id) do nothing;

create or replace function public.buy_ride(p_model text) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); m public.ride_models; c int; ed int; price int; item_id text;
begin
  if me is null then raise exception 'sign in first'; end if;
  if exists (select 1 from public.inventory where user_id = me and item like 'spc:ride:' || p_model || '#%' and qty > 0) then raise exception 'you already own this ride'; end if;
  select * into m from public.ride_models where id = p_model for update;
  if not found then raise exception 'unknown ride'; end if;
  price := public.market_price('spc:ridem:' || p_model);
  if price is null then price := m.price; end if;
  if coalesce(array_length(m.back, 1), 0) = 0 and m.minted >= m.supply then raise exception 'sold out'; end if;
  update public.profiles set coins = coins - price where id = me and coins >= price returning coins into c;
  if c is null then raise exception 'not enough coins'; end if;
  if coalesce(array_length(m.back, 1), 0) > 0 then ed := m.back[1]; update public.ride_models set back = m.back[2:] where id = p_model;
  else update public.ride_models set minted = minted + 1 where id = p_model returning minted into ed; end if;
  item_id := 'spc:ride:' || p_model || '#' || ed;
  insert into public.items (id, name, base, kind) values (item_id, m.name || ' #' || ed, m.price, 'ride') on conflict (id) do nothing;
  insert into public.inventory (user_id, item, qty) values (me, item_id, 1) on conflict (user_id, item) do update set qty = public.inventory.qty + 1;
  insert into public.trades (item, side) values ('spc:ridem:' || p_model, 1);
  return item_id;
end $$;

create or replace function public.sell_ride(p_key text) returns integer
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); mdl text; ed int; pay int; c int;
begin
  if me is null then raise exception 'sign in first'; end if;
  if p_key !~ '^spc:ride:[a-z0-9-]+#[0-9]+$' then raise exception 'not a ride'; end if;
  mdl := split_part(substring(p_key from 10), '#', 1); ed := split_part(p_key, '#', 2)::int;
  if not exists (select 1 from public.ride_models where id = mdl) then raise exception 'starter rides can not be sold'; end if;
  if exists (select 1 from public.listings where item = p_key and not sold) then raise exception 'take it off the listings first'; end if;
  update public.inventory set qty = qty - 1 where user_id = me and item = p_key and qty > 0 returning qty into c;
  if c is null then raise exception 'you do not own it'; end if;
  select floor(public.market_price(i.id) * i.spread)::int into pay from public.items i where i.id = 'spc:ridem:' || mdl;
  update public.profiles set coins = coins + pay where id = me returning coins into c;
  update public.ride_models set back = array_append(back, ed) where id = mdl;
  insert into public.trades (item, side) values ('spc:ridem:' || mdl, -1);
  return c;
end $$;
revoke all on function public.sell_ride(text) from public, anon;
grant execute on function public.sell_ride(text) to authenticated;

-- one of each ride model per rider applies to player listings too
create or replace function public.buy_listing(p_id uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); l public.listings; c int;
begin
  select * into l from public.listings where id = p_id for update;
  if not found or l.sold then raise exception 'already sold'; end if;
  if l.seller = me then raise exception 'that is your own listing'; end if;
  if l.item like 'spc:ride:%#%' and exists (select 1 from public.inventory where user_id = me and qty > 0 and item like split_part(l.item, '#', 1) || '#%') then raise exception 'you already own this ride'; end if;
  update public.profiles set coins = coins - l.price where id = me and coins >= l.price returning coins into c;
  if c is null then raise exception 'not enough coins'; end if;
  update public.profiles set coins = coins + l.price where id = l.seller;
  insert into public.inventory (user_id, item, qty) values (me, l.item, 1)
    on conflict (user_id, item) do update set qty = public.inventory.qty + 1;
  update public.listings set sold = true, buyer = me, sold_at = now() where id = p_id;
  return c;
end $$;

-- ---------- v78: street race boards (fastest times, ride tier shown) ----------
-- Stored as score = 60000 - hundredths, so the shared ordering (higher first, earlier first on ties) works for times too.
alter table public.scores add column if not exists ride text;
create or replace function public.submit_race(p_board text, p_cs integer, p_tier text) returns bigint
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); sid bigint; nm text;
begin
  if me is null then raise exception 'sign in first'; end if;
  if p_board !~ '^race[a-z]{2,10}$' then raise exception 'unknown board'; end if;
  if p_cs < 300 or p_cs > 59999 then raise exception 'time out of range'; end if;
  if p_tier not in ('starter', 'common', 'rare', 'legendary') then raise exception 'unknown ride'; end if;
  if (select count(*) from public.scores where user_id = me and created_at > now() - interval '1 minute') >= 5 then raise exception 'slow down'; end if;
  select username into nm from public.profiles where id = me;
  if nm is null then raise exception 'pick a username first'; end if;
  insert into public.scores (board, user_id, initials, score, grade, assisted, ride) values (p_board, me, nm, 60000 - p_cs, null, false, p_tier) returning id into sid;
  return sid;
end $$;
create or replace function public.top_races(p_board text) returns table (initials text, cs integer, ride text)
language sql stable security definer set search_path = public as $$
  select initials, 60000 - score, ride from public.scores where board = p_board order by score desc, id asc limit 10;
$$;
revoke all on function public.submit_race(text, integer, text) from public, anon;
grant execute on function public.submit_race(text, integer, text) to authenticated;
grant execute on function public.top_races(text) to anon, authenticated;

-- ---------- v79: #1 ghosts, one per board ----------
create table if not exists public.ghosts (
  board text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  initials text not null,
  score integer not null,
  data text not null check (length(data) < 300000),
  created_at timestamptz not null default now()
);
alter table public.ghosts enable row level security;
-- only kept when the run really is #1: the score must be on the board under this rider and beat the stored ghost
create or replace function public.save_ghost(p_board text, p_score integer, p_data text) returns boolean
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); nm text; cur int;
begin
  if me is null then raise exception 'sign in first'; end if;
  if not exists (select 1 from public.scores where board = p_board and user_id = me and score = p_score) then raise exception 'score not on the board'; end if;
  if p_score < (select coalesce(max(score), 0) from public.scores where board = p_board) then return false; end if;
  select score into cur from public.ghosts where board = p_board;
  if cur is not null and cur >= p_score then return false; end if;
  select username into nm from public.profiles where id = me;
  insert into public.ghosts (board, user_id, initials, score, data) values (p_board, me, coalesce(nm, 'RIDER'), p_score, p_data)
    on conflict (board) do update set user_id = excluded.user_id, initials = excluded.initials, score = excluded.score, data = excluded.data, created_at = now();
  return true;
end $$;
create or replace function public.get_ghost(p_board text) returns table (initials text, score integer, data text)
language sql stable security definer set search_path = public as $$
  select initials, score, data from public.ghosts where board = p_board;
$$;
revoke all on function public.save_ghost(text, integer, text) from public, anon;
grant execute on function public.save_ghost(text, integer, text) to authenticated;
grant execute on function public.get_ghost(text) to anon, authenticated;

-- ---------- v80: walls fixed for Queens, writer names, and player crews ----------
-- Queens walls (q5p1, qch...) and 7 LINE PURPLE paint were rejected by the old checks
alter table public.spots drop constraint if exists spots_id_check;
alter table public.spots add constraint spots_id_check check (id ~ '^([wh][0-9]{1,2}|q[a-z0-9]{1,4})$');
alter table public.spots drop constraint if exists spots_paint_check;
alter table public.spots add constraint spots_paint_check check (paint in ('basic', 'chrome', 'gold', 'seven'));
alter table public.spots add column if not exists crew_id uuid;
alter table public.spots add column if not exists crew_col text;

-- crews: riders only, 2-5 letter name, a colour, a 6 character join code, 12 writers max, one crew each
create table if not exists public.crews (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (name ~ '^[A-Z0-9]{2,5}$'),
  col text not null check (col ~ '^#[0-9a-fA-F]{6}$'),
  code text not null unique check (code ~ '^[A-Z0-9]{6}$'),
  founder uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists public.crew_members (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  crew_id uuid not null references public.crews(id) on delete cascade,
  name text not null,
  joined timestamptz not null default now()
);
create index if not exists crew_members_crew on public.crew_members (crew_id);
-- every crew piece logs its points; a week of these sets the ranks
create table if not exists public.crew_paints (
  id bigserial primary key,
  crew_id uuid not null references public.crews(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  pts numeric(8, 1) not null check (pts > 0 and pts < 1000),
  at timestamptz not null default now()
);
create index if not exists crew_paints_crew_at on public.crew_paints (crew_id, at);
alter table public.crews enable row level security;
alter table public.crew_members enable row level security;
alter table public.crew_paints enable row level security;
drop policy if exists "crews readable" on public.crews;
create policy "crews readable" on public.crews for select using (true);
-- join codes stay private to members: the public view leaves them out
revoke select on public.crews from anon, authenticated;
grant select (id, name, col, created_at) on public.crews to anon, authenticated;

create or replace function public._crew_code() returns text language plpgsql as $$
declare a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; o text := ''; i int;
begin for i in 1..6 loop o := o || substr(a, 1 + floor(random()*32)::int, 1); end loop; return o; end $$;

create or replace function public.create_crew(p_name text, p_col text) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); nm text := upper(coalesce(p_name, '')); cid uuid; wn text;
begin
  if me is null then raise exception 'sign in first'; end if;
  if exists (select 1 from public.crew_members where user_id = me) then raise exception 'leave your crew first'; end if;
  if nm !~ '^[A-Z0-9]{2,5}$' then raise exception '2 to 5 letters or numbers'; end if;
  if exists (select 1 from public.crews where name = nm) then raise exception '% is taken', nm; end if;
  select coalesce(username, name, 'RIDER') into wn from public.profiles where id = me;
  insert into public.crews (name, col, code, founder) values (nm, p_col, public._crew_code(), me) returning id into cid;
  insert into public.crew_members (user_id, crew_id, name) values (me, cid, coalesce(wn, 'RIDER'));
  return cid;
end $$;

create or replace function public.join_crew(p_code text, p_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); cid uuid; n int;
begin
  if me is null then raise exception 'sign in first'; end if;
  if exists (select 1 from public.crew_members where user_id = me) then raise exception 'leave your crew first'; end if;
  select id into cid from public.crews where code = upper(coalesce(p_code, '')) for update;
  if cid is null then raise exception 'no crew with that code'; end if;
  select count(*) into n from public.crew_members where crew_id = cid;
  if n >= 12 then raise exception 'that crew is full (12)'; end if;
  insert into public.crew_members (user_id, crew_id, name) values (me, cid, coalesce(nullif(upper(regexp_replace(coalesce(p_name, ''), '[^A-Za-z0-9]', '', 'g')), ''), 'RIDER'));
  return cid;
end $$;

-- the founder role passes to the longest-standing writer; an empty crew is deleted
create or replace function public.leave_crew() returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); cid uuid; nxt uuid;
begin
  if me is null then raise exception 'sign in first'; end if;
  delete from public.crew_members where user_id = me returning crew_id into cid;
  if cid is null then return; end if;
  select user_id into nxt from public.crew_members where crew_id = cid order by joined limit 1;
  if nxt is null then update public.spots set crew_id = null where crew_id = cid; delete from public.crews where id = cid;
  else update public.crews set founder = nxt where id = cid and founder = me; end if;
end $$;

create or replace function public.set_crew_look(p_name text, p_col text) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); nm text := upper(coalesce(p_name, '')); cid uuid;
begin
  select id into cid from public.crews where founder = me;
  if cid is null then raise exception 'only the founder can change the name and colour'; end if;
  if nm !~ '^[A-Z0-9]{2,5}$' then raise exception '2 to 5 letters or numbers'; end if;
  if exists (select 1 from public.crews where name = nm and id <> cid) then raise exception '% is taken', nm; end if;
  update public.crews set name = nm, col = p_col where id = cid;
end $$;

-- your crew, its writers and a week of painting, in one call
create or replace function public.my_crew() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when c.id is null then jsonb_build_object('crew', null) else jsonb_build_object(
    'crew', jsonb_build_object('id', c.id, 'name', c.name, 'col', c.col, 'code', c.code, 'founder', c.founder),
    'members', (select coalesce(jsonb_agg(jsonb_build_object('user_id', m.user_id, 'name', m.name, 'joined', m.joined) order by m.joined), '[]') from public.crew_members m where m.crew_id = c.id),
    'log', (select coalesce(jsonb_agg(jsonb_build_object('user_id', p.user_id, 'pts', p.pts, 'at', p.at)), '[]') from public.crew_paints p where p.crew_id = c.id and p.at > now() - interval '7 days')) end
  from (select 1) one left join public.crew_members me on me.user_id = public._me() left join public.crews c on c.id = me.crew_id;
$$;

-- painting: in a crew the piece carries the crew's name and colour and logs points for the ranks.
-- Crewmates can't go over each other. Out of a crew the piece carries your writer name (2-5 characters).
drop function if exists public.paint_spot(text, text, text);
create or replace function public.paint_spot(p_spot text, p_type text, p_paint text, p_name text default null) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(); nm text; cid uuid; ccol text; cur public.spots; pts numeric;
begin
  if me is null then raise exception 'sign in first'; end if;
  select c.id, c.name, c.col into cid, nm, ccol from public.crew_members m join public.crews c on c.id = m.crew_id where m.user_id = me;
  select * into cur from public.spots where id = p_spot;
  if cid is not null and cur.crew_id = cid and cur.uid is distinct from me then raise exception 'crewmates don''t go over each other'; end if;
  if cid is null then
    nm := nullif(upper(regexp_replace(coalesce(p_name, ''), '[^A-Za-z0-9]', '', 'g')), '');
    if nm is null or length(nm) < 2 then select coalesce(username, name, 'RIDER') into nm from public.profiles where id = me; end if;
    nm := left(coalesce(nm, 'RIDER'), 5);
  end if;
  insert into public.spots (id, uid, name, type, paint, at, crew_id, crew_col) values (p_spot, me, nm, p_type, p_paint, now(), cid, ccol)
    on conflict (id) do update set uid = excluded.uid, name = excluded.name, type = excluded.type, paint = excluded.paint, at = now(), crew_id = excluded.crew_id, crew_col = excluded.crew_col;
  if cid is not null then
    pts := case p_type when 'tag' then 0.5 when 'throw' then 1 when 'bomb' then 2 when 'piece' then 3 else 6 end * case when p_spot ~ '^(h|q.*h$)' then 3 else 1 end;
    insert into public.crew_paints (crew_id, user_id, pts) values (cid, me, pts);
  end if;
end $$;
revoke all on function public.create_crew(text, text), public.join_crew(text, text), public.leave_crew(), public.set_crew_look(text, text), public.my_crew(), public.paint_spot(text, text, text, text) from public, anon;
grant execute on function public.create_crew(text, text), public.join_crew(text, text), public.leave_crew(), public.set_crew_look(text, text), public.my_crew(), public.paint_spot(text, text, text, text) to authenticated;

-- ---------- v80: username + password accounts ----------
-- The game signs people up with a made-up address (username@your authDomain) because Supabase needs an email.
-- Turn OFF "Confirm email" (Authentication > Sign In / Providers > Email) or nobody can finish signing up.
create or replace function public.username_available(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select upper(coalesce(p_name, '')) ~ '^[A-Z0-9_]{3,12}$' and not exists (select 1 from public.profiles where username = upper(p_name));
$$;
grant execute on function public.username_available(text) to anon, authenticated;
-- new accounts get the username they signed up with, when it's valid and free
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare nm text := upper(coalesce(new.raw_user_meta_data->>'username', ''));
begin
  if nm !~ '^[A-Z0-9_]{3,12}$' or exists (select 1 from public.profiles where username = nm) then nm := null; end if;
  insert into public.profiles (id, username) values (new.id, nm) on conflict (id) do nothing;
  return new;
exception when unique_violation then
  insert into public.profiles (id) values (new.id) on conflict (id) do nothing; return new;
end $$;

-- ---------- v80: lock down internal helpers ----------
alter function public._me() set search_path = public;
alter function public._crew_code() set search_path = public;
revoke all on function public._match_settle(text), public.handle_new_user(), public._crew_code() from public, anon, authenticated;
revoke all on function public.post_cred(numeric) from public, anon;
grant execute on function public.post_cred(numeric) to authenticated;

-- ---------- v80: every store item the game sells (newer clothing, extras, 7 LINE PURPLE, Queens songs) ----------
insert into public.items (id, name, base, supply) values
  ('spc:design:throw', 'THROW-UP DESIGN', 150, 1000),
  ('spc:design:bomb', 'BOMB DESIGN', 350, 500),
  ('spc:design:piece', 'PIECE DESIGN', 700, 250),
  ('spc:design:burner', 'BURNER DESIGN', 1500, 100),
  ('spc:paint:chrome', 'CHROME PAINT', 250, 500),
  ('spc:paint:gold', 'GOLD LEAF PAINT', 800, 100),
  ('spc:paint:seven', '7 LINE PURPLE PAINT', 450, 150),
  ('spc:wear:top:2', 'TANK (TOP)', 60, 300),
  ('spc:wear:top:3', 'JERSEY (TOP)', 90, 300),
  ('spc:wear:top:4', 'JACKET (TOP)', 140, 300),
  ('spc:wear:top:5', 'FLANNEL (TOP)', 110, 300),
  ('spc:wear:top:7', 'TRIPLE STRIPE TRACKSUIT (TOP)', 240, 150),
  ('spc:wear:top:8', 'STARTUP JACKET (TOP)', 320, 150),
  ('spc:wear:top:9', 'POLO STALLION RUGBY (TOP)', 280, 150),
  ('spc:wear:top:10', 'SHEARLING BOMBER (TOP)', 340, 150),
  ('spc:wear:bot:2', 'CARGOS (BOTTOMS)', 70, 300),
  ('spc:wear:bot:3', 'SWEATS (BOTTOMS)', 60, 300),
  ('spc:wear:bot:4', 'TRACKIES (BOTTOMS)', 90, 300),
  ('spc:wear:shoe:2', 'SLIP-ONS (SHOES)', 50, 300),
  ('spc:wear:shoe:3', 'BOOTS (SHOES)', 80, 300),
  ('spc:wear:shoe:4', 'RUNNERS (SHOES)', 70, 300),
  ('spc:wear:shoe:5', 'TIMBOS 6-INCH (SHOES)', 260, 150),
  ('spc:wear:shoe:6', 'WALLABEEZ (SHOES)', 240, 150),
  ('spc:wear:shoe:7', 'SHELLTOE SUPERSTARZ (SHOES)', 220, 150),
  ('spc:wear:hat:2', 'CAP (HEADWEAR)', 40, 300),
  ('spc:wear:hat:3', 'BACK CAP (HEADWEAR)', 40, 300),
  ('spc:wear:hat:4', 'BEANIE (HEADWEAR)', 50, 300),
  ('spc:wear:hat:7', 'KANGOROO BUCKET (HEADWEAR)', 220, 150),
  ('spc:wear:hat:8', 'LAMBSKIN FITTED (HEADWEAR)', 260, 150),
  ('spc:wear:acc:1', 'DOOKIE ROPE CHAIN (EXTRAS)', 400, 150),
  ('spc:wear:acc:2', 'CAZZAL FRAMES (EXTRAS)', 300, 150),
  ('spc:wear:acc:3', 'FOUR-FINGER RING (EXTRAS)', 380, 150),
  ('spc:walkman', 'WALKMAN', 250, 1000),
  ('spc:song:city', 'FINESSE THE BLOCK', 40, 500),
  ('spc:song:tut', 'THE WIZARD’S FIRST SCRATCH', 60, 500),
  ('spc:song:spc', 'MERRY-GO-ROUND ON SEDGWICK', 60, 500),
  ('spc:song:proj', 'BOOGIE DOWN ROCK', 60, 500),
  ('spc:song:sewer', 'CRITICAL LAY-UP', 60, 500),
  ('spc:song:lots', 'DIGGIN’ THE LOTS', 60, 500),
  ('spc:song:xbx', 'FURIOUS FIVE ROOFTOPS', 60, 500),
  ('spc:song:allA', 'ENJOY THE BEAT', 80, 500),
  ('spc:song:allS', 'SOUL CLAP SUNDAY', 100, 500),
  ('spc:song:q_city', 'BACK ON LINDEN BOULEVARD', 50, 500),
  ('spc:song:qb', 'JUICE ON THE BRIDGE', 70, 500),
  ('spc:song:hollis', 'TWO TURNTABLES ON 205TH', 70, 500),
  ('spc:song:jam', 'SUCKER DRUMS ON THE AVE', 70, 500),
  ('spc:song:seven', 'WATCH OUT FOR THE 7', 70, 500),
  ('spc:song:lefrak', 'LEFRAK IN FULL', 70, 500),
  ('spc:song:flush', 'LOOKING AT THE UNISPHERE', 70, 500),
  ('spc:song:q_allS', 'SHOOK ON THE BRIDGE', 110, 500),
  ('spc:song:q_100', 'PUSH IT DOWN JAMAICA AVE', 120, 500)
on conflict (id) do update set name = excluded.name, base = excluded.base, supply = excluded.supply;