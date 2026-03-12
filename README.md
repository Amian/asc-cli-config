# App Store Connect Automation
This repository hosts a lightweight Bash workflow for configuring App Store Connect metadata, pricing, subscriptions, and review settings through the `asc` CLI.

## Overview
- `setup_app.sh` is the orchestrator: it reads an `app_config.json` payload, creates or updates an app bundle, and applies metadata, pricing, availability, subscriptions, privacy, and review info.
- `app_config.json` is the canonical example configuration. Update it with your values and any new schema fields before running the script so the automation stays in sync with your requirements.

## Prerequisites
- `asc` (App Store Connect CLI) and an API key configured via `asc auth login`.
- `jq` for parsing `app_config.json`.
- A POSIX-compatible shell that respects `set -euo pipefail`.

## Usage
1. `./setup_app.sh app_config.json` – create a new app or apply a full configuration baseline.
2. `./setup_app.sh --update app_config.json` – refresh metadata for an existing bundle ID.
3. `bash -n setup_app.sh` – syntax-check the workflow before running it.
4. `jq . app_config.json >/dev/null` – validate the JSON payload.
5. `shellcheck setup_app.sh` (optional) – lint the script for stylistic issues.

## Configuration Layout
- Keep high-level script values (app ID, version, territory flags) in uppercase names and read them via `cfg` helpers in `setup_app.sh`.
- `app_config.json` uses `snake_case` fields; add at least one complete example for every new field you introduce so the sample config always reflects reality.
- Availability sections can now source territory lists either explicitly or by fetching the `asc pricing territories list` catalog when `include_all` is `true`.

## Testing & Validation
1. `bash -n setup_app.sh`
2. `jq . app_config.json >/dev/null`
3. Run the workflow against a non-production bundle to ensure the CLI behaves as expected before touching production metadata.

## Contributing
- Keep helper functions short and self-explanatory (`log`, `warn`, `cfg`, etc.).
- Prefer quoting every variable expansion and using two-space indentation.
- Document schema changes by updating `app_config.json` so users can copy a working example.
- Target one logical change per commit with a conventional-style message (`fix:`, `chore:`, etc.).
