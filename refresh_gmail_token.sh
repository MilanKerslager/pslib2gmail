#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Načteme konfiguraci
source "$SCRIPT_DIR/config"

# ------------------------------------------------------------
# Kontrola závislostí
# ------------------------------------------------------------

for cmd in curl jq date; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Program '$cmd' nebyl nalezen." >&2
        exit 1
    fi
done


# ------------------------------------------------------------
# Kontrola token souboru
# ------------------------------------------------------------

if [[ ! -f "$GMAIL_TOKEN_FILE" ]]; then
    echo "ERROR: Access token soubor neexistuje: $GMAIL_TOKEN_FILE" >&2
    exit 1
fi

ACCESS_TOKEN="$(jq -r '.access_token // empty' "$GMAIL_TOKEN_FILE")"

if [[ -z "$ACCESS_TOKEN" ]]; then
    echo "ERROR: V token souboru $GMAIL_TOKEN_FILE není access_token." >&2
    exit 1
fi

REFRESH_TOKEN="$(jq -r '.refresh_token // empty' "$GMAIL_TOKEN_FILE")"

if [[ -z "$REFRESH_TOKEN" ]]; then
    echo "ERROR: V token souboru $GMAIL_TOKEN_FILE není refresh_token." >&2
    exit 1
fi


# ----------------------------------------------------------------------
# Return cached access token if it is still valid.
#
# Keep a 60 second safety margin.
# ----------------------------------------------------------------------

NOW=$(date +%s)

EXPIRES_AT=$(jq -r '.expires_at // 0' "$GMAIL_TOKEN_FILE")

if [[ -n "$ACCESS_TOKEN" &&
      "$EXPIRES_AT" =~ ^[0-9]+$ &&
      "$EXPIRES_AT" -gt $((NOW + TOKEN_REFRESH_MARGIN)) ]]; then

	REMAINING=$((EXPIRES_AT - NOW))

    echo "GMail access token je stále platný (${REMAINING} sec)."
    exit 0
fi

echo "GMail access token je potřeba obnovit..."

# ----------------------------------------------------------------------
# Access token is missing or expired.
# Get a new one using the refresh token.
# ----------------------------------------------------------------------

RESPONSE=$(curl --fail-with-body -sS \
    -X POST "$GMAIL_TOKEN_URL" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "client_id=${GMAIL_CLIENT_ID}" \
    --data-urlencode "client_secret=${GMAIL_CLIENT_SECRET}" \
    --data-urlencode "refresh_token=${REFRESH_TOKEN}" \
    --data-urlencode 'grant_type=refresh_token'
)

echo -n "Response: "
jq . <<< $RESPONSE

# ----------------------------------------------------------------------
# Validate response
# ----------------------------------------------------------------------

ACCESS_TOKEN=$(jq -r '.access_token // empty' <<< "$RESPONSE")

if [[ -z "$ACCESS_TOKEN" ]]; then
    echo "ERROR: Google did not return an access_token." >&2
    echo "$RESPONSE" | jq . >&2 || echo "$RESPONSE" >&2
    exit 1
fi

EXPIRES_IN=$(jq -r '.expires_in // 3600' <<< "$RESPONSE")

if ! [[ "$EXPIRES_IN" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid expires_in returned by Google." >&2
    exit 1
fi
EXPIRES_AT=$(( $(date +%s) + EXPIRES_IN ))

REFRESH_IN=$(jq -r '.refresh_token_expires_in // 0' <<< "$RESPONSE")

if ! [[ "$REFRESH_IN" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid refresh_token_expires_in returned by Google." >&2
    exit 1
fi
REFRESH_AT=$(( $(date +%s) + REFRESH_IN ))


# ----------------------------------------------------------------------
# Google normally does NOT return a new refresh token here.
# If it does, save it for future use.
# ----------------------------------------------------------------------

NEW_REFRESH_TOKEN=$(jq -r '.refresh_token // empty' <<< "$RESPONSE")

if [[ -n "$NEW_REFRESH_TOKEN" ]]; then
    REFRESH_TOKEN="$NEW_REFRESH_TOKEN"
    echo "GMail refresh token úspěšně obnoven."
fi


# ----------------------------------------------------------------------
# Save access token and expiration.
# ----------------------------------------------------------------------

TMP_FILE="${GMAIL_TOKEN_FILE}.tmp"

jq -n \
    --arg access_token "$ACCESS_TOKEN" \
    --arg refresh_token "$REFRESH_TOKEN" \
    --argjson expires_at "$EXPIRES_AT" \
    --argjson refresh_token_expires_at "$REFRESH_AT" \
    '{
        access_token: $access_token,
        refresh_token: $refresh_token,
        expires_at: $expires_at,
        refresh_token_expires_at: $refresh_token_expires_at
    }' > "$TMP_FILE"

chmod 600 "$TMP_FILE"
mv -f "$TMP_FILE" "$GMAIL_TOKEN_FILE"

echo "GMail access token úspěšně obnoven."

echo -n "Uložený JSON: "
jq . < $GMAIL_TOKEN_FILE

echo "Platnost access tokenu do:  $(date -d "@${EXPIRES_AT}" '+%Y-%m-%d %H:%M:%S %Z') (${EXPIRES_IN} sec)"
echo "Platnost refresh tokenu do: $(date -d "@${REFRESH_AT}" '+%Y-%m-%d %H:%M:%S %Z') (${REFRESH_IN} sec)"

# Uložení aktuálního access tokenu do samostatného souboru.
# imapsync tento soubor načte jako OAuth2 token.
printf '%s\n' "$ACCESS_TOKEN" > "$GMAIL_ACCESS_TOKEN_FILE"
chmod 600 "$GMAIL_ACCESS_TOKEN_FILE"
