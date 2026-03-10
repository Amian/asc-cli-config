#!/usr/bin/env bash
# setup_app.sh — Create or update an app on App Store Connect using the asc CLI.
# Usage: ./setup_app.sh [--update] app_config.json
#
# Flags:
#   --update  Update an existing app instead of creating a new one.
#             Skips bundle ID registration and app creation; looks up existing resources.
#
# Prerequisites:
#   - asc CLI installed (https://github.com/rudrankriyam/App-Store-Connect-CLI)
#   - Authenticated via `asc auth login`
#   - jq installed for JSON parsing

set -euo pipefail

MODE="create"
CONFIG=""

for arg in "$@"; do
  case "$arg" in
    --update) MODE="update" ;;
    *) CONFIG="$arg" ;;
  esac
done

if [[ -z "$CONFIG" ]]; then
  echo "Usage: $0 [--update] <config.json>"
  exit 1
fi

if ! command -v asc &>/dev/null; then
  echo "asc CLI not found. Installing..."
  curl -fsSL https://raw.githubusercontent.com/rudrankriyam/App-Store-Connect-CLI/main/install.sh | bash
  if ! command -v asc &>/dev/null; then
    echo "ERROR: asc CLI installation failed. Install manually from https://github.com/rudrankriyam/App-Store-Connect-CLI"
    exit 1
  fi
  echo "asc CLI installed successfully."
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not found. Install with: brew install jq"
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: $CONFIG"
  exit 1
fi

# Check API key auth is configured (used for all steps except app creation)
if ! asc apps list --limit 1 --output json >/dev/null 2>&1; then
  echo ""
  echo "API key authentication not configured. You need to set this up first."
  echo "1. Go to https://appstoreconnect.apple.com/access/integrations/api"
  echo "2. Generate an API key (Admin role recommended)"
  echo "3. Download the .p8 file"
  echo "4. Run: asc auth login --key-id YOUR_KEY_ID --issuer-id YOUR_ISSUER_ID --private-key /path/to/AuthKey_XXXX.p8"
  echo ""
  exit 1
fi
echo "API key auth: OK"

cfg() { jq -r "$1" "$CONFIG"; }
cfg_bool() { jq -e "$1" "$CONFIG" >/dev/null 2>&1; }

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[SKIP]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
step() { echo -e "\n${YELLOW}==>${NC} $1"; }

APP_ID=$(cfg '.app.id // empty')
APP_NAME=$(cfg '.app.name')
BUNDLE_ID=$(cfg '.app.bundle_id')
SKU=$(cfg '.app.sku')
PLATFORM=$(cfg '.app.platform')
PRIMARY_LOCALE=$(cfg '.app.primary_locale')

if [[ "$MODE" == "create" ]]; then
  # ── Step 0: Register Bundle ID ─────────────────────────────────────────────

  step "Registering bundle ID: $BUNDLE_ID"

  if BID_ERR=$(asc bundle-ids create \
    --identifier "$BUNDLE_ID" \
    --name "$APP_NAME" \
    --platform "$PLATFORM" \
    --output json 2>&1); then
    log "Bundle ID registered: $BUNDLE_ID"
  else
    warn "Bundle ID already exists or could not be created (continuing): $BID_ERR"
  fi

  # ── Step 1: Create the App ─────────────────────────────────────────────────

  step "Creating app (interactive — Apple ID + 2FA required)..."
  echo "  The CLI will prompt you for Apple ID credentials and a 2FA code."
  echo "  (Sessions are cached, so future runs won't need 2FA again.)"
  echo ""

  # Capture output to extract app ID from create response
  APP_CREATE_OUTPUT=$(asc apps create \
    --name "$APP_NAME" \
    --bundle-id "$BUNDLE_ID" \
    --sku "$SKU" \
    --platform "$PLATFORM" \
    --primary-locale "$PRIMARY_LOCALE" 2>&1) || true
  echo "$APP_CREATE_OUTPUT" | grep -v "Authenticated as"

  # Try to extract app ID directly from the create output
  APP_ID=$(echo "$APP_CREATE_OUTPUT" | grep -o '"id":"[0-9]*"' | head -1 | grep -o '[0-9]*' || true)
else
  step "Update mode — looking up existing app..."
fi

# If we don't have an app ID yet, look it up by bundle ID
if [[ -z "${APP_ID:-}" ]]; then
  echo "Looking up app by bundle ID..."
  CREATE_OUTPUT=$(asc apps list --bundle-id "$BUNDLE_ID" --output json 2>&1)
  APP_ID=$(echo "$CREATE_OUTPUT" | jq -r '.data[0].id // empty' 2>/dev/null || true)
fi

if [[ -z "$APP_ID" ]]; then
  fail "Could not find app with bundle ID: $BUNDLE_ID"
  exit 1
fi

log "App ID: $APP_ID"

# Check if the app has a live version (determines whether whatsNew is applicable)
HAS_LIVE_VERSION=false
LIVE_CHECK=$(asc versions list --app "$APP_ID" --state READY_FOR_SALE --output json 2>&1) || true
LIVE_COUNT=$(echo "$LIVE_CHECK" | jq -r '.data | length // 0' 2>/dev/null || echo "0")
if [[ "$LIVE_COUNT" -gt 0 ]]; then
  HAS_LIVE_VERSION=true
fi

# ── Step 2: Update content rights ────────────────────────────────────────────

CONTENT_RIGHTS=$(cfg '.app.content_rights // empty')
if [[ -n "$CONTENT_RIGHTS" ]]; then
  step "Setting content rights..."
  if ! CR_ERR=$(asc apps update --id "$APP_ID" --content-rights "$CONTENT_RIGHTS" --output json 2>&1); then
    warn "Could not set content rights (may need manual setup): $CR_ERR"
  else
    log "Content rights set to $CONTENT_RIGHTS"
  fi
