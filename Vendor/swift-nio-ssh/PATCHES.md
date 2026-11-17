# SwiftNIO SSH, vendored with patches

Source: https://github.com/apple/swift-nio-ssh 0.15.1, commit `d1985926494b624e751b379009dc83f3395fd88a`,
Apache License 2.0 (`LICENSE.txt`). Only `Sources/NIOSSH` is kept; the manifest is trimmed to that target.

Why: older network gear (Catalyst 2960/3750 on IOS 12.2/15.x, small-business switches, many appliances) only
speaks finite-field Diffie-Hellman, `ssh-rsa` host keys, CBC/CTR ciphers and HMAC-SHA1. Upstream NIOSSH keeps
key exchange and host key types internal, so they can't be added from outside. Every change is marked
`Netdeck patch` in the code. Modern algorithms stay first in every list, so a device that supports them never
gets an older one.

## Added (`Sources/NIOSSH/Legacy/`)

- `SSHUnsignedInteger.swift`: a small unsigned big integer and Montgomery modular exponentiation (CIOS) for
  Diffie-Hellman and RSA verification. Not constant time; it only handles ephemeral DH values and public RSA data.
- `DiffieHellmanKeyExchange.swift`: `diffie-hellman-group16-sha512`, `-group14-sha256`, `-group14-sha1` and
  `-group1-sha1` (RFC 4253 §8, RFC 8268; primes from RFC 3526/2409, checked against the RFC formula). It reuses
  the ECDH message types (same numbers and layout). Also `SSHKeyDerivation`, which extends keys longer than
  the hash (RFC 4253 §7.2).
- `RSA.swift`: `ssh-rsa`, `rsa-sha2-256`, `rsa-sha2-512` (RFC 8332) host keys, verified by re-encoding
  EMSA-PKCS1-v1_5 (moduli from 512 to 16384 bits; old Cisco keys can be 768 bits). An RSA private key backed by
  Security.framework, for SSH servers in tests.
- `CipherMACTransportProtection.swift`: `aes{128,192,256}-ctr`, `aes{128,192,256}-cbc`, `3des-cbc` with
  `hmac-sha2-256`, `hmac-sha2-512`, `hmac-sha1` (encrypt-and-MAC), through CommonCrypto.
- `NIOSSHAlgorithms.swift`: the public lists (`keyExchange`, `hostKey`, `legacy`,
  `clientTransportProtectionSchemes`) and `NIOSSHNegotiatedAlgorithms`.

## Changed

- `SSHKeyExchangeStateMachine`: DH implementations after the elliptic curves; RSA host key algorithms after the
  others; the key exchange list comes from the configuration; cipher and MAC names offered once each (several
  schemes share a cipher); `rsa-sha2-*` accepted for an `ssh-rsa` key; negotiation failures say what the peer
  offered ("no matching cipher found. Their offer: ..."); the client reports what was negotiated.
- `EllipticCurveKeyExchange`: session keys through `SSHKeyDerivation`, so a key may be longer than the hash
  (`hmac-sha2-512` after a SHA-256 exchange; upstream asserts that every key fits in one hash).
- `NIOSSHPublicKey`, `NIOSSHSignature`, `NIOSSHPrivateKey`, `NIOSSHCertifiedPublicKey`: an `rsa` case.
- `SSHClientConfiguration`: `keyExchangeAlgorithms`, `algorithmsNegotiated`. `SSHServerConfiguration`:
  `keyExchangeAlgorithms`.
- `NIOSSHError`: `keyExchangeNegotiationFailure(_:theirOffer:)`.
- `Package.swift`: the target is optimised (`-O`) in debug builds too, since unoptimised key exchange
  arithmetic is about 20 times slower.

## Not supported

`diffie-hellman-group-exchange-*` (its group request messages would need new state machine states), RSA
certificates, RSA user keys, `hmac-md5`, `*-etm@openssh.com` MACs, `chacha20-poly1305@openssh.com`.

## Tests

`Tests/NetdeckCoreTests/LegacySSHTests.swift` in Netdeck: full sessions against an in-process NIOSSH server, and
handshakes against the system OpenSSH `sshd` run as the current user with only legacy algorithms enabled.
