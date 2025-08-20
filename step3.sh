source init_envs
source env_vars

aws s3 mb s3://$DEPLOY_MODEL_S3_BUCKET --region ${AWS_REGION}

aws iam put-role-policy \
  --role-name ${EXECUTION_ROLE##*/} \
  --policy-name S3ReadModelAccess \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:ListBucket","s3:GetObject"],"Resource":["arn:aws:s3:::*","arn:aws:s3:::*/*"]}]}'

cat <<EOF> /tmp/s3accesspolicy.json
{
   "Version": "2012-10-17",
   "Statement": [
        {
            "Sid": "MountpointFullBucketAccess",
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket"
            ],
            "Resource": [
                "*"
            ]
        },
        {
            "Sid": "MountpointFullObjectAccess",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:AbortMultipartUpload",
                "s3:DeleteObject"
            ],
            "Resource": [
                "*"
            ]
        }
   ]
}
EOF

s3_policy_ts=$(date +%Y%m%d_%H%M%S)
# aws iam create-policy \
#     --policy-name S3MountpointAccessPolicy-$EKS_CLUSTER_NAME \
#     --policy-document file:///tmp/s3accesspolicy.json

# 'Policy.{PolicyName:PolicyName,Arn:Arn}'

s3_policy_arn=$(aws iam create-policy \
    --policy-name S3MountpointAccessPolicy-$EKS_CLUSTER_NAME \
    --policy-document file:///tmp/s3accesspolicy.json \
    --query 'Policy.Arn' \
    --output text)

ROLE_NAME=SM_HP_S3_CSI_ROLE_$EKS_CLUSTER_NAME
# POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName==\`S3MountpointAccessPolicy-$s3_policy_ts\`]" | jq '.[0].Arn' |  tr -d '"')

eksctl create iamserviceaccount \
    --name s3-csi-driver-sa \
    --namespace kube-system \
    --override-existing-serviceaccounts \
    --cluster $EKS_CLUSTER_NAME \
    --attach-policy-arn $s3_policy_arn \
    --approve \
    --role-name $ROLE_NAME \
    --region $AWS_REGION \
    --role-only

# kubectl annotate serviceaccount s3-csi-driver-sa -n kube-system eks.amazonaws.com/role-arn=arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME --overwrite


ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME  --query 'Role.Arn' --output text)
eksctl create addon --name aws-mountpoint-s3-csi-driver --cluster $EKS_CLUSTER_NAME --service-account-role-arn $ROLE_ARN --force

cat <<EOF> /tmp/pv_s3.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: s3-pv
spec:
  capacity:
    storage: 1200Gi # ignored, required
  accessModes:
    - ReadWriteMany # supported options: ReadWriteMany / ReadOnlyMany
  mountOptions:
    - allow-delete
    - region $AWS_REGION
  csi:
    driver: s3.csi.aws.com # required
    volumeHandle: s3-csi-driver-volume
    volumeAttributes:
      bucketName: $DEPLOY_MODEL_S3_BUCKET
EOF

kubectl apply -f /tmp/pv_s3.yaml

cat <<EOF> /tmp/pvc_s3.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: s3-claim
spec:
  accessModes:
    - ReadWriteMany # supported options: ReadWriteMany / ReadOnlyMany
  storageClassName: "" # required for static provisioning
  resources:
    requests:
      storage: 1200Gi # ignored, required
  volumeName: s3-pv
EOF

kubectl apply -f /tmp/pvc_s3.yaml

# sleep 30
