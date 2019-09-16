#!/bin/sh

sudo curl --silent --location -o /usr/local/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/v1.13.7/bin/linux/amd64/kubectl


sudo chmod +x /usr/local/bin/kubectl

sudo apt install -y jq gettext

for command in kubectl jq envsubst
  do
    which $command &>/dev/null && echo "$command in path" || echo "$command NOT FOUND"
  done
  
#https://eksworkshop.com/prerequisites/iamrole/
https://eksworkshop.com/prerequisites/workspaceiam/
