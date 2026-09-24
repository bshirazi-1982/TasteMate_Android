-- Tastemate central database
-- Users and vendors sign in with Supabase Auth. Offers, vouchers, redemptions and token
-- purchases are stored here so vendors get real statistics and tokens can't be forged.

-- ---------------------------------------------------------------------------
-- Settings (change prices and the free allowance here)
-- ---------------------------------------------------------------------------
create table public.settings (
  key text primary key,
  value numeric not null,
  note text
);
insert into public.settings (key, value, note) values
  ('free_tokens_per_month', 10, 'Free user tokens each vendor gets per calendar month (UK time)'),
  ('price_single_pence', 75, 'Price per user token when buying fewer than bulk_min_qty'),
  ('price_bulk_pence', 45, 'Price per user token when buying bulk_min_qty or more'),
  ('bulk_min_qty', 100, 'Minimum tokens for the bulk price'),
  ('redeem_grace_minutes', 15, 'Minutes after an offer ends that a voucher can still be scanned');

create or replace function public.setting(p_key text) returns numeric
language sql stable security definer set search_path = public as $$
  select value from public.settings where key = p_key
$$;

-- ---------------------------------------------------------------------------
-- People
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  role text not null default 'user' check (role in ('user', 'vendor', 'admin')),
  display_name text,
  created_at timestamptz not null default now()
);

create table public.venues (
  id text primary key,
  name text not null,
  cat text,
  kind text,
  area text,
  addr text,
  lat double precision,
  lng double precision,
  google_place_id text,
  created_at timestamptz not null default now()
);

create table public.vendors (
  id uuid primary key references public.profiles (id) on delete cascade,
  business_name text not null,
  venue_id text references public.venues (id),
  contact_email text,
  approved boolean not null default false,
  approved_at timestamptz,
  stripe_customer_id text,
  created_at timestamptz not null default now()
);

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
$$;

-- New sign-ups get a profile. Vendors also get a vendor record, waiting for approval.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_role text := case when new.raw_user_meta_data ->> 'role' = 'vendor' then 'vendor' else 'user' end;
  v_venue text := nullif(new.raw_user_meta_data ->> 'venue_id', '');
begin
  insert into public.profiles (id, role, display_name)
  values (new.id, v_role, coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), split_part(new.email, '@', 1)));
  if v_role = 'vendor' then
    if v_venue is not null and not exists (select 1 from public.venues where id = v_venue) then
      v_venue := null;
    end if;
    insert into public.vendors (id, business_name, venue_id, contact_email)
    values (new.id, coalesce(nullif(new.raw_user_meta_data ->> 'business_name', ''), 'New business'), v_venue, new.email);
  end if;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Ratings (so taste matching can include real members)
-- ---------------------------------------------------------------------------
create table public.ratings (
  user_id uuid not null references public.profiles (id) on delete cascade,
  venue_id text not null references public.venues (id) on delete cascade,
  rating numeric(2, 1) not null check (rating between 0.5 and 5),
  source text not null default 'manual',
  updated_at timestamptz not null default now(),
  primary key (user_id, venue_id)
);

-- ---------------------------------------------------------------------------
-- Offers, vouchers and the token ledger
-- ---------------------------------------------------------------------------
create table public.offers (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references public.vendors (id) on delete cascade,
  venue_id text not null references public.venues (id),
  title text not null check (char_length(title) between 3 and 80),
  offer_type text not null check (offer_type in ('percent_off', 'two_for_one', 'free_item', 'fixed_off', 'other')),
  tokens int not null check (tokens between 1 and 5000),
  free_tokens int not null default 0,
  paid_tokens int not null default 0,
  radius_km numeric not null default 3 check (radius_km > 0 and radius_km <= 50),
  min_pred numeric not null default 3.5 check (min_pred between 1 and 5),
  starts_at timestamptz not null default now(),
  expires_at timestamptz not null,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  check (expires_at > starts_at)
);
create index offers_vendor_idx on public.offers (vendor_id, created_at desc);
create index offers_live_idx on public.offers (expires_at) where cancelled_at is null;

