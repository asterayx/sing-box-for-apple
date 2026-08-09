SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
.SILENT:

INSTALLER_SIGN_IDENTITY := 16480CA444F481F8DEAF9421FAD2CCE590FC54E4
XCODEBUILD_FLAGS ?= -skipPackagePluginValidation
export DISABLE_SWIFTLINT := 1

EXPECTED_CORE_TAG ?= v1.14.0-beta.10
SING_BOX_SOURCE ?= ../sing-box
GO_BIN_PATH ?= $(shell go env GOPATH)/bin
CORE_PROTOCOL_PATCH := $(CURDIR)/Patches/sing-box-without-vmess-vless.patch
IOS_DEVELOPMENT_ARCHIVE_PATH ?= build/SFI-development.xcarchive
IOS_DEVELOPMENT_EXPORT_PATH ?= build/SFI-development
TEAM_ID ?= EL6G8M5A96
BUNDLE_ID ?= com.asterayx.sfi.dev
ALLOW_PROVISIONING_UPDATES ?= 0

ifeq ($(ALLOW_PROVISIONING_UPDATES),1)
IOS_PROVISIONING_FLAGS := -allowProvisioningUpdates -allowProvisioningDeviceRegistration
endif

build_all: build_ios build_macos build_tvos

build_ios_deb:
	bash Jailbreak/package.sh

build_ios:
	xcodebuild build $(XCODEBUILD_FLAGS) -scheme SFI -configuration Debug -destination 'generic/platform=iOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

check_ios_core:
	test -e "$(SING_BOX_SOURCE)/.git"
	test "$$(git -C "$(SING_BOX_SOURCE)" describe --tags --exact-match 2>/dev/null)" = "$(EXPECTED_CORE_TAG)"
	test -x "$(GO_BIN_PATH)/gomobile"
	test -x "$(GO_BIN_PATH)/gobind"
	git -C "$(SING_BOX_SOURCE)" apply --check --reverse "$(CORE_PROTOCOL_PATCH)"

apply_ios_core_protocol_patch:
	test -e "$(SING_BOX_SOURCE)/.git"
	test "$$(git -C "$(SING_BOX_SOURCE)" describe --tags --exact-match 2>/dev/null)" = "$(EXPECTED_CORE_TAG)"
	if ! git -C "$(SING_BOX_SOURCE)" apply --check --reverse "$(CORE_PROTOCOL_PATCH)" >/dev/null 2>&1; then \
		git -C "$(SING_BOX_SOURCE)" apply --check "$(CORE_PROTOCOL_PATCH)"; \
		git -C "$(SING_BOX_SOURCE)" apply "$(CORE_PROTOCOL_PATCH)"; \
	fi

test_ios_core_protocol_patch: check_ios_core
	cd "$(SING_BOX_SOURCE)" && go test -tags "without_vmess_vless without_openvpn_openconnect_naive" ./include
	cd "$(SING_BOX_SOURCE)" && go test -tags "with_low_memory with_quic without_vmess_vless without_openvpn_openconnect_naive" ./protocol/tuic
	cd "$(SING_BOX_SOURCE)" && ! go list -deps -tags "without_vmess_vless without_openvpn_openconnect_naive with_quic" ./experimental/libbox | grep -E '/protocol/(vmess|vless|openvpn|openconnect|naive)$$'

build_libbox_ios: check_ios_core
	cd "$(SING_BOX_SOURCE)" && PATH="$(GO_BIN_PATH):$$PATH" go run ./cmd/internal/build_libbox -target apple -platform ios -without-vmess-vless -without-openvpn-openconnect-naive
	if test -d "$(SING_BOX_SOURCE)/Libbox.xcframework"; then \
		rm -rf "$(CURDIR)/Libbox.xcframework"; \
		mv "$(SING_BOX_SOURCE)/Libbox.xcframework" "$(CURDIR)/Libbox.xcframework"; \
	fi
	test -d "$(CURDIR)/Libbox.xcframework"

check_ios_development_signing:
	test -n "$(TEAM_ID)"
	test -n "$(BUNDLE_ID)"

archive_ios_development: check_ios_development_signing
	rm -rf "$(IOS_DEVELOPMENT_ARCHIVE_PATH)"
	xcodebuild archive $(XCODEBUILD_FLAGS) $(IOS_PROVISIONING_FLAGS) -scheme SFI -configuration Release -destination 'generic/platform=iOS' -archivePath "$(IOS_DEVELOPMENT_ARCHIVE_PATH)" DEVELOPMENT_TEAM="$(TEAM_ID)" BASE_PACKAGE_IDENTIFIER="$(BUNDLE_ID)" | xcbeautify

