import { useEffect, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import HalfCourtShotChart from '../components/HalfCourtShotChart'
import SplitsPanel from '../components/SplitsPanel'
import StatCards from '../components/StatCards'
import ThreeCourt from '../components/ThreeCourt'
import ZoneHeatmap from '../components/ZoneHeatmap'
import { freshness } from '../lib/freshness'
import { navigate } from '../lib/router'
import { sb } from '../lib/supabase'
import type { BoxScore, EventRow, ZoneSplit } from '../types/contract'

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
