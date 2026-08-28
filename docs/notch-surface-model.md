# Notch Surface Model

The island now separates layout from content surface:

- `closed`: collapsed notch only
- `opened + sessionList`: manual browsing of attached sessions
- `opened + approvalCard`: auto-expanded approval interaction after a short pending-state delay
- `opened + questionCard`: question interaction reached through the session list
- `opened + completionCard`: auto-expanded finished-task reminder

Routing rules:

- manual click or hover opens `sessionList`
- `permissionRequested` opens `approvalCard` only when it remains unresolved long enough to require human attention
- `questionAsked` updates the actionable session state without opening the island
- `sessionCompleted` opens `completionCard`
- activity, thinking, tool, and metadata updates never open the island

Completion cards are temporary surfaces:

- they auto-collapse after a short timeout
- they also collapse when the pointer leaves the card after first hover
- they are not rendered as inline actions inside the session list

This keeps background progress quiet. The island interrupts the user only for
finished work and approval requests that were not resolved automatically;
questions and intermediate activity remain available in the session list.

The main DEV window is now a dedicated debug harness for these surfaces. It
drives inline mock previews for the session list plus approval, question, and
completion cards, and it can mirror the currently selected mock onto the real
island overlay for visual inspection.
