#!/bin/bash

# aws eks create-access-entry \
#  --cluster-name $EKS_CLUSTER_NAME \
#  --principal-arn arn:aws:iam::xxxxxxxxxxxx:role/ExampleRole \
#  --type STANDARD \
#  --region $AWS_REGION

source init_envs

execute_aws_command() {
    local command="$1"
    
    OUTPUT=$(eval "$command" 2>&1)
    EXIT_CODE=$?
    
    if [ $EXIT_CODE -eq 0 ]; then
        echo "$OUTPUT"
    else
        echo "[EXECUTING] $command"
        echo "[WARNING] $OUTPUT"
    fi
    
    return $EXIT_CODE
}

curl -O https://raw.githubusercontent.com/aws-samples/awsome-distributed-training/refs/heads/main/1.architectures/7.sagemaker-hyperpod-eks/create_config.sh 

chmod +x create_config.sh

./create_config.sh
rm create_config.sh

source env_vars
aws eks update-kubeconfig --name $EKS_CLUSTER_NAME --region $AWS_REGION

eksctl utils associate-iam-oidc-provider \
    --region ${AWS_REGION} \
    --cluster ${EKS_CLUSTER_NAME} \
    --approve

curl -o /tmp/iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.10.0/docs/install/iam_policy.json

execute_aws_command "aws iam create-policy \
      --policy-name AWSLoadBalancerControllerIAMPolicy \
      --policy-document file:///tmp/iam-policy.json"


curl -o /tmp/alb-iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.0/docs/install/iam_policy.json

policy_arn="arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"

execute_aws_command "aws iam delete-policy --policy-arn $policy_arn"

execute_aws_command "aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file:///tmp/alb-iam-policy.json"


execute_aws_command "eksctl create iamserviceaccount \
--cluster=${EKS_CLUSTER_NAME} \
--namespace=kube-system \
--name=aws-load-balancer-controller \
--attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
--override-existing-serviceaccounts \
--region=${AWS_REGION} \
--approve"

# kubectl delete serviceaccount -n kube-system aws-load-balancer-controller


## Add eks helm charts
helm repo add eks https://aws.github.io/eks-charts
## Make sure you update to the latest version
helm repo update eks

execute_aws_command "helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=${HP_CLUSTER_NAME} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set vpcId=${VPC_ID} \
  --set region=${AWS_REGION}"

# kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system
# kubectl get deployment -n kube-system aws-load-balancer-controller
# kubectl logs -n kube-system aws-load-balancer-controller-86799fd799-gnf8h --tail=10

helm ls -n kube-system

PUBLIC_SUBNETS=$(aws ec2 describe-subnets --filters "[ {\"Name\":\"vpc-id\",\"Values\":[\"${VPC_ID}\"]}, {\"Name\":\"map-public-ip-on-launch\",\"Values\":[\"true\"]} ]" --query 'Subnets[*].{SubnetId:SubnetId}' --output text)
for SUBNET_ID in $PUBLIC_SUBNETS; do
    aws ec2 create-tags --resources $SUBNET_ID --tags Key=kubernetes.io/role/elb,Value=1
done
