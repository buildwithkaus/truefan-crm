# Business context

**TrueFan** (truefan.ai) — celebrity-fronted brand content platform. Businesses buy
packages like "Brand promotional video + Celebrity photo rights" (see the 5 SKUs in
`mx_Selected_Product` on Lead). Segments: B2B and B2C (`mx_Business_Model`). An "AI for
Business" product line runs through the same pipeline (Source values like
`Website-ai-for-business`, `ad-ai-for-business`; a `Does not want AI` disqualification
reason; `AI Phone Call / Follow Up` activity type).

## The diagnosis that started this project

The CRM has one object (Lead) doing three jobs: who the person is, what stage the
*company relationship* is at, and what the outcome of the *last call* was, all crammed
into a single 26-value `ProspectStage` field. That's why reps historically maintained
personal pipeline sheets — the system couldn't answer "what's my account list and where
does each stand," so that view got rebuilt by hand, per rep, out of band.

## Prior plans (context, not in this repo)

Two emails from Kaustubh Chauhan (Founder's Office) to Mehak Dhar, both 2026-07-24,
both approved:

1. **"New SMB Outreach Model"** — shift outbound from contact-level/volume-based to
   account-level. Build a Target Account List (TAL) of ICP-fit companies, tiered/scored,
   assign accounts (not leads) to reps (~500 accounts/rep/month), give reps full channel
   flexibility, shift focus upstream to account research and buying-committee mapping,
   allow "no need today" to be revisited rather than treated as dead.
2. **"Pipeline Centralization in LSQ"** — replace manual rep sheets with LSQ-native
   pipeline tracking. Diagnosed the same stage-field overload problem. Proposed splitting
   into Contact Lifecycle Stage / Call Disposition / Company-Opportunity stage. Noted the
   Opportunity object was completely unused and Company stage (Prospect/Opportunity/
   Customer) was too coarse.

This repo is the execution of both, unified into one data model + migration.

## ICP / TAL status (as of 2026-07-27)

A GTM engineer is building the TAL from ICP rules Kaustubh already gave him. Most target
companies **already exist** in LSQ's Company object — the work is enrichment (Industry,
Revenue, Employees — currently ~0% filled, see `02-company-schema-audit.md`), not sourcing
net-new companies. Do not build a separate/parallel account-sourcing process — enrich what
exists.

## Team

18 confirmed active sales reps (see `04-active-rep-roster.md`). Reassignment of departed
reps' books to Admin was executed 2026-07-27 (see `05-departed-owner-reassignment.md`).
