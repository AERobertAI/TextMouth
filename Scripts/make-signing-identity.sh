#!/bin/bash
#
# make-signing-identity.sh: gives this Mac a stable code-signing identity for
# TextMouth, and signs builds with it.
#
# Why: macOS records each app's microphone permission (TCC) against the app's
# designated requirement (DR), the part of its signature that says "if you
# see me again, here is how you tell it is really me" (Apple's TN3127). An ad
# hoc signature, which Xcode gives TextMouth, has a DR that is the hash of
# that one build, so every rebuild is a stranger to macOS and it asks for the
# microphone again. Signed with this identity, every build's DR is the same:
#
#   identifier "com.textmouth.TextMouth" and certificate leaf = H"<the certificate's SHA-1>"
#
# so a permission given to one build carries over to the next.
#
# Usage:
#   Scripts/make-signing-identity.sh              (or: make signing-identity)
#       Creates, when this Mac has none, a self-signed certificate named
#       "TextMouth Developer" for code signing, with its private key, in the
#       login keychain, and says what it did. Run it again and it says the
#       identity is already there and changes nothing.
#   Scripts/make-signing-identity.sh --sign-app <path to .app>
#       Signs the app with that identity, keeping the entitlements its build
#       gave it, and prints its designated requirement; `make build` runs
#       this. When this Mac has no such identity, the app keeps the ad hoc
#       signature it has, and a note says so.
#
# How the identity is made: OpenSSL (the copy macOS ships, /usr/bin/openssl,
# whose PKCS #12 files `security import` reads; OpenSSL 3's default ones it
# cannot) writes a key and a certificate whose extended key usage is code
# signing, and `security import` puts both in the keychain, with codesign
# allowed to use the key without asking and the key marked non-extractable.
#
# No trust setting is made. codesign signs with an untrusted self-signed
# identity, and the DR above names the certificate by its hash, which a check
# against the DR compares without asking whether anyone trusts it (measured
# on macOS 26.3). Trusting the certificate would only change how Keychain
# Access shows it, and changing the user's trust settings always opens a
# password panel (SecTrustSettings.h), which this script never does.
#
# Environment:
#   TEXTMOUTH_SIGNING_KEYCHAIN   the keychain to create the identity in, in
#                                place of the login keychain; the self-test
#                                (Scripts/check-selftest.sh) uses a
#                                throwaway one. --sign-app always looks in
#                                the keychains codesign searches.
#
# Exit status: 0 on success, including "already there" and "no identity, ad
# hoc kept"; 1 when an identity could not be made, or the app could not be
# signed with an identity this Mac has.

set -uo pipefail

# The certificate's name, which is also how codesign finds the identity.
readonly IDENTITY_NAME="TextMouth Developer"
# How long the certificate is valid: twenty years, so it never expires under
# a build. A new certificate means a new DR, and one more permission prompt.
readonly VALIDITY_DAYS=7300
# The OpenSSL macOS ships (LibreSSL). Its PKCS #12 encryption is one
# `security import` reads; OpenSSL 3's default is not.
readonly OPENSSL=/usr/bin/openssl

# The temporary folder that holds the private key while the identity is made,
# or empty. A global, not a local, so the exit trap below still sees it after
# the function that made it has returned.
WORK=""

# remove_work: removes the temporary folder, private key and all, if there is
# one. Runs on every exit.
remove_work() {
  if [[ -n $WORK ]]; then
    rm -rf "$WORK"
  fi
}
trap remove_work EXIT

# fail <message>: prints <message> as an error and exits with status 1.
fail() {
  echo "make-signing-identity: error: $1" >&2
  exit 1
}

# target_keychain: prints the keychain the identity is created in: the one
# TEXTMOUTH_SIGNING_KEYCHAIN names, or else the login keychain, as `security
# login-keychain` reports it (quoted and indented, which is removed here).
target_keychain() {
  if [[ -n ${TEXTMOUTH_SIGNING_KEYCHAIN:-} ]]; then
    printf '%s\n' "$TEXTMOUTH_SIGNING_KEYCHAIN"
    return
  fi
  security login-keychain | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/'
}

# identity_hash [keychain]: prints the SHA-1 of the first code-signing
# identity named IDENTITY_NAME, valid or not, in <keychain>, or in every
# keychain codesign searches when none is given; prints nothing when there is
# none. An identity is a certificate together with its private key, so a
# certificate whose key is missing is not one.
identity_hash() {
  # `security find-identity` lists each identity as
  #   1) 2556...9BFE "TextMouth Developer" (CSSMERR_TP_NOT_TRUSTED)
  # first under "Matching identities", the section read here.
  security find-identity -p codesigning "$@" 2>/dev/null |
    awk -v quoted="\"$IDENTITY_NAME\"" 'index($0, quoted) { print $2; exit }'
}

