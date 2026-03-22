class KeypoWallet < Formula
  desc "ERC-4337 smart wallet CLI with Secure Enclave P-256 signing"
  homepage "https://github.com/keypo-us/keypo-cli"
  version "0.4.2"
  license "MIT"

  url "https://github.com/keypo-us/keypo-cli/releases/download/v#{version}/keypo-wallet-#{version}-macos-arm64.tar.gz"
  sha256 "6b2275e7ed904e484df3e91820b2ae2862b4b34248b1adde83ea0bbcf2da18fc"

  depends_on macos: :sonoma
  depends_on arch: :arm64

  def install
    bin.install "keypo-wallet"
    prefix.install "keypo-signer.app"
    bin.install_symlink prefix/"keypo-signer.app/Contents/MacOS/keypo-signer"
  end

  def caveats
    <<~EOS
      If you previously installed keypo-signer standalone, uninstall it first:
        brew uninstall keypo-signer

      keypo-wallet requires Apple Silicon (M1 or later).
      macOS 14 (Sonoma) or later is required.

      Touch ID signing requires Touch ID hardware:
        - MacBook Pro/Air with Touch ID
        - Mac with Magic Keyboard with Touch ID

      Signing keys are stored in the Secure Enclave and cannot be extracted.

      On first launch, macOS contacts Apple's servers to verify
      the notarization ticket (internet connection required).
    EOS
  end

  conflicts_with "keypo-signer", because: "keypo-wallet includes keypo-signer"

  test do
    system "#{bin}/keypo-wallet", "--help"
    assert_match version.to_s, shell_output("#{bin}/keypo-signer info --system")
  end
end
