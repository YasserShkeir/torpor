#!/usr/bin/env python3
"""Insert a release into docs/appcast.xml.

Sparkle reads this feed to decide whether an update exists. The signature
attribute is the whole trust anchor: Sparkle installs nothing without a valid
EdDSA signature over the archive, checked against SUPublicEDKey in the app's
Info.plist. Written by hand rather than with generate_appcast because that tool
wants a directory of every past build, which CI does not have.
"""
import sys, re
from xml.sax.saxutils import escape

version, tag, url, sig_line, path = sys.argv[1:6]

# sign_update prints: sparkle:edSignature="..." length="..."
sig = re.search(r'sparkle:edSignature="([^"]+)"', sig_line)
length = re.search(r'length="(\d+)"', sig_line)
if not sig or not length:
    sys.exit(f"could not parse sign_update output: {sig_line!r}")

# The release page for this enclosure, derived rather than hardcoded: a fork or
# a rename would otherwise publish a feed whose download and release notes point
# at different repositories.
base, sep, _ = url.partition("/releases/download/")
if not sep:
    sys.exit(f"not a release download URL: {url!r}")
page = f"{base}/releases/tag/{tag}"

from email.utils import formatdate
item = f"""    <item>
      <title>{escape(version)}</title>
      <link>{escape(page)}</link>
      <sparkle:version>{escape(version)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>{escape(page)}</sparkle:releaseNotesLink>
      <pubDate>{formatdate(localtime=False, usegmt=True)}</pubDate>
      <enclosure url="{escape(url)}"
                 sparkle:edSignature="{sig.group(1)}"
                 length="{length.group(1)}"
                 type="application/octet-stream" />
    </item>
"""

xml = open(path).read()
if f"<sparkle:version>{version}</sparkle:version>" in xml:
    sys.exit(f"{version} is already in the appcast")

marker = "<!-- Releases are inserted here"
if marker in xml:
    line_end = xml.index("\n", xml.index(marker)) + 1
    xml = xml[:line_end] + item + xml[line_end:]
else:
    xml = xml.replace("    <item>", item + "    <item>", 1)

open(path, "w").write(xml)

# Parse back what was written, not what was intended: both insertion paths above
# are string splices, and Sparkle answers a malformed feed with silence.
import xml.etree.ElementTree as ET
root = ET.parse(path).getroot()
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
if not any(v.text == version for v in root.iterfind(".//sparkle:version", ns)):
    sys.exit(f"appcast parsed but has no item for {version}")
print(f"appcast: added {version}")
