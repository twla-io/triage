---
name: triage-api-codegen
description: Generate the HTTP API — src/Transport.hs (JSON DTOs) and src/Api.hs (Servant routes and handlers) — from triage's Domain.hs and Service.hs. Use this skill whenever designing, generating, or extending API endpoints, routes, request/response bodies, JSON encodings or OpenAPI schemas for the triage domain model. Trigger this even if the user just says "build the API" or "add an endpoint for X" without mentioning Domain.hs explicitly. Do not use this skill for database schema, Persistence or Service generation (triage-db-codegen, triage-service-codegen) or for the UI (triage-ui-codegen).
---

# triage-api-codegen

Derive `src/Transport.hs` and `src/Api.hs` from two sources:
- **`Domain.hs`** gives every name and every shape on the wire.
- **`Service.hs`** gives the operations: one endpoint per public function, with its parameters, and its errors and outcomes.

This skill says only how those become JSON and routes. It names no Domain type or Service function; `e.g.` marks an illustration, never a requirement.

- Read both files fresh every time. Existing `Transport.hs`/`Api.hs` are output to check against these rules, never examples to copy.
- These are decisions already made: apply them, don't offer alternatives. Reasons are in `docs/decisions.md`.
- The API never reaches past `Service.hs` into `Persistence.hs`, and adds no logic of its own beyond parsing, supplying the current time, and rendering answers. The one import from `Persistence` is the `ConnectionPool` type, which Service's signatures use.
- If the sources leave something a rule needs undetermined, stop and ask. The fix belongs in `Domain.hs` or `Service.hs`.
- Rules apply to existing code. After a rule or a source changes, check every type and handler against every rule.
- The strategy is REST over HTTP. Event sourcing was explored and rejected (`docs/decisions.md`).

## Wire format (`Transport.hs`)

### `names-come-from-domain`
- **Keys** are `Domain.hs` names: a record field's name, a sealed type's read-only accessor's name, or for a single-field constructor, the constructor's name in lowerCamelCase. The innermost name above a value wins; an ID newtype is not a name, nor is a sealed newtype over one value (it is the value itself, encoded through its accessor and decoded through its smart constructor).
- **A request body's keys** are the names of the `Domain.hs` fields their values land in, not Service's parameter names. An ID with no field of its own takes its ID type's name in lowerCamelCase (e.g. `slotId`).
- **Discriminator values** are constructor names in lowerCamelCase.
- There is no independent wire vocabulary: a rename in `Domain.hs` changes the wire, and every client is regenerated from the API's schema.

### `tagged-flat-serialization`
- **Sum types:** one flat JSON object per case, discriminated by a key named `"type"` at every nesting level. Never a nested `contents` wrapper, never a case-specific discriminator key.
- **Embedded stages** are flattened into their case's object: a case carries its own fields and every field of the stages it embeds, under the same keys wherever they appear.
- **A nested value** (a sum type or record held in a field) is an object under its field's key.
- **A single-field constructor** whose payload is a record or newtype is flattened into its case's object; one whose payload is a sum type is nested under the constructor's name, since one object can't hold two `"type"` keys.
- **A field whose sum type's cases each carry a stage** is flattened: the stage's fields join the enclosing case's object, and the field keeps only `{"type": <case>}`.
- **An enumeration** is an object with only `"type"`.
- **No key is `null` for "hasn't reached this stage yet"**: a case's object has exactly its own keys. A `Maybe` field's key is always present; an absent value is `null`.

### `schemas-follow-cases`
The spec is OpenAPI 3 (`openapi3`, `servant-openapi3`), served at `/openapi.json`, with Swagger UI at `/swagger-ui`. Every schema states exactly what `ToJSON` produces:
- **A record** is an object schema with exactly its keys, all required. A `Maybe` field's key is required and its schema is `nullable: true`.
- **A sum type** is `oneOf` one named schema per case, `<Type><Constructor>`, with `discriminator: {propertyName: "type"}`. Each case's schema has `type` as a one-value enum plus exactly that case's keys (stages flattened, per `tagged-flat-serialization`). Cases are never merged into one object. A discriminator always has an explicit `mapping` from each tag to its case's schema (`#/components/schemas/<Type><Constructor>`), because tags are not schema names. A case whose keys depend on a nested tag (a flattened field whose sum's cases carry different stages) is itself `oneOf` its variants, named `<Type><Constructor><InnerConstructor>`; a sum containing such a case has no `discriminator`, since one can only map to an object schema.
- **An enumeration** is one object schema whose `type` is an enum of its constructors.
- **A `UTCTime`** is `type: string, format: date-time`, inline.
- **Each answer** (`<Function>Answer`) is `oneOf` one schema per outcome tag, `{outcome: <that tag>, detail: <that payload's schema, or null>}`, with `discriminator: {propertyName: "outcome"}` and an explicit `mapping` from each tag to its schema. So `detail` is typed per outcome.
- **Names:** each answer case's schema is `<Function>Answer<Constructor>` (e.g. `FetchDoctorAnswerOk`); a nested answer type keeps its own name (`<Type><Constructor>`). A request variant of a type that loses a time the server records is `<Type>Request`, its cases `<Type>Request<Constructor>`, and its Haskell constructors carry the same names.

### `opaque-uuid-ids`
Every ID is a plain UUID string, never wrapped. Distinct ID types stay distinct in the schema and in path parameter names.

