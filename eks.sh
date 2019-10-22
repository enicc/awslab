export AWS_ACCESS_KEY_ID=
export AWS_SECRET_ACCESS_KEY=' '
export AWS_DEFAULT_REGION=
# should handle no default
export SSH_PRIV_KEY=
# should clarify key is filename (not path) only
export SSH_PUB_KEY=
# should clarify key is filename (not path) only
export EC2_KEY_NAME=
# should have option to use an existing one

export GITLAB_RELEASE_NAME=gitlab
export EKS_CLUSTER_NAME=ed1
export EKS_DEFAULT_NODEGROUP_NAME=defaultnodes
export EKS_DEFAULT_NODEGROUP_TYPE=t3.medium
export EKS_DEFAULT_NODEGROUP_COUNT=2
export EKS_2NDARY_NODEGROUP_NAME=2ndarynodes
export EKS_2NDARY_NODEGROUP_TYPE=t3.medium
export EKS_2NDARY_NODEGROUP_COUNT=3

# attempt to determine if we are in LA Cloud sandbox
awsid=$(aws sts get-caller-identity | jq -r '.Arn')
if $(echo $awsid | grep 'cloud_user' > /dev/null) ; then export la_cloud_user=true; fi

# upload an existing public key to use with ssh
ssh-keygen -y -f ~/.ssh/$SSH_PRIV_KEY > ~/.ssh/$SSH_PUB_KEY
aws ec2 import-key-pair --key-name $EC2_KEY_NAME --public-key-material file://~/.ssh/$SSH_PUB_KEY

#work to make eksctl consumable from terraform / able to output terraform:
# https://github.com/weaveworks/eksctl/issues/813
# https://github.com/weaveworks/eksctl/issues/1094

#why here? jq -r '.host_components | map(.HostRoles.host_name) | join(",")'

AWS_AZS=($(aws ec2 describe-availability-zones --region $AWS_DEFAULT_REGION | jq -r '.[][0,1,2].ZoneName'))
AWS_AZS=$(echo $AWS_AZS | sed 's/ /,/g')
export AWS_AZS
echo $AWS_AZS

# spot capacity is difficult (impossible?) to provision on command line
# https://docs.aws.amazon.com/autoscaling/ec2/APIReference/API_InstancesDistribution.html
# https://eksctl.io/usage/spot-instances/
# for this reason build the cluster config file:
cat <<EOT >> cluster-config-$EKS_CLUSTER_NAME.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: $EKS_CLUSTER_NAME
  region: $AWS_DEFAULT_REGION
nodeGroups:
  - name: $EKS_DEFAULT_NODEGROUP_NAME
    minSize: 3
    maxSize: 9
    instancesDistribution:
      maxPrice: 0.017
      instanceTypes: ["t3.small", "$EKS_DEFAULT_NODEGROUP_TYPE"] # At least two instance types should be specified
      onDemandBaseCapacity: 3
      onDemandPercentageAboveBaseCapacity: 0
      spotInstancePools: 2
    ssh:
      publicKeyPath: $EC2_KEY_NAME
EOT

# eksctl create cluster -f cluster-config-$EKS_CLUSTER_NAME.yaml
# we don't use this - how to specify zones in config file?

#for LA cloud sandbox needs region to be us-east-1 & nodetype to be t2 or t3 medium
#https://support.linuxacademy.com/hc/en-us/articles/360025783132-What-can-I-do-with-the-Cloud-Playground-AWS-Sandbox-
date
time eksctl create cluster \
  --region "$AWS_DEFAULT_REGION" \
  --zones "$AWS_AZS" \
  --name "$EKS_CLUSTER_NAME" \
  --without-nodegroup
date

eksctl create nodegroup --config-file=cluster-config-$EKS_CLUSTER_NAME.yaml

# commented as this action replaced with the above
#for LA cloud sandbox needs region to be us-east-1 & nodetype to be t2 or t3 medium
#https://support.linuxacademy.com/hc/en-us/articles/360025783132-What-can-I-do-with-the-Cloud-Playground-AWS-Sandbox-
#date
#time eksctl create cluster \
#  --region "$AWS_DEFAULT_REGION" \
#  --zones "$AWS_AZS" \
#  --name "$EKS_CLUSTER_NAME" \
#  --node-type "$EKS_DEFAULT_NODEGROUP_TYPE" \
#  --nodes "$EKS_DEFAULT_NODEGROUP_COUNT" \
#  --nodegroup-name "$EKS_DEFAULT_NODEGROUP_NAME" \
#  --ssh-access --ssh-public-key "$EC2_KEY_NAME"
#date

# obsolete functionality?
# cluster=$(eksctl get cluster -o json | jq -r '.[].name'); nodegroup=$(eksctl get nodegroup -o json --cluster $cluster | jq -r '.[].Name'); eksctl scale nodegroup $nodegroup  -N 4 --cluster $cluster
#nodegroup=$(eksctl get nodegroup \
#  -o json \
#  --cluster $EKS_CLUSTER_NAME | jq -r '.[].Name')

