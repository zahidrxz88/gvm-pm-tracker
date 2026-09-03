# AV Service Contract Rack — Project Context

This is an internal PM (preventive maintenance) contract tracking dashboard for
**Global Vision Multimedia (a Ricoh company)**. It tracks AV service contracts,
their SLA-defined check frequency, and upcoming/completed PM checks.

## Live setup

- **Hosting:** Netlify, currently deployed via manual drag-and-drop of `index.html`
  (not yet connected to a Git repo — see "Suggested next step" below).
- **Data:** Supabase (Postgres). Project URL and anon key are hardcoded near the
  top of `index.html` (search for `SUPABASE_URL`). Table setup is in `setup.sql` —
  run that once in the Supabase SQL Editor if setting up a fresh project.
- **No backend/server code.** Everything is client-side. The browser talks
  directly to Supabase's REST API (PostgREST) using the anon key.

## IMPORTANT: how `index.html` is built

This is a **single self-contained HTML file** with React, ReactDOM, and the app
code all inlined directly — there are **no external `<script src>` CDN
dependencies at all**. This was deliberate: an earlier version loaded React/
ReactDOM/Babel from `unpkg.com` at runtime, and on some networks (corporate
firewalls, ad blockers) one of those requests would silently fail, producing a
blank page with no error. Inlining everything eliminated that failure mode.

**The React code inside `index.html` is precompiled, plain
`React.createElement(...)` calls — not JSX.** It was originally written as JSX,
then compiled with Babel using the *classic* runtime (not automatic — automatic
runtime needs `react/jsx-runtime` as an importable module, which doesn't exist
in this no-build-tool setup). If you (Claude Code) need to make edits:

- **Small edits:** you can often hand-edit the `React.createElement(...)` calls
  directly, if you're careful. It's readable but verbose.
- **Bigger edits:** it's much saner to reconstruct the JSX version, edit that,
  recompile with Babel (`@babel/core` + `@babel/preset-react` with
  `{ runtime: "classic" }`), and re-inline the output. Do NOT reintroduce
  `<script type="text/babel">` + a CDN Babel loader — that's the exact bug we
  fixed.
- React and ReactDOM production UMD builds are inlined as raw `<script>` tags
  right before the app script. If upgrading React versions, regenerate those
  from `node_modules/react/umd/react.production.min.js` etc.

## Suggested next step (recommended, not yet done)

This hand-rolled "precompile and inline" approach works but isn't fun to
maintain long-term. If the user wants proper iteration going forward, consider
proposing a migration to a real Vite + React project with:
- A `package.json`, real `npm run build`, and a `src/` folder with actual `.jsx`
  files (no more manual Babel compiling)
- A GitHub repo connected to Netlify for auto-deploy on every push (instead of
  manual drag-and-drop)
- The Supabase logic pulled into its own module

This is a judgment call — only worth the churn if the user is going to keep
iterating a lot. Ask before doing a big restructure.

## Data model

Everything lives in one Supabase table, `kv_store` (key/value, `value` is
`jsonb`):

- `key = 'contracts'` → JSON array of contract objects:
  ```
  {
    id, vendor (GVMS no), contractName (Client), rooms (Address), region (country),
    startDate, endDate, frequency (1 | 2 | 4, checks per year),
    schedule: [ { id, date: string|null, completed: boolean }, ... ]
  }
  ```
- `key = 'presence:<profile.id>'` → `{ email }`, one row per logged-in account,
  used for the "who's online" avatars in the header. Each logged-in client
  upserts its own row via `kvSet` every 10s (see the "send a 'still here'
  heartbeat" effect in `Dashboard`) and every client polls `kvList("presence:")`
  every 10s to read them all back. A row counts as online only if its
  `updated_at` is within the last 25s (`PRESENCE_STALE_MS`) — there's no
  explicit "going offline" write, closing the tab or losing network just lets
  the row go stale and drop off. This piggybacks on the existing
  authenticated-write / anyone-read `kv_store` RLS policies, so no schema
  changes were needed for it.

Real accounts and roles live in Supabase's own `auth.users` table plus a
`profiles` table (`id`, `email`, `role`), and an `activity_log` table holds the
audit trail. All three (plus their RLS policies and a `handle_new_user`
trigger) are defined in `setup.sql` — re-run that file in the Supabase SQL
Editor after pulling changes to it; it's written to be safe to re-run.

The dashboard polls `kv_store` every 10 seconds and merges in changes, so
multiple people can use the same link and see each other's edits (not
real-time push — up to a 10s lag).

