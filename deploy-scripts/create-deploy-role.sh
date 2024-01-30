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
    '--aws-account-id') set -- "$@" '-i' ;;
    '--github-runner-account-id') set -- "$@" '-g' ;;
    '--runner-account-id') set -- "$@" '-g' ;;
    '--application-name') set -- "$@" '-n' ;;
    '--lowercase-application-name') set -- "$@" '-l' ;;
    '--environment') set -- "$@" '-e' ;;
    '--region') set -- "$@" '-r' ;;
    '--tags') set -- "$@" '-t' ;;
    '--profile') set -- "$@" '-p' ;;
    '--sam-managed-bucket') set -- "$@" '-b' ;;
    '--oidc-url') set -- "$@" '-u' ;;
    '--role-args') set -- "$@" '-a' ;;
    *) set -- "$@" "$ARG" ;;
  esac
done



# Short Arguments
while getopts i:g:n:e:r:t:p:l:b:u:a: ARG; do
  case $ARG in
    i) AWS_ACCOUNT_ID=$OPTARG ;;
    g) RUNNER_ACCOUNT_ID=$OPTARG ;;
    n) APPLICATION_NAME=$OPTARG ;;
    l) LOWERCASE_APPLICATION_NAME=$OPTARG ;;
    e) ENVIRONMENT=$OPTARG ;;
    r) REGION=$OPTARG ;;
    t) read -r -a TAGS <<< "$OPTARG" ;;
    p) PROFILE_ARG=("--profile" "$OPTARG") ;;
    b) SAM_MANAGED_BUCKET=$OPTARG ;;
    u) OIDC_URL=$OPTARG ;;
    a) read -r -a ROLE_ARGS <<< "$OPTARG" ;;
    *) usage ;;
  esac
done

# Configuring Variables Needed for AWS
RUNNER_ROOT_ARN="arn:aws:iam::${RUNNER_ACCOUNT_ID}:root"
ROLE_NAME="${APPLICATION_NAME}AssumeRole${ENVIRONMENT}"
OIDC_ROOT="$(echo "$OIDC_URL" | sed -e 's/^https:\/\///')"
OIDC_ARN="arn:aws:iam::${RUNNER_ACCOUNT_ID}:oidc-provider/${OIDC_ROOT}"
AWS_ACCOUNT_ID="$RUNNER_ACCOUNT_ID"

# Policy that Allows the GitHub Runner to Assume this Account
TRUSTED_POLICY=$(echo "\
{\
  \"Version\": \"2012-10-17\",\
  \"Statement\": [\
    {\
      \"Sid\": \"AllowAssumeRoleOIDC\",\
      \"Effect\": \"Allow\",\
      \"Principal\": {\
        \"Federated\": \"$OIDC_ARN\"\
      },\
      \"Action\": \"sts:AssumeRoleWithWebIdentity\",\
      \"Condition\": {\
        \"StringLike\": {\
          \"$OIDC_ROOT:sub\": \"repo:Viaanix/*\"
        },\
        \"StringEquals\": {\
          \"$OIDC_ROOT:aud\": \"sts.amazonaws.com\"
        }\
      }\
    },\
    {\
      \"Sid\": \"AllowAssumeRole\",\
      \"Effect\": \"Allow\",\
      \"Principal\": {\
        \"AWS\": \"${RUNNER_ROOT_ARN}\"\
      },\
      \"Action\": \"sts:AssumeRole\"\
    },\
    {\
      \"Sid\": \"AllowAssumeRoleSession\",\
      \"Effect\": \"Allow\",\
      \"Principal\": {\
        \"AWS\": \"arn:aws:sts::${AWS_ACCOUNT_ID}:assumed-role/${APPLICATION_NAME}AssumeRole${ENVIRONMENT}/${LOWERCASE_APPLICATION_NAME}-assume-session-via-oidc\"\
      },\
      \"Action\": \"sts:AssumeRole\"\
    }\
  ]\
}" | jq -c '.')

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
) || echo -e "${X} The IAM Role ${BOLD}${RED}${ROLE_NAME}${RESET} was unable to be created" && exit 1

