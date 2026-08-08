# Excel dashboard - SMB Centralized Dashboard

Live-ish Excel workbook on OneDrive, pulling from Supabase with Power Query. Native
PivotTables, so rep / stage / disposition can be re-sliced without a code change.

Same views the Google Sheet reads, so the two cannot disagree about what "connected" means.

---

## Before you start: which key goes in the workbook

**Use the `anon` key. Never the `service_role` key.**

The workbook gets shared, so whatever key it carries is handed to everyone who opens it -
and a Power Query key is stored in plain text inside the file. `service_role` bypasses row
level security and grants full write access to the database.

Migration `004_excel_and_cutover.sql` grants `anon` SELECT on the aggregate views only. Base
tables stay unreachable, and `fact_call` is deliberately not granted because it carries phone
numbers and recording URLs. A leaked workbook then exposes aggregates and nothing more.

Get it from: Supabase > Project Settings > API > Project API keys > `anon` `public`.

---

## Setup, once

### 1. Two parameters

Data > Get Data > Launch Power Query Editor > Manage Parameters > New:

| Name | Type | Current value |
|---|---|---|
| `SupabaseUrl` | Text | `https://<your-project-ref>.supabase.co/rest/v1/` |
| `SupabaseKey` | Text | your **anon** key |

Parameters rather than inline literals so the key is changed in one place when it rotates.

### 2. A shared fetch function

New Source > Blank Query > Advanced Editor. Name it **`fnSupabase`**:

```m
let
    fnSupabase = (view as text, optional queryOptions as record) as table =>
        let
            opts  = if queryOptions = null then [] else queryOptions,
            query = Record.AddField(opts, "select", "*"),
            raw   = Web.Contents(
                SupabaseUrl,
                [
                    // RelativePath + Query, NOT string concatenation. Power Query refuses to
                    // refresh a query whose URL is built dynamically ("the query references
                    // other queries, so it may not directly access a data source") and this
                    // is the form that stays refreshable.
                    RelativePath = view,
                    Query        = query,
                    Headers      = [
                        apikey        = SupabaseKey,
                        Authorization = "Bearer " & SupabaseKey,
                        // PostgREST caps rows at 1000 unless asked otherwise.
                        #"Range-Unit"  = "items",
                        Range          = "0-99999"
                    ]
                ]
            ),
            json = Json.Document(raw),
            tbl  = Table.FromList(json, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
            cols = if Table.IsEmpty(tbl) then tbl
                   else Table.ExpandRecordColumn(tbl, "Column1", Record.FieldNames(tbl{0}[Column1]))
        in
            cols
in
    fnSupabase
```

### 3. One query per view

New Source > Blank Query > Advanced Editor for each. Load each to a **Table** on its own
sheet (or Connection Only for the ones you only pivot).

**`Pivot`** - the source for the main PivotTable:
```m
let
    Source  = fnSupabase("v_pivot_disposition", [order = "call_date_ist.desc"]),
    Typed   = Table.TransformColumnTypes(Source, {
        {"call_date_ist", type date}, {"rep", type text}, {"contact_stage", type text},
        {"disposition", type text}, {"calls", Int64.Type}, {"contacts", Int64.Type},
        {"connects", Int64.Type}, {"talk_min", type number},
        {"disposition_not_selectable", type logical}
    })
in
    Typed
```

**`RepDay`**:
```m
let
    Source = fnSupabase("v_rep_day", [order = "report_date.desc,dials.desc"])
in
    Source
```

**`DailyTotals`** - the month view:
```m
let
    Source = fnSupabase("v_daily_totals", [order = "report_date.desc"])
in
    Source
```

**`Funnel`**:
```m
let
    Source = fnSupabase("v_funnel_movement", [order = "report_date.desc"])
in
    Source
```

**`Exceptions`** - the hygiene worklist:
```m
let
    Source = fnSupabase("v_hygiene_exceptions", [order = "severity.asc,rep.asc"])
in
    Source
```

**`Health`** - put this somewhere visible:
```m
let
    Source = fnSupabase("v_pipeline_health")
in
    Source
```

### 4. Build the PivotTable

Insert > PivotTable > From Data Model / from the `Pivot` table:

- **Rows**: `rep`, then `contact_stage`
- **Columns**: `disposition`
- **Values**: Sum of `calls`
- **Filters**: `call_date_ist`

That is the matrix - for each rep and each stage, how many calls and with what outcome.
Swap Values to `connects` or `talk_min` for the same cut on a different measure.

Add slicers for `call_date_ist` and `rep` (PivotTable Analyze > Insert Slicer) so the whole
sheet re-slices with one click.

### 5. Refresh

Data > Queries & Connections > right-click each query > Properties:
- **Refresh data when opening the file**
- **Refresh every 15 minutes** (only ticks while the workbook is open)

---

## What "live" actually means here

**Refresh runs in desktop Excel, on the machine that has the file open.** Excel Online in a
browser cannot refresh a Power Query that sends custom headers, so viewers see whatever was
last saved.

In practice: keep the workbook open on your laptop during the day and it refreshes itself;
OneDrive syncs the values out to everyone else. Close the laptop and the numbers freeze at
the last refresh - which is why the **Health** query matters. Put
`minutes_since_last_ingest` somewhere prominent so a frozen sheet is obvious rather than
mistaken for a quiet afternoon.

If refresh has to happen without your machine, that is Power Automate: a scheduled cloud
flow calling the same Supabase URLs and writing rows through the Excel Online connector.
More setup and a licence, but no laptop dependency.

The Google Sheet stays as the always-on monitor for exactly this reason - it refreshes every
10 minutes with nothing open anywhere.

---

## Reading the numbers honestly

**Disposition is blank before 2026-08-08.** It shows `<no history>`, and that is deliberate.
`mx_Call_Disposition` is a lead field holding only its current value - LeadSquared keeps no
history - so for any call before the field-change webhooks went live, the disposition that
applied at the time is genuinely unrecoverable. Showing today's value against a call from
1 August would be wrong for every contact worked more than once.

**Stage is exact all the way back.** `EventCode 3002` records each transition with a
timestamp and the backfill loads the full history, so "stage at time of call" is a real
reconstruction rather than an approximation.

**A `*` on a disposition** means the value is stored in LeadSquared but is not a selectable
dropdown option - reps cannot filter on it, and it is usually a sign of a newly-invented
value drifting into the funnel.

**Clean % next to Contradicts.** A jump in Clean % straight after a batch cleanup means
someone re-staged a backlog, not that the team started dispositioning properly. The two
columns have to be read together.
