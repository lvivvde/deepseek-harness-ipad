# Domain Docs

How the engineering skills consume this repo's domain documentation.

## Before exploring, read these

- `CONTEXT.md` at the repo root.
- ADRs in `docs/adr/` that touch the area you are about to work in.

If these files do not exist, proceed silently. Domain modeling creates them lazily when terms or decisions are resolved.

## File structure

This repo uses a single-context layout:

```text
/
├── CONTEXT.md
└── docs/adr/
    ├── 0001-<decision>.md
    └── 0002-<decision>.md
```

## Use the glossary's vocabulary

When naming a domain concept in an issue title, refactor proposal, hypothesis, or test name, use the term defined in `CONTEXT.md`.

If a concept is missing, reconsider whether it belongs to the project's vocabulary. Record a real glossary gap for domain modeling.

## Flag ADR conflicts

If your output contradicts an existing ADR, surface the conflict explicitly and explain why the decision should be reopened.
