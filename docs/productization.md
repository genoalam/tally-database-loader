# Productization Plan: Multi-Company Warehouse with Incremental Sync

This document is the product and engineering specification extracted from the current `tally-database-loader` codebase. It covers:

1. How the utility works today, with emphasis on **incremental upload**.
2. How to **repackage** it as a product with a real UI, instead of a config-file utility.
3. How to store **multiple split Tally companies in one database**, across different financial-year time frames.
4. How to keep reports correct when **master names change** (ledgers, stock items, groups, godowns, and so on).

The current code is a local Windows utility that talks to Tally Prime over XML and dumps tabular data into SQL Server / MySQL / PostgreSQL / BigQuery / CSV. It is not a multi-tenant warehouse, and it is not a product UI. The design below keeps the existing Tally extraction engine and rebuilds identity, storage, and presentation around it.

---

## 1. What this repo is today

### 1.1 Runtime shape

```mermaid
flowchart LR
    GUI["gui.html on localhost:8997"] --> Server["src/server.mts"]
    CLI["run.bat / dist/index.mjs"] --> Engine["src/tally.mts"]
    Server -->|"fork + CLI flags"| Engine
    Engine -->|"TDL XML POST"| Tally["Tally Prime XML :9000"]
    Engine -->|"CSV then bulk load"| DB["One schema: tallydb"]
    Engine --> Logs["import-log.txt / error-log.txt"]
```

Important facts:

- One process, one `config.json`, one target schema, one Tally company name.
- The GUI is a Bootstrap form that edits `config.json` and streams log lines over WebSocket `:8998`.
- Multi-company today means **one database per company**, driven by `platform/powershell/sync-multiple-company.ps1`.
- Multi-year inside a *single* Tally company is a hidden CLI trick: first year full load, later years `--tally-master false --tally-truncate false`. That is not the same as Tally **Split Company**.

### 1.2 Data model today

Tally is hierarchical. The loader flattens it into:

| Kind | Prefix | Identity |
| --- | --- | --- |
| Master | `mst_*` | `guid` primary key |
| Transaction header | `trn_voucher` | `guid` primary key |
| Transaction lines | `trn_accounting`, `trn_inventory`, … | no own PK; linked by voucher `guid` |

Relationships used by reports are **name-based**, not GUID-based:

```
mst_ledger.name  -->  trn_accounting.ledger
mst_stock_item.name  -->  trn_inventory.item
mst_group.name  -->  mst_ledger.parent
```

That is why renaming a ledger in Tally is a first-class incremental problem: every child row still stores the old name unless it is rewritten.

### 1.3 Two export definitions

| File | Method | Sync modes |
| --- | --- | --- |
| `tally-export-config.yaml` | Report-based TDL | Full |
| `tally-export-config.json` | Collection-based (faster, less RAM) | Full only |
| `tally-export-config-incremental.yaml` | Report-based + `alterid`, `_guid` FKs, cascade rules | Incremental |

Incremental sync **refuses JSON definitions**. Collection-based extraction is the better engine; it is not wired to incremental yet.

---

## 2. Incremental data upload (current implementation)

This is the highest-value existing feature and the hardest one to reuse for split companies without changing identity.

### 2.1 Why it exists

A full sync truncates every table and reloads masters + vouchers for the selected period. On large companies that is slow and RAM-heavy in Tally. Incremental pulls only rows whose Tally `AlterID` is newer than the last successful sync.

### 2.2 Prerequisites

From `docs/incremental-sync.md` and `src/tally.mts`:

1. Recreate the database from `database-structure-incremental.sql` (not the full-sync script).
2. `config.json`:
   - `sync: incremental`
   - `definition: tally-export-config-incremental.yaml`
   - `company` **must** be a real company name (blank = active company, unsafe)
   - `frequency` > 0 to poll Tally every *n* minutes
