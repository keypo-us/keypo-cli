class KeypoSigner < Formula
  desc "Manage P-256 signing keys in the Apple Secure Enclave"
  homepage "https://github.com/keypo-us/keypo-wallet"
  version "0.1.0"
  license "MIT"

  url "https://github.com/keypo-us/keypo-wallet/releases/download/v#{version}/keypo-wallet-#{version}-macos-arm64.tar.gz"
  sha256 "957511aea2108d05ecc5ed6b9629879308899cf5752b3a294a4760236910159a"

  depends_on macos: :sonoma
  depends_on arch: :arm64

  livecheck do
    url :stable
    strategy :github_latest
  end

  conflicts_with "keypo-wallet", because: "keypo-wallet includes keypo-signer"

  def install
    bin.install "keypo-signer"
  end

  def caveats
    <<~EOS
      keypo-signer requires Apple Silicon (M1 or later).
      macOS 14 (Sonoma) or later is required.

      Touch ID signing requires Touch ID hardware:
        - MacBook Pro/Air with Touch ID
        - Mac with Magic Keyboard with Touch ID

      Keys are stored in the Secure Enclave and cannot be extracted.

      On first launch, macOS contacts Apple's servers to verify
      the notarization ticket (internet connection required).

      For the full smart wallet CLI, install keypo-wallet instead:
        brew install keypo-us/tap/keypo-wallet
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/keypo-signer info --system")
  end
end
