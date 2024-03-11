#!/bin/bash

## Bash Styling
#RESET="\e[0m"
#RESET_COLOR="\e[39m"
#BOLD="\e[1m"
#BLUE="\e[34m${BOLD}"
#RED="${RESET}\e[38;5;196m"
#YELLOW="\e[33m${BOLD}"
#GREEN="\e[32m${BOLD}"
#X="${RESET}${BOLD}[${RED}x${RESET_COLOR}${BOLD}]${RESET}"
#CHECKMARK="${RESET}${BOLD}[${GREEN}✓${RESET_COLOR}]${RESET}"

## Transform Long Arguments to Short Arguments
#for ARG in "$@"; do
#  shift
#  case "$ARG" in
#    '--aws-account-id') set -- "$@" '-i' ;;
#    '--github-runner-account-id') set -- "$@" '-g' ;;
#    '--runner-account-id') set -- "$@" '-g' ;;
#    '--application-name') set -- "$@" '-n' ;;
#    '--lowercase-application-name') set -- "$@" '-l' ;;
#    '--environment') set -- "$@" '-e' ;;
#    '--region') set -- "$@" '-r' ;;
#    '--tags') set -- "$@" '-t' ;;
#    '--profile') set -- "$@" '-p' ;;
#    '--sam-managed-bucket') set -- "$@" '-b' ;;
#    '--oidc-url') set -- "$@" '-u' ;;
#    '--role-args') set -- "$@" '-a' ;;
#    *) set -- "$@" "$ARG" ;;
#  esac
#done
#
#
#
## Short Arguments
#while getopts i:g:n:e:r:t:p:l:b:u:a: ARG; do
#  case $ARG in
#    i) AWS_ACCOUNT_ID=$OPTARG ;;
#    g) RUNNER_ACCOUNT_ID=$OPTARG ;;
#    n) APPLICATION_NAME=$OPTARG ;;
#    l) LOWERCASE_APPLICATION_NAME=$OPTARG ;;
#    e) ENVIRONMENT=$OPTARG ;;
#    r) REGION=$OPTARG ;;
#    t) read -r -a TAGS <<< "$OPTARG" ;;
#    p) PROFILE_ARG=("--profile" "$OPTARG") ;;
#    b) SAM_MANAGED_BUCKET=$OPTARG ;;
#    u) OIDC_URL=$OPTARG ;;
#    a) read -r -a ROLE_ARGS <<< "$OPTARG" ;;
#    *) usage ;;
#  esac
#done

# Configuring Variables Needed for AWS
RUNNER_ROOT_ARN="arn:aws:iam::${RUNNER_ACCOUNT_ID}:root"
ROLE_NAME="${APPLICATION_NAME}AssumeRole${ENVIRONMENT}"
OIDC_ROOT="$(echo "$OIDC_URL" | sed -e 's/^https:\/\///')"
OIDC_ARN="arn:aws:iam::${RUNNER_ACCOUNT_ID}:oidc-provider/${OIDC_ROOT}"
#AWS_ACCOUNT_ID="$RUNNER_ACCOUNT_ID"

. "$DEPLOY_SCRIPTS_PATH"/.policies

create_iam_role() {
  # GitHub Runner IAM Role Creation
  echo -e "${BLUE}Creating/Finding the IAM Role ${ROLE_NAME}...${RED}"

  (
    aws iam get-role --role-name "$ROLE_NAME" --region "$REGION" "${PROFILE_ARG[@]}" > /dev/null &&
    echo -e "${CHECKMARK} Found the IAM Role ${BOLD}${GREEN}${ROLE_NAME}"
  ) || (
    echo -e "${X} The IAM Role ${BOLD}${RED}${ROLE_NAME}${RESET} was not found"
    echo -e "${BLUE}Attempting to create the IAM Role ${ROLE_NAME}...${RED}"
    (
      aws iam create-role \
          --role-name "${ROLE_NAME}" \
          --assume-role-policy-document "${TRUSTED_POLICY}" \
          --tags "${TAGS[0]}" \
          > /dev/null
    ) && echo -e "${CHECKMARK} Created the IAM Role ${BOLD}${GREEN}${ROLE_NAME}"
  ) || (echo -e "${X} The IAM Role ${BOLD}${RED}${ROLE_NAME}${RESET} was unable to be created" && exit 1)

  # Updates the GitHub Runner IAM Role to keep all Policies up to date
  echo -e "${BLUE}Updating the IAM Role ${ROLE_NAME}...${RED}"
  (
    aws iam update-assume-role-policy --role-name "${ROLE_NAME}" --policy-document "${TRUSTED_POLICY}" --region "$REGION" "${PROFILE_ARG[@]}" &&
    echo -e "${CHECKMARK} Successfully updated the IAM Role ${BOLD}${GREEN}${ROLE_NAME}"
  ) || ( echo -e "${X} The IAM Role ${BOLD}${RED}${ROLE_NAME}${RESET} was unable to be updated" && exit 1 )
}

