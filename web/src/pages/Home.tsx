import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { fmtDate } from '../lib/format'
import { navigate } from '../lib/router'
import { sb } from '../lib/supabase'
import type { Mode, Player, Session, Team } from '../types/contract'

const MODES: Mode[] = ['game', 'practice', 'drill', 'freethrow']
const POLL_MS = 10_000 // fallback path; Realtime session changes invalidate sooner
// A session still 'live' after this long is a zombie (app killed without
// End Session) — show it as ended, never in "Live now".
const STALE_LIVE_MS = 3 * 60 * 60 * 1000

type RecentSession = Session & { players: { name: string } | null }

export function isActuallyLive(s: Session, now = Date.now()): boolean {
  return s.status === 'live' && now - new Date(s.started_at).getTime() < STALE_LIVE_MS
}

function ModeTag({ mode }: { mode: Mode }) {
  return <span className={`mode-tag ${mode}`}>{mode === 'freethrow' ? 'free throw' : mode}</span>
}

function StatusTag({ s }: { s: Session }) {
  return (
    <span className={`status-tag ${isActuallyLive(s) ? 'live' : 'ended'}`}>
      {isActuallyLive(s) ? 'LIVE' : 'ENDED'}
    </span>
  )
}

/** Mode filter chips shared by every session list. */
function ModeFilter({ value, onChange }: { value: Mode | 'all'; onChange: (m: Mode | 'all') => void }) {
  return (
    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', margin: '8px 0' }}>
      {(['all', ...MODES] as const).map((m) => (
        <button
          key={m}
          className="btn"
          onClick={() => onChange(m)}
          style={{
            padding: '2px 10px',
            fontSize: 12,
            opacity: value === m ? 1 : 0.5,
            border: value === m ? '1px solid var(--orange)' : '1px solid transparent',
          }}
        >
          {m === 'freethrow' ? 'free throw' : m}
        </button>
      ))}
    </div>
  )
}

export default function Home() {
  const qc = useQueryClient()
  const [selectedTeamId, setSelectedTeamId] = useState<string | null>(null)
  const [teamName, setTeamName] = useState('')

  const teamsQ = useQuery({
    queryKey: ['teams'],
    queryFn: async () => {
      const { data, error } = await sb().from('teams').select('*').order('created_at')
      if (error) throw error
      return data as Team[]
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
        .limit(20)
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
          qc.invalidateQueries({ queryKey: ['team-sessions'] })
        },
      )
      .subscribe()
    return () => {
      void sb().removeChannel(channel)
    }
  }, [qc])

  const createTeam = useMutation({
    mutationFn: async () => {
      const { error } = await sb().from('teams').insert({ name: teamName.trim() })
      if (error) throw error
    },
    onSuccess: () => {
      setTeamName('')
      qc.invalidateQueries({ queryKey: ['teams'] })
    },
  })

  const teams = teamsQ.data ?? []
  const selectedTeam = teams.find((t) => t.id === selectedTeamId) ?? teams[0]
  const liveSessions = (recentQ.data ?? []).filter((s) => isActuallyLive(s))

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
              <ModeTag mode={s.mode} />
              <span className="status-tag live">LIVE</span>
            </div>
          ))}
        </div>
      )}

      <div className="grid-2">
        <div className="card">
          <h2>Teams</h2>
          <p className="card-sub">Your team is the unit — roster and sessions live under it</p>
          {teamsQ.isError && <p className="error-text">{(teamsQ.error as Error).message}</p>}
          {teams.map((t) => (
            <div className="row-item" key={t.id}>
              <span
                className="row-main"
                style={
                  selectedTeam?.id === t.id
                    ? { color: 'var(--orange)', fontWeight: 700 }
                    : undefined
                }
                onClick={() => setSelectedTeamId(t.id)}
              >
                {t.name}
              </span>
            </div>
          ))}
          {teamsQ.isSuccess && teams.length === 0 && (
            <p className="muted">No teams yet — create one below.</p>
          )}
          <form
            className="form-row"
            onSubmit={(e) => {
              e.preventDefault()
              createTeam.mutate()
            }}
          >
            <input
              className="input"
              placeholder="Team name"
              required
              value={teamName}
              onChange={(e) => setTeamName(e.target.value)}
              style={{ flex: 1, minWidth: 140 }}
            />
            <button className="btn" disabled={createTeam.isPending || !teamName.trim()}>
              Create team
            </button>
          </form>
        </div>

        {selectedTeam ? (
          <Roster key={selectedTeam.id} team={selectedTeam} />
        ) : (
          <div className="card">
            <h2>Roster</h2>
            <p className="muted">Create a team to add players.</p>
          </div>
        )}
      </div>

      {selectedTeam && <TeamSessions key={`s-${selectedTeam.id}`} team={selectedTeam} />}

      <RecentSessions sessions={recentQ.data ?? []} />
    </>
  )
}

