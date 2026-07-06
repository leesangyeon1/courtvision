import { useState } from 'react'
import type { FormEvent } from 'react'
import { sb } from '../lib/supabase'

export default function AuthScreen() {
  const [mode, setMode] = useState<'signin' | 'signup'>('signin')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function submit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setNotice(null)
    setBusy(true)
    const res =
      mode === 'signin'
        ? await sb().auth.signInWithPassword({ email, password })
        : await sb().auth.signUp({ email, password })
    setBusy(false)
    if (res.error) setError(res.error.message)
    else if (mode === 'signup' && !res.data.session)
      setNotice('Account created — check your email to confirm, then sign in.')
  }

  return (
    <div className="center-screen">
      <div className="auth-card">
        <div className="card">
          <h2 style={{ fontSize: 22 }}>
            Court<span className="logo-accent">Vision</span>
          </h2>
          <p className="card-sub">
            {mode === 'signin' ? 'Sign in to your dashboard' : 'Create an account'}
          </p>
          <form onSubmit={submit}>
            <div className="auth-field">
              <label>EMAIL</label>
              <input
                className="input"
                type="email"
                required
                autoComplete="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
              />
            </div>
            <div className="auth-field">
              <label>PASSWORD</label>
              <input
                className="input"
                type="password"
                required
                minLength={6}
                autoComplete={mode === 'signin' ? 'current-password' : 'new-password'}
                value={password}
                onChange={(e) => setPassword(e.target.value)}
              />
            </div>
            {error && <p className="error-text">{error}</p>}
            {notice && <p className="hint" style={{ marginBottom: 10 }}>{notice}</p>}
            <button className="btn" style={{ width: '100%' }} disabled={busy}>
              {busy ? '…' : mode === 'signin' ? 'Sign in' : 'Sign up'}
            </button>
          </form>
          <p className="muted" style={{ marginTop: 14 }}>
            {mode === 'signin' ? 'No account? ' : 'Have an account? '}
            <a
              style={{ cursor: 'pointer' }}
              onClick={() => {
                setMode(mode === 'signin' ? 'signup' : 'signin')
                setError(null)
                setNotice(null)
              }}
            >
              {mode === 'signin' ? 'Sign up' : 'Sign in'}
            </a>
          </p>
        </div>
      </div>
    </div>
  )
}
