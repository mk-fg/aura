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

See [project homepage](http://desktop-aura.sf.net/) for details.


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

* [colormath python module](http://code.google.com/p/python-colormath/) - to
	pick the most contrast color for label using CIEDE2000 (simplier algorithm
	will be used otherwise).

These are probably best to get using the package manager, but colormath
(pure-python module, no deps) can be installed with a simple "easy_install
colormath" or "pip colormath" command.

Project files can be downloaded from [this
page](http://sf.net/projects/desktop-aura/files/), just one latest .tar.gz will
do.
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
	  aura.sh [ -n | --next ] [ -f | --fave ] \
	    [ -b | --blacklist ] [ -k | --kill ] [ -h | --help ]

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

	~% head -17 aura
	#!/bin/bash

	## Options
	interval=$(( 3 * 3600 )) # 3h
	recheck=$(( 3600 )) # 1h
	activity_timeout=$(( 30 * 60 )) # 30min
	max_log_size=$(( 1024 * 1024 )) # 1M, current+last files are kept

	gimp_cmd="nice ionice -c3 gimp"

	wps_dir=~/.aura
	blacklist="$wps_dir"/blacklist
	log_err="$wps_dir"/picker.log
	log_hist="$wps_dir"/history.log
	log_curr="$wps_dir"/current
	pid="$wps_dir"/picker.pid

Also, see the beginning of a python plugin (lqr_wpset) for some image
processing options:

	max_aspect_diff = 0.5 # 16/9 - 4/3 = 0.444
	max_smaller_diff = 2 # don't process images N times smaller by area (w*h)
	min_prescale_diff = 0.3 # use cubic on larger images (preserving aspect), then lqr

	label_offset = 10, 10
	label_colors = [0]*3, [255]*3, (255, 0, 0),\
		(0, 255, 0), (0, 0, 255), (255, 255, 0), (0, 255, 255) # most contrast one will be chosen

	font_filename = 'URW Palladio L Medium', 16
	font_timestamp = 'URW Palladio L Medium', 11

	tmp_dir = '/tmp'

Not that there should be any need to change this stuff, but if there is - it's
just a shell/python.

I just put something like `aura -d ~/media/picz` into my ~/.xinitrc.


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
