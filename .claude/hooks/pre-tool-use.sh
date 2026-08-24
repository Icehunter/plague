#!/bin/bash
# Pre-tool-use hook. Surfaces Plague's silent-failure reminders right before the relevant file is
# touched, and blocks any attempt to launch Minecraft.
#
# Claude Code sends the hook payload as JSON on STDIN, with the tool name under `.tool_name` and its
# arguments under `.tool_input.*`. When there is something to say, this script writes the official
# PreToolUse JSON envelope to stdout.
#
# Everything named here is a failure this repository has actually taken, not a style preference.

INPUT="$(cat)"

# No jq, no hook. Never block on a missing dependency.
command -v jq >/dev/null 2>&1 || exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')

emit_deny() {
    jq -n --arg reason "$1" '{
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": $reason
        }
    }'
    exit 0
}

CONTEXT_PARTS=()

# ==============================================================================
# Bash: block launching Minecraft, and keep the verification commands honest.
# ==============================================================================
if [[ "$TOOL_NAME" == "Bash" ]]; then
    case "$COMMAND" in
        *runClient*|*"open -a Minecraft"*|*"open -a PrismLauncher"*|*"Minecraft.app"*|*prismlauncher*|*"ModrinthApp"*)
            emit_deny "CLAUDE.md: never launch Minecraft. Live verification comes from the user's own sessions -- they launch, they report. If this task needs in-game evidence, say so and stop."
            ;;
    esac

    if [[ "$COMMAND" == *"check_shaders.sh"* ]]; then
        CONTEXT_PARTS+=("VERIFICATION: check_shaders.sh compiles each pass under the ARMS listed in its own variants_for(). A shader whose new code sits behind a default-off #if is reported 'ok' without ever meeting a compiler -- PLAGUE_SNOW and terrain.fsh's whole deferred arm both shipped that way. If this change added or gated an arm, add the variant in the same edit.")
    fi

    if [[ "$COMMAND" == *"git commit"* ]]; then
        CONTEXT_PARTS+=("COMMIT GATE: (1) the owner runs changes in game BEFORE a commit is created -- do not commit unrun work. (2) Never name another pack as a source in the message: not 'ported from', not 'matches X's default'. (3) The pre-commit hook runs verify_notices.py then check_shaders.sh; --no-verify is the owner's call, not yours. (4) If the notices count SHRANK, run tools/verify_notices.py --update in this same commit or the gate fails.")
    fi

    if [[ "$COMMAND" == *"verify_notices.py"*"--update"* ]]; then
        CONTEXT_PARTS+=("NOTICES BASELINE: --update records a SHRUNKEN surface and belongs in the same commit as the shrink. It is not a way to make a failing gate pass -- a count ABOVE baseline is new unbacked text and must be removed, not recorded.")
    fi
fi

