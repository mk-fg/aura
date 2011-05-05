#!/usr/bin/env python
# -*- coding: utf-8 -*-
from __future__ import unicode_literals, print_function

####################

# Usage examples:
# cp lqr_wpset.py ~/.gimp-2.6/plug-ins/ && chmod +x ~/.gimp-2.6/plug-ins/lqr_wpset.py
# gimp -ib '(python-fu-lqr-wpset RUN-NONINTERACTIVE "file.jpg") (gimp-quit TRUE)'
# gimp -ib '(catch (gimp-message "WS-ERR_FAIL")
# 		(gimp-message-set-handler ERROR-CONSOLE)
# 		(python-fu-lqr-wpset RUN-NONINTERACTIVE "file.jpg"))
# 	(gimp-quit TRUE)' 2>&1 1>/dev/null | tee log | grep WS-ERR

__author__ = 'Mike Kazantsev'
__copyright__ = 'Copyright 2011, Mike Kazantsev'
__license__ = 'Public Domain'
__version__ = '0.10'
__email__ = 'mk.fraggod@gmail.com'
__status__ = 'beta'
__blurb__ = 'LQRify to desktop'
__description__ = 'LQR-rescale image to desktop size and set as a background.'

max_aspect_diff = 0.7 # 16/9 - 4/3 = 0.444
max_smaller_diff = 3 # don't process images N times smaller by area (w*h)
min_prescale_diff = 0.3 # use cubic on larger images (preserving aspect), then lqr
label_offset = 10, 10
label_colors = [0]*3, [255]*3, (255, 0, 0),\
	(0, 255, 0), (0, 0, 255), (255, 255, 0), (0, 255, 255) # most contrast one will be chosen
font_filename = 'URW Palladio L Medium', 16
font_timestamp = 'URW Palladio L Medium', 11
result_path = '/tmp/.lqr_wpset_bg.png'

# see also extra-bulky "label_tags" definition in the script's tail
####################


### Body of a plugin

import itertools as it, operator as op, functools as ft
from datetime import datetime
from tempfile import mkstemp
from gtk import gdk
import os, sys, collections

from gimpfu import *
import gimp

def process_tags(path):
	meta = dict()
	try: import pyexiv2
	except ImportError: pass # TODO: gimp is capable of parsing XMP on it's own
	else:
		try:
			tags = pyexiv2.ImageMetadata(path)
			tags.read()
		except AttributeError: # pyexiv2 <=1.3
			tags = pyexiv2.Image(path)
			tags.readMetadata()
		for spec in label_tags:
			label, tag_ids = spec[:2]
			for tag_id in tag_ids:
				try:
					try: meta[label] = tags[bytes(tag_id)]
					except IndexError: raise KeyError # older pyexiv2
					try: meta[label] = meta[label].human_value
					except AttributeError:
						try: meta[label] = meta[label].value
						except AttributeError: pass
					if not meta[label]: raise KeyError # skip empty entries
					if isinstance(meta[label], dict) and 'x-default' in meta[label]:
						meta[label] = meta[label]['x-default']
					if isinstance(meta[label], collections.Sequence)\
						and len(meta[label]) == 1: meta[label] = meta[label][0]
					meta[label] = unicode(meta[label]).strip()
					if meta[label] in label_tags_discard:
						del meta[label]
						raise KeyError
				except KeyError: pass
				else: break
	return meta

def pick_contrast_color(bg_color):
	try: from colormath.color_objects import RGBColor
	except ImportError: # use simple sum(abs(R1-R2), ...) algorithm
		color_diffs = dict((sum( abs(c1 - c2) for c1,c2 in
			it.izip(bg_color, color) ), color) for color in label_colors)
	else: # CIEDE2000 algorithm, if available (see wiki)
		color_bg_diff = RGBColor(*bg_color).delta_e
		color_diffs = dict(
			(color_bg_diff(RGBColor(*color)), color)
			for color in label_colors )
	return tuple(color_diffs[max(color_diffs)])


