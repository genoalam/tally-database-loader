-- Phase B: rewrite names on every slice of an entity from the latest master.
-- Winner: current slice if it still has the GUID, else newest books_to that has it.
-- Never compare AlterID across slices. Never propagate historical names onto current.

create or replace function propagate_latest_master_names(p_entity_id uuid)
returns table(master_type text, winners int, rows_updated bigint)
language plpgsql
as $$
begin
    if not exists (select 1 from company_slice where entity_id = p_entity_id) then
        raise exception 'unknown legal_entity %', p_entity_id;
    end if;

    create temporary table _win (
        master_type text not null,
        guid        text not null,
        name        text,
        primary key (master_type, guid)
    ) on commit drop;

    -- Latest master per GUID: is_current first, then books_to, then alterid inside that slice.
    insert into _win (master_type, guid, name)
    select master_type, guid, name
    from (
        select
            x.master_type,
            x.guid,
            x.name,
            row_number() over (
                partition by x.master_type, x.guid
                order by x.is_current desc, x.books_to desc nulls last, x.alterid desc nulls last, x.slice_id
            ) as rn
        from (
            select 'group'::text, g.guid, g.name, g.alterid, s.is_current, s.books_to, s.id
            from mst_group g
            join company_slice s on s.id = g.slice_id
            where s.entity_id = p_entity_id
            union all
            select 'ledger', l.guid, l.name, l.alterid, s.is_current, s.books_to, s.id
            from mst_ledger l
            join company_slice s on s.id = l.slice_id
            where s.entity_id = p_entity_id
            union all
            select 'vouchertype', v.guid, v.name, v.alterid, s.is_current, s.books_to, s.id
            from mst_vouchertype v
            join company_slice s on s.id = v.slice_id
            where s.entity_id = p_entity_id
            union all
            select 'uom', u.guid, u.name, u.alterid, s.is_current, s.books_to, s.id
            from mst_uom u
            join company_slice s on s.id = u.slice_id
            where s.entity_id = p_entity_id
            union all
            select 'godown', d.guid, d.name, d.alterid, s.is_current, s.books_to, s.id
            from mst_godown d
            join company_slice s on s.id = d.slice_id
            where s.entity_id = p_entity_id
            union all
            select 'stock_category', c.guid, c.name, c.alterid, s.is_current, s.books_to, s.id
            from mst_stock_category c
            join company_slice s on s.id = c.slice_id
            where s.entity_id = p_entity_id
            union all
            select 'stock_group', sg.guid, sg.name, sg.alterid, s.is_current, s.books_to, s.id
            from mst_stock_group sg
            join company_slice s on s.id = sg.slice_id
            where s.entity_id = p_entity_id
            union all
            select 'stock_item', i.guid, i.name, i.alterid, s.is_current, s.books_to, s.id
            from mst_stock_item i
            join company_slice s on s.id = i.slice_id
            where s.entity_id = p_entity_id
            union all
            select 'cost_category', cc.guid, cc.name, cc.alterid, s.is_current, s.books_to, s.id
            from mst_cost_category cc
            join company_slice s on s.id = cc.slice_id
            where s.entity_id = p_entity_id
            union all
            select 'cost_centre', ce.guid, ce.name, ce.alterid, s.is_current, s.books_to, s.id
            from mst_cost_centre ce
            join company_slice s on s.id = ce.slice_id
            where s.entity_id = p_entity_id
            union all
            select 'attendance_type', a.guid, a.name, a.alterid, s.is_current, s.books_to, s.id
            from mst_attendance_type a
            join company_slice s on s.id = a.slice_id
            where s.entity_id = p_entity_id
            union all
            select 'employee', e.guid, e.name, e.alterid, s.is_current, s.books_to, s.id
            from mst_employee e
            join company_slice s on s.id = e.slice_id
            where s.entity_id = p_entity_id
            union all
            select 'payhead', p.guid, p.name, p.alterid, s.is_current, s.books_to, s.id
            from mst_payhead p
            join company_slice s on s.id = p.slice_id
            where s.entity_id = p_entity_id
        ) as x(master_type, guid, name, alterid, is_current, books_to, slice_id)
    ) ranked
    where rn = 1;

    insert into master_identity (id, entity_id, master_type, stable_guid, canonical_name, match_method)
    select gen_random_uuid(), p_entity_id, w.master_type, w.guid, coalesce(w.name, ''), 'guid'
    from _win w
    on conflict (entity_id, master_type, stable_guid) do update
    set canonical_name = excluded.canonical_name,
        match_method = 'guid';

    -- Audit previous slice-local names before rewrite.
    insert into master_alias (identity_id, slice_id, name, alias, observed_at)
    select i.id, l.slice_id, l.name, l.alias, now()
    from mst_ledger l
    join company_slice s on s.id = l.slice_id
    join _win w on w.master_type = 'ledger' and w.guid = l.guid
    join master_identity i on i.entity_id = s.entity_id and i.master_type = 'ledger' and i.stable_guid = l.guid
    where s.entity_id = p_entity_id
      and l.name is distinct from w.name
    on conflict do nothing;

    -- Frozen (and current) master name copies.
    update mst_group t set name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'group' and w.guid = t.guid and t.name is distinct from w.name;

    update mst_ledger t set name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'ledger' and w.guid = t.guid and t.name is distinct from w.name;

    update mst_vouchertype t set name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'vouchertype' and w.guid = t.guid and t.name is distinct from w.name;

    update mst_uom t set name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'uom' and w.guid = t.guid and t.name is distinct from w.name;

    update mst_godown t set name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'godown' and w.guid = t.guid and t.name is distinct from w.name;

    update mst_stock_category t set name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'stock_category' and w.guid = t.guid and t.name is distinct from w.name;

    update mst_stock_group t set name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'stock_group' and w.guid = t.guid and t.name is distinct from w.name;

    update mst_stock_item t set name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'stock_item' and w.guid = t.guid and t.name is distinct from w.name;

    update mst_cost_category t set name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'cost_category' and w.guid = t.guid and t.name is distinct from w.name;

    update mst_cost_centre t set name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'cost_centre' and w.guid = t.guid and t.name is distinct from w.name;

    update mst_attendance_type t set name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'attendance_type' and w.guid = t.guid and t.name is distinct from w.name;

    update mst_employee t set name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'employee' and w.guid = t.guid and t.name is distinct from w.name;

    update mst_payhead t set name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'payhead' and w.guid = t.guid and t.name is distinct from w.name;

    -- Child name copies. Join winners by GUID column; restrict to this entity via slice.
    -- group
    update mst_group t set parent = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'group' and w.guid = t._parent and t.parent is distinct from w.name;
    update mst_ledger t set parent = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'group' and w.guid = t._parent and t.parent is distinct from w.name;

    -- ledger
    update trn_accounting t set ledger = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'ledger' and w.guid = t._ledger and t.ledger is distinct from w.name;
    update trn_cost_centre t set ledger = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'ledger' and w.guid = t._ledger and t.ledger is distinct from w.name;
    update trn_cost_category_centre t set ledger = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'ledger' and w.guid = t._ledger and t.ledger is distinct from w.name;
    update trn_cost_inventory_category_centre t set ledger = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'ledger' and w.guid = t._ledger and t.ledger is distinct from w.name;
    update trn_bill t set ledger = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'ledger' and w.guid = t._ledger and t.ledger is distinct from w.name;
    update trn_bank t set ledger = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'ledger' and w.guid = t._ledger and t.ledger is distinct from w.name;
    update trn_inventory_additional_cost t set ledger = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'ledger' and w.guid = t._ledger and t.ledger is distinct from w.name;
    update trn_payhead t set payhead_name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'ledger' and w.guid = t._payhead_name and t.payhead_name is distinct from w.name;
    update trn_voucher t set party_name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'ledger' and w.guid = t._party_name and t.party_name is distinct from w.name;
    update mst_opening_bill_allocation t set ledger = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'ledger' and w.guid = t._ledger and t.ledger is distinct from w.name;
    update trn_closingstock_ledger t set ledger = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'ledger' and w.guid = t._ledger and t.ledger is distinct from w.name;

    -- vouchertype
    update mst_vouchertype t set parent = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'vouchertype' and w.guid = t._parent and t.parent is distinct from w.name;
    update trn_voucher t set voucher_type = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'vouchertype' and w.guid = t._voucher_type and t.voucher_type is distinct from w.name;

    -- uom
    update mst_stock_item t set uom = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'uom' and w.guid = t._uom and t.uom is distinct from w.name;
    update mst_stock_item t set alternate_uom = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'uom' and w.guid = t._alternate_uom and t.alternate_uom is distinct from w.name;
    update mst_attendance_type t set uom = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'uom' and w.guid = t._uom and t.uom is distinct from w.name;

    -- godown
    update mst_godown t set parent = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'godown' and w.guid = t._parent and t.parent is distinct from w.name;
    update mst_opening_batch_allocation t set godown = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'godown' and w.guid = t._godown and t.godown is distinct from w.name;
    update trn_inventory t set godown = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'godown' and w.guid = t._godown and t.godown is distinct from w.name;
    update trn_batch t set godown = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'godown' and w.guid = t._godown and t.godown is distinct from w.name;
    update trn_batch t set destination_godown = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'godown' and w.guid = t._destination_godown and t.destination_godown is distinct from w.name;

    -- stock category / group / item
    update mst_stock_item t set category = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'stock_category' and w.guid = t._category and t.category is distinct from w.name;
    update mst_stock_group t set parent = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'stock_group' and w.guid = t._parent and t.parent is distinct from w.name;
    update mst_stock_item t set parent = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'stock_group' and w.guid = t._parent and t.parent is distinct from w.name;
    update trn_inventory t set item = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'stock_item' and w.guid = t._item and t.item is distinct from w.name;
    update trn_batch t set item = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'stock_item' and w.guid = t._item and t.item is distinct from w.name;
    update trn_cost_inventory_category_centre t set item = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'stock_item' and w.guid = t._item and t.item is distinct from w.name;
    update mst_stockitem_standard_cost t set item = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'stock_item' and w.guid = t._item and t.item is distinct from w.name;
    update mst_stockitem_standard_price t set item = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'stock_item' and w.guid = t._item and t.item is distinct from w.name;
    update mst_gst_effective_rate t set item = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'stock_item' and w.guid = t._item and t.item is distinct from w.name;
    update mst_opening_batch_allocation t set item = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'stock_item' and w.guid = t._item and t.item is distinct from w.name;

    -- cost category / centre (employees share cost-centre GUIDs in Tally payroll)
    update mst_cost_centre t set parent = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'cost_category' and w.guid = t._parent and t.parent is distinct from w.name;
    update trn_cost_category_centre t set costcategory = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'cost_category' and w.guid = t._costcategory and t.costcategory is distinct from w.name;
    update trn_cost_inventory_category_centre t set costcategory = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'cost_category' and w.guid = t._costcategory and t.costcategory is distinct from w.name;
    update trn_employee t set category = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'cost_category' and w.guid = t._category and t.category is distinct from w.name;
    update trn_payhead t set category = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'cost_category' and w.guid = t._category and t.category is distinct from w.name;
    update trn_cost_centre t set costcentre = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'cost_centre' and w.guid = t._costcentre and t.costcentre is distinct from w.name;
    update trn_cost_category_centre t set costcentre = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'cost_centre' and w.guid = t._costcentre and t.costcentre is distinct from w.name;
    update trn_cost_inventory_category_centre t set costcentre = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'cost_centre' and w.guid = t._costcentre and t.costcentre is distinct from w.name;
    update trn_employee t set employee_name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'cost_centre' and w.guid = t._employee_name and t.employee_name is distinct from w.name;
    update trn_payhead t set employee_name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'cost_centre' and w.guid = t._employee_name and t.employee_name is distinct from w.name;
    update trn_attendance t set employee_name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'cost_centre' and w.guid = t._employee_name and t.employee_name is distinct from w.name;

    update trn_attendance t set attendancetype_name = w.name
    from _win w, company_slice s
    where s.id = t.slice_id and s.entity_id = p_entity_id
      and w.master_type = 'attendance_type' and w.guid = t._attendancetype_name
      and t.attendancetype_name is distinct from w.name;

    update legal_entity
    set last_name_propagated_at = now()
    where id = p_entity_id;

    return query
    select w.master_type, count(*)::int, 0::bigint
    from _win w
    group by w.master_type
    order by w.master_type;

    -- rows_updated left 0 here; GET DIAGNOSTICS per statement is verbose.
    -- Callers can compare names with IS DISTINCT FROM before/after if they need a count.
end;
$$;
