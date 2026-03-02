class KeypoSigner < Formula
  desc "Manage P-256 signing keys in the Apple Secure Enclave"
  homepage "https://github.com/keypo-us/keypo-signer-cli"
  version "0.1.0"
  license "MIT"

  url "https://github.com/keypo-us/keypo-signer-cli/releases/download/v#{version}/keypo-signer-#{version}-macos-arm64.tar.gz"
  sha256 "1e37fc5e7780777468fb5414bd8cdeb9d3a4914f3b38b6762b5a6862a1fb1b83"

  depends_on macos: :sonoma
  depends_on arch: :arm64

  livecheck do
    url :stable
    strategy :github_latest
  end

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
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/keypo-signer info --system")
  end
end
