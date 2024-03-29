#!/bin/bash

# Bash Styling
RESET="\e[0m"
RESET_COLOR="\e[39m"
BOLD="\e[1m"
BLUE="\e[34m${BOLD}"
RED="${RESET}\e[38;5;196m"
YELLOW="\e[33m${BOLD}"
GREEN="\e[32m${BOLD}"
X="${RESET}${BOLD}[${RED}x${RESET_COLOR}${BOLD}]${RESET}"
CHECKMARK="${RESET}${BOLD}[${GREEN}✓${RESET_COLOR}]${RESET}"

# Transform Long Arguments to Short Arguments
for ARG in "$@"; do
  shift
  case "$ARG" in
    '--environment') set -- "$@" '-e' ;;
    '--force-deploy') set -- "$@" '-d' ;;
    '--custom-parameter-overrides') set -- "$@" '-p' ;;
    '--parameter-overrides') set -- "$@" '-p' ;;
    *) set -- "$@" "$ARG" ;;
  esac
done

# Short Arguments
while getopts e:p:rbdal ARG; do
  case $ARG in
    e) ENVIRONMENT=$OPTARG ;;
    l) LOCAL_DEPLOYMENT=1 ;;
    r) UPDATE_ROLE=1 ;;
    b) UPDATE_S3_BUCKET=1 ;;
    d) FORCE_DEPLOY=1 ;;
    p) CUSTOM_PARAMETER_OVERRIDES="$(echo "$OPTARG" | sed sed -e 's/\"//')" ;;
    *) usage ;;
  esac
done

if [ -z "$ENVIRONMENT" ] || [ "$ENVIRONMENT" == " " ]; then
  ENVIRONMENT="DEV"
fi

if [ "$1" == "all" ]; then
  UPDATE_ROLE=1
  UPDATE_S3_BUCKET=1
  FORCE_DEPLOY=1
fi

if [ "$LOCAL_DEPLOYMENT" == 1 ]; then
  TTY="tty"
else
  TTY="tty0"
fi

get_env_var() {
  (grep "$1=" "$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]').env") | sed -e 's/\"//' | cut -d '=' -f2-
}

if [ "$LOCAL_DEPLOYMENT" == 1 ]; then
  APPLICATION_NAME="$(get_env_var "APPLICATION_NAME")"
  RUNNER_ACCOUNT_ID="$(get_env_var "RUNNER_ACCOUNT_ID")"
  AWS_ACCOUNT_ID="$(get_env_var "AWS_ACCOUNT_ID")"
  ENVIRONMENT="$(echo "$ENVIRONMENT" | tr '[:lower:]' '[:upper:]')"
  REGION="$(get_env_var "REGION")"
  PROFILE="$(get_env_var "PROFILE")"
  RUNNER_ACCESS_TOKEN="$(get_env_var "RUNNER_ACCESS_TOKEN")"
  ORG_URL="$(get_env_var "ORG_URL")"
  OIDC_URL="$(get_env_var "OIDC_URL")"
  OIDC_THUMBPRINT="$(get_env_var "OIDC_THUMBPRINT")"
  UNPARSED_TAGS="$(get_env_var "TAGS")"
  CONTAINER_REGISTRY_TOKEN="$(get_env_var "CONTAINER_REGISTRY_TOKEN")"
  RUNNER_IMAGE="$(get_env_var "RUNNER_IMAGE")"
  LOWERCASE_NAME="$(echo "$APPLICATION_NAME" | sed -e 's|\([A-Z][^A-Z]\)| \1|g' -e 's|\([a-z]\)\([A-Z]\)|\1 \2|g' | sed 's/^ *//g' | tr '[:upper:]' '[:lower:]' | tr " " "-")"
  LOWERCASE_APPLICATION_NAME="$LOWERCASE_NAME-$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]')"
  SAM_MANAGED_BUCKET="$LOWERCASE_NAME-sam-managed-$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]')"
  ROLE_ARGS="$(get_env_var "ROLE_ARGS")"
  CUSTOM_PARAMETER_OVERRIDES="$(get_env_var "CUSTOM_PARAMETER_OVERRIDES" | sed -e 's/\"//')"
fi

PROFILE_ARG=()

if [ -n "$PROFILE" ] && [ "$PROFILE" != " " ]; then
  PROFILE_ARG=("--profile" "$PROFILE")
fi

ROLE_ARG=()

if [ -n "$ROLE_ARGS" ] && [ "$ROLE_ARGS" != " " ]; then
  ROLE_ARG=("--role-args" "\"$ROLE_ARGS\"")
fi