def set_background(path):
	# Note that the path is not unlinked, because gconf and xfconf set bg
	#  asynchronously, so there's no way of knowing when the image will
	#  actually be used

	## Gconf - GNOME, XFCE/nautilus and such
	try:
		import gconf
		gconf = gconf.client_get_default()
		gconf.set_string(
			'/desktop/gnome/background/picture_filename', path )
	except ImportError: pass

	## Xfconf (via dbus interface) - XFCE/xfdesktop
	try: import dbus
	except ImportError: pass
	else:
		try:
			xfconf = dbus.Interface(
				dbus.SessionBus().get_object(
					'org.xfce.Xfconf', '/org/xfce/Xfconf' ),
				dbus_interface='org.xfce.Xfconf' )
			for k,v in xfconf.GetAllProperties('xfce4-desktop', '/backdrop').iteritems():
				if k.endswith('/image-path'): xfconf.SetProperty('xfce4-desktop', k, path)
		except dbus.exceptions.DBusException: pass # no property/object/interface/etc

	## Paint X root window via pygtk
	pb = gdk.pixbuf_new_from_file(path)
	pm, mask = pb.render_pixmap_and_mask()
	win = gdk.get_default_root_window()
	win.set_back_pixmap(pm, False)
	win.clear()
	win.draw_pixbuf(gdk.GC(win), pb, 0, 0, 0, 0, -1, -1)


