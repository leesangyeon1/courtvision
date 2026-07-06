/** 0.5102 -> "51.0%" */
export function fmtPct(v: number): string {
  return `${(v * 100).toFixed(1)}%`
}
