#!/bin/bash

# Environment Variables Needed for Viaanix Applications
LOWERCASE_NAME="$(echo "$APPLICATION_NAME" | sed -e 's|\([A-Z][^A-Z]\)| \1|g' -e 's|\([a-z]\)\([A-Z]\)|\1 \2|g' | sed 's/^ *//g' | tr '[:upper:]' '[:lower:]' | tr " " "-")"
LOWERCASE_APPLICATION_NAME="$LOWERCASE_NAME-$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]')"
SAM_MANAGED_BUCKET="$LOWERCASE_NAME-sam-managed-viaanix-$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]')"
echo "LOWERCASE_APPLICATION_NAME=$LOWERCASE_APPLICATION_NAME" >> "$GITHUB_OUTPUT"
echo "SAM_MANAGED_BUCKET=$LOWERCASE_NAME-sam-managed-viaanix-$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]')" >> "$GITHUB_OUTPUT"