import { fmtPct } from '../lib/format'
import type { Session, TeamBoxScore } from '../types/contract'

const ROWS: [string, (t: TeamBoxScore) => string][] = [
  ['PTS', (t) => String(t.pts)],
  ['FG', (t) => `${t.fgm}-${t.fga} (${fmtPct(t.fg_pct)})`],
  ['3P', (t) => `${t.three_pm}-${t.three_pa} (${fmtPct(t.three_pct)})`],
  ['FT', (t) => `${t.ftm}-${t.fta} (${fmtPct(t.ft_pct)})`],
  ['eFG%', (t) => fmtPct(t.efg_pct)],
  ['TS%', (t) => fmtPct(t.ts_pct)],
]

/** Side-by-side team box score for game sessions. */
export default function TeamPanel({
  session,
  teams,
}: {
  session: Session
  teams: TeamBoxScore[]
}) {
  const byTeam = new Map(teams.map((t) => [t.team, t]))
  const cols: ['A' | 'B', string][] = [
    ['A', session.team_a ?? 'Team A'],
    ['B', session.team_b ?? 'Team B'],
  ]
  return (
    <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 14 }}>
      <thead>
        <tr>
          <th style={{ textAlign: 'left', padding: '6px 0' }} />
          {cols.map(([, name]) => (
            <th key={name} style={{ textAlign: 'right', padding: '6px 0', fontWeight: 700 }}>
              {name}
            </th>
          ))}
        </tr>
      </thead>
      <tbody>
        {ROWS.map(([label, fmt]) => (
          <tr key={label} style={{ borderTop: '1px solid var(--bg-inset)' }}>
            <td style={{ padding: '6px 0', color: 'var(--text-secondary)', fontWeight: 700 }}>
              {label}
            </td>
            {cols.map(([key, name]) => {
              const t = byTeam.get(key)
              return (
                <td key={name} style={{ textAlign: 'right', padding: '6px 0' }}>
                  {t ? fmt(t) : '—'}
                </td>
              )
            })}
          </tr>
        ))}
      </tbody>
    </table>
  )
}
