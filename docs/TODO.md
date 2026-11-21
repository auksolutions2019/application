# First Choice Laptops: tasks left (checked 21 Nov 2026)

## Done and checked on 21 Nov 2026
- Code: all pushed to GitHub, app version fcl-v10.
- Live site first-choice-laptops.pages.dev opens and serves fcl-v10. The warranty page /w/ opens.
- Database: awake, answers the keep-alive ping, has every update up to Export. The public key cannot read any table.
- Sign-ups are off.
- All 5 Edge Functions (auth-login, change-pin, admin-users, warranty-check, photo-delete) answer with the app's own messages, so Verify JWT is off on all of them.
- APP_ORIGIN is set. App Settings are filled in. The app is installed on the phones.
- Local tests: 317 database checks, 21 unit checks, 36 Excel-import checks, all pass.

Most important first. Who does it is in brackets.

## 1. Dealer questions, then the Excel import (dealer, then you)
- Ask the dealer:
  - lot 10: is the cost the line total or the price per laptop, and is the date 1 Sep?
  - lot 13's date (it was entered late)
  - the 3 sales on the "wc" tab: lot 12 or lot 13?
  - two possible double entries: 19 Oct "i5 6th 8/256" (Lead Matrix) and 27 Sep "HP pentinum 360" (OLX)
  - are "elec city office" and "electronic city" the same customer?
- Then log in as admin: More → Backup and import → Dealer's Excel file. Answer the preview questions the way the dealer said. Check the preview shows total sales of ₹4,97,400, then click Import.
- Right after: More → Backup and import → Export → Excel and JSON, as the first backup.

## 2. Cloudinary secrets for deleting photos (you, if not done yet)
- Cloudinary → Settings → API Keys: copy the Cloud name, the API Key and the API Secret.
- Supabase → Edge Functions → Secrets: add `CLOUDINARY_CLOUD_NAME`, `CLOUDINARY_API_KEY` and `CLOUDINARY_API_SECRET`.
- Without them, a deleted photo leaves the app but stays in Cloudinary.
- These cannot be checked from outside. Test 3 (Photos) below proves it.

## 3. Keep-alive check (you)
- GitHub (auksolutions2019) → application → Actions → Keep Supabase awake. The latest run should be green.
- Claude cannot see this (private repo, no GitHub tool on this PC). Send a screenshot.

## 4. Real-phone tests (you)
- **Two phones:** sell on one; it shows on the other within seconds.
- **Scan:** the live camera on a sticker; Choose from gallery with a WhatsApp photo; Share → First Choice from WhatsApp.
- **Photos:** add one, delete one, and check it's gone in Cloudinary.
- **Low stock:** an accessory with stock 3, sell 2. The 🔔 shows a count; allow phone notifications when asked.
- **PIN lock:** 5 wrong PINs lock the login for 15 minutes. Use a test user, not the admin.

## 5. Printing tests (you)
- Stickers on A4 gum paper (4 per row).
- One black-and-white bill on the printer, and one colour PDF.
- Scan the warranty QR on the printed bill with a phone camera.

## 6. Weekly habit (you or the dealer)
- Every week: More → Backup and import → Export → Excel and JSON. Keep the files private, off the shop phones.

## 7. Users (you, when needed)
- More → Users → Add a user: Raheem as Co-admin, each worker as Staff.
- The extra admin: log in once and change the PIN (More → Change my PIN).

## 0. Custom domain app.firstchoicelaptops.com (you, now)
Status 22 Nov: the domain is connected and serves fcl-v10, and /w/ opens on both addresses. ⚠️ Login on the new
address fails ("Could not reach the server") because Supabase still runs the old one-address functions.
Steps 3 and 4 are done; steps 1 and 2 are left.

The functions in the repo accept both addresses (commit 5b68342). Do these in order:
1. **Deploy the 4 changed functions** (auth-login, change-pin, admin-users, photo-delete) with the dealer's Supabase account. warranty-check did not change.
   - Dashboard: Edge Functions → open each one → Code → paste `supabase/functions/<name>/index.ts` → Deploy. Then check that Verify JWT is still off.
   - Or the CLI with a dealer access token (Supabase → Account → Access Tokens), without touching the TaqwaSteps login: see README step 4.
2. **Only then**, in Supabase → Edge Functions → Secrets, set `APP_ORIGIN` to
   `https://first-choice-laptops.pages.dev,https://app.firstchoicelaptops.com`
3. Cloudflare: Workers & Pages → first-choice-laptops → Custom domains → add `app.firstchoicelaptops.com`.
4. Domain host (Hostinger): add a DNS record of type CNAME, name `app`, target `first-choice-laptops.pages.dev`.
5. When Cloudflare shows it Active, open the new address on each phone, log in, and do Add to Home screen. The old address keeps working, so there's no rush.
6. Tell Claude "check the domain" to confirm both addresses work.

## 9. Ideas, not built yet (ask Claude when wanted)
- A "Reverse payment" button for a single payment (today only Undo sale and Return reverse payments).
- Phone notifications while the app is fully closed (needs a push server).
- Lot expenses in the co-admin's export (left out on purpose).
