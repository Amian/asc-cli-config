# App Store Connect Automation

Use `setup_app.sh` with `app_config.json` to script bundle registration, metadata updates, pricing, subscriptions, privacy, and review details through the [`asc`](https://github.com/rudrankriyam/App-Store-Connect-CLI) CLI.

## Prerequisites
- [`asc`](https://github.com/rudrankriyam/App-Store-Connect-CLI) installed and authenticated (`asc auth login --key-id <KEY_ID> --issuer-id <ISSUER_ID> --private-key /path/to/AuthKey_XXXX.p8`).
- [`jq`](https://stedolan.github.io/jq/) for parsing the JSON config.
- A registered App Store Connect API key (https://appstoreconnect.apple.com/access/integrations/api) with Admin permissions.
- Bash or another POSIX shell that honors `set -euo pipefail`.

## Quick start
1. Copy and edit `app_config.json` with your app metadata, pricing, subscriptions, privacy, and review data. Keep the schema keys in `snake_case`.
2. Run `bash -n setup_app.sh` and `jq . app_config.json >/dev/null` to validate the script and config.
3. Execute `./setup_app.sh app_config.json` to create a new app or `./setup_app.sh --update app_config.json` to refresh an existing bundle.
4. App Privacy sections rely on `privacy.apple_id` (and optional `privacy.two_factor_code`) to seed `asc web auth login` before running `asc web privacy` commands.

## Validation & follow-up
- Always run `bash -n setup_app.sh` and `jq . app_config.json >/dev/null` before executing.
- Dry run the script using a sandbox or test bundle to confirm the `asc` flow succeeds.
- After the script finishes, manually upload screenshots (`asc screenshots upload`), upload your build, and submit for review (`asc submit`).

Keep pushing the `dev` branch only (per repository workflow). Refer to `AGENTS.md` for coding and commit conventions when you edit the script or config.
