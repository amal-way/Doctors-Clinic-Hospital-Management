create extension if not exists pgcrypto;

create type public.user_role as enum ('admin','doctor','receptionist','nurse','lab','pharmacist','accountant','patient');
create type public.appointment_status as enum ('waiting','in_consultation','completed','cancelled');
create type public.lab_status as enum ('ordered','sample_collected','processing','ready','cancelled');
create type public.payment_status as enum ('pending','partial','paid','cancelled');

create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 full_name text not null,
 phone text,
 role public.user_role not null default 'receptionist',
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);

create table public.patients (
 id uuid primary key default gen_random_uuid(),
 patient_no text unique not null,
 full_name text not null,
 date_of_birth date,
 gender text,
 phone text,
 email text,
 address text,
 blood_group text,
 allergies text,
 emergency_contact text,
 created_by uuid references public.profiles(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);

create table public.encounters (
 id uuid primary key default gen_random_uuid(),
 patient_id uuid not null references public.patients(id) on delete cascade,
 doctor_id uuid references public.profiles(id),
 chief_complaint text,
 history text,
 examination text,
 vitals jsonb not null default '{}'::jsonb,
 assessment text,
 plan text,
 voice_transcript text,
 source_language text,
 translated_text text,
 status text not null default 'draft',
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);

create table public.prescriptions (
 id uuid primary key default gen_random_uuid(),
 encounter_id uuid not null references public.encounters(id) on delete cascade,
 patient_id uuid not null references public.patients(id) on delete cascade,
 doctor_id uuid references public.profiles(id),
 status text not null default 'draft',
 instructions text,
 approved_at timestamptz,
 created_at timestamptz not null default now()
);

create table public.prescription_items (
 id uuid primary key default gen_random_uuid(),
 prescription_id uuid not null references public.prescriptions(id) on delete cascade,
 medicine_name text not null,
 strength text,
 dosage text,
 frequency text,
 route text,
 duration text,
 quantity numeric,
 instructions text
);

create table public.appointments (
 id uuid primary key default gen_random_uuid(),
 patient_id uuid not null references public.patients(id),
 doctor_id uuid references public.profiles(id),
 appointment_date date not null default current_date,
 appointment_time time,
 token_no integer,
 type text,
 status public.appointment_status not null default 'waiting',
 notes text,
 created_at timestamptz not null default now()
);

create table public.lab_orders (
 id uuid primary key default gen_random_uuid(),
 patient_id uuid not null references public.patients(id),
 encounter_id uuid references public.encounters(id),
 ordered_by uuid references public.profiles(id),
 test_name text not null,
 priority text not null default 'routine',
 status public.lab_status not null default 'ordered',
 result jsonb,
 report_url text,
 created_at timestamptz not null default now(),
 completed_at timestamptz
);

create table public.invoices (
 id uuid primary key default gen_random_uuid(),
 invoice_no text unique not null,
 patient_id uuid references public.patients(id),
 subtotal numeric(12,2) not null default 0,
 tax numeric(12,2) not null default 0,
 discount numeric(12,2) not null default 0,
 total numeric(12,2) generated always as (subtotal + tax - discount) stored,
 status public.payment_status not null default 'pending',
 created_at timestamptz not null default now()
);

create table public.invoice_items (
 id uuid primary key default gen_random_uuid(),
 invoice_id uuid not null references public.invoices(id) on delete cascade,
 description text not null,
 quantity numeric not null default 1,
 unit_price numeric(12,2) not null default 0,
 amount numeric(12,2) generated always as (quantity * unit_price) stored
);

create table public.payments (
 id uuid primary key default gen_random_uuid(),
 invoice_id uuid not null references public.invoices(id),
 amount numeric(12,2) not null check (amount > 0),
 method text not null,
 reference text,
 paid_at timestamptz not null default now(),
 received_by uuid references public.profiles(id)
);

create table public.beds (
 id uuid primary key default gen_random_uuid(),
 ward text not null,
 room text,
 bed_no text not null,
 status text not null default 'available',
 unique(ward, bed_no)
);

create table public.admissions (
 id uuid primary key default gen_random_uuid(),
 patient_id uuid not null references public.patients(id),
 bed_id uuid references public.beds(id),
 admitted_at timestamptz not null default now(),
 discharged_at timestamptz,
 diagnosis text,
 discharge_summary text,
 status text not null default 'admitted'
);

create table public.medicines (
 id uuid primary key default gen_random_uuid(),
 name text not null,
 generic_name text,
 strength text,
 form text,
 batch_no text,
 expiry_date date,
 stock numeric not null default 0,
 reorder_level numeric not null default 10,
 unit_price numeric(12,2) not null default 0,
 created_at timestamptz not null default now()
);

create table public.audit_logs (
 id bigint generated always as identity primary key,
 actor_id uuid references public.profiles(id),
 action text not null,
 entity_type text not null,
 entity_id uuid,
 metadata jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into public.profiles(id,full_name) values(new.id,coalesce(new.raw_user_meta_data->>'full_name',new.email)); return new; end; $$;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

alter table public.profiles enable row level security;
alter table public.patients enable row level security;
alter table public.encounters enable row level security;
alter table public.prescriptions enable row level security;
alter table public.prescription_items enable row level security;
alter table public.appointments enable row level security;
alter table public.lab_orders enable row level security;
alter table public.invoices enable row level security;
alter table public.invoice_items enable row level security;
alter table public.payments enable row level security;
alter table public.beds enable row level security;
alter table public.admissions enable row level security;
alter table public.medicines enable row level security;
alter table public.audit_logs enable row level security;

create or replace function public.current_role() returns public.user_role language sql stable security definer set search_path=public as $$ select role from public.profiles where id=auth.uid() $$;
create policy profiles_self on public.profiles for select using(id=auth.uid());
create policy profiles_admin on public.profiles for all using(public.current_role()='admin') with check(public.current_role()='admin');

create policy patients_staff on public.patients for all using(public.current_role() in ('admin','doctor','receptionist','nurse','lab','pharmacist','accountant')) with check(public.current_role() in ('admin','doctor','receptionist','nurse','lab','pharmacist','accountant'));
create policy encounters_clinical on public.encounters for all using(public.current_role() in ('admin','doctor','nurse')) with check(public.current_role() in ('admin','doctor','nurse'));
create policy prescriptions_clinical on public.prescriptions for all using(public.current_role() in ('admin','doctor','pharmacist')) with check(public.current_role() in ('admin','doctor','pharmacist'));
create policy prescription_items_clinical on public.prescription_items for all using(public.current_role() in ('admin','doctor','pharmacist')) with check(public.current_role() in ('admin','doctor','pharmacist'));
create policy appointments_staff on public.appointments for all using(public.current_role() in ('admin','doctor','receptionist','nurse')) with check(public.current_role() in ('admin','doctor','receptionist','nurse'));
create policy lab_staff on public.lab_orders for all using(public.current_role() in ('admin','doctor','nurse','lab')) with check(public.current_role() in ('admin','doctor','nurse','lab'));
create policy billing_staff on public.invoices for all using(public.current_role() in ('admin','receptionist','accountant')) with check(public.current_role() in ('admin','receptionist','accountant'));
create policy invoice_items_staff on public.invoice_items for all using(public.current_role() in ('admin','receptionist','accountant')) with check(public.current_role() in ('admin','receptionist','accountant'));
create policy payments_staff on public.payments for all using(public.current_role() in ('admin','receptionist','accountant')) with check(public.current_role() in ('admin','receptionist','accountant'));
create policy beds_staff on public.beds for all using(public.current_role() in ('admin','doctor','nurse','receptionist')) with check(public.current_role() in ('admin','doctor','nurse','receptionist'));
create policy admissions_staff on public.admissions for all using(public.current_role() in ('admin','doctor','nurse','receptionist')) with check(public.current_role() in ('admin','doctor','nurse','receptionist'));
create policy medicines_staff on public.medicines for all using(public.current_role() in ('admin','pharmacist','doctor')) with check(public.current_role() in ('admin','pharmacist','doctor'));
create policy audit_admin on public.audit_logs for select using(public.current_role()='admin');
create policy audit_insert on public.audit_logs for insert with check(auth.uid()=actor_id);
