APK Overlay Builder
===================

The purpose of this script is building an overlay archive for
[Alpine Linux](https://alpinelinux.org/) network boot.

It supports various basic customization options as well as installing packages
into the overlay, starting services at boot and adding arbitrary custom files.
It is possible to build cross-architecture overlays if the appropriate
[QEMU](https://www.qemu.org/) user-mode package is installed and `binfmt` is
set up correctly.


Usage
-----

```
build-ovl.sh [-c <path>]
Alpine overlay build script.
Options:
  -c, --config path
    Read the configuration file at path.
  -h, --help
    Show this help message and exit.
```

Host the resulting `.tar.gz` archive on some web server and point to `apkovl`
kernel command line parameter to it to make Alpine's initramfs download if and
set it up as the root file system.

**Important**: This script only works when the build environment runs Alpine
Linux. It does work in an Alpine-based container, though.
When running in a container and building a cross-architecture overlay, note
that QEMU and `binfmt` need to be set up on the host, not inside the container.


Configuration
-------------

The configuration file follows Busybox ash syntax (an extension of POSIX shell
syntax) and therefore inherits all the powers and limitations of shell
scripting.
In the simplest case, it consists of assignments of values to variables in the
following format (note that spaces around the `=` are not allowed):
```sh
variable=value
```

The following configuration options are respected by the core script.
[Modules](#modules) add their own options, that are described further below.

* `mirror`  
  APK mirror URL to use when installing packages.
  Defaults to the first URL from the builder's `/etc/apk/repositories`.
* `alpine_release`  
  Alpine release (i.e. version) to base the overlay on.
  When using a specific version number, it must start with `v` (e.g. `v3.20`).
  Default is `latest-stable`.
* `target_arch`  
  Install packages for this architecture into the overlay.
  The builder must be able to run binaries of this architecture.
  If it is not the builder's native architecture, that means installing the
  respective QEMU user-mode package and setting up `binfmt` accordingly.
  Defaults to the architecture from the builder's `/etc/apk/arch`.
* `output_file`  
  Path where the resulting overlay archive is saved.
  Default is `overlay.tar.gz` in the current working directory at runtime.
* `modules_dir`  
  Directory containing builder modules.
  See `modules` below.
  Default is `modules/` in the same directory, where `build-ovl.sh` is located.
* `module_files_dir`  
  Directory containing additional files required by builder modules.
  Default is `module-files/` in the same directory, where `build-ovl.sh` is located.
* `files_dirs`  
  A list of directories containing supplementary files.
  See `files` below.
  Default is `files/` in the same directory, where `build-ovl.sh` is located.
* `root_size`  
  Size of the running system's tmpfs root file system in MiB.
  Not set by default, which means that the system determines the size (usually half of the available RAM).
* `modules`  
  A list of builder modules to enable.
  See [Modules](#modules) below for a list.
  Optional.
* `pkgs`  
  A list of Alpine packages to install.
  Optional.
* `files`  
  A list of supplementary file archives to add to the overlay.
  They must be tar archives and stored in `files_dir`.
  These archives are extracted into the root directory of the overlay.
  Files within must therefore be stored with the desired paths, ownership and mode.
  Optional.
* `services`  
  A list of system services to start on boot.
  Use this to enable services installed by installed packages, for example.
  Optional.
* `default_services`  
  Enable all of Alpine's default services during boot.
  Default is `false`.
* `rc_parallel`  
  Whether to enable OpenRC's `rc_parallel` option in `/etc/rc.conf`.
  Doing so allows services to start in parallel, which may result in faster startup times.
  Default is `false`.
* `hostname`  
  Host name for the system running from the overlay.
  Not set by default, which means that the initramfs determines the host name.
* `timezone`  
  Time zone to set for the system running from the overlay.
  Default is the time zone from the builder's `/etc/localtime`.
* `ntp_servers`  
  A list of NTP servers to synchronize the system clock with on start up.
  Setting this value automatically enables the `ntpd` service.
  If this service is enabled without setting `ntp_servers`, it synchronizes the
  system clock with it's default server(s).
* `root_password`  
  The password to set for the `root` user account within the overlay.
  May be given in plain text or as a hash in `crypt` format.
  Note: Passwords starting with `$` are assumed to be in `crypt` format. Plain
  text password may therefore not start with `$`.
  By default, no password gets set for the `root` user.

In addition to these variables, the configuration file also supports two hook
functions, which allow customizing the overlay package further.
The functions must be named `setup` and `cleanup`.
Just like the configuration file itself, they are Busybox ash syntax.

The `setup` function runs after all other setup sets have completed, i.e.
packages are installed, supplementary file archives extracted, etc.
Its purpose is to make adjustments to the overlay package that can not (easily)
handled by the configuration options above.

The `cleanup` function runs after all module cleanup function have completed
but before removing the package manager and other basic Alpine functionality.
The purpose of the `cleanup` function is to remove unwanted files from the
overlay in order to reduce its size or limit its functionality.

**Important**: Both function run in the build system environment and therefore have
full access to it. To access files in the overlay, their paths must be prefixed
with `$root_dir`!

In addition to the commands installed on the build system, the following custom
commands can be used within these functions:

* `add_file <source> <destination>`  
  Adds a file to the overlay.
  `source` is the path on the build system or the URL of the file to add.
  `destination` is the path within the overlay package to which the file will
  be saved.
* `apk_root <pkg> ...`  
  Install one or more Alpine packages into the overlay.
  Prefer using the `pkgs` option, if possible.
* `erase_pkg <pkg> ...`  
  Remove one or more installed Alpine packages without formally uninstalling
  them (and all of their reverse dependencies).
* `rc_add <service> <runlevel>`  
  Add the service `service` to the OpenRC runlevel `runlevel`, i.e. make it run
  at boot.
  Prefer using the `services` option, if possible.


Modules
-------

### ACME

This module handles requesting an X.509 certificate from a Certificate
Authority that supports the ACME protocol. It uses
[uacme](https://github.com/ndilieto/uacme).
The certificate is requested on boot only and not renewed later on.

* `acme_base_dir`  
  The directory where uacme stores the certificate and private key.
  Refer to [uacme's documentation](https://ndilieto.github.io/uacme/uacme.html)
  for the sub-directory structure uacme sets up.
  Enable the [`persistence`](#persistence) module and set `acme_base_dir` to a
  path below `persistence_mountpoint` in order to keep certificates across
  reboots. This may significantly reduce boot times.
  Defaults to `/etc/ssl/uacme/`.
* `acme_identities`  
  A list of identities (i.e. DNS names) for which to request a certificate.
  If not set, a certificate is requested for the system's host name at run
  time.
* `acme_url`  
  The URL of the Certificate Authority's ACMEv2 server directory.
  If not set, the default is determined by uacme (Let's Encrypt, at the time of
  this writing).
* `acme_staging`  
  Request a certificate from Let's Encrypt's staging environment.
  This is for testing and ignored if `acme_url` is set.
  Defaults to `false`.
* `acme_account_key`  
  Location of an ACME account private key file in PEM format.
  May be either a path on the target device or a URL.
  In the latter case, the key file is retrieved during boot.
  If getting the key file requires authentication, set up the `root` user's
  `.netrc` as described in the documentation for the [`fetch`](#fetch) module.
  If not set, a new account is created on boot. Unless `acme_base_dir` is on
  persistent storage, this means that a new account is created on each boot.
* `acme_account_email`  
  The contact e-mail address for any ACME accounts created by this module.
  Ignored if `acme_account_key` is set.
  Optional.
* `acme_profile`  
  Request a certificate with this profile from the Certificate Authority.
  Supported values depend on the Certificate Authority.
  Optional.
* `acme_key_type`  
  The type of key to use for the account key as well as X.509 certificate's
  private key.
  One of `RSA` or `EC`.
  If not set, the default is determined by uacme.
* `acme_key_bits`  
  Length of any newly generated keys in bits.
  Default as well as allowed values depend on `acme_key_type`.
* `acme_renew_days`  
  Existing certificates will get renewed on boot if they would expire within
  this many days.
  If not set, the ACME server is queried for renewal information.
* `acme_hook`  
  Location of a uacme hook script that handles the ACME challenge on
  certificate issuance or renewal.
  May be either a path on the building system or a URL.
  Relative paths are interpreted as relative to the `module_files_dir`.
  Mandatory.
* `acme_hook_creds_file`  
  Location of a file containing credentials required by the `acme_hook` script.
  May be either a path on the target device or a URL.
  In the latter case, the credential file is retrieved during boot.
  If getting the credential file requires authentication, set up the `root`
  user's `.netrc` as described in the documentation for the [`fetch`](#fetch)
  module.
  Optional, but the hook script may not work without credentials.


### Fetch

This module installs `fetch.sh`, a simple wrapper script around `wget` that
transparently adds HTTP basic authentication credentials to every request.

The user name and password are taken from the user's `~/.netrc`.
This file must contain one or more lines of the following format:
```
machine <FQDN> login <USER> password <PASSWORD>
```
It may also contains a fall back line of the following format:
```
default login <USER> password <PASSWORD>
```

When making a request using `fetch.sh`, the host name in the URL is compared to
the `FQDN` values in `~/.netrc` to select the appropriate line. If no line match,
the fall back line is used, if it is present.
`fetch.sh` will send `USER` as the user name and `PASSWORD` as the password. If
`PASSWORD` starts with `file://`, it is interpreted as the path to a file
containing the password.

Other modules will be transparently enabled the `fetch` module, if they require
it. In this case, there is no need to enable it manually. However, it is
necessary to set up the `.netrc` file, possibly using the `files` configuration
option.

In addition to the `fetch.sh` command, this module optionally also installs a
system service that can be use to download files on system boot.
To enable and use it, simply define the files to download as follows:

* `fetch_on_boot`  
  A space separated list of files to download on boot using `fetch.sh`.
  Each list item must be formatted like the following:  
  `url|path|owner|group|mode`  
  The meaning of these values is:
  * `url`  
    The URL from which to download the file.
    Mandatory.
  * `path`  
    The local path where to store the downloaded file.
    Mandatory.
  * `owner`  
    Set the file's owner to this system user.
    Optional.
  * `group`  
    Set the file's group to this system group.
    Optional.
  * `mode`  
    Set the file's access permissions to this value.
    May be given as symbolic or numeric permission mode.
    Optional.

### Firmware Update

This module installs a system service that checks for a firmware update on boot
and installs it, if necessary.
Firmware update files must be (possibly compressed) tar archives, suitable for extracting directly onto the mounted firmware partition.

* `firmware_update_partition`  
  The path of the firmware partition device.
  As part of the update process, the partition will be mounted and files will
  be replaced with nwe or changed files from the firmware update archive.
  On Raspberry Pi systems, A/B firmware partitions will be transparently
  detected if `autoboot.txt` is on this partition.
  Defaults to `/dev/mmcblk0p1`.
* `firmware_update_local_version_file`  
  The path to a file holding the locally installed firmware version.
  Relative paths are interpreted as relative to the mounted firmware partition (cf. `firmware_update_partition`).
  Optional.
  When not set, a firmware update is done on each boot, regardless if the firmware versions differ or not.
* `firmware_update_remote_version_url`  
  A URL that returns the version of the firmware to download and install (if it differs from the local version, cf. `firmware_update_local_version_file`).
  Mandatory.
* `firmware_update_url`  
  The download URL for the latest firmware update package.
  The placeholder `$version` in the URL will be replaced by the version number returned by `firmware_update_remote_version_url`.
  Mandatory.

### Persistence

This module sets up a partition for persistent storage, i.e. to preserve files
across reboots. It respects the following configuration options:

* `persistence_partition`  
  Device name for the persistence partition.
  It if does not exist on boot, it will be created with the configured parameters.
  Mandatory.
* `persistence_size`  
  The size of the persistence partition in MiB.
  Defaults to `256`.
* `persistence_keyfile`  
  Location of a LUKS key file with which the persistence partition is encrypted.
  May be either a path on the target device or a URL.
  In the latter case, the key file is retrieved during boot.
  If getting the key file requires authentication, set up the `root` user's
  `.netrc` as described in the documentation for the [`fetch`](#fetch) module.
  If `persistence_keyfile` is not set, the persistence partition is created and
  used without encryption.
  Optional.
* `persistence_high_entropy_key`  
  Whether the `persistence_keyfile` contains a strong, high entropy key.
  If it does, a weak but fast key derivation function is used during LUKS
  setup. This may significantly reduct boot time on low powered devices.
  Ignored if `persistence_keyfile` is not set.
  Defaults to `false`.
* `persistence_luksformat_args`  
  Command line argument to pass to `cryptsetup luksFormat` when initially
  encrypting the persistence partition.
  Ignored if `persistence_keyfile` is not set.
  Defaults to `--type luks2 --use-urandom --sector-size 4096 --cipher xchacha12,aes-adiantum-plain64`.
* `persistence_fs`  
  The type of file system to create on the persistence partition.
  Supported file systems are `btrfs`, `ext2`, `ext3`, `ext4` and `xfs`.
  Defaults to `ext4`.
* `persistence_mountpoint`  
  Path where the persistence partition gets mounted.
  Defaults to `/mnt/persistence`.