check_aws_creds() {
  echo -e "\n\e[1;38;5;39m* Checking status of AWS Credentials..." > /dev/"$TTY"
  (
    aws sts get-caller-identity "${PROFILE_ARG[@]}" | jq ".Account" | tr -d "\"" &&
    echo -e "\e[1;32m  Valid Security Token" > /dev/"$TTY"
  ) || (
    (
      # TODO: Add windows vs mac check
      echo -e "${BOLD}${RED} Expired Security Token\n\e[1;33m  > aws configure sso${YELLOW}" > /dev/"$TTY"
      winpty aws configure sso "${PROFILE_ARG[@]}" > /dev/"$TTY" &&
      aws sts get-caller-identity "${PROFILE_ARG[@]}" | jq ".Account" | tr -d "\""
    ) || (echo -e "${BOLD}${RED}  Error running 'aws configure sso'\e[1;38;5;39m" > /dev/stderr && exit 1)
  )
}

parse_tags() {
  # Parsing Tags to a Usable Form for the AWS CLI

  if [ "$LOCAL_DEPLOYMENT" == 1 ]; then
    read -r -a TAGSET <<< "$(get_env_var "TAGS")"
  else
    read -r -a TAGSET <<< "$TAGS"
  fi

  TAGS=""
  KEYS=()

  declare -A TAGS_FOR_DEPLOY

  for TAG in "${TAGSET[@]}"; do
    TAG="${TAG//\"/}"
    if [[ -n $TAG ]] && [[ $TAG != " " ]]; then
      KEY="$( (echo "$TAG" | cut -d "=" -f1))"
      VALUE="$( (echo "$TAG" | cut -d "=" -f2) | sed -e 's/'\''//')"
      if [[ $TAGS == "" ]]; then
        TAGS="{\"Key\":\"${KEY}\",\"Value\":\"${VALUE}\"}"
      else
        TAGS="$TAGS,{\"Key\":\"${KEY}\",\"Value\":\"${VALUE}\"}"
      fi
      KEYS+=("$KEY")
      TAGS_FOR_DEPLOY[$KEY]=$VALUE
    fi
  done

  # Updating Existing Tags
  NEW_TAGSET=""
  for KEY in "${KEYS[@]}"; do
    if [[ $NEW_TAGSET == "" ]]; then
      NEW_TAGSET="$NEW_TAGSET{Key=$KEY,Value=${TAGS_FOR_DEPLOY[$KEY]}}"
    else
      NEW_TAGSET="$NEW_TAGSET,{Key=$KEY,Value=${TAGS_FOR_DEPLOY[$KEY]}}"
    fi
  done

  NEW_TAGSET="[$NEW_TAGSET]"

  echo "[$TAGS]" "[$NEW_TAGSET]"
}

RUNNER_ACCOUNT_ID=$(check_aws_creds)

if [ -z "$AWS_ACCOUNT_ID" ] || [ "$AWS_ACCOUNT_ID" == " " ]; then
  AWS_ACCOUNT_ID="$RUNNER_ACCOUNT_ID"
fi

if [ "$LOCAL_DEPLOYMENT" != 1 ]; then
  UNPARSED_TAGS=$TAGS
fi

read -r -a TAGS <<< "$(parse_tags)"

update_role() {
  UPDATE_ROLE_ARGS=(
    "--aws-account-id" "$AWS_ACCOUNT_ID"
    "--github-runner-account-id" "$RUNNER_ACCOUNT_ID"
    "--application-name" "$APPLICATION_NAME"
    "--lowercase-application-name" "$LOWERCASE_APPLICATION_NAME"
    "--environment" "$ENVIRONMENT"
    "--region" "$REGION"
    "${PROFILE_ARG[@]}"
    "${ROLE_ARG[@]}"
    "--sam-managed-bucket" "$SAM_MANAGED_BUCKET"
    "--oidc-url" "$OIDC_URL"
    "--tags" "${TAGS[*]}"
  )
  if [ "$LOCAL_DEPLOYMENT" == 1 ]; then
    ./deploy-scripts/create-deploy-role.sh "${UPDATE_ROLE_ARGS[@]}"
  else
    /deploy-scripts/create-deploy-role.sh "${UPDATE_ROLE_ARGS[@]}"
  fi
}

update_s3_bucket() {
  UPDATE_S3_BUCKET_ARGS=(
    "--bucket-name" "$SAM_MANAGED_BUCKET"
    "--tags" "$UNPARSED_TAGS"
    "${PROFILE_ARG[@]}"
    "--region" "$REGION"
  )

  if [ "$LOCAL_DEPLOYMENT" == 1 ]; then
    ./deploy-scripts/create-s3-bucket.sh "${UPDATE_S3_BUCKET_ARGS[@]}"
  else
    /deploy-scripts/create-s3-bucket.sh "${UPDATE_S3_BUCKET_ARGS[@]}"
  fi
}