# Updates the GitHub Runner IAM Role to keep all Policies up to date
echo -e "${BLUE}Updating the IAM Role ${ROLE_NAME}...${RED}"
(
  aws iam update-assume-role-policy --role-name "${ROLE_NAME}" --policy-document "${TRUSTED_POLICY}" --region "$REGION" "${PROFILE_ARG[@]}" &&
  echo -e "${CHECKMARK} Successfully updated the IAM Role ${BOLD}${GREEN}${ROLE_NAME}"
) || ( echo -e "${X} The IAM Role ${BOLD}${RED}${ROLE_NAME}${RESET} was unable to be updated" && exit 1 )

# Least Access Needed for Cloud Formation - Always Needed
CLOUD_FORMATION_POLICY=$(echo "\
{\
  \"Version\": \"2012-10-17\",\
  \"Statement\": [\
    {\
      \"Sid\": \"AllowBasicCloudFormation\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"cloudformation:CreateChangeSet\",\
        \"cloudformation:DescribeChangeSet\",\
        \"cloudformation:DeleteChangeSet\",\
        \"cloudformation:ExecuteChangeSet\",\
        \"cloudformation:DescribeStacks\",\
        \"cloudformation:DescribeStackEvents\",\
        \"cloudformation:GetTemplateSummary\"\
      ],\
      \"Resource\": [\
        \"arn:aws:s3:::${SAM_MANAGED_BUCKET}/*\",\
        \"arn:aws:cloudformation:${REGION}:${AWS_ACCOUNT_ID}:stack/${APPLICATION_NAME}${ENVIRONMENT}/*\",\
        \"arn:aws:cloudformation:${REGION}:aws:transform/Serverless-2016-10-31\"\
      ]\
    },\
    {\
      \"Sid\": \"AllowBasicCloudFormationResources\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"cloudformation:DeleteResource\",\
        \"cloudformation:GetResource\",\
        \"cloudformation:UpdateResource\",\
        \"cloudformation:CreateResource\"\
      ],\
      \"Resource\": [\
        \"*\"\
      ]\
    }\
  ]\
}" | jq -c '.')

# Least Access Needed for CloudWatch - Always Needed
CLOUDWATCH_POLICY=$(echo "\
{\
  \"Version\": \"2012-10-17\",\
  \"Statement\": [\
    {\
      \"Sid\": \"AllowBasicLogs\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"logs:CreateLogGroup\",\
        \"logs:DescribeLogGroups\",\
        \"logs:DeleteLogGroup\",\
        \"logs:TagResource\",\
        \"logs:UntagResource\",\
        \"logs:ListTagsForResource\",\
        \"logs:UntagLogGroup\",\
        \"logs:TagLogGroup\",\
        \"logs:ListTagsLogGroup\"\
      ],\
      \"Resource\": [\
        \"arn:aws:logs:${REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/events/${APPLICATION_NAME}*${ENVIRONMENT}:log-stream:\",\
        \"arn:aws:logs:${REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/events/${APPLICATION_NAME}*${ENVIRONMENT}\",\
        \"arn:aws:logs:${REGION}:${AWS_ACCOUNT_ID}:log-group:${APPLICATION_NAME}*${ENVIRONMENT}:log-stream:\",\
        \"arn:aws:logs:${REGION}:${AWS_ACCOUNT_ID}:log-group:${APPLICATION_NAME}*${ENVIRONMENT}\",\
        \"arn:aws:logs:${REGION}:${AWS_ACCOUNT_ID}:log-group:*${LOWERCASE_APPLICATION_NAME}:log-stream:\",\
        \"arn:aws:logs:${REGION}:${AWS_ACCOUNT_ID}:log-group:*${LOWERCASE_APPLICATION_NAME}\",\
        \"arn:aws:logs:${REGION}:${AWS_ACCOUNT_ID}:log-group::log-stream:\"\
      ]\
    },\
    {\
      \"Sid\": \"AllowBasicLogsResources\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"logs:CreateLogDelivery\",\
        \"logs:GetLogDelivery\",\
        \"logs:ListLogDeliveries\",\
        \"logs:UpdateLogDelivery\",\
        \"logs:PutResourcePolicy\",\
        \"logs:DescribeResourcePolicies\",\
        \"logs:DeleteResourcePolicy\"\
      ],\
      \"Resource\": [\
        \"*\"\
      ]\
    }\
  ]\
}" | jq -c '.')

