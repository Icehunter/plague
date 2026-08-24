#!/bin/bash
# Session start hook - remind Claude to follow project rules.
# Runs at the start of every Claude session.

cat <<'EOF'
IMPORTANT: This project has strict requirements in AGENTS.md and .claude/rules/.

Before writing any shader code:
- Read AGENTS.md, especially "Before you write shader code, read .claude/rules/clean-room.md"
- The rules in .claude/rules/ are REQUIREMENTS, not suggestions
- Clean-room: a context that has read another shaderpack may NOT write the implementation
- Never name another pack as a source, in code or in a commit message
- This pack is SYMLINKED into the Minecraft profile: every shader edit is live the instant it is
  written. Batch edits, then say explicitly when the set is complete and safe to load. Never ask
  for an in-game reading mid-edit -- a "broken shader" report taken then is a false signal
- Verify with tools/check_shaders.sh and the relevant python3 tools/verify_*.py. A default arm
  compiling is not a check: an option that is default-off hides its whole feature from the compiler
- NEVER launch Minecraft. In-game evidence comes from the user's own sessions: they launch, they report
- Do not create a commit until the owner has run the change locally

Do not skip these steps.
EOF
