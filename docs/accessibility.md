# Accessibility Testing

Caramelo treats accessibility as an ongoing product requirement. Automated checks
protect the rendered pages from common regressions, while manual checks cover the
parts of WCAG that require human judgment.

## Automated Checks

System tests use Deque’s open-source axe-core engine through the
`axe-core-capybara` Ruby integration. The audit runs against the current
Capybara/Selenium page, so it can inspect authenticated content and states after
an interaction. The test suite selects the WCAG 2.0, 2.1, and 2.2 Level A and AA
rule tags.

Run the focused checks with:

```sh
docker compose -f .devcontainer/compose.yaml exec rails-app \
  bash -lc 'mise exec -- bin/rails test test/system/accessibility_test.rb'
```

The normal `bin/ci` system-test job includes this file, so a violation fails CI.
Each failure reports the axe rule, impact, affected selector and HTML, and a
Deque help link for the rule.

The regression matrix currently covers:

- populated dashboard, positions, transactions, performance, institutions,
  instruments, instrument, settings, market-data health, trade forms, instrument
  forms, corporate-action forms, and methodology pages;
- mobile rendering at 390 × 844 and desktop rendering at 1280 × 900;
- body-level horizontal overflow on mobile, while allowing intentionally
  scrollable data tables;
- revealed currency pickers, transaction menus, mobile navigation, and price
  history;
- empty positions and transaction states;
- server-side form validation errors; and
- destructive controls with their confirmation path.

There are currently no global rule or selector exclusions. If a third-party
region ever needs an exclusion, keep it limited to that region, explain why in
the test, and track the missing coverage in an issue.

## Manual Checklist

Run this checklist for new interactive flows and before a significant UI release:

- Navigate the complete flow with a keyboard only. Tab order follows the visual
  order, every control is reachable, and Enter/Space activates the expected
  action.
- Confirm the focused control is always visible and has a clear focus ring,
  including inside menus, dialogs, custom selects, and sticky regions.
- Check the page has one meaningful `h1`, ordered headings, landmarks, and a
  working “Skip to content” link.
- Verify every field has a visible label, errors are adjacent to the field, and
  the first invalid field receives focus after submission.
- Check status changes, loading, errors, and success messages are announced
  politely without trapping focus.
- Inspect text, controls, charts, badges, and links in light and dark themes at
  normal contrast and when hovered or focused.
- Zoom to 200% and 400% and use a 390-pixel viewport. Content should reflow
  without hidden actions or accidental page-level horizontal scrolling.
- Enable reduced motion and confirm essential information and controls remain
  available without animation.
- Perform a basic screen-reader pass: page title, landmarks, headings, form
  labels, chart descriptions, exact-value tables, and error/status announcements.

## What Automation Does Not Prove

axe-core checks only rules that can be evaluated from the current DOM and browser
state. A passing scan is not a WCAG conformance claim: it cannot reliably judge
whether copy is understandable, whether a focus sequence makes sense, whether a
screen-reader announcement is useful, or whether a workflow is usable with
assistive technology. Keep the automated checks and manual checklist together.

The scanner runs only in the test process and is not loaded by the production
application. Like other browser accessibility engines, it may inspect referenced
cross-origin stylesheets while evaluating contrast; no application credentials or
financial data are sent to a Deque service.
