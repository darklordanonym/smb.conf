#!/bin/bash
# /etc/bin/dhcp-dyndns.sh
# This script is for secure DDNS updates on Samba 4
# Version: 0.8.7
# DNS domain
domain=$(hostname -d)
if [ -z ${domain} ]; then
	echo "Cannot obtain domain name, is DNS set up correctly?"
	echo "Cannot continue... Exiting."
	logger "Cannot obtain domain name, is DNS set up correctly?"
	logger "Cannot continue... Exiting."
	exit 1
fi

# Samba 4 realm
REALM=$(echo ${domain^^})

# Additional nsupdate flags (-g already applied), e.g. "-d" for debug
NSUPDFLAGS="-d"

# krbcc ticket cache
export KRB5CCNAME="/tmp/dhcp-dyndns.cc"

# Kerberos principal
SETPRINCIPAL="dhcpduser@${REALM}"

# Kerberos keytab

# /etc/dhcpduser.keytab
# krbcc ticket cache
# /tmp/dhcp-dyndns.cc
TESTUSER=$(wbinfo -u | grep dhcpduser)
if [ -z "${TESTUSER}" ]; then
	echo "No AD dhcp user exists, need to create it first.. exiting."
	echo "you can do this by typing the following commands"
	echo "kinit Administrator@${REALM}"
	echo "samba-tool user create dhcpduser --random-password --description=\"Unprivileged user for DNS updates via ISC DHCP server\""
	echo "samba-tool user setexpiry dhcpduser --noexpiry"
	echo "samba-tool group addmembers DnsAdmins dhcpduser"
exit 1
fi

# Check for Kerberos keytab
if [ ! -f /etc/dhcp/dhcpduser.keytab ]; then
	echo "Required keytab /etc/dhcpduser.keytab not found, it needs to be created."
	echo "Use the following commands as root"
	echo "samba-tool domain exportkeytab --principal=${SETPRINCIPAL} /etc/dhcpduser.keytab"
	echo "chown dhcpd:dhcpd /etc/dhcpduser.keytab"
	echo "chmod 400 /etc/dhcpduser.keytab"
	exit 1
fi

# Variables supplied by dhcpd.conf
action=$1
ip=$2
DHCID=$3
name=${4%%.*}

usage()
{
	echo "USAGE:"
	echo " ‘basename $0‘ add ip-address dhcid|mac-address hostname"
	echo " ‘basename $0‘ delete ip-address dhcid|mac-address"
}

_KERBEROS () {
# get current time as a number
test=$(date +%d'-'%m'-'%y' '%H':'%M':'%S)
# Note: there have been problems with this
# check that 'date' returns something like
# 04-09-15 09:38:14

# Check for valid kerberos ticket
#logger "${test} [dyndns] : Running check for valid kerberos ticket"
klist -c /tmp/dhcp-dyndns.cc -s
if [ "$?" != "0" ]; then
    logger "${test} [dyndns] : Getting new ticket, old one has expired"
    kinit -F -k -t /etc/dhcpduser.keytab -c /tmp/dhcp-dyndns.cc "${SETPRINCIPAL}"
    if [ "$?" != "0" ]; then
        logger "${test} [dyndns] : dhcpd kinit for dynamic DNS failed"
        exit 1;
    fi
fi
}

# Exit if no ip address or mac-address
if [ -z "${ip}" ] || [ -z "${DHCID}" ]; then
	usage
	exit 1
fi

# Exit if no computer name supplied, unless the action is 'delete'
if [ "${name}" = "" ]; then
    if [ "${action}" = "delete" ]; then
        name=$(host -t PTR "${ip}" | awk '{print $NF}' | awk -F '.' '{print $1}')
    else
        usage
        exit 1;
    fi
fi

# Set PTR address
ptr=$(echo ${ip} | awk -F '.' '{print $4"."$3"."$2"."$1".in-addr.arpa"}')

## nsupdate ##
case "${action}" in
add)
    _KERBEROS

nsupdate -g ${NSUPDFLAGS} << UPDATE
server 127.0.0.1
realm ${REALM}
update delete ${name}.${domain} 3600 A
update add ${name}.${domain} 3600 A ${ip}
send
UPDATE
result1=$?

nsupdate -g ${NSUPDFLAGS} << UPDATE
server 127.0.0.1
realm ${REALM}
update delete ${ptr} 3600 PTR
update add ${ptr} 3600 PTR ${name}.${domain}
send
UPDATE
result2=$?
;;
delete)
     _KERBEROS

nsupdate -g ${NSUPDFLAGS} << UPDATE
server 127.0.0.1
realm ${REALM}
update delete ${name}.${domain} 3600 A
send
UPDATE
result1=$?

nsupdate -g ${NSUPDFLAGS} << UPDATE
server 127.0.0.1
realm ${REALM}
update delete ${ptr} 3600 PTR
send
UPDATE
result2=$?
;;
*)
echo "Invalid action specified"
exit 103
;;
esac

result="${result1}${result2}"

if [ "${result}" != "00" ]; then
    logger "DHCP-DNS Update failed: ${result}"
else
    logger "DHCP-DNS Update succeeded"
fi

exit ${result}

