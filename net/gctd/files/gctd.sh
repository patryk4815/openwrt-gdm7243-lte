#!/bin/sh
# netifd protocol handler for gctd
# netifd manages gctd lifecycle: ifup lte = start, ifdown lte = stop

. /lib/functions.sh
. ../netifd-proto.sh
init_proto "$@"

proto_gctd_init_config() {
	available=1
	proto_config_add_string apn
	proto_config_add_string pdptype
	proto_config_add_string pin
	proto_config_add_string auth
	proto_config_add_string username
	proto_config_add_string password
	proto_config_add_string cid
	proto_config_add_boolean allow_roaming
	proto_config_add_boolean leds
	proto_config_add_boolean use_apn_dns
}

proto_gctd_setup() {
	local interface="$1"
	local device="$2"

	local apn pdptype pin auth username password cid allow_roaming leds use_apn_dns
	json_get_vars apn pdptype pin auth username password cid allow_roaming leds use_apn_dns

	local args=""
	[ -n "$apn" ] && append args "--apn $apn"
	[ -n "$pdptype" ] && append args "--pdptype $pdptype"
	[ -n "$pin" ] && append args "--pin $pin"
	[ -n "$auth" ] && append args "--auth $auth"
	[ -n "$username" ] && append args "--username $username"
	[ -n "$password" ] && append args "--password $password"
	[ -n "$cid" ] && append args "--cid $cid"
	[ "$allow_roaming" = "0" ] && append args "--no-roaming"
	[ "$leds" = "0" ] && append args "--no-leds"
	[ "$use_apn_dns" = "0" ] && append args "--no-apn-dns"

	proto_run_command "$interface" /usr/sbin/gctd daemon "$interface" "$device" $args
}

proto_gctd_teardown() {
	local interface="$1"
	proto_kill_command "$interface"
}

add_protocol gctd
