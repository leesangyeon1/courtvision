import { useEffect, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import HalfCourtShotChart from '../components/HalfCourtShotChart'
import SplitsPanel from '../components/SplitsPanel'
import StatCards from '../components/StatCards'
import ThreeCourt from '../components/ThreeCourt'
import ZoneHeatmap from '../components/ZoneHeatmap'
import TeamPanel from '../components/TeamPanel'
import { freshness } from '../lib/freshness'
import { navigate } from '../lib/router'
import { sb } from '../lib/supabase'
import type { BoxScore, EventRow, Player, PlayerBoxScore, Session, TeamBoxScore, ZoneSplit } from '../types/contract'

const POLL_MS = 10_000 // fallback path; Realtime INSERTs invalidate sooner

export default function SessionView({ sessionId }: { sessionId: string }) {
  const qc = useQueryClient()

  const boxQ = useQuery({
    queryKey: ['box', sessionId],
    refetchInterval: POLL_MS,
    queryFn: async () => {
      const { data, error } = await sb()
        .from('session_box_scores')
        .select('*')
        .eq('session_id', sessionId)
        .single()
      if (error) throw error
      return data as BoxScore
    },
  })

  const shotsQ = useQuery({
    queryKey: ['shots', sessionId],
    refetchInterval: POLL_MS,
    queryFn: async () => {
      const { data, error } = await sb()
        .from('events')
        .select('*')
        .eq('session_id', sessionId)
        .order('ts')
      if (error) throw error
      return data as EventRow[]
    },
  })

  const zonesQ = useQuery({
    queryKey: ['zones', sessionId],
    refetchInterval: POLL_MS,
    queryFn: async () => {
      const { data, error } = await sb()
        .from('session_zone_splits')
        .select('*')
        .eq('session_id', sessionId)
      if (error) throw error
      return data as ZoneSplit[]
    },
  })

  // Game sessions: team names + per-team box scores.
  const sessionQ = useQuery({
    queryKey: ['session', sessionId],
    queryFn: async () => {
      const { data, error } = await sb()
        .from('sessions')
        .select('*')
        .eq('id', sessionId)
        .single()
      if (error) throw error
      return data as Session
    },
  })

  // Per-player attribution (game mode: shooter identified by jersey number).
  const playerBoxQ = useQuery({
    queryKey: ['player-box', sessionId],
    refetchInterval: POLL_MS,
    enabled: sessionQ.data?.mode === 'game',
    queryFn: async () => {
      const { data, error } = await sb()
        .from('session_player_box_scores')
        .select('*')
        .eq('session_id', sessionId)
      if (error) throw error
      return data as PlayerBoxScore[]
    },
  })

  const rosterQ = useQuery({
    queryKey: ['roster', sessionQ.data?.team_id],
    enabled: !!sessionQ.data?.team_id,
    queryFn: async () => {
      const { data, error } = await sb()
        .from('players')
        .select('*')
        .eq('team_id', sessionQ.data!.team_id!)
      if (error) throw error
      return data as Player[]
    },
  })

  const teamsQ = useQuery({
    queryKey: ['teams', sessionId],
    refetchInterval: POLL_MS,
    enabled: sessionQ.data?.mode === 'game',
    queryFn: async () => {
      const { data, error } = await sb()
        .from('session_team_box_scores')
        .select('*')
        .eq('session_id', sessionId)
      if (error) throw error
      return data as TeamBoxScore[]
    },
  })

  // Fast path: Realtime INSERTs on this session's events invalidate the queries.
  useEffect(() => {
    const channel = sb()
      .channel(`session-${sessionId}`)
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'public',
          table: 'events',
          filter: `session_id=eq.${sessionId}`,
        },
        () => {
          qc.invalidateQueries({ queryKey: ['box', sessionId] })
          qc.invalidateQueries({ queryKey: ['shots', sessionId] })
          qc.invalidateQueries({ queryKey: ['zones', sessionId] })
          qc.invalidateQueries({ queryKey: ['teams', sessionId] })
          qc.invalidateQueries({ queryKey: ['player-box', sessionId] })
        },
      )
      .subscribe()
    return () => {
      void sb().removeChannel(channel)
    }
  }, [sessionId, qc])

  // Freshness badge ticks every second off the newest successful fetch.
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(t)
  }, [])

  const lastDataAt = Math.max(
    boxQ.dataUpdatedAt,
    shotsQ.dataUpdatedAt,
    zonesQ.dataUpdatedAt,
  )
  const fresh = freshness(now, lastDataAt, boxQ.data?.status)

  const shots = shotsQ.data ?? []
  const zones = zonesQ.data ?? []

  return (
    <>
      <span className="back-link" onClick={() => navigate('/')}>
        ← All sessions
      </span>
      <div>
        <span className={`badge ${fresh.tone}`}>
          {fresh.tone === 'live' && <span className="live-dot" />}
          {fresh.label}
        </span>
      </div>

      {boxQ.isError && (
        <div className="card">
          <h2>Session unavailable</h2>
          <p className="error-text">{(boxQ.error as Error).message}</p>
        </div>
      )}

      {boxQ.data && <StatCards box={boxQ.data} />}

      {sessionQ.data?.mode === 'game' && (
        <div className="card">
          <h2>Player box score</h2>
          <p className="card-sub">Shots attributed by detected jersey number</p>
          {playerBoxQ.data?.length ? (
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 14 }}>
              <thead>
                <tr style={{ color: 'var(--text-secondary)' }}>
                  <th style={{ textAlign: 'left', padding: '6px 0' }}>Player</th>
                  <th style={{ textAlign: 'right' }}>PTS</th>
                  <th style={{ textAlign: 'right' }}>FG</th>
                  <th style={{ textAlign: 'right' }}>3P</th>
                  <th style={{ textAlign: 'right' }}>FT</th>
                </tr>
              </thead>
              <tbody>
                {[...playerBoxQ.data]
                  .sort((a, b) => b.pts - a.pts)
                  .map((row) => {
                    const p = (rosterQ.data ?? []).find((pl) => pl.id === row.player_id)
                    return (
                      <tr key={row.player_id} style={{ borderTop: '1px solid var(--bg-inset)' }}>
                        <td style={{ padding: '6px 0' }}>
                          {p ? `${p.jersey_number != null ? `#${p.jersey_number} ` : ''}${p.name}` : 'Unknown'}
                        </td>
                        <td style={{ textAlign: 'right', fontWeight: 700 }}>{row.pts}</td>
                        <td style={{ textAlign: 'right' }}>{row.fgm}-{row.fga}</td>
                        <td style={{ textAlign: 'right' }}>{row.three_pm}-{row.three_pa}</td>
                        <td style={{ textAlign: 'right' }}>{row.ftm}-{row.fta}</td>
                      </tr>
                    )
                  })}
              </tbody>
            </table>
          ) : (
            <p className="muted">No player-attributed shots yet…</p>
          )}
        </div>
      )}

      {sessionQ.data?.mode === 'game' && (
        <div className="card">
          <h2>Teams</h2>
          <p className="card-sub">
            {sessionQ.data.team_a ?? 'Team A'} vs {sessionQ.data.team_b ?? 'Team B'} — server-derived
            from session_team_box_scores
          </p>
          {teamsQ.data?.length ? (
            <TeamPanel session={sessionQ.data} teams={teamsQ.data} />
          ) : (
            <p className="muted">No team-attributed shots yet…</p>
          )}
        </div>
      )}

      <div className="grid-2">
        <div className="card">
          <h2>Shot chart</h2>
          <p className="card-sub">Every attempt at its court location</p>
          <HalfCourtShotChart shots={shots} />
        </div>
        <div className="card">
          <h2>3D court</h2>
          <p className="card-sub">Shot arcs to the rim — drag to orbit, scroll to zoom</p>
          <ThreeCourt shots={shots} />
        </div>
      </div>

      <div className="grid-2">
        <div className="card">
          <h2>Zone heatmap</h2>
          <p className="card-sub">Make % by zone (made/attempted)</p>
          <ZoneHeatmap splits={zones} />
        </div>
        <div className="card">
          <h2>Shooting splits</h2>
          <p className="card-sub">Server-derived from session_box_scores</p>
          {boxQ.data ? (
            <SplitsPanel box={boxQ.data} />
          ) : (
            <p className="muted">Waiting for data…</p>
          )}
        </div>
      </div>
    </>
  )
}
