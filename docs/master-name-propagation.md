# Safe master-name rewrite across split companies

Locked product rule: **rewrite names on older slices from the latest master.** Identity is GUID. Older Tally files are uploaded rarely and are not edited; a full pass over historical rows after a current-year master change is acceptable.

This document is the safety fix for today’s incremental `cascade_update`, which joins **only** on `guid`:

```sql
update t set t.ledger = s.name
from trn_accounting as t
join mst_ledger as s on s.guid = t._ledger;
```

That is correct for **one** company. With two slices sharing a Tally GUID, the join is 1:N. Which `name` wins is undefined, and a historical re-upload can push old names onto current-year vouchers.

---

## 1. Why `alterid` cannot pick the winner

`AlterID` is per Tally company. FY 2024-25 may sit at `AltMstId = 8000` while the current split sits at `120`. Comparing them across slices is meaningless.

`last_sync_at` is also the wrong winner. A rare full reload of the archived company would look “newest” and regress `Cash in Hand` back to `Cash`.

## 2. Winner rule (latest master)

For each `entity_id` + master type + `guid`, pick **one** source row:

1. The row from the **current** slice (`company_slice.is_current`), if that GUID still exists there.
2. Else the row from the slice with the latest `books_to` that still has the GUID (closed ledger that exists only in history).
3. Tie-break: higher `alterid` **inside that same slice**, then `slice_id`.

Propagation is **one-way: winner → every other slice of that entity.** Never historical → current.

```text
current slice has GUID?  --yes-->  that name is canonical
                         --no--->  newest books_to that still has GUID
```

Manual mapping is only for GUIDs that **differ** across slices (company recreated, not Split). Same GUID never needs a name map.

## 3. Two-phase apply (this is the safety fix)

### Phase A — during sync of **one** slice (hot path)

Scope every delete and name update with **both** `guid` and `slice_id`. Current incremental SQL becomes:

```sql
update t
set t.ledger = s.name
from trn_accounting as t
join mst_ledger as s
  on s.guid = t._ledger
 and s.slice_id = t.slice_id
where t.slice_id = @current_slice_id
  and s.slice_id = @current_slice_id;
```

Rules for this phase:

- `_diff` / `_delete` only see rows of `@current_slice_id`.
- A GUID missing in the current Tally company does **not** delete that GUID from frozen slices.
- Current-slice child names follow current-slice masters only.

### Phase B — after current-slice **master** sync (low frequency)

Run `propagate_latest_master_names(entity_id)` once per successful master import of the current slice, and again after a rare historical reload.

The job:

1. Build a winner set: one `(guid, name)` per master type using the rule in §2.
2. Write `master_identity.canonical_name` from the winner (GUID match, `match_method = guid`).
3. Rewrite `name` on **frozen** `mst_*` rows with that GUID (same entity, other `slice_id`).
4. Rewrite every child name column whose `_guid` column equals that GUID, **all slices of the entity**, only where the stored name differs.
5. Append `master_alias` when a slice-local name changes (audit of previous label).

Do **not** run Phase B after a frozen-slice sync until Phase A of that sync finishes, then run Phase B from the **current** slice winners so a historical reload cannot stick.

## 4. What is rewritten vs what is not

| Rewritten | Not touched |
| --- | --- |
| `mst_*.name` on frozen slices | `guid`, `_ledger`, `_item`, … |
| Child name copies (`trn_accounting.ledger`, …) | Opening / closing balances |
| `trn_voucher.party_name` | Voucher amounts, dates, numbers |
| `master_identity.canonical_name` | Incremental AlterID cursors |
| | Deletes on frozen slices |

A ledger removed in the current company stays in history with the last winner name (fallback rule §2.2). Phase B never cascade-deletes frozen rows.

## 5. When it runs

| Event | Phase A | Phase B |
| --- | --- | --- |
| Incremental / full sync of **current** slice, masters changed | Yes | Yes, after import |
| Incremental of current slice, vouchers only | Slice-scoped voucher work only | Skip |
| Rare full upload of an **old** slice | Slice-scoped load only | Yes, immediately after, winners still from current |
| Polling with no AlterID change | No | No |

Phase B is a set-based UPDATE with `IS DISTINCT FROM` (or `<> OR NULL`). Unchanged names are skipped. Indexes on every `_guid` column plus `(slice_id, guid)` keep a multi-year pass cheap relative to talking to Tally.

## 6. Engine change vs today’s YAML cascade

Keep `cascade_update` in `tally-export-config-incremental.yaml` as the list of child **name** fields. Change the generated SQL to add `slice_id` (Phase A). Drive Phase B from the same list, plus gaps the YAML never had:

- `trn_voucher.party_name` ← `mst_ledger` via `_party_name`
- `mst_opening_bill_allocation.ledger` ← `_ledger`
- `trn_closingstock_ledger.ledger` ← `_ledger`
- `mst_gst_effective_rate.item` ← `_item`
- `mst_opening_batch_allocation.item` ← `_item`
- `mst_payhead.name` ← same GUID as `mst_ledger`
- `mst_employee.name` ← same GUID as `mst_cost_centre`
- `mst_stock_item.alternate_uom` ← `mst_uom` via `_alternate_uom`
- `mst_attendance_type.uom` ← `mst_uom` via `_uom`

`trn_batch.destination_godown` already maps to `_destination_godown` in the current engine (`t._${targetField}`).

## 7. SQL

- PostgreSQL: `platform/postgresql/propagate-latest-master-names.sql`
- SQL Server: `platform/mssql/propagate-latest-master-names.sql`

Call after a current-slice master sync:

```sql
select * from propagate_latest_master_names(:entity_id);
```