def lqr_wpset(path):
	image = pdb.gimp_file_load(path, path)
	layer_image = image.active_layer
	w, h = gdk.screen_width(), gdk.screen_height()
	bak_colors = gimp.get_foreground(), gimp.get_background()

	## Crop black margins
	# ...by adding a layer, making it more contrast (to drop noise on margins),
	#  then cropping the layer and image to the produced layer size
	layer_guide = image.active_layer.copy()
	image.add_layer(layer_guide, 1)
	pdb.gimp_brightness_contrast(layer_guide, -30, 30)
	pdb.plug_in_autocrop_layer(image, layer_guide) # should crop margins on layer
	pdb.gimp_image_crop( image,
		layer_guide.width, layer_guide.height,
		layer_guide.offsets[0], layer_guide.offsets[1] )
	image.remove_layer(layer_guide)

	## Check whether size/aspect difference isn't too great
	aspects = float(w)/h, float(image.width)/image.height
	diff_aspect = abs(aspects[0] - aspects[1])
	diff_size = float(image.width * image.height) / (w*h)
	if diff_aspect > max_aspect_diff or diff_size < 1.0/max_smaller_diff:
		pdb.gimp_message( 'Aspect diff: {0:.2f} (max: {1:.2f}), size diff: {2:.2f} (min: {3:.2f})'\
			.format(diff_aspect, max_aspect_diff, diff_size, 1.0/max_smaller_diff) )
		pdb.gimp_message('WPS-ERR:next')
		return

	## Metadata: image name, data from image parasite tags and/or file mtime
	meta_base = { 'title': os.path.basename(path),
		'created': datetime.fromtimestamp(os.stat(path).st_mtime),
		'original size': '{0} x {1}'.format(*op.attrgetter('width', 'height')(image)) }
	meta = process_tags(path)\
		if set(image.parasite_list())\
			.intersection(['icc-profile', 'jpeg-settings',
				'exif-data', 'gimp-metadata'])\
		else dict()
	for spec in label_tags:
		try: label, conv = op.itemgetter(0, 2)(spec)
		except IndexError: label, conv = spec[0], lambda x: x
		if meta.get(label): # try to use tags whenever possible
			try: meta[label] = '{0} (tag)'.format(conv(meta[label]))
			except: meta[label] = '{0} (raw tag)'.format(meta[label])
		else:
			if label in meta: del meta[label] # empty tag (shouldn't really happen here)
			try:
				spec = conv(meta_base.get(label))
				if not spec: raise KeyError
				meta_base[label] = unicode(spec)
			except:
				if label in meta_base:
					meta_base[label] = '{0} (raw)'.format(meta_base[label])
	meta_base.update(meta)
	meta = meta_base

	## Rescaling
	# Pre-LQR rescaling, preserving aspect
	# Improves quality and saves a lot of jiffies
	if diff_size > min_prescale_diff:
		new_size = map( lambda x: round(x, 0),
			(image.width - (image.height - h) * aspects[1], h)\
			if aspects[1] > aspects[0] else\
			(w, image.height - (image.width - w) / aspects[0]) )
		pdb.gimp_image_scale_full( image,
			new_size[0], new_size[1], INTERPOLATION_CUBIC )
	# All but the first 4 parameters are defaults, taken from batch-gimp-lqr.scm
	pdb.plug_in_lqr( image, layer_image, w, h,
		0, 1000, 0, 1000, 0, 0, 1, 150, 1, 1, 0, 0, 3, 0, 0, 0, 0, 1, '', '', '', '' )

	## Render label on top of the image layer
	# First, render all the the text boxes
	# Image title, larger than the rest of the tags
	label_title = pdb.gimp_text_fontname( image, layer_image,
		label_offset[0], label_offset[1], meta.pop('title'),
		-1, True, font_filename[1], PIXELS, font_filename[0] )
	pdb.gimp_floating_sel_to_layer(label_title)
	# Tags, ordered according to label_tags
	meta = list( (label, meta.pop(label))
		for label in it.imap(op.itemgetter(0), label_tags)
		if label in meta ) + list(meta.iteritems())
	offset_layer = 0.5 * font_timestamp[1]
	offset_y = label_title.offsets[1] + label_title.height + offset_layer
	label_keys = pdb.gimp_text_fontname( image, layer_image,
		label_title.offsets[1] + 3 * font_timestamp[1], offset_y,
		'\n'.join(it.imap(op.itemgetter(0), meta)),
		-1, True, font_timestamp[1], PIXELS, font_timestamp[0] )
	pdb.gimp_floating_sel_to_layer(label_keys)
	label_vals = pdb.gimp_text_fontname( image, layer_image,
		label_keys.offsets[0] + label_keys.width + offset_layer, offset_y,
		'\n'.join(it.imap(op.itemgetter(1), meta)),
		-1, True, font_timestamp[1], PIXELS, font_timestamp[0] )
	pdb.gimp_floating_sel_to_layer(label_vals)
	label_layers = label_title, label_keys, label_vals

	# Find average color within the label_geom box
	#  and pick the most distant color from label_colors
	label_geom = tuple(( layer.offsets + op.attrgetter(
		'width', 'height')(layer) ) for layer in label_layers)
	label_geom = label_offset + tuple( # (offsets + dimensions)
		max((g[i] + g[2+i] - label_offset[i]) for g in geoms)
		for i,geoms in enumerate([label_geom]*2) )
	pdb.gimp_rect_select( image,
		label_geom[0], label_geom[1],
		label_geom[2], label_geom[3],
		CHANNEL_OP_REPLACE, False, 0 )
	label_bg_color = tuple(
		int(round(pdb.gimp_histogram(layer_image, channel, 0, 255)[0], 0)) # mean intensity value
		for channel in [HISTOGRAM_RED, HISTOGRAM_GREEN, HISTOGRAM_BLUE] )
	label_fg_color = pick_contrast_color(label_bg_color)
	gimp.set_foreground(label_fg_color), gimp.set_background(label_bg_color)
	# Set the picked color for all label layers, draw outlines
	label_outline = image.new_layer( 'label_outline',
		opacity=30, pos=image.layers.index(layer_image) )
	for layer in label_layers:
		pdb.gimp_text_layer_set_color(layer, label_fg_color)
		path = pdb.gimp_vectors_new_from_text_layer(image, layer)
		pdb.gimp_image_add_vectors(image, path, -1)
		pdb.gimp_vectors_to_selection(path, CHANNEL_OP_REPLACE, True, False, 0, 0)
		pdb.gimp_selection_grow(image, 1), pdb.gimp_selection_border(image, 1)
		pdb.gimp_edit_fill(label_outline, BACKGROUND_FILL)
	# Meld all the layers together
	image.flatten()

	## Save image to a temporary file and set it as a bg
	# Relying on underlying os /tmp cleanup mechanisms here
	pdb.gimp_file_save(image, image.active_layer, result_path, result_path)
	set_background(result_path)

	## Restore gimp state
	pdb.gimp_image_delete(image)
	gimp.set_foreground(bak_colors[0]), gimp.set_background(bak_colors[1])


