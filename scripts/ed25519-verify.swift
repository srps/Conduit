// Checks a Sparkle EdDSA signature the way the installed app will:
//   swift ed25519-verify.swift <public key base64> <signature base64> <file>
// Exits 0 when the signature is valid, 1 otherwise. Used by make-appcast.sh
// so a release never publishes a feed the shipped key would reject.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let publicKeyData = Data(base64Encoded: arguments[1]),
      let signature = Data(base64Encoded: arguments[2]),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
    FileHandle.standardError.write(Data("usage: ed25519-verify.swift <public key> <signature> <file>, with base64 keys\n".utf8))
    exit(2)
}
let data: Data
do {
    data = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
} catch {
    FileHandle.standardError.write(Data("cannot read \(arguments[3]): \(error.localizedDescription)\n".utf8))
    exit(2)
}
exit(publicKey.isValidSignature(signature, for: data) ? 0 : 1)
