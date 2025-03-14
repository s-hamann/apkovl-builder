#!/bin/sh
# shellcheck disable=3043  # ash supports local

set -eu

mirror="$(sed -Ene 's@.*(https?://.*/)(v[0-9]+\.[0-9]+|edge)/(main|community|testing)@\1@ p' /etc/apk/repositories 2>/dev/null | head -n1)"
alpine_release=latest-stable
target_arch="$(cat /etc/apk/arch 2>/dev/null || true)"
output_file=overlay.tar.gz
modules_dir="$(dirname -- "$0")/modules/"
module_files_dir="$(dirname -- "$0")/module-files/"
files_dirs="$(dirname -- "$0")/files/"
root_size=
modules=
pkgs=
files=
services=
default_services=false
rc_parallel=false
hostname=
timezone="$(readlink /etc/localtime | sed -e 's:.*/zoneinfo/::')"
ntp_servers=
root_password=

apk_root() {
    # Run an apk operation in the overlay root directory.
    apk --repository "${mirror}/${alpine_release}/main" --repository "${mirror}/${alpine_release}/community" --root "${root_dir}" --arch "${target_arch}" --keys-dir "/usr/share/apk/keys/${target_arch}" "$@"
}

erase_pkg() {
    # Delete all the files installed by the given packages without removing the
    # packages themselves. This will break stuff without apk noticing.
    for pkg in "$@"; do
        correct_pkg=false
        while read -r line; do
            if [ "${line}" = "P:${pkg}" ]; then
                correct_pkg=true
                dir=
                continue
            elif [ -z "${line}" ]; then
                correct_pkg=false
                continue
            elif [ "${correct_pkg}" = true ]; then
                k="${line%%:*}"
                v="${line#*:}"
                case "${k}" in
                F)
                    if [ -n "${dir}" ] && [ -d "${root_dir}/${dir}" ]; then
                        rmdir --ignore-fail-on-non-empty -- "${root_dir}/${dir}"
                    fi
                    dir="${v}"
                    continue
                    ;;
                R)
                    rm -f -- "${root_dir}/${dir}/${v}"
                    ;;
                esac
            fi
        done <"${root_dir}/lib/apk/db/installed"
    done
}

rc_add() {
    # Add the given service to the given runlevel.
    local service="$1"
    local runlevel="${2:-default}"
    mkdir -p "${root_dir}/etc/runlevels/${runlevel}"
    ln -sf "/etc/init.d/${service}" "${root_dir}/etc/runlevels/${runlevel}/${service}"
}

add_file() {
    # Add a file or directory to the overlay. The source may be a URL.
    local source="$1"
    local dest="${2#"${root_dir}"}"
    local dest_dir="$(dirname -- "${dest}")"
    mkdir -p -- "${root_dir}${dest_dir}"
    case "${source}" in
        http://*|https://*|ftp://*)
            wget "${source}" -O "${root_dir}${dest}"
            ;;
        *)
            cp -a -- "${source}" "${root_dir}${dest}"
            ;;
    esac
}


config_file=
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            cat - <<EOH
$(basename -- "$0") [-c <path>]
Alpine overlay build script.
Options:
  -c, --config path
    Read the configuration file at path.
  -h, --help
    Show this help message and exit.
EOH
            exit 0
            ;;
        -c|--config)
            config_file="$2"
            shift
            ;;
        *)
            printf 'Invalid option %s\n' "$1" >&2
            exit 1
            ;;
    esac
    shift
done

if [ -n "${config_file}" ]; then
    # Read the configuration file.
    # shellcheck disable=SC1090
    . "${config_file}"
fi


for mod in ${modules}; do
    # Load modules.
    module_depends=
    # shellcheck disable=SC1090
    . "${modules_dir}/${mod}"
    while [ -n "${module_depends}" ]; do
        deps_depends=
        for dep in ${module_depends}; do
            for m in ${modules}; do
                if [ "${dep}" = "${m}" ]; then
                    continue 2
                fi
            done
            modules="${dep} ${modules}"
            module_depends=
            . "${modules_dir}/${dep}"
            deps_depends="${module_depends} ${deps_depends}"
        done
        module_depends="${deps_depends}"
    done
