#!/bin/bash
#set -e
#set -x

[ "$(id -u)" != 0 ] && echo 'Not running as root!' && exit

SSID=YOURNETNAME                           # set this to your desired string (avoid spaces and non-ascii characters)
PASSCODE=foobarfo              # set this to your desired string (8 to 63 characters)
WIFI_INTERFACE=wlan0                # set this according to your device (lshw | grep -A10 Wireless | grep 'logical name')
SUBNET=10.0.0                   # must be different than WIFI_INTERFACE
AP_INTERFACE=$WIFI_INTERFACE-1
IP=${SUBNET}.1
DIR=/data/local/tmp/$AP_INTERFACE

USAGE()
{
    echo 'Usage:'
    printf '\t%s\n' "$(basename "$0") start|stop"
    exit
}

STOP()
{
    # hope there are no other instances of same daemons
    pkill hostapd
    kill  "$(pidof dnsmasq)"
    # remove iptables rules
    iptables -D INPUT -i $AP_INTERFACE -p udp -m udp --dport 67 -j ACCEPT
    iptables -t nat -D POSTROUTING -s ${SUBNET}.0/24 ! -o $AP_INTERFACE -j MASQUERADE
    iptables -D FORWARD -i $AP_INTERFACE -s ${IP}/24 -j ACCEPT
    iptables -D FORWARD -i $WIFI_INTERFACE -d ${SUBNET}.0/24 -j ACCEPT
 þ   # delete AP interface
    ip link show | grep "${AP_INTERFACE}:" && iw $AP_INTERFACE del
} >/dev/null 2>&1

clear

CHECKS()
{
    for binary in iw ip iptables hostapd dnsmasq; do
        which $binary >/dev/null && continue
        exit
    done

    # this check is necessary if need to use single channel
    if iw dev $WIFI_INTERFACE link | grep -q '^Not connected'
    then
        echo 'First connect to Wi-Fi for internet sharing.'
    fi

    if ! iw phy | grep -iqE '{.*managed.*AP.*}' && ! iw phy | grep -iqE '{.*AP.*managed.*}'
    then
        echo 'AP mode not supported.'
        exit
    fi
}

CREATE_AP()
{
    if ! iw dev $WIFI_INTERFACE interface add $AP_INTERFACE type __ap
    then
        echo "Couldn't create AP."  # :(
        exit
    fi
}

FIND_CHANNEL()
{
    # find what channel wi-fi is using
    CHANNEL="$iwlist wlan0 channel | tail -2 | head -1 | cut -d\( -f 2 | cut -c 9"
    if [ -z "$CHANNEL" ]
    then
        echo  "Couldn't find channel info. Are you are connected to Wi-Fi?"
        STOP
        exit
    fi
    # if more than 1 channels are supported, use any frequency
    #[ ! -z "$CHANNEL" ] || CHANNEL=11
}

##This is meant to determine between 2.4GHz and 5GHz based on host network
##It doesn't work currently, best to use 2.4GHz for now...
#GET_BAND()
#{
#    MODE="$(iw dev wlan0 link | grep -i freq | cut -c 8)"
#
#        if  [ $(cat $MODE) = 5]
#        then
#            HW_MODE=a
#            echo "Setting AP for 2.4GHz band"
#        else
#            HW_MODE=g
#            echo "Setting AP for 5GHz band"
#        fi
#}


ADD_IP_ROUTE()
{
    # activate the interface and add IP
    ip link set up dev $AP_INTERFACE
    ip addr add ${IP}/24 broadcast ${SUBNET}.255 dev $AP_INTERFACE

    # routing table 97 needs to be put necessarily on Android
    # because in main table, route for $WIFI_INTERFACE takes priority (ip route show)
    # and all traffic goes there ignoring $AP_INTERFACE
    ip route add ${SUBNET}.0/24 dev $AP_INTERFACE table 97
}

