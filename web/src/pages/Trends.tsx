import {
  BarController,
  BarElement,
  CategoryScale,
  Chart as ChartJS,
  Legend,
  LinearScale,
  LineController,
  LineElement,
  PointElement,
  Tooltip,
} from 'chart.js'
import { Chart } from 'react-chartjs-2'
import { useQuery } from '@tanstack/react-query'
import { fmtDate } from '../lib/format'
import { navigate } from '../lib/router'
import { sb } from '../lib/supabase'
import type { Player, TrendPoint } from '../types/contract'

ChartJS.register(
  BarController,
  BarElement,
  CategoryScale,
  Legend,
  LinearScale,
  LineController,
  LineElement,
  PointElement,
  Tooltip,
)

export default function Trends({ playerId }: { playerId: string }) {
  const playerQ = useQuery({
    queryKey: ['player', playerId],
    queryFn: async () => {
      const { data, error } = await sb()
        .from('players')
        .select('*')
        .eq('id', playerId)
        .single()
      if (error) throw error
      return data as Player
    },
  })

  const trendsQ = useQuery({
    queryKey: ['trends', playerId],
    queryFn: async () => {
      const { data, error } = await sb()
        .from('player_trends')
        .select('*')
        .eq('player_id', playerId)
        .order('started_at')
      if (error) throw error
      return data as TrendPoint[]
    },
  })

  const points = trendsQ.data ?? []

  const line = (label: string, key: 'fg_pct' | 'efg_pct' | 'ts_pct', color: string) => ({
    type: 'line' as const,
    label,
    data: points.map((p) => p[key] * 100),
    borderColor: color,
    backgroundColor: color,
    yAxisID: 'pct',
    tension: 0.3,
    pointRadius: 3,
  })

  const data = {
    labels: points.map((p) => fmtDate(p.started_at)),
    datasets: [
      line('FG%', 'fg_pct', '#ff7a2f'),
      line('eFG%', 'efg_pct', '#00c896'),
      line('TS%', 'ts_pct', '#60a5fa'),
      {
        type: 'bar' as const,
        label: 'PTS',
        data: points.map((p) => p.pts),
        backgroundColor: 'rgba(255, 122, 47, 0.22)',
        yAxisID: 'pts',
        borderRadius: 4,
      },
    ],
  }

  const options = {
    responsive: true,
    maintainAspectRatio: false,
    interaction: { mode: 'index' as const, intersect: false },
    plugins: { legend: { labels: { color: '#9aa4b2' } } },
    scales: {
      x: { ticks: { color: '#5d6b7e' }, grid: { color: '#171d27' } },
      pct: {
        type: 'linear' as const,
        position: 'left' as const,
        min: 0,
        max: 100,
        ticks: { color: '#5d6b7e', callback: (v: string | number) => `${v}%` },
        grid: { color: '#171d27' },
      },
      pts: {
        type: 'linear' as const,
        position: 'right' as const,
        beginAtZero: true,
        ticks: { color: '#5d6b7e' },
        grid: { display: false },
      },
    },
  }

  return (
    <>
      <span className="back-link" onClick={() => navigate('/')}>
        ← All players
      </span>
      <h1 className="page-title">
        {playerQ.data ? `${playerQ.data.name} — trends` : 'Trends'}
      </h1>
      <p className="card-sub">FG% / eFG% / TS% per session, points as bars</p>
      <div className="card">
        {trendsQ.isError && (
          <p className="error-text">{(trendsQ.error as Error).message}</p>
        )}
        {trendsQ.isSuccess && points.length === 0 ? (
          <p className="muted">No sessions recorded for this player yet.</p>
        ) : (
          <div className="chart-wrap">
            <Chart type="bar" data={data} options={options} />
          </div>
        )}
      </div>
    </>
  )
}
