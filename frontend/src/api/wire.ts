// Exact wire types, derived from Domain.hs (sums-come-from-domain).
//
// Swagger 2.0 can't express a sum type, so the generated type of a sum is one
// object with a `type` enum and every case's keys optional, and an answer's
// `detail` is untyped. This module declares:
// - each sum type crossing the wire: an exact discriminated union, one member
//   per constructor, embedded stages flattened like the API does;
// - each use case's answer: a union over its outcome tags with exact details;
// - one narrowing function per sum type, generated type -> exact union.
// Records that are not a case of a sum type come from types.ts unchanged.
// Stage records (the payloads of IntakeRequest's cases) are delivered in the form of their
// IntakeRequest case, so their own sum-typed fields are exact too.
//
// It is the only module that imports from types.ts.

import type { components } from './types'

type S = components['schemas']

// ═══════════════════════════════════════════════════════════════════════════
// Records and ids (unchanged from types.ts)
// ═══════════════════════════════════════════════════════════════════════════

export type DoctorId = S['DoctorId']
export type PatientId = S['PatientId']
export type HealthcareServiceId = S['HealthcareServiceId']
export type IntakeRequestId = S['IntakeRequestId']
export type SlotId = S['SlotId']
export type UTCTime = S['UTCTime']

export type Doctor = S['Doctor']
export type Patient = S['Patient']
export type HealthcareService = S['HealthcareService']
export type AvailableSlot = S['AvailableSlot']

export type CreateDoctorRequest = S['CreateDoctorRequest']
export type CreatePatientRequest = S['CreatePatientRequest']
export type CreateHealthcareServiceRequest = S['CreateHealthcareServiceRequest']
export type CreateAvailableSlotRequest = S['CreateAvailableSlotRequest']
export type SubmitIntakeRequestRequest = S['SubmitIntakeRequestRequest']
export type RejectSubmittedIntakeRequestRequest = S['RejectSubmittedIntakeRequestRequest']
export type WithdrawIntakeRequestRequest = S['WithdrawIntakeRequestRequest']
export type MatchAcceptedIntakeRequestToSlotRequest = S['MatchAcceptedIntakeRequestToSlotRequest']

// ═══════════════════════════════════════════════════════════════════════════
// Constructor lists (constructor order; adding a constructor fails to compile
// until it is listed)
// ═══════════════════════════════════════════════════════════════════════════

function allOf<T extends string>() {
  return <const A extends readonly T[]>(
    tags: A,
    ..._exhaustive: [Exclude<T, A[number]>] extends [never] ? [] : [missing: Exclude<T, A[number]>]
  ): A => tags
}

export const durationTags = allOf<S['Duration']['type']>()(['quarterOfAnHour', 'halfAnHour', 'oneHour'])
export const appointmentPartyTags = allOf<S['AppointmentParty']['type']>()(['doctorParty', 'patientParty'])
export const doctorRequirementTags = allOf<S['DoctorRequirement']['type']>()(['anyDoctor', 'specificDoctor'])
export const routineDueTags = allOf<S['RoutineDue']['type']>()([
  'routineAnytime',
  'routineNotBefore',
  'routineNotAfter',
  'routineWithin',
])
export const intakeRequestPriorityTags = allOf<S['IntakeRequestPriority']['type']>()(['emergency', 'urgent', 'routine'])
export const closeReasonTags = allOf<S['CloseReasonRequest']['type']>()(['completed', 'cancelled', 'noShow'])
const closeReasonResponseTags = allOf<S['CloseReason']['type']>()(['completed', 'cancelled', 'noShow'])
export const intakeRequestTags = allOf<S['IntakeRequest']['type']>()([
  'submitted',
  'rejected',
  'accepted',
  'appointed',
  'withdrawn',
  'stale',
  'closed',
])
const withdrawnFromTags = allOf<S['WithdrawnIntakeRequest']['withdrawnFrom']['type']>()(['fromSubmitted', 'fromAccepted'])
const doctorCalendarEntryTags = allOf<S['DoctorCalendarEntry']['type']>()(['slot', 'appointment'])

// ═══════════════════════════════════════════════════════════════════════════
// Exact sum types
// ═══════════════════════════════════════════════════════════════════════════

export type Duration = { type: 'quarterOfAnHour' } | { type: 'halfAnHour' } | { type: 'oneHour' }

export type AppointmentParty = { type: 'doctorParty' } | { type: 'patientParty' }

export type DoctorRequirement = { type: 'anyDoctor' } | { type: 'specificDoctor'; specificDoctor: DoctorId }

export type RoutineDue =
  | { type: 'routineAnytime' }
  | { type: 'routineNotBefore'; routineNotBefore: UTCTime }
  | { type: 'routineNotAfter'; routineNotAfter: UTCTime }
  | { type: 'routineWithin'; routineNotBefore: UTCTime; routineNotAfter: UTCTime }

export type IntakeRequestPriority =
  | { type: 'emergency'; mustBeSeenBy: UTCTime }
  | { type: 'urgent'; mustBeSeenBy: UTCTime }
  | { type: 'routine'; routine: RoutineDue }