# Least Access Needed for S3 - Always Needed for SAM_MANAGED_BUCKET
S3_POLICY=$(echo "\
{\
  \"Version\": \"2012-10-17\",\
  \"Statement\": [\
    {\
      \"Sid\": \"AllowBasicS3\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"s3:PutObject\",\
        \"s3:GetObject\",\
        \"s3:ListBucket\",\
        \"s3:ListObjects\",\
        \"s3:DeleteObject\",\
        \"s3:GetBucketTagging\",\
        \"s3:GetBucketVersioning\",\
        \"s3:PutBucketVersioning\",\
        \"s3:PutBucketPublicAccessBlock\",\
        \"s3:GetBucketPublicAccessBlock\",\
        \"s3:PutPublicAccessBlock\",\
        \"s3:GetPublicAccessBlock\",\
        \"s3:GetAccountPublicAccessBlock\",\
        \"s3:PutBucketOwnershipControls\",\
        \"s3:GetBucketOwnershipControls\"\
      ],\
      \"Resource\": [\
        \"arn:aws:s3:::${SAM_MANAGED_BUCKET}/*\",\
        \"arn:aws:s3:::${SAM_MANAGED_BUCKET}\",\
        \"arn:aws:s3:::*${LOWERCASE_APPLICATION_NAME}/*\",\
        \"arn:aws:s3:::*${LOWERCASE_APPLICATION_NAME}\"\
      ]\
    },\
    {\
      \"Sid\": \"AllowBasicS3Resources\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"s3:CreateBucket\",\
        \"s3:DeleteBucket\",\
        \"s3:PutBucketTagging\",\
        \"s3:GetBucketPolicy\",\
        \"s3:PutBucketPolicy\",\
        \"s3:DeleteBucketPolicy\",\
        \"s3:PutBucketPublicAccessBlock\",\
        \"s3:GetAccountPublicAccessBlock\"\
      ],\
      \"Resource\": [\
        \"*\"\
      ]\
    }\
  ]\
}" | jq -c '.')

# Least Access Needed for Lambda
LAMBDA_POLICY=$(echo "\
{\
  \"Version\": \"2012-10-17\",\
  \"Statement\": [\
    {\
      \"Sid\": \"AllowBasicLambda\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"lambda:CreateFunction\",\
        \"lambda:GetFunction\",\
        \"lambda:UpdateFunctionConfiguration\",\
        \"lambda:UpdateFunctionCode\",\
        \"lambda:DeleteFunction\",\
        \"lambda:ListTags\",\
        \"lambda:TagResource\",\
        \"lambda:UntagResource\",\
        \"lambda:AddPermission\",\
        \"lambda:RemovePermission\",\
        \"lambda:GetLayerVersion\",\
        \"lambda:ListLayerVersions\",\
        \"lambda:PublishLayerVersion\",\
        \"lambda:DeleteLayerVersion\",\
        \"lambda:AddLayerVersionPermission\",\
        \"lambda:RemoveLayerVersionPermission\",\
        \"lambda:PutFunctionEventInvokeConfig\",\
        \"lambda:UpdateFunctionEventInvokeConfig\",\
        \"lambda:DeleteFunctionEventInvokeConfig\"\
      ],\
      \"Resource\": [\
        \"arn:aws:lambda:*:${AWS_ACCOUNT_ID}:layer:${APPLICATION_NAME}*:*\",\
        \"arn:aws:lambda:*:${AWS_ACCOUNT_ID}:layer:${APPLICATION_NAME}*\",\
        \"arn:aws:lambda:*:${AWS_ACCOUNT_ID}:function:${APPLICATION_NAME}*${ENVIRONMENT}\",\
        \"arn:aws:lambda:*:${AWS_ACCOUNT_ID}:function:${APPLICATION_NAME}*${ENVIRONMENT}:*\"\
      ]\
    }\
  ]\
}" | jq -c '.')

