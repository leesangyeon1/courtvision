import { useEffect, useState } from 'react'
import type { Session as AuthSession } from '@supabase/supabase-js'
import { navigate, usePath } from './lib/router'
import { sb, supabase } from './lib/supabase'
import AuthScreen from './pages/AuthScreen'
import Home from './pages/Home'
import SessionView from './pages/SessionView'
import SetupScreen from './pages/SetupScreen'
import Trends from './pages/Trends'

export default function App() {
  if (!supabase) return <SetupScreen />
  return <AuthedApp />
}

function AuthedApp() {
  const [authSession, setAuthSession] = useState<AuthSession | null>(null)
  const [ready, setReady] = useState(false)
  const path = usePath()

  useEffect(() => {
    sb()
      .auth.getSession()
      .then(({ data }) => {
        setAuthSession(data.session)
        setReady(true)
      })
    const { data: sub } = sb().auth.onAuthStateChange((_event, session) => {
      setAuthSession(session)
    })
    return () => sub.subscription.unsubscribe()
  }, [])

  if (!ready) return null
  if (!authSession) return <AuthScreen />

  const sessionMatch = path.match(/^\/session\/([0-9a-f-]+)$/i)
  const trendsMatch = path.match(/^\/trends\/([0-9a-f-]+)$/i)

  return (
    <>
      <header className="header">
        <div className="logo" onClick={() => navigate('/')}>
          Court<span className="logo-accent">Vision</span>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <span className="live-label">{authSession.user.email}</span>
          <button className="btn btn-ghost" onClick={() => sb().auth.signOut()}>
            Sign out
          </button>
        </div>
      </header>
      <main className="container">
        {sessionMatch ? (
          <SessionView sessionId={sessionMatch[1]} />
        ) : trendsMatch ? (
          <Trends playerId={trendsMatch[1]} />
        ) : (
          <Home />
        )}
      </main>
    </>
  )
}
