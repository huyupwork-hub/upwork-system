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

**[Download the APK](https://github.com/huyupwork-hub/upwork-system/releases/tag/v0.1.0-demo)**
· `sha256 1676c8d48d4ca5c825d865fe5bec62bc62708319818e8ddf990e8c839b0b557f`

```
fieldproof-demo-inspector@yopmail.com
DemoInspector2026!
```

An **inspector**. Sideload; Android will warn about an unknown developer, which
is what it says about any self-signed build.

---

## What to look at, in the order it makes sense

**1. The console lists submitted inspections only.** Three of them. Search across
site, address and client: `northgate` matches a site, `bristol` matches an
address, and `meridian` matches two different inspections — one by site, one by
client.

**2. Open one.** Punch items carry severity and open/resolved state; photographs
render through short-lived signed URLs, because the storage bucket is private and
has no public path.

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
will not claim locally something no server has agreed to.

---

## Deployed commit

| | |
|---|---|
| Commit | `f12d71d` on `main` |
| CI | [run 33500750773](https://github.com/huyupwork-hub/upwork-system/actions/runs/33500750773) — six gates green |
| Supabase | hosted project `dkgrpoudebqvtpxdetdg`, region `ap-south-1` |
| Keys in the browser | the publishable key only. The app refuses to start with a privileged one |

## Known limitations, deliberately not fixed

- **Offline photo capture** (`E1b`). Drafts and punch items work offline;
  attaching a photo does not. Deferred with its reasoning in `DECISIONS.md` D27.
- **~30 s cold start when opened offline** (`L2`). The history waits for the
  profile lookup to fail before rendering. No data is at risk — it is latency,
  not correctness.
- **iOS is unverified** (`L2` in `ACCEPTANCE.md`). It needs a macOS runner, which
  this project has never had.
- **Vercel auto-deploy is off.** The Vercel account is not linked to the GitHub
  identity that authors the commits, so Git-triggered builds are blocked;
  production is deployed explicitly instead.

## Demo credentials are published on purpose

Both accounts above are meant to be shared, and the project holds only demo data.
The blast radius is bounded by the same policies the product relies on: the admin
account can read submitted inspections and write nothing at all, and the inspector
account can reach only its own rows. That is the point of publishing them — the
security model is the thing worth reviewing, so it should be possible to push
against it.