create table public.vouchers (
  id uuid primary key default gen_random_uuid(),
  offer_id uuid not null references public.offers (id) on delete cascade,
  user_id uuid references public.profiles (id) on delete set null,  -- kept (anonymised) for vendor stats if the diner deletes their account
  code text not null unique,
  claimed_at timestamptz not null default now(),
  redeemed_at timestamptz,
  redeemed_by uuid references public.vendors (id),
  bill_pence int check (bill_pence >= 0 and bill_pence <= 10000000),
  party_size int check (party_size between 1 and 100),
  unique (offer_id, user_id)
);
create index vouchers_offer_idx on public.vouchers (offer_id);
create index vouchers_user_idx on public.vouchers (user_id, claimed_at desc);

-- One row per purchase or per offer issued.
-- paid_delta: change in purchased tokens (+ on purchase, - when an offer uses them)
-- free_used: free monthly tokens used by an offer
create table public.token_ledger (
  id bigserial primary key,
  vendor_id uuid not null references public.vendors (id) on delete cascade,
  kind text not null check (kind in ('purchase', 'issue', 'adjustment')),
  paid_delta int not null default 0,
  free_used int not null default 0,
  unit_pence int,
  amount_pence int,
  stripe_session_id text unique,
  offer_id uuid references public.offers (id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);
create index token_ledger_vendor_idx on public.token_ledger (vendor_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Row level security: people only see their own data
-- ---------------------------------------------------------------------------
alter table public.settings enable row level security;
alter table public.profiles enable row level security;
alter table public.venues enable row level security;
alter table public.vendors enable row level security;
alter table public.ratings enable row level security;
alter table public.offers enable row level security;
alter table public.vouchers enable row level security;
alter table public.token_ledger enable row level security;

create policy "settings readable" on public.settings for select using (true);
create policy "venues readable" on public.venues for select using (true);

create policy "own profile" on public.profiles for select using (id = auth.uid() or public.is_admin());
create policy "update own profile" on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

create policy "own vendor record" on public.vendors for select using (id = auth.uid() or public.is_admin());

create policy "own ratings read" on public.ratings for select using (user_id = auth.uid());
create policy "own ratings insert" on public.ratings for insert with check (user_id = auth.uid());
create policy "own ratings update" on public.ratings for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own ratings delete" on public.ratings for delete using (user_id = auth.uid());

create policy "own or live offers" on public.offers for select using (
  vendor_id = auth.uid() or public.is_admin()
  or (cancelled_at is null and starts_at <= now() and expires_at > now())
);

create policy "own vouchers or vendor's vouchers" on public.vouchers for select using (
  user_id = auth.uid() or public.is_admin()
  or exists (select 1 from public.offers o where o.id = offer_id and o.vendor_id = auth.uid())
);

create policy "own ledger" on public.token_ledger for select using (vendor_id = auth.uid() or public.is_admin());

-- Column-level limits: people may only change their display name; everything else goes through functions below
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (display_name) on public.profiles to authenticated;
revoke all on public.vendors, public.offers, public.vouchers, public.token_ledger from anon, authenticated;
grant select on public.vendors, public.offers, public.vouchers, public.token_ledger to authenticated;
revoke all on public.ratings from anon;
grant select, insert, update, delete on public.ratings to authenticated;
grant select on public.venues, public.settings to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Token balance
-- ---------------------------------------------------------------------------
create or replace function public.vendor_balance(p_vendor uuid default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_id uuid := coalesce(p_vendor, auth.uid());
  v_month_start timestamptz := (date_trunc('month', now() at time zone 'Europe/London')) at time zone 'Europe/London';
  v_allow int := public.setting('free_tokens_per_month')::int;
  v_free_used int;
  v_paid int;
begin
  if v_id is distinct from auth.uid() and not public.is_admin() then
    raise exception 'Not allowed';
  end if;
  select coalesce(sum(free_used), 0) into v_free_used from public.token_ledger where vendor_id = v_id and created_at >= v_month_start;
  select coalesce(sum(paid_delta), 0) into v_paid from public.token_ledger where vendor_id = v_id;
  return json_build_object(
    'free_allowance', v_allow,
    'free_left', greatest(0, v_allow - v_free_used),
    'paid', v_paid,
    'total', greatest(0, v_allow - v_free_used) + v_paid,
    'resets_at', (date_trunc('month', now() at time zone 'Europe/London') + interval '1 month') at time zone 'Europe/London',
    'price_single_pence', public.setting('price_single_pence'),
    'price_bulk_pence', public.setting('price_bulk_pence'),
    'bulk_min_qty', public.setting('bulk_min_qty')
  );
end $$;

-- ---------------------------------------------------------------------------
-- Vendors create offers. Every place offered uses one token, whether or not it is claimed.
-- Free monthly tokens are used first, then purchased tokens.
-- ---------------------------------------------------------------------------
create or replace function public.create_offer(
  p_title text, p_offer_type text, p_tokens int, p_hours numeric,
  p_radius_km numeric default 3, p_min_pred numeric default 3.5
) returns public.offers
language plpgsql security definer set search_path = public as $$
declare
  v public.vendors;
  b json;
  v_free_left int;
  v_paid int;
  v_free_use int;
  v_paid_use int;
  o public.offers;
begin
  select * into v from public.vendors where id = auth.uid();
  if not found then raise exception 'Only business accounts can create offers.'; end if;
  if not v.approved then raise exception 'Your business account is waiting for approval. You can create offers once it is approved.'; end if;
  if v.venue_id is null then raise exception 'Your business account is not linked to a venue yet.'; end if;
  if p_tokens is null or p_tokens < 1 then raise exception 'Offer it to at least 1 person.'; end if;
  if p_hours is null or p_hours <= 0 or p_hours > 168 then raise exception 'An offer can run for up to 7 days.'; end if;

  -- One offer at a time per vendor, so two devices can't spend the same tokens
  perform pg_advisory_xact_lock(hashtextextended(v.id::text, 0));
  b := public.vendor_balance(v.id);
  v_free_left := (b ->> 'free_left')::int;
  v_paid := (b ->> 'paid')::int;
  v_free_use := least(v_free_left, p_tokens);
  v_paid_use := p_tokens - v_free_use;
  if v_paid_use > v_paid then
    raise exception 'Not enough tokens. This offer needs % and you have % (% free this month, % bought). Buy more tokens or offer it to fewer people.',
      p_tokens, v_free_left + v_paid, v_free_left, v_paid;
  end if;

  insert into public.offers (vendor_id, venue_id, title, offer_type, tokens, free_tokens, paid_tokens, radius_km, min_pred, expires_at)
  values (v.id, v.venue_id, trim(p_title), p_offer_type, p_tokens, v_free_use, v_paid_use,
          coalesce(p_radius_km, 3), coalesce(p_min_pred, 3.5), now() + make_interval(secs => (p_hours * 3600)::double precision))
  returning * into o;

  insert into public.token_ledger (vendor_id, kind, paid_delta, free_used, offer_id, note)
  values (v.id, 'issue', -v_paid_use, v_free_use, o.id, p_tokens || ' tokens for "' || o.title || '"');
  return o;
end $$;

-- Ending an offer early does not return tokens (each place offered uses a token).
create or replace function public.end_offer(p_offer uuid) returns public.offers
language plpgsql security definer set search_path = public as $$
declare o public.offers;
begin
  update public.offers set cancelled_at = now()
  where id = p_offer and vendor_id = auth.uid() and cancelled_at is null and expires_at > now()
  returning * into o;
  if not found then raise exception 'Offer not found or already ended.'; end if;
  return o;
end $$;

-- ---------------------------------------------------------------------------
-- Live offers for diners, with how many places are left
-- ---------------------------------------------------------------------------
create or replace function public.live_offers() returns table (
  id uuid, venue_id text, title text, offer_type text, tokens int, claimed int,
  radius_km numeric, min_pred numeric, starts_at timestamptz, expires_at timestamptz, my_code text
)
language sql stable security definer set search_path = public as $$
  select o.id, o.venue_id, o.title, o.offer_type, o.tokens,
         (select count(*)::int from public.vouchers v where v.offer_id = o.id) as claimed,
         o.radius_km, o.min_pred, o.starts_at, o.expires_at,
         (select v.code from public.vouchers v where v.offer_id = o.id and v.user_id = auth.uid()) as my_code
  from public.offers o
  where o.cancelled_at is null and o.starts_at <= now() and o.expires_at > now()
  order by o.expires_at
$$;

-- ---------------------------------------------------------------------------
-- Diners claim a voucher. The code is what the vendor scans.
-- ---------------------------------------------------------------------------
create or replace function public.claim_offer(p_offer uuid) returns public.vouchers
language plpgsql security definer set search_path = public as $$
declare
  o public.offers;
  existing public.vouchers;
  v_code text;
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  i int;
  vch public.vouchers;
begin
  if auth.uid() is null then raise exception 'Sign in to claim offers.'; end if;
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'user') then
    raise exception 'Offers can only be claimed with a diner account.';
  end if;
  select * into o from public.offers where id = p_offer for update;
  if not found then raise exception 'Offer not found.'; end if;
  if o.cancelled_at is not null or o.expires_at <= now() then raise exception 'This offer has ended.'; end if;
  if o.starts_at > now() then raise exception 'This offer has not started yet.'; end if;

  select * into existing from public.vouchers where offer_id = p_offer and user_id = auth.uid();
  if found then return existing; end if;

  if (select count(*) from public.vouchers where offer_id = p_offer) >= o.tokens then
    raise exception 'All % vouchers for this offer have been claimed.', o.tokens;
  end if;

  loop
    v_code := 'TM-';
    for i in 1..6 loop
      v_code := v_code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.vouchers where code = v_code);
  end loop;

  insert into public.vouchers (offer_id, user_id, code) values (p_offer, auth.uid(), v_code) returning * into vch;
  return vch;
end $$;

-- A diner's own vouchers, including ones for offers that have ended
create or replace function public.my_vouchers() returns table (
  code text, claimed_at timestamptz, redeemed_at timestamptz, offer_id uuid, title text, offer_type text,
  venue_id text, expires_at timestamptz, cancelled_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select v.code, v.claimed_at, v.redeemed_at, o.id, o.title, o.offer_type, o.venue_id, o.expires_at, o.cancelled_at
  from public.vouchers v join public.offers o on o.id = v.offer_id
  where v.user_id = auth.uid()
  order by v.claimed_at desc
$$;

-- ---------------------------------------------------------------------------
-- Vendors scan a code. This records the use centrally, with the bill if entered.
-- ---------------------------------------------------------------------------
create or replace function public.redeem_voucher(p_code text, p_bill_pence int default null, p_party_size int default null) returns json
language plpgsql security definer set search_path = public as $$
declare
  v public.vendors;
  vch public.vouchers;
  o public.offers;
  venue_name text;
  grace int := public.setting('redeem_grace_minutes')::int;
begin
  select * into v from public.vendors where id = auth.uid();
  if not found then raise exception 'Only business accounts can scan vouchers.'; end if;
  if not v.approved then raise exception 'Your business account is waiting for approval.'; end if;

  select * into vch from public.vouchers where code = upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g')) for update;
  if not found then raise exception 'Code % not recognised. Check it and try again.', upper(trim(coalesce(p_code, ''))); end if;
  select * into o from public.offers where id = vch.offer_id;

  if o.vendor_id <> v.id then
    select name into venue_name from public.venues where id = o.venue_id;
    raise exception 'This voucher is for %, not your venue.', coalesce(venue_name, 'another venue');
  end if;
  if vch.redeemed_at is not null then
    raise exception 'Already used on % at %.', to_char(vch.redeemed_at at time zone 'Europe/London', 'DD Mon'), to_char(vch.redeemed_at at time zone 'Europe/London', 'HH24:MI');
  end if;
  if now() > o.expires_at + make_interval(mins => grace) then
    raise exception 'This voucher expired at % on %.', to_char(o.expires_at at time zone 'Europe/London', 'HH24:MI'), to_char(o.expires_at at time zone 'Europe/London', 'DD Mon');
  end if;

  update public.vouchers
     set redeemed_at = now(), redeemed_by = v.id,
         bill_pence = p_bill_pence, party_size = p_party_size
   where id = vch.id
   returning * into vch;

  return json_build_object('code', vch.code, 'offer_title', o.title, 'offer_type', o.offer_type,
                           'claimed_at', vch.claimed_at, 'redeemed_at', vch.redeemed_at,
                           'bill_pence', vch.bill_pence, 'party_size', vch.party_size);
end $$;

-- ---------------------------------------------------------------------------
-- Taste matching pool: everyone's ratings, anonymised, for the recommendation engine
-- ---------------------------------------------------------------------------
create or replace function public.match_pool() returns table (member text, venue_id text, rating numeric)
language sql stable security definer set search_path = public as $$
  select 'm' || left(md5(r.user_id::text || 'tastemate-pool'), 10), r.venue_id, r.rating
  from public.ratings r
  where r.user_id is distinct from auth.uid()
$$;

-- ---------------------------------------------------------------------------
-- Payments (called only by the Stripe webhook, using the service role key)
-- ---------------------------------------------------------------------------
create or replace function public.record_purchase(p_vendor uuid, p_qty int, p_unit_pence int, p_amount_pence int, p_session text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.vendors where id = p_vendor) then raise exception 'Unknown vendor %', p_vendor; end if;
  insert into public.token_ledger (vendor_id, kind, paid_delta, unit_pence, amount_pence, stripe_session_id, note)
  values (p_vendor, 'purchase', p_qty, p_unit_pence, p_amount_pence, p_session, p_qty || ' tokens bought')
  on conflict (stripe_session_id) do nothing;
  return found;
end $$;

-- ---------------------------------------------------------------------------
-- Publisher (admin) tools
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_vendor(p_vendor uuid, p_approved boolean, p_venue text default null) returns public.vendors
language plpgsql security definer set search_path = public as $$
declare v public.vendors;
begin
  if not public.is_admin() then raise exception 'Only the publisher can approve businesses.'; end if;
  update public.vendors
     set approved = p_approved,
         approved_at = case when p_approved then now() else null end,
         venue_id = coalesce(p_venue, venue_id)
   where id = p_vendor
   returning * into v;
  if not found then raise exception 'Business not found.'; end if;
  return v;
end $$;

create or replace function public.admin_grant_tokens(p_vendor uuid, p_qty int, p_note text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only the publisher can grant tokens.'; end if;
  insert into public.token_ledger (vendor_id, kind, paid_delta, note) values (p_vendor, 'adjustment', p_qty, coalesce(p_note, 'Granted by publisher'));
  return true;
end $$;

create or replace function public.admin_overview() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not allowed'; end if;
  return json_build_object(
    'users', (select count(*) from public.profiles where role = 'user'),
    'vendors', (select count(*) from public.vendors),
    'vendors_pending', (select count(*) from public.vendors where not approved),
    'tokens_sold', (select coalesce(sum(paid_delta), 0) from public.token_ledger where kind = 'purchase'),
    'revenue_pence', (select coalesce(sum(amount_pence), 0) from public.token_ledger where kind = 'purchase'),
    'offers', (select count(*) from public.offers),
    'tokens_issued', (select coalesce(sum(tokens), 0) from public.offers),
    'vouchers_claimed', (select count(*) from public.vouchers),
    'vouchers_redeemed', (select count(*) from public.vouchers where redeemed_at is not null),
    'vendor_spend_pence', (select coalesce(sum(bill_pence), 0) from public.vouchers where redeemed_at is not null)
  );
end $$;

create or replace function public.admin_vendors() returns table (
  id uuid, business_name text, contact_email text, venue_id text, venue_name text, approved boolean, created_at timestamptz,
  tokens_bought bigint, revenue_pence bigint
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not allowed'; end if;
  return query
  select v.id, v.business_name, v.contact_email, v.venue_id, ve.name, v.approved, v.created_at,
         coalesce((select sum(l.paid_delta) from public.token_ledger l where l.vendor_id = v.id and l.kind = 'purchase'), 0)::bigint,
         coalesce((select sum(l.amount_pence) from public.token_ledger l where l.vendor_id = v.id and l.kind = 'purchase'), 0)::bigint
  from public.vendors v left join public.venues ve on ve.id = v.venue_id
  order by v.approved, v.created_at desc;
end $$;

-- Who can call what
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.setting(text), public.is_admin(), public.vendor_balance(uuid), public.create_offer(text, text, int, numeric, numeric, numeric),
  public.end_offer(uuid), public.live_offers(), public.my_vouchers(), public.claim_offer(uuid), public.redeem_voucher(text, int, int), public.match_pool(),
  public.admin_set_vendor(uuid, boolean, text), public.admin_grant_tokens(uuid, int, text), public.admin_overview(), public.admin_vendors()
  to authenticated;
grant execute on function public.live_offers() to anon;
grant execute on function public.record_purchase(uuid, int, int, int, text) to service_role;

-- ---------------------------------------------------------------------------
-- The 53 London places
-- ---------------------------------------------------------------------------
insert into public.venues (id,name,cat,kind,area,addr,lat,lng,google_place_id) values
('p1','Blacklock Soho','Steakhouse','Eat','Soho','24 Great Windmill St, London W1D 7LG',51.51178,-0.1347,'ChIJOTAQhtMEdkgR9ZmC_mZR0UM'),
('p2','The Soho Social','Restaurant & bar','Eat','Soho','9 Berwick St, London W1F 0PJ',51.51325,-0.13454,'ChIJhVBIm2AFdkgRe9fUbPJSvdc'),
('p3','Milk Beach Soho','Australian brunch','Eat','Soho','14 Greek St, James Court, London W1D 4AL',51.51424,-0.13077,'ChIJR96P1aQFdkgRVCU0FCf6358'),
('p4','Scarlett Green','Brunch & cocktails','Eat','Soho','4 Noel St, London W1F 8GB',51.51531,-0.1358,'ChIJl8b8USsbdkgRwY4c6Yh7udU'),
('p5','Dirty Bones Soho','Burgers & brunch','Eat','Soho','14 Denman St, London W1D 7HN',51.51083,-0.13531,'ChIJwYSoC9QEdkgR1DbvuJwey8o'),
('p6','Nessa Soho','Brasserie & cocktails','Drink','Soho','86 Brewer St, London W1F 9UB',51.51073,-0.13722,'ChIJr5F6YRwFdkgRNR-MS9GLn8s'),
('p7','The Devonshire','Pub & grill','Drink','Soho','The Devonshire, 17 Denman St, London W1D 7HW',51.51063,-0.13534,'ChIJsc95TQcFdkgRDgDjFkIJCz8'),
('p8','Harry''s Covent Garden','Italian','Eat','Covent Garden','11-12 Russell St, London WC2B 5HZ',51.51219,-0.12179,'ChIJvYQ6oMsEdkgRG9zlwh2N_-U'),
('p9','Brother Marcus Covent Garden','Mediterranean brunch','Eat','Covent Garden','23 Slingsby Pl, London WC2E 9AB',51.5128,-0.12636,'ChIJp9exgRcFdkgRpjsnrbLsyto'),
('p10','Blacklock Covent Garden','Steakhouse','Eat','Covent Garden','16a Bedford St, London WC2E 9HE',51.51066,-0.12471,'ChIJyeTsrLoFdkgRdsewS8ne0fQ'),
('p11','Ave Mario','Italian','Eat','Covent Garden','15 Henrietta St, London WC2E 8QG',51.51086,-0.12397,'ChIJoaTWHMsFdkgREy3QGecEo6c'),
('p12','Flat Iron Covent Garden','Steakhouse','Eat','Covent Garden','17-18 Henrietta St, London WC2E 8QH',51.51079,-0.12407,'ChIJ7a_rDcwEdkgRdiGLXlk7s-g'),
('p13','Gloria','Italian trattoria','Eat','Shoreditch','54-56 Great Eastern St, London EC2A 3QR',51.52512,-0.08138,'ChIJj99O4ScddkgRNnDfPFxdplY'),
('p14','Kricket Shoreditch','Indian','Eat','Shoreditch','35-42 Charlotte Rd, London EC2A 3PB',51.52525,-0.08095,'ChIJAQxeaAAddkgRkKAT-b-BK14'),
('p15','Hoppers Shoreditch','Sri Lankan','Eat','Shoreditch','Tea Building, 56 Shoreditch High St, London E1 6JJ',51.52372,-0.07648,'ChIJJViZx8UddkgRz7PTUq6ZXRw'),
('p16','Dishoom Shoreditch','Indian','Eat','Shoreditch','7 Boundary St, London E2 7JE',51.5245,-0.0766,'ChIJxYs1ArocdkgR-G13PLmofec'),
('p17','Padella Shoreditch','Fresh pasta','Eat','Shoreditch','Padella, Shoreditch, 1 Phipp St, London EC2A 4PS',51.52338,-0.08177,'ChIJmdTnioQddkgRkUPct-OykWI'),
('p18','Blacklock Shoreditch','Steakhouse','Eat','Shoreditch','28-30 Rivington St, London EC2A 3DZ',51.52602,-0.08196,'ChIJ44hFhjgddkgRdPaKatX_eGY'),
('p19','Pavyllon London','French fine dining','Eat','Mayfair','Hamilton Pl, London W1J 7DR',51.50417,-0.14995,'ChIJBfOjfiUFdkgRvsanD9nfpA0'),
('p20','Ormer Mayfair','Fine dining, seafood','Eat','Mayfair','Flemings Mayfair, 7-12 Half Moon St, 7-12 Half Moon St, London W1J 7BH',51.50645,-0.14514,'ChIJQxoh3SgFdkgRqFi4kGLn29c'),
('p21','Noble Rot Mayfair','Wine bar & restaurant','Eat','Mayfair','5 Trebeck St, Shepherd Market, London W1J 7LT',51.50652,-0.1472,'ChIJAzNI_8sFdkgRbRvnLqAvUJY'),
('p22','HIDE','Fine dining','Eat','Piccadilly','85 Piccadilly, London W1J 7NB',51.50619,-0.14444,'ChIJn1DE_XsFdkgR6NyYk4IWd64'),
('p23','Bacchanalia','Mediterranean','Eat','Mayfair','1-3 Mount St, London W1K 3NB',51.51057,-0.14773,'ChIJf53OwjQFdkgR_FlcHpcOo2g'),
('p24','Carlotta','Italian','Eat','Marylebone','77-78 Marylebone High St, London W1U 5JX',51.52097,-0.15213,'ChIJefT-hWIbdkgRAGGu1AuI0qg'),
('p25','108 Brasserie','Brasserie','Eat','Marylebone','108 Marylebone Ln, London W1U 2QE',51.51795,-0.15061,'ChIJIckEWtIadkgR0jqFi7ItZbA'),
('p26','Delamina Marylebone','Eastern Mediterranean','Eat','Marylebone','56-58 Marylebone Ln, London W1U 2NX',51.51638,-0.15009,'ChIJfZ_N4NIadkgRS-9ZCmodXHw'),
('p27','The Ivy Cafe Marylebone','British brasserie','Eat','Marylebone','96 Marylebone Ln, London W1U 2QA',51.5175,-0.15061,'ChIJecXp99IadkgRnWOHbk1a1Ec'),
('p28','Lina Stores Marylebone','Pasta & deli','Eat','Marylebone','13-15 Marylebone Ln, London W1U 2NE',51.51626,-0.1502,'ChIJDzt8MxQbdkgREAU6tIAGDbM'),
('p29','Brother Marcus Borough','Mediterranean brunch','Eat','Borough','1 Dirty Ln, London SE1 9PA',51.50564,-0.09223,'ChIJST09sxMDdkgROwVZQizAacI'),
('p30','Salt Yard Borough','Tapas','Eat','Borough','New Hibernia House, Winchester Walk, London SE1 9AG',51.50623,-0.09079,'ChIJY6uVgmoDdkgR5axDgVfG9_Q'),
('p31','Padella Borough Market','Fresh pasta','Eat','Borough','6 Southwark St, London SE1 1TQ',51.50517,-0.08992,'ChIJdZ6paFcDdkgRpPUHPngIeq8'),
('p32','OMA','Greek','Eat','Borough','2-4 Bedale St, London SE1 9AL',51.50535,-0.09002,'ChIJ4co2k5kDdkgROKjVBk6wD8k'),
('p33','Elliot''s Borough Market','Wine bar & grill','Drink','Borough','12 Stoney St, London SE1 9AD',51.50567,-0.0916,'ChIJA6RcmFcDdkgRhKbA3VHeY5U'),
('p34','Osteria Napoletana','Neapolitan pizza','Eat','Notting Hill','186 Kensington Park Rd, ES W11 2ES',51.51543,-0.20548,'ChIJNWlwNBgRdkgRj-WJmjibnCw'),
('p35','Gold','Modern European','Eat','Notting Hill','95-97 Portobello Rd, London W11 2QB',51.51298,-0.20264,'ChIJlbCxxa4PdkgR18AHB07QwLA'),
('p36','Granger and Co. Notting Hill','Australian brunch','Eat','Notting Hill','175 Westbourne Grove, London W11 2SB',51.5146,-0.19775,'ChIJK44GY_0PdkgRZqwjZA3l7-w'),
('p37','Frame Notting Hill','Tapas','Eat','Notting Hill','39 Hereford Rd, London W2 4AB',51.51486,-0.19395,'ChIJMzkn7zoRdkgRbRuR09X_t8Q'),
('p38','The National Gallery','Art museum','Culture','Trafalgar Square','Trafalgar Square, London WC2N 5DN',51.50893,-0.1283,'ChIJeclqF84EdkgRtKAjTmWFr0I'),
('p39','Victoria and Albert Museum','Design museum','Culture','South Kensington','Cromwell Rd, London SW7 2RL',51.49664,-0.17218,'ChIJw1d-sUMFdkgRH2XN_U0Jt54'),
('p40','The British Museum','Museum','Culture','Bloomsbury','Great Russell St, London WC1B 3DG',51.51941,-0.12696,'ChIJB9OTMDIbdkgRp0JWbQGZsS8'),
('p41','The Wallace Collection','Art collection','Culture','Marylebone','Hertford House, Manchester Square, London W1U 3BN',51.51732,-0.15309,'ChIJczuZfc0adkgRc8X-u3ZiHcE'),
('p42','Tate Modern','Modern art','Culture','Bankside','Bankside, London SE1 9TG',51.5076,-0.09936,'ChIJlRl2MakEdkgR55tr4CNv_B8'),
('p43','Frameless','Immersive art','Culture','Marble Arch','6 Marble Arch, London W1H 7AP',51.51368,-0.16036,'ChIJId2oNroFdkgReafXXIrGnkY'),
('p44','Foyles','Bookshop','Shop','Charing Cross Road','107 Charing Cross Rd, London WC2H 0EB',51.51431,-0.1299,'ChIJ5574rdIEdkgRA9294QpXDhw'),
('p45','Daunt Books Marylebone','Bookshop','Shop','Marylebone','84 Marylebone High St, London W1U 4QW',51.5204,-0.15199,'ChIJTQJH99EadkgRgli4gpxCkOY'),
('p46','Waterstones Piccadilly','Bookshop','Shop','Piccadilly','203-206 Piccadilly, London W1J 9HD',51.50912,-0.13605,'ChIJHXK0sdYEdkgRcrN_uxt5bOM'),
('p47','Word on the Water','Canal-boat bookshop','Shop','King''s Cross','Regent''s Canal Towpath, London N1C 4LW',51.53541,-0.12348,'ChIJ16mQBD4bdkgRQ8z5iJUz9fo'),
('p48','The Notting Hill Bookshop','Bookshop','Shop','Notting Hill','13 Blenheim Cres, London W11 2EE',51.51567,-0.20552,'ChIJ6y6Z4x0QdkgRMlPKETeKZKs'),
('p49','STEREO Covent Garden','Cocktails & live music','Drink','Covent Garden','35 The Piazza, London WC2E 8BE',51.51166,-0.12213,'ChIJMwnuyW4FdkgRVdwzLW-kJRw'),
('p50','Cahoots Underground','Cocktail bar','Drink','Carnaby','13 Kingly Ct, Carnaby, London W1B 5PW',51.51248,-0.13855,'ChIJ-2mrB9UEdkgReKgh9HDC-7s'),
('p51','Amazing Grace London Bridge','Karaoke cocktail bar','Drink','London Bridge','9a St Thomas St, London SE1 9RY',51.505,-0.08844,'ChIJLQhK3sUDdkgRjdb6JaFRLAo'),
('p52','The Little Violet Door','Cocktail bar','Drink','Carnaby','9 Kingly St, Carnaby, London W1B 5PH',51.51244,-0.13899,'ChIJ936KxucFdkgRV_Wlcb-EVL8'),
('p53','Nightjar','Speakeasy jazz bar','Drink','Old Street','129 City Rd, London EC1V 1JB',51.52652,-0.08774,'ChIJO5NM4aUcdkgR-XrNmE-75f8')
on conflict (id) do nothing;
