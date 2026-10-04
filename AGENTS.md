# Stats — macOS System Monitor

macOS menu bar system monitor. Written in Swift with C/Objective-C bridging for low-level hardware access (IOKit, SMC, IOReport, HID).

## Module Structure

| Directory | Role |
|-----------|------|
| `Kit/` | Shared framework — base module system, widgets, plugins (DB, Charts, Logger, Updater, Store), helpers, types |
| `Modules/CPU/` | CPU usage monitoring (IOReport bridge) |
| `Modules/GPU/` | GPU usage monitoring (IOReport bridge) |
| `Modules/RAM/` | Memory usage monitoring with auto-purge |
| `Modules/Disk/` | Disk I/O and SMART health (NVMe/ATA bridge) |
| `Modules/Net/` | Network traffic monitoring |
| `Modules/Sensors/` | Hardware sensors via HID + IOReport (Apple Silicon & Intel) |
| `Modules/Battery/` | Battery status monitoring |
| `Modules/Bluetooth/` | Bluetooth device monitoring |
| `Modules/Clock/` | World clock module |
| `Modules/Remote/` | Remote sensor data source |
| `SMC/` | System Management Controller — direct hardware read/write (fans, temperatures, keys) |
| `Stats/` | App entry point (`AppDelegate`), views, localization |
| `Widgets/` | WidgetKit extension for macOS widgets |
| `LaunchAtLogin/` | Login item helper |
| `Tests/` | Unit tests |

Each module under `Modules/` follows a consistent structure: `main.swift` (module registration), `readers.swift` (data collection), `popup.swift` (popup UI), `portal.swift` (portal view), `settings.swift` (preferences), `notifications.swift` (alert rules).

## C/Objective-C Bridge Files

These headers bridge private macOS frameworks that have no Swift interface:

| File | Purpose |
|------|---------|
| `Modules/CPU/bridge.h` | IOReport API for CPU core usage and residency |
| `Modules/GPU/bridge.h` | IOReport API for GPU utilization |
| `Modules/Sensors/bridge.h` | IOHIDEventSystem + IOReport for Apple Silicon sensor readings |
| `Modules/Sensors/reader.m` | Objective-C implementation of `AppleSiliconSensors()` using HID |
| `Modules/Disk/header.h` | NVMe SMART log structure and `IONVMeSMARTInterface` via IOKit ATA |
| `SMC/smc.swift` | SMC communication via `IOConnectCallStructMethod` (fan control, temperature, key read/write) |
| `Kit/lldb/lldb.h` + `lldb.m` | LevelDB wrapper for local persistence |

## Module Boundaries

- **Kit** is the shared dependency — all modules import it. Modules must not import each other directly.
- **SMC** is a standalone library used by `Modules/Sensors/` and `Modules/Battery/` for hardware data.
- **Bridge headers** are module-scoped. Each module's `bridge.h` declares only the C functions it needs.
- **Widgets** extension depends on `Kit` for shared widget views but has no access to module internals.
- **Stats** (app target) assembles modules via `AppDelegate` and manages the menu bar UI.

---

## Local Validation Commands

### SwiftLint (Lint)

Run SwiftLint locally to check Swift code style and conventions before pushing.
Configuration: [`.swiftlint.yml`](.swiftlint.yml)

```bash
# Requires SwiftLint installed (brew install swiftlint)
swiftlint
```

Key configuration points from `.swiftlint.yml`:
- **Disabled rules**: `force_cast`, `type_name`, `cyclomatic_complexity`, `trailing_whitespace`, `opening_brace`, `implicit_getter`, `implicit_optional_initialization`, `large_tuple`, `function_body_length`
- **Opt-in rules**: `control_statement`, `empty_count`, `trailing_newline`, `colon`, `comma`
- **Line length**: 200 characters
- **Type body length**: warning at 700, error at 1000
- **File length**: warning at 1400, error at 1800

### Build (Compile Check)

Compile the project without code signing to verify the build succeeds:

