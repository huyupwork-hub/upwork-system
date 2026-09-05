# Public demo

Everything below runs against the same hosted Supabase project the CI gates run
against. There is no demo backend, no seeded fake API, and no relaxed security:
the review console and the phone are two clients of one database, and Row Level
Security decides what each of them may see.

---

## Web — review console

**https://upwork-system-thun-viet.vercel.app**

```
fieldproof-demo-admin@yopmail.com
DemoAdmin2026!
```

An **admin**. Admins are read-only by policy and see submitted work only — an
inspector's drafts are invisible to them, including to this account.

## Android — field capture

**[Download the APK](https://github.com/huyupwork-hub/upwork-system/releases/tag/v0.1.0-demo.2)**
· `sha256 2d1d0fdcd79269342c3bf91dbbdad2ca28eef9f37d2eb74af18176e274a12f3a`
· built from the same commit as the console (`76339db`)

```
fieldproof-demo-inspector@yopmail.com
DemoInspector2026!
```

An **inspector**. Sideload; Android will warn about an unknown developer, which
is what it says about any self-signed build.

---

## What to look at, in the order it makes sense

**1. The console lists submitted inspections only.** Three of them — plus one
`SMOKE run… do-not-keep` row per hosted smoke execution, which the cleanup job cannot
delete for the reasons in `DEPLOY.md` §5; test residue rather than demo content. Search across
site, address and client: `northgate` matches a site, `bristol` matches an
address, and `meridian` matches two different inspections — one by site, one by
client.

**2. Open one.** Punch items carry severity and open/resolved state; photographs
render through short-lived signed URLs, because the storage bucket is private and
has no public path. Under the facts is **PDF report** — the document the phone
rendered when the inspection was submitted, downloaded through a 10-minute signed
URL from a private bucket. The console did not generate it and cannot replace it.
Where no report has been uploaded yet, the console says exactly that rather than
showing nothing.

**3. Sign into the console as the *inspector* instead.** You are refused and sent
to `/no-access`, with nothing rendered. That refusal is two independent layers:
an authorisation gate in the app, and RLS in the database. Removing the gate
leaks nothing; removing RLS leaks everything.

**4. On the phone, sign in as the inspector.** You now see a draft the console
could not: `Cavendish House`. Same database, same row, different reader.

**5. Turn on airplane mode and create an inspection.** It is kept on the device,
marked **Not synced**, and the banner says only local drafts are being shown —
nothing server-backed is cached, so the app tells you what is missing rather than
implying the list is complete.

**6. Force-stop the app and reopen it, still offline.** The draft and its items
are still there.

**7. Reconnect and press Retry.** The draft syncs once and appears exactly once.
The push is an upsert on a key the device generated before the first attempt, so
a retry cannot create a second row.

**8. Submit it.** Submit is only offered *after* the draft has synced —
submission stamps `submitted_at` server-side and freezes the record, and the app
will not claim locally something no server has agreed to. The phone then renders
the PDF and uploads it once; reopen the inspection in the console and the report
is there. If the upload fails the phone says so and offers it again — the
submission itself is already permanent.

---

## Deployed commit

| | |
|---|---|
| Commit | `76339db` on `main`, 2026-09-05 — the commit `v0.1.0-demo.2` is built from |
| Supabase | hosted project `dkgrpoudebqvtpxdetdg`, region `ap-south-1` |
| Keys in the browser | the publishable key only. The app refuses to start with a privileged one |

**How the commit is known.** Merging PR #6 produced a git-triggered production
deployment, `dpl_44uJ3krZS6oZHgDj9cCmjDCWVyu2`, whose `gitSource` records `76339db`; the
public URL resolves to it. Its tree, `942bb45b`, is the tree the APK in `v0.1.0-demo.2`
was built from. The deployment before it (`dpl_7mY5ksjdvqk8jC9NqZtRWuQpKPRh`, 2026-09-02)
was a git build of `6fc2ee5`; the previous version of this page called that unknown because
`vercel inspect` hides git metadata. Details in `DEPLOY.md` §4 and §6.

## Known limitations, deliberately not fixed

- **Offline photo capture** (`E1b`). Drafts and punch items work offline;
  attaching a photo does not. Deferred with its reasoning in `DECISIONS.md` D27.
- **~30 s cold start when opened offline** (`L2`). The history waits for the
  profile lookup to fail before rendering. No data is at risk — it is latency,
  not correctness.
- **iOS is unverified** (`L2` in `ACCEPTANCE.md`). It needs a macOS runner, which
  this project has never had.
- **Production is deployed by pushing to `main`.** It always was; an earlier version of
  this page said auto-deploy was off, which Vercel's own deployment record contradicts.
  Hand deploys are possible but ship the whole checkout, so `DEPLOY.md` §4 sets the
  conditions.
- **Reports exist only for inspections submitted from `v0.1.0-demo.3` or later.** The
  three demo inspections get theirs from the demo inspector's phone (`DEPLOY.md` §7) —
  the same product path, one tap on the Reports tab — and until that tap each reads
  *No PDF report has been uploaded for this inspection yet* in the console. An
  inspection submitted from the older build shows the same until its owner taps
  **Upload** on the Reports tab; nothing uploads by itself.

## Demo credentials are published on purpose

Both accounts above are meant to be shared, and the project holds only demo data.
The blast radius is bounded by the same policies the product relies on: the admin
account can read submitted inspections and write nothing at all, and the inspector
account can reach only its own rows. That is the point of publishing them — the
security model is the thing worth reviewing, so it should be possible to push
against it.