export_ios_development: check_ios_development_signing
	rm -rf "$(IOS_DEVELOPMENT_EXPORT_PATH)"
	xcodebuild -exportArchive $(IOS_PROVISIONING_FLAGS) -archivePath "$(IOS_DEVELOPMENT_ARCHIVE_PATH)" -exportOptionsPlist SFI/Export.plist -exportPath "$(IOS_DEVELOPMENT_EXPORT_PATH)"

package_ios_development: archive_ios_development export_ios_development

package_ios_development_trimmed: build_libbox_ios package_ios_development

build_macos:
	xcodebuild build $(XCODEBUILD_FLAGS) -scheme SFM -configuration Debug -destination 'generic/platform=macOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

build_macos_standalone:
	xcodebuild build $(XCODEBUILD_FLAGS) -scheme SFM.System -configuration Debug -destination 'generic/platform=macOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

build_tvos:
	xcodebuild build $(XCODEBUILD_FLAGS) -scheme SFT -configuration Debug -destination 'generic/platform=tvOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

release: release_ios release_macos release_tvos

release_ios: archive_ios upload_ios

archive_ios:
	rm -rf build/SFI.xcarchive
	xcodebuild archive $(XCODEBUILD_FLAGS) -scheme SFI -configuration Release -destination 'generic/platform=iOS' -archivePath build/SFI.xcarchive | xcbeautify

upload_ios:
	xcodebuild -exportArchive -archivePath build/SFI.xcarchive -exportOptionsPlist SFI/Upload.plist

release_macos: archive_macos upload_macos

archive_macos:
	rm -rf build/SFM.xcarchive
	xcodebuild archive $(XCODEBUILD_FLAGS) -scheme SFM -configuration Release -archivePath build/SFM.xcarchive | xcbeautify

upload_macos:
	xcodebuild -exportArchive -archivePath build/SFM.xcarchive -exportOptionsPlist SFI/Upload.plist

release_tvos: archive_tvos upload_tvos

archive_tvos:
	rm -rf build/SFT.xcarchive
	xcodebuild archive $(XCODEBUILD_FLAGS) -scheme SFT -configuration Release -archivePath build/SFT.xcarchive | xcbeautify

upload_tvos:
	xcodebuild -exportArchive -archivePath build/SFT.xcarchive -exportOptionsPlist SFI/Upload.plist

release_macos_standalone: release_macos_dmg release_macos_pkg

# Archive commands
archive_macos_standalone_apple:
	rm -rf build/SFM.System-arm64.xcarchive
	xcodebuild archive $(XCODEBUILD_FLAGS) -scheme SFM.System -configuration Release -archivePath build/SFM.System-arm64.xcarchive -derivedDataPath build/SFM.System-arm64.dd ARCHS=arm64 | xcbeautify

archive_macos_standalone_intel:
	rm -rf build/SFM.System-x86_64.xcarchive
	xcodebuild archive $(XCODEBUILD_FLAGS) -scheme SFM.System -configuration Release -archivePath build/SFM.System-x86_64.xcarchive -derivedDataPath build/SFM.System-x86_64.dd ARCHS=x86_64 | xcbeautify

archive_macos_standalone_universal:
	rm -rf build/SFM.System-universal.xcarchive
	xcodebuild archive $(XCODEBUILD_FLAGS) -scheme SFM.System -configuration Release -archivePath build/SFM.System-universal.xcarchive -derivedDataPath build/SFM.System-universal.dd | xcbeautify

archive_macos_standalone: archive_macos_standalone_apple archive_macos_standalone_intel archive_macos_standalone_universal

# Export commands
export_macos_standalone_apple:
	rm -rf build/SFM.System-arm64
	xcodebuild -exportArchive -archivePath build/SFM.System-arm64.xcarchive -exportOptionsPlist SFM.System/Export.plist -exportPath build/SFM.System-arm64

export_macos_standalone_intel:
	rm -rf build/SFM.System-x86_64
	xcodebuild -exportArchive -archivePath build/SFM.System-x86_64.xcarchive -exportOptionsPlist SFM.System/Export.plist -exportPath build/SFM.System-x86_64

export_macos_standalone_universal:
	rm -rf build/SFM.System-universal
	xcodebuild -exportArchive -archivePath build/SFM.System-universal.xcarchive -exportOptionsPlist SFM.System/Export.plist -exportPath build/SFM.System-universal

