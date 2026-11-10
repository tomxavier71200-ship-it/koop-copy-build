name: iOS Release

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: 2.7
      - name: Install Fastlane
        run: |
          gem install bundler
          gem install fastlane
      - name: Install Fastlane dependencies
        run: |
          cd ios
          bundle install
      - name: Install Flutter
        run: |
          sudo apt-get update
          sudo apt-get install -y git curl unzip
          curl -sSL https://storage.googleapis.com/flutter_infra_release/releases/releases_linux/flutter_linux_v3_19_1-stable.tar.xz | tar xz
          export PATH="$PATH:/home/runner/flutter/bin"
      - name: Install Flutter dependencies
        run: |
          flutter pub get
      - name: Build iOS IPA
        run: |
          cd ios
          flutter build ipa --release --no-tree-shake-icons
      - name: Upload to TestFlight
        env:
          MATCH_GIT_URL: ${{ secrets.MATCH_GIT_URL }}
          APP_STORE_CONNECT_API_KEY: ${{ secrets.APP_STORE_CONNECT_API_KEY }}
          APP_STORE_CONNECT_API_ISSUER_ID: ${{ secrets.APP_STORE_CONNECT_API_ISSUER_ID }}
          APP_STORE_CONNECT_API_KEY_ID: ${{ secrets.APP_STORE_CONNECT_API_KEY_ID }}
          APP_STORE_CONNECT_API_PASSWORD: ${{ secrets.APP_STORE_CONNECT_API_PASSWORD }}
        run:
          cd ios
          bundle exec fastlane beta
```

Now we need to create the directory for the workflow file.
</think>
<tool_call>
<function=Bash>
<parameter=command>
mkdir -p C:/Users/tomxa/koop-copy-build/.github/workflows