#!/usr/bin/env python3
"""Adds a version at the top of a Sparkle appcast. Used by direct.sh.
appcast.py <appcast file> <version> <build> <sparkle signature attributes> <release notes .html> <download URL>"""
import email.utils
import os
import re
import sys

path, version, build, sig, notes, url = sys.argv[1:]
items = []
if os.path.exists(path):
    items = re.findall(r'(?s)\s*<item>.*?</item>', open(path).read())
    items = [i for i in items if f'<sparkle:version>{build}</sparkle:version>' not in i]
text = open(notes).read().strip() if os.path.exists(notes) else f'<h2>Wingman {version}</h2>'
item = f"""
    <item>
      <title>Wingman {version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{text}]]></description>
      <enclosure url="{url}" type="application/octet-stream" {sig.strip()}/>
    </item>"""
with open(path, 'w') as f:
    f.write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Wingman</title>
    <link>https://leinerud.se/wingman/</link>
    <language>en</language>{item}{"".join(items)}
  </channel>
</rss>
""")
