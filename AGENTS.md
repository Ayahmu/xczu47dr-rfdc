# Repository instructions

## Runnable tools and examples

- Follow the repository's established invocation and configuration conventions. Do not impose one configuration mechanism on every script.
- Choose the interface according to purpose: direct constants are suitable for small single-purpose examples, command-line arguments for reusable tools, and environment variables or configuration files for deployment settings.
- Keep user-adjustable inputs easy to find, consistently named, documented, and validated before performing expensive or state-changing work.
- Avoid exposing the same setting through several mechanisms unless precedence is explicit and the added flexibility is necessary.
- Examples should be focused, use safe defaults where possible, and run with the documented command. State required hardware, permissions, connections, and expected results.
- Treat established command-line and library interfaces as compatibility boundaries. Change them deliberately and update callers, tests, and documentation together.

## Documentation and code comments

- Do not create a new document for each feature, experiment, bug fix, or test. Update the closest existing canonical document by default.
- Keep the public documentation set small. Create a document only when the user explicitly requests it or no existing document has the same audience and purpose.
- One topic must have one canonical explanation. Remove obsolete or duplicate guides and repair every reference when documentation is reorganized.
- Delivery and quick-start documents must be short and task-oriented. Put implementation detail in the API reference or code only when it is needed.
- Technical writing must present prerequisites, steps, expected results, and failure handling in a clear order. Avoid history, repeated explanations, speculation, and filler.
- Important code must explain hardware contracts, timing and unit assumptions, state transitions, non-obvious algorithms, and safety or recovery behavior in detailed comments. Do not comment trivial syntax.
## Project

- Do not preserve backward compatibility. Remove obsolete paths instead of adding compatibility layers,fallbacks, or migrations.
- Choose the simplest implementation that fully meets the current requirements,Avoid speculative abstractions, configuration, and indirection.
- Grow the system in layers, Start from the smallest version that works end to end, and add each new capability on top of a product that already works. Never trade a working product for unfinished complexity.
- Keep components modular and concerns clearly separated.
- Prefer established, well-maintained libraries when they reduce overall complexity or improve reliability. Do not reimplement common functionality without a clear reason.
- Lean on the dependencies already in the project before writing your own implementation or adding packages. Do not assume a library lacks a capability without checking its documentation and types.
- Make architectural decisions for the long term. Do not accept a stopgap that only works for now and is meant to be replaced later.