3. First run is still a full extract of whatever Tally currently holds. Incremental only helps on later runs.
4. Supported targets: SQL Server, MySQL, PostgreSQL. Not BigQuery (UPDATE cost) and not CSV.

### 2.3 Extra columns only present in the incremental schema

Compared with `database-structure.sql`, the incremental schema adds:

- `alterid` on every primary master and on `trn_voucher`
- GUID foreign keys next to every name field: `_parent`, `_ledger`, `_item`, `_godown`, `_uom`, `_voucher_type`, …
- Staging tables: `_diff`, `_delete`, `_vchnumber`
- `config` key/value rows for last AlterIDs

The underscore columns are the **stable identity**. The name columns are the **display copy**, kept in sync by cascade updates.

### 2.4 Algorithm (as implemented)

```mermaid
flowchart TD
    A[Read Last AlterID Master / Transaction from config] --> B[Read current AltMstId / AltVchId from Tally]
    B --> C{Anything changed?}
    C -->|No| Z[Exit]
    C -->|Masters and/or vouchers| D[For each Primary collection: dump guid + alterid into _diff]
    D --> E[GUIDs in DB not in _diff = deleted]
    E --> F[Same GUID, different alterid = modified]
    F --> G[Delete those GUIDs from primary table]
    G --> H[cascade_delete derived tables]
    H --> I[Re-import rows with AlterID greater than last stored]
    I --> J[cascade_update child name fields from master.name via _guid]
    J --> K{Any voucher type uses Automatic numbering?}
    K -->|Yes| L[Refresh all auto voucher numbers]
    K -->|No| M[Write new AlterIDs into config]
    L --> M
```

Concrete SQL (SQL Server flavour, from `src/tally.mts`):

```sql
-- deleted in Tally
insert into _delete
select guid from mst_ledger
where guid not in (select guid from _diff);

-- modified in Tally
insert into _delete
select t.guid from mst_ledger t
join _diff s on s.guid = t.guid
where s.alterid <> t.alterid;

delete from mst_ledger where guid in (select guid from _delete);
delete from trn_accounting where _ledger in (select guid from _delete); -- cascade_delete example

-- after fresh insert of changed masters
update t set t.ledger = s.name
from trn_accounting t
join mst_ledger s on s.guid = t._ledger;
```

The last statement is how **master renames** are handled today: Tally returns the new name on the master row; child tables are rewritten to match.

### 2.5 What incremental does *not* do

These constraints are the reason split-company-in-one-DB cannot be a config tweak:

| Constraint | Effect |
| --- | --- |
| `fromdate` / `todate` forced to `auto` | Whole books, not a FY window |
| Single `config` table, truncated on every save | One company cursor only |
| Deletes are `guid not in _diff` with no company filter | A second company would look like a mass delete of the first |
| Primary keys are `guid` alone | Tally split often **reuses master GUIDs** across the old and new company |
| `opening_balance` lives on `mst_ledger` | Each split year has its own opening; last write wins |
| YAML-only | Cannot use the faster JSON extractor |
| Manual DELETE/TRUNCATE of warehouse tables | Breaks the AlterID cursor |
| Recommended: one FY per incremental company | Matches Tally split practice, but the loader still stores only one company |

Polling (`frequency`) compares in-memory AlterIDs and skips Tally export when nothing moved. Continuous sync also refuses to start if `company` is blank.

### 2.6 Opening allocations: already a split-company artefact

Release 1.0.8 added `mst_opening_bill_allocation` and `mst_opening_batch_allocation` specifically for **pending bills and batches as on the split date**. Bills receivable/payable reports already union those opening rows with `trn_bill`. That is the correct pattern for one split slice. It becomes wrong if two slices share one ledger table without a company key: openings from FY 2024-25 would mix with openings from FY 2025-26.

---

## 3. Productization: repackage as a product UI

### 3.1 Why the current GUI is not a product

`gui.html` is a single 640px form: database credentials, Tally host, one company, one period, Sync / Abort. Gaps:

