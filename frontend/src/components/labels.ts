import dayjs from 'dayjs'

// A Domain.hs name humanized: `mustBeSeenBy` → "Must be seen by",
// `QuarterOfAnHour` → "Quarter of an hour".
export function humanize(name: string): string {
  const words = name
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/([A-Z])([A-Z][a-z])/g, '$1 $2')
    .toLowerCase()
  return words.charAt(0).toUpperCase() + words.slice(1)
}

// The same, for use inside a sentence.
export const humanizeLower = (name: string): string => humanize(name).toLowerCase()

// A time shows date and time, in the browser's time zone.
export const formatTime = (utc: string): string => dayjs(utc).format('YYYY-MM-DD HH:mm')

// A Date in the API's UTCTime format (yyyy-mm-ddThh:MM:ssZ).
export const toUtcTime = (date: Date): string => date.toISOString().replace(/\.\d{3}Z$/, 'Z')
