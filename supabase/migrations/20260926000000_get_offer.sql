-- "Get offer": tickets for shows, £1 to secure other offers, or a free claim that isn't guaranteed.
--  * ticket  : diner pays the ticket price. Guaranteed place.
--  * secured : diner pays a £1 fee. Guaranteed place.
--  * free    : no payment. Only honoured at the venue if places are still left when they arrive.
-- Guaranteed places (secured, ticket, and payments in progress) can never exceed the offer's places.

insert into public.settings (key, value, note) values
  ('secure_fee_pence', 100, 'What a diner pays to secure (guarantee) a non-ticket offer'),
  ('payment_hold_minutes', 35, 'How long a place is held while a diner pays')
on conflict (key) do nothing;

alter table public.offers drop constraint if exists offers_offer_type_check;
alter table public.offers add constraint offers_offer_type_check
  check (offer_type in ('percent_off', 'two_for_one', 'free_item', 'fixed_off', 'other', 'ticket'));
alter table public.offers add column if not exists price_pence int check (price_pence is null or price_pence between 50 and 100000);
alter table public.offers add column if not exists was_price_pence int check (was_price_pence is null or was_price_pence between 50 and 100000);
alter table public.offers add constraint offers_ticket_price check (offer_type <> 'ticket' or price_pence is not null);

alter table public.vouchers add column if not exists kind text not null default 'free' check (kind in ('free', 'secured', 'ticket'));
alter table public.vouchers add column if not exists status text not null default 'active' check (status in ('pending', 'active', 'cancelled'));
alter table public.vouchers add column if not exists paid_pence int check (paid_pence is null or paid_pence >= 0);
alter table public.vouchers add column if not exists hold_until timestamptz;
alter table public.vouchers add column if not exists stripe_session_id text unique;