- No saved list of companies or split timeline.
- No sync history, row counts per table, or last successful cursor.
- Frequency is collected in the form but `prepareConfigObj()` currently reads frequency from the sync-mode dropdown, so GUI-driven polling is broken.
- Passwords land in `config.json` on disk if the user clicks Save.
- Windows-only launcher (`run-gui.bat`, `child_process.exec('start http://...')`).
- The process exits when the browser tab closes.
- Reports live as raw `.sql` files; the UI never runs them.
- No mapping screen for renamed masters.

### 3.2 Product shape that fits Tally

Tally XML is almost always on the accountant's PC. This should stay a **local agent + local web UI**, not a cloud-only SaaS that cannot reach Tally.

Recommended packaging:

| Layer | Role |
| --- | --- |
| **Agent** | Existing Node engine (`tally.mts` / `database.mts`), run as a Windows service or tray app |
| **App UI** | Local web app (desktop shell optional: Tauri/Electron) on `127.0.0.1` |
| **Warehouse** | One PostgreSQL (preferred) or SQL Server database per customer / CA firm, many companies inside it |
| **Optional cloud** | Read replica / BigQuery / MotherDuck for dashboards, fed by the warehouse, never by live Tally |

Do not put Tally credentials or XML in the cloud. Sync always originates on the machine where Tally Prime is licensed.

### 3.3 UI information architecture

```text
Workspace
├── Connections          database + Tally XML endpoint
├── Entities             legal entities (GSTIN / PAN)
│   └── Company slices   each Tally company + books-from/to
│       ├── Sync         full / incremental, schedule, logs
│       └── Masters      identity + rename review
├── Jobs                 queue, last run, errors, Abort
├── Explore              ledgers, vouchers, trial balance
└── Reports              TB, P&amp;L, registers, ageing — filtered by entity and period
```

Primary screens:

1. **Setup wizard** — detect Tally on `:9000`, list open companies, test DB, create warehouse schema.
2. **Company timeline** — a Gantt-style list of slices: `Acme Pvt Ltd (to 31-Mar-2025)` then `Acme Pvt Ltd (from 01-Apr-2025)`. User marks “this is a split of that”.
3. **Sync console** — per-slice progress (masters vs vouchers, table row counts), not a raw log dump as the only view. Keep the log as a drawer.
4. **Master mapping** — unmatched / renamed / merged ledgers and items across slices. This is the product feature that makes multi-year reports possible.
5. **Period explorer** — pick entity + from/to; run the existing SQL reports against GUID-joined views.

Visual direction: drop Bootstrap 5 form chrome. Use a dense operations UI (sidebar + table + inspector). Shadcn/Radix + a simple local API is enough; the value is the domain model, not a marketing landing page.

### 3.4 Agent API (replace ad-hoc HTTP in `server.mts`)

Keep the engine, replace the protocol:

| Method | Purpose |
| --- | --- |
| `GET /tally/status` | Prime running? version? |
| `GET /tally/companies` | Open companies, books-from, AlterIDs |
| `POST /slices` | Register a Tally company as a warehouse slice |
| `POST /slices/:id/sync` | Full or incremental, scoped to that slice |
| `POST /slices/:id/abort` | Kill the child process |
| `GET /jobs/:id` | Status + log cursor |
| `GET /entities/:id/masters?unmapped=1` | Mapping work queue |
| `POST /masters/map` | Manual GUID / name links |

Config should move from a single `config.json` to:

- encrypted connection secret store
- `company_slice` + `sync_state` tables in the warehouse

CLI flags stay for unattended Task Scheduler jobs.

---

## 4. Multiple split companies in one database

### 4.1 Tally split, in warehouse terms

When books are split on (say) 01-Apr-2025:

| Slice | Typical Tally name | Contents |
| --- | --- | --- |
| Historical | `Acme Pvt Ltd` or `Acme Pvt Ltd FY 2024-25` | Vouchers up to 31-Mar-2025, masters as they stood in that company |
| Current | `Acme Pvt Ltd from 01-Apr-2025` | Opening balances + bills/batches as on split date, vouchers from 01-Apr-2025 |

