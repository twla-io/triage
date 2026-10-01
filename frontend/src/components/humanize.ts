/** `mustBeSeenBy` → "Must be seen by"; `MatchToSlot` → "Match to slot". */
export function humanize(name: string): string {
  const words = name.replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase()
  return words.charAt(0).toUpperCase() + words.slice(1)
}

/** The same words for use mid-sentence: `intakeRequest` → "intake request". */
export function humanizeLower(name: string): string {
  return name.replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase()
}

/** The article a humanized entity takes: "an intake request", "a slot". */
export function withArticle(name: string): string {
  const words = humanizeLower(name)
  return /^[aeiou]/.test(words) ? `an ${words}` : `a ${words}`
}