# Least Access Needed for IAM - Always Needed
IAM_POLICY=$(echo "\
{\
  \"Version\": \"2012-10-17\",\
  \"Statement\": [\
    {\
      \"Sid\": \"AllowBasicIAM\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"iam:PassRole\",\
        \"iam:AttachRolePolicy\",\
        \"iam:DetachRolePolicy\",\
        \"iam:TagRole\",\
        \"iam:UntagRole\",\
        \"iam:TagPolicy\",\
        \"iam:UntagPolicy\",\
        \"iam:CreateRole\",\
        \"iam:GetRole\",\
        \"iam:UpdateRole\",\
        \"iam:UpdateAssumeRolePolicy\",\
        \"iam:DeleteRole\",\
        \"iam:GetRolePolicy\",\
        \"iam:PutRolePolicy\",\
        \"iam:DeleteRolePolicy\",\
        \"iam:GetOpenIDConnectProvider\",\
        \"iam:UpdateOpenIDConnectProvider\",\
        \"iam:DeleteOpenIDConnectProvider\",\
        \"iam:UpdateOpenIDConnectProviderThumbprint\",\
        \"iam:AddClientIDToOpenIDConnectProvider\",\
        \"iam:RemoveClientIDFromOpenIDConnectProvider\",\
        \"iam:AddRoleToInstanceProfile\",\
        \"iam:CreateInstanceProfile\",\
        \"iam:DeleteInstanceProfile\",\
        \"iam:ListInstanceProfileTags\",\
        \"iam:ListInstanceProfilesForRole\",\
        \"iam:RemoveRoleFromInstanceProfile\",\
        \"iam:TagInstanceProfile\",\
        \"iam:UntagInstanceProfile\",\
        \"iam:GetInstanceProfile\"\
      ],\
      \"Resource\": [\
        \"arn:aws:iam::${AWS_ACCOUNT_ID}:role/${APPLICATION_NAME}*\",\
        \"arn:aws:iam::${AWS_ACCOUNT_ID}:role/${APPLICATION_NAME}EC2Role${ENVIRONMENT}\",\
        \"arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${APPLICATION_NAME}*\",\
        \"arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ROOT}\",\
        \"arn:aws:iam::${AWS_ACCOUNT_ID}:instance-profile/${APPLICATION_NAME}EC2InstanceProfile${ENVIRONMENT}\"\
      ]\
    },\
    {\
      \"Sid\": \"AllowBasicIAMResources\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"iam:ListInstanceProfiles\"\
      ],\
      \"Resource\": [\
        \"*\"\
      ]\
    }\
  ]\
}" | jq -c '.')

