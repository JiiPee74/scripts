#!/bin/sh

pci_devices=$(lspci -qnn)
block_devices=$(readlink /sys/block/* | grep "/pci" | sed 's/^../\/sys/')
usb_devices=$(readlink /sys/bus/usb/devices/* | grep -E "[0-9]{1,2}-[0-9]{1,2}$" | sed 's/^[.\/]\{8\}/\/sys/')

#declare -a devs=()
#declare -a usbs=()

for i in $block_devices
do
        id=$(echo "$i" | grep -oE "/[0-9,a-f]{4}:[0-9,a-f]{2}:[0-9,a-f]{2}\.[0-9,a-f]{1,2}" | tail -n 1 | sed 's/^\/[0-9,a-f]\{4\}://')
        dev=$(echo "$i" | awk -F "/" '{print $NF}')
        devs+=("$id $dev $i")
done

for i in $usb_devices
do
        id=$(echo "$i" | grep -oE "/[0-9,a-f]{4}:[0-9,a-f]{2}:[0-9,a-f]{2}\.[0-9,a-f]{1,2}" | tail -n 1 | sed 's/^\/[0-9,a-f]\{4\}://')
        dev=$(echo "$i" | awk -F "/" '{print $--NF}' | sed 's/^[0-9]\{4\}://')
        usbs+=("$id $dev $i")
done


for group in $(ls /sys/kernel/iommu_groups | sort -h)
do
        echo "IOMMU Group $group"
        for device_id in $(ls /sys/kernel/iommu_groups/${group}/devices | awk -F ":" '{print $2":"$3}')
        do
                pci_device=$(echo "$pci_devices" | grep "$device_id")
                echo "  $pci_device"

                # loop block devices
                if [[ $(echo "${devs[@]}" | grep "$device_id") ]]
                then
                        for index in ${!devs[@]}
                        do
                                read ID DEV LOC <<< ${devs[$index]}
                                if [[ $ID == $device_id ]]
                                then
                                        if [[ $(echo "$DEV" | grep "nvme") ]]
                                        then
                                                model=$(cat $LOC/../model); transport=$(cat $LOC/../transport)
                                                echo -e "\t$DEV\t $transport \t$model"
                                        else
                                                model=$(cat $LOC/../../model); rev=$(cat $LOC/../../rev); vendor=$(cat $LOC/../../vendor)
                                                echo -e "\t$DEV\t $vendor $model $rev"
                                        fi
                                fi
                        done
                fi

                # loop usb devices
                if [[ $(echo "${usbs[@]}" | grep "$device_id") ]]
                then
                        for index in ${!usbs[@]}
                        do
                                read ID DEV LOC <<< ${usbs[$index]}
                                #echo "ID [$ID] DEV [$DEV] LOC [$LOC]"
                                if [[ $ID == $device_id ]]
                                then
                                        manufacturer=$(cat $LOC/manufacturer); product=$(cat $LOC/product); version=$(cat $LOC/version); speed=$(cat $LOC/speed)
                                        echo -e "\t$DEV\t $manufacturer $product \tSpeed: ${speed}Mbps  Version:$version"
                                fi
                        done
                fi
        done

        echo ""
done
