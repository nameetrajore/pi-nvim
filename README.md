# pi-nvim

AI-authored, approval-first Pi editing for Neovim and headless use. Requires Python 3,
authenticated `pi`, and Neovim 0.12+ (uses native prompt-buffer chat APIs).
Default model: **`openai-codex/gpt-6.1-terra`**, for editor requests, the CLI, and
fresh-session handoffs. This does not change your global Pi settings.

## Install

```sh
git clone https://github.com/nameetrajore/pi-nvim.git
cd pi-nvim
./install.sh
```

The installer replaces only plugin-owned files: `lua/pi_nvim/*.lua`,
`lua/custom/plugins/pi-nvim.lua`, and `scripts/pi_nvim.py` under your Neovim config,
plus `~/.local/bin/pi-nvim`. Back up custom edits to those files first. Installed
copies do not depend on keeping the checkout. `XDG_CONFIG_HOME` and `NVIM_APPNAME`
are respected. Add `~/.local/bin` to PATH for the headless CLI.

If your config auto-loads `lua/custom/plugins/`, no extra setup is needed. Otherwise,
add `require('pi_nvim').setup {}` to `init.lua`. The installer never loads your full
config, downloads plugins, connects to Pi, or installs credentials.

For chezmoi, import those installed files and the launcher with `chezmoi add`.
Do not import Pi credentials, run history, or private handoff snapshots.

## Questions and edits in one chat

Ask a question or request an edit in the same floating chat. Pi decides whether to
answer or propose changes; ambiguous requests should prompt clarification. A model can
misread intent, so check its response. Proposals never apply automatically and always
require your explicit acceptance. Questions can reference a pending proposal without
discarding it. Questions support named UTF-8 text buffers; edits support Markdown and
Neovim Lua configuration (`:PiConfig`).

## Editor workflow

1. Open a named UTF-8/Unix buffer. Unsaved edits and new named files are supported.
   Press **Space pi**, optionally after a characterwise (`v`) or linewise (`V`) selection.
2. Type in the small floating chat. **Insert-mode Enter sends**; the chat hides
   and focus returns to the source. Requests never apply edits automatically.
3. Read the proposal inline: removed source lines are highlighted, additions are
   virtual lines. Buffer text, undo history, and disk are untouched by previews.
4. **Space pi** reopens this chat. Type feedback and Enter to revise the proposal.
   The same chat retains previous messages; each revision is a linked history run.
5. **Esc**, then **Enter** in Normal mode opens selectable actions:
   **Apply**, **Dismiss preview**, **New request**, **Requests**, **History**, and
   **Copy Pi session command**. Revision is just another chat message, not a button.

Apply edits the existing source buffer as **one separate native undo step**, clears
the preview, and hides the chat. It does not write the file, reload it, or open a
result split. Use **u** to undo, **Ctrl-R** to redo, and **:write** to save normally.
Earlier unsaved edits and undo history are preserved. Readonly/nonmodifiable buffers
and buffers with undo disabled are not changed. Final-newline/encoding options are
preserved rather than changed outside the undo tree. There is no editor Rollback.
Dismiss only removes the preview; history stays intact. Normal-mode `q` hides chat without
cancelling a request. Ordinary `i`/`a`, navigation, and yanking work in chat.
While a valid inline proposal is selected, **Normal-mode Ctrl-Y accepts** and
**Ctrl-N dismisses**. These are temporary buffer-local bindings: existing mappings
are restored when the preview is cleared. Insert-mode completion keys and Harpoon's
Ctrl-E are untouched. There are no new global action shortcuts. The older plugin-owned
`Space p{a,u,e,h,d,c,r,l}` bindings are removed; user-defined replacements are kept.
`setup { mappings = false }` disables installation of the Space pi entry point.

Multiple requests can run independently. Choose **New request**, select another
region, or use `:PiRun` to start another chat. **Requests** switches between them.
One chat/preview is selected per source buffer; late results never replace the
selected request or steal focus. Feedback in one chat is sequential: wait for its
current response before submitting another message there. Draft feedback survives
asynchronous output. Drafts are editor-local until submitted. After acceptance,
subsequent messages use the current buffer (even after undo or further edits) as a
fresh snapshot in the same conversation; select text again for a new scoped request.

