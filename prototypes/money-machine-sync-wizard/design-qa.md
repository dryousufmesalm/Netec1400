# Design QA — Real Money Machine CSV Sync Wizard

## Comparison target

**Source visual truth**

- Overview: `/root/.codex/generated_images/01a02e0e-aad3-7422-ba97-12daf1fc3f79/exec-58863cab-3ab1-4d4d-b5bd-35dc4871a2a6.png`
- VPS details: `/root/.codex/generated_images/01a02e0e-aad3-7422-ba97-12daf1fc3f79/exec-ec4d0ca1-9262-4ff5-ad75-ab59e567421b.png`
- Readiness check: `/root/.codex/generated_images/01a02e0e-aad3-7422-ba97-12daf1fc3f79/exec-108d32b8-907f-47b4-9497-6ca74231bab2.png`
- Source pixels: `1487 × 1058` each.

**Real Windows implementation**

- Browser: installed Microsoft Edge on the connected Windows 11 device.
- Host: real Windows PowerShell loopback service serving the packaged `WizardApp`; no mocked API.
- Desktop viewport: `1440 × 1024` CSS pixels at device scale factor 1.
- Mobile viewport: `390 × 844` CSS pixels at device scale factor 1.
- Evidence:
  - `qa-real/01-real-overview-empty.png`
  - `qa-real/02-real-form.png`
  - `qa-real/03-real-account-error.png`
  - `qa-real/04-real-success.png`
  - `qa-real/05-real-updated-overview.png`
  - `qa-real/06-real-overview-mobile.png`
- Desktop pixels: `1440 × 1024`; mobile full-page capture: `390 × 1354`.
- Browser console evidence: `qa-real/console-errors.json` contains `[]` after accounting for the one intentionally tested 422 account-validation response.

## Combined comparison evidence

- `qa-comparison/comparison-overview.png`
- `qa-comparison/comparison-form.png`
- `qa-comparison/comparison-check.png`

Each 2948-pixel-wide board places the original source and the matching real Windows state in the same image. Both sides are proportionally fit into equal columns without cropping; density is 1×. Separate focused crops were not required because fields, labels, states, icons, and error copy remain readable in the full-resolution pair boards.

## Real interactions tested

- Load discovery from the PowerShell API and show an empty configured-device state.
- Open the add-VPS flow with the discovered MT4 CSV and OneDrive root preselected.
- Submit an intentionally wrong MT4 account and verify a visible, non-technical Arabic error.
- Correct the account and complete schema validation, atomic config write, real first CSV publication, and staging task-registration skip.
- Verify the success state distinguishes local publication from receiver-side cloud proof.
- Return to the dashboard and verify the newly configured VPS, real CSV count, and active state.
- Reload at 390 pixels wide and verify the updated account on mobile.
- Check all browser console/page errors.

## Required fidelity surfaces

- **Fonts and typography:** Tahoma/Segoe UI Arabic fallbacks render consistently in Edge. Heading scale, small labels, LTR paths, wrapping, and error text remain readable on desktop and mobile.
- **Spacing and layout rhythm:** the three-step hierarchy, large cards, form rows, readiness checks, status dashboard, radii, and shadows match the selected calm light-blue direction. Real discovery adds one OneDrive selector without breaking the original rhythm.
- **Colors and visual tokens:** navy, Microsoft-like blue, pale-blue surfaces, green success, red validation, amber cloud-proof, and blue-gray borders are semantically consistent and maintain contrast.
- **Image and icon quality:** Phosphor icons remain sharp at both densities. The source mockups' three separate explanatory illustrations are intentionally consolidated into the live VPS-to-OneDrive diagram because the approved product is one connected web flow.
- **Copy and content:** the app is Arabic RTL and hides PowerShell/OneDrive implementation detail. It never requests passwords, labels local publication honestly, and translates backend validation into operator-friendly copy.

## Findings

- No actionable P0, P1, or P2 findings remain.
- Simulated Windows title bars and the source mockups' separate overview windows are intentionally omitted; the packaged wizard opens inside the user's installed browser and uses one continuous navigation model.

## Comparison history

1. Initial prototype QA was blocked because the Linux environment had no browser.
2. Windows Edge capture enabled full comparison. The initial desktop form had a P2 short-card/density issue and one favicon 404; both were fixed and retested.
3. The first real API acceptance found two P2 issues: the schema mismatch leaked technical English, and a long local destination path overflowed the success card.
4. Fixes: known setup failures now map to concise Arabic guidance; destination text uses constrained wrapping; browser acceptance asserts the path bounding box remains inside the card.
5. Post-fix evidence: `qa-real/03-real-account-error.png`, `qa-real/04-real-success.png`, and all three combined comparison boards. The final real Windows acceptance passed with six screenshots and zero unexpected console errors.

## Follow-up polish

- P3: a signed installer can replace the folder-copy deployment later; it is not required for the current self-contained PowerShell package.

final result: passed
