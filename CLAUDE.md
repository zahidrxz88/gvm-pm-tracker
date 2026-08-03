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
- `key = 'admin_pin'` → string, default `Admin1234!`
- `key = 'user_pin'` → string, default `User1234!`

The dashboard polls Supabase every 10 seconds and merges in changes, so
multiple people can use the same link and see each other's edits (not
real-time push — up to a 10s lag).

## Auth model (three tiers, app-level only — NOT real security)

- **Guest** (default, no login): view-only. Cannot see PM schedule dates at all,
  cannot add/edit/delete contracts, cannot see the "Upcoming PM Checks" section.
- **User** (PIN: `User1234!`): can view + set/change PM check dates. Cannot mark
  a check "Done", cannot add/edit/delete contracts.
- **Admin** (PIN: `Admin1234!`): full access — add/edit/delete contracts, mark
  checks Done, change either PIN.
- Role choice is stored in `localStorage` per-device (not shared). PINs are
  stored in Supabase (shared — same PIN for everyone).
- **This is a soft gate**, not real auth — anyone with the anon key (visible in
  the page source) could technically read/write the table directly. Fine for a
  low-stakes internal tool; would need real backend auth for anything sensitive.

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
- The "Upcoming PM Checks" section and each contract's PM schedule only ever
  show the **next 2** pending checks (not the full list) — this is intentional,
  not a bug or a missing "show more."
- Contracts list is sorted by **start date ascending**.
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