done

# Create a temporary directory for the overlay contents.
readonly tmpdir="$(mktemp -d -p "${TMPDIR:-/tmp}" apkovl.XXXXXX)"
readonly root_dir="${tmpdir}/root"
mkdir -p -- "${root_dir}"
# Check if nodev is in effect on $tmpdir.
t="${tmpdir}"
tmpdir_needs_mount=false
while [ "${t}" != / ]; do
    t="$(dirname -- "${t}")"
    mount_opts="$(grep -F " ${t} " /proc/mounts | cut -d' ' -f4)"
    if [ -z "${mount_opts}" ]; then
        # $t is not a mount point. Try the parent.
        continue
    fi
    # If we get here, we found the mount point that $tmpdir is on. This is the
    # last iteration of the loop.
    case "${mount_opts}" in
        nodev|*,nodev|nodev,*|*,nodev,*) tmpdir_needs_mount=true ;;
    esac
    unset t mount_opts
    break
done
# Note: The mode of the root directory MUST be 0755. The mode gets stored in
# the overlay archive and subsequently applied to the root directory of the
# system that uses this overlay.
if [ "${tmpdir_needs_mount}" = true ]; then
    # We must be able to write device files to the overlay's /dev. Mount a
    # tmpfs with the 'dev' option.
    mount -t tmpfs -o mode=0755,dev tmpfs "${root_dir}"
else
    chmod 0755 "${root_dir}"
fi
# shellcheck disable=SC2064  # expanding the variables now is intended
trap "[ '${tmpdir_needs_mount}' = true ] && umount -- '${root_dir}'; rm -rf -- '${tmpdir}'" EXIT INT TERM QUIT

if [ "${default_services}" = true ]; then
    # Enable all default services at boot.
    touch -- "${root_dir}/etc/.default_boot_services"
fi

# Set up a minimal base system.
apk_root add --update-cache --initdb alpine-base openssl


# Install custom packages.
if [ -n "${pkgs}" ]; then
    # shellcheck disable=SC2086  # splitting is required
    apk_root add ${pkgs}
fi


# Run module setup functions.
if [ -n "${modules}" ]; then
    for m in ${modules}; do
        command -v "setup_${m}" >/dev/null && "setup_${m}"
    done
fi


# Extract supplementary archive files.
if [ -n "${files}" ]; then
    for f in ${files}; do
        file_done=false
        for d in ${files_dirs}; do
            if [ -f "${d}/${f}" ]; then
                tar -C "${root_dir}" -xf "${d}/${f}"
                file_done=true
                break
            fi
        done
        if [ "${file_done}" != true ]; then
            printf 'Warning: File archive %s not found\n' "${f}"
        fi
    done
fi


if [ "${rc_parallel}" = true ]; then
    sed -i -Ee 's/#?\s*rc_parallel=.*/rc_parallel=YES/' "${root_dir}/etc/rc.conf"
fi
sed -i -Ee 's/#?\s*rc_tty_number=.*/rc_tty_number=1/' "${root_dir}/etc/rc.conf"


# Note: Alpine's udhcpc script ignores NTP servers :(
# There's nothing we can do about it, since udhcpc runs in the initramfs.
if [ -n "${ntp_servers}" ]; then
    NTPD_OPTS="-N"
    for host in ${ntp_servers}; do
        NTPD_OPTS="${NTPD_OPTS} -p ${host}"
    done
    sed -i -e "s/NTPD_OPTS=.*/NTPD_OPTS='${NTPD_OPTS}'/" "${root_dir}/etc/conf.d/ntpd"
    services="${services} ntpd"
fi


