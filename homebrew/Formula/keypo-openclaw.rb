class KeypoOpenclaw < Formula
  desc "Hardware-secured secrets for OpenClaw via Secure Enclave"
  homepage "https://github.com/keypo-us/keypo-cli"
  version "0.1.0"
  license "MIT"

  url "https://github.com/keypo-us/keypo-cli/releases/download/openclaw-v#{version}/keypo-openclaw-#{version}-macos-arm64.tar.gz"
  sha256 "PLACEHOLDER"

  depends_on macos: :sonoma
  depends_on arch: :arm64
  depends_on "keypo-us/tap/keypo-signer"

  livecheck do
    url :stable
    strategy :github_latest
  end

  def install
    bin.install "keypo-openclaw"
  end

  def caveats
    <<~EOS
      keypo-openclaw requires Apple Silicon (M1 or later).
      macOS 14 (Sonoma) or later is required.

      keypo-signer must be installed (added as a dependency).

      On headless devices (Mac Mini without Touch ID), initialize with:
        keypo-signer vault init --open-only

      On first launch, macOS contacts Apple's servers to verify
      the notarization ticket (internet connection required).
    EOS
  end

  test do
    assert_match "keypo-openclaw", shell_output("#{bin}/keypo-openclaw --help")
  end
end
