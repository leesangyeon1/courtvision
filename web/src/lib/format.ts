/** 0.5102 -> "51.0%" */
export function fmtPct(v: number): string {
  return `${(v * 100).toFixed(1)}%`
}

/** ISO timestamp -> short locale date+time, e.g. "Jul 5, 3:42 PM". */
export function fmtDate(iso: string): string {
  return new Date(iso).toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  })
}
