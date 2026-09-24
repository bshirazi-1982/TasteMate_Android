# Setting up and publishing Tastemate

You don't need Android Studio or any programming tools. GitHub builds and deploys everything in the cloud, and you only fill in forms on websites.

| Part | What it gives you | Your time | Cost |
|---|---|---|---|
| **Before you start** | The project on GitHub | 20 min | Free |
| **A. Backend (Supabase)** | Sign-in and the central database of offers, scans and tokens | 30 min | Free tier is enough for a beta |
| **B. Payments (Stripe)** | Businesses buy tokens by card, paid into your bank | 30 min, plus Stripe's checks | 1.5% + 20p per UK card payment (check Stripe's current rates) |
| **C. Website** | The business portal, where tokens are bought, plus your privacy policy | 10 min | Free |
| **D. Android app** | The app on Google Play | 2 hours over a few days | US$25 once |

Try everything first: the app has a **demo mode** that works with no setup. Open `www/index.html` after a build, or the demo page Claude published. The demo accounts are `diner@demo.app`, `vendor@demo.app` and `admin@demo.app`, and each uses the password `tastemate`.

---

## Before you start: put the project on GitHub

1. Create a free account at <https://github.com> and click **New repository**. Name it `tastemate` and make it **Public**, which gives free website hosting. No passwords or keys go into the repository.
2. Click **uploading an existing file** and drag in everything from the `tastemate-android` folder. Include the hidden `.github` folder. If your computer hides it, use GitHub Desktop.
3. Everything below goes into **Settings › Secrets and variables › Actions**:
   - **Secrets** are private, such as passwords and keys.
   - **Variables** are not secret, such as web addresses.

   The full list is at the end of this guide.

---

## A. Backend (Supabase)

1. Sign up at <https://supabase.com> and click **New project**:
   - Name: `tastemate`
   - **Region: London (eu-west-2)**, which keeps UK data in the UK
   - Choose a strong database password and save it in your password manager.
2. Once the project is ready, open **Project Settings › Data API** (or **API**) and note:
   - the **Project URL**, which looks like `https://abcdefgh.supabase.co`. The part before `.supabase.co` is your **project ref**.
   - the **anon / publishable key**. It's safe to include in the app; the database rules protect everything.
3. Create a personal access token at <https://supabase.com/dashboard/account/tokens>.
4. In GitHub, add:
   - Secrets: `SUPABASE_ACCESS_TOKEN` (the token from step 3) and `SUPABASE_DB_PASSWORD`
   - Variables: `SUPABASE_PROJECT_REF`, `SUPABASE_URL` and `SUPABASE_ANON_KEY`
5. In GitHub, open **Actions › Set up backend › Run workflow**. This creates the tables, security rules and 64 London places (including 11 theatres and comedy venues), and deploys the payment and account-deletion functions. It takes about 2 minutes.
6. In Supabase, open **Authentication › URL Configuration**. Set **Site URL** to your website address from part C (for example `https://YOUR-GITHUB-NAME.github.io/tastemate/`) and add the same address under **Redirect URLs**.
7. **Make yourself the publisher.** Create a normal diner account in the app or on the website with your own email. Then, in Supabase, open **SQL Editor**, paste this line with your email, and click **Run**:
   ```sql
   update public.profiles set role = 'admin' where id = (select id from auth.users where email = 'you@example.com');
   ```
   Sign out and back in. You'll now see **Overview** and **Businesses**, where you approve new businesses.

> Supabase's built-in email sends only a few emails an hour. That's fine for testing. Before launch, connect an email service under **Authentication › Emails › SMTP settings** (for example Resend or Postmark) so sign-up and password emails always arrive.

## B. Payments (Stripe)

1. Sign up at <https://dashboard.stripe.com/register>. Complete **Activate payments** with your business details and the bank account for payouts. Token money goes to your Stripe balance, and Stripe pays it into that bank account automatically.
2. Start in **test mode** (the toggle at the top). Under **Developers › API keys**, copy the **Secret key** (`sk_test_…`).
3. Under **Developers › Webhooks › Add endpoint**:
   - Endpoint URL: `https://YOUR-PROJECT-REF.supabase.co/functions/v1/stripe-webhook`
   - Events: `checkout.session.completed` and `checkout.session.async_payment_succeeded`
   - After saving, reveal the **Signing secret** (`whsec_…`).
4. In GitHub, add secrets `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET`, then run **Set up backend** again.
5. Test it: on the website, sign in as a business you've approved, open **Tokens**, and buy 100. Pay with test card `4242 4242 4242 4242`, any future date and any CVC. The tokens appear within a few seconds.
6. When you're ready for real money, switch Stripe to **live mode**. Create a live secret key and a live webhook the same way, replace the two GitHub secrets, and run **Set up backend** again.

**Prices and the free allowance** live in the database, not the app. To change them, open Supabase **Table Editor › settings** and edit a value: `free_tokens_per_month` (10), `price_single_pence` (75), `price_bulk_pence` (45) or `bulk_min_qty` (100). The change applies immediately to everyone.

**VAT.** Prices are charged exactly as set, with no VAT added. If you're VAT-registered, decide whether 75p and 45p include VAT, or turn on Stripe Tax. Check with your accountant.

## C. Website (business portal and privacy policy)

1. In GitHub, open **Settings › Pages** and set **Source** to **GitHub Actions**.
2. Add the variable `APP_URL` = `https://YOUR-GITHUB-NAME.github.io/tastemate/`, with the trailing slash.
3. Edit `docs/privacy-policy.html` on GitHub (click the pencil icon). Replace `PUBLISHER_NAME`, `CONTACT_EMAIL` and `APP_URL`, then commit. The website publishes itself after every change. You can also run **Actions › Publish website**.
4. Your addresses are:
   - Website: `https://YOUR-GITHUB-NAME.github.io/tastemate/`
   - Privacy policy: the same address plus `privacy-policy.html`
   - Account deletion page, which Google Play asks for: the same address plus `#account`

