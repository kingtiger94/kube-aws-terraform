#!/bin/bash -e
#
# Copyright 2014, 2017 Xu Wang, Xueshan Feng
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# This is a coreos-cluster-cloudinit bootstrap script. It is passed in as 'user-data' file during the machine build. 
# Then the script is executed to download the CoreOs "cloud-config.yaml" file  and "initial-cluster" files.
# These files  will configure the system to join the CoreOS cluster. The second stage cloud-config.yaml can 
# be changed to allow system configuration changes without having to rebuild the system. All it takes is a reboot.
# If this script changes, the machine will need to be rebuild (user-data change)
# 
# AWS doc: http://docs.aws.amazon.com/general/latest/gr/signature-version-4.html.
# Reference: http://czak.pl/2015/09/15/s3-rest-api-with-curl.html

# s3get.sh <bucket> <filePath> <destination>
# e.g. ./s3get.sh my-s3bucket config/my-configuration.conf /etc/my-configuration.conf

# Initilize variables
init_vars() {

  # For signature v4 signning purpose
  timestamp=$(date -u "+%Y-%m-%d %H:%M:%S")
  isoTimpstamp=$(date -ud "${timestamp}" "+%Y%m%dT%H%M%SZ")
  dateScope=$(date -ud "${timestamp}" "+%Y%m%d")
  #dateHeader=$(date -ud "${timestamp}" "+%a, %d %h %Y %T %Z") 
  signedHeaders="host;x-amz-content-sha256;x-amz-date;x-amz-security-token"
  service="s3"

  # Get instance auth token from meta-data
  region=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document/ | jq -r '.region')
  roleProfile=$(curl -s http://169.254.169.254/latest/meta-data/iam/info \
        | jq -r '.InstanceProfileArn' \
        | sed  's#.*instance-profile/##')
  accountId=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .'accountId')

  # KeyId, secret, and token
  accessKeyId=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/$roleProfile | jq -r '.AccessKeyId')
  secretAccessKey=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/$roleProfile | jq -r '.SecretAccessKey')
  stsToken=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/$roleProfile | jq -r '.Token')

  # Empty payload hash (we are getting content, not upload)
  payload=$(sha256_hash /dev/null)

  # Host header 
  hostHeader="${bucket}.s3-${region}.amazonaws.com"

  # Curl options
  opts="-v -L --fail --retry 5 --retry-delay 3 --silent --show-error"
  # Curl logs
  curlLog=/tmp/curlLog.log
}

# Untilities
hmac_sha256() {
  key="$1"
  data="$2"
  echo -n "$data" | openssl dgst -sha256  -mac HMAC -macopt "$key" | sed 's/^.* //'
}
sha256_hash() {
  echo $(sha256sum "$1" | awk '{print $1}')
}

# Authorization: <Algorithm> Credential=<Access Key ID/Scope>, SignedHeaders=<SignedHeaders>, Signature=<Signature>
# Virtual Hosted-style API: http://docs.aws.amazon.com/AmazonS3/latest/dev/VirtualHosting.html#VirtualHostingLimitations
# Using Example Virtual Hosted–Style Method - this will default to US East and cause a temporary redirect (307) 
#     https://${bucket}.s3.amazonaws.com/${filePath}
#    Host: ${bucket}.s3.amazonaws.com" \
# This should avoid the redirect
#  Virtual Hosted–Style Method for a Bucket in a Region Other Than US East
curl_get() {
  curl $opts -H "Host: ${hostHeader}" \
     -H "Authorization: AWS4-HMAC-SHA256 \
	Credential=${accessKeyId}/${dateScope}/${region}/s3/aws4_request, \
	SignedHeaders=${signedHeaders}, Signature=${signature}" \
     -H "x-amz-content-sha256: ${payload}" \
     -H "x-amz-date: ${isoTimpstamp}" \
     -H "x-amz-security-token:${stsToken}" \
     https://${hostHeader}/${filePath}
}

# 1. Canonical request(note Query string is empty, payload is empty for download).
#<HTTPMethod>\n #<CanonicalURI>\n #<CanonicalQueryString>\n #<CanonicalHeaders>\n #<SignedHeaders>\n #<HashedPayload>
#echo "/${bucket}/${cloudConfigYaml}"
canonical_request() {
  echo "GET"
  echo "/${filePath}"
  echo ""
  echo host:${hostHeader}
  echo "x-amz-content-sha256:${payload}"
  echo "x-amz-date:${isoTimpstamp}"
  echo "x-amz-security-token:${stsToken}"
  echo ""
  echo "${signedHeaders}"
  printf "${payload}"
}
# 2. String to sign
string_to_sign() {
  echo "AWS4-HMAC-SHA256"
  echo "${isoTimpstamp}"
  echo "${dateScope}/${region}/s3/aws4_request"
  printf "$(canonical_request | sha256_hash -)"
}
# 3. Signing key
signing_key() {
  dateKey=$(hmac_sha256 key:"AWS4$secretAccessKey" $dateScope)
  dateRegionKey=$(hmac_sha256 hexkey:$dateKey $region)
  dateRegionServiceKey=$(hmac_sha256 hexkey:$dateRegionKey $service)
  signingKey=$(hmac_sha256 hexkey:$dateRegionServiceKey "aws4_request")
  printf "${signingKey}"
}

# Initlize varables
bucket=$1
filePath=$2
destination=$3
if [[ -z $bucket ]] || [[ -z $filePath ]] || [[ -z $destination ]];
then
  echo "Missing parameters."
  echo "Usage: ./s3get.sh bucket filePath destination"
  exit 1
fi
init_vars

path=$(dirname $destination)
[ -s "$path" ] && mkdir -p $path

signature=$(string_to_sign | openssl dgst -sha256 -mac HMAC -macopt hexkey:$(signing_key) | awk '{print $NF}')
curl_get 2>> ${curlLog} > ${destination}