export type CloseReason =
  | { type: 'completed' }
  | { type: 'cancelled'; cancelledBy: AppointmentParty; cancelledAt: UTCTime; cancellationNote?: string }
  | { type: 'noShow'; absentParty: AppointmentParty }

// The request form of CloseReason: cancelledAt is recorded by the server.
export type CloseReasonRequest =
  | { type: 'completed' }
  | { type: 'cancelled'; cancelledBy: AppointmentParty; cancellationNote?: string }
  | { type: 'noShow'; absentParty: AppointmentParty }

// Stage records, flattened the way the API sends them.
export interface SubmittedFields {
  id: IntakeRequestId
  patientId: PatientId
  narrative: string
  createdAt: UTCTime
}

export interface TriagedFields extends SubmittedFields {
  healthcareServiceId: HealthcareServiceId
  priority: IntakeRequestPriority
  doctorRequirement: DoctorRequirement
  triagedAt: UTCTime
}

export interface AppointedFields extends TriagedFields {
  doctorId: DoctorId
  start: UTCTime
  duration: Duration
}

export type WithdrawnFrom =
  | ({ withdrawnFrom: { type: 'fromSubmitted' } } & SubmittedFields)
  | ({ withdrawnFrom: { type: 'fromAccepted' } } & TriagedFields)

export type WithdrawnIntakeRequest = WithdrawnFrom & { withdrawnAt: UTCTime; withdrawalNote?: string }

// TypeScript doesn't narrow a union by a nested tag; this checks the tag.
export function isWithdrawnFromAccepted<W extends WithdrawnFrom>(
  w: W,
): w is Extract<W, { withdrawnFrom: { type: 'fromAccepted' } }> {
  return w.withdrawnFrom.type === 'fromAccepted'
}

export type IntakeRequest =
  | ({ type: 'submitted' } & SubmittedFields)
  | ({ type: 'rejected' } & SubmittedFields & { rejectedAt: UTCTime; rejectionReason: string })
  | ({ type: 'accepted' } & TriagedFields)
  | ({ type: 'appointed' } & AppointedFields)
  | ({ type: 'withdrawn' } & WithdrawnIntakeRequest)
  | ({ type: 'stale' } & TriagedFields & { staleAt: UTCTime })
  | ({ type: 'closed' } & AppointedFields & { closeReason: CloseReason })

export type IntakeRequestOf<T extends IntakeRequest['type']> = Extract<IntakeRequest, { type: T }>

export interface AvailableSlotFields {
  id: SlotId
  doctorId: DoctorId
  healthcareServiceId: HealthcareServiceId
  start: UTCTime
  duration: Duration
}

export type DoctorCalendarEntry =
  | ({ type: 'slot' } & AvailableSlotFields)
  | ({ type: 'appointment' } & AppointedFields)

// Request bodies carrying sum types, checked against the generated shapes.
type Checked<A extends B, B> = A

export type AcceptSubmittedIntakeRequestRequest = Checked<
  {
    healthcareServiceId: HealthcareServiceId
    priority: IntakeRequestPriority
    doctorRequirement: DoctorRequirement
  },
  S['AcceptSubmittedIntakeRequestRequest']
>

export type CloseAppointedIntakeRequestRequest = Checked<
  { closeReason: CloseReasonRequest },
  S['CloseAppointedIntakeRequestRequest']
>

// ═══════════════════════════════════════════════════════════════════════════
// Decoding untyped JSON into the generated types
// ═══════════════════════════════════════════════════════════════════════════

export class DecodeError extends Error {
  constructor(message: string) {
    super(`Unexpected response: ${message}`)
    this.name = 'DecodeError'
  }
}

type Json = Record<string, unknown>

function isJsonObject(x: unknown): x is Json {
  return typeof x === 'object' && x !== null && !Array.isArray(x)
}

function obj(x: unknown, what: string): Json {
  if (!isJsonObject(x)) throw new DecodeError(`${what} is not an object`)
  return x
}

function str(x: unknown, what: string): string {
  if (typeof x !== 'string') throw new DecodeError(`${what} is not a string`)
  return x
}

function field(o: Json, key: string, what: string): string {
  return str(o[key], `${what}.${key}`)
}

function optional<T>(o: Json, key: string, decode: (x: unknown, what: string) => T, what: string): T | undefined {
  const v = o[key]
  return v === undefined || v === null ? undefined : decode(v, `${what}.${key}`)
}

function nothing(x: unknown, what: string): null {
  if (x !== null && x !== undefined) throw new DecodeError(`${what} is not null`)
  return null
}

function arrayOf<T>(decode: (x: unknown, what: string) => T) {
  return (x: unknown, what: string): T[] => {
    if (!Array.isArray(x)) throw new DecodeError(`${what} is not an array`)
    return x.map((e, i) => decode(e, `${what}[${i}]`))
  }
}

function tagOf<T extends string>(tags: readonly T[], x: unknown, what: string): T {
  const found = tags.find((t) => t === x)
  if (found === undefined) throw new DecodeError(`${what} carries an unrecognised tag ${JSON.stringify(x)}`)
  return found
}

function need<T>(v: T | undefined, what: string): T {
  if (v === undefined) throw new DecodeError(`${what} is missing`)
  return v
}

