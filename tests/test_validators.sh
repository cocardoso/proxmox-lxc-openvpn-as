#!/usr/bin/env bash
# Unit tests for the input validators.
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh
source ./openvpn-as-lxc.sh

assert_ok     "plain ip"            is_ipv4 192.168.1.10
assert_fails  "octet > 255"         is_ipv4 192.168.1.256
assert_fails  "three octets"        is_ipv4 10.0.0
assert_fails  "leading zero"        is_ipv4 10.0.0.01
assert_fails  "empty ip"            is_ipv4 ""

assert_ok     "cidr /24"            is_ipv4_cidr 10.0.0.5/24
assert_ok     "cidr /32"            is_ipv4_cidr 10.0.0.5/32
assert_fails  "cidr /33"            is_ipv4_cidr 10.0.0.5/33
assert_fails  "cidr missing mask"   is_ipv4_cidr 10.0.0.5
assert_fails  "cidr bad ip"         is_ipv4_cidr 10.0.300.5/24

assert_ok     "port 443"            is_port 443
assert_ok     "port 65535"          is_port 65535
assert_fails  "port 0"              is_port 0
assert_fails  "port 65536"          is_port 65536
assert_fails  "port text"           is_port abc

assert_ok     "hostname simple"     is_hostname openvpn-as
assert_fails  "hostname underscore" is_hostname open_vpn
assert_fails  "hostname dash start" is_hostname -vpn
assert_fails  "hostname with dot"   is_hostname vpn.example.com
assert_fails  "hostname too long"   is_hostname "$(printf 'a%.0s' {1..64})"

assert_ok     "fqdn"                is_fqdn_or_ip vpn.example.com
assert_ok     "public ip"           is_fqdn_or_ip 203.0.113.7
assert_fails  "fqdn with space"     is_fqdn_or_ip "vpn example.com"
assert_fails  "empty host"          is_fqdn_or_ip ""

assert_ok     "vlan empty"          is_vlan ""
assert_ok     "vlan 10"             is_vlan 10
assert_fails  "vlan 0"              is_vlan 0
assert_fails  "vlan 4095"           is_vlan 4095

assert_ok     "positive int"        is_positive_int 8
assert_fails  "zero"                is_positive_int 0
assert_fails  "negative"            is_positive_int -1
assert_fails  "decimal"             is_positive_int 1.5

assert_ok     "domain"              is_domain example.com.br
assert_fails  "domain single label" is_domain localhost
assert_fails  "domain is ip"        is_domain 203.0.113.7

DDNS_ZONE=example.com.br
assert_ok     "record in zone"      is_record_in_zone vpn.example.com.br
assert_fails  "zone apex"           is_record_in_zone example.com.br
assert_ok     "record upper-case"   is_record_in_zone VPN.Example.com.br
assert_fails  "record other zone"   is_record_in_zone vpn.other.com
assert_fails  "suffix trick"        is_record_in_zone vpnexample.com.br

finish
