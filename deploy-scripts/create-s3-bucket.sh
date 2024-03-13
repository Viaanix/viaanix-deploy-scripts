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
    '--application-bucket') set -- "$@" '-b' ;;
    '--application-bucket-name') set -- "$@" '-b' ;;
    '--bucket') set -- "$@" '-b' ;;
    '--bucket-name') set -- "$@" '-b' ;;
    '--tags') set -- "$@" '-t' ;;
    '--profile') set -- "$@" '-p' ;;
    '--region') set -- "$@" '-r' ;;
    *) set -- "$@" "$ARG" ;;
  esac
done

# Short Arguments
while getopts b:t:p:r: ARG; do
  case $ARG in
    b) BUCKET_NAME=$OPTARG ;;
    t) read -r -a TAGS <<< "$OPTARG" ;;
    p) PROFILE_ARG=("--profile" "$OPTARG") ;;
#    p) PROFILE=$OPTARG ;;
    r) REGION=$OPTARG ;;
    *) usage ;;
  esac
done

# Creating S3 Bucket if it Doesn't Exist
echo -e "${BLUE}Looking for existing S3 Bucket $BUCKET_NAME...${RED}"
(
  (
    aws s3api head-bucket --bucket "$BUCKET_NAME" "${PROFILE_ARG[@]}" > /dev/null &&
    echo -e "${CHECKMARK} S3 Bucket $BUCKET_NAME ${GREEN}found${RESET}"
  ) || # Bucket Does Not Exist -> Create Bucket
    (
      echo -e "${X} S3 Bucket $BUCKET_NAME not found. Creating an S3 Bucket $BUCKET_NAME...${RED}" &&
        (
          aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION" --acl private "${PROFILE_ARG[@]}" > /dev/null &&
          echo -e "${CHECKMARK} S3 Bucket $BUCKET_NAME ${GREEN}created${RESET}"
        ) || # Error Creating Bucket
        (echo -e "${X} Error creating the S3 Bucket $BUCKET_NAME" && exit 1)
    )
) || # Error Accessing the S3 Bucket
  (echo -e "${X} Error accessing the S3 Bucket $BUCKET_NAME" && exit 1)

# Turning Off All Public Access Settings to the S3 Bucket
echo -e "${BLUE}Checking public access settings of the S3 Bucket $BUCKET_NAME...${RED}"
PUBLIC_ACCESS_SETTINGS=$( aws s3api get-public-access-block --bucket "$BUCKET_NAME" "${PROFILE_ARG[@]}" | jq ".[].BlockPublicAcls,.[].IgnorePublicAcls,.[].BlockPublicPolicy,.[].RestrictPublicBuckets")

if echo "$PUBLIC_ACCESS_SETTINGS" | grep -q "false"; then # Some Settings are Not Blocking Public Access
  echo -e "${X} Some settings are not ${YELLOW}Blocking Public Access${RESET} to the S3 Bucket $BUCKET_NAME. This is not best practice - Blocking public access to the S3 Bucket $BUCKET_NAME..."
  aws s3api put-public-access-block --bucket "$BUCKET_NAME" --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" "${PROFILE_ARG[@]}"
elif echo "$PUBLIC_ACCESS_SETTINGS" | grep -q "true"; then # Block Public Access Settings are On
  echo -e "${CHECKMARK} The S3 Bucket $BUCKET_NAME is ${GREEN}Blocking Public Access${RESET}"
else # Error Accessing the Public Access Settings of the S3 Bucket
  echo -e "${X} Error accessing the Blocking Public Access Settings to the S3 Bucket $BUCKET_NAME"
  echo -e "${BLUE}Creating Block Public Access Settings for the S3 Bucket $BUCKET_NAME...${RED}"
  (
    aws s3api put-public-access-block --bucket "$BUCKET_NAME" --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" "${PROFILE_ARG[@]}" &&
    echo -e "${CHECKMARK} Created Block Public Access Settings for the S3 Bucket $BUCKET_NAME"
  ) || (echo -e "${X} Error creating Block Public Access Settings for the S3 Bucket $BUCKET_NAME" && exit 1)
fi

