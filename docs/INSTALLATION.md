# Installing Noiro on Apple devices

Noiro is not yet released. This guide defines the customer-signing model that
must be tested before the Shop is allowed to sell a package.

## What Vortexo does

After a purchase is attached to a passwordless Vortexo account, Library may
grant a short-lived download for the Xcode package and matching source archive.
Vortexo never asks for an Apple ID, password, app-specific password, signing
certificate, provisioning profile, or two-factor code. It does not claim to
install an app directly onto an Apple TV.

## iPhone, iPad, and Apple TV

1. Download the Xcode package and matching GPL source archive from Vortexo
   Library and verify the published SHA-256 checksums.
2. Install the Xcode version named in that release's build instructions.
3. Open the generated `Noiro.xcodeproj`, select the relevant Noiro target, then
   choose your own team under Signing & Capabilities.
4. Change each bundle identifier to a unique identifier owned by your team. The
   vendor identifiers in `project.yml` identify official builds and cannot be
   provisioned by an unrelated team.
5. For a free Personal Team, remove the App Groups and Increased Memory Limit
   capabilities from the target and use a local-only build. Noiro's base app
   must continue to work without those capabilities. A paid team may create its
   own uniquely named app group and update both the target entitlement and app
   code to that group.
6. Connect the device to Xcode, select it as the run destination, and run the
   app. Apple TV may require Developer Mode and local-network pairing with
   Xcode.

Apple documents development distribution to registered devices in
[Distributing your app to registered devices](https://developer.apple.com/documentation/Xcode/distributing-your-app-to-registered-devices).
Paid Apple Developer Program teams may register up to 100 devices per product
family per membership year, subject to Apple's rules in
[Devices overview](https://developer.apple.com/help/account/devices/devices-overview).

Apple's free Personal Team has much tighter limits: up to 10 App IDs and three
devices per platform, with provisioning that expires after seven days and up to
three simultaneously installed test apps per device. The app must be rebuilt
and installed again after expiry. See
[About your developer account](https://developer.apple.com/help/account/basics/about-your-developer-account).

These limits are Apple's, may change, and are not removed by buying Noiro.

## Mac

The intended customer artifact is a Developer ID-signed, hardened-runtime,
notarized package. Customers should verify the SHA-256 checksum, signature,
notarization ticket, and matching source archive before installation. An ad-hoc
signed or unnotarized development build is not an official customer package.

## Noiro Sync pairing

Noiro creates the ten-minute code shown on the device. In a signed-in browser,
open `https://vortexo.app/studio/devices`, enter that exact code, select the
profile, and approve it. Return to Noiro and choose Check Approval if automatic
polling has not completed. The website must never generate the production code
or simulate the device's claim.
