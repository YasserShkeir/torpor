# Signing and notarising

How releases are signed and notarised, and what had to exist first. Torpor ships
signed with a Developer ID and notarised, with the ticket stapled into the
bundle, so `brew install --cask` and a double-click is the whole install.

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

Five secrets. Missing ones warn rather than fail the release: no certificate
ships an ad-hoc build, no API key ships a signed one with no ticket. The
packaged-app check then asserts on what actually happened — including the
negative — so a release cannot claim to be notarised when it isn't.

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

The release workflow uses `NOTARY_KEY_ID` / `NOTARY_ISSUER_ID` /
`NOTARY_KEY_PATH` rather than a keychain profile — same script, the other of the
two ways it can authenticate.

## 5. Apple held the first submission for 84 hours

Write this down because the next person to hit it will assume their bundle is
broken. It isn't. Apple holds a new account's **first** submission for in-depth
analysis, and every later submission from that account queues behind it. Ours
sat for 84 hours and was then accepted with nothing changed. Submissions after
it come back in minutes.

While it lasted, `notarytool submit --wait` did not fail — it hung, on a runner
billed at 10x. That is what the `SKIP_NOTARIZATION` repository variable in
`.github/workflows/release.yml` is for: set it to `true` and a tag ships signed
but unnotarised rather than not at all. Unset it the moment the hold clears. The
packaged-app check refuses to describe a build as notarised while it is set, so
the two cannot drift.

## 6. What users get

```sh
brew install --cask yassershkeir/torpor/torpor
```

and it opens. No `xattr`, no *could not verify Torpor is free of malware*, no
**Open Anyway**. The ticket is stapled into the bundle, so a first launch works
offline. On an installed copy, the two questions worth asking are:

```sh
spctl --assess --type execute --verbose=2 /Applications/Torpor.app
xcrun stapler validate /Applications/Torpor.app
```

`accepted … source=Notarized Developer ID` and a valid ticket is the state a
release is supposed to be in.

The quieter fix is the grants. macOS binds Automation and Keychain consent to
the signing identity, and every ad-hoc build had a different one, so Torpor
re-asked for Terminal control after every update. A stable Developer ID means it
asks once, ever.

What notarisation is not: Apple vouching for what Torpor does. It is an
automated malware scan and a signature Gatekeeper will accept. Torpor is not
sandboxed and is not on the App Store — it reads other processes' memory and
signals them, and the sandbox forbids both. `Resources/Torpor.entitlements`
records that, along with the hardened-runtime exceptions deliberately *not*
taken.

## Renewal

Developer ID certificates last five years; the Program membership is annual. If
the membership lapses the certificate is revoked and already-notarised builds
keep working, but you cannot sign new ones. The `--timestamp` flag in the signing
step is what makes existing signatures outlive the certificate, so don't remove
it.
