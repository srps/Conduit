// Prints the Ed25519 public key (base64) for the private seed (base64) on
// stdin, so create-release-identity.sh can check a restored update key
// against the committed Resources/sparkle-public-ed-key before uploading it.
import CryptoKit
import Foundation

guard let line = readLine(), let seed = Data(base64Encoded: line),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    FileHandle.standardError.write(Data("stdin is not a base64 Ed25519 seed\n".utf8))
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