# create 2ndary nodegroup
#time eksctl create nodegroup "$EKS_2NDARY_NODEGROUP_NAME" \
#  --nodes "$EKS_2NDARY_NODEGROUP_COUNT" \
#  --cluster "$EKS_CLUSTER_NAME" \
#  --node-type "$EKS_2NDARY_NODEGROUP_TYPE" \
#  --ssh-access --ssh-public-key "$EC2_KEY_NAME" \

# scale existing nodegroup
#eksctl scale nodegroup $EKS_DEFAULT_NODEGROUP_NAME \
#  --nodes $EKS_DEFAULT_NODEGROUP_COUNT \
#  --cluster $EKS_CLUSTER_NAME

# CHECK: re-source the env, which for me is just
#seems unnecessary .

# does local tiller sometimes get corrupted?
helm tiller start
helm repo add gitlab https://charts.gitlab.io/
helm repo update
helm search -l gitlab/gitlab

export DNS_ZONE_ID=$(aws route53 list-hosted-zones | jq -r '.HostedZones[0].Id' | sed 's/\/hostedzone\///')
export DNS_ZONE_NAME=$(aws route53 list-hosted-zones | jq -r '.HostedZones[0].Name' | sed 's/.$//')


helm upgrade --install $GITLAB_RELEASE_NAME gitlab/gitlab --timeout 600 --set global.hosts.domain=$DNS_ZONE_NAME --set global.edition=ce --set certmanager-issuer.email=me@example.com --set-string global.ingress.annotations."nginx.ingress.kubernetes.io/ssl-redirect"=false

helm upgrade --install $GITLAB_RELEASE_NAME gitlab/gitlab --timeout 600 --set global.hosts.domain=$DNS_ZONE_NAME --set global.edition=ce --set certmanager-issuer.email=me@example.com --set-string global.ingress.annotations."nginx.ingress.kubernetes.io/ssl-redirect"=true

# should consider another subdomain when used in shared aws account(s)
export GITLAB_LB=$(kubectl get service gitlab-nginx-ingress-controller -ojson | jq -r '.status.loadBalancer.ingress[0].hostname')

export DNS_RECORD_TEMPLATE='{"Comment": "CREATE/DELETE/UPSERT a record ","Changes": [{"Action": "CREATE","ResourceRecordSet": {"Name": "RECORD_TO_CREATE","Type": "CNAME","TTL": 300,"ResourceRecords": [{ "Value": "TARGET_RECORD"}]}}]}'

export DNS_RECORD_GITLAB=$DNS_RECORD_TEMPLATE
export DNS_RECORD_GITLAB=$(echo $DNS_RECORD_GITLAB | sed "s/RECORD_TO_CREATE/gitlab.$DNS_ZONE_NAME/")
export DNS_RECORD_GITLAB=$(echo $DNS_RECORD_GITLAB | sed "s/TARGET_RECORD/$GITLAB_LB/")

export DNS_RECORD_MINIO=$DNS_RECORD_TEMPLATE
export DNS_RECORD_MINIO=$(echo $DNS_RECORD_MINIO | sed "s/RECORD_TO_CREATE/minio.$DNS_ZONE_NAME/")
export DNS_RECORD_MINIO=$(echo $DNS_RECORD_MINIO | sed "s/TARGET_RECORD/$GITLAB_LB/")

export DNS_RECORD_REGISTRY=$DNS_RECORD_TEMPLATE
export DNS_RECORD_REGISTRY=$(echo $DNS_RECORD_REGISTRY | sed "s/RECORD_TO_CREATE/registry.$DNS_ZONE_NAME/")
export DNS_RECORD_REGISTRY=$(echo $DNS_RECORD_REGISTRY | sed "s/TARGET_RECORD/$GITLAB_LB/")


aws route53 change-resource-record-sets --hosted-zone-id $DNS_ZONE_ID --change-batch "$DNS_RECORD_GITLAB"
aws route53 change-resource-record-sets --hosted-zone-id $DNS_ZONE_ID --change-batch "$DNS_RECORD_MINIO"
aws route53 change-resource-record-sets --hosted-zone-id $DNS_ZONE_ID --change-batch "$DNS_RECORD_REGISTRY"

echo https://gitlab.$DNS_ZONE_NAME/
kubectl get secret $GITLAB_RELEASE_NAME-gitlab-initial-root-password -ojsonpath='{.data.password}' | base64 --decode ; echo

jx install --git-provider-url=https://$DNS_RECORD_GITLAB --git-username=root --git-provider-kind=gitlab --provider=eks --static-jenkins=true


helm delete gitlab --purge
kubectl config unset contexts.
kubectl config unset clusters.fabulous-mushroom-1571491275.us-east-1.eksctl.io
kubectl config unset users.cloud_user@fabulous-mushroom-1571491275.us-east-1.eksctl.io
