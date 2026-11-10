# Architecture decision records

An **architecture decision record** (ADR) is a short page that explains one important choice: the situation, the decision, what it costs, and what was rejected. The code and the configuration say *what* the infrastructure is; the ADRs say *why*. Six months later, or for the next technician, the why is the part that is otherwise lost.

## Index

| ADR | Title | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0002](0002-administration-only-over-mesh-vpn.md) | Administration only over a mesh VPN, no public administrative port | Accepted, partly applied |
| [0003](0003-separate-critical-and-automation-roles.md) | Separate the critical node from the automation node | Accepted, applied |
| [0004](0004-human-approval-for-irreversible-actions.md) | Human approval for irreversible actions of the automation | Accepted, first level applied |

## How to write one

1. Copy [the template](0000-template.md) to `NNNN-short-title.md` with the next free number.
2. Fill in every section. *Alternatives considered* is not optional: a decision without a rejected option is a habit, not a decision.
3. Start with status **Proposed**; change it to **Accepted** when the change is made or scheduled.
4. Never rewrite an accepted ADR to say something else. If the decision changes, write a new ADR and set the old one to **Superseded by NNNN**. The history of the reasoning is part of the documentation.

## Status values

| Status | Meaning |
|---|---|
| Proposed | Under discussion, nothing changed yet |
| Accepted | The rule applies; the *Status* line says how much of it is in place |
| Deprecated | No longer relevant (the component was removed) |
| Superseded by NNNN | Replaced by a newer decision |

Reference: Michael Nygard, [Documenting Architecture Decisions](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions) (2011); [adr.github.io](https://adr.github.io/).