# create_identity: creates the identity in the target keychain unless it has
# one already, and says which of the two happened.
create_identity() {
  local keychain existing password
  keychain=$(target_keychain)
  [[ -n $keychain ]] || fail "could not find the login keychain"

  existing=$(identity_hash "$keychain")
  if [[ -n $existing ]]; then
    echo "The signing identity \"$IDENTITY_NAME\" is already in $keychain (SHA-1 $existing); nothing to do."
    echo "make build and make install sign TextMouth with it."
    return 0
  fi
  # A certificate of that name without its key cannot sign, and a second
  # certificate beside it would make the name ambiguous to codesign.
  if security find-certificate -c "$IDENTITY_NAME" "$keychain" >/dev/null 2>&1; then
    fail "$keychain holds a certificate named \"$IDENTITY_NAME\" without its private key. Delete it in Keychain Access (or: security delete-certificate -c \"$IDENTITY_NAME\" \"$keychain\"), then run this again."
  fi
  [[ -x $OPENSSL ]] || fail "$OPENSSL is missing; it ships with macOS"

  # The private key is written only into this folder, readable by this user
  # alone, which is removed on every exit (remove_work).
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/textmouth-signing.XXXXXX") || fail "could not make a temporary folder"
  chmod 700 "$WORK"

  # A certificate for code signing only: its own issuer (self-signed), not a
  # certificate authority, used for digital signatures, and marked for code
  # signing, which codesign looks for.
  cat > "$WORK/certificate.cnf" <<EOF
[ req ]
distinguished_name = subject
prompt = no
x509_extensions = code_signing
[ subject ]
CN = $IDENTITY_NAME
[ code_signing ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
  (umask 077 && "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days "$VALIDITY_DAYS" \
      -config "$WORK/certificate.cnf" -keyout "$WORK/key.pem" -out "$WORK/certificate.pem" 2>"$WORK/openssl.log") ||
    fail "OpenSSL could not make the certificate: $(cat "$WORK/openssl.log")"

  # The key and certificate travel into the keychain together, as a PKCS #12
  # file protected by a password that lives only as long as this script.
  password=$("$OPENSSL" rand -hex 24) || fail "OpenSSL could not make a password"
  (umask 077 && "$OPENSSL" pkcs12 -export -name "$IDENTITY_NAME" -inkey "$WORK/key.pem" \
      -in "$WORK/certificate.pem" -out "$WORK/identity.p12" -passout "pass:$password" 2>"$WORK/openssl.log") ||
    fail "OpenSSL could not package the identity: $(cat "$WORK/openssl.log")"

  # -T lets codesign use the key without asking; -x keeps the key from ever
  # being exported.
  security import "$WORK/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign -x >/dev/null ||
    fail "security import could not add the identity to $keychain"

  existing=$(identity_hash "$keychain")
  [[ -n $existing ]] || fail "the identity was imported into $keychain, but codesign cannot find it there"
  echo "Created the signing identity \"$IDENTITY_NAME\" (SHA-1 $existing) in $keychain."
  echo "make build and make install now sign TextMouth with it, so macOS keeps the"
  echo "microphone permission from one build to the next. The first build signed this"
  echo "way asks for the permission once more."
}

# sign_app <app>: signs <app> with the identity when this Mac has one, keeping
# the entitlements its build gave it and asking no timestamp server; prints
# the designated requirement it gave. Without an identity it leaves the app's
# ad hoc signature and says what that means.
sign_app() {
  local app=$1 hash requirement
  [[ -d $app ]] || fail "$app is not an app bundle"

  hash=$(identity_hash)
  if [[ -z $hash ]]; then
    echo "note: this Mac has no \"$IDENTITY_NAME\" signing identity, so $app keeps its ad hoc"
    echo "signature, and macOS will ask for the microphone again after each build."
    echo "Run make signing-identity once to make one."
    return 0
  fi

  # The identity is named by its hash, so another certificate of the same
  # name in some other keychain cannot make the choice ambiguous. There is no
  # nested code to sign first: Swift packages are linked into the app.
  if ! codesign --force --sign "$hash" --preserve-metadata=entitlements --timestamp=none "$app" 2>&1; then
    fail "codesign could not sign $app with \"$IDENTITY_NAME\" (SHA-1 $hash). If the login keychain is locked, as in an SSH session, unlock it with: security unlock-keychain"
  fi
  requirement=$(codesign --display --requirements - "$app" 2>/dev/null | sed -n 's/^designated => //p')
  echo "==> Signed $app with \"$IDENTITY_NAME\"; its designated requirement: $requirement"
}

# main <arguments...>: creates the identity, or with --sign-app signs an app.
main() {
  case ${1:-} in
    "")
      create_identity ;;
    --sign-app)
      [[ $# -eq 2 ]] || fail "usage: $0 --sign-app <path to .app>"
      sign_app "$2" ;;
    *)
      fail "usage: $0 [--sign-app <path to .app>]" ;;
  esac
}

main "$@"
