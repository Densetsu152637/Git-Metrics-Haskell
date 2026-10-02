# Coding standards

## Apply these rules

- Read applicable `AGENTS.md` instructions, relevant `docs/` READMEs, nearby code/tests, and formatter/linter/build configuration before editing.
- Follow established project and framework conventions. The language defaults below guide new code where no stronger local convention exists; do not rewrite working code into a different paradigm without task justification.
- Make the smallest cohesive change that satisfies the requirements. Favor clarity and explicit contracts over fewest lines, speculative abstractions, or broad cleanup.

## Language defaults

FP = functional programming; OOP/OOD = object-oriented programming/design. Languages may combine paradigms; choose idiomatic constructs for the problem.

| Language                | Default paradigm and emphasis                                                                             |
| ----------------------- | --------------------------------------------------------------------------------------------------------- |
| Haskell                 | FP; pure transformations, algebraic data types, explicit effects                                          |
| C++                     | OOP/OOD with value semantics, RAII, composition, and generic algorithms                                   |
| C                       | Procedural/structured; explicit data ownership, lifetimes, and cleanup                                    |
| C# / Java               | OOP/OOD; cohesive types, interfaces at boundaries, composition                                            |
| TypeScript / JavaScript | Functional composition for transformations; modules/components; classes for meaningful state or lifecycle |
| Python                  | Procedural/functional core; classes for domain state and behavior; idiomatic iteration                    |
| Rust                    | Ownership-oriented, data-oriented design; structs/enums/traits and functional iterators                   |
| Go                      | Procedural composition; small interfaces, explicit errors and concurrency ownership                       |
| Kotlin / Swift          | OOP plus functional/value-oriented design; idiomatic framework conventions                                |
| F# / OCaml / Scala      | FP-first; algebraic modeling and explicit effects; idiomatic interop                                      |
| SQL                     | Declarative, set-based queries; explicit joins, constraints, and transactions                             |
| Shell / PowerShell      | Procedural orchestration; small commands/functions, quoted paths, explicit failure handling               |

For unlisted languages, follow their ecosystem and local conventions. Prefer local, controlled mutation when it makes an algorithm clearer or more efficient; avoid hidden shared mutable state. Pure functions and immutability improve reasoning, but do not inherently guarantee performance.

## Functions

- Give each function one coherent responsibility and a name that describes its intent. Keep control flow shallow and readable; extract helpers when they isolate a meaningful concept, repeated behavior, or testable boundary.
- Make inputs, outputs, effects, and failure behavior explicit. Prefer pure transformations for business rules; keep I/O and orchestration at clear boundaries. Do not introduce hidden global dependencies.
- Use typed/named parameter groups when arguments become ambiguous. Avoid boolean mode flags and long positional argument lists where separate operations or a meaningful options type are clearer.
- Validate untrusted input at boundaries. Handle empty, invalid, and missing values deliberately; preserve distinctions that matter to the domain instead of inventing silent defaults.
- Use composition, currying, and higher-order functions where idiomatic and helpful. Do not force currying, one-line functions, recursion, or chained expressions when straightforward control flow reads better.
- Document public contracts, non-obvious invariants, units, effects, and exceptions/errors in the language's standard documentation format. Do not restate the signature in boilerplate comments.

## Classes, types, and modules

- Use classes for cohesive state, invariants, behavior, or resource lifecycle. Use records/structs/data types for plain data; do not create a class solely to hold unrelated utility functions.
- Establish valid state during construction and maintain it through a small public API. Encapsulate mutable state and expose the least authority callers need.
- Prefer composition to inheritance. Use inheritance only for a real substitutable relationship or framework requirement; avoid deep hierarchies and oversized manager/service classes.
- Keep modules focused with clear dependency direction. Introduce interfaces at real substitution, integration, or testing boundaries rather than one interface per class by default.
- Make resource and concurrency ownership explicit. Close files, release locks/connections, cancel work, and dispose resources using language mechanisms such as RAII, context managers, or `defer`/`using`.
- Model domain states with appropriate types, enums, or tagged unions. Avoid unchecked casts and overly broad types that conceal invalid states.

## Naming and formatting

- Use the repository's language-specific naming conventions: for example, `snake_case` in Python/Rust and `camelCase` in JavaScript/TypeScript where configured. Do not impose one language's casing globally.
- Use descriptive nouns for values/types and intent-revealing verbs for operations. Boolean names should read as predicates, such as `isLoading`, adapted to language conventions. Keep abbreviations only when standard and clear.
- Let configured formatters and linters enforce layout/import order. Limit formatting changes to the affected code unless the task requires more.
- Comments explain rationale, constraints, and surprising decisions. Remove stale comments when behavior changes. Keep documentation and examples consistent with the implementation.

## Errors and asynchronous work

- Use the existing error strategy (exceptions, typed results, error returns, etc.). Preserve failures until a boundary can handle them; catch only to recover, add useful context, clean up, or present a safe error.
- Do not swallow errors, report success after failure, or expose tokens, raw sensitive responses, or stack traces in user-facing messages. Offer an appropriate retry, resubmit, or navigation path.
- Await or explicitly handle every asynchronous operation. Own cancellation, loading state, and cleanup. A `void` prefix does not itself handle a rejected promise.
- Prevent stale or cancelled requests from overwriting current state, including error and loading state. Use cancellation plus a current-request/lifecycle guard where cancellation alone cannot guarantee this.
- Validate HTTP status, decoding, and application-level success according to the endpoint contract. Reuse shared request helpers; do not introduce a second `Result`/`Either` framework for routine requests when existing Promise/error composition suffices.

### Existing web-app helper conventions

When working in a project containing `web-app/src/shared/pathways.ts` and `web-app/src/lib/connector.ts`, inspect and use those shared helpers and preserve connector rejections. Use `clientErrorMessage(error, fallback)` and `reportClientError(error, context)` where defined for safe messages and development diagnostics, following the configured `@shared/pathways` import alias.

React effects must handle their background promises and cancel in-flight work on cleanup. Ignore expected cleanup aborts; guard state updates from superseded requests, including updates in `finally`. Event handlers must handle awaited connector failures; use `void` in JSX only when the invoked handler handles its own rejection. Verify these helper paths/APIs exist; do not assume every project contains this web-app or copy missing helpers blindly.

## Validation and completion

- Add or update behavior-focused tests for changed behavior and material regressions. Cover relevant edge cases and failure paths; do not write tests that merely mirror the implementation or add runtime tests for prose-only changes.
- Run required format/lint, type/build, and focused test checks from the relevant project README/configuration. For the web-app above, verify its scripts before using `npm run lint`, `npm run typecheck`, and `npm test` or documented Docker equivalents.
- Review the final diff for unintended behavior, unrelated edits, exposed secrets, stale documentation, and resource/error handling. Measure before claiming a performance improvement.
- Report the exact checks performed and material unrun/failed checks. After integration or further edits, rerun checks whose result could have changed; do not repeat unaffected passing checks without cause.
