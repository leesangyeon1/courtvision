import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { fmtDate } from '../lib/format'
import { navigate } from '../lib/router'
import { sb } from '../lib/supabase'
import type { Mode, Player, Session } from '../types/contract'

const MODES: Mode[] = ['game', 'practice', 'drill', 'freethrow']
const POLL_MS = 10_000 // fallback path; Realtime session changes invalidate sooner

type RecentSession = Session & { players: { name: string } | null }

export default function Home() {
  const qc = useQueryClient()
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [name, setName] = useState('')
  const [jersey, setJersey] = useState('')
  const [position, setPosition] = useState('')

  const playersQ = useQuery({
    queryKey: ['players'],
    queryFn: async () => {
      const { data, error } = await sb().from('players').select('*').order('created_at')
      if (error) throw error
      return data as Player[]
    },
  })

  const recentQ = useQuery({
    queryKey: ['recent-sessions'],
    refetchInterval: POLL_MS,
    queryFn: async () => {
      const { data, error } = await sb()
        .from('sessions')
        .select('*, players(name)')
        .order('started_at', { ascending: false })
        .limit(12)
      if (error) throw error
      return data as unknown as RecentSession[]
    },
  })

  // Fast path: a session started/ended on the phone shows up here without a
  // reload — Realtime on the sessions table invalidates the lists.
  useEffect(() => {
    const channel = sb()
      .channel('home-sessions')
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'sessions' },
        () => {
          qc.invalidateQueries({ queryKey: ['recent-sessions'] })
          qc.invalidateQueries({ queryKey: ['sessions'] })
        },
      )
      .subscribe()
    return () => {
      void sb().removeChannel(channel)
    }
  }, [qc])

  const liveSessions = (recentQ.data ?? []).filter((s) => s.status === 'live')

  const createPlayer = useMutation({
    mutationFn: async () => {
      const { error } = await sb().from('players').insert({
        name: name.trim(),
        jersey_number: jersey === '' ? null : Number(jersey),
        position: position.trim() || null,
      })
      if (error) throw error
    },
    onSuccess: () => {
      setName('')
      setJersey('')
      setPosition('')
      qc.invalidateQueries({ queryKey: ['players'] })
    },
  })

  const players = playersQ.data ?? []
  const selected = players.find((p) => p.id === selectedId) ?? players[0]

  return (
    <>
      {liveSessions.length > 0 && (
        <div className="card" style={{ borderColor: 'var(--orange)' }}>
          <h2>
            <span className="live-dot" /> Live now
          </h2>
          <p className="card-sub">Recording on the phone — tap to watch live</p>
          {liveSessions.map((s) => (
            <div className="row-item" key={s.id}>
              <span className="row-main" onClick={() => navigate(`/session/${s.id}`)}>
                {s.players?.name ?? 'Unknown player'}
                <span className="row-meta"> · started {fmtDate(s.started_at)}</span>
                {s.mode === 'game' && (
                  <span className="row-meta">
                    {' '}
                    · {s.team_a ?? 'Team A'} vs {s.team_b ?? 'Team B'}
                  </span>
                )}
              </span>
              <span className={`mode-tag ${s.mode}`}>{s.mode}</span>
              <span className="status-tag live">LIVE</span>
            </div>
          ))}
        </div>
      )}

      <div className="grid-2">
        <div className="card">
          <h2>Players</h2>
          <p className="card-sub">Pick a player to see their sessions</p>
          {playersQ.isError && (
            <p className="error-text">{(playersQ.error as Error).message}</p>
          )}
          {players.map((p) => (
            <div className="row-item" key={p.id}>
              <span
                className="row-main"
                style={
                  selected?.id === p.id
                    ? { color: 'var(--orange)', fontWeight: 700 }
                    : undefined
                }
                onClick={() => setSelectedId(p.id)}
              >
                {p.name}
                {p.jersey_number != null ? ` #${p.jersey_number}` : ''}
                {p.position ? <span className="row-meta"> · {p.position}</span> : null}
              </span>
              <a
                style={{ cursor: 'pointer', fontSize: 12 }}
                onClick={() => navigate(`/trends/${p.id}`)}
              >
                Trends
              </a>
            </div>
          ))}
          {playersQ.isSuccess && players.length === 0 && (
            <p className="muted">No players yet — add one below.</p>
          )}
          <form
            className="form-row"
            onSubmit={(e) => {
              e.preventDefault()
              createPlayer.mutate()
            }}
          >
            <input
              className="input"
              placeholder="Name"
              required
              value={name}
              onChange={(e) => setName(e.target.value)}
              style={{ flex: 2, minWidth: 120 }}
            />
            <input
              className="input"
              placeholder="#"
              type="number"
              min={0}
              max={99}
              value={jersey}
              onChange={(e) => setJersey(e.target.value)}
              style={{ width: 64 }}
            />
            <input
              className="input"
              placeholder="Position"
              value={position}
              onChange={(e) => setPosition(e.target.value)}
              style={{ flex: 1, minWidth: 90 }}
            />
            <button className="btn" disabled={createPlayer.isPending || !name.trim()}>
              Add
            </button>
          </form>
          {createPlayer.isError && (
            <p className="error-text">{(createPlayer.error as Error).message}</p>
          )}
        </div>

        {selected ? (
          <PlayerSessions key={selected.id} player={selected} />
        ) : (
          <div className="card">
            <h2>Sessions</h2>
            <p className="muted">Add a player to start a session.</p>
          </div>
        )}
      </div>

      <div className="card">
        <h2>Recent sessions</h2>
        <p className="card-sub">Across all players</p>
        {(recentQ.data ?? []).map((s) => (
          <div className="row-item" key={s.id}>
            <span className="row-main" onClick={() => navigate(`/session/${s.id}`)}>
              {s.players?.name ?? 'Unknown player'}
              <span className="row-meta"> · {fmtDate(s.started_at)}</span>
            </span>
            <span className={`mode-tag ${s.mode}`}>{s.mode}</span>
            <span className={`status-tag ${s.status}`}>
              {s.status === 'live' ? 'LIVE' : 'ENDED'}
            </span>
          </div>
        ))}
        {recentQ.isSuccess && (recentQ.data ?? []).length === 0 && (
          <p className="muted">No sessions yet.</p>
        )}
        {recentQ.isError && (
          <p className="error-text">{(recentQ.error as Error).message}</p>
        )}
      </div>
    </>
  )
}