### Extra bulky metadata

# Fields to display on label
# First nonempty tag on the list will be used for a label, unfilled entries will be hidden
# Optional third element is a conversion/autofill function, see "set", "created"
# Pre-initialized fields are "title" (file basename), "created" (file mtime as datetime)
# All the fields are taken from here: http://www.exiv2.org/metadata.html
ts_format = '%H:%M %d.%m.%Y' # just for conversion funcs below
label_tags = [
	('title', [ 'Xmp.dc.title',
			'Xmp.xmp.Label',
			'Exif.Image.XPTitle',
			'Xmp.iptcExt.AOTitle',
			'Xmp.tiff.ImageDescription',
			'Exif.Image.ImageDescription',
			'Xmp.dc.description' ],
		lambda title: title if not isinstance(title, dict)\
			else ', '.join(title.itervalues())),
	('author', [ 'Exif.Image.Artist',
			'Xmp.dc.creator',
			'Xmp.xmpRights.Owner',
			'Xmp.plus.CopyrightOwnerName',
			'Xmp.plus.ImageCreatorName',
			'Xmp.iptcExt.AOCreator',
			'Exif.Image.XPAuthor',
			'Xmp.digiKam.CaptionsAuthorNames',
			'Iptc.Application2.Credit',
			'Xmp.photoshop.Credit',
			'Xmp.plus.ImageSupplierName',
			'Xmp.dc.contributor',
			'Xmp.dc.publisher',
			'Exif.Canon.OwnerName',
			'Xmp.expressionmedia.People',
			'Xmp.mediapro.People' ]),
	('created', [ 'Exif.Image.DateTime',
			'Xmp.xmp.CreateDate',
			'Xmp.iptcExt.AODateCreated',
			'Exif.Image.DateTimeOriginal',
			'Xmp.exif.DateTimeOriginal',
			'Xmp.dc.date', 'Xmp.photoshop.DateCreated',
			'Xmp.tiff.DateTime',
			'Xmp.MicrosoftPhoto.DateAcquired',
			'Exif.Pentax.Date',
			'Exif.MinoltaCsNew.MinoltaDate'
			'Iptc.Application2.DateCreated',
			'Xmp.plus.FirstPublicationDate',
			'Iptc.Application2.ReleaseDate',
			'Xmp.digiKam.CaptionsDateTimeStamps',
			'Xmp.xmp.ModifyDate',
			'Exif.GPSInfo.GPSDateStamp'
			'Iptc.Envelope.DateSent',
			'Exif.Panasonic.WorldTimeLocation' ],
		lambda ts: ( datetime.strptime(ts, '%Y:%m:%d %H:%M:%S')
			if not isinstance(ts, datetime) else ts).strftime(ts_format)),
	('set', [], lambda ts: datetime.now().strftime(ts_format)) ]

# Stuff that should never appear in the label
label_tags_discard = set(['SONY DSC', 'OLYMPUS DIGITAL CAMERA'])


### Gimp plugin boilerplate
register(
	'lqr_wpset',
	__blurb__, __description__,
	__author__, __copyright__,
	'2011',
	'<Toolbox>/Xtns/Languages/Python-Fu/LQRify to desktop',
	'RGB*',
	[(PF_FILE, 'file_name', 'Input file name', '')], [],
	lqr_wpset )
main()
