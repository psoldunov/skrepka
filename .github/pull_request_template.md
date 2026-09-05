<!--
Thanks for the pull request. CONTRIBUTING.md has the full expectations; this
template is the short version. Delete any section that genuinely does not apply
rather than leaving it empty.
-->

## What this changes

<!-- One paragraph. What behaviour is different after this lands? -->

## Why

<!--
The problem, not the patch. Link the issue it closes: `Closes #123`.
If there is no issue and this is more than a typo, say why it did not need one.
-->

## How you verified it

<!--
This is the section that matters most. A lot of Skrepka's behaviour only shows
up with the app actually running over another app, and no automated check sees
it. Say what you actually did, not what should work.
-->

- [ ] `scripts/doctor.sh` is green — format, lint, build with warnings as errors, tests, dead-code scan
- [ ] SwiftLint and Periphery are installed, so neither step was skipped with a warning
- [ ] Launched with `scripts/run.sh`, not by executing the binary

Manual checks performed:

<!--
For example: opened the picker over a full-screen app; confirmed focus returned
to the previous app after pasting; checked the menu bar mark in both light and
dark appearance; revoked and re-granted Accessibility.
-->

## Tests

<!--
A bug fix starts with a failing test that reproduces the bug — name it here.
If the change is genuinely untestable (SwiftUI view body, NSPanel placement,
hotkey registration, a permission flow), say which of those it is and why.
-->

## API claims

<!--
Which external APIs, config keys or CLI flags this change relies on, and where
you confirmed each one — SDK headers, a .swiftinterface, vendor docs. Anything
you could not verify goes here labelled as unverified, rather than being left
to look checked.
-->

## Notes for review

<!--
Anything else: a lint rule silenced at a line and why, a decision you were
unsure about, a follow-up you deliberately left out of scope, or a screenshot
or recording if this changes what the user sees.
-->
