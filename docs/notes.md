# Project notes

Working notebook for productizing this loader: one warehouse, many split Tally companies, incremental sync, master names rewritten from the latest GUID.

Longer specs stay in their own files. This page is the index of **decisions** and **where to look**.

| Topic | File |
| --- | --- |
| Product / UI / warehouse plan | [productization.md](productization.md) |
| GUID name rewrite (Phase A / B) | [master-name-propagation.md](master-name-propagation.md) |
| Incremental sync as shipped | [incremental-sync.md](incremental-sync.md) |
| Table / report semantics | [data-structure.md](data-structure.md) |
| Schema sketch | [proposed-schema-multi-company.sql](proposed-schema-multi-company.sql) |
| Phase B SQL | [../platform/postgresql/propagate-latest-master-names.sql](../platform/postgresql/propagate-latest-master-names.sql) |

---

## What this codebase is

Local Windows utility. Tally Prime XML on `:9000` → Node (`src/tally.mts`) → one SQL schema. GUI is `gui.html` (config form), not a product. One Tally company per database today.

Upstream: MIT, copyright Dhananjay Gokhale (2021). Commercial use is allowed; keep the original license notice on shipped original files. `package.json` says ISC; `LICENSE` is MIT — MIT is the grant.

---

## Locked decisions

1. **PostgreSQL first** for the multi-slice warehouse. SQL Server second. Not BigQuery for incremental.
2. **Identity is Tally GUID.** Names are display copies.
3. **Rewrite older years from the latest master.** Do not keep FY-local names for reporting.
4. **Latest master** = current slice (`company_slice.is_current`) if that GUID exists there; else newest `books_to` that still has it.
5. **Never** pick a winner with `alterid` or `last_sync_at` across slices. AlterID is per Tally company. A historical reload would look newest and regress names.
6. **Two-phase cascade:** Phase A (`guid` + `slice_id`) during sync; Phase B (`propagate_latest_master_names`) after a current-slice master sync, and again after a rare old-year upload.
7. **Frozen slices:** no Tally edits expected; no cross-slice deletes. Names may still be rewritten.
8. **One writer** per warehouse. Tally XML is not safe to hit in parallel from two companies on one Prime instance.
9. **Local agent + local UI.** Tally stays on the accountant PC. Do not send Tally XML to the cloud.
10. Mapping UI is only for **different GUIDs** (company recreated, not Split).

---

## Vocabulary

| Term | Meaning |
| --- | --- |
| **Legal entity** | The GSTIN / PAN business you report on |
| **Slice** | One Tally company file + its books-from / books-to |
| **Current slice** | The open / latest split (`is_current`) |
| **Frozen slice** | Archived year; uploaded rarely |
| **GUID** | Tally `Guid`; stable inside a company; often **copied** on Split |
| **`_ledger` / `_item` / …** | Hidden GUID FK next to the name column (incremental schema only) |
| **AlterID** | Tally change counter; incremental cursor; **not** comparable across companies |
| **Phase A** | Slice-scoped incremental delete / name update |
| **Phase B** | Entity-wide rewrite of names from the winner GUID |

Split Company ≠ multi-year inside one Tally file. The latter is `--tally-truncate false`. Do not mix those mechanisms.

---

## Incremental (as shipped)

- YAML only (`tally-export-config-incremental.yaml`). JSON collection extract is faster but full-sync only.
- Forces `fromdate` / `todate` to `auto`.
- Cursor lives in `config` (truncated every run) — one company only.
- Deletes: GUID in DB not in `_diff`. Unsafe once two slices share a table.
- Renames: `cascade_update` copies `master.name` onto children via `_guid`.
- Opening bills/batches (`mst_opening_*_allocation`) already exist for split-date pending items.

---

## Engine not done yet

`src/tally.mts` still joins cascade updates on `guid` alone and still truncates `config`. Phase A / B and `slice_id` are spec + SQL only until the warehouse schema lands.

---

## License (product)

MIT allows forking, shipping, and selling a product on top. Keep `LICENSE` / copyright on substantial original code. New UI and warehouse code may be proprietary. This is not a Tally Solutions license; do not imply an official Tally product.
