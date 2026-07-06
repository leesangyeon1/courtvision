import { fmtPct } from '../lib/format'
import type { BoxScore } from '../types/contract'

const ROWS: [string, keyof Pick<BoxScore, 'fg_pct' | 'three_pct' | 'ft_pct' | 'efg_pct' | 'ts_pct'>, string][] = [
  ['FG%', 'fg_pct', 'var(--orange)'],
  ['3P%', 'three_pct', 'var(--teal)'],
  ['FT%', 'ft_pct', '#60a5fa'],
  ['eFG%', 'efg_pct', '#a78bfa'],
  ['TS%', 'ts_pct', '#f472b6'],
]

export default function SplitsPanel({ box }: { box: BoxScore }) {
  return (
    <div>
      {ROWS.map(([label, key, color]) => {
        const v = box[key]
        return (
          <div
            key={label}
            style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '8px 0' }}
          >
            <span
              style={{
                width: 44,
                fontSize: 12,
                fontWeight: 700,
                color: 'var(--text-secondary)',
              }}
            >
              {label}
            </span>
            <div
              style={{
                flex: 1,
                height: 10,
                borderRadius: 5,
                background: 'var(--bg-inset)',
                overflow: 'hidden',
              }}
            >
              <div
                style={{
                  width: `${Math.min(100, v * 100)}%`,
                  height: '100%',
                  borderRadius: 5,
                  background: color,
                  transition: 'width 0.4s',
                }}
              />
            </div>
            <span style={{ width: 52, textAlign: 'right', fontSize: 13, fontWeight: 700 }}>
              {fmtPct(v)}
            </span>
          </div>
        )
      })}
    </div>
  )
}
