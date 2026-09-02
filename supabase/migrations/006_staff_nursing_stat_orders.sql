-- Staff directory and STAT medication routing to Nursing Station.
alter table public.profiles
  add column if not exists staff_no text,
  add column if not exists designation text,
  add column if not exists department text,
  add column if not exists phone text,
  add column if not exists qualification text,
  add column if not exists registration_no text,
  add column if not exists joining_date date,
  add column if not exists active boolean not null default true;

create table if not exists public.nursing_medication_orders (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.patients(id) on delete cascade,
  prescription_id uuid references public.prescriptions(id) on delete set null,
  prescription_item_id uuid references public.prescription_items(id) on delete set null,
  medicine_name text not null,
  strength text,
  dose text,
  route text,
  frequency text,
  quantity numeric,
  priority text not null default 'routine' check(priority in ('routine','stat')),
  status text not null default 'pending' check(status in ('pending','acknowledged','administered','cancelled')),
  ordered_by uuid references public.profiles(id),
  nursing_station text not null default 'Main Nursing Station',
  instructions text,
  ordered_at timestamptz not null default now(),
  acknowledged_at timestamptz,
  administered_at timestamptz,
  administered_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_nursing_med_orders_patient on public.nursing_medication_orders(patient_id, ordered_at desc);
create index if not exists idx_nursing_med_orders_queue on public.nursing_medication_orders(status, priority, ordered_at desc);

alter table public.nursing_medication_orders enable row level security;

drop policy if exists nursing_med_orders_select on public.nursing_medication_orders;
create policy nursing_med_orders_select on public.nursing_medication_orders for select to authenticated using (true);
drop policy if exists nursing_med_orders_insert on public.nursing_medication_orders;
create policy nursing_med_orders_insert on public.nursing_medication_orders for insert to authenticated with check (true);
drop policy if exists nursing_med_orders_update on public.nursing_medication_orders;
create policy nursing_med_orders_update on public.nursing_medication_orders for update to authenticated using (true) with check (true);

create or replace function public.route_stat_medication_to_nursing(
  p_patient_id uuid,
  p_prescription_id uuid,
  p_prescription_item_id uuid,
  p_medicine_name text,
  p_strength text,
  p_dose text,
  p_route text,
  p_frequency text,
  p_quantity numeric,
  p_instructions text default null,
  p_ordered_by uuid default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid;
begin
  insert into public.nursing_medication_orders(patient_id,prescription_id,prescription_item_id,medicine_name,strength,dose,route,frequency,quantity,priority,instructions,ordered_by)
  values(p_patient_id,p_prescription_id,p_prescription_item_id,p_medicine_name,p_strength,p_dose,p_route,p_frequency,p_quantity,'stat',p_instructions,p_ordered_by)
  returning id into new_id;
  return new_id;
end; $$;

create or replace function public.acknowledge_nursing_medication(p_order_id uuid, p_user_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  update public.nursing_medication_orders set status='acknowledged', acknowledged_at=now() where id=p_order_id and status='pending';
  return found;
end; $$;

create or replace function public.administer_nursing_medication(p_order_id uuid, p_user_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  update public.nursing_medication_orders set status='administered', administered_at=now(), administered_by=p_user_id where id=p_order_id and status in ('pending','acknowledged');
  return found;
end; $$;
