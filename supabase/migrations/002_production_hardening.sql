-- Production hardening migration
-- Run after 001_initial_schema.sql.

create index if not exists idx_patients_name on public.patients using gin (to_tsvector('simple', full_name));
create index if not exists idx_patients_phone on public.patients(phone);
create index if not exists idx_encounters_patient_created on public.encounters(patient_id, created_at desc);
create index if not exists idx_prescriptions_patient_created on public.prescriptions(patient_id, created_at desc);
create index if not exists idx_appointments_date_status on public.appointments(appointment_date, status, token_no);
create index if not exists idx_lab_orders_status on public.lab_orders(status, priority, created_at desc);
create index if not exists idx_invoices_patient_created on public.invoices(patient_id, created_at desc);
create index if not exists idx_payments_invoice_paid on public.payments(invoice_id, paid_at desc);
create index if not exists idx_admissions_active on public.admissions(status, admitted_at desc);
create index if not exists idx_medicines_expiry on public.medicines(expiry_date);
create index if not exists idx_audit_actor_created on public.audit_logs(actor_id, created_at desc);

create or replace function public.set_updated_at() returns trigger
language plpgsql security definer set search_path=public as $$
begin new.updated_at = now(); return new; end; $$;

 drop trigger if exists profiles_set_updated_at on public.profiles;
 create trigger profiles_set_updated_at before update on public.profiles for each row execute function public.set_updated_at();
 drop trigger if exists patients_set_updated_at on public.patients;
 create trigger patients_set_updated_at before update on public.patients for each row execute function public.set_updated_at();
 drop trigger if exists encounters_set_updated_at on public.encounters;
 create trigger encounters_set_updated_at before update on public.encounters for each row execute function public.set_updated_at();

-- Patients can only see their own linked patient record when a patient portal is used.
create policy patients_self on public.patients for select
using (created_by = auth.uid());

-- A doctor can only modify clinical encounters assigned to them; admins retain full access.
drop policy if exists encounters_clinical on public.encounters;
create policy encounters_clinical on public.encounters for all
using (public.current_role()='admin' or (public.current_role() in ('doctor','nurse') and (doctor_id=auth.uid() or doctor_id is null)))
with check (public.current_role()='admin' or (public.current_role() in ('doctor','nurse') and (doctor_id=auth.uid() or doctor_id is null)));

-- Appointment tokens are unique per doctor/date where a doctor is assigned.
create unique index if not exists uq_appointment_token_doctor_date
on public.appointments(doctor_id, appointment_date, token_no)
where token_no is not null and doctor_id is not null;

-- Prevent negative inventory and invalid financial totals.
alter table public.medicines drop constraint if exists medicines_stock_nonnegative;
alter table public.medicines add constraint medicines_stock_nonnegative check (stock >= 0);
alter table public.invoices drop constraint if exists invoices_nonnegative_values;
alter table public.invoices add constraint invoices_nonnegative_values check (subtotal >= 0 and tax >= 0 and discount >= 0 and subtotal + tax - discount >= 0);

-- Central approval function: only a doctor may approve their own prescription.
create or replace function public.approve_prescription(p_prescription_id uuid)
returns public.prescriptions
language plpgsql security definer set search_path=public as $$
declare p public.prescriptions;
begin
  select * into p from public.prescriptions where id=p_prescription_id for update;
  if p.id is null then raise exception 'Prescription not found'; end if;
  if public.current_role() <> 'admin' and (public.current_role() <> 'doctor' or p.doctor_id <> auth.uid()) then
    raise exception 'Only the prescribing doctor or administrator may approve this prescription';
  end if;
  if p.status <> 'draft' then raise exception 'Only draft prescriptions can be approved'; end if;
  update public.prescriptions set status='approved', approved_at=now() where id=p_prescription_id returning * into p;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(auth.uid(),'approve','prescription',p.id,jsonb_build_object('patient_id',p.patient_id,'encounter_id',p.encounter_id));
  return p;
end; $$;
revoke all on function public.approve_prescription(uuid) from public;
grant execute on function public.approve_prescription(uuid) to authenticated;

-- Immutable audit records: clients may insert their own event, but cannot update/delete audit history.
drop policy if exists audit_insert on public.audit_logs;
create policy audit_insert on public.audit_logs for insert with check (auth.uid()=actor_id);
