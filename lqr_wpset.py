#!/usr/bin/env python
# -*- coding: utf-8 -*-
from __future__ import unicode_literals, print_function

####################

# Usage examples:
# gimp -ib '(python-fu-lqr-wpset RUN-NONINTERACTIVE "file.jpg") (gimp-quit 0)'
# gimp -ib '(catch (gimp-message "WS-ERR_FAIL")
# 		(gimp-message-set-handler ERROR-CONSOLE)
# 		(python-fu-lqr-wpset RUN-NONINTERACTIVE "file.jpg"))
# 	(gimp-quit TRUE)' 2>&1 1>/dev/null | tee log | grep WS-ERR

__author__ = 'Mike Kazantsev'
__copyright__ = 'Copyright 2010, Mike Kazantsev'
__license__ = 'BSD'
__version__ = '0.1'
__email__ = 'mk.fraggod@gmail.com'
__status__ = 'alpha'
__blurb__ = 'LQRify to desktop'
__description__ = 'LQR-rescale image to desktop size and set as a background.'

max_aspect_diff = 0.5 # 16/9 - 4/3 = 0.444
max_smaller_diff = 2 # don't process images N times smaller by area (w*h)
label_offset = 10, 10
label_colors = (255, 0, 0), (0, 255, 0), (0, 0, 255) # most contrast one will be chosen
timestamp_format = '%H:%M %d.%m.%Y' # None to disable
font_filename = 'URW Palladio L Medium', 16
font_timestamp = 'URW Palladio L Medium', 11
tmp_dir = '/tmp'

####################


import itertools as it, operator as op, functools as ft
from datetime import datetime
from tempfile import mkstemp
import os, sys, gtk

from gimpfu import *
import gimp


