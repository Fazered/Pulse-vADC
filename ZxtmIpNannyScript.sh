#!/bin/bash
#
# This is a heavily edited version of this script provided to us from Pulse:
# https://github.com/dkalintsev/vADC-CloudFormation/blob/master/Template/housekeeper.sh
#
# The purpose of this script is to add IPs on a secondary interface when the AWS interface IP
# limit has been reached. Run on a cron to ensure Traffic IPs are raised consistently. 
# - Add private IPs to vADC node to match the configured Traffic IPs Groups
#
# This script assumes there are 2 interfaces and the total number of Traffic IPs is lower than
# instance type limit minus the primary IPs.
# Jamie HEnderson - 25/04/2019

export PATH=$PATH:/usr/local/bin
export ZEUSHOME=/opt/zeus
logFile="/var/log/ZxtmIpNannyScript.log"
verbose="No" # Verbose = "Yes|No" - this controls whether we print extensive log messages as we go.

# Creating temp filenames to keep lists of running and clustered instances, and delta between the two.
rand_str=$(cat /dev/urandom | env LC_CTYPE=C tr -cd 'a-f0-9' | head -c 10)
resFName="/tmp/aws-out.$rand_str"
awscliLogF="/var/log/ZxtmIpNannyScript-out.log"
lockF=/tmp/ZxtmIpNannyScript.lock
leaveLock="0"

cleanup() {
    rm -f $resFName
    if [[ "$leaveLock" == "0" ]]; then
        rm -f $lockF
    fi
}

trap cleanup EXIT

logMsg() {
    if [[ "$verbose" =~ ^[Yy] ]]; then
        ts=$(date -u +%FT%TZ)
        echo "$ts $0[$$]: $*" >>$logFile
    fi
}

if [[ "$verbose" == "" ]]; then
    # there's no such thing as too much logging ;)
    verbose="Yes"
fi

if [[ -f $lockF ]]; then
    logMsg "001: Found lock file, exiting."
    leaveLock="1"
    exit 1
fi

# We need jq
which jq >/dev/null 2>&1
if [[ "$?" != "0" ]]; then
    wget https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64
    mv jq-linux64 /usr/local/bin/jq
    chmod +x /usr/local/bin/jq
fi

# We also need aws cli tools.
which aws >/dev/null 2>&1
if [[ "$?" != "0" ]]; then
    curl "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip" -o "awscli-bundle.zip"
    unzip awscli-bundle.zip
    ./awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws
    rm -rf awscli*
fi

#Get the AWS info for instance
myInstanceID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
region=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq .region -r)

# Execute AWS CLI command "safely": if error occurs - backoff exponentially
# If succeeded - return 0 and save output, if any, in $resFName
# Given this script runs once only, the "failure isn't an option".
# So this func will block till the cows come home.
#
safe_aws() {
    errCode=1
    backoff=0
    retries=0
    while [[ "$errCode" != "0" ]]; do
        let "backoff = 2**retries"
        if (($retries > 5)); then
            # Exceeded retry budget of 5.
            # Doing random sleep up to 45 sec, then back to try again.
            backoff=$RANDOM
            let "backoff %= 45"
            logMsg "004: safe_aws \"$*\" exceeded retry budget. Sleeping for $backoff second(s), then back to work.."
            sleep $backoff
            retries=0
            backoff=1
        fi
        aws $* >$resFName 2>>$awscliLogF
        errCode=$?
        if [[ "$errCode" != "0" ]]; then
            logMsg "005: AWS CLI returned error $errCode; sleeping for $backoff seconds.."
            sleep $backoff
            let "retries += 1"
        fi
        # We are assuming that aws cli produced valid JSON output or "".
        # While this is thing worth checking, we'll just leave it alone for now.
        # jq '.' $resFName > /dev/null 2>&1
        # errCode=$?
    done
    return 0
}

cleanup
touch $lockF

declare -a list

# Make sure this instance has the right number of private IP addresses - as many as there are
# Traffic IPs assigned to all TIP Groups
#
# Sample output we're working on:
# ip-10-8-2-115:~# echo 'TrafficIPGroups.getTrafficIPGroupNames' | /usr/bin/zcli
# ["Web VIP"]
# ip-10-8-2-115:~# echo 'TrafficIPGroups.getIPAddresses "Web VIP"' | /usr/bin/zcli
# ["13.54.192.46","54.153.152.253"]
#
# Get configured TIP Groups
tipArray=()
tmpArray=()
zresponse=$(echo 'TrafficIPGroups.getTrafficIPGroupNames' | /usr/bin/zcli)
if [[ "$?" == 0 ]]; then
    IFS='[]",' read -r -a tmpArray <<<"$zresponse"
    for i in "${!tmpArray[@]}"; do
        if [[ ${tmpArray[i]} != "" ]]; then
            tipArray+=("${tmpArray[i]}")
        fi
    done
    unset tmpArray
    s_list=$(echo ${tipArray[@]/%/,} | sed -e "s/,$//g")
    logMsg "025: Got Traffic IP groups: \"$s_list\""