/** Team roster: players with jersey numbers. In game mode the on-device
 *  detector reads jersey numbers and attributes shots to these players. */
function Roster({ team }: { team: Team }) {
  const qc = useQueryClient()
  const [name, setName] = useState('')
  const [jersey, setJersey] = useState('')
  const [position, setPosition] = useState('')

  const playersQ = useQuery({
    queryKey: ['players', team.id],
    queryFn: async () => {
      const { data, error } = await sb()
        .from('players')
        .select('*')
        .eq('team_id', team.id)
        .order('jersey_number')
      if (error) throw error
      return data as Player[]
    },
  })

  const addPlayer = useMutation({
    mutationFn: async () => {
      const { error } = await sb().from('players').insert({
        name: name.trim(),
        jersey_number: jersey === '' ? null : Number(jersey),
        position: position.trim() || null,
        team_id: team.id,
      })
      if (error) throw error
    },
    onSuccess: () => {
      setName('')
      setJersey('')
      setPosition('')
      qc.invalidateQueries({ queryKey: ['players', team.id] })
    },
  })

  const players = playersQ.data ?? []
  return (
    <div className="card">
      <h2>{team.name} — roster</h2>
      <p className="card-sub">Jersey numbers link on-court detections to these players</p>
      {players.map((p) => (
        <div className="row-item" key={p.id}>
          <span className="row-main">
            {p.jersey_number != null ? `#${p.jersey_number} ` : ''}
            {p.name}
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
        <p className="muted">No players yet — add your roster below.</p>
      )}
      <form
        className="form-row"
        onSubmit={(e) => {
          e.preventDefault()
          addPlayer.mutate()
        }}
      >
        <input
          className="input"
          placeholder="Name"
          required
          value={name}
          onChange={(e) => setName(e.target.value)}
          style={{ flex: 2, minWidth: 110 }}
        />
        <input
          className="input"
          placeholder="#"
          type="number"
          min={0}
          max={99}
          value={jersey}
          onChange={(e) => setJersey(e.target.value)}
          style={{ width: 60 }}
        />
        <input
          className="input"
          placeholder="Position"
          value={position}
          onChange={(e) => setPosition(e.target.value)}
          style={{ flex: 1, minWidth: 80 }}
        />
        <button className="btn" disabled={addPlayer.isPending || !name.trim()}>
          Add
        </button>
      </form>
      {addPlayer.isError && <p className="error-text">{(addPlayer.error as Error).message}</p>}
    </div>
  )
}

/** Sessions of the selected team, filterable by mode; start new sessions. */
function TeamSessions({ team }: { team: Team }) {
  const [mode, setMode] = useState<Mode>('practice')
  const [filter, setFilter] = useState<Mode | 'all'>('all')
  const [playerId, setPlayerId] = useState<string>('')
  const [opponent, setOpponent] = useState('')

  const playersQ = useQuery({
    queryKey: ['players', team.id],
    queryFn: async () => {
      const { data, error } = await sb()
        .from('players')
        .select('*')
        .eq('team_id', team.id)
        .order('jersey_number')
      if (error) throw error
      return data as Player[]
    },
  })

  const sessionsQ = useQuery({
    queryKey: ['team-sessions', team.id],
    refetchInterval: POLL_MS,
    queryFn: async () => {
      const { data, error } = await sb()
        .from('sessions')
        .select('*')
        .eq('team_id', team.id)
        .order('started_at', { ascending: false })
      if (error) throw error
      return data as Session[]
    },
  })

  const players = playersQ.data ?? []
  const mainPlayer = players.find((p) => p.id === playerId) ?? players[0]

  const start = useMutation({
    mutationFn: async () => {
      if (!mainPlayer) throw new Error('Add a player to the roster first.')
      const { data, error } = await sb()
        .from('sessions')
        .insert({
          player_id: mainPlayer.id,
          team_id: team.id,
          mode,
          team_a: mode === 'game' ? team.name : null,
          team_b: mode === 'game' ? opponent.trim() || 'Opponent' : null,
        })
        .select()
        .single()
      if (error) throw error
      return data as Session
    },
    onSuccess: (s) => navigate(`/session/${s.id}`),
  })

  const sessions = (sessionsQ.data ?? []).filter((s) => filter === 'all' || s.mode === filter)

  return (
    <div className="card">
      <h2>{team.name} — sessions</h2>
      <p className="card-sub">Start a new session or open a past one</p>
      <div className="form-row" style={{ marginTop: 0, marginBottom: 4 }}>
        <select className="input" value={mode} onChange={(e) => setMode(e.target.value as Mode)}>
          {MODES.map((m) => (
            <option key={m} value={m}>
              {m === 'freethrow' ? 'free throw' : m}
            </option>
          ))}
        </select>
        <select
          className="input"
          value={mainPlayer?.id ?? ''}
          onChange={(e) => setPlayerId(e.target.value)}
        >
          {players.map((p) => (
            <option key={p.id} value={p.id}>
              {p.jersey_number != null ? `#${p.jersey_number} ` : ''}
              {p.name}
            </option>
          ))}
        </select>
        {mode === 'game' && (
          <input
            className="input"
            placeholder="Opponent"
            value={opponent}
            onChange={(e) => setOpponent(e.target.value)}
            style={{ flex: 1, minWidth: 100 }}
          />
        )}
        <button
          className="btn btn-teal"
          onClick={() => start.mutate()}
          disabled={start.isPending || !mainPlayer}
        >
          Start session
        </button>
      </div>
      {start.isError && <p className="error-text">{(start.error as Error).message}</p>}
      <ModeFilter value={filter} onChange={setFilter} />
      {sessions.map((s) => (
        <div className="row-item" key={s.id}>
          <span className="row-main" onClick={() => navigate(`/session/${s.id}`)}>
            {fmtDate(s.started_at)}
            {s.mode === 'game' && s.team_b ? (
              <span className="row-meta"> · vs {s.team_b}</span>
            ) : null}
          </span>
          <ModeTag mode={s.mode} />
          <StatusTag s={s} />
        </div>
      ))}
      {sessionsQ.isSuccess && sessions.length === 0 && (
        <p className="muted">No {filter === 'all' ? '' : `${filter} `}sessions for this team yet.</p>
      )}
    </div>
  )
}

function RecentSessions({ sessions }: { sessions: RecentSession[] }) {
  const [filter, setFilter] = useState<Mode | 'all'>('all')
  const filtered = sessions.filter((s) => filter === 'all' || s.mode === filter)
  return (
    <div className="card">
      <h2>Recent sessions</h2>
      <p className="card-sub">Across all teams and players</p>
      <ModeFilter value={filter} onChange={setFilter} />
      {filtered.map((s) => (
        <div className="row-item" key={s.id}>
          <span className="row-main" onClick={() => navigate(`/session/${s.id}`)}>
            {s.players?.name ?? 'Unknown player'}
            <span className="row-meta"> · {fmtDate(s.started_at)}</span>
          </span>
          <ModeTag mode={s.mode} />
          <StatusTag s={s} />
        </div>
      ))}
      {filtered.length === 0 && <p className="muted">No sessions.</p>}
    </div>
  )
}