# Adding All Policies to an Array to Make Creation Simpler
POLICIES=("S3 ${S3_POLICY}" "CloudFormation ${CLOUD_FORMATION_POLICY}" "IAM ${IAM_POLICY}" "CloudWatch ${CLOUDWATCH_POLICY}")

add_custom_policies() {
  echo "ROLE_ARGS: $ROLE_ARGS"
  read -r ALL_ROLE_ARGS; do
    echo "ALL_ROLE_ARGS: $ALL_ROLE_ARGS"
    # Adding Custom Policies to the Array
    for ROLE_ARG in "${ALL_ROLE_ARGS[@]}"; do
      ROLE_ARG="${ROLE_ARG//\"/}"
      if [ -n "$ROLE_ARG" ] && [ "$ROLE_ARG" != " " ]; then
        case "$ROLE_ARG" in
          'ec2') POLICIES+=("EC2 ${EC2_POLICY}") ;;
          'eventbridge') POLICIES+=("EventBridge ${EVENTBRIDGE_POLICY}") ;;
          'lambda') POLICIES+=("Lambda ${LAMBDA_POLICY}") ;;
          'sqs') POLICIES+=("SQS ${SQS_POLICY}") ;;
          'ssm') POLICIES+=("SSM ${SSM_POLICY}") ;;
          'vpc') POLICIES+=("VPC ${VPC_POLICY}") ;;
          'iot') POLICIES+=("IoT ${IoT_POLICY}") ;;
          *) echo -e "${X} The Role Argument ${BOLD}${RED}${ROLE_ARG}${RESET} is not valid" && exit 1 ;;
        esac
      fi
    done
  done < <(echo "$ROLE_ARGS")
}

# Creates the Policies for the GitHub Runner Role as Inline
CreatePolicy() {
  # Helper Variables for Naming
  POLICY_TYPE="$1"
  POLICY="$2"

  (
    aws iam put-role-policy \
      --role-name "${ROLE_NAME}" \
      --policy-name "${APPLICATION_NAME}${POLICY_TYPE}Policy${ENVIRONMENT}" \
      --policy-document "${POLICY}" \
      "${PROFILE_ARG[@]}" && echo 0 # Success
  ) || echo 1 # Failure
}

update_policies() {
  # Helper Variables for Printing to the Terminal
  SHOULD_FAIL=0
  FAILED=0

  # Updates the Inline Policies for the GitHub Runner Role
  echo -e "${BLUE}Adding/Updating inline policies for the IAM Role ${ROLE_NAME}...${RED}"
  for POLICY in "${POLICIES[@]}"; do
    # Helper Variables for Naming
    POLICY_TYPE=$(echo "$POLICY" | cut -d " " -f1)
    POLICY=$(echo "$POLICY" | cut -d " " -f2)
    FAILED=$(CreatePolicy "${POLICY_TYPE}" "${POLICY}")

    if [ "$FAILED" == 1 ]; then # Job Will Fail With Warnings
      echo -e "${X} Unable to add/update the ${BOLD}${RED}${POLICY_TYPE}${RESET} Policy to the IAM Role ${BOLD}${RED}${ROLE_NAME}${RED}" # > /dev/stderr
      exit 1
    else
      echo -e "${CHECKMARK} Successfully added/updated the ${BOLD}${GREEN}${POLICY_TYPE}${RESET} Policy to the IAM Role ${BOLD}${GREEN}${ROLE_NAME}${RED}" # > /dev/tty
    fi
  done

  # TODO: Fix this because it never fails with errors
  exit $SHOULD_FAIL
}

