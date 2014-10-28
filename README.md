Aura - clever desktop background setter tool for art appreciators
--------------------


Summary
--------------------

"aura" tool is a desktop (X root window) background setter, capable of:

* picking image randomly from specified paths;

* skipping too small images and images with too different aspect rate;

* rescaling it in a clever ways (crop solid margins, resize with cubic, then
	liquid rescale algorithm) to fit the desktop with as little quality loss
	as possible;

* labelling images (that is, rendering the label in the corner) using
	embedded tags;

* daemonizing to pick new image on a time-basis or when triggered (by SIGHUP
	or cli);

* keeping track of used images, blacklisting.

Intended usage is to point it to the path(s) with random image collection(s)
and let it adjust any suitable ones to the current screen size. It has no gui
and no capabilities to dowload images from anywhere.

See [old sf.net project homepage](http://desktop-aura.sf.net/) for more details.


Installation
--------------------

While "aura" script is pure bash, all image manipulations are performed from a
python script ("lqr_wpset.py") using gimp's python-fu.

Thus, some stuff must be installed for the tool to work:

* [bash](http://gnu.org/software/bash/)
* [python (2.6 or 2.7, not 3.X)](http://python.org/)
* [pygtk (2.X series, haven't tested with/ported to gi)](http://www.pygtk.org/)
* [gimp (2.6-2.8 or later, with python plugin support)](http://gimp.org/)
* [gimp-lqr-plugin](http://liquidrescale.wikidot.com/)

Everything aside from gimp-lqr-plugin is probably present in any decent
desktop linux system.

Optional stuff (will be used if available):

* [xprintidle tool](http://www.dtek.chalmers.se/~henoch/text/xprintidle.html)
	([debian mirror](http://packages.debian.org/sid/xprintidle), hosts sources
	as well) - to cycle images only when system is not idle (1h threshold, by
	default).

* [pyexiv2 python module](http://tilloy.net/dev/pyexiv2/) - to use information
	from EXIF/XMP/IDC tags in labels.

* [dbus-python
	module](http://www.freedesktop.org/wiki/Software/DBusBindings#dbus-python) -
	to set background in xfce and enlightenment (e17) window managers.

These are probably best to get with the distro package manager.

Project releases can be downloaded from
[this page](http://sf.net/projects/desktop-aura/files/),
just one latest .tar.gz will do.

Tarball can be extracted with regular double-click from some GUI (like GNOME
Nautilus shell, KDE Dolphin, XFCE Thunar, etc), tapping enter on it inside
midnight commander or typing "tar xf /path/to/aura-X.Y.tar.gz" in some shell.
Inside there are two files beside the ubiquitous "README" - "lqr_wpset.py" and
"aura".

Alternatively, newer sources can be checked-out from [github
repository](https://github.com/mk-fg/aura/).

Actual "installation" is needed for the gimp plugin (lqr_wpset.py), which should
be put into one of gimp plugin directories, like "~/.gimp-2.8/plug-ins/" (another
option is usually "/usr/lib/gimp/2.0/plug-ins", but your mileage may vary across
distros, read the gimp/distro docs if in doubt) and be marked as executable.
Here's what I mean:

	mkdir -p ~/.gimp-2.8/plug-ins/
	cp lqr_wpset.py ~/.gimp-2.8/plug-ins/
	chmod +x ~/.gimp-2.8/plug-ins/lqr_wpset.py

Bash script itself ("aura") will work from any path, just run it.


Usage
--------------------

To quote the command itself:

	~% aura -h
	Usage:
	  aura.sh paths...
	  aura.sh --favepick directory
	  aura.sh ( -d | --daemon ) [ --no-fork ] [ --no-init ] paths...
	  aura.sh [ -n | --next ] [ -c | --current ] \
	    [ -f | --fave ] [ -b | --blacklist ] [ -k | --kill ] [ -h | --help ]

	Set background image, randomly selected from the specified paths.
	Option --favepick makes it weighted-random among fave-list (see also --fave).
	Blacklisted paths never get picked (see --blacklist).

	Optional --daemon flag starts instance in the background (unless --no-fork is
	also specified), and picks/sets a new image on start (unless --no-init is specified),
	and every 10800s afterwards.

	Some options (or their one-letter equivalents) can be given instead of paths to
	control already-running instance (started with --daemon flag):
	  --next       cycle to then next background immediately.
	  --fave       give +1 rating (used with --favepick) to current background image.
	  --blacklist  add current background to blacklist (skip it from now on).
	  --kill       stop currently running instance.
	  --current    echo current background image name
	  --help       this text

	Various paths and parameters are specified in the beginning of this script.

...and mentioned "beginning of this script" is:

	~% head -50 aura
	#!/bin/bash

	### Options start

	interval=$(( 3 * 3600 )) # 3h
	recheck=$(( 3600 )) # 1h
	activity_timeout=$(( 30 * 60 )) # 30min
	max_log_size=$(( 1024 * 1024 )) # 1M, current+last files are kept

	gimp_cmd="nice ionice -c3 gimp"

	...

	# Resets sleep timer in daemon (if running) after oneshot script invocation
	delay_daemon_on_oneshot_change=true # empty for false

	[[ -r ~/.aurarc ]] && source ~/.aurarc

	### Options end

Note that any of the option defaults listed there can be overidden in ~/.aurarc
file, e.g. to enable caching for rescaled images and change cache size/cleanup,
put these lines there:

	cache_enabled=t
	cache_cleanup_keep=$(( 1000 * 2**20 ))
	cache_cleanup_chance=5

Also, see the beginning of a python plugin (lqr_wpset) for some image
processing options.
As mentioned there, these can be overidden via `LQR_WPSET_*` env vars.

Script can be enabled for desktop session by putting something like `aura -d
~/media/picz` into ~/.xinitrc, or via whatever systemd user session unit.


Copying
--------------------

Images used in html documentation are subject to a copyright and used with
author's permission.

Code is released under a permissive WTFPL license, feel free to hack and reuse
it as you see fit.


Links
--------------------

* [Project homepage](http://desktop-aura.sf.net/)
* [Sourceforge project page](http://sf.net/projects/desktop-aura/)
* [github repository](https://github.com/mk-fg/aura/)
* [File releases (aka "Downloads")](http://sf.net/projects/desktop-aura/files/)