# Least Access Needed for EventBridge
EVENTBRIDGE_POLICY=$(echo "\
{\
  \"Version\": \"2012-10-17\",\
  \"Statement\": [\
    {\
      \"Sid\": \"AllowBasicEventBridge\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"events:TagResource\",\
        \"events:UntagResource\",\
        \"events:CreateEventBus\",\
        \"events:DeleteEventBus\",\
        \"events:PutPermission\",\
        \"events:RemovePermission\",\
        \"events:PutEvents\",\
        \"events:DescribeEventBus\",\
        \"events:DescribeRule\",\
        \"events:PutTargets\",\
        \"events:RemoveTargets\",\
        \"events:PutRule\",\
        \"events:DeleteRule\",\
        \"events:CreateArchive\",\
        \"events:DescribeArchive\",\
        \"events:UpdateArchive\",\
        \"events:DeleteArchive\"\
      ],\
      \"Resource\": [\
        \"arn:aws:events:${REGION}:${AWS_ACCOUNT_ID}:rule/${APPLICATION_NAME}*\",\
        \"arn:aws:events:${REGION}:${AWS_ACCOUNT_ID}:archive/${APPLICATION_NAME}Archive${ENVIRONMENT}\",\
        \"arn:aws:events:${REGION}:${AWS_ACCOUNT_ID}:event-bus/default\"\
      ]\
    },\
    {\
      \"Sid\": \"AllowBasicEventBridgeResources\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"events:ListArchives\"\
      ],\
      \"Resource\": [\
        \"*\"\
      ]\
    }\
  ]\
}" | jq -c '.')

# Least Access Needed for SQS
SQS_POLICY=$(echo "\
{\
  \"Version\": \"2012-10-17\",\
  \"Statement\": [\
    {\
      \"Sid\": \"AllowBasicSQS\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"sqs:createqueue\",\
        \"sqs:getqueueattributes\",\
        \"sqs:setqueueattributes\",\
        \"sqs:listqueuetags\",\
        \"sqs:tagqueue\",\
        \"sqs:untagqueue\",\
        \"sqs:deletequeue\"\
      ],\
      \"Resource\": [\
        \"arn:aws:sqs:${REGION}:${AWS_ACCOUNT_ID}:${APPLICATION_NAME}DeadLetterQueue${ENVIRONMENT}\"\
      ]\
    }\
  ]\
}" | jq -c '.')

# Least Access Needed for SSM
SSM_POLICY=$(echo "\
{\
  \"Version\": \"2012-10-17\",\
  \"Statement\": [\
    {\
      \"Sid\": \"AllowBasicSSM\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"ssm:SendCommand\"\
      ],\
      \"Resource\": [\
        \"arn:aws:ec2:${REGION}:${AWS_ACCOUNT_ID}:instance/*\",\
        \"arn:aws:ssm:${REGION}::document/AWS-RunShellScript\"\
      ]\
    },\
    {\
      \"Sid\": \"AllowSSMGetCommandInvocation\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"ssm:GetCommandInvocation\"\
      ],\
      \"Resource\": [\
        \"arn:aws:ssm:${REGION}:${AWS_ACCOUNT_ID}:*\"\
      ]\
    }\
  ]\
}" | jq -c '.')

# Least Access Needed for VPC
VPC_POLICY=$(echo "\
{\
  \"Version\": \"2012-10-17\",\
  \"Statement\": [\
    {\
      \"Sid\": \"AllowBasicVPC\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"ec2:RunInstances\",\
        \"ec2:CreateSecurityGroup\",\
        \"ec2:DeleteSecurityGroup\"\
      ],\
      \"Resource\": [\
        \"arn:aws:ec2:${REGION}:${AWS_ACCOUNT_ID}:${APPLICATION_NAME}${ENVIRONMENT}/*\"\
      ]\
    },\
    {\
      \"Sid\": \"AllowBasicVPCResources\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"s3:CreateBucket\",\
        \"s3:GetAccountPublicAccessBlock\"\
      ],\
      \"Resource\": [\
        \"*\"\
      ]\
    }\
  ]\
}" | jq -c '.')

