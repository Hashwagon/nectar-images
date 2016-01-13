#!/bin/bash -e

# This script requires:
#  - QEMU/KVM to be configured and running
#  - image-builder OpenStack credentials loaded in your environment
#  - Jenkins image testing SSH key in your ssh-agent

FILE=$1
if [ -z $FILE ]; then
    echo "Give file to build"
    exit 1
fi

if [ "$OS_USERNAME" != "image-builder" ]; then
    echo "Please load image-builder credentials"
    exit 1
fi

# Find packer
if which packer >/dev/null 2>&1; then
    PACKER=packer
elif which packer-io >/dev/null 2>&1; then
    PACKER=packer-io
else
    echo "You need packer installed to use this"
    exit 1
fi

NAME=$(basename -s .json $FILE)
BUILD_NUMBER=$(date "+%Y%m%d%H%M")

if [ -d output-$NAME ]; then
    echo "Cleaning up exising output directory \"output-$NAME \"..."
    rm -fr output-$NAME
fi

if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
    echo "Running over SSH shell, not enabling headless mode"
    PACKER_FILE=$FILE
else
    # For local builds, we'll disable headless mode
    sed 's/"headless": true/"headless": false/g' $NAME.json >/tmp/temp-$NAME.json
    PACKER_FILE=/tmp/temp-$NAME.json
fi

echo "Building image $NAME..."
$PACKER build $PACKER_FILE
[ -f /tmp/temp-$NAME.json ] && rm /tmp/temp-$NAME.json

echo "Shrinking image..."
cd output-$NAME
qemu-img convert -c -o compat=0.10 -O qcow2 $NAME $NAME.qcow2
rm $NAME
cd ..

echo "Creating image \"NeCTAR $NAME\"..."
IMAGE_ID=$(openstack image create --os-image-api-version=1 -f value -c id --disk-format qcow2 --container-format bare --file output-$NAME/$NAME.qcow2 --property nectar_build=$BUILD_NUMBER "NeCTAR $NAME")
echo "Image ID: $IMAGE_ID"

echo "Removing image working directory..."
rm -fr rm -fr output-$NAME

echo "Creating instance \"test_${NAME}_$BUILD_NUMBER\"..."
INSTANCE_ID=$(openstack server create -f value -c id --image $IMAGE_ID --flavor m1.small --key-name jenkins-image-testing "test_${NAME}_$BUILD_NUMBER")
echo "Instance ID: $INSTANCE_ID"

set +e

ATTEMPTS=50
ATTEMPT=1
while [ $ATTEMPT -le $ATTEMPTS ]; do
    STATUS=$(openstack server show -f value -c status $INSTANCE_ID)
    [ "$STATUS" = "ACTIVE" ] && break
    echo "Waiting for instance to become ACTIVE [$STATUS]... ($ATTEMPT/$ATTEMPTS)"
    [ $ATTEMPT -eq $ATTEMPTS ] && exit 1
    ATTEMPT=$((ATTEMPT+1))
    sleep 5
done

IP_ADDRESS=$(openstack server show -f value -c accessIPv4 $INSTANCE_ID)
echo "Instance has IP address: $IP_ADDRESS"

# Discover which user account to use
if echo "$NAME" | grep -qi debian; then
    USER_ACCOUNT=debian
elif echo "$NAME" | grep -q ubuntu; then
    USER_ACCOUNT=ubuntu
else
    USER_ACCOUNT=ec2-user
fi

ATTEMPT=1
while [ $ATTEMPT -le $ATTEMPTS ]; do
    echo "Checking for SSH connection... ($ATTEMPT/$ATTEMPTS)"
    ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null $USER_ACCOUNT@$IP_ADDRESS exit 2>&1 >/dev/null
    [ $? -eq 0 ] && break
    [ $ATTEMPT -eq $ATTEMPTS ] && exit 1
    ATTEMPT=$((ATTEMPT+1))
    sleep 10
done

echo "Running tests (ssh $USER_ACCOUNT@$IP_ADDRESS '/bin/bash /usr/nectar/run_tests.sh')..."
ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null $USER_ACCOUNT@$IP_ADDRESS '/bin/bash /usr/nectar/run_tests.sh'

echo "Deleting instance $INSTANCE_ID..."
openstack server delete $INSTANCE_ID