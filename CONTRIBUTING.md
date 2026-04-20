# Contributing

Thanks for taking the time to look at `zend`.

This project is still small and opinionated. The most helpful contributions are the ones that make the behavior clearer, safer, and easier to verify, not the ones that add surface area quickly.

## Before you change code

- Read the top-level `README.md` first so you have the current shape of the repo.
- Keep changes focused. Small, reviewable pull requests are much easier to land than broad rewrites.
- If you plan to make a large change to the protocol, relay behavior, or CLI UX, open an issue first so the direction can be discussed before implementation work starts.

## Development expectations

- Match the existing style of the surrounding code instead of reformatting unrelated files.
- Avoid adding dependencies unless there is a clear payoff.
- Prefer explicit behavior over clever abstractions.
- Preserve the split between the relay-backed flow and the direct peer-to-peer CLI flow unless the change is intentionally restructuring both.

## What to include in a pull request

- A short explanation of what changed and why.
- Notes about any tradeoffs or follow-on work.
- Tests or verification steps when behavior changed.
- Documentation updates if the user-facing behavior, config, or setup flow changed.

## Good contribution areas

- Relay correctness and error handling
- End-to-end tests
- Configuration cleanup
- Documentation and deployment guides
- Performance work that keeps the code understandable
- Security hardening with clear reasoning

## Please avoid

- Mixing refactors with behavior changes in the same pull request
- Reformatting large parts of the repo without a strong reason
- Sneaking in unrelated fixes
- Marketing copy disguised as technical documentation

## Reporting bugs

When opening an issue, include:

- what you expected to happen
- what actually happened
- the component involved (`apps/relay`, `apps/web`, `apps/cli`, or shared packages)
- reproduction steps
- local environment details if relevant

## Security issues

Please do not open public issues for suspected security vulnerabilities. Follow the process in `SECURITY.md`.
