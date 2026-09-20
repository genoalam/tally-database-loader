-- SQL Server Phase B: rewrite names from the latest master (current slice wins).
-- Pair with PostgreSQL platform/postgresql/propagate-latest-master-names.sql
-- Requires the multi-slice warehouse tables (slice_id, company_slice, legal_entity).

create or alter procedure propagate_latest_master_names
    @entity_id uniqueidentifier
as
begin
    set nocount on;

    if not exists (select 1 from company_slice where entity_id = @entity_id)
    begin
        raiserror('unknown legal_entity', 16, 1);
        return;
    end;

    if object_id('tempdb..#_win') is not null drop table #_win;
    create table #_win (
        master_type nvarchar(64) not null,
        guid nvarchar(64) not null,
        name nvarchar(1024),
        primary key (master_type, guid)
    );

    ;with src as (
        select 'group' as master_type, g.guid, g.name, g.alterid, s.is_current, s.books_to, s.id as slice_id
        from mst_group g
        join company_slice s on s.id = g.slice_id
        where s.entity_id = @entity_id
        union all
        select 'ledger', l.guid, l.name, l.alterid, s.is_current, s.books_to, s.id
        from mst_ledger l
        join company_slice s on s.id = l.slice_id
        where s.entity_id = @entity_id
        union all
        select 'vouchertype', v.guid, v.name, v.alterid, s.is_current, s.books_to, s.id
        from mst_vouchertype v
        join company_slice s on s.id = v.slice_id
        where s.entity_id = @entity_id
        union all
        select 'uom', u.guid, u.name, u.alterid, s.is_current, s.books_to, s.id
        from mst_uom u
        join company_slice s on s.id = u.slice_id
        where s.entity_id = @entity_id
        union all
        select 'godown', d.guid, d.name, d.alterid, s.is_current, s.books_to, s.id
        from mst_godown d
        join company_slice s on s.id = d.slice_id
        where s.entity_id = @entity_id
        union all
        select 'stock_category', c.guid, c.name, c.alterid, s.is_current, s.books_to, s.id
        from mst_stock_category c
        join company_slice s on s.id = c.slice_id
        where s.entity_id = @entity_id
        union all
        select 'stock_group', sg.guid, sg.name, sg.alterid, s.is_current, s.books_to, s.id
        from mst_stock_group sg
        join company_slice s on s.id = sg.slice_id
        where s.entity_id = @entity_id
        union all
        select 'stock_item', i.guid, i.name, i.alterid, s.is_current, s.books_to, s.id
        from mst_stock_item i
        join company_slice s on s.id = i.slice_id
        where s.entity_id = @entity_id
        union all
        select 'cost_category', cc.guid, cc.name, cc.alterid, s.is_current, s.books_to, s.id
        from mst_cost_category cc
        join company_slice s on s.id = cc.slice_id
        where s.entity_id = @entity_id
        union all
        select 'cost_centre', ce.guid, ce.name, ce.alterid, s.is_current, s.books_to, s.id
        from mst_cost_centre ce
        join company_slice s on s.id = ce.slice_id
        where s.entity_id = @entity_id
        union all
        select 'attendance_type', a.guid, a.name, a.alterid, s.is_current, s.books_to, s.id
        from mst_attendance_type a
        join company_slice s on s.id = a.slice_id
        where s.entity_id = @entity_id
        union all
        select 'employee', e.guid, e.name, e.alterid, s.is_current, s.books_to, s.id
        from mst_employee e
        join company_slice s on s.id = e.slice_id
        where s.entity_id = @entity_id
        union all
        select 'payhead', p.guid, p.name, p.alterid, s.is_current, s.books_to, s.id
        from mst_payhead p
        join company_slice s on s.id = p.slice_id
        where s.entity_id = @entity_id
    ),
    ranked as (
        select *,
            row_number() over (
                partition by master_type, guid
                order by case when is_current = 1 then 0 else 1 end,
                         books_to desc,
                         alterid desc,
                         slice_id
            ) as rn
        from src
    )
    insert into #_win (master_type, guid, name)
    select master_type, guid, name
    from ranked
    where rn = 1;

    merge master_identity as t
    using #_win as w
    on t.entity_id = @entity_id and t.master_type = w.master_type and t.stable_guid = w.guid
    when matched then
        update set canonical_name = w.name, match_method = 'guid'
    when not matched then
        insert (id, entity_id, master_type, stable_guid, canonical_name, match_method)
        values (newid(), @entity_id, w.master_type, w.guid, isnull(w.name, N''), 'guid');

    insert into master_alias (identity_id, slice_id, name, alias, observed_at)
    select i.id, l.slice_id, l.name, l.alias, sysdatetimeoffset()
    from mst_ledger l
    join company_slice s on s.id = l.slice_id
    join #_win w on w.master_type = 'ledger' and w.guid = l.guid
    join master_identity i on i.entity_id = s.entity_id and i.master_type = 'ledger' and i.stable_guid = l.guid
    where s.entity_id = @entity_id
      and (l.name <> w.name or (l.name is null and w.name is not null) or (l.name is not null and w.name is null));

    -- Master name copies
    update t set name = w.name
    from mst_group t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'group' and w.guid = t.guid
    where s.entity_id = @entity_id and isnull(t.name, '') <> isnull(w.name, '');

    update t set name = w.name
    from mst_ledger t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'ledger' and w.guid = t.guid
    where s.entity_id = @entity_id and isnull(t.name, '') <> isnull(w.name, '');

    update t set name = w.name
    from mst_vouchertype t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'vouchertype' and w.guid = t.guid
    where s.entity_id = @entity_id and isnull(t.name, '') <> isnull(w.name, '');

    update t set name = w.name
    from mst_uom t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'uom' and w.guid = t.guid
    where s.entity_id = @entity_id and isnull(t.name, '') <> isnull(w.name, '');

    update t set name = w.name
    from mst_godown t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'godown' and w.guid = t.guid
    where s.entity_id = @entity_id and isnull(t.name, '') <> isnull(w.name, '');

    update t set name = w.name
    from mst_stock_category t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'stock_category' and w.guid = t.guid
    where s.entity_id = @entity_id and isnull(t.name, '') <> isnull(w.name, '');

    update t set name = w.name
    from mst_stock_group t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'stock_group' and w.guid = t.guid
    where s.entity_id = @entity_id and isnull(t.name, '') <> isnull(w.name, '');

    update t set name = w.name
    from mst_stock_item t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'stock_item' and w.guid = t.guid
    where s.entity_id = @entity_id and isnull(t.name, '') <> isnull(w.name, '');

    update t set name = w.name
    from mst_cost_category t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'cost_category' and w.guid = t.guid
    where s.entity_id = @entity_id and isnull(t.name, '') <> isnull(w.name, '');

    update t set name = w.name
    from mst_cost_centre t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'cost_centre' and w.guid = t.guid
    where s.entity_id = @entity_id and isnull(t.name, '') <> isnull(w.name, '');

    update t set name = w.name
    from mst_attendance_type t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'attendance_type' and w.guid = t.guid
    where s.entity_id = @entity_id and isnull(t.name, '') <> isnull(w.name, '');

    update t set name = w.name
    from mst_employee t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'employee' and w.guid = t.guid
    where s.entity_id = @entity_id and isnull(t.name, '') <> isnull(w.name, '');

    update t set name = w.name
    from mst_payhead t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'payhead' and w.guid = t.guid
    where s.entity_id = @entity_id and isnull(t.name, '') <> isnull(w.name, '');

    -- Child copies (same predicates as the PostgreSQL function)
    update t set parent = w.name
    from mst_group t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'group' and w.guid = t._parent
    where s.entity_id = @entity_id and isnull(t.parent, '') <> isnull(w.name, '');

    update t set parent = w.name
    from mst_ledger t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'group' and w.guid = t._parent
    where s.entity_id = @entity_id and isnull(t.parent, '') <> isnull(w.name, '');

    update t set ledger = w.name
    from trn_accounting t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'ledger' and w.guid = t._ledger
    where s.entity_id = @entity_id and isnull(t.ledger, '') <> isnull(w.name, '');

    update t set ledger = w.name
    from trn_cost_centre t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'ledger' and w.guid = t._ledger
    where s.entity_id = @entity_id and isnull(t.ledger, '') <> isnull(w.name, '');

    update t set ledger = w.name
    from trn_cost_category_centre t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'ledger' and w.guid = t._ledger
    where s.entity_id = @entity_id and isnull(t.ledger, '') <> isnull(w.name, '');

    update t set ledger = w.name
    from trn_cost_inventory_category_centre t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'ledger' and w.guid = t._ledger
    where s.entity_id = @entity_id and isnull(t.ledger, '') <> isnull(w.name, '');

    update t set ledger = w.name
    from trn_bill t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'ledger' and w.guid = t._ledger
    where s.entity_id = @entity_id and isnull(t.ledger, '') <> isnull(w.name, '');

    update t set ledger = w.name
    from trn_bank t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'ledger' and w.guid = t._ledger
    where s.entity_id = @entity_id and isnull(t.ledger, '') <> isnull(w.name, '');

    update t set ledger = w.name
    from trn_inventory_additional_cost t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'ledger' and w.guid = t._ledger
    where s.entity_id = @entity_id and isnull(t.ledger, '') <> isnull(w.name, '');

    update t set payhead_name = w.name
    from trn_payhead t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'ledger' and w.guid = t._payhead_name
    where s.entity_id = @entity_id and isnull(t.payhead_name, '') <> isnull(w.name, '');

    update t set party_name = w.name
    from trn_voucher t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'ledger' and w.guid = t._party_name
    where s.entity_id = @entity_id and isnull(t.party_name, '') <> isnull(w.name, '');

    update t set ledger = w.name
    from mst_opening_bill_allocation t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'ledger' and w.guid = t._ledger
    where s.entity_id = @entity_id and isnull(t.ledger, '') <> isnull(w.name, '');

    update t set ledger = w.name
    from trn_closingstock_ledger t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'ledger' and w.guid = t._ledger
    where s.entity_id = @entity_id and isnull(t.ledger, '') <> isnull(w.name, '');

    update t set parent = w.name
    from mst_vouchertype t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'vouchertype' and w.guid = t._parent
    where s.entity_id = @entity_id and isnull(t.parent, '') <> isnull(w.name, '');

    update t set voucher_type = w.name
    from trn_voucher t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'vouchertype' and w.guid = t._voucher_type
    where s.entity_id = @entity_id and isnull(t.voucher_type, '') <> isnull(w.name, '');

    update t set uom = w.name
    from mst_stock_item t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'uom' and w.guid = t._uom
    where s.entity_id = @entity_id and isnull(t.uom, '') <> isnull(w.name, '');

    update t set alternate_uom = w.name
    from mst_stock_item t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'uom' and w.guid = t._alternate_uom
    where s.entity_id = @entity_id and isnull(t.alternate_uom, '') <> isnull(w.name, '');

    update t set uom = w.name
    from mst_attendance_type t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'uom' and w.guid = t._uom
    where s.entity_id = @entity_id and isnull(t.uom, '') <> isnull(w.name, '');

    update t set parent = w.name
    from mst_godown t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'godown' and w.guid = t._parent
    where s.entity_id = @entity_id and isnull(t.parent, '') <> isnull(w.name, '');

    update t set godown = w.name
    from mst_opening_batch_allocation t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'godown' and w.guid = t._godown
    where s.entity_id = @entity_id and isnull(t.godown, '') <> isnull(w.name, '');

    update t set godown = w.name
    from trn_inventory t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'godown' and w.guid = t._godown
    where s.entity_id = @entity_id and isnull(t.godown, '') <> isnull(w.name, '');

    update t set godown = w.name
    from trn_batch t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'godown' and w.guid = t._godown
    where s.entity_id = @entity_id and isnull(t.godown, '') <> isnull(w.name, '');

    update t set destination_godown = w.name
    from trn_batch t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'godown' and w.guid = t._destination_godown
    where s.entity_id = @entity_id and isnull(t.destination_godown, '') <> isnull(w.name, '');

    update t set category = w.name
    from mst_stock_item t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'stock_category' and w.guid = t._category
    where s.entity_id = @entity_id and isnull(t.category, '') <> isnull(w.name, '');

    update t set parent = w.name
    from mst_stock_group t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'stock_group' and w.guid = t._parent
    where s.entity_id = @entity_id and isnull(t.parent, '') <> isnull(w.name, '');

    update t set parent = w.name
    from mst_stock_item t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'stock_group' and w.guid = t._parent
    where s.entity_id = @entity_id and isnull(t.parent, '') <> isnull(w.name, '');

    update t set item = w.name
    from trn_inventory t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'stock_item' and w.guid = t._item
    where s.entity_id = @entity_id and isnull(t.item, '') <> isnull(w.name, '');

    update t set item = w.name
    from trn_batch t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'stock_item' and w.guid = t._item
    where s.entity_id = @entity_id and isnull(t.item, '') <> isnull(w.name, '');

    update t set item = w.name
    from trn_cost_inventory_category_centre t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'stock_item' and w.guid = t._item
    where s.entity_id = @entity_id and isnull(t.item, '') <> isnull(w.name, '');

    update t set item = w.name
    from mst_stockitem_standard_cost t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'stock_item' and w.guid = t._item
    where s.entity_id = @entity_id and isnull(t.item, '') <> isnull(w.name, '');

    update t set item = w.name
    from mst_stockitem_standard_price t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'stock_item' and w.guid = t._item
    where s.entity_id = @entity_id and isnull(t.item, '') <> isnull(w.name, '');

    update t set item = w.name
    from mst_gst_effective_rate t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'stock_item' and w.guid = t._item
    where s.entity_id = @entity_id and isnull(t.item, '') <> isnull(w.name, '');

    update t set item = w.name
    from mst_opening_batch_allocation t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'stock_item' and w.guid = t._item
    where s.entity_id = @entity_id and isnull(t.item, '') <> isnull(w.name, '');

    update t set parent = w.name
    from mst_cost_centre t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'cost_category' and w.guid = t._parent
    where s.entity_id = @entity_id and isnull(t.parent, '') <> isnull(w.name, '');

    update t set costcategory = w.name
    from trn_cost_category_centre t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'cost_category' and w.guid = t._costcategory
    where s.entity_id = @entity_id and isnull(t.costcategory, '') <> isnull(w.name, '');

    update t set costcategory = w.name
    from trn_cost_inventory_category_centre t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'cost_category' and w.guid = t._costcategory
    where s.entity_id = @entity_id and isnull(t.costcategory, '') <> isnull(w.name, '');

    update t set category = w.name
    from trn_employee t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'cost_category' and w.guid = t._category
    where s.entity_id = @entity_id and isnull(t.category, '') <> isnull(w.name, '');

    update t set category = w.name
    from trn_payhead t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'cost_category' and w.guid = t._category
    where s.entity_id = @entity_id and isnull(t.category, '') <> isnull(w.name, '');

    update t set costcentre = w.name
    from trn_cost_centre t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'cost_centre' and w.guid = t._costcentre
    where s.entity_id = @entity_id and isnull(t.costcentre, '') <> isnull(w.name, '');

    update t set costcentre = w.name
    from trn_cost_category_centre t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'cost_centre' and w.guid = t._costcentre
    where s.entity_id = @entity_id and isnull(t.costcentre, '') <> isnull(w.name, '');

    update t set costcentre = w.name
    from trn_cost_inventory_category_centre t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'cost_centre' and w.guid = t._costcentre
    where s.entity_id = @entity_id and isnull(t.costcentre, '') <> isnull(w.name, '');

    update t set employee_name = w.name
    from trn_employee t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'cost_centre' and w.guid = t._employee_name
    where s.entity_id = @entity_id and isnull(t.employee_name, '') <> isnull(w.name, '');

    update t set employee_name = w.name
    from trn_payhead t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'cost_centre' and w.guid = t._employee_name
    where s.entity_id = @entity_id and isnull(t.employee_name, '') <> isnull(w.name, '');

    update t set employee_name = w.name
    from trn_attendance t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'cost_centre' and w.guid = t._employee_name
    where s.entity_id = @entity_id and isnull(t.employee_name, '') <> isnull(w.name, '');

    update t set attendancetype_name = w.name
    from trn_attendance t
    join company_slice s on s.id = t.slice_id
    join #_win w on w.master_type = 'attendance_type' and w.guid = t._attendancetype_name
    where s.entity_id = @entity_id and isnull(t.attendancetype_name, '') <> isnull(w.name, '');

    update legal_entity
    set last_name_propagated_at = sysdatetimeoffset()
    where id = @entity_id;

    select master_type, count(*) as winners
    from #_win
    group by master_type
    order by master_type;
end;
go
