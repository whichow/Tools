# whichow Runner Farm — One-click deployment

This directory turns development PCs into private GitHub Actions self-hosted runners with one command.

> Security default: the installer refuses repository-level registration against a public repository unless the explicit public-repo override is used. Keep hardware/GPU runners on trusted private repositories or a restricted private organization runner group.

## Presets

| Preset | Intended machine | Custom labels |
| --- | --- | --- |
| `gpu` | RTX / GPU workstation | `gpu`, `nvidia` when detected, `rtx5080` when detected, `unity`, `ai-video` |
| `mac` | Mac mini / Mac workstation | `apple-silicon`, `xcode`, `unity` |
| `scanner` | Scanner-connected PC | `scanner-x1`, `usb`, `ble`, `wifi`, `unity` |
| `android` | Android real-device PC | `android-device`, `adb`, `camera` |
| `robot` | Robot / ESP32 bench | `robot`, `esp32`, `camera` |
| `generic` | Generic build node | `ci` |
| `auto` | Detect basic local capability | platform-dependent |

Every runner also receives `host-<computer-name>` plus GitHub's normal default labels such as `self-hosted`, OS and architecture.

## Windows — one command

Open PowerShell. Hardware/GPU presets normally run in the logged-in user session so GPU, USB, camera and ADB behave like your normal desktop applications.

```powershell
$u='https://raw.githubusercontent.com/whichow/Tools/master/runner-farm/install-runner.ps1'; $p="$env:TEMP\install-runner.ps1"; irm $u -OutFile $p; & $p -Target 'whichow/PrivacyCamera' -Preset android
```

Examples:

```powershell
# RTX 5080 workstation — replace target with the private repository that needs GPU CI.
& $p -Target 'OWNER/PRIVATE_REPO' -Preset gpu

# Scanner workstation.
& $p -Target 'OWNER/PRIVATE_REPO' -Preset scanner

# Android real-device workstation.
& $p -Target 'whichow/PrivacyCamera' -Preset android

# Generic always-on Windows build service. Run elevated as Administrator.
& $p -Target 'OWNER/PRIVATE_REPO' -Preset generic -Mode service
```

`gpu`, `scanner`, `android`, and `robot` default to `-Mode user` on Windows. This creates a hidden startup launcher and starts the runner immediately in the current interactive session. `generic` defaults to Windows service mode.

## macOS / Linux — one command

```bash
curl -fsSL https://raw.githubusercontent.com/whichow/Tools/master/runner-farm/install-runner.sh -o /tmp/install-runner.sh && bash /tmp/install-runner.sh --target OWNER/PRIVATE_REPO --preset mac
```

Mac mini M4 example:

```bash
bash /tmp/install-runner.sh --target OWNER/PRIVATE_REPO --preset mac
```

Linux GPU example:

```bash
bash /tmp/install-runner.sh --target OWNER/PRIVATE_REPO --preset gpu
```

macOS and Linux default to service mode. The script installs the GitHub-generated `svc.sh` service so the runner starts automatically.

## Authentication

The installer chooses the first available method:

1. `GH_TOKEN` environment variable.
2. `gh auth token` from an existing GitHub CLI login.
3. Hidden interactive PAT prompt.

For repository runners, the API token must be allowed to create a runner registration token for the repository. A fine-grained PAT can use `Administration: write` for that repository. A classic/OAuth token needs the required repository scope.

The short-lived runner registration token is fetched by the installer and is not committed to the repository.

## Repository vs organization scope

Repository scope:

```powershell
& $p -Scope repo -Target 'whichow/PrivacyCamera' -Preset android
```

```bash
bash /tmp/install-runner.sh --scope repo --target whichow/PrivacyCamera --preset android
```

A repository-level runner serves that repository only.

If projects are moved under a GitHub organization, one machine can instead be registered once at organization scope and then shared by allowed repositories / runner groups:

```powershell
& $p -Scope org -Target 'YOUR_ORG' -Preset gpu
```

```bash
bash /tmp/install-runner.sh --scope org --target YOUR_ORG --preset gpu
```

Organization registration requires organization runner administration permission.

## Workflow routing examples

RTX 5080:

```yaml
runs-on: [self-hosted, Windows, gpu, rtx5080]
```

Mac mini Apple Silicon:

```yaml
runs-on: [self-hosted, macOS, ARM64, apple-silicon, xcode]
```

Scanner workstation:

```yaml
runs-on: [self-hosted, Windows, scanner-x1, usb]
```

Android device workstation:

```yaml
runs-on: [self-hosted, Windows, android-device, adb]
```

Robot bench:

```yaml
runs-on: [self-hosted, robot, esp32]
```

## Re-running the installer

The installer is intentionally non-destructive. If the target installation directory already contains a configured `.runner`, it does not unregister/re-register it. GitHub Actions Runner handles normal runner application updates itself.

To attach one physical computer to several unrelated repository-level targets, use a different runner name per target or run the installer separately for each repository. Each registration creates a separate runner process/service and can accept work independently, so do not register many parallel GPU/hardware runners on the same physical device unless concurrent jobs are safe.

## Recommended whichow topology

```text
GitHub hosted runners
       |
       +-- RTX 5080 PC      [gpu, rtx5080, unity, ai-video]
       +-- Mac mini M4      [apple-silicon, xcode, unity]
       +-- Scanner PC       [scanner-x1, usb, ble, wifi]
       +-- Android PC       [android-device, adb, camera]
       +-- Robot bench      [robot, esp32, camera]
```

Use private repositories for these machines. For a large number of repositories, organization-level runners are cleaner than registering separate repository runners for every project.
