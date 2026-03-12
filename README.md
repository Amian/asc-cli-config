# App Store Connect Automation

This repository automates App Store Connect setup via the `asc` CLI so you can drive bundle registration, metadata, pricing, subscriptions, privacy, and review details from a single `app_config.json` manifest.

## Repository layout
- `setup_app.sh`: orchestrates the full workflow. Reads `app_config.json`, creates or updates the app, and runs each `asc` command in a guarded step with logging and graceful skips.
- `app_config.json`: canonical configuration payload. Extend this file with every new schema entry so examples stay accurate.
- `AGENTS.md`: local guidelines for contributors (read before editing the workflow/JSON).

## Prerequisites
- [`asc` (App Store Connect CLI)](https://github.com/rudrankriyam/App-Store-Connect-CLI) – install per the repo instructions and authenticate with `asc auth login --key-id <KEY_ID> --issuer-id <ISSUER_ID> --private-key /path/to/AuthKey_XXXX.p8`.
- [App Store Connect API keys](https://appstoreconnect.apple.com/access/integrations/api) – create an Admin-scoped key and keep the `.p8` private key locally.
- [`jq`](https://stedolan.github.io/jq/) – used for parsing `app_config.json` (install via `brew install jq`, `apt install jq`, etc.).
- POSIX shell honoring `set -euo pipefail` (the script assumes Bash-compatible features and strict error handling).

## Configuration schema
Every section lives under `app_config.json` and follows the snake_case naming convention.

- `app`: `id` (empty for create, filled by lookup in update mode), `name`, `bundle_id`, `sku`, `platform`, `primary_locale`, `content_rights`, and other defaults that `asc apps create` consumes.
- `version`: `version_string`, optional `copyright`, and `release_type`.
- `categories`: `primary`, `secondary`, and their subcategory slots (`primary_subcategory_one`, `secondary_subcategory_two`, etc.).
- `age_rating`: combine enum flags (e.g., `alcohol_tobacco_or_drug_use_or_references`) with boolean toggles (`advertising`, `parental_controls`, etc.); the script maps these to `asc age-rating` flags.
- `localizations`: array per locale with `subtitle`, `description`, `keywords`, `whats_new`, `promotional_text`, `support_url`, `marketing_url`, and `privacy_policy_url`; the script updates both the version and app-info localizations.
- `privacy`: `enabled`, `publish`, `allow_deletes`, optional `apple_id`, `two_factor_code`, and `data_usages` (schemaVersion 1) for the App Privacy declarations that `asc web privacy` manages.
- `pricing`: `base_territory`, either `price_tier` or explicit `price`, and `availability` with `available_in_new_territories`, `include_all`, and explicit `territories`. When `include_all` is `true`, the script fetches `asc pricing territories list` and sets every territory.
- `subscriptions`: groups array. Each group lists `reference_name`, optional `localizations`, and `subscriptions` containing `ref_name`, `product_id`, `subscription_period`, `family_sharable`, `prices` (territory/tier pairs), and `localizations`. Availability mirrors the `pricing` availability helpers when configured.
- `in_app_purchases`: type, `ref_name`, `product_id`, `family_sharable`, `prices` (territories plus tiers), and localizations.
- `encryption`: booleans for `contains_proprietary_cryptography`, `contains_third_party_cryptography`, `available_on_french_store`, and a description summary.
- `review_info`: contact details (`contact_first_name`, etc.), demo credentials, and `notes`.

Use the helpers at the top of `setup_app.sh` (e.g., `cfg`, `cfg_bool`, `cfg_bool_default`) to access these values safely.

## Workflow
1. Validate prerequisites (presence of `asc`, `jq`, and API key auth). The script fails fast if these are missing.
2. In create mode (default), the script registers the bundle ID, runs `asc apps create`, and captures the new App ID. In update mode (`--update`), it skips creation and tries to find existing versions.
3. It sets content rights, creates or finds the App Store version, sets categories/age rating, updates localizations, manages App Privacy via `asc web privacy`, and configures pricing plus availability.
4. Subscription groups/prices/localizations and IAPs are created next, followed by encryption declarations and explicit review details for the version.
5. After completion, the script prints the app identifiers and points out the remaining manual steps (`asc screenshots upload`, build upload, `asc submit`).

## Usage
1. Update `app_config.json` to reflect your metadata, localizations, pricing, subscriptions, encryptions, etc.
2. `bash -n setup_app.sh` – syntax-check the script.
3. `jq . app_config.json >/dev/null` – ensure JSON is valid.
4. Run `./setup_app.sh app_config.json` to create a new app (prompts for Apple ID + 2FA once).
5. Use `./setup_app.sh --update app_config.json` to refresh metadata on an existing bundle ID; this reuses the App ID from `asc apps list`.
6. For App Privacy, the script may prompt `asc web auth login` if no cached session exists; pass `privacy.apple_id` and optionally `privacy.two_factor_code` to automate it.

## Validation
- `bash -n setup_app.sh`
- `jq . app_config.json >/dev/null`
- Dry run the script against a sandbox or non-production bundle before pushing to active apps. This ensures `asc` commands succeed and your JSON matches reality.

## Notes
- The script enforces strict quoting, two-space indentation, and minimal helper comments (aligning with the local style guide in `AGENTS.md`).
- When modifying `app_config.json`, always leave a realistic example of each added field so users understand how to structure it.
- Push only the `dev` branch to the remote; this repo avoids accidentally publishing `main`.
