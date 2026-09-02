-- Connect Doctor -> Pharmacy -> Nursing Station -> Administration for STAT medicines.
-- A STAT prescription item automatically creates one workflow task. Pharmacy is the only
-- component allowed to deduct stock; Nursing can administer only after pharmacy dispense.

alter table public.nursing_medication_orders
  add column if not exists pharmacy_status text not null default 'pending' check (pharmacy_status in ('pending','dispensed','cancelled')),
  add column if not exists pharmacy_dispensed_at timestamptz,
  add column if not exists pharmacy_dispensed_by uuid references public.profiles(id),
  add column if not exists medicine_id uuid references public.medicines(id),
  add column if not exists pharmacy_quantity numeric;

create unique index if not exists uq_nursing_stat_prescription_item
  on public.nursing_medication_orders(prescription_item_id)
  where priority='stat' and prescription_item_id is not null and status <> 'cancelled';

create or replace function public.sync_stat_prescription_item_to_workflow()
returns trigger language plpgsql security definer set search_path=public as $$
declare p public.prescriptions%rowtype; existing_id uuid;
begin
  select * into p from public.prescriptions where id=new.prescription_id;
  if p.id is null then return new; end if;
  if upper(coalesce(new.frequency,'')) = 'STAT'
     or upper(coalesce(new.dosage,'')) ~ '\\mSTAT\\M'
     or upper(coalesce(new.instructions,'')) ~ '\\mSTAT\\M' then
    select id into existing_id from public.nursing_medication_orders
      where prescription_item_id=new.id and priority='stat' and status <> 'cancelled'
      limit 1;
    if existing_id is null then
      insert into public.nursing_medication_orders(
        patient_id,prescription_id,prescription_item_id,medicine_name,strength,dose,route,frequency,quantity,priority,status,ordered_by,instructions
      ) values (
        p.patient_id,p.id,new.id,new.medicine_name,new.strength,new.dosage,new.route,new.frequency,new.quantity,'stat','pending',p.doctor_id,new.instructions
      );
    else
      update public.nursing_medication_orders set
        medicine_name=new.medicine_name,strength=new.strength,dose=new.dosage,route=new.route,frequency=new.frequency,quantity=new.quantity,instructions=new.instructions
      where id=existing_id and pharmacy_status='pending';
    end if;
  end if;
  return new;
end; $$;

drop trigger if exists trg_stat_prescription_item_workflow on public.prescription_items;
create trigger trg_stat_prescription_item_workflow
after insert or update of medicine_name,strength,dosage,frequency,route,quantity,instructions on public.prescription_items
for each row execute function public.sync_stat_prescription_item_to_workflow();

create or replace function public.dispense_stat_medication(
  p_order_id uuid,
  p_medicine_id uuid,
  p_quantity numeric,
  p_user_id uuid
) returns boolean language plpgsql security definer set search_path=public as $$
declare o public.nursing_medication_orders%rowtype; m public.medicines%rowtype;
begin
  if p_quantity is null or p_quantity <= 0 then raise exception 'Quantity must be greater than zero'; end if;
  select * into o from public.nursing_medication_orders where id=p_order_id for update;
  if o.id is null then raise exception 'STAT medication task not found'; end if;
  if o.priority <> 'stat' or o.pharmacy_status <> 'pending' then raise exception 'STAT task is not available for dispensing'; end if;
  if p_quantity > coalesce(o.quantity,p_quantity) then raise exception 'Dispensing quantity exceeds ordered quantity'; end if;
  select * into m from public.medicines where id=p_medicine_id for update;
  if m.id is null then raise exception 'Medicine not found'; end if;
  if m.stock < p_quantity then raise exception 'Insufficient stock for % (available: %)',m.name,m.stock; end if;
  update public.medicines set stock=stock-p_quantity where id=m.id;
  insert into public.pharmacy_transactions(medicine_id,transaction_type,quantity,batch_no,expiry_date,reference_type,reference_id,notes,created_by)
  values(m.id,'dispense',p_quantity,m.batch_no,m.expiry_date,'nursing_medication_order',o.id,'STAT medication dispensed for patient '||o.patient_id::text,p_user_id);
  update public.nursing_medication_orders set
    medicine_id=m.id,pharmacy_quantity=p_quantity,pharmacy_status='dispensed',pharmacy_dispensed_at=now(),pharmacy_dispensed_by=p_user_id
  where id=o.id;
  return true;
end; $$;

create or replace function public.administer_nursing_medication(p_order_id uuid, p_user_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  update public.nursing_medication_orders
    set status='administered', administered_at=now(), administered_by=p_user_id
  where id=p_order_id and status in ('pending','acknowledged') and (priority <> 'stat' or pharmacy_status='dispensed');
  return found;
end; $$;

create or replace function public.acknowledge_nursing_medication(p_order_id uuid, p_user_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  update public.nursing_medication_orders
    set status='acknowledged', acknowledged_at=now()
  where id=p_order_id and status='pending';
  return found;
end; $$;
