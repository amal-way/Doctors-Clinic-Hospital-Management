-- Link verified laboratory findings into prescriptions.
alter table public.prescriptions
  add column if not exists lab_findings jsonb not null default '[]'::jsonb;

create or replace function public.sync_lab_findings_to_prescription()
returns trigger language plpgsql security definer set search_path=public as $$
declare findings jsonb;
begin
  if NEW.status = 'ready' and NEW.encounter_id is not null then
    select coalesce(jsonb_agg(jsonb_build_object('test_name',lo.test_name,'priority',lo.priority,'status',lo.status,'verified_at',lo.verified_at,'entries',coalesce(lo.result->'entries','[]'::jsonb)) order by lo.created_at),'[]'::jsonb) into findings
    from public.lab_orders lo where lo.encounter_id=NEW.encounter_id and lo.status='ready';
    update public.prescriptions set lab_findings=findings where encounter_id=NEW.encounter_id;
  end if;
  return NEW;
end; $$;

drop trigger if exists trg_sync_lab_findings_to_prescription on public.lab_orders;
create trigger trg_sync_lab_findings_to_prescription after insert or update of status,result,verified_at on public.lab_orders for each row execute function public.sync_lab_findings_to_prescription();

create or replace function public.sync_lab_findings_on_prescription()
returns trigger language plpgsql security definer set search_path=public as $$
declare findings jsonb;
begin
  if NEW.encounter_id is not null then
    select coalesce(jsonb_agg(jsonb_build_object('test_name',lo.test_name,'priority',lo.priority,'status',lo.status,'verified_at',lo.verified_at,'entries',coalesce(lo.result->'entries','[]'::jsonb)) order by lo.created_at),'[]'::jsonb) into findings
    from public.lab_orders lo where lo.encounter_id=NEW.encounter_id and lo.status='ready';
    NEW.lab_findings:=findings;
  end if;
  return NEW;
end; $$;

drop trigger if exists trg_sync_lab_findings_on_prescription on public.prescriptions;
create trigger trg_sync_lab_findings_on_prescription before insert or update of encounter_id on public.prescriptions for each row execute function public.sync_lab_findings_on_prescription();

insert into storage.buckets(id,name,public) values('clinical-reports','clinical-reports',false) on conflict(id) do update set public=false;

drop policy if exists clinical_reports_insert on storage.objects;
create policy clinical_reports_insert on storage.objects for insert to authenticated with check(bucket_id='clinical-reports' and (storage.foldername(name))[1]='prescriptions');
drop policy if exists clinical_reports_select on storage.objects;
create policy clinical_reports_select on storage.objects for select to authenticated using(bucket_id='clinical-reports');
drop policy if exists clinical_reports_update on storage.objects;
create policy clinical_reports_update on storage.objects for update to authenticated using(bucket_id='clinical-reports') with check(bucket_id='clinical-reports');
