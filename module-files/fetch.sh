#!/bin/sh

url="$1"
outfile="$2"

user=
password=
host="${url#*://}"
host="${host%%/*}"
host="${host#*@}"
host="${host%:*}"
if [ -f "${HOME}/.netrc" ]; then
    line="$(grep "^machine\\s${host}\\s" "${HOME}/.netrc")"
    if [ -z "${line}" ]; then
        line="$(grep '^default\s' "${HOME}/.netrc")"
    fi
    if [ -n "${line}" ]; then
        user="$(echo "${line}" | sed -Ee 's/.*\slogin\s(\S+)\s.*/\1/')"
        password="$(echo "${line}" | sed -Ee 's/.*\spassword\s(\S+)$/\1/')"
        if [ "${user#file://}" != "${user}" ]; then
            user="$(cat -- "${user#file://}")"
        fi
        if [ "${password#file://}" != "${password}" ]; then
            password="$(cat -- "${password#file://}")"
        fi
    fi
    set -- "--header" "Authorization: Basic $(printf '%s:%s' "${user}" "${password}" | base64)"
fi

if [ -n "${outfile}" ]; then
    set -- "$@" -O "${outfile}"
fi

wget -q "$@" "${url}"