Proposals from the same old buffer version are **not merged**. Accepting one makes
others stale, even for disjoint selections. Start a new request on the current
source. Only changes since the proposal's snapshot block acceptance; pre-existing
unsaved edits are part of that snapshot. Provider limits/costs apply independently to
each request. There is no automatic terminal launch or background daemon.

### Processing versus waiting for you

The floating title, request picker, and source annotation distinguish:

- **Working…**: Pi is still processing; nothing is ready to accept yet.
- **Ready — awaiting your review**: processing finished; accept, dismiss, or chat.
- **Answered — ask a follow-up**: read the answer in chat.
- **Needs your input — reply in chat**: Pi finished but needs clarification.
- **Rejected** / **Failed**: no usable proposal; open chat for the reason.
- **Accepted in buffer**: text was accepted, not automatically saved.
- **Outdated**: the source changed; the old proposal cannot be accepted.

## Interactive Pi handoff

Select **Copy Pi session command** (or `:PiCopyCommand`). This creates a private
context file with the conversation, source snapshot, selection, proposal, and the
current buffer when loaded (including unsaved edits), then
copies a shell-quoted command to the unnamed register and clipboard when available:

```sh
cd -- WORKSPACE && pi --model openai-codex/gpt-6.1-terra -- @PRIVATE_CONTEXT_FILE
```

Paste it into a separate terminal yourself. It starts a **fresh interactive Pi
session**, not a resumed SDK/session transcript. The handoff asks Pi to review the
context and ask what to do next, not automatically apply the saved proposal. It
uses your ordinary Pi credentials/tools/trust checks. The context file is also
shown in the chat; handoff files under the state directory's `handoffs/` remain
until explicitly deleted. They can contain sensitive source and conversation data.

## Setup and commands

The installed loader is `~/.config/nvim/lua/custom/plugins/pi-nvim.lua`:

```lua
require('pi_nvim').setup {} -- optional override: model = 'provider/model:thinking'
```

It uses the runner in the same config's `scripts/pi_nvim.py`, not a machine-specific
project path. Set `cli` explicitly only if using a development checkout.

- `:PiRun [instruction]`: new Markdown request; no argument opens the floating input.
  `:'<,'>PiRun ...` scopes an Ex request to selected **lines**. Visual Space pi
  instead preserves exact character boundaries.
- `:PiConfig [instruction]`: Lua config buffer under `~/.config/nvim`.
- `:PiActions`, `:PiRequests`, `:PiHistory`: selectable controls and run browsers.
- `:PiShow [id]`: reopen chat/history; restores linked conversation when available.
- `:PiApply [id]`: accept into the source buffer, not the file. Use native undo.
  `:PiRevise` and `:PiRollback` have been removed; chat and undo replace them.
- `:PiReload`: reload integration code without losing chats; waits for active jobs.
- `:PiSource`: separately confirm execution of reviewed, saved Lua config.
  Lua runtime side effects are **not transactional**; restart for non-idempotent
  plugin/startup changes. File rollback cannot undo execution side effects.

Buffer edits and inline previews require UTF-8/Unix text without a BOM.
Blockwise and virtual-column selections are rejected. Source edits remove preview
decorations; snapshots that no longer match the buffer cannot be accepted. Inline
display is capped at 120 changed lines; the saved proposal/diff remains complete.

## Headless

```sh
pi-nvim run notes/workflow.md 'Insert a grounded Mermaid diagram' --workspace "$PWD"
pi-nvim run notes/workflow.md 'Explain this workflow' --mode ask --workspace "$PWD"
pi-nvim history
pi-nvim show RUN_ID
pi-nvim revise RUN_ID 'Shorten the labels'
pi-nvim apply REVISED_RUN_ID
pi-nvim rollback REVISED_RUN_ID
pi-nvim thread REVISED_RUN_ID
pi-nvim handoff REVISED_RUN_ID
pi-nvim delete RUN_ID
```

