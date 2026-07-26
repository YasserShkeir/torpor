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

from email.utils import formatdate
item = f"""    <item>
      <title>{escape(version)}</title>
      <link>https://github.com/YasserShkeir/torpor/releases/tag/{escape(tag)}</link>
      <sparkle:version>{escape(version)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/YasserShkeir/torpor/releases/tag/{escape(tag)}</sparkle:releaseNotesLink>
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
print(f"appcast: added {version}")
