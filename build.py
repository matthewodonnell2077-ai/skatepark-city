#!/usr/bin/env python3
"""Build the standalone site from the game file.

    python3 build.py ../skatepark-city.html

Writes index.html next to this script: the same game, wrapped in a full HTML document,
with config.js loaded first so the game can find your Supabase keys.
"""
import sys, pathlib
here = pathlib.Path(__file__).resolve().parent
src = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else here.parent / 'skatepark-city.html').read_text(encoding='utf-8')
extra = sys.argv[2] if len(sys.argv) > 2 else ''  # optional extra <script> tags (tests only)
assert src.count('\n<script>\n') == 1, 'expected one main <script> block'
body = src.replace('\n<script>\n', '\n<script src="config.js"></script>\n' + extra + '<script>\n', 1)
head_end = body.index('<div id="wrap">')
doc = ('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
       '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
       '<meta name="apple-mobile-web-app-capable" content="yes">\n<meta name="mobile-web-app-capable" content="yes">\n'
       '<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">\n<meta name="apple-mobile-web-app-title" content="Skatepark">\n'
       '<meta name="theme-color" content="#140e24">\n<link rel="manifest" href="manifest.webmanifest">\n<link rel="apple-touch-icon" href="icon-180.png">\n'
       '<meta name="description" content="Skatepark City: a 16-bit BMX and skate speed platformer with street fights, H.O.R.S.E. and online play.">\n'
       + body[:head_end] + '<style>html,body{margin:0}</style>\n</head>\n<body>\n' + body[head_end:] + '\n</body>\n</html>\n')
(here / 'index.html').write_text(doc, encoding='utf-8')
print('wrote', here / 'index.html', len(doc), 'bytes')
