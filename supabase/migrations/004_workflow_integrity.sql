-- Workflow integrity refinements
create or replace function public.dispense_prescription(p_prescription_id uuid, p_items jsonb, p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare d_id uuid; item jsonb; med_id uuid; qty numeric; current_stock numeric;
begin
  if public.current_role() not in ('admin','pharmacist') then raise exception 'Not authorized'; end if;
  if exists(select 1 from public.dispensations where prescription_id=p_prescription_id and status='dispensed') then raise exception 'Prescription already dispensed'; end if;
  insert into public.dispensations(patient_id,prescription_id,status,dispensed_by,dispensed_at,notes)
  select patient_id,p_prescription_id,'dispensed',auth.uid(),now(),p_notes from public.prescriptions where id=p_prescription_id and status='approved' returning id into d_id;
  if d_id is null then raise exception 'Prescription must exist and be approved'; end if;
  for item in select * from jsonb_array_elements(p_items) loop
    med_id := (item->>'medicine_id')::uuid;
    qty := (item->>'quantity')::numeric;
    if qty <= 0 then raise exception 'Quantity must be positive'; end if;
    select stock into current_stock from public.medicines where id=med_id for update;
    if current_stock is null or current_stock < qty then raise exception 'Insufficient stock for %', item->>'medicine_name'; end if;
    update public.medicines set stock=stock-qty where id=med_id;
    insert into public.dispensation_items(dispensation_id,medicine_id,medicine_name,quantity,unit_price,batch_no,expiry_date)
    select d_id,id,name,qty,unit_price,batch_no,expiry_date from public.medicines where id=med_id;
    insert into public.pharmacy_transactions(medicine_id,transaction_type,quantity,reference_type,reference_id,created_by,notes)
    values(med_id,'dispense',qty,'dispensation',d_id,auth.uid(),p_notes);
  end loop;
  update public.prescriptions set status='dispensed' where id=p_prescription_id;
  return d_id;
end; $$;
grant execute on function public.dispense_prescription(uuid,jsonb,text) to authenticated;

-- Prevent a bed from being assigned twice at the same time.
create unique index if not exists admissions_active_bed_unique on public.admissions(bed_id) where status='admitted' and bed_id is not null;