deploy_sam() {
  DEPLOY_SAM_ARGS=(
      "${PROFILE_ARG[@]}"
      "--parameter-overrides" "ApplicationName=$APPLICATION_NAME Environment=$ENVIRONMENT Region=$REGION LowerCaseApplicationName=$LOWERCASE_APPLICATION_NAME $UNPARSED_TAGS $CUSTOM_PARAMETER_OVERRIDES"
      "--stack-name" "${APPLICATION_NAME}${ENVIRONMENT}"
      "--s3-bucket" "${SAM_MANAGED_BUCKET}"
      "--capabilities" "CAPABILITY_NAMED_IAM"
      "--region" "$REGION"
      "--tags" "$UNPARSED_TAGS"
      "--no-confirm-changeset"
      "--no-fail-on-empty-changeset"
    )

    echo -e "\n\e[1;38;5;39m* Deploying to AWS through SAM..."
    if where sam 2> /dev/null | grep -qi '.cmd'; then
      # TODO: Add a sam build parameter..?
      C:/PROGRA~1/Amazon/AWSSAMCLI/bin/sam.cmd deploy "${DEPLOY_SAM_ARGS[@]}" || exit 1
    else
      sam deploy "${DEPLOY_SAM_ARGS[@]}" || exit 1
    fi
}

DEPLOY_ROLE_ASSUMED=0

assume_deploy_role() {
  if [ $DEPLOY_ROLE_ASSUMED == 0 ]; then
  echo -e "\n\e[1;38;5;39m* Assuming Deploy Role..."
  eval "$( (aws sts assume-role --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${APPLICATION_NAME}AssumeRole${ENVIRONMENT}" --role-session-name "${LOWERCASE_APPLICATION_NAME}-assume-session-via-oidc" || exit 1) | jq -r '.Credentials | "export AWS_ACCESS_KEY_ID=\(.AccessKeyId)\nexport AWS_SECRET_ACCESS_KEY=\(.SecretAccessKey)\nexport AWS_SESSION_TOKEN=\(.SessionToken)\n"')" || exit 1
    DEPLOY_ROLE_ASSUMED=1
  fi
}

if [ "$UPDATE_ROLE" == 1 ]; then
  update_role
fi

if [ "$UPDATE_S3_BUCKET" == 1 ]; then
  assume_deploy_role
  update_s3_bucket
fi

if [ "$FORCE_DEPLOY" == 1 ] && [ "$LOCAL_DEPLOYMENT" != 1 ]; then
    assume_deploy_role
    deploy_sam
fi

if [ "$LOCAL_DEPLOYMENT" == 1 ]; then
  readarray -t DEPLOY_FILES <<< "$( (stat -c %n:%Y ./deploy-scripts/deploy.sh "$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]').env" ./deploy-scripts/create-* template.yaml) | sed -e 's/.\/deploy-scripts\///' | sed -e 's/.sh//')"

  LAST_DEPLOY=0
  MODIFIED=0

  for FILE in "${DEPLOY_FILES[@]}"; do
    FILE_NAME="$(echo "$FILE" | cut -d ':' -f1)"
    MODIFIED_TIME="$(echo "$FILE" | cut -d ':' -f2)"

    case "$FILE_NAME" in
    "deploy")
      LAST_DEPLOY="$MODIFIED_TIME"
      ;;
  #    export LAST_DEPLOY ;;
    "$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]').env")
      if [[ "$MODIFIED_TIME" -gt "$LAST_DEPLOY" ]]; then
        update_role
        assume_deploy_role
        update_s3_bucket
        MODIFIED=1
      fi
      ;;
    "create-deploy-role")
      if [[ "$MODIFIED_TIME" -gt "$LAST_DEPLOY" ]]; then
        update_role
        MODIFIED=1
      fi
      ;;
    "create-s3-bucket")
      if [[ "$MODIFIED_TIME" -gt "$LAST_DEPLOY" ]]; then
        assume_deploy_role
        update_s3_bucket
        MODIFIED=1
      fi
      ;;
    "template.yaml")
      if [[ "$MODIFIED_TIME" -gt "$LAST_DEPLOY" ]]; then
        MODIFIED=1
      fi
      ;;
    *) ;;
    esac

  done

  if [ "$MODIFIED" == 1 ]; then
    assume_deploy_role
    deploy_sam
  else
    if [ "$FORCE_DEPLOY" == 1 ]; then
      assume_deploy_role
      deploy_sam
    else
      echo -e "\n\e[1;38;5;39mNo Modified Files\n\n\tUse --force-deploy or -d to Force a Deployment\n\nExiting..."
    fi
  fi

  touch ./deploy-scripts/create-*.sh
  touch "$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]').env"
  touch ./deploy-scripts/deploy.sh
fi