# DMG commands
build_macos_dmg_apple: archive_macos_standalone_apple export_macos_standalone_apple
	rm -f build/SFM-Apple.dmg
	create-dmg \
		--volname "sing-box" \
		--volicon "build/SFM.System-arm64/SFM.app/Contents/Resources/AppIcon.icns" \
		--icon "SFM.app" 0 0 \
		--hide-extension "SFM.app" \
		--app-drop-link 0 0 \
		--skip-jenkins \
		"build/SFM-Apple.dmg" "build/SFM.System-arm64/SFM.app"

build_macos_dmg_intel: archive_macos_standalone_intel export_macos_standalone_intel
	rm -f build/SFM-Intel.dmg
	create-dmg \
		--volname "sing-box" \
		--volicon "build/SFM.System-x86_64/SFM.app/Contents/Resources/AppIcon.icns" \
		--icon "SFM.app" 0 0 \
		--hide-extension "SFM.app" \
		--app-drop-link 0 0 \
		--skip-jenkins \
		"build/SFM-Intel.dmg" "build/SFM.System-x86_64/SFM.app"

build_macos_dmg_universal: archive_macos_standalone_universal export_macos_standalone_universal
	rm -f build/SFM-Universal.dmg
	create-dmg \
		--volname "sing-box" \
		--volicon "build/SFM.System-universal/SFM.app/Contents/Resources/AppIcon.icns" \
		--icon "SFM.app" 0 0 \
		--hide-extension "SFM.app" \
		--app-drop-link 0 0 \
		--skip-jenkins \
		"build/SFM-Universal.dmg" "build/SFM.System-universal/SFM.app"

build_macos_dmg: build_macos_dmg_apple build_macos_dmg_intel build_macos_dmg_universal

# DMG notarize commands
notarize_macos_dmg_apple:
	xcrun notarytool submit "build/SFM-Apple.dmg" --wait --keychain-profile "notarytool-password"
	xcrun stapler staple "build/SFM-Apple.dmg"

notarize_macos_dmg_intel:
	xcrun notarytool submit "build/SFM-Intel.dmg" --wait --keychain-profile "notarytool-password"
	xcrun stapler staple "build/SFM-Intel.dmg"

notarize_macos_dmg_universal:
	xcrun notarytool submit "build/SFM-Universal.dmg" --wait --keychain-profile "notarytool-password"
	xcrun stapler staple "build/SFM-Universal.dmg"

notarize_macos_dmg: notarize_macos_dmg_apple notarize_macos_dmg_intel notarize_macos_dmg_universal

# DMG release commands
release_macos_dmg_apple: build_macos_dmg_apple notarize_macos_dmg_apple
release_macos_dmg_intel: build_macos_dmg_intel notarize_macos_dmg_intel
release_macos_dmg_universal: build_macos_dmg_universal notarize_macos_dmg_universal
release_macos_dmg: release_macos_dmg_apple release_macos_dmg_intel release_macos_dmg_universal

# PKG commands
build_macos_pkg_apple: archive_macos_standalone_apple export_macos_standalone_apple
	rm -f build/SFM-Apple.pkg
	rm -rf build/pkgroot-arm64
	mkdir -p build/pkgroot-arm64
	ditto "build/SFM.System-arm64/SFM.app" "build/pkgroot-arm64/SFM.app"
	pkgbuild --root "build/pkgroot-arm64" \
		--component-plist SFM.System/component.plist \
		--identifier io.nekohasekai.sfavt.standalone \
		--install-location /Applications \
		--min-os-version 13.0 \
		--compression latest \
		build/component-arm64.pkg
	productbuild --distribution SFM.System/distribution-arm64.xml \
		--package-path build \
		--resources SFM.System/Resources \
		--sign "$(INSTALLER_SIGN_IDENTITY)" \
		build/SFM-Apple.pkg
	rm -rf build/pkgroot-arm64
	rm -f build/component-arm64.pkg

build_macos_pkg_intel: archive_macos_standalone_intel export_macos_standalone_intel
	rm -f build/SFM-Intel.pkg
	rm -rf build/pkgroot-x86_64
	mkdir -p build/pkgroot-x86_64
	ditto "build/SFM.System-x86_64/SFM.app" "build/pkgroot-x86_64/SFM.app"
	pkgbuild --root "build/pkgroot-x86_64" \
		--component-plist SFM.System/component.plist \
		--identifier io.nekohasekai.sfavt.standalone \
		--install-location /Applications \
		--min-os-version 13.0 \
		--compression latest \
		build/component-x86_64.pkg
	productbuild --distribution SFM.System/distribution-x86_64.xml \
		--package-path build \
		--resources SFM.System/Resources \
		--sign "$(INSTALLER_SIGN_IDENTITY)" \
		build/SFM-Intel.pkg
	rm -rf build/pkgroot-x86_64
	rm -f build/component-x86_64.pkg

