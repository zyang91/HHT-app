# One-command workflows. Run `make help`.
# Needs: Xcode (xcode-select pointing at it), xcodegen (brew install xcodegen), python3.

SCHEME      := HHT
PROJECT     := HHT.xcodeproj
BUILD_DIR   := .build-xcode
SIM_NAME    ?= iPhone 17
EXPORT_DIR  := $(BUILD_DIR)/export-check
PY          := analysis/.venv/bin/python

.PHONY: help test project build sim phone analysis-env export-check ci clean

help:            ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-14s %s\n", $$1, $$2}'

test:            ## run the core test suite (inference, edits, export, analytics)
	cd Packages/HHTCore && swift test

project:         ## regenerate HHT.xcodeproj from project.yml
	xcodegen generate

build: project   ## compile the iOS app for the simulator (no signing)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(BUILD_DIR) CODE_SIGNING_ALLOWED=NO build | tail -3

sim: build       ## install + launch in the simulator with demo data (SIM_NAME="iPhone 17")
	xcrun simctl boot "$(SIM_NAME)" 2>/dev/null || true
	open -a Simulator
	xcrun simctl install "$(SIM_NAME)" $(BUILD_DIR)/Build/Products/Debug-iphonesimulator/HHT.app
	xcrun simctl launch "$(SIM_NAME)" com.zyang91.hht -hhtDemo YES

phone: project   ## build, sign and install on the USB-connected iPhone (also renews the 7-day signature)
	./scripts/install-phone.sh

analysis-env:    ## create analysis/.venv with pandas etc.
	python3 -m venv analysis/.venv
	$(PY) -m pip install -q -r analysis/requirements.txt

export-check:    ## end-to-end: Swift writes a real export, Python loads and validates it
	rm -rf $(EXPORT_DIR) && mkdir -p $(EXPORT_DIR)
	cd Packages/HHTCore && HHT_EXPORT_DIR=$(abspath $(EXPORT_DIR)) swift test --filter writeExportForPythonCheck
	cd analysis && $(if $(wildcard $(PY)),.venv/bin/python,python3) check_export.py $(abspath $(EXPORT_DIR))

ci: test build export-check   ## everything GitHub Actions runs

clean:
	rm -rf $(BUILD_DIR) Packages/HHTCore/.build