fi

# ── Step 3: Create App Store Version ─────────────────────────────────────────

VERSION_STRING=$(cfg '.version.version_string')
COPYRIGHT=$(cfg '.version.copyright // empty')
RELEASE_TYPE=$(cfg '.version.release_type // empty')

if [[ "$MODE" == "update" ]]; then
  step "Looking up existing app store version..."
  VER_LIST=$(asc versions list --app "$APP_ID" --version "$VERSION_STRING" --output json 2>&1) || true
  VERSION_ID=$(echo "$VER_LIST" | jq -r '.data[0].id // empty' 2>/dev/null || true)

  if [[ -z "$VERSION_ID" ]]; then
    echo "Version $VERSION_STRING not found, looking up latest editable version..."
    VER_LIST=$(asc versions list --app "$APP_ID" --state PREPARE_FOR_SUBMISSION --output json 2>&1) || true
    VERSION_ID=$(echo "$VER_LIST" | jq -r '.data[0].id // empty' 2>/dev/null || true)
  fi

  if [[ -z "$VERSION_ID" ]]; then
    echo "No editable version found, creating version $VERSION_STRING..."
    VERSION_ARGS=(--app "$APP_ID" --platform "$PLATFORM" --version "$VERSION_STRING" --output json)
    [[ -n "$COPYRIGHT" ]] && VERSION_ARGS+=(--copyright "$COPYRIGHT")
    [[ -n "$RELEASE_TYPE" ]] && VERSION_ARGS+=(--release-type "$RELEASE_TYPE")

    VERSION_OUTPUT=$(asc versions create "${VERSION_ARGS[@]}" 2>&1) || true
    VERSION_ID=$(echo "$VERSION_OUTPUT" | jq -r '.data.id // .id // empty' 2>/dev/null || true)
  fi
else
  step "Creating app store version..."
  VERSION_ARGS=(--app "$APP_ID" --platform "$PLATFORM" --version "$VERSION_STRING" --output json)
  [[ -n "$COPYRIGHT" ]] && VERSION_ARGS+=(--copyright "$COPYRIGHT")
  [[ -n "$RELEASE_TYPE" ]] && VERSION_ARGS+=(--release-type "$RELEASE_TYPE")

  VERSION_OUTPUT=$(asc versions create "${VERSION_ARGS[@]}" 2>&1) || true
  VERSION_ID=$(echo "$VERSION_OUTPUT" | jq -r '.data.id // .id // empty' 2>/dev/null || true)

  if [[ -z "$VERSION_ID" ]]; then
    echo "Trying to look up existing version..."
    VER_LIST=$(asc versions list --app "$APP_ID" --output json 2>&1)
    VERSION_ID=$(echo "$VER_LIST" | jq -r '.data[0].id // empty' 2>/dev/null || true)
  fi
fi

if [[ -n "$VERSION_ID" ]]; then
  log "Version ID: $VERSION_ID"
  VERSION_UPDATE_ARGS=(--version-id "$VERSION_ID" --output json)
  [[ -n "$COPYRIGHT" ]] && VERSION_UPDATE_ARGS+=(--copyright "$COPYRIGHT")
  [[ -n "$RELEASE_TYPE" ]] && VERSION_UPDATE_ARGS+=(--release-type "$RELEASE_TYPE")
  if [[ ${#VERSION_UPDATE_ARGS[@]} -gt 2 ]]; then
    if ! VERSION_UPDATE_ERR=$(asc versions update "${VERSION_UPDATE_ARGS[@]}" 2>&1); then
      warn "Could not update version metadata: $VERSION_UPDATE_ERR"
    else
      log "Version metadata refreshed"
    fi
  fi
else
  warn "Could not create or find version. Some steps may fail."
fi

# ── Step 4: Set categories ───────────────────────────────────────────────────

step "Setting categories..."

# First get the app info ID
APP_INFO_OUTPUT=$(asc app-infos list --app "$APP_ID" --output json 2>&1) || true
APP_INFO_ID=$(echo "$APP_INFO_OUTPUT" | jq -r '.data[0].id // empty' 2>/dev/null || true)

if [[ -n "$APP_INFO_ID" ]]; then
  PRIMARY_CAT=$(cfg '.categories.primary // empty')
  SECONDARY_CAT=$(cfg '.categories.secondary // empty')
  PRIMARY_SUB1=$(cfg '.categories.primary_subcategory_one // empty')
  PRIMARY_SUB2=$(cfg '.categories.primary_subcategory_two // empty')
  SECONDARY_SUB1=$(cfg '.categories.secondary_subcategory_one // empty')
  SECONDARY_SUB2=$(cfg '.categories.secondary_subcategory_two // empty')

  CAT_ARGS=(--app "$APP_ID" --output json)
  [[ -n "$PRIMARY_CAT" ]] && CAT_ARGS+=(--primary "$PRIMARY_CAT")
  [[ -n "$SECONDARY_CAT" ]] && CAT_ARGS+=(--secondary "$SECONDARY_CAT")
  [[ -n "$PRIMARY_SUB1" ]] && CAT_ARGS+=(--primary-subcategory-one "$PRIMARY_SUB1")
  [[ -n "$PRIMARY_SUB2" ]] && CAT_ARGS+=(--primary-subcategory-two "$PRIMARY_SUB2")
  [[ -n "$SECONDARY_SUB1" ]] && CAT_ARGS+=(--secondary-subcategory-one "$SECONDARY_SUB1")
  [[ -n "$SECONDARY_SUB2" ]] && CAT_ARGS+=(--secondary-subcategory-two "$SECONDARY_SUB2")

  if ! CAT_ERR=$(asc categories set "${CAT_ARGS[@]}" 2>&1); then
    warn "Could not set categories (check category IDs with: asc categories list): $CAT_ERR"
  else
    log "Categories set"
  fi
else
  warn "Could not find app info ID for categories"
fi

# ── Step 5: Set age rating ───────────────────────────────────────────────────

step "Setting age rating..."

AGE_ARGS=(--app "$APP_ID" --output json)

# Enum fields — config key → CLI flag (flags verified via `asc age-rating --help`)
# Using a function to map config keys to CLI flags (avoids bash associative array issues)
age_rating_flag() {
  case "$1" in
    alcohol_tobacco_or_drug_use_or_references) echo "--alcohol-tobacco-drug-use" ;;
    contests)                                  echo "--contests" ;;
    gambling_simulated)                        echo "--gambling-simulated" ;;
    guns_or_other_weapons)                     echo "--guns-or-other-weapons" ;;
    medical_or_treatment_information)           echo "--medical-treatment" ;;
    profanity_or_crude_humor)                  echo "--profanity-humor" ;;
    sexual_content_graphic_and_nudity)         echo "--sexual-content-graphic-nudity" ;;
    sexual_content_or_nudity)                  echo "--sexual-content-nudity" ;;
    horror_or_fear_themes)                     echo "--horror-fear" ;;
    mature_or_suggestive_themes)               echo "--mature-suggestive" ;;
    violence_cartoon_or_fantasy)               echo "--violence-cartoon" ;;
    violence_realistic)                        echo "--violence-realistic" ;;
    violence_realistic_prolonged_graphic_or_sadistic) echo "--violence-realistic-graphic" ;;
  esac
}