# ==============================================================================
# Write/Edit: reminders chosen by which file is being edited.
# ==============================================================================
if [[ "$TOOL_NAME" == "Write" ]] || [[ "$TOOL_NAME" == "Edit" ]] || [[ "$TOOL_NAME" == "MultiEdit" ]]; then

    # Any shader source.
    case "$FILE_PATH" in
        *.glsl|*.fsh|*.vsh|*.comp)
            CONTEXT_PARTS+=("SHADER RULES: this file is LIVE in the user's profile the moment it is written -- batch edits and say when the set is complete before asking for a reading. Every authored constant needs a provenance comment (paper, measurement, or the render it was tuned against); a number with no comment is a liability. Never name another pack in a comment. See .claude/rules/shaders.md.")
            CONTEXT_PARTS+=("ARM COVERAGE: new code behind a #if whose option is default-off is NEVER compiled by tools/check_shaders.sh unless the file has a variants_for() entry turning it on. 'ok' on an uncompiled arm is the pack's most repeated failure. Add the variant in this same change.")
            ;;
    esac

    # Clean room, on EVERY shader write. The two-context rule is about what this CONTEXT has read,
    # not about whether the file is new -- editing an existing shader with a reference pack in
    # context is the same violation, and it is by far the more common path. Registration advice is
    # additionally attached when the file does not yet exist.
    case "$FILE_PATH" in
        *.glsl|*.fsh|*.vsh|*.comp)
            CONTEXT_PARTS+=("CLEAN ROOM, FIRST: if this context has read another shaderpack -- for any reason, at any point -- it may NOT write this implementation, new file or existing. Reader produces prose with no code, identifiers or constants; a separate writer implements it (.claude/rules/clean-room.md). A rename is not a re-derivation.")
            if [[ ! -f "$FILE_PATH" ]]; then
                CONTEXT_PARTS+=("NEW SHADER FILE: a pass file that no graph.toml [[pass]] names is never executed, with no error anywhere; an include that nothing #moj_imports is likewise dead text.")
            fi
            ;;
    esac

    # Option declarations.
    case "$FILE_PATH" in
        *.fsh|*.vsh)
            CONTEXT_PARTS+=("OPTIONS: a new '#define X //[...] compile \"Label\"' is INVISIBLE to the player until it is also listed on a screen in screens.toml, and renders as a cycle button unless its name is in that file's top-level sliders array. The option scanner MERGES same-name declarations across files and rejects any mismatch as a load error -- change every declaration byte-identically. Geometry passes get no u_PackOptions block, so a runtime option cannot be declared in one; declare it in a fullscreen shader and bridge it by name.")
            ;;
    esac

    # graph.toml.
    case "$FILE_PATH" in
        *graph.toml)
            CONTEXT_PARTS+=("GRAPH: pass 'inputs' are POSITIONAL -- they arrive as u_GeomInput0/1/2..., so inserting one renumbers every later sampler in the shader with no error anywhere. APPEND, never insert. Passes execute in declaration order. A blend-only pass must NOT list the target it blends into as an input (same-frame read-write hazard). Only COMPILE options may appear in enabled_if. A pass name and its target name are independent identifiers -- never rely on the two strings matching. See .claude/rules/graph-format.md.")
            ;;
        *screens.toml)
            CONTEXT_PARTS+=("SCREENS: three failures here are all silent -- an option not listed on a screen is invisible though fully working; a ranged runtime option is a cycle button unless named in the top-level sliders array; a page not listed under [yacl] is unreachable. There is no second route into a page.")
            ;;
        *blocks.toml)
            CONTEXT_PARTS+=("NO IPBR: this file has exactly ONE category, and the reasoning for it is written at the top of the file. Material properties come from labPBR channels or the albedo, never from a per-block table. A second category has to re-argue that case from scratch: identity buys nothing unless the alternative is impossible.")
            ;;
    esac

    # Python tooling.
    case "$FILE_PATH" in
        */tools/verify_*.py|*/tools/fit_*.py|*/tools/derive_*.py|*/tools/render_look.py)
            CONTEXT_PARTS+=("OFFLINE MODEL: a harness must reproduce a REAL defect before it is trusted -- a model that cannot show the photographed bug is testing assumptions, not the shader. Parse the live GLSL rather than restating its constants, print 'ok'/'FAIL' per check and exit non-zero on failure. A missing capture must SKIP and say so (tools/captures_dir.py returns None), never crash and never silently pass. State what was measured, not what it was measured against.")
            ;;
    esac
fi

# ==============================================================================
# Emit
# ==============================================================================
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    CONTEXT=""
    for part in "${CONTEXT_PARTS[@]}"; do
        if [[ -n "$CONTEXT" ]]; then
            CONTEXT="$CONTEXT | $part"
        else
            CONTEXT="$part"
        fi
    done

    jq -n --arg context "$CONTEXT" '{
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": $context
        }
    }'
fi

# Anything not denied above is allowed to proceed.
exit 0
