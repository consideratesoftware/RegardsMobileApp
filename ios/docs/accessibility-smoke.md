# VoiceOver manual smoke

Run this before merging any UI-touching PR. Records go in the PR description
under a **Manual accessibility smoke** heading.

## Setup

1. Boot the iPhone 17 Pro simulator (`xcrun simctl boot "iPhone 17 Pro"` or open from
   Xcode).
2. Install the Debug build.
3. On Simulator, open **Accessibility Inspector**, select the running Regards
   process, and use point inspection plus its narration controls to emulate
   VoiceOver. Simulator can expose a VoiceOver toggle through its Settings app,
   but it is not reliable for gesture testing; use a physical device for native
   VoiceOver validation. On device, enable it in Settings → Accessibility →
   VoiceOver or with the configured Accessibility Shortcut.
4. Simulator → **Features → Toggle Software Keyboard** (so you can type if
   prompted, otherwise leave off).

## Launch and tab shell

- [ ] Launch app. VoiceOver announces "Regards. Loading." as a header.
- [ ] Force a production database-open failure. VoiceOver announces the error,
      focuses “Try Again”, and activation recovers to onboarding without a trap.
- [ ] On a fresh install, VoiceOver reaches the Contacts pre-prompt heading,
      benefit cards, permission CTA, and proofs link in reading order.
- [ ] Activate "Why we ask" and return with Done; neither route traps focus.
- [ ] Grant, deny (both before and during launch), and retry states expose only
      working controls. Importing disables duplicate activation, and the
      browse-without-importing action reaches the tab root.
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
- [ ] All Contacts only, when a corrupt row is reachable: the corruption
      banner reads as one sentence ("N contact(s) couldn't be read and
      needs/need attention.") with no separate icon announcement, and
      VoiceOver can still reach a healthy row below it.

## Reminder windows

Run this when the PR touches the reminder-window editor or Contact Detail's
Reminder window row.

- [ ] Settings → Reminder windows: each day pill reads its full day name (for
      example, "Thursday") and its value, "allowed" or "not allowed".
- [ ] Turn off every day and activate Save. The error banner scrolls to the
      center of the screen, focus moves to it, and then VoiceOver announces the
      message. The screen stays open, and the draft is unchanged.
- [ ] Scroll to the bottom of the editor and activate Save with a refusal. The
      error banner scrolls to the center of the screen and focus moves to it.
- [ ] Repeat with an overlapping time range, then with quiet hours whose start
      equals end. Each refusal moves focus to the message, then announces it.
- [ ] Quiet hours that cover every allowed time are refused with "Quiet hours
      cover every allowed time, so no reminder could ever fire. Shorten the
      quiet hours or add a time range."
- [ ] Select each day set and listen to the day summary: "No days selected.",
      "Weekdays only. Weekends are yours.", "Weekends only.", "Any day.", or a
      list of the selected day names.
- [ ] "+ Add range" is labelled "Add range" and adds a one-hour range that
      starts at the latest range end, clamped to 11:59 pm. When the latest range
      already ends at 11:59 pm, the button is disabled, and its hint says "The
      last range already ends at 11:59 pm, so there's no time left after it."
- [ ] Activate "+ Add range". VoiceOver announces "Range N added, <start> to
      <end>", for example "Range 2 added, 10:00 PM to 11:00 PM".
- [ ] Activate the Remove button on a range (it is absent when only one range
      is left). VoiceOver announces "Range N removed. X range(s) left.", for
      example "Range 2 removed. 1 range left."
- [ ] The "Quiet hours" section header reads "Quiet hours". With quiet hours
      off, the toggle speaks "Quiet hours" and then "off". With quiet hours on,
      it speaks "Never between, <start> to <end>" and then "on". Check it in
      both modes.
- [ ] Global editor only: the morning-of caption and its hint both read
      "Birthdays and anniversaries, separate from cadence." The footer reads "All times local ·
      <zone name>. Daylight saving time is handled automatically."
- [ ] Activate Save on a valid window. The editor dismisses, and Upcoming shows
      the new "Next N days" label.
- [ ] Change a day, leave without Save, and reopen the editor. The change is
      gone, and nothing asks for confirmation.
- [ ] Open Contact Detail for a tracked contact with a cadence. "Reminder
      window" reads "Default window", with a Change button. Activate Change,
      change one day or one time range, then Save. The editor dismisses, and
      the row reads "Custom window".
- [ ] In that override editor, activate "Use default window". The editor
      dismisses, and the row reads "Default window".
- [ ] At Dynamic Type `accessibility5`, the day pills, time ranges, Save, and
      "Use default window" fit without clipping and stay tappable.
- [ ] Open the editor for a contact on the default window, change nothing, and
      activate Save. The editor closes, and the row still reads "Default window".
- [ ] Contact Detail has no "Next reminder" row.
- [ ] Overdue shows no digest time and no footer sentence. The lead reads
      "Send your regards".

## Reporting

In the PR description:

```
## Manual accessibility smoke
Simulator: iPhone 17 Pro · current CI-pinned iOS runtime
VoiceOver: Accessibility Inspector emulation (simulator) / on (physical device)
Dynamic Type: accessibility5
Reduce Motion: on / off (both tested)
Increased Contrast: on / off (both tested)

Findings: none  (or: list, with proposed fixes)
```