### Transport types
- One DTO per `Domain.hs` type that crosses the wire, named `<Type>DTO`, with hand-written `ToJSON`, `FromJSON` and `ToSchema`. Never `Generic`-derived, and never an instance on a `Domain.hs` type.
- `toDomain<Type>` / `fromDomain<Type>` convert at the boundary. A sealed type is decoded only through its smart constructor; a refusal is a parse failure (`400`).
- A request body is a `<Function>Request` type, named after its Service function, holding exactly that function's caller-supplied facts; a function with none takes no body. A `Domain.hs` value the caller supplies whole but that contains a time the server records gets a request type without that time, converted once the handler has it.
- **Check:** a test validates every DTO's and every answer's `ToJSON` against its schema (`triage-test`); a sum type's value must match exactly one case. `openapi3`'s validator ignores `nullable`, so the test accepts `null` for a `Maybe` field itself; the published spec stays standard OpenAPI 3.0.

## Routes (`Api.hs`)

### `routes-follow-use-cases`
Every public `Service.hs` function gets exactly one endpoint, derived from its kind (`triage-service-codegen`'s `function-per-use-case`). `<table>` is the entity's table name in kebab-case (`triage-db-codegen`'s `names-come-from-domain`).

| Use case | Route |
|---|---|
| create | `POST /<table>` |
| grow a sealed collection | `POST /<element table>` |
| transition | `POST /<table>/:id/<action>`, the action being the function name minus its source case and entity, in kebab-case |
| Domain function over stored values | `POST /<table of the input the caller names>/:id/<action>`, the action being the function name minus the entity, in kebab-case |
| read by id | `GET /<table>/:id` |
| read all | `GET /<table>` |
| read by case | `GET /<table>/<case>` |
| read a terminal case by range | `GET /<table>/<case>?from=…&to=…` |
| read a sealed collection | `GET /<collection>?from=…&to=…`, the collection type's name in kebab-case |

A narrower read's filters are query parameters. Path segments only ever identify a resource; a path parameter is named after its ID type in lowerCamelCase (e.g. `{intakeRequestId}`).

### `verb-minimalism`
`GET` and `POST` only. Nothing is replaced wholesale (no `PUT`), no caller deletes anything (no `DELETE`), and a transition is an operation with a precondition, not a field update (no `PATCH`).

### Timestamps
Every time a Service function takes as "when this happened" is supplied by the handler (`getCurrentTime`), never by the request body: it records when the action was recorded. Service's caller is the handler: it supplies the current time, including inside a whole Domain value it builds.

## Answers

### `error-vs-outcome-mapping`
| Status | When |
|---|---|
| `400` | the request never reached Service: malformed JSON, a wrong, missing or unknown field, an invalid ID, a sealed value its smart constructor refuses |
| `404` | the route itself doesn't exist (decided by the router) |
| `200` | Service ran and answered: success, every outcome and every error fact, discriminated in the body |
| `500` | outside the domain's vocabulary: a decode failure, a database failure, anything unexpected |

An id that doesn't exist is a `200` with its not-found answer, never a `404`: Service ran a query to find that out. A `500` body is plain text and exposes no internals. Every `500` is written to stderr with its cause (for a decode failure, the `DecodeError`), in one place every handler passes through; no other path may answer `500`.

### The response envelope
- **Every** `200` body, for mutations and reads alike, is `{"outcome": <tag>, "detail": <payload or null>}`, so a client parses every answer the same way.
- **The tag** is the answer's constructor name in lowerCamelCase for each outcome constructor (e.g. `transitioned`, `movedOn`), and the fact type's name for each error fact (e.g. `doctorNotFound`), so a fact has the same tag in every answer whichever `<Function>Error` wraps it. An answer lists exactly its use case's outcomes and facts. An answer that is a plain value with no constructor of its own (a created entity, a read's result) has the tag `ok`. A `Nothing` from a by-id read of an entity deleted on consumption has the tag `<entity>Consumed` and the requested id as `detail`, the same shape as Service's fact everywhere else; its render function takes the id too (`render<Function>Answer :: <Id> -> Maybe <Entity> -> <Function>Answer`).
- **The detail** is the payload rendered by its DTO, or `null` when there is none. A payload that is itself an answer type is rendered as a nested envelope.

Each use case's answer is rendered by `render<Function>Answer :: <Service result> -> <Function>Answer`, exported from `Api` (the seam `triage-test` checks against the schema). The rendering of each Service answer type is written once, as one exhaustive function with no wildcard, and shared by every handler that returns it: each fact type is rendered once, and a `<Function>Error` by delegating to its facts. A decode failure arrives as an exception and becomes a `500`.

## Servant implementation
- **Framework:** Servant: routes and handlers correspond at compile time.
- **One module, `Api.hs`,** with the API type grouped per resource (one sub-API per table, composed with `:<|>`). Each resource's route type, handlers and server sit together in a banner-commented section, because Servant matches handlers to routes by position and small groups contain a misordering.
- **Handlers** run in `AppM = ReaderT ConnectionPool Handler`, with no environment record; `hoistServer` supplies the pool once.
- **Configuration:** `TRIAGE_DB_URL` (default `postgresql://localhost/triage`) and `TRIAGE_PORT` (default 8080; a malformed value fails at startup). The pool holds 10 connections with a 60-second idle timeout. CORS allows the frontend's origin. Swagger UI is at `/swagger-ui`, and the OpenAPI 3 spec at `/openapi.json`.
- **`main` only serves.** Migrations are a separate, manual step.

## When unsure
Prefer the option that keeps the API a thin, faithful mirror of `Service.hs`, and flag the ambiguity rather than inventing a convention. A new rule gets a kebab-case name before its text.
