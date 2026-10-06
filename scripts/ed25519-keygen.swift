// Prints a new Ed25519 key pair for Sparkle update signing, as two lines:
// the private seed, then the public key, both base64 of their 32 raw bytes.
// That is the form Sparkle's `sign_update --ed-key-file` reads and its
// `SUPublicEDKey` expects. LibreSSL 3.3 has no Ed25519, so CryptoKit makes it.
// Run by scripts/create-release-identity.sh; the output goes to a pipe.
import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