def lqr_wpset(path):
	image = pdb.gimp_file_load(path, path)
	layer_image = image.active_layer
	w, h = gtk.gdk.screen_width(), gtk.gdk.screen_height()

	## Crop black margins
	# ...by adding a layer, making it more contrast (to drop noise on margins),
	#  then cropping the layer and image to the produced layer size
	layer_guide = image.active_layer.copy()
	image.add_layer(layer_guide, 1)
	pdb.gimp_brightness_contrast(layer_guide, -20, 20)
	pdb.plug_in_autocrop_layer(image, layer_guide) # should crop margins on layer
	pdb.gimp_image_crop( image,
		layer_guide.width, layer_guide.height,
		layer_guide.offsets[0], layer_guide.offsets[1] )
	image.remove_layer(layer_guide)

	## Check whether size/aspect difference isn't too great
	diff_aspect = abs(float(w)/h - float(image.width)/image.height)
	diff_size = float(image.width*image.height) / (w*h)
	if diff_aspect > max_aspect_diff or diff_size < 1.0/max_smaller_diff:
		pdb.gimp_message( 'Aspect diff: {:.2f} (max: {:.2f}), size diff: {:.2f} (min: {:.2f})'\
			.format(diff_aspect, max_aspect_diff, diff_size, 1.0/max_smaller_diff) )
		pdb.gimp_message('WPS-ERR:next')
		return

	## Metadata: get image timestamp from parasite tags or file mtime
	ts, meta = None, image.parasite_list()
	if 'exif-data' in meta: # EXIF
		from EXIF import process_file
		ts = process_file(open(path))#, stop_tag='DateTime')
		ts = ts.get('Image DateTime') or ts.get('EXIF DateTimeOriginal')
	# XMP parsing seem to invariably fail with my current gimp version, no idea why
	# if not ts and 'gimp-metadata' in meta: # XMP
	# 	try:
	# 		print(pdb.plug_in_metadata_get_simple(image, 'dc', 'Date'))
	# 		print(pdb.plug_in_metadata_get_simple(image, 'xmpMM', 'HistoryWhen'))
	# 		print(pdb.plug_in_metadata_get_simple(image, 'http://purl.org/dc/elements/1.1/', 'Date'))
	# 	except RuntimeError: pass # these seem to be quite common with XMP metadata
	ts, ts_src = (datetime.strptime(str(ts), '%Y:%m:%d %H:%M:%S'), 'exif')\
		if ts else (datetime.fromtimestamp(os.stat(path).st_mtime), 'mtime')

	## All but the first 4 parameters are defaults, taken from batch-gimp-lqr.scm
	pdb.plug_in_lqr( image, layer_image, w, h,
		0, 1000, 0, 1000, 0, 0, 1, 150, 1, 1, 0, 0, 3, 0, 0, 0, 0, 1, '', '', '', '' )

	## Render label on top of the image layer
	# first, render all the the text boxes
	label_name = pdb.gimp_text_fontname( image, layer_image,
		label_offset[0], label_offset[1], os.path.basename(path),
		-1, True, font_filename[1], PIXELS, font_filename[0] )
	pdb.gimp_floating_sel_to_layer(label_name)
	if timestamp_format:
		offset_layer = 0.5 * font_timestamp[1]
		offset_y = label_name.offsets[1] + label_name.height + offset_layer
		label_tsl = pdb.gimp_text_fontname( image, layer_image,
				label_name.offsets[1] + 3 * font_timestamp[1], offset_y,
				'created:\nset:', -1, True, font_timestamp[1], PIXELS, font_timestamp[0] )
		pdb.gimp_floating_sel_to_layer(label_tsl)
		label_ts = pdb.gimp_text_fontname( image, layer_image,
				label_tsl.offsets[0] + label_tsl.width + offset_layer, offset_y,
				'{} ({})\n{}'.format( ts.strftime(timestamp_format), ts_src,
					datetime.now().strftime(timestamp_format) ),
				-1, True, font_timestamp[1], PIXELS, font_timestamp[0] )
		pdb.gimp_floating_sel_to_layer(label_ts)
		label_layers = label_name, label_tsl, label_ts
	else: label_layers = label_name,

	# find average color within the label_geom box
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
	try: from colormath.color_objects import RGBColor
	except ImportError: # use simple sum(abs(R1-R2), ...) algorithm
		color_diffs = dict((sum( abs(c1 - c2) for c1,c2 in
			it.izip(label_bg_color, color) ), color) for color in label_colors)
	else: # CIEDE2000 algorithm, if available (see wiki)
		color_bg_diff = RGBColor(*label_bg_color).delta_e
		color_diffs = dict(
			(color_bg_diff(RGBColor(*color)), color)
			for color in label_colors )
	color = color_diffs[max(color_diffs)]
	# set the picked color for all the label layers, meld all the layers together
	for layer in label_layers: pdb.gimp_text_layer_set_color(layer, color)
	image.flatten()

	## Save image to a temporary file and load it into a gdk pixbuffer
	fd, tmp_file = mkstemp(prefix='gimp.', suffix='.png', dir=tmp_dir)
	try:
		pdb.gimp_file_save(image, image.active_layer, tmp_file, tmp_file)
		pb = gtk.gdk.pixbuf_new_from_file(tmp_file)
	finally: os.unlink(tmp_file)
	pdb.gimp_image_delete(image)

	## Set image as a root window background
	win = gtk.gdk.get_default_root_window()
	pm, mask = pb.render_pixmap_and_mask()
	win.set_back_pixmap(pm, False)
	win.clear()
	pb.render_to_drawable(win, gtk.gdk.GC(win), 0, 0, 0, 0, -1, -1)


register(
	'lqr_wpset',
	__blurb__, __description__,
	__author__, __copyright__,
	'2011',
	'<Toolbox>/Xtns/Languages/Python-Fu/LQRify to desktop',
	'RGB*',
	[(PF_STRING, 'file_name', 'Input file name', '')], [],
	lqr_wpset )

main()