# Changing Object Ownership Settings of the S3 Bucket
echo -e "${BLUE}Checking object ownership settings of the S3 Bucket $BUCKET_NAME...${RED}"
(
  aws s3api get-bucket-ownership-controls --bucket "$BUCKET_NAME" "${PROFILE_ARG[@]}" | jq ".[].Rules[].ObjectOwnership" |
    if grep -q "BucketOwnerPreferred"; then # Bucket Owner Preferred is On
      echo -e "${CHECKMARK} The object ownership of the S3 Bucket $BUCKET_NAME is ${GREEN}\e[32mBucketOwnerPreferred${RESET}"
    else
      (
        grep -q "BucketOwnerPreferred" && # Checking For Error
          # Changing the Object Ownership Settings of the S3 Bucket to Bucket Owner Preferred
          echo -e "${X} The object ownership of the S3 Bucket $BUCKET_NAME is not ${YELLOW}BucketOwnerPreferred${RESET}. This is not best practice - Setting the object ownership of the S3 Bucket $BUCKET_NAME to ${YELLOW}\e[33mBucketOwnerPreferred${RESET}...${RED}" &&
          aws s3api put-bucket-ownership-controls --bucket "$BUCKET_NAME" --ownership-controls "{\"Rules\":[{\"ObjectOwnership\":\"BucketOwnerPreferred\"}]}" "${PROFILE_ARG[@]}"
      ) || # Error Accessing the Object Ownership Settings of the S3 Bucket
        echo -e "${X} Error accessing the object ownership settings of the S3 Bucket $BUCKET_NAME"
      echo -e "${BLUE}Creating Bucket Ownership Settings for the S3 Bucket $BUCKET_NAME...${RED}"
      (
        aws s3api put-bucket-ownership-controls --bucket "$BUCKET_NAME" --ownership-controls "{\"Rules\":[{\"ObjectOwnership\":\"BucketOwnerPreferred\"}]}" "${PROFILE_ARG[@]}" &&
        echo -e "${CHECKMARK} Created Bucket Ownership Settings for the S3 Bucket $BUCKET_NAME"
      ) || (echo -e "${X} Error creating Bucket Ownership Settings for the S3 Bucket $BUCKET_NAME" && exit 1)
    fi
) ||
  (
    echo -e "${X} Error accessing the object ownership settings of the S3 Bucket $BUCKET_NAME"
    echo -e "${BLUE}Creating Bucket Ownership Settings for the S3 Bucket $BUCKET_NAME...${RED}"
    (
      aws s3api put-bucket-ownership-controls --bucket "$BUCKET_NAME" --ownership-controls "{\"Rules\":[{\"ObjectOwnership\":\"BucketOwnerPreferred\"}]}" "${PROFILE_ARG[@]}" &&
        echo -e "${CHECKMARK} Created Bucket Ownership Settings for the S3 Bucket $BUCKET_NAME"
    ) || (echo -e "${X} Error creating Bucket Ownership Settings for the S3 Bucket $BUCKET_NAME" && exit 1)
  )

echo -e "${BLUE}Adding tags the S3 Bucket $BUCKET_NAME...${RED}"

KEYS=()
declare -A NEW_TAGS

# Getting the Existing Tags of the S3 Bucket
#   This step is necessary because SAM creates tags that cannot be removed,
#   and adding tags will remove tags not included in the tagset list
# TODO: There is an error with getting the current tagset
readarray -t <<< "$( aws s3api get-bucket-tagging --bucket "$BUCKET_NAME" "${PROFILE_ARG[@]}" | tr -s " " | tr -d "{}[],\t\r\"")" &&
  if [ -z "${MAPFILE[*]}" ]; then # Error Accessing the Existing Tags of the S3 Bucket
    echo -e "${X} Error accessing the existing tags to the S3 Bucket $BUCKET_NAME"
    echo -e "${BLUE}Creating new tagset for the S3 Bucket $BUCKET_NAME...${RED}"
    TAGSET=""
    # Adding New Tags
    for TAG in "${TAGS[@]}"; do
      if [[ $TAGSET == "" ]]; then
        TAGSET="{Key=$(echo "$TAG" | cut -d "=" -f1),Value=$(echo "$TAG" | cut -d "=" -f2)}"
      else
        TAGSET="$TAGSET,{Key=$(echo "$TAG" | cut -d "=" -f1),Value=$(echo "$TAG" | cut -d "=" -f2)}"
      fi
      NEW_TAGS["$(echo "$TAG" | cut -d "=" -f1)"]="$(echo "$TAG" | cut -d "=" -f2)"
    done
    TAGSET="[$TAGSET]"
  else
    # Parsing Tags
    for TAG in "${TAGS[@]}"; do
      TAG="${TAG//\"/}"
      NEW_TAGS["$(echo "$TAG" | cut -d "=" -f1)"]="$(echo "$TAG" | cut -d "=" -f2)"
    done
    # Parsing Existing Tags
    for ENTRY in "${MAPFILE[@]}"; do
      if [[ -n $ENTRY ]] && [[ $ENTRY != " " ]]; then
        if [[ $(echo "$ENTRY" | cut -d " " -f2) == "Key:" ]]; then
          KEYS+=("$(echo "$ENTRY" | cut -d " " -f3)")
          NEXT_TAG=$(echo "$ENTRY" | cut -d " " -f3)
        elif [[ $(echo "$ENTRY" | cut -d " " -f2) == "Value:" ]]; then
          NEW_TAGS[$NEXT_TAG]=$(echo "$ENTRY" | cut -d " " -f3)
        fi
      fi
    done

    # Updating Existing Tags
    TAGSET=""
    for KEY in "${KEYS[@]}"; do
      if [[ $TAGSET == "" ]]; then
        TAGSET="$TAGSET{Key=$KEY,Value=${NEW_TAGS[$KEY]}}"
      else
        TAGSET="$TAGSET,{Key=$KEY,Value=${NEW_TAGS[$KEY]}}"
      fi
    done

    TAGSET="[$TAGSET]"
  fi

# Adding Tags to the S3 Bucket
(
  aws s3api put-bucket-tagging --bucket "$BUCKET_NAME" --tagging "TagSet=$TAGSET" "${PROFILE_ARG[@]}" &&
  echo -e "${CHECKMARK} Successfully ${GREEN}added tags${RESET} to the S3 Bucket $BUCKET_NAME"
) || echo -e "${X} Error adding tags to the S3 Bucket $BUCKET_NAME. You will need to check the tags manually through the AWS console to ensure they are correctly added"