-- Places that are guaranteed (paid, or being paid for right now)
create or replace function public.guaranteed_count(p_offer uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.vouchers
  where offer_id = p_offer
    and ((status = 'active' and kind in ('secured', 'ticket'))
      or (status = 'pending' and hold_until > now()))
$$;

-- ---------------------------------------------------------------------------
-- Vendors: create_offer gains ticket prices
-- ---------------------------------------------------------------------------
drop function if exists public.create_offer(text, text, int, numeric, numeric, numeric);
create or replace function public.create_offer(
  p_title text, p_offer_type text, p_tokens int, p_hours numeric,
  p_radius_km numeric default 3, p_min_pred numeric default 3.5,
  p_price_pence int default null, p_was_price_pence int default null
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
  if p_offer_type = 'ticket' and (p_price_pence is null or p_price_pence < 50) then raise exception 'Set a ticket price of at least 50p.'; end if;

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

  insert into public.offers (vendor_id, venue_id, title, offer_type, tokens, free_tokens, paid_tokens, radius_km, min_pred, expires_at, price_pence, was_price_pence)
  values (v.id, v.venue_id, trim(p_title), p_offer_type, p_tokens, v_free_use, v_paid_use,
          coalesce(p_radius_km, 3), coalesce(p_min_pred, 3.5), now() + make_interval(secs => (p_hours * 3600)::double precision),
          case when p_offer_type = 'ticket' then p_price_pence end, case when p_offer_type = 'ticket' then p_was_price_pence end)
  returning * into o;

  insert into public.token_ledger (vendor_id, kind, paid_delta, free_used, offer_id, note)
  values (v.id, 'issue', -v_paid_use, v_free_use, o.id, p_tokens || ' tokens for "' || o.title || '"');
  return o;
end $$;

-- ---------------------------------------------------------------------------
-- Diners: live offers now show prices and guaranteed places left
-- ---------------------------------------------------------------------------
drop function if exists public.live_offers();
create or replace function public.live_offers() returns table (
  id uuid, venue_id text, title text, offer_type text, tokens int, claimed int, guaranteed int,
  radius_km numeric, min_pred numeric, starts_at timestamptz, expires_at timestamptz,
  price_pence int, was_price_pence int, my_code text, my_kind text, my_status text
)
language sql stable security definer set search_path = public as $$
  select o.id, o.venue_id, o.title, o.offer_type, o.tokens,
         (select count(*)::int from public.vouchers v where v.offer_id = o.id and v.status <> 'cancelled') as claimed,
         public.guaranteed_count(o.id) as guaranteed,
         o.radius_km, o.min_pred, o.starts_at, o.expires_at, o.price_pence, o.was_price_pence,
         mv.code, mv.kind, mv.status
  from public.offers o
  left join public.vouchers mv on mv.offer_id = o.id and mv.user_id = auth.uid() and mv.status <> 'cancelled'
  where o.cancelled_at is null and o.starts_at <= now() and o.expires_at > now()
  order by o.expires_at
$$;

-- p_mode: 'free', 'secured' or 'ticket'. Paid modes hold a place while the diner pays.
drop function if exists public.claim_offer(uuid);
create or replace function public.claim_offer(p_offer uuid, p_mode text default 'free') returns public.vouchers
language plpgsql security definer set search_path = public as $$
declare
  o public.offers;
  existing public.vouchers;
  v_code text;
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  i int;
  vch public.vouchers;
  hold int := public.setting('payment_hold_minutes')::int;
begin
  if auth.uid() is null then raise exception 'Sign in to get offers.'; end if;
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'user') then
    raise exception 'Offers can only be claimed with a diner account.';
  end if;
  if p_mode not in ('free', 'secured', 'ticket') then raise exception 'Choose how to get this offer.'; end if;
  select * into o from public.offers where id = p_offer for update;
  if not found then raise exception 'Offer not found.'; end if;
  if o.cancelled_at is not null or o.expires_at <= now() then raise exception 'This offer has ended.'; end if;
  if o.starts_at > now() then raise exception 'This offer has not started yet.'; end if;
  if o.offer_type = 'ticket' and p_mode <> 'ticket' then raise exception 'This is a ticketed offer. Buy a ticket to get it.'; end if;
  if o.offer_type <> 'ticket' and p_mode = 'ticket' then raise exception 'This offer is not ticketed.'; end if;

  -- Clear the diner's own abandoned payment, if any
  delete from public.vouchers where offer_id = p_offer and user_id = auth.uid() and status = 'pending' and hold_until <= now();

  select * into existing from public.vouchers where offer_id = p_offer and user_id = auth.uid() and status <> 'cancelled';
  if found then
    -- Upgrading a free claim to a secured one
    if existing.kind = 'free' and p_mode = 'secured' and existing.redeemed_at is null then
      if public.guaranteed_count(p_offer) >= o.tokens then raise exception 'All % places have been secured. Your free claim still stands if places are left when you arrive.', o.tokens; end if;
      update public.vouchers set kind = 'secured', status = 'pending', hold_until = now() + make_interval(mins => hold) where id = existing.id returning * into vch;
      return vch;
    end if;
    return existing;
  end if;

  if public.guaranteed_count(p_offer) >= o.tokens then
    raise exception 'All % places for this offer are taken.', o.tokens;
  end if;

  loop
    v_code := 'TM-';
    for i in 1..6 loop
      v_code := v_code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.vouchers where code = v_code);
  end loop;

  insert into public.vouchers (offer_id, user_id, code, kind, status, hold_until)
  values (p_offer, auth.uid(), v_code, p_mode,
          case when p_mode = 'free' then 'active' else 'pending' end,
          case when p_mode = 'free' then null else now() + make_interval(mins => hold) end)
  returning * into vch;
  return vch;
end $$;