for field in \
  alcohol_tobacco_or_drug_use_or_references \
  contests \
  gambling_simulated \
  guns_or_other_weapons \
  medical_or_treatment_information \
  profanity_or_crude_humor \
  sexual_content_graphic_and_nudity \
  sexual_content_or_nudity \
  horror_or_fear_themes \
  mature_or_suggestive_themes \
  violence_cartoon_or_fantasy \
  violence_realistic \
  violence_realistic_prolonged_graphic_or_sadistic; do
  val=$(cfg ".age_rating.${field} // empty")
  if [[ -n "$val" ]]; then
    AGE_ARGS+=("$(age_rating_flag "$field")" "$val")
  fi
done

# Boolean fields — pass true/false as values
# Note: jq's // operator treats false as empty, so we use tostring and check for null
for field in advertising age_assurance gambling health_or_wellness_topics loot_box messaging_and_chat parental_controls unrestricted_web_access user_generated_content; do
  val=$(jq -r "if .age_rating.${field} != null then .age_rating.${field} | tostring else \"_null_\" end" "$CONFIG")
  if [[ "$val" != "_null_" ]]; then
    flag_name=$(echo "$field" | tr '_' '-')
    AGE_ARGS+=("--${flag_name}" "$val")
  fi
done

if ! AGE_ERR=$(asc age-rating set "${AGE_ARGS[@]}" 2>&1); then
  warn "Could not set age rating (check: asc age-rating --help): $AGE_ERR"
else
  log "Age rating configured"
fi

# ── Step 6: Set localizations (description, keywords, etc.) ─────────────────

step "Setting localizations..."

LOC_COUNT=$(jq '.localizations | length' "$CONFIG")
for ((i=0; i<LOC_COUNT; i++)); do
  LOCALE=$(cfg ".localizations[$i].locale")
  SUBTITLE=$(cfg ".localizations[$i].subtitle // empty")
  DESC=$(cfg ".localizations[$i].description // empty")
  KEYWORDS=$(cfg ".localizations[$i].keywords // empty")
  WHATS_NEW=$(cfg ".localizations[$i].whats_new // empty")
  PROMO_TEXT=$(cfg ".localizations[$i].promotional_text // empty")
  SUPPORT_URL=$(cfg ".localizations[$i].support_url // empty")
  MARKETING_URL=$(cfg ".localizations[$i].marketing_url // empty")
  PRIVACY_URL=$(cfg ".localizations[$i].privacy_policy_url // empty")

  echo "  Setting localization for $LOCALE..."

  # Update version localization (description, keywords, whats-new, etc.)
  if [[ -n "$VERSION_ID" ]]; then
    LOC_ARGS=(--version "$VERSION_ID" --locale "$LOCALE" --output json)
    [[ -n "$DESC" ]] && LOC_ARGS+=(--description "$DESC")
    [[ -n "$KEYWORDS" ]] && LOC_ARGS+=(--keywords "$KEYWORDS")
    [[ "$HAS_LIVE_VERSION" == "true" && -n "$WHATS_NEW" ]] && LOC_ARGS+=(--whats-new "$WHATS_NEW")
    [[ -n "$PROMO_TEXT" ]] && LOC_ARGS+=(--promotional-text "$PROMO_TEXT")
    [[ -n "$SUPPORT_URL" ]] && LOC_ARGS+=(--support-url "$SUPPORT_URL")
    [[ -n "$MARKETING_URL" ]] && LOC_ARGS+=(--marketing-url "$MARKETING_URL")

    if ! LOC_ERR=$(asc localizations update "${LOC_ARGS[@]}" 2>&1); then
      warn "Could not set version localization for $LOCALE: $LOC_ERR"
    fi
  fi

  # Update app-info localization (subtitle, privacy policy URL, etc.)
  if [[ -n "$APP_INFO_ID" && ( -n "$SUBTITLE" || -n "$PRIVACY_URL" ) ]]; then
    INFO_ARGS=(--app "$APP_ID" --type app-info --locale "$LOCALE" --output json)
    [[ -n "$SUBTITLE" ]] && INFO_ARGS+=(--subtitle "$SUBTITLE")
    [[ -n "$PRIVACY_URL" ]] && INFO_ARGS+=(--privacy-policy-url "$PRIVACY_URL")

    if ! INFO_ERR=$(asc localizations update "${INFO_ARGS[@]}" 2>&1); then
      warn "Could not set app-info localization for $LOCALE: $INFO_ERR"
    fi
  fi

  log "Localization for $LOCALE done"