## D. Android app on Google Play

1. **Google Play developer account.** Sign up at <https://play.google.com/console/signup> (US$25), then complete identity verification. This takes 1–3 days.
2. **Google Maps key.** In <https://console.cloud.google.com>:
   - Create a project with billing, and turn on **Maps JavaScript API** and **Places API (New)**.
   - Create an API key and restrict it. Under **Websites**, allow `https://localhost/*` (the Android app) and `https://YOUR-GITHUB-NAME.github.io/*` (the website). Under **APIs**, allow only those two.
   - Set a monthly budget alert.
   - Optionally create a **Map ID** (type JavaScript).
   - Add the GitHub secrets `MAPS_API_KEY`, and `MAP_ID` if you created one.
3. **Upload key.** Add the GitHub secrets `KEYSTORE_BASE64` and `KEYSTORE_PASSWORD` from `GITHUB-SECRETS.txt`. Keep `tastemate-upload.jks` and that file in your password manager, never on GitHub.
4. **Build.** Run **Actions › Build Android beta**. After about 8 minutes, download **tastemate-beta-N**:
   - `app-release.aab` is the file for Google Play.
   - `app-release.apk` installs straight onto your own phone for testing.
5. **Create the app in Play Console.** Choose **Create app**, name it **Tastemate: London Picks**, type App, Free. Keep **Play App Signing** on. Fill in the store listing from `store/listing.md` and the images in `store/`.
6. **App content** (Policy › App content):

   | Section | Answer |
   |---|---|
   | Privacy policy | Your privacy policy address from part C |
   | App access | Some features need an account. Give Google the diner test login `review@…` and a business test login you've approved, with passwords. |
   | Account deletion | Yes. In-app: tap your name, then Delete my account. Web link: your website address plus `#account` |
   | Ads | No |
   | Content rating | Complete the questionnaire. The app mentions bars and cocktails, so answer yes to references to alcohol. |
   | Target audience | 18 and over |
   | Financial features | None for diners. Businesses buy advertising tokens on the website. |

   **Data safety answers:**

   | Data type | Collected | Shared | Purpose | Optional? |
   |---|---|---|---|---|
   | Personal info › Name, Email address | Yes | No | Account management, App functionality | Required for an account |
   | Financial info › Purchase history | Yes (businesses only) | No | App functionality | Required to buy tokens |
   | App activity › Other user-generated content (ratings) | Yes | No | App functionality, Personalisation | Optional |
   | App activity › Other actions (vouchers claimed and used) | Yes | No | App functionality, Analytics for venues | Optional |
   | Location › Approximate and Precise | Yes, processed on the device only | No | App functionality | Optional |

   Also answer: data encrypted in transit **Yes**, and users can request deletion **Yes**.
7. **Release to testers.** Under **Testing › Internal testing**, upload `app-release.aab`, roll it out, and send testers the opt-in link. For a personal developer account, Google requires a **closed test with at least 12 testers for 14 days in a row** before you can release to everyone. Start this early.

---

## Before a public launch: decisions and checks

1. **Google Play payment rules (most important).** Google normally requires its own billing (and fee) for digital items bought inside an Android app. Tastemate avoids in-app buying: businesses buy tokens only on the website, and the Android app just tells them to buy tokens on the web. Tokens are a business advertising service used for real-world visits, which may be exempt. However, Google's rules on both buying digital items and pointing users to outside payment are strict and change often. **Confirm with Google Play's Payments policy, or a specialist, before production.** Alternatives are removing the web mention from the Android app or adding Google Play Billing.
2. **Stored Google ratings.** The app contains Google's ratings as of 23 Sep 2026. Google Maps Platform terms generally don't allow keeping these long term. Switch the lists to live ratings, or to Tastemate members' own ratings, before launch.
3. **Supabase free tier.** Free projects pause after a week with no activity and have usage limits. Move to the Pro plan (about US$25 a month) before launch.
4. **Email.** Connect your own email service (see part A).
5. **Legal.** Get the privacy policy, terms for businesses (token pricing, no refunds for unclaimed places, approval), and consumer terms checked.
6. **Simulated profiles.** Remove the 50 simulated profiles once enough real members have rated places.

## Everything you add to GitHub

| Name | Type | Where it comes from |
|---|---|---|
| `SUPABASE_ACCESS_TOKEN` | Secret | Supabase account › Access tokens |
| `SUPABASE_DB_PASSWORD` | Secret | The password you chose for the Supabase project |
| `SUPABASE_PROJECT_REF` | Variable | The part of the project URL before `.supabase.co` |
| `SUPABASE_URL` | Variable | Supabase › Project Settings › API |
| `SUPABASE_ANON_KEY` | Variable | Supabase › Project Settings › API (anon / publishable) |
| `STRIPE_SECRET_KEY` | Secret | Stripe › Developers › API keys |
| `STRIPE_WEBHOOK_SECRET` | Secret | Stripe › Developers › Webhooks › your endpoint |
| `APP_URL` | Variable | Your GitHub Pages address, ending in `/` |
| `MAPS_API_KEY` | Secret | Google Cloud › Credentials |
| `MAP_ID` | Secret (optional) | Google Cloud › Map management |
| `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD` | Secrets | `GITHUB-SECRETS.txt` |

## Making changes later

- The app's screens are in `src/app.html`. Edit it and the website updates itself. Run **Build Android beta** for a new app version, then upload it as a new release.
- Database changes go in a new file under `supabase/migrations/`. Run **Set up backend** to apply it.
