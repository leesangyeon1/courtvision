import { createClient, type SupabaseClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined

// Null when env is missing — App then renders the Setup screen.
export const supabase: SupabaseClient | null =
  url && anonKey ? createClient(url, anonKey) : null

// For code paths only reachable when configured.
export const sb = (): SupabaseClient => supabase as SupabaseClient