function PlayerSessions({ player }: { player: Player }) {
  const [mode, setMode] = useState<Mode>('practice')

  const sessionsQ = useQuery({
    queryKey: ['sessions', player.id],
    refetchInterval: POLL_MS,
    queryFn: async () => {
      const { data, error } = await sb()
        .from('sessions')
        .select('*')
        .eq('player_id', player.id)
        .order('started_at', { ascending: false })
      if (error) throw error
      return data as Session[]
    },
  })

  const start = useMutation({
    mutationFn: async () => {
      const { data, error } = await sb()
        .from('sessions')
        .insert({ player_id: player.id, mode })
        .select()
        .single()
      if (error) throw error
      return data as Session
    },
    onSuccess: (s) => navigate(`/session/${s.id}`),
  })

  return (
    <div className="card">
      <h2>{player.name} — sessions</h2>
      <p className="card-sub">Start a new session or open a past one</p>
      <div className="form-row" style={{ marginTop: 0, marginBottom: 12 }}>
        <select
          className="input"
          value={mode}
          onChange={(e) => setMode(e.target.value as Mode)}
        >
          {MODES.map((m) => (
            <option key={m} value={m}>
              {m}
            </option>
          ))}
        </select>
        <button
          className="btn btn-teal"
          onClick={() => start.mutate()}
          disabled={start.isPending}
        >
          Start session
        </button>
      </div>
      {start.isError && <p className="error-text">{(start.error as Error).message}</p>}
      {(sessionsQ.data ?? []).map((s) => (
        <div className="row-item" key={s.id}>
          <span className="row-main" onClick={() => navigate(`/session/${s.id}`)}>
            {fmtDate(s.started_at)}
          </span>
          <span className={`mode-tag ${s.mode}`}>{s.mode}</span>
          <span className={`status-tag ${s.status}`}>
            {s.status === 'live' ? 'LIVE' : 'ENDED'}
          </span>
        </div>
      ))}
      {sessionsQ.isSuccess && (sessionsQ.data ?? []).length === 0 && (
        <p className="muted">No sessions for this player yet.</p>
      )}
      {sessionsQ.isError && (
        <p className="error-text">{(sessionsQ.error as Error).message}</p>
      )}
    </div>
  )
}