done

# ── Step 6b: Set app privacy declarations ───────────────────────────────────

PRIVACY_ENABLED=$(jq -r '
  if .privacy.enabled != null then
    .privacy.enabled | tostring
  elif .privacy.data_usages != null then
    "true"
  else
    "false"
  end
' "$CONFIG")

if [[ "$PRIVACY_ENABLED" == "true" ]]; then
  step "Setting app privacy..."

  PRIVACY_USAGE_COUNT=$(jq '.privacy.data_usages | length // 0' "$CONFIG")
  if [[ "$PRIVACY_USAGE_COUNT" -eq 0 ]]; then
    warn "Privacy enabled but privacy.data_usages is empty"
  else
    PRIVACY_APPLE_ID=$(cfg '.privacy.apple_id // empty')
    PRIVACY_TWO_FACTOR=$(cfg '.privacy.two_factor_code // empty')
    PRIVACY_PUBLISH=$(jq -r 'if .privacy.publish != null then .privacy.publish | tostring else "true" end' "$CONFIG")
    PRIVACY_ALLOW_DELETES=$(jq -r 'if .privacy.allow_deletes != null then .privacy.allow_deletes | tostring else "true" end' "$CONFIG")
    PRIVACY_FILE=$(mktemp "${TMPDIR:-/tmp}/asc-privacy.XXXXXX")

    jq '{
      schemaVersion: 1,
      dataUsages: (.privacy.data_usages // [])
    }' "$CONFIG" > "$PRIVACY_FILE"

    WEB_STATUS_ARGS=()
    WEB_LOGIN_ARGS=()
    WEB_PRIVACY_ARGS=()

    if [[ -n "$PRIVACY_APPLE_ID" ]]; then
      WEB_STATUS_ARGS+=(--apple-id "$PRIVACY_APPLE_ID")
      WEB_LOGIN_ARGS+=(--apple-id "$PRIVACY_APPLE_ID")
      WEB_PRIVACY_ARGS+=(--apple-id "$PRIVACY_APPLE_ID")
    fi
    if [[ -n "$PRIVACY_TWO_FACTOR" ]]; then
      WEB_LOGIN_ARGS+=(--two-factor-code "$PRIVACY_TWO_FACTOR")
      WEB_PRIVACY_ARGS+=(--two-factor-code "$PRIVACY_TWO_FACTOR")
    fi

    PRIVACY_READY=true
    if [[ ${#WEB_STATUS_ARGS[@]} -gt 0 ]]; then
      WEB_STATUS_OK=true
      if ! asc web auth status "${WEB_STATUS_ARGS[@]}" --output json >/dev/null 2>&1; then
        WEB_STATUS_OK=false
      fi
    else
      WEB_STATUS_OK=true
      if ! asc web auth status --output json >/dev/null 2>&1; then
        WEB_STATUS_OK=false
      fi
    fi

    if [[ "$WEB_STATUS_OK" != "true" ]]; then
      if [[ -z "$PRIVACY_APPLE_ID" ]]; then
        warn "No cached asc web auth session found for App Privacy. Set privacy.apple_id or run: asc web auth login --apple-id YOUR_APPLE_ID"
        PRIVACY_READY=false
      else
        echo "  Authenticating asc web session for App Privacy..."
        if ! WEB_LOGIN_ERR=$(asc web auth login "${WEB_LOGIN_ARGS[@]}" --output json 2>&1); then
          warn "Could not authenticate asc web session for App Privacy: $WEB_LOGIN_ERR"
          PRIVACY_READY=false
        else
          log "App Privacy web session authenticated"
        fi
      fi
    fi

    if [[ "$PRIVACY_READY" == "true" ]]; then
      PRIVACY_PLAN_ARGS=(--app "$APP_ID" --file "$PRIVACY_FILE" --output json)
      if [[ ${#WEB_PRIVACY_ARGS[@]} -gt 0 ]]; then
        PRIVACY_PLAN_CMD=(asc web privacy plan "${PRIVACY_PLAN_ARGS[@]}" "${WEB_PRIVACY_ARGS[@]}")
      else
        PRIVACY_PLAN_CMD=(asc web privacy plan "${PRIVACY_PLAN_ARGS[@]}")
      fi

      if ! PRIVACY_PLAN_OUTPUT=$("${PRIVACY_PLAN_CMD[@]}" 2>&1); then
        warn "Could not plan App Privacy changes (check: asc web privacy plan --help): $PRIVACY_PLAN_OUTPUT"
      else
        PLAN_ADDS=$(echo "$PRIVACY_PLAN_OUTPUT" | jq -r '.adds | length // 0' 2>/dev/null || echo "0")
        PLAN_UPDATES=$(echo "$PRIVACY_PLAN_OUTPUT" | jq -r '.updates | length // 0' 2>/dev/null || echo "0")
        PLAN_DELETES=$(echo "$PRIVACY_PLAN_OUTPUT" | jq -r '.deletes | length // 0' 2>/dev/null || echo "0")
        log "App Privacy plan ready (adds: $PLAN_ADDS, updates: $PLAN_UPDATES, deletes: $PLAN_DELETES)"

        PRIVACY_APPLY_ARGS=(--app "$APP_ID" --file "$PRIVACY_FILE" --output json)
        if [[ "$PRIVACY_ALLOW_DELETES" == "true" ]]; then
          PRIVACY_APPLY_ARGS+=(--allow-deletes --confirm)
        fi

        if [[ ${#WEB_PRIVACY_ARGS[@]} -gt 0 ]]; then
          PRIVACY_APPLY_CMD=(asc web privacy apply "${PRIVACY_APPLY_ARGS[@]}" "${WEB_PRIVACY_ARGS[@]}")
        else
          PRIVACY_APPLY_CMD=(asc web privacy apply "${PRIVACY_APPLY_ARGS[@]}")
        fi

        if ! PRIVACY_APPLY_ERR=$("${PRIVACY_APPLY_CMD[@]}" 2>&1); then
          warn "Could not apply App Privacy changes (check: asc web privacy apply --help): $PRIVACY_APPLY_ERR"
        else
          log "App Privacy declarations applied"

          if [[ "$PRIVACY_PUBLISH" == "true" ]]; then
            PRIVACY_PUBLISH_ARGS=(--app "$APP_ID" --confirm --output json)
            if [[ ${#WEB_PRIVACY_ARGS[@]} -gt 0 ]]; then
              PRIVACY_PUBLISH_CMD=(asc web privacy publish "${PRIVACY_PUBLISH_ARGS[@]}" "${WEB_PRIVACY_ARGS[@]}")
            else
              PRIVACY_PUBLISH_CMD=(asc web privacy publish "${PRIVACY_PUBLISH_ARGS[@]}")
            fi

            if ! PRIVACY_PUBLISH_ERR=$("${PRIVACY_PUBLISH_CMD[@]}" 2>&1); then
              warn "Could not publish App Privacy declarations (check: asc web privacy publish --help): $PRIVACY_PUBLISH_ERR"
            else
              log "App Privacy declarations published"
            fi
          else
            warn "App Privacy changes applied but not published (privacy.publish=false)"
          fi
        fi
      fi
    fi

    rm -f "$PRIVACY_FILE"
  fi
fi

# ── Step 7: Set pricing ──────────────────────────────────────────────────────

step "Setting pricing..."

BASE_TERRITORY=$(cfg '.pricing.base_territory // empty')
PRICE_TIER=$(cfg '.pricing.price_tier // empty')
PRICE_TIER=${PRICE_TIER:-0}
START_DATE=$(date -u +"%Y-%m-%d")

PRICE_ARGS=(--app "$APP_ID" --base-territory "$BASE_TERRITORY" --tier "$PRICE_TIER" --start-date "$START_DATE" --output json)
if ! PRICE_ERR=$(asc pricing schedule create "${PRICE_ARGS[@]}" 2>&1); then
  warn "Could not set pricing schedule (check: asc pricing schedule create --help): $PRICE_ERR"
else
  log "Pricing set (tier: $PRICE_TIER)"
fi

# Set availability
AVAIL_NEW=$(cfg '.pricing.availability.available_in_new_territories')
TERRITORY_COUNT=$(jq '.pricing.availability.territories | length' "$CONFIG")
  AVAIL_ARGS=(--app "$APP_ID" --available true --available-in-new-territories "$AVAIL_NEW" --output json)
  if [[ "$TERRITORY_COUNT" -gt 0 ]]; then
    TERRITORIES=$(jq -r '.pricing.availability.territories | join(",")' "$CONFIG")
    AVAIL_ARGS+=(--territory "$TERRITORIES")
  fi

if ! AVAIL_ERR=$(asc pricing availability set "${AVAIL_ARGS[@]}" 2>&1); then
  warn "Could not set availability: $AVAIL_ERR"
else
  log "Availability configured"
fi

# ── Step 8: Create subscription groups & subscriptions ───────────────────────

step "Setting up subscriptions..."

SUB_GROUP_COUNT=$(jq '.subscriptions.groups | length' "$CONFIG")
for ((g=0; g<SUB_GROUP_COUNT; g++)); do
  GROUP_REF=$(cfg ".subscriptions.groups[$g].reference_name")
  echo "  Creating subscription group: $GROUP_REF"

  # Try to find existing group first (for update mode or idempotency)
  GROUPS_LIST=$(asc subscriptions groups list --app "$APP_ID" --output json 2>&1) || true
  GROUP_ID=$(echo "$GROUPS_LIST" | jq -r --arg ref "$GROUP_REF" '.data[] | select(.attributes.referenceName == $ref) | .id // empty' 2>/dev/null || true)

  if [[ -z "$GROUP_ID" ]]; then
    echo "    Group not found, creating..."
    GROUP_OUTPUT=$(asc subscriptions groups create \
      --app "$APP_ID" \
      --reference-name "$GROUP_REF" \
      --output json 2>&1) || true
    GROUP_ID=$(echo "$GROUP_OUTPUT" | jq -r '.data.id // .id // empty' 2>/dev/null || true)
  fi

  if [[ -z "$GROUP_ID" ]]; then
    fail "Could not create or find subscription group: $GROUP_REF"
    continue
  fi

  log "Subscription group '$GROUP_REF' ID: $GROUP_ID"

  # Group localizations
  GROUP_LOC_LIST=$(asc subscriptions groups localizations list --group-id "$GROUP_ID" --output json 2>&1) || true
  GLOC_COUNT=$(jq ".subscriptions.groups[$g].localizations | length" "$CONFIG")
  for ((gl=0; gl<GLOC_COUNT; gl++)); do
    GLOC_LOCALE=$(cfg ".subscriptions.groups[$g].localizations[$gl].locale")
    GLOC_NAME=$(cfg ".subscriptions.groups[$g].localizations[$gl].name")
    GLOC_APP_NAME=$(cfg ".subscriptions.groups[$g].localizations[$gl].custom_app_name // empty")

    GROUP_LOC_ID=$(echo "$GROUP_LOC_LIST" | jq -r --arg locale "$GLOC_LOCALE" '.data[] | select(.attributes.locale == $locale) | .id // empty' 2>/dev/null | head -1 || true)

    if [[ -n "$GROUP_LOC_ID" ]]; then
      GLOC_ARGS=(--id "$GROUP_LOC_ID" --name "$GLOC_NAME" --output json)
      [[ -n "$GLOC_APP_NAME" ]] && GLOC_ARGS+=(--custom-app-name "$GLOC_APP_NAME")

      if ! GLOC_ERR=$(asc subscriptions groups localizations update "${GLOC_ARGS[@]}" 2>&1); then
        warn "Could not update group localization for $GLOC_LOCALE: $GLOC_ERR"
      fi
    else
      GLOC_ARGS=(--group-id "$GROUP_ID" --locale "$GLOC_LOCALE" --name "$GLOC_NAME" --output json)
      [[ -n "$GLOC_APP_NAME" ]] && GLOC_ARGS+=(--custom-app-name "$GLOC_APP_NAME")

      if ! GLOC_ERR=$(asc subscriptions groups localizations create "${GLOC_ARGS[@]}" 2>&1); then
        warn "Could not create group localization for $GLOC_LOCALE: $GLOC_ERR"
      fi
    fi
  done

  # Create subscriptions in the group
  SUBS_LIST=$(asc subscriptions list --group "$GROUP_ID" --output json 2>&1) || true
  SUB_COUNT=$(jq ".subscriptions.groups[$g].subscriptions | length" "$CONFIG")
  for ((s=0; s<SUB_COUNT; s++)); do
    SUB_REF=$(cfg ".subscriptions.groups[$g].subscriptions[$s].ref_name")
    SUB_PRODUCT=$(cfg ".subscriptions.groups[$g].subscriptions[$s].product_id")
    SUB_PERIOD=$(cfg ".subscriptions.groups[$g].subscriptions[$s].subscription_period")
    SUB_FAMILY=$(cfg ".subscriptions.groups[$g].subscriptions[$s].family_sharable")

    echo "    Creating subscription: $SUB_REF ($SUB_PRODUCT)"

    if [[ "$SUB_PRODUCT" == *"<TODO>"* ]]; then
      fail "Subscription product ID contains <TODO>: $SUB_PRODUCT — update config before running"
      continue
    fi

    SUB_ID=$(echo "$SUBS_LIST" | jq -r --arg product "$SUB_PRODUCT" --arg ref "$SUB_REF" '
      .data[]
      | select(.attributes.productId == $product or .attributes.referenceName == $ref)
      | .id // empty
    ' 2>/dev/null | head -1 || true)

    if [[ -n "$SUB_ID" ]]; then
      SUB_ARGS=(--id "$SUB_ID" --ref-name "$SUB_REF" --subscription-period "$SUB_PERIOD" --output json)
      [[ "$SUB_FAMILY" == "true" ]] && SUB_ARGS+=(--family-sharable)

      if ! SUB_ERR=$(asc subscriptions update "${SUB_ARGS[@]}" 2>&1); then
        warn "Could not update subscription '$SUB_REF': $SUB_ERR"
        continue
      fi
    else
      SUB_ARGS=(--group "$GROUP_ID" --ref-name "$SUB_REF" --product-id "$SUB_PRODUCT" --subscription-period "$SUB_PERIOD" --output json)
      [[ "$SUB_FAMILY" == "true" ]] && SUB_ARGS+=(--family-sharable)

      SUB_OUTPUT=$(asc subscriptions create "${SUB_ARGS[@]}" 2>&1) || true
      SUB_ID=$(echo "$SUB_OUTPUT" | jq -r '.data.id // .id // empty' 2>/dev/null || true)

      if [[ -z "$SUB_ID" ]]; then
        warn "Could not create subscription '$SUB_REF': $SUB_OUTPUT"
        continue
      fi
    fi

    log "Subscription '$SUB_REF' ID: $SUB_ID"
    SUB_AVAIL_ARGS=(--id "$SUB_ID" --available-in-new-territories true --output json)
    if [[ -n "${TERRITORIES:-}" ]]; then
      SUB_AVAIL_ARGS+=(--territory "$TERRITORIES")
    fi
    if ! SUB_AVAIL_ERR=$(asc subscriptions availability set "${SUB_AVAIL_ARGS[@]}" 2>&1); then
      warn "Could not set subscription availability for '$SUB_REF': $SUB_AVAIL_ERR"
    fi

    # Subscription prices
    SPRICE_COUNT=$(jq ".subscriptions.groups[$g].subscriptions[$s].prices | length" "$CONFIG")
    for ((sp=0; sp<SPRICE_COUNT; sp++)); do
      SP_TERRITORY=$(cfg ".subscriptions.groups[$g].subscriptions[$s].prices[$sp].territory")
      SP_TIER=$(cfg ".subscriptions.groups[$g].subscriptions[$s].prices[$sp].tier")

      if ! SP_ERR=$(asc subscriptions prices add \
        --id "$SUB_ID" \
        --app "$APP_ID" \
        --territory "$SP_TERRITORY" \
        --tier "$SP_TIER" \
        --output json 2>&1); then
        warn "  Could not set price for $SP_TERRITORY: $SP_ERR"
      else
        log "  Price set for $SP_TERRITORY (tier $SP_TIER)"
      fi
    done

    # Subscription localizations
    SUB_LOC_LIST=$(asc subscriptions localizations list --subscription-id "$SUB_ID" --output json 2>&1) || true
    SLOC_COUNT=$(jq ".subscriptions.groups[$g].subscriptions[$s].localizations | length" "$CONFIG")
    for ((sl=0; sl<SLOC_COUNT; sl++)); do
      SL_LOCALE=$(cfg ".subscriptions.groups[$g].subscriptions[$s].localizations[$sl].locale")
      SL_NAME=$(cfg ".subscriptions.groups[$g].subscriptions[$s].localizations[$sl].name")
      SL_DESC=$(cfg ".subscriptions.groups[$g].subscriptions[$s].localizations[$sl].description // empty")

      SUB_LOC_ID=$(echo "$SUB_LOC_LIST" | jq -r --arg locale "$SL_LOCALE" '.data[] | select(.attributes.locale == $locale) | .id // empty' 2>/dev/null | head -1 || true)

      if [[ -n "$SUB_LOC_ID" ]]; then
        SLOC_ARGS=(--id "$SUB_LOC_ID" --name "$SL_NAME" --output json)
        [[ -n "$SL_DESC" ]] && SLOC_ARGS+=(--description "$SL_DESC")

        if ! SLOC_ERR=$(asc subscriptions localizations update "${SLOC_ARGS[@]}" 2>&1); then
          warn "  Could not update subscription localization for $SL_LOCALE: $SLOC_ERR"
        fi
      else
        SLOC_ARGS=(--subscription-id "$SUB_ID" --locale "$SL_LOCALE" --name "$SL_NAME" --output json)
        [[ -n "$SL_DESC" ]] && SLOC_ARGS+=(--description "$SL_DESC")

        if ! SLOC_ERR=$(asc subscriptions localizations create "${SLOC_ARGS[@]}" 2>&1); then
          warn "  Could not create subscription localization for $SL_LOCALE: $SLOC_ERR"
        fi
      fi
    done
  done
done

# ── Step 9: Create in-app purchases ─────────────────────────────────────────

step "Setting up in-app purchases..."

IAP_LIST=$(asc iap list --app "$APP_ID" --output json 2>&1) || true
IAP_COUNT=$(jq '.in_app_purchases | length' "$CONFIG")
for ((i=0; i<IAP_COUNT; i++)); do
  IAP_TYPE=$(cfg ".in_app_purchases[$i].type")
  IAP_REF=$(cfg ".in_app_purchases[$i].ref_name")
  IAP_PRODUCT=$(cfg ".in_app_purchases[$i].product_id")
  IAP_FAMILY=$(cfg ".in_app_purchases[$i].family_sharable")

  echo "  Creating IAP: $IAP_REF ($IAP_PRODUCT)"

  IAP_ID=$(echo "$IAP_LIST" | jq -r --arg product "$IAP_PRODUCT" --arg ref "$IAP_REF" '
    .data[]
    | select(.attributes.productId == $product or .attributes.referenceName == $ref)
    | .id // empty
  ' 2>/dev/null | head -1 || true)

  if [[ -n "$IAP_ID" ]]; then
    IAP_ARGS=(--id "$IAP_ID" --ref-name "$IAP_REF" --output json)
    [[ "$IAP_FAMILY" == "true" ]] && IAP_ARGS+=(--family-sharable)

    if ! IAP_ERR=$(asc iap update "${IAP_ARGS[@]}" 2>&1); then
      warn "Could not update IAP '$IAP_REF': $IAP_ERR"
      continue
    fi
  else
    IAP_ARGS=(--app "$APP_ID" --type "$IAP_TYPE" --ref-name "$IAP_REF" --product-id "$IAP_PRODUCT" --output json)
    [[ "$IAP_FAMILY" == "true" ]] && IAP_ARGS+=(--family-sharable)

    IAP_OUTPUT=$(asc iap create "${IAP_ARGS[@]}" 2>&1) || true
    IAP_ID=$(echo "$IAP_OUTPUT" | jq -r '.data.id // .id // empty' 2>/dev/null || true)

    if [[ -z "$IAP_ID" ]]; then
      warn "Could not create IAP '$IAP_REF': $IAP_OUTPUT"
      continue
    fi
  fi

  log "IAP '$IAP_REF' ID: $IAP_ID"

  # IAP price schedule
  IPRICE_COUNT=$(jq ".in_app_purchases[$i].prices | length" "$CONFIG")
  if [[ "$IPRICE_COUNT" -gt 0 ]]; then
    IP_TERRITORY=$(cfg ".in_app_purchases[$i].prices[0].territory")
    IP_TIER=$(cfg ".in_app_purchases[$i].prices[0].tier")
    IP_START=$(date -u +"%Y-%m-%d")

    if ! IP_ERR=$(asc iap price-schedules create \
      --iap-id "$IAP_ID" \
      --base-territory "$IP_TERRITORY" \
      --tier "$IP_TIER" \
      --start-date "$IP_START" \
      --output json 2>&1); then
      warn "  Could not set price schedule for $IP_TERRITORY: $IP_ERR"
    else
      log "  Price schedule set for $IP_TERRITORY (tier $IP_TIER)"
    fi
  fi

  # IAP localizations
  IAP_LOC_LIST=$(asc iap localizations list --iap-id "$IAP_ID" --output json 2>&1) || true
  ILOC_COUNT=$(jq ".in_app_purchases[$i].localizations | length" "$CONFIG")
  for ((l=0; l<ILOC_COUNT; l++)); do
    IL_LOCALE=$(cfg ".in_app_purchases[$i].localizations[$l].locale")
    IL_NAME=$(cfg ".in_app_purchases[$i].localizations[$l].name")
    IL_DESC=$(cfg ".in_app_purchases[$i].localizations[$l].description // empty")

    IAP_LOC_ID=$(echo "$IAP_LOC_LIST" | jq -r --arg locale "$IL_LOCALE" '.data[] | select(.attributes.locale == $locale) | .id // empty' 2>/dev/null | head -1 || true)

    if [[ -n "$IAP_LOC_ID" ]]; then
      ILOC_ARGS=(--localization-id "$IAP_LOC_ID" --name "$IL_NAME" --output json)
      [[ -n "$IL_DESC" ]] && ILOC_ARGS+=(--description "$IL_DESC")

      if ! ILOC_ERR=$(asc iap localizations update "${ILOC_ARGS[@]}" 2>&1); then
        warn "  Could not update IAP localization for $IL_LOCALE: $ILOC_ERR"
      fi
    else
      ILOC_ARGS=(--iap-id "$IAP_ID" --locale "$IL_LOCALE" --name "$IL_NAME" --output json)
      [[ -n "$IL_DESC" ]] && ILOC_ARGS+=(--description "$IL_DESC")

      if ! ILOC_ERR=$(asc iap localizations create "${ILOC_ARGS[@]}" 2>&1); then
        warn "  Could not create IAP localization for $IL_LOCALE: $ILOC_ERR"
      fi
    fi
  done
done

# ── Step 10: Set encryption declaration ──────────────────────────────────────

step "Setting encryption declaration..."

PROP_CRYPTO=$(cfg '.encryption.contains_proprietary_cryptography')
THIRD_CRYPTO=$(cfg '.encryption.contains_third_party_cryptography')
FRENCH_STORE=$(cfg '.encryption.available_on_french_store')
ENC_DESC=$(cfg '.encryption.description // "This app does not use encryption."')

if [[ "$PROP_CRYPTO" == "false" && "$THIRD_CRYPTO" == "false" ]]; then
  log "Encryption: app does not use encryption (no declaration needed)"
else
  ENC_ARGS=(--app "$APP_ID" --app-description "$ENC_DESC")
  ENC_ARGS+=(--contains-proprietary-cryptography="$PROP_CRYPTO")
  ENC_ARGS+=(--contains-third-party-cryptography="$THIRD_CRYPTO")
  ENC_ARGS+=(--available-on-french-store="$FRENCH_STORE")
  ENC_ARGS+=(--output json)

  if ! ENC_ERR=$(asc encryption declarations create "${ENC_ARGS[@]}" 2>&1); then
    warn "Could not set encryption (check: asc encryption declarations --help): $ENC_ERR"
  else
    log "Encryption declaration set"
  fi
fi

# ── Step 11: Set review details ───────────────────────────────────────────────

if [[ -n "${VERSION_ID:-}" ]]; then
  REVIEW_EMAIL=$(cfg '.review_info.contact_email // empty')
  if [[ -n "$REVIEW_EMAIL" ]]; then
    step "Setting review details..."

    REVIEW_FIRST=$(cfg '.review_info.contact_first_name // empty')
    REVIEW_LAST=$(cfg '.review_info.contact_last_name // empty')
    REVIEW_PHONE=$(cfg '.review_info.contact_phone // empty')
    REVIEW_USER=$(cfg '.review_info.demo_username // empty')
    REVIEW_PASS=$(cfg '.review_info.demo_password // empty')
    REVIEW_NOTES=$(cfg '.review_info.notes // empty')

    REVIEW_FIELDS=(--contact-email "$REVIEW_EMAIL")
    [[ -n "$REVIEW_FIRST" ]] && REVIEW_FIELDS+=(--contact-first-name "$REVIEW_FIRST")
    [[ -n "$REVIEW_LAST" ]] && REVIEW_FIELDS+=(--contact-last-name "$REVIEW_LAST")
    [[ -n "$REVIEW_PHONE" ]] && REVIEW_FIELDS+=(--contact-phone "$REVIEW_PHONE")
    if [[ -n "$REVIEW_USER" && -n "$REVIEW_PASS" ]]; then
      REVIEW_FIELDS+=(--demo-account-name "$REVIEW_USER" --demo-account-password "$REVIEW_PASS" --demo-account-required true)
    else
      REVIEW_FIELDS+=(--demo-account-required false)
    fi
    [[ -n "$REVIEW_NOTES" ]] && REVIEW_FIELDS+=(--notes "$REVIEW_NOTES")

    if [[ "$MODE" == "update" ]]; then
      # Look up existing review detail for this version
      DETAIL_OUTPUT=$(asc review details-for-version --version-id "$VERSION_ID" --output json 2>&1) || true
      DETAIL_ID=$(echo "$DETAIL_OUTPUT" | jq -r '.data.id // empty' 2>/dev/null || true)

      if [[ -n "$DETAIL_ID" ]]; then
        if ! REV_ERR=$(asc review details-update --id "$DETAIL_ID" "${REVIEW_FIELDS[@]}" --output json 2>&1); then
          warn "Could not update review details: $REV_ERR"
        else
          log "Review details updated"
        fi
      else
        # No existing detail — create one
        if ! REV_ERR=$(asc review details-create --version-id "$VERSION_ID" "${REVIEW_FIELDS[@]}" --output json 2>&1); then
          warn "Could not create review details: $REV_ERR"
        else
          log "Review details created"
        fi
      fi
    else
      if ! REV_ERR=$(asc review details-create --version-id "$VERSION_ID" "${REVIEW_FIELDS[@]}" --output json 2>&1); then
        warn "Could not set review details: $REV_ERR"
      else
        log "Review details set"
      fi
    fi
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "============================================"
if [[ "$MODE" == "update" ]]; then
  echo "  App update complete!"
else
  echo "  App setup complete!"
fi
echo "============================================"
echo "  App Name:    $APP_NAME"
echo "  Bundle ID:   $BUNDLE_ID"
echo "  App ID:      $APP_ID"
[[ -n "${VERSION_ID:-}" ]] && echo "  Version ID:  $VERSION_ID"
echo "  Version:     $VERSION_STRING"
echo ""
echo "  Remaining manual steps:"
echo "    - Upload screenshots (asc screenshots upload)"
echo "    - Upload app build via Xcode or Transporter"
echo "    - Submit for review (asc submit)"
echo "============================================"