```bash
xcodebuild -scheme Stats -destination 'platform=macOS' -configuration Release archive CODE_SIGNING_ALLOWED=NO
```

This is the same command used by the CI build workflow. It verifies that the entire project (app + all modules + widget extension) compiles successfully in Release configuration.

### i18n Check (Internationalization)

Validate that all translation files have the same keys as the English reference file:

```bash
# Requires Python 3
python3 Kit/scripts/i18n.py
```

The script checks every `*.lproj/Localizable.strings` file against `en.lproj/Localizable.strings` and fails if any key is missing or mismatched.

Additional i18n commands (not run in CI):
- `python3 Kit/scripts/i18n.py fix` — auto-insert missing English keys into all translation files
- `python3 Kit/scripts/i18n.py scan` — detect unused keys and strings missing from en.lproj

---

## CI Workflows

All workflows are defined in [`.github/workflows/`](.github/workflows/).

### 1. Build (`build.yaml`)

| Property | Value |
|----------|-------|
| **Trigger** | Push and PR to `master` |
| **Runner** | `macos-15` |
| **Concurrency** | Groups by ref; cancels in-progress runs |

**What it validates:**
- The full project compiles successfully in Release configuration
- All targets (Stats app, modules, widget extension, helper) build without errors
- No linker errors or missing symbols

**Command:**
```bash
xcodebuild -scheme Stats -destination 'platform=macOS' -configuration Release archive CODE_SIGNING_ALLOWED=NO
```

### 2. Linter (`linter.yaml`)

| Property | Value |
|----------|-------|
| **Trigger** | Push/PR that modifies `**/*.swift`, `.swiftlint.yml`, or the workflow file itself |
| **Runner** | `ubuntu-latest` |

**What it validates:**
- Swift code style and conventions via SwiftLint
- Compliance with rules defined in `.swiftlint.yml`
- Uses `norio-nomura/action-swiftlint@3.2.1`

### 3. i18n Check (`i18n.yaml`)

| Property | Value |
|----------|-------|
| **Trigger** | Push/PR that modifies `**/*.strings` or the workflow file itself |
| **Runner** | `ubuntu-latest` |

**What it validates:**
- All translation files (`*.lproj/Localizable.strings`) contain every key present in the English reference file
- Keys are in the correct order and match exactly
- Fails the build if any translation is missing a key

**Command:**
```bash
python3 Kit/scripts/i18n.py
```

---

## Release Build Process (Not CI)

The full release build is done locally via `make build`. This is NOT part of CI and requires macOS with code-signing certificates and notarization credentials.

The project uses `Stats.xcodeproj` (not a workspace). The main scheme is `Stats`; a separate `SMC` scheme builds the SMC CLI tool.

```bash
make build
```

This runs the following pipeline:
1. **clean** — Remove build artifacts
2. **next-version** — Increment `CFBundleVersion` in `Info.plist`
3. **archive** — Build and export `.xcarchive` with `xcodebuild` (uses `exportOptions.plist`)
4. **notarize** — Submit to Apple Notary Service (`xcrun notarytool`)
5. **sign** — Staple the notarization ticket (`xcrun stapler`)
6. **verify** — Check widget extension exists, versions match, and code signature is valid
7. **prepare-dmg** — Create `.dmg` installer
8. **prepare-dSYM** — Zip debug symbols

Helper commands:
- `make smc` — Build the SMC helper tool
- `make leveldb` — Build the LevelDB static library
- `make history` — Check notarization history
- `make check` — Query a specific notarization log

---

## Quick Reference: Dev vs Release

| Command | Purpose | When to Run |
|---------|---------|-------------|
| `swiftlint` | Check Swift code style | Before every commit |
| `xcodebuild -scheme Stats ...` | Verify compilation | Before pushing / opening PR |
| `python3 Kit/scripts/i18n.py` | Verify translation keys | After modifying any `.strings` file |
| `make build` | Full release pipeline | When preparing a release (requires signing certs) |
