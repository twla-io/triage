import type { Schemas } from '../api/client'

function words(name: string): string {
  return name.replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase()
}

// `fooBarBaz` and `FooBarBaz` both become "Foo bar baz".
export function humanize(name: string): string {
  const text = words(name)
  return text.charAt(0).toUpperCase() + text.slice(1)
}

// The same words, lower case, for use inside a sentence.
export function inSentence(name: string): string {
  return words(name)
}

export function withArticle(name: string): string {
  const text = words(name)
  return `${/^[aeiou]/.test(text) ? 'an' : 'a'} ${text}`
}

// A use case is an answer schema's name without `Answer`.
export type UseCase = {
  [K in keyof Schemas]: K extends `${infer U}Answer` ? U : never
}[keyof Schemas]

// An action's label: its use case's name minus its entity and source case, humanized.
export function actionLabel(useCase: UseCase, entity: string, sourceCase = ''): string {
  return humanize(useCase.replace(`${sourceCase}${entity}`, ''))
}
