# FieldProof — V1 Specification

## Problem

Field inspectors record property defects on site, often with poor or no connectivity.
Work is commonly captured on paper or in photo rolls, then retyped later into a report.
This loses time, loses context, and produces inconsistent deliverables.

FieldProof lets an inspector capture a structured punch list with photos on a phone —
including while offline — and produce a professional PDF report, while an administrator
reviews submitted inspections from a web dashboard.

## Actors

| Actor | Description | Trust |
|---|---|---|
| **Anonymous** | Unauthenticated visitor. | No access to any application data. |
| **Inspector** | Authenticated field user. Owns the inspections they create. | Full CRUD on own data only. |
| **Administrator** | Authenticated reviewer. | Read-only across all inspections. Cannot mutate inspector content. |

There is no organization/tenant dimension in V1. Ownership is per-user.

## Core workflows

### W1 — Authenticate
Email + password via Supabase Auth. A `profiles` row is created on signup with role
`inspector`. Role is never client-assignable (see `DECISIONS.md` D4).

### W2 — Create and edit an inspection
Inspector creates an inspection with site/property information (site name, address,
client, inspection date). Status begins as `draft`.

### W3 — Manage punch-list items
Add, edit, delete, and reorder defect items within an inspection. Each item has a title,
optional description and area, a severity (`low` | `medium` | `high` | `critical`) and a
status (`open` | `resolved`).

### W4 — Attach photos
One or more photos per item, uploaded to private Supabase Storage under a path rooted at
the owning inspector's user id.

### W5 — Work offline
An inspection in `draft` status is held in local device storage and is fully editable
without connectivity. Local drafts are never silently discarded.

### W6 — Synchronize
When connectivity returns, local drafts are pushed to Supabase. Push is idempotent —
rows carry device-generated UUID primary keys, so a retried sync cannot duplicate data.
Conflict semantics are defined in `DECISIONS.md` D5.

### W7 — Generate PDF
The inspector generates an inspection report on-device. The PDF contains site/property
information, inspector name, inspection date, and every punch-list item with description,
area, severity, status, and its photographs.

### W8 — History and search
The inspector browses their previous inspections and searches them by site name, address,
or client, backed by a Postgres full-text index.

### W9 — Administrative review
An administrator signs into the Next.js dashboard and reads any inspection, its items and
its photos. Read-only in V1.

## In scope (V1)

- Email/password authentication and per-user profiles.
- Inspection CRUD, punch-list item CRUD with reordering.
- Photo capture and upload to private storage.
- Offline drafting of new inspections and idempotent push sync.
- On-device PDF report generation.
- Inspection history and full-text search.
- Read-only Next.js admin dashboard.
- Row Level Security on every application table and storage bucket, default-deny.
- Automated tests: RLS/database (pgTAP), Flutter unit/widget, admin unit.
- GitHub Actions quality gates and reproducible build artifacts.

## Out of scope (V1)

Explicitly excluded unless approved later:

- AI or chatbot features
- Payments or subscriptions
- Analytics platforms
- Social features
- Organization management or multi-tenancy
- Push or email notifications
- An elaborate design system, or non-trivial animation
- Offline editing of already-synced inspections (see D5)
- Admin write access of any kind (see D3)
- Server-side PDF rendering (see D6)
- Speculative abstractions and premature generalization

## Non-goals

FieldProof is portfolio evidence, not a startup. Feature growth beyond the Definition of
Done in `ACCEPTANCE.md` is out of scope by default.
