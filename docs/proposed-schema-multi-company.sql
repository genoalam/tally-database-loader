-- PostgreSQL sketch: multi-slice Tally warehouse
-- Not wired into the loader yet. Illustrates identity + incremental scoping.
-- Existing mst_* / trn_* columns stay; every table gains slice_id.

create table legal_entity (
    id              uuid primary key,
    name            text not null,
    canonical_name  text not null,
    gstn            text,
    pan             text,
    created_at      timestamptz not null default now()
);

create table company_slice (
    id                  uuid primary key,
    entity_id           uuid not null references legal_entity (id),
    tally_guid          text,
    tally_name          text not null,
    books_from          date,
    books_to            date,
    parent_slice_id     uuid references company_slice (id),
    sync_mode           text not null default 'full' check (sync_mode in ('full', 'incremental')),
    is_current          boolean not null default false,
    notes               text,
    created_at          timestamptz not null default now()
);

create unique index uq_slice_tally_name on company_slice (entity_id, tally_name);

create table sync_state (
    slice_id                    uuid primary key references company_slice (id),
    last_alterid_master         bigint not null default 0,
    last_alterid_transaction    bigint not null default 0,
    last_sync_at                timestamptz,
    last_status                 text,
    last_error                  text,
    row_counts                  jsonb
);

create table master_identity (
    id              uuid primary key,
    entity_id       uuid not null references legal_entity (id),
    master_type     text not null,  -- ledger | group | stock_item | godown | uom | vouchertype | ...
    stable_guid     text,           -- Tally GUID when preserved across split
    canonical_name  text not null,
    match_method    text not null default 'unmatched'
                    check (match_method in ('guid', 'gstn', 'alias', 'name', 'manual', 'unmatched')),
    created_at      timestamptz not null default now(),
    unique (entity_id, master_type, stable_guid)
);

create table master_alias (
    identity_id     uuid not null references master_identity (id),
    slice_id        uuid not null references company_slice (id),
    name            text not null,
    alias           text,
    observed_at     timestamptz not null default now(),
    primary key (identity_id, slice_id, name)
);

-- Staging remains process-global; always used for one slice at a time.
create table _diff (
    guid        text not null,
    alterid     int
);

create table _delete (
    guid        text not null
);

create table _vchnumber (
    guid            text not null,
    voucher_number  text
);

-- Example fact table. Repeat the slice_id + composite key pattern for every mst_/trn_ table.
create table mst_ledger (
    slice_id            uuid not null references company_slice (id),
    guid                text not null,
    identity_id         uuid references master_identity (id),
    alterid             int,
    name                text,
    parent              text,
    _parent             text,
    alias               text,
    opening_balance     numeric(17,2),
    closing_balance     numeric(17,2),
    gstn                text,
    it_pan              text,
    primary key (slice_id, guid)
);

create table trn_voucher (
    slice_id                uuid not null references company_slice (id),
    guid                    text not null,
    alterid                 int,
    date                    date,
    voucher_type            text,
    _voucher_type           text,
    voucher_number          text,
    is_order_voucher        smallint,
    is_inventory_voucher    smallint,
    is_accounting_voucher   smallint,
    primary key (slice_id, guid)
);

create table trn_accounting (
    slice_id        uuid not null references company_slice (id),
    guid            text not null,
    ledger          text,
    _ledger         text,
    amount          numeric(17,2)
);

create index ix_trn_accounting_slice_voucher on trn_accounting (slice_id, guid);
create index ix_trn_accounting_slice_ledger on trn_accounting (slice_id, _ledger);

-- Cross-year reporting: names come from identity, amounts from the slice that owns the voucher.
create or replace view v_accounting as
select
    s.entity_id,
    a.slice_id,
    v.date,
    coalesce(i.canonical_name, l.name) as ledger,
    a.amount,
    v.voucher_number,
    v.is_order_voucher,
    v.is_inventory_voucher
from trn_accounting a
join trn_voucher v
    on v.slice_id = a.slice_id and v.guid = a.guid
join company_slice s
    on s.id = a.slice_id
left join mst_ledger l
    on l.slice_id = a.slice_id and l.guid = a._ledger
left join master_identity i
    on i.id = l.identity_id;