All commands emit JSON. `run` is proposal-only unless `--apply` is explicitly used
(Markdown only; config never auto-applies). Options: `--model`, `--timeout 180`,
`--kind config`, `--mode edit|ask|auto`, `--parent RUN_ID`. Ask responses never create
an applicable replacement and cannot be combined with auto-apply.
`--start-byte N --end-byte M` defines a zero-based,
end-exclusive UTF-8 selection; `--expected-sha256 HASH` checks its source snapshot.
Revisions retain selection boundaries and require unchanged source. Paths resolve
relative to `--workspace`. Errors exit nonzero; refusals/clarifications are successful
no-edit decisions. `--source-stdin` supplies a buffer snapshot to `run` or `revise`;
such runs never auto-apply and preserve the source's final-newline convention.
`accept-buffer ID` records an editor acceptance event without writing source files.
`handoff ID --source-stdin` includes the current buffer in the handoff context.
File-level `apply`/`rollback` remain for headless use only, with disk-content checks.
Headless runs need no editor process; Lua syntax validation uses
isolated `nvim --headless -u NONE -i NONE`, never the user's startup config.

## Boundaries and storage

Pi has no tools, extensions, MCP, skills, or project-instruction loading in editing
runs. This is capability restriction, not an OS sandbox. File/context data is
untrusted; refusals are model decisions, but paths, selection boundaries, validation,
and stale-source checks are enforced in code. Neovim owns editor text/saving/undo;
the runner writes source files only for explicitly requested headless apply/rollback.
Markdown fence balance is checked; **Mermaid syntax/rendering is not validated**.
No code fences execute. Named buffers only (headless file operations require an
existing file); no multi-file changes or shell tools.

The whole source plus up to four relevant Markdown files is sent to your configured
provider. Selection restricts editing, not model visibility. Retrieval scans at most
500 Markdown candidates and excludes hidden trees, symlinks, dependencies, and
oversized files. Do not choose workspaces with material you cannot send to that
provider. Source limit: 150 KB; replacement: 200 KB. Headless writes are serialized,
but external programs do not honor that lock. Editor saving uses normal Neovim
checks for external file changes; acceptance never overwrites the disk.

History: `${PI_NVIM_STATE:-~/.local/state/pi-nvim}/<id>.json`, directory 0700,
records 0600. Includes instructions, timestamps, source/proposal/diff, context
filenames, decisions/errors, selected text/offsets, and revision parents. `accepted`
means accepted into a buffer, **not saved**; it records an event, not the current
undo-tree position. Native undo/redo does not rewrite historical events. Older
`applied` records describe headless/legacy disk writes, not native buffer acceptance.
Each run
uses a fresh tool-free Pi invocation; there is no separately resumable Pi session.
No automatic retention. Deleting a record does not erase descendant records or
separate handoff snapshots that include its content. Killed jobs may leave a
`running` record; inspect before retrying. Config edits still need `chezmoi add`;
this integration never commits or pushes dotfiles.

## Checks

```sh
python3 -m unittest discover -s tests -v
python3 tests/run_editor.py
```

Runner tests cover boundaries, stale apply/rollback, refusals, syntax/fence checks,
UTF-8 selection/revision, unsaved snapshot input, final-newline preservation,
acceptance-event recording without file writes, and private shell-safe handoffs.
Headless editor tests use a deterministic Pi substitute and native prompt Enter:
floating input, chat revisions, selectable actions, non-mutating inline previews,
preview dismissal, concurrent/out-of-order jobs, draft preservation, copied
handoff commands, shortcut migration, and reload-stable chat identity. Native buffer
tests cover undo/redo (including prior unsaved edits), local/global undo options,
insertions/deletions, missing final newline, readonly buffers, and stale proposals.
Tests also exercise transient Ctrl-Y/Ctrl-N mappings and restoration of existing Lua
bindings, preserved Ctrl-E, processing/clarification states, the default model, and
an isolated installation that works without the source checkout. Ask-mode tests
check that malformed edit output is rejected, no source/undo changes occur, and
question/edit turns preserve both the pending proposal and conversation history.
