// Stripe calls this after a vendor pays. It adds the tokens to the vendor's balance.
// The signature check makes sure the message really came from Stripe.
import Stripe from "npm:stripe@22.6.2";
import { createClient } from "npm:@supabase/supabase-js@2.117.1";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", { httpClient: Stripe.createFetchHttpClient() });
const crypto = Stripe.createSubtleCryptoProvider();
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(async (req) => {
  const signature = req.headers.get("Stripe-Signature");
  const body = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, signature ?? "", Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "", undefined, crypto);
  } catch (err) {
    return new Response(`Signature check failed: ${(err as Error).message}`, { status: 400 });
  }

  if (event.type === "checkout.session.completed" || event.type === "checkout.session.async_payment_succeeded") {
    const session = event.data.object as Stripe.Checkout.Session;
    if (session.payment_status !== "paid") return new Response("Waiting for payment", { status: 200 });
    const vendor = session.metadata?.vendor_id;
    const qty = Number(session.metadata?.qty);
    const unit = Number(session.metadata?.unit_pence);
    if (!vendor || !qty) return new Response("Missing details", { status: 400 });
    const { error } = await admin.rpc("record_purchase", {
      p_vendor: vendor, p_qty: qty, p_unit_pence: unit, p_amount_pence: session.amount_total ?? unit * qty, p_session: session.id,
    });
    if (error) return new Response(`Could not record purchase: ${error.message}`, { status: 500 }); // Stripe will retry
  }
  return new Response("ok", { status: 200 });
});
