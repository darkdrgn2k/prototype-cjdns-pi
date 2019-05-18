#!/bin/bash

# Collect IP address information passed by socat

# Remote IP address
SOCAT_PEERADDR=$(echo "$SOCAT_PEERADDR" | tr -d \[ | tr -d \]) 
# Local IP address
SOCAT_SOCKADDR=$(echo "$SOCAT_SOCKADDR" | tr -d \[ | tr -d \]) 
# Truncate ip address to remove []
LOCAL=$(echo $SOCAT_SOCKADDR  | tr -d \[ | tr -d \] | tr -d \:) 

# Match local ip address with interface
IFACE=$(cat /proc/net/if_inet6  | grep $LOCAL  | awk '{print $6}')

# Returns index of a an existing WG connection using its public key
function getIndex {
      index=$(cat /var/run/babel-wg/list | grep $1 | awk '{print $1}' | head -n 1)
      echo $index
}

# Creates a new index and assignes it the public key used to create a new WG connection
function createIndex {
   index=$(cat /var/run/babel-wg/index)
   index=$((index+1))
   echo $index "${peerPub}" >> /var/run/babel-wg/list
   echo $index > /var/run/babel-wg/index
   echo $index
}

# If local ip=remote ip skip - loopback broadcast
if [[ "$SOCAT_SOCKADDR" == "$SOCAT_PEERADDR" ]]; then
   exit 0
fi

# Read content of socat transmission
read -r line

# If line does not include a | its garbage data, skip
if [[ "$line" != *"|"* ]]  ; then
   exit 0
fi

# Parse first paramater of transmission
A="$(echo $line | cut -d'|' -f1)"

# Load WG variables
source /etc/wg

# command WG = Initial announcement
if [[ "$A" == "WG" ]]; then
      # Parse param2 - Pubkey
      peerPub="$(echo $line | cut -d'|' -f2)"
      # Match it with index
      index=$(getIndex $peerPub)
      
      # Does not exist, create one
      if [ -z $index ]; then
         index=$(createIndex);
      fi
      
      # Respond with WGPORT, include port of new wg interface for this peer
      echo "WGPORT|$publicKey|101$index" |  socat - UDP6-datagram:[$SOCAT_PEERADDR%$IFACE]:1234
fi


# command WGPORT or WGPORTACK = Create WG link
if [[ "$A" == "WGPORT" || "$A" == "WGPORTACK" ]]; then

    echo wglink - Receive $A  >> /var/log/babel-wg
    
    # Prase remote pubkey and remote port paramaters
    peerPub="$(cut -d'|' -f2 <<<"$line")"
    peerPort="$(cut -d'|' -f3 <<<"$line")"

    # Match it with index
    index=$(getIndex $peerPub)
    # Does not exist, create one
    if [ -z $index ]; then
         index=$(createIndex);
    fi

    # check if WG interface for pubkey already exists
    if [ ! -z "$(wg 2>&1  |  grep "${peerPub}")" ]; then
        # Parse existing port for existing connection
        testPort=$(wg | grep -A1 ${peerPub} | tail -n1 | rev | cut -d ":" -f1 | rev)
        
        # Ports dont match, remove link to re-create
        if [[ $testPort != $peerPort ]]; then

            # Iterate through interfaces
            for int in $(find /sys/class/net/* -maxdepth 1 -print0 | xargs -0 -l basename); do
                # Match wg interfaces
                if [[ "$int" == "wg"* ]]; then                
                    # match public peer for $int
                    wg=$(wg show $int | grep $peerPub)
                    
                    # If wg pub match found, delete
                    if [ ! -z "$wg" ]; then
                        echo wglink - Deleteing $wg due to port mismatch $testPort != $peerPort >> /var/log/babel-wg
                        ip link del dev $int type wireguard
                    fi
                fi
            done
        fi
    fi

    # check if WG interface for pubkey already exists again
    # has it been deleted?
    if [ -z "$(wg 2>&1 | grep "${peerPub}")" ]; then

        echo wglink - adding wg${index} 101$index $peerPort >> /var/log/babel-wg
        
        # Configure wg interface
        ip link add dev wg${index} type wireguard
        ip link set dev wg${index} up
        # Configure wg connection
        wg set wg${index} listen-port 101${index}
        wg set wg${index} listen-port 101${index} private-key /etc/wg.key peer $peerPub endpoint [$SOCAT_PEERADDR%$IFACE]:$peerPort persistent-keepalive 60 allowed-ips ::/0

        # Add Interface to Babeld
        echo "interface wg${index}" |  socat - TCP6:[::1]:999 > /dev/null

        # add ipv6 address to WG interface
        ip -6 address add dev wg${index} scope link $ipv6/128
        # add local link ipv6 address to WG so babeld can use it to peer
        ip -6 address add dev wg${index} scope link fe80::$((1 + RANDOM % 99))$((1 + RANDOM % 99)):$((1 + RANDOM % 99))$((1 + RANDOM % 99)):$((1 + RANDOM % 99))$((1 + RANDOM % 99)):$((1 + RANDOM % 99))${index}/64

   fi
   
   # If this is not an ACK packet
   if [[ "$A" != "WGPORTACK" ]]; then
      # Send ACK packet with reciprical information to allow remote side to form connection back
      echo wglink - Send ACK wg${index}  >> /var/log/babel-wg
      echo "WGPORTACK|$publicKey|101$index" |  socat - UDP6-datagram:[$SOCAT_PEERADDR%$IFACE]:1234
   fi

fi