build_macos_pkg_universal: archive_macos_standalone_universal export_macos_standalone_universal
	rm -f build/SFM-Universal.pkg
	rm -rf build/pkgroot-universal
	mkdir -p build/pkgroot-universal
	ditto "build/SFM.System-universal/SFM.app" "build/pkgroot-universal/SFM.app"
	pkgbuild --root "build/pkgroot-universal" \
		--component-plist SFM.System/component.plist \
		--identifier io.nekohasekai.sfavt.standalone \
		--install-location /Applications \
		--min-os-version 13.0 \
		--compression latest \
		build/component-universal.pkg
	productbuild --distribution SFM.System/distribution-universal.xml \
		--package-path build \
		--resources SFM.System/Resources \
		--sign "$(INSTALLER_SIGN_IDENTITY)" \
		build/SFM-Universal.pkg
	rm -rf build/pkgroot-universal
	rm -f build/component-universal.pkg

build_macos_pkg: build_macos_pkg_apple build_macos_pkg_intel build_macos_pkg_universal

build_macos_pkg_all: archive_macos_standalone_universal export_macos_standalone_universal
	bash SFM.System/package_from_universal.sh

# PKG notarize commands
notarize_macos_pkg_apple:
	xcrun notarytool submit build/SFM-Apple.pkg --wait --keychain-profile "notarytool-password"
	xcrun stapler staple build/SFM-Apple.pkg

notarize_macos_pkg_intel:
	xcrun notarytool submit build/SFM-Intel.pkg --wait --keychain-profile "notarytool-password"
	xcrun stapler staple build/SFM-Intel.pkg

notarize_macos_pkg_universal:
	xcrun notarytool submit build/SFM-Universal.pkg --wait --keychain-profile "notarytool-password"
	xcrun stapler staple build/SFM-Universal.pkg

notarize_macos_pkg: notarize_macos_pkg_apple notarize_macos_pkg_intel notarize_macos_pkg_universal

notarize_macos_pkg_all:
	set -e; \
	xcrun notarytool submit build/SFM-Apple.pkg --wait --keychain-profile "notarytool-password" & apple_pid=$$!; \
	xcrun notarytool submit build/SFM-Intel.pkg --wait --keychain-profile "notarytool-password" & intel_pid=$$!; \
	xcrun notarytool submit build/SFM-Universal.pkg --wait --keychain-profile "notarytool-password" & universal_pid=$$!; \
	wait $$apple_pid; wait $$intel_pid; wait $$universal_pid
	xcrun stapler staple build/SFM-Apple.pkg
	xcrun stapler staple build/SFM-Intel.pkg
	xcrun stapler staple build/SFM-Universal.pkg

# PKG release commands
release_macos_pkg_apple: build_macos_pkg_apple notarize_macos_pkg_apple
release_macos_pkg_intel: build_macos_pkg_intel notarize_macos_pkg_intel
release_macos_pkg_universal: build_macos_pkg_universal notarize_macos_pkg_universal
release_macos_pkg: release_macos_pkg_apple release_macos_pkg_intel release_macos_pkg_universal

fmt:
	swiftformat .

fmt_install:
	brew install swiftformat

lint:
	swiftlint

lint_install:
	brew install swiftlint

dmg_install:
	brew install create-dmg

clean:
	rm -rf build/SFI.xcarchive
	rm -rf build/SFM.xcarchive
	rm -rf build/SFT.xcarchive
	rm -rf build/SFM.System-arm64.xcarchive
	rm -rf build/SFM.System-x86_64.xcarchive
	rm -rf build/SFM.System-universal.xcarchive
	rm -rf build/SFM.System-arm64
	rm -rf build/SFM.System-x86_64
	rm -rf build/SFM.System-universal
	rm -rf build/SFI.dd
	rm -rf build/SFM.dd
	rm -rf build/SFT.dd
	rm -rf build/SFM.System-arm64.dd
	rm -rf build/SFM.System-x86_64.dd
	rm -rf build/SFM.System-universal.dd
	rm -f build/SFM-Apple.dmg build/SFM-Intel.dmg build/SFM-Universal.dmg
	rm -f build/SFM-Apple.pkg build/SFM-Intel.pkg build/SFM-Universal.pkg
