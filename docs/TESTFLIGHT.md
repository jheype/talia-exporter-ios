# TestFlight distribution

Source package: version 0.4.0, build 7. This is not a signed archive or an uploaded TestFlight build. Archiving, signing, upload validation and device testing must run on a Mac with Xcode 26 or later.

## App record and signing

1. In App Store Connect, open the existing app with bundle ID `com.talia.exporter`. If there is no app record, create an iOS app named Talia Exporter with primary language English (UK), that bundle ID and an unused SKU such as `talia-exporter-ios`.
2. Open `TaliaExporter.xcodeproj` and select the TaliaExporter scheme.
3. In Signing & Capabilities, use the Apple team `S3SCDDP668` for both targets. The app identifier is `com.talia.exporter`; the widget identifier is `com.talia.exporter.widgets`. Both require the App Group `group.com.talia.exporter.shared`, and the app requires Push Notifications. Use automatic signing.
4. The app and widget inherit version 0.4.0 and build 7 from the project. If build 7 has already been uploaded, choose a higher build number for both targets before archiving, or allow the distribution wizard to manage the build number.

## Archive and upload

1. Select an iOS device archive destination, such as Any iOS Device (arm64).
2. Confirm Product > Scheme > Edit Scheme > Archive uses Release.
3. Choose Product > Archive. When it finishes, select the archive in Window > Organizer.
4. Choose Distribute App and the App Store Connect upload workflow. Keep automatic signing and follow validation through to Upload. TestFlight Internal Only is also suitable if this build will be used exclusively by internal testers.
5. Wait for App Store Connect to process the build. Resolve any validation or export-compliance questions shown by Apple before assigning the build.
6. Under the app's TestFlight tab, create an Internal Testing group. Add your own App Store Connect account as a tester and add the processed build. Install it through TestFlight on the iPhone. Internal testers must have access to this app in App Store Connect.

## Verify the production push

The Archive scheme uses Release. In this project Release sets `APS_ENVIRONMENT=production`; both the push entitlement and `TaliaPushEnvironment` use that setting. The debug Run scheme uses the development environment.

Keep the Production APNs key configured in the CRM backend. Open the TestFlight installation, sign into SA Portal, and enable security alerts if needed. Opening the SA session registers the current token and production environment with the server. Wait for the phone registration status, then send one test notification.

The result must say `APNs environment: Production`. A successful APNs response confirms acceptance by Apple; verify notification delivery separately on the phone. Launching from Xcode with the Debug Run scheme installs a Sandbox build again.

## Privacy manifest scope

The app declares UserDefaults for its own preferences (`CA92.1`) and for preferences shared with its widget in the same App Group (`1C8F.1`). The widget declares only the latter. Each manifest is included in its target's Copy Bundle Resources phase, and the XcodeGen specification includes the same resources explicitly.

These manifests document required-reason API usage. They do not replace the App Store Connect data-collection disclosures, and they do not claim that the app collects no data.

## Checks completed for this package

- Property lists, project references, resource membership, archive configuration and app/widget version consistency checked locally.
- App icon is 1024 x 1024 RGB with no alpha channel.
- No Xcode compilation, Apple upload or production push delivery has been performed in this environment.

Apple references:
- https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/
- https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/
- https://developer.apple.com/documentation/bundleresources/entitlements/aps-environment
- https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype
