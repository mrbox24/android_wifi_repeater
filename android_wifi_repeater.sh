#!/system/bin/sh
#set -e
#set -x


SSID=rnet                           # set this to your desired string (avoid spaces and non-ascii characters)
WIFI=wlan0                # set this according to your device (lshw | grep -A10 Wireless | grep 'logical name')
SUBNET=10.0.0                   # must be different than WIFI
PASSCODE=foobarfoo
AP=rnet
IP=${SUBNET}.1
DIR=/data/local/$AP

mkdir -p $DIR

DOWN()
{
    # hope there are no other instances of same daemons
    pkill hostapd
    kill  "$(pidof dnsmasq)"
    # remove iptables rules
    iptables -D INPUT -i $AP -p udp -m udp --dport 67 -j ACCEPT
    iptables -t nat -D POSTROUTING -s ${SUBNET}.0/24 ! -o $AP -j MASQUERADE
    iptables -D FORWARD -i $AP -s ${IP}/24 -j ACCEPT
    iptables -D FORWARD -i $WIFI -d ${SUBNET}.0/24 -j ACCEPT
 þ   # delete AP interface
    ip link show | grep "${AP}:" && iw $AP del
} >/dev/null 2>&1

CHECKS()
{
    for binary in iw ip iptables hostapd dnsmasq; do

        which $binary >/dev/null && continue
        exit
    done

    # this check is necessary if need to use single channel
    if iw dev $WIFI link | grep -q '^Not connected'
    then
        echo 'Connect to target network first....'
#       exit
    fi
}

TARGET_INFO()
{
    # Here we set vars for hostapd
    iw wlan0 scan | head -n 11 >/data/local/tmp/scn
    FRQ=$(cat /data/local/tmp/scn | grep freq | cut -d : -f 2 | tr -d ' ')
    HSSID=$(cat /data/local/tmp/scn | grep SSID | cut -d : -f 2 | tr -d ' ')
    CH=$(cat /data/local/tmp/scn | grep channel | cut -d l -f 2 | tr -d ' ')
    BSS=$(cat /data/local/tmp/scn|grep BSS|cut -d S -f 3 |cut -d - -f 1|tr -d ' '|cut -c 1-17)
    SIGNL=$(cat /data/local/tmp/scn|grep signal| cut -d : -f 2|tr -d ' ')
}

SETHW()
{
    if  [ "$CH" -lt "14" ]; then
        HW=g
    else 
        HW=a
    fi
}


CREATE_AP()
{
    if ! iw dev $WIFI interface add $AP type __ap
    then
        echo "Couldn't create AP."  # :(
        exit
    fi
}

ADD_IP_ROUTE()
{
    # activate the interface and add IP
    ip link set up dev $AP
    ip addr add ${IP}/24 broadcast ${SUBNET}.255 dev $AP

    # routing table 97 needs to be put necessarily on Android
    # because in main table, route for $WIFI takes priority (ip route show)
    # and all traffic goes there ignoring $AP
    ip route add ${SUBNET}.0/24 dev $AP table 97
}

HOSTAPD_CONFIG()
{
    # hostapd configuration
    mkdir -p $DIR/hostapd
	cat <<-EOF >$DIR/hostapd.conf
	# network name
	ssid=$SSID
	# ap mac
	# network interface to listen on
	interface=$AP
	# wi-fi driver
	driver=nl80211
	# ctrl interface
	#ctrl_interface=/data/misc/wifi/hostapd/ctrl
	# barrowed from host hostapd.conf
	ignore_broadcast_ssid=0
	# WLAN channel to use
	channel=$CH
	# HT config
	ieee80211n=1
	ieee80211ac=1
	# testing options for stability
	macaddr_acl=0
	# ser operation mode, what frequency to use
	hw_mode=$HW
	# enforce Wireless Protected Access (WPA)
	wpa=2
	# wireless protected access psk
	wpa_passphrase=$PASSCODE
	# use wpa_passphrase rnet foobarfoo
	#wpa_psk=
	#rsn_pairwise=CCMP
	# WPA protocol
	wpa_key_mgmt=WPA-PSK
	EOF

}

INTERNET_SHARE()
{
    # allow IP forwarding
    echo 1 >/proc/sys/net/ipv4/ip_forward
    # route and allow forwrding through firewall
    iptables -t nat -I POSTROUTING -s ${SUBNET}.0/24 ! -o $AP -j MASQUERADE
    iptables -I FORWARD -i $AP -s ${IP}/24 -j ACCEPT
    iptables -I FORWARD -i $WIFI -d ${SUBNET}.0/24 -j ACCEPT
}

DHCP_SERVER()
{
    # configuration
    cat <<-EOF >$DIR/dnsmasq.conf
	# we dont want DNS server, only DHCP
	port=0
	# only listen on AP interface
	interface=$AP
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
    iptables -I INPUT -i $AP -p udp -m udp --dport 67 -j ACCEPT

    # start dhcp server
    dnsmasq -x $DIR/dnsmasq.pid -C $DIR/dnsmasq.conf
}

if [ "$1" = down ]; then
    DOWN || true
    exit
fi

[ "$1" = start ]

# basic check
CHECKS
# stop running instances
DOWN || true
# scan info from current connection
TARGET_INFO
# set band with target
SETHW
# create virtual wireless interface
CREATE_AP
# configre newly created interface
ADD_IP_ROUTE
# configure acces point daemon
HOSTAPD_CONFIG
# start hostapd
hostapd  -B -d -e$DIR/entropy.bin -g$DIR/hostapd/ctrl/$AP  $DIR/hostapd.conf |xargs >/sdcard/rnet.log &2>&1
# share internet from Wi-Fi to AP
INTERNET_SHARE
# run a dhcp server to assign IP's dynamically
# otherwise assign a static IP to connected device in subnet range (2 to 254)
DHCP_SERVER
# special stuffs #haveged #powersave off
iw dev wlan0 set power_save off

if [ "$HW" = "g"   ]; then
    BND=2.4GHz
else
    BND=5GHz
fi


echo wifi: \| $HSSID \| $BSS \| "$(ifconfig "$WIFI"|head -n 2|tail -n 1|cut -d : -f 2 |cut -d B -f 1|cut -d\( -f 2 |tr -d ' ')" \| $SIGNL \|
echo AP: \| $SSID \| "$(ifconfig "$AP" |head -n 1 |cut -d H -f 2|cut -c 7-24|tr -d ' ')" \| $IP \| $CH \| $FRQ \| $BND \|
echo
echo stop with: $(printf '\t%s\n'|tr -d '[:blank:]') $(basename "$0") down
