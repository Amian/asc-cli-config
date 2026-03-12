# App Store Connect Automation

Use `setup_app.sh` with `app_config.json` to script bundle registration, metadata updates, pricing, subscriptions, privacy, and review details through the [`asc`](https://github.com/rudrankriyam/App-Store-Connect-CLI) CLI.

## Overview
- `setup_app.sh` is the orchestrator: it reads `app_config.json`, creates or updates an app, and applies metadata, pricing, availability, subscriptions, privacy, and review info.
- `app_config.json` is the canonical example configuration; keep it in sync with script capabilities.

## Prerequisites
- [`asc`](https://github.com/rudrankriyam/App-Store-Connect-CLI) installed and authenticated (`asc auth login --key-id <KEY_ID> --issuer-id <ISSUER_ID> --private-key /path/to/AuthKey_XXXX.p8`).
- [`jq`](https://stedolan.github.io/jq/) for parsing the JSON config.
- A registered App Store Connect API key (https://appstoreconnect.apple.com/access/integrations/api) with Admin permissions.
- Bash or another POSIX shell that honors `set -euo pipefail`.

## Quick Start
1. Copy and edit `app_config.json` with your app metadata, pricing, subscriptions, privacy, and review data.
2. Validate inputs: `bash -n setup_app.sh` and `jq . app_config.json >/dev/null`.
3. Run `./setup_app.sh app_config.json` to create a new app, or `./setup_app.sh --update app_config.json` to update an existing one.
4. For App Privacy, provide `privacy.apple_id` (and optionally `privacy.two_factor_code`) if no cached web auth session exists.

## Configuration Layout
- Keep config keys in `snake_case`.
- Keep helper-driven script values centralized and quoted in `setup_app.sh`.
- Include at least one complete example for each new config field in `app_config.json`.
- Availability can be explicit by territory list or via generated full-territory input when supported by the script flow.

## Testing And Validation
1. `bash -n setup_app.sh`
2. `jq . app_config.json >/dev/null`
3. Optionally run `shellcheck setup_app.sh`
4. Test against a non-production bundle before production metadata changes.

## Follow-Up
- Upload screenshots (`asc screenshots upload`).
- Upload the build via Xcode or Transporter.
- Submit for review (`asc submit`) when metadata and build are ready.

## Contributing
- Keep helper functions short and self-explanatory (`log`, `warn`, `cfg`, etc.).
- Prefer quoting variable expansions.
- Document schema changes by updating `app_config.json`.
- Keep one logical change per commit with a clear commit message.
