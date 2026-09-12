# whichow Shared CI Platform

This repository currently hosts the shared GitHub Actions workflows used by whichow projects. A dedicated `whichow/ci-workflows` repository can replace this location later without changing the overall design.

## Reusable workflows

| Workflow | Purpose |
| --- | --- |
| `.github/workflows/reusable-android.yml` | Android APK/AAB verification, build, checksums and artifact upload |
| `.github/workflows/reusable-web.yml` | Node/Web install, test, build and artifact upload |
| `.github/workflows/reusable-python.yml` | Python compile check, tests and optional artifacts |
| `.github/workflows/reusable-docker.yml` | BuildKit build/cache and optional GHCR push |
| `.github/workflows/reusable-unity.yml` | Unity Test Runner + Unity Builder + artifact upload |
| `.github/workflows/reusable-3d-assets.yml` | Basic GLB/GLTF/OBJ/STL/PLY inventory and SHA-256 QA |
| `.github/workflows/reusable-dotnet.yml` | .NET restore/build/test and optional artifacts |
| `.github/workflows/reusable-cmake.yml` | CMake configure/build/CTest and optional artifacts |
| `.github/workflows/reusable-release.yml` | Collect artifacts, SHA-256 and publish a tag release |

## Current first integration

`whichow/PrivacyCamera` is the first repository migrated to the shared platform. Its normal Android CI now calls `whichow/Tools/.github/workflows/reusable-android.yml@master` rather than duplicating setup/build/upload steps.

The permanent Android release workflow is being hardened around these rules:

- CI version inputs must be injected into the APK manifest rather than only used in the GitHub tag/title.
- Release builds are treated as unsigned output first.
- `zipalign` runs before signing.
- The permanent keystore signs with `apksigner`.
- `apksigner verify` and `aapt dump badging` verify signature plus versionName/versionCode.
- GitHub Release publishing is a separate opt-in step; artifact-only verification remains possible.

## Android caller example

```yaml
jobs:
  build:
    uses: whichow/Tools/.github/workflows/reusable-android.yml@master
    with:
      java-version: '17'
      gradle-version: '9.6.0'
      use-wrapper: false
      verify-command: 'python3 scripts/verify_project.py'
      gradle-arguments: ':app:assembleDebug'
      artifact-name: 'app-debug'
```

Projects with `gradlew` should use `use-wrapper: true`.

## Unity caller example

```yaml
jobs:
  windows:
    uses: whichow/Tools/.github/workflows/reusable-unity.yml@master
    with:
      project-path: '.'
      unity-version: '2022.3.20f1'
      target-platform: StandaloneWindows64
    secrets: inherit
```

Unity projects need the appropriate GameCI/Unity license secrets before real player builds can pass.

## Planned self-hosted runner labels

### RTX 5080 workstation

`self-hosted`, `windows`, `x64`, `gpu`, `rtx5080`, `unity`, `ai-video`

Use for long-running GPU rendering, point-cloud regression, renderer benchmarks and local AI/video workloads.

### Mac mini M4

`self-hosted`, `macos`, `arm64`, `apple-silicon`, `unity`, `xcode`

Use for native Apple Silicon validation, Unity macOS builds and Xcode/iOS pipelines.

### Scanner test workstation

`self-hosted`, `windows`, `scanner-x1`, `usb`, `ble`, `wifi`

Use for Creality scanner HIL tests: USB enumeration, file transfer, video/point-cloud streams, disconnect/reconnect and BLE provisioning.

### Android device workstation

`self-hosted`, `android-device`, `adb`

Use for real-device installation, upgrade, background/foreground, floating-window and camera/media tests.

### Robot lab

`self-hosted`, `robot`, `esp32`, `camera`

Use for firmware flashing, serial tests, motors/servos, sensors and camera validation.

## Secret naming convention

Android release signing:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Unity/GameCI:

- `UNITY_LICENSE`
- `UNITY_EMAIL`
- `UNITY_PASSWORD`

Apple release pipelines should keep certificates, App Store Connect credentials and notarization credentials as repository/environment secrets rather than committing them.

## Migration order

1. PrivacyCamera — shared Android CI, then permanent signed release and emulator/real-device gates.
2. CrealityScan — Unity tests/build matrix, renderer regression and scanner HIL runners.
3. LumenForge / Web Blender / Azura — Web E2E, import/export and visual regression.
4. OpenPuppet2D / Museverse — Web + Unity golden-pose/golden-image compatibility matrix.
5. NovelForge / AgentOS / ModelBridge — Python/Docker tests, images and staged deployments.
6. Offline Fig Viewer / VRM Studio / renderer tools — desktop matrix and render regression.
7. PcSentinel / KnowledgeHub / QuarkFind — .NET/CMake build matrices and performance gates.
8. AI Drama / OpenChatCut / AI Singer — deterministic media-pipeline QA, then optional GPU/provider smoke jobs.

## CI policy

- PR: fast verification and deterministic tests.
- Main push: build artifacts and broader regression.
- Tag: signed/reproducible release pipeline.
- Nightly: long-running GPU, performance and HIL tests.
- Production deployment: use protected GitHub Environments and explicit approval gates.
- Store generated binaries, screenshots, logs, QA JSON and benchmark reports as workflow artifacts.