# Enable custom services.
if [ -n "${services}" ]; then
    for service in ${services}; do
        rc_add "${service}" default
    done
fi


# Set root password.
if [ -n "${root_password}" ]; then
    if [ "${root_password#\$*\$}" != "${root_password}" ]; then
        echo "root:${root_password}" | chpasswd -e -R "${root_dir}"
    else
        echo "root:${root_password}" | chpasswd -R "${root_dir}"
    fi
    unset "${root_password}"
fi


# Disable virtual TTYs.
[ -f "${root_dir}/etc/inittab" ] && sed -i -e '/^tty[0-9]::/d' -- "${root_dir}/etc/inittab"


# Store the current time stamp for swclock.
mkdir -p -- "${root_dir}/var/lib/misc"
touch -- "${root_dir}/var/lib/misc/openrc-shutdowntime"


# Initialize the RNG on boot using some entropy from this system.
mkdir -p -- "${root_dir}/var/lib/seedrng"
head -c "$(( $(cat /proc/sys/kernel/random/poolsize) / 8 ))" /dev/urandom > "${root_dir}/var/lib/seedrng/seed.no-credit"
chmod 400 -- "${root_dir}/var/lib/seedrng/seed.no-credit"


# The initramfs will bring up the network, but not satisfy the 'net' dependency
# of init scripts. Add an empty configuration for ifupdown, so the networking
# script can run.
touch -- "${root_dir}/etc/network/interfaces"

if [ -n "${root_size}" ]; then
    # Add root mount point with limited size to /etc/fstab.
    printf 'tmpfs / tmpfs noatime,size=%dM 0 0\n' "${root_size}" >> "${root_dir}/etc/fstab"
fi


# Load modules on boot.
rc_add modloop boot
rc_add modules boot


# Enable sysctl service if it would do anything.
if [ -n "$(find "${root_dir}/lib/sysctl.d/" "${root_dir}/usr/lib/sysctl.d/" "${root_dir}/etc/sysctl.d/" -name "*.conf" -print -quit)" ]; then
    echo 'rc_after=modules' > "${root_dir}/etc/conf.d/sysctl"
    rc_add sysctl boot
fi


# Set the system host name.
if [ -n "${hostname}" ]; then
    printf '%s\n' "${hostname}" > "${root_dir}/etc/hostname"
    rc_add hostname boot
fi


# Set the time zone.
if [ -n "${timezone}" ]; then
    source_file="/usr/share/zoneinfo/${timezone}"
    del_tzdata=false
    if [ ! -f "${source_file}" ]; then
        del_tzdata=true
        apk_root add --virtual .setup-timezone tzdata
        source_file="${root_dir}${source_file}"
    fi
    add_file "${source_file}" "/etc/zoneinfo/${timezone}"
    ln -nfs "/etc/zoneinfo/${timezone}" "${root_dir}/etc/localtime"
    if [ "${del_tzdata}" = true ]; then
        apk_root del .setup-timezone
    fi
fi


command -v "setup" >/dev/null && "setup"


# Run module cleanup functions.
if [ -n "${modules}" ]; then
    for m in ${modules}; do
        command -v "cleanup_${m}" >/dev/null && "cleanup_${m}"
    done
fi


# Remove files not required on the live system.
# Run custom cleanup hook function.
command -v "cleanup" >/dev/null && "cleanup"
# Remove some packages.
for pkg in alpine-conf alpine-keys apk-tools; do
    case "${pkgs}" in
        "${pkg}") : ;;
        "${pkg} "*) : ;;
        *" ${pkg}") : ;;
        *" ${pkg} "*) : ;;
        *) erase_pkg "${pkg}" ;;
    esac
done
# Remove apk caches, config and state.
rm -rf -- "${root_dir}/var/cache/apk/" "${root_dir}/etc/apk/" "${root_dir}/lib/apk/"


# Make an overlay package from the root directory.
tar -czf "${output_file}" -C "${root_dir}" --exclude dev .
