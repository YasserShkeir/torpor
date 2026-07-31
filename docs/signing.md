# Signing and notarising

What has to exist before a release stops asking users to run `xattr`.

Team ID: **5HSKMD6X59**

## 1. The certificate

In the Apple Developer portal, **Certificates → +** and choose **Developer ID
Application**. Not *Developer ID Installer*, which signs `.pkg` files; Torpor
ships a zip.

It asks for a CSR, which you make locally so the private key never leaves your
Mac:

1. **Keychain Access → Certificate Assistant → Request a Certificate From a
   Certificate Authority**
2. Your email, Common Name `Yasser Shkeir`, CA Email blank
3. **Saved to disk**, and tick **Let me specify key pair information**
4. **2048 bits**, **RSA**

Upload the `.csr`, download the `.cer`, double-click it into your **login**
keychain. Then:

```sh
security find-identity -v -p codesigning
```

You want a line reading `Developer ID Application: Yasser Shkeir (5HSKMD6X59)`.
If it doesn't appear, the intermediate is missing: install **Developer ID - G2**
from the bottom of that same portal page.

## 2. The notarisation key

Notarising needs credentials that work without a GUI. An App Store Connect API
key is the one to use, because it doesn't expire the way an app-specific password
does and it's the only option that behaves in CI.

**App Store Connect → Users and Access → Integrations → App Store Connect API →
+**, role **Developer**. Download the `.p8` **once**, it is not shown again. Note
the Key ID and the Issuer ID next to it.

## 3. Building a signed, notarised app locally

Store the credentials once:

```sh
xcrun notarytool store-credentials torpor-notary \
  --key ~/path/AuthKey_XXXXXXXX.p8 --key-id XXXXXXXX --issuer <issuer-uuid>
```

Then:

```sh
IDENTITY="Developer ID Application: Yasser Shkeir (5HSKMD6X59)" \
NOTARY_PROFILE=torpor-notary \
./scripts/build-app.sh
```

The script signs Sparkle's helpers first and the app last, applies
`Resources/Torpor.entitlements` to the app alone, submits, waits, staples the
ticket into the bundle, and finishes by asking Gatekeeper directly:

```
spctl --assess --type execute --verbose=2 dist/Torpor.app
dist/Torpor.app: accepted
source=Notarized Developer ID
```

`accepted` is the only line that matters. `codesign --verify` passing means the
signature is internally consistent, which an ad-hoc build also manages while
still being refused on every machine that didn't build it.

Without `NOTARY_PROFILE` the script signs and skips notarising. Without
`IDENTITY` it stays ad-hoc, so a plain `./scripts/build-app.sh` still works for
development.

## 4. Releasing from CI

Five secrets. Missing ones downgrade the release to ad-hoc with a warning rather
than failing it, and the packaged-app check asserts on what actually happened, so
a release cannot claim to be notarised when it isn't.

| Secret | What it is |
|---|---|
| `APPLE_CERT_P12` | The certificate **and private key**, base64 |
| `APPLE_CERT_PASSWORD` | The password you set when exporting it |
| `APPLE_API_KEY_ID` | Key ID from step 2 |
| `APPLE_API_ISSUER_ID` | Issuer ID from step 2 |
| `APPLE_API_KEY_P8` | The `.p8` contents, base64 |

Export the certificate with its key: in Keychain Access, expand the
**Developer ID Application** entry, select **both** the certificate and the key
beneath it, right-click → **Export 2 items**, save as `.p12` with a password.
Exporting the certificate alone gives CI something it cannot sign with.

```sh
base64 -i Certificates.p12 | pbcopy          # APPLE_CERT_P12
base64 -i AuthKey_XXXXXXXX.p8 | pbcopy       # APPLE_API_KEY_P8
gh secret set APPLE_CERT_P12                 # paste, then the rest the same way
```

## 5. What changes for users

Once a tagged release is notarised, the install stops being a two-step apology:

```sh
brew install --cask yassershkeir/torpor/torpor
```

and it opens. No `xattr`, no **Open Anyway**.

The other thing it fixes is quieter and more annoying today. macOS binds
Automation and Keychain grants to the signing identity, and every ad-hoc build
has a different one, so the app re-asks for Terminal control after every update.
A stable Developer ID means it asks once, ever.

**Update the README when the first notarised release ships, not before.** It
currently tells people to clear the quarantine flag, which is correct for 0.2.0
and wrong the moment a signed build is out. The section to cut is
`## Install`'s `xattr` paragraph, and `Why macOS blocks it` goes entirely.

## Renewal

Developer ID certificates last five years; the Program membership is annual. If
the membership lapses the certificate is revoked and already-notarised builds
keep working, but you cannot sign new ones. The `--timestamp` flag in the signing
step is what makes existing signatures outlive the certificate, so don't remove
it.
