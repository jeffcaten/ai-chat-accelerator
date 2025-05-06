#!/bin/bash
# usage: ./deploy.sh app-name linux/amd64
set -e

export APP=$1
export ARCH=$2

export VERSION=$(cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | fold -w 50 | head -n 1)

# login to ECR
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY=${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com
echo "logging into to ecr: ${REGISTRY}"
aws ecr get-login-password | docker login --username AWS --password-stdin ${REGISTRY}

# build and push image
IMAGE=${REGISTRY}/${APP}:${VERSION}
echo ""
echo "building and pushing image: ${IMAGE}"
docker build --platform ${ARCH} -t ${IMAGE} .
docker push ${IMAGE}

# deploy new image to ECS
CLUSTER=${APP}
SERVICE=${APP}
TASK_FAMILY=${APP}

# create a new task definition
echo ""
echo "creating new task definition for image: ${IMAGE}"
TASK_DEF=$(aws ecs describe-task-definition --task-definition ${TASK_FAMILY})
NEW_TASK_DEF=$(echo $TASK_DEF | jq --arg IMAGE "$IMAGE" '.taskDefinition |
	.containerDefinitions[0].image = $IMAGE |
	del(.taskDefinitionArn) | del(.revision) | del(.status) |
	del(.requiresAttributes) | del(.compatibilities) |
	del(.registeredAt) | del(.registeredBy)
')

echo "$TASK_DEF" > /tmp/NEW_TASK_DEF.json

PATCHER_IMAGE="trendmicrocloudone/ecs-taskdef-patcher:2.6.5"

#run the Docker container to patch the task definition
docker run --rm \
	-v /tmp:/mnt \
	$PATCHER_IMAGE \
	-i "/mnt/NEW_TASK_DEF.json" \
	-o "/mnt/NEW_TASK_DEF_INJECTED.json"
 


# register new task definition
REGISTRATION=$(aws ecs register-task-definition --cli-input-json "/tmp/NEW_TASK_DEF_INJECTED.json")
REV=$(echo ${REGISTRATION} | jq '.taskDefinition.revision')
echo ""
echo "registered revision: ${REV}"

# tell service to use it
aws ecs update-service --cluster ${CLUSTER} --service ${SERVICE} \
	--task-definition ${TASK_FAMILY}:${REV}
echo ""
echo "service updated to use the new task definition with image: ${IMAGE}"

echo "waiting for service to finish deployment..."
aws ecs wait services-stable --cluster ${CLUSTER} --services ${SERVICE}

echo ""
echo "deployment complete"
