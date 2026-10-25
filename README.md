# ruki-trenirovka

Training ground for generic desktop UI movements on Windows: UIA element search,
SendInput unicode typing with focus checks and read-back, Enter/Tab/Esc, window
visibility, and a hard stop on password fields.

- `polygon/` neutral local practice pages with seeded disturbances
  (delay, popping modal, focus moved away, re-render that clears a field)
- `lib/` PowerShell library of movements
- `skills/zapolnit-formu.ps1` fill a form by a JSON plan (`plans/`)
- `ci/progon.ps1` one training job; `ci/svod.py` aggregation
- `ci/proverka-gigieny.ps1` public hygiene check (runs first in CI)

Results of the last run are published to the branch `itog` (`itog.md`, `itog.json`).

File upload trainer (branch `trener-fajl`): `lib/fajl.ps1` drives the system file-open dialog
(file name box by ValuePattern, Open / Cancel by posted clicks), pages `polygon/fajl-*.html`,
plans `plans/fajl-*.json` (step type `fajl`), job `ci/progon-fajl.ps1`, results in branch `itog-fajl`.
