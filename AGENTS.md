# Collaboration workflow

The user prefers a split between primary-agent reasoning and Sol implementation to reduce usage.

- The primary agent owns understanding the request, scoping, architecture and design decisions, integration, and final review.
- Delegate substantive implementation to `gpt-6.1-sol` subagents. The user explicitly authorizes this delegation. Keep tiny, straightforward edits local.
- Start implementation subagents with `fork_turns: "none"` and an explicit model override. Give them a concise, self-contained brief with relevant files, constraints, acceptance criteria, and required checks rather than copying the whole conversation.
- Prefer one implementation agent for a cohesive change. Use parallel agents only for clearly independent work; avoid duplicate exploration and review agents by default.
- Implementation agents should run focused checks and report changed files, results, and unresolved issues concisely. The primary agent reviews the result and performs necessary integration and user-flow validation.
- Do not delegate already-completed work merely to satisfy this workflow, and do not claim a model change unless the tool call actually selected that model.

Keep the shipped app pure Swift with Apple system frameworks, local storage, and no third-party runtime dependencies, network services, or subprocess-based action execution.
