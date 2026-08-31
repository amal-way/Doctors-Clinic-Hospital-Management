# Doctor's Clinic / Hospital Management

Production-oriented clinic/hospital management web app built with React + Vite and Supabase PostgreSQL/Auth.

## Architecture
- Frontend: React + Vite + responsive CSS
- Authentication: Supabase Auth with persistent sessions
- Database: PostgreSQL via Supabase
- Authorization: PostgreSQL Row Level Security (RLS) by staff role
- Documents: jsPDF foundation for consultation/report PDFs
- Voice: browser Web Speech API for clinician-reviewed draft transcription
- Deployment: Vercel-compatible SPA configuration
- CI: GitHub Actions build validation

## Modules
Patient EMR, appointments/token queue, consultations, voice notes, prescriptions, laboratory, billing/payments, admissions/beds, pharmacy, doctors/staff and audit logging.

## Setup
1. Create a Supabase project.
2. Run `supabase/migrations/001_initial_schema.sql` in the Supabase SQL Editor.
3. Create an application user through the sign-up screen.
4. Set the initial administrator role: `update public.profiles set role='admin' where id='<AUTH_USER_UUID>';`
5. Copy `.env.example` to `.env` and add the Supabase project URL and anon key.
6. Run `npm install` and `npm run dev`.

Never put a Supabase service-role key in the frontend. Only the publishable/anon key belongs in Vite environment variables. RLS is the security boundary for application data.

## Clinical AI safety
Voice transcription and future translation/AI extraction are assistance features and must produce editable drafts. An authorized clinician must review clinical facts, diagnosis, dosage, route, duration and prescription before approval or printing.

## Production checklist
- Configure Supabase backups and retention
- Configure custom domain and HTTPS
- Add storage buckets with RLS for lab reports/documents
- Add server-side AI/translation Edge Functions with secrets kept off the client
- Complete prescription approval/dispensing workflows
- Add payment reconciliation and invoice PDF templates
- Add audit triggers for sensitive record changes
- Add monitoring/error reporting
- Perform security, privacy and clinical workflow validation before real patient use
