1. build kiss linux core with kiss (pm)
2. clean port to osh
3. build installer iso
5. port more packages over to osh
6. build updated wayland and firefox
7. start simplifying
   - would be nice to port away from autoconf, m4, etc.
   - use busybox as much as possible

The dream is to further shrink the required userland to the most
elemental tools and have `osh` builtins replace most of the individual
text processing stuff - a coreutils-less distribution if you will.
The vision is that shell builtins can replace the need for many
individual traditional unix userland binaries - you boot to linux
and the shell and the only other userland is the package manager itself
which is just a shell script, and busybox (for now). That alone is
enough to ntpd, ip, dhcpcd and start downloading and building packages.

The idea behind using `osh` is that the shell should be powerful and
expressive enough that it can be a capable enough language for
gluing together the rest of the system. No system perl, no python, etc.

