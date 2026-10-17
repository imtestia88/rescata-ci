# rescata-ci

Emulator CI harness: boots an Android emulator on GitHub Actions, installs
an app build, drives a few UI interactions and uploads the screen recording
as an artifact.

- The app source code is NOT stored in this repo: the workflow fetches it at
  runtime from a private repository using a repository secret.
- No APK artifacts are published here (video artifact only).
