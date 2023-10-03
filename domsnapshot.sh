#!/bin/bash
if [[ $1 == "" ]]
then
        echo "Usage: $0 <domain>"
        echo "Example: $0 fedora33"
        exit 1
fi

DOMAIN="$1"
TIMESTAMP=`date '+%Y%m%d-%H%M%S'`
SNAPSHOT_NAME=$TIMESTAMP

VM_FOLDER=$(virsh domblklist --domain $DOMAIN | awk '{print $2}' | grep "$DOMAIN" | awk -F "$DOMAIN" '{print $1}')
#VM_FOLDER="/path/to/vms"
SNAPSHOT_FOLDER="${VM_FOLDER}snapshots/${DOMAIN}/${TIMESTAMP}"

#echo "
#DOMAIN $DOMAIN
#TIMESTAMP $TIMESTAMP
#SNAPSHOT_NAME $SNAPSHOT_NAME
#VM_FOLDER $VM_FOLDER
#SNAPSHOT_FOLDER $SNAPSHOT_FOLDER "
#echo end

#exit 1
#sleep 1d

# Magic happens here
mkdir -p $SNAPSHOT_FOLDER

MEM_FILE="`echo $SNAPSHOT_FOLDER`/mem.qcow2"
DISK_FILE="`echo $SNAPSHOT_FOLDER`/disk.qcow2"

# Find out if running or not
STATE=`virsh dominfo $DOMAIN | grep "State" | cut -d " " -f 11`

if [ "$STATE" = "running" ]; then

  virsh snapshot-create-as \
    --domain $DOMAIN $SNAPSHOT_NAME \
    --diskspec vda,file=$DISK_FILE,snapshot=external \
    --memspec file=$MEM_FILE,snapshot=external \
    --atomic

else

  virsh snapshot-create-as \
    --domain $DOMAIN $SNAPSHOT_NAME \
    --diskspec vda,file=$DISK_FILE,snapshot=external \
    --disk-only \
    --atomic

fi
