# Tastemate

Recommendations for London restaurants, bars, museums and shops based on your 10 closest taste matches, plus live offers from venues, with QR vouchers, visit tracking and vendor statistics.

- `src/app.html`: the whole app (diner, business and publisher screens). Runs in demo mode when no backend is configured.
- `supabase/`: central database (tables, security rules, tokens, vouchers) and functions for Stripe payments and account deletion
- `android/`: Android wrapper (Capacitor 8)
- `.github/workflows/`: cloud jobs to set up the backend, publish the website and build the Android app
- `store/`: Google Play images and listing text
- `docs/privacy-policy.html`: privacy policy (published with the website)

**Start with [PUBLISHING.md](PUBLISHING.md).**
