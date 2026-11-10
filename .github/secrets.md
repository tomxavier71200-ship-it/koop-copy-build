# GitHub Actions Secrets Required for iOS TestFlight / App Store Build

## Required Secrets

| Secret Name | Description | How to Obtain |
|-------------|-------------|---------------|
| `MATCH_GIT_URL` | Git URL for Match certificate repository (e.g., `git@github.com:yourorg/certificates.git`) | Create a private repo for certs |
| `MATCH_PASSWORD` | Passphrase for Match encryption | Generate a strong passphrase |
| `MATCH_KEYCHAIN_NAME` | Name of the keychain (e.g., `fastlane_tmp_keychain`) | Any name |
| `MATCH_KEYCHAIN_PASSWORD` | Password for the keychain | Generate a strong password |
| `APPLE_ID` | Apple Developer account email | Your Apple ID |
| `TEAM_ID` | Apple Developer Team ID (e.g., `2U62X3RF3R`) | Developer Portal → Membership |
| `APP_STORE_CONNECT_API_KEY` | Base64-encoded App Store Connect API key JSON | See below |

## App Store Connect API Key Setup

1. Go to [App Store Connect → Users and Access → Keys](https://appstoreconnect.apple.com/access/api)
2. Click **Generate API Key**
3. Name: `GitHub Actions CI`
4. Access: **App Manager** (or Admin)
5. Download the `.p8` file (private key)
6. Note the **Key ID** and **Issuer ID**

Create the API key JSON:
```json
{
  "key_id": "YOUR_KEY_ID",
  "issuer_id": "YOUR_ISSUER_ID",
  "key": "-----BEGIN PRIVATE KEY-----\nYOUR_PRIVATE_KEY_BASE64\n-----END PRIVATE KEY-----"
}
```

Encode to base64:
```bash
cat api_key.json | base64 -w 0
```

Add the base64 string as `APP_STORE_CONNECT_API_KEY` secret.

## Match Certificate Repository Setup

1. Create a private GitHub repository (e.g., `yourorg/ios-certificates`)
2. Add deploy key with write access to this repo
3. Run locally once to populate:
```bash
cd ios
bundle exec fastlane match appstore --readonly=false
```
4. This will create certificates and provisioning profiles in the repo

## First-Time Setup Checklist

- [ ] Apple Developer Program enrolled ($99/yr)
- [ ] App Store Connect app created with bundle ID `wtf.openstrap.koopcopy`
- [ ] Match certificate repo created and populated
- [ ] All GitHub secrets added
- [ ] Fastlane Gemfile installed locally (`bundle install` in ios/)
- [ ] Test workflow manually via "Run workflow" in Actions tab

## Workflow Triggers

- **TestFlight**: Push to `main` or `release/*` branches, or manual dispatch
- **App Store**: Push a tag starting with `v*` (e.g., `v0.10.1`)
- **Manual**: Use "Run workflow" button, choose `testflight` or `appstore`

## Troubleshooting

| Error | Fix |
|-------|-----|
| "No matching provisioning profiles found" | Run `fastlane match appstore` locally, ensure certs in Match repo |
| "App Store Connect API key invalid" | Verify key_id, issuer_id, and private key are correct |
| "Team ID not found" | Check TEAM_ID matches Developer Portal |
| "Certificate expired" | Run `fastlane match appstore --force` to regenerate |