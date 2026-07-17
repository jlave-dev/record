# frozen_string_literal: true

# Homebrew formula for the Record macOS CLI.
class Record < Formula
  desc "Native macOS app capture and local transcription CLI"
  homepage "https://github.com/jlave-dev/record"
  url "https://github.com/jlave-dev/record/releases/download/v0.3.0/record-0.3.0-macos-arm64.tar.gz"
  version "0.3.0"
  sha256 "f9799e61c270d130c54ebbbf3738e51396aacd2b02214df2be7e1b68ad2b8d45"
  license "MIT"

  depends_on arch: :arm64
  depends_on "ffmpeg"
  depends_on macos: :sequoia
  depends_on "whisper-cpp"

  def install
    prefix.install Dir["*"]
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/record --version").strip
    assert_match "record plugin install", shell_output("#{bin}/record --help")
  end
end
