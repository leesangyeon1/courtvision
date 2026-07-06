import {
  COURT_H,
  COURT_W,
  FT_CIRCLE_R,
  FT_LINE_Y,
  KEY_HALF_W,
  RIM_X,
  RIM_Y,
  THREE_POINT_PATH,
  ZONE_ANCHORS,
  zoneRegions,
} from '../lib/court'
import { ZONES } from '../types/contract'
import type { ZoneSplit } from '../types/contract'

const REGIONS = zoneRegions(1)
const LINE = { stroke: '#2c3a4e', strokeWidth: 0.25, fill: 'none' } as const

/** cold (blue) -> hot (red) by make percentage */
function heat(pct: number): string {
  return `hsl(${Math.round(210 - pct * 210)}, 72%, 46%)`
}

export default function ZoneHeatmap({ splits }: { splits: ZoneSplit[] }) {
  const byZone = new Map(splits.map((s) => [s.zone, s]))
  return (
    <svg
      className="court-svg"
      viewBox={`0 0 ${COURT_W} ${COURT_H}`}
      role="img"
      aria-label="Zone heatmap"
    >
      {ZONES.map((zone) => {
        const split = byZone.get(zone)
        return (
          <g key={zone} shapeRendering="crispEdges" opacity={split ? 0.55 : 0.25}>
            {REGIONS[zone].map((c, i) => (
              <rect
                key={i}
                x={c.x}
                y={c.y}
                width={c.w + 0.03}
                height={c.h + 0.03}
                fill={split ? heat(split.pct) : '#161d29'}
              />
            ))}
          </g>
        )
      })}
      <rect x={0} y={0} width={COURT_W} height={COURT_H} {...LINE} />
      <rect
        x={RIM_X - KEY_HALF_W}
        y={0}
        width={KEY_HALF_W * 2}
        height={FT_LINE_Y}
        {...LINE}
      />
      <circle cx={RIM_X} cy={FT_LINE_Y} r={FT_CIRCLE_R} {...LINE} />
      <circle
        cx={RIM_X}
        cy={RIM_Y}
        r={0.75}
        stroke="var(--orange)"
        strokeWidth={0.25}
        fill="none"
      />
      <path d={THREE_POINT_PATH} {...LINE} />
      {ZONES.map((zone) => {
        const split = byZone.get(zone)
        if (!split) return null
        const [ax, ay] = ZONE_ANCHORS[zone]
        return (
          <text
            key={zone}
            x={ax}
            y={ay}
            textAnchor="middle"
            fontSize={1.7}
            fontWeight={700}
            fill="#fff"
            stroke="rgba(0, 0, 0, 0.55)"
            strokeWidth={0.35}
            style={{ paintOrder: 'stroke' }}
          >
            {split.made}/{split.attempted}
          </text>
        )
      })}
    </svg>
  )
}
