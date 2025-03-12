#!/bin/sh
# shellcheck disable=SC3043

: "${DESEC_BASE_URL:=https://desec.io/api/v1}"
: "${TOKEN_FILE:="$(dirname -- "$0")/desec_token"}"

update_record() {
    local dnsname="$1"
    local value="$2"
    local ttl=3600
    local domain
    local subname
    local records
    local desec_token="$(cat -- "${TOKEN_FILE}")"

    # Split the $dnsname into the $domain and $subname that deSEC wants.
    # We do so by retrieving all domains in the account that the token has
    # access to, sorting them by length and checking, if they are a suffix of
    # the $dnsname.
    for d in $(curl --silent --retry 10 --header "Authorization: Token ${desec_token}" "${DESEC_BASE_URL}/domains/" | jq '.[] | .name' | awk -F'"' '{ print length, $2 }' | sort -nr | cut -d' ' -f2-); do
        if [ "${dnsname%.$d}" != "${dnsname}" ]; then
            # $dnsname ends with .$d, i.e. the current domain.
            domain="${d}"
            break
        fi
    done
    if [ -z "${domain}" ]; then
        printf 'Error: Could not find parent domain for %s\n' "${dnsname}" >&2
        return 1
    fi
    subname="${dnsname%.${domain}}"

    if [ -n "${value}" ]; then
        # Note: The outer double quotes are for JSON. The escaped, inner ones
        # are part of the record value, which must be quoted for TXT records.
        records='"\"'${value}'\""'
    else
        # An empty record list deletes the TXT record.
        records=''
    fi
    printf '[{"subname":"%s","type":"TXT","ttl":%d,"records":[%s]}]' "${subname}" "${ttl}" "${records}" | \
        curl \
        --silent \
        --retry 10 \
        --request PUT \
        --header "Authorization: Token ${desec_token}" \
        --header 'Content-Type: application/json' \
        --data @- \
        "${DESEC_BASE_URL}/domains/${domain}/rrsets/"
}

publish_response() {
    # Add the response to the DNS via the deSEC API.
    update_record "_acme-challenge.$1" "$2"
    local r=$?
    # We need to wait until the record has propagated to all of deSEC's name
    # servers before we can let the CA check the DNS response. As we can not
    # check the propagation status in any way, we simply wait, as propagation
    # should not take much longer than a minute.
    [ "${r}" -eq 0 ] && sleep 80
    return "${r}"
}

clear_response() {
    # Remove the response from the DNS via the deSEC API.
    update_record "_acme-challenge.$1"
}

if [ "$#" -ne 5 ]; then
    cat - >&2 <<EOH
Usage: $(basename -- "$0") method type ident token auth
  This script is a hook for uacme and should not be called directly.
EOH
    exit 85
fi

method="$1"
type="$2"
ident="$3"
token="$4"
auth="$5"

case "${type}" in
    dns-01)
        case "${method}" in
            begin)
                publish_response "${ident}" "${auth}"
                ;;
            done|failed)
                clear_response "${ident}"
                ;;
            *)
                echo "$0: invalid method" >&2
                exit 1
                ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
