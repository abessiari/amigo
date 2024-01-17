#!/usr/bin/env bash

ansible --version
terraform --version
ls -l /tmp

# Prepare TF backend

s3_terraform_backend=$S3_TF_BACKEND
sed "s/REPLACE_ME_AMIGO_S3_STATE_STORE/$s3_terraform_backend/g" ./github/backend.tf.sample > aws/backend.tf

# Prepare config yaml files.
zone_id=`aws route53 list-hosted-zones-by-name --dns-name geneontology.io. --max-items 1  --query "HostedZones[].Id" --output text  | tr "/" " " | awk '{ print $2 }'`
amigo_record_name=cicd-test-amigo.geneontology.io
golr_record_name=cicd-test-golr.geneontology.io


aws route53 list-resource-record-sets --hosted-zone-id $zone_id  --max-items 1000 --query "ResourceRecordSets[].Name" | egrep "$amigo_record_name|$golr_record_name"
ret=$?

if [ "${ret}" == 0 ]
then
   echo "$amigo_record_name exists. Cannot proceed. Tray again"
   exit 1
fi

echo "Great. $amigo_record_name and $golr_record_name not found ... Proceeeding"

sed "s/REPLACE_ME_WITH_ZONE_ID/$zone_id/g" ./github/config-instance.yaml.sample > ./github/config-instance.yaml
sed -i "s/REPLACE_ME_WITH_AMIGO_RECORD_NAME/$amigo_record_name/g" ./github/config-instance.yaml
sed -i "s/REPLACE_ME_WITH_GOLR_RECORD_NAME/$golr_record_name/g" ./github/config-instance.yaml

s3_cert_bucket=$S3_CERT_BUCKET
ssl_certs="s3:\/\/$s3_cert_bucket\/geneontology.io.tar.gz"
sed "s/REPLACE_ME_WITH_URI/$ssl_certs/g" ./github/config-stack.yaml.sample > ./github/config-stack.yaml
sed -i "s/REPLACE_ME_WITH_AMIGO_RECORD_NAME/$amigo_record_name/g" ./github/config-stack.yaml
sed -i "s/REPLACE_ME_WITH_GOLR_RECORD_NAME/$golr_record_name/g" ./github/config-stack.yaml

# Provision aws instance and fast-api stack.

workspace=cicd-test-amigo

go-deploy -init --working-directory aws -verbose

go-deploy --working-directory aws -w $workspace -c ./github/config-instance.yaml -verbose

go-deploy --working-directory aws -w $workspace -output -verbose

go-deploy --working-directory aws -w $workspace -c ./github/config-stack.yaml -verbose

ret=1
total=${NUM_OF_RETRIES:=100}


for (( c=1; c<=$total; c++ ))
do
   # This should be redirected to https
   echo wget  --https-only --no-dns-cache http://$amigo_record_name/amigo/landing
   wget  --https-only --no-dns-cache http://$amigo_record_name/amigo/landing
   ret=$?
   if [ "${ret}" == 0 ]
   then
        echo "Success"
        break
   fi
   echo "Got exit_code=$ret.Going to sleep. Will retry.attempt=$c:total=$total"
   sleep 10
done

# Destroy
go-deploy --working-directory aws -w $workspace -destroy -verbose
rm -f ./github/config-instance.yaml ./github/config-stack.yaml landing $workspace-inventory.cfg $workspace.tfvars.json
exit $ret 