Facts that break the current schema:

1. **Master GUIDs are often copied** into the new company. `guid` is unique *inside* a Tally company, not across split companies. A single-column PK collides.
2. **Voucher GUIDs are new** in the new company. Transaction tables can coexist if prefixed by company, but masters cannot.
3. **Names drift independently** after the split. “Cash” in FY24 may be “Cash in Hand” in FY25, same GUID or not.
4. **Opening balances are per slice.** Loading the new company over the old `mst_ledger` row overwrites FY24 opening with FY25 opening.
5. **AlterID is per Tally company.** Incremental cursors cannot be shared.
6. Company **names themselves change** (`… FY 2024-25` vs `… from 01-Apr-2025`). The loader already keys off `tally.company` string equality.

### 4.2 Target identity model

```mermaid
erDiagram
    legal_entity ||--|{ company_slice : splits
    company_slice ||--|{ sync_state : cursor
    legal_entity ||--|{ master_identity : canonical
    master_identity ||--|{ master_alias : names
    company_slice ||--|{ mst_ledger : slice_masters
    company_slice ||--|{ trn_voucher : slice_vouchers
    master_identity ||--o{ mst_ledger : resolves
```

**`legal_entity`** — the business the CA actually reports on (GSTIN / PAN / group name).

**`company_slice`** — one open Tally company, one books interval, one incremental cursor.

**`master_identity`** — one row per real-world ledger/item/group across slices.

**`master_alias`** — every name/alias seen, with the slice and time it was observed.

All existing `mst_*` / `trn_*` tables gain `slice_id`. Primary keys become `(slice_id, guid)` for tables that currently use `guid`. Line tables become `(slice_id, guid, …)`. Every incremental DELETE/UPDATE is `WHERE slice_id = ?`.

### 4.3 Proposed core tables

See `docs/proposed-schema-multi-company.sql` for a PostgreSQL sketch. The minimum additive set:

```text
legal_entity (id, name, gstn, pan, canonical_name)
company_slice (
  id, entity_id,
  tally_guid, tally_name,
  books_from, books_to,
  parent_slice_id,          -- previous FY / split source
  sync_mode                 -- full | incremental
)
sync_state (
  slice_id,
  last_alterid_master,
  last_alterid_transaction,
  last_sync_at,
  last_status
)
master_identity (
  id, entity_id,
  master_type,              -- ledger | group | stock_item | godown | ...
  stable_guid,              -- Tally GUID when it is the same across splits
  canonical_name,
  match_method              -- guid | gstn | alias | manual | unmatched
)
master_alias (
  identity_id, slice_id, name, alias, observed_at
)
```

Then, for example:

```text
mst_ledger  PK (slice_id, guid)
            identity_id nullable FK  -- filled by matcher
            name, _parent, opening_balance, ...   -- slice-local

trn_accounting  (slice_id, guid, _ledger, amount, ...)
```

Warehouse joins use `trn_accounting._ledger` → GUID **and** `slice_id`. After Phase B, name columns match the latest master, so Excel / Power BI grouping by `ledger` stays correct across years.

### 4.4 How a split year is ingested

1. User registers slice A: Tally company `Acme Pvt Ltd`, period auto or to 31-Mar-2025. Full sync into `slice_id=A`.
2. User registers slice B: Tally company `Acme Pvt Ltd from 01-Apr-2025`, marks parent = A. Full sync into `slice_id=B`.
3. Matcher runs:
   - Same Tally GUID + same master type → same `master_identity` (usual split case).
   - Else GSTIN / PAN / bank account for ledgers; HSN + part number for items; case-folded alias.
   - Remainder goes to the mapping UI.
4. Incremental thereafter is **per slice**. Only the open current-year company is typically polled. Historical slices are frozen unless the user re-opens that Tally company.

