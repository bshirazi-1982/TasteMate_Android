// Creates a Stripe Checkout page for a vendor buying user tokens.
// Price per token comes from the settings table: 75p each, or 45p each for 100 or more.
// Payment goes to the publisher's Stripe account.
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
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return json({ error: "Sign in to buy tokens." }, 401);

  const { data: vendor } = await supabase.from("vendors").select("id, business_name, contact_email, approved").eq("id", user.id).single();
  if (!vendor) return json({ error: "Only business accounts can buy tokens." }, 403);

  let body: { qty?: number; return_url?: string } = {};
  try { body = await req.json(); } catch { /* empty body */ }
  const qty = Math.floor(Number(body.qty));
  if (!Number.isFinite(qty) || qty < 1 || qty > 20000) return json({ error: "Choose between 1 and 20,000 tokens." }, 400);

  const { data: settings } = await supabase.from("settings").select("key, value");
  const s = Object.fromEntries((settings ?? []).map((r: { key: string; value: number }) => [r.key, Number(r.value)]));
  const bulkMin = s.bulk_min_qty ?? 100;
  const unit = qty >= bulkMin ? (s.price_bulk_pence ?? 45) : (s.price_single_pence ?? 75);

  // Only send people back to our own app after paying
  const back = body.return_url && APP_URL && body.return_url.startsWith(APP_URL) ? body.return_url.split("#")[0] : APP_URL;

  const session = await stripe.checkout.sessions.create({
    mode: "payment",
    line_items: [{
      quantity: qty,
      price_data: {
        currency: "gbp",
        unit_amount: unit,
        product_data: {
          name: qty >= bulkMin ? "Tastemate user tokens (bulk price)" : "Tastemate user tokens",
          description: "Each token lets one person claim one of your offers.",
        },
      },
    }],
    customer_email: vendor.contact_email ?? user.email ?? undefined,
    client_reference_id: vendor.id,
    metadata: { vendor_id: vendor.id, qty: String(qty), unit_pence: String(unit) },
    payment_intent_data: { metadata: { vendor_id: vendor.id, qty: String(qty) }, description: `${qty} Tastemate tokens for ${vendor.business_name}` },
    invoice_creation: { enabled: true },
    success_url: `${back}#tokens-paid`,
    cancel_url: `${back}#tokens-cancelled`,
  });

  return json({ url: session.url, qty, unit_pence: unit, amount_pence: unit * qty });
});
