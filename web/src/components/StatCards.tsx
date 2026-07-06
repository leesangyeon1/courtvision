import { fmtPct } from '../lib/format'
import type { BoxScore } from '../types/contract'

export default function StatCards({ box }: { box: BoxScore }) {
  const cards = [
    { label: 'PTS', value: String(box.pts), sub: 'points', orange: true },
    { label: 'FG', value: `${box.fgm}-${box.fga}`, sub: fmtPct(box.fg_pct) },
    { label: '3PT', value: `${box.three_pm}-${box.three_pa}`, sub: fmtPct(box.three_pct) },
    { label: 'FT', value: `${box.ftm}-${box.fta}`, sub: fmtPct(box.ft_pct) },
  ]
  return (
    <div className="hero-row">
      {cards.map((c) => (
        <div className="hero-card" key={c.label}>
          <div className="hero-label">{c.label}</div>
          <div className={`hero-value${c.orange ? ' orange' : ''}`}>{c.value}</div>
          <div className="hero-sub">{c.sub}</div>
        </div>
      ))}
    </div>
  )
}
