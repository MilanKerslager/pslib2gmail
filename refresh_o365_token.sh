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

if [[ ! -f "$O365_TOKEN_FILE" ]]; then
    echo "ERROR: Token file neexistuje: $O365_TOKEN_FILE" >&2
    exit 1
fi

REFRESH_TOKEN="$(jq -r '.refresh_token // empty' "$O365_TOKEN_FILE")"

if [[ -z "$REFRESH_TOKEN" ]]; then
    echo "ERROR: V token souboru $REFRESH_TOKEN není refresh_token." >&2
    exit 1
fi


# ------------------------------------------------------------
# Je access token stále použitelný?
#
# Pokud máme expires_at a zbývá více než TOKEN_REFRESH_MARGIN,
# nemusíme dělat nový refresh.
# ------------------------------------------------------------

NOW="$(date +%s)"

EXPIRES_AT="$(jq -r '.expires_at // 0' "$O365_TOKEN_FILE")"

if [[ "$EXPIRES_AT" =~ ^[0-9]+$ ]] && \
   (( EXPIRES_AT > NOW + TOKEN_REFRESH_MARGIN )); then

    REMAINING=$((EXPIRES_AT - NOW))

    echo "O365 access token je stále platný (${REMAINING} sec)."
    exit 0
fi


# ------------------------------------------------------------
# Refresh OAuth tokenu
# ------------------------------------------------------------

echo "O365 access token je potřeba obnovit..."

TMP_RESPONSE="$(mktemp)"

trap 'rm -f "$TMP_RESPONSE"' EXIT

HTTP_CODE="$(
    curl \
        --silent \
        --show-error \
        --output "$TMP_RESPONSE" \
        --write-out '%{http_code}' \
        --request POST \
        "$O365_TOKEN_URL" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "client_id=${O365_CLIENT_ID}" \
        --data-urlencode "scope=${O365_SCOPE}" \
        --data-urlencode "refresh_token=${REFRESH_TOKEN}" \
        --data-urlencode "grant_type=refresh_token"
)"

if [[ "$HTTP_CODE" != "200" ]]; then
    echo "ERROR: OAuth token refresh selhal." >&2
    echo "HTTP status: $HTTP_CODE" >&2
    echo "Microsoft response:" >&2
    jq . "$TMP_RESPONSE" 2>/dev/null || cat "$TMP_RESPONSE"
    exit 1
fi

echo -n "Response: "
jq . "$TMP_RESPONSE"

# ------------------------------------------------------------
# Zpracování odpovědi
# ------------------------------------------------------------

ACCESS_TOKEN="$(jq -r '.access_token // empty' "$TMP_RESPONSE")"
NEW_REFRESH_TOKEN="$(jq -r '.refresh_token // empty' "$TMP_RESPONSE")"
EXPIRES_IN="$(jq -r '.expires_in // empty' "$TMP_RESPONSE")"

if [[ -z "$ACCESS_TOKEN" ]]; then
    echo "ERROR: Microsoft nevrátil access_token." >&2
    jq . "$TMP_RESPONSE"
    exit 1
fi

if [[ -z "$EXPIRES_IN" || ! "$EXPIRES_IN" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Microsoft nevrátil platné expires_in." >&2
    jq . "$TMP_RESPONSE"
    exit 1
fi

EXPIRES_AT=$((NOW + EXPIRES_IN))


# ------------------------------------------------------------
# Pokud Microsoft vydal nový refresh token, použijeme ho.
# Jinak zachováme původní.
# ------------------------------------------------------------

if [[ -n "$NEW_REFRESH_TOKEN" ]]; then
    REFRESH_TOKEN_TO_SAVE="$NEW_REFRESH_TOKEN"
else
    REFRESH_TOKEN_TO_SAVE="$REFRESH_TOKEN"
fi


# ------------------------------------------------------------
# Atomický zápis token souboru
# ------------------------------------------------------------

TMP_TOKEN="${O365_TOKEN_FILE}.tmp.$$"

jq -n \
    --arg refresh_token "$REFRESH_TOKEN_TO_SAVE" \
    --arg access_token "$ACCESS_TOKEN" \
    --argjson expires_at "$EXPIRES_AT" \
    --argjson refreshed_at "$NOW" \
    '{
        refresh_token: $refresh_token,
        access_token: $access_token,
        expires_at: $expires_at,
        refreshed_at: $refreshed_at
    }' \
    > "$TMP_TOKEN"

chmod 600 "$TMP_TOKEN"

mv "$TMP_TOKEN" "$O365_TOKEN_FILE"


echo "O365 access token úspěšně obnoven."
echo "Platnost: $(date -d "@$EXPIRES_AT" '+%Y-%m-%d %H:%M:%S')"

# Uložení aktuálního access tokenu do samostatného souboru.
# imapsync tento soubor načte jako OAuth2 token.
printf '%s\n' "$ACCESS_TOKEN" > "$O365_ACCESS_TOKEN_FILE"
chmod 600 "$O365_ACCESS_TOKEN_FILE"