const genDuration = (x: unknown, what: string): S['Duration'] => ({
  type: tagOf(durationTags, obj(x, what).type, `${what}.type`),
})

const genAppointmentParty = (x: unknown, what: string): S['AppointmentParty'] => ({
  type: tagOf(appointmentPartyTags, obj(x, what).type, `${what}.type`),
})

function genDoctorRequirement(x: unknown, what: string): S['DoctorRequirement'] {
  const o = obj(x, what)
  return {
    type: tagOf(doctorRequirementTags, o.type, `${what}.type`),
    specificDoctor: optional(o, 'specificDoctor', str, what),
  }
}

function genRoutineDue(x: unknown, what: string): S['RoutineDue'] {
  const o = obj(x, what)
  return {
    type: tagOf(routineDueTags, o.type, `${what}.type`),
    routineNotBefore: optional(o, 'routineNotBefore', str, what),
    routineNotAfter: optional(o, 'routineNotAfter', str, what),
  }
}

function genIntakeRequestPriority(x: unknown, what: string): S['IntakeRequestPriority'] {
  const o = obj(x, what)
  return {
    type: tagOf(intakeRequestPriorityTags, o.type, `${what}.type`),
    mustBeSeenBy: optional(o, 'mustBeSeenBy', str, what),
    routine: optional(o, 'routine', genRoutineDue, what),
  }
}

function genCloseReason(x: unknown, what: string): S['CloseReason'] {
  const o = obj(x, what)
  return {
    type: tagOf(closeReasonResponseTags, o.type, `${what}.type`),
    cancelledBy: optional(o, 'cancelledBy', genAppointmentParty, what),
    cancelledAt: optional(o, 'cancelledAt', str, what),
    cancellationNote: optional(o, 'cancellationNote', str, what),
    absentParty: optional(o, 'absentParty', genAppointmentParty, what),
  }
}

function genWithdrawnFrom(x: unknown, what: string): S['WithdrawnIntakeRequest']['withdrawnFrom'] {
  return { type: tagOf(withdrawnFromTags, obj(x, what).type, `${what}.type`) }
}

function genDoctor(x: unknown, what: string): Doctor {
  const o = obj(x, what)
  return { id: field(o, 'id', what), name: field(o, 'name', what) }
}

function genPatient(x: unknown, what: string): Patient {
  const o = obj(x, what)
  return { id: field(o, 'id', what), name: field(o, 'name', what) }
}

function genHealthcareService(x: unknown, what: string): HealthcareService {
  const o = obj(x, what)
  return { id: field(o, 'id', what), name: field(o, 'name', what), duration: genDuration(o.duration, `${what}.duration`) }
}

function genAvailableSlot(x: unknown, what: string): AvailableSlot {
  const o = obj(x, what)
  return {
    id: field(o, 'id', what),
    doctorId: field(o, 'doctorId', what),
    healthcareServiceId: field(o, 'healthcareServiceId', what),
    start: field(o, 'start', what),
    duration: genDuration(o.duration, `${what}.duration`),
  }
}

// Every stage key, optional: the shape shared by the generated IntakeRequest,
// stage records, WithdrawnIntakeRequest and DoctorCalendarEntry.
interface LooseStage {
  id?: string
  patientId?: string
  narrative?: string
  createdAt?: string
  healthcareServiceId?: string
  priority?: S['IntakeRequestPriority']
  doctorRequirement?: S['DoctorRequirement']
  triagedAt?: string
  doctorId?: string
  start?: string
  duration?: S['Duration']
}

function genLooseStage(o: Json, what: string): LooseStage {
  return {
    id: optional(o, 'id', str, what),
    patientId: optional(o, 'patientId', str, what),
    narrative: optional(o, 'narrative', str, what),
    createdAt: optional(o, 'createdAt', str, what),
    healthcareServiceId: optional(o, 'healthcareServiceId', str, what),
    priority: optional(o, 'priority', genIntakeRequestPriority, what),
    doctorRequirement: optional(o, 'doctorRequirement', genDoctorRequirement, what),
    triagedAt: optional(o, 'triagedAt', str, what),
    doctorId: optional(o, 'doctorId', str, what),
    start: optional(o, 'start', str, what),
    duration: optional(o, 'duration', genDuration, what),
  }
}

function genIntakeRequest(x: unknown, what: string): S['IntakeRequest'] {
  const o = obj(x, what)
  const s = genLooseStage(o, what)
  return {
    ...s,
    type: tagOf(intakeRequestTags, o.type, `${what}.type`),
    id: need(s.id, `${what}.id`),
    patientId: need(s.patientId, `${what}.patientId`),
    narrative: need(s.narrative, `${what}.narrative`),
    createdAt: need(s.createdAt, `${what}.createdAt`),
    rejectedAt: optional(o, 'rejectedAt', str, what),
    rejectionReason: optional(o, 'rejectionReason', str, what),
    withdrawnFrom: optional(o, 'withdrawnFrom', genWithdrawnFrom, what),
    withdrawnAt: optional(o, 'withdrawnAt', str, what),
    withdrawalNote: optional(o, 'withdrawalNote', str, what),
    staleAt: optional(o, 'staleAt', str, what),
    closeReason: optional(o, 'closeReason', genCloseReason, what),
  }
}