-- Called by the Stripe webhook once the diner has paid
create or replace function public.confirm_voucher_payment(p_voucher uuid, p_amount_pence int, p_session text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update public.vouchers
     set status = 'active', paid_pence = p_amount_pence, stripe_session_id = p_session, hold_until = null
   where id = p_voucher and status = 'pending';
  return found;
end $$;

-- What a diner pays for a voucher (used by the checkout function)
create or replace function public.voucher_price(p_voucher uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare vch public.vouchers; o public.offers; ve text;
begin
  select * into vch from public.vouchers where id = p_voucher and user_id = auth.uid();
  if not found then raise exception 'Voucher not found.'; end if;
  if vch.status <> 'pending' then raise exception 'This voucher is already paid for.'; end if;
  if vch.hold_until <= now() then raise exception 'Your place was released because payment took too long. Get the offer again.'; end if;
  select * into o from public.offers where id = vch.offer_id;
  select name into ve from public.venues where id = o.venue_id;
  return json_build_object('voucher_id', vch.id, 'kind', vch.kind, 'code', vch.code, 'title', o.title, 'venue', ve,
    'amount_pence', case when vch.kind = 'ticket' then o.price_pence else public.setting('secure_fee_pence')::int end);
end $$;

drop function if exists public.my_vouchers();
create or replace function public.my_vouchers() returns table (
  id uuid, code text, claimed_at timestamptz, redeemed_at timestamptz, offer_id uuid, title text, offer_type text,
  venue_id text, expires_at timestamptz, cancelled_at timestamptz, kind text, status text, paid_pence int, hold_until timestamptz, price_pence int
)
language sql stable security definer set search_path = public as $$
  select v.id, v.code, v.claimed_at, v.redeemed_at, o.id, o.title, o.offer_type, o.venue_id, o.expires_at, o.cancelled_at,
         v.kind, v.status, v.paid_pence, v.hold_until, o.price_pence
  from public.vouchers v join public.offers o on o.id = v.offer_id
  where v.user_id = auth.uid() and v.status <> 'cancelled'
  order by v.claimed_at desc
$$;

-- ---------------------------------------------------------------------------
-- Vendors scan: free claims are only honoured while unguaranteed places remain
-- ---------------------------------------------------------------------------
create or replace function public.redeem_voucher(p_code text, p_bill_pence int default null, p_party_size int default null) returns json
language plpgsql security definer set search_path = public as $$
declare
  v public.vendors;
  vch public.vouchers;
  o public.offers;
  venue_name text;
  grace int := public.setting('redeem_grace_minutes')::int;
  used int;
  owed int;
begin
  select * into v from public.vendors where id = auth.uid();
  if not found then raise exception 'Only business accounts can scan vouchers.'; end if;
  if not v.approved then raise exception 'Your business account is waiting for approval.'; end if;

  select * into vch from public.vouchers where code = upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g')) for update;
  if not found then raise exception 'Code % not recognised. Check it and try again.', upper(trim(coalesce(p_code, ''))); end if;
  select * into o from public.offers where id = vch.offer_id for update;

  if o.vendor_id <> v.id then
    select name into venue_name from public.venues where id = o.venue_id;
    raise exception 'This voucher is for %, not your venue.', coalesce(venue_name, 'another venue');
  end if;
  if vch.status = 'pending' then raise exception 'Not valid: the customer has not finished paying for this voucher.'; end if;
  if vch.status = 'cancelled' then raise exception 'This voucher was cancelled.'; end if;
  if vch.redeemed_at is not null then
    raise exception 'Already used on % at %.', to_char(vch.redeemed_at at time zone 'Europe/London', 'DD Mon'), to_char(vch.redeemed_at at time zone 'Europe/London', 'HH24:MI');
  end if;
  if now() > o.expires_at + make_interval(mins => grace) then
    raise exception 'This voucher expired at % on %.', to_char(o.expires_at at time zone 'Europe/London', 'HH24:MI'), to_char(o.expires_at at time zone 'Europe/London', 'DD Mon');
  end if;
  if vch.kind = 'free' then
    select count(*) into used from public.vouchers where offer_id = o.id and redeemed_at is not null;
    select count(*) into owed from public.vouchers where offer_id = o.id and redeemed_at is null and status = 'active' and kind in ('secured', 'ticket');
    if used + owed >= o.tokens then
      raise exception 'No places left for free claims: all % places are used or secured. Do not honour this voucher.', o.tokens;
    end if;
  end if;

  update public.vouchers
     set redeemed_at = now(), redeemed_by = v.id, bill_pence = p_bill_pence, party_size = p_party_size
   where id = vch.id
   returning * into vch;

  return json_build_object('code', vch.code, 'offer_title', o.title, 'offer_type', o.offer_type, 'kind', vch.kind, 'paid_pence', vch.paid_pence,
                           'claimed_at', vch.claimed_at, 'redeemed_at', vch.redeemed_at,
                           'bill_pence', vch.bill_pence, 'party_size', vch.party_size);
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
    'vouchers_claimed', (select count(*) from public.vouchers where status = 'active'),
    'vouchers_redeemed', (select count(*) from public.vouchers where redeemed_at is not null),
    'vendor_spend_pence', (select coalesce(sum(bill_pence), 0) from public.vouchers where redeemed_at is not null),
    'secure_fees_pence', (select coalesce(sum(paid_pence), 0) from public.vouchers where kind = 'secured' and status = 'active'),
    'ticket_sales_pence', (select coalesce(sum(paid_pence), 0) from public.vouchers where kind = 'ticket' and status = 'active')
  );
end $$;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.setting(text), public.is_admin(), public.vendor_balance(uuid),
  public.create_offer(text, text, int, numeric, numeric, numeric, int, int),
  public.end_offer(uuid), public.live_offers(), public.my_vouchers(), public.claim_offer(uuid, text), public.voucher_price(uuid),
  public.redeem_voucher(text, int, int), public.match_pool(), public.guaranteed_count(uuid),
  public.admin_set_vendor(uuid, boolean, text), public.admin_grant_tokens(uuid, int, text), public.admin_overview(), public.admin_vendors()
  to authenticated;
grant execute on function public.live_offers(), public.guaranteed_count(uuid) to anon;
grant execute on function public.record_purchase(uuid, int, int, int, text), public.confirm_voucher_payment(uuid, int, text) to service_role;
