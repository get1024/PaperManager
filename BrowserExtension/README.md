# PaperManager Connector source package

This Manifest V3 package is an independently implemented connector for the local PaperManager app. It is not installed or enabled by the build scripts. Its manifest requests `activeTab`, `scripting`, `storage`, and access to the loopback API only; it does not request access to all websites.

The popup reads citation meta tags, common Dublin Core / Open Graph metadata, and article JSON-LD from the active page. It displays editable metadata before saving. Existing collections and tags support multiple selection. Duplicate handling defaults to **Skip**; replacing metadata and replacing a primary PDF are separate explicit choices.

PDF upload is optional. Same-origin page PDFs may be fetched using the active tab's granted origin; cross-origin PDFs require the user to download and select a local file. The connector does not request broader website permissions to bypass this boundary. It checks the PDF signature and the decimal 200,000,000-byte limit. Keep the popup open until saving finishes.

When File Library is unavailable, the popup indicates metadata-only operation. If availability changes during a save, the result reports that metadata was saved and the PDF was not uploaded. A legacy location conflict blocks creation until resolved in the app. Read-only mode blocks all mutations. Duplicate skip never automatically attaches a PDF to the existing record, and upload conflicts never automatically retry with force.

## Development and packaging

For a developer-controlled Chrome or Edge profile, this directory is the unpacked-extension source. Opening its popup requires the app's Local API to be enabled; match the port shown in app settings. No test installs the extension, grants permissions, navigates to an external academic site, or changes the user's browser profile.

The API usage follows Chrome's documented [activeTab permission](https://developer.chrome.com/docs/extensions/develop/concepts/activeTab) and [scripting API](https://developer.chrome.com/docs/extensions/reference/api/scripting). Academic page contents remain untrusted data and are rendered with form values or textContent, never HTML injection or eval.

For local signed Safari app distribution, use a Safari Web Extension app project and Xcode's packaging/signing workflow, described in [packaging a web extension for Safari](https://developer.apple.com/documentation/safariservices/packaging-a-web-extension-for-safari). Apple also offers [App Store Connect cloud packaging](https://developer.apple.com/documentation/safariservices/packaging-and-distributing-safari-web-extensions-with-app-store-connect), and current macOS Safari supports [temporary source-folder testing](https://developer.apple.com/documentation/safariservices/running-your-safari-web-extension). None of those install, account, packaging or signing actions was performed. This is a portable source package, not a verified Safari distribution.

## Executed checks

`Tests/Connector/run.sh` builds a native Swift fixture running the actual reconstructed LocalAPIServer on a system-assigned loopback port. Node exercises this connector's core against that real server. Metadata extraction uses local document fixtures, not external browsing. Tests cover Unicode limits, exact identities, duplicate handling, primary-PDF conflicts, protected source-file preservation, metadata-only fallback, read-only policy and legacy conflicts, alongside the CLI/MCP tests.

The Chrome/Edge/Safari popup's permission prompt, scripting injection, native browser UI, and packaged signing remain browser acceptance checks. Unit and TCP tests establish helper and server behavior only.
