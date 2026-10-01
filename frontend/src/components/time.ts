import dayjs, { type Dayjs } from 'dayjs'

/** A time in the form the wire takes: `yyyy-mm-ddThh:MM:ssZ`. */
export function wireTime(time: Date | Dayjs): string {
  return dayjs(time).toDate().toISOString().replace(/\.\d{3}Z$/, 'Z')
}

/** A time for display: its local date and time. */
export function shownTime(time: string): string {
  return dayjs(time).format('YYYY-MM-DD HH:mm')
}
