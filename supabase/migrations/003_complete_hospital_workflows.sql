-- Complete Lab + Pharmacy + Billing + Admission/Discharge workflows
-- Run after 001_initial_schema.sql and 002_production_hardening.sql.

create table if not exists public.lab_result_entries (
  id uuid primary key default gen_random_uuid(),
  lab_order_id uuid not null references public.lab_orders(id) on delete cascade,
  parameter_name text not null,
  value_text text,
  unit text,
  reference_range text,
  abnormal_flag text,
  created_at timestamptz not null default now()
);

alter table public.lab_orders
  add column if not exists specimen_type text,
  add column if not exists clinical_notes text,
  add column if not exists collected_at timestamptz,
  add column if not exists verified_at timestamptz,
  add column if not exists verified_by uuid references public.profiles(id);

create table if not exists public.pharmacy_transactions (
  id uuid primary key default gen_random_uuid(),
  medicine_id uuid not null references public.medicines(id),
  transaction_type text not null check (transaction_type in ('purchase','adjustment_in','adjustment_out','dispense','return','wastage')),
  quantity numeric not null check (quantity > 0),
  batch_no text,
  expiry_date date,
  reference_type text,
  reference_id uuid,
  notes text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.dispensations (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.patients(id),
  prescription_id uuid references public.prescriptions(id),
  status text not null default 'pending' check (status in ('pending','dispensed','cancelled')),
  dispensed_by uuid references public.profiles(id),
  dispensed_at timestamptz,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists public.dispensation_items (
  id uuid primary key default gen_random_uuid(),
  dispensation_id uuid not null references public.dispensations(id) on delete cascade,
  medicine_id uuid references public.medicines(id),
  medicine_name text not null,
  quantity numeric not null check (quantity > 0),
  unit_price numeric(12,2) not null default 0,
  batch_no text,
  expiry_date date
);

alter table public.invoices
  add column if not exists notes text,
  add column if not exists due_date date,
  add column if not exists paid_at timestamptz;

alter table public.admissions
  add column if not exists admission_no text,
  add column if not exists admitting_doctor_id uuid references public.profiles(id),
  add column if not exists reason text,
  add column if not exists discharge_diagnosis text,
  add column if not exists discharge_condition text,
  add column if not exists follow_up_date date,
  add column if not exists discharge_instructions text,
  add column if not exists discharged_by uuid references public.profiles(id);

update public.admissions
set admission_no = 'ADM-' || upper(substr(replace(id::text,'-',''),1,8))
where admission_no is null;

alter table public.admissions alter column admission_no set default ('ADM-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)));
create unique index if not exists admissions_admission_no_key on public.admissions(admission_no);

create index if not exists lab_orders_patient_status_idx on public.lab_orders(patient_id,status);
create index if not exists pharmacy_transactions_medicine_idx on public.pharmacy_transactions(medicine_id,created_at desc);
create index if not exists dispensations_patient_idx on public.dispensations(patient_id,created_at desc);
create index if not exists admissions_patient_status_idx on public.admissions(patient_id,status);
create index if not exists invoices_patient_status_idx on public.invoices(patient_id,status);

alter table public.lab_result_entries enable row level security;
alter table public.pharmacy_transactions enable row level security;
alter table public.dispensations enable row level security;
alter table public.dispensation_items enable row level security;

create policy lab_results_staff on public.lab_result_entries for all
to authenticated using (public.current_role() in ('admin','doctor','nurse','lab'))
with check (public.current_role() in ('admin','doctor','nurse','lab'));

create policy pharmacy_transactions_staff on public.pharmacy_transactions for all
to authenticated using (public.current_role() in ('admin','pharmacist','accountant'))
with check (public.current_role() in ('admin','pharmacist','accountant'));

create policy dispensations_staff on public.dispensations for all
to authenticated using (public.current_role() in ('admin','doctor','pharmacist','nurse'))
with check (public.current_role() in ('admin','doctor','pharmacist','nurse'));

create policy dispensation_items_staff on public.dispensation_items for all
to authenticated using (public.current_role() in ('admin','doctor','pharmacist','nurse'))
with check (public.current_role() in ('admin','doctor','pharmacist','nurse'));

-- Atomic stock movement. Positive quantity adds stock; negative quantity removes it.
create or replace function public.apply_pharmacy_stock(p_medicine_id uuid, p_delta numeric)
returns numeric language plpgsql security definer set search_path=public as $$
declare new_stock numeric;
begin
  if public.current_role() not in ('admin','pharmacist') then raise exception 'Not authorized'; end if;
  update public.medicines set stock = stock + p_delta where id = p_medicine_id and stock + p_delta >= 0 returning stock into new_stock;
  if new_stock is null then raise exception 'Insufficient stock or medicine not found'; end if;
  return new_stock;
end; $$;

grant execute on function public.apply_pharmacy_stock(uuid,numeric) to authenticated;

create or replace function public.mark_lab_collected(p_order_id uuid, p_specimen_type text)
returns public.lab_orders language plpgsql security definer set search_path=public as $$
declare r public.lab_orders;
begin
  if public.current_role() not in ('admin','lab','nurse') then raise exception 'Not authorized'; end if;
  update public.lab_orders set status='sample_collected', specimen_type=p_specimen_type, collected_at=now() where id=p_order_id returning * into r;
  return r;
end; $$;

grant execute on function public.mark_lab_collected(uuid,text) to authenticated;

create or replace function public.verify_lab_order(p_order_id uuid)
returns public.lab_orders language plpgsql security definer set search_path=public as $$
declare r public.lab_orders;
begin
  if public.current_role() not in ('admin','doctor','lab') then raise exception 'Not authorized'; end if;
  update public.lab_orders set status='ready', verified_at=now(), verified_by=auth.uid(), completed_at=coalesce(completed_at,now()) where id=p_order_id returning * into r;
  return r;
end; $$;

grant execute on function public.verify_lab_order(uuid) to authenticated;

create or replace function public.dispense_prescription(p_prescription_id uuid, p_items jsonb, p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare d_id uuid; item jsonb; med_id uuid; qty numeric; current_stock numeric;
begin
  if public.current_role() not in ('admin','pharmacist') then raise exception 'Not authorized'; end if;
  insert into public.dispensations(patient_id,prescription_id,status,dispensed_by,dispensed_at,notes)
  select patient_id,p_prescription_id,'dispensed',auth.uid(),now(),p_notes from public.prescriptions where id=p_prescription_id and status='approved' returning id into d_id;
  if d_id is null then raise exception 'Prescription must exist and be approved'; end if;
  for item in select * from jsonb_array_elements(p_items) loop
    med_id := (item->>'medicine_id')::uuid;
    qty := (item->>'quantity')::numeric;
    select stock into current_stock from public.medicines where id=med_id for update;
    if current_stock is null or current_stock < qty then raise exception 'Insufficient stock for %', item->>'medicine_name'; end if;
    update public.medicines set stock=stock-qty where id=med_id;
    insert into public.dispensation_items(dispensation_id,medicine_id,medicine_name,quantity,unit_price,batch_no,expiry_date)
    select d_id,id,name,qty,unit_price,batch_no,expiry_date from public.medicines where id=med_id;
    insert into public.pharmacy_transactions(medicine_id,transaction_type,quantity,reference_type,reference_id,created_by,notes)
    values(med_id,'dispense',qty,'dispensation',d_id,auth.uid(),p_notes);
  end loop;
  return d_id;
end; $$;

grant execute on function public.dispense_prescription(uuid,jsonb,text) to authenticated;

create or replace function public.complete_admission_discharge(p_admission_id uuid,p_diagnosis text,p_condition text,p_follow_up date,p_instructions text)
returns public.admissions language plpgsql security definer set search_path=public as $$
declare r public.admissions;
begin
  if public.current_role() not in ('admin','doctor','nurse') then raise exception 'Not authorized'; end if;
  update public.admissions set status='discharged',discharged_at=now(),discharge_diagnosis=p_diagnosis,discharge_condition=p_condition,follow_up_date=p_follow_up,discharge_instructions=p_instructions,discharged_by=auth.uid(),discharge_summary=coalesce(discharge_summary,p_instructions) where id=p_admission_id and status='admitted' returning * into r;
  if r.id is null then raise exception 'Admission is not active'; end if;
  if r.bed_id is not null then update public.beds set status='available' where id=r.bed_id; end if;
  return r;
end; $$;

grant execute on function public.complete_admission_discharge(uuid,text,text,date,text) to authenticated;

-- Keep the workflow database protected through RLS and least-privilege policies.