function genWithdrawnIntakeRequest(x: unknown, what: string): S['WithdrawnIntakeRequest'] {
  const o = obj(x, what)
  const s = genLooseStage(o, what)
  return {
    ...s,
    id: need(s.id, `${what}.id`),
    patientId: need(s.patientId, `${what}.patientId`),
    narrative: need(s.narrative, `${what}.narrative`),
    createdAt: need(s.createdAt, `${what}.createdAt`),
    withdrawnFrom: genWithdrawnFrom(o.withdrawnFrom, `${what}.withdrawnFrom`),
    withdrawnAt: field(o, 'withdrawnAt', what),
    withdrawalNote: optional(o, 'withdrawalNote', str, what),
  }
}

function genDoctorCalendarEntry(x: unknown, what: string): S['DoctorCalendarEntry'] {
  const o = obj(x, what)
  const s = genLooseStage(o, what)
  return {
    ...s,
    type: tagOf(doctorCalendarEntryTags, o.type, `${what}.type`),
    id: need(s.id, `${what}.id`),
    doctorId: need(s.doctorId, `${what}.doctorId`),
    healthcareServiceId: need(s.healthcareServiceId, `${what}.healthcareServiceId`),
    start: need(s.start, `${what}.start`),
    duration: need(s.duration, `${what}.duration`),
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Narrowing: generated type → exact union (one per sum type)
// ═══════════════════════════════════════════════════════════════════════════

export function narrowDuration(g: S['Duration']): Duration {
  switch (g.type) {
    case 'quarterOfAnHour':
      return { type: 'quarterOfAnHour' }
    case 'halfAnHour':
      return { type: 'halfAnHour' }
    case 'oneHour':
      return { type: 'oneHour' }
  }
}

export function narrowAppointmentParty(g: S['AppointmentParty']): AppointmentParty {
  switch (g.type) {
    case 'doctorParty':
      return { type: 'doctorParty' }
    case 'patientParty':
      return { type: 'patientParty' }
  }
}

export function narrowDoctorRequirement(g: S['DoctorRequirement']): DoctorRequirement {
  switch (g.type) {
    case 'anyDoctor':
      return { type: 'anyDoctor' }
    case 'specificDoctor':
      return { type: 'specificDoctor', specificDoctor: need(g.specificDoctor, 'specificDoctor') }
  }
}

export function narrowRoutineDue(g: S['RoutineDue']): RoutineDue {
  switch (g.type) {
    case 'routineAnytime':
      return { type: 'routineAnytime' }
    case 'routineNotBefore':
      return { type: 'routineNotBefore', routineNotBefore: need(g.routineNotBefore, 'routineNotBefore') }
    case 'routineNotAfter':
      return { type: 'routineNotAfter', routineNotAfter: need(g.routineNotAfter, 'routineNotAfter') }
    case 'routineWithin':
      return {
        type: 'routineWithin',
        routineNotBefore: need(g.routineNotBefore, 'routineNotBefore'),
        routineNotAfter: need(g.routineNotAfter, 'routineNotAfter'),
      }
  }
}

export function narrowIntakeRequestPriority(g: S['IntakeRequestPriority']): IntakeRequestPriority {
  switch (g.type) {
    case 'emergency':
      return { type: 'emergency', mustBeSeenBy: need(g.mustBeSeenBy, 'mustBeSeenBy') }
    case 'urgent':
      return { type: 'urgent', mustBeSeenBy: need(g.mustBeSeenBy, 'mustBeSeenBy') }
    case 'routine':
      return { type: 'routine', routine: narrowRoutineDue(need(g.routine, 'routine')) }
  }
}

export function narrowCloseReason(g: S['CloseReason']): CloseReason {
  switch (g.type) {
    case 'completed':
      return { type: 'completed' }
    case 'cancelled':
      return {
        type: 'cancelled',
        cancelledBy: narrowAppointmentParty(need(g.cancelledBy, 'cancelledBy')),
        cancelledAt: need(g.cancelledAt, 'cancelledAt'),
        cancellationNote: g.cancellationNote,
      }
    case 'noShow':
      return { type: 'noShow', absentParty: narrowAppointmentParty(need(g.absentParty, 'absentParty')) }
  }
}

function submittedFields(g: LooseStage): SubmittedFields {
  return {
    id: need(g.id, 'id'),
    patientId: need(g.patientId, 'patientId'),
    narrative: need(g.narrative, 'narrative'),
    createdAt: need(g.createdAt, 'createdAt'),
  }
}

function triagedFields(g: LooseStage): TriagedFields {
  return {
    ...submittedFields(g),
    healthcareServiceId: need(g.healthcareServiceId, 'healthcareServiceId'),
    priority: narrowIntakeRequestPriority(need(g.priority, 'priority')),
    doctorRequirement: narrowDoctorRequirement(need(g.doctorRequirement, 'doctorRequirement')),
    triagedAt: need(g.triagedAt, 'triagedAt'),
  }
}

function appointedFields(g: LooseStage): AppointedFields {
  return {
    ...triagedFields(g),
    doctorId: need(g.doctorId, 'doctorId'),
    start: need(g.start, 'start'),
    duration: narrowDuration(need(g.duration, 'duration')),
  }
}

export function narrowWithdrawnIntakeRequest(
  g: LooseStage & Pick<S['WithdrawnIntakeRequest'], 'withdrawalNote'> & {
    withdrawnFrom?: S['WithdrawnIntakeRequest']['withdrawnFrom']
    withdrawnAt?: UTCTime
  },
): WithdrawnIntakeRequest {
  const facts = { withdrawnAt: need(g.withdrawnAt, 'withdrawnAt'), withdrawalNote: g.withdrawalNote }
  const from = need(g.withdrawnFrom, 'withdrawnFrom')
  switch (from.type) {
    case 'fromSubmitted':
      return { withdrawnFrom: { type: 'fromSubmitted' }, ...submittedFields(g), ...facts }
    case 'fromAccepted':
      return { withdrawnFrom: { type: 'fromAccepted' }, ...triagedFields(g), ...facts }
  }
}

export function narrowIntakeRequest(g: S['IntakeRequest']): IntakeRequest {
  switch (g.type) {
    case 'submitted':
      return { type: 'submitted', ...submittedFields(g) }
    case 'rejected':
      return {
        type: 'rejected',
        ...submittedFields(g),
        rejectedAt: need(g.rejectedAt, 'rejectedAt'),
        rejectionReason: need(g.rejectionReason, 'rejectionReason'),
      }
    case 'accepted':
      return { type: 'accepted', ...triagedFields(g) }
    case 'appointed':
      return { type: 'appointed', ...appointedFields(g) }
    case 'withdrawn':
      return { type: 'withdrawn', ...narrowWithdrawnIntakeRequest(g) }
    case 'stale':
      return { type: 'stale', ...triagedFields(g), staleAt: need(g.staleAt, 'staleAt') }
    case 'closed':
      return {
        type: 'closed',
        ...appointedFields(g),
        closeReason: narrowCloseReason(need(g.closeReason, 'closeReason')),
      }
  }
}

export function narrowDoctorCalendarEntry(g: S['DoctorCalendarEntry']): DoctorCalendarEntry {
  switch (g.type) {
    case 'slot':
      return {
        type: 'slot',
        id: g.id,
        doctorId: g.doctorId,
        healthcareServiceId: g.healthcareServiceId,
        start: g.start,
        duration: narrowDuration(g.duration),
      }
    case 'appointment':
      return { type: 'appointment', ...appointedFields(g) }
  }
}

// ── Stage records → their IntakeRequest case ───────────────────────────────

const decodeSubmitted = (x: unknown, what: string): IntakeRequestOf<'submitted'> => ({
  type: 'submitted',
  ...submittedFields(genLooseStage(obj(x, what), what)),
})

function decodeRejected(x: unknown, what: string): IntakeRequestOf<'rejected'> {
  const o = obj(x, what)
  return {
    type: 'rejected',
    ...submittedFields(genLooseStage(o, what)),
    rejectedAt: field(o, 'rejectedAt', what),
    rejectionReason: field(o, 'rejectionReason', what),
  }
}

const decodeAccepted = (x: unknown, what: string): IntakeRequestOf<'accepted'> => ({
  type: 'accepted',
  ...triagedFields(genLooseStage(obj(x, what), what)),
})

const decodeAppointed = (x: unknown, what: string): IntakeRequestOf<'appointed'> => ({
  type: 'appointed',
  ...appointedFields(genLooseStage(obj(x, what), what)),
})

const decodeWithdrawn = (x: unknown, what: string): IntakeRequestOf<'withdrawn'> => ({
  type: 'withdrawn',
  ...narrowWithdrawnIntakeRequest(genWithdrawnIntakeRequest(x, what)),
})

function decodeStale(x: unknown, what: string): IntakeRequestOf<'stale'> {
  const o = obj(x, what)
  return { type: 'stale', ...triagedFields(genLooseStage(o, what)), staleAt: field(o, 'staleAt', what) }
}

function decodeClosed(x: unknown, what: string): IntakeRequestOf<'closed'> {
  const o = obj(x, what)
  return {
    type: 'closed',
    ...appointedFields(genLooseStage(o, what)),
    closeReason: narrowCloseReason(genCloseReason(o.closeReason, `${what}.closeReason`)),
  }
}

const decodeIntakeRequest = (x: unknown, what: string): IntakeRequest => narrowIntakeRequest(genIntakeRequest(x, what))

const decodeDoctorCalendarEntry = (x: unknown, what: string): DoctorCalendarEntry =>
  narrowDoctorCalendarEntry(genDoctorCalendarEntry(x, what))

// ═══════════════════════════════════════════════════════════════════════════
// Answers: one union per use case over its outcome tags
// ═══════════════════════════════════════════════════════════════════════════

type Variant<T extends string, D> = { outcome: T; detail: D }

export type ServiceErrorAnswer =
  | Variant<'doctorNotFound', DoctorId>
  | Variant<'patientNotFound', PatientId>
  | Variant<'healthcareServiceNotFound', HealthcareServiceId>
  | Variant<'intakeRequestNotFound', IntakeRequestId>
  | Variant<'intakeRequestInWrongState', IntakeRequest>
  | Variant<'slotDoesNotMatchIntakeRequest', null>

type ServiceErrorTag = ServiceErrorAnswer['outcome']

export type OkAnswer<T> = Variant<'ok', T>
export type OkOrErrorAnswer<T> = Variant<'ok', T> | ServiceErrorAnswer

export type TransitionAnswer<T> = Variant<'transitioned', T> | Variant<'movedOn', IntakeRequest> | ServiceErrorAnswer

export type MatchOutcome =
  | Variant<'matched', IntakeRequestOf<'appointed'>>
  | Variant<'availableSlotConsumed', null>
  | Variant<'intakeRequestMovedOn', IntakeRequest>

export type MatchAcceptedIntakeRequestToSlotAnswer = MatchOutcome | ServiceErrorAnswer

export type MatchAvailableSlotByPriorityAnswer =
  | Variant<'noMatchingIntakeRequest', null>
  | Variant<'matchAttempted', MatchOutcome>
  | ServiceErrorAnswer

export type CreateAvailableSlotAnswer =
  | Variant<'slotCreated', AvailableSlot>
  | Variant<'slotOverlapsDoctorCalendar', null>
  | ServiceErrorAnswer

export type FetchDoctorsAnswer = OkAnswer<Doctor[]>
export type CreateDoctorAnswer = OkAnswer<Doctor>
export type FetchPatientsAnswer = OkAnswer<Patient[]>
export type CreatePatientAnswer = OkAnswer<Patient>
export type FetchHealthcareServicesAnswer = OkOrErrorAnswer<HealthcareService[]>
export type CreateHealthcareServiceAnswer = OkAnswer<HealthcareService>
export type SubmitIntakeRequestAnswer = OkOrErrorAnswer<IntakeRequestOf<'submitted'>>
export type FetchSubmittedIntakeRequestsAnswer = OkOrErrorAnswer<IntakeRequestOf<'submitted'>[]>
export type FetchRejectedIntakeRequestsAnswer = OkOrErrorAnswer<IntakeRequestOf<'rejected'>[]>
export type FetchAcceptedIntakeRequestsAnswer = OkOrErrorAnswer<IntakeRequestOf<'accepted'>[]>
export type FetchAppointedIntakeRequestsAnswer = OkOrErrorAnswer<IntakeRequestOf<'appointed'>[]>
export type FetchWithdrawnIntakeRequestsAnswer = OkOrErrorAnswer<IntakeRequestOf<'withdrawn'>[]>
export type FetchStaleIntakeRequestsAnswer = OkOrErrorAnswer<IntakeRequestOf<'stale'>[]>
export type FetchClosedIntakeRequestsAnswer = OkOrErrorAnswer<IntakeRequestOf<'closed'>[]>
export type FetchDoctorCalendarEntriesAnswer = OkOrErrorAnswer<DoctorCalendarEntry[]>
export type AcceptSubmittedIntakeRequestAnswer = TransitionAnswer<IntakeRequestOf<'accepted'>>
export type RejectSubmittedIntakeRequestAnswer = TransitionAnswer<IntakeRequestOf<'rejected'>>
export type WithdrawIntakeRequestAnswer = TransitionAnswer<IntakeRequestOf<'withdrawn'>>
export type MarkAcceptedIntakeRequestStaleAnswer = TransitionAnswer<IntakeRequestOf<'stale'>>
export type CloseAppointedIntakeRequestAnswer = TransitionAnswer<IntakeRequestOf<'closed'>>

// Every answer variant any use case can give.
export type AnyAnswer =
  | Variant<'ok', unknown>
  | Variant<'transitioned', unknown>
  | Variant<'slotCreated', unknown>
  | Variant<'movedOn', IntakeRequest>
  | MatchOutcome
  | MatchAvailableSlotByPriorityAnswer
  | CreateAvailableSlotAnswer

// ── Envelope decoding ──────────────────────────────────────────────────────

function envelope<T extends string>(json: unknown, tags: readonly T[], what: string): { outcome: T; detail: unknown } {
  const o = obj(json, what)
  return { outcome: tagOf(tags, o.outcome, `${what}.outcome`), detail: o.detail }
}

function serviceError(outcome: ServiceErrorTag, detail: unknown, what: string): ServiceErrorAnswer {
  const at = `${what}.detail`
  switch (outcome) {
    case 'doctorNotFound':
      return { outcome, detail: str(detail, at) }
    case 'patientNotFound':
      return { outcome, detail: str(detail, at) }
    case 'healthcareServiceNotFound':
      return { outcome, detail: str(detail, at) }
    case 'intakeRequestNotFound':
      return { outcome, detail: str(detail, at) }
    case 'intakeRequestInWrongState':
      return { outcome, detail: decodeIntakeRequest(detail, at) }
    case 'slotDoesNotMatchIntakeRequest':
      return { outcome, detail: nothing(detail, at) }
  }
}

function okOnly<T>(tags: readonly 'ok'[], decode: (x: unknown, what: string) => T, what: string) {
  return (json: unknown): OkAnswer<T> => {
    const { outcome, detail } = envelope(json, tags, what)
    return { outcome, detail: decode(detail, `${what}.detail`) }
  }
}

function okOrError<T>(
  tags: readonly ('ok' | ServiceErrorTag)[],
  decode: (x: unknown, what: string) => T,
  what: string,
) {
  return (json: unknown): OkOrErrorAnswer<T> => {
    const { outcome, detail } = envelope(json, tags, what)
    switch (outcome) {
      case 'ok':
        return { outcome, detail: decode(detail, `${what}.detail`) }
      default:
        return serviceError(outcome, detail, what)
    }
  }
}

function transition<T>(
  tags: readonly ('transitioned' | 'movedOn' | ServiceErrorTag)[],
  decode: (x: unknown, what: string) => T,
  what: string,
) {
  return (json: unknown): TransitionAnswer<T> => {
    const { outcome, detail } = envelope(json, tags, what)
    switch (outcome) {
      case 'transitioned':
        return { outcome, detail: decode(detail, `${what}.detail`) }
      case 'movedOn':
        return { outcome, detail: decodeIntakeRequest(detail, `${what}.detail`) }
      default:
        return serviceError(outcome, detail, what)
    }
  }
}

const matchOutcomeTags = allOf<S['MatchOutcome']['outcome']>()(['matched', 'availableSlotConsumed', 'intakeRequestMovedOn'])

function matchOutcome(outcome: MatchOutcome['outcome'], detail: unknown, what: string): MatchOutcome {
  const at = `${what}.detail`
  switch (outcome) {
    case 'matched':
      return { outcome, detail: decodeAppointed(detail, at) }
    case 'availableSlotConsumed':
      return { outcome, detail: nothing(detail, at) }
    case 'intakeRequestMovedOn':
      return { outcome, detail: decodeIntakeRequest(detail, at) }
  }
}

function decodeMatchOutcome(x: unknown, what: string): MatchOutcome {
  const { outcome, detail } = envelope(x, matchOutcomeTags, what)
  return matchOutcome(outcome, detail, what)
}

const serviceErrorTags = allOf<ServiceErrorTag>()([
  'doctorNotFound',
  'patientNotFound',
  'healthcareServiceNotFound',
  'intakeRequestNotFound',
  'intakeRequestInWrongState',
  'slotDoesNotMatchIntakeRequest',
])


export const decodeFetchDoctorsAnswer = okOnly(
  allOf<S['FetchDoctorsAnswer']['outcome']>()(['ok']),
  arrayOf(genDoctor),
  'FetchDoctorsAnswer',
)
export const decodeCreateDoctorAnswer = okOnly(
  allOf<S['CreateDoctorAnswer']['outcome']>()(['ok']),
  genDoctor,
  'CreateDoctorAnswer',
)
export const decodeFetchPatientsAnswer = okOnly(
  allOf<S['FetchPatientsAnswer']['outcome']>()(['ok']),
  arrayOf(genPatient),
  'FetchPatientsAnswer',
)
export const decodeCreatePatientAnswer = okOnly(
  allOf<S['CreatePatientAnswer']['outcome']>()(['ok']),
  genPatient,
  'CreatePatientAnswer',
)
export const decodeFetchHealthcareServicesAnswer = okOrError(
  allOf<S['FetchHealthcareServicesAnswer']['outcome']>()(['ok', ...serviceErrorTags]),
  arrayOf(genHealthcareService),
  'FetchHealthcareServicesAnswer',
)
export const decodeCreateHealthcareServiceAnswer = okOnly(
  allOf<S['CreateHealthcareServiceAnswer']['outcome']>()(['ok']),
  genHealthcareService,
  'CreateHealthcareServiceAnswer',
)
export const decodeSubmitIntakeRequestAnswer = okOrError(
  allOf<S['SubmitIntakeRequestAnswer']['outcome']>()(['ok', ...serviceErrorTags]),
  decodeSubmitted,
  'SubmitIntakeRequestAnswer',
)
export const decodeFetchSubmittedIntakeRequestsAnswer = okOrError(
  allOf<S['FetchSubmittedIntakeRequestsAnswer']['outcome']>()(['ok', ...serviceErrorTags]),
  arrayOf(decodeSubmitted),
  'FetchSubmittedIntakeRequestsAnswer',
)
export const decodeFetchRejectedIntakeRequestsAnswer = okOrError(
  allOf<S['FetchRejectedIntakeRequestsByRejectedAtAnswer']['outcome']>()(['ok', ...serviceErrorTags]),
  arrayOf(decodeRejected),
  'FetchRejectedIntakeRequestsByRejectedAtAnswer',
)
export const decodeFetchAcceptedIntakeRequestsAnswer = okOrError(
  allOf<S['FetchAcceptedIntakeRequestsAnswer']['outcome']>()(['ok', ...serviceErrorTags]),
  arrayOf(decodeAccepted),
  'FetchAcceptedIntakeRequestsAnswer',
)
export const decodeFetchAppointedIntakeRequestsAnswer = okOrError(
  allOf<S['FetchAppointedIntakeRequestsAnswer']['outcome']>()(['ok', ...serviceErrorTags]),
  arrayOf(decodeAppointed),
  'FetchAppointedIntakeRequestsAnswer',
)
export const decodeFetchWithdrawnIntakeRequestsAnswer = okOrError(
  allOf<S['FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer']['outcome']>()(['ok', ...serviceErrorTags]),
  arrayOf(decodeWithdrawn),
  'FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer',
)
export const decodeFetchStaleIntakeRequestsAnswer = okOrError(
  allOf<S['FetchStaleIntakeRequestsByStaleAtAnswer']['outcome']>()(['ok', ...serviceErrorTags]),
  arrayOf(decodeStale),
  'FetchStaleIntakeRequestsByStaleAtAnswer',
)
export const decodeFetchClosedIntakeRequestsAnswer = okOrError(
  allOf<S['FetchClosedIntakeRequestsByStartAnswer']['outcome']>()(['ok', ...serviceErrorTags]),
  arrayOf(decodeClosed),
  'FetchClosedIntakeRequestsByStartAnswer',
)
export const decodeFetchDoctorCalendarEntriesAnswer = okOrError(
  allOf<S['FetchDoctorCalendarEntriesOverlappingAnswer']['outcome']>()(['ok', ...serviceErrorTags]),
  arrayOf(decodeDoctorCalendarEntry),
  'FetchDoctorCalendarEntriesOverlappingAnswer',
)
export const decodeAcceptSubmittedIntakeRequestAnswer = transition(
  allOf<S['AcceptSubmittedIntakeRequestAnswer']['outcome']>()(['transitioned', 'movedOn', ...serviceErrorTags]),
  decodeAccepted,
  'AcceptSubmittedIntakeRequestAnswer',
)
export const decodeRejectSubmittedIntakeRequestAnswer = transition(
  allOf<S['RejectSubmittedIntakeRequestAnswer']['outcome']>()(['transitioned', 'movedOn', ...serviceErrorTags]),
  decodeRejected,
  'RejectSubmittedIntakeRequestAnswer',
)
export const decodeWithdrawIntakeRequestAnswer = transition(
  allOf<S['WithdrawIntakeRequestAnswer']['outcome']>()(['transitioned', 'movedOn', ...serviceErrorTags]),
  decodeWithdrawn,
  'WithdrawIntakeRequestAnswer',
)
export const decodeMarkAcceptedIntakeRequestStaleAnswer = transition(
  allOf<S['MarkAcceptedIntakeRequestStaleAnswer']['outcome']>()(['transitioned', 'movedOn', ...serviceErrorTags]),
  decodeStale,
  'MarkAcceptedIntakeRequestStaleAnswer',
)
export const decodeCloseAppointedIntakeRequestAnswer = transition(
  allOf<S['CloseAppointedIntakeRequestAnswer']['outcome']>()(['transitioned', 'movedOn', ...serviceErrorTags]),
  decodeClosed,
  'CloseAppointedIntakeRequestAnswer',
)

const matchToSlotTags = allOf<S['MatchAcceptedIntakeRequestToSlotAnswer']['outcome']>()([
  ...matchOutcomeTags,
  ...serviceErrorTags,
])

export function decodeMatchAcceptedIntakeRequestToSlotAnswer(json: unknown): MatchAcceptedIntakeRequestToSlotAnswer {
  const what = 'MatchAcceptedIntakeRequestToSlotAnswer'
  const { outcome, detail } = envelope(json, matchToSlotTags, what)
  switch (outcome) {
    case 'matched':
    case 'availableSlotConsumed':
    case 'intakeRequestMovedOn':
      return matchOutcome(outcome, detail, what)
    default:
      return serviceError(outcome, detail, what)
  }
}

const matchByPriorityTags = allOf<S['MatchAvailableSlotByPriorityAnswer']['outcome']>()([
  'noMatchingIntakeRequest',
  'matchAttempted',
  ...serviceErrorTags,
])

export function decodeMatchAvailableSlotByPriorityAnswer(json: unknown): MatchAvailableSlotByPriorityAnswer {
  const what = 'MatchAvailableSlotByPriorityAnswer'
  const { outcome, detail } = envelope(json, matchByPriorityTags, what)
  switch (outcome) {
    case 'noMatchingIntakeRequest':
      return { outcome, detail: nothing(detail, `${what}.detail`) }
    case 'matchAttempted':
      return { outcome, detail: decodeMatchOutcome(detail, `${what}.detail`) }
    default:
      return serviceError(outcome, detail, what)
  }
}

const createSlotTags = allOf<S['CreateAvailableSlotAnswer']['outcome']>()([
  'slotCreated',
  'slotOverlapsDoctorCalendar',
  ...serviceErrorTags,
])

export function decodeCreateAvailableSlotAnswer(json: unknown): CreateAvailableSlotAnswer {
  const what = 'CreateAvailableSlotAnswer'
  const { outcome, detail } = envelope(json, createSlotTags, what)
  switch (outcome) {
    case 'slotCreated':
      return { outcome, detail: genAvailableSlot(detail, `${what}.detail`) }
    case 'slotOverlapsDoctorCalendar':
      return { outcome, detail: nothing(detail, `${what}.detail`) }
    default:
      return serviceError(outcome, detail, what)
  }
}
