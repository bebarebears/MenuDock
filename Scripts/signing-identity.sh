#!/bin/bash
#
# Creates a stable, self-signed code-signing identity for local MenuDock builds.
#
# Why this exists
# ---------------
# MenuDock signs ad-hoc by default (CODE_SIGN_IDENTITY = "-"), which needs no developer account
# and is what lets a fresh clone build and run. The cost is invisible until you grant MenuDock a
# macOS permission: an ad-hoc signature has no certificate, so the designated requirement macOS
# records is the binary's *cdhash*, and every rebuild produces a new one. TCC then refuses the
# grant it made yesterday — while still showing the switch as on — and auto-paste stops working
# with no visible cause. `tccd` logs it as:
#
#     Failed to match existing code requirement for subject com.bebarebears.MenuDock
#                                                and service kTCCServiceAccessibility
#
# Signing with a certificate — any certificate, including a self-signed one — changes the
# requirement to `certificate leaf = H"..."`, which is the same for every build made with it. The
# Accessibility grant then survives rebuilds, and `make install` stops silently breaking paste.
#
# This is for the development loop. Shipped builds still want a Developer ID and notarisation;
# see the CODE_SIGN_IDENTITY note in project.yml.
#
# Usage:  make signing-identity     (or run this script directly)
#
# macOS will ask for your login keychain password — once, to add the certificate. The certificate
# is self-signed, local to this Mac, and grants nothing beyond signing your own builds.

set -euo pipefail

NAME="MenuDock Developer"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -qF "\"${NAME}\""; then
    echo "Signing identity \"${NAME}\" already exists — nothing to do."
    echo "Builds will use it automatically; run 'make install' to re-sign with it."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A code-signing certificate needs the codeSigning extended key usage; without it `codesign`
# rejects the identity and `security find-identity -p codesigning` will not list it.
cat > "${WORK}/openssl.cnf" <<'CONFIG'
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = MenuDock Developer

[ ext ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG

echo "Creating a self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "${WORK}/openssl.cnf" \
    -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" 2>/dev/null

openssl pkcs12 -export -legacy \
    -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
    -out "${WORK}/identity.p12" -passout pass: 2>/dev/null

echo "Adding it to your login keychain…"
# -T /usr/bin/codesign lets codesign use the key without prompting on every build.
security import "${WORK}/identity.p12" -k "${KEYCHAIN}" -P "" -T /usr/bin/codesign -A

# A self-signed certificate in your own keychain is not trusted as a root until it is said so.
# User domain (-d is deliberately omitted), so this needs your password rather than sudo.
echo "Marking it trusted for code signing — macOS will ask for your password…"
security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" "${WORK}/cert.pem"

if security find-identity -v -p codesigning | grep -qF "\"${NAME}\""; then
    echo
    echo "Done. \"${NAME}\" will be picked up automatically by make."
    echo
    echo "Because this changes MenuDock's signature one last time, any permission you have"
    echo "already granted it is now stale. Reset it once:"
    echo
    echo "    tccutil reset Accessibility com.bebarebears.MenuDock"
    echo "    make install"
    echo
    echo "then re-add MenuDock in System Settings › Privacy & Security › Accessibility."
    echo "It will stick across every build after that."
else
    echo "The certificate was created but is not being offered for code signing." >&2
    echo "Open Keychain Access, find \"${NAME}\", and set its trust for Code Signing to" >&2
    echo "\"Always Trust\"." >&2
    exit 1
fi