Do not use `--tally-truncate false` across two Tally companies. That flag is only for multiple years **inside one company file**.

### 4.5 Period rules

- Store `books_from` / `books_to` on the slice from Tally (`BooksFrom`, last voucher date).
- Reject overlapping voucher dates for two slices of the same entity unless the user explicitly allows it (rare: partial recast).
- Cross-year P&amp;L / trial balance:
  - Use opening balances **only from the earliest slice**.
  - Use `mst_opening_bill_allocation` / `mst_opening_batch_allocation` **only from the slice that owns that opening** (usually the later split).
  - Sum `trn_*` across slices in range, joined through `master_identity`.
- Incremental remains `fromdate=auto` **inside that Tally company**. The warehouse period filter is applied at query time, not at Tally export time.

### 4.6 Incremental engine changes required

All of these are in `src/tally.mts` / `src/database.mts`:

1. Stop truncating `config`. Use `sync_state` keyed by `slice_id`.
2. Stamp every extracted row with `slice_id` before bulk load (CSV extra column, or `ALTER TABLE` default + session setting).
3. Scope `_diff` / `_delete` comparisons: `guid not in _diff` **and** `slice_id = current`.
4. Scope cascade_update / cascade_delete with **both** `guid` and `slice_id` (Phase A). Never join child → master on `guid` alone.
5. Do not treat a reused master GUID from another slice as a collision; PK includes `slice_id`.
6. Keep `_diff` / `_delete` / `_vchnumber` global staging tables but always truncated and filled for one slice at a time (single-writer queue).
7. After a **current-slice** master import, run `propagate_latest_master_names(entity_id)` (Phase B) so frozen years pick up the new names. See [master-name-propagation.md](master-name-propagation.md).

Until those exist, loading a second company into the same schema will either unique-key-fail or silently delete the first company’s rows.

---

## 5. Master names that have changed

**Locked:** rewrite older slices from the latest master. Identity is GUID. Full algorithm: [master-name-propagation.md](master-name-propagation.md).

Tally stores the **current** master name on vouchers. Incremental YAML already rewrites child name columns via `cascade_update` inside one company. Across split companies that join is unsafe: two `mst_ledger` rows can share a GUID, so `join on guid` is 1:N.

### 5.1 Safety fix (two phases)

**Phase A (hot path, current slice only).** Add `slice_id` to every cascade join:

```sql
update t set t.ledger = s.name
from trn_accounting as t
join mst_ledger as s
  on s.guid = t._ledger
 and s.slice_id = t.slice_id
where t.slice_id = @current_slice_id;
```

Deletes are also `slice_id = current`. A GUID missing in this year’s Tally file must not delete last year’s rows.

**Phase B (low frequency, whole entity).** After a current-slice master sync, pick one winner name per GUID and stamp it on every slice:

1. Prefer the **current** slice’s master row if that GUID still exists there.
2. Else the slice with the latest `books_to` that still has the GUID.
3. Do **not** use `alterid` or `last_sync_at` across slices (`alterid` is per Tally company; a rare historical reload would look “newest” and regress names).

Then rewrite frozen `mst_*.name` and all child name copies (`trn_accounting.ledger`, `trn_voucher.party_name`, …) where `_guid` matches. Skip rows whose name is already equal. Keep GUID columns and balances untouched.

A historical reload is allowed: load that slice (Phase A), then immediately run Phase B from **current** winners so old Tally names cannot stick.

### 5.2 GUID merge vs name map

| Signal | Action |
| --- | --- |
| Same Tally GUID across slices | Auto-link. Phase B supplies the name. No mapping UI. |
| GUID missing in current, present in history | Keep last winner name (newest `books_to`). Do not delete history. |
| Different GUIDs (company recreated) | GSTIN / alias / manual map. GUID-only cannot merge these. |

`master_identity.canonical_name` is written from the Phase B winner. `master_alias` records the previous slice-local label when a rewrite happens.

