import {
  COURT_H,
  COURT_W,
  FT_CIRCLE_R,
  FT_LINE_Y,
  KEY_HALF_W,
  RIM_X,
  RIM_Y,
  THREE_POINT_PATH,
} from '../lib/court'
import type { EventRow } from '../types/contract'

const LINE = { stroke: '#2c3a4e', strokeWidth: 0.25, fill: 'none' } as const

export default function HalfCourtShotChart({ shots }: { shots: EventRow[] }) {
  return (
    <>
      <svg
        className="court-svg"
        viewBox={`0 0 ${COURT_W} ${COURT_H}`}
        role="img"
        aria-label="Half-court shot chart"
      >
        {/* court lines: border, paint, FT circle, backboard, rim, 3-pt line */}
        <rect x={0} y={0} width={COURT_W} height={COURT_H} {...LINE} />
        <rect
          x={RIM_X - KEY_HALF_W}
          y={0}
          width={KEY_HALF_W * 2}
          height={FT_LINE_Y}
          {...LINE}
        />
        <circle cx={RIM_X} cy={FT_LINE_Y} r={FT_CIRCLE_R} {...LINE} />
        <line x1={RIM_X - 3} y1={4} x2={RIM_X + 3} y2={4} {...LINE} />
        <circle
          cx={RIM_X}
          cy={RIM_Y}
          r={0.75}
          stroke="var(--orange)"
          strokeWidth={0.25}
          fill="none"
        />
        <path d={THREE_POINT_PATH} {...LINE} />
        {shots.map((s) => {
          const x = s.court_x * COURT_W
          const y = s.court_y * COURT_H
          return s.made ? (
            <circle key={s.id} cx={x} cy={y} r={0.55} fill="var(--green)" opacity={0.9} />
          ) : (
            <circle
              key={s.id}
              cx={x}
              cy={y}
              r={0.5}
              fill="none"
              stroke="var(--red)"
              strokeWidth={0.28}
              opacity={0.9}
            />
          )
        })}
      </svg>
      <div className="legend-row">
        <div className="legend-item">
          <span className="dot green" /> Made
        </div>
        <div className="legend-item">
          <span className="dot red" /> Miss
        </div>
      </div>
    </>
  )
}
