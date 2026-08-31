import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

export const supabase = url && anonKey ? createClient(url, anonKey, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
}) : null

export function requireSupabase() {
  if (!supabase) throw new Error('Supabase is not configured. Copy .env.example to .env and add VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY.')
  return supabase
}
