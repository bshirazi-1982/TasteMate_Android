// Diner pays for a voucher: a show ticket (ticket price) or £1 to secure an offer.
// The place is held while they pay; the Stripe webhook activates the voucher when payment succeeds.
import Stripe from "npm:stripe@22.6.2";
import { createClient } from "npm:@supabase/supabase-js@2.117.1";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", { httpClient: Stripe.createFetchHttpClient() });
const APP_URL = (Deno.env.get("APP_URL") ?? "").replace(/\/$/, "");
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return json({ error: "Sign in to pay." }, 401);

  let body: { voucher_id?: string; return_url?: string } = {};
  try { body = await req.json(); } catch { /* empty */ }
  if (!body.voucher_id) return json({ error: "Missing voucher." }, 400);

  const { data: price, error } = await supabase.rpc("voucher_price", { p_voucher: body.voucher_id });
  if (error || !price) return json({ error: error?.message ?? "Voucher not found." }, 400);

  const back = body.return_url && APP_URL && body.return_url.startsWith(APP_URL) ? body.return_url.split("#")[0] : APP_URL;
  const isTicket = price.kind === "ticket";
  const session = await stripe.checkout.sessions.create({
    mode: "payment",
    line_items: [{
      quantity: 1,
      price_data: {
        currency: "gbp",
        unit_amount: price.amount_pence,
        product_data: {
          name: isTicket ? `Ticket: ${price.title}` : `Secure offer: ${price.title}`,
          description: `${price.venue ?? "Tastemate venue"} · voucher ${price.code}${isTicket ? "" : " · guarantees your place"}`,
        },
      },
    }],
    customer_email: user.email ?? undefined,
    client_reference_id: user.id,
    metadata: { purpose: "voucher", voucher_id: price.voucher_id, user_id: user.id, kind: price.kind },
    expires_at: Math.floor(Date.now() / 1000) + 30 * 60,
    success_url: `${back}#voucher-paid`,
    cancel_url: `${back}#voucher-cancelled`,
  });
  return json({ url: session.url, amount_pence: price.amount_pence });
});
