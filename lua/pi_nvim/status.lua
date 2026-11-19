local M = {}
function M.label(panel)
  if panel.dismissed then return 'Dismissed — no changes applied' end
  if panel.stale and panel.status == 'proposed' then return 'Outdated — request again' end
  local labels = {
    idle = 'Draft — type your request',
    running = 'Working…',
    proposed = 'Ready — awaiting your review',
    needs_clarification = 'Needs your input — reply in chat',
    rejected = 'Rejected — no change proposed',
    failed = 'Failed — open chat for details',
    accepted = 'Accepted in buffer',
    applied = 'Applied to disk (headless/legacy)',
    rolled_back = 'Reverted on disk (headless/legacy)',
  }
  return labels[panel.status] or panel.status
end
return M
