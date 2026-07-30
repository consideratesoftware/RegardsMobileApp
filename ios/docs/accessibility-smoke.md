# VoiceOver manual smoke

Run this before merging any UI-touching PR. Records go in the PR description
under a **Manual accessibility smoke** heading.

## Setup

1. Boot the iPhone 17 Pro simulator (`xcrun simctl boot "iPhone 17 Pro"` or open from
   Xcode).
2. Install the Debug build.
3. Simulator → **Features → Toggle VoiceOver** (⌘+⌥+F5 on a real device, or
   Accessibility Inspector on simulator).
4. Simulator → **Features → Toggle Software Keyboard** (so you can type if
   prompted, otherwise leave off).

## Launch and tab shell

- [ ] Launch app. VoiceOver announces "Regards. Loading." as a header.
- [ ] After the splash fades, focus can reach the Overdue heading and all four
      tab buttons.
- [ ] No VoiceOver focus trap. You can move through the tab root and back.
- [ ] Toggle Dynamic Type to `accessibility5`
      (Settings → Accessibility → Display & Text Size → Larger Text → slider
      all the way up). App re-renders without clipping or truncation.

## Screen checklist

Apply this checklist to every screen changed by the pull request:

- [ ] VoiceOver announces the screen title as a header.
- [ ] Each row reads as a single natural-language sentence.
- [ ] All interactive elements announce a trait (button, tab, toggle…).
- [ ] Hints describe the effect of activation where non-obvious.
- [ ] At Dynamic Type `accessibility5`, the screen still fits without
      mid-word truncation and all CTAs remain tappable.
- [ ] With **Reduce Motion** on, transitions into/out of this screen use a
      crossfade or no animation.
- [ ] With **Increased Contrast** on, no text/background pair looks washed
      out; icons remain visible.
- [ ] Priority indicators (inner-circle ring, overdue state) are still
      distinguishable without color.

## Reporting

In the PR description:

```
## Manual accessibility smoke
Simulator: iPhone 17 Pro · current CI-pinned iOS runtime
VoiceOver: on
Dynamic Type: accessibility5
Reduce Motion: on / off (both tested)
Increased Contrast: on / off (both tested)

Findings: none  (or: list, with proposed fixes)
```