else
    logMsg "026: Error getting Traffic IP Groups; perhaps none configured yet"
fi

numTIPs=0
for tipGroup in "${!tipArray[@]}"; do
    zresponse=$(echo "TrafficIPGroups.getIPAddresses \"${tipArray[$tipGroup]}\"" | /usr/bin/zcli)
    if [[ "$?" == 0 ]]; then
        IFS='[]",' read -r -a tmpArray <<<"$zresponse"
        for i in "${!tmpArray[@]}"; do
            if [[ ${tmpArray[i]} != "" ]]; then
                tipIPArray+=("${tmpArray[i]}")
            fi
        done

        if [[ ${#tipIPArray[*]} != 0 ]]; then
            let "numTIPs = ${#tipIPArray[*]}"
        fi
        s_list=$(echo ${tipIPArray[@]/%/,} | sed -e "s/,$//g")
        logMsg "027: Got Traffic IPs for TIP Group \"${tipArray[$tipGroup]}\": ${tmpArray[*]} - numTIPs is now $numTIPs"
        unset tmpArray
    else
        logMsg "028: Error getting Traffic IPs from TIP Group \"${tipArray[$tipGroup]}\""
    fi
done

# We would like to always have at least two secondary IPs available, to ensure
# configuration for a typical scenario with 2 x TIPs works successfully.
# If we don't do this, vADC cluster may sit in "Error" state until the next ZxtmIpNannyScript run
# after a first TIP Group has been created.
#
# AWS Docs reference on instance types and secondary IPs:
# http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-eni.html#AvailableIpPerENI
#
if [[ $numTIPs < 2 ]]; then
    numTIPs=2
fi

# Get a JSON for ourselves in $resFName
safe_aws ec2 describe-instances --region $region \
--instance-id $myInstanceID --output json

# Get my InstanceType to check if we're not trying to grab more IPs than possible
instanceType=$(
    cat $resFName | \
    jq -r ".Reservations[].Instances[].InstanceType"
)

myLocalIP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

# What's the ENI ID of the primary and secondary interfaces. We'll need it to add/remove private IPs.
# Find .NetworkInterfaces where .PrivateIpAddresses[].PrivateIpAddress = $myLocalIP,
# then extract the .NetworkInterfaceId
# This assume that there are only 2 interfaces but could be extended to use more.
eniID=$(
    cat $resFName | \
    jq -r ".Reservations[].Instances[].NetworkInterfaces[] | \
    select(.PrivateIpAddresses[].PrivateIpAddress==\"$myLocalIP\") | \
    .NetworkInterfaceId"
)
# Get the secondary IP
eniID2=$(
    cat $resFName | \
    jq -r ".Reservations[].Instances[].NetworkInterfaces[] | \
    select(.NetworkInterfaceId!=\"$eniID\") | \
    .NetworkInterfaceId"
)

# Let's see how many secondary IP addresses I already have
declare -a myPrivateIPs
myPrivateIPs=($(
    cat $resFName | \
    jq -r ".Reservations[].Instances[].NetworkInterfaces[].PrivateIpAddresses[] | \
    select(.Primary==false) | \
    .PrivateIpAddress"
))

# Compare the number of my secondary private IPs with the number of TIPs
if [[ "${#myPrivateIPs[*]}" != "$numTIPs" ]]; then
    # There's a difference; we need to adjust
    logMsg "030: Need to adjust the number of private IPs. Have: ${#myPrivateIPs[*]}, need: $numTIPs"
    if (($numTIPs > ${#myPrivateIPs[*]})); then
        #Compare the Traffic IP and the current private IP arrays to get the missing IPs
        tps=" ${tipIPArray[*]} "
        for item in ${myPrivateIPs[@]}; do
            tps=${tps/ ${item} / }
        done
        #Create a string for the aws cli
        requiredIPs=${tps[*]}

        # Need to add required private IPs
        logMsg "031: Adding private IPs to ENI $eniID2"
        safe_aws ec2 assign-private-ip-addresses \
        --region $region \
        --network-interface-id $eniID2 \
        --private-ip-addresses $requiredIPs
    fi
    logMsg "034: Done adjusting private IPs."
else
    logMsg "035: No need to adjust private IPs."
fi

exit 0
