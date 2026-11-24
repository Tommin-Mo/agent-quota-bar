# Motion language

AgentQuotaBar is an operating surface, not a showcase. Motion explains a state
change or confirms an action; it never makes the user wait for choreography.

## One scale

| Duration | Use |
|---|---|
| 120 ms | feedback: value change, check-in status, hint |
| 180 ms | routine state: expand, page, scope, conditional field |
| 240 ms | spatial/layout transition |
| 100 ms | exit |

Entrances use `cubic-bezier(0.16, 1, 0.3, 1)` (`QuotaMotion.enterEase`).
Exits use a faster deceleration. No bounce, elastic, or looping decoration.
All motion lives in `Sources/AgentQuotaBar/QuotaMotion.swift`; new code must use
those constants rather than inventing a duration.

## State map

- **Panel structural change**: rows fade in with a 3 pt rise. Same-order data
  refreshes do not replay the entrance.
- **Changed primary value**: only the changed number gets a 120 ms fade/2 pt
  settle; unchanged rows stay still.
- **Expand / collapse**: detail enters with a 180 ms fade/3 pt rise; collapse
  removes immediately so an interrupted re-tap cannot leave a stale row.
- **Pager / settings page**: new page fades in without translation; the old
  page is hidden synchronously so the next layout is deterministic. Pages have
  no spatial relationship, so a vertical move would only expose the layout jump.
- **History month / scope**: calendar fades in with a 2 pt rise; selected-day
  details use feedback timing.
- **Conditional fields** (fixed service, custom proxy, manual setup): reveal
  with the same standard transition.
- **Header hint**: short feedback fade.
- **Drag reorder**: direct manipulation, no layout animation.

## Constraints

- Only opacity and transform; no animated blur or shadow. The rare account
  sheet height change is the one AppKit frame change, and it is disabled under
  Reduce Motion.
- Animations are layer-local; large surfaces get one layer, not per-row layers.
- Re-entrant calls do not restart from zero: a running entrance is allowed to
  finish, so rapid page/month/value changes settle on the final state without
  a one-frame flash.
- `NSWorkspace.accessibilityDisplayShouldReduceMotion` disables movement,
  animated entrances, the account-sheet frame animation, and the rating
  popover's built-in animation. All final states remain visible without motion.
- No background loops; polling and network work remain on their existing
  schedules.