HOSTAPD_CONFIG()
{
    mkdir -p "$DIR" "$DIR/ctrl_interface"
    cat <<-EOF >$DIR/hostapd.conf
	# network name
	ssid=$SSID
	# network interface to listen on
	interface=$AP_INTERFACE
	# wi-fi driver
	driver=nl80211
	# WLAN channel to use
	channel=7
	# ser operation mode, what frequency to use
	hw_mode=g
	# enforce Wireless Protected Access (WPA)
	wpa=2
	# passphrase to use for protected access
	wpa_passphrase=$PASSCODE
	# WPA protocol
	wpa_key_mgmt=WPA-PSK
	EOF

    # you can tune other parameters such as mtu, beacon_int, ieee80211n, wowlan_triggers (if supported)
    # for better performace and options such as *_pairwise for better security
}

INTERNET_SHARE()
{
    # allow IP forwarding
    echo 1 >/proc/sys/net/ipv4/ip_forward
    # route and allow forwrding through firewall
    iptables -t nat -I POSTROUTING -s ${SUBNET}.0/24 ! -o $AP_INTERFACE -j MASQUERADE
    iptables -I FORWARD -i $AP_INTERFACE -s ${IP}/24 -j ACCEPT
    iptables -I FORWARD -i $WIFI_INTERFACE -d ${SUBNET}.0/24 -j ACCEPT
}

DHCP_SERVER()
{
    # configuration
    cat <<-EOF >$DIR/dnsmasq.conf
	# we dont want DNS server, only DHCP
	port=0
	# only listen on AP interface
	interface=$AP_INTERFACE
	listen-address=$IP
	#bind-interfaces
	# range of IPs to make available to wlan devices andwhen to renew IP
	dhcp-range=$IP,${SUBNET}.254,24h
	# where to save leases
	dhcp-leasefile=$DIR/dnsmasq.leases
	# set default gateway
	dhcp-option-force=option:router,$IP
	# add OpenDNS servers for DNS lookup to announce
	dhcp-option-force=option:dns-server,208.67.220.220,208.67.222.222
	#dhcp-option-force=option:mtu,1500
	# respond to a client who is requesting from a different IP broadcast subnet
	# or requesting an out of range / occupied IP
	# or requesting an IP from expired lease of previous sessions
	# or obtained from some other server which is offline now
	dhcp-authoritative
	# don't look for any hosts file and resolv file
	no-hosts
	no-resolv
	EOF

    # open listening port
    iptables -I INPUT -i $AP_INTERFACE -p udp -m udp --dport 67 -j ACCEPT

    # start dhcp server
    dnsmasq -x $DIR/dnsmasq.pid -C $DIR/dnsmasq.conf
}


if [ "$1" = stop ]
then
    STOP || true
    exit
fi

[ "$1" = start ] || USAGE

# basic check
CHECKS
echo "Starting AP now..."
# stop running instances
STOP || true
# create virtual wireless interface
CREATE_AP
# find channed already used ny wi-fi
FIND_CHANNEL #CHANNEL="$(iwlist wlan0 scan | head | grep -i Channel | cut -d\: -f 2)"
# get hw_mode from frequency 2.4 or 5GHz
#GET_BAND
# configre newly created interface
ADD_IP_ROUTE
# configure acces point daemon
HOSTAPD_CONFIG
# start hostapd
hostapd -e $DIR/entropy.bin $DIR/hostapd.conf &
# share internet from Wi-Fi to AP
INTERNET_SHARE
# run a dhcp server to assign IP's dynamically
# otherwise assign a static IP to connected device in subnet range (2 to 254)
DHCP_SERVER
# special stuffs #haveged #powersave off
iw dev wlan0 set power_save off
haveged -v 1 --w 1024 -p $DIR/haveged.pid &


NETWORK="$(iwconfig $WIFI_INTERFACE | grep ESSID | cut -d\" -f 2)"

if HW_MODE=g
then
BND=2.4GHz
else
BND=5GHz                  #elif [ HW_MODE == g ] then
fi

echo " "
echo " "
echo "Launched AP!"
echo "Name:$SSID"
echo "Gateway:$IP"
echo "Repeating $NETWORK $BND"
