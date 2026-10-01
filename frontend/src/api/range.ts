// A week is the half-open [Monday 00:00, next Monday 00:00) in local time.
export type Week = { from: Date; to: Date }

function weekStartingOn(monday: Date): Week {
  const to = new Date(monday)
  to.setDate(to.getDate() + 7)
  return { from: monday, to }
}

export function currentWeek(): Week {
  const monday = new Date()
  monday.setHours(0, 0, 0, 0)
  monday.setDate(monday.getDate() - ((monday.getDay() + 6) % 7))
  return weekStartingOn(monday)
}

export function shiftWeek(week: Week, by: number): Week {
  const monday = new Date(week.from)
  monday.setDate(monday.getDate() + 7 * by)
  return weekStartingOn(monday)
}

function utc(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z')
}

export function rangeQuery(week: Week): { from: string; to: string } {
  return { from: utc(week.from), to: utc(week.to) }
}