### 5.3 What not to do

- Do not join child → master on `guid` without `slice_id` (Phase A) or without a winner set (Phase B).
- Do not delete frozen-slice masters because they are absent from the current company’s `_diff`.
- Do not let a frozen-slice sync drive Phase B winners.
- Do not assume GUID equality when a company was **recreated** instead of Split.

---

## 6. Packaging and delivery

### 6.1 Keep

- TDL generation from YAML (and later, JSON incremental).
- GUID extraction (`$Guid:Collection:$Name` expressions already in the incremental YAML).
- Bulk load paths (`insert` vs `file`).
- Report SQL as the analytics contract — rewrite them onto views, do not invent a new metric engine first.
- Open-source MIT engine.

### 6.2 Change

| Today | Product |
| --- | --- |
| Zip + `run.bat` | Signed installer or `npx`/portable folder + Windows service |
| `config.json` | UI + encrypted secrets + warehouse metadata |
| One schema per company | One warehouse, many slices |
| `gui.html` | App shell with company timeline and mapping |
| PowerShell loop | Job queue inside the agent |
| Docs as the only “reports UI” | In-app SQL runner / export to Excel / Power BI views |

### 6.3 Suggested implementation sequence

Work is ordered by dependency, not by calendar.

1. **Warehouse identity** — `legal_entity`, `company_slice`, `sync_state`; add `slice_id` to every table; composite keys; views that restore today’s single-company report SQL.
2. **Scoped incremental** — filter `_diff` / `_delete` / cascade SQL by `slice_id`; stop truncating global `config`.
3. **Ingest second slice** — register split, full load without wiping slice 1; prove trial balance per slice.
4. **Phase B name rewrite** — `propagate_latest_master_names`; mapping UI only for non-matching GUIDs.
5. **Product UI** — wizard, timeline, job console, log drawer; retire `gui.html` as the primary surface.
6. **JSON incremental** — reuse collection extractor with AlterID filters so large current-year companies stay fast.
7. **Hardening** — single-writer job queue, Tally-not-open handling (already partially present), backup-before-full-sync.

Step 1–4 are the actual product. Step 5 without 1–4 is a prettier way to corrupt a database.

---

## 7. Source map (where to change code)

| Concern | Files |
| --- | --- |
| Incremental algorithm | `src/tally.mts` (`importData` when `sync == 'incremental'`) |
| AlterID polling | `src/index.mts`, `tally.updateLastAlterId()` |
| Cascade rules | `tally-export-config-incremental.yaml` (`cascade_update`, `cascade_delete`) |
| Schemas | `database-structure-incremental.sql`, `platform/*/database-structure-incremental.sql` |
| Company cursor | `tally.saveCompanyInfo()` writes `config` |
| GUI / local server | `gui.html`, `src/server.mts` |
| Multi-company today | `platform/powershell/sync-multiple-company.ps1`, `docs/commandline-options.md` |
| Split openings | `mst_opening_bill_allocation`, `mst_opening_batch_allocation`, `reports/*/bills-*.sql` |
| Name rewrite across slices | `docs/master-name-propagation.md`, `platform/postgresql/propagate-latest-master-names.sql`, `platform/mssql/propagate-latest-master-names.sql` |

---

## 8. Decisions to lock before implementation

1. **PostgreSQL first** for the multi-slice warehouse (JSON matcher state, cheaper updates). Keep SQL Server as a second target; do not start with BigQuery.
2. **GUID-first identity.** Latest master name (current slice) is rewritten onto older slices. Canonical name follows that winner.
3. **One writer** to a warehouse at a time (queue). Tally XML is not safe for parallel companies on one Prime instance anyway.
4. Historical slices are **frozen for Tally edits and deletes**. Names are rewritten from the current master after each current-slice master sync, and again after a rare historical reload.
5. Reports can keep grouping by name after Phase B. Joins for warehouse logic still use GUID + `slice_id`.