## Auth model (real accounts via Supabase Auth, roles in Postgres)

There is **no Supabase JS SDK** in this file (would mean either an external
CDN dependency or inlining a large UMD bundle). Instead, login/signup/logout
and session refresh are done with hand-rolled `fetch` calls straight to
Supabase's GoTrue REST endpoints (`/auth/v1/signup`, `/auth/v1/token?grant_type=...`,
`/auth/v1/logout`) — see the "AUTH" section right after `kvGet`/`kvSet` in
`index.html`. The session (access/refresh token) is cached in `localStorage`
under `gvm_auth_session` and silently refreshed before it expires.

- **Guest** (no login): view-only. Cannot see PM schedule dates at all,
  cannot add/edit/delete contracts, cannot see the "Upcoming PM Checks" section.
- **User** (self-signup default): can view + set/change PM check dates. Cannot
  mark a check "Done", cannot add/edit/delete contracts.
- **Admin**: full access — add/edit/delete contracts, mark checks Done.
- **Super admin** (locked to `zahidrxz@gmail.com`, enforced in `setup.sql` via
  `is_locked_super_admin()` — not just client-side): everything Admin can do,
  plus the **Manage Users** panel (assign `user`/`admin` roles — only the
  super admin can do this, enforced by an RLS policy, not just hidden UI) and
  the **Activity Log** panel (read-only audit trail of logins/logouts,
  contract changes, PM date/done changes, and role changes — also RLS-gated to
  super admin only, so the query returns rows for nobody else).
- Anyone can self-sign-up (email + password) and starts as `user`. The role
  actually enforced comes from the `profiles.role` column server-side (via
  RLS), not from client state — this is a real improvement over the old PIN
  model. **One nuance:** `kv_store` (the contracts blob) is one JSON row, not
  one row per contract, so Postgres RLS can only gate "authenticated vs. not"
  on writes to it — it can't itself distinguish "user may set a date" from
  "admin may delete a contract" within that blob. That finer split is still
  enforced client-side only (same limitation the old PIN model had). Tightening
  it further would mean moving contracts to real per-row storage plus RPC
  functions — don't take that on without asking first.
- Depending on the Supabase project's Auth settings, "Confirm email" may be
  required before a freshly-signed-up account can log in — if so, the signup
  flow shows a "check your email" notice instead of logging them in
  immediately. If confirmation emails redirect somewhere wrong, check the
  Auth → URL Configuration "Site URL" in the Supabase dashboard against the
  Netlify domain.

## Key business logic worth knowing before touching it

- **PM schedule slot count** is calculated *proportionally*, not by walking
  calendar months. See `computeSlotCount()`. Earlier versions tried stepping by
  exact month intervals and kept losing a slot whenever a contract's end date
  was one day short of a clean year (extremely common — e.g. "Jul 15, 2026 to
  Jul 14, 2027" is a totally normal way to write a 1-year contract). The fix:
  `count = round((days_between(start,end) / 365.25) * frequency)`. Don't
  regress this back to calendar-stepping logic.
- PM check **dates are entirely user-picked** — nothing is auto-suggested. A
  slot starts as `date: null` ("Please select a date") and the user picks the
  real date via a native `<input type="date">`.
- The top-level **"Upcoming PM Checks"** section shows **every** pending,
  dated PM check across all contracts, soonest first — no cap. Each
  **contract card's own** "PM SCHEDULE" mini-list still only ever shows its
  **next 2** pending checks (not the full per-contract list) — that part is
  intentional, not a bug or a missing "show more."
- Contracts list is sorted **alphabetically by Client (contractName)**, so
  the grid reads left-to-right then top-to-bottom in alphabetical order.
- GVMS no / Client / Address are forced UPPERCASE as you type. Region is a
  country dropdown (not free text), also displayed uppercase.
- "Export CSV" button (visible to User/Admin) downloads a long-format CSV — one
  row per PM check occurrence — for monthly reporting. No xlsx library is used;
  it's a hand-built CSV string, which Excel/Sheets both open fine.
- Currently **dark theme** (a light theme was tried and explicitly reverted —
  don't reintroduce it without being asked).
- All font sizes were deliberately bumped +2px from the original design at the
  user's request. If redoing typography, keep that in mind rather than
  reverting to smaller defaults.

## Icons

No icon library is used (no `lucide-react` — that needs a package manager,
which this no-build setup doesn't have). Icons are small hand-written inline
SVGs styled to look like the Lucide set. If adding new icons, follow the same
pattern (a shared `<Icon>` wrapper + a small hand-drawn path).
