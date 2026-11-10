# 0001. Record architecture decisions

- **Status:** Accepted
- **Decided:** 2026-11-10
- **Applies to:** the whole infrastructure

## Context

The infrastructure was built over several weeks, one service at a time. The reasons behind the important choices (why the bot runs on one server and not the other, why a service listens on loopback only) lived in private working notes, mixed with real addresses and secrets locations. Those notes cannot be published, and they describe the *current state* more than the *reasons*. Someone reading only the configuration would see `127.0.0.1:5678` and might "fix" it to `0.0.0.0` to make the editor reachable.

## Decision

We will record every decision that is hard to reverse, that affects security, or that a newcomer could undo by mistake, as an ADR in `docs/adr/`, using [the template](0000-template.md). ADRs are written with placeholders only and are never rewritten after acceptance: a changed decision gets a new ADR.

## Consequences

- **Positive:** the reasons survive, separately from the private notes. Each ADR can be read on its own in a few minutes, which also makes it a good support for explaining the design in a job interview or a hand-over.
- **Negative:** a few minutes of writing per decision, and the discipline of updating the *Status* line when a follow-up is done.
- **Follow-up:** the existing decisions are recorded first (0002 to 0004); later pages of this repository link to them instead of repeating the reasoning.

## Alternatives considered

| Option | Why it was not chosen |
|---|---|
| Comments in configuration files | Scattered across two servers, invisible from GitHub, and the files contain real values. |
| One long design document | Grows without structure; hard to tell which part is still valid after a change. |
| Nothing (the configuration is the documentation) | Shows *what*, never *why*, and never the rejected options. |

## How to verify

Every decision cited in [the architecture overview](../architecture.md) links to an ADR, and the [ADR index](README.md) lists every file of this folder.

## References

- Michael Nygard, [Documenting Architecture Decisions](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions).