# TODO: Configure correct image id, run instances
# Least Access Needed for EC2
EC2_POLICY=$(echo "\
{\
  \"Version\": \"2012-10-17\",\
  \"Statement\": [\
    {\
      \"Sid\": \"AllowBasicEC2\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"ec2:CreateLaunchTemplate\",\
        \"ec2:CreateLaunchTemplateVersion\",\
        \"ec2:DeleteLaunchTemplate\",\
        \"ec2:DeleteLaunchTemplateVersions\",\
        \"ec2:GetLaunchTemplateData\",\
        \"ec2:ModifyLaunchTemplate\",\
        \"ec2:CreateTags\",\
        \"ec2:DeleteTags\",\
        \"ec2:DescribeImageAttribute\",\
        \"autoscaling:SetDesiredCapacity\",\
        \"autoscaling:CreateAutoScalingGroup\",\
        \"autoscaling:DeleteAutoScalingGroup\",\
        \"autoscaling:UpdateAutoScalingGroup\",\
        \"autoscaling:TerminateInstanceInAutoScalingGroup\",\
        \"autoscaling:CreateOrUpdateTags\",\
        \"autoscaling:DeleteTags\"\
      ],\
      \"Resource\": [\
        \"arn:aws:ec2:${REGION}:${AWS_ACCOUNT_ID}:launch-template/*\",\
        \"arn:aws:ec2:${REGION}:${AWS_ACCOUNT_ID}:instance/*\",\
        \"arn:aws:autoscaling:${REGION}:${AWS_ACCOUNT_ID}:autoScalingGroup:*:autoScalingGroupName/${APPLICATION_NAME}AutoScalingGroup*DEV\"\
      ]\
    },\
    {\
      \"Sid\": \"AllowBasicEC2Resources\",\
      \"Effect\": \"Allow\",\
      \"Action\": [\
        \"ec2:DescribeLaunchTemplates\",\
        \"ec2:DescribeLaunchTemplateVersions\",\
        \"ec2:DescribeAvailabilityZones\",\
        \"ec2:DescribeAccountAttributes\",\
        \"ec2:DescribeSubnets\",\
        \"ec2:DescribeImages\",\
        \"ec2:RunInstances\",\
        \"autoscaling:DescribeAutoScalingGroups\",\
        \"autoscaling:DescribeTags\",\
        \"autoscaling:DescribeScalingActivities\"\
      ],\
      \"Resource\": [\
        \"*\"\
      ]\
    }\
  ]\
}" | jq -c '.')

POLICIES=("S3 ${S3_POLICY}" "CloudFormation ${CLOUD_FORMATION_POLICY}" "IAM ${IAM_POLICY}" "CloudWatch ${CLOUDWATCH_POLICY}")
for ROLE_ARG in "${ROLE_ARGS[@]}"; do
  ROLE_ARG="${ROLE_ARG//\"/}"
  if [ -n "$ROLE_ARG" ] && [ "$ROLE_ARG" != " " ]; then
    case "$ROLE_ARG" in
      'ec2') POLICIES+=("EC2 ${EC2_POLICY}") ;;
      'eventbridge') POLICIES+=("EventBridge ${EVENTBRIDGE_POLICY}") ;;
      'lambda') POLICIES+=("Lambda ${LAMBDA_POLICY}") ;;
      'sqs') POLICIES+=("SQS ${SQS_POLICY}") ;;
      'ssm') POLICIES+=("SSM ${SSM_POLICY}") ;;
      'vpc') POLICIES+=("VPC ${VPC_POLICY}") ;;
      *) echo -e "${X} The Role Argument ${BOLD}${RED}${ROLE_ARG}${RESET} is not valid" ;;
    esac
  fi
done
# Adding All Policies to an Array to Make Creation Simpler
#POLICIES=("EC2 ${EC2_POLICY}")
# "EventBridge ${EVENTBRIDGE_POLICY}" "Lambda ${LAMBDA_POLICY}" "SQS ${SQS_POLICY}" "SSM ${SSM_POLICY}" "VPC ${VPC_POLICY}"

# Helper Variables for Printing to the Terminal
SHOULD_FAIL=0
FAILED=0

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