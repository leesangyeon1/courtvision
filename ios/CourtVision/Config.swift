import Foundation

/// Supabase project configuration.
///
/// ┌──────────────────────────────────────────────────────────────────────┐
/// │ TODO: paste your Supabase project's URL and anon key below.          │
/// │ Find both in the Supabase dashboard under Settings → API.            │
/// │ Example: SUPABASE_URL = "https://abcd1234.supabase.co"               │
/// └──────────────────────────────────────────────────────────────────────┘
///
/// While these are left as placeholders the app shows a setup notice instead
/// of the login screen — it never fabricates data or talks to a fake backend.
enum Config {
    // TODO: replace with your project URL (Settings → API).
    static let SUPABASE_URL = "https://guljpvrfppodnymkrqsh.supabase.co"
    // TODO: replace with your project anon (public) key (Settings → API).
    static let SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imd1bGpwdnJmcHBvZG55bWtycXNoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI2ODk1OTUsImV4cCI6MjA5ODI2NTU5NX0.R819vZBeXOmfpkUsyRlPqSkq4dH_yQbG0jnIlnmTu4c"

    static var isConfigured: Bool {
        !SUPABASE_URL.contains("TODO")
            && !SUPABASE_ANON_KEY.contains("TODO")
            && URL(string: SUPABASE_URL) != nil
    }
}
